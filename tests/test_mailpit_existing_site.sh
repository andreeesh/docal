#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT/scripts/mailpit-site.py" <<'PY'
import importlib.util
from pathlib import Path
import tempfile
import sys

spec = importlib.util.spec_from_file_location("mailpit_site", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    site = root / "site-qa"
    content = site / "wordpress" / "wp-content"
    content.mkdir(parents=True)
    (site / ".env").write_text("SITE_SLUG=site-qa\n")
    (site / "docker-compose.yml").write_text("services: {}\n")
    config = site / "wordpress" / "wp-config.php"
    config.write_text("<?php // local fixture only")
    other_file = content / "other.php"
    other_file.write_text("<?php // preserve")
    config_snapshot = config.read_bytes()

    m.enable(site)
    target = content / "mu-plugins" / m.PLUGIN_NAME
    assert target.read_text() == m.PLUGIN_SOURCE
    assert "phpmailer_init" in target.read_text()
    assert "PHP_INT_MAX" in target.read_text()
    assert "docal-mailpit" in target.read_text()
    assert "SMTPAuth = false" in target.read_text()
    assert "SMTPAutoTLS = false" in target.read_text()
    assert "1025" in target.read_text()
    m.enable(site)  # Idempotent
    assert config.read_bytes() == config_snapshot
    assert other_file.read_text() == "<?php // preserve"

    target.write_text("<?php // user-edited plugin")
    for action in (m.enable, m.disable):
        try:
            action(site)
        except ValueError as e:
            assert "differs" in str(e)
        else:
            raise AssertionError("Modified plugin was silently replaced or deleted")
    assert target.read_text() == "<?php // user-edited plugin"

    target.unlink()
    m.enable(site)
    m.disable(site)
    m.disable(site)  # Idempotent
    assert not target.exists()
    assert config.read_bytes() == config_snapshot
    assert other_file.exists()

    # A symbolic link inside the WordPress path must never be followed.
    (content / "mu-plugins").rmdir()
    (content / "mu-plugins").symlink_to(root / "outside")
    try:
        m.enable(site)
    except ValueError as e:
        assert "symlinked" in str(e)
    else:
        raise AssertionError("Symlinked mu-plugins directory accepted")
    (content / "mu-plugins").unlink()

    (site / ".docal-import-pending").touch()
    try:
        m.enable(site)
    except ValueError as e:
        assert "incomplete" in str(e)
    else:
        raise AssertionError("Import-pending site accepted")

print("Existing-site Mailpit integration is reversible, scoped, and fail-closed")
PY
