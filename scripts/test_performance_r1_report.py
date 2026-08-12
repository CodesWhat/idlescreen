#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import math
import tempfile
import unittest
from pathlib import Path

import performance_r1_report


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
BASE_ENVIRONMENT_INPUT_PATHS = (
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
)


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, sort_keys=True), encoding="utf-8")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def distribution(count: int, value: float = 1.0) -> dict[str, object]:
    return {
        "count": count,
        "minimum": value,
        "median": value,
        "p95": value,
        "p99": value,
        "maximum": value,
        "mean": value,
    }


def resources(duration: float) -> dict[str, object]:
    return {
        "durationSeconds": duration,
        "averageCPUPercent": 1.0,
        "peakResidentMemoryBytes": 100 * 1024**2,
        "lifetimePeakResidentMemoryBytes": 120 * 1024**2,
        "residentMemoryGrowthBytesPerHour": 0.0,
        "wakeupsPerSecond": 1.0,
    }


def memory_context(
    duration: float, footprints: list[int] | None = None
) -> dict[str, object]:
    if footprints is None:
        footprints = [100 * 1024**2] * (16 if duration >= 900 else 2)
    spacing = duration / (len(footprints) - 1)
    samples = [
        {"capturedAt": index * spacing, "physicalFootprintBytes": footprint}
        for index, footprint in enumerate(footprints)
    ]

    def growth(selected: list[dict[str, object]]) -> float:
        origin = float(selected[0]["capturedAt"])
        times = [float(sample["capturedAt"]) - origin for sample in selected]
        values = [float(sample["physicalFootprintBytes"]) for sample in selected]
        mean_time = sum(times) / len(times)
        mean_value = sum(values) / len(values)
        denominator = sum((value - mean_time) ** 2 for value in times)
        if denominator == 0:
            return 0.0
        numerator = sum(
            (time - mean_time) * (value - mean_value)
            for time, value in zip(times, values)
        )
        return max(0.0, numerator / denominator * 3600)

    def sustained_growth(selected: list[dict[str, object]]) -> float:
        if len(selected) < 6:
            return growth(selected)
        duration = float(selected[-1]["capturedAt"]) - float(
            selected[0]["capturedAt"]
        )
        window_duration = duration / 5
        slopes: list[float] = []
        end_index = 1
        for start_index, start in enumerate(selected):
            end_index = max(end_index, start_index + 1)
            window_end = float(start["capturedAt"]) + window_duration
            while (
                end_index < len(selected)
                and float(selected[end_index]["capturedAt"]) < window_end
            ):
                end_index += 1
            if end_index >= len(selected):
                break
            slopes.append(growth(selected[start_index : end_index + 1]))
        if not slopes:
            return growth(selected)
        slopes.sort()
        midpoint = len(slopes) // 2
        if len(slopes) % 2 == 0:
            return (slopes[midpoint - 1] + slopes[midpoint]) / 2
        return slopes[midpoint]

    midpoint = float(samples[0]["capturedAt"]) + duration / 2
    first_tail = next(
        index
        for index, sample in enumerate(samples)
        if float(sample["capturedAt"]) >= midpoint
    )
    tail_start = max(0, first_tail - 1)
    trend = {
        "sampleCount": len(samples),
        "peakPhysicalFootprintBytes": max(footprints),
        "growthBytesPerHour": sustained_growth(samples[tail_start:]),
        "wholeWindowGrowthBytesPerHour": growth(samples),
        "steadyStateWindowStartedAt": samples[tail_start]["capturedAt"],
    }
    return {"memorySamples": samples, "memoryTrend": trend}


def render_surface() -> dict[str, object]:
    return {
        "logicalWidth": 2056,
        "logicalHeight": 1329,
        "drawableWidth": 4112,
        "drawableHeight": 2658,
        "deviceName": "Apple M4 Pro",
        "deviceRegistryID": 1234,
        "colorPixelFormat": "bgra8Unorm",
    }


def cadence_diagnostics(frame_count: int) -> dict[str, object]:
    return {
        "attemptStartIntervalMilliseconds": distribution(frame_count - 1, 33.0),
        "wakeLatenessMilliseconds": distribution(frame_count, 1.0),
        "attemptDurationMilliseconds": distribution(frame_count, 2.0),
        "submissionOffsetMilliseconds": distribution(frame_count, 1.0),
        "slowIntervalThresholdMilliseconds": 40.0,
        "slowSubmissionIntervalCount": 0,
        "slowAttemptStartIntervalCount": 0,
        "slowSubmissionWithSlowAttemptStartCount": 0,
    }


