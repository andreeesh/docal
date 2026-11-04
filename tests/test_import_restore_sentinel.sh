#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${ROOT}/scripts/lib-import-wpress.sh"
bash -n "${FILE}"
grep -Fq 'wp option add "${restore_marker}" pending --skip-plugins --skip-themes --allow-root' "${FILE}"
grep -Fq 'wp option get "${restore_marker}" --skip-plugins --skip-themes --allow-root' "${FILE}"
grep -Fq 'Restore did not replace the WordPress database' "${FILE}"
grep -Fq 'All-in-One WP Migration restore command failed' "${FILE}"
echo 'Import restore sentinel checks passed'
