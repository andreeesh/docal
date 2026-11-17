#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT/scripts/safe-start.py" <<'PY'
import importlib.util
import io
import json
import copy
from pathlib import Path
import shutil
import socket
import sys
import tempfile
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("safe_start", sys.argv[1])
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)

# Docker may return the original DB container's Mounts in a different order
# between read-only inspections. That is not a configuration change.
mount_snapshot = {
    "Id": "source-db-id", "Name": "/docal-safe-fixture-db",
    "Config": {"Image": "mysql:8"}, "HostConfig": {"RestartPolicy": {"Name": "unless-stopped"}},
    "Mounts": [
        {"Type": "volume", "Name": "source-data", "Destination": "/var/lib/mysql", "Source": "/docker/source-data", "RW": True},
        {"Type": "volume", "Name": "source-socket", "Destination": "/var/run/mysqld", "Source": "/docker/source-socket", "RW": True},
    ],
    "State": {"Status": "running", "Running": True, "StartedAt": "fixed", "Health": {"Status": "healthy"}},
    "NetworkSettings": {"Networks": {"synthetic": {}}},
}
old_network_snapshot = s.source_network_snapshot
s.source_network_snapshot = lambda _container: {}
try:
    first_mount_snapshot = s.source_container_snapshot(mount_snapshot)
    reordered_mount_snapshot = copy.deepcopy(mount_snapshot)
    reordered_mount_snapshot["Mounts"].reverse()
    assert s.source_container_snapshot(reordered_mount_snapshot)["config_hash"] == first_mount_snapshot["config_hash"]
finally:
    s.source_network_snapshot = old_network_snapshot


