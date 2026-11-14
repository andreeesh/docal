#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${ROOT}/scripts/validate-wordpress-zip.py" <<'PY'
import importlib.util
import pathlib
import tempfile
import zipfile
import sys

spec = importlib.util.spec_from_file_location("validator", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp) / "test.zip"
    def check(entries, expected=None):
        with zipfile.ZipFile(path, "w") as z:
            for name in entries:
                z.writestr(name, "content")
        if expected:
            assert module.validate(path) == expected, entries
        else:
            try:
                module.validate(path)
            except ValueError:
                return
            raise AssertionError(f"accepted unsafe ZIP: {entries}")
    check(["wp-content/plugins/a.php"], "wp-content")
    check(["site/wp-content/themes/a.php"], "wp-content")
    check(["wp-admin/index.php", "wp-includes/version.php", "wp-content/index.php"], "full-wordpress")
    check(["../wp-content/a.php"])
    check(["/wp-content/a.php"])
    check(["C:/wp-content/a.php"])
    check(["wp-content/a.php", "wp-content/a.php"])
    check(["wp-admin/index.php", "wp-content/index.php"])
print("WordPress ZIP preflight tests passed")
PY
