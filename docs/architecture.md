# Architecture

## Layout

```
~/.docal/                           # docal's own code + state (never your sites)
├── repo/                           # git checkout — what `docal update` pulls
│   ├── scripts/
│   │   ├── docal                   # CLI entrypoint
│   │   ├── lib-config.sh           # global config + sites_dir resolution
│   │   ├── lib-doctor.sh           # `docal doctor` checks
│   │   ├── setup-wordpress.sh      # create / import wizard
│   │   ├── lib-import-wpress.sh    # shared .wpress restore + finalize logic
│   │   ├── start-proxy.sh
│   │   ├── ensure-wp-rewrites.sh
│   │   ├── fix-wp-permissions.sh
│   │   └── lint-php.sh
│   ├── templates/                  # docker-compose.yml.tpl, Dockerfile.tpl
│   ├── plugins/                    # optional local plugin .zips (gitignored)
│   ├── wpress/                     # optional All-in-One .wpress (gitignored)
│   ├── dbs/                        # optional .sql / .sql.gz dumps (gitignored)
│   └── files/                      # optional uploads .zips (gitignored)
├── proxy/
│   ├── docker-compose.yml          # Traefik (auto-generated)
│   └── certs/                      # TLS certificates, one per site
└── config                          # flat KEY=value file (docal config)

<sites_dir>/                        # default ~/Sites — see docs/configuration.md
└── <site-slug>/
    ├── docker-compose.yml
    ├── Dockerfile
    ├── uploads.ini
    ├── .env                        # per-site credentials and settings
    └── wordpress/                  # WordPress source
```

`~/.docal` holds code and shared state; `<sites_dir>` holds every WordPress project, and can live
anywhere (a different drive, a synced folder, wherever). Neither one needs the other to exist in
any particular relative location — that's the whole point of the split. See
[configuration.md](configuration.md) for how `sites_dir` is resolved.

## Legacy clone/symlink installs

Before this split existed, docal was just a git clone with sites living in `<clone>/sites/`. That
still works: run `scripts/docal` straight out of an old clone and `docal install` symlinks it, the
same as always. The first time any command resolves `sites_dir` and finds no config yet, it checks
whether the clone it's running from has a non-empty `sites/` folder — if so, that folder is adopted
as `sites_dir` and saved to `~/.docal/config`, instead of silently starting a second, empty
`~/Sites`. Nothing is moved or renamed. See `resolve_sites_dir()` in
`scripts/lib-config.sh`.

## How `docal create` works

1. `docal create` runs `setup-wordpress.sh`, which generates `docker-compose.yml` from the
   per-site template.
2. WordPress is cloned (official repo by default, or a custom one with `--repo`) into
   `<site-dir>/wordpress/`.
3. `wp-config.php` is generated with unique credentials and a Unix socket connection to MySQL
   (avoids `caching_sha2_password` issues with MySQL 8.x).
4. mkcert generates a TLS certificate for `<slug>.<domain>`.
5. The shared Traefik proxy is started (if not already running) and the site containers come up.
6. The `wp-init` container installs WordPress via WP-CLI and creates the admin account.
7. If a `.wpress`/db/uploads import source was picked interactively, it runs and finalizes (see
   [importing-sites.md](importing-sites.md)).

MySQL connection uses a Unix socket (`/var/run/mysqld/mysqld.sock`, shared via a Docker volume)
instead of TCP, which avoids `caching_sha2_password` authentication issues with MySQL 8.x from the
bundled MariaDB client.

## Docker preflight

No Docker Desktop dependency — Docker Engine runs natively inside WSL2, managed by systemd.
`scripts/docal`'s `ensure_docker()` runs before every command that needs it:

1. `docker_is_native()` treats `docker` as "not installed" if the resolved binary lives under
   `/mnt/*` — that's Docker Desktop's WSL-integration shim, which stops responding once Desktop is
   closed — rather than a real package.
2. If not native, `install_docker_engine()` adds the official `download.docker.com/linux/ubuntu`
   apt repo and installs `docker-ce docker-ce-cli containerd.io docker-buildx-plugin
   docker-compose-plugin`.
3. `start_docker_daemon()` starts the daemon via systemd (or `service` as a fallback) and polls
   `docker info`.
4. If the daemon responds but the current shell hasn't picked up the `docker` group yet, the whole
   invocation re-execs itself via `exec sg docker -c '...'` so you never have to open a new
   terminal.

`docal doctor` surfaces the same checks without the auto-install/auto-fix side effects (unless you
pass `--fix`), so you can see what's wrong before anything changes.

## Contributing

See [../CONTRIBUTING.md](../CONTRIBUTING.md) for conventions, known environment quirks, and how to
run the test suite.
