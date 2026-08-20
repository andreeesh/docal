# Sharing a site publicly with Cloudflare Tunnel

`docal tunnel` exposes a running local site to the internet through a [Cloudflare
Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — useful
for sharing a site for client review, or testing webhooks that need a public URL. **Not needed for
normal local development.**

> ⚠️ **Anything exposed through a tunnel is public.** Docal's defaults (the `admin`/`admin`
> account, permissive local config) are meant for a machine only you can reach. Once a site is
> tunneled, treat it like any other internet-facing WordPress install — see
> [security.md](security.md).

## Requirements

- Your own domain managed in Cloudflare DNS.
- `cloudflared` installed and logged in:

```bash
sudo apt-get install cloudflared   # or see https://pkg.cloudflare.com/cloudflared
cloudflared login                  # one-time, opens a browser, saves ~/.cloudflared/cert.pem
export DOCAL_TUNNEL_DOMAIN=example.com   # a domain you control in Cloudflare DNS
```

## Usage

```bash
docal tunnel start  myblog               # creates the tunnel (first run) and starts it
docal tunnel status myblog
docal tunnel url    myblog
docal tunnel stop   myblog
docal tunnel delete myblog               # removes the tunnel and DNS record
```

The public URL is `https://<site>.<DOCAL_TUNNEL_DOMAIN>`. Each site gets its own named tunnel
(`docal-<site>`), so the public URL is stable across restarts. Credentials and config are stored
per-site under `<site-dir>/tunnel/`, self-contained rather than only in `~/.cloudflared`.

`docal info <site>` doesn't currently show tunnel status — check with `docal tunnel status
<site>` directly.
