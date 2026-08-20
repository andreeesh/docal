# Importing an existing site

Bringing a real WordPress site local — from a client handoff, a backup, or production — is one of
the main reasons to reach for Docal instead of a generic Docker setup.

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
  whatever `--admin-user`/`admin_user` was set to when the site was created) and password `admin`.
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

A unified `docal import <site> <file>` that dispatches on file extension (`.wpress`, `.sql[.gz]`,
`.zip`) instead of three separate entry points, and eventually `docal pull` for a
production-to-local sync over SSH, are planned — see the README's Roadmap section. Neither exists
yet.
