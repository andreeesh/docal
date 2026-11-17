# Command reference

Run `docal help` any time for a compact version of this list.

## Sites

### `docal create [<site>] [options]`

Creates a full WordPress site. Without a site name, opens an interactive wizard; with one, runs
non-interactively (skips plugin/import prompts).

| Option | Default | Description |
|---|---|---|
| `--title=<title>` | site name | WordPress site title |
| `--domain=<domain>` | `localhost`, or config `default_domain` | Local base domain |
| `--email=<email>` | `admin@docal.com`, or config `admin_email` | Admin email |
| `--admin-user=<user>` | `admin`, or config `admin_user` | Admin username |
| `--php=<version>` | `latest`, or config `default_php` | PHP version (`8.3`, `8.2`, `8.1`, `8.0`) |
| `--mysql=<version>` | `8.4`, or config `default_mysql` | MySQL version (`8.4`, `8.0`) |
| `--upload=<size>` | `2G`, or config `default_upload_limit` | Max upload size |
| `--repo=<url>` | official WordPress | Git repository to clone instead of official WordPress |
| `--aiowp` | — | Install and activate All-in-One WP Migration |

```bash
docal create                                    # interactive wizard
docal create myblog --title="My Blog"
docal create shop --php=8.2 --mysql=8.0
docal create portfolio --upload=500M
docal create myblog --aiowp
```

See [configuration.md](configuration.md) for setting these as persistent defaults, and
[importing-sites.md](importing-sites.md) for the local-plugins and content-import prompts that
appear during interactive creation.

### `docal list [--json]`

Lists all sites with status, PHP/MySQL version, and URL. `--json` emits the same data as a JSON
array for scripting.

```bash
docal list
docal list --json | jq -r '.[] | select(.status=="running") | .site'
```

### `docal info <site>`

Compact status dashboard: running state, URL, admin URL, PHP/MySQL versions, path, per-container
status, and the admin username. Full `.env` (including DB credentials) is at
`<site-dir>/.env`, referenced at the bottom of the output rather than dumped in full.

```bash
docal info myblog
```

### `docal start <site> --safe [--port 8443]`

Runs a plugin-free WordPress preview from a temporary file copy on a
new internal Docker network, with a separate TLS proxy bound only to
localhost. A PHP IPv4/IPv6/DNS egress test must succeed (i.e., fail to
reach outside) before the web container starts.

```bash
docal start mysite --safe --port 8443
# Open https://mysite.localhost:8443
docal stop mysite
```

The preview uses a disposable WordPress file copy and a **disposable MySQL
clone** populated by streaming SQL from the already-running original local
DB. The original DB must be healthy: Safe Start refuses to start or
reconfigure it. WordPress mounts only the private clone's Unix socket.
`docal stop` removes preview MySQL volumes and temporary web resources but
leaves the original DB running. No normal WordPress service or shared
Traefik network is started. Requires rsync and a local TLS certificate.
The implementation has passed a synthetic WordPress E2E on WSL2.
See [Safe preview](safe-start.md).

### `docal start` / `stop` / `restart` <site>

Start, stop, or restart a site's containers. `start` also starts the shared Traefik proxy if it
isn't already running.

### `docal rebuild <site>`

Rebuilds the Docker image from scratch (no cache), restarts containers, fixes `wp-content`
permissions, and reconfigures permalinks. Use after changing `--php`, `--upload`, or other
build-time options.

### `docal delete <site>`

Removes containers, volumes (database), files, and TLS certificates. Requires typing the site
name to confirm. **Irreversible.**

## WordPress

### `docal wp <site> <command>`

Runs a WP-CLI command inside the WordPress container.

```bash
docal wp myblog plugin list --status=active
docal wp myblog user list
docal wp myblog theme install twentytwentyfour --activate
```

### `docal import <new-site> --zip ZIP --db SQL`

Creates a **new** WordPress site from a standard ZIP and SQL database dump.
The ZIP can contain WordPress core plus `wp-content`, or `wp-content`
alone. The SQL dump can be `.sql`, `.sql.gz`, or a gzip-compressed
`.gz` SQL file. It never overwrites an existing Docal site.

```bash
docal import myblog --zip ./site.zip --db ./backup.sql.gz
docal start myblog --safe --port 8443
```

Input files are validated and staged before creating a site. Docal then
imports into a new, empty MySQL database, preserves its generated
`wp-config.php`, detects the table prefix, updates serialized production
URLs, and generates a fresh local administrator password. Imported WordPress
remains stopped until `docal start` is run explicitly.

Failed imports can leave an incomplete, import-pending **new** site for
diagnosis. The standard `docal start` command refuses to start such a
site; manually remove it with `docal delete` before retrying.

The ZIP + SQL restore flow was validated on Docker/MySQL. Inspect
restored sites using `--safe` before deliberately running their plugins
with ordinary `docal start`. See [ZIP + SQL design](import-zip-sql-design.md).

### `docal pull <new-site> --ssh ALIAS --path REMOTE_PATH [--dry-run]`

