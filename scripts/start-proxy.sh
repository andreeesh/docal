#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROXY_DIR="${BASE_DIR}/proxy"
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
      - "80:80"
      - "443:443"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./certs:/certs:ro
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
docker compose up -d --build

echo "[ok] Traefik proxy running at http://localhost:8080"
