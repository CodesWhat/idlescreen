#!/usr/bin/env python3
"""Prepare an inert, camera-free eight-row C6 evidence workspace."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

from camera_gate_c6_schema import (
    MATRIX_SCHEMA,
    ROWS,
    ROW_SCHEMA,
    CDHASH_RE,
    ID_RE,
    C6EvidenceError,
    sha256,
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description=(
            "Prepare C6 evidence templates only. This command performs no Settings, "
            "chooser, saver, lock, sleep, display, camera, TCC, install, or registration action."
        )
    )
    result.add_argument("output_root", type=Path)
    result.add_argument("--matrix-id", required=True)
    result.add_argument("--candidate-provenance", required=True, type=Path)
    result.add_argument("--extension-cdhash", required=True)
    return result


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def prepare(args: argparse.Namespace) -> Path:
    output = args.output_root
    provenance = args.candidate_provenance
    matrix_id = args.matrix_id
    extension_cdhash = args.extension_cdhash
    if not output.is_absolute() or output.exists() or output.is_symlink():
        raise C6EvidenceError("output_root must be a new absolute path")
    if not output.parent.is_dir() or output.parent.is_symlink():
        raise C6EvidenceError("output_root parent must be an existing non-symlink directory")
    if not provenance.is_absolute() or provenance.is_symlink() or not provenance.is_file():
        raise C6EvidenceError("candidate provenance must be an absolute non-symlink regular file")
    if ID_RE.fullmatch(matrix_id) is None:
        raise C6EvidenceError("matrix-id must be 8-128 safe identifier characters")
    if CDHASH_RE.fullmatch(extension_cdhash) is None:
        raise C6EvidenceError("extension-cdhash must be one lowercase 40-character CDHash")

    provenance_hash = sha256(provenance)
    temporary = output.parent / f".{output.name}.preparing-{os.getpid()}"
    if temporary.exists() or temporary.is_symlink():
        raise C6EvidenceError("temporary preparation path already exists")
    try:
        (temporary / "rows").mkdir(parents=True, mode=0o700)
        (temporary / "artifacts").mkdir(mode=0o700)
        copied_provenance = temporary / "candidate-provenance.txt"
        shutil.copyfile(provenance, copied_provenance)
        if sha256(copied_provenance) != provenance_hash:
            raise C6EvidenceError("candidate provenance changed while it was copied")
        copied_provenance.chmod(0o400)

        row_references: list[dict[str, object]] = []
        for definition in ROWS:
            row_references.append({"row_id": definition.row_id, "path": definition.filename})
            checks = {name: None for name in definition.required_checks}
            row = {
                "schema": ROW_SCHEMA,
                "matrix_id": matrix_id,
                "row_id": definition.row_id,
                "ordinal": definition.ordinal,
                "scenario": definition.scenario,
                "status": "pending",
                "row_run_id": None,
                "candidate": {
                    "provenance_sha256": provenance_hash,
                    "extension_cdhash": extension_cdhash,
                },
                "required_authorization_actions": list(definition.required_actions),
                "authorization": {
                    "id": None,
                    "granted_at_utc": None,
                    "actions": [],
                    "row_only": True,
                    "expires_after_row": True,
                    "scope_statement": definition.authorization_statement,
                },
                "timing": {"started_at_utc": None, "completed_at_utc": None},
                "evidence": {
                    "host_log": {"path": None, "sha256": None},
                    "operator_attestation": {"path": None, "sha256": None},
                },
                "observations": {
                    "host_activity_states": [],
                    "checks": checks,
                    "activation_expected": definition.activation_expected,
                    "activation_observed": None,
                    "teardown_observed": None,
                    "chooser_false_positive": None,
                    "genuine_activation_false_negative": None,
                    "stale_or_ambiguous_state": None,
                    "unexpected_prompt": None,
                    "focus_theft": None,
                    "loop_or_crash": None,
                    "camera_opened": None,
                    "tcc_action": None,
                    "raw_frame_or_content_evidence": None,
                },
                "interpretation": {
                    "verdict": None,
                    "unambiguous": None,
                    "rejection_reasons": [],
                },
            }
            write_json(temporary / definition.filename, row)

        matrix = {
            "schema": MATRIX_SCHEMA,
            "matrix_id": matrix_id,
            "candidate": {
                "provenance_file": "candidate-provenance.txt",
                "provenance_sha256": provenance_hash,
                "extension_cdhash": extension_cdhash,
            },
            "physical_boundary": {
                "camera": "prohibited",
                "tcc": "prohibited",
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
    except (C6EvidenceError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PREPARED: eight pending C6 rows; no physical action was performed.")
    print(f"Evidence: {manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
