#!/usr/bin/python3

"""Offline verifier for the C5 unlocked-companion physical-camera row.

The verifier consumes retained, hash-bound evidence only.  It never launches an
application, changes TCC, opens Settings, starts AVFoundation, or touches camera
hardware.
"""

from __future__ import annotations

import hashlib
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence

import verify_camera_gate_a1_log as gate_a


class EvidenceFailure(Exception):
    pass


TEAM = "3524374A2S"
APP_GROUP = "group.com.idlescreen.shared"
MACH_SERVICE = "group.com.idlescreen.shared.camera-agent"
APP_ID = "com.idlescreen.app"
HELPER_ID = "com.idlescreen.camera-agent"
EXTENSION_ID = "com.idlescreen.app.screensaver"
APP_PATH = "/Applications/idlescreen.app"
APP_EXECUTABLE = f"{APP_PATH}/Contents/MacOS/IdleScreen"
HELPER_EXECUTABLE = (
    f"{APP_PATH}/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/"
    "IdleScreenCameraAgent"
)
EXTENSION_EXECUTABLE = (
    f"{APP_PATH}/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/"
    "IdleScreenScreenSaver"
)

SHA256 = re.compile(r"[0-9a-f]{64}")
CDHASH = re.compile(r"[0-9a-f]{40}")
POSITIVE = re.compile(r"[1-9][0-9]*")

MANIFEST_FIELDS = (
    "format",
    "evidence_semantics",
    "trusted_for_production",
    "attribution_verdict",
    "console_state",
    "app_launch_action",
    "app_launch_authorization",
    "tcc_reset_action",
    "tcc_reset_authorization",
    "tcc_request_action",
    "tcc_request_authorization",
    "tcc_settings_action",
    "tcc_settings_authorization",
    "camera_start_action",
    "camera_start_authorization",
    "camera_hardware_action",
    "camera_hardware_authorization",
    "c3_provenance_manifest",
    "c3_provenance_manifest_sha256",
    "c4_restoration_manifest",
    "c4_restoration_manifest_sha256",
    "c3_archive_tree_sha256",
    "identity_snapshot",
    "identity_snapshot_sha256",
    "runtime_ownership",
    "runtime_ownership_sha256",
    "attribution_observation",
    "attribution_observation_sha256",
    "led_observation",
    "led_observation_sha256",
    "checkpoints",
    "checkpoints_sha256",
    "log_path",
    "log_sha256",
    "helper_pid",
    "companion_pid",
    "capture_generation",
    "consumption_generation",
    "producer_epoch",
    "first_consumed_sequence",
    "last_consumed_sequence",
    "consumed_receipt_count",
    "final_active_lease_count",
)

