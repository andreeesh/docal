# Safe preview of imported WordPress sites

**Status:** experimental (PR #6). A real Docker/WSL2 E2E test is required before release.

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
6. Launch WordPress only on the internal network, mounted read-only, with
   the existing local MySQL database accessible through the Unix socket.
7. Launch a dedicated Nginx HTTPS frontend on the internal network. Its
   only host port is 127.0.0.1:<port>. It does not join Docal's shared proxy
   network and has traefik.enable=false.
8. docal stop removes only the safe web/TLS containers, network and temporary
   file copy, then stops the site's standard containers.

## Important limitations

- **This is not a database snapshot.** WordPress can modify the site's
  existing LOCAL MySQL database during safe browsing. Use a disposable
  database for reproducible tests; normal site files are preserved.
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
- This mode does not alter other Docal sites or the shared Traefik proxy.

## WSL2 acceptance tests before merging

Run on a disposable local WordPress fixture, not a client site:

- Check Compose syntax, internal network and effective IPv6/DNS/IP egress
  with the PHP probe. A failed probe MUST stop before WordPress starts.
- Check that the normal WordPress container does not run; plugins, MU
  plugins and drop-ins are absent from the disposable copy.
- Check loopback-only HTTPS, frontend, /wp-login.php and authenticated admin.
- Check that temporary containers and network stop without deleting or
  restarting unrelated containers or MySQL volumes.
- Check a second safe start works after cleanup and a port conflict fails
  closed. Record actual DB mutations (if any) in the disposable local DB.
