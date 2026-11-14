# ZIP + SQL import: initial scope

Docal's primary, plugin-independent restore path accepts a ZIP archive and a
SQL dump. All operations target a **new, explicitly named** site by default;
existing sites must not be overwritten implicitly.

## Supported inputs

- WordPress installation ZIP containing `wp-admin/`, `wp-includes/`,
  `wp-content/` and optionally `wp-config.php`.
- `wp-content/`-only ZIP, with WordPress core supplied by Docal.
- SQL dump in `.sql`, `.sql.gz`, or gzip-compressed SQL format.

A full-site ZIP's `wp-config.php` is **never** installed over Docal's local
configuration. Original database credentials and production secrets must not
be carried into the local environment.

## User-facing workflow (proposed)

```bash
docal import mysite --zip ./site.zip --db ./database.sql.gz
```

The command creates `mysite` when absent. It refuses to overwrite an existing
site; updating an existing site requires a separately designed explicit opt-in.

## Implementation boundaries

1. Preflight and validate inputs (readability, archive structure, disk space).
2. Reject unsafe ZIP entries (absolute paths, `..` traversal, symlinks,
   unexpected extraction targets) before extraction.
3. Create a new Docal site and extract into a staging directory.
4. Import SQL into the dedicated database.
5. Normalize URLs, permissions, local admin credentials and permalinks using
   shared finalization logic.
6. Validate restored DB and files before reporting success.
7. On failure, preserve diagnostics and avoid touching pre-existing sites.

## Deliberately out of scope

- SSH acquisition (a later adapter to the same restore pipeline).
- Commercial migration plugin installation.
- Existing-site overwrite or bidirectional synchronization.
- FTP/SFTP and hosting-provider-specific APIs.

The existing `import-db` and `import-wpress` commands remain available.
This document is an implementation contract, **not** a claim that the proposed
`docal import` command is already implemented.


## Implemented: safe ZIP staging (not yet connected to Docal CLI)

A Python 3 helper validates archives without extracting them:

```bash
python3 scripts/validate-wordpress-zip.py ./site.zip
```

To unpack into a **new directory that does not yet exist**:

```bash
python3 scripts/validate-wordpress-zip.py ./site.zip --extract-to /tmp/docal-zip-staging
```

The extractor strips an optional single top-level wrapper directory and
supports full WordPress or `wp-content`-only archives. It preserves the
original ZIP, **omits the source `wp-config.php`**, and creates output files
with non-executable permissions. For `wp-content`-only archives, unrelated
root-level files are ignored.

Preflight rejects path traversal, absolute/Windows-style paths, backslashes,
duplicate or case-colliding entries, symlinks, special files, encryption,
partial WordPress core layouts, and file/directory collisions. It enforces
limits of 250,000 entries, 10 GiB per file, 20 GiB uncompressed overall and
a 1,000:1 compression ratio, and checks destination disk space. Extraction
removes only its newly created staging directory when an error occurs.

**Limitations:** this staging helper does not install WordPress, import SQL,
replace URLs, create containers, or modify an existing Docal site. A ZIP can
contain untrusted PHP that must not be executed without appropriate isolation.
The upcoming importer must integrate staging and cleanup carefully.


## Implemented: SQL staging and guarded fresh-database loader

SQL preparation supports plain `.sql` and gzip-compressed `.sql.gz` /
`.gz` dumps:

```bash
python3 scripts/prepare-sql-dump.py ./database.sql.gz --output /tmp/docal-private-stage/database.sql
```

The destination must not exist and should be inside a private staging
directory owned by the current user. The helper writes with mode 0600,
checks the complete gzip stream (including integrity/truncation), rejects
empty dumps and sources that are symbolic links, applies a 10 GiB
uncompressed-size limit and removes partial output on failure. It
does not execute or rewrite SQL.

`scripts/lib-import-sql.sh` provides the **internal** function
`docal_import_staged_sql_new_site`, intended to be sourced by the future
import orchestrator. It requires `SITE_DIR`, `DB_NAME`, `DB_USER` and
`DB_PASSWORD` populated from the new site's configuration, an absolute
staged `.sql` file, and a `.docal-import-pending` marker under that site.
Before making changes, it checks that the site's dedicated database
contains zero tables. It then imports with the **scoped site database user**
(not MySQL root), checks command exit status, and requires at least one
table before reporting success. A failed SQL import can leave a partially
populated **new** database; the orchestrator must handle cleanup.

**Integration blocker:** the current `docal create` workflow installs
WordPress and populates the database immediately. The future
`docal import` orchestrator must provision a new empty site database
without running initial WordPress installation, then stage ZIP and SQL
before invoking this loader. The loader is deliberately **not connected
to the CLI** and must never replace the existing interactive
`docal import-db` command. Its current tests use mocked Docker calls;
no real MySQL restoration has been validated yet.

SQL dumps are **trusted user input** for development migration, not
executable sandbox-safe data. MySQL permissions must remain limited
to the isolated site's database and no dump should be replayed into
another site's schema.


## Implemented: prepare an empty import site

`scripts/setup-wordpress.sh` now accepts an **internal** combination of
`--prepare-import --non-interactive`, with an explicit `SITE_NAME` (a
lowercase Docal slug). This path reuses normal site templates, core checkout,
local `wp-config.php` generation and credentials, but does **not** run
`wp-init`, start WordPress/PHP, register a TLS certificate or start Traefik.
It creates an import-pending marker and starts only the new MySQL service,
checking that the dedicated database is accessible and contains zero tables.

With `--skip-docker` it writes configuration and the import-pending marker
without starting MySQL; this supports isolated unit tests. It cannot be used
on a directory that already exists (including symlinks), and refuses
conflicting existing Docker container names or Compose volumes before
running Docker. Normal `docal create`, `docal start` and `docal rebuild`
are blocked for import-pending sites.

This remains **internal**, not a published command. Do not point it at
client sites or remove the pending marker manually. The future orchestrator
must stage and verify ZIP/SQL, run the import, finalize URLs and local admin
access, and remove the pending marker **only after successful checks**.
Failure cleanup must target exclusively resources created by the new
import operation, never existing sites or shared proxy resources.

The tests use an offline minimal WordPress Git fixture and mocked Docker
responses. An actual MySQL container and real restored WordPress site have
not yet been tested.
