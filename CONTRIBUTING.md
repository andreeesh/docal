# Contributing to Docal

Notes for anyone changing the CLI, the site creation/import flow, the Docker preflight, or these docs.

## Layout

```
docal/
├── scripts/docal                 # CLI entrypoint
├── scripts/setup-wordpress.sh    # create / import wizard
├── scripts/lib-import-wpress.sh  # shared .wpress restore logic
├── scripts/start-proxy.sh
├── scripts/ensure-wp-rewrites.sh
├── scripts/fix-wp-permissions.sh
├── scripts/lint-php.sh
├── templates/                    # docker-compose.yml.tpl, Dockerfile.tpl
├── proxy/                        # Traefik + certs/
├── plugins/                      # optional local plugin .zips (gitignored)
├── wpress/                       # optional All-in-One .wpress (gitignored)
├── dbs/                          # optional .sql / .sql.gz dumps (gitignored)
├── files/                        # optional uploads .zips (gitignored)
└── sites/<slug>/                 # generated sites (gitignored)
```

## CLI (`scripts/docal`)

Commands: `create`, `start`, `stop`, `restart`, `rebuild`, `fix-rewrites`, `delete`, `list`,
`info`, `logs`, `exec`, `wp`, `lint`, `replace-url`, `export-db`, `import-db`, `import-wpress`,
`clean-certs`, `proxy`, `tunnel`, `install`, `help`.

`create` without a site name is interactive; with a name runs `--non-interactive` (skips
plugin/import prompts).

## Docker preflight (`ensure_docker`)

No Docker Desktop dependency — Docker Engine runs natively inside WSL2 (Ubuntu), managed by
systemd. `scripts/docal` runs `ensure_docker` before every command except `help`, `install`,
and `clean-certs`, so the whole thing is unattended:

1. `docker_is_native` — treats `docker` as "not installed" if the resolved binary lives under
   `/mnt/*` (that's Docker Desktop's WSL-integration shim, which stops responding once Desktop
   is closed) rather than a real package.
2. If not native: `install_docker_engine` adds the official `download.docker.com/linux/ubuntu`
   apt repo (keyed off `$UBUNTU_CODENAME`/`$VERSION_CODENAME`) and installs
   `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`. Both
   `apt-get update` calls are `|| warn`-guarded — an unrelated broken third-party apt repo must
   not abort the Docker install under `set -e`. Only `apt-get install` failures are fatal.
3. `start_docker_daemon` — `systemctl enable --now docker` (falls back to `service docker
   start`), then polls `docker info` for up to ~15s.
4. If the daemon responds but this shell's process doesn't have the `docker` group applied yet
   (e.g. `usermod -aG docker` just ran), it re-execs the whole invocation via
   `exec sg docker -c '...'` — so the user never has to open a new terminal. Guarded by
   `DOCAL_SG_RETRIED` against infinite retries.
5. If systemd isn't active in the WSL distro (`/run/systemd/system` missing), warns the user to
   add `systemd=true` under `[boot]` in `/etc/wsl.conf` and run `wsl --shutdown` from Windows —
   that step can't be automated from inside WSL.

README.md documents the manual equivalent of all of this for anyone who wants to set it up
themselves instead of relying on the automatic check. **Keep the two in sync** whenever you
touch `ensure_docker`/`install_docker_engine`/`start_docker_daemon`.

## Create / import flow

Sources are **mutually exclusive**: All-in-One (`.wpress`) **or** database/uploads.

1. If both `wpress/*.wpress` and (`dbs/*.{sql,sql.gz}` or `files/*.zip`) exist → ask method `1` or `2`.
2. Method **wpress**: pick a backup → AI1WM restore → finalize.
3. Method **db/files**: optionally pick a dump from `dbs/`, optionally pick a zip from `files/` → import → finalize if DB was imported.

`docal import-wpress` reuses the same restore + finalize logic (in `lib-import-wpress.sh`)
against an already-created site, so `create --aiowp` and `import-wpress` never drift apart.

