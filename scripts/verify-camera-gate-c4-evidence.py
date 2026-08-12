#!/usr/bin/python3

"""Verify one complete, retained C4 A1T-then-A1TR evidence bundle.

This verifier is deliberately offline.  It replays hash-bound evidence captured by
the separately authorized physical runner; it never installs, registers, launches,
activates, or terminates anything itself.
"""

from __future__ import annotations

import hashlib
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import verify_camera_gate_a1_log as a1


class EvidenceFailure(Exception):
    pass


TEAM = "3524374A2S"
APP_GROUP = "group.com.idlescreen.shared"
MACH_SERVICE = "group.com.idlescreen.shared.camera-agent"
APP_ID = "com.idlescreen.app"
HELPER_ID = "com.idlescreen.camera-agent"
EXTENSION_ID = "com.idlescreen.app.screensaver"
INSTALLED_APP = "/Applications/idlescreen.app"
HELPER_BUNDLE = (
    f"{INSTALLED_APP}/Contents/Helpers/IdleScreenCameraAgent.app"
)
HELPER_EXECUTABLE = f"{HELPER_BUNDLE}/Contents/MacOS/IdleScreenCameraAgent"
EXTENSION_BUNDLE = (
    f"{INSTALLED_APP}/Contents/PlugIns/IdleScreenScreenSaver.appex"
)
EXTENSION_EXECUTABLE = (
    f"{EXTENSION_BUNDLE}/Contents/MacOS/IdleScreenScreenSaver"
)

SHA256 = re.compile(r"[0-9a-f]{64}")
CDHASH = re.compile(r"[0-9a-fA-F]{40}")
TRANSACTION_ID = re.compile(r"[A-Za-z0-9._-]{1,128}")

