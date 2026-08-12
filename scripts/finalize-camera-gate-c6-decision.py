#!/usr/bin/env python3
"""Generate the C6 shipping-policy decision only from verified matrix evidence."""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from camera_gate_c6_schema import C6EvidenceError, POLICIES, verify_matrix


def one_line(value: str, label: str) -> str:
    normalized = value.strip()
    if not normalized or "\n" in normalized or "\r" in normalized:
        raise C6EvidenceError(f"{label} must be one nonempty line")
    return normalized


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Verify all C6 rows, then generate one immutable shipping-policy decision record."
    )
    result.add_argument("matrix_manifest", type=Path)
    result.add_argument("output", type=Path)
    result.add_argument("--policy", choices=POLICIES, required=True)
    result.add_argument("--capability-name", required=True)
    result.add_argument("--privacy-limitations", required=True)
    result.add_argument("--energy-limitations", required=True)
    result.add_argument("--rationale", required=True)
    return result


def generate(args: argparse.Namespace) -> Path:
    verified = verify_matrix(args.matrix_manifest)
    output = args.output
    if not output.is_absolute() or output.exists() or output.is_symlink():
        raise C6EvidenceError("decision output must be a new absolute path")
    if not output.parent.is_dir() or output.parent.is_symlink():
        raise C6EvidenceError("decision output parent must be an existing non-symlink directory")
    capability = one_line(args.capability_name, "capability-name")
    privacy = one_line(args.privacy_limitations, "privacy-limitations")
    energy = one_line(args.energy_limitations, "energy-limitations")
    rationale = one_line(args.rationale, "rationale")
    if args.policy == "trustworthy-activation-capability" and verified.candidate_verdict != "accepted":
        raise C6EvidenceError(
            "trustworthy activation capability is forbidden because at least one row rejected the signal"
        )
    if args.policy != "trustworthy-activation-capability" and capability.lower() in (
        "none",
        "n/a",
        "na",
    ):
        capability = "No trustworthy per-activation capability selected"

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rows = []
    for row in verified.rows:
        reasons = ", ".join(row.rejection_reasons) if row.rejection_reasons else "none"
        rows.append(
            f"| {row.definition.ordinal} | `{row.definition.row_id}` | "
            f"{row.verdict} | {reasons} | `{row.authorization_id}` | `{row.row_run_id}` |"
        )
    decision = f"""# IdleScreen C6 activation-provenance decision

- Generated at UTC: `{generated_at}`
- Matrix ID: `{verified.matrix_id}`
- Matrix manifest SHA-256: `{verified.matrix_manifest_sha256}`
- Complete evidence-set SHA-256: `{verified.evidence_set_sha256}`
- Candidate provenance SHA-256: `{verified.candidate_provenance_sha256}`
- Candidate extension CDHash: `{verified.extension_cdhash}`
- Candidate signal verdict: **{verified.candidate_verdict}**
- Shipping policy: **{args.policy}**
- Capability: {capability}

## Decision

{rationale}

## Privacy limitations

{privacy}

## Energy limitations

{energy}

## Matrix rows

| # | Row | Candidate result | Rejection reasons | Row-only authorization | Run ID |
| ---: | --- | --- | --- | --- | --- |
{os.linesep.join(rows)}

## Binding and scope

This record was generated only after the offline verifier accepted all eight
distinct, completed, separately authorized, camera/TCC-free, unambiguous C6
rows. The matrix is camera-free activation-provenance evidence. It is not A1T
transport evidence, camera/TCC evidence, or authorization to promote, install,
register, activate, lock, sleep, change displays, or open Settings again.
"""
    temporary = output.parent / f".{output.name}.writing-{os.getpid()}"
    if temporary.exists() or temporary.is_symlink():
        raise C6EvidenceError("temporary decision path already exists")
    try:
        temporary.write_text(decision, encoding="utf-8")
        temporary.rename(output)
    except BaseException:
        if temporary.exists() and not temporary.is_symlink():
            temporary.unlink()
        raise
    return output


def main() -> int:
    try:
        output = generate(parser().parse_args())
    except (C6EvidenceError, OSError, UnicodeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: finalized the C6 shipping-policy decision from verified camera-free evidence.")
    print(f"Decision: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
