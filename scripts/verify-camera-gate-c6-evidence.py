#!/usr/bin/env python3
"""Offline, fail-closed verifier for completed C6 evidence."""

from __future__ import annotations

import sys
from pathlib import Path

from camera_gate_c6_schema import C6EvidenceError, verify_matrix


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"Usage: {argv[0]} /absolute/path/to/matrix.json", file=sys.stderr)
        return 64
    try:
        verified = verify_matrix(Path(argv[1]))
    except (C6EvidenceError, OSError, UnicodeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: C6 evidence contains eight distinct, completed, separately authorized, "
        "camera/TCC-free, unambiguous rows."
    )
    print(f"Candidate signal: {verified.candidate_verdict}")
    print(f"Matrix ID: {verified.matrix_id}")
    print(f"Matrix manifest SHA-256: {verified.matrix_manifest_sha256}")
    print(f"Evidence set SHA-256: {verified.evidence_set_sha256}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
