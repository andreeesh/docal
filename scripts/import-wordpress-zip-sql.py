#!/usr/bin/env python3
"""Restore ZIP + SQL into a new Docal site; leave the web service stopped."""
import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

SCRIPTS = Path(__file__).resolve().parent
IDENTIFIER = re.compile(r"[a-zA-Z0-9_]+")


def run(*args, cwd=None, env=None, capture=False, check=True):
    return subprocess.run(
        list(args), cwd=cwd, env=env, text=True, check=check,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def choose_prefix(tables):
    names = set(tables)
    matches = {
        table[:-7] for table in tables
        if IDENTIFIER.fullmatch(table) and table.endswith("options")
        and table[:-7] and table[:-7] + "users" in names
        and table[:-7] + "usermeta" in names
    }
    if len(matches) != 1:
        raise ValueError("WordPress table prefix is ambiguous or absent")
    return matches.pop()


def copy_files(stage, wordpress):
    count = 0
    for src in stage.rglob("*"):
        relative = src.relative_to(stage)
        if ".git" in relative.parts or "__MACOSX" in relative.parts:
            continue
        if relative.as_posix() in ("wp-config.php", ".htaccess", ".user.ini", "php.ini"):
            continue
        if src.is_symlink():
            raise ValueError("Staged ZIP contains a symlink")
        dest = wordpress / relative
        if src.is_dir():
            if dest.is_symlink():
                raise ValueError("Symlink destination refused")
            dest.mkdir(parents=True, exist_ok=True)
        elif src.is_file():
            if dest.is_symlink() or dest.is_dir():
                raise ValueError("Unsafe WordPress file destination")
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest)
            dest.chmod(0o644)
            count += 1
        else:
            raise ValueError("Unexpected staged file")
    if not count:
        raise ValueError("ZIP has no WordPress files")
    return count


@contextmanager
def no_bootstrap_plugins(site):
    content = site / "wordpress" / "wp-content"
    quarantine = site / ".docal-import-quarantine"
    quarantine.mkdir(mode=0o700, exist_ok=False)
    moved = []
    try:
        for name in ("mu-plugins", "db.php", "object-cache.php", "advanced-cache.php",
                     "sunrise.php", "maintenance.php"):
            src = content / name
            if src.is_symlink():
                raise ValueError("Symlinked WordPress drop-in")
            if src.exists():
                dest = quarantine / name
                src.rename(dest)
                moved.append((src, dest))
        yield
    finally:
        for src, dest in reversed(moved):
            if dest.exists():
                dest.rename(src)
        quarantine.rmdir()


def mysql(site, env, query):
    process_env = dict(os.environ, MYSQL_PWD=env["DB_PASSWORD"])
    return run(
        "docker", "compose", "exec", "-T", "-e", "MYSQL_PWD",
        "db", "mysql", "--batch", "--skip-column-names",
        "-u", env["DB_USER"], env["DB_NAME"], "-e", query,
        cwd=site, env=process_env, capture=True,
    ).stdout.strip()


def wp(site, *args, check=True):
    return run(
        "docker", "compose", "run", "-T", "--rm", "--no-deps",
        "--entrypoint", "wp", "wordpress", "--path=/var/www/html",
        *args, "--skip-plugins", "--skip-themes", "--allow-root",
        cwd=site, capture=True, check=check,
    )


def update_config(path, prefix):
    original = path.read_text(encoding="utf-8")
    changed, count = re.subn(
        r"""(?m)^\$table_prefix\s*=\s*['"][^'"]+['"]\s*;""",
        lambda _: "$table_prefix = '" + prefix + "';",
        original,
    )
    marker = "require_once ABSPATH . 'wp-settings.php';"
    if count != 1 or changed.count(marker) != 1:
        raise ValueError("Unexpected local wp-config.php structure")
    options = (
        "defined( 'DISABLE_WP_CRON' ) || define( 'DISABLE_WP_CRON', true );\n"
        "defined( 'WP_HTTP_BLOCK_EXTERNAL' ) || define( 'WP_HTTP_BLOCK_EXTERNAL', true );\n"
    )
    path.write_text(changed.replace(marker, options + marker), encoding="utf-8")
    path.chmod(0o600)


def old_urls(site, env, prefix):
    result = []
    for key in ("siteurl", "home"):
        url = mysql(site, env, "SELECT option_value FROM " + prefix +
                    "options WHERE option_name='" + key + "' LIMIT 1")
        parsed = urlsplit(url)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise ValueError("Invalid imported site URL")
        if any(ord(c) < 32 for c in url):
            raise ValueError("Invalid imported site URL characters")
        url = url.rstrip("/")
        if url not in result:
            result.append(url)
    return result


def certificate(name, proxy_dir):
    if not shutil.which("mkcert"):
        print("[warn] mkcert unavailable; no HTTPS certificate generated", file=sys.stderr)
        return
    certs = proxy_dir / "certs"
    certs.mkdir(parents=True, exist_ok=True)
    paths = [certs / (name + suffix) for suffix in (".crt", ".key", ".yml")]
    if any(p.exists() or p.is_symlink() for p in paths):
        raise ValueError("TLS certificate name already exists")
    run("mkcert", "-install", capture=True)
    run("mkcert", "-cert-file", str(paths[0]), "-key-file", str(paths[1]),
        name, capture=True)
    paths[1].chmod(0o600)
    paths[2].write_text(
        "tls:\n  certificates:\n"
        "    - certFile: /certs/" + name + ".crt\n"
        "      keyFile: /certs/" + name + ".key\n",
        encoding="utf-8",
    )


