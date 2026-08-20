#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "${TMP_HOME}"' EXIT
export HOME="${TMP_HOME}"

scripts/docal config set default_php 8.3 >/dev/null
got="$(scripts/docal config get default_php)"
[[ "${got}" == "8.3" ]] || { echo "FAIL: expected 8.3, got '${got}'" >&2; exit 1; }

# Setting an existing key again overwrites in place instead of duplicating it.
scripts/docal config set default_php 8.2 >/dev/null
got="$(scripts/docal config get default_php)"
[[ "${got}" == "8.2" ]] || { echo "FAIL: update did not overwrite the existing key, got '${got}'" >&2; exit 1; }

lines="$(grep -c '^default_php=' "${TMP_HOME}/.docal/config")"
[[ "${lines}" -eq 1 ]] || { echo "FAIL: expected exactly one default_php line, found ${lines}" >&2; exit 1; }

set +e
scripts/docal config set bogus_key value >/dev/null 2>&1
rc=$?
set -e
[[ ${rc} -ne 0 ]] || { echo "FAIL: setting an unknown config key should fail" >&2; exit 1; }

echo "OK: docal config get/set round-trips and rejects unknown keys"
