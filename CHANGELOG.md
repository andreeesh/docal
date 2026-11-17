# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.0] - 2026-11-17

### Added

- Plugin-independent WordPress ZIP + SQL new-site importer, with archive/SQL
  validation, guarded database restore, local admin reset and serialized
  URL normalization.
- Read-only-designed SSH acquisition (`docal pull --ssh ... --path ...`)
  with remote WP-CLI/rsync prerequisites and isolated local restoration.
- Safe Start preview (`docal start <site> --safe`) using an isolated PHP
  network, loopback-only HTTPS, plugin-free temporary file copy and a
  **disposable MySQL clone** for browsing without changing the source
  local database.

### Security and reliability

- Source MySQL container identity, config, health and network endpoints are
  inspected before and throughout Safe Start. Safe Start does not start
  or reconcile the original database container.
- Guard against conflicting Docker container, volume and network names,
  unsafe staging paths and failed/partial restores.
- Tested SSH/local restore flows and the Safe Start disposable-DB workflow
  end to end under WSL2/Docker Engine, using authorized/synthetic fixtures
  as appropriate. CI covers the mocked preflight and failure paths.

### Documentation

- Updated README, import, Safe Start, security and command guides to match
  current implementation; added release acceptance checklist.

## [0.2.0]

### Added

- `docal doctor [--fix]` — diagnoses WSL2/Docker/mkcert/Traefik/ports/sites-dir setup, with a
  safe, idempotent `--fix` for the same operations the Docker preflight already performs.
- `docal version` — prints the installed version.
- `docal config`, `docal config get <key>`, `docal config set <key> <value>` — global
  configuration (`sites_dir`, `default_php`, `default_mysql`, `default_domain`, `admin_user`,
  `admin_email`, `default_upload_limit`), stored at `~/.docal/config`.
- `docal update` — fast-forward updates a git-checkout install in place, without touching sites.
- `docal uninstall` — removes the `docal` command and `~/.docal`, never touches user sites.
- `install.sh` — one-line installer (`curl -fsSL <url>/install.sh | bash`) that clones docal into
  `~/.docal/repo` and symlinks the CLI onto `PATH`. Idempotent; safe to re-run to update.
- `docal list --json` and PHP/MySQL columns in the default table output.
- `docal info` rewritten as a compact status dashboard (status, URL, admin, PHP/MySQL, path,
  containers, credentials).
- `docs/` — installation, commands, importing sites, configuration, tunnels, troubleshooting,
  architecture, and security guides, split out of `README.md`.
- `.github/ISSUE_TEMPLATE/` and pull request template.

### Changed

- Docal's own code/state now lives under `~/.docal` (config, Traefik proxy, certs), fully
  decoupled from wherever it was cloned. **User sites are unaffected** — they resolve via
  `DOCAL_SITES_DIR` env var → `sites_dir` config → automatic one-time adoption of an existing
  `sites/` folder inside an old-style clone → default `~/Sites`. No existing install loses data
  or has to move anything by hand.
- README rewritten around "bring a WordPress site to local" as the core workflow, with an honest
  comparison to DDEV/Lando/Local/wp-env and a Roadmap section for work not yet built.

### Roadmap (not implemented in this release — see README)

Mailpit, `docal open`/`admin`, a unified `docal import`, `docal db shell`/`reset`, snapshots,
shell completion, `docal pull` and other production-to-local sync work.
