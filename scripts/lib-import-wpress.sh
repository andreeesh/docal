#!/usr/bin/env bash
# Shared by setup-wordpress.sh (create --aiowp flow) and
# `docal import-wpress` (existing-site flow).
#
# Callers must set before sourcing: SCRIPTS_DIR, SITE_DIR, SITE_SLUG,
# SITE_DOMAIN, ADMIN_EMAIL, INSTALL_AIOWP_MIGRATION (0/1), and cd into
# SITE_DIR (docker compose commands run against the site's compose file).

# Post-import: local URL, cache cleanup, permalinks, admin/admin.
finalize_imported_site() {
  local old_siteurl new_siteurl old_domain old_siteurl_http

  docker compose exec -T wordpress wp plugin deactivate wp-rocket --skip-plugins=wp-rocket --allow-root 2>/dev/null || true
  docker compose exec -T wordpress bash -c "rm -rf /var/www/html/wp-content/cache/wp-rocket /var/www/html/wp-content/cache/min 2>/dev/null" || true

  old_siteurl="$(docker compose exec -T wordpress wp option get siteurl --skip-plugins=wp-rocket --allow-root 2>/dev/null | tr -d '\r\n')" || true
  new_siteurl="https://${SITE_SLUG}.${SITE_DOMAIN}"

  docker compose exec -T wordpress wp option update siteurl "${new_siteurl}" --skip-plugins=wp-rocket --allow-root
  docker compose exec -T wordpress wp option update home "${new_siteurl}" --skip-plugins=wp-rocket --allow-root

  if [[ -n "${old_siteurl}" && "${old_siteurl}" != "${new_siteurl}" ]]; then
    echo "[info] Replacing URLs: ${old_siteurl} → ${new_siteurl}"
    docker compose exec -T wordpress wp search-replace "${old_siteurl}" "${new_siteurl}" \
      --recurse-objects --skip-columns=guid --skip-plugins=wp-rocket --allow-root
    old_siteurl_http="${old_siteurl/https:\/\//http:\/\/}"
    if [[ "${old_siteurl_http}" != "${old_siteurl}" ]]; then
      docker compose exec -T wordpress wp search-replace "${old_siteurl_http}" "${new_siteurl}" \
        --recurse-objects --skip-columns=guid --skip-plugins=wp-rocket --allow-root 2>/dev/null || true
    fi
  fi

  old_domain="${old_siteurl#https://}"
  old_domain="${old_domain#http://}"
  if [[ -n "${old_domain}" ]]; then
    # old_domain/new_siteurl come from the imported backup's own DB content, so
    # they're untrusted — pass them in as env vars instead of splicing them into
    # the inner bash -c string, or a crafted siteurl could break out of the sed
    # expression and run arbitrary commands in the container.
    docker compose exec -T -e OLD_DOMAIN="${old_domain}" -e NEW_SITEURL="${new_siteurl}" wordpress \
      bash -c 'find /var/www/html/wp-content/uploads -type f -name "*.css" -exec sed -i "s|https://${OLD_DOMAIN}|${NEW_SITEURL}|g; s|http://${OLD_DOMAIN}|${NEW_SITEURL}|g" {} +' 2>/dev/null || true
  fi

  docker compose exec -T wordpress mkdir -p /var/www/html/wp-content/uploads/elementor/css 2>/dev/null || true
  docker compose exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content/uploads/elementor 2>/dev/null || true
  docker compose exec -T wordpress wp elementor flush_css --skip-plugins=wp-rocket --allow-root 2>/dev/null || true

  "${SCRIPTS_DIR}/ensure-wp-rewrites.sh" "${SITE_DIR}" || echo "[warn] ensure-wp-rewrites.sh failed after import — check .htaccess manually." >&2

  docker compose exec -T wordpress wp user update admin --user_pass=admin --skip-plugins=wp-rocket --allow-root 2>/dev/null || \
    docker compose exec -T wordpress wp user create admin "${ADMIN_EMAIL}" --role=administrator --user_pass=admin --skip-plugins=wp-rocket --allow-root 2>/dev/null || true

  docker compose exec -T wordpress wp cache flush --skip-plugins=wp-rocket --allow-root 2>/dev/null || true
}

import_wpress_backup() {
  local selected_wpress="$1"
  local wpress_name container_name
  wpress_name="$(basename "${selected_wpress}")"
  container_name="docal-${SITE_SLUG}-wp"

  if [[ "${INSTALL_AIOWP_MIGRATION}" -ne 1 ]]; then
    echo "[info] Installing All-in-One WP Migration (required for restore)..."
    docker compose exec -T wordpress wp plugin install all-in-one-wp-migration --activate --force --allow-root
    docker compose exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content
  fi

  echo "[info] Copying backup to container..."
  docker cp "${selected_wpress}" "${container_name}:/var/www/html/wp-content/ai1wm-backups/${wpress_name}"
  docker compose exec -T wordpress chown www-data:www-data "/var/www/html/wp-content/ai1wm-backups/${wpress_name}"

  echo "[info] Importing backup (this may take several minutes)..."
  docker compose exec -T wordpress wp ai1wm restore "${wpress_name}" --yes --allow-root
  docker compose exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content

  finalize_imported_site
  echo "[ok] Backup imported."
}
