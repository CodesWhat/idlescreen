#!/usr/bin/python3

"""Read-only, replayable camera/hybrid configuration preflight for Gate A1T."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
from pathlib import Path
from typing import Dict


class PreflightFailure(Exception):
    pass


SNAPSHOT_FIELDS = (
    "format",
    "configuration_path",
    "schema_version",
    "source",
    "device",
    "inode",
    "size",
    "mtime_ns",
    "sha256",
)


def fail(message: str) -> None:
    raise PreflightFailure(message)


def read_configuration(path: Path) -> Dict[str, str]:
    if not path.is_absolute() or path.is_symlink():
        fail("configuration path must be absolute and must not be a symlink")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"configuration cannot be opened read-only: {error}")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            fail("configuration is not a regular file")
        chunks = []
        while True:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    identity_before = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
    )
    identity_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if identity_before != identity_after:
        fail("configuration changed while it was being read")
    payload = b"".join(chunks)
    if len(payload) != before.st_size:
        fail("configuration size changed while it was being read")
    try:
        document = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"configuration is not valid UTF-8 JSON: {error}")
    if not isinstance(document, dict):
        fail("configuration root must be an object")
    schema_version = document.get("schemaVersion")
    if type(schema_version) is not int or schema_version < 0 or schema_version > 1:
        fail("configuration schemaVersion is missing or unsupported")
    source = document.get("source")
    if source not in ("camera", "hybrid"):
        fail(f"A1T requires source camera or hybrid; found {source!r}")
    return {
        "format": "IdleScreenCameraGateConfigurationV1",
        "configuration_path": str(path),
        "schema_version": str(schema_version),
        "source": source,
        "device": str(before.st_dev),
        "inode": str(before.st_ino),
        "size": str(before.st_size),
        "mtime_ns": str(before.st_mtime_ns),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def parse_snapshot(path: Path) -> Dict[str, str]:
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        fail("configuration snapshot must be an absolute regular file")
    values: Dict[str, str] = {}
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        if "=" not in raw_line:
            fail(f"malformed configuration snapshot line {line_number}")
        key, value = raw_line.split("=", 1)
        if key not in SNAPSHOT_FIELDS or key in values or not value:
            fail(f"unexpected or duplicate configuration snapshot field {key!r}")
        values[key] = value
    if tuple(values) != SNAPSHOT_FIELDS:
        fail("configuration snapshot fields are missing or out of order")
    return values


def write_snapshot(path: Path, values: Dict[str, str]) -> None:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        fail("snapshot output must be a new absolute path")
    payload = "".join(f"{key}={values[key]}\n" for key in SNAPSHOT_FIELDS).encode()
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        fail(f"could not write configuration evidence snapshot: {error}")


def main(argv: list[str]) -> int:
    if len(argv) != 4 or argv[1] not in ("snapshot", "recheck"):
        print(
            "Usage: verify-camera-gate-a1-config.py snapshot|recheck "
            "/absolute/configuration.json /absolute/configuration.snapshot",
            file=sys.stderr,
        )
        return 64
    operation = argv[1]
    configuration_path = Path(argv[2])
    snapshot_path = Path(argv[3])
    try:
        current = read_configuration(configuration_path)
        if operation == "snapshot":
            write_snapshot(snapshot_path, current)
        else:
            expected = parse_snapshot(snapshot_path)
            if current != expected:
                fail("configuration identity or content changed after preflight")
    except (OSError, PreflightFailure) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: configuration is immutable and source={current['source']}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
