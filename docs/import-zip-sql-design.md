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
