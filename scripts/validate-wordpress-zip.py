#!/usr/bin/env python3
"""Validate a WordPress ZIP; optionally extract into a NEW staging directory.

The ZIP is never allowed to write to an existing destination or import the
production wp-config.php. This helper does not run WordPress or import SQL.
"""

import argparse
import pathlib
import re
import shutil
import stat
import sys
import zipfile

MAX_ENTRIES = 250_000
MAX_TOTAL_BYTES = 20 * 1024**3
MAX_FILE_BYTES = 10 * 1024**3
MAX_RATIO = 1_000
CHUNK_SIZE = 1024 * 1024


def _inspect(zf: zipfile.ZipFile) -> tuple[str, list[tuple[zipfile.ZipInfo, str]]]:
    infos = zf.infolist()
    if len(infos) > MAX_ENTRIES:
        raise ValueError("Too many ZIP entries")
    seen: set[str] = set()
    file_names: set[str] = set()
    members: list[tuple[zipfile.ZipInfo, str]] = []
    total = 0

    for info in infos:
        name = info.filename
        if not name or "\x00" in name or "\\" in name:
            raise ValueError("Invalid ZIP entry name")
        if name.startswith("/") or re.match(r"^[A-Za-z]:", name):
            raise ValueError("Absolute ZIP entry path")
        raw_parts = name.rstrip("/").split("/")
        if not raw_parts or any(part in ("", ".", "..") for part in raw_parts):
            raise ValueError("Unsafe ZIP path")
        normalized = "/".join(raw_parts)
        folded = normalized.casefold()
        if folded in seen:
            raise ValueError("Duplicate or case-colliding ZIP entry")
        seen.add(folded)

        mode = (info.external_attr >> 16) & 0xFFFF
        kind = stat.S_IFMT(mode)
        if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise ValueError("ZIP contains link or special file")
        if kind == stat.S_IFDIR and not info.is_dir():
            raise ValueError("Directory entry without trailing slash")
        if kind == stat.S_IFREG and info.is_dir():
            raise ValueError("File entry masquerading as directory")
        if info.flag_bits & 0x1:
            raise ValueError("Encrypted ZIP entry")
        if info.file_size < 0 or info.compress_size < 0:
            raise ValueError("Invalid ZIP entry size")
        if not info.is_dir():
            if info.file_size > MAX_FILE_BYTES:
                raise ValueError("ZIP member exceeds file size limit")
            total += info.file_size
            if total > MAX_TOTAL_BYTES:
                raise ValueError("ZIP exceeds uncompressed size limit")
            if info.file_size > MAX_RATIO * max(info.compress_size, 1):
                raise ValueError("Suspicious ZIP compression ratio")
            file_names.add(normalized)
        members.append((info, normalized))

    if not file_names:
        raise ValueError("ZIP contains no files")
    # A ZIP may wrap WordPress in one top-level directory. Never unwrap an
    # archive already rooted at wp-content, wp-admin, or wp-includes.
    roots = {name.split("/")[0] for name in file_names}
    prefix = ""
    if len(roots) == 1 and next(iter(roots)) not in {
        "wp-content", "wp-admin", "wp-includes"
    }:
        prefix = next(iter(roots)) + "/"
        members = [
            (info, name[len(prefix):])
            for info, name in members
            if name.startswith(prefix) and len(name) > len(prefix)
        ]
        file_names = {name[len(prefix):] for name in file_names}

    # A regular file must not also be the parent of another entry.
    folded_files = {name.casefold() for name in file_names}
    for name in file_names:
        parts = name.split("/")
        for i in range(1, len(parts)):
            if "/".join(parts[:i]).casefold() in folded_files:
                raise ValueError("File/directory path collision")

    has_content = any(name.startswith("wp-content/") for name in file_names)
    has_admin = any(name.startswith("wp-admin/") for name in file_names)
    has_includes = any(name.startswith("wp-includes/") for name in file_names)
    if not has_content:
        raise ValueError("ZIP must contain wp-content files")
    if has_admin != has_includes:
        raise ValueError("Partial WordPress core detected")
    layout = "full-wordpress" if has_admin else "wp-content"
    return layout, members


def validate(archive: pathlib.Path) -> str:
    if not archive.is_file():
        raise ValueError("ZIP archive does not exist")
    with zipfile.ZipFile(archive) as zf:
        layout, _ = _inspect(zf)
        return layout


def extract(archive: pathlib.Path, destination: pathlib.Path) -> str:
    """Extract into a nonexistent path; delete only that path on failure."""
    if not archive.is_file():
        raise ValueError("ZIP archive does not exist")
    if not destination.parent.is_dir():
        raise ValueError("Staging parent directory does not exist")
    with zipfile.ZipFile(archive) as zf:
        layout, members = _inspect(zf)
        selected = [
            (info, name)
            for info, name in members
            if not info.is_dir()
            and name != "wp-config.php"
            and (layout == "full-wordpress" or name.startswith("wp-content/"))
        ]
        required_bytes = sum(info.file_size for info, _ in selected)
        if shutil.disk_usage(destination.parent).free < required_bytes:
            raise ValueError("Insufficient free disk space for ZIP extraction")
        # mkdir must fail if anything already occupies the destination,
        # including an existing directory or a symlink.
        destination.mkdir(mode=0o700, exist_ok=False)
        try:
            for info, name in selected:
                target = destination.joinpath(*name.split("/"))
                target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                actual_size = 0
                # Exclusive creation: no archive entry may overwrite a file.
                with zf.open(info) as source, target.open("xb") as output:
                    while chunk := source.read(CHUNK_SIZE):
                        actual_size += len(chunk)
                        if actual_size > info.file_size:
                            raise ValueError("ZIP member exceeded declared size")
                        output.write(chunk)
                if actual_size != info.file_size:
                    raise ValueError("ZIP member size mismatch")
                target.chmod(0o644)
        except BaseException:
            shutil.rmtree(destination)
            raise
    return layout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("--extract-to", type=pathlib.Path, help="New, nonexistent staging directory")
    args = parser.parse_args()
    try:
        layout = extract(args.archive, args.extract_to) if args.extract_to else validate(args.archive)
    except (OSError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile, RuntimeError, EOFError, NotImplementedError) as exc:
        print(f"Unsafe or unsupported ZIP: {exc}", file=sys.stderr)
        return 1
    print(layout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
