#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT/scripts/pull-wordpress-ssh.py" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import zipfile

spec = importlib.util.spec_from_file_location("pull_ssh", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

assert m.validate("my-production", "/home/test/public_html", "new-copy") == "/home/test/public_html"
assert m.validate("my-production", "/home/test/public_html/", "new-copy") == "/home/test/public_html"
for alias, path, site in [
    ("evil;ls", "/var/www/html", "new"),
    ("user@prod", "/var/www/html", "new"),
    ("my-prod", "/var/www/html/../private", "new"),
    ("my-prod", "relative/path", "new"),
    ("my-prod", "/", "new"),
    ("my-prod", "/var/www/html", "../escape"),
    ("my-prod", "/var/www/evil\ncmd", "new"),
]:
    try:
        m.validate(alias, path, site)
    except ValueError:
        pass
    else:
        raise AssertionError("Accepted unsafe SSH pull argument")

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    sites = root / "sites"
    sites.mkdir()
    fakebin = root / "bin"
    fakebin.mkdir()
    operations = root / "operations.log"

    fake_docker = fakebin / "docker"
    fake_docker.write_text("""#!/usr/bin/env python3
import os
import sys
args = sys.argv[1:]
if args[:1] == ["info"]:
    if os.environ.get("MOCK_DOCKER_FAIL_INFO") == "1":
        raise SystemExit(1)
    print("disposable-docker-test-engine")
    raise SystemExit(0)
if len(args) == 3 and args[1] == "inspect":
    raise SystemExit(0 if args[2] == os.environ.get("MOCK_DOCKER_CONFLICT") else 1)
raise SystemExit(2)
""")
    fake_docker.chmod(0o700)
    fake_ssh = fakebin / "ssh"
    fake_ssh.write_text("""#!/usr/bin/env python3
import os
import sys
from pathlib import Path
args = sys.argv[1:]
remote_command = args[-1]
with Path(os.environ['MOCK_OPERATIONS']).open('a') as f:
    f.write('ssh:' + remote_command + '\\n')
if os.environ.get('MOCK_SSH_FAIL') == '1':
    print('Remote probe/export failed', file=sys.stderr)
    raise SystemExit(5)
if 'wp db prefix' in remote_command:
    print('synt_')
elif 'wp db export' in remote_command:
    sys.stdout.write('-- SQL dump test generated on remote stdout\\n')
    sys.stdout.write('CREATE TABLE synt_options (option_id INT);\\n')
else:
    raise SystemExit('Unexpected remote command')
""")
    fake_ssh.chmod(0o700)

    fake_rsync = fakebin / "rsync"
    fake_rsync.write_text("""#!/usr/bin/env python3
import os
import sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ['MOCK_OPERATIONS']).open('a') as f:
    f.write('rsync:' + ' '.join(args) + '\\n')
if '--delete' in args or '--copy-links' in args:
    raise SystemExit('Unsafe rsync operation')
target = Path(args[-1])
(target / 'plugins').mkdir(parents=True, exist_ok=True)
(target / 'plugins/test.php').write_text('<?php // synthetic fixture')
(target / 'uploads').mkdir(exist_ok=True)
(target / 'uploads/image.txt').write_text('synthetic upload')
""")
    fake_rsync.chmod(0o700)

    saved = os.environ.copy()
    os.environ.update({
        "PATH": str(fakebin) + os.pathsep + saved.get("PATH", ""),
        "MOCK_OPERATIONS": str(operations),
        "SITES_DIR": str(sites),
        "PROXY_DIR": str(root / "proxy"),
    })
    try:
        m.pull("dry-run", "prod-alias", "/srv/wordpress", True)
        assert not operations.read_text().count("rsync:")
        assert sorted(sites.iterdir()) == []

        # Docker is global even when site roots are isolated. Refuse existing
        # container, volume, image and network names before opening SSH.
        for name in (
            "docal-collision-db", "docal-collision-wp",
            "collision_db-data", "collision_db-socket",
            "docal/wordpress-collision:latest", "collision_default",
        ):
            os.environ["MOCK_DOCKER_CONFLICT"] = name
            before_log = operations.read_text()
            try:
                m.pull("collision", "prod-alias", "/srv/wordpress", False)
            except ValueError as e:
                assert name in str(e)
            else:
                raise AssertionError("Accepted Docker resource collision: " + name)
            assert operations.read_text() == before_log
            assert not (sites / "collision").exists()
        os.environ.pop("MOCK_DOCKER_CONFLICT")

        os.environ["MOCK_DOCKER_FAIL_INFO"] = "1"
        before_log = operations.read_text()
        try:
            m.pull("no-daemon", "prod-alias", "/srv/wordpress", False)
        except RuntimeError:
            pass
        else:
            raise AssertionError("Accepted inaccessible Docker Engine")
        assert operations.read_text() == before_log
        os.environ.pop("MOCK_DOCKER_FAIL_INFO")

        observed = {}
        def inspect_import(site, zip_file, sql_file):
            observed["site"] = site
            observed["stage"] = zip_file.parent
            with zipfile.ZipFile(zip_file) as zf:
                names = set(zf.namelist())
                assert "wp-content/plugins/test.php" in names
                assert "wp-content/uploads/image.txt" in names
                assert "wp-config.php" not in names
                assert zf.read("wp-content/uploads/image.txt") == b"synthetic upload"
            assert sql_file.read_bytes().startswith(b"-- SQL dump")
            assert sql_file.stat().st_mode & 0o777 == 0o600
            assert zip_file.stat().st_mode & 0o777 == 0o600
        original_invoke = m.invoke_import
        m.invoke_import = inspect_import
        try:
            m.pull("new-import", "prod-alias", "/srv/wordpress", False)
        finally:
            m.invoke_import = original_invoke
        assert observed["site"] == "new-import"
        assert not observed["stage"].exists()
        assert sorted(sites.iterdir()) == []
        log = operations.read_text()
        assert "wp db prefix" in log
        assert "wp db export" in log
        assert "--single-transaction" in log
        assert "--skip-lock-tables" in log
        assert "--delete" not in log
        assert "rsync:" in log

        os.environ["MOCK_SSH_FAIL"] = "1"
        try:
            m.pull("bad-remote", "prod-alias", "/srv/wordpress", False)
        except RuntimeError:
            pass
        else:
            raise AssertionError("SSH failure was ignored")
        assert not (sites / "bad-remote").exists()
        assert sorted(sites.iterdir()) == []

        (sites / "existing").mkdir()
        (sites / "existing" / ".env").write_text("untouched")
        prior_log = operations.read_text()
        try:
            m.pull("existing", "prod-alias", "/srv/wordpress", True)
        except ValueError:
            pass
        else:
            raise AssertionError("Existing local site overwritten")
        assert (sites / "existing" / ".env").read_text() == "untouched"
        assert operations.read_text() == prior_log
    finally:
        os.environ.clear()
        os.environ.update(saved)

print("SSH pull validation, mocked transfer and safety tests passed")
PY
