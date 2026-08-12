#!/usr/bin/python3

"""Replay one privacy-safe, topology-equivalent Gate A1T/A1TR lifecycle."""

from __future__ import annotations

import hashlib
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


class EvidenceFailure(Exception):
    pass


@dataclass(frozen=True)
class AgentEvent:
    line: int
    timestamp: float
    pid: int
    name: str
    fields: Dict[str, str]


@dataclass(frozen=True)
class Receipt:
    line: int
    timestamp: float
    saver_pid: int
    state: str
    epoch: Optional[int]
    sequence: Optional[int]
    instance: str


@dataclass(frozen=True)
class HostedGateMarker:
    line: int
    timestamp: float
    saver_pid: int
    instance: str


@dataclass(frozen=True)
class HostedGatePreflight:
    line: int
    timestamp: float
    saver_pid: int
    helper_pid: int


@dataclass(frozen=True)
class Animation:
    line: int
    timestamp: float
    saver_pid: int
    state: str
    instance: str


PID_PATTERN = re.compile(r"IdleScreenCameraAgent\[(?P<pid>[1-9][0-9]*):")
SAVER_PID_PATTERN = re.compile(r"IdleScreenScreenSaver\[(?P<pid>[1-9][0-9]*):")
AGENT_NAMESPACE = "[com.idlescreen.camera-agent:"
SAVER_NAMESPACE = "[com.idlescreen.screensaver:"
SAVER_VIEW_NAMESPACE = "[com.idlescreen.screensaver:View]"
SAVER_GATE_NAMESPACE = "[com.idlescreen.screensaver:SyntheticHostedGate]"
LOG_TIMESTAMP_PATTERN = re.compile(
    r"^(?P<timestamp>[0-9]{4}-[0-9]{2}-[0-9]{2} "
    r"[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3,6})"
    r"(?P<timezone>[+-][0-9]{4})?\s"
)
COMPACT_TIMESTAMP_PATTERN = re.compile(
    r"(?P<timestamp>[0-9]{4}-[0-9]{2}-[0-9]{2} "
    r"[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3,6})"
    r"(?P<timezone>[+-][0-9]{4})?"
)

AGENT_MESSAGES: Tuple[Tuple[str, re.Pattern[str]], ...] = (
    (
        "authorization_status",
        re.compile(
            r"authorization_status status=(?P<status>not-determined|restricted|denied|authorized) "
            r"source=(?P<source>startup|status-refresh|explicit-request-completion|runtime-observation)"
        ),
    ),
    (
        "peer_identity_rejected",
        re.compile(
            r"peer_identity_rejected pid=(?P<peer_pid>-?[0-9]+) "
            r"reason=(?P<reason>identity-unavailable|policy|identifier-exhausted)"
        ),
    ),
    (
        "peer_admission_rejected",
        re.compile(
            r"peer_admission_rejected pid=(?P<peer_pid>-?[0-9]+) team_id=(?P<team_id>[A-Za-z0-9]+) "
            r"bundle_id=(?P<bundle_id>[A-Za-z0-9.-]+) role=(?P<role>companion|screen-saver|unrecognized) "
            r"reason=(?P<reason>identity-unavailable|policy|identifier-exhausted)"
        ),
    ),
    (
        "peer_admission_accepted",
        re.compile(
            r"peer_admission_accepted connection_id=(?P<connection_id>[A-Za-z0-9-]{1,128}) "
            r"pid=(?P<peer_pid>[1-9][0-9]*) team_id=(?P<team_id>[A-Za-z0-9]+) "
            r"bundle_id=(?P<bundle_id>[A-Za-z0-9.-]+) role=(?P<role>companion|screen-saver|unrecognized)"
        ),
    ),
    (
        "connection_invalidated",
        re.compile(
            r"connection_invalidated connection_id=(?P<connection_id>[A-Za-z0-9-]{1,128}) "
            r"pid=(?P<peer_pid>[1-9][0-9]*) team_id=(?P<team_id>[A-Za-z0-9]+) "
            r"bundle_id=(?P<bundle_id>[A-Za-z0-9.-]+) role=(?P<role>companion|screen-saver|unrecognized)"
        ),
    ),
    (
        "lease_count_changed",
        re.compile(
            r"lease_count_changed previous=(?P<previous>[0-9]+) current=(?P<current>[0-9]+) "
            r"epoch=(?P<epoch>[1-9][0-9]*)"
        ),
    ),
    (
        "capture_start_requested",
        re.compile(
            r"capture_start_requested generation=(?P<generation>[1-9][0-9]*) epoch=(?P<epoch>[1-9][0-9]*)"
        ),
    ),
    (
        "capture_started",
        re.compile(
            r"capture_started generation=(?P<generation>[1-9][0-9]*) epoch=(?P<epoch>[1-9][0-9]*)"
        ),
    ),
    (
        "first_frame_published",
        re.compile(
            r"first_frame_published generation=(?P<generation>[1-9][0-9]*) "
            r"epoch=(?P<epoch>[1-9][0-9]*) sequence=(?P<sequence>[1-9][0-9]*)"
        ),
    ),
    (
        "capture_stop_requested",
        re.compile(
            r"capture_stop_requested generation=(?P<generation>[1-9][0-9]*) epoch=(?P<epoch>[1-9][0-9]*)"
        ),
    ),
    (
        "capture_stopped",
        re.compile(
            r"capture_stopped generation=(?P<generation>[1-9][0-9]*) epoch=(?P<epoch>[1-9][0-9]*)"
        ),
    ),
    (
        "capture_interrupted",
        re.compile(
            r"capture_interrupted generation=(?P<generation>[1-9][0-9]*) epoch=(?P<epoch>[1-9][0-9]*)"
        ),
    ),
    (
        "capture_runtime_error",
        re.compile(
            r"capture_runtime_error generation=(?P<generation>[1-9][0-9]*) epoch=(?P<epoch>[1-9][0-9]*)"
        ),
    ),
    (
        "recovery_failure",
        re.compile(
            r"recovery_failure generation=(?P<generation>[1-9][0-9]*) epoch=(?P<epoch>[1-9][0-9]*) "
            r"cause=(?P<cause>[a-z-]+)"
        ),
    ),
    (
        "recovery_retry_scheduled",
        re.compile(
            r"recovery_retry_scheduled generation=(?P<generation>[1-9][0-9]*) epoch=(?P<epoch>[1-9][0-9]*)"
        ),
    ),
    (
        "recovery_retry_started",
        re.compile(
            r"recovery_retry_started generation=(?P<generation>[1-9][0-9]*) epoch=(?P<epoch>[1-9][0-9]*)"
        ),
    ),
)

