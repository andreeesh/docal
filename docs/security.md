# Security notes

Docal is intended for **local development only**, not production hosting.

- New WordPress sites receive a randomly generated administrator password, displayed during initial creation. The administrator username defaults to `admin` and is configurable.
- Existing WordPress administrator credentials are not reset when a site is reconfigured.
- After a `.wpress` import, Docal attempts to set a new random password for the local administrator and reports failure if this cannot be done. The import workflow has not yet been validated with a disposable end-to-end backup.
- Database credentials are generated randomly and stored in plaintext in `<site-dir>/.env`.
- Generated site configuration may contain the initial administrator password. Protect site files and avoid sharing them.
- Traefik binds ports 80, 443 and 8080 to `127.0.0.1` by default. Its dashboard has no authentication, even though it is loopback-only.
- HTTPS uses a local mkcert certificate authority; certificates are trusted only where that CA has been installed.

Local-only bindings do **not** make a site safe to share publicly. A Cloudflare Tunnel or other forwarding mechanism can expose WordPress to external users. Before sharing a site, review its users, passwords, plugins, sensitive data and tunnel access controls. Never expose a production backup containing real customer data without appropriate safeguards.

## Safe preview for imported sites

The opt-in `docal start mysite --safe` uses an isolated Docker network,
a local-only HTTPS proxy and a temporary WordPress copy without plugins,
MU-plugins or common drop-ins. Its preflight checks block IPv4, IPv6 and
external DNS access before site PHP is served. Original MySQL must already
be running and healthy: Safe Start reads it with Docker inspections and
`docker exec`, never by starting or reconnecting the container.

The database is cloned using a local SQL pipe into **disposable MySQL data
and socket volumes**. Browsing the preview can mutate the temporary clone
but cannot write through the original local database socket. A validated
synthetic WSL2 E2E confirmed this isolation. Treat local restored content as
sensitive regardless: the local DB copy contains real data if a real site
was imported, and theme PHP can still execute. Safe Start is not a substitute
for tested backups, OS hardening or sandboxing untrusted code. See
[safe preview details](safe-start.md).

## Reporting a vulnerability

Docal has no automated update-notification mechanism or telemetry. For security-sensitive findings, contact the maintainer privately rather than publishing exploit details in a public issue.
