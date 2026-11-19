#!/usr/bin/env python3
"""Private, Docker-independent primitives for Docal snapshot storage.

This module deliberately does not create snapshots from WordPress or MySQL,
and is not wired into the Docal CLI yet. It provides site identity, private
storage, per-site locking, staged publication, versioned manifests and payload
integrity checks for later snapshot operations.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import time
from typing import BinaryIO, Iterator, Mapping
import uuid


FORMAT_VERSION = 1
IDENTITY_FILENAME = ".docal-snapshot-identity.json"
MANIFEST_FILENAME = "manifest.json"
MANIFEST_CHECKSUM_FILENAME = "manifest.sha256"
LOCK_FILENAME = ".lock"
MAX_MANIFEST_BYTES = 64 * 1024
CHUNK_SIZE = 1024 * 1024

SNAPSHOT_ID_RE = re.compile(r"^[0-9]{8}T[0-9]{12}Z-[0-9a-f]{12}$")
SITE_ID_RE = re.compile(r"^[0-9a-f]{32}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}$")
PAYLOADS_BY_KIND = {
    "database": {"database.sql.gz"},
    "full": {"database.sql.gz", "wordpress.tar.gz"},
}
CONSISTENCY_VALUES = {"transactional", "best_effort", "offline", "unknown"}
DATABASE_ENGINES = {"mysql", "mariadb", "unknown"}


class SnapshotError(Exception):
    """Stable, serializable error returned by the snapshot foundation."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message

    def to_dict(self) -> dict[str, object]:
        return {"ok": False, "error": {"code": self.code, "message": self.message}}


@dataclass(frozen=True)
class SiteIdentity:
    """Public identity fields plus a private, in-memory canonical site path."""

    site_id: str
    path_binding: str
    _canonical_path: Path = field(repr=False, compare=False)

    def to_dict(self) -> dict[str, str]:
        """Return safe identity data; never serialize the local path."""
        return {"site_id": self.site_id, "path_binding": self.path_binding}


def resolve_store_root(
    explicit: str | os.PathLike[str] | None = None,
    *,
    environ: Mapping[str, str] | None = None,
    home: str | os.PathLike[str] | None = None,
) -> Path:
    """Resolve an absolute, configurable root without creating it."""
    env = os.environ if environ is None else environ
    configured = explicit if explicit is not None else env.get("DOCAL_SNAPSHOTS_DIR")
    if configured is not None:
        path = Path(configured).expanduser()
        if not path.is_absolute():
            raise SnapshotError("INVALID_STORE_PATH", "Snapshot store path must be absolute")
        return path

    xdg = env.get("XDG_DATA_HOME")
    if xdg:
        xdg_path = Path(xdg).expanduser()
        if not xdg_path.is_absolute():
            raise SnapshotError("INVALID_STORE_PATH", "XDG_DATA_HOME must be absolute")
        return xdg_path / "docal" / "snapshots"

    home_path = Path(home).expanduser() if home is not None else Path.home()
    if not home_path.is_absolute():
        raise SnapshotError("INVALID_STORE_PATH", "Home directory must be absolute")
    return home_path / ".local" / "share" / "docal" / "snapshots"


def generate_snapshot_id(now: datetime | None = None) -> str:
    """Create a lexically time-sortable ID with a random collision suffix."""
    instant = now or datetime.now(timezone.utc)
    if instant.tzinfo is None:
        raise SnapshotError("INVALID_ARGUMENT", "Snapshot timestamp must include a timezone")
    instant = instant.astimezone(timezone.utc)
    return instant.strftime("%Y%m%dT%H%M%S%fZ") + "-" + secrets.token_hex(6)


