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

## User-facing workflow (implemented, pending live E2E validation)

```bash
docal import mysite --zip ./site.zip --db ./database.sql.gz
```

The command creates `mysite` when absent. It refuses to overwrite an existing
site. It leaves the imported site **stopped** until an explicit `docal start mysite`,
so WordPress code and plugins are not served while the database is being restored.
Updating existing sites requires a separately designed explicit opt-in.

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
The importer is available on this development branch, but a full restoration
with real MySQL and Docker has **not yet passed an end-to-end test**. Do not
merge this PR or use it with an existing client site until that validation passes.


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

The new import command now invokes the empty-site provisioner and guarded
SQL loader without calling the standard `docal create` initialization.
The existing interactive `docal import-db` command remains unchanged.
The SQL loader tests use mocked Docker calls; real MySQL restoration is
still pending.

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

This preparation mode remains **internal**, used by the new `docal import`
CLI. Do not point it at client sites or remove the pending marker manually.
The import orchestrator stages ZIP/SQL, normalizes URLs and local admin access,
and removes the pending marker **only after successful checks**.
Failure cleanup must target exclusively resources created by the new
import operation, never existing sites or shared proxy resources.

The tests use an offline minimal WordPress Git fixture and mocked Docker
responses. An actual MySQL container and real restored WordPress site have
not yet been tested.

## Implemented: end-to-end orchestration (awaiting real Docker validation)

The CLI entrypoint now accepts:

```bash
docal import mysite --zip ./wordpress-site.zip --db ./database.sql.gz
docal start mysite
```

The first command rejects an existing site; validates and stages both input
files before provisioning; creates a dedicated empty MySQL database; copies
WordPress files **without replacing the generated local wp-config.php**;
imports SQL using the scoped database user; detects a unique root WordPress
table prefix; and invokes WP-CLI in one-off containers without starting the
web service. It temporarily quarantines mu-plugins and database/cache
drop-ins during bootstrap, uses WordPress-aware serialized URL replacement,
updates local home/siteurl, and generates a fresh administrator password.
It verifies WordPress installation and the saved URLs before clearing the
import-pending marker. Existing sites are never valid import destinations.

The import command deliberately leaves the WordPress web service stopped.
A separate `docal start mysite` is necessary to run the restored PHP and
plugins. The generated local configuration disables WP-Cron and WordPress's
HTTP API access to external services, but this **does not** prohibit all
outbound activity (e.g. raw PHP sockets/cURL or direct plugin SMTP).
Only start backups that you trust and consider additional container egress
controls for sensitive client data.

If failure occurs after provisioning, the new site may contain a partial
database and retains its import-pending marker; the operator must diagnose
and explicitly delete/recreate the disposable site before retrying. The
source backups remain unchanged. The new workflow has unit and mocked-Docker
tests, but **no real end-to-end Docker/MySQL restoration has been confirmed**.
