# Docal

**A WordPress-first local development environment for WSL2.**

Create, import and manage WordPress sites from the terminal with Docker, automatic HTTPS, WP-CLI
and WordPress-specific workflows — without Docker Desktop.

```bash
docal create mysite
```

```text
✓ WordPress installed
✓ PHP 8.3
✓ MySQL 8.4
✓ HTTPS configured
✓ WP-CLI ready

https://mysite.localhost
```

> **Local development only.** Every default here (the `admin`/`admin` account, database
> passwords, the open Traefik dashboard) is chosen for convenience on your own machine, not
> security. See [Security notes](docs/security.md).

---

## Why Docal?

General-purpose Docker environments are powerful, but WordPress developers repeatedly solve the
same WordPress-specific problems by hand: restoring a client's `.wpress` backup, replacing a
production domain across serialized data, disabling WP Rocket so WP-CLI stops crashing, matching a
site's exact PHP/MySQL versions, getting HTTPS working locally at all.

Docal automates the ones it can, today:

- Fresh WordPress installs, ready in one command
- `.wpress` (All-in-One WP Migration) restores, into a new or existing site
- SQL dump and uploads-archive imports
- Safe URL replacement across serialized data after an import
- Automatic WP Rocket cleanup and Elementor CSS regeneration after a restore
- WP-CLI, built in, running the site's own PHP version
- Per-project PHP and MySQL versions
- Automatic HTTPS via mkcert — no browser warnings
- Optional Cloudflare Tunnel for sharing a site publicly
- No Docker Desktop — Docker Engine runs natively inside WSL2

