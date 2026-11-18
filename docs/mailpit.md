# Local mail capture with Mailpit

**Status:** proposed in the Mailpit feature PR; requires Docker/WSL2 E2E
validation before merging. No existing site or its Docker containers are
modified by opening this pull request.

Mailpit is a shared **development-only SMTP sink**, not an outgoing mail
provider. New Docal WordPress images use `msmtp-mta` to send standard
`mail()` / `wp_mail()` messages to the local Mailpit container. Mailpit
stores captured messages for inspection, **not delivery to recipients**.

## Start, inspect and stop

```bash
docal mail start
docal mail status
docal mail url
docal mail stop
```

- Web inbox: **http://localhost:8025** (host `127.0.0.1` only).
- SMTP address inside Docker: **`docal-mailpit:1025`** on the shared
  `docal-proxy` network. Port `1025` is **not published** to the host.
- `docal mail start` brings up Traefik only when it is absent or stopped, then
  waits up to 15 seconds for Mailpit's container, network, loopback HTTP API
  and Docker-internal SMTP connection to pass operational checks. It returns
  an error with a diagnostic if any check fails. `docal mail status` runs the
  same checks without waiting; a running container alone is not considered
  ready.
- `docal mail stop` stops **only Mailpit**, not Traefik, MySQL or sites.
- Starting the regular Docal proxy/site also attempts to start Mailpit;
  a conflict on port `8025` should not take down Traefik.

The inbox is shared by all normal local WordPress sites using Docal's
SMTP transport. Mailpit keeps at most **500** messages, automatically
removes messages older than **7 days**, and has **no mounted persistent
volume**. Captured messages can disappear when Mailpit is recreated;
do not rely on it for durable records or backups.

## New sites

New sites created with the updated `templates/Dockerfile.tpl` have
`msmtp-mta` installed. PHP's default sendmail path points to
`/usr/sbin/sendmail -t -i`, backed by `msmtp` configured for
`docal-mailpit:1025` with no credentials and no TLS (Docker-local only).
Normal `wp_mail()` and other PHP `mail()` calls should be captured by
Mailpit once the WordPress image has been built and Mailpit is running.

Smoke test **only with a synthetic local WordPress site**:

```bash
docal mail start
docal create mail-qa
docal wp mail-qa eval 'var_dump( wp_mail("qa@example.test", "Mailpit smoke test", "Local capture only") );'
# Visit http://localhost:8025 and verify the message
```

Use `.test` addresses and synthetic content. Do not generate real client
notification emails just to test capture.

## Existing sites and SMTP plugins

Existing sites are **never modified automatically**. To capture ordinary
WordPress `wp_mail()` messages on an existing site, explicitly install a
Docal-managed local MU-plugin:

```bash
docal mail enable mysite
# Later, when local email testing is finished:
docal mail disable mysite
```

This adds only `wp-content/mu-plugins/docal-mailpit-capture.php` to
the named local site, routing standard WordPress PHPMailer traffic to
`docal-mailpit:1025` with authentication, TLS and STARTTLS disabled.
It does **not** rewrite `wp-config.php`, replace the site's Dockerfile,
rebuild any image, start WordPress or alter its database. Enabling twice
is idempotent; if a file with this name already exists but differs, the
command refuses to overwrite or delete it. Symlinked WordPress/MU-plugin
paths and import-pending sites are rejected.

This is a WordPress-level hook, not a replacement for the PHP sendmail
binary. Older WordPress images may still lack `msmtp-mta` and therefore
standalone PHP `mail()` calls outside WordPress may not work through
Mailpit. New sites have the PHP-level transport by default.

SMTP plugins can bypass `wp_mail()` (for example with a `pre_wp_mail`
short circuit), and custom PHP code can connect directly to external SMTP
servers. Mailpit **cannot guarantee interception of every outgoing
request** from arbitrary restored WordPress plugins. Review and disable
real SMTP credentials before normal WordPress startup.

## Safe Start is intentionally different

`docal start <site> --safe` remains isolated on its own internal Docker
network, **does not join** `docal-proxy` and explicitly sets PHP's
`sendmail_path = /bin/false`. It does not send messages to Mailpit.
This preserves the no-egress behavior validated for imported content.
Use the normal local WordPress environment for mail testing **only after**
you have reviewed the restored site's plugins and SMTP configuration.

## Security and privacy

- The Mailpit UI is **unauthenticated** on loopback HTTP; never publish
  it to the LAN, internet, reverse proxy or a Cloudflare Tunnel.
- All local sites share one inbox. Emails can contain customer data,
  reset links, login tokens and addresses; avoid using real datasets.
- The SMTP container is reachable only from other services attached to
  the local Docker `docal-proxy` network. No real mail relay credentials
  or SMTP-forwarding configuration is provided.
- Opening message HTML may fetch remote tracking resources in a browser.
  Treat external links/images from imported messages as potentially
  unsafe; disable remote content where feasible.
- Mailpit is only for local development and is **not a security boundary**
  preventing hostile plugins from establishing direct network connections.

## Troubleshooting

- `docal mail status`: verify the container, `docal-proxy` attachment, exact
  loopback HTTP publication, API response and internal SMTP connectivity.
- `docker logs docal-mailpit`: inspect container startup errors.
- Port `8025` busy? Identify the conflicting process; do not change
  Traefik or delete unrelated containers to fix it.
- A `wp_mail()` test returned false? Verify the WordPress image has
  `msmtp-mta`, `/etc/msmtprc` and `sendmail_path` configured; then check
  DNS resolution of `docal-mailpit` from the normal WordPress container.
- `wp_mail()` returns true but the inbox is empty? Verify no SMTP plugin
  overrides `wp_mail()`/PHPMailer and that the test actually used PHP mail.
- For live WSL2 acceptance, also confirm Safe Start still blocks
  outbound IPv4/IPv6/DNS and leaves source MySQL untouched.

Mailpit reference: https://mailpit.axllent.org/docs/install/docker/
