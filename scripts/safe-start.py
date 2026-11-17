#!/usr/bin/env python3
"""Fail-closed local preview of a Docal site, with isolated WordPress networking.

Preview serves https://<site>.localhost:<port> via a separate local-only TLS
reverse proxy. WordPress joins ONLY a fresh internal network and reaches its
existing LOCAL MySQL database through the Docal socket volume. Plugins, MU
plugins and common drop-ins are excluded from a disposable file copy.

This does NOT snapshot the existing local database or guarantee that themes
have no side effects. A Docker networking / egress probe must pass before PHP
is started. It intentionally leaves the normal Docal proxy untouched.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

SLUG = re.compile(r"[a-z0-9][a-z0-9-]*")
HOST = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]*")
SAFE_DIR_NAME = ".docal-safe-runtime"
MAX_PORT = 65535
# Existing local site may use some of these paths. They must not be copied
# into the isolated preview; no production plugin PHP should be loaded.
RSYNC_EXCLUDES = (
    "/.git/", "/wp-content/plugins/", "/wp-content/mu-plugins/",
    "/wp-content/cache/", "/wp-content/ai1wm-backups/",
    "/wp-content/updraft/", "/wp-content/backups/",
    "/wp-content/db.php", "/wp-content/object-cache.php",
    "/wp-content/advanced-cache.php", "/wp-content/sunrise.php",
    "/wp-content/maintenance.php", "/wp-content/fatal-error-handler.php",
    "/wp-content/php-error.php", "*.sql", "*.sql.gz", ".env",
)

# Check actual reachability, not only network metadata. Refuse if even one
# external target is reachable OR if an external name gets resolved.
# The WordPress network has no other containers during the probe.
EGRESS_PROBE = r"""
$targets = array(
  'tcp://1.1.1.1:443',
  'tcp://[2606:4700:4700::1111]:443'
);
foreach ($targets as $target) {
  $connection = @stream_socket_client($target, $errno, $errstr, 2);
  if ($connection !== false) {
    fclose($connection);
    fwrite(STDERR, 'Unexpected external connection: ' . $target . PHP_EOL);
    exit(31);
  }
}
if (@gethostbyname('example.com') !== 'example.com') {
  fwrite(STDERR, 'External DNS name resolved' . PHP_EOL);
  exit(32);
}
echo 'External IPv4, IPv6 and DNS checks blocked' . PHP_EOL;
"""


def invoke(args, *, cwd=None, capture=False, check=True):
    result = subprocess.run(
        args, cwd=cwd, text=True, check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode != 0:
        # Never print full arguments; they may include private paths/secrets.
        raise RuntimeError("Command failed (exit " + str(result.returncode) + ")")
    return result


def read_site(site_dir):
    if site_dir.is_symlink() or not site_dir.is_dir():
        raise ValueError("Site path missing or symlinked")
    if not (site_dir / "docker-compose.yml").is_file():
        raise ValueError("Docal Compose configuration missing")
    settings = {}
    for line in (site_dir / ".env").read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, val = line.split("=", 1)
            settings[key] = val
    slug = settings.get("SITE_SLUG", "")
    domain = settings.get("SITE_DOMAIN", "")
    if not SLUG.fullmatch(slug) or not HOST.fullmatch(domain) or ".." in domain:
        raise ValueError("Invalid Docal site identity in .env")
    if site_dir.name != slug:
        raise ValueError("Site directory and Docal site slug disagree")
    if (site_dir / ".docal-import-pending").exists():
        raise ValueError("Cannot preview a pending or incomplete import")
    return settings


def names(slug):
    return {
        "network": "docal-" + slug + "-safe",
        "edge_network": "docal-" + slug + "-safe-edge",
        "web": "docal-" + slug + "-safe-web",
        "tls": "docal-" + slug + "-safe-tls",
        "image": "docal/wordpress-" + slug + ":latest",
    }


def resource_exists(kind, name):
    return invoke(
        ["docker", kind, "inspect", name], capture=True, check=False,
    ).returncode == 0


def assert_available(slug):
    obj = names(slug)
    for key in ("network", "edge_network", "web", "tls"):
        kind = "network" if key in ("network", "edge_network") else "container"
        if resource_exists(kind, obj[key]):
            raise ValueError(
                "Safe preview resource already exists: " + obj[key]
                + "; refusing to replace any Docker resource"
            )


def prepare_files(site_dir, runtime):
    root = runtime / "wordpress"
    root.mkdir()
    original = site_dir / "wordpress"
    if original.is_symlink() or not (original / "wp-config.php").is_file():
        raise ValueError("Local WordPress directory or config missing")
    command = [
        "rsync", "-rt", "--no-links", "--no-devices", "--no-specials",
        "--chmod=D755,F644",
    ]
    for entry in RSYNC_EXCLUDES:
        command.append("--exclude=" + entry)
    invoke(command + [str(original) + "/", str(root) + "/"])
    config = root / "wp-config.php"
    if not config.is_file() or config.is_symlink():
        raise ValueError("Copied local wp-config.php missing")
    for dir_name in ("plugins", "mu-plugins"):
        plugin_dir = root / "wp-content" / dir_name
        plugin_dir.mkdir(parents=True, exist_ok=True)
        if any(plugin_dir.iterdir()):
            raise ValueError("Unsafe preview: plugin directory was not empty")
    for forbidden in (
        "db.php", "object-cache.php", "advanced-cache.php",
        "sunrise.php", "maintenance.php", "fatal-error-handler.php",
    ):
        if (root / "wp-content" / forbidden).exists():
            raise ValueError("Unsafe preview: WordPress drop-in present")
    return config


def update_preview_config(config_path, url):
    """Modify only the disposable copy of Docal's generated wp-config.php."""
    original = config_path.read_text(encoding="utf-8")
    text = original
    for constant in ("WP_HOME", "WP_SITEURL"):
        pattern = (
            r"(?m)(defined\(\s*'"+constant+r"'\s*\)\s*\|\|\s*"
            r"define\(\s*'"+constant+r"'\s*,\s*')[^']+('\s*\);)"
        )
        text, count = re.subn(
            pattern, lambda match: match.group(1) + url + match.group(2), text,
        )
        if count != 1:
            raise ValueError("Unsupported wp-config.php: missing " + constant)
    marker = "require_once ABSPATH . 'wp-settings.php';"
    if text.count(marker) != 1:
        raise ValueError("Unsupported local WordPress bootstrap")
    policy = "\n".join([
        "defined( 'DISABLE_WP_CRON' ) || define( 'DISABLE_WP_CRON', true );",
        "defined( 'AUTOMATIC_UPDATER_DISABLED' ) || define( 'AUTOMATIC_UPDATER_DISABLED', true );",
        "defined( 'DISALLOW_FILE_MODS' ) || define( 'DISALLOW_FILE_MODS', true );",
        "defined( 'WP_HTTP_BLOCK_EXTERNAL' ) || define( 'WP_HTTP_BLOCK_EXTERNAL', true );",
        "",
    ])
    config_path.write_text(text.replace(marker, policy + marker), encoding="utf-8")
    config_path.chmod(0o640)


