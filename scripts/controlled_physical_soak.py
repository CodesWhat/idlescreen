#!/usr/bin/env python3
"""Bounded, operator-attended energy observation for an installed candidate."""

from __future__ import annotations

import hashlib
import importlib.util
import ctypes
import errno
import json
import math
import os
import plistlib
import re
import signal
import select
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor, wait
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

import camera_gate_c8_schema as _C8_SCHEMA


_C8_PATH = Path(__file__).with_name("run-camera-gate-c8-row.py")
_C8_SPEC = importlib.util.spec_from_file_location("c8_planner_for_soak", _C8_PATH)
if _C8_SPEC is None or _C8_SPEC.loader is None:
    raise ImportError("could not load the canonical C8 publication helper")
_C8 = importlib.util.module_from_spec(_C8_SPEC)
_C8_SPEC.loader.exec_module(_C8)


PLAN_SCHEMA = "IdleScreenControlledSoakPlan/v1"
ENERGY_SCHEMA = "IdleScreenControlledSoakEnergy/v1"
RESULT_SCHEMA = "IdleScreenControlledSoakResult/v1"
PLAN_TTL_SECONDS = 300
MIN_DURATION_SECONDS = 10
MAX_DURATION_SECONDS = 900
MAX_SAMPLES = 10000
MAX_COLLECTOR_BYTES = 1024 * 1024
MAX_PLAN_BYTES = 1024 * 1024
SAMPLE_INTERVAL_SECONDS = 1
MAX_LIFECYCLE_EVENTS = 256
APP_PATH = Path("/Applications/idlescreen.app")
APP_EXECUTABLE_PATH = APP_PATH / "Contents/MacOS/IdleScreen"
HELPER_PATH = APP_PATH / "Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
EXTENSION_PATH = APP_PATH / "Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver"
TEAM_IDENTIFIER = "3524374A2S"
AUTHORIZATION_ENV = "IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"
PHYSICAL_TEST_ENV = "IDLESCREEN_ALLOW_PHYSICAL_TESTS"
PLAN_KEYS = frozenset(
    (
        "schema",
        "matrix_path",
        "matrix_id",
        "matrix_sha256",
        "row_id",
        "authorization_id",
        "duration_seconds",
        "candidate",
        "created_at_utc",
        "expires_at_utc",
        "c8_evidence_completed",
        "physical_actions_performed",
        "plan_digest",
    )
)
ENERGY_KEYS = frozenset(
    (
        "schema",
        "plan_digest",
        "sampled_pids",
        "samples",
        "sample_interval_seconds",
        "sample_count",
        "duration_seconds",
        "per_pid_counts",
        "coverage",
    )
)
RESULT_KEYS = frozenset(
    (
        "schema",
        "status",
        "plan_digest",
        "authorization_id",
        "candidate",
        "lifecycle_observations",
        "energy_artifact_sha256",
        "sample_coverage",
        "started_at_utc",
        "completed_at_utc",
        "failure_reasons",
        "c8_evidence_completed",
        "physical_actions_performed",
    )
)
CANDIDATE_KEYS = frozenset(
    (
        "app_path",
        "app_executable_path",
        "helper_path",
        "extension_path",
        "team_identifier",
        "app_cdhash",
        "helper_cdhash",
        "extension_cdhash",
        "archive_tree_sha256",
        "provenance_sha256",
        "matrix_provenance_sha256",
        "provenance_archive_tree_sha256",
    )
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CDHASH_RE = re.compile(r"^[0-9a-f]{40}$")


class _ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


class ControlledSoakError(_C8.C8EvidenceError):
    """A controlled soak was refused or produced incomplete evidence."""


@dataclass(frozen=True)
class RunnerDependencies:
    console_probe: Callable[[], dict[str, Any]]
    candidate_probe: Callable[[], dict[str, Any]]
    lifecycle_collector: Callable[[float], dict[str, Any]]
    energy_sampler: Callable[[list[int], float], dict[str, Any]]
    process_probe: Callable[[], list[dict[str, Any]]]
    cleanup: Callable[[], bool] = lambda: True
    clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)


@dataclass
class _Reservation:
    path: Path
    descriptor: int
    parent_descriptors: list[int]
    published: bool = False
    completed_commit: bool = False


@dataclass
class _PlanHandle:
    path: Path
    descriptor: int
    parent_descriptors: list[int]


def _reserve_output(path: Path) -> _Reservation:
    if not path.is_absolute() or path == Path("/"):
        raise ControlledSoakError("output must be an absolute path")
    parent_descriptor, parent_descriptors = _C8._open_trusted_parent(path)
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path.name, flags, 0, dir_fd=parent_descriptor)
    except BaseException:
        _C8._close_descriptors(parent_descriptors)
        raise ControlledSoakError("output is occupied or unsafe")
    return _Reservation(path, descriptor, parent_descriptors)


def _mark_publication_committed(reservation: _Reservation, value: object) -> None:
    reservation.published = True
    reservation.completed_commit = (
        isinstance(value, dict)
        and value.get("schema") == RESULT_SCHEMA
        and value.get("status") == "completed"
    )


def _publish_reserved(reservation: _Reservation, value: object) -> None:
    payload = _canonical(value)
    try:
        _C8._verify_parent_identity(reservation.path, reservation.parent_descriptors)
        _C8._verify_published_inode(
            reservation.parent_descriptors[-1], reservation.path.name, reservation.descriptor
        )
        os.ftruncate(reservation.descriptor, 0)
        os.lseek(reservation.descriptor, 0, os.SEEK_SET)
        remaining = memoryview(payload)
        while remaining:
            written = os.write(reservation.descriptor, remaining)
            if written <= 0:
                raise OSError("reserved output write made no progress")
            remaining = remaining[written:]
        os.fsync(reservation.descriptor)
        os.fchmod(reservation.descriptor, 0o400)
        os.fsync(reservation.descriptor)
        os.fsync(reservation.parent_descriptors[-1])
        _C8._verify_parent_identity(reservation.path, reservation.parent_descriptors)
        _C8._verify_published_inode(
            reservation.parent_descriptors[-1], reservation.path.name, reservation.descriptor
        )
        _mark_publication_committed(reservation, value)
    except BaseException:
        reservation.published = False
        reservation.completed_commit = False
        try:
            _C8._poison_descriptor(reservation.descriptor)
        finally:
            raise


def _close_reservation(reservation: _Reservation) -> None:
    close_error = _C8._close_output_descriptor(reservation.descriptor)
    try:
        _C8._close_descriptors(reservation.parent_descriptors)
    except OSError as error:
        if close_error is None:
            close_error = error
    if close_error is not None:
        raise ControlledSoakError("controlled soak output close failed") from close_error


def _close_plan(handle: _PlanHandle) -> None:
    close_error = _C8._close_output_descriptor(handle.descriptor)
    try:
        _C8._close_descriptors(handle.parent_descriptors)
    except OSError as error:
        if close_error is None:
            close_error = error
    if close_error is not None:
        raise ControlledSoakError("controlled soak plan close failed") from close_error


def _discard_reservation(reservation: _Reservation) -> None:
    try:
        _C8._poison_descriptor(reservation.descriptor)
        removed = _C8._remove_owned_entry(
            reservation.parent_descriptors[-1], reservation.path.name, reservation.descriptor
        )
        if not removed:
            raise ControlledSoakError("reserved output was replaced during cleanup")
    except (OSError, _C8.C8EvidenceError) as error:
        raise ControlledSoakError("controlled soak output cleanup failed") from error


def _canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def _digest(value: object) -> str:
    return hashlib.sha256(_canonical(value)).hexdigest()


