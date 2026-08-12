#!/usr/bin/python3

"""Build deterministic C4 evidence fixtures and exercise false-pass mutations."""

from __future__ import annotations

import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple


PROJECT_ROOT = Path(__file__).resolve().parents[1]
VERIFIER = PROJECT_ROOT / "scripts/verify-camera-gate-c4-evidence.py"
TEAM = "3524374A2S"
APP_GROUP = "group.com.idlescreen.shared"
APP = "/Applications/idlescreen.app"
HELPER_BUNDLE = f"{APP}/Contents/Helpers/IdleScreenCameraAgent.app"
HELPER = f"{HELPER_BUNDLE}/Contents/MacOS/IdleScreenCameraAgent"
HELPER_MARKER = f"{HELPER_BUNDLE}/Contents/Info.plist"
EXTENSION_BUNDLE = f"{APP}/Contents/PlugIns/IdleScreenScreenSaver.appex"
EXTENSION = f"{EXTENSION_BUNDLE}/Contents/MacOS/IdleScreenScreenSaver"
EXTENSION_MARKER = f"{EXTENSION_BUNDLE}/Contents/Info.plist"
PRODUCTION_APP_HASH = "a" * 40
PRODUCTION_HELPER_HASH = "b" * 40
PRODUCTION_EXTENSION_HASH = "c" * 40
GATE_APP_HASH = "d" * 40
GATE_HELPER_HASH = "1" * 40
GATE_EXTENSION_HASH = "2" * 40
ARCHIVE_HASH = "0" * 64


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def write_kv(path: Path, pairs: Iterable[Tuple[str, str]]) -> Path:
    return write(path, "".join(f"{key}={value}\n" for key, value in pairs))


def read_kv(path: Path) -> Dict[str, str]:
    return dict(line.split("=", 1) for line in path.read_text(encoding="utf-8").splitlines())


def replace_field(path: Path, key: str, value: str) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    matches = 0
    result: List[str] = []
    for line in lines:
        current, separator, _ = line.partition("=")
        if separator and current == key:
            result.append(f"{key}={value}")
            matches += 1
        else:
            result.append(line)
    if matches != 1:
        raise AssertionError(f"fixture field {key} appeared {matches} times in {path}")
    path.write_text("\n".join(result) + "\n", encoding="utf-8")


def log_lines(mode: str) -> str:
    time = "2026-08-01 12:00:00.000000-0400" if mode == "a1t" else "2026-08-01 12:01:00.000000-0400"

    def agent(pid: int, category: str, message: str) -> str:
        return f"{time} I IdleScreenCameraAgent[{pid}:abc] [com.idlescreen.camera-agent:{category}] {message}"

    def saver(namespace: str, message: str) -> str:
        return f"{time} I IdleScreenScreenSaver[501:def] [com.idlescreen.screensaver:{namespace}] {message}"

    def accepted(pid: int, connection: str) -> str:
        return agent(pid, "identity", f"peer_admission_accepted connection_id={connection} pid=501 team_id={TEAM} bundle_id=com.idlescreen.app.screensaver role=screen-saver")

    def invalidated(pid: int, connection: str) -> str:
        return agent(pid, "identity", f"connection_invalidated connection_id={connection} pid=501 team_id={TEAM} bundle_id=com.idlescreen.app.screensaver role=screen-saver")

    def start(pid: int, connection: str, epoch: int, generation: int) -> List[str]:
        return [
            accepted(pid, connection),
            agent(pid, "lifecycle", f"lease_count_changed previous=0 current=1 epoch={epoch}"),
            agent(pid, "lifecycle", f"capture_start_requested generation={generation} epoch={epoch}"),
            agent(pid, "lifecycle", f"capture_started generation={generation} epoch={epoch}"),
            agent(pid, "lifecycle", f"first_frame_published generation={generation} epoch={epoch} sequence=1"),
        ]

    def receipt(epoch: int, sequence: int) -> str:
        return saver("View", f"Camera receipt state=available epoch={epoch} sequence={sequence} instance=view-a display=1")

    def cleanup(pid: int, connection: str, epoch: int, generation: int) -> List[str]:
        return [
            invalidated(pid, connection),
            agent(pid, "lifecycle", f"lease_count_changed previous=1 current=0 epoch={epoch}"),
            agent(pid, "lifecycle", f"capture_stop_requested generation={generation} epoch={epoch}"),
            agent(pid, "lifecycle", f"capture_stopped generation={generation} epoch={epoch}"),
        ]

    lines = [
        accepted(101, "connection-preflight-A"),
        saver("SyntheticHostedGate", "Synthetic hosted gate preflight helper_pid=101 accepted=true active_lease_count=0 capture_active=false"),
        invalidated(101, "connection-preflight-A"),
        saver("SyntheticHostedGate", "Synthetic hosted gate loaded topology-equivalent=true trusted-for-production=false pid=501 instance=view-a preview=false"),
        saver("View", "Animation started preview=false instance=view-a display=1"),
        *start(101, "connection-A-1", 7001, 4),
        receipt(7001, 1),
        receipt(7001, 11),
        receipt(7001, 21),
    ]
    if mode == "a1tr":
        lines.extend(
            [
                saver("View", "Camera receipt state=fallback-unavailable instance=view-a display=1"),
                *start(202, "connection-B-1", 9001, 1),
                receipt(9001, 1),
                receipt(9001, 12),
                receipt(9001, 24),
                saver("View", "Animation stopped preview=false instance=view-a display=1"),
                *cleanup(202, "connection-B-1", 9001, 1),
            ]
        )
    else:
        lines.extend(
            [
                saver("View", "Animation stopped preview=false instance=view-a display=1"),
                *cleanup(101, "connection-A-1", 7001, 4),
                "operator-note screenshot=false",
            ]
        )
    return "\n".join(lines) + "\n"