def prepare_runtime(site_dir, proxy_dir, port, runtime):
    conf = read_site(site_dir)
    slug, domain = conf["SITE_SLUG"], conf["SITE_DOMAIN"]
    hostname = slug + "." + domain
    if not isinstance(port, int) or not 1 <= port <= MAX_PORT:
        raise ValueError("Invalid local HTTPS port")
    cert = proxy_dir / "certs" / (hostname + ".crt")
    key = proxy_dir / "certs" / (hostname + ".key")
    if not cert.is_file() or not key.is_file() or cert.is_symlink() or key.is_symlink():
        raise ValueError("Missing local TLS certificate; generate it before safe preview")
    config_path = prepare_files(site_dir, runtime)
    update_preview_config(config_path, "https://" + hostname + ":" + str(port))
    (runtime / "safe.ini").write_text(
        "sendmail_path = /bin/false\n"
        "allow_url_fopen = Off\n"
        "expose_php = Off\n",
        encoding="utf-8",
    )
    # Uploaded PHP is never needed for a browser smoke test and must not run.
    # Enforce at Apache config level, independent of imported .htaccess files.
    (runtime / "safe-apache.conf").write_text(
        '<Directory "/var/www/html/wp-content/uploads">\n'
        '  <FilesMatch "\\.(?i:php[0-9]*|phtml|phar)$">\n'
        '    Require all denied\n'
        '  </FilesMatch>\n'
        '</Directory>\n',
        encoding="utf-8",
    )
    (runtime / "resolv.conf").write_text("nameserver 127.0.0.1\n", encoding="utf-8")
    (runtime / "nginx.conf").write_text(
        "server {\n"
        "  listen 443 ssl;\n"
        "  server_name " + hostname + ";\n"
        "  ssl_certificate /etc/docal/safe.crt;\n"
        "  ssl_certificate_key /etc/docal/safe.key;\n"
        "  location / {\n"
        "    proxy_pass http://safe-web:80;\n"
        "    proxy_set_header Host $http_host;\n"
        "    proxy_set_header X-Forwarded-Proto https;\n"
        "    proxy_set_header X-Forwarded-Port " + str(port) + ";\n"
        "    proxy_set_header X-Real-IP $remote_addr;\n"
        "  }\n"
        "}\n",
        encoding="utf-8",
    )
    obj = names(slug)
    # All paths are fully qualified and serialized by json.dumps; JSON is
    # accepted YAML, so Compose can read this without a YAML dependency.
    override = {
        "services": {
            "safe-web": {
                "profiles": ["safe"],
                "image": obj["image"],
                "container_name": obj["web"],
                "restart": "no",
                "depends_on": {"db": {"condition": "service_healthy"}},
                "volumes": [
                    str(runtime / "wordpress") + ":/var/www/html:ro",
                    "db-socket:/var/run/mysqld",
                    str(runtime / "safe.ini") + ":/usr/local/etc/php/conf.d/zz-docal-safe.ini:ro",
                    str(runtime / "safe-apache.conf") + ":/etc/apache2/conf-enabled/zz-docal-safe.conf:ro",
                    str(runtime / "resolv.conf") + ":/etc/resolv.conf:ro",
                ],
                "networks": ["docal-safe-internal"],
                "read_only": True,
                "tmpfs": ["/tmp", "/run/apache2", "/var/lock/apache2", "/var/log/apache2"],
                "security_opt": ["no-new-privileges:true"],
                "labels": {"traefik.enable": "false"},
            },
            "safe-tls": {
                "profiles": ["safe"],
                "image": "nginx:alpine",
                "container_name": obj["tls"],
                "restart": "no",
                "depends_on": ["safe-web"],
                "ports": [{"target": 443, "published": str(port), "host_ip": "127.0.0.1", "protocol": "tcp"}],
                "volumes": [
                    str(runtime / "nginx.conf") + ":/etc/nginx/conf.d/default.conf:ro",
                    str(cert) + ":/etc/docal/safe.crt:ro",
                    str(key) + ":/etc/docal/safe.key:ro",
                ],
                # Docker Engine does not publish ports for containers whose
                # only network is internal. Put the trusted TLS proxy on a
                # dedicated no-masquerade bridge first so localhost port
                # publishing works without giving WordPress another network.
                "networks": ["safe-tls-edge", "docal-safe-internal"],
                "read_only": True,
                "tmpfs": ["/var/cache/nginx", "/var/run", "/tmp"],
                "security_opt": ["no-new-privileges:true"],
                "labels": {"traefik.enable": "false"},
            },
        },
        "networks": {
            "docal-safe-internal": {"external": True, "name": obj["network"]},
            "safe-tls-edge": {"external": True, "name": obj["edge_network"]},
        },
    }
    (runtime / "compose.safe.yml").write_text(
        json.dumps(override, indent=2) + "\n", encoding="utf-8",
    )
    (runtime / "identity.json").write_text(
        json.dumps({"site": slug, "port": port, "network": obj["network"],
                    "edge_network": obj["edge_network"]}),
        encoding="utf-8",
    )
    return obj


