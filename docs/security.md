# Security notes

Docal is built for **local development only**. It intentionally trades security for convenience,
the same way Lando/DDEV/Valet do — none of the choices below are safe defaults for anything
reachable from outside your own machine.

- Every site's WordPress admin account defaults to `admin` / `admin` (the username is
  configurable via `--admin-user` / `docal config set admin_user`; the password is not).
- Database passwords are randomly generated but stored in plaintext in `<site-dir>/.env`.
- The Traefik dashboard (`:8080`) has no authentication.
- TLS certificates are signed by your local mkcert CA, not a public CA — they're only trusted on
  machines where you've run `mkcert -install`.

None of this is a problem on your own machine behind your own firewall. It becomes a problem the
moment any of these ports are reachable from the internet — port forwarding, a cloud VM with a
public IP, or `docal tunnel` pointed at a site you haven't hardened. **`admin`/`admin` is never
acceptable outside local development, full stop** — if you need to share a site externally, use
[`docal tunnel`](tunnels.md) with a throwaway domain, change the admin password first, and treat
anything exposed through it as public.

## Reporting a vulnerability

Docal has no automated update-notification mechanism and no telemetry. If you find a security
issue in docal itself (not in WordPress or a plugin you've installed), open an issue on the
repository, or contact the maintainer directly if it's sensitive enough that a public issue isn't
appropriate.
