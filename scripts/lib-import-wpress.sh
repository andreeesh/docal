#!/usr/bin/env bash
# Shared by setup-wordpress.sh (create --aiowp flow) and
# `docal import-wpress` (existing-site flow).
#
# Callers must set before sourcing: SCRIPTS_DIR, SITE_DIR, SITE_SLUG,
# SITE_DOMAIN, ADMIN_EMAIL, INSTALL_AIOWP_MIGRATION (0/1), and cd into
# SITE_DIR (docker compose commands run against the site's compose file).

# Post-import: local URL, cache cleanup, permalinks, secure local administrator.
finalize_imported_site() {
  local old_siteurl new_siteurl old_domain old_siteurl_http

  docker compose exec -T wordpress wp plugin deactivate wp-rocket --skip-plugins=wp-rocket --allow-root 2>/dev/null || true
  docker compose exec -T wordpress bash -c "rm -rf /var/www/html/wp-content/cache/wp-rocket /var/www/html/wp-content/cache/min 2>/dev/null" || true
  echo "✓ WP Rocket disabled"

  old_siteurl="$(docker compose exec -T wordpress wp option get siteurl --skip-plugins=wp-rocket --allow-root 2>/dev/null | tr -d '\r\n')" || true
  new_siteurl="https://${SITE_SLUG}.${SITE_DOMAIN}"

  docker compose exec -T wordpress wp option update siteurl "${new_siteurl}" --skip-plugins=wp-rocket --allow-root
  docker compose exec -T wordpress wp option update home "${new_siteurl}" --skip-plugins=wp-rocket --allow-root

  if [[ -n "${old_siteurl}" && "${old_siteurl}" != "${new_siteurl}" ]]; then
    echo "✓ Production URL detected: ${old_siteurl}"
    docker compose exec -T wordpress wp search-replace "${old_siteurl}" "${new_siteurl}" \
      --recurse-objects --skip-columns=guid --skip-plugins=wp-rocket --allow-root
    old_siteurl_http="${old_siteurl/https:\/\//http:\/\/}"
    if [[ "${old_siteurl_http}" != "${old_siteurl}" ]]; then
      docker compose exec -T wordpress wp search-replace "${old_siteurl_http}" "${new_siteurl}" \
        --recurse-objects --skip-columns=guid --skip-plugins=wp-rocket --allow-root 2>/dev/null || true
    fi
    echo "✓ URLs replaced"
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
  echo "✓ Elementor CSS regenerated"

  "${SCRIPTS_DIR}/ensure-wp-rewrites.sh" "${SITE_DIR}" || echo "[warn] ensure-wp-rewrites.sh failed after import — check .htaccess manually." >&2
  echo "✓ Permalinks flushed"

  local admin_user="${ADMIN_USER:-admin}"
  local import_admin_password
  import_admin_password="$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  if docker compose exec -T wordpress wp user update "${admin_user}" --role=administrator --user_pass="${import_admin_password}" --skip-plugins=wp-rocket --allow-root 2>/dev/null || \
     docker compose exec -T wordpress wp user create "${admin_user}" "${ADMIN_EMAIL}" --role=administrator --user_pass="${import_admin_password}" --skip-plugins=wp-rocket --allow-root 2>/dev/null; then
    echo "[info] Imported site admin password for ${admin_user}: ${import_admin_password}"
  else
    echo "[error] Could not configure a local administrator after import." >&2
    return 1
  fi

  docker compose exec -T wordpress wp cache flush --skip-plugins=wp-rocket --allow-root 2>/dev/null || true
  echo "✓ Local administrator ready"
}

import_wpress_backup() {
  local selected_wpress="$1"
  local wpress_name container_name restore_marker
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

  # A successful exit code alone does not prove that a restore occurred.
  # The marker is written to the fresh site's DB and must disappear when
  # the backup replaces that database.
  restore_marker="docal_restore_probe_$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  docker compose exec -T wordpress wp option add "${restore_marker}" pending --skip-plugins --skip-themes --allow-root >/dev/null
  echo "[info] Importing backup (this may take several minutes)..."
  if ! docker compose exec -T wordpress wp ai1wm restore "${wpress_name}" --yes --allow-root; then
    echo "[error] All-in-One WP Migration restore command failed. Check plugin/extension compatibility." >&2
    return 1
  fi
  if docker compose exec -T wordpress wp option get "${restore_marker}" --skip-plugins --skip-themes --allow-root >/dev/null 2>&1; then
    echo "[error] Restore did not replace the WordPress database; refusing to report success." >&2
    return 1
  fi
  docker compose exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content
  echo "✓ Backup restored"

  finalize_imported_site
}
