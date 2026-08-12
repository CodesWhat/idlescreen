#!/usr/bin/env python3
"""Offline, fail-closed verifier for a complete C8 lifecycle matrix."""

from __future__ import annotations

import sys
from pathlib import Path

from camera_gate_c8_schema import C8EvidenceError, verify_matrix


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"Usage: {argv[0]} /absolute/path/to/C8/matrix.json", file=sys.stderr)
        return 64
    try:
        verified = verify_matrix(Path(argv[1]))
    except (C8EvidenceError, OSError, UnicodeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: all 17 C8 lifecycle classes bind one signed candidate, typed "
        "privacy-safe evidence, stale-frame rejection, stable identity, bounded "
        "recovery, no focus/restart loop, and authorized final cleanup."
    )
    print(f"Matrix ID: {verified.definition.matrix_id}")
    print(f"Matrix manifest SHA-256: {verified.matrix_manifest_sha256}")
    print(f"Evidence set SHA-256: {verified.evidence_set_sha256}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