def helper_identity(captured_at: str, snapshot: str) -> dict[str, object]:
    executable = (
        "/Applications/idlescreen.app/Contents/Helpers/"
        "IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
    )
    return {
        "schemaVersion": 1,
        "capturedAt": captured_at,
        "launchdJob": "gui/501/group.com.idlescreen.shared.camera-agent",
        "launchdSnapshot": snapshot,
        "pid": 42,
        "startIdentity": f"Sun Aug 9 17:00:00 2026 {executable}",
        "executablePath": executable,
        "executableSHA256": "e" * 64,
        "codesign": {
            "cdHash": "f" * 40,
            "identifier": "com.idlescreen.camera-agent",
            "teamIdentifier": "3524374A2S",
            "staticDetails": "Identifier=com.idlescreen.camera-agent",
            "dynamicDetails": "Identifier=com.idlescreen.camera-agent",
        },
        "bundle": {
            "identifier": "com.idlescreen.camera-agent",
            "version": "28",
            "shortVersion": "0.1",
        },
    }


def startup_result(workload: str, iterations: int) -> dict[str, object]:
    duration = 0.1
    return {
        "workload": workload,
        "durationSeconds": duration,
        "scheduledFrameCount": iterations,
        "attemptedFrameCount": iterations,
        "submittedFrameCount": iterations,
        "completedFrameCount": iterations,
        "droppedFrameCount": 0,
        "droppedFrameRatio": 0.0,
        "deadlineMissCount": 0,
        "operationMilliseconds": distribution(iterations, 10.0),
        "dropReasons": [],
        "resources": resources(duration),
        "renderSurface": render_surface(),
        **memory_context(duration),
    }


def duration_result(workload: str, duration: float = 900.0) -> dict[str, object]:
    base: dict[str, object] = {
        "workload": workload,
        "durationSeconds": duration,
        "scheduledFrameCount": 0,
        "attemptedFrameCount": 0,
        "submittedFrameCount": 0,
        "completedFrameCount": 0,
        "droppedFrameCount": 0,
        "droppedFrameRatio": 0.0,
        "deadlineMissCount": 0,
        "dropReasons": [],
        "resources": resources(duration),
        **memory_context(duration),
    }
    if workload in RENDER_WORKLOADS:
        frame_count = 27_000
        base.update(
            {
                "scheduledFrameCount": frame_count,
                "attemptedFrameCount": frame_count,
                "submittedFrameCount": frame_count,
                "completedFrameCount": frame_count,
                "deadlineMissCount": 2,
                "cpuMilliseconds": distribution(frame_count, 2.0),
                "gpuMilliseconds": distribution(frame_count, 1.0),
                "frameIntervalMilliseconds": distribution(
                    frame_count - 1, 33.0
                ),
                "cadenceDiagnostics": cadence_diagnostics(frame_count),
                "renderSurface": render_surface(),
            }
        )
    elif workload in {"mailboxTransport", "agentSignalPolling"}:
        base["operationMilliseconds"] = distribution(900, 0.5)
    return base


