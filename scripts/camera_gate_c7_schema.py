#!/usr/bin/env python3
"""Offline C7 policy-decision and A1P evidence contracts."""

from __future__ import annotations

import hashlib
import json
import plistlib
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Mapping

from camera_gate_c6_schema import POLICIES, C6EvidenceError, verify_matrix


SHA256_RE = re.compile(r"[0-9a-f]{64}")
CDHASH_RE = re.compile(r"[0-9a-f]{40}")
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{7,127}")
A1P_SCHEMA = "IdleScreenC7A1PEvidence/v2"
CANDIDATE_SCHEMA = "IdleScreenC7PromotedCandidateBinding/v2"
RUNTIME_SCHEMA = "IdleScreenC7A1PRuntimeBinding/v2"
JOURNAL_SCHEMA = "IdleScreenC7A1PJournalEvent/v1"
TEAM = "3524374A2S"
APP_GROUP = "group.com.idlescreen.shared"
MACH_SERVICE = "group.com.idlescreen.shared.camera-agent"
APP_ID = "com.idlescreen.app"
HELPER_ID = "com.idlescreen.camera-agent"
EXTENSION_ID = "com.idlescreen.app.screensaver"
GENERATED_POLICY_REPOSITORY_PATH = (
    "IdleScreenCore/Generated/IdleScreenC7ActivationDecision.generated.swift"
)
SWIFT_CASES = {
    "trustworthy-activation-capability": "trustworthyActivationCapability",
    "disclosed-prewarm-continuation": "disclosedPrewarmContinuation",
    "camera-disabled-saver-fallback": "cameraDisabledSaverFallback",
}

C3_FIELDS = (
    "schema",
    "verification_mode",
    "archive_tree_sha256",
    "team_identifier",
    "app_group",
    "mach_service",
    "camera_usage_description_sha256",
    "launch_agent_sha256",
    "signer_certificate_sha256",
    "app_bundle_identifier",
    "app_cdhash",
    "app_designated_requirement_sha256",
    "app_entitlements_sha256",
    "app_profile_sha256",
    "app_profile_uuid",
    "app_profile_expiration",
    "extension_bundle_identifier",
    "extension_cdhash",
    "extension_designated_requirement_sha256",
    "extension_entitlements_sha256",
    "extension_profile_sha256",
    "extension_profile_uuid",
    "extension_profile_expiration",
    "helper_bundle_identifier",
    "helper_cdhash",
    "helper_designated_requirement_sha256",
    "helper_entitlements_sha256",
    "helper_profile_sha256",
    "helper_profile_uuid",
    "helper_profile_expiration",
)


class C7EvidenceError(RuntimeError):
    pass


@dataclass(frozen=True)
class ReleaseProvenance:
    path: Path
    sha256: str
    archive_tree_sha256: str
    app_cdhash: str
    helper_cdhash: str
    extension_cdhash: str


@dataclass(frozen=True)
class VerifiedC6Decision:
    path: Path
    sha256: str
    matrix_id: str
    evidence_set_sha256: str
    candidate_provenance_sha256: str
    candidate_extension_cdhash: str
    candidate_verdict: str
    policy: str
    candidate_release_provenance: ReleaseProvenance


@dataclass(frozen=True)
class VerifiedA1P:
    manifest_path: Path
    manifest_sha256: str
    decision: VerifiedC6Decision
    candidate_binding_sha256: str
    archive_tree_sha256: str
    app_cdhash: str
    helper_cdhash: str
    extension_cdhash: str


