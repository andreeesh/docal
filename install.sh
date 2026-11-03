#!/usr/bin/env bash
# Docal installer.
#
#   curl -fsSL https://raw.githubusercontent.com/andreeesh/docal/main/install.sh | bash
#
# Idempotent: safe to re-run. Clones (or fast-forward updates) docal into
# ~/.docal/repo and symlinks the `docal` command onto PATH. Never touches
# existing sites — those live wherever DOCAL_SITES_DIR / `docal config` points,
# resolved the first time `docal` itself runs (see scripts/lib-config.sh).

set -euo pipefail

REPO_URL="${DOCAL_REPO_URL:-https://github.com/andreeesh/docal.git}"
DOCAL_HOME="${DOCAL_HOME:-$HOME/.docal}"
DOCAL_REPO_DIR="${DOCAL_HOME}/repo"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[install]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*" >&2; }
die()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

command -v git  >/dev/null 2>&1 || die "git is required. Install it first: sudo apt-get install -y git"
command -v curl >/dev/null 2>&1 || die "curl is required. Install it first: sudo apt-get install -y curl"

if grep -qi microsoft /proc/version 2>/dev/null; then
  ok "WSL2 detected"
else
  warn "WSL2 not detected — docal targets WSL2. Continuing anyway, but you're off the tested path."
fi

if [[ -f /etc/os-release ]]; then
  DISTRO_NAME="$(. /etc/os-release && echo "${PRETTY_NAME:-${NAME:-unknown}}")"
  info "Distro: ${DISTRO_NAME}"
  if ! (. /etc/os-release && [[ "${ID_LIKE:-}${ID:-}" == *debian* || "${ID_LIKE:-}${ID:-}" == *ubuntu* ]]); then
    warn "This doesn't look like a Debian/Ubuntu-based distro. Docal's Docker-install step assumes apt; you may need to install Docker Engine yourself."
  fi
fi

mkdir -p "${DOCAL_HOME}"

if [[ -d "${DOCAL_REPO_DIR}/.git" ]]; then
  info "Existing install found at ${DOCAL_REPO_DIR} — updating..."
  if ! git -C "${DOCAL_REPO_DIR}" diff --quiet || ! git -C "${DOCAL_REPO_DIR}" diff --cached --quiet; then
    die "Local changes found in ${DOCAL_REPO_DIR} — refusing to overwrite. Commit/stash them, or remove that directory and re-run this installer."
  fi
  CURRENT_BRANCH="$(git -C "${DOCAL_REPO_DIR}" symbolic-ref --quiet --short HEAD || true)"
  [[ "${CURRENT_BRANCH}" == "main" ]] || die "Existing checkout is on '${CURRENT_BRANCH:-detached HEAD}', not main. Refusing to update it automatically."
  if [[ -n "$(git -C "${DOCAL_REPO_DIR}" ls-files --others --exclude-standard)" ]]; then
    die "Untracked files found in ${DOCAL_REPO_DIR}. Review them before updating."
  fi
  git -C "${DOCAL_REPO_DIR}" pull --ff-only || die "Update failed. Inspect it with: git -C ${DOCAL_REPO_DIR} status"
else
  info "Cloning docal into ${DOCAL_REPO_DIR}..."
  git clone --depth 1 "${REPO_URL}" "${DOCAL_REPO_DIR}"
fi

DOCAL_BIN="${DOCAL_REPO_DIR}/scripts/docal"
chmod +x "${DOCAL_BIN}" "${DOCAL_REPO_DIR}"/scripts/*.sh 2>/dev/null || true

# Never overwrite an unrelated executable or symlink.
safe_link() {
  local target="$1" existing
  if [[ -e "${target}" || -L "${target}" ]]; then
    existing="$(readlink -f -- "${target}" 2>/dev/null || true)"
    [[ "${existing}" == "${DOCAL_BIN}" ]] || return 1
  fi
  ln -sfn -- "${DOCAL_BIN}" "${target}"
}

INSTALLED=0
if [[ ! -e /usr/local/bin/docal && ! -L /usr/local/bin/docal ]] || \
   [[ "$(readlink -f /usr/local/bin/docal 2>/dev/null || true)" == "${DOCAL_BIN}" ]]; then
  if safe_link /usr/local/bin/docal 2>/dev/null || \
     sudo -n bash -c 'target="$1"; link="$2"; if [[ ! -e "$link" && ! -L "$link" ]] || [[ "$(readlink -f "$link" 2>/dev/null || true)" == "$target" ]]; then ln -sfn -- "$target" "$link"; else exit 1; fi' _ "${DOCAL_BIN}" /usr/local/bin/docal 2>/dev/null; then
    ok "docal linked at /usr/local/bin/docal"
    INSTALLED=1
  fi
fi

if [[ "${INSTALLED}" -eq 0 ]]; then
  mkdir -p "${HOME}/.local/bin"
  safe_link "${HOME}/.local/bin/docal" || die "Existing command at ~/.local/bin/docal points elsewhere. Refusing to overwrite it."
  ok "docal linked at ${HOME}/.local/bin/docal"
  case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) INSTALLED=1 ;;
    *) warn "${HOME}/.local/bin is not on your PATH. Add this to your shell profile:"
       echo ""
       echo "    export PATH=\"\\$HOME/.local/bin:\\$PATH\""
       echo ""
       ;;
  esac
fi

mkdir -p "${DOCAL_HOME}/proxy/certs"
touch "${DOCAL_HOME}/config"

echo ""
ok "Docal installed."
echo ""
echo "  Next steps:"
echo ""
echo "    docal doctor"
echo "    docal create mysite"
echo ""
if [[ "${INSTALLED}" -eq 0 ]]; then
  info "Once docal is on your PATH, run: docal doctor"
fi
