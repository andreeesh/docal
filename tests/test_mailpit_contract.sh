#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
source_compose = (root / "proxy/docker-compose.yml").read_text()
generator = (root / "scripts/start-proxy.sh").read_text()
dockerfile = (root / "templates/Dockerfile.tpl").read_text()
cli = (root / "scripts/docal").read_text()
safe_start = (root / "scripts/safe-start.py").read_text()
site_mail = (root / "scripts/mailpit-site.py").read_text()

# Docal generates ~/.docal/proxy/docker-compose.yml from start-proxy.sh.
# Guard against edits that accidentally desynchronize the two variants.
match = re.search(r"cat > .*? <<'EOF'\n(.*?)\nEOF", generator, re.S)
assert match, "Unable to locate generated proxy Compose configuration"
assert match.group(1) + "\n" == source_compose, "Proxy Compose template and generator differ"

mailpit = re.search(r"(?ms)^  mailpit:\n((?:^    .*\n|^\n)+)", source_compose)
assert mailpit, "Missing shared Mailpit service"
mail = mailpit.group(1)
assert "axllent/mailpit:v1.31.6" in mail
assert "container_name: docal-mailpit" in mail
assert '"127.0.0.1:8025:8025"' in mail
assert "traefik.enable=false" in mail
assert "docal-proxy" in mail
assert "MP_MAX_MESSAGES" in mail
assert "MP_MAX_AGE" in mail
assert not re.search(r"(?m)^\s*-\s*[\"']?(?:0\.0\.0\.0:)?1025:1025", mail), (
    "SMTP must not be published on the host"
)
assert "MP_SMTP_FORWARD_CONFIG" not in mail
assert "MP_SMTP_FORWARD" not in mail
assert "MP_UI_AUTH_FILE" not in mail  # This is loopback-only, unauthenticated.

# Default PHP mail() must go to Mailpit. Safe Start still overrides mail()
# to /bin/false while running on its private network.
assert "msmtp-mta" in dockerfile
assert "host docal-mailpit" in dockerfile
assert "port 1025" in dockerfile
assert "auth off" in dockerfile and "tls off" in dockerfile
assert "/usr/sbin/sendmail -t -i" in dockerfile
assert 'sendmail_path = /bin/false' in safe_start
assert '["docal-safe-internal"]' in safe_start

assert "cmd_mail()" in cli
for command in ("start)", "stop)", "status)", "url)"):
    assert command in cli[cli.index("cmd_mail()"):cli.index("# ── install")], command
assert 'mailpit-site.py' in cli
assert 'require_site "$1"' in cli[cli.index("cmd_mail()"):cli.index("# ── install")]
assert "phpmailer_init" in site_mail
assert "PHP_INT_MAX" in site_mail
assert "docal-mailpit" in site_mail
assert "SMTPAutoTLS = false" in site_mail
assert 'docker compose stop mailpit' in cli
assert 'cmd_mail "$@"' in cli
assert "docker compose up -d traefik" in generator
assert "if docker compose up -d mailpit" in generator
assert "mailpit-health.py" in cli

print("Mailpit proxy, PHP sendmail, safe-preview and CLI contracts passed")
PY

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/sites"
actual="$(HOME="$tmp" DOCAL_SITES_DIR="$tmp/sites" "$ROOT/scripts/docal" mail url)"
[[ "$actual" == "http://localhost:8025" ]] || {
  echo "Unexpected docal mail url: $actual" >&2
  exit 1
}
echo "Mailpit URL command works without starting Docker"