Clones a remote site's `wp-content` and database to a **new** local Docal
site using a host alias configured in `~/.ssh/config`.

```bash
docal pull mysite --ssh prod-alias --path /var/www/html --dry-run
docal pull mysite --ssh prod-alias --path /var/www/html
docal start mysite --safe --port 8443
```

`--dry-run` verifies the remote WP-CLI table prefix and prerequisites,
without transferring data or starting Docker. Actual transfer uses
read-only rsync (excluding common caches/backups and symlinks) plus a
streamed WP-CLI SQL export. The existing ZIP + SQL importer handles
normalization and creates the local site, which remains stopped.

Requires remote `rsync` and `wp`, local key-based SSH, a trusted host key,
and an absolute remote WordPress path. No remote credentials are stored.
See [SSH import](import-ssh.md) for scope, consistency limits and safety
considerations. The remote acquisition and subsequent local restore have
been exercised end to end on a real WordPress site. This is still
best-effort consistency, not an atomic production snapshot.

### `docal import-wpress <site> [file]`

Restores an All-in-One WP Migration (`.wpress`) backup into an **already-created** site. See
[importing-sites.md](importing-sites.md) for the full workflow, including what gets cleaned up
automatically afterward (URLs, WP Rocket, Elementor CSS, permalinks, local admin).

### `docal replace-url <site> <old-url> <new-url>`

Replaces a URL across the entire database (including serialized data via WP-CLI's
`search-replace`), updates `siteurl`/`home`, flushes the cache, and restarts WordPress.

```bash
docal replace-url myblog https://myblog.com https://myblog.localhost
```

### `docal fix-rewrites <site>`

Repairs permalink rules and the REST API without a full rebuild. Useful when `/wp-json/` 404s or
pretty URLs stop working.

### `docal lint <site> [path ...]`

Lints PHP files using the PHP CLI already inside that site's container, so linting matches the
site's actual PHP version.

```bash
docal lint myblog
docal lint myblog wp-content/plugins/my-plugin/my-plugin.php
docal lint myblog --changed wp-content/plugins/my-plugin main   # only files changed vs "main"
```

## Database

### `docal export-db <site> [file]`

Exports the database to a `.sql.gz` file in the site directory.

### `docal import-db <site> [file]`

Imports a `.sql.gz` dump into the site's database. Without a filename, shows an interactive
picker over `.sql.gz` files already in the site directory.

## Development

### `docal mail [start|stop|status|url]`

Manages the shared local-only Mailpit inbox (no live email delivery):

```bash
docal mail start
docal mail status
docal mail url               # http://localhost:8025
docal mail stop
```

The Mailpit web UI is exposed only to `127.0.0.1:8025`. SMTP uses
`docal-mailpit:1025` **only** inside Docker's `docal-proxy` network;
SMTP port 1025 is not published to the host. Normal new Docal WordPress
images use `msmtp-mta` for default PHP `mail()`/`wp_mail()`, whereas
Safe Start continues to disable sendmail and outbound network access.
Existing images and SMTP plugins are not silently changed. See
[Mailpit setup](mailpit.md) for testing and security limits.


### `docal exec <site> [command]`

Runs a command in the WordPress container (default: `bash`).

### `docal logs <site> [service]`

Tails logs in real time. Without a service name, shows all; with one, filters (`wordpress`, `db`).

## Sharing

### `docal tunnel <start|stop|status|delete|url> <site>`

Exposes a running site to the internet through a Cloudflare Tunnel. See
[tunnels.md](tunnels.md) — this is optional and requires your own domain in Cloudflare DNS.
**Anything exposed this way is public** — treat it accordingly.

## Docal itself

### `docal doctor [--fix]`

Diagnoses your environment: WSL2, distro, systemd, Docker Engine/daemon/group/Compose, mkcert and
its local CA, curl, git, ports 80/443/8080, the Traefik proxy, and whether your sites directory is
writable. `--fix` applies the same safe, idempotent fixes the automatic Docker preflight already
uses (install/start Docker, `mkcert -install`) — it never touches sites or config.

### `docal config`, `docal config get/set`

See [configuration.md](configuration.md).

### `docal version`

Prints the installed version.

### `docal update`

Fast-forward-updates a git-checkout install in place (refuses if you've hand-modified the
checkout). Never touches sites.

### `docal install`

Symlinks the current checkout's `scripts/docal` onto `PATH`. Usually done for you by
[install.sh](installation.md); useful if you're running from a manual clone.

### `docal uninstall`

Removes the `docal` command and `~/.docal`. **Never touches your sites** — it prints their
location and reminds you their containers keep running until you `docker compose down` each one.

### `docal clean-certs`

Finds TLS certificates in `~/.docal/proxy/certs/` that don't match any existing site and offers
to delete them.

### `docal proxy [start|stop|restart|status]`

Manages the shared Traefik proxy. The dashboard is at `http://localhost:8080` (no
authentication — local-only, see [security.md](security.md)). Starting the
proxy also attempts to start shared Mailpit; a Mailpit port conflict must
not stop Traefik.
