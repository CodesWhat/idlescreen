#!/usr/bin/env python3
"""Equivalent C3 provenance manifests get equivalent verdicts from C4, C5 and C7."""

from __future__ import annotations

import hashlib
import importlib.util
import sys
import tempfile
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))

import camera_gate_c7_schema  # noqa: E402
import camera_gate_evidence_common as common  # noqa: E402


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


c4 = load("c4_verifier", "verify-camera-gate-c4-evidence.py")
c5 = load("c5_verifier", "verify-camera-gate-c5-evidence.py")

SHA = "a" * 64
CDHASH = "b" * 40
UUIDS = {
    "app": "11111111-1111-4111-8111-111111111111",
    "extension": "22222222-2222-4222-8222-222222222222",
    "helper": "33333333-3333-4333-8333-333333333333",
}


def valid_records() -> List[Tuple[str, str]]:
    records: List[Tuple[str, str]] = []
    for key in common.C3_FIELDS:
        if key in common.C3_EXPECTED_IDENTITY:
            value = common.C3_EXPECTED_IDENTITY[key]
        elif key.endswith("_sha256"):
            value = SHA
        elif key.endswith("_cdhash"):
            value = CDHASH
        elif key.endswith("_profile_uuid"):
            value = UUIDS[key.split("_", 1)[0]]
        elif key.endswith("_profile_expiration"):
            value = "2027-08-01T00:00:00Z"
        else:
            raise AssertionError(key)
        records.append((key, value))
    return records


def render(records: List[Tuple[str, str]]) -> str:
    return "".join(f"{key}={value}\n" for key, value in records)


def replace(records, key, value):
    return [(k, value if k == key else v) for k, v in records]


def mutations() -> Dict[str, Tuple[bool, str]]:
    base = valid_records()
    cases: Dict[str, Tuple[bool, str]] = {"valid": (True, render(base))}
    cases["uppercase-cdhash"] = (True, render(replace(base, "app_cdhash", "B" * 40)))
    cases["missing-field"] = (False, render([r for r in base if r[0] != "helper_cdhash"]))
    cases["duplicate-field"] = (False, render(base + [base[0]]))
    swapped = list(base)
    swapped[0], swapped[1] = swapped[1], swapped[0]
    cases["reordered-fields"] = (False, render(swapped))
    cases["unexpected-field"] = (False, render(base + [("extra", "x")]))
    cases["empty-value"] = (False, render(replace(base, "app_cdhash", "")))
    cases["no-equals-line"] = (False, render(base) + "garbage\n")
    cases["blank-line"] = (False, render(base) + "\n")
    cases["control-character"] = (False, render(replace(base, "app_group", "group\tx")))
    cases["wrong-team"] = (False, render(replace(base, "team_identifier", "ZZZZZZZZZZ")))
    cases["wrong-schema"] = (False, render(replace(base, "schema", "Other/v1")))
    cases["wrong-bundle-id"] = (False, render(replace(base, "helper_bundle_identifier", "x.y")))
    for key in ("archive_tree_sha256", "app_profile_sha256", "helper_entitlements_sha256"):
        cases[f"uppercase-{key}"] = (False, render(replace(base, key, "A" * 64)))
        cases[f"short-{key}"] = (False, render(replace(base, key, "a" * 63)))
    for key in ("app_cdhash", "helper_cdhash", "extension_cdhash"):
        cases[f"short-{key}"] = (False, render(replace(base, key, "b" * 39)))
        cases[f"nonhex-{key}"] = (False, render(replace(base, key, "g" * 40)))
    for kind in ("app", "extension", "helper"):
        key = f"{kind}_profile_uuid"
        cases[f"placeholder-{key}"] = (False, render(replace(base, key, f"{kind}-profile")))
        cases[f"dashes-only-{key}"] = (False, render(replace(base, key, "-" * 36)))
        key = f"{kind}_profile_expiration"
        cases[f"bad-{key}"] = (False, render(replace(base, key, "next year")))
    return cases


def c4_verdict(path: Path) -> Optional[Dict[str, str]]:
    try:
        return c4.validate_c3(path)
    except c4.EvidenceFailure:
        return None


def c5_verdict(path: Path) -> Optional[Dict[str, str]]:
    try:
        return c5.validate_c3(path)
    except c5.EvidenceFailure:
        return None


def c7_verdict(path: Path) -> Optional[Dict[str, str]]:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    try:
        release = camera_gate_c7_schema.parse_release_provenance(path, digest, "C3")
    except camera_gate_c7_schema.C7EvidenceError:
        return None
    return {
        "archive_tree_sha256": release.archive_tree_sha256,
        "app_cdhash": release.app_cdhash,
        "helper_cdhash": release.helper_cdhash,
        "extension_cdhash": release.extension_cdhash,
    }


def main() -> int:
    consumers: Tuple[Tuple[str, Callable[[Path], Optional[Dict[str, str]]]], ...] = (
        ("C4", c4_verdict),
        ("C5", c5_verdict),
        ("C7", c7_verdict),
    )
    failures: List[str] = []
    cases = mutations()
    with tempfile.TemporaryDirectory(prefix="idlescreen-c3-common-") as directory:
        for name, (should_accept, text) in cases.items():
            path = Path(directory) / f"{name}.manifest"
            path.write_text(text, encoding="utf-8")
            results = {label: verdict(path) for label, verdict in consumers}
            for label, result in results.items():
                if (result is not None) != should_accept:
                    failures.append(
                        f"{name}: {label} {'rejected' if should_accept else 'accepted'} it"
                    )
            if should_accept:
                for key in ("app_cdhash", "helper_cdhash", "extension_cdhash", "archive_tree_sha256"):
                    values = {label: result[key] for label, result in results.items() if result}
                    if len(set(values.values())) != 1:
                        failures.append(f"{name}: consumers disagree on {key}: {values}")
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print(
        f"PASS: C3 provenance gets one verdict from the C4, C5 and C7 consumers across {len(cases)} inputs."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
