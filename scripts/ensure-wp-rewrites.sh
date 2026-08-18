#!/usr/bin/env bash
set -euo pipefail

SITE_DIR="${1:?Usage: ensure-wp-rewrites.sh <site-directory>}"
HTACCESS="${SITE_DIR}/wordpress/.htaccess"

if [[ ! -f "${SITE_DIR}/docker-compose.yml" ]]; then
  echo "[error] docker-compose.yml not found in ${SITE_DIR}" >&2
  exit 1
fi

cd "${SITE_DIR}"

WP_REWRITE_BLOCK='# BEGIN WordPress
# The directives (lines) between "BEGIN WordPress" and "END WordPress" are
# dynamically generated, and should only be modified via WordPress filters.
# Any changes to the directives between these markers will be overwritten.
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress'

inject_wp_rewrite_block() {
  if [[ ! -f "${HTACCESS}" ]]; then
    printf '%s\n' "${WP_REWRITE_BLOCK}" > "${HTACCESS}"
    echo "[ok] Created ${HTACCESS} with WordPress rewrite rules."
    return 0
  fi

  if grep -q '# BEGIN WordPress' "${HTACCESS}"; then
    # Markers can exist with an empty body (common after security .htaccess edits).
    # Always restore the WordPress rewrite block so pretty permalinks keep working.
    python3 - "${HTACCESS}" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
block = '''# BEGIN WordPress
# The directives (lines) between "BEGIN WordPress" and "END WordPress" are
# dynamically generated, and should only be modified via WordPress filters.
# Any changes to the directives between these markers will be overwritten.
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>

# END WordPress'''
new, n = re.subn(r'# BEGIN WordPress.*?# END WordPress', block, text, count=1, flags=re.S)
if n:
    open(path, 'w', encoding='utf-8').write(new)
    print(f'[ok] Restored WordPress rewrite rules in {path}.')
else:
    print(f'[warn] WordPress markers found but replace failed for {path}.', file=sys.stderr)
    sys.exit(1)
PY
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  printf '%s\n\n' "${WP_REWRITE_BLOCK}" > "${tmp}"
  cat "${HTACCESS}" >> "${tmp}"
  mv "${tmp}" "${HTACCESS}"
  echo "[ok] WordPress rewrite rules added to ${HTACCESS}."
}

echo "[info] Ensuring .htaccess permissions..."
docker compose exec -T wordpress touch /var/www/html/.htaccess 2>/dev/null || true
docker compose exec -T wordpress chown www-data:www-data /var/www/html/.htaccess 2>/dev/null || true
docker compose exec -T wordpress chmod 664 /var/www/html/.htaccess 2>/dev/null || true

inject_wp_rewrite_block

echo "[info] Regenerating permalink rules via WP-CLI..."
docker compose exec -T wordpress wp rewrite structure '/%postname%/' --allow-root
docker compose exec -T wordpress wp rewrite flush --allow-root

echo "[info] Checking REST API..."
local_code="$(docker compose exec -T wordpress curl -s -o /dev/null -w '%{http_code}' http://localhost/wp-json/ 2>/dev/null || echo "000")"
if [[ "${local_code}" == "200" ]]; then
  echo "[ok] /wp-json/ responded HTTP 200."
else
  echo "[warn] /wp-json/ returned HTTP ${local_code} — check permalinks and .htaccess manually." >&2
  exit 1
fi
