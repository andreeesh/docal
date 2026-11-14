#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib-import-sql.sh"

temp_root="$(mktemp -d)"
trap 'rm -rf -- "${temp_root}"' EXIT

SITE_DIR="${temp_root}/disposable-site"
DB_NAME="wp_disposable"
DB_USER="wp_disposable"
DB_PASSWORD="test-local-secret"
MOCK_CAPTURE="${temp_root}/import-capture.sql"
MOCK_IMPORTED="${temp_root}/imported"
MOCK_FAIL_IMPORT=0
MOCK_FORCE_NONEMPTY=0

mkdir -p "${SITE_DIR}"
touch "${SITE_DIR}/docker-compose.yml" "${SITE_DIR}/.env"
sql_file="${temp_root}/staged.sql"
printf 'CREATE TABLE wp_options (id INT);\n' > "${sql_file}"

docker() {
  local args="$*"
  # All SQL operations must use the scoped WordPress DB account.
  [[ "${args}" == *"-u ${DB_USER}"* && "${args}" != *"-u root"* ]] || return 1
  if [[ "${args}" == *"SELECT COUNT("* ]]; then
    if [[ "${MOCK_FORCE_NONEMPTY}" -eq 1 || -f "${MOCK_IMPORTED}" ]]; then
      printf '12\n'
    else
      printf '0\n'
    fi
  elif [[ "${args}" == *"--binary-mode"* ]]; then
    cat > "${MOCK_CAPTURE}"
    [[ "${MOCK_FAIL_IMPORT}" -eq 0 ]] || return 1
    touch "${MOCK_IMPORTED}"
  else
    return 1
  fi
}

# No marker: absolutely no DB calls.
if docal_import_staged_sql_new_site "${sql_file}" >/dev/null 2>&1; then
  echo "Unmarked site was accepted" >&2
  exit 1
fi
[[ ! -f "${MOCK_CAPTURE}" ]]

touch "${SITE_DIR}/.docal-import-pending"
MOCK_FORCE_NONEMPTY=1
if docal_import_staged_sql_new_site "${sql_file}" >/dev/null 2>&1; then
  echo "Nonempty database was accepted" >&2
  exit 1
fi
[[ ! -f "${MOCK_CAPTURE}" ]]

MOCK_FORCE_NONEMPTY=0
MOCK_FAIL_IMPORT=1
if docal_import_staged_sql_new_site "${sql_file}" >/dev/null 2>&1; then
  echo "Failed SQL command was incorrectly reported as success" >&2
  exit 1
fi
[[ ! -f "${MOCK_IMPORTED}" ]]

MOCK_FAIL_IMPORT=0
docal_import_staged_sql_new_site "${sql_file}" > "${temp_root}/output"
cmp "${sql_file}" "${MOCK_CAPTURE}"
grep -q '12 tables' "${temp_root}/output"

# Import cannot be repeated against a populated database.
if docal_import_staged_sql_new_site "${sql_file}" >/dev/null 2>&1; then
  echo "Second import into populated database was accepted" >&2
  exit 1
fi

echo "Guarded SQL loader tests passed"
