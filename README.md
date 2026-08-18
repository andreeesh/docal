# Docal

Local WordPress site manager with Docker + Traefik + automatic HTTPS — think **Lando** or **DDEV**, purpose-built for WordPress on WSL2.

Each site runs in its own container at `https://<name>.localhost` with a valid TLS certificate (mkcert) and a ready-to-use `admin / admin` account.

> **Local development only.** Every default here (the `admin`/`admin` account, database passwords, the open Traefik dashboard) is chosen for convenience on your own machine, not for security. Never expose these containers or ports to the internet. See [Security notes](#security-notes).

---

## Requirements

- **Docker Engine** running natively inside WSL2 (no Docker Desktop needed — see below)
- **mkcert** for local TLS certificates
- **Python 3** (to generate `wp-config.php`)

### Install Docker Engine natively in WSL (no Docker Desktop)

Docker Desktop isn't required. Any `docal` command that touches Docker (`create`, `start`, `restart`, `rebuild`, `list`, etc.) runs a preflight check first: if Docker Engine isn't installed, it installs it; if the daemon isn't running, it starts it; if your shell hasn't picked up the `docker` group yet, it re-execs itself with the group applied — all without you needing to intervene. `docal install` and `docal help` skip this check.

If you'd rather set it up yourself (or want to understand what the automatic check does), here are the manual steps:

**1. Enable systemd in WSL** (requires Windows 11 / WSL 0.67+). Edit (or create) `/etc/wsl.conf` inside your distro:

```ini
[boot]
systemd=true
```

Then restart WSL from PowerShell/CMD:

```powershell
wsl --shutdown
```

Reopen your WSL terminal and confirm systemd is active:

```bash
ps -p 1   # should show "systemd", not "init"
```

**2. Install Docker Engine (official repo, not the Ubuntu one)**

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**3. Enable and start the daemon, and let your user run Docker without `sudo`**

```bash
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Close and reopen the WSL terminal (or run `newgrp docker`) so the group change takes effect, then verify:

```bash
docker run hello-world
docker compose version
```

From here on, Docker starts automatically every time you open a WSL terminal — no need to launch anything from Windows.

### Install mkcert on WSL

```bash
sudo apt install libnss3-tools
curl -Lo mkcert https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v1.4.4-linux-amd64
chmod +x mkcert && sudo mv mkcert /usr/local/bin/
mkcert -install
```

---

## Install the CLI

Clone the repository, then symlink the CLI onto your `PATH`:

```bash
git clone https://github.com/<your-username>/docal.git
cd docal
sudo ln -sf "$(pwd)/scripts/docal" /usr/local/bin/docal
```

Or run `docal install` from inside the repo directory (does the same thing, and prints the manual command if it can't write to `/usr/local/bin`).

After this, `docal` is available from any directory. All site data lives under the repo's `sites/` folder, so keep the clone somewhere permanent.

---

## Quick start

```bash
# Interactive wizard
docal create

# One-liner
docal create myblog --title="My Blog"

# List all sites
docal list
```

The first `create` takes a couple of minutes: it clones WordPress, generates a TLS certificate, starts the containers, and installs WordPress automatically.

---

## Commands

### `docal create [<site>] [options]`

Creates a full WordPress site. Without arguments opens the interactive wizard; with a site name runs non-interactively.

| Option | Default | Description |
|---|---|---|
| `--title=<title>` | site name | WordPress site title |
| `--domain=<domain>` | `localhost` | Local base domain |
| `--email=<email>` | `admin@docal.com` | Admin email |
| `--php=<version>` | `latest` | PHP version (`8.3`, `8.2`, `8.1`) |
| `--mysql=<version>` | `8.4` | MySQL version (`8.4`, `8.0`) |
| `--upload=<size>` | `2G` | Max upload size |
| `--repo=<url>` | official WordPress | Git repository to clone instead of official WordPress |
| `--aiowp` | — | Install and activate All-in-One WP Migration |

```bash
docal create                                    # interactive wizard
docal create myblog --title="My Blog"
docal create shop --php=8.2 --mysql=8.0
docal create portfolio --upload=500M
docal create myblog --aiowp
```

**Local plugins:** if a `plugins/` folder exists at the repo root, `create` will list its `.zip` files and ask which ones to install. Place any premium or private plugin zips there — they're never committed to the repo (see `.gitignore`).

**Content import (interactive `create` only):** pick **one** method — they do not combine:

| Method | Folder | Files | What happens |
|---|---|---|---|
| All-in-One WP Migration | `wpress/` | `.wpress` | Restore via AI1WM, then finalize |
| Database + uploads | `dbs/` + `files/` | `.sql` / `.sql.gz`, uploads `.zip` | Import dump and/or unzip media into `wp-content/uploads/` |

If both methods have files available, `create` asks which method to use. Within database/uploads you can skip DB, skip files, or import both.

Uploads zips are handled intelligently: if the archive contains an `uploads/` folder (at the root or inside a single wrapper directory), only that folder's contents are copied; otherwise loose files go straight into `wp-content/uploads/`.

**Finalize after import:** old domain → `https://<site>.localhost` (serialized DB + uploads CSS), WP Rocket deactivated, Elementor CSS flushed, permalinks/rewrites fixed, `admin` / `admin` recreated.

### `docal import-wpress <site> [file]`

Restores an All-in-One WP Migration (`.wpress`) backup into an **already-created** site — useful when you want to refresh a site's content without recreating it. Picks from `wpress/*.wpress` interactively if no file is given. Runs the same finalize steps as `create` (WP Rocket deactivation, URL replace, permalinks, `admin`/`admin`).

```bash
docal import-wpress myshop                # picks from wpress/*.wpress
docal import-wpress myshop backup.wpress
```

⚠️ This replaces the site's database, uploads, and installed plugins/themes with whatever is in the backup. Asks for confirmation first.

### `docal list`

Lists all sites with their status (running / stopped) and URL.

```bash
docal list
```

### `docal info <site>`

Shows URL, credentials, configuration and container status.

```bash
docal info myblog
```

### `docal start <site>`

Starts the site containers (also starts the Traefik proxy if it's not running).

```bash
docal start myblog
```

### `docal stop <site>`

Stops containers without deleting data.

```bash
docal stop myblog
```

### `docal restart <site>`

Restarts containers.

```bash
docal restart myblog
```

### `docal rebuild <site>`

Rebuilds the Docker image from scratch (no cache), restarts containers, fixes `wp-content` permissions, and reconfigures permalinks. Use this after changing `--php`, `--upload`, or other build-time options.

```bash
docal rebuild myblog
```

### `docal fix-rewrites <site>`

Fixes permalink rules and REST API without a full rebuild. Useful when `/wp-json/` returns 404 or pretty URLs stop working.

```bash
docal fix-rewrites myblog
```

### `docal delete <site>`

Removes the site: containers, volumes (database), files, and TLS certificates.
Requires typing the site name to confirm. **Irreversible.**

```bash
docal delete myblog
```

### `docal logs <site> [service]`

Tails logs in real time. Without a service name shows all; with a service name filters.

```bash
docal logs myblog
docal logs myblog wordpress
docal logs myblog db
```

### `docal exec <site> [command]`

Opens a shell in the WordPress container.

```bash
docal exec myblog              # opens bash
docal exec myblog bash
docal exec myblog php -v
```

### `docal wp <site> <command>`

Runs a WP-CLI command inside the WordPress container.

```bash
docal wp myblog plugin list --status=active
docal wp myblog user list
docal wp myblog theme install twentytwentyfour --activate
docal wp myblog option get siteurl
docal wp myblog post list
```

### `docal lint <site> [path ...]`

Lints PHP files using the PHP CLI already inside that site's container, so linting always matches the site's actual PHP version — no local PHP install needed.

```bash
docal lint myblog                                          # lint all plugins/themes
docal lint myblog wp-content/plugins/my-plugin/my-plugin.php
docal lint myblog --changed wp-content/plugins/my-plugin main   # only files changed vs "main"
```

### `docal replace-url <site> <old-url> <new-url>`

Replaces a URL across the entire database (useful after importing from production).
Also updates the `siteurl` and `home` options, flushes the cache, and restarts WordPress.

```bash
docal replace-url myblog https://myblog.com https://myblog.localhost
```

### `docal export-db <site> [file]`

Exports the database to a `.sql.gz` file in the site directory.

```bash
docal export-db myblog
docal export-db myblog backup-before-update
```

### `docal import-db <site> [file]`

Imports a `.sql.gz` dump into the site's database. Without a filename shows an interactive picker.

```bash
docal import-db myblog
docal import-db myblog myblog-20250101-120000.sql.gz
```

### `docal clean-certs`

Finds TLS certificates in `proxy/certs/` that don't match any existing site and offers to delete them.

```bash
docal clean-certs
```

### `docal proxy [start|stop|restart|status]`

Manages the global Traefik proxy (shared across all sites).

```bash
docal proxy start     # starts (done automatically by create/start)
docal proxy stop
docal proxy status
```

The Traefik dashboard is available at `http://localhost:8080` (no authentication — local-only, see [Security notes](#security-notes)).

### `docal tunnel <start|stop|status|delete|url> <site>` (optional)

Exposes a running site to the internet through a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — useful for sharing a local site for client review, or testing webhooks that need a public URL. Not needed for normal local development.

Requires your own domain managed in Cloudflare DNS and `cloudflared` installed and logged in:

```bash
export DOCAL_TUNNEL_DOMAIN=example.com   # a domain you control in Cloudflare DNS
cloudflared login                        # one-time, opens a browser

docal tunnel start  myblog               # https://myblog.example.com
docal tunnel status myblog
docal tunnel stop   myblog
docal tunnel delete myblog               # removes the tunnel and DNS record
```

### `docal install`

Symlinks `scripts/docal` to `/usr/local/bin/docal` so the CLI is available from anywhere.

---

## Credentials

All sites are created with:

| Field | Value |
|---|---|
| WordPress user | `admin` |
| WordPress password | `admin` |
| Admin URL | `https://<site>.localhost/wp-admin` |

Database credentials are stored in `sites/<site>/.env`.

---

## Security notes

Docal is built for **local development only**. It intentionally trades security for convenience, the same way Lando/DDEV/Valet do:

- Every site's WordPress admin account is `admin` / `admin`.
- Database passwords are randomly generated but stored in plaintext in `sites/<site>/.env`.
- The Traefik dashboard (`:8080`) has no authentication.
- TLS certificates are signed by your local mkcert CA, not a public CA — they're only trusted on machines where you've run `mkcert -install`.

None of this is a problem on your own machine behind your own firewall. It becomes a problem the moment any of these ports are reachable from the internet (e.g. via port forwarding, a cloud VM with public IPs, or `docal tunnel` pointed at credentials you care about). If you need to share a site externally, use `docal tunnel` with a throwaway domain and treat anything exposed through it as public.

---

## File structure

```
docal/
├── scripts/
│   ├── docal                       # CLI entrypoint
│   ├── setup-wordpress.sh          # site creation script
│   ├── lib-import-wpress.sh        # shared .wpress restore logic (create --aiowp + import-wpress)
│   ├── start-proxy.sh              # starts Traefik
│   ├── clone-official-wordpress.sh # clones WordPress
│   ├── ensure-wp-rewrites.sh       # fixes permalinks and REST API
│   ├── fix-wp-permissions.sh       # fixes wp-content ownership
│   └── lint-php.sh                 # lints PHP using the site's own container
├── templates/
│   ├── docker-compose.yml.tpl      # per-site template
│   └── Dockerfile.tpl
├── proxy/
│   ├── docker-compose.yml          # Traefik (auto-generated)
│   └── certs/                      # TLS certificates per site
├── plugins/                        # (optional) local .zip plugins to install
├── wpress/                         # (optional) .wpress backups to import
├── dbs/                            # (optional) .sql / .sql.gz dumps to import
├── files/                          # (optional) uploads .zip archives to import
└── sites/
    └── <site>/
        ├── docker-compose.yml
        ├── Dockerfile
        ├── uploads.ini
        ├── .env                    # credentials
        └── wordpress/              # WordPress source
```

---

## How it works

1. `docal create` runs `setup-wordpress.sh`, which generates `docker-compose.yml` from the template.
2. WordPress is cloned (official repo by default, or a custom one with `--repo`) into `sites/<site>/wordpress/`.
3. `wp-config.php` is generated with unique credentials and a Unix socket connection to MySQL (avoids `caching_sha2_password` issues with MySQL 8.x).
4. mkcert generates a TLS certificate for `<site>.localhost`.
5. Traefik is started (if not already running) and the site containers are brought up.
6. The `wp-init` container installs WordPress via WP-CLI and creates the `admin / admin` account.
7. If AIOWP is active and a backup is selected: the `.wpress` file is imported, the old domain is replaced with the new local URL across the entire database (including serialized data), CSS files in `uploads/` are patched, Elementor CSS is flushed, and the admin account is reset to `admin / admin`.

MySQL connection uses a Unix socket (`/var/run/mysqld/mysqld.sock` shared via Docker volume) instead of TCP, which avoids `caching_sha2_password` authentication issues with MySQL 8.x.

---

## Troubleshooting

**Site doesn't open in the browser**
```bash
docal info <site>          # check if containers are running
docal logs <site>          # look for errors
docal proxy status         # verify Traefik is running
```

**TLS certificate error in the browser**
```bash
mkcert -install            # install the mkcert root CA
# On Windows: also run in PowerShell as admin:
# mkcert -install
```

**Frontend has no styles after backup import**

This happens when the old domain is still embedded in Elementor data or CSS files. Run:
```bash
docal wp <site> search-replace "https://old-domain.com" "https://<site>.localhost" --recurse-objects --skip-columns=guid
# Then flush Elementor CSS and fix uploads permissions:
docal exec <site> chown -R www-data:www-data /var/www/html/wp-content/uploads
docal wp <site> elementor flush_css
```

**WP Rocket crashes WP-CLI after a backup import**

WP Rocket's Cloudflare integration throws a fatal PHP error during WP-CLI bootstrap (and can crash every page load, not just WP-CLI). Add `--skip-plugins=wp-rocket` to any `wp` command run after an import. `docal create` and `docal import-wpress` both handle this automatically.

**Reset from scratch on an existing site**
```bash
cd sites/<site>
docker compose down -v      # removes containers and database
docker compose up -d --build
docker compose run -T --rm wp-init
```

**Large import with All-in-One WP Migration (upload limit error)**
```bash
# Recreate the site with a higher upload limit (e.g. 12G)
docal create <site> --upload=12G --aiowp
```
Limits are applied in PHP (`uploads.ini`), Apache, Traefik (body size + no 60s timeout) and WordPress (`WP_MEMORY_LIMIT`). For very large files you can also copy the `.wpress` directly to `sites/<site>/wordpress/wp-content/ai1wm-backups/`.

**See all available commands**
```bash
docal help
```

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the project layout, conventions, and known environment quirks worth knowing before changing the CLI or import flows.

## License

[MIT](LICENSE)