def write_a1_row(root: Path, mode: str) -> Path:
    row = root / mode
    log = write(row / "combined.log", log_lines(mode))
    initial_procinfo = write(row / "initial-helper-procinfo-101.txt", "pid=101\nentitlements validated\n")
    saver_procinfo = write(row / "hosted-saver-procinfo-501.txt", "pid=501\nentitlements validated\n")
    helper_marker = write_kv(
        row / "helper-marker-extract.txt",
        (("marker_path", HELPER_MARKER), ("marker_key", "IdleScreenSyntheticGateVersion"), ("marker_value", "1")),
    )
    extension_marker = write_kv(
        row / "extension-marker-extract.txt",
        (("marker_path", EXTENSION_MARKER), ("marker_key", "IdleScreenSyntheticHostedGateVersion"), ("marker_value", "1")),
    )
    helper_codesign = write(row / "helper-codesign.txt", f"Identifier=com.idlescreen.camera-agent\nTeamIdentifier={TEAM}\nCDHash={GATE_HELPER_HASH}\n")
    extension_codesign = write(row / "extension-codesign.txt", f"Identifier=com.idlescreen.app.screensaver\nTeamIdentifier={TEAM}\nCDHash={GATE_EXTENSION_HASH}\n")
    configuration = write_kv(
        row / "configuration-preflight.txt",
        (
            ("format", "IdleScreenCameraGateConfigurationV1"),
            ("configuration_path", "/Users/fixture/Library/Group Containers/group.com.idlescreen.shared/configuration.json"),
            ("schema_version", "1"),
            ("source", "camera"),
            ("device", "1"),
            ("inode", "2"),
            ("size", "41"),
            ("mtime_ns", "1785600000000000000"),
            ("sha256", "3" * 64),
        ),
    )
    if mode == "a1tr":
        recovered_procinfo = write(row / "recovered-helper-procinfo-202.txt", "pid=202\nentitlements validated\n")
        recovered_values = (
            ("fault_termination_timestamp", "2026-08-01 12:01:00.000000-0400"),
            ("recovered_helper_pid", "202"),
            ("recovered_helper_identity", f"Sat Aug 1 12:01:01 2026 {HELPER}|{GATE_HELPER_HASH}"),
            ("recovered_helper_procinfo", str(recovered_procinfo)),
            ("recovered_helper_procinfo_sha256", sha(recovered_procinfo)),
        )
    else:
        recovered_values = (
            ("fault_termination_timestamp", "none"),
            ("recovered_helper_pid", "none"),
            ("recovered_helper_identity", "none"),
            ("recovered_helper_procinfo", "none"),
            ("recovered_helper_procinfo_sha256", "none"),
        )
    manifest = row / "evidence-manifest.txt"
    write_kv(
        manifest,
        (
            ("format", "IdleScreenCameraGateEvidenceV1"),
            ("mode", mode),
            ("evidence_semantics", "topology-equivalent-a1t"),
            ("trusted_for_production", "false"),
            ("log_path", str(log)),
            ("log_sha256", sha(log)),
            ("helper_marker_path", HELPER_MARKER),
            ("helper_marker_version", "1"),
            ("extension_marker_path", EXTENSION_MARKER),
            ("extension_marker_version", "1"),
            ("helper_marker_extract", str(helper_marker)),
            ("helper_marker_extract_sha256", sha(helper_marker)),
            ("extension_marker_extract", str(extension_marker)),
            ("extension_marker_extract_sha256", sha(extension_marker)),
            ("helper_path", HELPER),
            ("helper_cdhash", GATE_HELPER_HASH),
            ("extension_path", EXTENSION),
            ("extension_cdhash", GATE_EXTENSION_HASH),
            ("helper_codesign_output", str(helper_codesign)),
            ("helper_codesign_output_sha256", sha(helper_codesign)),
            ("extension_codesign_output", str(extension_codesign)),
            ("extension_codesign_output_sha256", sha(extension_codesign)),
            ("initial_helper_class", "absent-cold"),
            ("initial_helper_pid", "101"),
            ("initial_helper_identity", f"Sat Aug 1 12:00:00 2026 {HELPER}|{GATE_HELPER_HASH}"),
            ("initial_helper_procinfo", str(initial_procinfo)),
            ("initial_helper_procinfo_sha256", sha(initial_procinfo)),
            ("saver_pid", "501"),
            ("saver_identity", f"Sat Aug 1 12:00:00 2026 {EXTENSION}|{GATE_EXTENSION_HASH}"),
            ("saver_procinfo", str(saver_procinfo)),
            ("saver_procinfo_sha256", sha(saver_procinfo)),
            ("configuration_snapshot", str(configuration)),
            ("configuration_snapshot_sha256", sha(configuration)),
            *recovered_values,
        ),
    )
    return manifest