RECEIPT_MESSAGE = re.compile(
    r"Camera receipt state=(?:(?P<available>available) epoch=(?P<epoch>[1-9][0-9]*) "
    r"sequence=(?P<sequence>[1-9][0-9]*)|(?P<fallback>fallback-unavailable)) "
    r"instance=(?P<instance>[A-Za-z0-9.-]+) display=(?:unknown|[0-9]+)"
)
SAVER_ANIMATION_MESSAGE = re.compile(
    r"Animation (?P<state>started|stopped) preview=false "
    r"instance=(?P<instance>[A-Za-z0-9.-]+) display=(?:unknown|[0-9]+)"
)
HOSTED_GATE_MESSAGE = re.compile(
    r"Synthetic hosted gate loaded topology-equivalent=true "
    r"trusted-for-production=false pid=(?P<declared_pid>[1-9][0-9]*) "
    r"instance=(?P<instance>[A-Za-z0-9.-]+) preview=false"
)
HOSTED_GATE_PREFLIGHT_MESSAGE = re.compile(
    r"Synthetic hosted gate preflight helper_pid=(?P<helper_pid>[1-9][0-9]*) "
    r"accepted=true active_lease_count=0 capture_active=false"
)

UNSAFE_EVIDENCE = re.compile(
    r"raw[ _-]*(?:frame|image|pixel|bytes|data)|"
    r"(?:frame|image|pixel)[ _-]*(?:payload|bytes|data|buffer|sample)|"
    r"glyph|checksum|jpeg|png|data.?url|cvpixelbuffer|base64|"
    r"\bpayload\b|\bhex\b|"
    r"screenshot(?!\s*=\s*false)|"
    r"(?:permission|tcc)[ _-]*prompt|settings[ _-]*focus|focus[ _-]*(?:stolen|changed)",
    re.IGNORECASE,
)

REJECTED_EVENTS = {
    "peer_identity_rejected",
    "peer_admission_rejected",
    "capture_interrupted",
    "capture_runtime_error",
    "recovery_failure",
    "recovery_retry_scheduled",
    "recovery_retry_started",
}


def fail(message: str) -> None:
    raise EvidenceFailure(message)


def message_after_namespace(line: str, namespace: str) -> str:
    namespace_start = line.find(namespace)
    closing = line.find("] ", namespace_start)
    if closing < 0:
        fail(f"malformed structured log namespace: {line.rstrip()}")
    return line[closing + 2 :].strip()


def parse_compact_timestamp(value: str, label: str) -> float:
    match = COMPACT_TIMESTAMP_PATTERN.fullmatch(value)
    if match is None:
        fail(f"{label} lacks a replayable millisecond timestamp")
    try:
        timestamp_text = match.group("timestamp")
        timezone_text = match.group("timezone")
        if timezone_text:
            parsed = datetime.strptime(
                timestamp_text + timezone_text,
                "%Y-%m-%d %H:%M:%S.%f%z",
            )
        else:
            parsed = datetime.strptime(timestamp_text, "%Y-%m-%d %H:%M:%S.%f").replace(
                tzinfo=timezone.utc
            )
        return parsed.timestamp()
    except ValueError:
        fail(f"{label} has an invalid timestamp")
    raise AssertionError("unreachable")


def structured_timestamp(line: str, line_number: int) -> float:
    match = LOG_TIMESTAMP_PATTERN.match(line)
    if not match:
        fail(f"line {line_number} lacks a replayable millisecond timestamp")
    value = match.group("timestamp") + (match.group("timezone") or "")
    return parse_compact_timestamp(value, f"line {line_number}")


