#!/usr/bin/python3

"""Offline parser fixtures for the C5 evidence verifier.

No fixture launches a product, changes TCC, opens UI, or accesses a camera.
"""

from __future__ import annotations

import hashlib
import subprocess
import sys
import tempfile
from collections import OrderedDict
from pathlib import Path
from typing import Dict, Iterable, Mapping


PROJECT_ROOT = Path(__file__).resolve().parent.parent
VERIFIER = PROJECT_ROOT / "scripts/verify-camera-gate-c5-evidence.py"
SHA = "a" * 64
APP_CDHASH = "1" * 40
HELPER_CDHASH = "2" * 40
EXTENSION_CDHASH = "3" * 40


def write_kv(path: Path, values: Mapping[str, str]) -> None:
    path.write_text(
        "".join(f"{key}={value}\n" for key, value in values.items()),
        encoding="utf-8",
    )


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def c3_values() -> OrderedDict[str, str]:
    values: OrderedDict[str, str] = OrderedDict(
        (
            ("schema", "IdleScreenReleaseArchiveProvenance/v1"),
            ("verification_mode", "release"),
            ("archive_tree_sha256", "b" * 64),
            ("team_identifier", "3524374A2S"),
            ("app_group", "group.com.idlescreen.shared"),
            ("mach_service", "group.com.idlescreen.shared.camera-agent"),
            ("camera_usage_description_sha256", SHA),
            ("launch_agent_sha256", SHA),
            ("signer_certificate_sha256", SHA),
            ("app_bundle_identifier", "com.idlescreen.app"),
            ("app_cdhash", APP_CDHASH),
            ("app_designated_requirement_sha256", SHA),
            ("app_entitlements_sha256", SHA),
            ("app_profile_sha256", SHA),
            ("app_profile_uuid", "app-profile"),
            ("app_profile_expiration", "2027-08-01T00:00:00Z"),
            ("extension_bundle_identifier", "com.idlescreen.app.screensaver"),
            ("extension_cdhash", EXTENSION_CDHASH),
            ("extension_designated_requirement_sha256", SHA),
            ("extension_entitlements_sha256", SHA),
            ("extension_profile_sha256", SHA),
            ("extension_profile_uuid", "extension-profile"),
            ("extension_profile_expiration", "2027-08-01T00:00:00Z"),
            ("helper_bundle_identifier", "com.idlescreen.camera-agent"),
            ("helper_cdhash", HELPER_CDHASH),
            ("helper_designated_requirement_sha256", SHA),
            ("helper_entitlements_sha256", SHA),
            ("helper_profile_sha256", SHA),
            ("helper_profile_uuid", "helper-profile"),
            ("helper_profile_expiration", "2027-08-01T00:00:00Z"),
        )
    )
    return values


def agent(timestamp: str, category: str, message: str) -> str:
    return (
        f"{timestamp} I IdleScreenCameraAgent[101:def] "
        f"[com.idlescreen.camera-agent:{category}] {message}"
    )


def companion(timestamp: str, sequence: int) -> str:
    return (
        f"{timestamp} I IdleScreen[202:def] [com.idlescreen.app:CameraEvidence] "
        f"companion_frame_consumed generation=1 epoch=9001 sequence={sequence}"
    )


def lifecycle_lines(mutation: str) -> Iterable[str]:
    lines = [
        agent(
            "2026-08-01 12:00:01.050000-0400",
            "identity",
            "peer_admission_accepted connection_id=control-1 pid=202 "
            "team_id=3524374A2S bundle_id=com.idlescreen.app role=companion",
        ),
        agent(
            "2026-08-01 12:00:01.100000-0400",
            "lifecycle",
            "authorization_status status=not-determined source=status-refresh",
        ),
    ]
    if mutation == "early-lease":
        lines.append(
            agent(
                "2026-08-01 12:00:01.500000-0400",
                "lifecycle",
                "lease_count_changed previous=0 current=1 epoch=9001",
            )
        )
    lines.extend(
        [
            agent(
                "2026-08-01 12:00:02.200000-0400",
                "lifecycle",
                "authorization_status status=authorized source=explicit-request-completion",
            ),
            agent(
                "2026-08-01 12:00:03.200000-0400",
                "lifecycle",
                "lease_count_changed previous=0 current=1 epoch=9001",
            ),
            agent(
                "2026-08-01 12:00:03.300000-0400",
                "lifecycle",
                "capture_start_requested generation=7 epoch=9001",
            ),
            agent(
                "2026-08-01 12:00:03.400000-0400",
                "lifecycle",
                "capture_started generation=7 epoch=9001",
            ),
            agent(
                "2026-08-01 12:00:03.500000-0400",
                "lifecycle",
                "first_frame_published generation=7 epoch=9001 sequence=1",
            ),
            companion("2026-08-01 12:00:03.600000-0400", 1),
            companion("2026-08-01 12:00:04.100000-0400", 3 if mutation == "decreasing" else 2),
            companion("2026-08-01 12:00:04.600000-0400", 2 if mutation == "decreasing" else 3),
            agent(
                "2026-08-01 12:00:05.100000-0400",
                "lifecycle",
                "lease_count_changed previous=1 current=0 epoch=9001",
            ),
            agent(
                "2026-08-01 12:00:05.200000-0400",
                "lifecycle",
                "capture_stop_requested generation=7 epoch=9001",
            ),
            agent(
                "2026-08-01 12:00:05.300000-0400",
                "lifecycle",
                "capture_stopped generation=7 epoch=9001",
            ),
        ]
    )
    if mutation == "extra-lifecycle":
        lines.insert(
            7,
            agent(
                "2026-08-01 12:00:03.550000-0400",
                "lifecycle",
                "capture_started generation=7 epoch=9001",
            ),
        )
    return lines


