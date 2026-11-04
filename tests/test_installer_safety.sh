#!/usr/bin/env bash
# Regression tests for installer link safety. No global paths are modified.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/install.sh"
bash -n "${INSTALLER}"

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT
DOCAL_BIN="${TMP}/repo/scripts/docal"
mkdir -p "${TMP}/repo/scripts" "${TMP}/bin"
printf '#!/bin/sh\n' > "${DOCAL_BIN}"

# Source only the installer helper; never run installation.
helper="$(sed -n '/^safe_link() {/,/^}/p' "${INSTALLER}")"
[[ -n "${helper}" ]] || { echo 'safe_link missing'; exit 1; }
eval "${helper}"

safe_link "${TMP}/bin/docal"
[[ "$(readlink -f "${TMP}/bin/docal")" == "${DOCAL_BIN}" ]]
safe_link "${TMP}/bin/docal"  # idempotent

printf '#!/bin/sh\n' > "${TMP}/other"
ln -s "${TMP}/other" "${TMP}/bin/foreign"
if safe_link "${TMP}/bin/foreign"; then
  echo 'Installer overwrote unrelated symlink' >&2
  exit 1
fi
[[ "$(readlink -f "${TMP}/bin/foreign")" == "${TMP}/other" ]]

printf 'unrelated executable\n' > "${TMP}/bin/existing"
if safe_link "${TMP}/bin/existing"; then
  echo 'Installer overwrote unrelated file' >&2
  exit 1
fi
grep -qx 'unrelated executable' "${TMP}/bin/existing"

echo 'Installer link safety tests passed'