def parse(
    lines: Iterable[str],
) -> Tuple[
    List[AgentEvent],
    List[Receipt],
    List[HostedGateMarker],
    List[HostedGatePreflight],
    List[Animation],
]:
    events: List[AgentEvent] = []
    receipts: List[Receipt] = []
    hosted_gate_markers: List[HostedGateMarker] = []
    hosted_gate_preflights: List[HostedGatePreflight] = []
    animations: List[Animation] = []
    previous_timestamp: Optional[float] = None
    for line_number, line in enumerate(lines, start=1):
        unsafe = UNSAFE_EVIDENCE.search(line)
        if unsafe:
            fail(
                f"line {line_number} contains forbidden evidence token '{unsafe.group(0)}'"
            )

        if AGENT_NAMESPACE in line:
            timestamp = structured_timestamp(line, line_number)
            if previous_timestamp is not None and timestamp < previous_timestamp:
                fail(f"structured timestamp moved backward at line {line_number}")
            previous_timestamp = timestamp
            pid_match = PID_PATTERN.search(line)
            if not pid_match:
                fail(
                    f"line {line_number} has agent diagnostics without an exact helper PID"
                )
            message = message_after_namespace(line, AGENT_NAMESPACE)
            parsed: Optional[AgentEvent] = None
            for name, pattern in AGENT_MESSAGES:
                match = pattern.fullmatch(message)
                if match:
                    parsed = AgentEvent(
                        line=line_number,
                        timestamp=timestamp,
                        pid=int(pid_match.group("pid")),
                        name=name,
                        fields=match.groupdict(),
                    )
                    break
            if parsed is None:
                fail(
                    f"line {line_number} is not in the camera-agent evidence whitelist"
                )
            if parsed.name in REJECTED_EVENTS:
                fail(f"line {line_number} contains rejected event {parsed.name}")
            events.append(parsed)

        if SAVER_NAMESPACE in line:
            timestamp = structured_timestamp(line, line_number)
            if previous_timestamp is not None and timestamp < previous_timestamp:
                fail(f"structured timestamp moved backward at line {line_number}")
            previous_timestamp = timestamp
            saver_pid_match = SAVER_PID_PATTERN.search(line)
            if not saver_pid_match:
                fail(
                    f"line {line_number} has saver evidence without an exact hosted PID"
                )
            message = message_after_namespace(line, SAVER_NAMESPACE)
            if SAVER_GATE_NAMESPACE in line:
                preflight_match = HOSTED_GATE_PREFLIGHT_MESSAGE.fullmatch(message)
                if preflight_match:
                    hosted_gate_preflights.append(
                        HostedGatePreflight(
                            line=line_number,
                            timestamp=timestamp,
                            saver_pid=int(saver_pid_match.group("pid")),
                            helper_pid=int(preflight_match.group("helper_pid")),
                        )
                    )
                    continue
                match = HOSTED_GATE_MESSAGE.fullmatch(message)
                if not match:
                    fail(
                        f"line {line_number} is not in the hosted-gate evidence whitelist"
                    )
                if int(match.group("declared_pid")) != int(
                    saver_pid_match.group("pid")
                ):
                    fail(
                        f"line {line_number} hosted-gate payload PID differs from its log PID"
                    )
                hosted_gate_markers.append(
                    HostedGateMarker(
                        line=line_number,
                        timestamp=timestamp,
                        saver_pid=int(saver_pid_match.group("pid")),
                        instance=match.group("instance"),
                    )
                )
                continue
            if SAVER_VIEW_NAMESPACE not in line:
                fail(f"line {line_number} uses an unexpected saver evidence category")
            if "Camera receipt state=" not in message:
                animation_match = SAVER_ANIMATION_MESSAGE.fullmatch(message)
                if not animation_match:
                    fail(f"line {line_number} is not in the saver evidence whitelist")
                animations.append(
                    Animation(
                        line=line_number,
                        timestamp=timestamp,
                        saver_pid=int(saver_pid_match.group("pid")),
                        state=animation_match.group("state"),
                        instance=animation_match.group("instance"),
                    )
                )
                continue
            match = RECEIPT_MESSAGE.fullmatch(message)
            if not match:
                fail(
                    f"line {line_number} is not in the hosted-receipt evidence whitelist"
                )
            available = match.group("available") is not None
            receipts.append(
                Receipt(
                    line=line_number,
                    timestamp=timestamp,
                    saver_pid=int(saver_pid_match.group("pid")),
                    state="available" if available else "fallback",
                    epoch=int(match.group("epoch")) if available else None,
                    sequence=int(match.group("sequence")) if available else None,
                    instance=match.group("instance"),
                )
            )
    return events, receipts, hosted_gate_markers, hosted_gate_preflights, animations


def first_event(
    events: List[AgentEvent],
    *,
    pid: int,
    name: str,
    after: int,
    fields: Optional[Dict[str, str]] = None,
) -> AgentEvent:
    fields = fields or {}
    for event in events:
        if event.line <= after or event.pid != pid or event.name != name:
            continue
        if all(event.fields.get(key) == value for key, value in fields.items()):
            return event
    details = ", ".join(f"{key}={value}" for key, value in fields.items())
    fail(
        f"missing ordered {name} for helper PID {pid}"
        + (f" ({details})" if details else "")
    )
    raise AssertionError("unreachable")


