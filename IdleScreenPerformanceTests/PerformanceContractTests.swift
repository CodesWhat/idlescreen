import Foundation
import Testing
@testable import IdleScreenPerformance

@Suite("R1.1 performance contract")
struct PerformanceContractTests {
    @Test("distributions use deterministic nearest-rank percentiles")
    func distributions() throws {
        let summary = try IdleScreenPerformanceDistribution(
            samples: [100, 1, 9, 4, 16, 25, 36, 49, 64, 81]
        )

        #expect(summary.count == 10)
        #expect(summary.minimum == 1)
        #expect(summary.median == 25)
        #expect(summary.p95 == 100)
        #expect(summary.p99 == 100)
        #expect(summary.maximum == 100)
        #expect(summary.mean == 38.5)
        #expect(throws: IdleScreenPerformanceContractError.emptySamples) {
            try IdleScreenPerformanceDistribution(samples: [])
        }
        #expect(throws: IdleScreenPerformanceContractError.nonfiniteSample) {
            try IdleScreenPerformanceDistribution(samples: [1, .infinity])
        }
    }

    @Test("M4 Pro release budgets cover every required R1.1 workload")
    func completeBudgetCoverage() {
        let budgets = IdleScreenPerformanceBudgets.m4ProSingleDisplay
        let covered = Set(budgets.limits.map(\.workload))

        #expect(covered == Set(IdleScreenPerformanceWorkload.allCases))
        #expect(budgets.hardwareClass == "Apple M4 Pro 20-core GPU")
        #expect(budgets.displayCount == 1)
        #expect(budgets.targetFramesPerSecond == 30)
        #expect(
            budgets.identifier
                == "m4-pro-4112x2658-single-display-r1.1-v2-render-capacity"
        )
        for limit in budgets.limits {
            #expect(limit.maximum.isFinite)
            #expect(limit.maximum > 0)
        }
        for workload in [
            IdleScreenPerformanceWorkload.generative,
            .cameraSynthetic,
            .pixelMaterialsSand,
            .pixelMaterialsWater,
            .pixelMaterialsMixed,
        ] {
            let workloadLimits = budgets.limits.filter {
                $0.workload == workload
            }
            #expect(workloadLimits.contains { limit in
                limit.metric == .deadlineMissRatio
            })
            #expect(workloadLimits.contains { limit in
                limit.metric == .attemptDurationP95Milliseconds
                    && limit.maximum == 20
            })
            #expect(!workloadLimits.contains { limit in
                limit.metric == .frameIntervalP95Milliseconds
            })
            #expect(workloadLimits.contains { limit in
                limit.metric == .peakResidentMemoryBytes
                    && limit.maximum == 512 * 1_024 * 1_024
            })
        }
    }

    @Test("named budget validates the exact hardware display and render surface")
    func exactEnvironmentValidation() {
        let budgets = IdleScreenPerformanceBudgets.m4ProSingleDisplay
        let surface = IdleScreenPerformanceRenderSurface(
            logicalWidth: 2_056,
            logicalHeight: 1_329,
            drawableWidth: 4_112,
            drawableHeight: 2_658,
            deviceName: "Apple M4 Pro",
            deviceRegistryID: 42,
            colorPixelFormat: "bgra8Unorm"
        )
        let exact = IdleScreenPerformanceBudgetEnvironment(
            hardwareClass: "Apple M4 Pro 20-core GPU",
            display: .init(
                count: 1,
                pixelWidth: 4_112,
                pixelHeight: 2_658,
                scale: 2
            ),
            targetFramesPerSecond: 30,
            renderSurface: surface
        )

        #expect(budgets.validate(environment: exact).passed)

        let wrongSurface = IdleScreenPerformanceBudgetEnvironment(
            hardwareClass: exact.hardwareClass,
            display: exact.display,
            targetFramesPerSecond: exact.targetFramesPerSecond,
            renderSurface: .init(
                logicalWidth: surface.logicalWidth,
                logicalHeight: surface.logicalHeight,
                drawableWidth: 2_056,
                drawableHeight: surface.drawableHeight,
                deviceName: surface.deviceName,
                deviceRegistryID: surface.deviceRegistryID,
                colorPixelFormat: surface.colorPixelFormat
            )
        )
        let validation = budgets.validate(environment: wrongSurface)

        #expect(!validation.passed)
        #expect(validation.mismatches.map(\.field).contains("renderSurface.drawableWidth"))
    }

    @Test("budget evaluation fails closed for missing and excessive metrics")
    func budgetEvaluation() {
        let budgets = IdleScreenPerformanceBudgetSet(
            identifier: "fixture",
            hardwareClass: "fixture",
            displayCount: 1,
            targetFramesPerSecond: 30,
            limits: [
                .init(
                    workload: .generative,
                    metric: .cpuFrameP95Milliseconds,
                    maximum: 20,
                    unit: .milliseconds
                ),
                .init(
                    workload: .generative,
                    metric: .droppedFrameRatio,
                    maximum: 0.01,
                    unit: .ratio
                ),
            ]
        )
        let evaluation = budgets.evaluate([
            .init(
                workload: .generative,
                metric: .cpuFrameP95Milliseconds,
                value: 21,
                unit: .milliseconds
            ),
        ])

        #expect(!evaluation.passed)
        #expect(evaluation.results.count == 2)
        #expect(evaluation.results[0].status == .overBudget)
        #expect(evaluation.results[1].status == .missing)
    }

    @Test("reports round-trip with exact artifact and environment identity")
    func reportRoundTrip() throws {
        let report = IdleScreenPerformanceReport(
            schemaVersion: 1,
            runIdentifier: "r1-fixture",
            capturedAt: Date(timeIntervalSince1970: 1_786_300_000),
            commit: "0123456789abcdef",
            artifactSHA256: String(repeating: "a", count: 64),
            hardware: .init(
                modelIdentifier: "Mac16,7",
                chip: "Apple M4 Pro",
                cpuCoreCount: 14,
                gpuCoreCount: 20,
                memoryBytes: 48 * 1_024 * 1_024 * 1_024
            ),
            operatingSystem: .init(version: "26.5.2", build: "25F84"),
            display: .init(
                count: 1,
                pixelWidth: 3456,
                pixelHeight: 2234,
                scale: 2
            ),
            budgetsIdentifier: "m4-pro-single-display-r1.1-v1",
            measurements: [
                .init(
                    workload: .agentSignalPolling,
                    metric: .operationP95Milliseconds,
                    value: 0.2,
                    unit: .milliseconds
                ),
            ],
            notes: ["synthetic camera pixels only"]
        )

        let data = try JSONEncoder.idleScreenPerformance.encode(report)
        let decoded = try JSONDecoder.idleScreenPerformance.decode(
            IdleScreenPerformanceReport.self,
            from: data
        )
        #expect(decoded == report)
    }
}
