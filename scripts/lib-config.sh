#!/usr/bin/env bash
# Global config for docal itself, kept separate from any site.
#
# Lives at $DOCAL_CONFIG (default: ~/.docal/config), a flat KEY=value file —
# no YAML/JSON dependency needed. Sourced by scripts/docal, which must already
# have DOCAL_HOME, DOCAL_CONFIG, DOCAL_DIR set and info()/warn()/err() defined.

DOCAL_CONFIG_KEYS=(sites_dir default_php default_mysql default_domain admin_user admin_email default_upload_limit)

config_known_key() {
  local key="$1" known
  for known in "${DOCAL_CONFIG_KEYS[@]}"; do
    [[ "${key}" == "${known}" ]] && return 0
  done
  return 1
}

ensure_docal_home() {
  mkdir -p "${DOCAL_HOME}" "${DOCAL_HOME}/proxy" "${DOCAL_HOME}/proxy/certs"
  touch "${DOCAL_CONFIG}"
}

config_get() {
  local key="$1"
  [[ -f "${DOCAL_CONFIG}" ]] || return 0
  grep -E "^${key}=" "${DOCAL_CONFIG}" 2>/dev/null | tail -n1 | cut -d= -f2-
}

config_set() {
  local key="$1" value="$2"
  config_known_key "${key}" || err "Unknown config key: ${key}\n\nKnown keys: ${DOCAL_CONFIG_KEYS[*]}"
  ensure_docal_home
  if grep -qE "^${key}=" "${DOCAL_CONFIG}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${DOCAL_CONFIG}"
  else
    echo "${key}=${value}" >> "${DOCAL_CONFIG}"
  fi
}

config_all() {
  [[ -f "${DOCAL_CONFIG}" ]] || return 0
  local key val
  for key in "${DOCAL_CONFIG_KEYS[@]}"; do
    val="$(config_get "${key}")"
    [[ -n "${val}" ]] && echo "${key}=${val}"
  done
}

# Precedence: $DOCAL_SITES_DIR env > config `sites_dir` > legacy in-repo sites/
# (adopted once, for pre-existing clone+symlink installs) > default ~/Sites.
# The chosen default (legacy or ~/Sites) is persisted to config so this only
# resolves once — later calls just read the config value.
resolve_sites_dir() {
  if [[ -n "${DOCAL_SITES_DIR:-}" ]]; then
    echo "${DOCAL_SITES_DIR}"
    return 0
  fi

  local configured
  configured="$(config_get sites_dir)"
  if [[ -n "${configured}" ]]; then
    echo "${configured}"
    return 0
  fi

  local chosen="${HOME}/Sites"
  if [[ ! -f "${DOCAL_CONFIG}" ]] && [[ -d "${DOCAL_DIR}/sites" ]] \
     && find "${DOCAL_DIR}/sites" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .; then
    chosen="${DOCAL_DIR}/sites"
    echo "[docal] Existing sites found in ${chosen} — using it as your sites directory." >&2
    echo "[docal] Change it any time with: docal config set sites_dir <path>" >&2
  fi

  config_set sites_dir "${chosen}"
  echo "${chosen}"
}