@dataclass(frozen=True)
class RunningProof:
    pid: int
    epoch: int
    generation: int
    connection_id: str
    peer_pid: str
    saver_pid: int
    instance: str
    first_line: int
    first_timestamp: float
    third_receipt_line: int
    third_receipt_timestamp: float
    last_receipt_line: int


def prove_running_incarnation(
    events: List[AgentEvent],
    receipts: List[Receipt],
    animations: List[Animation],
    *,
    pid: int,
    after: int,
    before: Optional[int] = None,
    enforce_activation_deadlines: bool = False,
) -> RunningProof:
    lease = first_event(
        events,
        pid=pid,
        name="lease_count_changed",
        after=after,
        fields={"previous": "0", "current": "1"},
    )
    admissions = [
        event
        for event in events
        if event.pid == pid
        and event.name == "peer_admission_accepted"
        and event.fields.get("role") == "screen-saver"
        and after < event.line < lease.line
    ]
    if not admissions:
        fail(f"missing ordered peer_admission_accepted for helper PID {pid}")
    admission = admissions[-1]
    epoch = int(lease.fields["epoch"])
    start_requested = first_event(
        events,
        pid=pid,
        name="capture_start_requested",
        after=lease.line,
        fields={"epoch": str(epoch)},
    )
    generation = int(start_requested.fields["generation"])
    started = first_event(
        events,
        pid=pid,
        name="capture_started",
        after=start_requested.line,
        fields={"epoch": str(epoch), "generation": str(generation)},
    )
    first_frame = first_event(
        events,
        pid=pid,
        name="first_frame_published",
        after=started.line,
        fields={"epoch": str(epoch), "generation": str(generation)},
    )
    first_sequence = int(first_frame.fields["sequence"])

    candidates = [
        receipt
        for receipt in receipts
        if receipt.state == "available"
        and receipt.saver_pid == int(admission.fields["peer_pid"])
        and receipt.epoch == epoch
        and receipt.line > first_frame.line
        and (before is None or receipt.line < before)
    ]
    by_instance: Dict[str, List[Receipt]] = {}
    for receipt in candidates:
        by_instance.setdefault(receipt.instance, []).append(receipt)

    qualifying: List[List[Receipt]] = []
    for instance_receipts in by_instance.values():
        previous = 0
        for receipt in instance_receipts:
            assert receipt.sequence is not None
            if receipt.sequence <= previous:
                fail(
                    f"hosted receipt sequence did not strictly increase for instance "
                    f"{receipt.instance} at line {receipt.line}"
                )
            previous = receipt.sequence
        if (
            len(instance_receipts) >= 3
            and instance_receipts[0].sequence >= first_sequence
        ):
            qualifying.append(instance_receipts)
    if not qualifying:
        fail(
            f"helper PID {pid} has no saver instance with three strictly increasing receipts"
        )
    chosen = min(qualifying, key=lambda candidate: candidate[2].line)
    if enforce_activation_deadlines:
        matching_starts = [
            animation
            for animation in animations
            if animation.state == "started"
            and animation.saver_pid == int(admission.fields["peer_pid"])
            and animation.instance == chosen[0].instance
            and animation.line < admission.line
        ]
        if not matching_starts:
            fail("missing matching hosted Animation started boundary")
        host_start = matching_starts[-1]
        deadlines = (
            (admission.timestamp, 2.0, "screen-saver admission"),
            (lease.timestamp, 2.0, "screen-saver lease"),
            (chosen[0].timestamp, 5.0, "first hosted receipt"),
            (chosen[2].timestamp, 5.0, "third hosted receipt"),
        )
        for timestamp, limit, description in deadlines:
            elapsed = timestamp - host_start.timestamp
            if elapsed < 0 or elapsed > limit:
                fail(f"{description} exceeded its {limit:g}-second deadline")
    last_line = max(receipt.line for receipt in candidates)
    return RunningProof(
        pid=pid,
        epoch=epoch,
        generation=generation,
        connection_id=admission.fields["connection_id"],
        peer_pid=admission.fields["peer_pid"],
        saver_pid=int(admission.fields["peer_pid"]),
        instance=chosen[0].instance,
        first_line=admission.line,
        first_timestamp=admission.timestamp,
        third_receipt_line=chosen[2].line,
        third_receipt_timestamp=chosen[2].timestamp,
        last_receipt_line=last_line,
    )


def prove_cleanup(events: List[AgentEvent], proof: RunningProof) -> int:
    invalidated = first_event(
        events,
        pid=proof.pid,
        name="connection_invalidated",
        after=proof.last_receipt_line,
        fields={
            "connection_id": proof.connection_id,
            "peer_pid": proof.peer_pid,
            "role": "screen-saver",
        },
    )
    lease_zero = first_event(
        events,
        pid=proof.pid,
        name="lease_count_changed",
        after=invalidated.line,
        fields={"previous": "1", "current": "0", "epoch": str(proof.epoch)},
    )
    stop_requested = first_event(
        events,
        pid=proof.pid,
        name="capture_stop_requested",
        after=lease_zero.line,
        fields={"generation": str(proof.generation), "epoch": str(proof.epoch)},
    )
    stopped = first_event(
        events,
        pid=proof.pid,
        name="capture_stopped",
        after=stop_requested.line,
        fields={"generation": str(proof.generation), "epoch": str(proof.epoch)},
    )
    cleanup_elapsed = stopped.timestamp - invalidated.timestamp
    if cleanup_elapsed < 0 or cleanup_elapsed > 2.0:
        fail("final producer stop exceeded the 2-second cleanup deadline")
    return stopped.line