def compose_args(site_dir, runtime):
    return [
        "docker", "compose",
        "-f", str(site_dir / "docker-compose.yml"),
        "-f", str(runtime / "compose.safe.yml"),
        "--profile", "safe",
    ]


def ensure_no_normal_web(site_dir):
    running = invoke(
        ["docker", "compose", "ps", "--status", "running", "--services"],
        cwd=site_dir, capture=True,
    ).stdout.splitlines()
    if "wordpress" in running:
        raise ValueError(
            "Normal WordPress web container is running; stop it before safe preview"
        )


def network_metadata(name):
    details = invoke(
        ["docker", "network", "inspect", name, "--format", "{{json .}}"],
        capture=True,
    ).stdout
    return json.loads(details)


def assert_owned_network(name, slug):
    data = network_metadata(name)
    if (data.get("Labels") or {}).get("docal.safe.site") != slug:
        raise RuntimeError("Preview network is not owned by this Docal site")
    return data


def inspect_network(name, slug):
    data = assert_owned_network(name, slug)
    if not data.get("Internal") or data.get("EnableIPv6"):
        raise RuntimeError("Dedicated preview network is not internal IPv4-only")
    if data.get("Containers"):
        raise RuntimeError("Preview network unexpectedly already has containers")


def probe_network(image, network, resolv):
    # A one-off PHP process runs before WordPress and before starting safe-web.
    # No site code is mounted or executed here.
    invoke([
        "docker", "run", "--rm",
        "--network", network,
        "--dns", "127.0.0.1",
        "-v", str(resolv) + ":/etc/resolv.conf:ro",
        "--entrypoint", "php", image, "-r", EGRESS_PROBE,
    ])