def build_bundle(root: Path, mutation: str) -> Path:
    root.mkdir()
    c3 = root / "c3.txt"
    write_kv(c3, c3_values())

    installed = root / "c4-installed.txt"
    write_kv(
        installed,
        OrderedDict(
            (
                ("format", "IdleScreenCameraGateC4InstalledIdentityV1"),
                ("captured_at_utc", "2026-08-01T15:59:58.000000Z"),
                ("app_path", "/Applications/idlescreen.app"),
                ("app_cdhash", APP_CDHASH),
                (
                    "helper_path",
                    "/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent",
                ),
                ("helper_cdhash", HELPER_CDHASH),
                (
                    "extension_path",
                    "/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver",
                ),
                ("extension_cdhash", EXTENSION_CDHASH),
                ("deep_signature", "valid"),
                ("helper_marker", "absent"),
                ("extension_marker", "absent"),
            )
        ),
    )
    tree = root / "restored-tree.tsv"
    tree.write_text("exact-restored-tree\n", encoding="utf-8")
    placeholder = root / "placeholder.txt"
    placeholder.write_text("placeholder\n", encoding="utf-8")

    c4 = root / "c4-transaction.txt"
    c4_values: OrderedDict[str, str] = OrderedDict(
        (
            ("format", "IdleScreenCameraGateC4TransactionV1"),
            ("mode", "a1tr"),
            ("started_at_utc", "2026-08-01T15:59:50.000000Z"),
            ("marker_processes_absent_at_utc", "2026-08-01T15:59:57.000000Z"),
            ("production_restored_at_utc", "2026-08-01T15:59:58.000000Z"),
            ("completed_at_utc", "2026-08-01T15:59:59.000000Z"),
            ("c3_archive_tree_sha256", "b" * 64),
            ("c3_provenance_manifest_sha256", digest(c3)),
            ("gate_binding_manifest_sha256", SHA),
            ("synthetic_gate_manifest_sha256", SHA),
            ("a1_evidence_manifest", str(placeholder)),
            ("a1_evidence_manifest_sha256", SHA),
            ("transaction_journal", str(placeholder)),
            ("transaction_journal_sha256", SHA),
            ("transaction_transitions", str(placeholder)),
            ("transaction_transitions_sha256", SHA),
            ("pre_state", str(placeholder)),
            ("pre_state_sha256", SHA),
            ("quiescence_inventory", str(placeholder)),
            ("quiescence_inventory_sha256", SHA),
            ("gate_bound_state", str(placeholder)),
            ("gate_bound_state_sha256", SHA),
            ("post_restore_state", str(placeholder)),
            ("post_restore_state_sha256", SHA),
            ("marker_process_inventory", str(placeholder)),
            ("marker_process_inventory_sha256", SHA),
            ("installed_production_identity", str(installed)),
            ("installed_production_identity_sha256", digest(installed)),
            ("restored_production_tree_inventory", str(tree)),
            ("restored_production_tree_inventory_sha256", digest(tree)),
            ("initial_helper_runtime_entitlements", str(placeholder)),
            ("initial_helper_runtime_entitlements_sha256", SHA),
            ("saver_runtime_entitlements", str(placeholder)),
            ("saver_runtime_entitlements_sha256", SHA),
            ("recovered_helper_runtime_entitlements", str(placeholder)),
            ("recovered_helper_runtime_entitlements_sha256", SHA),
        )
    )
    write_kv(c4, c4_values)

    identity = root / "identity.txt"
    write_kv(
        identity,
        OrderedDict(
            (
                ("format", "IdleScreenCameraGateC5IdentityV1"),
                ("captured_at_utc", "2026-08-01T16:00:00.000000Z"),
                ("app_path", "/Applications/idlescreen.app"),
                ("app_bundle_identifier", "com.idlescreen.app"),
                ("app_team_identifier", "3524374A2S"),
                ("app_cdhash", APP_CDHASH),
                (
                    "helper_path",
                    "/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent",
                ),
                ("helper_bundle_identifier", "com.idlescreen.camera-agent"),
                ("helper_team_identifier", "3524374A2S"),
                ("helper_cdhash", HELPER_CDHASH),
                (
                    "extension_path",
                    "/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver",
                ),
                ("extension_bundle_identifier", "com.idlescreen.app.screensaver"),
                ("extension_team_identifier", "3524374A2S"),
                ("extension_cdhash", EXTENSION_CDHASH),
                ("deep_signature", "valid"),
                ("helper_marker", "absent"),
                ("extension_marker", "absent"),
                ("restored_release_identity", "exact"),
            )
        ),
    )

    ownership = root / "ownership.txt"
    ownership_helper = "999" if mutation == "owner-drift" else "101"
    write_kv(
        ownership,
        OrderedDict(
            (
                ("format", "IdleScreenCameraGateC5RuntimeOwnershipV1"),
                ("captured_at_utc", "2026-08-01T16:00:04.700000Z"),
                ("helper_pid", ownership_helper),
                (
                    "helper_path",
                    "/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent",
                ),
                ("helper_cdhash", HELPER_CDHASH),
                ("companion_pid", "202"),
                ("companion_path", "/Applications/idlescreen.app/Contents/MacOS/IdleScreen"),
                ("companion_cdhash", APP_CDHASH),
                ("screen_saver_pids", "none"),
                ("other_helper_pids", "none"),
                ("static_avfoundation_owner_bundle_identifier", "com.idlescreen.camera-agent"),
                ("runtime_capture_owner_pid", "101"),
                ("companion_frame_consumer_pid", "202"),
                ("active_peer_role", "companion"),
                ("maximum_active_lease_count", "1"),
                ("avfoundation_capture_owner_count", "1"),
                ("sole_avfoundation_owner", "true"),
            )
        ),
    )

    attribution = root / "attribution.txt"
    write_kv(
        attribution,
        OrderedDict(
            (
                ("format", "IdleScreenCameraGateC5AttributionV1"),
                ("fresh_authorization_state", "not-determined"),
                ("visible_permission_label", "idlescreen"),
                ("permission_action", "companion-explicit-request"),
                ("authorized_bundle_identifier", "com.idlescreen.camera-agent"),
                ("preview_lease_during_permission", "absent"),
                ("capture_during_permission", "absent"),
                ("attribution_verdict", "resolved-fresh"),
            )
        ),
    )

    led = root / "led.txt"
    led_time = "2026-08-01T16:00:08.000000Z" if mutation == "late-led" else "2026-08-01T16:00:06.000000Z"
    write_kv(
        led,
        OrderedDict(
            (
                ("format", "IdleScreenCameraGateC5LEDObservationV1"),
                ("observer", "human-visible-camera-indicator"),
                ("before_preview", "off"),
                ("during_preview", "on"),
                ("after_final_lease", "off"),
                ("after_final_lease_observed_at_utc", led_time),
            )
        ),
    )

    checkpoints = root / "checkpoints.txt"
    checkpoint_values = OrderedDict(
        (
            ("format", "IdleScreenCameraGateC5CheckpointsV1"),
            ("runner_started_at_utc", "2026-08-01T16:00:00.000000Z"),
            ("identity_verified_at_utc", "2026-08-01T16:00:00.000000Z"),
            ("console_unlocked_at_utc", "2026-08-01T16:00:00.100000Z"),
            ("app_launch_authorized_at_utc", "2026-08-01T16:00:00.900000Z"),
            ("app_launched_at_utc", "2026-08-01T16:00:01.000000Z"),
            ("permission_not_determined_at_utc", "2026-08-01T16:00:01.100000Z"),
            ("permission_action_authorized_at_utc", "2026-08-01T16:00:02.000000Z"),
            ("permission_request_at_utc", "2026-08-01T16:00:02.100000Z"),
            ("permission_authorized_at_utc", "2026-08-01T16:00:02.200000Z"),
            ("permission_zero_lease_at_utc", "2026-08-01T16:00:02.300000Z"),
            ("preview_action_authorized_at_utc", "2026-08-01T16:00:03.000000Z"),
            ("hardware_use_authorized_at_utc", "2026-08-01T16:00:03.000000Z"),
            ("preview_request_at_utc", "2026-08-01T16:00:03.100000Z"),
            ("preview_lease_at_utc", "2026-08-01T16:00:03.200000Z"),
            ("capture_started_at_utc", "2026-08-01T16:00:03.400000Z"),
            ("first_consumed_at_utc", "2026-08-01T16:00:03.600000Z"),
            ("last_consumed_at_utc", "2026-08-01T16:00:04.600000Z"),
            ("stop_request_at_utc", "2026-08-01T16:00:05.000000Z"),
            ("final_lease_zero_at_utc", "2026-08-01T16:00:05.100000Z"),
            ("capture_stopped_at_utc", "2026-08-01T16:00:05.300000Z"),
            ("led_off_at_utc", led_time),
            ("completed_at_utc", "2026-08-01T16:00:08.100000Z" if mutation == "late-led" else "2026-08-01T16:00:06.100000Z"),
        )
    )
    write_kv(checkpoints, checkpoint_values)

    log = root / "combined.log"
    log.write_text("\n".join(lifecycle_lines(mutation)) + "\n", encoding="utf-8")

    manifest = root / "evidence-manifest.txt"
    values: OrderedDict[str, str] = OrderedDict(
        (
            ("format", "IdleScreenCameraGateC5EvidenceV1"),
            ("evidence_semantics", "unlocked-companion-physical-camera"),
            ("trusted_for_production", "true"),
            ("attribution_verdict", "resolved-fresh"),
            ("console_state", "unlocked"),
            ("app_launch_action", "performed"),
            ("app_launch_authorization", "yes"),
            ("tcc_reset_action", "not-performed"),
            ("tcc_reset_authorization", "not-used"),
            ("tcc_request_action", "performed"),
            ("tcc_request_authorization", "yes"),
            ("tcc_settings_action", "not-performed"),
            ("tcc_settings_authorization", "yes" if mutation == "ambient-settings" else "not-used"),
            ("camera_start_action", "performed"),
            ("camera_start_authorization", "yes"),
            ("camera_hardware_action", "performed"),
            ("camera_hardware_authorization", "yes"),
            ("c3_provenance_manifest", str(c3)),
            ("c3_provenance_manifest_sha256", digest(c3)),
            ("c4_restoration_manifest", str(c4)),
            ("c4_restoration_manifest_sha256", digest(c4)),
            ("c3_archive_tree_sha256", "b" * 64),
            ("identity_snapshot", str(identity)),
            ("identity_snapshot_sha256", digest(identity)),
            ("runtime_ownership", str(ownership)),
            ("runtime_ownership_sha256", digest(ownership)),
            ("attribution_observation", str(attribution)),
            ("attribution_observation_sha256", digest(attribution)),
            ("led_observation", str(led)),
            ("led_observation_sha256", digest(led)),
            ("checkpoints", str(checkpoints)),
            ("checkpoints_sha256", digest(checkpoints)),
            ("log_path", str(log)),
            ("log_sha256", digest(log)),
            ("helper_pid", "101"),
            ("companion_pid", "202"),
            ("capture_generation", "7"),
            ("consumption_generation", "1"),
            ("producer_epoch", "9001"),
            ("first_consumed_sequence", "1"),
            ("last_consumed_sequence", "2" if mutation == "decreasing" else "3"),
            ("consumed_receipt_count", "3"),
            ("final_active_lease_count", "0"),
        )
    )
    write_kv(manifest, values)
    return manifest


def run_fixture(root: Path, name: str, expect_success: bool) -> None:
    manifest = build_bundle(root / name, name)
    result = subprocess.run(
        [sys.executable, str(VERIFIER), str(manifest)],
        text=True,
        capture_output=True,
        check=False,
    )
    if (result.returncode == 0) != expect_success:
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        raise RuntimeError(f"fixture {name} returned {result.returncode}")
    print(f"PASS: C5 offline fixture {name}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="idlescreen-c5-fixtures.") as temporary:
        root = Path(temporary)
        run_fixture(root, "valid", True)
        for mutation in (
            "early-lease",
            "decreasing",
            "late-led",
            "ambient-settings",
            "owner-drift",
            "extra-lifecycle",
        ):
            run_fixture(root, mutation, False)
    print("PASS: C5 evidence verifier accepts the complete row and fails closed on boundary mutations.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