def _canonical_site_path(site_dir: str | os.PathLike[str]) -> Path:
    raw = Path(site_dir).expanduser()
    try:
        mode = raw.lstat().st_mode
    except OSError as exc:
        raise SnapshotError("SITE_UNAVAILABLE", "Site directory is unavailable") from exc
    if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
        raise SnapshotError("UNSAFE_SITE_PATH", "Site path must be a real directory")
    try:
        return raw.resolve(strict=True)
    except OSError as exc:
        raise SnapshotError("UNSAFE_SITE_PATH", "Site path cannot be resolved safely") from exc


def _path_binding(site_id: str, canonical_path: Path) -> str:
    material = b"docal-site-path-v1\0" + site_id.encode("ascii") + b"\0"
    material += os.fsencode(canonical_path)
    return hashlib.sha256(material).hexdigest()


def _ensure_directory(path: Path, *, private: bool = True) -> None:
    """Create path components without following symlinks; privatize leaf."""
    absolute = Path(os.path.abspath(path))
    current = Path(absolute.anchor)
    leaf_created = False
    for part in absolute.parts[1:]:
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError:
            try:
                current.mkdir(mode=0o700)
                if current == absolute:
                    leaf_created = True
            except FileExistsError:
                pass
            except OSError as exc:
                raise SnapshotError("STORE_UNAVAILABLE", "Cannot create snapshot storage") from exc
            try:
                info = current.lstat()
            except OSError as exc:
                raise SnapshotError("STORE_UNAVAILABLE", "Cannot create snapshot storage") from exc
        except OSError as exc:
            raise SnapshotError("STORE_UNAVAILABLE", "Cannot inspect snapshot storage") from exc
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise SnapshotError("UNSAFE_STORE_PATH", "Snapshot storage contains an unsafe path")
    if private:
        try:
            info = path.lstat()
        except OSError as exc:
            raise SnapshotError("STORE_UNAVAILABLE", "Cannot inspect snapshot storage permissions") from exc
        if leaf_created:
            try:
                path.chmod(0o700)
            except OSError as exc:
                raise SnapshotError("STORE_UNAVAILABLE", "Cannot secure snapshot storage permissions") from exc
        elif info.st_mode & 0o077:
            # Do not chmod an existing user directory (or a shared system
            # directory such as /tmp) as a side effect of choosing a store.
            raise SnapshotError("UNSAFE_PERMISSIONS", "Existing snapshot storage directory is not private")


def _require_private_directory(path: Path) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise SnapshotError("STORE_UNAVAILABLE", "Snapshot storage directory is unavailable") from exc
    if not stat.S_ISDIR(info.st_mode):
        raise SnapshotError("UNSAFE_STORE_PATH", "Snapshot storage must be a real directory")
    if info.st_mode & 0o077:
        raise SnapshotError("UNSAFE_PERMISSIONS", "Snapshot storage directories must be private")


def _check_path_components(path: Path) -> None:
    """Reject symlinks and non-directories anywhere in an existing path."""
    absolute = Path(os.path.abspath(path))
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise SnapshotError("UNSAFE_STORE_PATH", "Cannot safely inspect snapshot storage") from exc
        if stat.S_ISLNK(info.st_mode):
            raise SnapshotError("UNSAFE_STORE_PATH", "Snapshot storage must not contain symlinks")


def _write_private_file(path: Path, data: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o600)
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except FileExistsError as exc:
        raise SnapshotError("PATH_COLLISION", "A snapshot storage path already exists") from exc
    except OSError as exc:
        raise SnapshotError("IO_ERROR", "Cannot write private snapshot data") from exc


def _fsync_directory(path: Path) -> None:
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as exc:
        raise SnapshotError("DURABILITY_UNCERTAIN", "Snapshot publication durability is uncertain") from exc


