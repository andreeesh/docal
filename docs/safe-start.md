# Safe preview of imported WordPress sites

**Status:** PR #6 has been merged and passed real Docker/WSL2 E2E. The disposable-MySQL extension in PR #7 is experimental until its own E2E passes.

Run:

    docal start mysite --safe --port 8443

Open https://mysite.localhost:8443, then remove the preview with:

    docal stop mysite

Normal start still uses Docal's shared Traefik network. Safe preview is an
opt-in isolated browser-facing inspection mode and does not launch the site's
normal WordPress container.

## Behavior

1. Refuse an incomplete import, a running normal WordPress container or a
   colliding Docker container/network name.
2. Create a temporary copy of the site's WordPress files using rsync,
   omitting plugins, MU-plugins, common backup directories and PHP drop-ins.
   The original local files are not modified.
3. Change only the copied local wp-config.php to use the preview HTTPS port,
   block WordPress external HTTP and disable WP-Cron, auto-updates and edits.
4. Disable PHP sendmail with /bin/false, and file URL wrappers.
5. Create a new Docker bridge with internal=true and IPv6 disabled, with no
   existing endpoints. Probe real IPv4, IPv6 and DNS access from a temporary
   PHP process on the same network BEFORE starting WordPress.
6. Launch a **new temporary MySQL** using two private named volumes (data
   and socket), only on the internal Docker network. Start the existing
   LOCAL source DB if needed, then stream its data with mysqldump
   (--single-transaction, --quick, --no-tablespaces) directly into the
   temporary DB over a local pipe. No database export is saved to disk.
   Compare source and clone table counts before launching WordPress.
7. Launch WordPress only on the internal network, mounted read-only. It
   connects solely to the disposable MySQL Unix socket. It does not mount
   the source site's database socket or join its normal Docker networks.
8. Launch a dedicated Nginx HTTPS frontend, joined to the internal network
   and a second dedicated **no-masquerade bridge**. The latter permits Docker
   to publish only 127.0.0.1:<port>, which did not work with an internal-only
   proxy on Docker Engine 29.6.1. It never joins shared Traefik.
9. docal stop removes only safe web/TLS/MySQL containers, private MySQL
   volumes, both dedicated networks and the disposable file copy. The
   original site's MySQL volumes and WordPress files are preserved.

## Important limitations

- **The preview database is discarded on stop.** Site PHP can modify only
  the disposable MySQL clone, not the original local site's MySQL socket.
  The source DB is accessed by local mysqldump during cloning. The dump is
  transactionally consistent for InnoDB tables, but not necessarily for
  nontransactional engines. This is not a replacement for durable backups.
- Plugins and MU-plugins are not loaded. Themes depending on them may show
  missing functionality, and theme PHP itself is not disabled.
- The port differs from normal local URLs. Hardcoded unported URLs inside
  content may leave the preview. WordPress-generated URLs use the copied
  configuration's port, but external links are not globally rewritten.
- A local mkcert certificate is required. Trust in the operating system's
  CA store is a separate issue; safe preview does not install a CA.
- The temporary WordPress copy requires free local disk space and contains
  client data and local DB credentials. Keep the workstation and staging
  directory protected. Use docal stop to remove the copy.
- The isolated network and preflight checks reduce outbound exposure but
  **must be validated on real Docker Engine**. Mocked tests are not proof
  of network isolation. Do not use on sensitive client imports until E2E
  verification has passed.
- Starting a preview may start the original site's LOCAL MySQL container
  solely to read a dump; it does not launch the original site's PHP. The
  normal source database is not connected to the preview network.
- A full logical clone can consume disk space, take time and temporarily
  increase source MySQL load. Use only for authorized local data.
- If the cleanup fails, the private preview runtime is retained for
  inspection rather than silently removing its recovery information.
- This mode does not alter other Docal sites or the shared Traefik proxy.

## WSL2 acceptance tests before merging

Run on a disposable local WordPress fixture, not a client site:

- Check Compose syntax, internal network and effective IPv6/DNS/IP egress
  with the PHP probe. A failed probe MUST stop before WordPress starts.
- Check that the normal WordPress container does not run; plugins, MU
  plugins and drop-ins are absent from the disposable copy.
- Check loopback-only HTTPS, frontend, /wp-login.php and authenticated admin.
- Check the disposable MySQL has the same table count and representative
  data as the local source. Modify a row through preview PHP and prove
  the original DB value remains unchanged.
- Check that temporary containers, both safe networks and private MySQL
  data/socket volumes are removed without deleting unrelated resources
  or the site's original database volumes.
- Check a second safe start works after cleanup; a port conflict, bad
  table count, source dump failure or missing MySQL image must fail closed.
  Ensure rollback preserves the original local database and all other
  Docker resources.
