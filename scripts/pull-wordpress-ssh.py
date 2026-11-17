#!/usr/bin/env python3
"""Read-only SSH acquisition for Docal's existing new-site ZIP + SQL importer.

Source: SSH config alias, absolute remote WordPress directory.
Transfers: wp-content via rsync, SQL via wp db export - (stdout).
No remote staging files, remote deletion, or remote database updates.
"""
import argparse
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import zipfile

SCRIPTS = Path(__file__).resolve().parent
SSH_ALIAS_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")
SLUG_RE = re.compile(r"[a-z0-9][a-z0-9-]*")
PREFIX_RE = re.compile(r"[A-Za-z0-9_]+")
MAX_SQL_BYTES = 10 * 1024**3
MAX_ZIP_BYTES = 20 * 1024**3
SSH_OPTIONS = [
    "-T", "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no",
    "-o", "StrictHostKeyChecking=yes", "-o", "ClearAllForwardings=yes",
    "-o", "ConnectTimeout=15",
]
# Explicitly omit common caches and backup artifacts. A copy of wp-content
# is not guaranteed to include symbolic links (rsync does not follow them).
RSYNC_EXCLUDES = [
    "--exclude=/.git/", "--exclude=/.svn/", "--exclude=/cache/",
    "--exclude=/ai1wm-backups/", "--exclude=/updraft/",
    "--exclude=/backups/", "--exclude=/backup/",
    "--exclude=**/.env", "--exclude=**/.env.*",
    "--exclude=**/wp-config.php",
    "--exclude=*.sql", "--exclude=*.sql.gz",
]


def validate(alias: str, remote_path: str, site: str) -> str:
    if not SSH_ALIAS_RE.fullmatch(alias):
        raise ValueError("Use an SSH config alias (letters, digits, dots, underscores, hyphens)")
    if not SLUG_RE.fullmatch(site):
        raise ValueError("Invalid new Docal site name")
    if (not remote_path.startswith("/") or remote_path == "/"
            or any(ord(ch) < 32 for ch in remote_path)
            or "\\" in remote_path):
        raise ValueError("Remote WordPress path must be a safe absolute Unix path")
    parts = remote_path.split("/")
    if any(part in (".", "..") for part in parts):
        raise ValueError("Remote WordPress path cannot contain . or .. segments")
    normalized = str(PurePosixPath(remote_path))
    if normalized == "/":
        raise ValueError("Cannot pull from remote filesystem root")
    return normalized