def restore(name, archive, sqlfile):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        raise ValueError("Invalid site name")
    raw_root = Path(os.environ["SITES_DIR"]).absolute()
    if raw_root.is_symlink():
        raise ValueError("Sites root cannot be symlinked")
    sites = raw_root.resolve(strict=True)
    site = sites / name
    if site.exists() or site.is_symlink():
        raise ValueError("Site already exists; no overwrite allowed")
    domain = os.environ.get("SITE_DOMAIN") or "localhost"
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", domain) or ".." in domain:
        raise ValueError("Invalid local domain")

    sources = []
    for filename, endings in ((archive, (".zip",)), (sqlfile, (".sql", ".gz"))):
        src = Path(filename).expanduser().absolute()
        if src.is_symlink() or not src.is_file() or not src.name.lower().endswith(endings):
            raise ValueError("Input file missing, symlinked or incorrect format")
        sources.append(src)

    with tempfile.TemporaryDirectory(prefix=".docal-stage-", dir=sites) as temp:
        staging = Path(temp)
        files, dump = staging / "files", staging / "database.sql"
        print("[info] Validating and staging ZIP + SQL...")
        run(sys.executable, str(SCRIPTS / "validate-wordpress-zip.py"),
            str(sources[0]), "--extract-to", str(files))
        run(sys.executable, str(SCRIPTS / "prepare-sql-dump.py"),
            str(sources[1]), "--output", str(dump))

        env = dict(os.environ, SITE_NAME=name, SITE_DOMAIN=domain,
                   INSTALL_AIOWP_MIGRATION="0")
        env.setdefault("SITE_TITLE", name)
        print("[info] Provisioning fresh MySQL without running WordPress...")
        run("bash", str(SCRIPTS / "setup-wordpress.sh"),
            "--prepare-import", "--non-interactive", env=env)
        if not (site / ".docal-import-pending").is_file():
            raise ValueError("New site has no import-pending marker")
        copied = copy_files(files, site / "wordpress")
        print("[info] Imported " + str(copied) + " files")

        conf = dict(
            line.split("=", 1)
            for line in (site / ".env").read_text(encoding="utf-8").splitlines()
            if "=" in line
        )
        for key in ("DB_NAME", "DB_USER", "DB_PASSWORD", "ADMIN_USER", "ADMIN_EMAIL"):
            if not conf.get(key):
                raise ValueError("Missing local site configuration: " + key)
        sql_env = dict(os.environ, **conf, SITE_DIR=str(site))
        run(
            "bash", "-c", 'source "$1"; docal_import_staged_sql_new_site "$2"',
            "docal-import", str(SCRIPTS / "lib-import-sql.sh"), str(dump),
            env=sql_env,
        )

        tables = mysql(
            site, conf,
            "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()",
        ).splitlines()
        prefix = choose_prefix(tables)
        update_config(site / "wordpress" / "wp-config.php", prefix)
        originals = old_urls(site, conf, prefix)
        new_url = "https://" + name + "." + domain

        print("[info] Normalizing imported site using temporary WP-CLI...")
        run("docker", "compose", "build", "wordpress", cwd=site)
        with no_bootstrap_plugins(site):
            if wp(site, "core", "is-installed", check=False).returncode:
                raise ValueError("Imported WordPress database is invalid")
            for original in originals:
                if original != new_url:
                    wp(site, "search-replace", original, new_url,
                       "--all-tables-with-prefix", "--recurse-objects",
                       "--skip-columns=guid", "--report-changed-only")
            for key in ("home", "siteurl"):
                wp(site, "option", "update", key, new_url)
            admin = conf["ADMIN_USER"]
            password = secrets.token_urlsafe(24)
            if wp(site, "user", "get", admin, check=False).returncode == 0:
                wp(site, "user", "set-role", admin, "administrator")
                wp(site, "user", "update", admin, "--user_pass=" + password)
            else:
                wp(site, "user", "create", admin, conf["ADMIN_EMAIL"],
                   "--role=administrator", "--user_pass=" + password)
            wp(site, "cache", "flush")
            if wp(site, "core", "is-installed", check=False).returncode:
                raise ValueError("WordPress verification failed")
            if wp(site, "user", "get", admin, check=False).returncode:
                raise ValueError("Administrator verification failed")

        for key in ("home", "siteurl"):
            if mysql(site, conf, "SELECT option_value FROM " + prefix +
                     "options WHERE option_name='" + key + "' LIMIT 1") != new_url:
                raise ValueError("Restored URL validation failed")

        certificate(name + "." + domain, Path(os.environ["PROXY_DIR"]).absolute())
        (site / ".docal-import-pending").unlink()
        print("[ok] Restored WordPress: " + new_url)
        print("[info] Local admin: " + admin)
        print("[info] Local admin password: " + password)
        print("[info] Start explicitly: docal start " + name)
        print("[warn] Restored plugins may contact external services when started.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site")
    parser.add_argument("--zip", required=True)
    parser.add_argument("--db", required=True)
    args = parser.parse_args()
    try:
        restore(args.site, args.zip, args.db)
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("[error] Import failed: " + str(error), file=sys.stderr)
        print("[info] Any new incomplete site remains stopped and import-pending.",
              file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
