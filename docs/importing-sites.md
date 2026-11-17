# Importing an existing site

Bringing a real WordPress site local — from a client handoff, a backup, or production — is one of
the main reasons to reach for Docal instead of a generic Docker setup.

## New site from ZIP + SQL (without a migration plugin)

If you have a WordPress ZIP and SQL dump, create a **new local site**:

```bash
docal import myshop --zip ./wordpress.zip --db ./database.sql.gz
docal start myshop --safe --port 8443
# Review at https://myshop.localhost:8443
docal stop myshop
```

This path validates the inputs, refuses existing site names, restores the
database into an isolated local MySQL service, normalizes URLs and admin
credentials, and leaves WordPress stopped. The original PHP plugins are
not served during import. Inspect the result using Safe Start before
intentionally running the normal site; Safe Start uses a disposable DB
clone so browsing does not modify the source local database.

See [ZIP + SQL implementation](import-zip-sql-design.md) and
[Safe preview](safe-start.md).

## Pull a site over SSH

```bash
docal pull myshop --ssh production-alias --path /var/www/html --dry-run
docal pull myshop --ssh production-alias --path /var/www/html
docal start myshop --safe --port 8443
```

The SSH alias and remote path are explicit. Remote WP-CLI and rsync
collect `wp-content` and database SQL using a remote-read-only design.
Always use an approved remote account; unrelated remote startup hooks
are outside Docal's control. A local site must not already exist under
that name. See [SSH import](import-ssh.md).

## During `docal create` (interactive only)

When you run `docal create` interactively, it looks for import sources in three optional folders
next to your docal install (`~/.docal/repo/{wpress,dbs,files}` for a managed install, or
`{wpress,dbs,files}/` next to a manual clone) and offers to use them. Pick **one** method — they
don't combine:

| Method | Folder | Files | What happens |
|---|---|---|---|
| All-in-One WP Migration | `wpress/` | `.wpress` | Restore via AI1WM, then finalize |
| Database + uploads | `dbs/` + `files/` | `.sql` / `.sql.gz`, uploads `.zip` | Import dump and/or unzip media into `wp-content/uploads/` |

If both methods have files available, `create` asks which to use. Within database/uploads you can
skip DB, skip files, or import both independently.

Uploads zips are handled intelligently: if the archive contains an `uploads/` folder (at the root,
or inside a single wrapper directory), only that folder's contents are copied; otherwise loose
files go straight into `wp-content/uploads/`.

**Local plugins:** if a `plugins/` folder exists next to your docal install, `create` lists its
`.zip` files and asks which to install — handy for premium/private plugins you don't want
committed anywhere.

## Into an existing site: `docal import-wpress <site> [file]`

Restores a `.wpress` backup into a site you've **already created**, without recreating it —
useful for refreshing content. Picks from `wpress/*.wpress` interactively if no file is given.

```bash
docal import-wpress myshop                # picks from wpress/*.wpress
docal import-wpress myshop backup.wpress
```

```text
✓ Backup restored
✓ Production URL detected
✓ URLs replaced
✓ WordPress cleaned for local development
✓ Local administrator ready

https://myshop.localhost
```

⚠️ This replaces the site's database, uploads, and installed plugins/themes with whatever is in
the backup. It asks for confirmation first.

## All-in-One WP Migration compatibility

Restoring a `.wpress` archive requires a functional `wp ai1wm restore` command.
Depending on the installed plugin version, this may require a compatible
Unlimited Extension. Docal does not bundle, download, or upgrade that commercial
extension automatically.

Before importing, verify the versions of both the migration plugin and any
locally installed extension. A reported incompatibility (for example, extension
2.84 when the migration plugin requires 2.89 or newer) must be resolved using
a legitimate compatible extension or a supported alternative restore mechanism.

Docal checks for a database replacement after running the restore command.
A fresh WordPress site returning HTTP 200 does **not** prove that the backup
was restored. If the restore fails, Docal reports an error and does not run
post-import cleanup.

## What "finalize" does automatically

Both paths above run the same shared cleanup after a database is imported (`lib-import-wpress.sh`
→ `finalize_imported_site`), so `create --aiowp` and `import-wpress` never drift apart:

- Deactivates WP Rocket and clears its cache (its Cloudflare integration otherwise crashes
  WP-CLI, and every page load, right after a restore).
- Updates `siteurl` and `home` to `https://<site>.<domain>`.
- Runs `wp search-replace` from the old URL (both `https://` and `http://`) to the new one,
  across all serialized data, skipping `guid`.
- Rewrites absolute URLs baked into CSS files under `wp-content/uploads/`.
- Flushes Elementor's CSS cache, if Elementor is present.
- Fixes permalinks and REST API rewrites.
- Ensures the local admin account exists with the configured username (`admin` by default, or
  whatever `--admin-user`/`admin_user` was set to when the site was created) and a newly generated random password (shown locally after import).
- Flushes the object cache.

Files-only imports (uploads with no database) skip the URL-replace step and just fix ownership and
rewrite rules.

## Plain database or SQL dump

Already have a `.sql`/`.sql.gz` dump instead of a `.wpress` backup?

```bash
docal import-db myblog myblog-backup.sql.gz
docal replace-url myblog https://myblog.com https://myblog.localhost
```

`import-db` only replaces the database; run `replace-url` afterward if the dump came from a
different domain (production dumps almost always do).

## Known gotchas

**Frontend has no styles after an import** — the old domain is still embedded in Elementor data
or a CSS file the automatic replace missed:

```bash
docal wp <site> search-replace "https://old-domain.com" "https://<site>.localhost" --recurse-objects --skip-columns=guid
docal exec <site> chown -R www-data:www-data /var/www/html/wp-content/uploads
docal wp <site> elementor flush_css
```

**WP Rocket crashes WP-CLI after a restore** — add `--skip-plugins=wp-rocket` to any `wp` command
you run manually right after an import; `docal create` and `docal import-wpress` already do this
for the steps they run automatically.

**Large `.wpress` files hit the upload limit** — recreate with a higher limit, or copy the file
directly into the container:

```bash
docal create <site> --upload=12G --aiowp
# or, for a very large file:
# copy it to <site-dir>/wordpress/wp-content/ai1wm-backups/ directly
```

## Roadmap

The current `docal import` requires explicit `--zip` and `--db` inputs,
and `docal pull` uses explicit SSH alias and remote path arguments.
Automatic source-format detection, new import adapters and incremental
remote synchronization remain future work. See the [README roadmap](../README.md#roadmap).