def require_hosted_gate_marker(
    markers: List[HostedGateMarker], proof: RunningProof
) -> HostedGateMarker:
    matching = [
        marker
        for marker in markers
        if (
            marker.saver_pid == proof.saver_pid
            and marker.instance == proof.instance
            and marker.line < proof.third_receipt_line
        )
    ]
    if len(matching) != 1:
        fail(
            "expected exactly one topology-equivalent hosted-gate marker for proven saver "
            f"PID {proof.saver_pid} instance {proof.instance}"
        )
    return matching[0]


def require_authenticated_idle_preflight(
    preflights: List[HostedGatePreflight],
    events: List[AgentEvent],
    proof: RunningProof,
    topology_marker: HostedGateMarker,
) -> None:
    matching = [
        preflight
        for preflight in preflights
        if preflight.saver_pid == proof.saver_pid
        and preflight.helper_pid == proof.pid
        and preflight.line < topology_marker.line
    ]
    if len(matching) != 1:
        fail(
            "expected exactly one authenticated zero-lease hosted preflight for "
            f"saver PID {proof.saver_pid} and helper PID {proof.pid}"
        )
    preflight = matching[0]
    admissions = [
        event
        for event in events
        if event.pid == proof.pid
        and event.name == "peer_admission_accepted"
        and event.fields.get("peer_pid") == str(proof.saver_pid)
        and event.fields.get("role") == "screen-saver"
        and event.line < preflight.line
    ]
    if not admissions:
        fail(
            "hosted idle preflight is not preceded by an authenticated saver admission"
        )
    admission = admissions[-1]
    preflight_elapsed = preflight.timestamp - admission.timestamp
    if preflight_elapsed < 0 or preflight_elapsed > 2.0:
        fail("authenticated hosted idle preflight exceeded the 2-second XPC deadline")
    invalidations = [
        event
        for event in events
        if event.pid == proof.pid
        and event.name == "connection_invalidated"
        and event.fields.get("connection_id") == admission.fields.get("connection_id")
        and event.fields.get("peer_pid") == str(proof.saver_pid)
        and preflight.line < event.line < proof.first_line
    ]
    if len(invalidations) != 1:
        fail(
            "authenticated hosted idle-preflight connection was not cleanly invalidated"
        )


def require_idle_activation_boundary(
    events: List[AgentEvent], proof: RunningProof, helper_class: str
) -> None:
    earlier = next(
        (
            event
            for event in events
            if event.pid == proof.pid
            and event.line < proof.first_line
            and event.name
            not in {
                "authorization_status",
                "peer_admission_accepted",
                "connection_invalidated",
            }
        ),
        None,
    )
    if earlier is not None:
        fail(
            f"{helper_class} helper was not lifecycle-idle before hosted admission; "
            f"found {earlier.name} at line {earlier.line}"
        )


def require_terminal_cleanup(
    events: List[AgentEvent],
    receipts: List[Receipt],
    markers: List[HostedGateMarker],
    preflights: List[HostedGatePreflight],
    animations: List[Animation],
    cleanup_line: int,
) -> None:
    later_event = next((event for event in events if event.line > cleanup_line), None)
    if later_event is not None:
        fail(
            f"helper lifecycle resumed after final cleanup at line {later_event.line} "
            f"({later_event.name})"
        )
    later_receipt = next(
        (receipt for receipt in receipts if receipt.line > cleanup_line), None
    )
    if later_receipt is not None:
        fail(
            f"hosted receipt appeared after final cleanup at line {later_receipt.line}"
        )
    later_marker = next(
        (marker for marker in markers if marker.line > cleanup_line), None
    )
    if later_marker is not None:
        fail(f"hosted gate reloaded after final cleanup at line {later_marker.line}")
    later_preflight = next(
        (preflight for preflight in preflights if preflight.line > cleanup_line), None
    )
    if later_preflight is not None:
        fail(f"hosted gate reprobed after final cleanup at line {later_preflight.line}")
    later_animation = next(
        (animation for animation in animations if animation.line > cleanup_line), None
    )
    if later_animation is not None:
        fail(
            f"host animation resumed after final cleanup at line {later_animation.line}"
        )


