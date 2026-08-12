#!/usr/bin/env python3
"""Validate canonical R1.1 evidence, assemble a report, and evaluate budgets."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from datetime import datetime
from pathlib import Path
from typing import Any


RENDER_WORKLOADS = (
    "generative",
    "cameraSynthetic",
    "pixelMaterialsSand",
    "pixelMaterialsWater",
    "pixelMaterialsMixed",
)
DOMAIN_WORKLOADS = (
    "mailboxTransport",
    "agentSignalPolling",
    "zeroConsumer",
    "helperIdle",
)
DURATION_WORKLOADS = RENDER_WORKLOADS + DOMAIN_WORKLOADS
EXPECTED_WORKLOADS = (
    "rendererStartupCold",
    "rendererStartupWarm",
    *DURATION_WORKLOADS,
)
HELPER_IDENTITY_PATHS = {
    "helper-start-identity.json",
    "helper-end-identity.json",
}
BASE_ENVIRONMENT_INPUT_PATHS = {
    "displays-end.json",
    "displays-start.json",
    "hardware-end.json",
    "hardware-start.json",
    "operating-system-end.txt",
    "operating-system-start.txt",
    "power-source-end.txt",
    "power-source-start.txt",
    "source-status-end.txt",
    "source-status-start.txt",
    "swift-version-end.txt",
    "swift-version-start.txt",
    "thermal-end.txt",
    "thermal-start.txt",
    "vm-end.txt",
    "vm-start.txt",
    "xcode-version-end.txt",
    "xcode-version-start.txt",
    "xcodegen-version-end.txt",
    "xcodegen-version-start.txt",
}
EXPECTED_ENVIRONMENT_INPUT_PATHS = BASE_ENVIRONMENT_INPUT_PATHS | {
    f"{workload}.footprint.csv" for workload in DURATION_WORKLOADS
}
MINIMUM_GATING_DURATION_SECONDS = 900.0
MINIMUM_SMOKE_DURATION_SECONDS = 5
MINIMUM_ENERGY_COVERAGE_RATIO = 0.80
MEMORY_TREND_RELATIVE_TOLERANCE = 1e-9
MEMORY_TREND_ABSOLUTE_TOLERANCE = 1e-6

PREFLIGHT_KEYS = {
    "schemaVersion",
    "runIdentifier",
    "mode",
    "capturedAt",
    "artifactBuiltAt",
    "requiredDurationSeconds",
    "coldStartupSampleCount",
    "warmStartupSampleCount",
    "energySamplingIntervalSeconds",
    "sourceIdentity",
    "toolchain",
    "operatingSystem",
    "hardware",
    "display",
    "targetFramesPerSecond",
    "targetSurface",
    "powerSource",
    "artifactManifestSHA256",
    "budgetsSHA256",
    "workloads",
    "environmentInputPaths",
}
WORKLOAD_SPEC_KEYS = {
    "workload",
    "resultPaths",
    "iterationsPerResult",
    "durationSeconds",
    "energyPath",
}
EVIDENCE_MANIFEST_KEYS = {"schemaVersion", "runIdentifier", "entries"}
EVIDENCE_ENTRY_KEYS = {"path", "sha256", "byteCount", "kind"}
EVIDENCE_KINDS = {
    "preflight",
    "artifact",
    "budgets",
    "metadata",
    "workload",
    "energy",
    "environment",
    "helperIdentity",
}
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


def _reject_json_constant(value: str) -> Any:
    raise ValueError(f"nonfinite JSON constant: {value}")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            parse_constant=_reject_json_constant,
            object_pairs_hook=_unique_object,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"unable to read JSON {path.name}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path.name}")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(128 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def nearest_rank(values: list[float], percentile: float) -> float:
    if not values:
        raise ValueError("percentile requires at least one value")
    ordered = sorted(values)
    rank = math.ceil(percentile * len(ordered))
    return ordered[max(0, min(len(ordered) - 1, rank - 1))]


def _require_dict(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{context} must be an object")
    return value


def _require_list(value: Any, context: str) -> list[Any]:
    if not isinstance(value, list):
        raise ValueError(f"{context} must be an array")
    return value


def _require_exact_keys(
    value: dict[str, Any], expected: set[str], context: str
) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ValueError(
            f"{context} schema mismatch; missing={missing}, extra={extra}"
        )


def _require_string(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{context} must be a nonempty string")
    return value


def _require_number(value: Any, context: str) -> float:
    if type(value) not in (int, float):
        raise ValueError(f"{context} must be a number")
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"{context} must be finite")
    return number


def _require_nonnegative_number(value: Any, context: str) -> float:
    number = _require_number(value, context)
    if number < 0:
        raise ValueError(f"{context} must not be negative")
    return number


def _require_positive_number(value: Any, context: str) -> float:
    number = _require_number(value, context)
    if number <= 0:
        raise ValueError(f"{context} must be positive")
    return number


def _require_nonnegative_int(value: Any, context: str) -> int:
    if type(value) is not int or value < 0:
        raise ValueError(f"{context} must be a nonnegative integer")
    return value


def _require_positive_int(value: Any, context: str) -> int:
    if type(value) is not int or value <= 0:
        raise ValueError(f"{context} must be a positive integer")
    return value


def _require_iso8601_utc(value: Any, context: str) -> datetime:
    timestamp = _require_string(value, context)
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", timestamp) is None:
        raise ValueError(f"{context} must be an ISO-8601 UTC timestamp")
    try:
        return datetime.fromisoformat(timestamp[:-1] + "+00:00")
    except ValueError as error:
        raise ValueError(f"{context} must be an ISO-8601 UTC timestamp") from error


def _require_sha256(value: Any, context: str) -> str:
    digest = _require_string(value, context)
    if SHA256_PATTERN.fullmatch(digest) is None:
        raise ValueError(f"{context} must be a lowercase SHA-256")
    return digest


def _validate_nonnegative_tree(value: Any, context: str) -> None:
    if type(value) in (int, float):
        _require_nonnegative_number(value, context)
    elif isinstance(value, dict):
        for key, child in value.items():
            _validate_nonnegative_tree(child, f"{context}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _validate_nonnegative_tree(child, f"{context}[{index}]")


def _relative_leaf(value: Any, context: str) -> str:
    path = _require_string(value, context)
    parsed = Path(path)
    if parsed.is_absolute() or parsed.name != path or path in {".", ".."}:
        raise ValueError(f"{context} must be a safe relative leaf path")
    return path


def parse_memory_bytes(raw_value: str) -> float:
    cleaned = raw_value.rstrip("+-")
    match = re.fullmatch(r"(?P<value>\d+(?:\.\d+)?)(?P<unit>[BKMGTP]?)", cleaned)
    if not match:
        raise ValueError(f"unsupported top memory value: {raw_value}")
    multipliers = {
        "": 1,
        "B": 1,
        "K": 1024,
        "M": 1024**2,
        "G": 1024**3,
        "T": 1024**4,
        "P": 1024**5,
    }
    return float(match.group("value")) * multipliers[match.group("unit")]


def top_observations(path: Path) -> list[tuple[float, float]]:
    if not path.is_file():
        return []
    rows = path.read_text(encoding="utf-8").splitlines()
    if not rows:
        return []
    row_pattern = re.compile(
        r"^\s*(?P<pid>\d+)\s+(?P<cpu>\d+(?:\.\d+)?)\s+"
        r"(?P<power>\d+(?:\.\d+)?)\s+(?P<memory>\S+)\s*$"
    )
    samples: list[tuple[float, float]] = []
    process_identifiers: set[int] = set()
    for index, line in enumerate(rows, start=1):
        match = row_pattern.fullmatch(line)
        if match is None:
            raise ValueError(f"invalid Energy sample row {path.name}:{index}")
        process_identifiers.add(int(match.group("pid")))
        cpu = float(match.group("cpu"))
        power = float(match.group("power"))
        memory = parse_memory_bytes(match.group("memory"))
        if not all(math.isfinite(item) and item >= 0 for item in (cpu, power, memory)):
            raise ValueError(f"invalid Energy sample value in {path.name}:{index}")
        samples.append((power, memory))
    if len(process_identifiers) != 1:
        raise ValueError(f"mixed process identifiers in Energy samples: {path.name}")
    # top's launch-baseline observation is cumulative and routinely zero.
    return samples[1:] if len(samples) > 1 else []


def energy_samples(path: Path) -> list[float]:
    return [power for power, _ in top_observations(path)]


def memory_growth_bytes_per_hour(
    samples: list[float], duration_seconds: float
) -> float:
    if len(samples) < 2 or duration_seconds <= 0:
        raise ValueError("memory trend requires two samples and positive duration")
    spacing = duration_seconds / (len(samples) - 1)
    times = [index * spacing for index in range(len(samples))]
    mean_time = sum(times) / len(times)
    mean_memory = sum(samples) / len(samples)
    denominator = sum((value - mean_time) ** 2 for value in times)
    if denominator == 0:
        return 0
    numerator = sum(
        (time - mean_time) * (memory - mean_memory)
        for time, memory in zip(times, samples)
    )
    return max(0, numerator / denominator * 3600)


def _growth_for_timestamped_memory(samples: list[dict[str, Any]]) -> float:
    origin = float(samples[0]["capturedAt"])
    times = [float(sample["capturedAt"]) - origin for sample in samples]
    values = [float(sample["physicalFootprintBytes"]) for sample in samples]
    mean_time = sum(times) / len(times)
    mean_value = sum(values) / len(values)
    denominator = sum((value - mean_time) ** 2 for value in times)
    if denominator <= 0:
        return 0.0
    numerator = sum(
        (time - mean_time) * (value - mean_value)
        for time, value in zip(times, values)
    )
    return max(0.0, numerator / denominator * 3600)


def _sustained_growth_for_timestamped_memory(
    samples: list[dict[str, Any]],
) -> float:
    if len(samples) < 6:
        return _growth_for_timestamped_memory(samples)
    duration = float(samples[-1]["capturedAt"]) - float(
        samples[0]["capturedAt"]
    )
    if duration <= 0:
        return 0.0
    window_duration = duration / 5
    slopes: list[float] = []
    end_index = 1
    for start_index, start in enumerate(samples):
        end_index = max(end_index, start_index + 1)
        window_end = float(start["capturedAt"]) + window_duration
        while (
            end_index < len(samples)
            and float(samples[end_index]["capturedAt"]) < window_end
        ):
            end_index += 1
        if end_index >= len(samples):
            break
        slopes.append(
            _growth_for_timestamped_memory(samples[start_index : end_index + 1])
        )
    if not slopes:
        return _growth_for_timestamped_memory(samples)
    slopes.sort()
    midpoint = len(slopes) // 2
    if len(slopes) % 2 == 0:
        return (slopes[midpoint - 1] + slopes[midpoint]) / 2
    return slopes[midpoint]


def _validate_memory_context(result: dict[str, Any], context: str) -> None:
    samples = _require_list(result.get("memorySamples"), f"{context}.memorySamples")
    if len(samples) < 2:
        raise ValueError(f"{context}.memorySamples requires at least two samples")
    normalized: list[dict[str, Any]] = []
    previous_time: float | None = None
    for index, raw_sample in enumerate(samples):
        sample = _require_dict(raw_sample, f"{context}.memorySamples[{index}]")
        _require_exact_keys(
            sample,
            {"capturedAt", "physicalFootprintBytes"},
            f"{context}.memorySamples[{index}]",
        )
        captured_at = _require_nonnegative_number(
            sample["capturedAt"], f"{context}.memorySamples[{index}].capturedAt"
        )
        _require_nonnegative_int(
            sample["physicalFootprintBytes"],
            f"{context}.memorySamples[{index}].physicalFootprintBytes",
        )
        if previous_time is not None and captured_at <= previous_time:
            raise ValueError(f"{context}.memorySamples timestamps are not ordered")
        previous_time = captured_at
        normalized.append(sample)
    sample_duration = float(normalized[-1]["capturedAt"]) - float(
        normalized[0]["capturedAt"]
    )
    duration = float(result["durationSeconds"])
    if not math.isclose(sample_duration, duration, rel_tol=0.01, abs_tol=0.1):
        raise ValueError(f"{context}.memorySamples duration does not match workload")

    trend = _require_dict(result.get("memoryTrend"), f"{context}.memoryTrend")
    _require_exact_keys(
        trend,
        {
            "sampleCount",
            "peakPhysicalFootprintBytes",
            "growthBytesPerHour",
            "wholeWindowGrowthBytesPerHour",
            "steadyStateWindowStartedAt",
        },
        f"{context}.memoryTrend",
    )
    if _require_positive_int(trend["sampleCount"], f"{context}.memoryTrend.sampleCount") != len(normalized):
        raise ValueError(f"{context}.memoryTrend sampleCount mismatch")
    expected_peak = max(int(item["physicalFootprintBytes"]) for item in normalized)
    if trend["peakPhysicalFootprintBytes"] != expected_peak:
        raise ValueError(f"{context}.memoryTrend peak mismatch")
    midpoint = float(normalized[0]["capturedAt"]) + sample_duration / 2
    first_tail = next(
        index
        for index, sample in enumerate(normalized)
        if float(sample["capturedAt"]) >= midpoint
    )
    tail_start = max(0, first_tail - 1)
    expected_steady_start = float(normalized[tail_start]["capturedAt"])
    expected_whole_growth = _growth_for_timestamped_memory(normalized)
    expected_steady_growth = _sustained_growth_for_timestamped_memory(
        normalized[tail_start:]
    )
    comparisons = {
        "steadyStateWindowStartedAt": expected_steady_start,
        "wholeWindowGrowthBytesPerHour": expected_whole_growth,
        "growthBytesPerHour": expected_steady_growth,
    }
    for key, expected in comparisons.items():
        actual = _require_nonnegative_number(trend[key], f"{context}.memoryTrend.{key}")
        if not math.isclose(
            actual,
            expected,
            rel_tol=MEMORY_TREND_RELATIVE_TOLERANCE,
            abs_tol=MEMORY_TREND_ABSOLUTE_TOLERANCE,
        ):
            raise ValueError(f"{context}.memoryTrend {key} mismatch")
    resources = _require_dict(result["resources"], f"{context}.resources")
    if not math.isclose(
        float(resources["residentMemoryGrowthBytesPerHour"]),
        expected_steady_growth,
        rel_tol=MEMORY_TREND_RELATIVE_TOLERANCE,
        abs_tol=MEMORY_TREND_ABSOLUTE_TOLERANCE,
    ):
        raise ValueError(f"{context}.resources memory trend mismatch")
    if resources["peakResidentMemoryBytes"] != expected_peak:
        raise ValueError(f"{context}.resources peak memory mismatch")


def _validate_distribution(
    raw: Any, context: str, expected_count: int | None = None
) -> dict[str, Any]:
    value = _require_dict(raw, context)
    _require_exact_keys(
        value,
        {"count", "minimum", "median", "p95", "p99", "maximum", "mean"},
        context,
    )
    count = _require_positive_int(value["count"], f"{context}.count")
    if expected_count is not None and count != expected_count:
        raise ValueError(
            f"{context} count {count} does not match expected {expected_count}"
        )
    ordered_keys = ("minimum", "median", "p95", "p99", "maximum")
    ordered = [
        _require_nonnegative_number(value[key], f"{context}.{key}")
        for key in ordered_keys
    ]
    if ordered != sorted(ordered):
        raise ValueError(f"{context} distribution order is incoherent")
    mean = _require_nonnegative_number(value["mean"], f"{context}.mean")
    if not ordered[0] <= mean <= ordered[-1]:
        raise ValueError(f"{context} mean is outside its distribution")
    return value


def _drop_reason_total(value: Any, context: str) -> int:
    if isinstance(value, dict):
        counts = list(value.values())
    elif isinstance(value, list):
        if len(value) % 2 != 0:
            raise ValueError(f"{context} must contain key/count pairs")
        counts = value[1::2]
    else:
        raise ValueError(f"{context} must be an object or key/count array")
    return sum(_require_nonnegative_int(count, context) for count in counts)


def _validate_render_surface(
    raw: Any,
    context: str,
    preflight: dict[str, Any],
    budgets: dict[str, Any],
) -> None:
    surface = _require_dict(raw, f"{context}.renderSurface")
    _require_exact_keys(
        surface,
        {
            "logicalWidth",
            "logicalHeight",
            "drawableWidth",
            "drawableHeight",
            "deviceName",
            "deviceRegistryID",
            "colorPixelFormat",
        },
        f"{context}.renderSurface",
    )
    target = preflight["targetSurface"]
    expected = {
        "logicalWidth": target["logicalWidth"],
        "logicalHeight": target["logicalHeight"],
        "drawableWidth": target["pixelWidth"],
        "drawableHeight": target["pixelHeight"],
        "deviceName": budgets["metalDeviceName"],
        "colorPixelFormat": budgets["colorPixelFormat"],
    }
    for key, expected_value in expected.items():
        if surface.get(key) != expected_value:
            raise ValueError(
                f"{context}.renderSurface.{key} does not match named target"
            )
    _require_positive_int(
        surface["deviceRegistryID"], f"{context}.renderSurface.deviceRegistryID"
    )


def _validate_cadence_diagnostics(
    raw: Any,
    context: str,
    counts: dict[str, int],
    preflight: dict[str, Any],
) -> None:
    cadence = _require_dict(raw, f"{context}.cadenceDiagnostics")
    _require_exact_keys(
        cadence,
        {
            "attemptStartIntervalMilliseconds",
            "wakeLatenessMilliseconds",
            "attemptDurationMilliseconds",
            "submissionOffsetMilliseconds",
            "slowIntervalThresholdMilliseconds",
            "slowSubmissionIntervalCount",
            "slowAttemptStartIntervalCount",
            "slowSubmissionWithSlowAttemptStartCount",
        },
        f"{context}.cadenceDiagnostics",
    )
    attempted = counts["attemptedFrameCount"]
    submitted = counts["submittedFrameCount"]
    attempt_intervals = _validate_distribution(
        cadence["attemptStartIntervalMilliseconds"],
        f"{context}.cadenceDiagnostics.attemptStartIntervalMilliseconds",
        max(0, attempted - 1),
    )
    _validate_distribution(
        cadence["wakeLatenessMilliseconds"],
        f"{context}.cadenceDiagnostics.wakeLatenessMilliseconds",
        attempted,
    )
    attempt_duration = _validate_distribution(
        cadence["attemptDurationMilliseconds"],
        f"{context}.cadenceDiagnostics.attemptDurationMilliseconds",
        attempted,
    )
    submission_offset = _validate_distribution(
        cadence["submissionOffsetMilliseconds"],
        f"{context}.cadenceDiagnostics.submissionOffsetMilliseconds",
        submitted,
    )
    if float(submission_offset["maximum"]) > float(attempt_duration["maximum"]):
        raise ValueError(f"{context}.cadenceDiagnostics submission offset exceeds attempt duration")

    threshold = _require_positive_number(
        cadence["slowIntervalThresholdMilliseconds"],
        f"{context}.cadenceDiagnostics.slowIntervalThresholdMilliseconds",
    )
    target_fps = _require_positive_int(
        preflight["targetFramesPerSecond"],
        "preflight.targetFramesPerSecond",
    )
    diagnostic_threshold = 1.2 * 1000 / target_fps
    if not math.isclose(threshold, diagnostic_threshold, rel_tol=0, abs_tol=1e-12):
        raise ValueError(
            f"{context}.cadenceDiagnostics threshold differs from 1.2 frame periods"
        )

    slow_submission = _require_nonnegative_int(
        cadence["slowSubmissionIntervalCount"],
        f"{context}.cadenceDiagnostics.slowSubmissionIntervalCount",
    )
    slow_attempt = _require_nonnegative_int(
        cadence["slowAttemptStartIntervalCount"],
        f"{context}.cadenceDiagnostics.slowAttemptStartIntervalCount",
    )
    correlated = _require_nonnegative_int(
        cadence["slowSubmissionWithSlowAttemptStartCount"],
        f"{context}.cadenceDiagnostics.slowSubmissionWithSlowAttemptStartCount",
    )
    if slow_submission > max(0, submitted - 1):
        raise ValueError(f"{context}.cadenceDiagnostics slow submission count is impossible")
    if slow_attempt > max(0, submitted - 1):
        raise ValueError(f"{context}.cadenceDiagnostics slow attempt count is impossible")
    if correlated > min(slow_submission, slow_attempt):
        raise ValueError(f"{context}.cadenceDiagnostics correlated count is impossible")
    if float(attempt_intervals["maximum"]) <= threshold and slow_attempt != 0:
        raise ValueError(f"{context}.cadenceDiagnostics slow attempt count is incoherent")


def _validate_workload_result(
    result: dict[str, Any],
    workload: str,
    path: str,
    preflight: dict[str, Any],
    budgets: dict[str, Any],
    expected_iterations: int | None,
) -> None:
    context = f"workload {workload} ({path})"
    if result.get("workload") != workload:
        raise ValueError(
            f"workload label for {path} does not match {workload}"
        )
    _validate_nonnegative_tree(result, context)
    duration = _require_positive_number(
        result.get("durationSeconds"), f"{context}.durationSeconds"
    )
    counts = {
        key: _require_nonnegative_int(result.get(key), f"{context}.{key}")
        for key in (
            "scheduledFrameCount",
            "attemptedFrameCount",
            "submittedFrameCount",
            "completedFrameCount",
            "droppedFrameCount",
            "deadlineMissCount",
        )
    }
    if counts["scheduledFrameCount"] != counts["attemptedFrameCount"]:
        raise ValueError(f"{context}.scheduledFrameCount does not match attempted")
    if counts["attemptedFrameCount"] != (
        counts["submittedFrameCount"] + counts["droppedFrameCount"]
    ):
        raise ValueError(f"{context}.attemptedFrameCount accounting is incoherent")
    if counts["completedFrameCount"] != counts["submittedFrameCount"]:
        raise ValueError(f"{context}.completedFrameCount does not match submitted")
    if counts["deadlineMissCount"] > counts["scheduledFrameCount"]:
        raise ValueError(f"{context}.deadlineMissCount exceeds scheduled frames")
    ratio = _require_nonnegative_number(
        result.get("droppedFrameRatio"), f"{context}.droppedFrameRatio"
    )
    expected_ratio = (
        counts["droppedFrameCount"] / counts["attemptedFrameCount"]
        if counts["attemptedFrameCount"]
        else 0.0
    )
    if not math.isclose(ratio, expected_ratio, rel_tol=1e-12, abs_tol=1e-12):
        raise ValueError(f"{context}.droppedFrameRatio is incoherent")
    if _drop_reason_total(result.get("dropReasons"), f"{context}.dropReasons") != counts["droppedFrameCount"]:
        raise ValueError(f"{context}.dropReasons do not match droppedFrameCount")

    resources = _require_dict(result.get("resources"), f"{context}.resources")
    _require_exact_keys(
        resources,
        {
            "durationSeconds",
            "averageCPUPercent",
            "residentMemoryGrowthBytesPerHour",
            "wakeupsPerSecond",
            "peakResidentMemoryBytes",
            "lifetimePeakResidentMemoryBytes",
        },
        f"{context}.resources",
    )
    resource_duration = _require_positive_number(
        resources["durationSeconds"], f"{context}.resources.durationSeconds"
    )
    if not math.isclose(resource_duration, duration, rel_tol=1e-6, abs_tol=0.01):
        raise ValueError(f"{context}.resources duration does not match workload")
    in_window_peak = _require_nonnegative_int(
        resources["peakResidentMemoryBytes"],
        f"{context}.resources.peakResidentMemoryBytes",
    )
    lifetime_peak = _require_nonnegative_int(
        resources["lifetimePeakResidentMemoryBytes"],
        f"{context}.resources.lifetimePeakResidentMemoryBytes",
    )
    if lifetime_peak < in_window_peak:
        raise ValueError(f"{context}.resources lifetime peak is below in-window peak")
    _validate_memory_context(result, context)

    if expected_iterations is not None:
        if workload == "rendererStartupCold" and expected_iterations != 1:
            raise ValueError("cold startup results must be singleton samples")
        if workload == "rendererStartupWarm" and expected_iterations != 5:
            raise ValueError("warm startup result must contain five samples")
        if counts["attemptedFrameCount"] != expected_iterations:
            label = "cold singleton" if workload == "rendererStartupCold" else "warm five"
            raise ValueError(f"{label} sample count is invalid")
        _validate_distribution(
            result.get("operationMilliseconds"),
            f"{context}.operationMilliseconds",
            expected_iterations,
        )
        _validate_render_surface(result.get("renderSurface"), context, preflight, budgets)
        return

    if workload in RENDER_WORKLOADS:
        submitted = counts["submittedFrameCount"]
        _validate_distribution(
            result.get("cpuMilliseconds"),
            f"{context}.cpuMilliseconds",
            submitted,
        )
        _validate_distribution(
            result.get("gpuMilliseconds"),
            f"{context}.gpuMilliseconds",
            counts["completedFrameCount"],
        )
        _validate_distribution(
            result.get("frameIntervalMilliseconds"),
            f"{context}.frameIntervalMilliseconds",
            max(0, submitted - 1),
        )
        if result.get("operationMilliseconds") is not None:
            _validate_distribution(
                result["operationMilliseconds"],
                f"{context}.operationMilliseconds",
                submitted,
            )
        _validate_cadence_diagnostics(
            result.get("cadenceDiagnostics"),
            context,
            counts,
            preflight,
        )
        _validate_render_surface(result.get("renderSurface"), context, preflight, budgets)
    else:
        if any(counts.values()):
            raise ValueError(f"{context} domain frame/schedule counts must be zero")
        if workload in {"mailboxTransport", "agentSignalPolling"}:
            _validate_distribution(
                result.get("operationMilliseconds"),
                f"{context}.operationMilliseconds",
            )


def _validate_budget_and_environment(
    preflight: dict[str, Any], budgets: dict[str, Any], metadata: dict[str, Any]
) -> None:
    _require_exact_keys(
        budgets,
        {
            "identifier",
            "hardwareClass",
            "displayCount",
            "displayPixelWidth",
            "displayPixelHeight",
            "displayScale",
            "metalDeviceName",
            "colorPixelFormat",
            "targetFramesPerSecond",
            "limits",
        },
        "budgets",
    )
    _require_exact_keys(
        metadata,
        {
            "schemaVersion",
            "runIdentifier",
            "capturedAt",
            "commit",
            "artifactSHA256",
            "hardware",
            "operatingSystem",
            "display",
            "notes",
        },
        "metadata",
    )
    if metadata["schemaVersion"] != 1:
        raise ValueError("metadata schemaVersion must be 1")
    notes = _require_list(metadata["notes"], "metadata.notes")
    for index, note in enumerate(notes):
        _require_string(note, f"metadata.notes[{index}]")

    hardware = _require_dict(preflight["hardware"], "preflight.hardware")
    _require_exact_keys(
        hardware,
        {
            "modelIdentifier",
            "hardwareClass",
            "chip",
            "cpuCoreCount",
            "gpuCoreCount",
            "memoryBytes",
        },
        "preflight.hardware",
    )
    for key in ("modelIdentifier", "hardwareClass", "chip"):
        _require_string(hardware[key], f"preflight.hardware.{key}")
    for key in ("cpuCoreCount", "gpuCoreCount", "memoryBytes"):
        _require_positive_int(hardware[key], f"preflight.hardware.{key}")
    expected_hardware_class = (
        f"{hardware['chip']} {hardware['gpuCoreCount']}-core GPU"
    )
    if hardware["hardwareClass"] != expected_hardware_class:
        raise ValueError("preflight hardwareClass does not match observed hardware")
    if budgets.get("hardwareClass") != hardware["hardwareClass"]:
        raise ValueError("budget hardwareClass does not match observed hardware")
    if budgets.get("metalDeviceName") != hardware["chip"]:
        raise ValueError("budget Metal device does not match observed hardware")

    display = _require_dict(preflight["display"], "preflight.display")
    _require_exact_keys(
        display,
        {
            "count",
            "logicalWidth",
            "logicalHeight",
            "pixelWidth",
            "pixelHeight",
            "scale",
            "refreshRateHertz",
        },
        "preflight.display",
    )
    for key in (
        "count",
        "logicalWidth",
        "logicalHeight",
        "pixelWidth",
        "pixelHeight",
    ):
        _require_positive_int(display[key], f"preflight.display.{key}")
    scale = _require_positive_number(display["scale"], "preflight.display.scale")
    _require_positive_number(
        display["refreshRateHertz"], "preflight.display.refreshRateHertz"
    )
    target = _require_dict(preflight["targetSurface"], "preflight.targetSurface")
    _require_exact_keys(
        target,
        {"logicalWidth", "logicalHeight", "pixelWidth", "pixelHeight"},
        "preflight.targetSurface",
    )
    for key in target:
        _require_positive_int(target[key], f"preflight.targetSurface.{key}")
        if target[key] != display[key]:
            raise ValueError(f"target surface {key} does not match actual display")
    if not math.isclose(
        target["logicalWidth"] * scale,
        target["pixelWidth"],
        rel_tol=0,
        abs_tol=1,
    ) or not math.isclose(
        target["logicalHeight"] * scale,
        target["pixelHeight"],
        rel_tol=0,
        abs_tol=1,
    ):
        raise ValueError("target surface scale is incoherent")

    budget_surface = {
        "displayCount": display["count"],
        "displayPixelWidth": display["pixelWidth"],
        "displayPixelHeight": display["pixelHeight"],
        "displayScale": display["scale"],
        "targetFramesPerSecond": preflight["targetFramesPerSecond"],
    }
    for key, expected in budget_surface.items():
        if budgets.get(key) != expected:
            raise ValueError(f"budget {key} does not match named environment")
    identifier = _require_string(budgets.get("identifier"), "budgets.identifier")
    dimensions = f"{target['pixelWidth']}x{target['pixelHeight']}"
    if dimensions not in identifier:
        raise ValueError("budget identifier does not name the target surface")
    _require_string(budgets.get("colorPixelFormat"), "budgets.colorPixelFormat")

    metadata_hardware = _require_dict(metadata.get("hardware"), "metadata.hardware")
    _require_exact_keys(metadata_hardware, set(hardware), "metadata.hardware")
    if metadata_hardware != hardware:
        raise ValueError("metadata hardware mismatch")
    metadata_display = _require_dict(metadata.get("display"), "metadata.display")
    _require_exact_keys(metadata_display, set(display), "metadata.display")
    if metadata_display != display:
        raise ValueError("metadata display mismatch")
    if metadata.get("operatingSystem") != preflight["operatingSystem"]:
        raise ValueError("metadata operatingSystem mismatch")
    if metadata.get("commit") != preflight["sourceIdentity"]["commit"]:
        raise ValueError("metadata source commit mismatch")


def _validate_limits(budgets: dict[str, Any]) -> list[dict[str, Any]]:
    limits = _require_list(budgets.get("limits"), "budgets.limits")
    if not limits:
        raise ValueError("budgets.limits must not be empty")
    seen: set[tuple[str, str]] = set()
    covered: set[str] = set()
    validated: list[dict[str, Any]] = []
    for index, raw_limit in enumerate(limits):
        limit = _require_dict(raw_limit, f"budgets.limits[{index}]")
        _require_exact_keys(
            limit,
            {"workload", "metric", "maximum", "unit"},
            f"budgets.limits[{index}]",
        )
        workload = _require_string(limit["workload"], "budget workload")
        metric = _require_string(limit["metric"], "budget metric")
        _require_nonnegative_number(limit["maximum"], "budget maximum")
        _require_string(limit["unit"], "budget unit")
        if workload not in EXPECTED_WORKLOADS:
            raise ValueError(f"unknown budget workload: {workload}")
        key = (workload, metric)
        if key in seen:
            raise ValueError(f"duplicate budget limit: {workload}/{metric}")
        seen.add(key)
        covered.add(workload)
        validated.append(limit)
    if covered != set(EXPECTED_WORKLOADS):
        raise ValueError("budget limits do not cover every required workload")
    return validated


def _validate_preflight_shape(preflight: dict[str, Any]) -> None:
    _require_exact_keys(preflight, PREFLIGHT_KEYS, "preflight")
    if preflight["schemaVersion"] != 1:
        raise ValueError("unsupported preflight schemaVersion")
    _require_string(preflight["runIdentifier"], "preflight.runIdentifier")
    mode = preflight["mode"]
    if mode not in {"gating", "smoke"}:
        raise ValueError("preflight.mode must be gating or smoke")
    captured_at = _require_iso8601_utc(preflight["capturedAt"], "capturedAt")
    artifact_built_at = _require_iso8601_utc(
        preflight["artifactBuiltAt"], "artifactBuiltAt"
    )
    if artifact_built_at > captured_at:
        raise ValueError("artifactBuiltAt must not follow capturedAt")
    duration = _require_positive_int(
        preflight["requiredDurationSeconds"], "requiredDurationSeconds"
    )
    if mode == "gating" and duration != MINIMUM_GATING_DURATION_SECONDS:
        raise ValueError("gating requiredDurationSeconds must be exactly 900")
    if mode == "smoke" and duration < MINIMUM_SMOKE_DURATION_SECONDS:
        raise ValueError("smoke requiredDurationSeconds must be at least 5")
    if mode == "smoke" and duration >= MINIMUM_GATING_DURATION_SECONDS:
        raise ValueError("smoke requiredDurationSeconds must be less than 900")
    if preflight["coldStartupSampleCount"] != 5:
        raise ValueError("gating evidence requires exactly five cold samples")
    if preflight["warmStartupSampleCount"] != 5:
        raise ValueError("warm startup requires five samples")
    _require_positive_number(
        preflight["energySamplingIntervalSeconds"],
        "energySamplingIntervalSeconds",
    )
    source = _require_dict(preflight["sourceIdentity"], "sourceIdentity")
    _require_exact_keys(
        source, {"commit", "diffSHA256", "dirtyPathCount"}, "sourceIdentity"
    )
    commit = _require_string(source["commit"], "sourceIdentity.commit")
    if re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", commit) is None:
        raise ValueError("sourceIdentity.commit must be a full Git hash")
    _require_sha256(source["diffSHA256"], "sourceIdentity.diffSHA256")
    _require_nonnegative_int(source["dirtyPathCount"], "sourceIdentity.dirtyPathCount")
    toolchain = _require_dict(preflight["toolchain"], "toolchain")
    _require_exact_keys(
        toolchain,
        {"xcodeVersion", "swiftVersion", "xcodegenVersion"},
        "toolchain",
    )
    for key, value in toolchain.items():
        _require_string(value, f"toolchain.{key}")
    operating_system = _require_dict(preflight["operatingSystem"], "operatingSystem")
    _require_exact_keys(operating_system, {"version", "build"}, "operatingSystem")
    for key, value in operating_system.items():
        _require_string(value, f"operatingSystem.{key}")
    _require_positive_int(
        preflight["targetFramesPerSecond"], "targetFramesPerSecond"
    )
    if mode == "gating" and preflight["powerSource"] != "AC Power":
        raise ValueError("gating evidence requires AC Power")
    _require_string(preflight["powerSource"], "powerSource")
    _require_sha256(preflight["artifactManifestSHA256"], "artifactManifestSHA256")
    _require_sha256(preflight["budgetsSHA256"], "budgetsSHA256")


def _validate_workload_specs(preflight: dict[str, Any]) -> dict[str, dict[str, Any]]:
    raw_specs = _require_list(preflight["workloads"], "preflight.workloads")
    specs: dict[str, dict[str, Any]] = {}
    for index, raw_spec in enumerate(raw_specs):
        spec = _require_dict(raw_spec, f"preflight.workloads[{index}]")
        _require_exact_keys(spec, WORKLOAD_SPEC_KEYS, f"preflight.workloads[{index}]")
        workload = _require_string(spec["workload"], "workload spec label")
        if workload in specs:
            raise ValueError(f"duplicate workload spec: {workload}")
        specs[workload] = spec
    if set(specs) != set(EXPECTED_WORKLOADS):
        raise ValueError("preflight workload set is incomplete or mixed")

    cold = specs["rendererStartupCold"]
    cold_paths = [
        _relative_leaf(value, "cold result path")
        for value in _require_list(cold["resultPaths"], "cold resultPaths")
    ]
    expected_cold_paths = [
        f"rendererStartupCold-{index}.json" for index in range(1, 6)
    ]
    if cold_paths != expected_cold_paths:
        raise ValueError("gating evidence requires exactly five cold result paths")
    if cold["iterationsPerResult"] != 1:
        raise ValueError("cold startup results must be singleton samples")
    if cold["durationSeconds"] is not None or cold["energyPath"] is not None:
        raise ValueError("cold startup duration and energy path must be null")

    warm = specs["rendererStartupWarm"]
    if warm["resultPaths"] != ["rendererStartupWarm.json"]:
        raise ValueError("warm startup requires one canonical result")
    if warm["iterationsPerResult"] != 5:
        raise ValueError("warm startup result requires five samples")
    if warm["durationSeconds"] is not None or warm["energyPath"] is not None:
        raise ValueError("warm startup duration and energy path must be null")

    required_duration = float(preflight["requiredDurationSeconds"])
    for workload in DURATION_WORKLOADS:
        spec = specs[workload]
        if spec["resultPaths"] != [f"{workload}.json"]:
            raise ValueError(f"{workload} result filename is not canonical")
        if spec["iterationsPerResult"] is not None:
            raise ValueError(f"{workload} iterationsPerResult must be null")
        duration = _require_positive_int(
            spec["durationSeconds"], f"{workload} durationSeconds"
        )
        if not math.isclose(duration, required_duration, rel_tol=0, abs_tol=1e-9):
            raise ValueError(f"{workload} duration does not match preflight")
        if spec["energyPath"] != f"{workload}.top.csv":
            raise ValueError(f"{workload} Energy path is not canonical")
    return specs


def _expected_evidence_paths(
    preflight: dict[str, Any], specs: dict[str, dict[str, Any]]
) -> tuple[set[str], set[str], set[str]]:
    workload_paths: set[str] = set()
    energy_paths: set[str] = set()
    for spec in specs.values():
        for raw_path in spec["resultPaths"]:
            workload_paths.add(_relative_leaf(raw_path, "workload result path"))
        if spec["energyPath"] is not None:
            energy_paths.add(_relative_leaf(spec["energyPath"], "Energy path"))
    raw_environment_paths = _require_list(
        preflight["environmentInputPaths"], "environmentInputPaths"
    )
    validated_environment_paths = [
        _relative_leaf(value, "environment input path")
        for value in raw_environment_paths
    ]
    if validated_environment_paths != sorted(EXPECTED_ENVIRONMENT_INPUT_PATHS):
        raise ValueError(
            "environmentInputPaths must be the complete sorted canonical set"
        )
    environment_paths = set(validated_environment_paths)
    expected = {
        "preflight-manifest.json",
        "artifact-manifest.txt",
        "budgets.json",
        "metadata.json",
        *HELPER_IDENTITY_PATHS,
        *workload_paths,
        *energy_paths,
        *environment_paths,
    }
    return expected, workload_paths, energy_paths


def _verify_evidence_manifest(
    input_directory: Path,
    preflight: dict[str, Any],
    manifest: dict[str, Any],
    specs: dict[str, dict[str, Any]],
) -> None:
    _require_exact_keys(manifest, EVIDENCE_MANIFEST_KEYS, "evidence manifest")
    if manifest["schemaVersion"] != 1:
        raise ValueError("unsupported evidence manifest schemaVersion")
    if manifest["runIdentifier"] != preflight["runIdentifier"]:
        raise ValueError("evidence manifest runIdentifier mismatch")
    expected_paths, workload_paths, energy_paths = _expected_evidence_paths(
        preflight, specs
    )
    entries = _require_list(manifest["entries"], "evidence manifest entries")
    paths: list[str] = []
    for index, raw_entry in enumerate(entries):
        entry = _require_dict(raw_entry, f"evidence entry {index}")
        _require_exact_keys(entry, EVIDENCE_ENTRY_KEYS, f"evidence entry {index}")
        path = _relative_leaf(entry["path"], f"evidence entry {index} path")
        paths.append(path)
        digest = _require_sha256(entry["sha256"], f"evidence entry {path} sha256")
        byte_count = _require_nonnegative_int(
            entry["byteCount"], f"evidence entry {path} byteCount"
        )
        kind = entry["kind"]
        if kind not in EVIDENCE_KINDS:
            raise ValueError(f"evidence entry {path} has invalid kind")
        expected_kind: str | None
        if path == "preflight-manifest.json":
            expected_kind = "preflight"
        elif path == "artifact-manifest.txt":
            expected_kind = "artifact"
        elif path == "budgets.json":
            expected_kind = "budgets"
        elif path == "metadata.json":
            expected_kind = "metadata"
        elif path in workload_paths:
            expected_kind = "workload"
        elif path in energy_paths:
            expected_kind = "energy"
        elif path in HELPER_IDENTITY_PATHS:
            expected_kind = "helperIdentity"
        else:
            expected_kind = None
        if expected_kind is not None and kind != expected_kind:
            raise ValueError(f"evidence entry {path} kind mismatch")
        if expected_kind is None and kind != "environment":
            raise ValueError(f"evidence entry {path} environment kind mismatch")
        candidate = input_directory / path
        if candidate.is_symlink() or not candidate.is_file():
            raise ValueError(f"canonical evidence is missing or unsafe: {path}")
        if candidate.stat().st_size != byte_count:
            raise ValueError(f"evidence byteCount mismatch: {path}")
        if sha256(candidate) != digest:
            raise ValueError(f"evidence SHA-256 mismatch: {path}")
    if paths != sorted(paths) or len(paths) != len(set(paths)):
        raise ValueError("evidence manifest entries must be unique and sorted")
    if set(paths) != expected_paths:
        raise ValueError("evidence manifest path set is incomplete or mixed")


def _helper_identity_projection(raw: Any, context: str) -> tuple[dict[str, Any], datetime]:
    identity = _require_dict(raw, context)
    _require_exact_keys(
        identity,
        {
            "schemaVersion",
            "capturedAt",
            "launchdJob",
            "launchdSnapshot",
            "pid",
            "startIdentity",
            "executablePath",
            "executableSHA256",
            "codesign",
            "bundle",
        },
        context,
    )
    if identity["schemaVersion"] != 1:
        raise ValueError(f"{context}.schemaVersion must be 1")
    captured_at = _require_iso8601_utc(identity["capturedAt"], f"{context}.capturedAt")
    launchd_job = _require_string(identity["launchdJob"], f"{context}.launchdJob")
    if re.fullmatch(
        r"gui/\d+/group\.com\.idlescreen\.shared\.camera-agent",
        launchd_job,
    ) is None:
        raise ValueError(f"{context}.launchdJob is not the camera helper job")
    _require_string(identity["launchdSnapshot"], f"{context}.launchdSnapshot")
    _require_positive_int(identity["pid"], f"{context}.pid")
    _require_string(identity["startIdentity"], f"{context}.startIdentity")
    executable_path = _require_string(
        identity["executablePath"], f"{context}.executablePath"
    )
    if not Path(executable_path).is_absolute() or not executable_path.endswith(
        "/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
    ):
        raise ValueError(f"{context}.executablePath is not the camera helper")
    _require_sha256(identity["executableSHA256"], f"{context}.executableSHA256")

    codesign = _require_dict(identity["codesign"], f"{context}.codesign")
    _require_exact_keys(
        codesign,
        {
            "cdHash",
            "identifier",
            "teamIdentifier",
            "staticDetails",
            "dynamicDetails",
        },
        f"{context}.codesign",
    )
    cd_hash = _require_string(codesign["cdHash"], f"{context}.codesign.cdHash")
    if re.fullmatch(r"[0-9a-f]{40,64}", cd_hash) is None:
        raise ValueError(f"{context}.codesign.cdHash is invalid")
    for key in ("identifier", "teamIdentifier", "staticDetails", "dynamicDetails"):
        _require_string(codesign[key], f"{context}.codesign.{key}")

    bundle = _require_dict(identity["bundle"], f"{context}.bundle")
    _require_exact_keys(
        bundle,
        {"identifier", "version", "shortVersion"},
        f"{context}.bundle",
    )
    for key in bundle:
        _require_string(bundle[key], f"{context}.bundle.{key}")
    if codesign["identifier"] != bundle["identifier"]:
        raise ValueError(f"{context} signed and bundled identifiers differ")

    stable_keys = (
        "launchdJob",
        "pid",
        "startIdentity",
        "executablePath",
        "executableSHA256",
        "codesign",
        "bundle",
    )
    return ({key: identity[key] for key in stable_keys}, captured_at)


def _validate_helper_identity_pair(input_directory: Path) -> None:
    start = read_json(input_directory / "helper-start-identity.json")
    end = read_json(input_directory / "helper-end-identity.json")
    start_projection, start_captured_at = _helper_identity_projection(
        start, "helper start identity"
    )
    end_projection, end_captured_at = _helper_identity_projection(
        end, "helper end identity"
    )
    if end_captured_at < start_captured_at:
        raise ValueError("helper identity capture timestamps are reversed")
    if end_projection != start_projection:
        raise ValueError("helper identity changed inside the sampled window")


def _load_and_validate_evidence(
    input_directory: Path,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any], dict[str, dict[str, Any]]]:
    preflight = read_json(input_directory / "preflight-manifest.json")
    _validate_preflight_shape(preflight)
    specs = _validate_workload_specs(preflight)
    manifest = read_json(input_directory / "evidence-manifest.json")
    _verify_evidence_manifest(input_directory, preflight, manifest, specs)
    _validate_helper_identity_pair(input_directory)
    budgets = read_json(input_directory / "budgets.json")
    metadata = read_json(input_directory / "metadata.json")
    if sha256(input_directory / "artifact-manifest.txt") != preflight["artifactManifestSHA256"]:
        raise ValueError("artifact manifest SHA-256 does not match preflight")
    if sha256(input_directory / "budgets.json") != preflight["budgetsSHA256"]:
        raise ValueError("budgets SHA-256 does not match preflight")
    if metadata.get("runIdentifier") != preflight["runIdentifier"]:
        raise ValueError("metadata runIdentifier mismatch")
    if metadata.get("capturedAt") != preflight["capturedAt"]:
        raise ValueError("metadata capturedAt mismatch")
    if metadata.get("artifactSHA256") != preflight["artifactManifestSHA256"]:
        raise ValueError("metadata artifact SHA-256 mismatch")
    _validate_limits(budgets)
    _validate_budget_and_environment(preflight, budgets, metadata)
    return preflight, manifest, budgets, metadata, specs


def workload_result(
    input_directory: Path,
    workload: str,
    specs: dict[str, dict[str, Any]] | None = None,
    preflight: dict[str, Any] | None = None,
    budgets: dict[str, Any] | None = None,
) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
    if specs is None or preflight is None or budgets is None:
        preflight, _, budgets, _, specs = _load_and_validate_evidence(input_directory)
    spec = specs[workload]
    results: list[dict[str, Any]] = []
    for path in spec["resultPaths"]:
        result = read_json(input_directory / path)
        _validate_workload_result(
            result,
            workload,
            path,
            preflight,
            budgets,
            spec["iterationsPerResult"],
        )
        if workload in DURATION_WORKLOADS:
            required = float(preflight["requiredDurationSeconds"])
            actual = float(result["durationSeconds"])
            if preflight["mode"] == "gating" and actual < MINIMUM_GATING_DURATION_SECONDS:
                raise ValueError(f"{workload} duration must be at least 900 seconds")
            if actual + 1e-9 < required:
                raise ValueError(f"{workload} duration is shorter than preflight")
        results.append(result)
    if workload == "rendererStartupCold":
        values = [float(result["operationMilliseconds"]["p95"]) for result in results]
        return {
            "workload": workload,
            "operationMilliseconds": {"p95": nearest_rank(values, 0.95)},
        }, results
    return results[0], results


def value_for_metric(
    input_directory: Path,
    workload: str,
    metric: str,
    result: dict[str, Any] | None,
) -> float | None:
    if metric == "averageEnergyImpact":
        samples = energy_samples(input_directory / f"{workload}.top.csv")
        return sum(samples) / len(samples) if samples else None
    if result is None:
        return None
    if metric == "deadlineMissRatio":
        scheduled = int(result.get("scheduledFrameCount", 0))
        misses = int(result.get("deadlineMissCount", 0))
        return misses / scheduled if scheduled else 0.0
    direct_paths: dict[str, tuple[str, ...]] = {
        "startupFirstFrameP95Milliseconds": ("operationMilliseconds", "p95"),
        "cpuFrameP95Milliseconds": ("cpuMilliseconds", "p95"),
        "gpuFrameP95Milliseconds": ("gpuMilliseconds", "p95"),
        "frameIntervalP95Milliseconds": ("frameIntervalMilliseconds", "p95"),
        "attemptDurationP95Milliseconds": (
            "cadenceDiagnostics",
            "attemptDurationMilliseconds",
            "p95",
        ),
        "droppedFrameRatio": ("droppedFrameRatio",),
        "averageCPUPercent": ("resources", "averageCPUPercent"),
        "peakResidentMemoryBytes": ("resources", "peakResidentMemoryBytes"),
        "residentMemoryGrowthBytesPerHour": (
            "resources",
            "residentMemoryGrowthBytesPerHour",
        ),
        "wakeupsPerSecond": ("resources", "wakeupsPerSecond"),
        "operationP95Milliseconds": ("operationMilliseconds", "p95"),
    }
    path = direct_paths.get(metric)
    if path is None:
        return None
    value: Any = result
    for component in path:
        if not isinstance(value, dict) or component not in value:
            return None
        value = value[component]
    if type(value) not in (int, float):
        return None
    return float(value)


def evaluate(
    limits: list[dict[str, Any]],
    measurements: list[dict[str, Any]],
) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    for limit in limits:
        measurement = next(
            (
                item
                for item in measurements
                if item["workload"] == limit["workload"]
                and item["metric"] == limit["metric"]
            ),
            None,
        )
        if measurement is None:
            status = "missing"
        elif measurement["unit"] != limit["unit"]:
            status = "unitMismatch"
        elif (
            not math.isfinite(float(measurement["value"]))
            or float(measurement["value"]) < 0
        ):
            status = "invalid"
        elif float(measurement["value"]) <= float(limit["maximum"]):
            status = "passed"
        else:
            status = "overBudget"
        results.append(
            {"limit": limit, "measurement": measurement, "status": status}
        )
    return {
        "passed": all(result["status"] == "passed" for result in results),
        "results": results,
    }


def build_report(input_directory: Path) -> dict[str, Any]:
    preflight, manifest, budgets, metadata, specs = _load_and_validate_evidence(
        input_directory
    )
    measurements: list[dict[str, Any]] = []
    raw_results: dict[str, list[dict[str, Any]]] = {}
    top_samples: dict[str, list[float]] = {}
    loaded: dict[str, dict[str, Any] | None] = {}

    for workload in EXPECTED_WORKLOADS:
        loaded[workload], raw_results[workload] = workload_result(
            input_directory,
            workload,
            specs=specs,
            preflight=preflight,
            budgets=budgets,
        )
        energy_path = specs[workload]["energyPath"]
        top_samples[workload] = (
            energy_samples(input_directory / energy_path)
            if energy_path is not None
            else []
        )
        if energy_path is not None:
            declared_duration = specs[workload]["durationSeconds"]
            if declared_duration is None:
                raise ValueError(f"Energy workload {workload} has no declared duration")
            duration = float(declared_duration)
            interval = float(preflight["energySamplingIntervalSeconds"])
            minimum_samples = math.ceil(
                duration / interval * MINIMUM_ENERGY_COVERAGE_RATIO
            )
            if len(top_samples[workload]) < minimum_samples:
                raise ValueError(
                    f"Energy sample coverage for {workload} is insufficient: "
                    f"{len(top_samples[workload])} < {minimum_samples}"
                )

    for limit in budgets["limits"]:
        workload = str(limit["workload"])
        value = value_for_metric(
            input_directory,
            workload,
            str(limit["metric"]),
            loaded[workload],
        )
        if value is not None:
            measurements.append(
                {
                    "workload": workload,
                    "metric": limit["metric"],
                    "value": value,
                    "unit": limit["unit"],
                }
            )
    evaluation = evaluate(budgets["limits"], measurements)
    gating_eligible = preflight["mode"] == "gating"
    report = {
        "schemaVersion": metadata["schemaVersion"],
        "runIdentifier": metadata["runIdentifier"],
        "capturedAt": metadata["capturedAt"],
        "commit": metadata["commit"],
        "artifactSHA256": metadata["artifactSHA256"],
        "hardware": metadata["hardware"],
        "operatingSystem": metadata["operatingSystem"],
        "display": metadata["display"],
        "budgetsIdentifier": budgets["identifier"],
        "evidenceMode": preflight["mode"],
        "gatingEligible": gating_eligible,
        "gatingPassed": gating_eligible and evaluation["passed"],
        "preflightManifestSHA256": sha256(
            input_directory / "preflight-manifest.json"
        ),
        "evidenceManifestSHA256": sha256(
            input_directory / "evidence-manifest.json"
        ),
        "canonicalEvidenceEntryCount": len(manifest["entries"]),
        "measurements": measurements,
        "budgetEvaluation": evaluation,
        "notes": metadata.get("notes", []),
        "workloadResults": raw_results,
        "energyImpactSamples": top_samples,
    }
    return report


def display_value(value: Any) -> str:
    if value is None:
        return "—"
    number = float(value)
    if abs(number) >= 1_000_000:
        return f"{number:,.0f}"
    return f"{number:.3f}".rstrip("0").rstrip(".")


def markdown_report(report: dict[str, Any]) -> str:
    evaluation = report["budgetEvaluation"]
    if not report["gatingEligible"]:
        verdict = "NON-GATING SMOKE"
    else:
        verdict = "PASS" if evaluation["passed"] else "FAIL"
    lines = [
        "# R1.1 performance and energy evidence",
        "",
        f"**Verdict: {verdict}**",
        "",
        f"Run: `{report['runIdentifier']}`  ",
        f"Commit: `{report['commit']}`  ",
        f"Artifact SHA-256: `{report['artifactSHA256']}`  ",
        f"Budgets: `{report['budgetsIdentifier']}`  ",
        f"Evidence mode: `{report['evidenceMode']}`",
        "",
        "| Workload | Metric | Observed | Budget | Unit | Verdict |",
        "|---|---|---:|---:|---|---|",
    ]
    for result in evaluation["results"]:
        limit = result["limit"]
        measurement = result["measurement"]
        lines.append(
            "| "
            + " | ".join(
                [
                    limit["workload"],
                    limit["metric"],
                    display_value(measurement["value"] if measurement else None),
                    display_value(limit["maximum"]),
                    limit["unit"],
                    "PASS" if result["status"] == "passed" else result["status"],
                ]
            )
            + " |"
        )
    lines.extend(["", "## Scope notes", ""])
    lines.extend(f"- {note}" for note in report.get("notes", []))
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--markdown", required=True, type=Path)
    arguments = parser.parse_args()
    report = build_report(arguments.input)
    arguments.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    arguments.markdown.write_text(markdown_report(report), encoding="utf-8")
    if not report["gatingEligible"]:
        return 0
    return 0 if report["budgetEvaluation"]["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