def safe_start(site_dir, proxy_dir, port):
    conf = read_site(site_dir)
    slug = conf["SITE_SLUG"]
    runtime = site_dir / SAFE_DIR_NAME
    if runtime.exists() or runtime.is_symlink():
        raise ValueError("Safe preview already prepared; use docal stop to clean it")
    ensure_no_normal_web(site_dir)
    assert_available(slug)
    if not shutil.which("rsync"):
        raise ValueError("rsync is required for disposable safe preview copies")
    runtime.mkdir(mode=0o700)
    obj = names(slug)
    networks_created = []
    try:
        prepare_runtime(site_dir, proxy_dir, port, runtime)
        # Refuse to build arbitrary site Dockerfiles while entering safe mode.
        # Import and standard create normally build this image already.
        if not resource_exists("image", obj["image"]):
            raise ValueError("Docal WordPress image is missing; refusing automatic build in safe mode")
        invoke([
            "docker", "network", "create", "--internal", "--driver", "bridge",
            "--label", "docal.safe.site=" + slug,
            obj["network"],
        ])
        networks_created.append(obj["network"])
        inspect_network(obj["network"], slug)
        invoke([
            "docker", "network", "create", "--driver", "bridge",
            "--opt", "com.docker.network.bridge.enable_ip_masquerade=false",
            "--label", "docal.safe.site=" + slug,
            obj["edge_network"],
        ])
        networks_created.append(obj["edge_network"])
        edge = assert_owned_network(obj["edge_network"], slug)
        edge_options = edge.get("Options") or {}
        if (edge.get("Driver") != "bridge" or edge.get("Internal")
                or edge.get("EnableIPv6") or edge.get("Containers")
                or edge_options.get("com.docker.network.bridge.enable_ip_masquerade") != "false"):
            raise RuntimeError("Dedicated TLS edge network is not isolated and empty")
        print("[info] Testing IPv4, IPv6 and DNS egress before starting PHP...", flush=True)
        probe_network(obj["image"], obj["network"], runtime / "resolv.conf")
        # Start the original site's DB only, never its public web service.
        invoke(["docker", "compose", "up", "-d", "db"], cwd=site_dir)
        args = compose_args(site_dir, runtime)
        invoke([*args, "up", "-d", "safe-tls"], cwd=site_dir)
        print("[ok] Safe preview: https://" + slug + "." + conf["SITE_DOMAIN"]
              + ":" + str(port), flush=True)
        print("[info] WordPress plugins and MU-plugins are absent from the preview.", flush=True)
        print("[warn] This mode still uses the site's LOCAL database; it can change during browsing.")
    except BaseException:
        # Stop only this preview; do not call compose down (which stops db).
        if (runtime / "compose.safe.yml").is_file():
            args = compose_args(site_dir, runtime)
            invoke([*args, "stop", "safe-tls", "safe-web"],
                   cwd=site_dir, check=False)
            invoke([*args, "rm", "-sf", "safe-tls", "safe-web"],
                   cwd=site_dir, check=False)
        for network in reversed(networks_created):
            # A replaced or externally modified network must not be deleted.
            try:
                assert_owned_network(network, slug)
            except (OSError, ValueError, RuntimeError):
                pass
            else:
                invoke(["docker", "network", "rm", network], check=False)
        shutil.rmtree(runtime)
        raise


def safe_stop(site_dir):
    runtime = site_dir / SAFE_DIR_NAME
    if not runtime.exists() and not runtime.is_symlink():
        return False
    if runtime.is_symlink() or not runtime.is_dir():
        raise ValueError("Unsafe safe preview directory; refusing cleanup")
    conf = read_site(site_dir)
    obj = names(conf["SITE_SLUG"])
    identity_path = runtime / "identity.json"
    if not identity_path.is_file() or identity_path.is_symlink():
        raise ValueError("Missing safe preview identity; refusing cleanup")
    identity = json.loads(identity_path.read_text(encoding="utf-8"))
    if (identity.get("site") != conf["SITE_SLUG"]
            or identity.get("network") != obj["network"]
            or identity.get("edge_network") != obj["edge_network"]):
        raise ValueError("Safe preview identity mismatch; refusing cleanup")
    args = compose_args(site_dir, runtime)
    invoke([*args, "stop", "safe-tls", "safe-web"], cwd=site_dir)
    invoke([*args, "rm", "-sf", "safe-tls", "safe-web"], cwd=site_dir)
    for network in (obj["network"], obj["edge_network"]):
        if resource_exists("network", network):
            assert_owned_network(network, conf["SITE_SLUG"])
            invoke(["docker", "network", "rm", network])
    shutil.rmtree(runtime)
    print("[ok] Safe preview web containers, networks and copy removed")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "stop"))
    parser.add_argument("--site-dir", type=Path, required=True)
    parser.add_argument("--proxy-dir", type=Path)
    parser.add_argument("--port", type=int, default=8443)
    args = parser.parse_args()
    try:
        site_dir = args.site_dir.absolute()
        if args.action == "start":
            if not args.proxy_dir:
                raise ValueError("--proxy-dir required for safe start")
            safe_start(site_dir, args.proxy_dir.absolute(), args.port)
        else:
            safe_stop(site_dir)
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as e:
        print("[error] Safe preview: " + str(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