def runtime_entitlements(path: Path, timestamp: str, pid: int, component: str) -> Path:
    helper = component == "helper"
    return write_kv(
        path,
        (
            ("format", "IdleScreenCameraGateC4RuntimeEntitlementsV1"),
            ("captured_at_utc", timestamp),
            ("source", "launchctl-procinfo"),
            ("entitlements_validated", "true"),
            ("pid", str(pid)),
            ("path", HELPER if helper else EXTENSION),
            ("cdhash", GATE_HELPER_HASH if helper else GATE_EXTENSION_HASH),
            ("team_identifier", TEAM),
            ("application_identifier", f"{TEAM}.com.idlescreen.camera-agent" if helper else f"{TEAM}.com.idlescreen.app.screensaver"),
            ("app_group", APP_GROUP),
            ("app_sandbox", "true"),
            ("camera", "false"),
            ("get_task_allow", "false"),
            ("disable_library_validation", "false" if helper else "true"),
            ("mach_lookup", "none" if helper else "com.apple.CARenderServer,com.apple.CoreDisplay.master,com.apple.ViewBridgeAuxiliary"),
        ),
    )


def state(path: Path, gate: bool) -> Path:
    return write_kv(
        path,
        (
            ("format", "1"),
            ("service_status", "enabled" if gate else "notRegistered"),
            ("launchd_registration", "loaded" if gate else "unbound"),
            ("helper_runtime", "absent"),
            ("helper_path", HELPER),
            ("helper_cdhash", GATE_HELPER_HASH if gate else PRODUCTION_HELPER_HASH),
            ("pluginkit_paths", EXTENSION_BUNDLE if gate else ""),
            ("selected_path", EXTENSION_BUNDLE if gate else ""),
            ("extension_cdhash", GATE_EXTENSION_HASH if gate else PRODUCTION_EXTENSION_HASH),
        ),
    )


