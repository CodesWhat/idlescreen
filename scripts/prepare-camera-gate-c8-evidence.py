#!/usr/bin/env python3
"""Prepare an inert C8 lifecycle evidence workspace; perform no lifecycle row."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

from camera_gate_c8_schema import (
    MATRIX_SCHEMA,
    ROWS,
    ROW_SCHEMA,
    C8EvidenceError,
    ID_RE,
    parse_candidate_provenance,
    sha256,
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description=(
            "Prepare typed C8 templates only. This command never sleeps, reboots, logs "
            "out, changes Background Items, replaces an app, changes TCC, opens a camera, "
            "changes a device/display/user/Space, terminates a process, or starts a soak."
        )
    )
    result.add_argument("output_root", type=Path)
    result.add_argument("--matrix-id", required=True)
    result.add_argument("--candidate-provenance", required=True, type=Path)
    return result


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)


def prepare(args: argparse.Namespace) -> Path:
    output: Path = args.output_root
    provenance: Path = args.candidate_provenance
    matrix_id: str = args.matrix_id
    if not output.is_absolute() or output == Path("/") or os.path.lexists(output):
        raise C8EvidenceError("output_root must be a new, distinct absolute path")
    if not output.parent.is_dir() or output.parent.is_symlink():
        raise C8EvidenceError(
            "output_root parent must be an existing non-symlink directory"
        )
    if (
        not provenance.is_absolute()
        or provenance.is_symlink()
        or not provenance.is_file()
    ):
        raise C8EvidenceError(
            "candidate provenance must be an absolute non-symlink regular file"
        )
    if ID_RE.fullmatch(matrix_id) is None:
        raise C8EvidenceError("matrix-id must be 8-128 safe identifier characters")
    candidate_tuple = parse_candidate_provenance(provenance)
    provenance_hash = sha256(provenance)

    temporary = output.parent / f".{output.name}.preparing-{os.getpid()}"
    if os.path.lexists(temporary):
        raise C8EvidenceError("temporary C8 preparation path already exists")
    try:
        (temporary / "rows").mkdir(parents=True, mode=0o700)
        (temporary / "artifacts").mkdir(mode=0o700)
        copied_provenance = temporary / "candidate-provenance.txt"
        shutil.copyfile(provenance, copied_provenance)
        copied_provenance.chmod(0o600)
        if sha256(copied_provenance) != provenance_hash:
            raise C8EvidenceError("candidate provenance changed while it was copied")

        matrix_candidate = {
            "provenance_file": "candidate-provenance.txt",
            "provenance_sha256": provenance_hash,
            **candidate_tuple,
        }
        row_candidate = {
            key: value
            for key, value in matrix_candidate.items()
            if key != "provenance_file"
        }
        row_references: list[dict[str, object]] = []
        for definition in ROWS:
            row_references.append(
                {
                    "row_id": definition.row_id,
                    "path": definition.filename,
                    "authorization_environment_variable": (
                        definition.authorization_environment_variable
                    ),
                    "requires_unlocked_start": definition.requires_unlocked_start,
                }
            )
            row = {
                "schema": ROW_SCHEMA,
                "matrix_id": matrix_id,
                "row_id": definition.row_id,
                "ordinal": definition.ordinal,
                "scenario": definition.scenario,
                "status": "pending",
                "row_run_id": None,
                "candidate": row_candidate,
                "action_class": definition.action_class,
                "authorization": {
                    "id": None,
                    "environment_variable": definition.authorization_environment_variable,
                    "value": None,
                    "granted_at_utc": None,
                    "action_class": definition.action_class,
                    "row_only": True,
                    "expires_after_row": True,
                    "scope_statement": definition.scope_statement,
                    "retained_consumer_authorized": False,
                    "retained_consumer_role": "none",
                    "retained_consumer_instance_id": "none",
                },
                "console": {
                    "requires_unlocked_start": definition.requires_unlocked_start,
                    "state_at_start": None,
                },
                "timing": {"started_at_utc": None, "completed_at_utc": None},
                "evidence": {
                    "typed_events": {"path": None, "sha256": None},
                    "identity_before": {"path": None, "sha256": None},
                    "identity_after": {"path": None, "sha256": None},
                    "final_state": {"path": None, "sha256": None},
                    "console_state": {"path": None, "sha256": None},
                    "operator_attestation": {"path": None, "sha256": None},
                },
                "observations": {
                    "typed_event_count": None,
                    "stale_frames_rejected": None,
                    "stale_frames_presented": None,
                    "restart_loop_detected": None,
                    "focus_theft": None,
                    "identity_changed": None,
                    "raw_frame_or_content_evidence": None,
                    "pixel_data_recorded": None,
                    "biometric_data_recorded": None,
                    "device_serial_recorded": None,
                    "unredacted_username_recorded": None,
                    "final_active_lease_count": None,
                    "final_capture_active": None,
                    "final_consumer": {
                        "role": "none",
                        "instance_id": "none",
                        "reason_code": "none",
                    },
                },
                "verdict": {"result": None, "rejection_reasons": []},
            }
            write_json(temporary / definition.filename, row)

        matrix = {
            "schema": MATRIX_SCHEMA,
            "matrix_id": matrix_id,
            "candidate": matrix_candidate,
            "physical_boundary": {
                "preparation_performs_physical_actions": False,
                "row_execution_implemented": False,
                "per_class_authorization_required": True,
                "raw_frame_or_content_evidence": "prohibited",
            },
            "row_count": len(ROWS),
            "rows": row_references,
        }
        write_json(temporary / "matrix.json", matrix)
        temporary.rename(output)
    except BaseException:
        if temporary.exists() and not temporary.is_symlink():
            shutil.rmtree(temporary)
        raise
    return output / "matrix.json"


def main() -> int:
    try:
        manifest = prepare(parser().parse_args())
    except (C8EvidenceError, OSError, UnicodeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PREPARED: {len(ROWS)} pending C8 rows; no physical action was performed.")
    print(f"Evidence: {manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
