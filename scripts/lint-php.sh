#!/usr/bin/env bash
# Lint PHP files using the PHP CLI already present inside each site's WordPress
# container (matches that site's actual runtime version). No PHP install is
# needed on the WSL host.
#
# Usage:
#   scripts/lint-php.sh <site> [path ...]
#   scripts/lint-php.sh <site> --changed [subdir] [git-ref]
#     Lints .php files changed vs git-ref (default: main) in the git repo that
#     owns <subdir> (default: the site's wordpress root). Many plugins/themes
#     under sites/<site>/wordpress are their own nested git repos (e.g. a
#     plugin tracked on its own branch) rather than part of one repo for the
#     whole wordpress folder, so the repo is resolved from <subdir>, not
#     assumed to be at the wordpress root.
#
# Examples:
#   scripts/lint-php.sh myshop
#   scripts/lint-php.sh myshop wp-content/plugins/my-plugin/my-plugin.php
#   scripts/lint-php.sh myshop --changed wp-content/plugins/my-plugin main

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "Usage: $0 <site> [path ...] | $0 <site> --changed [git-ref]" >&2
  exit 1
}

[ $# -ge 1 ] || usage
SITE="$1"; shift

CONTAINER="docal-${SITE}-wp"
SITE_DIR="${BASE_DIR}/sites/${SITE}/wordpress"

if [ ! -d "${SITE_DIR}" ]; then
  echo "Error: no such site directory: ${SITE_DIR}" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  echo "Error: container '${CONTAINER}' is not running. Start the site (docker compose up -d) first." >&2
  exit 1
fi

declare -a FILES=()

if [ "${1:-}" = "--changed" ]; then
  SUBDIR="${2:-}"
  REF="${3:-main}"
  SCOPE_DIR="${SITE_DIR}"
  [ -n "${SUBDIR}" ] && SCOPE_DIR="${SITE_DIR}/${SUBDIR}"

  REPO_ROOT="$(git -C "${SCOPE_DIR}" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Error: '${SCOPE_DIR}' is not inside a git repo." >&2
    exit 1
  }
  REPO_PREFIX="${REPO_ROOT#${SITE_DIR}/}"
  [ "${REPO_PREFIX}" = "${REPO_ROOT}" ] && REPO_PREFIX=""  # repo root == SITE_DIR

  while IFS= read -r -d '' f; do
    rel="${REPO_PREFIX:+${REPO_PREFIX}/}${f}"
    [ -f "${SITE_DIR}/${rel}" ] && FILES+=("${rel}")
  done < <(git -C "${REPO_ROOT}" diff --name-only -z --diff-filter=d "${REF}" -- '*.php' 2>/dev/null || true)

  if [ ${#FILES[@]} -eq 0 ]; then
    echo "No changed .php files vs ${REF} in ${REPO_ROOT}."
    exit 0
  fi
else
  if [ $# -eq 0 ]; then
    while IFS= read -r -d '' f; do
      FILES+=("${f#${SITE_DIR}/}")
    done < <(find "${SITE_DIR}/wp-content/plugins" "${SITE_DIR}/wp-content/themes" \
              -type f -name '*.php' -print0 2>/dev/null)
  else
    for p in "$@"; do
      FILES+=("${p#${SITE_DIR}/}")
    done
  fi
fi

FAIL=0
COUNT=0
for f in "${FILES[@]}"; do
  COUNT=$((COUNT + 1))
  OUT="$(docker exec "${CONTAINER}" php -l "/var/www/html/${f}" 2>&1)" || {
    FAIL=1
    echo "✗ ${f}"
    echo "${OUT}" | sed 's/^/    /'
    continue
  }
done

echo "---"
if [ "${FAIL}" -eq 0 ]; then
  echo "✓ ${COUNT} file(s) linted clean (php -l via ${CONTAINER})"
else
  echo "Lint errors found (php -l via ${CONTAINER})"
  exit 1
fi
