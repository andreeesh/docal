#!/usr/bin/env python3
"""Validate a WordPress ZIP without extracting it.

Exit nonzero for unsafe paths, links, duplicates, encryption, or unsupported
layouts. This is a preflight validator, not an extraction routine.
"""
import argparse
import pathlib
import re
import stat
import sys
import zipfile


def validate(archive: pathlib.Path) -> str:
    if not archive.is_file():
        raise ValueError("ZIP archive does not exist")
    seen = set()
    files = set()
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            name = info.filename
            if not name or "\x00" in name or "\\" in name:
                raise ValueError("Invalid ZIP entry name")
            if name.startswith("/") or re.match(r"^[A-Za-z]:", name):
                raise ValueError("Absolute ZIP entry path")
            parts = pathlib.PurePosixPath(name).parts
            if ".." in parts or "." in parts:
                raise ValueError("Unsafe ZIP path traversal")
            normalized = "/".join(parts)
            if normalized in seen:
                raise ValueError("Duplicate ZIP entry")
            seen.add(normalized)
            mode = (info.external_attr >> 16) & 0xFFFF
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError("ZIP contains link or special file")
            if info.flag_bits & 0x1:
                raise ValueError("Encrypted ZIP entry")
            if not info.is_dir():
                files.add(normalized)
        if not files:
            raise ValueError("ZIP contains no files")
        roots = {p.split("/")[0] for p in files}
        if len(roots) == 1:
            root = next(iter(roots))
            prefix = root + "/"
            files = {p[len(prefix):] for p in files if p.startswith(prefix)}
        has_content = any(p.startswith("wp-content/") for p in files)
        has_core = any(p.startswith("wp-admin/") for p in files) and any(
            p.startswith("wp-includes/") for p in files
        )
        if not has_content:
            raise ValueError("ZIP must contain wp-content files")
        if has_core:
            return "full-wordpress"
        if any(p.startswith("wp-admin/") or p.startswith("wp-includes/") for p in files):
            raise ValueError("Partial WordPress core detected")
        return "wp-content"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=pathlib.Path)
    args = parser.parse_args()
    try:
        layout = validate(args.archive)
    except (OSError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile) as exc:
        print(f"Unsafe or unsupported ZIP: {exc}", file=sys.stderr)
        return 1
    print(layout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
