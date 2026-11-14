#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${ROOT}/scripts/prepare-sql-dump.py" <<'PY'
import gzip
import importlib.util
import os
from pathlib import Path
import tempfile
import sys

spec = importlib.util.spec_from_file_location("sql_stage", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    sql = root / "source.sql"
    gz = root / "source.sql.gz"
    content = b"-- local test\nCREATE TABLE wp_options (option_id INT);\n"
    sql.write_bytes(content)
    with gzip.open(gz, "wb") as fh:
        fh.write(content)
    output1 = root / "first.sql"
    assert module.prepare(sql, output1) == len(content)
    assert output1.read_bytes() == content
    assert (output1.stat().st_mode & 0o777) == 0o600
    assert sql.read_bytes() == content

    output2 = root / "second.sql"
    assert module.prepare(gz, output2) == len(content)
    assert output2.read_bytes() == content
    assert gz.exists()

    # Existing stage files must never be overwritten.
    try:
        module.prepare(sql, output2)
    except FileExistsError:
        pass
    else:
        raise AssertionError("Existing staged SQL was overwritten")
    assert output2.read_bytes() == content

    invalid = root / "invalid.gz"
    invalid.write_bytes(b"not a gzip file")
    try:
        module.prepare(invalid, root / "bad.sql")
    except ValueError:
        assert not (root / "bad.sql").exists()
    else:
        raise AssertionError("Invalid gzip header accepted")

    truncated = root / "truncated.sql.gz"
    truncated.write_bytes(gz.read_bytes()[:-6])
    try:
        module.prepare(truncated, root / "truncated-output.sql")
    except (EOFError, OSError):
        assert not (root / "truncated-output.sql").exists()
    else:
        raise AssertionError("Truncated gzip was accepted")

    empty = root / "empty.sql.gz"
    with gzip.open(empty, "wb") as fh:
        pass
    try:
        module.prepare(empty, root / "empty-output.sql")
    except ValueError:
        assert not (root / "empty-output.sql").exists()
    else:
        raise AssertionError("Empty SQL was accepted")

    link = root / "source-link.sql"
    link.symlink_to(sql)
    try:
        module.prepare(link, root / "symlink-output.sql")
    except ValueError:
        assert not (root / "symlink-output.sql").exists()
    else:
        raise AssertionError("Symlink source was accepted")

    original_limit = module.MAX_UNCOMPRESSED_BYTES
    module.MAX_UNCOMPRESSED_BYTES = 8
    try:
        module.prepare(gz, root / "size-output.sql")
    except ValueError:
        assert not (root / "size-output.sql").exists()
    else:
        raise AssertionError("Uncompressed size limit was ignored")
    module.MAX_UNCOMPRESSED_BYTES = original_limit

print("SQL dump preparation tests passed")
PY
