#!/usr/bin/env python3
"""Generate one C7 Swift input only from an exact verified C6 decision hash."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from camera_gate_c7_schema import C7EvidenceError, verify_c6_decision


SWIFT_CASES = {
    "trustworthy-activation-capability": "trustworthyActivationCapability",
    "disclosed-prewarm-continuation": "disclosedPrewarmContinuation",
    "camera-disabled-saver-fallback": "cameraDisabledSaverFallback",
}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Replay C6 and generate a hash-bound C7 shipping-policy Swift input."
    )
    result.add_argument("matrix", type=Path)
    result.add_argument("decision", type=Path)
    result.add_argument("output", type=Path)
    result.add_argument("--expected-decision-sha256", required=True)
    return result


def generate(args: argparse.Namespace) -> Path:
    verified = verify_c6_decision(
        args.matrix,
        args.decision,
        args.expected_decision_sha256,
    )
    output = args.output
    if not output.is_absolute() or output.exists() or output.is_symlink():
        raise C7EvidenceError("generated policy output must be a new absolute path")
    if not output.parent.is_dir() or output.parent.is_symlink():
        raise C7EvidenceError("generated policy parent must be an existing non-symlink directory")
    swift_case = SWIFT_CASES[verified.policy]
    payload = f"""// schema=IdleScreenC7GeneratedActivationDecision/v1
// c6-decision-sha256={verified.sha256}
// c6-evidence-set-sha256={verified.evidence_set_sha256}
// policy={verified.policy}
// Generated only after replaying the complete C6 matrix. Do not hand-edit.

public enum IdleScreenC7GeneratedActivationDecision {{
    public static let input = IdleScreenSaverActivationDecisionInput(
        policy: .{swift_case},
        c6DecisionSHA256: "{verified.sha256}",
        c6EvidenceSetSHA256: "{verified.evidence_set_sha256}",
        generatedFromVerifiedC6Decision: true
    )
}}
"""
    temporary = output.parent / f".{output.name}.writing-{os.getpid()}"
    if temporary.exists() or temporary.is_symlink():
        raise C7EvidenceError("temporary generated-policy path already exists")
    try:
        temporary.write_text(payload, encoding="utf-8")
        temporary.rename(output)
    except BaseException:
        if temporary.exists() and not temporary.is_symlink():
            temporary.unlink()
        raise
    return output


def main() -> int:
    try:
        output = generate(parser().parse_args())
    except (C7EvidenceError, OSError, UnicodeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: generated a C7 policy input from the exact verified C6 decision hash.")
    print(f"Generated: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