TOP_FIELDS = (
    "format",
    "evidence_semantics",
    "trusted_for_production",
    "c3_provenance_manifest",
    "c3_provenance_manifest_sha256",
    "c3_archive_tree_sha256",
    "gate_binding_manifest",
    "gate_binding_manifest_sha256",
    "synthetic_gate_manifest",
    "synthetic_gate_manifest_sha256",
    "production_install_manifest",
    "production_install_manifest_sha256",
    "production_candidate_tree_inventory",
    "production_candidate_tree_inventory_sha256",
    "production_installed_tree_inventory",
    "production_installed_tree_inventory_sha256",
    "a1t_evidence_manifest",
    "a1t_evidence_manifest_sha256",
    "a1t_transaction_manifest",
    "a1t_transaction_manifest_sha256",
    "a1tr_evidence_manifest",
    "a1tr_evidence_manifest_sha256",
    "a1tr_transaction_manifest",
    "a1tr_transaction_manifest_sha256",
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

BINDING_FIELDS = (
    "schema",
    "verification_mode",
    "c3_archive_tree_sha256",
    "c3_provenance_manifest_sha256",
    "c3_product_tree_sha256",
    "c3_app_cdhash",
    "c3_helper_cdhash",
    "c3_extension_cdhash",
    "gate_manifest_sha256",
    "gate_app_cdhash",
    "gate_helper_cdhash",
    "gate_extension_cdhash",
)

INSTALL_FIELDS = (
    "schema",
    "verification_mode",
    "c3_archive_tree_sha256",
    "c3_provenance_manifest_sha256",
    "app_cdhash",
    "helper_cdhash",
    "extension_cdhash",
    "candidate_tree_sha256",
    "installed_tree_sha256",
    "prior_backup_tree_sha256",
    "initial_registration",
    "final_registration",
    "camera_tcc_action",
)

TRANSACTION_FIELDS = (
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

JOURNAL_FIELDS = (
    "format",
    "phase",
    "transaction_id",
    "production_app_cdhash",
    "production_helper_cdhash",
    "production_extension_cdhash",
    "synthetic_app_cdhash",
    "synthetic_helper_cdhash",
    "synthetic_extension_cdhash",
    "installed_app_path",
    "production_helper_path",
    "production_extension_path",
    "gate_candidate_path",
    "synthetic_helper_path",
    "synthetic_extension_path",
    "manifest_sha256",
    "pre_state_sha256",
    "quiescence_inventory_sha256",
    "gate_bound_state_sha256",
    "post_restore_state_sha256",
)

SNAPSHOT_FIELDS = (
    "format",
    "service_status",
    "launchd_registration",
    "helper_runtime",
    "helper_path",
    "helper_cdhash",
    "pluginkit_paths",
    "selected_path",
    "extension_cdhash",
)

QUIESCENCE_FIELDS = (
    "format",
    "sample_count",
    "sample_1_pid_paths",
    "sample_2_pid_paths",
    "sample_3_pid_paths",
)

RUNTIME_ENTITLEMENT_FIELDS = (
    "format",
    "captured_at_utc",
    "source",
    "entitlements_validated",
    "pid",
    "path",
    "cdhash",
    "team_identifier",
    "application_identifier",
    "app_group",
    "app_sandbox",
    "camera",
    "get_task_allow",
    "disable_library_validation",
    "mach_lookup",
)

PROCESS_INVENTORY_FIELDS = (
    "format",
    "captured_at_utc",
    "helper_path",
    "helper_cdhash",
    "helper_pids",
    "extension_path",
    "extension_cdhash",
    "extension_pids",
)

INSTALLED_IDENTITY_FIELDS = (
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

TRANSITION_NAMES = (
    "pre_state_captured",
    "production_registration_retired",
    "quiescence_proven",
    "production_bytes_backed_up",
    "gate_installed",
    "gate_registration_rebound",
    "runner_started",
    "runner_completed",
    "gate_registration_retired",
    "marker_processes_absent",
    "production_bytes_restored",
    "production_registration_rebound",
    "post_restore_state_captured",
)
TRANSITION_FIELDS = (
    "format",
    "transaction_id",
    *(f"event_{index:02d}" for index in range(1, len(TRANSITION_NAMES) + 1)),
)


def fail(message: str) -> None:
    raise EvidenceFailure(message)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_kv(
    path: Path,
    fields: Sequence[str],
    label: str,
    allow_empty: Sequence[str] = (),
) -> Dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        fail(f"could not read {label}: {error}")
    values: Dict[str, str] = {}
    for line_number, line in enumerate(lines, 1):
        if "=" not in line or any(ord(character) < 0x20 for character in line):
            fail(f"malformed {label} line {line_number}")
        key, value = line.split("=", 1)
        if key not in fields or key in values or (not value and key not in allow_empty):
            fail(f"unexpected, empty, or duplicate {label} field {key!r}")
        values[key] = value
    if tuple(values) != tuple(fields):
        fail(f"{label} fields are missing or out of order")
    return values


def require_sha(value: str, label: str) -> str:
    if SHA256.fullmatch(value) is None:
        fail(f"{label} is not a lowercase SHA-256")
    return value


def require_cdhash(value: str, label: str) -> str:
    if CDHASH.fullmatch(value) is None:
        fail(f"{label} is not a CDHash")
    return value.lower()


def normalize_cdhash_fields(
    values: Dict[str, str], fields: Iterable[str], label: str
) -> None:
    for key in fields:
        values[key] = require_cdhash(values[key], f"{label} {key}")


def require_descendant(root: Path, recorded: str, digest: str, label: str) -> Path:
    path = Path(recorded)
    require_sha(digest, f"{label} SHA-256")
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        fail(f"{label} is not an absolute regular evidence file")
    try:
        path.resolve().relative_to(root)
    except ValueError:
        fail(f"{label} escapes the C4 evidence root")
    if sha256_file(path) != digest:
        fail(f"{label} differs from its recorded SHA-256")
    return path


def parse_timestamp(value: str, label: str) -> float:
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        fail(f"{label} is not a UTC timestamp with fractional seconds")
    return parsed.timestamp()


def require_equal(values: Dict[str, str], expected: Dict[str, str], label: str) -> None:
    for key, value in expected.items():
        if values.get(key) != value:
            fail(f"{label} {key} must equal {value!r}")


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
            "extension_bundle_identifier": EXTENSION_ID,
            "helper_bundle_identifier": HELPER_ID,
        },
        "C3 provenance manifest",
    )
    for key, value in values.items():
        if key.endswith("_sha256"):
            require_sha(value, f"C3 {key}")
        if key.endswith("_cdhash"):
            values[key] = require_cdhash(value, f"C3 {key}")
    for key in ("app_profile_uuid", "extension_profile_uuid", "helper_profile_uuid"):
        if re.fullmatch(r"[0-9A-Fa-f-]{36}", values[key]) is None:
            fail(f"C3 {key} is malformed")
    for key in (
        "app_profile_expiration",
        "extension_profile_expiration",
        "helper_profile_expiration",
    ):
        try:
            datetime.fromisoformat(values[key].replace("Z", "+00:00"))
        except ValueError:
            fail(f"C3 {key} is malformed")
    return values


def validate_synthetic_gate(path: Path, c3: Dict[str, str]) -> Dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        fail(f"could not read synthetic gate manifest: {error}")
    expected_keys = (
        "format",
        "unchangedInventorySHA256",
        "outerExecutableUnsignedSHA256",
        "outerIdentifier",
        "outerTeamIdentifier",
        "outerCodeDirectoryFlags",
        "productionExtensionPath",
        "productionExtensionTreeSHA256",
        "syntheticExtensionTreeSHA256",
        "productionLaunchAgentsPath",
        "productionLaunchAgentsTreeSHA256",
        "productionHelperCDHash",
        "syntheticHelperCDHash",
        "productionExtensionCDHash",
        "syntheticExtensionCDHash",
        "allowedSubstitution",
        "allowedSubstitution",
        "allowedSignatureEnvelope",
        "allowedSubstitution",
    )
    pairs: List[Tuple[str, str]] = []
    for line_number, line in enumerate(lines, 1):
        if "=" not in line:
            fail(f"malformed synthetic gate manifest line {line_number}")
        key, value = line.split("=", 1)
        if not value:
            fail(f"empty synthetic gate manifest field {key!r}")
        pairs.append((key, value))
    if tuple(key for key, _ in pairs) != expected_keys:
        fail("synthetic gate manifest fields are missing or out of order")
    values = dict(pairs[:15])
    normalize_cdhash_fields(
        values,
        (
            "productionHelperCDHash",
            "syntheticHelperCDHash",
            "productionExtensionCDHash",
            "syntheticExtensionCDHash",
        ),
        "synthetic gate",
    )
    require_equal(
        values,
        {
            "format": "IdleScreenSyntheticGateManifestV1",
            "outerIdentifier": APP_ID,
            "outerTeamIdentifier": TEAM,
            "productionExtensionPath": "Contents/PlugIns/IdleScreenScreenSaver.appex",
            "productionLaunchAgentsPath": "Contents/Library/LaunchAgents",
            "productionHelperCDHash": c3["helper_cdhash"],
            "productionExtensionCDHash": c3["extension_cdhash"],
        },
        "synthetic gate manifest",
    )
    if "runtime" not in values["outerCodeDirectoryFlags"]:
        fail("synthetic gate outer CodeDirectory flags do not retain hardened runtime")
    for key in (
        "unchangedInventorySHA256",
        "outerExecutableUnsignedSHA256",
        "productionExtensionTreeSHA256",
        "syntheticExtensionTreeSHA256",
        "productionLaunchAgentsTreeSHA256",
    ):
        require_sha(values[key], f"synthetic gate {key}")
    if values["productionHelperCDHash"].lower() == values["syntheticHelperCDHash"].lower():
        fail("synthetic helper does not have a distinct CDHash")
    if values["productionExtensionCDHash"].lower() == values["syntheticExtensionCDHash"].lower():
        fail("synthetic extension does not have a distinct CDHash")
    if tuple(pairs[15:]) != (
        ("allowedSubstitution", "Contents/Helpers/IdleScreenCameraAgent.app/"),
        ("allowedSubstitution", "Contents/PlugIns/IdleScreenScreenSaver.appex/"),
        ("allowedSignatureEnvelope", "Contents/MacOS/IdleScreen"),
        ("allowedSubstitution", "Contents/_CodeSignature/CodeResources"),
    ):
        fail("synthetic gate substitution allowlist is not exact")
    return values


def validate_binding(
    path: Path,
    c3: Dict[str, str],
    c3_digest: str,
    gate: Dict[str, str],
    gate_digest: str,
) -> Dict[str, str]:
    values = parse_kv(path, BINDING_FIELDS, "gate binding manifest")
    normalize_cdhash_fields(
        values,
        (
            "c3_app_cdhash",
            "c3_helper_cdhash",
            "c3_extension_cdhash",
            "gate_app_cdhash",
            "gate_helper_cdhash",
            "gate_extension_cdhash",
        ),
        "gate binding",
    )
    require_equal(
        values,
        {
            "schema": "IdleScreenC4GateBinding/v1",
            "verification_mode": "release",
            "c3_archive_tree_sha256": c3["archive_tree_sha256"],
            "c3_provenance_manifest_sha256": c3_digest,
            "c3_app_cdhash": c3["app_cdhash"],
            "c3_helper_cdhash": c3["helper_cdhash"],
            "c3_extension_cdhash": c3["extension_cdhash"],
            "gate_manifest_sha256": gate_digest,
            "gate_helper_cdhash": gate["syntheticHelperCDHash"],
            "gate_extension_cdhash": gate["syntheticExtensionCDHash"],
        },
        "gate binding manifest",
    )
    for key in values:
        if key.endswith("_sha256"):
            require_sha(values[key], f"gate binding {key}")
    if values["gate_app_cdhash"].lower() == values["c3_app_cdhash"].lower():
        fail("synthetic outer app does not have a distinct CDHash")
    return values


def validate_install(
    path: Path,
    candidate_inventory: Path,
    installed_inventory: Path,
    c3: Dict[str, str],
    c3_digest: str,
) -> Dict[str, str]:
    values = parse_kv(path, INSTALL_FIELDS, "C4 production install manifest")
    normalize_cdhash_fields(
        values, ("app_cdhash", "helper_cdhash", "extension_cdhash"), "C4 production install"
    )
    require_equal(
        values,
        {
            "schema": "IdleScreenC4ProductionInstall/v1",
            "verification_mode": "release",
            "c3_archive_tree_sha256": c3["archive_tree_sha256"],
            "c3_provenance_manifest_sha256": c3_digest,
            "app_cdhash": c3["app_cdhash"],
            "helper_cdhash": c3["helper_cdhash"],
            "extension_cdhash": c3["extension_cdhash"],
            "candidate_tree_sha256": sha256_file(candidate_inventory),
            "installed_tree_sha256": sha256_file(installed_inventory),
            "initial_registration": "unbound",
            "final_registration": "unbound",
            "camera_tcc_action": "none",
        },
        "C4 production install manifest",
    )
    for key in ("candidate_tree_sha256", "installed_tree_sha256", "prior_backup_tree_sha256"):
        require_sha(values[key], f"C4 production install {key}")
    if candidate_inventory.read_bytes() != installed_inventory.read_bytes():
        fail("installed production tree inventory differs from the exact C3 candidate")
    return values


def validate_snapshot(
    path: Path,
    label: str,
    helper_cdhash: str,
    extension_cdhash: str,
    gate_bound: bool,
) -> Dict[str, str]:
    values = parse_kv(
        path,
        SNAPSHOT_FIELDS,
        label,
        allow_empty=("pluginkit_paths", "selected_path"),
    )
    normalize_cdhash_fields(values, ("helper_cdhash", "extension_cdhash"), label)
    if gate_bound:
        state_values = {
            "service_status": "enabled",
            "launchd_registration": "loaded",
            "helper_runtime": "absent",
            "pluginkit_paths": EXTENSION_BUNDLE,
            "selected_path": EXTENSION_BUNDLE,
        }
    else:
        state_values = {
            "service_status": "notRegistered",
            "launchd_registration": "unbound",
            "helper_runtime": "absent",
            "pluginkit_paths": "",
            "selected_path": "",
        }
    require_equal(
        values,
        {
            "format": "1",
            "helper_path": HELPER_EXECUTABLE,
            "helper_cdhash": helper_cdhash,
            "extension_cdhash": extension_cdhash,
            **state_values,
        },
        label,
    )
    return values


def validate_quiescence(path: Path) -> None:
    empty_samples = (
        "sample_1_pid_paths",
        "sample_2_pid_paths",
        "sample_3_pid_paths",
    )
    values = parse_kv(
        path,
        QUIESCENCE_FIELDS,
        "quiescence inventory",
        allow_empty=empty_samples,
    )
    require_equal(
        values,
        {
            "format": "1",
            "sample_count": "3",
            "sample_1_pid_paths": "",
            "sample_2_pid_paths": "",
            "sample_3_pid_paths": "",
        },
        "quiescence inventory",
    )


def validate_runtime_entitlements(
    path: Path,
    label: str,
    pid: str,
    component: str,
    cdhash: str,
    started: float,
    marker_absent: float,
) -> None:
    values = parse_kv(path, RUNTIME_ENTITLEMENT_FIELDS, label)
    normalize_cdhash_fields(values, ("cdhash",), label)
    if component == "helper":
        component_values = {
            "path": HELPER_EXECUTABLE,
            "application_identifier": f"{TEAM}.{HELPER_ID}",
            "disable_library_validation": "false",
            "mach_lookup": "none",
        }
    else:
        component_values = {
            "path": EXTENSION_EXECUTABLE,
            "application_identifier": f"{TEAM}.{EXTENSION_ID}",
            "disable_library_validation": "true",
            "mach_lookup": (
                "com.apple.CARenderServer,com.apple.CoreDisplay.master,"
                "com.apple.ViewBridgeAuxiliary"
            ),
        }
    require_equal(
        values,
        {
            "format": "IdleScreenCameraGateC4RuntimeEntitlementsV1",
            "source": "launchctl-procinfo",
            "entitlements_validated": "true",
            "pid": pid,
            "cdhash": cdhash,
            "team_identifier": TEAM,
            "app_group": APP_GROUP,
            "app_sandbox": "true",
            "camera": "false",
            "get_task_allow": "false",
            **component_values,
        },
        label,
    )
    captured = parse_timestamp(values["captured_at_utc"], f"{label} capture time")
    if not started <= captured <= marker_absent:
        fail(f"{label} was captured outside its transaction")


def validate_transitions(
    path: Path,
    transaction_id: str,
    started: float,
    marker_absent: float,
    restored: float,
    completed: float,
) -> None:
    values = parse_kv(path, TRANSITION_FIELDS, "transaction transitions")
    require_equal(
        values,
        {
            "format": "IdleScreenCameraGateC4TransitionsV1",
            "transaction_id": transaction_id,
        },
        "transaction transitions",
    )
    times: List[float] = []
    for index, expected_name in enumerate(TRANSITION_NAMES, 1):
        value = values[f"event_{index:02d}"]
        name, separator, timestamp = value.partition("@")
        if separator != "@" or name != expected_name:
            fail(f"transaction transition {index} is not {expected_name}")
        times.append(parse_timestamp(timestamp, f"transaction transition {index}"))
    if times != sorted(times) or times[0] < started or times[-1] > completed:
        fail("transaction transitions are not ordered within the transaction")
    if times[9] != marker_absent or times[10] != restored:
        fail("transaction transitions do not bind marker absence and restoration times")


def validate_transaction(
    root: Path,
    mode: str,
    path: Path,
    expected_a1_manifest: Path,
    expected_a1_digest: str,
    c3: Dict[str, str],
    c3_digest: str,
    binding: Dict[str, str],
    binding_digest: str,
    gate_digest: str,
    production_tree_inventory: Path,
) -> Tuple[float, float, str]:
    values = parse_kv(path, TRANSACTION_FIELDS, f"{mode} transaction manifest")
    require_equal(
        values,
        {
            "format": "IdleScreenCameraGateC4TransactionV1",
            "mode": mode,
            "c3_archive_tree_sha256": c3["archive_tree_sha256"],
            "c3_provenance_manifest_sha256": c3_digest,
            "gate_binding_manifest_sha256": binding_digest,
            "synthetic_gate_manifest_sha256": gate_digest,
            "a1_evidence_manifest": str(expected_a1_manifest),
            "a1_evidence_manifest_sha256": expected_a1_digest,
        },
        f"{mode} transaction manifest",
    )
    started = parse_timestamp(values["started_at_utc"], f"{mode} start")
    marker_absent = parse_timestamp(
        values["marker_processes_absent_at_utc"], f"{mode} marker absence"
    )
    restored = parse_timestamp(values["production_restored_at_utc"], f"{mode} restoration")
    completed = parse_timestamp(values["completed_at_utc"], f"{mode} completion")
    if not started < marker_absent <= restored <= completed:
        fail(f"{mode} transaction timestamps are not ordered")

    referenced: Dict[str, Path] = {}
    for key in (
        "transaction_journal",
        "transaction_transitions",
        "pre_state",
        "quiescence_inventory",
        "gate_bound_state",
        "post_restore_state",
        "marker_process_inventory",
        "installed_production_identity",
        "restored_production_tree_inventory",
        "initial_helper_runtime_entitlements",
        "saver_runtime_entitlements",
    ):
        referenced[key] = require_descendant(
            root, values[key], values[f"{key}_sha256"], f"{mode} {key}"
        )
    if mode == "a1tr":
        referenced["recovered_helper_runtime_entitlements"] = require_descendant(
            root,
            values["recovered_helper_runtime_entitlements"],
            values["recovered_helper_runtime_entitlements_sha256"],
            f"{mode} recovered helper runtime entitlements",
        )
    elif (
        values["recovered_helper_runtime_entitlements"] != "none"
        or values["recovered_helper_runtime_entitlements_sha256"] != "none"
    ):
        fail("A1T unexpectedly names recovered-helper runtime entitlements")

    journal = parse_kv(referenced["transaction_journal"], JOURNAL_FIELDS, f"{mode} journal")
    normalize_cdhash_fields(
        journal,
        (
            "production_app_cdhash",
            "production_helper_cdhash",
            "production_extension_cdhash",
            "synthetic_app_cdhash",
            "synthetic_helper_cdhash",
            "synthetic_extension_cdhash",
        ),
        f"{mode} journal",
    )
    if TRANSACTION_ID.fullmatch(journal["transaction_id"]) is None:
        fail(f"{mode} journal transaction ID is malformed")
    require_equal(
        journal,
        {
            "format": "4",
            "phase": "production_rebound",
            "production_app_cdhash": c3["app_cdhash"],
            "production_helper_cdhash": c3["helper_cdhash"],
            "production_extension_cdhash": c3["extension_cdhash"],
            "synthetic_app_cdhash": binding["gate_app_cdhash"],
            "synthetic_helper_cdhash": binding["gate_helper_cdhash"],
            "synthetic_extension_cdhash": binding["gate_extension_cdhash"],
            "installed_app_path": INSTALLED_APP,
            "production_helper_path": HELPER_BUNDLE,
            "production_extension_path": EXTENSION_BUNDLE,
            "manifest_sha256": gate_digest,
            "pre_state_sha256": values["pre_state_sha256"],
            "quiescence_inventory_sha256": values["quiescence_inventory_sha256"],
            "gate_bound_state_sha256": values["gate_bound_state_sha256"],
            "post_restore_state_sha256": values["post_restore_state_sha256"],
        },
        f"{mode} journal",
    )
    for key in ("gate_candidate_path", "synthetic_helper_path", "synthetic_extension_path"):
        if not journal[key].startswith("/") or journal[key] in (
            INSTALLED_APP,
            HELPER_BUNDLE,
            EXTENSION_BUNDLE,
        ):
            fail(f"{mode} journal {key} is not a distinct absolute gate path")

    pre = validate_snapshot(
        referenced["pre_state"],
        f"{mode} pre-state",
        c3["helper_cdhash"],
        c3["extension_cdhash"],
        False,
    )
    post = validate_snapshot(
        referenced["post_restore_state"],
        f"{mode} post-restore state",
        c3["helper_cdhash"],
        c3["extension_cdhash"],
        False,
    )
    if referenced["pre_state"].read_bytes() != referenced["post_restore_state"].read_bytes():
        fail(f"{mode} production registration/selection was not restored byte-exactly")
    if pre != post:
        fail(f"{mode} production state changed during restoration")
    validate_snapshot(
        referenced["gate_bound_state"],
        f"{mode} gate-bound state",
        binding["gate_helper_cdhash"],
        binding["gate_extension_cdhash"],
        True,
    )
    validate_quiescence(referenced["quiescence_inventory"])

    transitions = referenced["transaction_transitions"]
    validate_transitions(
        transitions, journal["transaction_id"], started, marker_absent, restored, completed
    )

    process_inventory = parse_kv(
        referenced["marker_process_inventory"],
        PROCESS_INVENTORY_FIELDS,
        f"{mode} marker process inventory",
    )
    normalize_cdhash_fields(
        process_inventory, ("helper_cdhash", "extension_cdhash"), f"{mode} process inventory"
    )
    require_equal(
        process_inventory,
        {
            "format": "IdleScreenCameraGateC4ProcessInventoryV1",
            "captured_at_utc": values["marker_processes_absent_at_utc"],
            "helper_path": HELPER_EXECUTABLE,
            "helper_cdhash": binding["gate_helper_cdhash"],
            "helper_pids": "none",
            "extension_path": EXTENSION_EXECUTABLE,
            "extension_cdhash": binding["gate_extension_cdhash"],
            "extension_pids": "none",
        },
        f"{mode} marker process inventory",
    )

    installed = parse_kv(
        referenced["installed_production_identity"],
        INSTALLED_IDENTITY_FIELDS,
        f"{mode} installed production identity",
    )
    normalize_cdhash_fields(
        installed,
        ("app_cdhash", "helper_cdhash", "extension_cdhash"),
        f"{mode} installed production identity",
    )
    if (
        referenced["restored_production_tree_inventory"].read_bytes()
        != production_tree_inventory.read_bytes()
    ):
        fail(f"{mode} restored production tree differs from the exact installed C3 tree")
    require_equal(
        installed,
        {
            "format": "IdleScreenCameraGateC4InstalledIdentityV1",
            "captured_at_utc": values["production_restored_at_utc"],
            "app_path": INSTALLED_APP,
            "app_cdhash": c3["app_cdhash"],
            "helper_path": HELPER_EXECUTABLE,
            "helper_cdhash": c3["helper_cdhash"],
            "extension_path": EXTENSION_EXECUTABLE,
            "extension_cdhash": c3["extension_cdhash"],
            "deep_signature": "valid",
            "helper_marker": "absent",
            "extension_marker": "absent",
        },
        f"{mode} installed production identity",
    )

    row_values = parse_kv(expected_a1_manifest, a1.MANIFEST_FIELDS, f"{mode} A1 evidence manifest")
    normalize_cdhash_fields(
        row_values, ("helper_cdhash", "extension_cdhash"), f"{mode} A1 evidence manifest"
    )
    require_equal(
        row_values,
        {
            "mode": mode,
            "helper_path": HELPER_EXECUTABLE,
            "helper_cdhash": binding["gate_helper_cdhash"],
            "extension_path": EXTENSION_EXECUTABLE,
            "extension_cdhash": binding["gate_extension_cdhash"],
        },
        f"{mode} A1 evidence manifest",
    )
    log_path = Path(row_values["log_path"])
    try:
        a1.verify(mode, log_path, expected_a1_manifest)
    except a1.EvidenceFailure as error:
        fail(f"{mode} lifecycle evidence failed: {error}")
    for prefix, identifier, expected_cdhash in (
        ("helper", HELPER_ID, binding["gate_helper_cdhash"]),
        ("extension", EXTENSION_ID, binding["gate_extension_cdhash"]),
    ):
        codesign_path = Path(row_values[f"{prefix}_codesign_output"])
        codesign_text = codesign_path.read_text(encoding="utf-8")
        if (
            f"Identifier={identifier}\n" not in codesign_text
            or f"TeamIdentifier={TEAM}\n" not in codesign_text
            or not any(
                line.startswith("CDHash=")
                and line[len("CDHash=") :].lower() == expected_cdhash
                for line in codesign_text.splitlines()
            )
        ):
            fail(f"{mode} {prefix} signed identity does not retain the exact C4 tuple")
    events, receipts, markers, preflights, animations = a1.parse(
        log_path.read_text(encoding="utf-8").splitlines()
    )
    observed_times = [item.timestamp for group in (events, receipts, markers, preflights, animations) for item in group]
    if not observed_times or min(observed_times) < started or max(observed_times) > marker_absent:
        fail(f"{mode} lifecycle log falls outside its transaction")

    validate_runtime_entitlements(
        referenced["initial_helper_runtime_entitlements"],
        f"{mode} initial helper runtime entitlements",
        row_values["initial_helper_pid"],
        "helper",
        binding["gate_helper_cdhash"],
        started,
        marker_absent,
    )
    validate_runtime_entitlements(
        referenced["saver_runtime_entitlements"],
        f"{mode} saver runtime entitlements",
        row_values["saver_pid"],
        "extension",
        binding["gate_extension_cdhash"],
        started,
        marker_absent,
    )
    if mode == "a1tr":
        validate_runtime_entitlements(
            referenced["recovered_helper_runtime_entitlements"],
            "a1tr recovered helper runtime entitlements",
            row_values["recovered_helper_pid"],
            "helper",
            binding["gate_helper_cdhash"],
            started,
            marker_absent,
        )
    return started, completed, journal["transaction_id"]


def verify(manifest_path: Path) -> None:
    if not manifest_path.is_absolute() or manifest_path.is_symlink() or not manifest_path.is_file():
        fail("C4 evidence manifest must be an absolute regular file")
    root = manifest_path.parent.resolve()
    top = parse_kv(manifest_path, TOP_FIELDS, "C4 evidence manifest")
    require_equal(
        top,
        {
            "format": "IdleScreenCameraGateC4EvidenceV1",
            "evidence_semantics": "topology-equivalent-camera-free",
            "trusted_for_production": "false",
        },
        "C4 evidence manifest",
    )

    c3_path = require_descendant(
        root,
        top["c3_provenance_manifest"],
        top["c3_provenance_manifest_sha256"],
        "C3 provenance manifest",
    )
    c3 = validate_c3(c3_path)
    if top["c3_archive_tree_sha256"] != c3["archive_tree_sha256"]:
        fail("C4 evidence does not bind the exact C3 archive tree")

    gate_path = require_descendant(
        root,
        top["synthetic_gate_manifest"],
        top["synthetic_gate_manifest_sha256"],
        "synthetic gate manifest",
    )
    gate = validate_synthetic_gate(gate_path, c3)
    binding_path = require_descendant(
        root,
        top["gate_binding_manifest"],
        top["gate_binding_manifest_sha256"],
        "gate binding manifest",
    )
    binding = validate_binding(
        binding_path,
        c3,
        top["c3_provenance_manifest_sha256"],
        gate,
        top["synthetic_gate_manifest_sha256"],
    )
    candidate_inventory = require_descendant(
        root,
        top["production_candidate_tree_inventory"],
        top["production_candidate_tree_inventory_sha256"],
        "C4 production candidate tree inventory",
    )
    installed_inventory = require_descendant(
        root,
        top["production_installed_tree_inventory"],
        top["production_installed_tree_inventory_sha256"],
        "C4 production installed tree inventory",
    )
    install_path = require_descendant(
        root,
        top["production_install_manifest"],
        top["production_install_manifest_sha256"],
        "C4 production install manifest",
    )
    validate_install(
        install_path,
        candidate_inventory,
        installed_inventory,
        c3,
        top["c3_provenance_manifest_sha256"],
    )
    if binding["c3_product_tree_sha256"] != sha256_file(candidate_inventory):
        fail("C4 install inventory is not the exact C3 archive product inventory")

    row_results: Dict[str, Tuple[float, float, str]] = {}
    for mode in ("a1t", "a1tr"):
        evidence_key = f"{mode}_evidence_manifest"
        transaction_key = f"{mode}_transaction_manifest"
        evidence_path = require_descendant(
            root,
            top[evidence_key],
            top[f"{evidence_key}_sha256"],
            f"{mode} A1 evidence manifest",
        )
        transaction_path = require_descendant(
            root,
            top[transaction_key],
            top[f"{transaction_key}_sha256"],
            f"{mode} transaction manifest",
        )
        row_results[mode] = validate_transaction(
            root,
            mode,
            transaction_path,
            evidence_path,
            top[f"{evidence_key}_sha256"],
            c3,
            top["c3_provenance_manifest_sha256"],
            binding,
            top["gate_binding_manifest_sha256"],
            top["synthetic_gate_manifest_sha256"],
            installed_inventory,
        )
    if row_results["a1t"][1] > row_results["a1tr"][0]:
        fail("C4 evidence did not complete A1T before starting A1TR")
    if row_results["a1t"][2] == row_results["a1tr"][2]:
        fail("C4 evidence reused one transaction identity for A1T and A1TR")


def main(argv: Sequence[str]) -> int:
    if len(argv) != 2:
        print(f"Usage: {argv[0]} /absolute/path/to/c4-evidence-manifest.txt", file=sys.stderr)
        return 64
    try:
        verify(Path(argv[1]))
    except (EvidenceFailure, OSError, UnicodeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: C4 evidence binds C3 provenance to camera-free A1T then A1TR and exact production restoration.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
