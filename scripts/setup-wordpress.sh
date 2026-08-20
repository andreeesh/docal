#!/usr/bin/env bash

set -euo pipefail

SKIP_DOCKER=0
NON_INTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --skip-docker) SKIP_DOCKER=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    --help|-h) echo "Usage: $0 [--skip-docker] [--non-interactive]"; exit 0 ;;
  esac
done

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="${BASE_DIR}/scripts"
TEMPLATES_DIR="${BASE_DIR}/templates"
SITES_DIR="${SITES_DIR:-${BASE_DIR}/sites}"
PROXY_DIR="${PROXY_DIR:-${BASE_DIR}/proxy}"

mkdir -p "${SITES_DIR}"

ask() {
  local prompt="$1"
  local default_value="$2"
  local var_name="$3"
  local answer=""

  read -r -p "${prompt} [${default_value}]: " answer || true
  answer="${answer:-$default_value}"
  printf -v "${var_name}" '%s' "${answer}"
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | sed -E 's/--+/-/g'
}

upload_size_to_bytes() {
  local size="$1"
  local num="${size%[KkMmGg]}"
  local unit="${size#"${num}"}"

  case "${unit^^}" in
    G) echo $((num * 1024 * 1024 * 1024)) ;;
    M) echo $((num * 1024 * 1024)) ;;
    K) echo $((num * 1024)) ;;
    *) echo "${num}" ;;
  esac
}

php_memory_limit_for_upload() {
  local size="$1"
  local num="${size%[KkMmGg]}"
  local unit="${size#"${num}"}"

  case "${unit^^}" in
    G)
      if [[ "${num}" -ge 2 ]]; then
        echo "1024M"
      else
        echo "512M"
      fi
      ;;
    M)
      if [[ "${num}" -ge 512 ]]; then
        echo "1024M"
      elif [[ "${num}" -ge 128 ]]; then
        echo "512M"
      else
        echo "256M"
      fi
      ;;
    *)
      echo "256M"
      ;;
  esac
}

generate_cert() {
  local slug="$1"
  local domain="$2"
  local cert_dir="${PROXY_DIR}/certs"

  if ! command -v mkcert >/dev/null 2>&1; then
    echo "[warn] mkcert not found — skipping TLS certificate generation." >&2
    echo "[info] Install mkcert: https://github.com/FiloSottile/mkcert" >&2
    return 0
  fi

  mkdir -p "${cert_dir}"
  mkcert -install 2>/dev/null || true

  mkcert \
    -cert-file "${cert_dir}/${slug}.${domain}.crt" \
    -key-file  "${cert_dir}/${slug}.${domain}.key" \
    "${slug}.${domain}"

  cat > "${cert_dir}/${slug}.${domain}.yml" <<TLSEOF
tls:
  certificates:
    - certFile: /certs/${slug}.${domain}.crt
      keyFile: /certs/${slug}.${domain}.key
TLSEOF

  echo "[ok] TLS certificate generated for ${slug}.${domain}"
}

# finalize_imported_site() and import_wpress_backup() live in lib-import-wpress.sh
# so `docal import-wpress` can reuse them against an already-created site.
source "${SCRIPTS_DIR}/lib-import-wpress.sh"

import_database_dump() {
  local dump_path="$1"
  local dump_name
  dump_name="$(basename "${dump_path}")"

  echo "[info] Importing database ${dump_name}..."
  if [[ "${dump_name}" == *.gz ]]; then
    gunzip -c "${dump_path}" | docker compose exec -T db mysql \
      -u root -p"${DB_PASSWORD}" "${DB_NAME}"
  else
    docker compose exec -T db mysql \
      -u root -p"${DB_PASSWORD}" "${DB_NAME}" < "${dump_path}"
  fi
  echo "[ok] Database imported."
}