class PerformanceR1ReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.addCleanup(self.temporary_directory.cleanup)
        self.run_identifier = "r1.1-fixture"

        self.budgets = {
            "identifier": (
                "m4-pro-4112x2658-single-display-r1.1-v2-render-capacity"
            ),
            "hardwareClass": "Apple M4 Pro 20-core GPU",
            "displayCount": 1,
            "displayPixelWidth": 4112,
            "displayPixelHeight": 2658,
            "displayScale": 2.0,
            "metalDeviceName": "Apple M4 Pro",
            "colorPixelFormat": "bgra8Unorm",
            "targetFramesPerSecond": 30,
            "limits": [
                {
                    "workload": "rendererStartupCold",
                    "metric": "startupFirstFrameP95Milliseconds",
                    "maximum": 500,
                    "unit": "milliseconds",
                },
                {
                    "workload": "rendererStartupWarm",
                    "metric": "startupFirstFrameP95Milliseconds",
                    "maximum": 200,
                    "unit": "milliseconds",
                },
                *[
                    {
                        "workload": workload,
                        "metric": "cpuFrameP95Milliseconds",
                        "maximum": 20,
                        "unit": "milliseconds",
                    }
                    for workload in RENDER_WORKLOADS
                ],
                *[
                    {
                        "workload": workload,
                        "metric": "attemptDurationP95Milliseconds",
                        "maximum": 20,
                        "unit": "milliseconds",
                    }
                    for workload in RENDER_WORKLOADS
                ],
                {
                    "workload": "generative",
                    "metric": "averageEnergyImpact",
                    "maximum": 25,
                    "unit": "energyImpact",
                },
                {
                    "workload": "generative",
                    "metric": "residentMemoryGrowthBytesPerHour",
                    "maximum": 16 * 1024**2,
                    "unit": "bytesPerHour",
                },
                {
                    "workload": "generative",
                    "metric": "deadlineMissRatio",
                    "maximum": 0.01,
                    "unit": "ratio",
                },
                {
                    "workload": "mailboxTransport",
                    "metric": "operationP95Milliseconds",
                    "maximum": 5,
                    "unit": "milliseconds",
                },
                {
                    "workload": "agentSignalPolling",
                    "metric": "operationP95Milliseconds",
                    "maximum": 2,
                    "unit": "milliseconds",
                },
                {
                    "workload": "zeroConsumer",
                    "metric": "averageCPUPercent",
                    "maximum": 2,
                    "unit": "percent",
                },
                {
                    "workload": "helperIdle",
                    "metric": "averageCPUPercent",
                    "maximum": 2,
                    "unit": "percent",
                },
            ],
        }
        write_json(self.root / "budgets.json", self.budgets)
        (self.root / "artifact-manifest.txt").write_text(
            f"{'a' * 64}  idlescreen-perf\n", encoding="utf-8"
        )
        self.metadata = {
            "schemaVersion": 1,
            "runIdentifier": self.run_identifier,
            "capturedAt": "2026-08-09T18:00:00Z",
            "commit": "0123456789abcdef0123456789abcdef01234567",
            "artifactSHA256": sha256(self.root / "artifact-manifest.txt"),
            "hardware": {
                "modelIdentifier": "Mac16,7",
                "hardwareClass": self.budgets["hardwareClass"],
                "chip": "Apple M4 Pro",
                "cpuCoreCount": 14,
                "gpuCoreCount": 20,
                "memoryBytes": 48 * 1024**3,
            },
            "operatingSystem": {"version": "26.5.2", "build": "25F84"},
            "display": {
                "count": 1,
                "pixelWidth": 4112,
                "pixelHeight": 2658,
                "scale": 2.0,
                "logicalWidth": 2056,
                "logicalHeight": 1329,
                "refreshRateHertz": 60.0,
            },
            "notes": ["fixture"],
        }
        write_json(self.root / "metadata.json", self.metadata)

        for index in range(1, 6):
            write_json(
                self.root / f"rendererStartupCold-{index}.json",
                startup_result("rendererStartupCold", 1),
            )
        write_json(
            self.root / "rendererStartupWarm.json",
            startup_result("rendererStartupWarm", 5),
        )
        for workload in DURATION_WORKLOADS:
            write_json(self.root / f"{workload}.json", duration_result(workload))
            self.write_energy_samples(workload, usable_count=720)
            (self.root / f"{workload}.footprint.csv").write_text(
                "2026-08-09T18:00:01Z 123 104857600\n",
                encoding="utf-8",
            )

        for name in BASE_ENVIRONMENT_INPUT_PATHS:
            (self.root / name).write_text(f"fixture {name}\n", encoding="utf-8")
        write_json(
            self.root / "helper-start-identity.json",
            helper_identity("2026-08-09T17:59:00Z", "pid = 42; state = running"),
        )
        write_json(
            self.root / "helper-end-identity.json",
            helper_identity("2026-08-09T18:15:00Z", "pid = 42; state = idle"),
        )

        self.preflight = self.make_preflight()
        self.refresh_manifests()

    def write_energy_samples(self, workload: str, usable_count: int) -> None:
        rows = ["123 0.0 0.0 100M"]
        rows.extend(f"123 1.0 10.0 {100 + index % 3}M" for index in range(usable_count))
        (self.root / f"{workload}.top.csv").write_text(
            "\n".join(rows) + "\n", encoding="utf-8"
        )

    def make_preflight(self) -> dict[str, object]:
        workloads: list[dict[str, object]] = [
            {
                "workload": "rendererStartupCold",
                "resultPaths": [
                    f"rendererStartupCold-{index}.json" for index in range(1, 6)
                ],
                "iterationsPerResult": 1,
                "durationSeconds": None,
                "energyPath": None,
            },
            {
                "workload": "rendererStartupWarm",
                "resultPaths": ["rendererStartupWarm.json"],
                "iterationsPerResult": 5,
                "durationSeconds": None,
                "energyPath": None,
            },
        ]
        workloads.extend(
            {
                "workload": workload,
                "resultPaths": [f"{workload}.json"],
                "iterationsPerResult": None,
                "durationSeconds": 900,
                "energyPath": f"{workload}.top.csv",
            }
            for workload in DURATION_WORKLOADS
        )
        return {
            "schemaVersion": 1,
            "runIdentifier": self.run_identifier,
            "mode": "gating",
            "capturedAt": "2026-08-09T18:00:00Z",
            "artifactBuiltAt": "2026-08-09T17:30:00Z",
            "requiredDurationSeconds": 900,
            "coldStartupSampleCount": 5,
            "warmStartupSampleCount": 5,
            "energySamplingIntervalSeconds": 1,
            "sourceIdentity": {
                "commit": self.metadata["commit"],
                "diffSHA256": "b" * 64,
                "dirtyPathCount": 2,
            },
            "toolchain": {
                "xcodeVersion": "26.6",
                "swiftVersion": "6.2",
                "xcodegenVersion": "2.46.0",
            },
            "operatingSystem": self.metadata["operatingSystem"],
            "hardware": {
                **self.metadata["hardware"],
            },
            "display": {
                **self.metadata["display"],
            },
            "targetFramesPerSecond": 30,
            "targetSurface": {
                "logicalWidth": 2056,
                "logicalHeight": 1329,
                "pixelWidth": 4112,
                "pixelHeight": 2658,
            },
            "powerSource": "AC Power",
            "artifactManifestSHA256": sha256(
                self.root / "artifact-manifest.txt"
            ),
            "budgetsSHA256": sha256(self.root / "budgets.json"),
            "workloads": workloads,
            "environmentInputPaths": sorted(
                [
                    *BASE_ENVIRONMENT_INPUT_PATHS,
                    *[
                        f"{workload}.footprint.csv"
                        for workload in DURATION_WORKLOADS
                    ],
                ]
            ),
        }

    def refresh_manifests(self) -> None:
        self.preflight["artifactManifestSHA256"] = sha256(
            self.root / "artifact-manifest.txt"
        )
        self.preflight["budgetsSHA256"] = sha256(self.root / "budgets.json")
        write_json(self.root / "preflight-manifest.json", self.preflight)
        workload_paths = {
            path
            for workload in self.preflight["workloads"]
            for path in [*workload["resultPaths"], workload["energyPath"]]
            if path is not None
        }
        helper_paths = {
            "helper-start-identity.json",
            "helper-end-identity.json",
        }
        required_paths = {
            "preflight-manifest.json",
            "artifact-manifest.txt",
            "budgets.json",
            "metadata.json",
            *helper_paths,
            *workload_paths,
            *self.preflight["environmentInputPaths"],
        }
        entries = []
        for path in sorted(required_paths):
            if path in helper_paths:
                kind = "helperIdentity"
            elif path == "preflight-manifest.json":
                kind = "preflight"
            elif path == "artifact-manifest.txt":
                kind = "artifact"
            elif path == "budgets.json":
                kind = "budgets"
            elif path == "metadata.json":
                kind = "metadata"
            elif path.endswith(".top.csv"):
                kind = "energy"
            elif path in workload_paths:
                kind = "workload"
            else:
                kind = "environment"
            file_path = self.root / path
            entries.append(
                {
                    "path": path,
                    "sha256": sha256(file_path),
                    "byteCount": file_path.stat().st_size,
                    "kind": kind,
                }
            )
        write_json(
            self.root / "evidence-manifest.json",
            {
                "schemaVersion": 1,
                "runIdentifier": self.run_identifier,
                "entries": entries,
            },
        )

    def rewrite_result(self, workload: str, update: object) -> None:
        path = self.root / f"{workload}.json"
        result = json.loads(path.read_text(encoding="utf-8"))
        update(result)
        write_json(path, result)
        self.refresh_manifests()

    def test_complete_gating_evidence_passes_and_skips_energy_warmup(self) -> None:
        report = performance_r1_report.build_report(self.root)

        self.assertTrue(report["gatingEligible"])
        self.assertTrue(report["budgetEvaluation"]["passed"])
        energy = next(
            measurement
            for measurement in report["measurements"]
            if measurement["metric"] == "averageEnergyImpact"
        )
        self.assertEqual(energy["value"], 10)

    def test_workload_label_must_match_result_filename(self) -> None:
        self.rewrite_result(
            "generative", lambda result: result.update(workload="cameraSynthetic")
        )

        with self.assertRaisesRegex(ValueError, "workload.*generative"):
            performance_r1_report.build_report(self.root)

    def test_gating_requires_exactly_five_cold_singletons(self) -> None:
        self.preflight["workloads"][0]["resultPaths"].pop()
        self.refresh_manifests()

        with self.assertRaisesRegex(ValueError, "five cold"):
            performance_r1_report.build_report(self.root)

    def test_each_cold_result_must_be_a_singleton(self) -> None:
        path = self.root / "rendererStartupCold-1.json"
        result = startup_result("rendererStartupCold", 2)
        write_json(path, result)
        self.refresh_manifests()

        with self.assertRaisesRegex(ValueError, "cold.*singleton"):
            performance_r1_report.build_report(self.root)

    def test_warm_result_requires_five_samples(self) -> None:
        write_json(
            self.root / "rendererStartupWarm.json",
            startup_result("rendererStartupWarm", 4),
        )
        self.refresh_manifests()

        with self.assertRaisesRegex(ValueError, "warm.*five"):
            performance_r1_report.build_report(self.root)

    def test_gating_duration_workloads_require_at_least_fifteen_minutes(self) -> None:
        def update(result: dict[str, object]) -> None:
            context = memory_context(899.99)
            result.update(context)
            result["durationSeconds"] = 899.99
            result["resources"]["durationSeconds"] = 899.99
            result["resources"]["peakResidentMemoryBytes"] = context[
                "memoryTrend"
            ]["peakPhysicalFootprintBytes"]
            result["resources"]["lifetimePeakResidentMemoryBytes"] = context[
                "memoryTrend"
            ]["peakPhysicalFootprintBytes"]
            result["resources"]["residentMemoryGrowthBytesPerHour"] = context[
                "memoryTrend"
            ]["growthBytesPerHour"]

        self.rewrite_result("generative", update)

        with self.assertRaisesRegex(ValueError, "generative.*900"):
            performance_r1_report.build_report(self.root)

    def test_short_smoke_is_explicitly_non_gating(self) -> None:
        self.preflight["mode"] = "smoke"
        self.preflight["requiredDurationSeconds"] = 5
        for workload in self.preflight["workloads"]:
            if workload["durationSeconds"] is not None:
                workload["durationSeconds"] = 5
                path = self.root / workload["resultPaths"][0]
                result = json.loads(path.read_text(encoding="utf-8"))
                result["durationSeconds"] = 5.005
                result["resources"]["durationSeconds"] = 5.005
                context = memory_context(5.005)
                result.update(context)
                result["resources"]["peakResidentMemoryBytes"] = context[
                    "memoryTrend"
                ]["peakPhysicalFootprintBytes"]
                result["resources"]["residentMemoryGrowthBytesPerHour"] = context[
                    "memoryTrend"
                ]["growthBytesPerHour"]
                write_json(path, result)
                self.write_energy_samples(workload["workload"], usable_count=4)
        self.refresh_manifests()

        report = performance_r1_report.build_report(self.root)

        self.assertFalse(report["gatingEligible"])
        self.assertEqual(report["evidenceMode"], "smoke")
        self.assertIn("NON-GATING", performance_r1_report.markdown_report(report))

    def test_smoke_requires_five_seconds_for_energy_coverage(self) -> None:
        self.preflight["mode"] = "smoke"
        self.preflight["requiredDurationSeconds"] = 4
        self.refresh_manifests()

        with self.assertRaisesRegex(ValueError, "smoke.*at least 5"):
            performance_r1_report.build_report(self.root)

    def test_gating_preflight_requires_exactly_nine_hundred_seconds(self) -> None:
        self.preflight["requiredDurationSeconds"] = 901
        self.refresh_manifests()

        with self.assertRaisesRegex(ValueError, "gating.*exactly 900"):
            performance_r1_report.build_report(self.root)

    def test_frame_lifecycle_counts_must_be_coherent(self) -> None:
        self.rewrite_result(
            "generative", lambda result: result.update(completedFrameCount=26_999)
        )

        with self.assertRaisesRegex(ValueError, "completedFrameCount"):
            performance_r1_report.build_report(self.root)

    def test_schedule_and_deadline_metrics_are_required(self) -> None:
        self.rewrite_result(
            "generative", lambda result: result.pop("deadlineMissCount")
        )

        with self.assertRaisesRegex(ValueError, "deadlineMissCount"):
            performance_r1_report.build_report(self.root)

    def test_distribution_count_must_match_submitted_frames(self) -> None:
        self.rewrite_result(
            "generative",
            lambda result: result["cpuMilliseconds"].update(count=26_999),
        )

        with self.assertRaisesRegex(ValueError, "cpuMilliseconds.*count"):
            performance_r1_report.build_report(self.root)

    def test_distribution_order_must_be_coherent(self) -> None:
        self.rewrite_result(
            "generative",
            lambda result: result["cpuMilliseconds"].update(p95=0.5),
        )

        with self.assertRaisesRegex(ValueError, "cpuMilliseconds.*order"):
            performance_r1_report.build_report(self.root)

    def test_render_results_require_correlated_cadence_diagnostics(self) -> None:
        self.rewrite_result(
            "generative", lambda result: result.pop("cadenceDiagnostics")
        )

        with self.assertRaisesRegex(ValueError, "cadenceDiagnostics"):
            performance_r1_report.build_report(self.root)

    def test_attempt_duration_budget_uses_whole_host_attempt(self) -> None:
        def update(result: dict[str, object]) -> None:
            distribution = result["cadenceDiagnostics"][
                "attemptDurationMilliseconds"
            ]
            distribution.update(p95=21.0, p99=21.0, maximum=21.0)

        self.rewrite_result("generative", update)

        report = performance_r1_report.build_report(self.root)
        verdict = next(
            item
            for item in report["budgetEvaluation"]["results"]
            if item["limit"]["workload"] == "generative"
            and item["limit"]["metric"]
            == "attemptDurationP95Milliseconds"
        )
        self.assertEqual(verdict["status"], "overBudget")

    def test_adjacent_submission_interval_is_diagnostic_not_gating(self) -> None:
        def update(result: dict[str, object]) -> None:
            result["frameIntervalMilliseconds"].update(
                p95=41.0,
                p99=42.0,
                maximum=43.0,
            )
            result["cadenceDiagnostics"].update(
                slowSubmissionIntervalCount=1_500,
                slowAttemptStartIntervalCount=1_490,
                slowSubmissionWithSlowAttemptStartCount=1_480,
            )
            result["cadenceDiagnostics"][
                "attemptStartIntervalMilliseconds"
            ].update(p95=41.0, p99=42.0, maximum=43.0)

        self.rewrite_result("generative", update)

        report = performance_r1_report.build_report(self.root)

        self.assertTrue(report["budgetEvaluation"]["passed"])

    def test_cadence_diagnostic_threshold_is_derived_from_frame_rate(self) -> None:
        self.rewrite_result(
            "generative",
            lambda result: result["cadenceDiagnostics"].update(
                slowIntervalThresholdMilliseconds=41.0
            ),
        )

        with self.assertRaisesRegex(ValueError, "1.2 frame periods"):
            performance_r1_report.build_report(self.root)

    def test_energy_samples_require_eighty_percent_coverage(self) -> None:
        self.write_energy_samples("generative", usable_count=719)
        self.refresh_manifests()

        with self.assertRaisesRegex(ValueError, "Energy.*coverage"):
            performance_r1_report.build_report(self.root)

    def test_energy_samples_reject_mixed_processes(self) -> None:
        path = self.root / "generative.top.csv"
        path.write_text(path.read_text(encoding="utf-8") + "456 1 1 100M\n")
        self.refresh_manifests()

        with self.assertRaisesRegex(ValueError, "mixed process"):
            performance_r1_report.build_report(self.root)

    def test_raw_json_rejects_nonfinite_numbers(self) -> None:
        self.rewrite_result(
            "generative", lambda result: result.update(durationSeconds=math.nan)
        )

        with self.assertRaisesRegex(ValueError, "nonfinite"):
            performance_r1_report.build_report(self.root)

    def test_raw_json_rejects_negative_metrics(self) -> None:
        self.rewrite_result(
            "generative",
            lambda result: result["resources"].update(averageCPUPercent=-1),
        )

        with self.assertRaisesRegex(ValueError, "negative"):
            performance_r1_report.build_report(self.root)

    def test_resource_duration_must_match_workload_duration(self) -> None:
        self.rewrite_result(
            "generative",
            lambda result: result["resources"].update(durationSeconds=800),
        )

        with self.assertRaisesRegex(ValueError, "resources.*duration"):
            performance_r1_report.build_report(self.root)

    def test_lifetime_peak_must_cover_in_window_peak(self) -> None:
        self.rewrite_result(
            "generative",
            lambda result: result["resources"].update(
                lifetimePeakResidentMemoryBytes=99 * 1024**2
            ),
        )

        with self.assertRaisesRegex(ValueError, "lifetime peak"):
            performance_r1_report.build_report(self.root)

    def test_budget_hardware_must_match_observed_hardware(self) -> None:
        self.preflight["hardware"]["hardwareClass"] = "Unknown Mac"
        self.refresh_manifests()

        with self.assertRaisesRegex(ValueError, "hardwareClass"):
            performance_r1_report.build_report(self.root)

    def test_metadata_schema_rejects_mixed_environment_fields(self) -> None:
        metadata_path = self.root / "metadata.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["legacyHardwareLabel"] = "M4 Pro"
        write_json(metadata_path, metadata)
        self.refresh_manifests()

        with self.assertRaisesRegex(ValueError, "metadata schema"):
            performance_r1_report.build_report(self.root)

    def test_budget_identifier_must_name_actual_pixel_surface(self) -> None:
        self.preflight["targetSurface"]["pixelWidth"] = 3456
        self.refresh_manifests()

        with self.assertRaisesRegex(ValueError, "target surface"):
            performance_r1_report.build_report(self.root)

    def test_raw_render_surface_must_match_named_target(self) -> None:
        self.rewrite_result(
            "generative",
            lambda result: result["renderSurface"].update(drawableWidth=3456),
        )

        with self.assertRaisesRegex(ValueError, "renderSurface.*drawableWidth"):
            performance_r1_report.build_report(self.root)

    def test_early_memory_step_uses_steady_state_trend_not_top_memory(self) -> None:
        footprints = [100 * 1024**2, *([160 * 1024**2] * 15)]

        def update(result: dict[str, object]) -> None:
            context = memory_context(900, footprints)
            result.update(context)
            result["resources"]["residentMemoryGrowthBytesPerHour"] = context[
                "memoryTrend"
            ]["growthBytesPerHour"]
            result["resources"]["peakResidentMemoryBytes"] = context[
                "memoryTrend"
            ]["peakPhysicalFootprintBytes"]
            result["resources"]["lifetimePeakResidentMemoryBytes"] = context[
                "memoryTrend"
            ]["peakPhysicalFootprintBytes"]

        self.rewrite_result("generative", update)

        report = performance_r1_report.build_report(self.root)

        growth = next(
            measurement["value"]
            for measurement in report["measurements"]
            if measurement["workload"] == "generative"
            and measurement["metric"] == "residentMemoryGrowthBytesPerHour"
        )
        self.assertEqual(growth, 0)

    def test_late_memory_step_plateau_is_diagnostic_not_a_growth_failure(
        self,
    ) -> None:
        footprints = [100 * 1024**2] * 12 + [200 * 1024**2] * 4

        def update(result: dict[str, object]) -> None:
            context = memory_context(900, footprints)
            result.update(context)
            result["resources"]["residentMemoryGrowthBytesPerHour"] = context[
                "memoryTrend"
            ]["growthBytesPerHour"]
            result["resources"]["peakResidentMemoryBytes"] = context[
                "memoryTrend"
            ]["peakPhysicalFootprintBytes"]
            result["resources"]["lifetimePeakResidentMemoryBytes"] = context[
                "memoryTrend"
            ]["peakPhysicalFootprintBytes"]

        self.rewrite_result("generative", update)

        report = performance_r1_report.build_report(self.root)

        growth = next(
            measurement["value"]
            for measurement in report["measurements"]
            if measurement["workload"] == "generative"
            and measurement["metric"] == "residentMemoryGrowthBytesPerHour"
        )
        self.assertEqual(growth, 0)

    def test_genuine_late_memory_growth_fails_budget(self) -> None:
        footprints = [100 * 1024**2] * 8 + [
            (100 + 4 * index) * 1024**2 for index in range(8)
        ]

        def update(result: dict[str, object]) -> None:
            context = memory_context(900, footprints)
            result.update(context)
            result["resources"]["residentMemoryGrowthBytesPerHour"] = context[
                "memoryTrend"
            ]["growthBytesPerHour"]
            result["resources"]["peakResidentMemoryBytes"] = context[
                "memoryTrend"
            ]["peakPhysicalFootprintBytes"]
            result["resources"]["lifetimePeakResidentMemoryBytes"] = context[
                "memoryTrend"
            ]["peakPhysicalFootprintBytes"]

        self.rewrite_result("generative", update)

        report = performance_r1_report.build_report(self.root)

        verdict = next(
            item
            for item in report["budgetEvaluation"]["results"]
            if item["limit"]["workload"] == "generative"
            and item["limit"]["metric"]
            == "residentMemoryGrowthBytesPerHour"
        )
        self.assertEqual(verdict["status"], "overBudget")

    def test_manifest_independently_rejects_raw_hash_drift(self) -> None:
        path = self.root / "generative.json"
        original = path.read_text(encoding="utf-8")
        path.write_text(
            original.replace(
                '"workload": "generative"',
                '"workload": "generativf"',
                1,
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(ValueError, "SHA-256"):
            performance_r1_report.build_report(self.root)

    def test_manifest_rejects_missing_canonical_input_entry(self) -> None:
        path = self.root / "evidence-manifest.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        manifest["entries"] = [
            entry
            for entry in manifest["entries"]
            if entry["path"] != "generative.json"
        ]
        write_json(path, manifest)

        with self.assertRaisesRegex(ValueError, "manifest.*path set"):
            performance_r1_report.build_report(self.root)

    def test_preflight_requires_the_complete_environment_input_set(self) -> None:
        self.preflight["environmentInputPaths"].remove(
            "generative.footprint.csv"
        )
        self.refresh_manifests()

        with self.assertRaisesRegex(ValueError, "environmentInputPaths"):
            performance_r1_report.build_report(self.root)

    def test_clean_source_status_may_be_a_hashed_zero_byte_input(self) -> None:
        (self.root / "source-status-start.txt").write_text("", encoding="utf-8")
        (self.root / "source-status-end.txt").write_text("", encoding="utf-8")
        self.refresh_manifests()

        report = performance_r1_report.build_report(self.root)

        self.assertTrue(report["gatingEligible"])

    def test_manifest_rejects_unsafe_relative_path(self) -> None:
        path = self.root / "evidence-manifest.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        manifest["entries"][0]["path"] = "../outside"
        write_json(path, manifest)

        with self.assertRaisesRegex(ValueError, "relative leaf"):
            performance_r1_report.build_report(self.root)

    def test_helper_identity_must_remain_stable_through_sample_window(self) -> None:
        end_path = self.root / "helper-end-identity.json"
        end_identity = json.loads(end_path.read_text(encoding="utf-8"))
        end_identity["pid"] = 43
        write_json(end_path, end_identity)
        self.refresh_manifests()

        with self.assertRaisesRegex(ValueError, "helper identity changed"):
            performance_r1_report.build_report(self.root)

    def test_memory_trend_uses_all_samples_and_clamps_recovery_to_zero(self) -> None:
        samples = [100 * 1024**2, 101 * 1024**2, 102 * 1024**2]

        growth = performance_r1_report.memory_growth_bytes_per_hour(
            samples, duration_seconds=7200
        )
        recovery = performance_r1_report.memory_growth_bytes_per_hour(
            list(reversed(samples)), duration_seconds=7200
        )

        self.assertEqual(growth, 1024**2)
        self.assertEqual(recovery, 0)


if __name__ == "__main__":
    unittest.main()
