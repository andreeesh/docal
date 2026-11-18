#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 "$ROOT/tests/test_mailpit_health.py"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/sites"
cat > "$tmp/bin/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
if [[ "$1" == info ]]; then exit 0; fi
if [[ "$1" == network && "$2" == inspect ]]; then exit 0; fi
if [[ "$1" == inspect && "$*" == *docal-traefik* ]]; then echo true; exit 0; fi
if [[ "$1" == compose && "$2" == up && "${*: -1}" == mailpit ]]; then
  if [[ "${MOCK_COMPOSE_MAILPIT_EXIT:-0}" != 0 ]]; then
    echo 'simulated port 8025 bind failure' >&2
    exit "$MOCK_COMPOSE_MAILPIT_EXIT"
  fi
  exit 0
fi
if [[ "$1" == compose && "$2" == up && "${*: -1}" == traefik ]]; then exit 0; fi
echo "Unexpected Docker call: $*" >&2
exit 90
MOCK_DOCKER
cat > "$tmp/bin/python3" <<'MOCK_PYTHON'
#!/usr/bin/env bash
if [[ "${1:-}" == *mailpit-health.py ]]; then
  echo "${MOCK_HEALTH_MESSAGE:-mock operational probe failed}"
  exit "${MOCK_HEALTH_EXIT:-0}"
fi
exec "$REAL_PYTHON3" "$@"
MOCK_PYTHON
cat > "$tmp/bin/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
exit 0
MOCK_SLEEP
chmod +x "$tmp/bin/docker" "$tmp/bin/python3" "$tmp/bin/sleep"

export DOCAL_HOME="$tmp/home"
export DOCAL_SITES_DIR="$tmp/sites"
REAL_PYTHON3="$(command -v python3)"
export PATH="$tmp/bin:$PATH"
export REAL_PYTHON3
export MOCK_DOCKER_LOG="$tmp/docker.log"

output="$(MOCK_HEALTH_EXIT=0 "$ROOT/scripts/docal" mail start 2>&1)"
[[ "$output" == *"Mailpit inbox:"* ]] || {
  echo "Healthy mocked start did not report success: $output" >&2
  exit 1
}
if grep -q 'compose up -d traefik' "$MOCK_DOCKER_LOG"; then
  echo "Mailpit start unnecessarily reconciled running Traefik" >&2
  exit 1
fi

: > "$MOCK_DOCKER_LOG"
set +e
output="$(MOCK_HEALTH_EXIT=1 MOCK_HEALTH_MESSAGE='SMTP unreachable' \
  MOCK_COMPOSE_MAILPIT_EXIT=1 "$ROOT/scripts/docal" mail start 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 && "$output" != *"Mailpit inbox:"* && "$output" == *"SMTP unreachable"* ]] || {
  echo "Failed Compose start produced a false success or poor diagnostic: rc=$rc output=$output" >&2
  exit 1
}

set +e
output="$(MOCK_HEALTH_EXIT=1 MOCK_HEALTH_MESSAGE='not connected to docal-proxy' \
  "$ROOT/scripts/docal" mail status 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 && "$output" == *"not connected to docal-proxy"* && "$output" != *"Mailpit running at"* ]] || {
  echo "Unhealthy status produced a false success: rc=$rc output=$output" >&2
  exit 1
}

output="$(MOCK_HEALTH_EXIT=0 "$ROOT/scripts/docal" mail status 2>&1)"
[[ "$output" == *"Mailpit running at"* ]] || {
  echo "Healthy status did not report success: $output" >&2
  exit 1
}

echo "Mailpit CLI start/status fail closed on mocked operational failures"