# Extract a uploads zip into wp-content/uploads.
# Detects root-level "uploads/" (or a single wrapper containing it) vs loose files.
import_uploads_zip() {
  local zip_path="$1"
  local container_name="$2"
  local zip_name tmp src
  zip_name="$(basename "${zip_path}")"
  tmp="$(mktemp -d)"

  echo "[info] Extracting ${zip_name}..."
  src="$(python3 - "${zip_path}" "${tmp}" <<'PY'
import sys
import zipfile
from pathlib import Path

zip_path = Path(sys.argv[1])
dest = Path(sys.argv[2])

with zipfile.ZipFile(zip_path) as zf:
    zf.extractall(dest)

def entries(path: Path):
    return sorted(
        p for p in path.iterdir()
        if p.name != "__MACOSX" and not p.name.startswith(".")
    )

top = entries(dest)
for item in top:
    if item.is_dir() and item.name.lower() == "uploads":
        print(item)
        raise SystemExit(0)

if len(top) == 1 and top[0].is_dir():
    nested = top[0] / "uploads"
    if nested.is_dir():
        print(nested)
        raise SystemExit(0)
    print(top[0])
    raise SystemExit(0)

print(dest)
PY
)"

  if [[ ! -d "${src}" ]]; then
    rm -rf "${tmp}"
    echo "[error] Could not determine uploads source inside ${zip_name}" >&2
    return 1
  fi

  if [[ "$(basename "${src}")" == "uploads" ]]; then
    echo "[info] Zip contains uploads/ — copying its contents into wp-content/uploads/"
  else
    echo "[info] Zip has loose files — copying into wp-content/uploads/"
  fi

  docker compose exec -T wordpress mkdir -p /var/www/html/wp-content/uploads
  docker cp "${src}/." "${container_name}:/var/www/html/wp-content/uploads/"
  docker compose exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content/uploads
  rm -rf "${tmp}"
  echo "[ok] Uploads imported."
}

write_wp_config() {
  local wp_dir="$1"
  local sample_file="${wp_dir}/wp-config-sample.php"
  local target_file="${wp_dir}/wp-config.php"

  if [[ ! -f "${sample_file}" ]]; then
    echo "[error] ${sample_file} not found. Clone the WordPress repository first." >&2
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "[error] python3 is required to generate wp-config.php." >&2
    return 1
  fi

  python3 - "${sample_file}" "${target_file}" "${DB_NAME}" "${DB_USER}" "${DB_PASSWORD}" "localhost:/var/run/mysqld/mysqld.sock" "${SITE_SLUG}.${SITE_DOMAIN}" "${WP_MEMORY_LIMIT}" <<'PY'
import pathlib
import secrets
import string
import sys

sample_path = pathlib.Path(sys.argv[1])
target_path = pathlib.Path(sys.argv[2])
db_name = sys.argv[3]
db_user = sys.argv[4]
db_password = sys.argv[5]
db_host = sys.argv[6]
site_host = sys.argv[7]
wp_memory_limit = sys.argv[8]

alphabet = string.ascii_letters + string.digits

def random_salt(length=64):
    return ''.join(secrets.choice(alphabet) for _ in range(length))

content = sample_path.read_text(encoding='utf-8')
content = content.replace("database_name_here", db_name)
content = content.replace("username_here", db_user)
content = content.replace("password_here", db_password)
content = content.replace("localhost", db_host)

replacements = {
    "define('AUTH_KEY', 'put your unique phrase here');": "define('AUTH_KEY', '%s');" % random_salt(),
    "define('SECURE_AUTH_KEY', 'put your unique phrase here');": "define('SECURE_AUTH_KEY', '%s');" % random_salt(),
    "define('LOGGED_IN_KEY', 'put your unique phrase here');": "define('LOGGED_IN_KEY', '%s');" % random_salt(),
    "define('NONCE_KEY', 'put your unique phrase here');": "define('NONCE_KEY', '%s');" % random_salt(),
    "define('AUTH_SALT', 'put your unique phrase here');": "define('AUTH_SALT', '%s');" % random_salt(),
    "define('SECURE_AUTH_SALT', 'put your unique phrase here');": "define('SECURE_AUTH_SALT', '%s');" % random_salt(),
    "define('LOGGED_IN_SALT', 'put your unique phrase here');": "define('LOGGED_IN_SALT', '%s');" % random_salt(),
    "define('NONCE_SALT', 'put your unique phrase here');": "define('NONCE_SALT', '%s');" % random_salt(),
}
for old, new in replacements.items():
    content = content.replace(old, new, 1)

extras = (
    "\n/** Site URL (fixed here because wp-config.php already exists by the time\n"
    " *  the container starts, so the WORDPRESS_* env vars are never applied) */\n"
    "defined( 'WP_HOME' ) || define( 'WP_HOME', 'https://%s' );\n"
    "defined( 'WP_SITEURL' ) || define( 'WP_SITEURL', 'https://%s' );\n"
    "defined( 'WP_MEMORY_LIMIT' ) || define( 'WP_MEMORY_LIMIT', '%s' );\n"
    "defined( 'WP_MAX_MEMORY_LIMIT' ) || define( 'WP_MAX_MEMORY_LIMIT', '%s' );\n"
    "\n/** Debug (local dev) */\n"
    "defined( 'WP_DEBUG' ) || define( 'WP_DEBUG', true );\n"
    "defined( 'WP_DEBUG_LOG' ) || define( 'WP_DEBUG_LOG', true );\n"
    "defined( 'WP_DEBUG_DISPLAY' ) || define( 'WP_DEBUG_DISPLAY', false );\n"
    "\n/** Reverse-proxy HTTPS detection (Traefik / any X-Forwarded-Proto proxy) */\n"
    "if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https' ) {\n"
    "\t$_SERVER['HTTPS'] = 'on';\n"
    "}\n\n"
) % (site_host, site_host, wp_memory_limit, wp_memory_limit)
content = content.replace(
    "require_once ABSPATH . 'wp-settings.php';",
    extras + "require_once ABSPATH . 'wp-settings.php';",
    1,
)

target_path.write_text(content, encoding='utf-8')
PY
}

