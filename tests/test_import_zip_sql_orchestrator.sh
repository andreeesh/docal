#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${ROOT}/scripts/import-wordpress-zip-sql.py" <<'PY'
import importlib.util
import os
from pathlib import Path
import tempfile
import sys
import zipfile

spec = importlib.util.spec_from_file_location("import_site", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

assert m.choose_prefix(["wp_options", "wp_users", "wp_usermeta"]) == "wp_"
assert m.choose_prefix(["abc_options", "abc_users", "abc_usermeta"]) == "abc_"
assert m.url_search_variants("https://example.test") == (
    "https://example.test",
    r"https:\/\/example.test",
    "http://example.test",
    r"http:\/\/example.test",
    "//example.test",
    r"\/\/example.test",
)
assert m.url_search_variants("http://www.example.test/subdir") == (
    "http://www.example.test/subdir",
    r"http:\/\/www.example.test\/subdir",
    "https://www.example.test/subdir",
    r"https:\/\/www.example.test\/subdir",
    "//www.example.test/subdir",
    r"\/\/www.example.test\/subdir",
)
assert m.choose_prefix([
    "wp_options", "wp_users", "wp_usermeta", "wp_2_options",
]) == "wp_"
for table_set in ([], ["wp_options", "wp_users"], [
    "wp_options", "wp_users", "wp_usermeta",
    "x_options", "x_users", "x_usermeta",
]):
    try:
        m.choose_prefix(table_set)
    except ValueError:
        pass
    else:
        raise AssertionError("Ambiguous or absent WordPress prefix accepted")

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    stage = root / "stage"
    wp = root / "wordpress"
    (stage / "wp-content" / "themes").mkdir(parents=True)
    (stage / "wp-content" / "themes" / "style.css").write_text("theme")
    (stage / "wp-config.php").write_text("production-secrets")
    (stage / ".git").mkdir()
    (stage / ".git" / "config").write_text("source-repository")
    wp.mkdir()
    local_config = wp / "wp-config.php"
    local_config.write_text(
        "<?php\n$table_prefix = 'wp_';\n"
        "require_once ABSPATH . 'wp-settings.php';\n"
    )
    assert m.copy_files(stage, wp) == 1
    assert local_config.read_text().startswith("<?php\n$table_prefix")
    assert not (wp / ".git").exists()
    m.update_config(local_config, "custom_")
    updated = local_config.read_text()
    assert "$table_prefix = 'custom_';" in updated
    assert "DISABLE_WP_CRON" in updated
    assert "WP_HTTP_BLOCK_EXTERNAL" in updated
    assert (local_config.stat().st_mode & 0o777) == 0o600

    # Same-origin URLs in copied theme and generated assets are normalized.
    assets = root / "assets"
    assets.mkdir()
    php_asset = assets / "theme.php"
    css_asset = assets / "generated.css"
    js_asset = assets / "builder.js"
    html_asset = assets / "page.html"
    json_asset = assets / "data.json"
    binary_asset = assets / "font.css"
    php_asset.write_text('<link href="https://example.test/media/hero.jpg">')
    css_asset.write_text('url(//www.example.test/media/background.webp)')
    js_asset.write_text(r'"src":"http:\/\/example.test\/media\/image.jpg"')
    html_asset.write_text(
        'mailto:team@example.test https://cdn.example.net/asset.css'
    )
    json_asset.write_text('{"url":"https://example.test/data"}')
    binary_asset.write_bytes(b'\x00https://example.test/font.woff2')
    changed_files, replacements = m.normalize_text_file_urls(
        assets,
        ["https://example.test", "https://www.example.test"],
        "https://local.test",
    )
    assert (changed_files, replacements) == (3, 3)
    assert 'https://local.test/media/hero.jpg' in php_asset.read_text()
    assert 'https://local.test/media/background.webp' in css_asset.read_text()
    assert r'https://local.test\/media\/image.jpg' in js_asset.read_text()
    assert 'team@example.test' in html_asset.read_text()
    assert 'https://cdn.example.net/asset.css' in html_asset.read_text()
    assert 'https://example.test/data' in json_asset.read_text()
    assert binary_asset.read_bytes() == b'\x00https://example.test/font.woff2'

    # Stage symlinks cannot affect files elsewhere.
    external = root / "external"
    external.write_text("safe")
    (stage / "wp-content" / "bad.php").symlink_to(external)
    try:
        m.copy_files(stage, wp)
    except ValueError:
        assert external.read_text() == "safe"
    else:
        raise AssertionError("Staged symlink was accepted")

    # Existing sites are rejected before staging or Docker setup.
    sites = root / "sites"
    sites.mkdir()
    existing = sites / "client-site"
    existing.mkdir()
    marker = existing / "important"
    marker.write_text("untouched")
    before = dict(os.environ)
    try:
        os.environ["SITES_DIR"] = str(sites)
        os.environ["PROXY_DIR"] = str(root / "proxy")
        try:
            m.restore("client-site", str(root / "missing.zip"), str(root / "missing.sql"))
        except ValueError:
            pass
        else:
            raise AssertionError("Existing site was accepted")
    finally:
        os.environ.clear()
        os.environ.update(before)
    assert marker.read_text() == "untouched"

# Failing subprocesses must never interpolate a generated admin password
# into a user-visible exception.
from types import SimpleNamespace
original_run = m.subprocess.run
try:
    m.subprocess.run = lambda *args, **kwargs: SimpleNamespace(returncode=12)
    try:
        m.run("wp", "user", "update", "--user_pass=PRIVATE_TEST_PASSWORD")
    except RuntimeError as exc:
        assert "PRIVATE_TEST_PASSWORD" not in str(exc)
        assert "12" in str(exc)
    else:
        raise AssertionError("Failed subprocess was treated as success")
finally:
    m.subprocess.run = original_run

print("ZIP + SQL orchestration preflight tests passed")
PY
