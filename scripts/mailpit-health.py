#!/usr/bin/env python3
"""Fail-closed operational check for Docal's local Mailpit service."""

from __future__ import annotations

import json
import socket
import subprocess
import sys
from urllib.error import URLError
from urllib.request import urlopen


CONTAINER = "docal-mailpit"
NETWORK = "docal-proxy"
HTTP_URL = "http://127.0.0.1:8025/api/v1/messages"
TIMEOUT = 2


def fail(message: str) -> int:
    print(f"[mailpit] {message}", file=sys.stderr)
    return 1


def check() -> int:
    try:
        result = subprocess.run(
            ["docker", "inspect", "--type", "container", CONTAINER],
            check=True,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
        data = json.loads(result.stdout)[0]
    except (subprocess.SubprocessError, OSError, ValueError, IndexError) as exc:
        return fail(f"cannot inspect {CONTAINER}: {exc}")

    if not data.get("State", {}).get("Running"):
        return fail(f"{CONTAINER} exists but is not running")

    network = data.get("NetworkSettings", {}).get("Networks", {}).get(NETWORK)
    if not network:
        return fail(f"{CONTAINER} is not connected to Docker network {NETWORK}")
    address = network.get("IPAddress")
    if not address:
        return fail(f"{CONTAINER} has no IPv4 address on {NETWORK}")
    aliases = network.get("Aliases") or []
    if CONTAINER not in aliases:
        return fail(f"{CONTAINER} is missing its {NETWORK} DNS alias")

    host_bindings = data.get("HostConfig", {}).get("PortBindings") or {}
    expected_http = [{"HostIp": "127.0.0.1", "HostPort": "8025"}]
    if host_bindings.get("8025/tcp") != expected_http:
        return fail("HTTP port must be published only as 127.0.0.1:8025")
    effective_ports = data.get("NetworkSettings", {}).get("Ports") or {}
    if effective_ports.get("8025/tcp") != expected_http:
        return fail("HTTP port 127.0.0.1:8025 is not effectively published")
    if host_bindings.get("1025/tcp") or effective_ports.get("1025/tcp"):
        return fail("SMTP port 1025 must not be published on the host")

    try:
        with urlopen(HTTP_URL, timeout=TIMEOUT) as response:
            if response.status != 200:
                return fail(f"Mailpit API returned HTTP {response.status}")
            payload = json.loads(response.read())
        if not isinstance(payload, dict) or not isinstance(payload.get("messages"), list):
            return fail("Mailpit API returned an unexpected JSON response")
    except (URLError, TimeoutError, OSError, ValueError) as exc:
        return fail(f"Mailpit API is not responding correctly: {exc}")

    try:
        with socket.create_connection((address, 1025), timeout=TIMEOUT):
            pass
    except OSError as exc:
        return fail(f"SMTP port 1025 is not reachable on {NETWORK}: {exc}")

    print("[mailpit] operational: running, connected, HTTP API and internal SMTP available")
    return 0


if __name__ == "__main__":
    sys.exit(check())
