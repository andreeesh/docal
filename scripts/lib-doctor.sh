#!/usr/bin/env bash
# `docal doctor` — environment diagnostics.
#
# Sourced by scripts/docal (cmd_doctor), so ok()/warn()/err()/info(),
# docker_is_native(), DOCAL_HOME, PROXY_DIR and SITES_DIR are already
# available. Kept in its own file so checks can be unit-tested individually
# without a real Docker daemon (see tests/test_doctor_smoke.sh).

DOCTOR_FIX=0
DOCTOR_FAILED=0

doctor_check() {
  local label="$1" ok_cond="$2" fix_hint="${3:-}"
  if eval "${ok_cond}"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    return 0
  fi
  echo -e "  ${RED}✗${NC} ${label}"
  if [[ -n "${fix_hint}" ]]; then
    echo -e "    Fix:"
    echo -e "      ${fix_hint}"
  fi
  DOCTOR_FAILED=1
  return 1
}

doctor_is_wsl2() {
  grep -qi microsoft /proc/version 2>/dev/null
}

doctor_check_wsl2() {
  if doctor_is_wsl2; then
    echo -e "  ${GREEN}✓${NC} WSL2 detected"
  else
    echo -e "  ${YELLOW}!${NC} WSL2 not detected — docal targets WSL2; other Linux environments are untested."
  fi
}

doctor_check_distro() {
  if [[ -f /etc/os-release ]]; then
    local name; name="$(. /etc/os-release && echo "${PRETTY_NAME:-${NAME:-unknown}}")"
    echo -e "  ${GREEN}✓${NC} ${name}"
  else
    echo -e "  ${YELLOW}!${NC} Could not read /etc/os-release"
  fi
}

doctor_check_systemd() {
  doctor_check "systemd running" '[[ -d /run/systemd/system ]]' \
    "Add 'systemd=true' under [boot] in /etc/wsl.conf, then run 'wsl --shutdown' from Windows."
}

doctor_check_docker_engine() {
  doctor_check "Docker Engine installed (native, not Docker Desktop)" 'docker_is_native' \
    "docal doctor --fix   # or see: docal help"
}

doctor_check_docker_daemon() {
  doctor_check "Docker daemon running" 'docker info >/dev/null 2>&1' \
    "sudo systemctl start docker"
}

doctor_check_docker_group() {
  doctor_check "User in the docker group" 'id -nG "${USER}" | grep -qw docker' \
    "sudo usermod -aG docker \"\$USER\"   # then open a new terminal"
}

doctor_check_compose() {
  doctor_check "Docker Compose v2 available" 'docker compose version >/dev/null 2>&1' \
    "sudo apt-get install -y docker-compose-plugin"
}

doctor_check_mkcert() {
  doctor_check "mkcert installed" 'command -v mkcert >/dev/null 2>&1' \
    "See https://github.com/FiloSottile/mkcert#installation"
}

doctor_check_mkcert_ca() {
  if ! command -v mkcert >/dev/null 2>&1; then
    return 0
  fi
  local caroot; caroot="$(mkcert -CAROOT 2>/dev/null)"
  doctor_check "Local CA installed" '[[ -n "${caroot}" && -f "${caroot}/rootCA.pem" ]]' \
    "mkcert -install"
}

doctor_check_curl() {
  doctor_check "curl installed" 'command -v curl >/dev/null 2>&1' "sudo apt-get install -y curl"
}

doctor_check_git() {
  doctor_check "git installed" 'command -v git >/dev/null 2>&1' "sudo apt-get install -y git"
}

doctor_check_ports() {
  local busy=()
  local port
  for port in 80 443 8080; do
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${port} "; then
      if ! docker ps --filter "name=docal-traefik" --format '{{.Names}}' 2>/dev/null | grep -q docal-traefik; then
        busy+=("${port}")
      fi
    fi
  done
  doctor_check "Ports 80/443/8080 available" '[[ ${#busy[@]} -eq 0 ]]' \
    "Something else is using port(s) ${busy[*]:-}. Stop it or free the port before starting docal's proxy."
}

doctor_check_traefik() {
  if docker ps --filter "name=docal-traefik" --format '{{.Names}}' 2>/dev/null | grep -q docal-traefik; then
    echo -e "  ${GREEN}✓${NC} Traefik proxy running"
  else
    echo -e "  ${YELLOW}!${NC} Traefik proxy not running (starts automatically on 'docal create'/'docal start')"
  fi
}

doctor_check_sites_dir() {
  doctor_check "Sites directory writable (${SITES_DIR})" \
    'mkdir -p "${SITES_DIR}" 2>/dev/null && [[ -w "${SITES_DIR}" ]]'
}

doctor_apply_fixes() {
  info "Applying safe, idempotent fixes..."
  if ! docker_is_native; then
    install_docker_engine
    hash -r
  fi
  docker info >/dev/null 2>&1 || start_docker_daemon || true
  command -v mkcert >/dev/null 2>&1 && mkcert -install 2>/dev/null || true
}

doctor_run() {
  local arg
  for arg in "$@"; do
    [[ "${arg}" == "--fix" ]] && DOCTOR_FIX=1
  done

  if [[ "${DOCTOR_FIX}" -eq 1 ]]; then
    doctor_apply_fixes
    echo ""
  fi

  echo ""
  echo -e "  ${BOLD}${CYAN}Docal Doctor${NC}"
  echo ""
  doctor_check_wsl2 || true
  doctor_check_distro || true
  doctor_check_systemd || true
  doctor_check_docker_engine || true
  doctor_check_docker_daemon || true
  doctor_check_docker_group || true
  doctor_check_compose || true
  doctor_check_mkcert || true
  doctor_check_mkcert_ca || true
  doctor_check_curl || true
  doctor_check_git || true
  doctor_check_ports || true
  doctor_check_traefik || true
  doctor_check_sites_dir || true
  echo ""

  if [[ "${DOCTOR_FAILED}" -eq 0 ]]; then
    ok "Everything looks good."
  else
    warn "Some checks failed. Fix the items above, or try: docal doctor --fix"
    return 1
  fi
}
