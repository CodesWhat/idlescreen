import Foundation
import Darwin
import IdleScreenRenderer
import Testing
@testable import IdleScreenPerformance

@Suite("R1.1 measurement recorder")
struct PerformanceRecorderTests {
    @Test("frame recorder correlates submissions, completions, drops, and pacing")
    func frameRecorder() throws {
        let clock = FixturePerformanceClock(values: [1, 1.033, 1.066])
        let recorder = IdleScreenPerformanceRecorder(now: { clock.next() })

        recorder.rendererDidRecordPerformance(
            .submitted(frameID: 1, cpuDurationMilliseconds: 2)
        )
        recorder.rendererDidRecordPerformance(
            .completed(frameID: 1, gpuDurationMilliseconds: 0.5)
        )
        recorder.rendererDidRecordPerformance(
            .submitted(frameID: 2, cpuDurationMilliseconds: 3)
        )
        recorder.rendererDidRecordPerformance(
            .completed(frameID: 2, gpuDurationMilliseconds: 0.75)
        )
        recorder.rendererDidRecordPerformance(
            .dropped(frameID: 3, reason: .inFlightSaturated)
        )

        let result = try recorder.frameResult(
            workload: .generative,
            durationSeconds: 1
        )
        #expect(result.attemptedFrameCount == 3)
        #expect(result.submittedFrameCount == 2)
        #expect(result.completedFrameCount == 2)
        #expect(result.droppedFrameCount == 1)
        #expect(result.droppedFrameRatio == 1.0 / 3.0)
        #expect(result.cpuMilliseconds?.p95 == 3)
        #expect(result.gpuMilliseconds?.p95 == 0.75)
        #expect(
            abs((result.frameIntervalMilliseconds?.p95 ?? 0) - 33) < 0.001
        )
        #expect(result.dropReasons == [.inFlightSaturated: 1])
    }

    @Test("completion before submission remains correlated")
    func completionBeforeSubmission() throws {
        let recorder = IdleScreenPerformanceRecorder(
            expectedFrameCount: 1,
            now: { 1 }
        )

        recorder.rendererDidRecordPerformance(
            .completed(frameID: 1, gpuDurationMilliseconds: 0.5)
        )
        #expect(recorder.pendingGPUFrameCount == 0)
        #expect(recorder.retainedCorrelationFrameCount == 1)

        recorder.rendererDidRecordPerformance(
            .submitted(frameID: 1, cpuDurationMilliseconds: 2)
        )

        let result = try recorder.frameResult(
            workload: .generative,
            durationSeconds: 1
        )
        #expect(result.attemptedFrameCount == 1)
        #expect(result.submittedFrameCount == 1)
        #expect(result.completedFrameCount == 1)
        #expect(result.cpuMilliseconds?.p95 == 2)
        #expect(result.gpuMilliseconds?.p95 == 0.5)
        #expect(recorder.pendingGPUFrameCount == 0)
        #expect(recorder.retainedCorrelationFrameCount == 0)
    }

    @Test("completed frames release correlation identifiers")
    func boundedFrameCorrelation() {
        let recorder = IdleScreenPerformanceRecorder(now: { 1 })
        for frameID in 1...10_000 {
            recorder.rendererDidRecordPerformance(
                .submitted(
                    frameID: UInt64(frameID),
                    cpuDurationMilliseconds: 1
                )
            )
            recorder.rendererDidRecordPerformance(
                .completed(
                    frameID: UInt64(frameID),
                    gpuDurationMilliseconds: 1
                )
            )
        }

        #expect(recorder.retainedCorrelationFrameCount == 0)
        #expect(recorder.pendingGPUFrameCount == 0)
    }

    @Test("resource deltas produce CPU, memory growth, and wakeup rates")
    func resourceDelta() {
        let start = IdleScreenPerformanceResourceSnapshot(
            capturedAt: 10,
            userCPUSeconds: 2,
            systemCPUSeconds: 1,
            residentMemoryBytes: 100,
            peakResidentMemoryBytes: 120,
            interruptWakeups: 20,
            platformIdleWakeups: 10,
            timerWakeups: 30
        )
        let end = IdleScreenPerformanceResourceSnapshot(
            capturedAt: 20,
            userCPUSeconds: 2.5,
            systemCPUSeconds: 1.5,
            residentMemoryBytes: 1_100,
            peakResidentMemoryBytes: 1_200,
            interruptWakeups: 25,
            platformIdleWakeups: 15,
            timerWakeups: 40
        )

        let delta = IdleScreenPerformanceResourceDelta(start: start, end: end)
        #expect(delta.durationSeconds == 10)
        #expect(delta.averageCPUPercent == 10)
        #expect(delta.residentMemoryGrowthBytesPerHour == 360_000)
        #expect(delta.wakeupsPerSecond == 2)
        #expect(delta.peakResidentMemoryBytes == 1_100)
        #expect(delta.lifetimePeakResidentMemoryBytes == 1_200)
    }

    @Test("scheduled deadline misses are distinct from renderer drops")
    func scheduledDeadlineMisses() throws {
        var schedule = try IdleScreenPerformanceFrameSchedule(
            startedAt: 10,
            targetFramesPerSecond: 10
        )

        let firstDeadline = schedule.recordAttemptCompleted(at: 10.05)
        let secondDeadline = schedule.recordAttemptCompleted(at: 10.25)

        #expect(abs(firstDeadline - 10.1) < 0.000_001)
        #expect(abs(secondDeadline - 10.2) < 0.000_001)
        #expect(schedule.scheduledFrameCount == 2)
        #expect(schedule.deadlineMissCount == 1)
        #expect(schedule.deadlineMissRatio == 0.5)
    }

    @Test("absolute frame pacing retries early wakes against one anchored deadline")
    func absoluteFramePacing() {
        var now = 10.0
        var requestedTicks: [UInt64] = []
        let pacer = IdleScreenPerformanceAbsoluteFramePacer(
            now: { now },
            anchorUptime: 10,
            anchorTicks: 1_000,
            ticksPerSecond: 100,
            waitUntil: { deadline in
                requestedTicks.append(deadline)
                now += requestedTicks.count == 1 ? 0.25 : 0.25
            }
        )

        pacer.wait(until: 10.5)

        #expect(requestedTicks == [1_050, 1_050])
        #expect(now == 10.5)
        pacer.wait(until: 10.4)
        #expect(requestedTicks == [1_050, 1_050])
    }

    @Test("cadence diagnostics correlate slow submissions with slow attempt starts")
    func cadenceDiagnostics() throws {
        let diagnostics = try IdleScreenPerformanceCadenceDiagnostics(
            scheduledStartTime: 10,
            targetFramesPerSecond: 10,
            slowIntervalThresholdMilliseconds: 150,
            attemptStartedAt: [10, 10.2, 10.3],
            attemptCompletedAt: [10.02, 10.23, 10.32],
            submittedAttemptStartedAt: [10, 10.2, 10.3],
            submittedAt: [10.01, 10.25, 10.31]
        )

        let attemptIntervals = try #require(
            diagnostics.attemptStartIntervalMilliseconds
        )
        let submissionOffsets = try #require(
            diagnostics.submissionOffsetMilliseconds
        )
        #expect(attemptIntervals.count == 2)
        #expect(
            abs(attemptIntervals.p95 - 200) < 0.001
        )
        #expect(diagnostics.wakeLatenessMilliseconds.count == 3)
        #expect(abs(diagnostics.wakeLatenessMilliseconds.p95 - 100) < 0.001)
        #expect(diagnostics.attemptDurationMilliseconds.count == 3)
        #expect(abs(diagnostics.attemptDurationMilliseconds.p95 - 30) < 0.001)
        #expect(submissionOffsets.count == 3)
        #expect(abs(submissionOffsets.p95 - 50) < 0.001)
        #expect(diagnostics.slowIntervalThresholdMilliseconds == 150)
        #expect(diagnostics.slowSubmissionIntervalCount == 1)
        #expect(diagnostics.slowAttemptStartIntervalCount == 1)
        #expect(diagnostics.slowSubmissionWithSlowAttemptStartCount == 1)
    }

    @Test("timestamped memory trend uses actual spacing and current footprint")
    func timestampedMemoryTrend() throws {
        let trend = try IdleScreenPerformanceMemoryTrend(samples: [
            .init(capturedAt: 10, physicalFootprintBytes: 100),
            .init(capturedAt: 20, physicalFootprintBytes: 200),
            .init(capturedAt: 40, physicalFootprintBytes: 300),
        ])

        #expect(trend.sampleCount == 3)
        #expect(trend.peakPhysicalFootprintBytes == 300)
        #expect(abs(trend.growthBytesPerHour - 18_000) < 0.001)
        #expect(
            abs(trend.wholeWindowGrowthBytesPerHour - 162_000.0 / 7.0)
                < 0.001
        )
        #expect(trend.steadyStateWindowStartedAt == 20)
    }

    @Test("timestamped memory recovery clamps growth without hiding its peak")
    func timestampedMemoryRecovery() throws {
        let trend = try IdleScreenPerformanceMemoryTrend(samples: [
            .init(capturedAt: 1, physicalFootprintBytes: 300),
            .init(capturedAt: 2, physicalFootprintBytes: 200),
            .init(capturedAt: 4, physicalFootprintBytes: 100),
        ])

        #expect(trend.growthBytesPerHour == 0)
        #expect(trend.peakPhysicalFootprintBytes == 300)
    }

    @Test("early residency step followed by a plateau has zero steady-state growth")
    func timestampedMemoryResidencyStep() throws {
        let trend = try IdleScreenPerformanceMemoryTrend(samples: [
            .init(capturedAt: 0, physicalFootprintBytes: 100),
            .init(capturedAt: 1, physicalFootprintBytes: 100),
            .init(capturedAt: 2, physicalFootprintBytes: 200),
            .init(capturedAt: 4, physicalFootprintBytes: 200),
            .init(capturedAt: 6, physicalFootprintBytes: 200),
            .init(capturedAt: 8, physicalFootprintBytes: 200),
            .init(capturedAt: 10, physicalFootprintBytes: 200),
        ])

        #expect(trend.growthBytesPerHour == 0)
        #expect(trend.wholeWindowGrowthBytesPerHour > 0)
        #expect(trend.peakPhysicalFootprintBytes == 200)
        #expect(trend.steadyStateWindowStartedAt == 4)
    }

    @Test("late memory leak remains visible in the steady-state tail")
    func timestampedLateMemoryLeak() throws {
        let trend = try IdleScreenPerformanceMemoryTrend(samples: [
            .init(capturedAt: 0, physicalFootprintBytes: 100),
            .init(capturedAt: 2, physicalFootprintBytes: 100),
            .init(capturedAt: 4, physicalFootprintBytes: 100),
            .init(capturedAt: 6, physicalFootprintBytes: 120),
            .init(capturedAt: 8, physicalFootprintBytes: 140),
            .init(capturedAt: 10, physicalFootprintBytes: 160),
        ])

        #expect(trend.growthBytesPerHour > 0)
        #expect(trend.wholeWindowGrowthBytesPerHour > 0)
        #expect(trend.steadyStateWindowStartedAt == 4)
    }

    @Test("late residency step followed by a plateau is not reported as a leak")
    func timestampedLateMemoryResidencyStep() throws {
        let trend = try IdleScreenPerformanceMemoryTrend(samples: [
            .init(capturedAt: 0, physicalFootprintBytes: 100),
            .init(capturedAt: 1, physicalFootprintBytes: 100),
            .init(capturedAt: 2, physicalFootprintBytes: 100),
            .init(capturedAt: 3, physicalFootprintBytes: 100),
            .init(capturedAt: 4, physicalFootprintBytes: 100),
            .init(capturedAt: 5, physicalFootprintBytes: 100),
            .init(capturedAt: 6, physicalFootprintBytes: 100),
            .init(capturedAt: 7, physicalFootprintBytes: 200),
            .init(capturedAt: 8, physicalFootprintBytes: 200),
            .init(capturedAt: 9, physicalFootprintBytes: 200),
            .init(capturedAt: 10, physicalFootprintBytes: 200),
        ])

        #expect(trend.growthBytesPerHour == 0)
        #expect(trend.wholeWindowGrowthBytesPerHour > 0)
        #expect(trend.peakPhysicalFootprintBytes == 200)
    }

    @Test("repeated residency steps remain visible as sustained growth")
    func timestampedSustainedMemoryStaircase() throws {
        let trend = try IdleScreenPerformanceMemoryTrend(samples: (0...20).map {
            second in
            .init(
                capturedAt: TimeInterval(second),
                physicalFootprintBytes: UInt64(100 + (second / 2) * 10)
            )
        })

        #expect(trend.growthBytesPerHour > 0)
        #expect(trend.wholeWindowGrowthBytesPerHour > 0)
    }

    @Test("measurement recorder commits expected sample storage before sampling")
    func recorderPrewarmsExpectedFrameStorage() {
        let recorder = IdleScreenPerformanceRecorder(
            expectedFrameCount: 27_000,
            now: { 1 }
        )

        #expect(recorder.prewarmedFrameCapacity >= 27_000)
    }

    @Test("the process sampler reads CPU, VM, and wakeup counters without privilege")
    func processSampler() throws {
        let snapshot = try IdleScreenPerformanceProcessSampler.snapshot()

        #expect(snapshot.capturedAt > 0)
        #expect(snapshot.userCPUSeconds >= 0)
        #expect(snapshot.systemCPUSeconds >= 0)
        #expect(snapshot.residentMemoryBytes > 0)
        #expect(
            snapshot.peakResidentMemoryBytes
                >= snapshot.residentMemoryBytes
        )

        let external = try IdleScreenPerformanceProcessSampler.snapshot(
            processIdentifier: getpid()
        )
        #expect(external.residentMemoryBytes > 0)
        #expect(external.userCPUSeconds >= 0)
    }

    @Test("workload output carries domain and resource results without pixels")
    func workloadOutputRoundTrip() throws {
        let output = IdleScreenPerformanceWorkloadResult(
            workload: .mailboxTransport,
            durationSeconds: 5,
            attemptedFrameCount: 0,
            submittedFrameCount: 0,
            completedFrameCount: 0,
            droppedFrameCount: 0,
            droppedFrameRatio: 0,
            cpuMilliseconds: nil,
            gpuMilliseconds: nil,
            frameIntervalMilliseconds: nil,
            operationMilliseconds: try .init(samples: [0.2, 0.3]),
            dropReasons: [:],
            resources: .init(
                durationSeconds: 5,
                averageCPUPercent: 2,
                residentMemoryGrowthBytesPerHour: 0,
                wakeupsPerSecond: 1,
                peakResidentMemoryBytes: 1024
            )
        )
        let data = try JSONEncoder.idleScreenPerformance.encode(output)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("pixels"))
        #expect(text.contains("\"scheduledFrameCount\" : 0"))
        #expect(text.contains("\"deadlineMissCount\" : 0"))
        #expect(
            try JSONDecoder.idleScreenPerformance.decode(
                IdleScreenPerformanceWorkloadResult.self,
                from: data
            ) == output
        )
    }
}

private final class FixturePerformanceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval]

    init(values: [TimeInterval]) {
        self.values = values
    }

    func next() -> TimeInterval {
        lock.withLock {
            values.isEmpty ? 0 : values.removeFirst()
        }
    }
}
