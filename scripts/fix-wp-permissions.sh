#!/usr/bin/env bash
set -euo pipefail

SITE_DIR="${1:?Usage: fix-wp-permissions.sh <site-directory>}"

if [[ ! -f "${SITE_DIR}/docker-compose.yml" ]]; then
  echo "[error] docker-compose.yml not found in ${SITE_DIR}" >&2
  exit 1
fi

cd "${SITE_DIR}"

docker compose exec -T wordpress mkdir -p /var/www/html/wp-content/uploads
docker compose exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content
docker compose exec -T wordpress chmod -R 775 /var/www/html/wp-content/uploads

# .htaccess must be writable by www-data so WP-CLI/WordPress can regenerate permalinks
docker compose exec -T wordpress touch /var/www/html/.htaccess 2>/dev/null || true
docker compose exec -T wordpress chown www-data:www-data /var/www/html/.htaccess 2>/dev/null || true
docker compose exec -T wordpress chmod 664 /var/www/html/.htaccess 2>/dev/null || true