MANIFEST_FIELDS = (
    "format",
    "mode",
    "evidence_semantics",
    "trusted_for_production",
    "log_path",
    "log_sha256",
    "helper_marker_path",
    "helper_marker_version",
    "extension_marker_path",
    "extension_marker_version",
    "helper_marker_extract",
    "helper_marker_extract_sha256",
    "extension_marker_extract",
    "extension_marker_extract_sha256",
    "helper_path",
    "helper_cdhash",
    "extension_path",
    "extension_cdhash",
    "helper_codesign_output",
    "helper_codesign_output_sha256",
    "extension_codesign_output",
    "extension_codesign_output_sha256",
    "initial_helper_class",
    "initial_helper_pid",
    "initial_helper_identity",
    "initial_helper_procinfo",
    "initial_helper_procinfo_sha256",
    "saver_pid",
    "saver_identity",
    "saver_procinfo",
    "saver_procinfo_sha256",
    "configuration_snapshot",
    "configuration_snapshot_sha256",
    "fault_termination_timestamp",
    "recovered_helper_pid",
    "recovered_helper_identity",
    "recovered_helper_procinfo",
    "recovered_helper_procinfo_sha256",
)
CONFIGURATION_FIELDS = (
    "format",
    "configuration_path",
    "schema_version",
    "source",
    "device",
    "inode",
    "size",
    "mtime_ns",
    "sha256",
)
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
CDHASH_PATTERN = re.compile(r"[0-9A-Fa-f]{40}")


def parse_key_value_file(
    path: Path, fields: Tuple[str, ...], label: str
) -> Dict[str, str]:
    values: Dict[str, str] = {}
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        if "=" not in raw_line:
            fail(f"malformed {label} line {line_number}")
        key, value = raw_line.split("=", 1)
        if key not in fields or key in values or not value:
            fail(f"unexpected or duplicate {label} field {key!r}")
        values[key] = value
    if tuple(values) != fields:
        fail(f"{label} fields are missing or out of order")
    return values


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_bound_file(
    manifest_path: Path,
    recorded_path: str,
    recorded_sha256: str,
    label: str,
) -> Path:
    path = Path(recorded_path)
    if (
        not path.is_absolute()
        or not path.is_file()
        or path.is_symlink()
        or path.parent.resolve() != manifest_path.parent.resolve()
    ):
        fail(f"{label} is not a regular sibling evidence file")
    if not SHA256_PATTERN.fullmatch(recorded_sha256):
        fail(f"{label} SHA-256 is malformed")
    if sha256_file(path) != recorded_sha256:
        fail(f"{label} differs from its recorded SHA-256")
    return path


def validate_procinfo(
    manifest_path: Path,
    values: Dict[str, str],
    prefix: str,
    pid: int,
    expected_path: str,
    expected_cdhash: str,
) -> None:
    identity = values[f"{prefix}_identity"]
    if not identity.endswith(f" {expected_path}|{expected_cdhash}"):
        fail(f"{prefix} identity does not bind its start time, path, and CDHash")
    procinfo = require_bound_file(
        manifest_path,
        values[f"{prefix}_procinfo"],
        values[f"{prefix}_procinfo_sha256"],
        f"{prefix} procinfo",
    )
    procinfo_text = procinfo.read_text(encoding="utf-8")
    if (
        f"pid={pid}\n" not in procinfo_text
        or "entitlements validated" not in procinfo_text
    ):
        fail(f"{prefix} procinfo does not bind PID {pid} with validated entitlements")


