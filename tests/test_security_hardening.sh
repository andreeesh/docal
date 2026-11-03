#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
mkdir -p "$tmp/sites/good-site" "$tmp/outside"
printf 'SITE_URL=https://good-site.localhost\n' > "$tmp/sites/good-site/.env"
touch "$tmp/sites/good-site/docker-compose.yml"
ln -s "$tmp/outside" "$tmp/sites/linked-site"
export DOCAL_SITES_DIR="$tmp/sites"

check_rejected() {
  local site="$1" output
  if output="$(scripts/docal info "$site" 2>&1)"; then
    echo "FAIL: unsafe site accepted: $site" >&2
    exit 1
  fi
  case "$site" in
    ../*|*/../*|/*|linked-site)
      grep -Eq 'Invalid site name|symlink|not found' <<< "$output" || {
        echo "FAIL: unexpected rejection for $site: $output" >&2; exit 1;
      }
      ;;
  esac
}
check_rejected '../outside'
check_rejected 'linked-site'
check_rejected '/tmp'
check_rejected 'good-site/../outside'
check_rejected 'not-found'

# A valid managed site must remain accessible.
scripts/docal info good-site >/dev/null 2>&1 || {
  echo "FAIL: valid site rejected" >&2; exit 1;
}

for compose in proxy/docker-compose.yml scripts/start-proxy.sh; do
  grep -q '127.0.0.1:8080:8080' "$compose" || {
    echo "FAIL: dashboard not bound to loopback in $compose" >&2; exit 1;
  }
  grep -q '127.0.0.1:80:80' "$compose" || {
    echo "FAIL: HTTP not bound to loopback in $compose" >&2; exit 1;
  }
  grep -q '127.0.0.1:443:443' "$compose" || {
    echo "FAIL: HTTPS not bound to loopback in $compose" >&2; exit 1;
  }
done

! grep -q -- '--admin_password=admin' templates/docker-compose.yml.tpl || {
  echo 'FAIL: hardcoded WordPress admin password' >&2; exit 1;
}
grep -q -- '--admin_password=__ADMIN_PASSWORD__' templates/docker-compose.yml.tpl || {
  echo 'FAIL: generated WordPress admin password not injected' >&2; exit 1;
}

echo "OK: site traversal, symlink and proxy exposure checks"
