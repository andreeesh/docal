#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT
export SITES_DIR="${TMP_ROOT}/sites"
export PROXY_DIR="${TMP_ROOT}/proxy"
export CAROOT="${TMP_ROOT}/caroot"
export WP_REPO_URL="${TMP_ROOT}/wp-repo"
mkdir -p "${TMP_ROOT}/bin" "${TMP_ROOT}/wp-repo"

# This test needs only wp-config-sample.php. Use a local fixture instead of
# cloning WordPress or writing a generated certificate into the shared proxy.
cat > "${TMP_ROOT}/wp-repo/wp-config-sample.php" <<'EOF'
<?php
define('DB_NAME', 'database_name_here');
define('DB_USER', 'username_here');
define('DB_PASSWORD', 'password_here');
define('DB_HOST', 'localhost');
define('AUTH_KEY', 'put your unique phrase here');
define('SECURE_AUTH_KEY', 'put your unique phrase here');
define('LOGGED_IN_KEY', 'put your unique phrase here');
define('NONCE_KEY', 'put your unique phrase here');
define('AUTH_SALT', 'put your unique phrase here');
define('SECURE_AUTH_SALT', 'put your unique phrase here');
define('LOGGED_IN_SALT', 'put your unique phrase here');
define('NONCE_SALT', 'put your unique phrase here');
$table_prefix = 'wp_';
require_once ABSPATH . 'wp-settings.php';
EOF
git -C "${TMP_ROOT}/wp-repo" init -q
git -C "${TMP_ROOT}/wp-repo" -c user.name='Docal QA' -c user.email='qa@example.invalid' add wp-config-sample.php
git -C "${TMP_ROOT}/wp-repo" -c user.name='Docal QA' -c user.email='qa@example.invalid' commit -qm 'synthetic WordPress config fixture'

cat > "${TMP_ROOT}/bin/mkcert" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-install" ]]; then exit 1; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -cert-file) printf 'synthetic certificate\n' > "$2"; shift 2 ;;
    -key-file) printf 'synthetic private key\n' > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
EOF
chmod 700 "${TMP_ROOT}/bin/mkcert"
export PATH="${TMP_ROOT}/bin:${PATH}"

printf 'testsite\n2G\nlatest\nlatest\nTest Site\nlocalhost\nadmin\nadmin@docal.com\n%s\nn\nn\n' \
  "${WP_REPO_URL}" > "${TMP_ROOT}/setup-input.txt"
if ! timeout 30 bash scripts/setup-wordpress.sh --skip-docker \
    < "${TMP_ROOT}/setup-input.txt" > "${TMP_ROOT}/setup.log" 2>&1; then
  cat "${TMP_ROOT}/setup.log"
fi

if [[ ! -f "${SITES_DIR}/testsite/wordpress/wp-config.php" ]]; then
  echo "FAIL: wp-config.php was not generated" >&2
  cat "${TMP_ROOT}/setup.log" >&2
  exit 1
fi

if ! grep -q "define.*DB_NAME" "${SITES_DIR}/testsite/wordpress/wp-config.php"; then
  echo "FAIL: wp-config.php does not contain DB credentials" >&2
  exit 1
fi

[[ -f "${PROXY_DIR}/certs/testsite.localhost.crt" ]]

echo "OK: wp-config.php generated with DB credentials"