def _sha256_descriptor(descriptor: int) -> str:
    digest = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    os.lseek(descriptor, 0, os.SEEK_SET)
    return digest.hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json_atomic(path: Path, value: object) -> None:
    _C8.write_exclusive_json(path, value)


def _utc(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() != timedelta(0):
        raise ControlledSoakError("timestamps must be UTC")
    if value.microsecond:
        raise ControlledSoakError("timestamps must not contain fractional seconds")
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_utc(value: object) -> datetime:
    if not isinstance(value, str):
        raise ControlledSoakError("timestamp is not UTC")
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise ControlledSoakError("timestamp must use exact UTC second syntax") from error
    return parsed


def _opt_in_refusal(extra_opt_ins: dict[str, str] | None = None) -> None:
    values = dict(os.environ)
    if extra_opt_ins:
        values.update(extra_opt_ins)
    if values.get(PHYSICAL_TEST_ENV) != "YES":
        raise ControlledSoakError(f"set {PHYSICAL_TEST_ENV}=YES for attended execution")
    if values.get(AUTHORIZATION_ENV) != "YES":
        raise ControlledSoakError(f"set only {AUTHORIZATION_ENV}=YES for attended execution")
    unrelated = sorted(
        key
        for key in _C8.AUTHORIZATION_ENVIRONMENT_VARIABLES
        if key != AUTHORIZATION_ENV and key in values
    )
    if unrelated or "IDLESCREEN_C8_AUTHORIZE_RETAINED_CONSUMER" in values:
        raise ControlledSoakError("unrelated or retained-consumer opt-in is present")


def _plan_opt_in(extra_opt_ins: dict[str, str]) -> None:
    values = dict(os.environ)
    values.update(extra_opt_ins)
    if values.get(AUTHORIZATION_ENV) != "YES":
        raise ControlledSoakError(f"set only {AUTHORIZATION_ENV}=YES for planning")
    unrelated = sorted(
        key
        for key in _C8.AUTHORIZATION_ENVIRONMENT_VARIABLES
        if key != AUTHORIZATION_ENV and key in values
    )
    if unrelated or "IDLESCREEN_C8_AUTHORIZE_RETAINED_CONSUMER" in values:
        raise ControlledSoakError("unrelated or retained-consumer opt-in is present")


def build_plan(
    matrix_path: Path,
    authorization_id: str,
    duration_seconds: int,
    *,
    now: datetime | None = None,
    candidate_path: Path = APP_PATH,
) -> dict[str, Any]:
    _plan_opt_in(dict(os.environ))
    if not _C8.ID_RE.fullmatch(authorization_id):
        raise ControlledSoakError("authorization ID is malformed")
    if not isinstance(duration_seconds, int) or not (
        MIN_DURATION_SECONDS <= duration_seconds <= MAX_DURATION_SECONDS
    ):
        raise ControlledSoakError("duration must be between 10 and 900 seconds")
    if candidate_path != APP_PATH:
        raise ControlledSoakError("candidate path must be /Applications/idlescreen.app")
    definition = _C8.load_matrix_definition(matrix_path)
    _C8.validate_pending_row(definition, "soak")
    created = now or datetime.now(timezone.utc).replace(microsecond=0)
    created_text = _utc(created)
    expires_text = _utc(created + timedelta(seconds=PLAN_TTL_SECONDS))
    installed_provenance = APP_PATH / "Contents/Resources/IdleScreenReleaseProvenance.plist"
    installed_provenance_sha256 = (
        sha256_file(installed_provenance)
        if installed_provenance.is_file() and not installed_provenance.is_symlink()
        else definition.candidate["provenance_sha256"]
    )
    candidate = {
        "app_path": str(APP_PATH),
        "app_executable_path": str(APP_EXECUTABLE_PATH),
        "helper_path": str(HELPER_PATH),
        "extension_path": str(EXTENSION_PATH),
        "team_identifier": definition.candidate["team_identifier"],
        "app_cdhash": definition.candidate["app_cdhash"],
        "helper_cdhash": definition.candidate["helper_cdhash"],
        "extension_cdhash": definition.candidate["extension_cdhash"],
        "archive_tree_sha256": definition.candidate["archive_tree_sha256"],
        "provenance_sha256": installed_provenance_sha256,
        "matrix_provenance_sha256": definition.candidate["provenance_sha256"],
        "provenance_archive_tree_sha256": definition.candidate["archive_tree_sha256"],
    }
    plan = {
        "schema": PLAN_SCHEMA,
        "matrix_path": str(matrix_path),
        "matrix_id": definition.matrix_id,
        "matrix_sha256": sha256_file(matrix_path),
        "row_id": "soak",
        "authorization_id": authorization_id,
        "duration_seconds": duration_seconds,
        "candidate": candidate,
        "created_at_utc": created_text,
        "expires_at_utc": expires_text,
        "c8_evidence_completed": False,
        "physical_actions_performed": False,
    }
    plan["plan_digest"] = _digest(plan)
    return plan


def _load_plan(path: Path) -> dict[str, Any]:
    handle = _open_plan(path)
    try:
        return _read_plan_handle(handle)
    finally:
        _close_plan(handle)


def _open_plan(path: Path) -> _PlanHandle:
    if not isinstance(path, Path) or not path.is_absolute() or path == Path("/"):
        raise ControlledSoakError("controlled soak plan must be an absolute regular file")
    parent_descriptor, parent_descriptors = _C8._open_trusted_parent(path)
    descriptor = None
    try:
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path.name, flags, dir_fd=parent_descriptor)
        plan_stat = os.fstat(descriptor)
        if plan_stat.st_uid not in (0, os.getuid()) or plan_stat.st_mode & 0o022:
            raise ControlledSoakError("controlled soak plan inode mode or ownership is unsafe")
        _C8._verify_parent_identity(path, parent_descriptors)
        _C8._verify_published_inode(parent_descriptor, path.name, descriptor)
        return _PlanHandle(path, descriptor, parent_descriptors)
    except (OSError, _C8.C8EvidenceError) as error:
        if descriptor is not None:
            _C8._close_output_descriptor(descriptor)
        _C8._close_descriptors(parent_descriptors)
        raise ControlledSoakError(f"controlled soak plan is missing or unsafe: {error}") from error


