#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${ROOT}/scripts/lib-import-wpress.sh"
bash -n "${FILE}"
grep -Fq 'wp plugin is-installed all-in-one-wp-migration --allow-root' "${FILE}"
grep -Fq 'wp plugin is-active all-in-one-wp-migration --allow-root' "${FILE}"
grep -Fq 'wp plugin activate all-in-one-wp-migration --allow-root' "${FILE}"
grep -Fq 'wp plugin install all-in-one-wp-migration --activate --force --allow-root' "${FILE}"
echo 'Existing migration plugin offline-install regression checks passed'