def _read_regular_file(path: Path, *, max_bytes: int | None = None) -> bytes:
    try:
        info = path.lstat()
    except OSError as exc:
        raise SnapshotError("MANIFEST_INVALID", "Required snapshot metadata is unavailable") from exc
    if not stat.S_ISREG(info.st_mode):
        raise SnapshotError("UNSAFE_PATH", "Snapshot metadata must be a regular file")
    if info.st_mode & 0o077:
        raise SnapshotError("UNSAFE_PERMISSIONS", "Snapshot files must be private")
    if max_bytes is not None and info.st_size > max_bytes:
        raise SnapshotError("MANIFEST_INVALID", "Snapshot manifest exceeds its size limit")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
        with os.fdopen(fd, "rb") as stream:
            data = stream.read((max_bytes + 1) if max_bytes is not None else -1)
    except OSError as exc:
        raise SnapshotError("UNSAFE_PATH", "Cannot safely read snapshot metadata") from exc
    if max_bytes is not None and len(data) > max_bytes:
        raise SnapshotError("MANIFEST_INVALID", "Snapshot manifest exceeds its size limit")
    return data


def load_or_create_site_identity(
    site_dir: str | os.PathLike[str],
    *,
    create: bool = True,
) -> SiteIdentity:
    """Load a site's stable ID, optionally creating a path-bound identity."""
    canonical = _canonical_site_path(site_dir)
    marker = canonical / IDENTITY_FILENAME
    try:
        marker_info = marker.lstat()
    except FileNotFoundError:
        if not create:
            raise SnapshotError("IDENTITY_MISSING", "Site identity file is missing")
        site_id = uuid.uuid4().hex
        binding = _path_binding(site_id, canonical)
        record = {
            "format_version": 1,
            "site_id": site_id,
            "path_binding": binding,
        }
        content = json.dumps(record, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        # O_EXCL makes concurrent first use safe; an interrupted marker is
        # intentionally not replaced because doing so could orphan snapshots.
        try:
            _write_private_file(marker, content)
            _fsync_directory(canonical)
        except SnapshotError as exc:
            if exc.code != "PATH_COLLISION":
                raise
            return load_or_create_site_identity(canonical, create=create)
        return SiteIdentity(site_id, binding, canonical)
    except OSError as exc:
        raise SnapshotError("IDENTITY_INVALID", "Site identity cannot be inspected safely") from exc

    if not stat.S_ISREG(marker_info.st_mode):
        raise SnapshotError("IDENTITY_INVALID", "Site identity must be a regular file")
    if marker_info.st_mode & 0o077:
        raise SnapshotError("UNSAFE_PERMISSIONS", "Site identity file must be private")
    try:
        record = json.loads(
            _read_regular_file(marker, max_bytes=4096),
            object_pairs_hook=_reject_duplicate_json_keys,
        )
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError, RecursionError) as exc:
        raise SnapshotError("IDENTITY_INVALID", "Site identity file is malformed") from exc
    if (not isinstance(record, dict)
            or set(record) != {"format_version", "site_id", "path_binding"}
            or type(record.get("format_version")) is not int
            or record.get("format_version") != 1
            or not isinstance(record.get("site_id"), str)
            or not SITE_ID_RE.fullmatch(record["site_id"])
            or not isinstance(record.get("path_binding"), str)
            or not SHA256_RE.fullmatch(record["path_binding"])):
        raise SnapshotError("IDENTITY_INVALID", "Site identity file has an unsupported format")
    expected_binding = _path_binding(record["site_id"], canonical)
    if not secrets.compare_digest(record["path_binding"], expected_binding):
        raise SnapshotError("SITE_IDENTITY_MISMATCH", "Site identity is bound to a different path")
    return SiteIdentity(record["site_id"], expected_binding, canonical)


def _validate_snapshot_id(snapshot_id: str) -> None:
    if not isinstance(snapshot_id, str) or not SNAPSHOT_ID_RE.fullmatch(snapshot_id):
        raise SnapshotError("INVALID_ARGUMENT", "Snapshot ID has an invalid format")