def checked_run(argv: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        argv, text=True, check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if result.returncode:
        raise RuntimeError(
            "Remote prerequisite or rsync command failed (exit "
            + str(result.returncode) + ")"
        )
    return result


def remote_wp_command(path: str, *arguments: str) -> str:
    return "wp " + " ".join(
        shlex.quote(arg) for arg in
        (*arguments, "--path=" + path, "--skip-plugins", "--skip-themes")
    )


def ssh_command(alias: str, remote_command: str) -> list[str]:
    return ["ssh", *SSH_OPTIONS, alias, remote_command]


def probe(alias: str, path: str) -> str:
    """Preflight without transferring files or writing remotely."""
    checks = " && ".join([
        "command -v wp >/dev/null",
        "command -v rsync >/dev/null",
        "test -d " + shlex.quote(path + "/wp-content"),
        remote_wp_command(path, "db", "prefix"),
    ])
    result = checked_run(ssh_command(alias, checks), capture=True)
    prefix = result.stdout.strip()
    if not PREFIX_RE.fullmatch(prefix):
        raise RuntimeError("Remote WP-CLI returned an invalid table prefix")
    return prefix


def copy_content(alias: str, path: str, staging: Path) -> Path:
    destination = staging / "wp-content"
    destination.mkdir(mode=0o700)
    # -s keeps remote path arguments out of the remote shell's word splitting.
    # -r/-t copy normal files; no -l, -L or -a, so no symlink traversal.
    checked_run([
        "rsync", "-rtzs", "--no-links", "--no-devices", "--no-specials",
        "--timeout=300", *RSYNC_EXCLUDES,
        "-e", "ssh -o BatchMode=yes -o PasswordAuthentication=no "
              "-o StrictHostKeyChecking=yes -o ClearAllForwardings=yes "
              "-o ConnectTimeout=15",
        alias + ":" + path + "/wp-content/",
        str(destination) + "/",
    ])
    if not any(p.is_file() for p in destination.rglob("*")):
        raise RuntimeError("SSH transfer produced no WordPress files")
    return destination


def stream_sql(alias: str, path: str, output: Path) -> None:
    """Read-only export into private staging, no SQL file on the remote host."""
    if output.exists() or output.is_symlink():
        raise ValueError("Refusing to overwrite SQL staging file")
    command = remote_wp_command(
        path, "db", "export", "-", "--single-transaction",
        "--quick", "--skip-lock-tables",
    )
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    size = 0
    try:
        with os.fdopen(fd, "wb") as destination:
            with tempfile.TemporaryFile() as errors:
                process = subprocess.Popen(
                    ssh_command(alias, command),
                    stdout=subprocess.PIPE, stderr=errors,
                )
                try:
                    assert process.stdout is not None
                    while data := process.stdout.read(1024 * 1024):
                        size += len(data)
                        if size > MAX_SQL_BYTES:
                            raise ValueError("Remote SQL export exceeds 10 GiB limit")
                        destination.write(data)
                    returncode = process.wait()
                    if returncode:
                        raise RuntimeError(
                            "Remote WP-CLI SQL export failed (exit "
                            + str(returncode) + ")"
                        )
                except BaseException:
                    process.kill()
                    process.wait()
                    raise
                finally:
                    if process.stdout:
                        process.stdout.close()
        if size < 32:
            raise ValueError("Remote SQL export is empty or incomplete")
    except BaseException:
        output.unlink(missing_ok=True)
        raise


def make_zip(content_root: Path, zip_path: Path) -> int:
    """Create a standard wp-content ZIP without following symlinks."""
    count = 0
    total = 0
    with zipfile.ZipFile(zip_path, "x", compression=zipfile.ZIP_STORED,
                         allowZip64=True) as archive:
        for directory, dirs, files in os.walk(content_root, followlinks=False):
            parent = Path(directory)
            for subdir in list(dirs):
                if (parent / subdir).is_symlink():
                    raise ValueError("Symlinked directory in SSH content; refusing ZIP")
            for filename in sorted(files):
                source = parent / filename
                if source.is_symlink() or not source.is_file():
                    raise ValueError("Non-regular or symlinked file in SSH content")
                total += source.stat().st_size
                if total > MAX_ZIP_BYTES:
                    raise ValueError("Remote wp-content exceeds 20 GiB limit")
                relative = source.relative_to(content_root)
                archive.write(source, arcname="wp-content/" + relative.as_posix())
                count += 1
    zip_path.chmod(0o600)
    if not count:
        raise ValueError("Remote wp-content ZIP has no files")
    return count


def invoke_import(site: str, zip_path: Path, sql_path: Path) -> None:
    checked_run([
        sys.executable, str(SCRIPTS / "import-wordpress-zip-sql.py"),
        site, "--zip", str(zip_path), "--db", str(sql_path),
    ])


def ensure_local_docker_names_unused(site: str) -> None:
    """Refuse global Docker name collisions BEFORE remote transfer begins."""
    # Docal site roots may be isolated while Docker Engine is still shared.
    daemon = subprocess.run(
        ["docker", "info", "--format", "{{.ID}}"],
        text=True, capture_output=True, check=False,
    )
    if daemon.returncode != 0:
        raise RuntimeError("Docker Engine unavailable; no SSH transfer started")
    resources = {
        "container": (f"docal-{site}-db", f"docal-{site}-wp"),
        "volume": (f"{site}_db-data", f"{site}_db-socket"),
        "image": (f"docal/wordpress-{site}:latest",),
        "network": (f"{site}_default",),
    }
    for kind, names in resources.items():
        for name in names:
            check = subprocess.run(
                ["docker", kind, "inspect", name],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                check=False,
            )
            if check.returncode == 0:
                raise ValueError(
                    f"Docker {kind} name already exists: {name}. "
                    "Choose a unique local site slug; existing resources were not changed."
                )

def pull(site: str, alias: str, path: str, dry_run: bool) -> None:
    path = validate(alias, path, site)
    root_path = Path(os.environ["SITES_DIR"]).absolute()
    if root_path.is_symlink() or not root_path.is_dir():
        raise ValueError("Configured Docal sites directory missing or symlinked")
    site_path = root_path / site
    if site_path.exists() or site_path.is_symlink():
        raise ValueError("Docal site already exists; SSH pull never overwrites a site")
    for binary in ("ssh", "rsync", "python3"):
        if not shutil.which(binary):
            raise ValueError("Required local executable is missing: " + binary)

    if not dry_run:
        ensure_local_docker_names_unused(site)

    print("[info] Checking remote WordPress and read-only SSH prerequisites...", flush=True)
    prefix = probe(alias, path)
    print("[ok] Remote site accessible via WP-CLI (table prefix: " + prefix + ")", flush=True)
    if dry_run:
        print("[ok] Dry run complete. No database or site files transferred.", flush=True)
        return

    with tempfile.TemporaryDirectory(prefix=".docal-ssh-stage-", dir=root_path) as temporary:
        stage = Path(temporary)
        print("[info] Copying wp-content with rsync (source read only)...", flush=True)
        source = copy_content(alias, path, stage)
        print("[info] Streaming database dump over SSH (no remote dump file)...", flush=True)
        sql_path = stage / "remote.sql"
        stream_sql(alias, path, sql_path)
        zip_path = stage / "wp-content.zip"
        count = make_zip(source, zip_path)
        print("[info] Prepared ZIP with " + str(count) + " files. Restoring locally...", flush=True)
        invoke_import(site, zip_path, sql_path)
    print("[ok] SSH content collected and imported via ZIP + SQL engine.", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site", help="New local Docal site name")
    parser.add_argument("--ssh", required=True, help="SSH config alias (not a password or URL)")
    parser.add_argument("--path", required=True, help="Absolute remote WordPress root path")
    parser.add_argument("--dry-run", action="store_true", help="Read-only SSH/WP-CLI preflight")
    args = parser.parse_args()
    try:
        pull(args.site, args.ssh, args.path, args.dry_run)
        return 0
    except (OSError, ValueError, RuntimeError) as error:
        print("[error] SSH pull failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
