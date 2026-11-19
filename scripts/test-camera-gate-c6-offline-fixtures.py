#!/usr/bin/env python3
"""Offline-only fixtures for the implemented C6 evidence/finalization contract."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parent
PREPARER = SCRIPT_ROOT / "prepare-camera-gate-c6-evidence.py"
VERIFIER = SCRIPT_ROOT / "verify-camera-gate-c6-evidence.py"
FINALIZER = SCRIPT_ROOT / "finalize-camera-gate-c6-decision.py"


def fail(message: str) -> None:
    raise RuntimeError(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def run(*arguments: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [sys.executable, *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != expected:
        fail(
            f"expected {expected}, got {result.returncode}: {' '.join(arguments)}\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )
    return result


def complete_supported_matrix(root: Path) -> None:
    matrix = load(root / "matrix.json")
    matrix_id = str(matrix["matrix_id"])
    for reference in matrix["rows"]:  # type: ignore[union-attr]
        row_path = root / reference["path"]
        row = load(row_path)
        ordinal = int(row["ordinal"])
        row_id = str(row["row_id"])
        run_id = f"run-{ordinal:02d}-{row_id}"
        authorization_id = f"authorization-{ordinal:02d}-{row_id}"
        active_expected = bool(row["observations"]["activation_expected"])  # type: ignore[index]
        states = ["inactive"] if not active_expected else ["inactive", "running-foreground", "inactive"]
        log_path = root / "artifacts" / f"{ordinal:02d}-{row_id}-host.log"
        lines = [f"C6 row marker row_id={row_id} run_id={run_id}"]
        for index, state in enumerate(states):
            lines.append(
                f"2026-08-01 22:{ordinal:02d}:{index:02d}.000 I IdleScreenScreenSaver["
                f"{4000 + ordinal}:abc] [com.idlescreen.screensaver:View] "
                f"Global host activity state={state} source=animation-frame "
                "changed=true cameraDemand=false"
            )
        log_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

        attestation_path = root / "artifacts" / f"{ordinal:02d}-{row_id}-operator.txt"
        attestation_path.write_text(
            "\n".join(
                (
                    "schema=IdleScreenC6OperatorAttestation/v1",
                    f"matrix_id={matrix_id}",
                    f"row_id={row_id}",
                    f"row_run_id={run_id}",
                    "camera_opened=false",
                    "tcc_action=false",
                    "raw_frame_or_content_evidence=false",
                    "unexpected_prompt=false",
                    "focus_theft=false",
                    "loop_or_crash=false",
                    "interpretation_unambiguous=true",
                )
            )
            + "\n",
            encoding="utf-8",
        )

        row["status"] = "completed"
        row["row_run_id"] = run_id
        row["authorization"]["id"] = authorization_id  # type: ignore[index]
        row["authorization"]["granted_at_utc"] = f"2026-08-01T21:{ordinal:02d}:00Z"  # type: ignore[index]
        row["authorization"]["actions"] = row["required_authorization_actions"]  # type: ignore[index]
        row["timing"]["started_at_utc"] = f"2026-08-01T22:{ordinal:02d}:00Z"  # type: ignore[index]
        row["timing"]["completed_at_utc"] = f"2026-08-01T22:{ordinal:02d}:30Z"  # type: ignore[index]
        row["evidence"]["host_log"] = {  # type: ignore[index]
            "path": log_path.relative_to(root).as_posix(),
            "sha256": digest(log_path),
        }
        row["evidence"]["operator_attestation"] = {  # type: ignore[index]
            "path": attestation_path.relative_to(root).as_posix(),
            "sha256": digest(attestation_path),
        }
        observations = row["observations"]
        observations["host_activity_states"] = states  # type: ignore[index]
        for check_name in observations["checks"]:  # type: ignore[index]
            observations["checks"][check_name] = True  # type: ignore[index]
        observations["activation_observed"] = active_expected  # type: ignore[index]
        observations["teardown_observed"] = active_expected  # type: ignore[index]
        for key in (
            "chooser_false_positive",
            "genuine_activation_false_negative",
            "stale_or_ambiguous_state",
            "unexpected_prompt",
            "focus_theft",
            "loop_or_crash",
            "camera_opened",
            "tcc_action",
            "raw_frame_or_content_evidence",
        ):
            observations[key] = False  # type: ignore[index]
        row["interpretation"] = {  # type: ignore[index]
            "verdict": "candidate-supported",
            "unambiguous": True,
            "rejection_reasons": [],
        }
        save(row_path, row)


def mutate_row(root: Path, ordinal: int, mutator: object) -> Path:
    matrix = load(root / "matrix.json")
    reference = matrix["rows"][ordinal - 1]  # type: ignore[index]
    path = root / reference["path"]
    row = load(path)
    mutator(row, root)  # type: ignore[operator]
    save(path, row)
    return path


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="idlescreen-c6-offline-") as temporary:
        fixture_root = Path(temporary)
        candidate = fixture_root / "candidate-provenance.txt"
        candidate.write_text(
            "schema=IdleScreenReleaseArchiveProvenance/v1\narchive_tree_sha256="
            + "a" * 64
            + "\n",
            encoding="utf-8",
        )
        valid = fixture_root / "valid"
        run(
            str(PREPARER),
            str(valid),
            "--matrix-id",
            "matrix-offline-valid",
            "--candidate-provenance",
            str(candidate),
            "--extension-cdhash",
            "b" * 40,
        )

        pending = run(str(VERIFIER), str(valid / "matrix.json"), expected=1)
        if "not completed" not in pending.stderr:
            fail("pending templates were not rejected as incomplete")
        complete_supported_matrix(valid)
        verified = run(str(VERIFIER), str(valid / "matrix.json"))
        if "eight distinct" not in verified.stdout or "Candidate signal: accepted" not in verified.stdout:
            fail("valid matrix did not report its complete accepted verdict")
        run(
            str(FINALIZER),
            str(valid / "matrix.json"),
            str(fixture_root / "trusted-decision.md"),
            "--policy",
            "trustworthy-activation-capability",
            "--capability-name",
            "Global host activity",
            "--privacy-limitations",
            "The capability authorizes demand only while genuine saver activation remains proven.",
            "--energy-limitations",
            "No prewarm is selected; helper idle cost remains outside this C6 proof.",
            "--rationale",
            "All eight exact candidate rows supported the signal without an adverse condition.",
        )

        def invalid_copy(name: str) -> Path:
            destination = fixture_root / name
            shutil.copytree(valid, destination)
            return destination

        missing = invalid_copy("missing-row")
        (missing / "rows" / "08-chooser-active-coexistence.json").unlink()
        run(str(VERIFIER), str(missing / "matrix.json"), expected=1)

        duplicate_authorization = invalid_copy("duplicate-authorization")
        first = load(duplicate_authorization / "rows" / "01-chooser-only.json")
        mutate_row(
            duplicate_authorization,
            2,
            lambda row, _: row["authorization"].update(  # type: ignore[index]
                {"id": first["authorization"]["id"]}  # type: ignore[index]
            ),
        )
        run(str(VERIFIER), str(duplicate_authorization / "matrix.json"), expected=1)

        wrong_scope = invalid_copy("wrong-scope")
        mutate_row(
            wrong_scope,
            6,
            lambda row, _: row["authorization"].update({"actions": ["activation"]}),  # type: ignore[index]
        )
        run(str(VERIFIER), str(wrong_scope / "matrix.json"), expected=1)

        ambiguous = invalid_copy("ambiguous")
        def make_ambiguous(row: dict[str, object], root: Path) -> None:
            row["interpretation"]["unambiguous"] = False  # type: ignore[index]
            attestation = root / row["evidence"]["operator_attestation"]["path"]  # type: ignore[index]
            attestation.write_text(
                attestation.read_text(encoding="utf-8").replace(
                    "interpretation_unambiguous=true",
                    "interpretation_unambiguous=false",
                ),
                encoding="utf-8",
            )
            row["evidence"]["operator_attestation"]["sha256"] = digest(attestation)  # type: ignore[index]
        mutate_row(ambiguous, 4, make_ambiguous)
        run(str(VERIFIER), str(ambiguous / "matrix.json"), expected=1)

        camera = invalid_copy("camera-crossing")
        mutate_row(
            camera,
            3,
            lambda row, _: row["observations"].update({"camera_opened": True}),  # type: ignore[index]
        )
        run(str(VERIFIER), str(camera / "matrix.json"), expected=1)

        camera_demand = invalid_copy("camera-demand")

        def enable_camera_demand(row: dict[str, object], root: Path) -> None:
            host_log = root / row["evidence"]["host_log"]["path"]  # type: ignore[index]
            host_log.write_text(
                host_log.read_text(encoding="utf-8").replace(
                    "cameraDemand=false",
                    "cameraDemand=true",
                ),
                encoding="utf-8",
            )
            row["evidence"]["host_log"]["sha256"] = digest(host_log)  # type: ignore[index]

        mutate_row(camera_demand, 3, enable_camera_demand)
        demanded = run(str(VERIFIER), str(camera_demand / "matrix.json"), expected=1)
        if "cameraDemand=false" not in demanded.stderr:
            fail("camera-demand evidence was rejected without explaining the C6 boundary")

        duplicate_log = invalid_copy("duplicate-log")
        first_log = duplicate_log / "artifacts" / "01-chooser-only-host.log"
        second_log = duplicate_log / "artifacts" / "02-manual-fullscreen-host.log"
        second_log.write_bytes(first_log.read_bytes())
        mutate_row(
            duplicate_log,
            2,
            lambda row, _: row["evidence"]["host_log"].update({"sha256": digest(second_log)}),  # type: ignore[index]
        )
        run(str(VERIFIER), str(duplicate_log / "matrix.json"), expected=1)

        rejected = invalid_copy("candidate-rejected")
        def reject_manual(row: dict[str, object], root: Path) -> None:
            row_id = str(row["row_id"])
            host_log = root / row["evidence"]["host_log"]["path"]  # type: ignore[index]
            host_log.write_text(
                f"C6 rejected marker row_id={row_id}\n"
                "2026-08-01 22:02:00.000 I IdleScreenScreenSaver[4002:abc] "
                "[com.idlescreen.screensaver:View] Global host activity state=inactive "
                "source=animation-frame changed=true cameraDemand=false\n",
                encoding="utf-8",
            )
            row["evidence"]["host_log"]["sha256"] = digest(host_log)  # type: ignore[index]
            observations = row["observations"]
            observations["host_activity_states"] = ["inactive"]  # type: ignore[index]
            observations["checks"]["active-running-foreground"] = False  # type: ignore[index]
            observations["activation_observed"] = False  # type: ignore[index]
            observations["genuine_activation_false_negative"] = True  # type: ignore[index]
            row["interpretation"] = {  # type: ignore[index]
                "verdict": "candidate-rejected",
                "unambiguous": True,
                "rejection_reasons": [
                    "genuine-activation-false-negative",
                    "scenario-check-failed",
                ],
            }
        mutate_row(rejected, 2, reject_manual)
        rejected_result = run(str(VERIFIER), str(rejected / "matrix.json"))
        if "Candidate signal: rejected" not in rejected_result.stdout:
            fail("unambiguous candidate rejection did not preserve a valid completed matrix")
        run(
            str(FINALIZER),
            str(rejected / "matrix.json"),
            str(fixture_root / "forbidden-trusted-decision.md"),
            "--policy",
            "trustworthy-activation-capability",
            "--capability-name",
            "Global host activity",
            "--privacy-limitations",
            "Signal rejected.",
            "--energy-limitations",
            "Signal rejected.",
            "--rationale",
            "This must fail.",
            expected=1,
        )
        run(
            str(FINALIZER),
            str(rejected / "matrix.json"),
            str(fixture_root / "fallback-decision.md"),
            "--policy",
            "camera-disabled-saver-fallback",
            "--capability-name",
            "none",
            "--privacy-limitations",
            "Camera sources remain disabled in the hosted saver.",
            "--energy-limitations",
            "No saver camera prewarm or continuation energy is incurred.",
            "--rationale",
            "The candidate produced a genuine-activation false negative.",
        )

    print(
        "PASS: offline C6 fixtures enforce eight rows, exact row-only authorization, "
        "distinct evidence, camera/TCC/camera-demand prohibition, unambiguous interpretation, "
        "and policy gating."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