PHP_VERSION="${PHP_VERSION:-latest}"
MYSQL_VERSION="${MYSQL_VERSION:-8.4}"
MAX_UPLOAD_SIZE="${MAX_UPLOAD_SIZE:-2G}"
SITE_NAME="${SITE_NAME:-demo}"
SITE_TITLE="${SITE_TITLE:-Demo site}"
SITE_DOMAIN="${SITE_DOMAIN:-localhost}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@docal.com}"
SITE_SLUG="${SITE_SLUG:-demo}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-wpuser}"
DB_PASSWORD="${DB_PASSWORD:-}"
INSTALL_AIOWP_MIGRATION="${INSTALL_AIOWP_MIGRATION:-0}"
OFFICIAL_WP_REPO="https://github.com/WordPress/WordPress.git"
WP_REPO_URL="${WP_REPO_URL:-${OFFICIAL_WP_REPO}}"

if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
  :
else
  ask "Site name (subdomain)" "${SITE_NAME}" SITE_NAME
  SITE_SLUG="$(slugify "${SITE_NAME}")"
  if [[ -z "${SITE_SLUG}" ]]; then
    SITE_SLUG="site"
  fi

  ask "Max upload size (e.g. 2G)" "${MAX_UPLOAD_SIZE}" MAX_UPLOAD_SIZE
  ask "PHP version (latest, 8.3, 8.2, 8.1, 8.0)" "${PHP_VERSION}" PHP_VERSION
  ask "MySQL version (latest, 8.4, 8.0, 5.7)" "${MYSQL_VERSION}" MYSQL_VERSION
  ask "Site title" "${SITE_TITLE}" SITE_TITLE
  ask "Local domain (default: localhost)" "${SITE_DOMAIN}" SITE_DOMAIN
  ask "Admin email" "${ADMIN_EMAIL}" ADMIN_EMAIL
  ask "Repository URL to clone (empty = official WordPress)" "${OFFICIAL_WP_REPO}" WP_REPO_URL
  if [[ -z "${WP_REPO_URL}" ]]; then
    WP_REPO_URL="${OFFICIAL_WP_REPO}"
  fi

  echo ""
  read -r -p "Install All-in-One WP Migration plugin? (https://wordpress.org/plugins/all-in-one-wp-migration/) [y/N]: " _aiowp
  [[ "${_aiowp:-N}" =~ ^[yY]$ ]] && INSTALL_AIOWP_MIGRATION=1