def make_site(root):
    site = root / "safe-fixture"
    wp = site / "wordpress"
    wp.mkdir(parents=True)
    (site / "docker-compose.yml").write_text("services:\n  db:\n    image: mysql:8\n")
    (site / ".env").write_text(
        "SITE_SLUG=safe-fixture\nSITE_DOMAIN=localhost\n"
        "DB_NAME=wp_safe-fixture\nDB_USER=wp_safe-fixture\nDB_PASSWORD=local$fake$secret\n"
    )
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
    assert s.db_credentials({
        "DB_NAME": "wp_safe-fixture",
        "DB_USER": "wp_safe-fixture",
        "DB_PASSWORD": "synthetic-secret",
    }) == ["wp_safe-fixture", "wp_safe-fixture", "synthetic-secret"]
    # The original database must be queried/exported through docker exec,
    # never through Compose commands that can reconcile its service.
    mysql_commands = []
    old_run = s.subprocess.run
    s.subprocess.run = lambda args, **_kwargs: (
        mysql_commands.append(tuple(args)) or SimpleNamespace(
            returncode=0, stdout="12\n", stderr="",
        )
    )
    try:
        assert s.local_table_count(
            {"DB_NAME": "wp_safe-fixture", "DB_USER": "wp_safe-fixture",
             "DB_PASSWORD": "synthetic-secret"},
            source_container="source-db-id",
        ) == 12
    finally:
        s.subprocess.run = old_run
    assert mysql_commands[0][:5] == (
        "docker", "exec", "-e", "MYSQL_PWD", "source-db-id",
    )
    assert "compose" not in mysql_commands[0]

    dump_commands = []
    old_popen = s.subprocess.Popen
    class FakeProcess:
        def __init__(self, args, **kwargs):
            dump_commands.append(tuple(args))
            self.stdout = io.BytesIO(b"synthetic SQL stream") if kwargs.get("stdout") is not None else None
        def poll(self): return 0
        def wait(self): return 0
        def kill(self): pass
    s.subprocess.Popen = FakeProcess
    try:
        s.stream_local_database(
            {"DB_NAME": "wp_safe-fixture", "DB_USER": "wp_safe-fixture",
             "DB_PASSWORD": "synthetic-secret"},
            "source-db-id", "safe-db-id",
        )
    finally:
        s.subprocess.Popen = old_popen
    assert dump_commands[0][:5] == (
        "docker", "exec", "-e", "MYSQL_PWD", "source-db-id",
    )
    assert "mysqldump" in dump_commands[0] and "compose" not in dump_commands[0]
    assert dump_commands[1][:5] == (
        "docker", "exec", "-i", "-e", "MYSQL_PWD",
    )
    assert "compose" not in dump_commands[1]
    original_config = (site / "wordpress/wp-config.php").read_bytes()
    runtime = site / s.SAFE_DIR_NAME
    commands = []
    created_networks = set()
    created_volumes = set()
    clone_events = []
    source_state = {"Status": "running", "Running": True, "StartedAt": "fixed-start", "RestartCount": 0,
                    "Health": {"Status": "healthy"}}
    source_network_members = {
        "source-db-id": {"Name": "docal-safe-fixture-db", "EndpointID": "source-endpoint",
                         "MacAddress": "02:42:ac:11:00:02", "IPv4Address": "172.20.0.2/16",
                         "IPv6Address": ""},
        "proxy-id": {"Name": "docal-proxy", "EndpointID": "proxy-endpoint",
                     "MacAddress": "02:42:ac:11:00:03", "IPv4Address": "172.20.0.3/16",
                     "IPv6Address": ""},
    }
    mutate_source_network = False
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
        if args[:4] == ["docker", "compose", "config", "--format"]:
            return SimpleNamespace(returncode=0,
                                   stdout=json.dumps({"services": {"db": {"image": "mysql:8"}}}),
                                   stderr="")
        if args[:4] == ["docker", "compose", "ps", "--status"]:
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if args[:3] == ["docker", "container", "inspect"]:
            data = {
                "Id": "source-db-id", "Name": "/docal-safe-fixture-db",
                "RestartCount": source_state["RestartCount"],
                "State": dict(source_state),
                "Config": {
                    "Image": "mysql:8",
                    "Labels": {"com.docker.compose.service": "db",
                               "com.docker.compose.project": "safe-fixture"},
                    "Env": ["MYSQL_DATABASE=wp_safe-fixture", "MYSQL_PASSWORD=fixture-secret"],
                },
                "HostConfig": {"RestartPolicy": {"Name": "unless-stopped"}},
                "Mounts": [{"Type": "volume", "Name": "safe-fixture_db-data",
                            "Source": "/var/lib/docker/volumes/source-data/_data",
                            "Destination": "/var/lib/mysql", "RW": True}],
                "NetworkSettings": {"Networks": {"docal-proxy": {
                    "NetworkID": "source-network-id", "EndpointID": "source-endpoint",
                    "Gateway": "172.20.0.1", "IPAddress": "172.20.0.2",
                    "IPPrefixLen": 16, "MacAddress": "02:42:ac:11:00:02",
                    "Aliases": ["db", "docal-safe-fixture-db"],
                }}},
            }
            return SimpleNamespace(returncode=0, stdout=json.dumps(data), stderr="")
        if args[:3] == ["docker", "network", "inspect"] and args[3] == "docal-proxy":
            members = dict(source_network_members)
            return SimpleNamespace(returncode=0, stdout=json.dumps({
                "Id": "source-network-id", "Driver": "bridge", "Scope": "local",
                "Internal": False, "EnableIPv6": False, "Options": {},
                "IPAM": {"Config": [{"Subnet": "172.20.0.0/16"}]},
                "Containers": members,
            }), stderr="")
        if args[:3] == ["docker", "compose", "up"] or (
            args[:2] == ["docker", "compose"] and "safe-db" in args and "up" in args
        ):
            created_volumes.update({
                "docal-safe-fixture-safe-db-data", "docal-safe-fixture-safe-db-socket",
            })
        if args[:3] == ["docker", "volume", "rm"]:
            created_volumes.discard(args[-1])
        if args[:3] == ["docker", "volume", "inspect"]:
            return SimpleNamespace(returncode=0, stdout=json.dumps({
                "Labels": {"docal.safe.site": "safe-fixture"},
            }), stderr="")
        if args[:3] == ["docker", "network", "create"]:
            created_networks.add(args[-1])
            if mutate_source_network:
                source_network_members["unexpected-id"] = {"Name": "unexpected-peer"}
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
    old_count, old_stream = s.local_table_count, s.stream_local_database
    try:
        s.invoke = fake_invoke
        s.resource_exists = lambda kind, name: (
            kind == "image"
            or (kind == "network" and name in created_networks)
            or (kind == "volume" and name in created_volumes)
        )
        s.local_table_count = lambda *_args, **_kwargs: 12
        s.stream_local_database = lambda *_args: clone_events.append("stream")
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
        db = compose["services"]["safe-db"]
        assert db["image"] == "mysql:8"
        assert db["networks"] == ["docal-safe-internal"]
        assert "ports" not in db
        assert db["environment"]["MYSQL_DATABASE"] == "wp_safe-fixture"
        assert db["environment"]["MYSQL_USER"] == "wp_safe-fixture"
        assert "$${MYSQL_PASSWORD}" in db["healthcheck"]["test"][1]
        assert "$${MYSQL_USER}" in db["healthcheck"]["test"][1]
        assert "$${MYSQL_DATABASE}" in db["healthcheck"]["test"][1]
        assert db["environment"]["MYSQL_PASSWORD"] == "local$$fake$$secret"
        assert "db-socket:/var/run/mysqld" not in compose["services"]["safe-web"]["volumes"]
        assert "docal-safe-db-socket:/var/run/mysqld" in compose["services"]["safe-web"]["volumes"]
        assert compose["services"]["safe-web"]["depends_on"] == {
            "safe-db": {"condition": "service_healthy"}
        }
        assert compose["volumes"]["docal-safe-db-data"]["name"] == "docal-safe-fixture-safe-db-data"
        assert compose["volumes"]["docal-safe-db-socket"]["name"] == "docal-safe-fixture-safe-db-socket"
        assert clone_events == ["stream"]
        assert compose["services"]["safe-tls"]["ports"][0]["host_ip"] == "127.0.0.1"
        assert compose["services"]["safe-tls"]["ports"][0]["published"] == "9443"
        assert "wordpress" not in compose["services"]
        assert compose["networks"]["safe-tls-edge"]["name"] == "docal-safe-fixture-safe-edge"
        assert any(
            any("enable_ip_masquerade=false" in part for part in command)
            for command in commands if command[:3] == ("docker", "network", "create")
        )
        assert not any(
            command[:2] == ("docker", "compose")
            and any(op in command for op in ("up", "start", "restart", "create", "run"))
            and "db" in command
            for command in commands
        ), "Safe Start invoked Compose to start or reconcile the original DB"
        assert (site / "wordpress/wp-config.php").read_bytes() == original_config
        assert (site / "wordpress/wp-content/plugins/untrusted.php").exists()
        assert s.safe_stop(site) is True
        assert not runtime.exists()
        assert not created_networks
        assert not created_volumes

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
        assert not created_volumes
        assert (site / "wordpress/wp-config.php").read_bytes() == original_config

        # A stopped/unhealthy original DB aborts before runtime or preview
        # resource creation and tells the user how to start it manually.
        source_state["Status"] = "exited"
        source_state["Running"] = False
        commands.clear()
        try:
            s.safe_start(site, proxy, 9443)
        except ValueError as e:
            assert "already be running and healthy" in str(e)
            assert "docker compose start db" in str(e)
        else:
            raise AssertionError("Started/reconciled an inactive original database")
        assert not runtime.exists()
        assert not created_networks and not created_volumes
        assert not any(
            command[:2] == ("docker", "compose")
            and any(op in command for op in ("up", "start", "restart", "create", "run"))
            for command in commands
        )
        source_state["Status"] = "running"
        source_state["Running"] = True

        # Detect a source network membership change during preview setup.
        mutate_source_network = True
        commands.clear()
        try:
            s.safe_start(site, proxy, 9443)
        except RuntimeError as e:
            assert "network connections changed" in str(e)
        else:
            raise AssertionError("Ignored a changed original MySQL network")
        assert not runtime.exists()
        assert not created_networks and not created_volumes
        source_network_members.pop("unexpected-id", None)
        mutate_source_network = False

        # An occupied loopback port must fail before any resource creation or
        # PHP container start, rather than relying on Compose's later bind error.
        commands.clear()
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen(1)
            occupied_port = occupied.getsockname()[1]
            try:
                s.safe_start(site, proxy, occupied_port)
            except ValueError as e:
                assert "port is already occupied" in str(e)
            else:
                raise AssertionError("Occupied loopback port was accepted")
        assert not commands
        assert not runtime.exists()
        assert not created_networks and not created_volumes

        # The source DB export can fail after disposable DB provisioning:
        # rollback must delete only the owned preview volumes and networks.
        s.probe_network = lambda *_args: None
        commands.clear()
        def failed_copy(*_args):
            raise RuntimeError("Local mysqldump failed")
        s.stream_local_database = failed_copy
        try:
            s.safe_start(site, proxy, 9443)
        except RuntimeError as e:
            assert "mysqldump failed" in str(e)
        else:
            raise AssertionError("Database cloning failure did not abort preview")
        assert not runtime.exists()
        assert not created_networks and not created_volumes
        assert not any("safe-tls" in command and "up" in command for command in commands)
        s.stream_local_database = lambda *_args: clone_events.append("stream")

        # A colliding globally named temporary database volume is refused.
        s.resource_exists = lambda kind, name: (
            kind == "volume" and name == "docal-safe-fixture-safe-db-data"
        )
        try:
            s.safe_start(site, proxy, 9443)
        except ValueError as e:
            assert "already exists" in str(e)
        else:
            raise AssertionError("Disposable database volume collision ignored")
        assert not runtime.exists()

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
        s.local_table_count, s.stream_local_database = old_count, old_stream

print("Safe start preview and fail-closed rollback tests passed")
PY
