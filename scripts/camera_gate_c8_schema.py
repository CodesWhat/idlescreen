#!/usr/bin/env python3
"""Strict schemas and offline verification for the C8 lifecycle release gate."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping


MATRIX_SCHEMA = "IdleScreenC8LifecycleMatrix/v1"
ROW_SCHEMA = "IdleScreenC8LifecycleRow/v1"
EVENT_SCHEMA = "IdleScreenC8TypedEvent/v1"
IDENTITY_SCHEMA = "IdleScreenC8IdentitySnapshot/v1"
FINAL_STATE_SCHEMA = "IdleScreenC8FinalState/v1"
CONSOLE_STATE_SCHEMA = "IdleScreenC8ConsoleState/v1"
PREFLIGHT_CONSOLE_STATE_SCHEMA = "IdleScreenC8PreflightConsoleState/v1"
ATTESTATION_SCHEMA = "IdleScreenC8OperatorAttestation/v1"
PLAN_SCHEMA = "IdleScreenC8RowPlan/v1"

TEAM = "3524374A2S"
APP_PATH = "/Applications/idlescreen.app"
HELPER_PATH = (
    f"{APP_PATH}/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/"
    "IdleScreenCameraAgent"
)
EXTENSION_PATH = (
    f"{APP_PATH}/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/"
    "IdleScreenScreenSaver"
)

SHA256_RE = re.compile(r"[0-9a-f]{64}")
CDHASH_RE = re.compile(r"[0-9a-f]{40}")
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{7,127}")
CONSUMER_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{2,127}")


@dataclass(frozen=True)
class RowDefinition:
    ordinal: int
    row_id: str
    scenario: str
    action_class: str
    authorization_environment_variable: str
    requires_unlocked_start: bool
    requires_fresh_recovery: bool
    maximum_helper_restart_count: int
    maximum_extension_restart_count: int
    required_detail_codes: tuple[str, ...]
    maximum_event_count: int = 128

    @property
    def filename(self) -> str:
        return f"rows/{self.ordinal:02d}-{self.row_id}.json"

    @property
    def scope_statement(self) -> str:
        return (
            f"Authorized only for C8 row {self.row_id} action class "
            f"{self.action_class} via "
            f"{self.authorization_environment_variable}=YES."
        )


ROWS: tuple[RowDefinition, ...] = (
    RowDefinition(
        1,
        "sleep-wake",
        "one normal system sleep and wake while one known lease is streaming",
        "sleep-wake",
        "IDLESCREEN_C8_AUTHORIZE_SLEEP_WAKE",
        True,
        True,
        0,
        0,
        (
            "system-sleep-entered",
            "system-wake-observed",
            "authorization-refreshed",
            "inventory-refreshed",
        ),
    ),
    RowDefinition(
        2,
        "reboot-login",
        "one normal reboot followed by login and fresh lifecycle activation",
        "reboot-login",
        "IDLESCREEN_C8_AUTHORIZE_REBOOT_LOGIN",
        True,
        True,
        1,
        1,
        ("boot-session-changed", "login-observed", "registration-restored"),
    ),
    RowDefinition(
        3,
        "background-items-disable",
        "disable the exact Background Item once and observe bounded teardown",
        "background-items-disable",
        "IDLESCREEN_C8_AUTHORIZE_BACKGROUND_ITEMS_DISABLE",
        True,
        False,
        0,
        0,
        ("background-item-disabled", "service-unbound", "fallback-observed"),
    ),
    RowDefinition(
        4,
        "background-items-enable",
        "enable the exact Background Item once and prove a fresh lifecycle",
        "background-items-enable",
        "IDLESCREEN_C8_AUTHORIZE_BACKGROUND_ITEMS_ENABLE",
        True,
        True,
        1,
        0,
        ("background-item-enabled", "service-rebound"),
    ),
    RowDefinition(
        5,
        "app-replacement",
        "replace the canonical app with the same recorded candidate and rebind once",
        "app-replacement",
        "IDLESCREEN_C8_AUTHORIZE_APP_REPLACEMENT",
        True,
        True,
        1,
        1,
        (
            "candidate-replacement-started",
            "candidate-replacement-completed",
            "registration-rebound",
        ),
    ),
    RowDefinition(
        6,
        "permission-revoke",
        "revoke Camera permission once and observe bounded capture teardown",
        "permission-revoke",
        "IDLESCREEN_C8_AUTHORIZE_PERMISSION_REVOKE",
        True,
        False,
        0,
        0,
        ("permission-revoked", "capture-stopped", "fallback-observed"),
    ),
    RowDefinition(
        7,
        "permission-grant",
        "grant Camera permission once through the expected visible consent surface",
        "permission-grant",
        "IDLESCREEN_C8_AUTHORIZE_PERMISSION_GRANT",
        True,
        True,
        0,
        0,
        ("permission-granted", "authorization-refreshed"),
    ),
    RowDefinition(
        8,
        "camera-contention",
        "introduce one named competing camera owner and recover after it releases",
        "camera-contention",
        "IDLESCREEN_C8_AUTHORIZE_CAMERA_CONTENTION",
        True,
        True,
        1,
        0,
        ("device-contention-observed", "fallback-observed", "contention-released"),
    ),
    RowDefinition(
        9,
        "device-disconnect",
        "disconnect the explicitly selected external camera once",
        "device-disconnect",
        "IDLESCREEN_C8_AUTHORIZE_DEVICE_DISCONNECT",
        True,
        False,
        1,
        0,
        ("selected-device-disconnected", "inventory-refreshed", "fallback-observed"),
    ),
    RowDefinition(
        10,
        "device-reconnect",
        "reconnect the explicitly selected external camera once",
        "device-reconnect",
        "IDLESCREEN_C8_AUTHORIZE_DEVICE_RECONNECT",
        True,
        True,
        1,
        0,
        ("selected-device-reconnected", "inventory-refreshed", "selection-stable"),
    ),
    RowDefinition(
        11,
        "multiple-views",
        "exercise multiple authenticated view consumers against one producer",
        "multiple-views",
        "IDLESCREEN_C8_AUTHORIZE_MULTIPLE_VIEWS",
        True,
        True,
        0,
        0,
        ("view-consumer-added", "view-consumer-removed", "single-producer-proven"),
    ),
    RowDefinition(
        12,
        "multiple-displays",
        "exercise distinct display consumers and one topology transition",
        "multiple-displays",
        "IDLESCREEN_C8_AUTHORIZE_MULTIPLE_DISPLAYS",
        True,
        True,
        0,
        0,
        (
            "display-consumer-added",
            "display-topology-changed",
            "display-consumer-removed",
        ),
    ),
    RowDefinition(
        13,
        "multiple-users",
        "exercise one authorized user-session transition without recording usernames",
        "multiple-users",
        "IDLESCREEN_C8_AUTHORIZE_MULTIPLE_USERS",
        True,
        True,
        1,
        1,
        ("user-session-transitioned", "other-session-isolated", "login-observed"),
    ),
    RowDefinition(
        14,
        "multiple-spaces",
        "exercise multiple Spaces while preserving exact provider identity",
        "multiple-spaces",
        "IDLESCREEN_C8_AUTHORIZE_MULTIPLE_SPACES",
        True,
        True,
        0,
        0,
        ("space-transitioned", "provider-stable", "space-consumer-removed"),
    ),
    RowDefinition(
        15,
        "helper-crash-recovery",
        "terminate the exact helper PID once and prove one bounded relaunch",
        "helper-crash-recovery",
        "IDLESCREEN_C8_AUTHORIZE_HELPER_CRASH_RECOVERY",
        False,
        True,
        1,
        0,
        ("helper-terminated", "fallback-observed", "helper-relaunched"),
    ),
    RowDefinition(
        16,
        "extension-crash-recovery",
        "terminate the exact hosted extension PID once and prove one bounded reload",
        "extension-crash-recovery",
        "IDLESCREEN_C8_AUTHORIZE_EXTENSION_CRASH_RECOVERY",
        False,
        True,
        0,
        1,
        ("extension-terminated", "lease-reclaimed", "extension-relaunched"),
    ),
    RowDefinition(
        17,
        "soak",
        "run one explicitly bounded extended camera lifecycle soak",
        "extended-soak",
        "IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK",
        True,
        True,
        0,
        0,
        ("soak-started", "soak-checkpoint", "soak-completed"),
        maximum_event_count=2048,
    ),
)

ROW_BY_ID = {row.row_id: row for row in ROWS}
AUTHORIZATION_ENVIRONMENT_VARIABLES = frozenset(
    row.authorization_environment_variable for row in ROWS
)

COMMON_DETAIL_CODES = frozenset(
    (
        "row-started",
        "identity-before-stable",
        "action-boundary",
        "stale-frame-rejected",
        "fresh-frame-consumed",
        "identity-after-stable",
        "final-state-observed",
        "row-completed",
    )
)
ALLOWED_DETAIL_CODES = COMMON_DETAIL_CODES | frozenset(
    code for row in ROWS for code in row.required_detail_codes
)
EVENT_TYPES = frozenset(("boundary", "identity", "lifecycle", "frame", "final"))
EVENT_COMPONENTS = frozenset(
    (
        "orchestrator",
        "app",
        "helper",
        "extension",
        "host",
        "system",
        "camera-device",
        "launchd",
        "tcc",
    )
)
FRAME_DISPOSITIONS = frozenset(
    ("not-applicable", "fresh-consumed", "stale-rejected", "fallback")
)
FINAL_CONSUMER_ROLES = frozenset(("none", "companion", "screen-saver"))
FINAL_CONSUMER_REASONS = frozenset(
    (
        "none",
        "authorized-preview-remains",
        "authorized-saver-remains",
        "authorized-soak-consumer-remains",
    )
)

MATRIX_KEYS = frozenset(
    ("schema", "matrix_id", "candidate", "physical_boundary", "row_count", "rows")
)
MATRIX_CANDIDATE_KEYS = frozenset(
    (
        "provenance_file",
        "provenance_sha256",
        "archive_tree_sha256",
        "team_identifier",
        "app_cdhash",
        "helper_cdhash",
        "extension_cdhash",
    )
)
BOUNDARY_KEYS = frozenset(
    (
        "preparation_performs_physical_actions",
        "row_execution_implemented",
        "per_class_authorization_required",
        "raw_frame_or_content_evidence",
    )
)
ROW_REFERENCE_KEYS = frozenset(
    (
        "row_id",
        "path",
        "authorization_environment_variable",
        "requires_unlocked_start",
    )
)
ROW_KEYS = frozenset(
    (
        "schema",
        "matrix_id",
        "row_id",
        "ordinal",
        "scenario",
        "status",
        "row_run_id",
        "candidate",
        "action_class",
        "authorization",
        "console",
        "timing",
        "evidence",
        "observations",
        "verdict",
    )
)
ROW_CANDIDATE_KEYS = MATRIX_CANDIDATE_KEYS - {"provenance_file"}
AUTHORIZATION_KEYS = frozenset(
    (
        "id",
        "environment_variable",
        "value",
        "granted_at_utc",
        "action_class",
        "row_only",
        "expires_after_row",
        "scope_statement",
        "retained_consumer_authorized",
        "retained_consumer_role",
        "retained_consumer_instance_id",
    )
)
CONSOLE_KEYS = frozenset(("requires_unlocked_start", "state_at_start"))
TIMING_KEYS = frozenset(("started_at_utc", "completed_at_utc"))
EVIDENCE_ORDER = (
    "typed_events",
    "identity_before",
    "identity_after",
    "final_state",
    "console_state",
    "operator_attestation",
)
EVIDENCE_KEYS = frozenset(EVIDENCE_ORDER)
ARTIFACT_KEYS = frozenset(("path", "sha256"))
OBSERVATION_KEYS = frozenset(
    (
        "typed_event_count",
        "stale_frames_rejected",
        "stale_frames_presented",
        "restart_loop_detected",
        "focus_theft",
        "identity_changed",
        "raw_frame_or_content_evidence",
        "pixel_data_recorded",
        "biometric_data_recorded",
        "device_serial_recorded",
        "unredacted_username_recorded",
        "final_active_lease_count",
        "final_capture_active",
        "final_consumer",
    )
)
FINAL_CONSUMER_KEYS = frozenset(("role", "instance_id", "reason_code"))
VERDICT_KEYS = frozenset(("result", "rejection_reasons"))
EVENT_KEYS = frozenset(
    (
        "schema",
        "matrix_id",
        "row_id",
        "row_run_id",
        "event_index",
        "captured_at_utc",
        "event_type",
        "component",
        "producer_epoch",
        "generation",
        "sequence",
        "frame_disposition",
        "active_lease_count",
        "capture_active",
        "helper_restart_count",
        "extension_restart_count",
        "consumer_instance",
        "detail_code",
    )
)
IDENTITY_KEYS = frozenset(
    (
        "schema",
        "matrix_id",
        "row_id",
        "row_run_id",
        "captured_at_utc",
        "app_path",
        "helper_path",
        "extension_path",
        "team_identifier",
        "archive_tree_sha256",
        "app_cdhash",
        "helper_cdhash",
        "extension_cdhash",
        "runtime_helper_pid",
        "runtime_extension_pids",
        "deep_signature_valid",
        "profiles_valid",
        "production_markers_absent",
    )
)
FINAL_STATE_KEYS = frozenset(
    (
        "schema",
        "matrix_id",
        "row_id",
        "row_run_id",
        "captured_at_utc",
        "active_lease_count",
        "capture_active",
        "producer_state",
        "led_state",
        "helper_restart_count",
        "extension_restart_count",
        "restart_loop_detected",
        "focus_theft",
        "stale_frame_presented",
        "final_consumer",
    )
)
CONSOLE_STATE_KEYS = frozenset(
    (
        "schema",
        "matrix_id",
        "row_id",
        "row_run_id",
        "captured_at_utc",
        "state",
        "source",
    )
)
ATTESTATION_KEYS = frozenset(
    (
        "schema",
        "matrix_id",
        "row_id",
        "row_run_id",
        "authorization_id",
        "action_class",
        "physical_action_performed",
        "unexpected_prompt",
        "focus_theft",
        "restart_loop_detected",
        "stale_frame_presented",
        "raw_frame_or_content_evidence",
        "pixel_data_recorded",
        "biometric_data_recorded",
        "device_serial_recorded",
        "unredacted_username_recorded",
    )
)


class C8EvidenceError(RuntimeError):
    pass


@dataclass(frozen=True)
class MatrixDefinition:
    root: Path
    matrix_path: Path
    matrix_id: str
    candidate: Mapping[str, str]
    row_paths: Mapping[str, Path]


@dataclass(frozen=True)
class VerifiedRow:
    definition: RowDefinition
    row_run_id: str
    authorization_id: str
    row_manifest_sha256: str
    artifact_paths: tuple[str, ...]
    artifact_hashes: tuple[str, ...]


@dataclass(frozen=True)
class VerifiedMatrix:
    definition: MatrixDefinition
    matrix_manifest_sha256: str
    rows: tuple[VerifiedRow, ...]

    @property
    def evidence_set_sha256(self) -> str:
        digest = hashlib.sha256()
        digest.update(f"matrix={self.matrix_manifest_sha256}\n".encode())
        digest.update(
            f"candidate={self.definition.candidate['provenance_sha256']}\n".encode()
        )
        for row in self.rows:
            digest.update(
                (
                    f"row={row.definition.ordinal}|{row.definition.row_id}|"
                    f"{row.row_manifest_sha256}\n"
                ).encode()
            )
            for path, artifact_hash in zip(row.artifact_paths, row.artifact_hashes):
                digest.update(f"artifact={path}|{artifact_hash}\n".encode())
        return digest.hexdigest()


def fail(message: str) -> None:
    raise C8EvidenceError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_object(value: Any, keys: Iterable[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != set(keys):
        fail(f"{label} fields are missing or unexpected")
    return value


def require_boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{label} must be boolean")
    return value


def require_nonnegative_integer(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        fail(f"{label} must be a nonnegative integer")
    return value


def require_positive_integer_or_none(value: Any, label: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        fail(f"{label} must be a positive integer or null")
    return value


def parse_timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        fail(f"{label} must be an explicit UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        fail(f"{label} is malformed")
    if parsed.tzinfo != timezone.utc:
        fail(f"{label} must be UTC")
    return parsed


def read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, UnicodeError) as error:
        fail(f"could not read {label}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be one JSON object")
    return value


def parse_candidate_provenance(path: Path) -> dict[str, str]:
    required = (
        "archive_tree_sha256",
        "team_identifier",
        "app_cdhash",
        "helper_cdhash",
        "extension_cdhash",
    )
    found: dict[str, str] = {}
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        if "=" not in line or any(ord(character) < 0x20 for character in line):
            fail(f"malformed candidate provenance line {line_number}")
        key, value = line.split("=", 1)
        if key in required:
            if key in found or not value:
                fail(f"candidate provenance does not contain exactly one {key}")
            found[key] = value
    if set(found) != set(required):
        fail("candidate provenance lacks the exact C8 signed identity tuple")
    if SHA256_RE.fullmatch(found["archive_tree_sha256"]) is None:
        fail("candidate archive tree SHA-256 is malformed")
    if found["team_identifier"] != TEAM:
        fail("candidate Team identifier is not the production Team")
    for key in ("app_cdhash", "helper_cdhash", "extension_cdhash"):
        if CDHASH_RE.fullmatch(found[key]) is None:
            fail(f"candidate {key} is malformed")
    return found


def require_relative_artifact(
    root: Path, reference: Mapping[str, Any], label: str
) -> tuple[Path, str]:
    artifact = require_object(reference, ARTIFACT_KEYS, label)
    path_text = artifact["path"]
    recorded_hash = artifact["sha256"]
    if not isinstance(path_text, str) or Path(path_text).is_absolute():
        fail(f"{label} path must be relative")
    if not isinstance(recorded_hash, str) or SHA256_RE.fullmatch(recorded_hash) is None:
        fail(f"{label} SHA-256 is malformed")
    path = root / path_text
    if path.is_symlink() or not path.is_file():
        fail(f"{label} is not a non-symlink regular file")
    try:
        path.resolve().relative_to(root)
    except ValueError:
        fail(f"{label} escapes the C8 evidence root")
    if sha256(path) != recorded_hash:
        fail(f"{label} differs from its recorded SHA-256")
    return path, recorded_hash


def load_matrix_definition(matrix_path: Path) -> MatrixDefinition:
    if (
        not matrix_path.is_absolute()
        or matrix_path.is_symlink()
        or not matrix_path.is_file()
    ):
        fail("C8 matrix must be an absolute, non-symlink regular file")
    root = matrix_path.parent.resolve()
    matrix = require_object(
        read_json(matrix_path, "C8 matrix"), MATRIX_KEYS, "C8 matrix"
    )
    if matrix["schema"] != MATRIX_SCHEMA:
        fail("C8 matrix schema is unsupported")
    matrix_id = matrix["matrix_id"]
    if not isinstance(matrix_id, str) or ID_RE.fullmatch(matrix_id) is None:
        fail("C8 matrix ID is malformed")
    candidate = require_object(
        matrix["candidate"], MATRIX_CANDIDATE_KEYS, "C8 matrix candidate"
    )
    provenance_file = candidate["provenance_file"]
    if provenance_file != "candidate-provenance.txt":
        fail("C8 candidate provenance path is not canonical")
    provenance = root / provenance_file
    if provenance.is_symlink() or not provenance.is_file():
        fail("C8 candidate provenance is not a non-symlink regular file")
    if (
        not isinstance(candidate["provenance_sha256"], str)
        or SHA256_RE.fullmatch(candidate["provenance_sha256"]) is None
        or sha256(provenance) != candidate["provenance_sha256"]
    ):
        fail("C8 candidate provenance hash is malformed or stale")
    provenance_tuple = parse_candidate_provenance(provenance)
    for key, value in provenance_tuple.items():
        if candidate.get(key) != value:
            fail(f"C8 matrix candidate {key} differs from its provenance")

    boundary = require_object(
        matrix["physical_boundary"], BOUNDARY_KEYS, "C8 physical boundary"
    )
    if boundary != {
        "preparation_performs_physical_actions": False,
        "row_execution_implemented": False,
        "per_class_authorization_required": True,
        "raw_frame_or_content_evidence": "prohibited",
    }:
        fail("C8 physical boundary is not fail-closed")
    if matrix["row_count"] != len(ROWS):
        fail("C8 matrix row count is not exact")
    references = matrix["rows"]
    if not isinstance(references, list) or len(references) != len(ROWS):
        fail("C8 matrix row references are incomplete")
    row_paths: dict[str, Path] = {}
    for reference, definition in zip(references, ROWS):
        item = require_object(reference, ROW_REFERENCE_KEYS, "C8 row reference")
        expected = {
            "row_id": definition.row_id,
            "path": definition.filename,
            "authorization_environment_variable": definition.authorization_environment_variable,
            "requires_unlocked_start": definition.requires_unlocked_start,
        }
        if item != expected:
            fail(f"C8 row reference {definition.row_id} is not exact")
        path = root / definition.filename
        if path.is_symlink() or not path.is_file():
            fail(f"C8 row manifest {definition.row_id} is missing")
        try:
            path.resolve().relative_to(root)
        except ValueError:
            fail(f"C8 row manifest {definition.row_id} escapes the matrix root")
        row_paths[definition.row_id] = path
    return MatrixDefinition(root, matrix_path, matrix_id, candidate, row_paths)


def require_candidate(
    candidate: Mapping[str, Any], expected: Mapping[str, str], label: str
) -> None:
    value = require_object(candidate, ROW_CANDIDATE_KEYS, label)
    for key in ROW_CANDIDATE_KEYS:
        if value[key] != expected[key]:
            fail(f"{label} {key} differs from the exact matrix candidate")


def validate_pending_row(definition: MatrixDefinition, row_id: str) -> dict[str, Any]:
    if row_id not in ROW_BY_ID:
        fail("unknown C8 row")
    row_definition = ROW_BY_ID[row_id]
    row = require_object(
        read_json(definition.row_paths[row_id], f"C8 row {row_id}"),
        ROW_KEYS,
        f"C8 row {row_id}",
    )
    if (
        row["schema"] != ROW_SCHEMA
        or row["matrix_id"] != definition.matrix_id
        or row["row_id"] != row_id
        or row["ordinal"] != row_definition.ordinal
        or row["scenario"] != row_definition.scenario
        or row["action_class"] != row_definition.action_class
    ):
        fail(f"C8 pending row {row_id} identity is not exact")
    require_candidate(
        row["candidate"], definition.candidate, f"C8 row {row_id} candidate"
    )
    if row["status"] != "pending" or row["row_run_id"] is not None:
        fail(f"C8 row {row_id} is not pending")
    console = require_object(row["console"], CONSOLE_KEYS, f"C8 row {row_id} console")
    if console != {
        "requires_unlocked_start": row_definition.requires_unlocked_start,
        "state_at_start": None,
    }:
        fail(f"C8 pending row {row_id} console template drifted")
    return row


def verify_identity(
    path: Path,
    matrix: MatrixDefinition,
    definition: RowDefinition,
    run_id: str,
    label: str,
) -> datetime:
    value = require_object(read_json(path, label), IDENTITY_KEYS, label)
    expected = {
        "schema": IDENTITY_SCHEMA,
        "matrix_id": matrix.matrix_id,
        "row_id": definition.row_id,
        "row_run_id": run_id,
        "app_path": APP_PATH,
        "helper_path": HELPER_PATH,
        "extension_path": EXTENSION_PATH,
        "team_identifier": matrix.candidate["team_identifier"],
        "archive_tree_sha256": matrix.candidate["archive_tree_sha256"],
        "app_cdhash": matrix.candidate["app_cdhash"],
        "helper_cdhash": matrix.candidate["helper_cdhash"],
        "extension_cdhash": matrix.candidate["extension_cdhash"],
        "deep_signature_valid": True,
        "profiles_valid": True,
        "production_markers_absent": True,
    }
    for key, expected_value in expected.items():
        if value[key] != expected_value:
            fail(f"{label} {key} differs from the exact signed candidate")
    require_positive_integer_or_none(value["runtime_helper_pid"], f"{label} helper PID")
    extension_pids = value["runtime_extension_pids"]
    if not isinstance(extension_pids, list) or len(set(extension_pids)) != len(
        extension_pids
    ):
        fail(f"{label} extension PIDs must be one distinct list")
    for pid in extension_pids:
        if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
            fail(f"{label} extension PID is malformed")
    return parse_timestamp(value["captured_at_utc"], f"{label} timestamp")


def verify_final_consumer(
    value: Any,
    authorization: Mapping[str, Any],
    lease_count: int,
    capture_active: bool,
    label: str,
) -> dict[str, str]:
    consumer = require_object(value, FINAL_CONSUMER_KEYS, label)
    role = consumer["role"]
    instance_id = consumer["instance_id"]
    reason = consumer["reason_code"]
    if role not in FINAL_CONSUMER_ROLES or reason not in FINAL_CONSUMER_REASONS:
        fail(f"{label} role or reason is unsupported")
    if role == "none":
        if consumer != {"role": "none", "instance_id": "none", "reason_code": "none"}:
            fail(f"{label} empty consumer tuple is malformed")
        if lease_count != 0 or capture_active:
            fail(f"{label} requires zero final leases and stopped capture")
        if (
            authorization["retained_consumer_authorized"] is not False
            or authorization["retained_consumer_role"] != "none"
            or authorization["retained_consumer_instance_id"] != "none"
        ):
            fail(f"{label} conflicts with retained-consumer authorization")
    else:
        if (
            not isinstance(instance_id, str)
            or CONSUMER_ID_RE.fullmatch(instance_id) is None
            or reason == "none"
            or lease_count != 1
        ):
            fail(f"{label} named consumer is not exact")
        if (
            authorization["retained_consumer_authorized"] is not True
            or authorization["retained_consumer_role"] != role
            or authorization["retained_consumer_instance_id"] != instance_id
        ):
            fail(f"{label} lacks exact retained-consumer authorization")
    return consumer


def verify_typed_events(
    path: Path,
    matrix: MatrixDefinition,
    definition: RowDefinition,
    run_id: str,
    started: datetime,
    completed: datetime,
    final_state: Mapping[str, Any],
) -> int:
    events: list[dict[str, Any]] = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        if not line or any(ord(character) < 0x20 for character in line):
            fail(f"C8 {definition.row_id} typed event line {line_number} is malformed")
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError as error:
            fail(f"C8 {definition.row_id} typed event line {line_number}: {error}")
        events.append(
            require_object(
                parsed, EVENT_KEYS, f"C8 {definition.row_id} event {line_number}"
            )
        )
    if not 8 <= len(events) <= definition.maximum_event_count:
        fail(f"C8 {definition.row_id} typed event count is outside its bound")
    detail_codes: list[str] = []
    timestamps: list[datetime] = []
    for index, event in enumerate(events, 1):
        if (
            event["schema"] != EVENT_SCHEMA
            or event["matrix_id"] != matrix.matrix_id
            or event["row_id"] != definition.row_id
            or event["row_run_id"] != run_id
            or event["event_index"] != index
        ):
            fail(f"C8 {definition.row_id} event {index} identity is not exact")
        timestamp = parse_timestamp(
            event["captured_at_utc"], f"C8 {definition.row_id} event {index}"
        )
        if not started <= timestamp <= completed:
            fail(f"C8 {definition.row_id} event {index} is outside its row timing")
        timestamps.append(timestamp)
        if (
            event["event_type"] not in EVENT_TYPES
            or event["component"] not in EVENT_COMPONENTS
        ):
            fail(f"C8 {definition.row_id} event {index} type/component is unsupported")
        for field in ("producer_epoch", "generation", "sequence"):
            require_positive_integer_or_none(
                event[field], f"C8 {definition.row_id} event {index} {field}"
            )
        if event["frame_disposition"] not in FRAME_DISPOSITIONS:
            fail(
                f"C8 {definition.row_id} event {index} frame disposition is unsupported"
            )
        require_nonnegative_integer(
            event["active_lease_count"],
            f"C8 {definition.row_id} event {index} lease count",
        )
        require_boolean(
            event["capture_active"], f"C8 {definition.row_id} event capture"
        )
        helper_restarts = require_nonnegative_integer(
            event["helper_restart_count"],
            f"C8 {definition.row_id} helper restart count",
        )
        extension_restarts = require_nonnegative_integer(
            event["extension_restart_count"],
            f"C8 {definition.row_id} extension restart count",
        )
        if (
            helper_restarts > definition.maximum_helper_restart_count
            or extension_restarts > definition.maximum_extension_restart_count
        ):
            fail(f"C8 {definition.row_id} restart count exceeds its no-loop bound")
        consumer_instance = event["consumer_instance"]
        if consumer_instance != "none" and (
            not isinstance(consumer_instance, str)
            or CONSUMER_ID_RE.fullmatch(consumer_instance) is None
        ):
            fail(f"C8 {definition.row_id} event consumer identity is malformed")
        detail_code = event["detail_code"]
        if detail_code not in ALLOWED_DETAIL_CODES:
            fail(
                f"C8 {definition.row_id} event detail code is not privacy-safe typed evidence"
            )
        detail_codes.append(detail_code)
    if timestamps != sorted(timestamps):
        fail(f"C8 {definition.row_id} event timestamps moved backward")
    required = {
        "row-started",
        "identity-before-stable",
        "action-boundary",
        "stale-frame-rejected",
        "identity-after-stable",
        "final-state-observed",
        "row-completed",
        *definition.required_detail_codes,
    }
    missing = sorted(required - set(detail_codes))
    if missing:
        fail(f"C8 {definition.row_id} typed evidence lacks {','.join(missing)}")
    if detail_codes[0] != "row-started" or detail_codes[-1] != "row-completed":
        fail(f"C8 {definition.row_id} event boundaries are not exact")
    stale_index = detail_codes.index("stale-frame-rejected")
    stale = events[stale_index]
    if (
        stale["event_type"] != "frame"
        or stale["frame_disposition"] != "stale-rejected"
        or any(
            stale[field] is None
            for field in ("producer_epoch", "generation", "sequence")
        )
    ):
        fail(f"C8 {definition.row_id} stale-frame rejection is not typed")
    if definition.requires_fresh_recovery:
        fresh_indices = [
            index
            for index, code in enumerate(detail_codes)
            if code == "fresh-frame-consumed" and index > stale_index
        ]
        if not fresh_indices:
            fail(f"C8 {definition.row_id} lacks fresh post-transition delivery")
        fresh = events[fresh_indices[0]]
        if (
            fresh["event_type"] != "frame"
            or fresh["frame_disposition"] != "fresh-consumed"
            or any(
                fresh[field] is None
                for field in ("producer_epoch", "generation", "sequence")
            )
            or (
                fresh["producer_epoch"] == stale["producer_epoch"]
                and fresh["generation"] == stale["generation"]
            )
        ):
            fail(
                f"C8 {definition.row_id} fresh delivery reused stale producer identity"
            )
    if (
        definition.row_id == "helper-crash-recovery"
        and max(event["helper_restart_count"] for event in events) != 1
    ):
        fail("C8 helper crash row did not prove exactly one helper relaunch")
    if (
        definition.row_id == "extension-crash-recovery"
        and max(event["extension_restart_count"] for event in events) != 1
    ):
        fail("C8 extension crash row did not prove exactly one extension reload")
    final_event = events[-2]
    if final_event["detail_code"] != "final-state-observed":
        fail(f"C8 {definition.row_id} final-state event is misplaced")
    for key in (
        "active_lease_count",
        "capture_active",
        "helper_restart_count",
        "extension_restart_count",
    ):
        if final_event[key] != final_state[key]:
            fail(f"C8 {definition.row_id} final event {key} differs from final state")
    return len(events)


def verify_completed_row(
    matrix: MatrixDefinition,
    definition: RowDefinition,
) -> VerifiedRow:
    path = matrix.row_paths[definition.row_id]
    row = require_object(
        read_json(path, f"C8 row {definition.row_id}"),
        ROW_KEYS,
        f"C8 row {definition.row_id}",
    )
    if (
        row["schema"] != ROW_SCHEMA
        or row["matrix_id"] != matrix.matrix_id
        or row["row_id"] != definition.row_id
        or row["ordinal"] != definition.ordinal
        or row["scenario"] != definition.scenario
        or row["action_class"] != definition.action_class
        or row["status"] != "completed"
    ):
        fail(f"C8 row {definition.row_id} contract is not exact or completed")
    run_id = row["row_run_id"]
    if not isinstance(run_id, str) or ID_RE.fullmatch(run_id) is None:
        fail(f"C8 row {definition.row_id} run ID is malformed")
    require_candidate(row["candidate"], matrix.candidate, f"C8 row {definition.row_id}")

    authorization = require_object(
        row["authorization"],
        AUTHORIZATION_KEYS,
        f"C8 row {definition.row_id} authorization",
    )
    authorization_id = authorization["id"]
    if (
        not isinstance(authorization_id, str)
        or ID_RE.fullmatch(authorization_id) is None
    ):
        fail(f"C8 row {definition.row_id} authorization ID is malformed")
    expected_authorization = {
        "environment_variable": definition.authorization_environment_variable,
        "value": "YES",
        "action_class": definition.action_class,
        "row_only": True,
        "expires_after_row": True,
        "scope_statement": definition.scope_statement,
    }
    for key, expected in expected_authorization.items():
        if authorization[key] != expected:
            fail(f"C8 row {definition.row_id} authorization {key} is not exact")
    require_boolean(
        authorization["retained_consumer_authorized"],
        f"C8 row {definition.row_id} retained consumer authorization",
    )
    granted = parse_timestamp(
        authorization["granted_at_utc"],
        f"C8 row {definition.row_id} authorization time",
    )

    console = require_object(
        row["console"], CONSOLE_KEYS, f"C8 row {definition.row_id} console"
    )
    state = console["state_at_start"]
    if console["requires_unlocked_start"] != definition.requires_unlocked_start:
        fail(f"C8 row {definition.row_id} console policy drifted")
    if state not in ("locked", "unlocked"):
        fail(f"C8 row {definition.row_id} console state is unknown")
    if definition.requires_unlocked_start and state != "unlocked":
        fail(f"C8 row {definition.row_id} started while locked")

    timing = require_object(
        row["timing"], TIMING_KEYS, f"C8 row {definition.row_id} timing"
    )
    started = parse_timestamp(
        timing["started_at_utc"], f"C8 row {definition.row_id} start"
    )
    completed = parse_timestamp(
        timing["completed_at_utc"], f"C8 row {definition.row_id} completion"
    )
    if not granted <= started < completed:
        fail(f"C8 row {definition.row_id} timing is not ordered after authorization")

    evidence = require_object(
        row["evidence"], EVIDENCE_KEYS, f"C8 row {definition.row_id} evidence"
    )
    artifact_paths: list[str] = []
    artifact_hashes: list[str] = []
    resolved: dict[str, Path] = {}
    for key in EVIDENCE_ORDER:
        artifact, artifact_hash = require_relative_artifact(
            matrix.root, evidence[key], f"C8 row {definition.row_id} {key}"
        )
        resolved[key] = artifact
        artifact_paths.append(artifact.relative_to(matrix.root).as_posix())
        artifact_hashes.append(artifact_hash)
    if len(set(artifact_paths)) != len(artifact_paths):
        fail(f"C8 row {definition.row_id} reuses an evidence artifact")

    before_time = verify_identity(
        resolved["identity_before"], matrix, definition, run_id, "C8 identity before"
    )
    after_time = verify_identity(
        resolved["identity_after"], matrix, definition, run_id, "C8 identity after"
    )
    if not started <= before_time <= after_time <= completed:
        fail(f"C8 row {definition.row_id} identity captures are outside the row")

    console_state = require_object(
        read_json(resolved["console_state"], "C8 console state"),
        CONSOLE_STATE_KEYS,
        "C8 console state",
    )
    if console_state != {
        "schema": CONSOLE_STATE_SCHEMA,
        "matrix_id": matrix.matrix_id,
        "row_id": definition.row_id,
        "row_run_id": run_id,
        "captured_at_utc": console_state["captured_at_utc"],
        "state": state,
        "source": "read-console-lock-state",
    }:
        fail(f"C8 row {definition.row_id} console artifact is not exact")
    console_time = parse_timestamp(
        console_state["captured_at_utc"], f"C8 row {definition.row_id} console capture"
    )
    if not granted <= console_time <= started:
        fail(f"C8 row {definition.row_id} console state was not captured at preflight")

    final_state = require_object(
        read_json(resolved["final_state"], "C8 final state"),
        FINAL_STATE_KEYS,
        "C8 final state",
    )
    for key, expected in {
        "schema": FINAL_STATE_SCHEMA,
        "matrix_id": matrix.matrix_id,
        "row_id": definition.row_id,
        "row_run_id": run_id,
        "restart_loop_detected": False,
        "focus_theft": False,
        "stale_frame_presented": False,
    }.items():
        if final_state[key] != expected:
            fail(f"C8 row {definition.row_id} final state {key} is not safe")
    final_time = parse_timestamp(
        final_state["captured_at_utc"], f"C8 row {definition.row_id} final state time"
    )
    if not after_time <= final_time <= completed:
        fail(f"C8 row {definition.row_id} final state time is outside the row")
    lease_count = require_nonnegative_integer(
        final_state["active_lease_count"], f"C8 row {definition.row_id} final leases"
    )
    capture_active = require_boolean(
        final_state["capture_active"], f"C8 row {definition.row_id} final capture"
    )
    helper_restarts = require_nonnegative_integer(
        final_state["helper_restart_count"],
        f"C8 row {definition.row_id} helper restarts",
    )
    extension_restarts = require_nonnegative_integer(
        final_state["extension_restart_count"],
        f"C8 row {definition.row_id} extension restarts",
    )
    if (
        helper_restarts > definition.maximum_helper_restart_count
        or extension_restarts > definition.maximum_extension_restart_count
    ):
        fail(f"C8 row {definition.row_id} final restart count exceeds its bound")
    if final_state["producer_state"] not in (
        "idle",
        "streaming",
        "unavailable",
        "disabled",
    ):
        fail(f"C8 row {definition.row_id} final producer state is unsupported")
    if final_state["led_state"] not in ("off", "on", "unavailable"):
        fail(f"C8 row {definition.row_id} final LED state is unsupported")
    final_consumer = verify_final_consumer(
        final_state["final_consumer"],
        authorization,
        lease_count,
        capture_active,
        f"C8 row {definition.row_id} final consumer",
    )
    if capture_active and final_state["led_state"] != "on":
        fail(f"C8 row {definition.row_id} active capture lacks an on LED observation")
    if not capture_active and final_state["led_state"] == "on":
        fail(f"C8 row {definition.row_id} stopped capture retains an on LED")

    event_count = verify_typed_events(
        resolved["typed_events"],
        matrix,
        definition,
        run_id,
        started,
        completed,
        final_state,
    )

    attestation = require_object(
        read_json(resolved["operator_attestation"], "C8 operator attestation"),
        ATTESTATION_KEYS,
        "C8 operator attestation",
    )
    expected_attestation = {
        "schema": ATTESTATION_SCHEMA,
        "matrix_id": matrix.matrix_id,
        "row_id": definition.row_id,
        "row_run_id": run_id,
        "authorization_id": authorization_id,
        "action_class": definition.action_class,
        "physical_action_performed": True,
        "unexpected_prompt": False,
        "focus_theft": False,
        "restart_loop_detected": False,
        "stale_frame_presented": False,
        "raw_frame_or_content_evidence": False,
        "pixel_data_recorded": False,
        "biometric_data_recorded": False,
        "device_serial_recorded": False,
        "unredacted_username_recorded": False,
    }
    if attestation != expected_attestation:
        fail(f"C8 row {definition.row_id} operator attestation is unsafe or mismatched")

    observations = require_object(
        row["observations"],
        OBSERVATION_KEYS,
        f"C8 row {definition.row_id} observations",
    )
    expected_observations = {
        "typed_event_count": event_count,
        "stale_frames_rejected": True,
        "stale_frames_presented": False,
        "restart_loop_detected": False,
        "focus_theft": False,
        "identity_changed": False,
        "raw_frame_or_content_evidence": False,
        "pixel_data_recorded": False,
        "biometric_data_recorded": False,
        "device_serial_recorded": False,
        "unredacted_username_recorded": False,
        "final_active_lease_count": lease_count,
        "final_capture_active": capture_active,
        "final_consumer": final_consumer,
    }
    if observations != expected_observations:
        fail(f"C8 row {definition.row_id} observations are incomplete or unsafe")
    verdict = require_object(
        row["verdict"], VERDICT_KEYS, f"C8 row {definition.row_id} verdict"
    )
    if verdict != {"result": "passed", "rejection_reasons": []}:
        fail(f"C8 row {definition.row_id} did not produce a release-supporting verdict")
    return VerifiedRow(
        definition,
        run_id,
        authorization_id,
        sha256(path),
        tuple(artifact_paths),
        tuple(artifact_hashes),
    )


def verify_matrix(matrix_path: Path) -> VerifiedMatrix:
    matrix = load_matrix_definition(matrix_path)
    rows = tuple(verify_completed_row(matrix, definition) for definition in ROWS)
    run_ids = [row.row_run_id for row in rows]
    authorization_ids = [row.authorization_id for row in rows]
    if len(set(run_ids)) != len(run_ids):
        fail("C8 rows reuse a row-run identity")
    if len(set(authorization_ids)) != len(authorization_ids):
        fail("C8 rows reuse an authorization identity")
    all_paths = [path for row in rows for path in row.artifact_paths]
    if len(set(all_paths)) != len(all_paths):
        fail("C8 rows reuse an evidence path")
    return VerifiedMatrix(matrix, sha256(matrix_path), rows)
