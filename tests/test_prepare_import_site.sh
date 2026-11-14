#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT

# Offline WordPress skeleton: no real site and no external download needed.
mkdir -p "${work}/source/wp-content" "${work}/source/wp-admin" "${work}/source/wp-includes"
cat > "${work}/source/wp-config-sample.php" <<'EOF'
<?php
define( 'DB_NAME', 'database_name_here' );
define( 'DB_USER', 'username_here' );
define( 'DB_PASSWORD', 'password_here' );
define( 'DB_HOST', 'localhost' );
require_once ABSPATH . 'wp-settings.php';
EOF
git init -q "${work}/source"
git -C "${work}/source" add .
git -C "${work}/source" -c user.email=test@example.invalid -c user.name="Docal Tests" commit -qm initial

export SITES_DIR="${work}/sites"
export PROXY_DIR="${work}/proxy"
export WP_REPO_URL="${work}/source"
export SITE_NAME="import-test"
mkdir -p "${SITES_DIR}"

# Even --skip-docker must create a separate site and not touch proxy/certs.
bash "${ROOT}/scripts/setup-wordpress.sh" --prepare-import --non-interactive --skip-docker > "${work}/output" 2>&1
site="${SITES_DIR}/import-test"
[[ -s "${site}/.docal-import-pending" ]]
[[ -f "${site}/.env" && -f "${site}/docker-compose.yml" ]]
[[ -f "${site}/wordpress/wp-config.php" ]]
[[ ! -e "${site}/.docal-wordpress-installed" ]]
[[ ! -e "${PROXY_DIR}/certs/import-test.localhost.crt" ]]
grep -q 'DB_NAME' "${site}/wordpress/wp-config.php"
before="$(sha256sum "${site}/.env" "${site}/wordpress/wp-config.php")"

# Never configure an existing site: preserve files byte for byte.
if bash "${ROOT}/scripts/setup-wordpress.sh" --prepare-import --non-interactive --skip-docker > "${work}/collision.log" 2>&1; then
  echo "FAIL: existing import site accepted" >&2
  exit 1
fi
after="$(sha256sum "${site}/.env" "${site}/wordpress/wp-config.php")"
[[ "${before}" == "${after}" ]]

# The import mode refuses implicit defaults and invalid site names.
if env -u SITE_NAME bash "${ROOT}/scripts/setup-wordpress.sh" --prepare-import --non-interactive --skip-docker >/dev/null 2>&1; then
  echo "FAIL: missing site name accepted" >&2
  exit 1
fi
if SITE_NAME="../escape" bash "${ROOT}/scripts/setup-wordpress.sh" --prepare-import --non-interactive --skip-docker >/dev/null 2>&1; then
  echo "FAIL: traversal site name accepted" >&2
  exit 1
fi
if SITE_NAME="interactive" bash "${ROOT}/scripts/setup-wordpress.sh" --prepare-import --skip-docker >/dev/null 2>&1; then
  echo "FAIL: interactive import creation accepted" >&2
  exit 1
fi

# Docker execution is mocked: verify database-only startup and no WordPress
# init, web container, or proxy. The test does not touch Docker resources.
mkdir -p "${work}/mock-bin"
export MOCK_DOCKER_LOG="${work}/docker.log"
cat > "${work}/mock-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_DOCKER_LOG}"
case "$*" in
  "container inspect "*|"volume inspect "*) exit 1 ;;
  "network create docal-proxy") exit 0 ;;
  "compose up -d db") exit 0 ;;
  *"SELECT COUNT("*)
    printf '%s\n' "${MOCK_DB_TABLES:-0}"
    exit 0 ;;
  *"SELECT 1"*) printf '%s\n' 1; exit 0 ;;
  *) echo "Unexpected Docker call" >&2; exit 1 ;;
esac
EOF
chmod +x "${work}/mock-bin/docker"
export PATH="${work}/mock-bin:${PATH}"

SITE_NAME="fresh-db" bash "${ROOT}/scripts/setup-wordpress.sh" --prepare-import --non-interactive > "${work}/db-output" 2>&1
[[ -f "${SITES_DIR}/fresh-db/.docal-import-pending" ]]
grep -qx 'compose up -d db' "${MOCK_DOCKER_LOG}"
! grep -q -E 'wp-init|compose up -d --build|compose up -d wordpress' "${MOCK_DOCKER_LOG}"
! grep -q 'WordPress installed' "${work}/db-output"

# Refuse a new import when MySQL is unexpectedly nonempty.
export MOCK_DB_TABLES=5
if SITE_NAME="populated-db" bash "${ROOT}/scripts/setup-wordpress.sh" --prepare-import --non-interactive > "${work}/nonempty.log" 2>&1; then
  echo "FAIL: populated import database accepted" >&2
  exit 1
fi
grep -q 'not empty' "${work}/nonempty.log"

# A colliding Docker container must be refused BEFORE making a new site.
cat > "${work}/mock-bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "container inspect docal-collision-db") exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${work}/mock-bin/docker"
if SITE_NAME="collision" bash "${ROOT}/scripts/setup-wordpress.sh" --prepare-import --non-interactive > "${work}/docker-collision.log" 2>&1; then
  echo "FAIL: existing Docker container accepted" >&2
  exit 1
fi
[[ ! -e "${SITES_DIR}/collision" ]]

echo "Fresh import site provisioning tests passed"
