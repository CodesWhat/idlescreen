#!/usr/bin/env python3
"""Deterministic offline fixtures for the C8 evidence and row-plan contracts."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from camera_gate_c8_schema import (
    ATTESTATION_SCHEMA,
    CONSOLE_STATE_SCHEMA,
    EVENT_SCHEMA,
    FINAL_STATE_SCHEMA,
    IDENTITY_SCHEMA,
    PREFLIGHT_CONSOLE_STATE_SCHEMA,
    ROWS,
)


SCRIPT_ROOT = Path(__file__).resolve().parent
PREPARER = SCRIPT_ROOT / "prepare-camera-gate-c8-evidence.py"
VERIFIER = SCRIPT_ROOT / "verify-camera-gate-c8-evidence.py"
ROW_RUNNER = SCRIPT_ROOT / "run-camera-gate-c8-row.py"


def fail(message: str) -> None:
    raise RuntimeError(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def run(
    *arguments: str,
    expected: int = 0,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [sys.executable, *arguments],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )
    if result.returncode != expected:
        fail(
            f"expected {expected}, got {result.returncode}: {' '.join(arguments)}\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )
    return result


def timestamp(hour: int, second: int) -> str:
    return f"2026-08-01T{hour:02d}:00:{second:02d}.000000Z"


def identity(
    matrix: dict[str, object],
    row_id: str,
    run_id: str,
    captured_at: str,
    helper_pid: int | None,
    extension_pids: list[int],
) -> dict[str, object]:
    candidate = matrix["candidate"]
    return {
        "schema": IDENTITY_SCHEMA,
        "matrix_id": matrix["matrix_id"],
        "row_id": row_id,
        "row_run_id": run_id,
        "captured_at_utc": captured_at,
        "app_path": "/Applications/idlescreen.app",
        "helper_path": (
            "/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/"
            "Contents/MacOS/IdleScreenCameraAgent"
        ),
        "extension_path": (
            "/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/"
            "Contents/MacOS/IdleScreenScreenSaver"
        ),
        "team_identifier": candidate["team_identifier"],  # type: ignore[index]
        "archive_tree_sha256": candidate["archive_tree_sha256"],  # type: ignore[index]
        "app_cdhash": candidate["app_cdhash"],  # type: ignore[index]
        "helper_cdhash": candidate["helper_cdhash"],  # type: ignore[index]
        "extension_cdhash": candidate["extension_cdhash"],  # type: ignore[index]
        "runtime_helper_pid": helper_pid,
        "runtime_extension_pids": extension_pids,
        "deep_signature_valid": True,
        "profiles_valid": True,
        "production_markers_absent": True,
    }


def complete_matrix(root: Path) -> None:
    matrix = load(root / "matrix.json")
    candidate = matrix["candidate"]
    for definition in ROWS:
        row_path = root / definition.filename
        row = load(row_path)
        hour = definition.ordinal
        run_id = f"run-c8-{definition.ordinal:02d}-{definition.row_id}"
        authorization_id = (
            f"authorization-c8-{definition.ordinal:02d}-{definition.row_id}"
        )
        artifact_root = (
            root / "artifacts" / f"{definition.ordinal:02d}-{definition.row_id}"
        )
        artifact_root.mkdir()

        detail_codes = [
            "row-started",
            "identity-before-stable",
            "action-boundary",
            *definition.required_detail_codes,
            "stale-frame-rejected",
        ]
        if definition.requires_fresh_recovery:
            detail_codes.append("fresh-frame-consumed")
        detail_codes.extend(
            ("identity-after-stable", "final-state-observed", "row-completed")
        )
        before_index = detail_codes.index("identity-before-stable") + 1
        after_index = detail_codes.index("identity-after-stable") + 1
        final_index = detail_codes.index("final-state-observed") + 1
        started = timestamp(hour, 1)
        completed = timestamp(hour, len(detail_codes) + 3)
        helper_restart_at = (
            detail_codes.index("helper-relaunched") + 1
            if "helper-relaunched" in detail_codes
            else None
        )
        extension_restart_at = (
            detail_codes.index("extension-relaunched") + 1
            if "extension-relaunched" in detail_codes
            else None
        )
        old_epoch = 1000 + definition.ordinal
        events: list[dict[str, object]] = []
        for index, code in enumerate(detail_codes, 1):
            helper_restarts = int(
                helper_restart_at is not None and index >= helper_restart_at
            )
            extension_restarts = int(
                extension_restart_at is not None and index >= extension_restart_at
            )
            if code == "stale-frame-rejected":
                event_type = "frame"
                disposition = "stale-rejected"
                epoch = old_epoch
                generation = 10
            elif code == "fresh-frame-consumed":
                event_type = "frame"
                disposition = "fresh-consumed"
                epoch = old_epoch + 1
                generation = 11
            elif code == "fallback-observed":
                event_type = "lifecycle"
                disposition = "fallback"
                epoch = old_epoch
                generation = 10
            elif code.startswith("identity-"):
                event_type = "identity"
                disposition = "not-applicable"
                epoch = old_epoch
                generation = 10
            elif code in ("final-state-observed", "row-completed"):
                event_type = "final"
                disposition = "not-applicable"
                epoch = old_epoch + int(definition.requires_fresh_recovery)
                generation = 10 + int(definition.requires_fresh_recovery)
            else:
                event_type = (
                    "boundary"
                    if code in ("row-started", "action-boundary")
                    else "lifecycle"
                )
                disposition = "not-applicable"
                epoch = old_epoch
                generation = 10
            final_boundary = code in ("final-state-observed", "row-completed")
            events.append(
                {
                    "schema": EVENT_SCHEMA,
                    "matrix_id": matrix["matrix_id"],
                    "row_id": definition.row_id,
                    "row_run_id": run_id,
                    "event_index": index,
                    "captured_at_utc": timestamp(hour, index + 1),
                    "event_type": event_type,
                    "component": "orchestrator",
                    "producer_epoch": epoch,
                    "generation": generation,
                    "sequence": index,
                    "frame_disposition": disposition,
                    "active_lease_count": 0 if final_boundary else 1,
                    "capture_active": not final_boundary and disposition != "fallback",
                    "helper_restart_count": helper_restarts,
                    "extension_restart_count": extension_restarts,
                    "consumer_instance": (
                        "none" if final_boundary else "screen-saver:fixture"
                    ),
                    "detail_code": code,
                }
            )

        events_path = artifact_root / "typed-events.jsonl"
        events_path.write_text(
            "".join(
                json.dumps(event, separators=(",", ":")) + "\n" for event in events
            ),
            encoding="utf-8",
        )
        helper_pid = 4000 + definition.ordinal
        extension_pid = 5000 + definition.ordinal
        identity_before = artifact_root / "identity-before.json"
        save(
            identity_before,
            identity(
                matrix,
                definition.row_id,
                run_id,
                timestamp(hour, before_index + 1),
                helper_pid,
                [extension_pid],
            ),
        )
        if definition.row_id == "helper-crash-recovery":
            helper_pid += 100
        if definition.row_id == "extension-crash-recovery":
            extension_pid += 100
        identity_after = artifact_root / "identity-after.json"
        save(
            identity_after,
            identity(
                matrix,
                definition.row_id,
                run_id,
                timestamp(hour, after_index + 1),
                helper_pid,
                [extension_pid],
            ),
        )
        console_path = artifact_root / "console-state.json"
        save(
            console_path,
            {
                "schema": CONSOLE_STATE_SCHEMA,
                "matrix_id": matrix["matrix_id"],
                "row_id": definition.row_id,
                "row_run_id": run_id,
                "captured_at_utc": timestamp(hour, 0),
                "state": "unlocked",
                "source": "read-console-lock-state",
            },
        )
        final_state_path = artifact_root / "final-state.json"
        final_helper_restarts = int(definition.row_id == "helper-crash-recovery")
        final_extension_restarts = int(definition.row_id == "extension-crash-recovery")
        final_consumer = {"role": "none", "instance_id": "none", "reason_code": "none"}
        save(
            final_state_path,
            {
                "schema": FINAL_STATE_SCHEMA,
                "matrix_id": matrix["matrix_id"],
                "row_id": definition.row_id,
                "row_run_id": run_id,
                "captured_at_utc": timestamp(hour, final_index + 1),
                "active_lease_count": 0,
                "capture_active": False,
                "producer_state": "idle",
                "led_state": "off",
                "helper_restart_count": final_helper_restarts,
                "extension_restart_count": final_extension_restarts,
                "restart_loop_detected": False,
                "focus_theft": False,
                "stale_frame_presented": False,
                "final_consumer": final_consumer,
            },
        )
        attestation_path = artifact_root / "operator-attestation.json"
        save(
            attestation_path,
            {
                "schema": ATTESTATION_SCHEMA,
                "matrix_id": matrix["matrix_id"],
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
            },
        )

        row["status"] = "completed"
        row["row_run_id"] = run_id
        row["candidate"] = {
            key: value
            for key, value in candidate.items()  # type: ignore[union-attr]
            if key != "provenance_file"
        }
        row["authorization"] = {
            "id": authorization_id,
            "environment_variable": definition.authorization_environment_variable,
            "value": "YES",
            "granted_at_utc": timestamp(hour, 0),
            "action_class": definition.action_class,
            "row_only": True,
            "expires_after_row": True,
            "scope_statement": definition.scope_statement,
            "retained_consumer_authorized": False,
            "retained_consumer_role": "none",
            "retained_consumer_instance_id": "none",
        }
        row["console"] = {
            "requires_unlocked_start": definition.requires_unlocked_start,
            "state_at_start": "unlocked",
        }
        row["timing"] = {"started_at_utc": started, "completed_at_utc": completed}
        row["evidence"] = {
            key: {
                "path": path.relative_to(root).as_posix(),
                "sha256": digest(path),
            }
            for key, path in (
                ("typed_events", events_path),
                ("identity_before", identity_before),
                ("identity_after", identity_after),
                ("final_state", final_state_path),
                ("console_state", console_path),
                ("operator_attestation", attestation_path),
            )
        }
        row["observations"] = {
            "typed_event_count": len(events),
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
            "final_active_lease_count": 0,
            "final_capture_active": False,
            "final_consumer": final_consumer,
        }
        row["verdict"] = {"result": "passed", "rejection_reasons": []}
        save(row_path, row)


def copy_fixture(source: Path, destination: Path) -> Path:
    shutil.copytree(source, destination)
    return destination


def mutate_row(
    root: Path,
    ordinal: int,
    mutator: Callable[[dict[str, object], Path], None],
) -> None:
    path = root / ROWS[ordinal - 1].filename
    row = load(path)
    mutator(row, root)
    save(path, row)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="idlescreen-c8-offline-") as temporary:
        scratch = Path(temporary)
        candidate = scratch / "candidate-provenance.txt"
        candidate.write_text(
            "\n".join(
                (
                    "schema=IdleScreenReleaseArchiveProvenance/v1",
                    f"archive_tree_sha256={'a' * 64}",
                    "team_identifier=3524374A2S",
                    f"app_cdhash={'b' * 40}",
                    f"helper_cdhash={'c' * 40}",
                    f"extension_cdhash={'d' * 40}",
                )
            )
            + "\n",
            encoding="utf-8",
        )
        valid = scratch / "valid"
        run(
            str(PREPARER),
            str(valid),
            "--matrix-id",
            "matrix-c8-offline-valid",
            "--candidate-provenance",
            str(candidate),
        )
        pending = run(str(VERIFIER), str(valid / "matrix.json"), expected=1)
        if "not exact or completed" not in pending.stderr:
            fail("pending C8 templates were not rejected")

        console = scratch / "console.json"
        save(
            console,
            {
                "schema": PREFLIGHT_CONSOLE_STATE_SCHEMA,
                "captured_at_utc": datetime.now(timezone.utc)
                .isoformat()
                .replace("+00:00", "Z"),
                "state": "unlocked",
                "source": "read-console-lock-state",
            },
        )
        row = ROWS[0]
        authorized_environment = dict(os.environ)
        authorized_environment[row.authorization_environment_variable] = "YES"
        plan = scratch / "sleep-wake-plan.json"
        run(
            str(ROW_RUNNER),
            str(valid / "matrix.json"),
            row.row_id,
            "--authorization-id",
            "authorization-c8-plan",
            "--console-state-file",
            str(console),
            "--output-plan",
            str(plan),
            "--dry-run",
            environment=authorized_environment,
        )
        plan_value = load(plan)
        if (
            plan_value["physical_action_performed"] is not False
            or plan_value["executor"] != "unimplemented"
        ):
            fail("C8 row skeleton emitted an executable or physical plan")
        missing_opt_in = scratch / "missing-opt-in.json"
        run(
            str(ROW_RUNNER),
            str(valid / "matrix.json"),
            row.row_id,
            "--authorization-id",
            "authorization-c8-missing",
            "--console-state-file",
            str(console),
            "--output-plan",
            str(missing_opt_in),
            "--dry-run",
            expected=65,
            environment=dict(os.environ),
        )
        mixed_environment = dict(authorized_environment)
        mixed_environment[ROWS[1].authorization_environment_variable] = "YES"
        run(
            str(ROW_RUNNER),
            str(valid / "matrix.json"),
            row.row_id,
            "--authorization-id",
            "authorization-c8-mixed",
            "--console-state-file",
            str(console),
            "--output-plan",
            str(scratch / "mixed-plan.json"),
            "--dry-run",
            expected=65,
            environment=mixed_environment,
        )
        locked = scratch / "locked-console.json"
        save(
            locked,
            {
                "schema": PREFLIGHT_CONSOLE_STATE_SCHEMA,
                "captured_at_utc": datetime.now(timezone.utc)
                .isoformat()
                .replace("+00:00", "Z"),
                "state": "locked",
                "source": "read-console-lock-state",
            },
        )
        run(
            str(ROW_RUNNER),
            str(valid / "matrix.json"),
            row.row_id,
            "--authorization-id",
            "authorization-c8-locked",
            "--console-state-file",
            str(locked),
            "--output-plan",
            str(scratch / "locked-plan.json"),
            "--dry-run",
            expected=65,
            environment=authorized_environment,
        )
        crash_row = ROWS[14]
        crash_environment = dict(os.environ)
        crash_environment[crash_row.authorization_environment_variable] = "YES"
        run(
            str(ROW_RUNNER),
            str(valid / "matrix.json"),
            crash_row.row_id,
            "--authorization-id",
            "authorization-c8-locked-crash",
            "--console-state-file",
            str(locked),
            "--output-plan",
            str(scratch / "locked-crash-plan.json"),
            "--dry-run",
            environment=crash_environment,
        )

        complete_matrix(valid)
        verified = run(str(VERIFIER), str(valid / "matrix.json"))
        if "all 17" not in verified.stdout:
            fail("complete C8 matrix did not pass")

        candidate_drift = copy_fixture(valid, scratch / "candidate-drift")
        mutate_row(
            candidate_drift,
            1,
            lambda value, _: value["candidate"].update({"helper_cdhash": "e" * 40}),  # type: ignore[index]
        )
        run(str(VERIFIER), str(candidate_drift / "matrix.json"), expected=1)

        locked_start = copy_fixture(valid, scratch / "locked-start")

        def set_locked(value: dict[str, object], root: Path) -> None:
            value["console"]["state_at_start"] = "locked"  # type: ignore[index]
            artifact = root / value["evidence"]["console_state"]["path"]  # type: ignore[index]
            document = load(artifact)
            document["state"] = "locked"
            save(artifact, document)
            value["evidence"]["console_state"]["sha256"] = digest(artifact)  # type: ignore[index]

        mutate_row(locked_start, 1, set_locked)
        run(str(VERIFIER), str(locked_start / "matrix.json"), expected=1)

        stale_presented = copy_fixture(valid, scratch / "stale-presented")
        mutate_row(
            stale_presented,
            2,
            lambda value, _: value["observations"].update({"stale_frames_presented": True}),  # type: ignore[index]
        )
        run(str(VERIFIER), str(stale_presented / "matrix.json"), expected=1)

        identity_drift = copy_fixture(valid, scratch / "identity-drift")

        def drift_identity(value: dict[str, object], root: Path) -> None:
            artifact = root / value["evidence"]["identity_after"]["path"]  # type: ignore[index]
            document = load(artifact)
            document["extension_cdhash"] = "e" * 40
            save(artifact, document)
            value["evidence"]["identity_after"]["sha256"] = digest(artifact)  # type: ignore[index]

        mutate_row(identity_drift, 5, drift_identity)
        run(str(VERIFIER), str(identity_drift / "matrix.json"), expected=1)

        focus_theft = copy_fixture(valid, scratch / "focus-theft")
        mutate_row(
            focus_theft,
            14,
            lambda value, _: value["observations"].update({"focus_theft": True}),  # type: ignore[index]
        )
        run(str(VERIFIER), str(focus_theft / "matrix.json"), expected=1)

        lease_leak = copy_fixture(valid, scratch / "lease-leak")
        mutate_row(
            lease_leak,
            11,
            lambda value, _: value["observations"].update({"final_active_lease_count": 1}),  # type: ignore[index]
        )
        run(str(VERIFIER), str(lease_leak / "matrix.json"), expected=1)

        privacy_leak = copy_fixture(valid, scratch / "privacy-leak")
        mutate_row(
            privacy_leak,
            17,
            lambda value, _: value["observations"].update({"raw_frame_or_content_evidence": True}),  # type: ignore[index]
        )
        run(str(VERIFIER), str(privacy_leak / "matrix.json"), expected=1)

        restart_loop = copy_fixture(valid, scratch / "restart-loop")

        def add_restart(value: dict[str, object], root: Path) -> None:
            artifact = root / value["evidence"]["final_state"]["path"]  # type: ignore[index]
            document = load(artifact)
            document["helper_restart_count"] = 2
            save(artifact, document)
            value["evidence"]["final_state"]["sha256"] = digest(artifact)  # type: ignore[index]

        mutate_row(restart_loop, 15, add_restart)
        run(str(VERIFIER), str(restart_loop / "matrix.json"), expected=1)

        duplicate_authorization = copy_fixture(
            valid, scratch / "duplicate-authorization"
        )
        first = load(duplicate_authorization / ROWS[0].filename)
        mutate_row(
            duplicate_authorization,
            2,
            lambda value, _: value["authorization"].update(  # type: ignore[index]
                {"id": first["authorization"]["id"]}  # type: ignore[index]
            ),
        )
        run(str(VERIFIER), str(duplicate_authorization / "matrix.json"), expected=1)

    print(
        "PASS: C8 offline fixtures cover 17 same-candidate lifecycle classes, "
        "class-scoped opt-ins, lock refusal, typed privacy-safe evidence, stale "
        "fencing, stable identity, restart bounds, and final cleanup."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
