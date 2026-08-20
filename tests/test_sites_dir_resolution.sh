#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Run against an isolated fake checkout (its own scripts/ + empty sites/),
# never the real repo's sites/ — which may hold real, non-empty site data
# (this test broke against that once already; don't repeat the mistake).
FAKE_REPO="$(mktemp -d)"
mkdir -p "${FAKE_REPO}/scripts" "${FAKE_REPO}/sites"
cp "${REPO_DIR}/scripts/docal" "${REPO_DIR}/scripts/lib-config.sh" "${FAKE_REPO}/scripts/"
trap 'rm -rf "${FAKE_REPO}"' EXIT

# 1. Fresh install, no legacy sites/ contents -> defaults to ~/Sites and persists it.
TMP_HOME="$(mktemp -d)"
got="$(HOME="${TMP_HOME}" bash "${FAKE_REPO}/scripts/docal" config get sites_dir)"
rm -rf "${TMP_HOME}"
[[ "${got}" == "${TMP_HOME}/Sites" ]] || { echo "FAIL: default sites_dir expected ${TMP_HOME}/Sites, got '${got}'" >&2; exit 1; }

# 2. DOCAL_SITES_DIR env var wins and is never written to config.
TMP_HOME="$(mktemp -d)"
got="$(HOME="${TMP_HOME}" DOCAL_SITES_DIR=/tmp/docal-test-env-override bash "${FAKE_REPO}/scripts/docal" config get sites_dir)"
rm -rf "${TMP_HOME}"
[[ -z "${got}" ]] || { echo "FAIL: env override leaked into config: '${got}'" >&2; exit 1; }

# 3. A configured sites_dir is honored over the default.
TMP_HOME="$(mktemp -d)"
HOME="${TMP_HOME}" bash "${FAKE_REPO}/scripts/docal" config set sites_dir /tmp/docal-test-configured >/dev/null
got="$(HOME="${TMP_HOME}" bash "${FAKE_REPO}/scripts/docal" config get sites_dir)"
rm -rf "${TMP_HOME}"
[[ "${got}" == "/tmp/docal-test-configured" ]] || { echo "FAIL: configured sites_dir not honored, got '${got}'" >&2; exit 1; }

# 4. Legacy in-repo sites/ (old clone+symlink installs) is adopted once, not
#    silently replaced by a fresh empty ~/Sites.
TMP_HOME="$(mktemp -d)"
mkdir -p "${FAKE_REPO}/sites/legacy-site"
got="$(HOME="${TMP_HOME}" bash "${FAKE_REPO}/scripts/docal" config get sites_dir)"
rm -rf "${TMP_HOME}"
[[ "${got}" == "${FAKE_REPO}/sites" ]] || { echo "FAIL: legacy sites_dir expected ${FAKE_REPO}/sites, got '${got}'" >&2; exit 1; }

echo "OK: sites_dir resolution (default / env / config / legacy-fallback) behaves as documented"