fi

SITE_SLUG="$(slugify "${SITE_NAME}")"
if [[ -z "${SITE_SLUG}" ]]; then
  SITE_SLUG="site"
fi

SITE_DIR="${SITES_DIR}/${SITE_SLUG}"

if [[ -d "${SITE_DIR}" && -f "${SITE_DIR}/docker-compose.yml" ]]; then
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    echo "[info] Site '${SITE_SLUG}' already exists — updating configuration only (DB and code untouched)."
  else
    echo ""
    echo "[warn] Site '${SITE_SLUG}' already exists in ${SITE_DIR}."
    echo "       Configuration will be updated (docker-compose, Dockerfile, uploads.ini)."
    echo "       Database and WordPress code will NOT be modified."
    read -r -p "Continue? [y/N]: " _confirm
    _confirm="${_confirm:-N}"
    if [[ ! "${_confirm}" =~ ^[yY]$ ]]; then
      echo "[info] Cancelled."
      exit 0
    fi
  fi
fi

# If the site already exists, reuse its credentials so we don't break the existing DB
if [[ -f "${SITE_DIR}/.env" ]]; then
  _existing_pw="$(grep '^DB_PASSWORD=' "${SITE_DIR}/.env" 2>/dev/null | cut -d= -f2- | tr -d '\r')" || true
  [[ -n "${_existing_pw}" ]] && DB_PASSWORD="${_existing_pw}"
fi

DB_NAME="${DB_NAME:-wp_${SITE_SLUG}}"
DB_USER="wp_${SITE_SLUG}"
DB_PASSWORD="${DB_PASSWORD:-$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)}"

mkdir -p "${SITE_DIR}/wordpress"

if [[ ! -f "${SITE_DIR}/wordpress/.git/config" ]]; then
  WP_REPO_URL="${WP_REPO_URL}" "${SCRIPTS_DIR}/clone-official-wordpress.sh" "${SITE_DIR}/wordpress"
  if [[ "${NON_INTERACTIVE}" -eq 0 ]]; then
    echo ""
    read -r -p "Remove the cloned git repository? [Y/n]: " _rmgit
    _rmgit="${_rmgit:-Y}"
    if [[ "${_rmgit}" =~ ^[yY]$ ]]; then
      rm -rf "${SITE_DIR}/wordpress/.git"
      echo "[ok] Git repository removed from ${SITE_DIR}/wordpress"
    fi
  fi
fi

PHP_IMAGE_TAG="latest"
if [[ "${PHP_VERSION}" != "latest" ]]; then
  PHP_IMAGE_TAG="php${PHP_VERSION}-apache"
fi

MYSQL_IMAGE_TAG="latest"
if [[ "${MYSQL_VERSION}" != "latest" ]]; then
  MYSQL_IMAGE_TAG="${MYSQL_VERSION}"
fi

UPLOAD_BYTES="$(upload_size_to_bytes "${MAX_UPLOAD_SIZE}")"
MAX_UPLOAD_BYTES="$((UPLOAD_BYTES + UPLOAD_BYTES / 10 + 104857600))"
WP_MEMORY_LIMIT="$(php_memory_limit_for_upload "${MAX_UPLOAD_SIZE}")"

