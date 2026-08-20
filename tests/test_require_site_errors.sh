#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "${TMP_HOME}"' EXIT
export HOME="${TMP_HOME}"

set +e
out="$(scripts/docal info 2>&1)"
rc=$?
set -e
[[ ${rc} -ne 0 ]] || { echo "FAIL: 'docal info' with no site name should fail" >&2; exit 1; }
grep -q "Site name required" <<< "${out}" || { echo "FAIL: missing 'Site name required' message: ${out}" >&2; exit 1; }

set +e
out="$(scripts/docal info does-not-exist 2>&1)"
rc=$?
set -e
[[ ${rc} -ne 0 ]] || { echo "FAIL: 'docal info' on a nonexistent site should fail" >&2; exit 1; }
grep -q "not found" <<< "${out}" || { echo "FAIL: missing 'not found' message: ${out}" >&2; exit 1; }
grep -q "docal list" <<< "${out}" || { echo "FAIL: missing actionable 'docal list' suggestion: ${out}" >&2; exit 1; }

echo "OK: require_site produces actionable errors for a missing name and a nonexistent site"
