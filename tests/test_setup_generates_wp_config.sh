#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."
rm -rf sites/testsite

if ! timeout 180 bash -lc 'printf "testsite\n2G\nlatest\nlatest\nTest Site\nlocalhost\nadmin@docal.com\n\n\n\n" | bash scripts/setup-wordpress.sh --skip-docker' > /tmp/docal-setup-test.log 2>&1; then
  cat /tmp/docal-setup-test.log
fi

if [[ ! -f sites/testsite/wordpress/wp-config.php ]]; then
  echo "FAIL: wp-config.php was not generated" >&2
  cat /tmp/docal-setup-test.log >&2
  exit 1
fi

if ! grep -q "define.*DB_NAME" sites/testsite/wordpress/wp-config.php; then
  echo "FAIL: wp-config.php does not contain DB credentials" >&2
  exit 1
fi

echo "OK: wp-config.php generated with DB credentials"
