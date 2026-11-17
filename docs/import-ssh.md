# Import a WordPress site over SSH

Docal can acquire files and a database from a remote WordPress installation
and feed them into its **existing, plugin-independent ZIP + SQL importer**.
It never needs a production database password or a commercial plugin.

## Requirements

On the local WSL2 machine:

- An SSH **host alias** configured in ~/.ssh/config with key-based access.
- A trusted SSH host key in known_hosts (interactive host-key enrollment is
  intentionally disabled by this command).
- ssh, rsync (with protected/secluded arguments support), Python 3, Docker.
- The remote WordPress location's absolute Unix path.

On the remote server:

- A readable WordPress installation with wp-content.
- A usable wp command (WP-CLI) and rsync on the remote SSH PATH.
- Database credentials in the remote site's wp-config.php that allow export.
- SSH access permitted to execute a command and send files.

Docal does **not** ask for or store the remote SSH password or database
credentials. Use a dedicated, least-privilege remote account when possible.
Ensure any WordPress bootstrap/custom WP-CLI configuration used by that host
does not perform unrelated writes.

## Usage

Example SSH config on the developer's machine (NOT a Docal configuration file):

    Host my-wp-production
        HostName wp.example.com
        User deploy
        IdentityFile ~/.ssh/id_ed25519

First verify access **without fetching files**:

    docal pull local-copy --ssh my-wp-production --path /var/www/html --dry-run

Then create and import into a **new local site**:

    docal pull local-copy --ssh my-wp-production --path /var/www/html

WordPress stays **stopped** after the import. Inspect it first using the
isolated preview with a disposable local database:

    docal start local-copy --safe --port 8443
    # https://local-copy.localhost:8443
    docal stop local-copy

Only use ordinary `docal start local-copy` after you deliberately decide
to run the restored plugins on Docal's shared local proxy network.

Never specify an already-existing local Docal site as the pull target.

**Docker Engine naming is global.** A separate `DOCAL_HOME` or
`DOCAL_SITES_DIR` does not isolate existing Docker containers or volumes.
Before the first actual transfer, Docal checks whether the selected slug
would reuse a container (`docal-<slug>-db/wp`), named volume, image
(`docal/wordpress-<slug>:latest`) or default network. If there is a
collision, choose a *different new slug* rather than deleting or renaming
the existing QA site's resources. The `--dry-run` mode intentionally
does not require Docker and checks SSH prerequisites only.

For repeated regression tests, use synthetic fixtures rather than
re-importing production data. Safe Start isolates restored PHP on a
dedicated Docker network with an outbound-egress preflight.

## Acquisition and import pipeline

1. Validate the new site name, SSH alias, remote path and local site path.
2. Probe the remote host using read-only checks and wp db prefix.
3. Copy wp-content with rsync as the **remote source**, excluding caches,
   common backup directories, .env files and SQL dumps. No --delete, no
   symlink following, no remote destination.
4. Stream wp db export - over SSH into a private local .sql file. The command
   uses single-transaction and nonlocking options where supported; it does
   not create a SQL dump file on the remote server.
5. Package transferred wp-content files as a temporary ZIP.
6. Pass ZIP and SQL to the existing docal import machinery: provision a fresh
   empty local database, import, replace WordPress URLs (including serialized
   values), create/reset the local admin and validate WordPress.
7. Remove temporary transferred data. The new WordPress site remains stopped
   until docal start.

If SSH or rsync fails before local site provisioning, the temporary files
are discarded and no site is created. If the local restoration fails later,
the new site can remain import-pending; diagnose it before using docal delete.
Existing sites are never overwritten.

## Limits and precautions

- This is a **read-only acquisition workflow by design**. It does not send
  file writes, WP updates, DB updates or cleanup commands to the remote
  server. Server-specific shell startup and WP-CLI hooks are outside Docal's
  control; confirm them before using production SSH credentials.
- It copies **wp-content**, not the remote WordPress core. Docal provides
  WordPress core locally. Check WordPress and PHP version compatibility.
- Snapshot consistency is best-effort: rsync files and the subsequent SQL
  export are not an atomic snapshot. Busy sites with concurrent uploads or
  writes may need a hosting backup/snapshot instead.
- Symlinks are intentionally not followed or preserved. A WordPress site
  depending on symlinked plugins/themes is not fully supported in this mode.
- MySQL single-transaction consistency applies to transactional engines such
  as InnoDB, not necessarily MyISAM.
- The export is capped at 10 GiB uncompressed; collected files at 20 GiB.
  Archives are restricted by the shared ZIP importer as well.
- Imported content may contain sensitive customer information, secrets or
  plugins that transmit data. The staging directory is private and temporary,
  but the resulting local installation contains a full DB/files copy.
  Use company/client authorization, protect the workstation and avoid
  unnecessary production data in tests.
- Restored WordPress plugins can make outbound requests with normal
  `docal start`. Docal's WordPress HTTP API blocking does not stop raw
  network calls. Inspect first with `--safe` (plugins excluded, dedicated
  internal network, disposable database) and review plugin integrations
  before opting into normal startup.
- SSH aliases and paths are explicit to minimize complexity. FTP, SFTP-only
  access, cloud hosting APIs, bidirectional sync and remote file modification
  are intentionally out of scope.

## Diagnosing remaining production references after import

An assertion that *every* origin-domain reference must disappear is too broad.
WordPress GUIDs, historical diagnostic logs, intentional external links and
hard-coded theme/plugin file URLs have different semantics.

For a disposable, isolated local QA copy:

1. Locate the origin of any frontend href: post content, postmeta, menu,
   Elementor data, widget, theme file, or generated asset. Report only the
   table/column/row ID or local file path, not private content or credentials.
2. Search the local database by *bare hostname*, not just an https:// URL.
   WP-CLI supports read-only `wp db search` with `--all-tables-with-prefix`.
   Keep the full matches private; they can contain customer data.
3. Classify any matches in GUID columns and in `elementor_log` separately.
   Elementor's serialized historical log may be skipped when its PHP classes
   are unavailable under --skip-plugins; that does not imply broken pages.
4. Fix confirmed internal links using serialization-aware WP-CLI operations
   on a disposable local DB, with specific regression tests. Never apply
   raw SQL REPLACE() to arbitrary PHP serialized objects. Do not activate
   imported plugins just to make object classes available.
5. Repeat isolated frontend/login checks to prove links stay local and no
   redirect sends users to the original site.

Intentional external links, historical GUIDs and diagnostic logs should
not be blindly rewritten. Document any remaining occurrences and their
nonfunctional classification. Preserve the original imported QA evidence.

`elementor_log` stores historical Elementor diagnostics rather than active
page content. Its serialized logger objects can produce WP-CLI
"uninitialized class" warnings when plugins are skipped. Preserve those log
entries; validate active post content and local text assets independently.

## Validation status

The SSH adapter has mocked SSH/rsync regressions in CI. Its read-only
acquisition path was exercised against an actual WordPress installation,
followed by a local Docker/MySQL restore and isolated frontend/login tests.
A successful test does **not** mean arbitrary remote shell hooks are proven
side-effect-free, or that independently changing production files and SQL
form an atomic snapshot. Use authorized remote access and preserve sensitive
data carefully.