def fail(message: str) -> None:
    raise C7EvidenceError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def strict_keys(value: Mapping[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        fail(
            f"{label} fields differ from schema "
            f"(missing={sorted(expected - actual)}, extra={sorted(actual - expected)})"
        )


def object_value(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def string_value(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        fail(f"{label} must be one nonempty line")
    return value


def bool_value(value: Any, label: str) -> bool:
    if type(value) is not bool:
        fail(f"{label} must be true or false")
    return value


def parse_utc(value: Any, label: str) -> datetime:
    text = string_value(value, label)
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", text) is None:
        fail(f"{label} must use second-resolution UTC")
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        fail(f"{label} is not a valid UTC timestamp")


def load_json(path: Path, label: str) -> Mapping[str, Any]:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        fail(f"{label} must be an absolute non-symlink regular file")

    def no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                fail(f"{label} repeats JSON key {key!r}")
            value[key] = item
        return value

    try:
        parsed = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=no_duplicates)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is not valid UTF-8 JSON: {error}")
    return object_value(parsed, label)


def resolve(root: Path, relative: Any, expected_hash: Any, label: str) -> tuple[Path, str]:
    relative_text = string_value(relative, f"{label}.path")
    digest = string_value(expected_hash, f"{label}.sha256")
    relative_path = Path(relative_text)
    if (
        relative_path.is_absolute()
        or relative_path == Path(".")
        or ".." in relative_path.parts
        or SHA256_RE.fullmatch(digest) is None
    ):
        fail(f"{label} path or SHA-256 is malformed")
    path = root / relative_path
    if path.is_symlink() or not path.is_file() or root.resolve() not in path.resolve().parents:
        fail(f"{label} must be a regular file inside the evidence root")
    if sha256(path) != digest:
        fail(f"{label} digest changed")
    return path, digest


def parse_release_provenance(path: Path, expected_hash: str, label: str) -> ReleaseProvenance:
    if SHA256_RE.fullmatch(expected_hash) is None or sha256(path) != expected_hash:
        fail(f"{label} does not match its exact manifest SHA-256")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        fail(f"{label} is unreadable: {error}")
    pairs: list[tuple[str, str]] = []
    for line_number, line in enumerate(lines, 1):
        if "=" not in line or any(ord(character) < 0x20 for character in line):
            fail(f"{label} line {line_number} is malformed")
        key, value = line.split("=", 1)
        if not value:
            fail(f"{label} field {key!r} is empty")
        pairs.append((key, value))
    if tuple(key for key, _ in pairs) != C3_FIELDS:
        fail(f"{label} is not the exact Release provenance schema")
    values = dict(pairs)
    expected = {
        "schema": "IdleScreenReleaseArchiveProvenance/v1",
        "verification_mode": "release",
        "team_identifier": TEAM,
        "app_group": APP_GROUP,
        "mach_service": MACH_SERVICE,
        "app_bundle_identifier": APP_ID,
        "helper_bundle_identifier": HELPER_ID,
        "extension_bundle_identifier": EXTENSION_ID,
    }
    for key, value in expected.items():
        if values[key] != value:
            fail(f"{label} {key} is not exact production Release provenance")
    if SHA256_RE.fullmatch(values["archive_tree_sha256"]) is None:
        fail(f"{label} archive tree SHA-256 is malformed")
    for key, value in values.items():
        if key.endswith("_sha256") and SHA256_RE.fullmatch(value) is None:
            fail(f"{label} {key} is malformed")
        if key.endswith("_cdhash") and CDHASH_RE.fullmatch(value) is None:
            fail(f"{label} {key} is malformed")
    return ReleaseProvenance(
        path=path,
        sha256=expected_hash,
        archive_tree_sha256=values["archive_tree_sha256"],
        app_cdhash=values["app_cdhash"],
        helper_cdhash=values["helper_cdhash"],
        extension_cdhash=values["extension_cdhash"],
    )


def unique_markdown_value(payload: str, pattern: str, label: str) -> str:
    matches = re.findall(pattern, payload, flags=re.MULTILINE)
    if len(matches) != 1:
        fail(f"C6 decision must contain exactly one {label}")
    return matches[0]


def verify_c6_decision(
    matrix_path: Path,
    decision_path: Path,
    expected_decision_sha256: str,
) -> VerifiedC6Decision:
    if SHA256_RE.fullmatch(expected_decision_sha256) is None:
        fail("expected C6 decision SHA-256 is malformed")
    if not decision_path.is_absolute() or decision_path.is_symlink() or not decision_path.is_file():
        fail("C6 decision must be an absolute non-symlink regular file")
    if sha256(decision_path) != expected_decision_sha256:
        fail("C6 decision does not match the explicitly expected SHA-256")
    try:
        matrix = verify_matrix(matrix_path)
        matrix_document = load_json(matrix_path, "C6 matrix manifest")
        payload = decision_path.read_text(encoding="utf-8")
    except C6EvidenceError as error:
        fail(f"C6 matrix replay failed: {error}")
    except (OSError, UnicodeError) as error:
        fail(f"C6 decision is unreadable: {error}")
    if not payload.startswith("# IdleScreen C6 activation-provenance decision\n"):
        fail("C6 decision is not a generated activation-provenance record")
    if "\r" in payload or "\x00" in payload:
        fail("C6 decision contains malformed text")

    matrix_id = unique_markdown_value(payload, r"^- Matrix ID: `([^`]+)`$", "matrix ID")
    matrix_sha = unique_markdown_value(
        payload,
        r"^- Matrix manifest SHA-256: `([0-9a-f]{64})`$",
        "matrix SHA-256",
    )
    evidence_sha = unique_markdown_value(
        payload,
        r"^- Complete evidence-set SHA-256: `([0-9a-f]{64})`$",
        "evidence-set SHA-256",
    )
    provenance_sha = unique_markdown_value(
        payload,
        r"^- Candidate provenance SHA-256: `([0-9a-f]{64})`$",
        "candidate provenance SHA-256",
    )
    extension_cdhash = unique_markdown_value(
        payload,
        r"^- Candidate extension CDHash: `([0-9a-f]{40})`$",
        "candidate extension CDHash",
    )
    candidate_verdict = unique_markdown_value(
        payload,
        r"^- Candidate signal verdict: \*\*(accepted|rejected)\*\*$",
        "candidate verdict",
    )
    policy = unique_markdown_value(
        payload,
        r"^- Shipping policy: \*\*([^*]+)\*\*$",
        "shipping policy",
    )
    if policy not in POLICIES:
        fail("C6 decision names a policy outside the closed shipping vocabulary")
    if (
        matrix_id != matrix.matrix_id
        or matrix_sha != matrix.matrix_manifest_sha256
        or evidence_sha != matrix.evidence_set_sha256
        or provenance_sha != matrix.candidate_provenance_sha256
        or extension_cdhash != matrix.extension_cdhash
        or candidate_verdict != matrix.candidate_verdict
    ):
        fail("C6 decision does not reproduce the verified matrix binding")
    if policy == "trustworthy-activation-capability" and candidate_verdict != "accepted":
        fail("C6 decision promotes a rejected candidate signal")
    if "## Privacy limitations\n\n" not in payload or "## Energy limitations\n\n" not in payload:
        fail("C6 decision lacks explicit privacy or energy limitations")
    for row in matrix.rows:
        marker = f"| {row.definition.ordinal} | `{row.definition.row_id}` |"
        if payload.count(marker) != 1:
            fail(f"C6 decision does not retain exactly one {row.definition.row_id} row")
        if f"| `{row.authorization_id}` | `{row.row_run_id}` |" not in payload:
            fail(f"C6 decision does not bind {row.definition.row_id} authorization/run identity")
    scope = (
        "This record was generated only after the offline verifier accepted all eight\n"
        "distinct, completed, separately authorized, camera/TCC-free, unambiguous C6\n"
        "rows."
    )
    if payload.count(scope) != 1:
        fail("C6 decision lacks the generated camera-free completion scope")
    matrix_candidate = object_value(matrix_document["candidate"], "C6 matrix candidate")
    prior_provenance_path, prior_provenance_hash = resolve(
        matrix.root,
        matrix_candidate["provenance_file"],
        matrix_candidate["provenance_sha256"],
        "C6-bound Release provenance",
    )
    prior_provenance = parse_release_provenance(
        prior_provenance_path,
        prior_provenance_hash,
        "C6-bound Release provenance",
    )
    if (
        prior_provenance.sha256 != matrix.candidate_provenance_sha256
        or prior_provenance.extension_cdhash != matrix.extension_cdhash
    ):
        fail("C6 matrix identity does not replay its exact Release provenance")
    return VerifiedC6Decision(
        path=decision_path,
        sha256=expected_decision_sha256,
        matrix_id=matrix.matrix_id,
        evidence_set_sha256=matrix.evidence_set_sha256,
        candidate_provenance_sha256=matrix.candidate_provenance_sha256,
        candidate_extension_cdhash=matrix.extension_cdhash,
        candidate_verdict=matrix.candidate_verdict,
        policy=policy,
        candidate_release_provenance=prior_provenance,
    )


A1P_KEYS = {
    "schema",
    "status",
    "evidence_semantics",
    "physical_boundary",
    "c6",
    "generated_policy_source",
    "release_provenance",
    "release_artifact_inventory",
    "candidate_binding",
    "authorizations",
    "timing",
    "transaction_journal",
    "runtime_binding",
}

RUNTIME_ARTIFACT_ORDER = (
    "app_codesign",
    "helper_codesign",
    "extension_codesign",
    "app_profile",
    "helper_profile",
    "extension_profile",
    "app_entitlements",
    "helper_entitlements",
    "extension_entitlements",
    "helper_procinfo",
    "plugin_registration",
    "launchd_registration",
    "selection",
    "runtime_diagnostic",
    "process_inventory",
    "marker_scan",
    "policy_contract_log",
)


def artifact_reference(value: Any, label: str) -> Mapping[str, Any]:
    reference = object_value(value, label)
    strict_keys(reference, {"path", "sha256"}, label)
    return reference


def expected_generated_policy_source(decision: VerifiedC6Decision) -> str:
    swift_case = SWIFT_CASES[decision.policy]
    return f"""// schema=IdleScreenC7GeneratedActivationDecision/v1
// c6-decision-sha256={decision.sha256}
// c6-evidence-set-sha256={decision.evidence_set_sha256}
// policy={decision.policy}
// Generated only after replaying the complete C6 matrix. Do not hand-edit.

public enum IdleScreenC7GeneratedActivationDecision {{
    public static let input = IdleScreenSaverActivationDecisionInput(
        policy: .{swift_case},
        c6DecisionSHA256: \"{decision.sha256}\",
        c6EvidenceSetSHA256: \"{decision.evidence_set_sha256}\",
        generatedFromVerifiedC6Decision: true
    )
}}
"""


def read_plist(path: Path, label: str) -> Mapping[str, Any]:
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"{label} is not a raw plist capture: {error}")
    return object_value(value, label)


def unique_raw_value(payload: str, key: str, label: str) -> str:
    values = [line[len(key) + 1 :] for line in payload.splitlines() if line.startswith(f"{key}=")]
    if len(values) != 1 or not values[0]:
        fail(f"{label} lacks exactly one raw {key}")
    return values[0]


def verify_codesign_capture(
    path: Path,
    identifier: str,
    cdhash: str,
    label: str,
) -> None:
    try:
        payload = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"{label} is unreadable: {error}")
    if (
        unique_raw_value(payload, "Identifier", label) != identifier
        or unique_raw_value(payload, "TeamIdentifier", label) != TEAM
        or unique_raw_value(payload, "CDHash", label).lower() != cdhash
        or "flags=" not in payload
        or "runtime" not in payload
    ):
        fail(f"{label} does not retain the exact hardened signed identity")


def verify_profile_and_entitlements(
    profile_path: Path,
    entitlements_path: Path,
    identifier: str,
    camera_expected: bool,
    label: str,
) -> None:
    profile = read_plist(profile_path, f"{label} profile")
    entitlements = read_plist(entitlements_path, f"{label} entitlements")
    profile_entitlements = object_value(profile.get("Entitlements"), f"{label} profile entitlements")
    expected_application = f"{TEAM}.{identifier}"
    for source, source_label in (
        (profile_entitlements, f"{label} profile"),
        (entitlements, f"{label} signed entitlements"),
    ):
        if (
            source.get("com.apple.developer.team-identifier") != TEAM
            or source.get("com.apple.application-identifier") != expected_application
            or source.get("com.apple.security.application-groups") != [APP_GROUP]
            or source.get("com.apple.security.app-sandbox") is not True
            or source.get("com.apple.security.get-task-allow") not in (None, False)
        ):
            fail(f"{source_label} does not authorize the exact production App Group identity")
        camera_value = source.get("com.apple.security.device.camera")
        if camera_expected and camera_value is not True:
            fail(f"{source_label} lacks the helper-only camera entitlement")
        if not camera_expected and camera_value not in (None, False):
            fail(f"{source_label} unexpectedly has camera entitlement")
    if profile.get("TeamIdentifier") != [TEAM]:
        fail(f"{label} profile is not signed for the exact Team")


def parse_kv_capture(path: Path, fields: tuple[str, ...], label: str) -> Mapping[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        fail(f"{label} is unreadable: {error}")
    pairs: list[tuple[str, str]] = []
    for line_number, line in enumerate(lines, 1):
        if "=" not in line or any(ord(character) < 0x20 for character in line):
            fail(f"{label} line {line_number} is malformed")
        key, value = line.split("=", 1)
        if not value:
            fail(f"{label} field {key!r} is empty")
        pairs.append((key, value))
    if tuple(key for key, _ in pairs) != fields:
        fail(f"{label} fields are missing, reordered, or unexpected")
    return dict(pairs)


def verify_journal(
    path: Path,
    root: Path,
    references: Mapping[str, tuple[Path, str]],
    generated_source: tuple[Path, str],
    release_provenance: tuple[Path, str],
    release_inventory: tuple[Path, str],
    authorization_ids: Mapping[str, str],
    authorization_times: Mapping[str, datetime],
    started: datetime,
    completed: datetime,
) -> None:
    expected_artifacts = {
        "generated_policy_source": generated_source,
        "release_provenance": release_provenance,
        "release_artifact_inventory": release_inventory,
        **references,
    }
    expected_stages = [
        "generated-policy-source-captured",
        "release-provenance-replayed",
        "release-inventory-bound",
        "installation-completed",
        "registration-completed",
        *(f"capture-{name.replace('_', '-')}" for name in RUNTIME_ARTIFACT_ORDER),
    ]
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        fail(f"A1P journal is unreadable: {error}")
    if len(lines) != len(expected_stages):
        fail("A1P journal does not contain one exact ordered transaction")
    previous = started
    artifact_stage_names = [
        "generated_policy_source",
        "release_provenance",
        "release_artifact_inventory",
        None,
        None,
        *RUNTIME_ARTIFACT_ORDER,
    ]
    for index, (line, stage, artifact_name) in enumerate(
        zip(lines, expected_stages, artifact_stage_names), 1
    ):
        try:
            event = json.loads(line)
        except json.JSONDecodeError as error:
            fail(f"A1P journal event {index} is malformed: {error}")
        event = object_value(event, f"A1P journal event {index}")
        strict_keys(
            event,
            {
                "schema",
                "event_index",
                "captured_at_utc",
                "stage",
                "authorization_id",
                "exit_status",
                "artifact_path",
                "artifact_sha256",
            },
            f"A1P journal event {index}",
        )
        captured = parse_utc(event["captured_at_utc"], f"A1P journal event {index}")
        if (
            event["schema"] != JOURNAL_SCHEMA
            or event["event_index"] != index
            or event["stage"] != stage
            or event["exit_status"] != 0
            or not previous <= captured <= completed
        ):
            fail(f"A1P journal event {index} is not an ordered successful capture")
        previous = captured
        if stage == "installation-completed":
            if (
                event["authorization_id"] != authorization_ids["installation"]
                or captured < authorization_times["installation"]
                or event["artifact_path"] != "none"
                or event["artifact_sha256"] != "none"
            ):
                fail("A1P install journal entry is not bound to immediate install authorization")
        elif stage == "registration-completed":
            if (
                event["authorization_id"] != authorization_ids["registration"]
                or captured < authorization_times["registration"]
                or event["artifact_path"] != "none"
                or event["artifact_sha256"] != "none"
            ):
                fail("A1P registration journal entry is not bound to immediate registration authorization")
        else:
            if event["authorization_id"] != "none" or artifact_name is None:
                fail(f"A1P journal event {index} has an unexpected authorization binding")
            artifact_path, artifact_hash = expected_artifacts[artifact_name]
            if (
                event["artifact_path"] != artifact_path.relative_to(root).as_posix()
                or event["artifact_sha256"] != artifact_hash
            ):
                fail(f"A1P journal event {index} does not hash-bind its raw artifact")


def verify_a1p(manifest_path: Path) -> VerifiedA1P:
    top = load_json(manifest_path, "C7 A1P manifest")
    strict_keys(top, A1P_KEYS, "C7 A1P manifest")
    if (
        top["schema"] != A1P_SCHEMA
        or top["status"] != "completed"
        or top["evidence_semantics"] != "camera-free-production-policy-promotion"
    ):
        fail("C7 A1P manifest is not completed camera-free promotion evidence")
    root = manifest_path.parent.resolve()
    boundary = object_value(top["physical_boundary"], "physical_boundary")
    strict_keys(
        boundary,
        {"camera", "tcc", "saver_activation", "raw_frame_or_content"},
        "physical_boundary",
    )
    if any(boundary[key] != "prohibited" for key in boundary):
        fail("A1P must prohibit camera, TCC, saver activation, and raw/content evidence")

    c6 = object_value(top["c6"], "c6")
    strict_keys(c6, {"matrix", "matrix_sha256", "decision", "decision_sha256"}, "c6")
    matrix_path, _ = resolve(root, c6["matrix"], c6["matrix_sha256"], "c6.matrix")
    decision_path, decision_hash = resolve(
        root, c6["decision"], c6["decision_sha256"], "c6.decision"
    )
    decision = verify_c6_decision(matrix_path, decision_path, decision_hash)

    generated_ref = artifact_reference(top["generated_policy_source"], "generated_policy_source")
    generated_path, generated_hash = resolve(
        root, generated_ref["path"], generated_ref["sha256"], "generated_policy_source"
    )
    try:
        generated_payload = generated_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"generated policy source is unreadable: {error}")
    if generated_payload != expected_generated_policy_source(decision):
        fail("generated policy source is not the exact Swift output for the replayed C6 decision")

    release_ref = artifact_reference(top["release_provenance"], "release_provenance")
    release_path, release_hash = resolve(
        root, release_ref["path"], release_ref["sha256"], "release_provenance"
    )
    release = parse_release_provenance(release_path, release_hash, "promoted Release provenance")
    inventory_ref = artifact_reference(
        top["release_artifact_inventory"], "release_artifact_inventory"
    )
    inventory_path, inventory_hash = resolve(
        root,
        inventory_ref["path"],
        inventory_ref["sha256"],
        "release_artifact_inventory",
    )
    if inventory_hash != release.archive_tree_sha256:
        fail("promoted Release inventory does not reproduce archive_tree_sha256")

    candidate_ref = artifact_reference(top["candidate_binding"], "candidate_binding")
    candidate_path, candidate_hash = resolve(
        root, candidate_ref["path"], candidate_ref["sha256"], "candidate_binding"
    )
    candidate = load_json(candidate_path.resolve(), "promoted candidate binding")
    candidate_keys = {
        "schema",
        "c6_decision_sha256",
        "c6_evidence_set_sha256",
        "policy",
        "generated_policy_repository_path",
        "generated_policy_source_sha256",
        "prior_c6_provenance_sha256",
        "prior_c6_archive_tree_sha256",
        "release_provenance_sha256",
        "release_artifact_inventory_sha256",
        "archive_tree_sha256",
        "app_cdhash",
        "helper_cdhash",
        "extension_cdhash",
        "team_identifier",
        "app_group",
        "mach_service",
        "app_bundle_identifier",
        "helper_bundle_identifier",
        "extension_bundle_identifier",
    }
    strict_keys(candidate, candidate_keys, "promoted candidate binding")
    prior = decision.candidate_release_provenance
    expected_candidate = {
        "schema": CANDIDATE_SCHEMA,
        "c6_decision_sha256": decision.sha256,
        "c6_evidence_set_sha256": decision.evidence_set_sha256,
        "policy": decision.policy,
        "generated_policy_repository_path": GENERATED_POLICY_REPOSITORY_PATH,
        "generated_policy_source_sha256": generated_hash,
        "prior_c6_provenance_sha256": prior.sha256,
        "prior_c6_archive_tree_sha256": prior.archive_tree_sha256,
        "release_provenance_sha256": release.sha256,
        "release_artifact_inventory_sha256": inventory_hash,
        "archive_tree_sha256": release.archive_tree_sha256,
        "app_cdhash": release.app_cdhash,
        "helper_cdhash": release.helper_cdhash,
        "extension_cdhash": release.extension_cdhash,
        "team_identifier": TEAM,
        "app_group": APP_GROUP,
        "mach_service": MACH_SERVICE,
        "app_bundle_identifier": APP_ID,
        "helper_bundle_identifier": HELPER_ID,
        "extension_bundle_identifier": EXTENSION_ID,
    }
    if candidate != expected_candidate:
        fail("promoted candidate binding does not replay C6, Swift source, and Release provenance")
    if release.archive_tree_sha256 == prior.archive_tree_sha256:
        fail("promoted candidate archive is not distinct from the C6-bound archive tree")

    authorizations = object_value(top["authorizations"], "authorizations")
    strict_keys(authorizations, {"installation", "registration"}, "authorizations")
    authorization_ids: dict[str, str] = {}
    authorization_times: dict[str, datetime] = {}
    for action in ("installation", "registration"):
        authorization = object_value(authorizations[action], f"authorizations.{action}")
        strict_keys(
            authorization,
            {
                "id",
                "granted_at_utc",
                "action",
                "candidate_archive_tree_sha256",
                "one_time",
                "immediate",
            },
            f"authorizations.{action}",
        )
        authorization_id = string_value(authorization["id"], f"{action} authorization ID")
        if ID_RE.fullmatch(authorization_id) is None or authorization_id in authorization_ids.values():
            fail(f"A1P {action} authorization is malformed or reused")
        authorization_ids[action] = authorization_id
        if (
            authorization["action"] != action
            or authorization["candidate_archive_tree_sha256"] != release.archive_tree_sha256
            or bool_value(authorization["one_time"], f"{action}.one_time") is not True
            or bool_value(authorization["immediate"], f"{action}.immediate") is not True
        ):
            fail(f"A1P {action} authorization is not exact, immediate, and one-time")
        authorization_times[action] = parse_utc(
            authorization["granted_at_utc"], f"{action}.granted_at_utc"
        )

    timing = object_value(top["timing"], "timing")
    strict_keys(timing, {"started_at_utc", "completed_at_utc"}, "timing")
    started = parse_utc(timing["started_at_utc"], "timing.started_at_utc")
    completed = parse_utc(timing["completed_at_utc"], "timing.completed_at_utc")
    if not all(granted <= started < completed for granted in authorization_times.values()):
        fail("A1P installation/registration was not separately authorized before execution")

    runtime_ref = artifact_reference(top["runtime_binding"], "runtime_binding")
    runtime_path, _ = resolve(root, runtime_ref["path"], runtime_ref["sha256"], "runtime_binding")
    runtime = load_json(runtime_path.resolve(), "A1P runtime binding")
    strict_keys(runtime, {"schema", "captured_at_utc", "archive_tree_sha256", "artifacts"}, "A1P runtime binding")
    if runtime["schema"] != RUNTIME_SCHEMA or runtime["archive_tree_sha256"] != release.archive_tree_sha256:
        fail("A1P runtime binding is not bound to the promoted Release archive")
    captured = parse_utc(runtime["captured_at_utc"], "runtime.captured_at_utc")
    if not started <= captured <= completed:
        fail("A1P runtime binding falls outside the authorized transaction")
    artifacts = object_value(runtime["artifacts"], "runtime.artifacts")
    strict_keys(artifacts, set(RUNTIME_ARTIFACT_ORDER), "runtime.artifacts")
    resolved_artifacts: dict[str, tuple[Path, str]] = {}
    for name in RUNTIME_ARTIFACT_ORDER:
        reference = artifact_reference(artifacts[name], f"runtime.artifacts.{name}")
        resolved_artifacts[name] = resolve(
            root, reference["path"], reference["sha256"], f"runtime.artifacts.{name}"
        )
    if len({path for path, _ in resolved_artifacts.values()}) != len(RUNTIME_ARTIFACT_ORDER):
        fail("A1P runtime binding reuses raw capture artifacts")

    verify_codesign_capture(
        resolved_artifacts["app_codesign"][0], APP_ID, release.app_cdhash, "app codesign capture"
    )
    verify_codesign_capture(
        resolved_artifacts["helper_codesign"][0],
        HELPER_ID,
        release.helper_cdhash,
        "helper codesign capture",
    )
    verify_codesign_capture(
        resolved_artifacts["extension_codesign"][0],
        EXTENSION_ID,
        release.extension_cdhash,
        "extension codesign capture",
    )
    for prefix, identifier, camera_expected in (
        ("app", APP_ID, False),
        ("helper", HELPER_ID, True),
        ("extension", EXTENSION_ID, False),
    ):
        verify_profile_and_entitlements(
            resolved_artifacts[f"{prefix}_profile"][0],
            resolved_artifacts[f"{prefix}_entitlements"][0],
            identifier,
            camera_expected,
            prefix,
        )

    try:
        procinfo = resolved_artifacts["helper_procinfo"][0].read_text(encoding="utf-8")
        plugin = resolved_artifacts["plugin_registration"][0].read_text(encoding="utf-8")
        launchd = resolved_artifacts["launchd_registration"][0].read_text(encoding="utf-8")
        selection = resolved_artifacts["selection"][0].read_text(encoding="utf-8")
        policy_log = resolved_artifacts["policy_contract_log"][0].read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"A1P raw text capture is unreadable: {error}")
    pid_matches = re.findall(r"(?:^|\n)(?:pid\s*=|pid=)([1-9][0-9]*)(?:\n|$)", procinfo)
    if (
        len(pid_matches) != 1
        or "entitlements validated" not in procinfo
        or f"{TEAM}.{HELPER_ID}" not in procinfo
        or APP_GROUP not in procinfo
    ):
        fail("helper procinfo does not prove runtime validated App Group identity")
    helper_pid = pid_matches[0]
    extension_bundle_path = (
        "/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex"
    )
    if plugin.count(EXTENSION_ID) != 1 or plugin.count(extension_bundle_path) != 1:
        fail("PlugInKit capture does not prove one exact extension registration")
    helper_executable = (
        "/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/"
        "Contents/MacOS/IdleScreenCameraAgent"
    )
    if launchd.count(MACH_SERVICE) != 1 or launchd.count(helper_executable) != 1:
        fail("launchd capture does not prove exact helper registration")
    if selection.splitlines() != [f"providers={EXTENSION_ID}", "selectedEverywhere=true"]:
        fail("selection capture does not prove the exact selected production saver")
    if policy_log.splitlines() != ["PASS: C7 policy/privacy contracts"]:
        fail("raw policy contract log is not one exact passing headless result")

    diagnostic = parse_kv_capture(
        resolved_artifacts["runtime_diagnostic"][0],
        (
            "format",
            "source",
            "captured_at_utc",
            "helper_pid",
            "active_lease_count",
            "capture_active",
            "camera_opened",
            "tcc_action",
            "saver_activated",
            "app_group_admitted",
        ),
        "runtime diagnostic",
    )
    if diagnostic != {
        "format": "IdleScreenC7A1PRuntimeDiagnosticV1",
        "source": "authenticated-helper-xpc",
        "captured_at_utc": diagnostic["captured_at_utc"],
        "helper_pid": helper_pid,
        "active_lease_count": "0",
        "capture_active": "false",
        "camera_opened": "false",
        "tcc_action": "false",
        "saver_activated": "false",
        "app_group_admitted": "true",
    }:
        fail("raw runtime diagnostic does not prove App Group admission and zero camera demand")
    diagnostic_time = parse_utc(diagnostic["captured_at_utc"], "runtime diagnostic time")
    if not started <= diagnostic_time <= completed:
        fail("runtime diagnostic falls outside the A1P transaction")
    process_inventory = parse_kv_capture(
        resolved_artifacts["process_inventory"][0],
        (
            "format",
            "captured_at_utc",
            "app_path",
            "helper_path",
            "extension_path",
            "gate_process_pids",
            "other_camera_owner_pids",
        ),
        "process inventory",
    )
    if process_inventory != {
        "format": "IdleScreenC7A1PProcessInventoryV1",
        "captured_at_utc": process_inventory["captured_at_utc"],
        "app_path": "/Applications/idlescreen.app",
        "helper_path": helper_executable,
        "extension_path": (
            f"{extension_bundle_path}/Contents/MacOS/IdleScreenScreenSaver"
        ),
        "gate_process_pids": "none",
        "other_camera_owner_pids": "none",
    }:
        fail("raw process inventory does not prove production-only zero-owner state")
    marker_scan = parse_kv_capture(
        resolved_artifacts["marker_scan"][0],
        ("format", "synthetic_seam", "helper_marker", "extension_marker"),
        "marker scan",
    )
    if marker_scan != {
        "format": "IdleScreenC7A1PMarkerScanV1",
        "synthetic_seam": "absent",
        "helper_marker": "absent",
        "extension_marker": "absent",
    }:
        fail("raw marker scan does not prove a shipping-only candidate")

    journal_ref = artifact_reference(top["transaction_journal"], "transaction_journal")
    journal_path, _ = resolve(
        root, journal_ref["path"], journal_ref["sha256"], "transaction_journal"
    )
    verify_journal(
        journal_path,
        root,
        resolved_artifacts,
        (generated_path, generated_hash),
        (release_path, release_hash),
        (inventory_path, inventory_hash),
        authorization_ids,
        authorization_times,
        started,
        completed,
    )

    return VerifiedA1P(
        manifest_path=manifest_path,
        manifest_sha256=sha256(manifest_path),
        decision=decision,
        candidate_binding_sha256=candidate_hash,
        archive_tree_sha256=release.archive_tree_sha256,
        app_cdhash=release.app_cdhash,
        helper_cdhash=release.helper_cdhash,
        extension_cdhash=release.extension_cdhash,
    )
