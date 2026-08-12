#!/usr/bin/env python3
"""Plan A2-A6R applicability from one verified A1P policy promotion."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from camera_gate_c7_schema import C7EvidenceError, verify_a1p


ROW_PLANS = {
    "trustworthy-activation-capability": (
        ("A2", "conditional", "Run only if the registered helper is naturally absent; never manufacture a cold state."),
        ("A3", "required", "Prove stopped-agent demand start under the verified activation capability."),
        ("A4", "not-required-by-selected-policy", "Warm-continuation is not the selected shipping rule."),
        ("A5", "not-required-by-selected-policy", "Companion handoff depends on the unselected warm-continuation row."),
        ("A6", "required", "Prove post-unlock teardown after the applicable locked saver row."),
        ("A6R", "required", "Prove post-unlock companion restart remains healthy."),
    ),
    "disclosed-prewarm-continuation": (
        ("A2", "not-required-by-selected-policy", "The selected policy does not demand-start a stopped producer."),
        ("A3", "not-required-by-selected-policy", "The selected policy requires an already warm producer."),
        ("A4", "required", "Prove disclosed warm capture continues across lock."),
        ("A5", "required", "Prove saver demand survives companion handoff."),
        ("A6", "required", "Prove post-unlock final-lease teardown."),
        ("A6R", "required", "Prove post-unlock companion restart remains healthy."),
    ),
    "camera-disabled-saver-fallback": tuple(
        (row, "N/A", "Verified C6 policy disables hosted-saver camera demand.")
        for row in ("A2", "A3", "A4", "A5", "A6", "A6R")
    ),
}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Generate a non-authorizing A2-A6R applicability plan from verified A1P evidence."
    )
    result.add_argument("a1p_manifest", type=Path)
    result.add_argument("output", type=Path)
    return result


def generate(args: argparse.Namespace) -> Path:
    a1p = verify_a1p(args.a1p_manifest)
    output = args.output
    if not output.is_absolute() or output.exists() or output.is_symlink():
        raise C7EvidenceError("applicability output must be a new absolute path")
    if not output.parent.is_dir() or output.parent.is_symlink():
        raise C7EvidenceError("applicability output parent must be an existing non-symlink directory")
    rows = [
        {"row": row, "applicability": applicability, "reason": reason}
        for row, applicability, reason in ROW_PLANS[a1p.decision.policy]
    ]
    if any(row["applicability"] == "N/A" for row in rows) and a1p.decision.policy != "camera-disabled-saver-fallback":
        raise C7EvidenceError("only a verified camera-disabled fallback may mark a row N/A")
    payload = {
        "schema": "IdleScreenC7A2A6RApplicability/v1",
        "authorization": "none",
        "a1p_manifest_sha256": a1p.manifest_sha256,
        "candidate_archive_tree_sha256": a1p.archive_tree_sha256,
        "c6_decision_sha256": a1p.decision.sha256,
        "policy": a1p.decision.policy,
        "rows": rows,
    }
    temporary = output.parent / f".{output.name}.writing-{os.getpid()}"
    if temporary.exists() or temporary.is_symlink():
        raise C7EvidenceError("temporary applicability path already exists")
    try:
        temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
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
    print("PASS: generated a non-authorizing A2-A6R applicability plan from verified A1P evidence.")
    print(f"Plan: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
