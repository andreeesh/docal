# ZIP + SQL import: implementation and safety boundaries

Docal provides a plugin-independent way to restore a **new** WordPress site
from a ZIP of WordPress files and a matching SQL database dump. The importer
is merged in `main` and has passed real Docker/MySQL restoration testing.

## Usage

```bash
docal import mysite --zip ./site.zip --db ./database.sql.gz
docal start mysite --safe --port 8443
# Inspect https://mysite.localhost:8443
docal stop mysite
```

After review, deliberately opt into `docal start mysite` **only if you want**
the restored plugins/themes running with the normal local Docal proxy.
Normal start is not equivalent to the network-isolated Safe Start mode.

An existing Docal site is never a valid target for this import path. A
failed new-site import may retain `.docal-import-pending` and partial data;
the CLI refuses to start an import-pending site. Diagnose or explicitly
delete the incomplete new site before retrying; it must not overwrite an
existing installation.

## Accepted inputs

- Full WordPress ZIP (`wp-admin/`, `wp-includes/`, `wp-content/`) optionally
  including a production `wp-config.php` (always excluded from restore).
- `wp-content/` ZIP, with the WordPress core supplied by Docal.
- Plain `.sql` and gzip-compressed `.sql.gz`/`.gz` database dumps.

ZIP and SQL are **trusted operator-supplied migration inputs**, not safe
sandbox data. A WordPress ZIP may contain PHP, and SQL can contain stored
credentials and confidential customer records. Use files you are authorized
to handle. Keep local staging and restored client data private.

## Validation, provisioning and staging

1. Validate the target name and ensure it is unused, including symlinked
   directories and globally named Docker containers/volumes/networks.
2. Validate ZIP structure and SQL compression/data integrity before creating
   a managed WordPress site. Files are staged privately.
3. Prepare a **new** Docal WordPress installation and its isolated MySQL
   database, without starting the normal WordPress service or shared proxy.
4. Extract the approved files, preserving Docal's locally generated
   `wp-config.php` and database credentials. Import SQL using the new
   database's scoped application user.
5. Detect the WordPress table prefix; normalize local URLs using WP-CLI
   serialization-aware operations with plugins/MU-plugins and common
   drop-ins quarantined. Restore local admin access and validate the DB.
6. Clear the import-pending marker only after successful validation.
   Leave WordPress stopped until an explicit start.

The ZIP validation helper is available independently:

```bash
python3 scripts/validate-wordpress-zip.py ./site.zip
python3 scripts/validate-wordpress-zip.py ./site.zip --extract-to /tmp/docal-zip-staging
```

It rejects traversal/absolute paths, symlinks, special files, encryption,
duplicate or case-colliding entries, file/directory collisions and partial
WordPress core layouts. Limits include 250,000 entries, 10 GiB per file,
20 GiB uncompressed overall and a 1,000:1 compression ratio. Extraction
must target a newly created staging path; source ZIP is preserved.

SQL can be prepared independently:

```bash
python3 scripts/prepare-sql-dump.py ./database.sql.gz --output /tmp/docal-private-stage/database.sql
```

The SQL staging helper refuses symlinked input, empty/truncated gzip streams
and more than 10 GiB of uncompressed data; writes mode 0600 and removes
its partial output on failure. The target output file must not exist.

Internal `docal_import_staged_sql_new_site` in `scripts/lib-import-sql.sh`
checks the import-pending marker and zero-table destination, then loads SQL
under the site's scoped DB account (never root). Its failure can leave
partial data **only** in the newly created import site.

## Safe Start after import

`docal start mysite --safe` does not run restored plugins or MU-plugins.
It creates a disposable WordPress file copy and MySQL clone, isolated on
private Docker networks and exposed over loopback-only HTTPS. It verifies
IPv4/IPv6/DNS egress before serving PHP and leaves the source local DB
untouched. The source site's MySQL container must already be running and
healthy; Safe Start will not start or reconcile it. See
[Safe preview](safe-start.md) for details and limitations.

## SSH acquisition

`docal pull --ssh ALIAS --path REMOTE_PATH` is an **existing** separate
read-only remote acquisition adapter which then uses the ZIP + SQL
importer. It copies `wp-content` and streams WP-CLI SQL from a remote
server without writing a backup file on the remote host. Remote server
hooks and concurrent writes are not atomic or controlled by Docal.
See [SSH import](import-ssh.md).

## Evidence and remaining limits

- ZIP + SQL and SSH-based local restores were tested with Docker/MySQL;
  synthetic fixtures cover the important failure/safety paths in CI.
- Safe Start (including the disposable MySQL clone and source-container
  invariants) passed WSL2 E2E with synthetic data. Revalidate when the
  Docker networking topology or cloning implementation changes.
- ZIP file collection and a separate SQL export are not an atomic snapshot;
  busy WordPress installations can change during acquisition.
- MySQL single-transaction consistency primarily applies to InnoDB;
  nontransactional engines may not be point-in-time consistent.
- The importer does not overwrite an existing site, run bidirectional sync,
  provide offsite backups or restore arbitrary remote WordPress bootstrap
  behavior. Specialized migration plugins remain a separate import path.