def _validate_payload_name(name: str) -> None:
    if not isinstance(name, str) or name not in {"database.sql.gz", "wordpress.tar.gz"}:
        raise SnapshotError("INVALID_MANIFEST", "Snapshot payload name is not permitted")


def _valid_version(value: object) -> bool:
    return value is None or (isinstance(value, str) and bool(VERSION_RE.fullmatch(value)))


def _canonical_json(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
    ).encode("utf-8") + b"\n"


def _reject_duplicate_json_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


class SnapshotStore:
    """Filesystem-only snapshot repository; no Docker or database dependency."""

    def __init__(self, root: str | os.PathLike[str] | None = None):
        raw_root = resolve_store_root(root)
        try:
            root_info = raw_root.lstat()
        except FileNotFoundError:
            root_info = None
        except OSError as exc:
            raise SnapshotError("UNSAFE_STORE_PATH", "Snapshot storage root cannot be inspected") from exc
        if root_info is not None and stat.S_ISLNK(root_info.st_mode):
            raise SnapshotError("UNSAFE_STORE_PATH", "Snapshot storage root must not be a symlink")
        try:
            # Canonicalize OS-level aliases such as macOS /tmp -> /private/tmp.
            # Children created below this root are still checked without
            # following symlinks.
            self.root = raw_root.resolve(strict=False)
        except OSError as exc:
            raise SnapshotError("UNSAFE_STORE_PATH", "Snapshot storage root cannot be resolved") from exc

    def _validate_identity(self, identity: SiteIdentity) -> None:
        canonical = _canonical_site_path(identity._canonical_path)
        if canonical != identity._canonical_path:
            raise SnapshotError("SITE_IDENTITY_MISMATCH", "Site identity no longer matches its path")
        marker = load_or_create_site_identity(canonical, create=False)
        if (marker.site_id != identity.site_id
                or not secrets.compare_digest(marker.path_binding, identity.path_binding)):
            raise SnapshotError("SITE_IDENTITY_MISMATCH", "Site identity does not match this site")

    def _site_root(self, identity: SiteIdentity, *, create: bool = False) -> Path:
        self._validate_identity(identity)
        site_path = identity._canonical_path
        try:
            common = Path(os.path.commonpath((str(self.root), str(site_path))))
        except ValueError as exc:
            raise SnapshotError("UNSAFE_STORE_PATH", "Snapshot storage and site must be separate") from exc
        if common == self.root or common == site_path:
            raise SnapshotError("UNSAFE_STORE_PATH", "Snapshot storage and site must be separate")
        configured_docal_home = os.environ.get("DOCAL_HOME")
        docal_home = Path(configured_docal_home).expanduser() if configured_docal_home else Path.home() / ".docal"
        docal_home = docal_home.resolve(strict=False)
        if self.root == docal_home or docal_home in self.root.parents:
            raise SnapshotError("UNSAFE_STORE_PATH", "Snapshot storage must be outside ~/.docal")
        if create:
            _ensure_directory(self.root)
        else:
            _check_path_components(self.root)
            if not self.root.is_dir():
                raise SnapshotError("SNAPSHOT_NOT_FOUND", "No snapshot store exists for this site")
            _require_private_directory(self.root)
        site_root = self.root / identity.site_id
        if create:
            _ensure_directory(site_root)
        else:
            _check_path_components(site_root)
            if not site_root.is_dir():
                raise SnapshotError("SNAPSHOT_NOT_FOUND", "No snapshot store exists for this site")
            _require_private_directory(site_root)
        return site_root

    @contextmanager
    def lock(self, identity: SiteIdentity, *, timeout: float = 10.0) -> Iterator[None]:
        if timeout < 0:
            raise SnapshotError("INVALID_ARGUMENT", "Lock timeout cannot be negative")
        site_root = self._site_root(identity, create=True)
        lock_path = site_root / LOCK_FILENAME
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        try:
            fd = os.open(lock_path, flags, 0o600)
            os.fchmod(fd, 0o600)
        except OSError as exc:
            raise SnapshotError("UNSAFE_PATH", "Cannot safely create the snapshot lock") from exc
        deadline = time.monotonic() + timeout
        try:
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise SnapshotError("LOCK_TIMEOUT", "Another snapshot operation is in progress")
                    time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
            yield
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)

    def list_snapshot_ids(self, identity: SiteIdentity) -> list[str]:
        try:
            site_root = self._site_root(identity)
        except SnapshotError as exc:
            if exc.code == "SNAPSHOT_NOT_FOUND":
                return []
            raise
        try:
            entries = list(os.scandir(site_root))
        except OSError as exc:
            raise SnapshotError("STORE_UNAVAILABLE", "Cannot list the snapshot store") from exc
        result = []
        for entry in entries:
            if entry.name.startswith(".") or not SNAPSHOT_ID_RE.fullmatch(entry.name):
                continue
            if entry.is_symlink():
                raise SnapshotError("UNSAFE_PATH", "Snapshot store contains a symlink")
            if (entry.is_dir(follow_symlinks=False)
                    and os.path.lexists(Path(entry.path) / MANIFEST_FILENAME)):
                result.append(entry.name)
        return sorted(result, reverse=True)

    def writer(
        self,
        identity: SiteIdentity,
        *,
        kind: str = "database",
        snapshot_id: str | None = None,
        lock_timeout: float = 10.0,
    ) -> "SnapshotWriter":
        return SnapshotWriter(self, identity, kind, snapshot_id, lock_timeout)

    def verify_snapshot(self, identity: SiteIdentity, snapshot_id: str) -> dict[str, object]:
        _validate_snapshot_id(snapshot_id)
        site_root = self._site_root(identity)
        snapshot_dir = site_root / snapshot_id
        _check_path_components(snapshot_dir)
        try:
            info = snapshot_dir.lstat()
        except OSError as exc:
            raise SnapshotError("SNAPSHOT_NOT_FOUND", "Snapshot does not exist") from exc
        if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o077:
            raise SnapshotError("UNSAFE_PATH", "Snapshot directory is unsafe or not private")

        manifest_path = snapshot_dir / MANIFEST_FILENAME
        checksum_path = snapshot_dir / MANIFEST_CHECKSUM_FILENAME
        manifest_bytes = _read_regular_file(manifest_path, max_bytes=MAX_MANIFEST_BYTES)
        checksum_bytes = _read_regular_file(checksum_path, max_bytes=256)
        try:
            expected_manifest_hash = checksum_bytes.decode("ascii", errors="strict").strip()
        except UnicodeDecodeError as exc:
            raise SnapshotError("MANIFEST_INVALID", "Snapshot manifest checksum is malformed") from exc
        actual_manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()
        if not SHA256_RE.fullmatch(expected_manifest_hash) or not secrets.compare_digest(
            expected_manifest_hash, actual_manifest_hash
        ):
            raise SnapshotError("MANIFEST_CHECKSUM_MISMATCH", "Snapshot manifest checksum does not match")
        try:
            manifest = json.loads(manifest_bytes, object_pairs_hook=_reject_duplicate_json_keys)
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError, RecursionError) as exc:
            raise SnapshotError("MANIFEST_INVALID", "Snapshot manifest is malformed") from exc
        if _canonical_json(manifest) != manifest_bytes:
            raise SnapshotError("MANIFEST_INVALID", "Snapshot manifest is not in canonical form")
        self._validate_manifest(manifest, identity, snapshot_id)

        expected_names = {MANIFEST_FILENAME, MANIFEST_CHECKSUM_FILENAME, *manifest["payloads"]}
        try:
            actual_names = {entry.name for entry in os.scandir(snapshot_dir)}
        except OSError as exc:
            raise SnapshotError("UNSAFE_PATH", "Cannot safely inspect snapshot contents") from exc
        if actual_names != expected_names:
            raise SnapshotError("MANIFEST_INVALID", "Snapshot contains missing or unexpected files")

        for name, spec in manifest["payloads"].items():
            _validate_payload_name(name)
            payload_path = snapshot_dir / name
            try:
                payload_info = payload_path.lstat()
            except OSError as exc:
                raise SnapshotError("CHECKSUM_MISMATCH", "Snapshot payload is unavailable") from exc
            if not stat.S_ISREG(payload_info.st_mode) or payload_info.st_mode & 0o077:
                raise SnapshotError("UNSAFE_PATH", "Snapshot payload must be a private regular file")
            if payload_info.st_size != spec["size_bytes"]:
                raise SnapshotError("CHECKSUM_MISMATCH", "Snapshot payload size does not match")
            digest = hashlib.sha256()
            try:
                fd = os.open(payload_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                with os.fdopen(fd, "rb") as stream:
                    while chunk := stream.read(CHUNK_SIZE):
                        digest.update(chunk)
            except OSError as exc:
                raise SnapshotError("UNSAFE_PATH", "Cannot safely read snapshot payload") from exc
            if not secrets.compare_digest(digest.hexdigest(), spec["sha256"]):
                raise SnapshotError("CHECKSUM_MISMATCH", "Snapshot payload checksum does not match")
        return manifest

    @staticmethod
    def _validate_manifest(
        manifest: object,
        identity: SiteIdentity,
        snapshot_id: str,
    ) -> None:
        expected_keys = {
            "format_version", "snapshot_id", "created_at", "kind", "site",
            "consistency", "docal_version", "database", "payloads",
        }
        if not isinstance(manifest, dict) or set(manifest) != expected_keys:
            raise SnapshotError("MANIFEST_INVALID", "Snapshot manifest has an unsupported schema")
        if (type(manifest["format_version"]) is not int
                or manifest["format_version"] != FORMAT_VERSION
                or not isinstance(manifest["snapshot_id"], str)
                or manifest["snapshot_id"] != snapshot_id):
            raise SnapshotError("MANIFEST_INVALID", "Snapshot manifest identity is invalid")
        if not isinstance(manifest["kind"], str) or manifest["kind"] not in PAYLOADS_BY_KIND:
            raise SnapshotError("MANIFEST_INVALID", "Snapshot kind is invalid")
        try:
            created = datetime.fromisoformat(manifest["created_at"].replace("Z", "+00:00"))
        except (AttributeError, TypeError, ValueError) as exc:
            raise SnapshotError("MANIFEST_INVALID", "Snapshot creation time is invalid") from exc
        if created.tzinfo is None:
            raise SnapshotError("MANIFEST_INVALID", "Snapshot creation time must be timezone-aware")
        if (not isinstance(manifest["consistency"], str)
                or manifest["consistency"] not in CONSISTENCY_VALUES):
            raise SnapshotError("MANIFEST_INVALID", "Snapshot consistency value is invalid")
        if not _valid_version(manifest["docal_version"]):
            raise SnapshotError("MANIFEST_INVALID", "Docal version metadata is invalid")
        site = manifest["site"]
        if (not isinstance(site, dict) or set(site) != {"site_id", "path_binding"}
                or site["site_id"] != identity.site_id
                or site["path_binding"] != identity.path_binding):
            raise SnapshotError("SITE_IDENTITY_MISMATCH", "Snapshot belongs to a different site")
        database = manifest["database"]
        if (not isinstance(database, dict) or set(database) != {"engine", "version"}
                or not isinstance(database["engine"], str)
                or database["engine"] not in DATABASE_ENGINES
                or not _valid_version(database["version"])):
            raise SnapshotError("MANIFEST_INVALID", "Database metadata is invalid")
        payloads = manifest["payloads"]
        if not isinstance(payloads, dict) or set(payloads) != PAYLOADS_BY_KIND[manifest["kind"]]:
            raise SnapshotError("MANIFEST_INVALID", "Snapshot payload set does not match its type")
        for name, spec in payloads.items():
            _validate_payload_name(name)
            if (not isinstance(spec, dict) or set(spec) != {"sha256", "size_bytes"}
                    or not isinstance(spec["sha256"], str) or not SHA256_RE.fullmatch(spec["sha256"])
                    or type(spec["size_bytes"]) is not int or spec["size_bytes"] < 0):
                raise SnapshotError("MANIFEST_INVALID", "Snapshot payload metadata is invalid")


class SnapshotWriter:
    """Write payloads privately, then atomically publish a verified directory."""

    def __init__(
        self,
        store: SnapshotStore,
        identity: SiteIdentity,
        kind: str,
        snapshot_id: str | None,
        lock_timeout: float,
    ):
        if not isinstance(kind, str) or kind not in PAYLOADS_BY_KIND:
            raise SnapshotError("INVALID_ARGUMENT", "Snapshot kind is unsupported")
        self.store = store
        self.identity = identity
        self.kind = kind
        self.requested_id = snapshot_id
        if snapshot_id is not None:
            _validate_snapshot_id(snapshot_id)
        self.lock_timeout = lock_timeout
        self.snapshot_id: str | None = None
        self.staging_dir: Path | None = None
        self.final_dir: Path | None = None
        self._lock_context = None
        self._published = False
        self._payloads: dict[str, dict[str, object]] = {}

    def __enter__(self) -> "SnapshotWriter":
        self._lock_context = self.store.lock(self.identity, timeout=self.lock_timeout)
        self._lock_context.__enter__()
        try:
            site_root = self.store._site_root(self.identity, create=True)
            snapshot_id = self.requested_id or generate_snapshot_id()
            _validate_snapshot_id(snapshot_id)
            self.final_dir = site_root / snapshot_id
            if os.path.lexists(self.final_dir):
                raise SnapshotError("SNAPSHOT_EXISTS", "Snapshot ID already exists")
            staging_name = f".staging-{snapshot_id}-{secrets.token_hex(8)}"
            self.staging_dir = site_root / staging_name
            self.staging_dir.mkdir(mode=0o700)
            self.staging_dir.chmod(0o700)
            self.snapshot_id = snapshot_id
            return self
        except BaseException:
            if self.staging_dir is not None:
                try:
                    self.staging_dir.rmdir()
                except OSError:
                    pass
            self._lock_context.__exit__(*sys.exc_info())
            self._lock_context = None
            raise

    def write_payload(self, name: str, source: BinaryIO | bytes) -> None:
        if self.staging_dir is None or self._published:
            raise SnapshotError("INVALID_STATE", "Snapshot writer is not open")
        _validate_payload_name(name)
        if name in self._payloads:
            raise SnapshotError("PATH_COLLISION", "Snapshot payload already exists")
        path = self.staging_dir / name
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        digest = hashlib.sha256()
        size = 0
        try:
            fd = os.open(path, flags, 0o600)
            with os.fdopen(fd, "wb") as output:
                os.fchmod(output.fileno(), 0o600)
                if isinstance(source, bytes):
                    chunks = (source,)
                else:
                    def read_chunks():
                        while True:
                            chunk = source.read(CHUNK_SIZE)
                            if not chunk:
                                return
                            yield chunk
                    chunks = read_chunks()
                for chunk in chunks:
                    if not isinstance(chunk, bytes):
                        raise SnapshotError("INVALID_ARGUMENT", "Snapshot payload stream must return bytes")
                    output.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
                output.flush()
                os.fsync(output.fileno())
        except SnapshotError:
            path.unlink(missing_ok=True)
            raise
        except OSError as exc:
            path.unlink(missing_ok=True)
            raise SnapshotError("WRITE_FAILED", "Snapshot payload could not be staged") from exc
        self._payloads[name] = {"sha256": digest.hexdigest(), "size_bytes": size}

    def publish(
        self,
        *,
        consistency: str = "unknown",
        docal_version: str | None = None,
        database_engine: str = "unknown",
        database_version: str | None = None,
        created_at: datetime | None = None,
    ) -> dict[str, object]:
        if self.staging_dir is None or self.final_dir is None or self.snapshot_id is None:
            raise SnapshotError("INVALID_STATE", "Snapshot writer is not open")
        if self._published:
            raise SnapshotError("INVALID_STATE", "Snapshot is already published")
        if set(self._payloads) != PAYLOADS_BY_KIND[self.kind]:
            raise SnapshotError("INVALID_MANIFEST", "Snapshot is missing required payloads")
        if (not isinstance(consistency, str) or consistency not in CONSISTENCY_VALUES
                or not isinstance(database_engine, str)
                or database_engine not in DATABASE_ENGINES):
            raise SnapshotError("INVALID_ARGUMENT", "Snapshot metadata value is unsupported")
        if not _valid_version(docal_version):
            raise SnapshotError("INVALID_ARGUMENT", "Docal version metadata is invalid")
        if not _valid_version(database_version):
            raise SnapshotError("INVALID_ARGUMENT", "Database version metadata is invalid")
        instant = created_at or datetime.now(timezone.utc)
        if instant.tzinfo is None:
            raise SnapshotError("INVALID_ARGUMENT", "Snapshot timestamp must include a timezone")
        created_text = instant.astimezone(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
        manifest: dict[str, object] = {
            "format_version": FORMAT_VERSION,
            "snapshot_id": self.snapshot_id,
            "created_at": created_text,
            "kind": self.kind,
            "site": self.identity.to_dict(),
            "consistency": consistency,
            "docal_version": docal_version,
            "database": {"engine": database_engine, "version": database_version},
            "payloads": dict(sorted(self._payloads.items())),
        }
        manifest_bytes = _canonical_json(manifest)
        manifest_digest = hashlib.sha256(manifest_bytes).hexdigest().encode("ascii") + b"\n"
        _write_private_file(self.staging_dir / MANIFEST_FILENAME, manifest_bytes)
        _write_private_file(self.staging_dir / MANIFEST_CHECKSUM_FILENAME, manifest_digest)
        _fsync_directory(self.staging_dir)
        # Run the same strict validator used by readers before commit.
        self.store._validate_manifest(manifest, self.identity, self.snapshot_id)
        if os.path.lexists(self.final_dir):
            raise SnapshotError("SNAPSHOT_EXISTS", "Snapshot ID already exists")
        try:
            os.rename(self.staging_dir, self.final_dir)
            self._published = True
            _fsync_directory(self.final_dir.parent)
        except FileExistsError as exc:
            raise SnapshotError("SNAPSHOT_EXISTS", "Snapshot ID already exists") from exc
        except OSError as exc:
            if self._published:
                raise SnapshotError("DURABILITY_UNCERTAIN", "Snapshot is visible but durability is uncertain") from exc
            raise SnapshotError("PUBLISH_FAILED", "Snapshot could not be published") from exc
        return manifest

    def __exit__(self, exc_type, exc_value, traceback) -> bool:
        try:
            if not self._published and self.staging_dir is not None:
                # Remove only the private staging directory this writer made.
                # A hard process interruption may leave a hidden .staging-*;
                # listing and verification never treat it as a snapshot.
                for entry in self.staging_dir.iterdir():
                    if entry.is_file() and not entry.is_symlink():
                        entry.unlink()
                self.staging_dir.rmdir()
        except OSError:
            # Do not replace the original error with cleanup noise. The hidden
            # partial directory remains private and is not considered published.
            pass
        finally:
            if self._lock_context is not None:
                self._lock_context.__exit__(exc_type, exc_value, traceback)
                self._lock_context = None
        return False