C3_FIELDS = (
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

C4_TRANSACTION_FIELDS = (
    "format",
    "mode",
    "started_at_utc",
    "marker_processes_absent_at_utc",
    "production_restored_at_utc",
    "completed_at_utc",
    "c3_archive_tree_sha256",
    "c3_provenance_manifest_sha256",
    "gate_binding_manifest_sha256",
    "synthetic_gate_manifest_sha256",
    "a1_evidence_manifest",
    "a1_evidence_manifest_sha256",
    "transaction_journal",
    "transaction_journal_sha256",
    "transaction_transitions",
    "transaction_transitions_sha256",
    "pre_state",
    "pre_state_sha256",
    "quiescence_inventory",
    "quiescence_inventory_sha256",
    "gate_bound_state",
    "gate_bound_state_sha256",
    "post_restore_state",
    "post_restore_state_sha256",
    "marker_process_inventory",
    "marker_process_inventory_sha256",
    "installed_production_identity",
    "installed_production_identity_sha256",
    "restored_production_tree_inventory",
    "restored_production_tree_inventory_sha256",
    "initial_helper_runtime_entitlements",
    "initial_helper_runtime_entitlements_sha256",
    "saver_runtime_entitlements",
    "saver_runtime_entitlements_sha256",
    "recovered_helper_runtime_entitlements",
    "recovered_helper_runtime_entitlements_sha256",
)

C4_INSTALLED_FIELDS = (
    "format",
    "captured_at_utc",
    "app_path",
    "app_cdhash",
    "helper_path",
    "helper_cdhash",
    "extension_path",
    "extension_cdhash",
    "deep_signature",
    "helper_marker",
    "extension_marker",
)

IDENTITY_FIELDS = (
    "format",
    "captured_at_utc",
    "app_path",
    "app_bundle_identifier",
    "app_team_identifier",
    "app_cdhash",
    "helper_path",
    "helper_bundle_identifier",
    "helper_team_identifier",
    "helper_cdhash",
    "extension_path",
    "extension_bundle_identifier",
    "extension_team_identifier",
    "extension_cdhash",
    "deep_signature",
    "helper_marker",
    "extension_marker",
    "restored_release_identity",
)

OWNERSHIP_FIELDS = (
    "format",
    "captured_at_utc",
    "helper_pid",
    "helper_path",
    "helper_cdhash",
    "companion_pid",
    "companion_path",
    "companion_cdhash",
    "screen_saver_pids",
    "other_helper_pids",
    "static_avfoundation_owner_bundle_identifier",
    "runtime_capture_owner_pid",
    "companion_frame_consumer_pid",
    "active_peer_role",
    "maximum_active_lease_count",
    "avfoundation_capture_owner_count",
    "sole_avfoundation_owner",
)

ATTRIBUTION_FIELDS = (
    "format",
    "fresh_authorization_state",
    "visible_permission_label",
    "permission_action",
    "authorized_bundle_identifier",
    "preview_lease_during_permission",
    "capture_during_permission",
    "attribution_verdict",
)

LED_FIELDS = (
    "format",
    "observer",
    "before_preview",
    "during_preview",
    "after_final_lease",
    "after_final_lease_observed_at_utc",
)

CHECKPOINT_FIELDS = (
    "format",
    "runner_started_at_utc",
    "identity_verified_at_utc",
    "console_unlocked_at_utc",
    "app_launch_authorized_at_utc",
    "app_launched_at_utc",
    "permission_not_determined_at_utc",
    "permission_action_authorized_at_utc",
    "permission_request_at_utc",
    "permission_authorized_at_utc",
    "permission_zero_lease_at_utc",
    "preview_action_authorized_at_utc",
    "hardware_use_authorized_at_utc",
    "preview_request_at_utc",
    "preview_lease_at_utc",
    "capture_started_at_utc",
    "first_consumed_at_utc",
    "last_consumed_at_utc",
    "stop_request_at_utc",
    "final_lease_zero_at_utc",
    "capture_stopped_at_utc",
    "led_off_at_utc",
    "completed_at_utc",
)

COMPANION_NAMESPACE = "[com.idlescreen.app:CameraEvidence]"
COMPANION_PID = re.compile(r"IdleScreen\[(?P<pid>[1-9][0-9]*):")
COMPANION_RECEIPT = re.compile(
    r"companion_frame_consumed generation=(?P<generation>[1-9][0-9]*) "
    r"epoch=(?P<epoch>[1-9][0-9]*) sequence=(?P<sequence>[1-9][0-9]*)"
)


@dataclass(frozen=True)
class CompanionReceipt:
    line: int
    timestamp: float
    pid: int
    generation: int
    epoch: int
    sequence: int


def fail(message: str) -> None:
    raise EvidenceFailure(message)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_kv(
    path: Path,
    fields: Sequence[str],
    label: str,
) -> Dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        fail(f"could not read {label}: {error}")
    values: Dict[str, str] = {}
    for line_number, line in enumerate(lines, start=1):
        if not line or "=" not in line:
            fail(f"{label} line {line_number} is not one key=value record")
        key, value = line.split("=", 1)
        if key not in fields:
            fail(f"{label} contains unexpected field {key}")
        if key in values:
            fail(f"{label} repeats field {key}")
        if not value or "\t" in value or "\n" in value:
            fail(f"{label} field {key} is empty or malformed")
        values[key] = value
    missing = [field for field in fields if field not in values]
    if missing:
        fail(f"{label} is missing fields: {', '.join(missing)}")
    return values


def require_equal(values: Dict[str, str], expected: Dict[str, str], label: str) -> None:
    for key, wanted in expected.items():
        if values.get(key) != wanted:
            fail(f"{label} {key} is {values.get(key)!r}, expected {wanted!r}")


def require_sha(value: str, label: str) -> str:
    normalized = value.lower()
    if SHA256.fullmatch(normalized) is None:
        fail(f"{label} is not a lowercase SHA-256")
    return normalized


def require_cdhash(value: str, label: str) -> str:
    normalized = value.lower()
    if CDHASH.fullmatch(normalized) is None:
        fail(f"{label} is not a 40-digit CDHash")
    return normalized


def require_positive(value: str, label: str) -> int:
    if POSITIVE.fullmatch(value) is None:
        fail(f"{label} is not a positive integer")
    return int(value)


def require_regular(path_value: str, digest: str, label: str) -> Path:
    path = Path(path_value)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        fail(f"{label} must be an absolute nonsymlink regular file")
    expected = require_sha(digest, f"{label} digest")
    if sha256_file(path) != expected:
        fail(f"{label} digest changed")
    return path


def parse_timestamp(value: str, label: str) -> float:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(f"{label} is not an ISO-8601 timestamp")
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        fail(f"{label} has no timezone")
    return parsed.timestamp()


def validate_c3(path: Path) -> Dict[str, str]:
    values = parse_kv(path, C3_FIELDS, "C3 provenance manifest")
    require_equal(
        values,
        {
            "schema": "IdleScreenReleaseArchiveProvenance/v1",
            "verification_mode": "release",
            "team_identifier": TEAM,
            "app_group": APP_GROUP,
            "mach_service": MACH_SERVICE,
            "app_bundle_identifier": APP_ID,
            "helper_bundle_identifier": HELPER_ID,
            "extension_bundle_identifier": EXTENSION_ID,
        },
        "C3 provenance manifest",
    )
    for key in (
        "archive_tree_sha256",
        "camera_usage_description_sha256",
        "launch_agent_sha256",
        "signer_certificate_sha256",
        "app_designated_requirement_sha256",
        "app_entitlements_sha256",
        "app_profile_sha256",
        "extension_designated_requirement_sha256",
        "extension_entitlements_sha256",
        "extension_profile_sha256",
        "helper_designated_requirement_sha256",
        "helper_entitlements_sha256",
        "helper_profile_sha256",
    ):
        require_sha(values[key], f"C3 {key}")
    for key in ("app_cdhash", "helper_cdhash", "extension_cdhash"):
        values[key] = require_cdhash(values[key], f"C3 {key}")
    return values


def validate_c4_restoration(
    path: Path,
    c3: Dict[str, str],
    c3_manifest_digest: str,
) -> float:
    values = parse_kv(path, C4_TRANSACTION_FIELDS, "C4 restoration manifest")
    require_equal(
        values,
        {
            "format": "IdleScreenCameraGateC4TransactionV1",
            "mode": "a1tr",
            "c3_archive_tree_sha256": c3["archive_tree_sha256"],
            "c3_provenance_manifest_sha256": c3_manifest_digest,
        },
        "C4 restoration manifest",
    )
    restored = parse_timestamp(values["production_restored_at_utc"], "C4 restoration")
    completed = parse_timestamp(values["completed_at_utc"], "C4 completion")
    marker_absent = parse_timestamp(
        values["marker_processes_absent_at_utc"], "C4 marker absence"
    )
    if not marker_absent <= restored <= completed:
        fail("C4 restoration timestamps are not ordered")
    installed_path = require_regular(
        values["installed_production_identity"],
        values["installed_production_identity_sha256"],
        "C4 installed production identity",
    )
    installed = parse_kv(
        installed_path, C4_INSTALLED_FIELDS, "C4 installed production identity"
    )
    require_equal(
        installed,
        {
            "format": "IdleScreenCameraGateC4InstalledIdentityV1",
            "captured_at_utc": values["production_restored_at_utc"],
            "app_path": APP_PATH,
            "app_cdhash": c3["app_cdhash"],
            "helper_path": HELPER_EXECUTABLE,
            "helper_cdhash": c3["helper_cdhash"],
            "extension_path": EXTENSION_EXECUTABLE,
            "extension_cdhash": c3["extension_cdhash"],
            "deep_signature": "valid",
            "helper_marker": "absent",
            "extension_marker": "absent",
        },
        "C4 installed production identity",
    )
    require_regular(
        values["restored_production_tree_inventory"],
        values["restored_production_tree_inventory_sha256"],
        "C4 restored production tree inventory",
    )
    return completed


def parse_companion_receipts(lines: Iterable[str]) -> List[CompanionReceipt]:
    receipts: List[CompanionReceipt] = []
    for line_number, line in enumerate(lines, start=1):
        if "[com.idlescreen.app:" not in line:
            continue
        if COMPANION_NAMESPACE not in line:
            fail(f"line {line_number} uses an unexpected companion evidence category")
        pid_match = COMPANION_PID.search(line)
        if pid_match is None:
            fail(f"line {line_number} lacks an exact companion PID")
        message = gate_a.message_after_namespace(line, COMPANION_NAMESPACE)
        match = COMPANION_RECEIPT.fullmatch(message)
        if match is None:
            fail(f"line {line_number} is not a whitelisted companion receipt")
        receipts.append(
            CompanionReceipt(
                line=line_number,
                timestamp=gate_a.structured_timestamp(line, line_number),
                pid=int(pid_match.group("pid")),
                generation=int(match.group("generation")),
                epoch=int(match.group("epoch")),
                sequence=int(match.group("sequence")),
            )
        )
    return receipts


def event_between(
    events: Sequence[gate_a.AgentEvent],
    *,
    name: str,
    after: float,
    before: float,
    fields: Optional[Dict[str, str]] = None,
) -> gate_a.AgentEvent:
    expected = fields or {}
    matches = [
        event
        for event in events
        if event.name == name
        and after <= event.timestamp <= before
        and all(event.fields.get(key) == value for key, value in expected.items())
    ]
    if not matches:
        detail = " ".join(f"{key}={value}" for key, value in expected.items())
        fail(f"missing {name}{(' ' + detail) if detail else ''} in its authorized phase")
    return matches[0]


def verify(manifest_path: Path) -> None:
    if not manifest_path.is_absolute() or manifest_path.is_symlink() or not manifest_path.is_file():
        fail("C5 evidence manifest must be an absolute nonsymlink regular file")
    top = parse_kv(manifest_path, MANIFEST_FIELDS, "C5 evidence manifest")
    require_equal(
        top,
        {
            "format": "IdleScreenCameraGateC5EvidenceV1",
            "evidence_semantics": "unlocked-companion-physical-camera",
            "trusted_for_production": "true",
            "attribution_verdict": "resolved-fresh",
            "console_state": "unlocked",
            "app_launch_action": "performed",
            "app_launch_authorization": "yes",
            "tcc_request_action": "performed",
            "tcc_request_authorization": "yes",
            "camera_start_action": "performed",
            "camera_start_authorization": "yes",
            "camera_hardware_action": "performed",
            "camera_hardware_authorization": "yes",
            "final_active_lease_count": "0",
        },
        "C5 evidence manifest",
    )
    for action in ("tcc_reset", "tcc_settings"):
        performed = top[f"{action}_action"] == "performed"
        if top[f"{action}_action"] not in ("performed", "not-performed"):
            fail(f"C5 {action} action has an invalid value")
        expected_authorization = "yes" if performed else "not-used"
        if top[f"{action}_authorization"] != expected_authorization:
            fail(f"C5 {action} action is not bound to its distinct authorization")

    c3_path = require_regular(
        top["c3_provenance_manifest"],
        top["c3_provenance_manifest_sha256"],
        "C3 provenance manifest",
    )
    c3 = validate_c3(c3_path)
    if top["c3_archive_tree_sha256"] != c3["archive_tree_sha256"]:
        fail("C5 evidence names a different C3 archive tree")
    c4_path = require_regular(
        top["c4_restoration_manifest"],
        top["c4_restoration_manifest_sha256"],
        "C4 restoration manifest",
    )
    c4_completed = validate_c4_restoration(
        c4_path, c3, top["c3_provenance_manifest_sha256"]
    )

    identity_path = require_regular(
        top["identity_snapshot"], top["identity_snapshot_sha256"], "C5 identity snapshot"
    )
    identity = parse_kv(identity_path, IDENTITY_FIELDS, "C5 identity snapshot")
    require_equal(
        identity,
        {
            "format": "IdleScreenCameraGateC5IdentityV1",
            "app_path": APP_PATH,
            "app_bundle_identifier": APP_ID,
            "app_team_identifier": TEAM,
            "app_cdhash": c3["app_cdhash"],
            "helper_path": HELPER_EXECUTABLE,
            "helper_bundle_identifier": HELPER_ID,
            "helper_team_identifier": TEAM,
            "helper_cdhash": c3["helper_cdhash"],
            "extension_path": EXTENSION_EXECUTABLE,
            "extension_bundle_identifier": EXTENSION_ID,
            "extension_team_identifier": TEAM,
            "extension_cdhash": c3["extension_cdhash"],
            "deep_signature": "valid",
            "helper_marker": "absent",
            "extension_marker": "absent",
            "restored_release_identity": "exact",
        },
        "C5 identity snapshot",
    )
    identity_time = parse_timestamp(identity["captured_at_utc"], "C5 identity snapshot")
    if identity_time < c4_completed:
        fail("C5 identity snapshot predates C4 production restoration")

    helper_pid = require_positive(top["helper_pid"], "C5 helper PID")
    companion_pid = require_positive(top["companion_pid"], "C5 companion PID")
    capture_generation = require_positive(
        top["capture_generation"], "C5 capture generation"
    )
    consumption_generation = require_positive(
        top["consumption_generation"], "C5 consumption generation"
    )
    epoch = require_positive(top["producer_epoch"], "C5 producer epoch")
    first_sequence = require_positive(
        top["first_consumed_sequence"], "C5 first consumed sequence"
    )
    last_sequence = require_positive(
        top["last_consumed_sequence"], "C5 last consumed sequence"
    )
    receipt_count = require_positive(top["consumed_receipt_count"], "C5 receipt count")
    if receipt_count < 3 or last_sequence <= first_sequence:
        fail("C5 manifest does not record three increasing companion receipts")

    ownership_path = require_regular(
        top["runtime_ownership"],
        top["runtime_ownership_sha256"],
        "C5 runtime ownership",
    )
    ownership = parse_kv(ownership_path, OWNERSHIP_FIELDS, "C5 runtime ownership")
    require_equal(
        ownership,
        {
            "format": "IdleScreenCameraGateC5RuntimeOwnershipV1",
            "helper_pid": str(helper_pid),
            "helper_path": HELPER_EXECUTABLE,
            "helper_cdhash": c3["helper_cdhash"],
            "companion_pid": str(companion_pid),
            "companion_path": APP_EXECUTABLE,
            "companion_cdhash": c3["app_cdhash"],
            "screen_saver_pids": "none",
            "other_helper_pids": "none",
            "static_avfoundation_owner_bundle_identifier": HELPER_ID,
            "runtime_capture_owner_pid": str(helper_pid),
            "companion_frame_consumer_pid": str(companion_pid),
            "active_peer_role": "companion",
            "maximum_active_lease_count": "1",
            "avfoundation_capture_owner_count": "1",
            "sole_avfoundation_owner": "true",
        },
        "C5 runtime ownership",
    )
    ownership_time = parse_timestamp(ownership["captured_at_utc"], "C5 ownership")

    attribution_path = require_regular(
        top["attribution_observation"],
        top["attribution_observation_sha256"],
        "C5 attribution observation",
    )
    attribution = parse_kv(
        attribution_path, ATTRIBUTION_FIELDS, "C5 attribution observation"
    )
    require_equal(
        attribution,
        {
            "format": "IdleScreenCameraGateC5AttributionV1",
            "fresh_authorization_state": "not-determined",
            "visible_permission_label": "idlescreen",
            "permission_action": "companion-explicit-request",
            "authorized_bundle_identifier": HELPER_ID,
            "preview_lease_during_permission": "absent",
            "capture_during_permission": "absent",
            "attribution_verdict": "resolved-fresh",
        },
        "C5 attribution observation",
    )

    led_path = require_regular(
        top["led_observation"], top["led_observation_sha256"], "C5 LED observation"
    )
    led = parse_kv(led_path, LED_FIELDS, "C5 LED observation")
    require_equal(
        led,
        {
            "format": "IdleScreenCameraGateC5LEDObservationV1",
            "observer": "human-visible-camera-indicator",
            "before_preview": "off",
            "during_preview": "on",
            "after_final_lease": "off",
        },
        "C5 LED observation",
    )
    led_off = parse_timestamp(
        led["after_final_lease_observed_at_utc"], "C5 LED-off observation"
    )

    checkpoints_path = require_regular(
        top["checkpoints"], top["checkpoints_sha256"], "C5 checkpoints"
    )
    checkpoints = parse_kv(checkpoints_path, CHECKPOINT_FIELDS, "C5 checkpoints")
    require_equal(
        checkpoints,
        {"format": "IdleScreenCameraGateC5CheckpointsV1"},
        "C5 checkpoints",
    )
    checkpoint_times = {
        key: parse_timestamp(value, f"C5 checkpoint {key}")
        for key, value in checkpoints.items()
        if key != "format"
    }
    ordered = [checkpoint_times[key] for key in CHECKPOINT_FIELDS if key != "format"]
    if any(later < earlier for earlier, later in zip(ordered, ordered[1:])):
        fail("C5 checkpoints are not monotonic")
    if checkpoint_times["identity_verified_at_utc"] != identity_time:
        fail("C5 identity snapshot is not bound to its checkpoint")
    if led_off != checkpoint_times["led_off_at_utc"]:
        fail("C5 LED observation is not bound to its checkpoint")
    if not (
        checkpoint_times["preview_lease_at_utc"]
        <= ownership_time
        <= checkpoint_times["stop_request_at_utc"]
    ):
        fail("C5 ownership snapshot was not captured while preview was active")

    log_path = require_regular(top["log_path"], top["log_sha256"], "C5 lifecycle log")
    lines = log_path.read_text(encoding="utf-8").splitlines()
    events, saver_receipts, markers, preflights, animations = gate_a.parse(lines)
    if saver_receipts or markers or preflights or animations:
        fail("C5 companion evidence unexpectedly contains a hosted screen-saver row")
    receipts = parse_companion_receipts(lines)
    if not events:
        fail("C5 evidence contains no agent diagnostics")
    if any(event.pid != helper_pid for event in events):
        fail("C5 diagnostics contain more than one camera-agent PID")

    run_start = checkpoint_times["runner_started_at_utc"]
    launch = checkpoint_times["app_launched_at_utc"]
    permission_request = checkpoint_times["permission_request_at_utc"]
    preview_request = checkpoint_times["preview_request_at_utc"]
    stop_request = checkpoint_times["stop_request_at_utc"]
    completed = checkpoint_times["completed_at_utc"]
    if min(event.timestamp for event in events) < run_start - 1.0:
        fail("C5 agent evidence predates the retained run")
    if max(event.timestamp for event in events) > completed + 1.0:
        fail("C5 agent evidence outlives the retained run")

    event_between(
        events,
        name="authorization_status",
        after=launch,
        before=permission_request,
        fields={"status": "not-determined"},
    )
    event_between(
        events,
        name="authorization_status",
        after=permission_request,
        before=preview_request,
        fields={"status": "authorized", "source": "explicit-request-completion"},
    )
    for event in events:
        if event.timestamp >= preview_request:
            continue
        if event.name in (
            "capture_start_requested",
            "capture_started",
            "first_frame_published",
            "capture_stop_requested",
            "capture_stopped",
        ):
            fail("capture lifecycle began before the separately authorized preview action")
        if event.name == "lease_count_changed" and int(event.fields["current"]) != 0:
            fail("a preview lease existed during the permission-only phase")

    admissions = [
        event
        for event in events
        if event.name == "peer_admission_accepted"
        and event.fields["role"] == "companion"
        and event.fields["peer_pid"] == str(companion_pid)
        and event.fields["team_id"] == TEAM
        and event.fields["bundle_id"] == APP_ID
    ]
    if not admissions:
        fail("exact companion peer admission is missing")
    if any(
        event.name == "peer_admission_accepted"
        and event.fields["role"] != "companion"
        for event in events
    ):
        fail("a non-companion peer was admitted during C5")

    lifecycle_events = [
        event
        for event in events
        if preview_request <= event.timestamp <= completed
        and event.name
        in (
            "lease_count_changed",
            "capture_start_requested",
            "capture_started",
            "first_frame_published",
            "capture_stop_requested",
            "capture_stopped",
        )
    ]
    expected_lifecycle = [
        "lease_count_changed",
        "capture_start_requested",
        "capture_started",
        "first_frame_published",
        "lease_count_changed",
        "capture_stop_requested",
        "capture_stopped",
    ]
    if [event.name for event in lifecycle_events] != expected_lifecycle:
        fail(
            "C5 requires exactly one ordered lease/start/frame/stop lifecycle; "
            "an event is missing, duplicated, or restarted"
        )

    lease_start = event_between(
        events,
        name="lease_count_changed",
        after=preview_request,
        before=stop_request,
        fields={"previous": "0", "current": "1", "epoch": str(epoch)},
    )
    start_requested = event_between(
        events,
        name="capture_start_requested",
        after=lease_start.timestamp,
        before=stop_request,
        fields={"generation": str(capture_generation), "epoch": str(epoch)},
    )
    started = event_between(
        events,
        name="capture_started",
        after=start_requested.timestamp,
        before=stop_request,
        fields={"generation": str(capture_generation), "epoch": str(epoch)},
    )
    first_published = event_between(
        events,
        name="first_frame_published",
        after=started.timestamp,
        before=stop_request,
        fields={"generation": str(capture_generation), "epoch": str(epoch)},
    )

    active_receipts = [
        receipt
        for receipt in receipts
        if first_published.timestamp <= receipt.timestamp <= stop_request
    ]
    if len(active_receipts) != receipt_count or len(active_receipts) < 3:
        fail("companion receipt count is not exact or is below three")
    if len(receipts) != len(active_receipts):
        fail("a companion receipt exists outside the one authorized capture lifecycle")
    previous_sequence = 0
    for receipt in active_receipts:
        if receipt.pid != companion_pid:
            fail("a companion receipt came from a different PID")
        if receipt.generation != consumption_generation or receipt.epoch != epoch:
            fail("a companion receipt crossed consumption generation or producer epoch")
        if receipt.sequence <= previous_sequence:
            fail("companion receipt sequence did not strictly increase")
        previous_sequence = receipt.sequence
    if (
        active_receipts[0].sequence != first_sequence
        or active_receipts[-1].sequence != last_sequence
    ):
        fail("manifest receipt bounds differ from the consumed companion receipts")
    if active_receipts[0].sequence < int(first_published.fields["sequence"]):
        fail("companion consumed a sequence older than the first published frame")

    final_lease = event_between(
        events,
        name="lease_count_changed",
        after=stop_request,
        before=completed,
        fields={"previous": "1", "current": "0", "epoch": str(epoch)},
    )
    stop_requested = event_between(
        events,
        name="capture_stop_requested",
        after=final_lease.timestamp,
        before=completed,
        fields={"generation": str(capture_generation), "epoch": str(epoch)},
    )
    stopped = event_between(
        events,
        name="capture_stopped",
        after=stop_requested.timestamp,
        before=completed,
        fields={"generation": str(capture_generation), "epoch": str(epoch)},
    )
    if stopped.timestamp - final_lease.timestamp > 2.0:
        fail("capture stop exceeded two seconds after the final lease")
    if led_off < final_lease.timestamp or led_off - final_lease.timestamp > 2.0:
        fail("visible camera indicator did not turn off within two seconds")
    if any(
        event.timestamp > stopped.timestamp
        and event.name
        in (
            "lease_count_changed",
            "capture_start_requested",
            "capture_started",
            "first_frame_published",
            "capture_stop_requested",
            "capture_stopped",
        )
        for event in events
    ):
        fail("a camera lifecycle event occurred after final teardown")
    if any(receipt.timestamp > final_lease.timestamp for receipt in receipts):
        fail("the companion consumed a frame after final lease teardown")


def main(argv: Sequence[str]) -> int:
    if len(argv) != 2:
        print(f"Usage: {argv[0]} /absolute/path/to/c5-evidence-manifest.txt", file=sys.stderr)
        return 64
    try:
        verify(Path(argv[1]))
    except (EvidenceFailure, gate_a.EvidenceFailure, OSError, UnicodeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: C5 evidence proves fresh A0 attribution, separate explicit preview demand, "
        "one exact helper capture owner, advancing companion-consumed receipts, and "
        "bounded zero-lease/LED-off teardown."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
