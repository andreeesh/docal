#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROXY_DIR="${PROXY_DIR:-${BASE_DIR}/proxy}"
mkdir -p "${PROXY_DIR}"

mkdir -p "${PROXY_DIR}/certs"

cat > "${PROXY_DIR}/docker-compose.yml" <<'EOF'
services:
  traefik:
    image: traefik:v3.7
    container_name: docal-traefik
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.file.directory=/certs
      - --providers.file.watch=true
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.web.transport.respondingTimeouts.readTimeout=0s
      - --entrypoints.web.transport.respondingTimeouts.writeTimeout=0s
      - --entrypoints.web.transport.respondingTimeouts.idleTimeout=0s
      - --entrypoints.websecure.address=:443
      - --entrypoints.websecure.transport.respondingTimeouts.readTimeout=0s
      - --entrypoints.websecure.transport.respondingTimeouts.writeTimeout=0s
      - --entrypoints.websecure.transport.respondingTimeouts.idleTimeout=0s
      - --api.dashboard=true
      - --api.insecure=true
    ports:
      - "127.0.0.1:80:80"
      - "127.0.0.1:443:443"
      - "127.0.0.1:8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./certs:/certs:ro
    networks:
      - docal-proxy

  # Shared SMTP sink for LOCAL development, never a delivery relay.
  # The SMTP port (1025) is reachable only by containers on docal-proxy.
  mailpit:
    image: axllent/mailpit:v1.31.6
    container_name: docal-mailpit
    restart: unless-stopped
    environment:
      MP_MAX_MESSAGES: "500"
      MP_MAX_AGE: "7d"
      MP_DISABLE_VERSION_CHECK: "true"
    ports:
      - "127.0.0.1:8025:8025"
    labels:
      - traefik.enable=false
    networks:
      - docal-proxy
networks:
  docal-proxy:
    external: true
EOF

if ! docker network inspect docal-proxy >/dev/null 2>&1; then
  docker network create docal-proxy >/dev/null 2>&1 || true
fi

cd "${PROXY_DIR}"
# Do not reconcile or recreate a running Traefik container just to start
# Mailpit. If Traefik is absent or stopped, bring it up as usual.
if ! docker inspect --format '{{.State.Running}}' docal-traefik 2>/dev/null | grep -qx true; then
  docker compose up -d traefik
fi

if docker compose up -d mailpit; then
  echo "[ok] Mailpit inbox at http://localhost:8025"
else
  echo "[warn] Mailpit could not start (check loopback port 8025); Traefik remains running." >&2
fi

echo "[ok] Traefik proxy running at http://localhost:8080"