def write_transaction(root: Path, mode: str, row_manifest: Path, production_tree: Path) -> Path:
    tx = root / mode / "transaction"
    if mode == "a1t":
        started = "2026-08-01T15:59:59.000000Z"
        captured = "2026-08-01T16:00:00.100000Z"
        marker_absent = "2026-08-01T16:00:01.000000Z"
        restored = "2026-08-01T16:00:01.100000Z"
        completed = "2026-08-01T16:00:02.000000Z"
    else:
        started = "2026-08-01T16:00:59.000000Z"
        captured = "2026-08-01T16:01:00.100000Z"
        marker_absent = "2026-08-01T16:01:01.000000Z"
        restored = "2026-08-01T16:01:01.100000Z"
        completed = "2026-08-01T16:01:02.000000Z"
    transaction_id = f"fixture-{mode}-20260801"
    pre = state(tx / "pre-state.txt", False)
    post = write(tx / "post-restore-state.txt", pre.read_text(encoding="utf-8"))
    gate_state = state(tx / "gate-bound-state.txt", True)
    quiescence = write_kv(
        tx / "quiescence-inventory.txt",
        (("format", "1"), ("sample_count", "3"), ("sample_1_pid_paths", ""), ("sample_2_pid_paths", ""), ("sample_3_pid_paths", "")),
    )
    marker_inventory = write_kv(
        tx / "marker-process-inventory.txt",
        (
            ("format", "IdleScreenCameraGateC4ProcessInventoryV1"),
            ("captured_at_utc", marker_absent),
            ("helper_path", HELPER),
            ("helper_cdhash", GATE_HELPER_HASH),
            ("helper_pids", "none"),
            ("extension_path", EXTENSION),
            ("extension_cdhash", GATE_EXTENSION_HASH),
            ("extension_pids", "none"),
        ),
    )
    installed_identity = write_kv(
        tx / "installed-production-identity.txt",
        (
            ("format", "IdleScreenCameraGateC4InstalledIdentityV1"),
            ("captured_at_utc", restored),
            ("app_path", APP),
            ("app_cdhash", PRODUCTION_APP_HASH),
            ("helper_path", HELPER),
            ("helper_cdhash", PRODUCTION_HELPER_HASH),
            ("extension_path", EXTENSION),
            ("extension_cdhash", PRODUCTION_EXTENSION_HASH),
            ("deep_signature", "valid"),
            ("helper_marker", "absent"),
            ("extension_marker", "absent"),
        ),
    )
    restored_tree = write(tx / "restored-production-tree.tsv", production_tree.read_text(encoding="utf-8"))
    initial_entitlements = runtime_entitlements(tx / "initial-helper-runtime-entitlements.txt", captured, 101, "helper")
    saver_entitlements = runtime_entitlements(tx / "saver-runtime-entitlements.txt", captured, 501, "extension")
    recovered_entitlements = None
    if mode == "a1tr":
        recovered_entitlements = runtime_entitlements(tx / "recovered-helper-runtime-entitlements.txt", captured, 202, "helper")
    event_times = [
        started,
        started,
        started,
        started,
        started,
        started,
        started,
        captured,
        captured,
        marker_absent,
        restored,
        restored,
        restored,
    ]
    event_names = (
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
    transitions = write_kv(
        tx / "transitions.txt",
        (("format", "IdleScreenCameraGateC4TransitionsV1"), ("transaction_id", transaction_id), *((f"event_{index:02d}", f"{name}@{timestamp}") for index, (name, timestamp) in enumerate(zip(event_names, event_times), 1))),
    )
    journal = write_kv(
        tx / "journal.txt",
        (
            ("format", "4"),
            ("phase", "production_rebound"),
            ("transaction_id", transaction_id),
            ("production_app_cdhash", PRODUCTION_APP_HASH),
            ("production_helper_cdhash", PRODUCTION_HELPER_HASH),
            ("production_extension_cdhash", PRODUCTION_EXTENSION_HASH),
            ("synthetic_app_cdhash", GATE_APP_HASH),
            ("synthetic_helper_cdhash", GATE_HELPER_HASH),
            ("synthetic_extension_cdhash", GATE_EXTENSION_HASH),
            ("installed_app_path", APP),
            ("production_helper_path", HELPER_BUNDLE),
            ("production_extension_path", EXTENSION_BUNDLE),
            ("gate_candidate_path", "/private/tmp/idlescreen-c4/IdleScreenC4Gate.app"),
            ("synthetic_helper_path", "/private/tmp/idlescreen-c4/IdleScreenC4Gate.app/Contents/Helpers/IdleScreenCameraAgent.app"),
            ("synthetic_extension_path", "/private/tmp/idlescreen-c4/IdleScreenC4Gate.app/Contents/PlugIns/IdleScreenScreenSaver.appex"),
            ("manifest_sha256", sha(root / "synthetic-gate-manifest.txt")),
            ("pre_state_sha256", sha(pre)),
            ("quiescence_inventory_sha256", sha(quiescence)),
            ("gate_bound_state_sha256", sha(gate_state)),
            ("post_restore_state_sha256", sha(post)),
        ),
    )
    transaction = tx / "transaction-manifest.txt"
    pairs: List[Tuple[str, str]] = [
        ("format", "IdleScreenCameraGateC4TransactionV1"),
        ("mode", mode),
        ("started_at_utc", started),
        ("marker_processes_absent_at_utc", marker_absent),
        ("production_restored_at_utc", restored),
        ("completed_at_utc", completed),
        ("c3_archive_tree_sha256", ARCHIVE_HASH),
        ("c3_provenance_manifest_sha256", sha(root / "c3-provenance.txt")),
        ("gate_binding_manifest_sha256", sha(root / "gate-binding.txt")),
        ("synthetic_gate_manifest_sha256", sha(root / "synthetic-gate-manifest.txt")),
        ("a1_evidence_manifest", str(row_manifest)),
        ("a1_evidence_manifest_sha256", sha(row_manifest)),
    ]
    for key, artifact in (
        ("transaction_journal", journal),
        ("transaction_transitions", transitions),
        ("pre_state", pre),
        ("quiescence_inventory", quiescence),
        ("gate_bound_state", gate_state),
        ("post_restore_state", post),
        ("marker_process_inventory", marker_inventory),
        ("installed_production_identity", installed_identity),
        ("restored_production_tree_inventory", restored_tree),
        ("initial_helper_runtime_entitlements", initial_entitlements),
        ("saver_runtime_entitlements", saver_entitlements),
    ):
        pairs.extend(((key, str(artifact)), (f"{key}_sha256", sha(artifact))))
    if recovered_entitlements is None:
        pairs.extend((("recovered_helper_runtime_entitlements", "none"), ("recovered_helper_runtime_entitlements_sha256", "none")))
    else:
        pairs.extend((("recovered_helper_runtime_entitlements", str(recovered_entitlements)), ("recovered_helper_runtime_entitlements_sha256", sha(recovered_entitlements))))
    return write_kv(transaction, pairs)


def build_bundle(root: Path) -> Path:
    c3 = write_kv(
        root / "c3-provenance.txt",
        (
            ("schema", "IdleScreenReleaseArchiveProvenance/v1"),
            ("verification_mode", "release"),
            ("archive_tree_sha256", ARCHIVE_HASH),
            ("team_identifier", TEAM),
            ("app_group", APP_GROUP),
            ("mach_service", f"{APP_GROUP}.camera-agent"),
            ("camera_usage_description_sha256", "3" * 64),
            ("launch_agent_sha256", "4" * 64),
            ("signer_certificate_sha256", "5" * 64),
            ("app_bundle_identifier", "com.idlescreen.app"),
            ("app_cdhash", PRODUCTION_APP_HASH),
            ("app_designated_requirement_sha256", "6" * 64),
            ("app_entitlements_sha256", "7" * 64),
            ("app_profile_sha256", "8" * 64),
            ("app_profile_uuid", "11111111-1111-1111-1111-111111111111"),
            ("app_profile_expiration", "2027-08-01T00:00:00Z"),
            ("extension_bundle_identifier", "com.idlescreen.app.screensaver"),
            ("extension_cdhash", PRODUCTION_EXTENSION_HASH),
            ("extension_designated_requirement_sha256", "9" * 64),
            ("extension_entitlements_sha256", "a" * 64),
            ("extension_profile_sha256", "b" * 64),
            ("extension_profile_uuid", "22222222-2222-2222-2222-222222222222"),
            ("extension_profile_expiration", "2027-08-01T00:00:00Z"),
            ("helper_bundle_identifier", "com.idlescreen.camera-agent"),
            ("helper_cdhash", PRODUCTION_HELPER_HASH),
            ("helper_designated_requirement_sha256", "c" * 64),
            ("helper_entitlements_sha256", "d" * 64),
            ("helper_profile_sha256", "e" * 64),
            ("helper_profile_uuid", "33333333-3333-3333-3333-333333333333"),
            ("helper_profile_expiration", "2027-08-01T00:00:00Z"),
        ),
    )
    gate = write_kv(
        root / "synthetic-gate-manifest.txt",
        (
            ("format", "IdleScreenSyntheticGateManifestV1"),
            ("unchangedInventorySHA256", "1" * 64),
            ("outerExecutableUnsignedSHA256", "2" * 64),
            ("outerIdentifier", "com.idlescreen.app"),
            ("outerTeamIdentifier", TEAM),
            ("outerCodeDirectoryFlags", "0x10000(runtime)"),
            ("productionExtensionPath", "Contents/PlugIns/IdleScreenScreenSaver.appex"),
            ("productionExtensionTreeSHA256", "3" * 64),
            ("syntheticExtensionTreeSHA256", "4" * 64),
            ("productionLaunchAgentsPath", "Contents/Library/LaunchAgents"),
            ("productionLaunchAgentsTreeSHA256", "5" * 64),
            ("productionHelperCDHash", PRODUCTION_HELPER_HASH),
            ("syntheticHelperCDHash", GATE_HELPER_HASH),
            ("productionExtensionCDHash", PRODUCTION_EXTENSION_HASH),
            ("syntheticExtensionCDHash", GATE_EXTENSION_HASH),
            ("allowedSubstitution", "Contents/Helpers/IdleScreenCameraAgent.app/"),
            ("allowedSubstitution", "Contents/PlugIns/IdleScreenScreenSaver.appex/"),
            ("allowedSignatureEnvelope", "Contents/MacOS/IdleScreen"),
            ("allowedSubstitution", "Contents/_CodeSignature/CodeResources"),
        ),
    )
    inventory_text = "directory\t755\t.\nfile\t755\t4\t" + "f" * 64 + "\tContents/MacOS/IdleScreen\n"
    candidate_tree = write(root / "candidate-tree.tsv", inventory_text)
    installed_tree = write(root / "installed-tree.tsv", inventory_text)
    binding = write_kv(
        root / "gate-binding.txt",
        (
            ("schema", "IdleScreenC4GateBinding/v1"),
            ("verification_mode", "release"),
            ("c3_archive_tree_sha256", ARCHIVE_HASH),
            ("c3_provenance_manifest_sha256", sha(c3)),
            ("c3_product_tree_sha256", sha(candidate_tree)),
            ("c3_app_cdhash", PRODUCTION_APP_HASH),
            ("c3_helper_cdhash", PRODUCTION_HELPER_HASH),
            ("c3_extension_cdhash", PRODUCTION_EXTENSION_HASH),
            ("gate_manifest_sha256", sha(gate)),
            ("gate_app_cdhash", GATE_APP_HASH),
            ("gate_helper_cdhash", GATE_HELPER_HASH),
            ("gate_extension_cdhash", GATE_EXTENSION_HASH),
        ),
    )
    install = write_kv(
        root / "production-install-manifest.txt",
        (
            ("schema", "IdleScreenC4ProductionInstall/v1"),
            ("verification_mode", "release"),
            ("c3_archive_tree_sha256", ARCHIVE_HASH),
            ("c3_provenance_manifest_sha256", sha(c3)),
            ("app_cdhash", PRODUCTION_APP_HASH),
            ("helper_cdhash", PRODUCTION_HELPER_HASH),
            ("extension_cdhash", PRODUCTION_EXTENSION_HASH),
            ("candidate_tree_sha256", sha(candidate_tree)),
            ("installed_tree_sha256", sha(installed_tree)),
            ("prior_backup_tree_sha256", "6" * 64),
            ("initial_registration", "unbound"),
            ("final_registration", "unbound"),
            ("camera_tcc_action", "none"),
        ),
    )
    row_manifests = {mode: write_a1_row(root, mode) for mode in ("a1t", "a1tr")}
    transactions = {mode: write_transaction(root, mode, row_manifests[mode], installed_tree) for mode in ("a1t", "a1tr")}
    top = root / "c4-evidence-manifest.txt"
    write_kv(
        top,
        (
            ("format", "IdleScreenCameraGateC4EvidenceV1"),
            ("evidence_semantics", "topology-equivalent-camera-free"),
            ("trusted_for_production", "false"),
            ("c3_provenance_manifest", str(c3)),
            ("c3_provenance_manifest_sha256", sha(c3)),
            ("c3_archive_tree_sha256", ARCHIVE_HASH),
            ("gate_binding_manifest", str(binding)),
            ("gate_binding_manifest_sha256", sha(binding)),
            ("synthetic_gate_manifest", str(gate)),
            ("synthetic_gate_manifest_sha256", sha(gate)),
            ("production_install_manifest", str(install)),
            ("production_install_manifest_sha256", sha(install)),
            ("production_candidate_tree_inventory", str(candidate_tree)),
            ("production_candidate_tree_inventory_sha256", sha(candidate_tree)),
            ("production_installed_tree_inventory", str(installed_tree)),
            ("production_installed_tree_inventory_sha256", sha(installed_tree)),
            ("a1t_evidence_manifest", str(row_manifests["a1t"])),
            ("a1t_evidence_manifest_sha256", sha(row_manifests["a1t"])),
            ("a1t_transaction_manifest", str(transactions["a1t"])),
            ("a1t_transaction_manifest_sha256", sha(transactions["a1t"])),
            ("a1tr_evidence_manifest", str(row_manifests["a1tr"])),
            ("a1tr_evidence_manifest_sha256", sha(row_manifests["a1tr"])),
            ("a1tr_transaction_manifest", str(transactions["a1tr"])),
            ("a1tr_transaction_manifest_sha256", sha(transactions["a1tr"])),
        ),
    )
    return top


def refresh_transaction(root: Path, mode: str, artifact_key: Optional[str] = None) -> None:
    top = root / "c4-evidence-manifest.txt"
    transaction = root / mode / "transaction/transaction-manifest.txt"
    if artifact_key is not None:
        artifact = Path(read_kv(transaction)[artifact_key])
        replace_field(transaction, f"{artifact_key}_sha256", sha(artifact))
    replace_field(top, f"{mode}_transaction_manifest_sha256", sha(transaction))


def expect_rejected(label: str, mutation: Callable[[Path], None], scratch: Path) -> None:
    root = scratch / label
    manifest = build_bundle(root)
    mutation(root)
    result = subprocess.run((str(VERIFIER), str(manifest)), text=True, capture_output=True, check=False)
    if result.returncode != 1:
        raise AssertionError(f"{label}: expected evidence rejection, got {result.returncode}: {result.stdout}{result.stderr}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="idlescreen-c4-fixtures.") as temporary:
        scratch = Path(temporary)
        valid = build_bundle(scratch / "valid")
        result = subprocess.run((str(VERIFIER), str(valid)), text=True, capture_output=True, check=False)
        if result.returncode != 0:
            raise AssertionError(f"valid C4 fixture rejected: {result.stdout}{result.stderr}")

        def c3_not_release(root: Path) -> None:
            c3 = root / "c3-provenance.txt"
            replace_field(c3, "verification_mode", "fixture")
            replace_field(root / "c4-evidence-manifest.txt", "c3_provenance_manifest_sha256", sha(c3))

        def archive_drift(root: Path) -> None:
            replace_field(root / "c4-evidence-manifest.txt", "c3_archive_tree_sha256", "f" * 64)

        def independent_production(root: Path) -> None:
            gate = root / "synthetic-gate-manifest.txt"
            replace_field(gate, "productionHelperCDHash", "e" * 40)
            replace_field(root / "c4-evidence-manifest.txt", "synthetic_gate_manifest_sha256", sha(gate))

        def installed_tree_drift(root: Path) -> None:
            installed = root / "installed-tree.tsv"
            installed.write_text(installed.read_text(encoding="utf-8") + "directory\t700\tdrift\n", encoding="utf-8")
            top = root / "c4-evidence-manifest.txt"
            replace_field(top, "production_installed_tree_inventory_sha256", sha(installed))
            install = root / "production-install-manifest.txt"
            replace_field(install, "installed_tree_sha256", sha(installed))
            replace_field(top, "production_install_manifest_sha256", sha(install))

        def camera_entitlement(root: Path) -> None:
            artifact = root / "a1t/transaction/initial-helper-runtime-entitlements.txt"
            replace_field(artifact, "camera", "true")
            refresh_transaction(root, "a1t", "initial_helper_runtime_entitlements")

        def missing_pre_registration(root: Path) -> None:
            for leaf in ("pre-state.txt", "post-restore-state.txt"):
                artifact = root / f"a1t/transaction/{leaf}"
                replace_field(artifact, "launchd_registration", "loaded")
            transaction = root / "a1t/transaction/transaction-manifest.txt"
            replace_field(transaction, "pre_state_sha256", sha(root / "a1t/transaction/pre-state.txt"))
            replace_field(transaction, "post_restore_state_sha256", sha(root / "a1t/transaction/post-restore-state.txt"))
            journal = root / "a1t/transaction/journal.txt"
            replace_field(journal, "pre_state_sha256", sha(root / "a1t/transaction/pre-state.txt"))
            replace_field(journal, "post_restore_state_sha256", sha(root / "a1t/transaction/post-restore-state.txt"))
            replace_field(transaction, "transaction_journal_sha256", sha(journal))
            refresh_transaction(root, "a1t")

        def restoration_drift(root: Path) -> None:
            artifact = root / "a1t/transaction/post-restore-state.txt"
            replace_field(artifact, "helper_runtime", "warm")
            transaction = root / "a1t/transaction/transaction-manifest.txt"
            replace_field(transaction, "post_restore_state_sha256", sha(artifact))
            journal = root / "a1t/transaction/journal.txt"
            replace_field(journal, "post_restore_state_sha256", sha(artifact))
            replace_field(transaction, "transaction_journal_sha256", sha(journal))
            refresh_transaction(root, "a1t")

        def missing_transition(root: Path) -> None:
            artifact = root / "a1t/transaction/transitions.txt"
            replace_field(artifact, "event_06", "gate_registration_skipped@2026-08-01T15:59:59.000000Z")
            refresh_transaction(root, "a1t", "transaction_transitions")

        def marker_process_survives(root: Path) -> None:
            artifact = root / "a1t/transaction/marker-process-inventory.txt"
            replace_field(artifact, "helper_pids", "777")
            refresh_transaction(root, "a1t", "marker_process_inventory")

        def production_marker_survives(root: Path) -> None:
            artifact = root / "a1t/transaction/installed-production-identity.txt"
            replace_field(artifact, "helper_marker", "present")
            refresh_transaction(root, "a1t", "installed_production_identity")

        def restored_tree_drift(root: Path) -> None:
            artifact = root / "a1t/transaction/restored-production-tree.tsv"
            artifact.write_text(artifact.read_text(encoding="utf-8") + "directory\t700\tdrift\n", encoding="utf-8")
            refresh_transaction(root, "a1t", "restored_production_tree_inventory")

        def stale_epoch_delivery(root: Path) -> None:
            log = root / "a1tr/combined.log"
            text = log.read_text(encoding="utf-8")
            text = text.replace("epoch=9001 sequence=1 instance=view-a", "epoch=7001 sequence=22 instance=view-a", 1)
            log.write_text(text, encoding="utf-8")
            row = root / "a1tr/evidence-manifest.txt"
            replace_field(row, "log_sha256", sha(log))
            top = root / "c4-evidence-manifest.txt"
            replace_field(top, "a1tr_evidence_manifest_sha256", sha(row))
            transaction = root / "a1tr/transaction/transaction-manifest.txt"
            replace_field(transaction, "a1_evidence_manifest_sha256", sha(row))
            refresh_transaction(root, "a1tr")

        def wrong_order(root: Path) -> None:
            transaction = root / "a1tr/transaction/transaction-manifest.txt"
            replace_field(transaction, "started_at_utc", "2026-08-01T15:59:00.000000Z")
            refresh_transaction(root, "a1tr")

        def missing_retained_journal(root: Path) -> None:
            (root / "a1t/transaction/journal.txt").unlink()

        mutations = (
            ("c3-not-release", c3_not_release),
            ("archive-tree-drift", archive_drift),
            ("independent-production", independent_production),
            ("installed-tree-drift", installed_tree_drift),
            ("camera-entitlement", camera_entitlement),
            ("missing-pre-registration", missing_pre_registration),
            ("restoration-drift", restoration_drift),
            ("missing-transition", missing_transition),
            ("marker-process-survives", marker_process_survives),
            ("production-marker-survives", production_marker_survives),
            ("restored-tree-drift", restored_tree_drift),
            ("stale-epoch-delivery", stale_epoch_delivery),
            ("a1tr-before-a1t", wrong_order),
            ("missing-retained-journal", missing_retained_journal),
        )
        for label, mutation in mutations:
            expect_rejected(label, mutation, scratch)
    print("PASS: C4 verifier accepts one complete bundle and rejects all false-pass mutations.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
