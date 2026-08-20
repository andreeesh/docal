#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "${TMP_HOME}"' EXIT
export HOME="${TMP_HOME}"

actual="$(scripts/docal version)"
expected="Docal $(tr -d '[:space:]' < VERSION)"

if [[ "${actual}" != "${expected}" ]]; then
  echo "FAIL: expected '${expected}', got '${actual}'" >&2
  exit 1
fi

echo "OK: docal version matches the VERSION file"
