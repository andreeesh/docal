#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "${TMP_HOME}"' EXIT
export HOME="${TMP_HOME}"

set +e
out="$(scripts/docal doctor 2>&1)"
rc=$?
set -e

grep -q "Docal Doctor" <<< "${out}" || { echo "FAIL: doctor output missing header: ${out}" >&2; exit 1; }
grep -q "Sites directory writable" <<< "${out}" || { echo "FAIL: doctor missing sites_dir check: ${out}" >&2; exit 1; }
[[ ${rc} -eq 0 || ${rc} -eq 1 ]] || { echo "FAIL: doctor exited with unexpected code ${rc}: ${out}" >&2; exit 1; }

echo "OK: docal doctor runs end-to-end and reports structured checks"
