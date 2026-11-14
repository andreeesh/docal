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
