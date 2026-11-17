#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT/scripts/safe-start.py" <<'PY'
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("safe_start", sys.argv[1])
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


def make_site(root):
    site = root / "safe-fixture"
    wp = site / "wordpress"
    wp.mkdir(parents=True)
    (site / "docker-compose.yml").write_text("services:\n  db:\n    image: mysql:8\n")
    (site / ".env").write_text("SITE_SLUG=safe-fixture\nSITE_DOMAIN=localhost\n")
    (wp / "wp-config.php").write_text(
        "<?php\n"
        "defined( 'WP_HOME' ) || define( 'WP_HOME', 'https://safe-fixture.localhost' );\n"
        "defined( 'WP_SITEURL' ) || define( 'WP_SITEURL', 'https://safe-fixture.localhost' );\n"
        "require_once ABSPATH . 'wp-settings.php';\n"
    )
    plugins = wp / "wp-content" / "plugins"
    plugins.mkdir(parents=True)
    (plugins / "untrusted.php").write_text("<?php // no execute")
    mu = wp / "wp-content" / "mu-plugins"
    mu.mkdir()
    (mu / "untrusted.php").write_text("<?php // no execute")
    (wp / "wp-content" / "object-cache.php").write_text("<?php // drop-in")
    theme = wp / "wp-content" / "themes"
    theme.mkdir()
    (theme / "style.css").write_text("/* theme */")
    certs = root / "proxy" / "certs"
    certs.mkdir(parents=True)
    (certs / "safe-fixture.localhost.crt").write_text("fixture cert")
    (certs / "safe-fixture.localhost.key").write_text("fixture key")
    return site, root / "proxy"


with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    site, proxy = make_site(root)
    original_config = (site / "wordpress/wp-config.php").read_bytes()
    runtime = site / s.SAFE_DIR_NAME
    commands = []
    created_networks = set()
    def fake_invoke(args, *, cwd=None, capture=False, check=True):
        commands.append(tuple(args))
        if args[0] == "rsync":
            src, dst = Path(args[-2]), Path(args[-1])
            shutil.copytree(
                src, dst, dirs_exist_ok=True,
                ignore=lambda directory, entries: [
                    item for item in entries
                    if item == ".git" or (
                        Path(directory).name == "wp-content" and
                        item in ("plugins", "mu-plugins", "object-cache.php")
                    )
                ],
            )
        if args[:4] == ["docker", "compose", "ps", "--status"]:
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if args[:3] == ["docker", "network", "create"]:
            created_networks.add(args[-1])
        if args[:3] == ["docker", "network", "rm"]:
            created_networks.discard(args[-1])
        if args[:3] == ["docker", "network", "inspect"]:
            edge = args[3].endswith("-safe-edge")
            return SimpleNamespace(returncode=0, stdout=json.dumps({
                "Driver": "bridge",
                "Internal": not edge,
                "EnableIPv6": False,
                "Options": {"com.docker.network.bridge.enable_ip_masquerade": "false"} if edge else {},
                "Containers": {},
                "Labels": {"docal.safe.site": "safe-fixture"},
            }), stderr="")
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    old_invoke, old_exists = s.invoke, s.resource_exists
    old_which, old_probe = s.shutil.which, s.probe_network
    try:
        s.invoke = fake_invoke
        s.resource_exists = lambda kind, name: (
            kind == "image" or (kind == "network" and name in created_networks)
        )
        s.shutil.which = lambda _name: "/usr/bin/rsync"
        s.probe_network = lambda *_args: None
        s.safe_start(site, proxy, 9443)

        assert (runtime / "wordpress/wp-config.php").exists()
        assert not list((runtime / "wordpress/wp-content/plugins").iterdir())
        assert not list((runtime / "wordpress/wp-content/mu-plugins").iterdir())
        assert not (runtime / "wordpress/wp-content/object-cache.php").exists()
        assert (runtime / "wordpress/wp-content/themes/style.css").exists()
        copy = (runtime / "wordpress/wp-config.php").read_text()
        assert "https://safe-fixture.localhost:9443" in copy
        assert "DISABLE_WP_CRON" in copy
        assert "WP_HTTP_BLOCK_EXTERNAL" in copy
        assert "DISALLOW_FILE_MODS" in copy
        assert "AUTOMATIC_UPDATER_DISABLED" in copy
        assert "sendmail_path = /bin/false" in (runtime / "safe.ini").read_text()
        assert "Require all denied" in (runtime / "safe-apache.conf").read_text()
        assert (runtime / "resolv.conf").read_text() == "nameserver 127.0.0.1\n"
        compose = json.loads((runtime / "compose.safe.yml").read_text())
        assert compose["services"]["safe-web"]["networks"] == ["docal-safe-internal"]
        assert compose["services"]["safe-tls"]["networks"] == [
            "safe-tls-edge", "docal-safe-internal",
        ]
        assert compose["services"]["safe-web"]["read_only"] is True
        assert compose["services"]["safe-tls"]["ports"][0]["host_ip"] == "127.0.0.1"
        assert compose["services"]["safe-tls"]["ports"][0]["published"] == "9443"
        assert "wordpress" not in compose["services"]
        assert compose["networks"]["safe-tls-edge"]["name"] == "docal-safe-fixture-safe-edge"
        assert any(
            any("enable_ip_masquerade=false" in part for part in command)
            for command in commands if command[:3] == ("docker", "network", "create")
        )
        assert (site / "wordpress/wp-config.php").read_bytes() == original_config
        assert (site / "wordpress/wp-content/plugins/untrusted.php").exists()
        assert s.safe_stop(site) is True
        assert not runtime.exists()
        assert not created_networks

        commands.clear()
        def failed_probe(*_args):
            raise RuntimeError("DNS leak")
        s.probe_network = failed_probe
        try:
            s.safe_start(site, proxy, 9443)
        except RuntimeError as e:
            assert "DNS leak" in str(e)
        else:
            raise AssertionError("Accepted failed egress probe")
        assert not any("up" in args for args in commands)
        assert not runtime.exists()
        assert not created_networks
        assert (site / "wordpress/wp-config.php").read_bytes() == original_config

        s.resource_exists = lambda kind, name: (
            kind == "container" and name.endswith("-safe-web")
        )
        try:
            s.safe_start(site, proxy, 9443)
        except ValueError as e:
            assert "already exists" in str(e)
        else:
            raise AssertionError("Docker name collision was not rejected")
        assert not runtime.exists()
    finally:
        s.invoke, s.resource_exists = old_invoke, old_exists
        s.shutil.which, s.probe_network = old_which, old_probe

print("Safe start preview and fail-closed rollback tests passed")
PY