Nothing above is aspirational — see [Roadmap](#roadmap) for what's planned but not built yet
(Mailpit, a unified `import`, snapshots, `docal pull`).

## From production to local

```text
production-backup.wpress
          │
          ▼
   docal import-wpress mysite backup.wpress
          │
          ▼
   database + uploads restored
          │
          ▼
   production URL detected → replaced everywhere (incl. serialized data)
          │
          ▼
   WP Rocket disabled · Elementor CSS flushed · permalinks fixed
          │
          ▼
   https://mysite.localhost
```

```bash
docal import-wpress mysite production-backup.wpress
```

```text
✓ Backup restored
✓ Production URL detected: https://example.com
✓ URLs replaced
✓ WP Rocket disabled
✓ Elementor CSS regenerated
✓ Permalinks flushed
✓ Local administrator ready

https://mysite.localhost
```

See [docs/importing-sites.md](docs/importing-sites.md) for the full workflow, including plain SQL
dumps and uploads-only imports.

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/andreeesh/docal/main/install.sh | bash

docal doctor
docal create mysite
```

That's it — no Docker Desktop, no manual WSL setup unless `docal doctor` tells you something's
missing. Full installation details, including the manual/no-curl path, are in
[docs/installation.md](docs/installation.md).

## Common workflows

```bash
# Create a WordPress site
docal create mysite

# Bring in defaults so you stop typing the same flags every time
docal config set default_php 8.3
docal config set sites_dir ~/projects

# Import a production backup
docal import-wpress mysite client-backup.wpress

# Run WP-CLI
docal wp mysite plugin list

# Enter the container
docal exec mysite

# Export the database
docal export-db mysite

# Check your environment
docal doctor

# Share with a client
docal tunnel start mysite
```

Full command reference: [docs/commands.md](docs/commands.md).

## How is Docal different?

**Docal trades general-purpose flexibility for a more opinionated WordPress workflow.** It isn't
trying to out-feature DDEV or Lando — it's trying to need fewer decisions for the one stack it
supports.

| | Docal | DDEV | Lando | Local (WP Engine) | wp-env |
|---|---|---|---|---|---|
| Scope | WordPress-only | General-purpose (WP, Drupal, Laravel, ...) | General-purpose, via "recipes" | WordPress-only | WordPress-only (core/plugin/theme dev) |
| Interface | CLI-only | CLI-first | CLI-first | GUI-first desktop app | CLI-only |
| Docker Desktop required | No — native Docker Engine in WSL2 | No — Docker CE/Engine, OrbStack, Lima, Colima, rootless Podman all supported | No official requirement, but Windows docs default to Docker Desktop | No — doesn't use Docker at all (native local PHP/MySQL) | No, but Docker is the documented default |
| WSL2 support | First-class (this is the target platform) | First-class — dedicated install flow | Documented, thinner than DDEV's | Not documented | Minimal (one line, no dedicated guide) |
| Restoring a `.wpress` backup | Built-in (`docal import-wpress`) | Not built-in | Not built-in | Not built-in (own zip+SQL format) | Not built-in |
| WordPress cleanup after import (URL replace, WP Rocket, Elementor) | Built-in, automatic | Manual | Manual | Manual | Manual |
| WP-CLI | Built-in | Built-in | Built-in | Built-in | Built-in |
| Per-project PHP version | Yes | Yes | Yes | Yes | Yes |
| Per-project DB version | Yes | Yes | Yes | Yes, but changing it isn't live | Not documented |
| Automatic local HTTPS | Yes (mkcert) | Yes (mkcert) | Conditional, per-service | Likely yes¹ | Not documented |
| Local email capture | Not yet (Roadmap) | Yes (Mailpit, built in) | Via official plugin, not on by default | Likely yes¹ | Not documented |
| Distinctive feature | WordPress-specific import/cleanup workflow | `ddev get` add-on registry | Per-framework "recipes" | Live Links, Blueprints | Ships the matching core PHPUnit suite |

¹ Reported by Local's own community/help docs but not verified here against a single canonical
current page — treat as likely-but-unconfirmed rather than fact.

*(Researched against each project's official documentation; if something above looks stale, it
probably is — these tools move. Please open an issue if you spot a mistake.)*

### Docal vs. DDEV/Lando

DDEV and Lando are excellent general-purpose development environments. Docal is intentionally
narrower: it's designed around WordPress workflows and makes opinionated decisions (one CMS, one
web server story, mkcert HTTPS by default, WSL2 as the only target) so WordPress developers have
less configuration to maintain. If you regularly work across different stacks, DDEV or Lando's
generality is a real advantage Docal doesn't try to match.

### Who is Docal for?

- WordPress developers working on Windows + WSL2
- Freelancers managing multiple client websites
- WordPress agencies
- Developers frequently bringing production WordPress sites local
- Developers who prefer terminal workflows over GUI tools

### Who is Docal not for?

- You need a general-purpose environment for many different stacks
- You want a GUI-first workflow
- You don't use WSL2
- You require production container orchestration

## Documentation

- [Installation](docs/installation.md)
- [Command reference](docs/commands.md)
- [Importing an existing site](docs/importing-sites.md)
- [Configuration](docs/configuration.md)
- [Sharing with Cloudflare Tunnel](docs/tunnels.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Architecture](docs/architecture.md)
- [Security notes](docs/security.md)

## Roadmap

Nothing below exists yet — it's what's planned, in rough priority order.

**Planned**
- `docal pull` — sync a site from production over SSH (db, and optionally uploads), with
  automatic URL replacement and cleanup, the same way `import-wpress` works today
- Mailpit for local email capture, shared across all sites
- A unified `docal import <site> <file>` dispatching on file type, wrapping today's
  `import-wpress`/`import-db` instead of replacing them
- `docal open` / `docal admin` — open a site (or its wp-admin) in the Windows browser
- `docal db shell` / `docal db reset` (with strong confirmation)
- Snapshots (`docal snapshot <site> [label]`) for quick before/after database backups
- Shell completion (bash/zsh), especially for site names

**Under consideration**
- Project templates / scaffolding
- Hooks / extensibility points for custom post-create steps
- Additional Linux distro support beyond Debian/Ubuntu-family
- macOS investigation (no timeline — WSL2 is the only supported platform today)
- multisite support

No dates attached to any of this — it moves when it moves.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the project layout, conventions, and known environment
quirks worth knowing before changing the CLI or import flows.

## License

[MIT](LICENSE)