sed \
  -e "s|__SITE_SLUG__|${SITE_SLUG}|g" \
  -e "s|__SITE_NAME__|${SITE_NAME}|g" \
  -e "s|__SITE_TITLE__|${SITE_TITLE}|g" \
  -e "s|__SITE_DOMAIN__|${SITE_DOMAIN}|g" \
  -e "s|__SITE_URL__|https://${SITE_SLUG}.${SITE_DOMAIN}|g" \
  -e "s|__ADMIN_EMAIL__|${ADMIN_EMAIL}|g" \
  -e "s|__PHP_IMAGE_TAG__|${PHP_IMAGE_TAG}|g" \
  -e "s|__MYSQL_IMAGE_TAG__|${MYSQL_IMAGE_TAG}|g" \
  -e "s|__DB_NAME__|${DB_NAME}|g" \
  -e "s|__DB_USER__|${DB_USER}|g" \
  -e "s|__DB_PASSWORD__|${DB_PASSWORD}|g" \
  -e "s|__MAX_UPLOAD_BYTES__|${MAX_UPLOAD_BYTES}|g" \
  -e "s|__WP_MEMORY_LIMIT__|${WP_MEMORY_LIMIT}|g" \
  "${TEMPLATES_DIR}/docker-compose.yml.tpl" > "${SITE_DIR}/docker-compose.yml"

sed \
  -e "s|__PHP_IMAGE_TAG__|${PHP_IMAGE_TAG}|g" \
  -e "s|__MAX_UPLOAD_BYTES__|${MAX_UPLOAD_BYTES}|g" \
  "${TEMPLATES_DIR}/Dockerfile.tpl" > "${SITE_DIR}/Dockerfile"

cat > "${SITE_DIR}/uploads.ini" <<EOF
file_uploads = On
upload_max_filesize = ${MAX_UPLOAD_SIZE}
post_max_size = ${MAX_UPLOAD_SIZE}
memory_limit = ${WP_MEMORY_LIMIT}
max_execution_time = 0
max_input_time = -1
output_buffering = Off
EOF

write_wp_config "${SITE_DIR}/wordpress"
generate_cert "${SITE_SLUG}" "${SITE_DOMAIN}"

cat > "${SITE_DIR}/.env" <<EOF
SITE_NAME=${SITE_NAME}
SITE_SLUG=${SITE_SLUG}
SITE_TITLE=${SITE_TITLE}
SITE_DOMAIN=${SITE_DOMAIN}
SITE_URL=https://${SITE_SLUG}.${SITE_DOMAIN}
PHP_VERSION=${PHP_VERSION}
MYSQL_VERSION=${MYSQL_VERSION}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
ADMIN_EMAIL=${ADMIN_EMAIL}
MAX_UPLOAD_SIZE=${MAX_UPLOAD_SIZE}
MAX_UPLOAD_BYTES=${MAX_UPLOAD_BYTES}
WP_MEMORY_LIMIT=${WP_MEMORY_LIMIT}
EOF

cat > "${SITE_DIR}/README.md" <<EOF
# ${SITE_NAME}

WordPress site ready to run with Docker.

- URL: https://${SITE_SLUG}.${SITE_DOMAIN}
- Admin user: admin
- Admin password: admin
- DB: ${DB_NAME}

Commands:
  cd ${SITE_DIR}
  docker compose up -d --build
EOF

if [[ "${SKIP_DOCKER}" -eq 1 ]]; then
  echo "[info] --skip-docker: containers will not be started."
  echo "[info] wp-config.php generated with DB_NAME=${DB_NAME} and DB_USER=${DB_USER}."
  exit 0
fi

docker network create docal-proxy >/dev/null 2>&1 || true

"${SCRIPTS_DIR}/start-proxy.sh"

export HOST_UID="${HOST_UID:-$(id -u)}"
export HOST_GID="${HOST_GID:-$(id -g)}"

echo "[info] Starting containers..."
cd "${SITE_DIR}"
docker compose up -d --build

echo "[info] Installing WordPress..."
docker compose run -T --rm wp-init

echo "[info] Fixing permissions..."
"${SCRIPTS_DIR}/fix-wp-permissions.sh" "${SITE_DIR}"

echo "[info] Configuring permalinks..."
"${SCRIPTS_DIR}/ensure-wp-rewrites.sh" "${SITE_DIR}"