### `dbs/`
- Accepts `.sql` and `.sql.gz`.
- Imports into the site's MySQL container (`mysql` / `gunzip | mysql`).

### `files/`
- Accepts `.zip` archives of media uploads.
- Always lands in `wp-content/uploads/`.
- Detection (Python `zipfile`): root (or single wrapper) contains `uploads/` → copy that
  folder's contents; otherwise treat zip contents as loose files into `uploads/`. Ignores
  `__MACOSX` / dotfiles at the top level when detecting.

### Finalize after content import

Shared helper `finalize_imported_site` in `lib-import-wpress.sh`:

- Deactivate WP Rocket + clear rocket/min caches
- `siteurl` / `home` → `https://<slug>.<domain>`
- `wp search-replace` old→new (https + http), skip `guid`
- Rewrite absolute URLs in uploads `*.css`
- Elementor `flush_css` (best-effort)
- `ensure-wp-rewrites.sh`
- Ensure `admin` / `admin`
- `wp cache flush`

Files-only import (no DB): chown uploads + rewrites; skip URL replace.

## Known environment quirks

- **MySQL 8.x/9.x vs the bundled MariaDB client:** `caching_sha2_password` breaks `wp db
  check`. The `wp-init` container replaces it with a small PHP `mysqli_connect` retry loop
  (see the comment above the base64 blob in `templates/docker-compose.yml.tpl` — it's
  base64 only because docker-compose would otherwise try to interpolate the PHP script's own
  `$variables`, not because it's obfuscated; the decoded source sits right above it).
- **WP Rocket crashes WP-CLI (and every page load) after a `.wpress` restore:** its Cloudflare
  integration throws a fatal PHP error on the `init` hook once the restored options are loaded.
  Always run `wp plugin deactivate wp-rocket --skip-plugins=wp-rocket` immediately after a
  restore, before anything else touches the site. `lib-import-wpress.sh` does this
  automatically; if you're scripting around it manually, don't skip this step.
- **Migrating a machine from Docker Desktop to native Docker Engine:** any container originally
  created under Docker Desktop has bind mounts baked in using Desktop's special path
  (`/run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/...`), which doesn't resolve under the
  native engine — the container exits immediately (OCI runtime error). Fix per site with
  `docker compose up -d --force-recreate` (safe, doesn't touch volumes/data); do the same for
  `proxy/`. Watch out for orphaned `docker-proxy` helper processes left over from a container
  that crashed on its first native-engine start — they keep relaying host ports to a stale
  container IP even after the real container is fixed, causing wildly inconsistent symptoms
  (wrong container's response, phantom install screens, 404s). Diagnose with
  `ps aux | grep docker-proxy` vs. `docker inspect <container> --format
  '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'`; fix by killing the stale
  `docker-proxy` PIDs (needs root) and recreating the port-publishing container.

## Testing

`tests/test_setup_generates_wp_config.sh` runs `setup-wordpress.sh --skip-docker` and checks
that `wp-config.php` comes out with real DB credentials — no Docker daemon required. CI
(`.github/workflows/ci.yml`) runs this plus `bash -n` and `shellcheck` on every script for each
push/PR. Run the same checks locally before opening a PR:

```bash
bash -n scripts/docal scripts/*.sh tests/*.sh
shellcheck scripts/docal scripts/*.sh tests/*.sh   # if you have it installed
bash tests/test_setup_generates_wp_config.sh
```

## Conventions

- Prefer extending `scripts/docal` + `scripts/setup-wordpress.sh` over one-off hacks.
- Keep import prompts interactive (Enter = skip), matching the plugins/wpress UX.
- Don't invent new import source directories — use `wpress/`, `dbs/`, `files/`, `plugins/`.
- Site credentials and env live in `sites/<slug>/.env`.
- After a DB import on an existing site, prefer the `docal import-db` / `docal replace-url`
  patterns already in the CLI over ad hoc `wp` calls.
- README.md is the user-facing reference — update it whenever CLI/import/Docker-preflight
  behavior changes.