def parse_evidence_manifest(
    mode: str, log_path: Path, manifest_path: Path
) -> Tuple[int, Optional[int], int, str, Optional[float]]:
    if (
        not manifest_path.is_absolute()
        or not manifest_path.is_file()
        or manifest_path.is_symlink()
        or manifest_path.parent.resolve() != log_path.parent.resolve()
    ):
        fail("evidence manifest must be a regular sibling of the combined log")
    values = parse_key_value_file(manifest_path, MANIFEST_FIELDS, "evidence manifest")
    fixed_values = {
        "format": "IdleScreenCameraGateEvidenceV1",
        "mode": mode,
        "evidence_semantics": "topology-equivalent-a1t",
        "trusted_for_production": "false",
        "helper_marker_version": "1",
        "extension_marker_version": "1",
    }
    for key, expected in fixed_values.items():
        if values[key] != expected:
            fail(f"evidence manifest {key} must equal {expected!r}")
    if values["log_path"] != str(log_path):
        fail("evidence manifest does not name the exact combined log")
    if not SHA256_PATTERN.fullmatch(values["log_sha256"]):
        fail("evidence manifest log SHA-256 is malformed")
    if sha256_file(log_path) != values["log_sha256"]:
        fail("combined log differs from its recorded SHA-256")
    expected_helper_path = (
        "/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/"
        "Contents/MacOS/IdleScreenCameraAgent"
    )
    expected_extension_path = (
        "/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/"
        "Contents/MacOS/IdleScreenScreenSaver"
    )
    if values["helper_path"] != expected_helper_path:
        fail("evidence manifest does not name the exact installed helper path")
    if values["extension_path"] != expected_extension_path:
        fail("evidence manifest does not name the exact installed extension path")
    if values["helper_marker_path"] != str(
        Path(expected_helper_path).parents[1] / "Info.plist"
    ):
        fail("evidence manifest helper marker path is not exact")
    if values["extension_marker_path"] != str(
        Path(expected_extension_path).parents[1] / "Info.plist"
    ):
        fail("evidence manifest extension marker path is not exact")
    if not CDHASH_PATTERN.fullmatch(values["helper_cdhash"]):
        fail("evidence manifest helper CDHash is malformed")
    if not CDHASH_PATTERN.fullmatch(values["extension_cdhash"]):
        fail("evidence manifest extension CDHash is malformed")
    helper_marker_extract = require_bound_file(
        manifest_path,
        values["helper_marker_extract"],
        values["helper_marker_extract_sha256"],
        "helper marker extract",
    )
    extension_marker_extract = require_bound_file(
        manifest_path,
        values["extension_marker_extract"],
        values["extension_marker_extract_sha256"],
        "extension marker extract",
    )
    for extract, marker_path, marker_key, label in (
        (
            helper_marker_extract,
            values["helper_marker_path"],
            "IdleScreenSyntheticGateVersion",
            "helper",
        ),
        (
            extension_marker_extract,
            values["extension_marker_path"],
            "IdleScreenSyntheticHostedGateVersion",
            "extension",
        ),
    ):
        marker_values = parse_key_value_file(
            extract,
            ("marker_path", "marker_key", "marker_value"),
            f"{label} marker extract",
        )
        if marker_values != {
            "marker_path": marker_path,
            "marker_key": marker_key,
            "marker_value": "1",
        }:
            fail(f"{label} marker extract does not preserve the exact marker")
    helper_codesign = require_bound_file(
        manifest_path,
        values["helper_codesign_output"],
        values["helper_codesign_output_sha256"],
        "helper codesign output",
    ).read_text(encoding="utf-8")
    extension_codesign = require_bound_file(
        manifest_path,
        values["extension_codesign_output"],
        values["extension_codesign_output_sha256"],
        "extension codesign output",
    ).read_text(encoding="utf-8")
    for output, identifier, cdhash, label in (
        (
            helper_codesign,
            "com.idlescreen.camera-agent",
            values["helper_cdhash"],
            "helper",
        ),
        (
            extension_codesign,
            "com.idlescreen.app.screensaver",
            values["extension_cdhash"],
            "extension",
        ),
    ):
        if (
            f"Identifier={identifier}\n" not in output
            or f"CDHash={cdhash}\n" not in output
            or not re.search(r"^TeamIdentifier=[A-Z0-9]{10}$", output, re.MULTILINE)
        ):
            fail(f"{label} codesign output does not bind identifier, Team, and CDHash")
    if values["initial_helper_class"] not in ("absent-cold", "warm-idle-bootstrapped"):
        fail("evidence manifest helper preflight classification is invalid")
    try:
        initial_pid = int(values["initial_helper_pid"])
        saver_pid = int(values["saver_pid"])
    except ValueError:
        fail("evidence manifest contains a malformed runtime PID")
    if initial_pid <= 0 or saver_pid <= 0:
        fail("evidence manifest runtime PIDs must be positive")
    validate_procinfo(
        manifest_path,
        values,
        "initial_helper",
        initial_pid,
        expected_helper_path,
        values["helper_cdhash"],
    )
    validate_procinfo(
        manifest_path,
        values,
        "saver",
        saver_pid,
        expected_extension_path,
        values["extension_cdhash"],
    )
    configuration_path = require_bound_file(
        manifest_path,
        values["configuration_snapshot"],
        values["configuration_snapshot_sha256"],
        "configuration snapshot",
    )
    configuration = parse_key_value_file(
        configuration_path, CONFIGURATION_FIELDS, "configuration snapshot"
    )
    if configuration["format"] != "IdleScreenCameraGateConfigurationV1":
        fail("configuration snapshot format is unsupported")
    if not re.fullmatch(
        r"/Users/[^/]+/Library/Group Containers/group\.com\.idlescreen\.shared/"
        r"configuration\.json",
        configuration["configuration_path"],
    ):
        fail("configuration snapshot does not name the real group-container path")
    if configuration["schema_version"] not in ("0", "1"):
        fail("configuration snapshot schema is unsupported")
    if configuration["source"] not in ("camera", "hybrid"):
        fail("configuration snapshot is not camera-backed")
    for key in ("device", "inode", "size", "mtime_ns"):
        if not configuration[key].isdigit():
            fail(f"configuration snapshot {key} is malformed")
    if not SHA256_PATTERN.fullmatch(configuration["sha256"]):
        fail("configuration snapshot content SHA-256 is malformed")

    recovered_pid: Optional[int] = None
    fault_termination_timestamp: Optional[float] = None
    if mode == "a1tr":
        try:
            recovered_pid = int(values["recovered_helper_pid"])
        except ValueError:
            fail("A1TR recovered helper PID is malformed")
        if recovered_pid <= 0 or recovered_pid == initial_pid:
            fail("A1TR requires one distinct recovered helper PID")
        fault_termination_timestamp = parse_compact_timestamp(
            values["fault_termination_timestamp"], "A1TR fault termination timestamp"
        )
        validate_procinfo(
            manifest_path,
            values,
            "recovered_helper",
            recovered_pid,
            expected_helper_path,
            values["helper_cdhash"],
        )
    elif values["fault_termination_timestamp"] != "none" or any(
        values[key] != "none"
        for key in (
            "recovered_helper_pid",
            "recovered_helper_identity",
            "recovered_helper_procinfo",
            "recovered_helper_procinfo_sha256",
        )
    ):
        fail("A1T evidence manifest unexpectedly names a recovered helper")
    return (
        initial_pid,
        recovered_pid,
        saver_pid,
        values["initial_helper_class"],
        fault_termination_timestamp,
    )


