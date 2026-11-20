#!/usr/bin/env python3
"""Shared offline validation for the C3 Release provenance manifest.

The C4 and C5 evidence verifiers and the C7 schema all consume the same C3
manifest.  They share one field sequence and one validator so an identical
manifest is accepted or rejected the same way everywhere.  Gate-specific
timestamp formats, artifact containment, and exception types stay with each
consumer; callers translate C3ProvenanceError into their own failure type.
"""

from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path
from typing import Dict, Tuple


class C3ProvenanceError(ValueError):
    pass


TEAM = "3524374A2S"
APP_GROUP = "group.com.idlescreen.shared"
MACH_SERVICE = "group.com.idlescreen.shared.camera-agent"
APP_ID = "com.idlescreen.app"
HELPER_ID = "com.idlescreen.camera-agent"
EXTENSION_ID = "com.idlescreen.app.screensaver"

C3_SCHEMA = "IdleScreenReleaseArchiveProvenance/v1"

C3_FIELDS: Tuple[str, ...] = (
    "schema",
    "verification_mode",
    "archive_tree_sha256",
    "team_identifier",
    "app_group",
    "mach_service",
    "camera_usage_description_sha256",
    "launch_agent_sha256",
    "signer_certificate_sha256",
    "app_bundle_identifier",
    "app_cdhash",
    "app_designated_requirement_sha256",
    "app_entitlements_sha256",
    "app_profile_sha256",
    "app_profile_uuid",
    "app_profile_expiration",
    "extension_bundle_identifier",
    "extension_cdhash",
    "extension_designated_requirement_sha256",
    "extension_entitlements_sha256",
    "extension_profile_sha256",
    "extension_profile_uuid",
    "extension_profile_expiration",
    "helper_bundle_identifier",
    "helper_cdhash",
    "helper_designated_requirement_sha256",
    "helper_entitlements_sha256",
    "helper_profile_sha256",
    "helper_profile_uuid",
    "helper_profile_expiration",
)

C3_EXPECTED_IDENTITY: Dict[str, str] = {
    "schema": C3_SCHEMA,
    "verification_mode": "release",
    "team_identifier": TEAM,
    "app_group": APP_GROUP,
    "mach_service": MACH_SERVICE,
    "app_bundle_identifier": APP_ID,
    "extension_bundle_identifier": EXTENSION_ID,
    "helper_bundle_identifier": HELPER_ID,
}

SHA256 = re.compile(r"[0-9a-f]{64}")
CDHASH = re.compile(r"[0-9a-fA-F]{40}")
PROFILE_UUID = re.compile(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)
PROFILE_UUID_FIELDS = tuple(f"{name}_profile_uuid" for name in ("app", "extension", "helper"))
PROFILE_EXPIRATION_FIELDS = tuple(
    f"{name}_profile_expiration" for name in ("app", "extension", "helper")
)


def fail(message: str) -> None:
    raise C3ProvenanceError(message)


def parse_c3_records(text: str, label: str) -> Dict[str, str]:
    """Parse key=value records, requiring the exact C3 fields in order."""
    values: Dict[str, str] = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        if "=" not in line or any(ord(character) < 0x20 for character in line):
            fail(f"{label} line {line_number} is not one key=value record")
        key, value = line.split("=", 1)
        if key not in C3_FIELDS:
            fail(f"{label} contains unexpected field {key!r}")
        if key in values:
            fail(f"{label} repeats field {key!r}")
        if not value:
            fail(f"{label} field {key!r} is empty")
        values[key] = value
    missing = [field for field in C3_FIELDS if field not in values]
    if missing:
        fail(f"{label} is missing fields: {', '.join(missing)}")
    if tuple(values) != C3_FIELDS:
        fail(f"{label} fields are out of order")
    return values


def validate_c3_values(values: Dict[str, str], label: str) -> Dict[str, str]:
    """Validate identity, digest, CDHash, profile UUID, and expiration fields."""
    validated = dict(values)
    for key, wanted in C3_EXPECTED_IDENTITY.items():
        if validated.get(key) != wanted:
            fail(f"{label} {key} must equal {wanted!r}")
    for key, value in values.items():
        if key.endswith("_sha256") and SHA256.fullmatch(value) is None:
            fail(f"{label} {key} is not a lowercase SHA-256")
        if key.endswith("_cdhash"):
            if CDHASH.fullmatch(value) is None:
                fail(f"{label} {key} is not a 40-digit CDHash")
            validated[key] = value.lower()
    for key in PROFILE_UUID_FIELDS:
        if PROFILE_UUID.fullmatch(validated[key]) is None:
            fail(f"{label} {key} is malformed")
    for key in PROFILE_EXPIRATION_FIELDS:
        try:
            datetime.fromisoformat(validated[key].replace("Z", "+00:00"))
        except ValueError:
            fail(f"{label} {key} is malformed")
    return validated


def parse_c3_manifest(path: Path, label: str = "C3 provenance manifest") -> Dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"could not read {label}: {error}")
    return validate_c3_values(parse_c3_records(text, label), label)
