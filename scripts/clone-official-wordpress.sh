#!/usr/bin/env bash

set -euo pipefail

TARGET_DIR="${1:-${PWD}/wordpress}"
OFFICIAL_REPO="https://github.com/WordPress/WordPress.git"
REPO_URL="${WP_REPO_URL:-${OFFICIAL_REPO}}"

if [[ -d "${TARGET_DIR}/.git" ]]; then
  echo "[info] Repository already exists at ${TARGET_DIR}."
  exit 0
fi

mkdir -p "$(dirname "${TARGET_DIR}")"

if ! command -v git >/dev/null 2>&1; then
  echo "[error] git is not installed. Install it to clone WordPress." >&2
  exit 1
fi

echo "[info] Cloning ${REPO_URL} into ${TARGET_DIR}..."
if [[ "${REPO_URL}" == "${OFFICIAL_REPO}" ]]; then
  git clone --depth 1 --branch master "${REPO_URL}" "${TARGET_DIR}"
else
  git clone "${REPO_URL}" "${TARGET_DIR}"
fi

echo "[ok] Repository ready at ${TARGET_DIR}"
