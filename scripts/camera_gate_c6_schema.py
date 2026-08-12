#!/usr/bin/env python3
"""Strict, camera-free C6 activation-provenance evidence contract."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


MATRIX_SCHEMA = "IdleScreenC6ActivationProvenanceMatrix/v1"
ROW_SCHEMA = "IdleScreenC6ActivationProvenanceRow/v1"
ATTESTATION_SCHEMA = "IdleScreenC6OperatorAttestation/v1"
POLICIES = (
    "trustworthy-activation-capability",
    "disclosed-prewarm-continuation",
    "camera-disabled-saver-fallback",
)
HOST_STATES = (
    "unavailable",
    "inactive",
    "running-foreground",
    "running-background",
    "inconsistent",
)
UNSAFE_HOST_STATES = frozenset(("unavailable", "running-background", "inconsistent"))


@dataclass(frozen=True)
class RowDefinition:
    ordinal: int
    row_id: str
    scenario: str
    required_actions: tuple[str, ...]
    activation_expected: bool
    required_checks: tuple[str, ...]

    @property
    def filename(self) -> str:
        return f"rows/{self.ordinal:02d}-{self.row_id}.json"

    @property
    def authorization_statement(self) -> str:
        return (
            f"Authorized only for C6 row {self.row_id}: "
            f"{','.join(self.required_actions)}."
        )


ROWS: tuple[RowDefinition, ...] = (
    RowDefinition(
        1,
        "chooser-only",
        "Screen Saver Settings chooser thumbnail and chooser-only live preview",
        ("settings", "chooser"),
        False,
        ("chooser-inactive",),
    ),
    RowDefinition(
        2,
        "manual-fullscreen",
        "manual full-screen saver activation and teardown",
        ("activation",),
        True,
        ("active-running-foreground", "timely-teardown"),
    ),
    RowDefinition(
        3,
        "lock-screen",
        "lock-screen saver activation and unlock teardown",
        ("activation", "lock-unlock"),
        True,
        ("active-running-foreground", "timely-teardown"),
    ),
    RowDefinition(
        4,
        "timed-idle",
        "normal timed-idle saver activation and teardown",
        ("activation",),
        True,
        ("active-running-foreground", "timely-teardown"),
    ),
    RowDefinition(
        5,
        "unlock-invalidation",
        "unlock and hosted extension invalidation",
        ("activation", "lock-unlock"),
        True,
        ("active-running-foreground", "timely-teardown", "invalidation-observed"),
    ),
    RowDefinition(
        6,
        "sleep-wake",
        "active saver sleep, wake, resumed observation, and final teardown",
        ("activation", "sleep-wake"),
        True,
        ("active-running-foreground", "sleep-wake-observed", "timely-teardown"),
    ),
    RowDefinition(
        7,
        "multidisplay-reconnect",
        "multiple displays with one display disconnect and reconnect",
        ("activation", "display-change"),
        True,
        (
            "active-running-foreground",
            "display-identities-distinct",
            "display-reconnect-observed",
            "timely-teardown",
        ),
    ),
    RowDefinition(
        8,
        "chooser-active-coexistence",
        "chooser instance coexisting with a genuine active saver",
        ("settings", "chooser", "activation", "coexistence"),
        True,
        (
            "chooser-inactive",
            "active-running-foreground",
            "instances-distinct",
            "timely-teardown",
        ),
    ),
)

ROW_BY_ID = {row.row_id: row for row in ROWS}

MATRIX_KEYS = frozenset(
    (
        "schema",
        "matrix_id",
        "candidate",
        "physical_boundary",
        "row_count",
        "rows",
    )
)
CANDIDATE_KEYS = frozenset(("provenance_file", "provenance_sha256", "extension_cdhash"))
BOUNDARY_KEYS = frozenset(("camera", "tcc", "raw_frame_or_content_evidence"))
ROW_KEYS = frozenset(
    (
        "schema",
        "matrix_id",
        "row_id",
        "ordinal",
        "scenario",
        "status",
        "row_run_id",
        "candidate",
        "required_authorization_actions",
        "authorization",
        "timing",
        "evidence",
        "observations",
        "interpretation",
    )
)
ROW_CANDIDATE_KEYS = frozenset(("provenance_sha256", "extension_cdhash"))
AUTHORIZATION_KEYS = frozenset(
    ("id", "granted_at_utc", "actions", "row_only", "expires_after_row", "scope_statement")
)
TIMING_KEYS = frozenset(("started_at_utc", "completed_at_utc"))
EVIDENCE_KEYS = frozenset(("host_log", "operator_attestation"))
ARTIFACT_KEYS = frozenset(("path", "sha256"))
OBSERVATION_KEYS = frozenset(
    (
        "host_activity_states",
        "checks",
        "activation_expected",
        "activation_observed",
        "teardown_observed",
        "chooser_false_positive",
        "genuine_activation_false_negative",
        "stale_or_ambiguous_state",
        "unexpected_prompt",
        "focus_theft",
        "loop_or_crash",
        "camera_opened",
        "tcc_action",
        "raw_frame_or_content_evidence",
    )
)
INTERPRETATION_KEYS = frozenset(("verdict", "unambiguous", "rejection_reasons"))
ATTESTATION_KEYS = frozenset(
    (
        "schema",
        "matrix_id",
        "row_id",
        "row_run_id",
        "camera_opened",
        "tcc_action",
        "raw_frame_or_content_evidence",
        "unexpected_prompt",
        "focus_theft",
        "loop_or_crash",
        "interpretation_unambiguous",
    )
)

HOST_ACTIVITY_RE = re.compile(
    r"Global host activity state="
    r"(unavailable|inactive|running-foreground|running-background|inconsistent) "
    r"source=(initialize|start-animation|animation-frame) "
    r"changed=(true|false) cameraDemand=(true|false)(?:\s|$)"
)
HOST_ACTIVITY_ANY_RE = re.compile(r"Global host activity")
PROHIBITED_ACTION_RE = re.compile(
    r"(?:"
    r"AVCapture|kTCCServiceCamera|tccutil|"
    r"Camera (?:capture|permission|authorization) (?:started|requested|prompted|running)|"
    r"Camera receipt state=(?:frame|live)|"
    r"camera_opened=true|tcc_action=true|raw_frame_or_content_evidence=true"
    r")",
    re.IGNORECASE,
)
SHA256_RE = re.compile(r"[0-9a-f]{64}")
CDHASH_RE = re.compile(r"[0-9a-f]{40}")
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{7,127}")


class C6EvidenceError(RuntimeError):
    pass


@dataclass(frozen=True)
class VerifiedRow:
    definition: RowDefinition
    row_run_id: str
    authorization_id: str
    artifact_paths: tuple[str, str]
    artifact_hashes: tuple[str, str]
    row_manifest_sha256: str
    verdict: str
    rejection_reasons: tuple[str, ...]


@dataclass(frozen=True)
class VerifiedMatrix:
    root: Path
    matrix_id: str
    candidate_provenance_sha256: str
    extension_cdhash: str
    matrix_manifest_sha256: str
    rows: tuple[VerifiedRow, ...]

    @property
    def candidate_verdict(self) -> str:
        return "accepted" if all(row.verdict == "candidate-supported" for row in self.rows) else "rejected"

    @property
    def evidence_set_sha256(self) -> str:
        digest = hashlib.sha256()
        digest.update(f"matrix={self.matrix_manifest_sha256}\n".encode())
        digest.update(f"candidate={self.candidate_provenance_sha256}\n".encode())
        digest.update(f"extension={self.extension_cdhash}\n".encode())
        for row in self.rows:
            digest.update(
                (
                    f"row={row.definition.ordinal}|{row.definition.row_id}|"
                    f"{row.row_manifest_sha256}|{row.artifact_paths[0]}|"
                    f"{row.artifact_hashes[0]}|{row.artifact_paths[1]}|"
                    f"{row.artifact_hashes[1]}\n"
                ).encode()
            )
        return digest.hexdigest()


def fail(message: str) -> None:
    raise C6EvidenceError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def strict_keys(value: Mapping[str, Any], expected: frozenset[str], label: str) -> None:
    actual = frozenset(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        fail(f"{label} fields differ from schema (missing={missing}, extra={extra})")


def object_value(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def string_value(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        fail(f"{label} must be one nonempty line")
    return value


def boolean_value(value: Any, label: str) -> bool:
    if type(value) is not bool:
        fail(f"{label} must be true or false")
    return value


def parse_utc(value: Any, label: str) -> datetime:
    text = string_value(value, label)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", text):
        fail(f"{label} must use second-resolution UTC (YYYY-MM-DDTHH:MM:SSZ)")
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        fail(f"{label} is not a valid UTC timestamp")


def load_json(path: Path, label: str) -> Mapping[str, Any]:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        fail(f"{label} must be an absolute, non-symlink regular file")
    try:
        def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
            result: dict[str, Any] = {}
            for key, item in pairs:
                if key in result:
                    fail(f"{label} contains duplicate JSON key {key!r}")
                result[key] = item
            return result

        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is not valid UTF-8 JSON: {error}")
    return object_value(value, label)


def resolve_evidence_file(root: Path, relative: Any, label: str) -> tuple[Path, str]:
    relative_text = string_value(relative, f"{label}.path")
    relative_path = Path(relative_text)
    if relative_path.is_absolute() or ".." in relative_path.parts or relative_path == Path("."):
        fail(f"{label}.path must be a normalized path inside the evidence root")
    resolved = root.joinpath(relative_path)
    if resolved.is_symlink() or not resolved.is_file():
        fail(f"{label}.path must name a non-symlink regular evidence file")
    try:
        if resolved.resolve().parent != root.resolve() and root.resolve() not in resolved.resolve().parents:
            fail(f"{label}.path escapes the evidence root")
    except OSError as error:
        fail(f"{label}.path cannot be resolved: {error}")
    return resolved, relative_text


def read_text_artifact(path: Path, label: str) -> str:
    try:
        payload = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"{label} must be UTF-8 text: {error}")
    if not payload.strip():
        fail(f"{label} must not be empty")
    if PROHIBITED_ACTION_RE.search(payload):
        fail(f"{label} contains camera/TCC/raw-frame action evidence")
    return payload


def compact_states(states: Iterable[str]) -> list[str]:
    compacted: list[str] = []
    for state in states:
        if not compacted or compacted[-1] != state:
            compacted.append(state)
    return compacted


def parse_host_log(payload: str, label: str) -> list[str]:
    states: list[str] = []
    for line in payload.splitlines():
        if not HOST_ACTIVITY_ANY_RE.search(line):
            continue
        match = HOST_ACTIVITY_RE.search(line)
        if match is None:
            fail(f"{label} contains malformed host-activity evidence")
        if match.group(4) != "false":
            fail(f"{label} must retain cameraDemand=false for the camera-disabled C6 gate")
        states.append(match.group(1))
    if not states:
        fail(f"{label} contains no global host-activity observation")
    return compact_states(states)


def parse_attestation(payload: str, label: str) -> Mapping[str, str]:
    values: dict[str, str] = {}
    for line_number, raw in enumerate(payload.splitlines(), start=1):
        if not raw:
            continue
        if "=" not in raw:
            fail(f"{label} line {line_number} is not key=value")
        key, value = raw.split("=", 1)
        if not key or key in values or "\n" in value or "\r" in value:
            fail(f"{label} contains a duplicate or malformed {key!r}")
        values[key] = value
    strict_keys(values, ATTESTATION_KEYS, label)
    return values


def bool_text(value: bool) -> str:
    return "true" if value else "false"


def expected_rejection_reasons(
    definition: RowDefinition,
    observations: Mapping[str, Any],
    checks: Mapping[str, Any],
    host_states: Sequence[str],
) -> tuple[str, ...]:
    reasons: set[str] = set()
    if boolean_value(observations["chooser_false_positive"], "chooser_false_positive"):
        reasons.add("chooser-false-positive")
    if boolean_value(
        observations["genuine_activation_false_negative"],
        "genuine_activation_false_negative",
    ):
        reasons.add("genuine-activation-false-negative")
    if boolean_value(observations["stale_or_ambiguous_state"], "stale_or_ambiguous_state"):
        reasons.add("stale-or-ambiguous-state")
    if boolean_value(observations["unexpected_prompt"], "unexpected_prompt"):
        reasons.add("unexpected-prompt")
    if boolean_value(observations["focus_theft"], "focus_theft"):
        reasons.add("focus-theft")
    if boolean_value(observations["loop_or_crash"], "loop_or_crash"):
        reasons.add("loop-or-crash")
    if UNSAFE_HOST_STATES.intersection(host_states):
        reasons.add("unsafe-host-state")
    if any(boolean_value(checks[name], f"checks.{name}") is False for name in definition.required_checks):
        reasons.add("scenario-check-failed")
    activation_observed = boolean_value(observations["activation_observed"], "activation_observed")
    if definition.activation_expected and not activation_observed:
        reasons.add("genuine-activation-false-negative")
    if not definition.activation_expected and activation_observed:
        reasons.add("chooser-false-positive")
    if definition.activation_expected and "running-foreground" not in host_states:
        reasons.add("genuine-activation-false-negative")
    if not definition.activation_expected and "running-foreground" in host_states:
        reasons.add("chooser-false-positive")
    return tuple(sorted(reasons))


def verify_matrix(manifest_path: Path) -> VerifiedMatrix:
    top = load_json(manifest_path, "C6 matrix manifest")
    strict_keys(top, MATRIX_KEYS, "C6 matrix manifest")
    if top["schema"] != MATRIX_SCHEMA:
        fail("C6 matrix manifest schema is not supported")
    matrix_id = string_value(top["matrix_id"], "matrix_id")
    if ID_RE.fullmatch(matrix_id) is None:
        fail("matrix_id has an unsafe or ambiguous shape")
    if type(top["row_count"]) is not int or top["row_count"] != len(ROWS):
        fail(f"C6 matrix must declare exactly {len(ROWS)} rows")
    root = manifest_path.parent.resolve()

    boundary = object_value(top["physical_boundary"], "physical_boundary")
    strict_keys(boundary, BOUNDARY_KEYS, "physical_boundary")
    if any(boundary[key] != "prohibited" for key in BOUNDARY_KEYS):
        fail("C6 physical boundary must prohibit camera, TCC, and raw/content evidence")

    candidate = object_value(top["candidate"], "candidate")
    strict_keys(candidate, CANDIDATE_KEYS, "candidate")
    provenance_hash = string_value(candidate["provenance_sha256"], "candidate.provenance_sha256")
    extension_cdhash = string_value(candidate["extension_cdhash"], "candidate.extension_cdhash")
    if SHA256_RE.fullmatch(provenance_hash) is None or CDHASH_RE.fullmatch(extension_cdhash) is None:
        fail("candidate hashes must be lowercase SHA-256 and CDHash values")
    provenance_path, _ = resolve_evidence_file(
        root,
        candidate["provenance_file"],
        "candidate.provenance_file",
    )
    if sha256(provenance_path) != provenance_hash:
        fail("candidate provenance file hash does not match the matrix binding")

    row_refs = top["rows"]
    if not isinstance(row_refs, list) or len(row_refs) != len(ROWS):
        fail("C6 matrix rows must be one ordered eight-entry list")
    verified_rows: list[VerifiedRow] = []
    seen_run_ids: set[str] = set()
    seen_authorization_ids: set[str] = set()
    seen_artifact_paths: set[str] = set()
    seen_artifact_hashes: set[str] = set()

    for definition, reference in zip(ROWS, row_refs):
        reference_object = object_value(reference, f"row reference {definition.ordinal}")
        strict_keys(reference_object, frozenset(("row_id", "path")), f"row reference {definition.ordinal}")
        if reference_object["row_id"] != definition.row_id or reference_object["path"] != definition.filename:
            fail(f"row reference {definition.ordinal} is missing, reordered, or renamed")
        row_path, _ = resolve_evidence_file(root, reference_object["path"], f"row {definition.row_id}")
        row = load_json(row_path.resolve(), f"row {definition.row_id}")
        strict_keys(row, ROW_KEYS, f"row {definition.row_id}")
        if (
            row["schema"] != ROW_SCHEMA
            or row["matrix_id"] != matrix_id
            or row["row_id"] != definition.row_id
            or type(row["ordinal"]) is not int
            or row["ordinal"] != definition.ordinal
            or row["scenario"] != definition.scenario
        ):
            fail(f"row {definition.row_id} identity or scenario drifted")
        if row["status"] != "completed":
            fail(f"row {definition.row_id} is not completed")
        row_run_id = string_value(row["row_run_id"], f"row {definition.row_id}.row_run_id")
        if ID_RE.fullmatch(row_run_id) is None or row_run_id in seen_run_ids:
            fail(f"row {definition.row_id} has a malformed or reused row_run_id")
        seen_run_ids.add(row_run_id)

        row_candidate = object_value(row["candidate"], f"row {definition.row_id}.candidate")
        strict_keys(row_candidate, ROW_CANDIDATE_KEYS, f"row {definition.row_id}.candidate")
        if row_candidate != {
            "provenance_sha256": provenance_hash,
            "extension_cdhash": extension_cdhash,
        }:
            fail(f"row {definition.row_id} is not bound to the exact matrix candidate")
        if row["required_authorization_actions"] != list(definition.required_actions):
            fail(f"row {definition.row_id} authorization scope drifted")

        authorization = object_value(row["authorization"], f"row {definition.row_id}.authorization")
        strict_keys(authorization, AUTHORIZATION_KEYS, f"row {definition.row_id}.authorization")
        authorization_id = string_value(authorization["id"], f"row {definition.row_id}.authorization.id")
        if ID_RE.fullmatch(authorization_id) is None or authorization_id in seen_authorization_ids:
            fail(f"row {definition.row_id} authorization is malformed or reused")
        seen_authorization_ids.add(authorization_id)
        if authorization["actions"] != list(definition.required_actions):
            fail(f"row {definition.row_id} was not separately authorized for its exact actions")
        if (
            boolean_value(authorization["row_only"], f"row {definition.row_id}.authorization.row_only") is not True
            or boolean_value(
                authorization["expires_after_row"],
                f"row {definition.row_id}.authorization.expires_after_row",
            )
            is not True
            or authorization["scope_statement"] != definition.authorization_statement
        ):
            fail(f"row {definition.row_id} authorization is not explicitly row-only")
        authorized_at = parse_utc(
            authorization["granted_at_utc"],
            f"row {definition.row_id}.authorization.granted_at_utc",
        )

        timing = object_value(row["timing"], f"row {definition.row_id}.timing")
        strict_keys(timing, TIMING_KEYS, f"row {definition.row_id}.timing")
        started_at = parse_utc(timing["started_at_utc"], f"row {definition.row_id}.started_at_utc")
        completed_at = parse_utc(timing["completed_at_utc"], f"row {definition.row_id}.completed_at_utc")
        if not authorized_at <= started_at < completed_at:
            fail(f"row {definition.row_id} was not authorized before its bounded execution")

        evidence = object_value(row["evidence"], f"row {definition.row_id}.evidence")
        strict_keys(evidence, EVIDENCE_KEYS, f"row {definition.row_id}.evidence")
        artifacts: dict[str, tuple[Path, str, str, str]] = {}
        for kind in ("host_log", "operator_attestation"):
            artifact = object_value(evidence[kind], f"row {definition.row_id}.evidence.{kind}")
            strict_keys(artifact, ARTIFACT_KEYS, f"row {definition.row_id}.evidence.{kind}")
            artifact_path, relative_path = resolve_evidence_file(
                root,
                artifact["path"],
                f"row {definition.row_id}.evidence.{kind}",
            )
            artifact_hash = string_value(
                artifact["sha256"],
                f"row {definition.row_id}.evidence.{kind}.sha256",
            )
            if SHA256_RE.fullmatch(artifact_hash) is None or sha256(artifact_path) != artifact_hash:
                fail(f"row {definition.row_id} {kind} hash is malformed or does not match")
            if relative_path in seen_artifact_paths or artifact_hash in seen_artifact_hashes:
                fail(f"row {definition.row_id} reuses evidence from another row or evidence kind")
            seen_artifact_paths.add(relative_path)
            seen_artifact_hashes.add(artifact_hash)
            artifacts[kind] = (
                artifact_path,
                relative_path,
                artifact_hash,
                read_text_artifact(artifact_path, f"row {definition.row_id} {kind}"),
            )

        observations = object_value(row["observations"], f"row {definition.row_id}.observations")
        strict_keys(observations, OBSERVATION_KEYS, f"row {definition.row_id}.observations")
        if observations["activation_expected"] is not definition.activation_expected:
            fail(f"row {definition.row_id} activation expectation drifted")
        checks = object_value(observations["checks"], f"row {definition.row_id}.checks")
        if frozenset(checks) != frozenset(definition.required_checks):
            fail(f"row {definition.row_id} scenario checks are missing, extra, or renamed")
        for name in definition.required_checks:
            boolean_value(checks[name], f"row {definition.row_id}.checks.{name}")
        for key in OBSERVATION_KEYS - {"host_activity_states", "checks"}:
            boolean_value(observations[key], f"row {definition.row_id}.{key}")
        if (
            observations["camera_opened"]
            or observations["tcc_action"]
            or observations["raw_frame_or_content_evidence"]
        ):
            fail(f"row {definition.row_id} crossed the camera/TCC/content boundary")

        host_states = parse_host_log(artifacts["host_log"][3], f"row {definition.row_id} host_log")
        declared_states = observations["host_activity_states"]
        if (
            not isinstance(declared_states, list)
            or any(state not in HOST_STATES for state in declared_states)
            or declared_states != host_states
        ):
            fail(f"row {definition.row_id} declared host states do not exactly match its log")

        activation_observed = observations["activation_observed"]
        foreground_observed = "running-foreground" in host_states
        if definition.activation_expected and checks.get("active-running-foreground") is not (
            activation_observed and foreground_observed
        ):
            fail(f"row {definition.row_id} active-running-foreground check contradicts its evidence")
        if "timely-teardown" in checks and checks["timely-teardown"] is not observations["teardown_observed"]:
            fail(f"row {definition.row_id} timely-teardown check contradicts its observation")
        if definition.row_id == "chooser-only" and checks["chooser-inactive"] is not (
            not activation_observed and "inactive" in host_states and not foreground_observed
        ):
            fail("chooser-only inactive check contradicts its activation/host-state evidence")

        attestation = parse_attestation(
            artifacts["operator_attestation"][3],
            f"row {definition.row_id} operator_attestation",
        )
        expected_attestation = {
            "schema": ATTESTATION_SCHEMA,
            "matrix_id": matrix_id,
            "row_id": definition.row_id,
            "row_run_id": row_run_id,
            "camera_opened": bool_text(observations["camera_opened"]),
            "tcc_action": bool_text(observations["tcc_action"]),
            "raw_frame_or_content_evidence": bool_text(
                observations["raw_frame_or_content_evidence"]
            ),
            "unexpected_prompt": bool_text(observations["unexpected_prompt"]),
            "focus_theft": bool_text(observations["focus_theft"]),
            "loop_or_crash": bool_text(observations["loop_or_crash"]),
            "interpretation_unambiguous": bool_text(
                object_value(row["interpretation"], f"row {definition.row_id}.interpretation").get(
                    "unambiguous"
                )
            ),
        }
        if attestation != expected_attestation:
            fail(f"row {definition.row_id} operator attestation does not match its observations")

        interpretation = object_value(row["interpretation"], f"row {definition.row_id}.interpretation")
        strict_keys(interpretation, INTERPRETATION_KEYS, f"row {definition.row_id}.interpretation")
        if boolean_value(interpretation["unambiguous"], f"row {definition.row_id}.unambiguous") is not True:
            fail(f"row {definition.row_id} interpretation is ambiguous")
        verdict = interpretation["verdict"]
        if verdict not in ("candidate-supported", "candidate-rejected"):
            fail(f"row {definition.row_id} has no final candidate verdict")
        reasons = expected_rejection_reasons(definition, observations, checks, host_states)
        if interpretation["rejection_reasons"] != list(reasons):
            fail(f"row {definition.row_id} rejection reasons are incomplete or non-deterministic")
        expected_verdict = "candidate-rejected" if reasons else "candidate-supported"
        if verdict != expected_verdict:
            fail(f"row {definition.row_id} verdict contradicts its evidence")

        verified_rows.append(
            VerifiedRow(
                definition,
                row_run_id,
                authorization_id,
                (artifacts["host_log"][1], artifacts["operator_attestation"][1]),
                (artifacts["host_log"][2], artifacts["operator_attestation"][2]),
                sha256(row_path),
                verdict,
                reasons,
            )
        )

    row_directory = root / "rows"
    actual_row_json = {
        path.relative_to(root).as_posix()
        for path in row_directory.glob("*.json")
        if path.is_file() and not path.is_symlink()
    }
    expected_row_json = {definition.filename for definition in ROWS}
    if actual_row_json != expected_row_json:
        fail("C6 row directory contains missing or unmanifested JSON row evidence")

    return VerifiedMatrix(
        root=root,
        matrix_id=matrix_id,
        candidate_provenance_sha256=provenance_hash,
        extension_cdhash=extension_cdhash,
        matrix_manifest_sha256=sha256(manifest_path),
        rows=tuple(verified_rows),
    )
