#!/usr/bin/env bash
# Static regression check: imported local admin must have administrator role.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${ROOT}/scripts/lib-import-wpress.sh"
bash -n "${FILE}"
grep -Fq 'wp user update "${admin_user}" --role=administrator --user_pass="${import_admin_password}"' "${FILE}"
grep -Fq 'wp user create "${admin_user}" "${ADMIN_EMAIL}" --role=administrator' "${FILE}"
echo 'Import administrator role regression checks passed'
