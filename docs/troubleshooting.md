# Troubleshooting

Start with:

```bash
docal doctor
```

It checks WSL2, distro, systemd, Docker Engine/daemon/group/Compose, mkcert and its local CA,
curl, git, ports 80/443/8080, the Traefik proxy, and your sites directory — and suggests a fix for
each failing item. `docal doctor --fix` applies the safe, idempotent ones automatically.

## Site doesn't open in the browser

```bash
docal info <site>          # check if containers are running
docal logs <site>          # look for errors
docal proxy status         # verify Traefik is running
```

## TLS certificate error in the browser

```bash
mkcert -install            # install the mkcert root CA
# On Windows: also run in PowerShell as admin:
# mkcert -install
```

## Frontend has no styles after a backup import

See [importing-sites.md](importing-sites.md#known-gotchas) — the old domain is usually still
embedded in Elementor data or a CSS file the automatic replace missed.

## WP Rocket crashes WP-CLI after a backup import

WP Rocket's Cloudflare integration throws a fatal PHP error during WP-CLI bootstrap (and can
crash every page load, not just WP-CLI). Add `--skip-plugins=wp-rocket` to any `wp` command you
run manually right after an import. `docal create` and `docal import-wpress` handle this
automatically for the steps they run.

## Reset a site from scratch

```bash
cd <site-dir>
docker compose down -v      # removes containers and database
docker compose up -d --build
docker compose run -T --rm wp-init
```

## Large import hits the upload limit

```bash
# Recreate the site with a higher upload limit (e.g. 12G)
docal create <site> --upload=12G --aiowp
```

Limits are applied in PHP (`uploads.ini`), Apache, Traefik (body size + no 60s timeout) and
WordPress (`WP_MEMORY_LIMIT`). For very large files you can also copy the `.wpress` directly to
`<site-dir>/wordpress/wp-content/ai1wm-backups/`.

## `docal update` refuses to update

`docal update` only fast-forwards a clean checkout. If it reports local changes, either commit or
stash them, or discard them if they were accidental (`git -C ~/.docal/repo status` to see what's
there first).

## Migrating a machine from Docker Desktop to native Docker Engine

Any container originally created under Docker Desktop has bind mounts baked in using Desktop's
special path (`/run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/...`), which doesn't resolve
under the native engine — the container exits immediately (OCI runtime error). Fix per site with:

```bash
cd <site-dir> && docker compose up -d --force-recreate   # safe, doesn't touch volumes/data
```

Do the same inside `~/.docal/proxy/`. Watch out for orphaned `docker-proxy` helper processes left
over from a container that crashed on its first native-engine start — they keep relaying host
ports to a stale container IP even after the real container is fixed, causing wildly inconsistent
symptoms (wrong container's response, phantom install screens, 404s). Diagnose with `ps aux |
grep docker-proxy` vs. `docker inspect <container> --format
'{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'`; fix by killing the stale
`docker-proxy` PIDs (needs root) and recreating the port-publishing container.

## See all available commands

```bash
docal help
```