def _read_plan_handle(handle: _PlanHandle) -> dict[str, Any]:
    chunks = bytearray()
    while True:
        chunk = os.read(handle.descriptor, min(8192, MAX_PLAN_BYTES + 1 - len(chunks)))
        if not chunk:
            break
        chunks.extend(chunk)
        if len(chunks) > MAX_PLAN_BYTES:
            raise ControlledSoakError("controlled soak plan exceeds its size cap")
    try:
        value = json.loads(bytes(chunks).decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ControlledSoakError(f"could not read controlled soak plan: {error}") from error
    validate_plan_document(value)
    return value


def validate_plan_document(value: object) -> None:
    if not isinstance(value, dict) or set(value) != PLAN_KEYS:
        raise ControlledSoakError("controlled soak plan schema is unsupported")
    if value["schema"] != PLAN_SCHEMA:
        raise ControlledSoakError("controlled soak plan schema is unsupported")
    if value["row_id"] != "soak" or value["c8_evidence_completed"] is not False or value["physical_actions_performed"] is not False:
        raise ControlledSoakError("controlled soak plan is not an inert C8 soak plan")
    if not isinstance(value["matrix_path"], str) or not Path(value["matrix_path"]).is_absolute() or Path(value["matrix_path"]).is_symlink():
        raise ControlledSoakError("controlled soak matrix path is not absolute")
    if not isinstance(value["matrix_id"], str) or _C8.ID_RE.fullmatch(value["matrix_id"]) is None:
        raise ControlledSoakError("controlled soak matrix ID is malformed")
    if not isinstance(value["authorization_id"], str) or _C8.ID_RE.fullmatch(value["authorization_id"]) is None:
        raise ControlledSoakError("controlled soak authorization ID is malformed")
    if isinstance(value["duration_seconds"], bool) or not isinstance(value["duration_seconds"], int) or not MIN_DURATION_SECONDS <= value["duration_seconds"] <= MAX_DURATION_SECONDS:
        raise ControlledSoakError("controlled soak duration is malformed")
    for key in ("matrix_sha256", "plan_digest"):
        if not isinstance(value[key], str) or SHA256_RE.fullmatch(value[key]) is None:
            raise ControlledSoakError(f"controlled soak {key} is malformed")
    created = _parse_utc(value["created_at_utc"])
    expires = _parse_utc(value["expires_at_utc"])
    if expires - created != timedelta(seconds=PLAN_TTL_SECONDS):
        raise ControlledSoakError("controlled soak plan TTL is not exactly 300 seconds")
    candidate = value["candidate"]
    if not isinstance(candidate, dict) or set(candidate) != CANDIDATE_KEYS:
        raise ControlledSoakError("controlled soak candidate binding is incomplete")
    if candidate["app_path"] != str(APP_PATH) or candidate["app_executable_path"] != str(APP_EXECUTABLE_PATH) or candidate["helper_path"] != str(HELPER_PATH) or candidate["extension_path"] != str(EXTENSION_PATH):
        raise ControlledSoakError("controlled soak candidate path is not canonical")
    if candidate["team_identifier"] != TEAM_IDENTIFIER:
        raise ControlledSoakError("controlled soak candidate team is not production")
    for key in ("app_cdhash", "helper_cdhash", "extension_cdhash"):
        if not isinstance(candidate[key], str) or CDHASH_RE.fullmatch(candidate[key]) is None:
            raise ControlledSoakError("controlled soak candidate CDHash is malformed")
    for key in ("archive_tree_sha256", "provenance_sha256", "matrix_provenance_sha256", "provenance_archive_tree_sha256"):
        if not isinstance(candidate[key], str) or SHA256_RE.fullmatch(candidate[key]) is None:
            raise ControlledSoakError("controlled soak candidate hash is malformed")
    body = {key: value[key] for key in value if key != "plan_digest"}
    if not isinstance(value["plan_digest"], str) or SHA256_RE.fullmatch(value["plan_digest"]) is None or value["plan_digest"] != _digest(body):
        raise ControlledSoakError("controlled soak plan digest is invalid")


def verify_energy_document(
    value: object, plan_digest: str, *, plan_duration_seconds: int | None = None
) -> None:
    if not isinstance(value, dict) or set(value) != ENERGY_KEYS:
        raise ControlledSoakError("controlled soak energy schema is unsupported")
    if value["schema"] != ENERGY_SCHEMA or value["plan_digest"] != plan_digest:
        raise ControlledSoakError("controlled soak energy is not bound to the plan")
    if not isinstance(value["sampled_pids"], list) or not value["sampled_pids"] or any(
        isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0
        for pid in value["sampled_pids"]
    ) or len(set(value["sampled_pids"])) != len(value["sampled_pids"]):
        raise ControlledSoakError("controlled soak sampled PIDs are malformed")
    if not isinstance(value["sample_count"], int) or isinstance(value["sample_count"], bool) or value["sample_count"] <= 0:
        raise ControlledSoakError("controlled soak sample count is malformed")
    if not isinstance(value["samples"], list) or not value["samples"] or len(value["samples"]) != value["sample_count"] or len(value["samples"]) > MAX_SAMPLES:
        raise ControlledSoakError("controlled soak energy has no samples")
    if isinstance(value["duration_seconds"], bool) or not isinstance(value["duration_seconds"], (int, float)) or not math.isfinite(value["duration_seconds"]) or value["duration_seconds"] <= 0:
        raise ControlledSoakError("controlled soak energy duration is malformed")
    if plan_duration_seconds is not None and value["duration_seconds"] != plan_duration_seconds:
        raise ControlledSoakError("controlled soak energy duration does not match plan")
    if value["sample_interval_seconds"] != SAMPLE_INTERVAL_SECONDS:
        raise ControlledSoakError("controlled soak sample interval is malformed")
    if not isinstance(value["per_pid_counts"], dict):
        raise ControlledSoakError("controlled soak per-PID counts are malformed")
    if set(value["per_pid_counts"]) != {str(pid) for pid in value["sampled_pids"]}:
        raise ControlledSoakError("controlled soak per-PID counts do not match sampled PIDs")
    if isinstance(value["coverage"], bool) or not isinstance(value["coverage"], (int, float)) or not math.isfinite(value["coverage"]) or value["coverage"] < 0.8 or value["coverage"] > 1.0:
        raise ControlledSoakError("controlled soak coverage is malformed")
    indices = []
    for sample in value["samples"]:
        if not isinstance(sample, dict) or set(sample) != {"pid", "cpu", "power", "mem", "index"}:
            raise ControlledSoakError("controlled soak energy sample is not privacy-scoped")
        if isinstance(sample["pid"], bool) or not isinstance(sample["pid"], int) or sample["pid"] <= 0:
            raise ControlledSoakError("controlled soak energy PID is malformed")
        for key in ("cpu", "power"):
            if not isinstance(sample[key], (int, float)) or isinstance(sample[key], bool) or not math.isfinite(sample[key]):
                raise ControlledSoakError("controlled soak energy metric is not finite")
        if not isinstance(sample["mem"], str) or re.fullmatch(r"[0-9]+(?:\.[0-9]+)?[KMG]", sample["mem"]) is None:
            raise ControlledSoakError("controlled soak memory metric is not privacy-scoped")
        if not isinstance(sample["index"], int) or sample["index"] < 0:
            raise ControlledSoakError("controlled soak energy sample index is malformed")
        indices.append(sample["index"])
    if len(set(indices)) != len(indices):
        raise ControlledSoakError("controlled soak energy sample indices drifted")
    if {sample["pid"] for sample in value["samples"]} != set(value["sampled_pids"]):
        raise ControlledSoakError("controlled soak sample PID set drifted")
    counts = {}
    for pid in value["sampled_pids"]:
        count = value["per_pid_counts"][str(pid)]
        if isinstance(count, bool) or not isinstance(count, int) or count != sum(sample["pid"] == pid for sample in value["samples"]):
            raise ControlledSoakError("controlled soak per-PID sample count drifted")
        counts[pid] = count
    expected_per_pid = max(1, int(math.ceil(value["duration_seconds"] / value["sample_interval_seconds"])))
    calculated_coverage = min(1.0, min(count / expected_per_pid for count in counts.values()))
    if calculated_coverage < 0.8 or abs(value["coverage"] - calculated_coverage) > 1e-9:
        raise ControlledSoakError("controlled soak per-PID coverage is insufficient")


def validate_lifecycle_observations(value: object) -> None:
    if not isinstance(value, dict) or value.keys() != {"events"}:
        raise ControlledSoakError("controlled soak lifecycle evidence is malformed")
    events = value["events"]
    if not isinstance(events, list) or len(events) != 2:
        raise ControlledSoakError("controlled soak lifecycle must contain one start and stop")
    if any(not isinstance(event, dict) or set(event) != {"instance_id", "kind", "sequence"} for event in events):
        raise ControlledSoakError("controlled soak lifecycle event is malformed")
    if any(not isinstance(event["instance_id"], str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", event["instance_id"]) for event in events):
        raise ControlledSoakError("controlled soak lifecycle instance is malformed")
    if events[0]["kind"] != "start" or events[1]["kind"] != "stop":
        raise ControlledSoakError("controlled soak lifecycle must start before stop")
    if events[0]["instance_id"] != events[1]["instance_id"]:
        raise ControlledSoakError("controlled soak lifecycle events use different instances")
    if any(isinstance(event["sequence"], bool) or not isinstance(event["sequence"], int) for event in events) or events[0]["sequence"] >= events[1]["sequence"]:
        raise ControlledSoakError("controlled soak lifecycle sequence is not ordered")


def verify_result_document(value: object, plan_digest: str | None = None) -> None:
    if not isinstance(value, dict) or set(value) != RESULT_KEYS:
        raise ControlledSoakError("controlled soak result schema is unsupported")
    if value["schema"] != RESULT_SCHEMA or value["plan_digest"] != plan_digest:
        raise ControlledSoakError("controlled soak result is not bound to the plan")
    if value["status"] not in ("completed", "failed"):
        raise ControlledSoakError("controlled soak result status is unsupported")
    if value["c8_evidence_completed"] is not False or value["physical_actions_performed"] is not False:
        raise ControlledSoakError("controlled soak result contains an unsafe claim")
    if not isinstance(value["failure_reasons"], list) or any(
        not isinstance(reason, str) or not reason for reason in value["failure_reasons"]
    ):
        raise ControlledSoakError("controlled soak failure reasons are malformed")
    if value["status"] == "completed" and value["failure_reasons"]:
        raise ControlledSoakError("completed controlled soak contains failure reasons")
    if value["status"] == "completed" or plan_digest is not None:
        if not isinstance(value["authorization_id"], str) or _C8.ID_RE.fullmatch(value["authorization_id"]) is None:
            raise ControlledSoakError("controlled soak authorization ID is malformed")
    elif value["authorization_id"] is not None:
        raise ControlledSoakError("controlled soak authorization ID is malformed")
    for key in ("started_at_utc", "completed_at_utc"):
        if value[key] is None and value["status"] == "failed":
            continue
        if not isinstance(value[key], str):
            raise ControlledSoakError("controlled soak result timing is malformed")
        _parse_utc(value[key])
    if value["status"] == "completed":
        if not isinstance(value["candidate"], dict) or set(value["candidate"]) != CANDIDATE_KEYS:
            raise ControlledSoakError("completed controlled soak candidate is malformed")
        if not isinstance(value["energy_artifact_sha256"], str) or SHA256_RE.fullmatch(value["energy_artifact_sha256"]) is None:
            raise ControlledSoakError("completed controlled soak energy digest is malformed")
        if isinstance(value["sample_coverage"], bool) or not isinstance(value["sample_coverage"], (int, float)) or not math.isfinite(value["sample_coverage"]) or value["sample_coverage"] < 0.8:
            raise ControlledSoakError("completed controlled soak coverage is malformed")
        if _parse_utc(value["completed_at_utc"]) <= _parse_utc(value["started_at_utc"]):
            raise ControlledSoakError("controlled soak result timing is out of order")
    lifecycle = value["lifecycle_observations"]
    if lifecycle is not None:
        validate_lifecycle_observations(lifecycle)
    elif value["status"] == "completed":
        raise ControlledSoakError("completed controlled soak lacks lifecycle evidence")


def _claim(handle: _PlanHandle, digest: str) -> None:
    try:
        _C8._verify_parent_identity(handle.path, handle.parent_descriptors)
        _C8._verify_published_inode(
            handle.parent_descriptors[-1], handle.path.name, handle.descriptor
        )
        claim_name = handle.path.name + ".claimed"
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(
                claim_name, flags, 0o600, dir_fd=handle.parent_descriptors[-1]
            )
        except FileExistsError as error:
            raise ControlledSoakError("controlled soak plan was already claimed") from error
        try:
            payload = (digest + "\n").encode("ascii")
            while payload:
                written = os.write(descriptor, payload)
                if written <= 0:
                    raise OSError("controlled soak claim made no progress")
                payload = payload[written:]
            os.fsync(descriptor)
            os.fsync(handle.parent_descriptors[-1])
        finally:
            os.close(descriptor)
        _C8._verify_parent_identity(handle.path, handle.parent_descriptors)
        _C8._verify_published_inode(
            handle.parent_descriptors[-1], handle.path.name, handle.descriptor
        )
    except OSError as error:
        raise ControlledSoakError("controlled soak plan claim failed") from error


def _default_process_probe() -> list[dict[str, Any]]:
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        libproc.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int32]
        libproc.proc_listpids.restype = ctypes.c_int32
        libproc.proc_pidpath.argtypes = [ctypes.c_int32, ctypes.c_void_p, ctypes.c_uint32]
        libproc.proc_pidpath.restype = ctypes.c_int32
        libproc.proc_pidinfo.argtypes = [ctypes.c_int32, ctypes.c_int32, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int32]
        libproc.proc_pidinfo.restype = ctypes.c_int32
        required = libproc.proc_listpids(1, 0, None, 0)
        if required <= 0:
            return []
        pids = (ctypes.c_int32 * (required // ctypes.sizeof(ctypes.c_int32)))()
        count = libproc.proc_listpids(1, 0, pids, ctypes.sizeof(pids))
    except (OSError, AttributeError, TypeError):
        return []
    allowed_paths = {str(APP_EXECUTABLE_PATH), str(HELPER_PATH), str(EXTENSION_PATH)}
    result = []
    for pid in pids[: count // ctypes.sizeof(ctypes.c_int32)]:
        if pid <= 0:
            continue
        start_before = _process_start_identity(libproc, int(pid))
        if not start_before:
            continue
        buffer = ctypes.create_string_buffer(4096)
        if libproc.proc_pidpath(pid, buffer, ctypes.sizeof(buffer)) <= 0:
            continue
        try:
            path = buffer.value.decode("utf-8", errors="strict")
        except UnicodeError:
            continue
        if path in allowed_paths:
            cdhash = _codesign_metadata(int(pid)).get("CDHash")
            start_after = _process_start_identity(libproc, int(pid))
            if not start_after or start_before != start_after:
                continue
            result.append(
                {
                    "pid": int(pid),
                    "path": path,
                    "cdhash": cdhash.lower() if cdhash else None,
                    "start_identity": start_after,
                }
            )
    return result


def _process_start_identity(libproc: Any, pid: int) -> str | None:
    if not hasattr(libproc, "proc_pidinfo"):
        return None
    info = _ProcBsdInfo()
    try:
        size = libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    except (OSError, TypeError):
        return None
    if size != ctypes.sizeof(info):
        return None
    return f"{info.pbi_start_tvsec}:{info.pbi_start_tvusec}"


def _codesign_metadata(path: Path | int) -> dict[str, str]:
    try:
        completed = subprocess.run(
            ["/usr/bin/codesign", "-dv", "--verbose=4", str(path)],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError, TypeError):
        return {}
    metadata = {}
    for line in completed.stderr.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            metadata[key] = value
    return metadata


def _profile_semantically_valid(path: Path, bundle_identifier: str, product_path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    try:
        decoded = subprocess.run(
            ["/usr/bin/security", "cms", "-D", "-i", str(path)],
            check=True,
            capture_output=True,
            timeout=10,
        ).stdout
        profile = plistlib.loads(decoded)
        with tempfile.TemporaryDirectory(prefix="idlescreen-profile-certs-") as directory:
            prefix = str(Path(directory) / "certificate-")
            subprocess.run(
                ["/usr/bin/codesign", "--display", f"--extract-certificates={prefix}", str(product_path)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )
            certificates = []
            for index in range(32):
                certificate = Path(f"{prefix}{index}")
                if not certificate.is_file():
                    break
                certificates.append(certificate.read_bytes())
        return _validate_profile_payload(profile, bundle_identifier, certificates)
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException, subprocess.SubprocessError):
        return False


def _validate_profile_payload(profile: object, bundle_identifier: str, certificates: list[bytes]) -> bool:
    if not isinstance(profile, dict):
        return False
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        return False
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    if expiration.astimezone(timezone.utc) <= datetime.now(timezone.utc):
        return False
    developer_certificates = profile.get("DeveloperCertificates")
    if not isinstance(developer_certificates, list) or not developer_certificates:
        return False
    if any(not isinstance(certificate, bytes) or not certificate for certificate in developer_certificates):
        return False
    if profile.get("ProvisionsAllDevices") is not True or "ProvisionedDevices" in profile:
        return False
    if profile.get("TeamIdentifier") != [TEAM_IDENTIFIER]:
        return False
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        return False
    if entitlements.get("com.apple.developer.team-identifier") != TEAM_IDENTIFIER:
        return False
    if entitlements.get("com.apple.application-identifier") != f"{TEAM_IDENTIFIER}.{bundle_identifier}":
        return False
    if "get-task-allow" in entitlements and entitlements["get-task-allow"] is not False:
        return False
    if entitlements.get("com.apple.security.application-groups") != ["group.com.idlescreen.shared"]:
        return False
    return bool(certificates) and isinstance(certificates[0], bytes) and certificates[0] in developer_certificates


def _default_candidate_probe() -> dict[str, Any]:
    if not APP_PATH.is_dir() or APP_PATH.is_symlink():
        return {}
    nested = {
        "app_cdhash": APP_PATH,
        "helper_cdhash": APP_PATH / "Contents/Helpers/IdleScreenCameraAgent.app",
        "extension_cdhash": APP_PATH / "Contents/PlugIns/IdleScreenScreenSaver.appex",
    }
    metadata = _codesign_metadata(APP_PATH)
    result = {
        "app_path": str(APP_PATH),
        "app_executable_path": str(APP_EXECUTABLE_PATH),
        "helper_path": str(HELPER_PATH),
        "extension_path": str(EXTENSION_PATH),
        "team_identifier": metadata.get("TeamIdentifier"),
        "profiles_valid": False,
        "production_marker_absent": True,
    }
    for key, path in nested.items():
        cdhash = _codesign_metadata(path).get("CDHash")
        result[key] = cdhash.lower() if cdhash else None
    profile_paths = [
        APP_PATH / "Contents/embedded.provisionprofile",
        nested["helper_cdhash"] / "Contents/embedded.provisionprofile",
        nested["extension_cdhash"] / "Contents/embedded.provisionprofile",
    ]
    try:
        verified = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(APP_PATH)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        ).returncode == 0
    except (OSError, subprocess.SubprocessError, TypeError):
        verified = False
    authority = Path(__file__).with_name("test-camera-agent-product.sh")
    try:
        authority_verified = subprocess.run(
            [str(authority), str(APP_PATH), "Release"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=60,
        ).returncode == 0
    except (OSError, subprocess.SubprocessError, TypeError):
        authority_verified = False
    result["profiles_valid"] = (
        verified
        and authority_verified
        and _profile_semantically_valid(profile_paths[0], "com.idlescreen.app", APP_PATH)
        and _profile_semantically_valid(profile_paths[1], "com.idlescreen.camera-agent", nested["helper_cdhash"])
        and _profile_semantically_valid(profile_paths[2], "com.idlescreen.app.screensaver", nested["extension_cdhash"])
    )
    for binary in (HELPER_PATH, EXTENSION_PATH):
        try:
            marker_scan = subprocess.run(
                ["/usr/bin/strings", str(binary)],
                check=True,
                capture_output=True,
                text=True,
                timeout=10,
            ).stdout
        except (OSError, subprocess.SubprocessError, TypeError):
            result["production_marker_absent"] = False
            break
        if "IdleScreenSynthetic" in marker_scan:
            result["production_marker_absent"] = False
            break
    provenance = APP_PATH / "Contents/Resources/IdleScreenReleaseProvenance.plist"
    try:
        provenance_value = subprocess.run(
            ["/usr/bin/plutil", "-extract", "C3ArchiveTreeSHA256", "raw", str(provenance)],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError, TypeError):
        provenance_value = None
    result["provenance_archive_tree_sha256"] = provenance_value
    result["archive_tree_sha256"] = provenance_value
    result["provenance_sha256"] = (
        sha256_file(provenance)
        if provenance.is_file() and not provenance.is_symlink()
        else None
    )
    return result


def _default_console_probe() -> dict[str, Any]:
    probe = Path(__file__).with_name("read-console-lock-state.sh")
    try:
        completed = subprocess.run(
            [str(probe)], check=False, capture_output=True, text=True, timeout=2
        )
    except (OSError, subprocess.SubprocessError, TypeError):
        return {"state": "unknown"}
    return {"state": "unlocked" if completed.returncode == 0 and completed.stdout.strip() == "false" else "locked"}


def _terminate_group(process: subprocess.Popen[str]) -> None:
    try:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=1)
        except (OSError, subprocess.TimeoutExpired):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                pass
            try:
                process.wait(timeout=1)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if not _group_gone(process):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                pass
            try:
                process.wait(timeout=1)
            except (OSError, subprocess.TimeoutExpired):
                pass
    finally:
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()


def _group_gone(process: subprocess.Popen[str]) -> bool:
    try:
        os.killpg(process.pid, 0)
    except OSError as error:
        return error.errno == errno.ESRCH
    return False


def _wait_group_gone(process: subprocess.Popen[str], timeout: float = 1.0) -> bool:
    deadline = time.monotonic() + timeout
    while True:
        if _group_gone(process):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.01)


def _read_bounded(process: subprocess.Popen[bytes], deadline: float) -> tuple[str, bool]:
    if process.stdout is None:
        raise ControlledSoakError("owned collector has no output stream")
    captured = bytearray()
    timed_out = False
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = process.poll() is None
            break
        ready, _, _ = select.select([process.stdout], [], [], min(0.1, remaining))
        if ready:
            if time.monotonic() >= deadline:
                timed_out = process.poll() is None
                break
            chunk = os.read(process.stdout.fileno(), min(8192, MAX_COLLECTOR_BYTES + 1 - len(captured)))
            if chunk:
                captured.extend(chunk)
                if len(captured) > MAX_COLLECTOR_BYTES:
                    raise ControlledSoakError("owned collector output exceeded its cap")
            elif process.poll() is not None:
                break
        elif process.poll() is not None:
            break
    return bytes(captured).decode("utf-8", errors="strict"), timed_out


def _default_lifecycle_collector(deadline: float) -> dict[str, Any]:
    if time.monotonic() >= deadline:
        raise ControlledSoakError("lifecycle collector started after its deadline")
    predicate = 'subsystem == "com.idlescreen.screensaver"'
    process = subprocess.Popen(
        ["/usr/bin/log", "stream", "--style", "compact", "--predicate", predicate],
        start_new_session=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=False,
    )
    try:
        output, timed_out = _read_bounded(process, deadline)
    finally:
        if process.poll() is None or not _wait_group_gone(process):
            _terminate_group(process)
        if not _wait_group_gone(process):
            raise ControlledSoakError("log collector process group cleanup was not verified")
    return _parse_lifecycle_lines(output)


def _parse_lifecycle_lines(output: str) -> dict[str, Any]:
    instance_pattern = re.compile(r"(?:instance_id|instance)[=: ]+([A-Za-z0-9._-]{1,64})")
    events = []
    for line in output.splitlines():
        kind = "start" if "Animation started" in line else "stop" if "Animation stopped" in line else None
        if kind is None:
            continue
        match = instance_pattern.search(line)
        if match is None:
            continue
        events.append({"instance_id": match.group(1), "kind": kind, "sequence": len(events) + 1})
    if len(events) < 2:
        return {"events": []}
    start = next((event for event in events if event["kind"] == "start"), None)
    if start is None:
        return {"events": events}
    stop = next((event for event in events if event["kind"] == "stop" and event["sequence"] > start["sequence"] and event["instance_id"] == start["instance_id"]), None)
    if stop is None or stop["instance_id"] != start["instance_id"]:
        return {"events": events[:2]}
    return {"events": [start, stop]}


def _default_sampler(pids: list[int], deadline: float) -> dict[str, Any]:
    if not pids:
        raise ControlledSoakError("no exact-path installed candidate process was observed")
    if time.monotonic() >= deadline:
        raise ControlledSoakError("energy sampler started after its deadline")
    command = ["/usr/bin/top", "-l", "0", "-s", "1", "-stats", "pid,cpu,power,mem"]
    for pid in pids:
        command.extend(("-pid", str(pid)))
    process = subprocess.Popen(
        command,
        start_new_session=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=False,
    )
    try:
        output, timed_out = _read_bounded(process, deadline)
    finally:
        if process.poll() is None or not _wait_group_gone(process):
            _terminate_group(process)
        if not _wait_group_gone(process):
            raise ControlledSoakError("energy sampler process group cleanup was not verified")
    if process.returncode != 0 and not timed_out:
        raise ControlledSoakError("energy sampler failed")
    samples = []
    for index, line in enumerate(output.splitlines()):
        fields = line.split()
        if len(fields) >= 4 and fields[0].isdigit():
            try:
                samples.append(
                    {
                        "pid": int(fields[0]),
                        "cpu": float(fields[1].rstrip("%")),
                        "power": float(fields[2]),
                        "mem": fields[3],
                        "index": index,
                    }
                )
            except ValueError:
                continue
    if not samples:
        raise ControlledSoakError("energy sampler returned no process-scoped samples")
    return {"samples": samples, "sample_interval_seconds": 1, "sample_count": len(samples), "coverage": 1.0}


def _deps_or_default(dependencies: RunnerDependencies | None) -> RunnerDependencies:
    if dependencies is not None:
        return dependencies
    return RunnerDependencies(
        console_probe=_default_console_probe,
        candidate_probe=_default_candidate_probe,
        lifecycle_collector=_default_lifecycle_collector,
        energy_sampler=_default_sampler,
        process_probe=_default_process_probe,
    )


def supervise_observation(
    duration_seconds: float,
    pids: list[int],
    lifecycle_collector: Callable[[float], dict[str, Any]],
    energy_sampler: Callable[[list[int], float], dict[str, Any]],
    *,
    monotonic: Callable[[], float] = time.monotonic,
) -> dict[str, Any]:
    started = monotonic()
    deadline = started + duration_seconds
    executor = ThreadPoolExecutor(max_workers=2)
    futures = [
        executor.submit(lifecycle_collector, deadline),
        executor.submit(energy_sampler, pids, deadline),
    ]
    pending = set(futures)
    try:
        done, pending = wait(futures, timeout=max(0.1, duration_seconds + 1))
        if pending:
            raise ControlledSoakError("observation exceeded its monotonic deadline")
        lifecycle, energy = (future.result() for future in futures)
        if not isinstance(energy, dict):
            raise ControlledSoakError("energy sampler returned malformed evidence")
        samples = energy.get("samples")
        interval = energy.get("sample_interval_seconds")
        if not isinstance(samples, list) or interval != SAMPLE_INTERVAL_SECONDS:
            raise ControlledSoakError("energy sampler returned malformed evidence")
        expected = max(1, int(math.ceil(duration_seconds / interval))) * len(pids)
        counts = {
            pid: sum(sample.get("pid") == pid for sample in samples)
            for pid in pids
        }
        coverage = min(1.0, min(count / max(1, int(math.ceil(duration_seconds / interval))) for count in counts.values()))
        if coverage < 0.8:
            raise ControlledSoakError("energy sample coverage is insufficient")
        energy["sample_count"] = len(samples)
        energy["duration_seconds"] = duration_seconds
        energy["sampled_pids"] = list(pids)
        energy["per_pid_counts"] = {str(pid): count for pid, count in counts.items()}
        energy["coverage"] = coverage
        return {"lifecycle": lifecycle, "energy": energy}
    finally:
        executor.shutdown(wait=not pending)


def _validate_candidate(candidate: dict[str, Any], plan: dict[str, Any]) -> None:
    if not isinstance(candidate, dict):
        raise ControlledSoakError("installed candidate identity is malformed")
    for key in (
        "app_path",
        "app_executable_path",
        "team_identifier",
        "app_cdhash",
        "helper_cdhash",
        "extension_cdhash",
    ):
        if candidate.get(key) != plan["candidate"][key]:
            raise ControlledSoakError("installed candidate identity drifted")
    for key in ("archive_tree_sha256", "provenance_sha256"):
        if key not in candidate or candidate[key] != plan["candidate"][key]:
            raise ControlledSoakError("installed candidate provenance drifted")
    if "matrix_provenance_sha256" in candidate and candidate["matrix_provenance_sha256"] != plan["candidate"]["matrix_provenance_sha256"]:
        raise ControlledSoakError("installed candidate matrix provenance drifted")
    if not candidate.get("profiles_valid") or not candidate.get("production_marker_absent"):
        raise ControlledSoakError("installed candidate signature or profile validation failed")
    if candidate.get("provenance_archive_tree_sha256") != plan["candidate"]["archive_tree_sha256"]:
        raise ControlledSoakError("installed release provenance drifted")


def _validate_matrix_binding(plan: dict[str, Any]) -> None:
    matrix_path = Path(plan["matrix_path"])
    parent_descriptor, parent_descriptors = _C8._open_trusted_parent(matrix_path)
    source_descriptors = []
    try:
        matrix_bytes, matrix_descriptor = _read_trusted_source(parent_descriptor, matrix_path.name)
        source_descriptors.append((matrix_path.name, matrix_descriptor))
        if hashlib.sha256(matrix_bytes).hexdigest() != plan["matrix_sha256"]:
            raise ControlledSoakError("matrix changed after plan creation")
        try:
            matrix_value = json.loads(matrix_bytes.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ControlledSoakError("matrix bytes are not valid JSON") from error
        candidate = matrix_value.get("candidate") if isinstance(matrix_value, dict) else None
        if not isinstance(candidate, dict):
            raise ControlledSoakError("matrix candidate is malformed")
        provenance_name = candidate.get("provenance_file")
        row_name = next((row.filename for row in _C8_SCHEMA.ROWS if row.row_id == "soak"), None)
        if provenance_name != "candidate-provenance.txt" or row_name is None:
            raise ControlledSoakError("matrix source paths are not canonical")
        provenance_bytes, provenance_descriptor = _read_trusted_source(parent_descriptor, provenance_name)
        source_descriptors.append((provenance_name, provenance_descriptor))
        row_bytes, row_descriptor = _read_trusted_source(parent_descriptor, row_name)
        source_descriptors.append((row_name, row_descriptor))
        if hashlib.sha256(provenance_bytes).hexdigest() != plan["candidate"]["matrix_provenance_sha256"]:
            raise ControlledSoakError("matrix provenance changed after plan creation")
        try:
            row_value = json.loads(row_bytes.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ControlledSoakError("soak row bytes are not valid JSON") from error
        matrix_candidate = _validate_matrix_bytes(matrix_value, provenance_bytes, row_value, plan)
        _C8._verify_parent_identity(matrix_path, parent_descriptors)
        for name, descriptor in source_descriptors:
            _C8._verify_published_inode(parent_descriptor, name, descriptor)
    finally:
        for _, descriptor in reversed(source_descriptors):
            _C8._close_output_descriptor(descriptor)
        _C8._close_descriptors(parent_descriptors)
def _validate_matrix_bytes(matrix: object, provenance: bytes, row: object, plan: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(matrix, dict) or set(matrix) != _C8_SCHEMA.MATRIX_KEYS:
        raise ControlledSoakError("matrix schema is unsupported")
    if matrix.get("schema") != _C8_SCHEMA.MATRIX_SCHEMA or matrix.get("matrix_id") != plan["matrix_id"]:
        raise ControlledSoakError("matrix identity changed after plan creation")
    candidate = matrix.get("candidate")
    if not isinstance(candidate, dict) or set(candidate) != _C8_SCHEMA.MATRIX_CANDIDATE_KEYS:
        raise ControlledSoakError("matrix candidate is malformed")
    if candidate.get("provenance_file") != "candidate-provenance.txt":
        raise ControlledSoakError("matrix provenance path is not canonical")
    if hashlib.sha256(provenance).hexdigest() != candidate.get("provenance_sha256"):
        raise ControlledSoakError("matrix provenance hash is stale")
    required_provenance = {
        "archive_tree_sha256",
        "team_identifier",
        "app_cdhash",
        "helper_cdhash",
        "extension_cdhash",
    }
    try:
        pairs = [line.split("=", 1) for line in provenance.decode("utf-8").splitlines()]
    except UnicodeError as error:
        raise ControlledSoakError("matrix provenance is not UTF-8") from error
    if any(len(pair) != 2 or not pair[0] or not pair[1] for pair in pairs):
        raise ControlledSoakError("matrix provenance is malformed")
    if {pair[0] for pair in pairs} != required_provenance or len(pairs) != len(required_provenance):
        raise ControlledSoakError("matrix provenance tuple is not exact")
    provenance_values = dict(pairs)
    if not SHA256_RE.fullmatch(provenance_values["archive_tree_sha256"]):
        raise ControlledSoakError("matrix archive tree hash is malformed")
    if provenance_values["team_identifier"] != TEAM_IDENTIFIER:
        raise ControlledSoakError("matrix team identifier is not production")
    if any(not CDHASH_RE.fullmatch(provenance_values[key]) for key in ("app_cdhash", "helper_cdhash", "extension_cdhash")):
        raise ControlledSoakError("matrix candidate CDHash is malformed")
    for key in required_provenance:
        if provenance_values[key] != candidate.get(key):
            raise ControlledSoakError("matrix candidate differs from its provenance")
    expected_candidate = {
        key: (
            "candidate-provenance.txt"
            if key == "provenance_file"
            else plan["candidate"]["matrix_provenance_sha256"]
            if key == "provenance_sha256"
            else plan["candidate"][key]
        )
        for key in _C8_SCHEMA.MATRIX_CANDIDATE_KEYS
    }
    if candidate != expected_candidate:
        raise ControlledSoakError("matrix candidate differs from the plan")
    expected_boundary = {
        "preparation_performs_physical_actions": False,
        "row_execution_implemented": False,
        "per_class_authorization_required": True,
        "raw_frame_or_content_evidence": "prohibited",
    }
    if matrix.get("physical_boundary") != expected_boundary or matrix.get("row_count") != len(_C8_SCHEMA.ROWS):
        raise ControlledSoakError("matrix physical boundary is not fail-closed")
    references = matrix.get("rows")
    if not isinstance(references, list) or len(references) != len(_C8_SCHEMA.ROWS):
        raise ControlledSoakError("matrix row references are incomplete")
    expected_references = [
        {
            "row_id": definition.row_id,
            "path": definition.filename,
            "authorization_environment_variable": definition.authorization_environment_variable,
            "requires_unlocked_start": definition.requires_unlocked_start,
        }
        for definition in _C8_SCHEMA.ROWS
    ]
    if references != expected_references:
        raise ControlledSoakError("matrix row references are not exact")
    soak_definition = next(item for item in _C8_SCHEMA.ROWS if item.row_id == "soak")
    if not isinstance(row, dict) or set(row) != _C8_SCHEMA.ROW_KEYS:
        raise ControlledSoakError("soak row schema is unsupported")
    if any(row.get(key) != expected for key, expected in {
        "schema": _C8_SCHEMA.ROW_SCHEMA,
        "matrix_id": plan["matrix_id"],
        "row_id": "soak",
        "ordinal": soak_definition.ordinal,
        "scenario": soak_definition.scenario,
        "action_class": soak_definition.action_class,
        "status": "pending",
        "row_run_id": None,
    }.items()):
        raise ControlledSoakError("soak row is not pending and exact")
    if row.get("candidate") != {key: candidate[key] for key in _C8_SCHEMA.ROW_CANDIDATE_KEYS}:
        raise ControlledSoakError("soak row candidate differs from matrix")
    if row.get("console") != {"requires_unlocked_start": soak_definition.requires_unlocked_start, "state_at_start": None}:
        raise ControlledSoakError("soak row console template drifted")
    return candidate


def _read_trusted_source(parent_descriptor: int, name: str) -> tuple[bytes, int]:
    flags = os.O_RDONLY | (os.O_NOFOLLOW if hasattr(os, "O_NOFOLLOW") else 0)
    descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    try:
        stat_result = os.fstat(descriptor)
        if stat_result.st_uid not in (0, os.getuid()) or stat_result.st_mode & 0o022:
            raise ControlledSoakError("matrix source inode is not private")
        chunks = bytearray()
        while True:
            chunk = os.read(descriptor, min(8192, MAX_PLAN_BYTES + 1 - len(chunks)))
            if not chunk:
                break
            chunks.extend(chunk)
            if len(chunks) > MAX_PLAN_BYTES:
                raise ControlledSoakError("matrix source exceeds its size cap")
        return bytes(chunks), descriptor
    except BaseException:
        _C8._close_output_descriptor(descriptor)
        raise


def _exact_processes(deps: RunnerDependencies, plan: dict[str, Any]) -> list[dict[str, Any]]:
    processes = deps.process_probe()
    if not isinstance(processes, list) or any(not isinstance(item, dict) for item in processes):
        raise ControlledSoakError("installed candidate process identity is malformed")
    allowed_paths = {
        plan["candidate"].get("app_executable_path", str(APP_EXECUTABLE_PATH)),
        plan["candidate"].get("helper_path", str(HELPER_PATH)),
        plan["candidate"].get("extension_path", str(EXTENSION_PATH)),
    }
    if not processes or any(item.get("path") not in allowed_paths for item in processes):
        raise ControlledSoakError("no exact-path installed candidate process was observed")
    required_cdhash = {
        plan["candidate"].get("app_executable_path", str(APP_EXECUTABLE_PATH)): plan["candidate"]["app_cdhash"],
        plan["candidate"]["helper_path"]: plan["candidate"]["helper_cdhash"],
        plan["candidate"]["extension_path"]: plan["candidate"]["extension_cdhash"],
    }
    if any(item.get("cdhash") != required_cdhash[item["path"]] for item in processes):
        raise ControlledSoakError("installed candidate process identity drifted")
    paths = {item["path"] for item in processes}
    if plan["candidate"]["helper_path"] not in paths or not (
        plan["candidate"].get("app_executable_path", str(APP_EXECUTABLE_PATH)) in paths
        or plan["candidate"]["extension_path"] in paths
    ):
        raise ControlledSoakError("helper and camera consumer process identities are incomplete")
    normalized = []
    for item in processes:
        try:
            pid = int(item["pid"])
        except (KeyError, TypeError, ValueError) as error:
            raise ControlledSoakError("installed candidate process identity is malformed") from error
        start_identity = item.get("start_identity")
        if pid <= 0 or not isinstance(start_identity, str) or not re.fullmatch(r"[0-9]+:[0-9]+", start_identity):
            raise ControlledSoakError("installed candidate process identity is malformed")
        normalized.append({"pid": pid, "path": item["path"], "cdhash": item["cdhash"], "start_identity": start_identity})
    if len({item["pid"] for item in normalized}) != len(normalized):
        raise ControlledSoakError("installed candidate process identity is malformed")
    return sorted(normalized, key=lambda item: item["pid"])


def _failure(plan: dict[str, Any] | None, reason: str) -> dict[str, Any]:
    reason = reason.strip() or "controlled soak failed"
    return {
        "schema": RESULT_SCHEMA,
        "status": "failed",
        "failure_reasons": [reason],
        "plan_digest": plan.get("plan_digest") if plan else None,
        "authorization_id": plan.get("authorization_id") if plan else None,
        "candidate": plan.get("candidate") if plan else None,
        "lifecycle_observations": None,
        "energy_artifact_sha256": None,
        "sample_coverage": 0.0,
        "started_at_utc": plan.get("created_at_utc") if plan else None,
        "completed_at_utc": None,
        "c8_evidence_completed": False,
        "physical_actions_performed": False,
    }


def _publish_failure(result_path: Path, plan: dict[str, Any] | None, reason: str) -> dict[str, Any]:
    result = _failure(plan, reason)
    write_json_atomic(result_path, result)
    return result


def execute_plan(
    plan_path: Path,
    result_path: Path,
    energy_path: Path,
    *,
    now: datetime | None = None,
    dependencies: RunnerDependencies | None = None,
    tty_available: bool = False,
    confirmation: Callable[[str], object] | None = None,
) -> dict[str, Any]:
    plan: dict[str, Any] | None = None
    plan_handle: _PlanHandle | None = None
    result_reservation: _Reservation | None = None
    energy_reservation: _Reservation | None = None
    success = False
    try:
        if result_path.resolve() == energy_path.resolve():
            raise ControlledSoakError("result and energy outputs must be distinct")
        plan_handle = _open_plan(plan_path)
        plan = _read_plan_handle(plan_handle)
        deps = _deps_or_default(dependencies)
        current = now or deps.clock()
        created = _parse_utc(plan["created_at_utc"])
        expires = _parse_utc(plan["expires_at_utc"])
        if created > current or expires - created != timedelta(seconds=PLAN_TTL_SECONDS):
            raise ControlledSoakError("controlled soak plan timing is invalid")
        if current >= expires:
            raise ControlledSoakError("controlled soak plan is expired")
        _opt_in_refusal()
        if not tty_available:
            raise ControlledSoakError("a controlling TTY is required")
        result_reservation = _reserve_output(result_path)
        energy_reservation = _reserve_output(energy_path)
        if deps.console_probe().get("state") != "unlocked":
            raise ControlledSoakError("live console probe is not unlocked")
        _validate_candidate(deps.candidate_probe(), plan)
        pre_boundary_processes = _exact_processes(deps, plan)
        pre_boundary_pids = [item["pid"] for item in pre_boundary_processes]
        expected = (
            f"CONFIRM CONTROLLED SOAK {plan['authorization_id']} "
            f"{plan['candidate']['archive_tree_sha256']} {plan['duration_seconds']}s"
        )
        current = now or deps.clock()
        if current >= expires:
            raise ControlledSoakError("controlled soak plan expired before confirmation")
        if confirmation is None or confirmation(expected) != expected:
            raise ControlledSoakError("operator declined controlled soak")
        current = now or deps.clock()
        if current >= expires:
            raise ControlledSoakError("controlled soak plan expired before claim")
        _validate_matrix_binding(plan)
        candidate = deps.candidate_probe()
        _validate_candidate(candidate, plan)
        if deps.console_probe().get("state") != "unlocked":
            raise ControlledSoakError("live console changed at action boundary")
        current = now or deps.clock()
        if current >= expires:
            raise ControlledSoakError("controlled soak plan expired before claim")
        action_started = current
        _claim(plan_handle, plan["plan_digest"])
        action_processes = _exact_processes(deps, plan)
        pids = [item["pid"] for item in action_processes]
        if action_processes != pre_boundary_processes:
            raise ControlledSoakError("installed candidate process identity drifted")
        observation = supervise_observation(
            plan["duration_seconds"],
            pids,
            deps.lifecycle_collector,
            deps.energy_sampler,
        )
        lifecycle = observation["lifecycle"]
        if not isinstance(lifecycle, dict):
            raise ControlledSoakError("lifecycle collector returned malformed evidence")
        validate_lifecycle_observations(lifecycle)
        energy = observation["energy"]
        samples = energy.get("samples")
        if not isinstance(samples, list) or not samples or energy.get("coverage", 0) < 0.8:
            raise ControlledSoakError("energy sample coverage is insufficient")
        energy_document = {
            "schema": ENERGY_SCHEMA,
            "plan_digest": plan["plan_digest"],
            "sampled_pids": energy["sampled_pids"],
            "samples": energy["samples"],
            "sample_interval_seconds": energy.get("sample_interval_seconds"),
            "sample_count": energy.get("sample_count"),
            "duration_seconds": energy.get("duration_seconds"),
            "per_pid_counts": energy.get("per_pid_counts"),
            "coverage": energy.get("coverage"),
        }
        verify_energy_document(
            energy_document,
            plan["plan_digest"],
            plan_duration_seconds=plan["duration_seconds"],
        )
        _publish_reserved(energy_reservation, energy_document)
        energy_digest = _sha256_descriptor(energy_reservation.descriptor)
        result = {
            "schema": RESULT_SCHEMA,
            "status": "completed",
            "plan_digest": plan["plan_digest"],
            "authorization_id": plan["authorization_id"],
            "candidate": plan["candidate"],
            "lifecycle_observations": lifecycle,
            "energy_artifact_sha256": energy_digest,
            "sample_coverage": energy.get("coverage"),
            "started_at_utc": _utc(action_started),
            "completed_at_utc": _utc((now or deps.clock()) if now is None else action_started + timedelta(seconds=1)),
            "failure_reasons": [],
            "c8_evidence_completed": False,
            "physical_actions_performed": False,
        }
        if not deps.cleanup():
            raise ControlledSoakError("runner cleanup was not verified")
        completed = (now or deps.clock()) if now is None else action_started + timedelta(seconds=1)
        if completed <= action_started:
            raise ControlledSoakError("controlled soak UTC timing is out of order")
        result["completed_at_utc"] = _utc(completed)
        verify_result_document(result, plan["plan_digest"])
        _publish_reserved(result_reservation, result)
        success = True
        return result
    except (ControlledSoakError, _C8.C8EvidenceError, OSError, TypeError, ValueError, KeyError, AttributeError) as error:
        result = _failure(plan, str(error))
        verify_result_document(result, plan["plan_digest"] if plan else None)
        if result_reservation is not None and not result_reservation.published:
            _publish_reserved(result_reservation, result)
        return result
    finally:
        close_errors = []
        for reservation in (energy_reservation, result_reservation):
            if reservation is None:
                continue
            if not reservation.published or (
                reservation is energy_reservation
                and not success
                and not (result_reservation and result_reservation.completed_commit)
            ):
                try:
                    _discard_reservation(reservation)
                except ControlledSoakError as error:
                    close_errors.append(error)
            try:
                _close_reservation(reservation)
            except ControlledSoakError as error:
                close_errors.append(error)
        if plan_handle is not None:
            try:
                _close_plan(plan_handle)
            except ControlledSoakError as error:
                close_errors.append(error)
        if close_errors:
            state = "committed" if success else "failed"
            raise ControlledSoakError(f"controlled soak {state} but cleanup failed") from close_errors[0]
