import Darwin
import Foundation
import Testing

@testable import IdleScreenPerformance

@Suite("R1.1 production workload harness")
struct PerformanceHarnessTests {
    @MainActor
    @Test(
        "offscreen renderer workloads submit and complete real Metal frames",
        arguments: [
            IdleScreenPerformanceWorkload.generative,
            .cameraSynthetic,
            .pixelMaterialsSand,
            .pixelMaterialsWater,
            .pixelMaterialsMixed,
        ]
    )
    func rendererWorkloads(workload: IdleScreenPerformanceWorkload) throws {
        let result = try IdleScreenPerformanceHarness.measureRenderer(
            workload: workload,
            durationSeconds: 1,
            logicalWidth: 320,
            logicalHeight: 180,
            drawableWidth: 640,
            drawableHeight: 360
        )

        #expect(result.attemptedFrameCount >= 2)
        #expect(result.submittedFrameCount >= 1)
        #expect(result.completedFrameCount == result.submittedFrameCount)
        #expect(result.cpuMilliseconds != nil)
        #expect(result.gpuMilliseconds != nil)
        #expect(result.resources.peakResidentMemoryBytes > 0)
        #expect(result.renderSurface?.logicalWidth == 320)
        #expect(result.renderSurface?.logicalHeight == 180)
        #expect(result.renderSurface?.drawableWidth == 640)
        #expect(result.renderSurface?.drawableHeight == 360)
        #expect(result.renderSurface?.deviceName.isEmpty == false)
        #expect(result.renderSurface?.deviceRegistryID != 0)
        #expect(result.renderSurface?.colorPixelFormat == "bgra8Unorm")
        #expect(result.scheduledFrameCount == result.attemptedFrameCount)
        #expect(
            result.attemptedFrameCount
                == result.submittedFrameCount + result.droppedFrameCount
        )
        #expect(result.completedFrameCount == result.submittedFrameCount)
        #expect(result.cpuMilliseconds?.count == result.submittedFrameCount)
        #expect(result.gpuMilliseconds?.count == result.completedFrameCount)
        #expect(
            result.frameIntervalMilliseconds?.count
                == max(0, result.submittedFrameCount - 1)
        )
        #expect(result.deadlineMissCount <= result.scheduledFrameCount)
        let cadence = try #require(result.cadenceDiagnostics)
        let attemptIntervals = try #require(
            cadence.attemptStartIntervalMilliseconds
        )
        let submissionOffsets = try #require(
            cadence.submissionOffsetMilliseconds
        )
        #expect(
            attemptIntervals.count
                == max(0, result.attemptedFrameCount - 1)
        )
        #expect(cadence.wakeLatenessMilliseconds.count == result.attemptedFrameCount)
        #expect(cadence.attemptDurationMilliseconds.count == result.attemptedFrameCount)
        #expect(submissionOffsets.count == result.submittedFrameCount)
        #expect((result.memorySamples?.count ?? 0) >= 2)
        #expect(result.memoryTrend?.sampleCount == result.memorySamples?.count)
        #expect(
            result.resources.residentMemoryGrowthBytesPerHour
                == result.memoryTrend?.growthBytesPerHour
        )
        #expect(
            result.resources.peakResidentMemoryBytes
                == result.memoryTrend?.peakPhysicalFootprintBytes
        )
    }

    @Test("mailbox benchmark uses the full publish-read-sample production path")
    func mailboxTransport() throws {
        let result = try IdleScreenPerformanceHarness.measureMailboxTransport(
            durationSeconds: 0.05,
            width: 128,
            height: 72
        )

        #expect(result.workload == .mailboxTransport)
        #expect((result.operationMilliseconds?.count ?? 0) > 0)
        #expect(result.resources.peakResidentMemoryBytes > 0)
    }

    @Test("AgentSignal polling benchmark reads the bounded atomic inbox")
    func agentSignalPolling() throws {
        let result = try IdleScreenPerformanceHarness.measureAgentSignalPolling(
            durationSeconds: 0.05,
            pollingInterval: 0.01
        )

        #expect(result.workload == .agentSignalPolling)
        #expect((result.operationMilliseconds?.count ?? 0) > 0)
        #expect(result.resources.peakResidentMemoryBytes > 0)
    }

    @Test("helper idle sampling observes an existing PID without launching it")
    func existingProcess() throws {
        let result = try IdleScreenPerformanceHarness.measureExternalProcess(
            workload: .helperIdle,
            processIdentifier: getpid(),
            durationSeconds: 0.01
        )

        #expect(result.workload == .helperIdle)
        #expect(result.resources.peakResidentMemoryBytes > 0)
        #expect(result.memorySamples?.count == 2)
        #expect(result.attemptedFrameCount == 0)
        #expect(result.scheduledFrameCount == 0)
        #expect(result.deadlineMissCount == 0)
    }

    @MainActor
    @Test("startup benchmark records five fresh renderer first frames")
    func startup() throws {
        let result = try IdleScreenPerformanceHarness.measureRendererStartup(
            workload: .rendererStartupWarm,
            iterations: 5,
            logicalWidth: 320,
            logicalHeight: 180,
            drawableWidth: 640,
            drawableHeight: 360
        )

        #expect(result.operationMilliseconds?.count == 5)
        #expect(result.submittedFrameCount == 5)
        #expect(result.completedFrameCount == 5)
        #expect(result.scheduledFrameCount == 5)
        #expect(result.deadlineMissCount == 0)
        #expect(result.renderSurface?.drawableWidth == 640)
        #expect(result.renderSurface?.drawableHeight == 360)
    }

    @Test("warm startup primes once without including the prime sample")
    func warmStartupPrime() throws {
        var attempts = 0

        let samples = try IdleScreenPerformanceHarness.startupOperationSamples(
            workload: .rendererStartupWarm,
            iterations: 3
        ) {
            attempts += 1
            return Double(attempts)
        }

        #expect(attempts == 4)
        #expect(samples == [2, 3, 4])
    }

    @Test("startup attempt failures propagate instead of becoming fast samples")
    func startupFailure() {
        var attempts = 0

        #expect(throws: FixtureStartupError.failed) {
            try IdleScreenPerformanceHarness.startupOperationSamples(
                workload: .rendererStartupCold,
                iterations: 5
            ) {
                attempts += 1
                throw FixtureStartupError.failed
            }
        }
        #expect(attempts == 1)
    }

    @Test("renderer measurement activity requests interactive precision and ends on success")
    func measurementActivitySuccess() throws {
        var events: [String] = []
        var requestedOptions: ProcessInfo.ActivityOptions = []
        let activity = IdleScreenPerformanceMeasurementActivity(
            begin: { options, reason in
                requestedOptions = options
                events.append("begin:\(reason)")
                return { events.append("end") }
            }
        )

        let value = activity.perform {
            events.append("body")
            return 42
        }

        #expect(value == 42)
        #expect(requestedOptions == .userInteractive)
        #expect(
            events == [
                "begin:IdleScreen R1 renderer measurement",
                "body",
                "end",
            ])
    }

    @Test("renderer measurement activity ends when measurement throws")
    func measurementActivityFailure() {
        var events: [String] = []
        let activity = IdleScreenPerformanceMeasurementActivity(
            begin: { _, _ in
                events.append("begin")
                return { events.append("end") }
            }
        )

        #expect(throws: FixtureStartupError.failed) {
            try activity.perform {
                events.append("body")
                throw FixtureStartupError.failed
            }
        }
        #expect(events == ["begin", "body", "end"])
    }
}

private enum FixtureStartupError: Error {
    case failed
}
