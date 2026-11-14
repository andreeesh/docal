#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${ROOT}/scripts/validate-wordpress-zip.py" <<'PY'
import importlib.util
import pathlib
import stat
import tempfile
import zipfile
import sys

spec = importlib.util.spec_from_file_location("validator", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    archive = root / "site.zip"

    def write_zip(entries):
        with zipfile.ZipFile(archive, "w") as z:
            for name, content in entries:
                z.writestr(name, content)

    write_zip([
        ("site/wp-admin/index.php", "admin"),
        ("site/wp-includes/version.php", "core"),
        ("site/wp-content/themes/theme/style.css", "theme"),
        ("site/wp-config.php", "PRODUCTION SECRET"),
        ("site/index.php", "index"),
    ])
    destination = root / "new-site"
    assert module.extract(archive, destination) == "full-wordpress"
    assert (destination / "wp-content/themes/theme/style.css").read_text() == "theme"
    assert (destination / "index.php").read_text() == "index"
    assert not (destination / "wp-config.php").exists()
    try:
        module.extract(archive, destination)
    except FileExistsError:
        pass
    else:
        raise AssertionError("Existing destination was overwritten")
    assert (destination / "index.php").read_text() == "index"

    write_zip([
        ("wp-content/plugins/test/plugin.php", "plugin"),
        ("wp-content/uploads/image.jpg", "image"),
        ("readme.txt", "ignore")
    ])
    dest2 = root / "content-only"
    assert module.extract(archive, dest2) == "wp-content"
    assert (dest2 / "wp-content/plugins/test/plugin.php").read_text() == "plugin"
    assert not (dest2 / "readme.txt").exists()

    for index, bad in enumerate(("../escape", "/absolute", "wp-content/../../escape", "C:/evil")):
        write_zip([("wp-content/index.php", "safe"), (bad, "bad")])
        dest_bad = root / ("unsafe-" + str(index))
        try:
            module.extract(archive, dest_bad)
        except ValueError:
            assert not dest_bad.exists()
        else:
            raise AssertionError(f"Unsafe archive accepted: {bad}")

    link = zipfile.ZipInfo("wp-content/plugins/link")
    link.create_system = 3
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("wp-content/index.php", "safe")
        z.writestr(link, "../../outside")
    dest_link = root / "link"
    try:
        module.extract(archive, dest_link)
    except ValueError:
        assert not dest_link.exists()
    else:
        raise AssertionError("ZIP symlink was accepted")

    # Corrupt content after creation, exercising CRC failure and cleanup.
    write_zip([("wp-content/index.php", "unchanged")])
    data = bytearray(archive.read_bytes())
    needle = data.find(b"unchanged")
    assert needle >= 0
    data[needle:needle + 9] = b"corrupted"
    archive.write_bytes(data)
    dest_crc = root / "corrupt"
    try:
        module.extract(archive, dest_crc)
    except zipfile.BadZipFile:
        assert not dest_crc.exists()
    else:
        raise AssertionError("CRC failure did not abort extraction")
    assert (destination / "index.php").read_text() == "index"

    # Resource limit and ambiguous archive-member checks run before creating output.
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr("wp-content/zeros.bin", bytes(2_000_000))
    try:
        module.extract(archive, root / "zip-bomb")
    except ValueError:
        assert not (root / "zip-bomb").exists()
    else:
        raise AssertionError("Excessive ZIP compression ratio was accepted")

    write_zip([
        ("wp-content/Plugin.php", "A"),
        ("wp-content/plugin.php", "B"),
    ])
    try:
        module.extract(archive, root / "case-collision")
    except ValueError:
        assert not (root / "case-collision").exists()
    else:
        raise AssertionError("Case-colliding ZIP entries were accepted")

    write_zip([
        ("wp-content/parent", "file"),
        ("wp-content/parent/child", "bad"),
    ])
    try:
        module.extract(archive, root / "file-dir-collision")
    except ValueError:
        assert not (root / "file-dir-collision").exists()
    else:
        raise AssertionError("File/directory collision was accepted")

print("WordPress ZIP extraction tests passed")
PY
