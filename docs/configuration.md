# Configuration

Docal keeps its own code and state under `~/.docal`, separate from your WordPress sites, which
can live anywhere.

```
~/.docal/
├── repo/            # docal's own code (what `docal update` pulls)
├── proxy/           # shared Traefik proxy + certs/ (TLS certificates)
└── config           # global settings (this page)
```

## Where your sites live

Resolved in this order, the first time any `docal` command runs, and then remembered:

1. `DOCAL_SITES_DIR` environment variable, if set — always wins, never written to config.
2. `sites_dir` in `~/.docal/config`, if set.
3. **First run only:** if you have an existing `sites/` folder next to an old-style docal clone
   (from before `~/.docal` existed), it's adopted automatically and saved as `sites_dir` — nothing
   is moved.
4. Otherwise, defaults to `~/Sites`, saved as `sites_dir`.

Change it any time with `docal config set sites_dir <path>` — existing sites already created
elsewhere aren't moved by that command, so only change it if you're intentionally starting fresh
or have already moved the files yourself.

```bash
export DOCAL_SITES_DIR="$HOME/projects"   # one-off override, e.g. in a script or CI
docal config set sites_dir ~/projects     # persistent
```

## `docal config`

```bash
docal config                       # print all configured keys
docal config get <key>
docal config set <key> <value>
```

Known keys:

| Key | Used for |
|---|---|
| `sites_dir` | Where new sites are created and existing ones are looked up |
| `default_php` | Default `--php` for `docal create` when not given on the command line |
| `default_mysql` | Default `--mysql` for `docal create` |
| `default_domain` | Default `--domain` for `docal create` |
| `admin_user` | Default `--admin-user` for `docal create` |
| `admin_email` | Default `--email` for `docal create` |
| `default_upload_limit` | Default `--upload` for `docal create` |

Command-line flags on `docal create` always win over config; config always wins over docal's own
built-in defaults (`latest` PHP, MySQL `8.4`, `localhost`, `admin@docal.com`, `admin`, `2G`).

```bash
docal config set default_php 8.3
docal config set default_domain test
docal create client            # picks up default_php=8.3 and default_domain=test automatically
docal create other --php=8.1   # --php on the command line still wins
```

Config values aren't secrets — don't put anything sensitive in them. Per-site database
credentials live in each site's own `.env`, never in the global config.
