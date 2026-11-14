#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${ROOT}/scripts/import-wordpress-zip-sql.py" <<'PY'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("import_site", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    bindir = root / "bin"
    bindir.mkdir()
    fake = bindir / "mkcert"
    fake.write_text("""#!/usr/bin/env python3
import pathlib, sys
if sys.argv[1:] == ['-install']:
    print('sudo: a terminal is required to authenticate', file=sys.stderr)
    raise SystemExit(1)
args = sys.argv[1:]
for option, value in zip(args, args[1:]):
    if option == '-cert-file': pathlib.Path(value).write_text('test certificate')
    if option == '-key-file': pathlib.Path(value).write_text('test private key')
""")
    fake.chmod(0o700)
    old_path = os.environ.get("PATH", "")
    os.environ["PATH"] = str(bindir) + os.pathsep + old_path
    certs = root / "proxy"
    result = subprocess.run(
        [sys.executable, "-c", "from pathlib import Path; import sys; "
         "import importlib.util; s=importlib.util.spec_from_file_location('m',sys.argv[1]); "
         "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
         "m.certificate('synthetic.localhost',Path(sys.argv[2]))",
         sys.argv[1], str(certs)],
        text=True, capture_output=True, env=os.environ.copy(), check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "Could not install the local CA" in result.stderr
    assert (certs / "certs/synthetic.localhost.crt").is_file()
    key = certs / "certs/synthetic.localhost.key"
    assert key.is_file() and (key.stat().st_mode & 0o777) == 0o600
    assert (certs / "certs/synthetic.localhost.yml").is_file()
    os.environ["PATH"] = old_path

print("Certificate generation fallback test passed")
PY