if [[ "${INSTALL_AIOWP_MIGRATION}" -eq 1 ]]; then
  echo "[info] Installing All-in-One WP Migration..."
  docker compose exec -T wordpress wp plugin install all-in-one-wp-migration --activate --force --allow-root
  docker compose exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content
  echo "[ok] All-in-One WP Migration installed."
fi

PLUGINS_DIR="${BASE_DIR}/plugins"
if [[ -d "${PLUGINS_DIR}" ]]; then
  mapfile -t plugin_zips < <(find "${PLUGINS_DIR}" -maxdepth 1 -name "*.zip" ! -name "*:*" | sort)

  if [[ ${#plugin_zips[@]} -gt 0 ]]; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      echo "[info] Non-interactive: skipping local plugin installation."
    else
      echo ""
      echo "Available plugins in ${PLUGINS_DIR}:"
      for i in "${!plugin_zips[@]}"; do
        echo "  $((i+1))) $(basename "${plugin_zips[$i]}")"
      done
      echo ""
      read -r -p "Install plugins? (space-separated numbers, 'all' for all, Enter to skip): " _plugin_choice

      selected_plugins=()
      if [[ "${_plugin_choice,,}" == "all" ]]; then
        selected_plugins=("${plugin_zips[@]}")
      elif [[ -n "${_plugin_choice}" ]]; then
        for num in ${_plugin_choice}; do
          if [[ "${num}" =~ ^[0-9]+$ ]]; then
            idx=$((num - 1))
            if [[ "${idx}" -ge 0 && "${idx}" -lt "${#plugin_zips[@]}" ]]; then
              selected_plugins+=("${plugin_zips[$idx]}")
            else
              echo "[warn] Invalid number: ${num}" >&2
            fi
          fi
        done
      fi

      if [[ ${#selected_plugins[@]} -gt 0 ]]; then
        CONTAINER_NAME="docal-${SITE_SLUG}-wp"
        for zip_path in "${selected_plugins[@]}"; do
          plugin_name="$(basename "${zip_path}")"
          echo "[info] Installing ${plugin_name}..."
          docker cp "${zip_path}" "${CONTAINER_NAME}:/tmp/${plugin_name}"
          docker compose exec -T wordpress wp plugin install "/tmp/${plugin_name}" --activate --force --allow-root
          docker compose exec -T wordpress rm "/tmp/${plugin_name}"
        done
        docker compose exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content
        echo "[ok] Local plugins installed."
      fi
    fi
  fi
fi

# Import sources are mutually exclusive: All-in-One (.wpress) OR database/uploads.
if [[ "${NON_INTERACTIVE}" -eq 0 ]]; then
  WPRESS_DIR="${BASE_DIR}/wpress"
  DBS_DIR="${BASE_DIR}/dbs"
  FILES_DIR="${BASE_DIR}/files"

  mapfile -t wpress_files < <(find "${WPRESS_DIR}" -maxdepth 1 -type f -name "*.wpress" 2>/dev/null | sort)
  mapfile -t db_dumps < <(find "${DBS_DIR}" -maxdepth 1 -type f \( -name "*.sql" -o -name "*.sql.gz" \) 2>/dev/null | sort)
  mapfile -t upload_zips < <(find "${FILES_DIR}" -maxdepth 1 -type f -name "*.zip" 2>/dev/null | sort)

  has_wpress=0
  has_db_files=0
  [[ ${#wpress_files[@]} -gt 0 ]] && has_wpress=1
  [[ ${#db_dumps[@]} -gt 0 || ${#upload_zips[@]} -gt 0 ]] && has_db_files=1

  import_mode=""
  if [[ "${has_wpress}" -eq 1 && "${has_db_files}" -eq 1 ]]; then
    echo ""
    echo "Import sources found. Choose ONE method (they do not combine):"
    echo "  1) All-in-One WP Migration backup (.wpress from wpress/)"
    echo "  2) Database and/or uploads (dbs/ + files/)"
    echo ""
    read -r -p "Import method? (1/2 or Enter to skip): " _import_mode_choice
    case "${_import_mode_choice}" in
      1) import_mode="wpress" ;;
      2) import_mode="dbfiles" ;;
      *) import_mode="skip" ;;
    esac
  elif [[ "${has_wpress}" -eq 1 ]]; then
    import_mode="wpress"
  elif [[ "${has_db_files}" -eq 1 ]]; then
    import_mode="dbfiles"
  fi

  if [[ "${import_mode}" == "wpress" ]]; then
    echo ""
    echo "Available backups in ${WPRESS_DIR}:"
    for i in "${!wpress_files[@]}"; do
      echo "  $((i+1))) $(basename "${wpress_files[$i]}")"
    done
    echo ""
    read -r -p "Import a backup? (number or Enter to skip): " _wpress_choice

    if [[ -n "${_wpress_choice}" && "${_wpress_choice}" =~ ^[0-9]+$ ]]; then
      wpress_idx=$((_wpress_choice - 1))
      if [[ "${wpress_idx}" -ge 0 && "${wpress_idx}" -lt "${#wpress_files[@]}" ]]; then
        import_wpress_backup "${wpress_files[$wpress_idx]}"
      else
        echo "[warn] Invalid selection: ${_wpress_choice}" >&2
      fi
    fi
  elif [[ "${import_mode}" == "dbfiles" ]]; then
    selected_db=""
    selected_files=""
    CONTAINER_NAME="docal-${SITE_SLUG}-wp"

    if [[ ${#db_dumps[@]} -gt 0 ]]; then
      echo ""
      echo "Available databases in ${DBS_DIR}:"
      for i in "${!db_dumps[@]}"; do
        echo "  $((i+1))) $(basename "${db_dumps[$i]}")"
      done
      echo ""
      read -r -p "Import a database? (number or Enter to skip): " _db_choice

      if [[ -n "${_db_choice}" && "${_db_choice}" =~ ^[0-9]+$ ]]; then
        db_idx=$((_db_choice - 1))
        if [[ "${db_idx}" -ge 0 && "${db_idx}" -lt "${#db_dumps[@]}" ]]; then
          selected_db="${db_dumps[$db_idx]}"
        else
          echo "[warn] Invalid selection: ${_db_choice}" >&2
        fi
      fi
    fi

    if [[ ${#upload_zips[@]} -gt 0 ]]; then
      echo ""
      echo "Available uploads archives in ${FILES_DIR}:"
      for i in "${!upload_zips[@]}"; do
        echo "  $((i+1))) $(basename "${upload_zips[$i]}")"
      done
      echo ""
      read -r -p "Import uploads files? (number or Enter to skip): " _files_choice

      if [[ -n "${_files_choice}" && "${_files_choice}" =~ ^[0-9]+$ ]]; then
        files_idx=$((_files_choice - 1))
        if [[ "${files_idx}" -ge 0 && "${files_idx}" -lt "${#upload_zips[@]}" ]]; then
          selected_files="${upload_zips[$files_idx]}"
        else
          echo "[warn] Invalid selection: ${_files_choice}" >&2
        fi
      fi
    fi

    if [[ -n "${selected_db}" ]]; then
      import_database_dump "${selected_db}"
    fi
    if [[ -n "${selected_files}" ]]; then
      import_uploads_zip "${selected_files}" "${CONTAINER_NAME}"
    fi
    if [[ -n "${selected_db}" || -n "${selected_files}" ]]; then
      if [[ -n "${selected_db}" ]]; then
        finalize_imported_site
      else
        docker compose exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content/uploads
        "${SCRIPTS_DIR}/ensure-wp-rewrites.sh" "${SITE_DIR}" || true
      fi
      echo "[ok] Database/uploads import finished."
    fi
  fi
fi

echo "[ok] https://${SITE_SLUG}.${SITE_DOMAIN}"

echo "[info] Credentials: admin / admin"
