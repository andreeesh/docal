#!/usr/bin/env bash
# Internal helper for the future "docal import --zip ... --db ..." workflow.
# Source from scripts/docal AFTER a new, dedicated site has been provisioned.
#
# Required globals: SITE_DIR, DB_NAME, DB_USER, DB_PASSWORD.
# A new-site provisioner must create .docal-import-pending in SITE_DIR.
# NEVER wire this helper into the existing import-db command.

docal_import_staged_sql_new_site() {
  local sql_file="${1:-}"
  local site_dir="${SITE_DIR:-}"
  local table_count

  if [[ -z "${site_dir}" || ! -d "${site_dir}" || -L "${site_dir}" ||
        ! -f "${site_dir}/docker-compose.yml" ||
        ! -f "${site_dir}/.env" ||
        ! -f "${site_dir}/.docal-import-pending" ]]; then
    echo "[error] SQL import requires a newly provisioned Docal site marked as import-pending." >&2
    return 1
  fi
  if [[ -z "${DB_NAME:-}" || -z "${DB_USER:-}" || -z "${DB_PASSWORD:-}" ]]; then
    echo "[error] Missing local database credentials." >&2
    return 1
  fi
  if [[ -z "${sql_file}" || ! -s "${sql_file}" || -L "${sql_file}" ]]; then
    echo "[error] A nonempty staged SQL file is required." >&2
    return 1
  fi
  if [[ "${sql_file}" != *.sql ]]; then
    echo "[error] Staged SQL must be an uncompressed .sql file." >&2
    return 1
  fi

  # Work only through the site's Compose project, using the scoped
  # WordPress database user instead of MySQL root.
  (
    cd "${site_dir}" || exit 1
    table_count="$(docker compose exec -T -e "MYSQL_PWD=${DB_PASSWORD}" db \
      mysql --batch --skip-column-names -u "${DB_USER}" "${DB_NAME}" \
      -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()' \
    )" || {
      echo "[error] Could not verify that the dedicated database is empty." >&2
      exit 1
    }
    if [[ "${table_count}" != "0" ]]; then
      echo "[error] Refusing SQL import: destination database is not empty." >&2
      exit 1
    fi

    if ! docker compose exec -T -e "MYSQL_PWD=${DB_PASSWORD}" db \
      mysql --binary-mode -u "${DB_USER}" "${DB_NAME}" < "${sql_file}"; then
      echo "[error] SQL import failed; destination database may be partially populated." >&2
      exit 1
    fi

    table_count="$(docker compose exec -T -e "MYSQL_PWD=${DB_PASSWORD}" db \
      mysql --batch --skip-column-names -u "${DB_USER}" "${DB_NAME}" \
      -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()' \
    )" || {
      echo "[error] SQL import finished but table verification failed." >&2
      exit 1
    }
    if [[ ! "${table_count}" =~ ^[0-9]+$ || "${table_count}" -eq 0 ]]; then
      echo "[error] SQL import did not create any tables; refusing to report success." >&2
      exit 1
    fi
    echo "[ok] SQL imported into new site database (${table_count} tables)."
  )
}