def verify(mode: str, path: Path, manifest_path: Path) -> None:
    (
        initial_pid,
        recovered_pid,
        manifest_saver_pid,
        initial_helper_class,
        fault_termination_timestamp,
    ) = parse_evidence_manifest(mode, path, manifest_path)
    (
        events,
        receipts,
        hosted_gate_markers,
        hosted_gate_preflights,
        animations,
    ) = parse(path.read_text(encoding="utf-8").splitlines())
    if not events:
        fail("no structured camera-agent events")
    if not receipts:
        fail("no structured hosted receipts")

    allowed_pids = {initial_pid}
    if recovered_pid is not None:
        allowed_pids.add(recovered_pid)
    observed_pids = {event.pid for event in events}
    unexpected_pids = observed_pids - allowed_pids
    if unexpected_pids:
        fail(f"unexpected helper diagnostic PID(s): {sorted(unexpected_pids)}")

    if mode == "a1t":
        initial = prove_running_incarnation(
            events,
            receipts,
            animations,
            pid=initial_pid,
            after=0,
            enforce_activation_deadlines=True,
        )
        if initial.saver_pid != manifest_saver_pid:
            fail("admitted saver PID differs from the evidence manifest")
        require_idle_activation_boundary(events, initial, initial_helper_class)
        topology_marker = require_hosted_gate_marker(hosted_gate_markers, initial)
        require_authenticated_idle_preflight(
            hosted_gate_preflights, events, initial, topology_marker
        )
        cleanup_line = prove_cleanup(events, initial)
        require_terminal_cleanup(
            events,
            receipts,
            hosted_gate_markers,
            hosted_gate_preflights,
            animations,
            cleanup_line,
        )
        return

    assert recovered_pid is not None
    if initial_pid == recovered_pid:
        fail("A1TR reused the initial helper PID")
    # Find an initial proof whose third receipt precedes a fallback, then bind
    # the recovered incarnation to the first such fallback boundary.
    initial = prove_running_incarnation(
        events,
        receipts,
        animations,
        pid=initial_pid,
        after=0,
        enforce_activation_deadlines=True,
    )
    if initial.saver_pid != manifest_saver_pid:
        fail("admitted saver PID differs from the evidence manifest")
    require_idle_activation_boundary(events, initial, initial_helper_class)
    topology_marker = require_hosted_gate_marker(hosted_gate_markers, initial)
    require_authenticated_idle_preflight(
        hosted_gate_preflights, events, initial, topology_marker
    )
    fallback_lines = [
        receipt.line
        for receipt in receipts
        if receipt.state == "fallback"
        and receipt.saver_pid == initial.saver_pid
        and receipt.instance == initial.instance
    ]
    if not fallback_lines:
        fail("A1TR has no fallback from the proven hosted saver instance")
    fallback_line = next(
        (line for line in fallback_lines if line > initial.third_receipt_line), None
    )
    if fallback_line is None:
        fail("hosted fallback did not follow initial rolling delivery")
    recovered = prove_running_incarnation(
        events,
        receipts,
        animations,
        pid=recovered_pid,
        after=fallback_line,
    )
    if (
        recovered.saver_pid != initial.saver_pid
        or recovered.instance != initial.instance
    ):
        fail("recovery evidence came from a different hosted saver PID or instance")
    if recovered.epoch == initial.epoch:
        fail("recovered helper reused the initial producer epoch")
    if recovered.generation == initial.generation:
        fail("recovered helper reused the initial producer generation")
    fallback = next(receipt for receipt in receipts if receipt.line == fallback_line)
    assert fault_termination_timestamp is not None
    fallback_elapsed = fallback.timestamp - fault_termination_timestamp
    if fallback_elapsed < 0 or fallback_elapsed > 1.0:
        fail("hosted fallback exceeded the 1-second recovery deadline")
    recovery_elapsed = recovered.third_receipt_timestamp - fallback.timestamp
    if recovery_elapsed < 0 or recovery_elapsed > 8.0:
        fail("fresh recovered delivery exceeded the 8-second recovery deadline")
    if any(
        receipt.state == "available"
        and receipt.epoch == initial.epoch
        and receipt.line > fallback_line
        for receipt in receipts
    ):
        fail("old-epoch hosted receipt appeared after fallback")
    cleanup_line = prove_cleanup(events, recovered)
    require_terminal_cleanup(
        events,
        receipts,
        hosted_gate_markers,
        hosted_gate_preflights,
        animations,
        cleanup_line,
    )


def main(argv: List[str]) -> int:
    if len(argv) != 4 or argv[1] not in ("a1t", "a1tr"):
        print(
            "Usage: verify_camera_gate_a1_log.py a1t|a1tr /absolute/combined.log "
            "/absolute/evidence-manifest.txt",
            file=sys.stderr,
        )
        return 64
    mode = argv[1]
    path = Path(argv[2])
    manifest_path = Path(argv[3])
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        return 64
    try:
        verify(mode, path, manifest_path)
    except (OSError, UnicodeError, EvidenceFailure) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        f"PASS: {mode} evidence proves one ordered, deadline-bounded, privacy-safe, "
        "topology-equivalent hosted lifecycle; trusted-for-production=false."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
