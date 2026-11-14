#!/usr/bin/env python3
"""Stage a .sql or gzip-compressed SQL dump into a NEW, private regular file.

This prepares and verifies the complete input before any database operation.
It does not execute SQL, create Docker resources, or overwrite files.
"""
import argparse
import gzip
import os
import pathlib
import shutil
import sys

MAX_UNCOMPRESSED_BYTES = 10 * 1024**3
CHUNK_SIZE = 1024 * 1024


def prepare(source: pathlib.Path, destination: pathlib.Path) -> int:
    if not source.is_file() or source.is_symlink():
        raise ValueError("SQL source must be a regular file, not a symlink")
    lower_name = source.name.lower()
    if not (lower_name.endswith(".sql") or lower_name.endswith(".gz")):
        raise ValueError("Expected a .sql, .sql.gz or .gz file")
    if not destination.parent.is_dir() or destination.parent.is_symlink():
        raise ValueError("Destination parent must be an existing staging directory")
    if destination.is_symlink() or destination.exists():
        raise FileExistsError("SQL staging output already exists")

    compressed = lower_name.endswith(".gz")
    with source.open("rb") as infile:
        header = infile.read(2)
    if compressed and header != b"\x1f\x8b":
        raise ValueError("Invalid gzip header")
    if not compressed and header == b"\x1f\x8b":
        raise ValueError("Compressed SQL must have a .gz extension")
    if not compressed and source.stat().st_size > MAX_UNCOMPRESSED_BYTES:
        raise ValueError("SQL exceeds uncompressed size limit")

    # This is a helpful early estimate for plain SQL; compressed SQL is
    # checked as bytes are expanded, preventing decompression bombs.
    if not compressed and shutil.disk_usage(destination.parent).free < source.stat().st_size:
        raise ValueError("Not enough disk space for SQL staging")

    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    written = 0
    created = False
    try:
        fd = os.open(destination, flags, 0o600)
        created = True
        with os.fdopen(fd, "wb") as outfile:
            opener = gzip.open if compressed else open
            with opener(source, "rb") as infile:
                while chunk := infile.read(CHUNK_SIZE):
                    written += len(chunk)
                    if written > MAX_UNCOMPRESSED_BYTES:
                        raise ValueError("SQL exceeds uncompressed size limit")
                    outfile.write(chunk)
        if written == 0:
            raise ValueError("SQL dump is empty")
    except BaseException:
        if created:
            destination.unlink(missing_ok=True)
        raise
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        size = prepare(args.source, args.output)
    except (OSError, ValueError, EOFError) as exc:
        print(f"SQL staging failed: {exc}", file=sys.stderr)
        return 1
    print(f"SQL staged successfully ({size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
