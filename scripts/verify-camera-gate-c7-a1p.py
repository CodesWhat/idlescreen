#!/usr/bin/env python3
"""Offline verifier for C7's camera-free A1P promoted-candidate binding."""

from __future__ import annotations

import sys
from pathlib import Path

from camera_gate_c7_schema import C7EvidenceError, verify_a1p


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"Usage: {argv[0]} /absolute/path/to/c7-a1p.json", file=sys.stderr)
        return 64
    try:
        evidence = verify_a1p(Path(argv[1]))
    except (C7EvidenceError, OSError, UnicodeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: A1P binds one verified C6 policy to a new exact production candidate, "
        "separate install/registration authorization, exact runtime identity, and zero camera demand."
    )
    print(f"Policy: {evidence.decision.policy}")
    print(f"Archive tree SHA-256: {evidence.archive_tree_sha256}")
    print(f"A1P manifest SHA-256: {evidence.manifest_sha256}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
