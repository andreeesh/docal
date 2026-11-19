#!/usr/bin/env python3
"""Temporary-filesystem tests for Docal's snapshot storage foundation."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from multiprocessing import Process, Pipe
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

import snapshot_store as snapshots  # noqa: E402


def make_snapshot(store, identity, *, snapshot_id=None, body=b"synthetic database"):
    with store.writer(identity, snapshot_id=snapshot_id) as writer:
        writer.write_payload("database.sql.gz", body)
        manifest = writer.publish(
            consistency="transactional",
            docal_version="0.5.0-dev",
            database_engine="mysql",
            database_version="8.4",
        )
    return manifest


def leave_interrupted_stage(site_dir, store_root, ready_connection):
    identity = snapshots.load_or_create_site_identity(site_dir)
    store = snapshots.SnapshotStore(store_root)
    writer = store.writer(identity)
    writer.__enter__()
    writer.write_payload("database.sql.gz", b"partial synthetic data")
    ready_connection.send_bytes(b"staged")
    # Simulate abrupt process termination: context managers and cleanup do not run.
    os._exit(23)


def hold_site_lock(identity, store_root, ready_connection):
    store = snapshots.SnapshotStore(store_root)
    with store.lock(identity, timeout=2):
        ready_connection.send_bytes(b"locked")
        import time
        time.sleep(0.35)


class SnapshotStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.site_dir = self.root / "sites" / "alpha"
        self.site_dir.mkdir(parents=True)
        self.store_root = self.root / "home" / ".local" / "share" / "docal" / "snapshots"
        self.store = snapshots.SnapshotStore(self.store_root)
        self.identity = snapshots.load_or_create_site_identity(self.site_dir)

    def tearDown(self):
        self.temp.cleanup()

    def assert_snapshot_error(self, code, func, *args, **kwargs):
        with self.assertRaises(snapshots.SnapshotError) as caught:
            func(*args, **kwargs)
        self.assertEqual(caught.exception.code, code)
        self.assertEqual(caught.exception.to_dict()["error"]["code"], code)
        return caught.exception

    def test_store_root_resolution(self):
        home = self.root / "home"
        self.assertEqual(
            snapshots.resolve_store_root(environ={}, home=home),
            home / ".local/share/docal/snapshots",
        )
        self.assertEqual(
            snapshots.resolve_store_root(environ={"XDG_DATA_HOME": str(home / "data")}),
            home / "data/docal/snapshots",
        )
        self.assertEqual(
            snapshots.resolve_store_root(environ={"DOCAL_SNAPSHOTS_DIR": str(self.store_root)}),
            self.store_root,
        )
        self.assert_snapshot_error(
            "INVALID_STORE_PATH",
            snapshots.resolve_store_root,
            environ={"XDG_DATA_HOME": "relative"},
        )
        self.assert_snapshot_error(
            "INVALID_STORE_PATH",
            snapshots.resolve_store_root,
            "relative/path",
            environ={},
        )

    def test_store_is_private_and_separate_from_site_and_docal_home(self):
        make_snapshot(self.store, self.identity)
        self.assertEqual(stat.S_IMODE(self.store_root.stat().st_mode), 0o700)
        site_root = self.store_root / self.identity.site_id
        self.assertEqual(stat.S_IMODE(site_root.stat().st_mode), 0o700)
        self.assertNotEqual(site_root.resolve(), self.site_dir.resolve())

        bad_roots = [self.site_dir, self.site_dir / "backups"]
        for bad_root in bad_roots:
            bad_store = snapshots.SnapshotStore(bad_root)
            self.assert_snapshot_error("UNSAFE_STORE_PATH", bad_store.list_snapshot_ids, self.identity)
        with patch.dict(os.environ, {"DOCAL_HOME": str(self.root / "home" / ".docal")}):
            bad_store = snapshots.SnapshotStore(self.root / "home" / ".docal")
            self.assert_snapshot_error("UNSAFE_STORE_PATH", bad_store.list_snapshot_ids, self.identity)

    def test_store_root_symlink_is_rejected(self):
        outside = self.root / "outside"
        outside.mkdir()
        linked = self.root / "linked-store"
        linked.symlink_to(outside, target_is_directory=True)
        self.assert_snapshot_error("UNSAFE_STORE_PATH", snapshots.SnapshotStore, linked)

    def test_existing_broad_directory_is_not_chmodded_as_a_store(self):
        broad = self.root / "shared"
        broad.mkdir(mode=0o755)
        broad.chmod(0o755)
        store = snapshots.SnapshotStore(broad)
        self.assert_snapshot_error("UNSAFE_PERMISSIONS", store.list_snapshot_ids, self.identity)
        self.assertEqual(stat.S_IMODE(broad.stat().st_mode), 0o755)

    def test_site_identity_is_stable_private_and_does_not_store_path(self):
        marker = self.site_dir / snapshots.IDENTITY_FILENAME
        before = marker.read_bytes()
        identity_again = snapshots.load_or_create_site_identity(self.site_dir)
        self.assertEqual(identity_again.site_id, self.identity.site_id)
        self.assertEqual(identity_again.path_binding, self.identity.path_binding)
        self.assertEqual(marker.read_bytes(), before)
        self.assertEqual(stat.S_IMODE(marker.stat().st_mode), 0o600)
        self.assertNotIn(str(self.site_dir).encode(), before)
        self.assertEqual(identity_again.to_dict(), {
            "site_id": self.identity.site_id,
            "path_binding": self.identity.path_binding,
        })

    def test_copied_identity_cannot_be_used_at_another_path(self):
        other_site = self.root / "sites" / "other"
        other_site.mkdir()
        shutil.copy2(self.site_dir / snapshots.IDENTITY_FILENAME,
                     other_site / snapshots.IDENTITY_FILENAME)
        self.assert_snapshot_error(
            "SITE_IDENTITY_MISMATCH",
            snapshots.load_or_create_site_identity,
            other_site,
        )
        # Verification of a removed identity fails closed and does not silently
        # mint a replacement identity that could orphan or misbind snapshots.
        marker = self.site_dir / snapshots.IDENTITY_FILENAME
        marker.unlink()
        self.assert_snapshot_error(
            "IDENTITY_MISSING", self.store.list_snapshot_ids, self.identity,
        )
        self.assertFalse(marker.exists())

    def test_site_identity_symlink_is_rejected(self):
        marker = self.site_dir / snapshots.IDENTITY_FILENAME
        marker.unlink()
        outside = self.root / "outside-identity"
        outside.write_text("synthetic fixture")
        marker.symlink_to(outside)
        self.assert_snapshot_error(
            "IDENTITY_INVALID", snapshots.load_or_create_site_identity, self.site_dir,
        )

    def test_snapshot_ids_are_orderable_and_unique(self):
        earlier = datetime(2026, 1, 1, tzinfo=timezone.utc)
        later = datetime(2026, 1, 2, tzinfo=timezone.utc)
        first = snapshots.generate_snapshot_id(earlier)
        second = snapshots.generate_snapshot_id(later)
        self.assertLess(first, second)
        self.assertRegex(first, snapshots.SNAPSHOT_ID_RE)
        self.assertNotEqual(
            snapshots.generate_snapshot_id(earlier),
            snapshots.generate_snapshot_id(earlier),
        )

    def test_create_publish_verify_and_private_modes(self):
        manifest = make_snapshot(self.store, self.identity)
        snapshot_id = manifest["snapshot_id"]
        snapshot_dir = self.store_root / self.identity.site_id / snapshot_id
        self.assertEqual(self.store.list_snapshot_ids(self.identity), [snapshot_id])
        verified = self.store.verify_snapshot(self.identity, snapshot_id)
        self.assertEqual(verified, manifest)
        self.assertEqual(stat.S_IMODE(snapshot_dir.stat().st_mode), 0o700)
        for file in snapshot_dir.iterdir():
            self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
        encoded = (snapshot_dir / snapshots.MANIFEST_FILENAME).read_text()
        self.assertNotIn(str(self.site_dir), encoded)
        self.assertNotIn("DB_PASSWORD", encoded)
        self.assertNotIn("secret", encoded.lower())

    def test_manifest_has_strict_schema_and_bad_json_is_rejected(self):
        manifest = make_snapshot(self.store, self.identity)
        snapshot_dir = self.store_root / self.identity.site_id / manifest["snapshot_id"]
        manifest_path = snapshot_dir / snapshots.MANIFEST_FILENAME
        checksum_path = snapshot_dir / snapshots.MANIFEST_CHECKSUM_FILENAME

        invalid = dict(manifest)
        invalid["unexpected"] = "field"
        raw = json.dumps(invalid, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        manifest_path.write_bytes(raw)
        manifest_path.chmod(0o600)
        checksum_path.write_text(hashlib.sha256(raw).hexdigest() + "\n")
        checksum_path.chmod(0o600)
        self.assert_snapshot_error(
            "MANIFEST_INVALID", self.store.verify_snapshot, self.identity, manifest["snapshot_id"],
        )

        raw = b'{"format_version":1,"format_version":1}\n'
        manifest_path.write_bytes(raw)
        checksum_path.write_text(hashlib.sha256(raw).hexdigest() + "\n")
        self.assert_snapshot_error(
            "MANIFEST_INVALID", self.store.verify_snapshot, self.identity, manifest["snapshot_id"],
        )

        raw = b"{ definitely not json }\n"
        manifest_path.write_bytes(raw)
        checksum_path.write_text(hashlib.sha256(raw).hexdigest() + "\n")
        self.assert_snapshot_error(
            "MANIFEST_INVALID", self.store.verify_snapshot, self.identity, manifest["snapshot_id"],
        )

    def test_malformed_types_return_stable_errors_not_python_type_errors(self):
        manifest = make_snapshot(self.store, self.identity)
        snapshot_dir = self.store_root / self.identity.site_id / manifest["snapshot_id"]
        altered = dict(manifest)
        altered["kind"] = []
        raw = json.dumps(altered, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        (snapshot_dir / snapshots.MANIFEST_FILENAME).write_bytes(raw)
        (snapshot_dir / snapshots.MANIFEST_CHECKSUM_FILENAME).write_text(
            hashlib.sha256(raw).hexdigest() + "\n"
        )
        self.assert_snapshot_error(
            "MANIFEST_INVALID", self.store.verify_snapshot, self.identity, manifest["snapshot_id"],
        )

    def test_manifest_version_metadata_is_allow_listed(self):
        writer = self.store.writer(self.identity)
        with writer:
            writer.write_payload("database.sql.gz", b"synthetic")
            self.assert_snapshot_error(
                "INVALID_ARGUMENT",
                writer.publish,
                database_version="password=must-not-be-stored",
            )
        self.assertEqual(self.store.list_snapshot_ids(self.identity), [])

    def test_manifest_and_payload_checksums_are_verified(self):
        manifest = make_snapshot(self.store, self.identity)
        snapshot_dir = self.store_root / self.identity.site_id / manifest["snapshot_id"]
        payload = snapshot_dir / "database.sql.gz"
        payload.write_bytes(b"corrupted synthetic database")
        payload.chmod(0o600)
        self.assert_snapshot_error(
            "CHECKSUM_MISMATCH", self.store.verify_snapshot, self.identity, manifest["snapshot_id"],
        )

        payload.write_bytes(b"synthetic database")
        payload.chmod(0o600)
        (snapshot_dir / snapshots.MANIFEST_CHECKSUM_FILENAME).write_text("0" * 64 + "\n")
        (snapshot_dir / snapshots.MANIFEST_CHECKSUM_FILENAME).chmod(0o600)
        self.assert_snapshot_error(
            "MANIFEST_CHECKSUM_MISMATCH", self.store.verify_snapshot,
            self.identity, manifest["snapshot_id"],
        )

    def test_snapshot_id_traversal_and_symlink_payload_are_rejected(self):
        self.assert_snapshot_error(
            "INVALID_ARGUMENT", self.store.verify_snapshot, self.identity, "../outside",
        )
        manifest = make_snapshot(self.store, self.identity)
        snapshot_dir = self.store_root / self.identity.site_id / manifest["snapshot_id"]
        payload = snapshot_dir / "database.sql.gz"
        payload.unlink()
        outside = self.root / "outside-payload"
        outside.write_bytes(b"synthetic outside")
        payload.symlink_to(outside)
        self.assert_snapshot_error(
            "UNSAFE_PATH", self.store.verify_snapshot, self.identity, manifest["snapshot_id"],
        )

        writer = self.store.writer(self.identity)
        with self.assertRaises(snapshots.SnapshotError) as caught:
            with writer:
                writer.write_payload("../outside.sql.gz", b"synthetic")
        self.assertEqual(caught.exception.code, "INVALID_MANIFEST")

    def test_snapshot_directory_symlinks_are_rejected(self):
        manifest = make_snapshot(self.store, self.identity)
        snapshot_dir = self.store_root / self.identity.site_id / manifest["snapshot_id"]
        outside = self.root / "outside-snapshot"
        snapshot_dir.rename(outside)
        snapshot_dir.symlink_to(outside, target_is_directory=True)
        self.assert_snapshot_error(
            "UNSAFE_PATH", self.store.list_snapshot_ids, self.identity,
        )

    def test_id_collisions_never_overwrite_existing_snapshot(self):
        fixed_id = "20260101T000000000000Z-0123456789ab"
        original = make_snapshot(self.store, self.identity, snapshot_id=fixed_id)
        with patch("snapshot_store.generate_snapshot_id", return_value=fixed_id):
            with self.assertRaises(snapshots.SnapshotError) as caught:
                with self.store.writer(self.identity):
                    pass
        self.assertEqual(caught.exception.code, "SNAPSHOT_EXISTS")
        self.assertEqual(self.store.verify_snapshot(self.identity, fixed_id), original)

        empty_collision = "20260102T000000000000Z-0123456789ab"
        collision_path = self.store_root / self.identity.site_id / empty_collision
        collision_path.mkdir()
        with self.assertRaises(snapshots.SnapshotError) as caught:
            with self.store.writer(self.identity, snapshot_id=empty_collision):
                pass
        self.assertEqual(caught.exception.code, "SNAPSHOT_EXISTS")
        self.assertTrue(collision_path.is_dir())
        self.assertEqual(list(collision_path.iterdir()), [])

    def test_failed_context_write_is_not_published(self):
        writer = self.store.writer(self.identity)
        with self.assertRaises(RuntimeError):
            with writer:
                writer.write_payload("database.sql.gz", b"partial")
                raise RuntimeError("synthetic interruption")
        self.assertEqual(self.store.list_snapshot_ids(self.identity), [])
        site_root = self.store_root / self.identity.site_id
        self.assertFalse(any(p.name.startswith(".staging-") for p in site_root.iterdir()))

    def test_abrupt_interruption_leaves_only_ignored_private_staging(self):
        parent, child = Pipe(duplex=False)
        process = Process(target=leave_interrupted_stage,
                          args=(self.site_dir, self.store_root, child))
        process.start()
        child.close()
        self.assertTrue(parent.poll(5), "interrupted writer did not reach its staging point")
        self.assertEqual(parent.recv_bytes(), b"staged")
        parent.close()
        process.join(timeout=5)
        self.assertEqual(process.exitcode, 23)
        self.assertEqual(self.store.list_snapshot_ids(self.identity), [])
        site_root = self.store_root / self.identity.site_id
        partials = [p for p in site_root.iterdir() if p.name.startswith(".staging-")]
        self.assertEqual(len(partials), 1)
        self.assertEqual(stat.S_IMODE(partials[0].stat().st_mode), 0o700)

    def test_publication_is_atomic_from_listing_perspective(self):
        writer = self.store.writer(self.identity)
        with writer:
            self.assertEqual(self.store.list_snapshot_ids(self.identity), [])
            writer.write_payload("database.sql.gz", b"complete synthetic payload")
            self.assertEqual(self.store.list_snapshot_ids(self.identity), [])
            manifest = writer.publish()
            self.assertEqual(self.store.list_snapshot_ids(self.identity), [manifest["snapshot_id"]])
        self.assertEqual(
            self.store.verify_snapshot(self.identity, manifest["snapshot_id"]), manifest,
        )

    def test_lock_serializes_concurrent_processes(self):
        parent, child = Pipe(duplex=False)
        process = Process(target=hold_site_lock,
                          args=(self.identity, self.store_root, child))
        process.start()
        child.close()
        self.assertTrue(parent.poll(5), "lock holder did not acquire the site lock")
        self.assertEqual(parent.recv_bytes(), b"locked")
        parent.close()
        other_site = self.root / "sites" / "independent"
        other_site.mkdir()
        other_identity = snapshots.load_or_create_site_identity(other_site)
        with self.store.lock(other_identity, timeout=0.1):
            pass
        self.assert_snapshot_error(
            "LOCK_TIMEOUT", lambda: self._acquire_immediately(self.store, self.identity),
        )
        process.join(timeout=5)
        self.assertEqual(process.exitcode, 0)
        with self.store.lock(self.identity, timeout=0.2):
            pass

    @staticmethod
    def _acquire_immediately(store, identity):
        with store.lock(identity, timeout=0.05):
            pass

    def test_sites_are_isolated_and_other_site_snapshots_are_not_reusable(self):
        first = make_snapshot(self.store, self.identity)
        other_site = self.root / "sites" / "beta"
        other_site.mkdir()
        other_identity = snapshots.load_or_create_site_identity(other_site)
        self.assertEqual(self.store.list_snapshot_ids(other_identity), [])
        first_snapshot_dir = (
            self.store_root / self.identity.site_id / first["snapshot_id"]
        )
        other_snapshot_dir = (
            self.store_root / other_identity.site_id / first["snapshot_id"]
        )
        other_snapshot_dir.parent.mkdir(parents=True, mode=0o700)
        shutil.copytree(first_snapshot_dir, other_snapshot_dir)
        self.assert_snapshot_error(
            "SITE_IDENTITY_MISMATCH", self.store.verify_snapshot,
            other_identity, first["snapshot_id"],
        )

    def test_snapshots_survive_uninstall_scope_and_unrelated_site_cleanup(self):
        manifest = make_snapshot(self.store, self.identity)
        uninstall_root = self.root / "home" / ".docal"
        uninstall_root.mkdir(parents=True)
        (uninstall_root / "config").write_text("synthetic local config")
        shutil.rmtree(uninstall_root)
        self.assertEqual(
            self.store.verify_snapshot(self.identity, manifest["snapshot_id"]), manifest,
        )
        unrelated_site = self.root / "sites" / "unrelated"
        unrelated_site.mkdir()
        (unrelated_site / "synthetic.txt").write_text("test only")
        shutil.rmtree(unrelated_site)
        self.assertEqual(self.store.list_snapshot_ids(self.identity), [manifest["snapshot_id"]])

    def test_snapshot_payload_survives_site_directory_removal(self):
        manifest = make_snapshot(self.store, self.identity)
        snapshot_dir = self.store_root / self.identity.site_id / manifest["snapshot_id"]
        expected_payload = (snapshot_dir / "database.sql.gz").read_bytes()
        shutil.rmtree(self.site_dir)
        self.assertTrue(snapshot_dir.is_dir())
        self.assertEqual((snapshot_dir / "database.sql.gz").read_bytes(), expected_payload)

    def test_store_permissions_are_checked_when_reading(self):
        manifest = make_snapshot(self.store, self.identity)
        self.store_root.chmod(0o755)
        self.assert_snapshot_error(
            "UNSAFE_PERMISSIONS", self.store.list_snapshot_ids, self.identity,
        )
        self.store_root.chmod(0o700)
        snapshot_dir = self.store_root / self.identity.site_id / manifest["snapshot_id"]
        snapshot_dir.chmod(0o755)
        self.assert_snapshot_error(
            "UNSAFE_PATH", self.store.verify_snapshot, self.identity, manifest["snapshot_id"],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
