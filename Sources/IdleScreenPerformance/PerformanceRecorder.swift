import Foundation
import Darwin
import IdleScreenRenderer

public struct IdleScreenPerformanceResourceSnapshot: Codable, Equatable,
    Sendable
{
    public let capturedAt: TimeInterval
    public let userCPUSeconds: Double
    public let systemCPUSeconds: Double
    public let residentMemoryBytes: UInt64
    public let peakResidentMemoryBytes: UInt64
    public let interruptWakeups: UInt64
    public let platformIdleWakeups: UInt64
    public let timerWakeups: UInt64

    public init(
        capturedAt: TimeInterval,
        userCPUSeconds: Double,
        systemCPUSeconds: Double,
        residentMemoryBytes: UInt64,
        peakResidentMemoryBytes: UInt64,
        interruptWakeups: UInt64,
        platformIdleWakeups: UInt64,
        timerWakeups: UInt64
    ) {
        self.capturedAt = capturedAt
        self.userCPUSeconds = userCPUSeconds
        self.systemCPUSeconds = systemCPUSeconds
        self.residentMemoryBytes = residentMemoryBytes
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.interruptWakeups = interruptWakeups
        self.platformIdleWakeups = platformIdleWakeups
        self.timerWakeups = timerWakeups
    }
}

public struct IdleScreenPerformanceResourceDelta: Codable, Equatable,
    Sendable
{
    public let durationSeconds: TimeInterval
    public let averageCPUPercent: Double
    public let residentMemoryGrowthBytesPerHour: Double
    public let wakeupsPerSecond: Double
    public let peakResidentMemoryBytes: UInt64
    public let lifetimePeakResidentMemoryBytes: UInt64

    public init(
        durationSeconds: TimeInterval,
        averageCPUPercent: Double,
        residentMemoryGrowthBytesPerHour: Double,
        wakeupsPerSecond: Double,
        peakResidentMemoryBytes: UInt64,
        lifetimePeakResidentMemoryBytes: UInt64? = nil
    ) {
        self.durationSeconds = durationSeconds
        self.averageCPUPercent = averageCPUPercent
        self.residentMemoryGrowthBytesPerHour = residentMemoryGrowthBytesPerHour
        self.wakeupsPerSecond = wakeupsPerSecond
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.lifetimePeakResidentMemoryBytes =
            lifetimePeakResidentMemoryBytes ?? peakResidentMemoryBytes
    }

    public init(
        start: IdleScreenPerformanceResourceSnapshot,
        end: IdleScreenPerformanceResourceSnapshot
    ) {
        let duration = max(0.000_001, end.capturedAt - start.capturedAt)
        let cpuSeconds = max(
            0,
            end.userCPUSeconds + end.systemCPUSeconds
                - start.userCPUSeconds - start.systemCPUSeconds
        )
        let growth = max(
            0,
            Double(end.residentMemoryBytes) - Double(start.residentMemoryBytes)
        )
        let interrupt = end.interruptWakeups >= start.interruptWakeups
            ? end.interruptWakeups - start.interruptWakeups
            : 0
        let platform = end.platformIdleWakeups >= start.platformIdleWakeups
            ? end.platformIdleWakeups - start.platformIdleWakeups
            : 0
        let timer = end.timerWakeups >= start.timerWakeups
            ? end.timerWakeups - start.timerWakeups
            : 0
        durationSeconds = duration
        averageCPUPercent = cpuSeconds / duration * 100
        residentMemoryGrowthBytesPerHour = growth / duration * 3_600
        wakeupsPerSecond = Double(interrupt + platform + timer) / duration
        peakResidentMemoryBytes = max(
            start.residentMemoryBytes,
            end.residentMemoryBytes
        )
        lifetimePeakResidentMemoryBytes = max(
            start.peakResidentMemoryBytes,
            end.peakResidentMemoryBytes
        )
    }

    public static let zero = Self(
        durationSeconds: 0,
        averageCPUPercent: 0,
        residentMemoryGrowthBytesPerHour: 0,
        wakeupsPerSecond: 0,
        peakResidentMemoryBytes: 0
    )

    public func replacingMemory(
        _ trend: IdleScreenPerformanceMemoryTrend
    ) -> Self {
        .init(
            durationSeconds: durationSeconds,
            averageCPUPercent: averageCPUPercent,
            residentMemoryGrowthBytesPerHour: trend.growthBytesPerHour,
            wakeupsPerSecond: wakeupsPerSecond,
            peakResidentMemoryBytes: trend.peakPhysicalFootprintBytes,
            lifetimePeakResidentMemoryBytes: lifetimePeakResidentMemoryBytes
        )
    }
}

public struct IdleScreenPerformanceMemorySample: Codable, Equatable, Sendable {
    public let capturedAt: TimeInterval
    public let physicalFootprintBytes: UInt64

    public init(capturedAt: TimeInterval, physicalFootprintBytes: UInt64) {
        self.capturedAt = capturedAt
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

public struct IdleScreenPerformanceMemoryTrend: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let peakPhysicalFootprintBytes: UInt64
    public let growthBytesPerHour: Double
    public let wholeWindowGrowthBytesPerHour: Double
    public let steadyStateWindowStartedAt: TimeInterval

    public init(samples: [IdleScreenPerformanceMemorySample]) throws {
        guard samples.count >= 2 else {
            throw IdleScreenPerformanceContractError.insufficientMemorySamples
        }
        guard samples.allSatisfy({ $0.capturedAt.isFinite }),
              zip(samples, samples.dropFirst()).allSatisfy({ pair in
                  pair.0.capturedAt < pair.1.capturedAt
              }) else {
            throw IdleScreenPerformanceContractError.invalidMemorySampleOrder
        }
        sampleCount = samples.count
        peakPhysicalFootprintBytes = samples.map(\.physicalFootprintBytes).max()
            ?? 0
        wholeWindowGrowthBytesPerHour = Self.leastSquaresGrowthBytesPerHour(
            samples: samples
        )
        let midpoint = samples[0].capturedAt
            + (samples[samples.count - 1].capturedAt - samples[0].capturedAt)
                / 2
        let firstTailIndex = samples.firstIndex {
            $0.capturedAt >= midpoint
        } ?? samples.count - 1
        let tailStartIndex = max(0, firstTailIndex - 1)
        let steadyStateSamples = Array(samples[tailStartIndex...])
        steadyStateWindowStartedAt = steadyStateSamples[0].capturedAt
        growthBytesPerHour = Self.sustainedGrowthBytesPerHour(
            samples: steadyStateSamples
        )
    }

    private static func sustainedGrowthBytesPerHour(
        samples: [IdleScreenPerformanceMemorySample]
    ) -> Double {
        guard samples.count >= 6 else {
            return leastSquaresGrowthBytesPerHour(samples: samples)
        }
        let duration = samples[samples.count - 1].capturedAt
            - samples[0].capturedAt
        guard duration > 0 else { return 0 }
        let windowDuration = duration / 5
        var windowSlopes: [Double] = []
        var endIndex = 1
        for startIndex in samples.indices {
            endIndex = max(endIndex, startIndex + 1)
            let windowEnd = samples[startIndex].capturedAt + windowDuration
            while endIndex < samples.count,
                  samples[endIndex].capturedAt < windowEnd {
                endIndex += 1
            }
            guard endIndex < samples.count else { break }
            windowSlopes.append(
                leastSquaresGrowthBytesPerHour(
                    samples: Array(samples[startIndex...endIndex])
                )
            )
        }
        guard !windowSlopes.isEmpty else {
            return leastSquaresGrowthBytesPerHour(samples: samples)
        }
        windowSlopes.sort()
        let midpoint = windowSlopes.count / 2
        if windowSlopes.count.isMultiple(of: 2) {
            return (windowSlopes[midpoint - 1] + windowSlopes[midpoint]) / 2
        }
        return windowSlopes[midpoint]
    }

    private static func leastSquaresGrowthBytesPerHour(
        samples: [IdleScreenPerformanceMemorySample]
    ) -> Double {
        let origin = samples[0].capturedAt
        let times = samples.map { $0.capturedAt - origin }
        let memory = samples.map { Double($0.physicalFootprintBytes) }
        let meanTime = times.reduce(0, +) / Double(times.count)
        let meanMemory = memory.reduce(0, +) / Double(memory.count)
        let denominator = times.reduce(0) {
            $0 + ($1 - meanTime) * ($1 - meanTime)
        }
        guard denominator > 0 else { return 0 }
        let numerator = zip(times, memory).reduce(0) { partial, pair in
            partial
                + (pair.0 - meanTime) * (pair.1 - meanMemory)
        }
        return max(0, numerator / denominator * 3_600)
    }
}

public struct IdleScreenPerformanceFrameSchedule: Equatable, Sendable {
    private let startedAt: TimeInterval
    private let frameInterval: TimeInterval
    public private(set) var scheduledFrameCount = 0
    public private(set) var deadlineMissCount = 0

    public init(
        startedAt: TimeInterval,
        targetFramesPerSecond: Int
    ) throws {
        guard startedAt.isFinite, targetFramesPerSecond > 0 else {
            throw IdleScreenPerformanceHarnessError.invalidDuration
        }
        self.startedAt = startedAt
        frameInterval = 1 / Double(targetFramesPerSecond)
    }

    public mutating func recordAttemptCompleted(
        at completedAt: TimeInterval
    ) -> TimeInterval {
        scheduledFrameCount += 1
        let deadline = startedAt
            + Double(scheduledFrameCount) * frameInterval
        if !completedAt.isFinite || completedAt > deadline {
            deadlineMissCount += 1
        }
        return deadline
    }

    public var deadlineMissRatio: Double {
        scheduledFrameCount == 0
            ? 0
            : Double(deadlineMissCount) / Double(scheduledFrameCount)
    }
}

/// Paces the offscreen renderer against one monotonic Mach-time anchor. A
/// cumulative schedule paired with relative `Thread.sleep` can inherit timer
/// coalescing jitter, especially for cheap frames that sleep for nearly the
/// entire 33 ms interval. `mach_wait_until` keeps that harness behavior out of
/// the renderer's submission-cadence metric without changing product code.
struct IdleScreenPerformanceAbsoluteFramePacer {
    private let now: () -> TimeInterval
    private let anchorUptime: TimeInterval
    private let anchorTicks: UInt64
    private let ticksPerSecond: Double
    private let waitUntil: (UInt64) -> Void

    init() {
        var timebase = mach_timebase_info_data_t()
        _ = mach_timebase_info(&timebase)
        precondition(timebase.numer > 0 && timebase.denom > 0)
        now = { ProcessInfo.processInfo.systemUptime }
        anchorUptime = ProcessInfo.processInfo.systemUptime
        anchorTicks = mach_absolute_time()
        ticksPerSecond = 1_000_000_000
            * Double(timebase.denom) / Double(timebase.numer)
        waitUntil = { deadline in _ = mach_wait_until(deadline) }
    }

    init(
        now: @escaping () -> TimeInterval,
        anchorUptime: TimeInterval,
        anchorTicks: UInt64,
        ticksPerSecond: Double,
        waitUntil: @escaping (UInt64) -> Void
    ) {
        precondition(anchorUptime.isFinite)
        precondition(ticksPerSecond.isFinite && ticksPerSecond > 0)
        self.now = now
        self.anchorUptime = anchorUptime
        self.anchorTicks = anchorTicks
        self.ticksPerSecond = ticksPerSecond
        self.waitUntil = waitUntil
    }

    func wait(until deadlineUptime: TimeInterval) {
        guard deadlineUptime.isFinite else { return }
        while now() < deadlineUptime {
            waitUntil(absoluteTicks(for: deadlineUptime))
        }
    }

    private func absoluteTicks(for deadlineUptime: TimeInterval) -> UInt64 {
        let delta = max(0, deadlineUptime - anchorUptime)
        let ticks = Double(anchorTicks) + delta * ticksPerSecond
        return UInt64(min(ticks.rounded(.up), Double(UInt64.max)))
    }
}

public struct IdleScreenPerformanceCadenceDiagnostics: Codable, Equatable,
    Sendable
{
    public let attemptStartIntervalMilliseconds:
        IdleScreenPerformanceDistribution?
    public let wakeLatenessMilliseconds: IdleScreenPerformanceDistribution
    public let attemptDurationMilliseconds: IdleScreenPerformanceDistribution
    public let submissionOffsetMilliseconds:
        IdleScreenPerformanceDistribution?
    public let slowIntervalThresholdMilliseconds: Double
    public let slowSubmissionIntervalCount: Int
    public let slowAttemptStartIntervalCount: Int
    public let slowSubmissionWithSlowAttemptStartCount: Int

    init(
        scheduledStartTime: TimeInterval,
        targetFramesPerSecond: Int,
        slowIntervalThresholdMilliseconds: Double,
        attemptStartedAt: [TimeInterval],
        attemptCompletedAt: [TimeInterval],
        submittedAttemptStartedAt: [TimeInterval],
        submittedAt: [TimeInterval]
    ) throws {
        guard attemptStartedAt.count == attemptCompletedAt.count,
              submittedAttemptStartedAt.count == submittedAt.count else {
            throw IdleScreenPerformanceContractError
                .incoherentCadenceAccounting(
                    attempts: attemptStartedAt.count,
                    completions: attemptCompletedAt.count,
                    submittedAttempts: submittedAttemptStartedAt.count,
                    submissions: submittedAt.count
                )
        }
        guard !attemptStartedAt.isEmpty,
              scheduledStartTime.isFinite,
              targetFramesPerSecond > 0,
              slowIntervalThresholdMilliseconds.isFinite,
              slowIntervalThresholdMilliseconds > 0,
              Self.areStrictlyIncreasing(attemptStartedAt),
              Self.areStrictlyIncreasing(submittedAttemptStartedAt),
              Self.areStrictlyIncreasing(submittedAt),
              zip(attemptStartedAt, attemptCompletedAt).allSatisfy({ pair in
                  pair.0.isFinite && pair.1.isFinite && pair.1 >= pair.0
              }),
              zip(submittedAttemptStartedAt, submittedAt).allSatisfy({ pair in
                  pair.0.isFinite && pair.1.isFinite && pair.1 >= pair.0
              }) else {
            throw IdleScreenPerformanceContractError.invalidCadenceSampleOrder
        }

        let attemptStartIntervals = Self.intervals(attemptStartedAt)
        let submittedAttemptStartIntervals = Self.intervals(
            submittedAttemptStartedAt
        )
        let submissionIntervals = Self.intervals(submittedAt)
        let frameInterval = 1 / Double(targetFramesPerSecond)
        let wakeLateness = attemptStartedAt.enumerated().map { index, startedAt in
            max(
                0,
                (startedAt - scheduledStartTime - Double(index) * frameInterval)
                    * 1_000
            )
        }
        let attemptDurations = zip(
            attemptStartedAt,
            attemptCompletedAt
        ).map { max(0, ($0.1 - $0.0) * 1_000) }
        let submissionOffsets = zip(
            submittedAttemptStartedAt,
            submittedAt
        ).map { max(0, ($0.1 - $0.0) * 1_000) }

        attemptStartIntervalMilliseconds = try Self.distribution(
            attemptStartIntervals
        )
        wakeLatenessMilliseconds = try .init(samples: wakeLateness)
        attemptDurationMilliseconds = try .init(samples: attemptDurations)
        submissionOffsetMilliseconds = try Self.distribution(submissionOffsets)
        self.slowIntervalThresholdMilliseconds =
            slowIntervalThresholdMilliseconds
        slowSubmissionIntervalCount = submissionIntervals.count {
            $0 > slowIntervalThresholdMilliseconds
        }
        slowAttemptStartIntervalCount = submittedAttemptStartIntervals.count {
            $0 > slowIntervalThresholdMilliseconds
        }
        slowSubmissionWithSlowAttemptStartCount = zip(
            submissionIntervals,
            submittedAttemptStartIntervals
        ).count { pair in
            pair.0 > slowIntervalThresholdMilliseconds
                && pair.1 > slowIntervalThresholdMilliseconds
        }
    }

    private static func intervals(
        _ timestamps: [TimeInterval]
    ) -> [Double] {
        zip(timestamps, timestamps.dropFirst()).map {
            max(0, ($0.1 - $0.0) * 1_000)
        }
    }

    private static func distribution(
        _ samples: [Double]
    ) throws -> IdleScreenPerformanceDistribution? {
        samples.isEmpty ? nil : try .init(samples: samples)
    }

    private static func areStrictlyIncreasing(
        _ timestamps: [TimeInterval]
    ) -> Bool {
        timestamps.allSatisfy(\.isFinite)
            && zip(timestamps, timestamps.dropFirst()).allSatisfy { pair in
                pair.0 < pair.1
            }
    }
}

public struct IdleScreenPerformanceWorkloadResult: Codable, Equatable,
    Sendable
{
    public let workload: IdleScreenPerformanceWorkload
    public let durationSeconds: TimeInterval
    public let attemptedFrameCount: Int
    public let submittedFrameCount: Int
    public let completedFrameCount: Int
    public let droppedFrameCount: Int
    public let droppedFrameRatio: Double
    public let scheduledFrameCount: Int
    public let deadlineMissCount: Int
    public let cpuMilliseconds: IdleScreenPerformanceDistribution?
    public let gpuMilliseconds: IdleScreenPerformanceDistribution?
    public let frameIntervalMilliseconds: IdleScreenPerformanceDistribution?
    public let operationMilliseconds: IdleScreenPerformanceDistribution?
    public let dropReasons: [IdleScreenRendererFrameDropReason: Int]
    public let resources: IdleScreenPerformanceResourceDelta
    public let renderSurface: IdleScreenPerformanceRenderSurface?
    public let memorySamples: [IdleScreenPerformanceMemorySample]?
    public let memoryTrend: IdleScreenPerformanceMemoryTrend?
    public let cadenceDiagnostics: IdleScreenPerformanceCadenceDiagnostics?

    public init(
        workload: IdleScreenPerformanceWorkload,
        durationSeconds: TimeInterval,
        attemptedFrameCount: Int,
        submittedFrameCount: Int,
        completedFrameCount: Int,
        droppedFrameCount: Int,
        droppedFrameRatio: Double,
        scheduledFrameCount: Int = 0,
        deadlineMissCount: Int = 0,
        cpuMilliseconds: IdleScreenPerformanceDistribution?,
        gpuMilliseconds: IdleScreenPerformanceDistribution?,
        frameIntervalMilliseconds: IdleScreenPerformanceDistribution?,
        operationMilliseconds: IdleScreenPerformanceDistribution?,
        dropReasons: [IdleScreenRendererFrameDropReason: Int],
        resources: IdleScreenPerformanceResourceDelta,
        renderSurface: IdleScreenPerformanceRenderSurface? = nil,
        memorySamples: [IdleScreenPerformanceMemorySample]? = nil,
        memoryTrend: IdleScreenPerformanceMemoryTrend? = nil,
        cadenceDiagnostics: IdleScreenPerformanceCadenceDiagnostics? = nil
    ) {
        self.workload = workload
        self.durationSeconds = durationSeconds
        self.attemptedFrameCount = attemptedFrameCount
        self.submittedFrameCount = submittedFrameCount
        self.completedFrameCount = completedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.droppedFrameRatio = droppedFrameRatio
        self.scheduledFrameCount = scheduledFrameCount
        self.deadlineMissCount = deadlineMissCount
        self.cpuMilliseconds = cpuMilliseconds
        self.gpuMilliseconds = gpuMilliseconds
        self.frameIntervalMilliseconds = frameIntervalMilliseconds
        self.operationMilliseconds = operationMilliseconds
        self.dropReasons = dropReasons
        self.resources = resources
        self.renderSurface = renderSurface
        self.memorySamples = memorySamples
        self.memoryTrend = memoryTrend
        self.cadenceDiagnostics = cadenceDiagnostics
    }

    public func replacingResources(
        _ resources: IdleScreenPerformanceResourceDelta
    ) -> Self {
        .init(
            workload: workload,
            durationSeconds: durationSeconds,
            attemptedFrameCount: attemptedFrameCount,
            submittedFrameCount: submittedFrameCount,
            completedFrameCount: completedFrameCount,
            droppedFrameCount: droppedFrameCount,
            droppedFrameRatio: droppedFrameRatio,
            scheduledFrameCount: scheduledFrameCount,
            deadlineMissCount: deadlineMissCount,
            cpuMilliseconds: cpuMilliseconds,
            gpuMilliseconds: gpuMilliseconds,
            frameIntervalMilliseconds: frameIntervalMilliseconds,
            operationMilliseconds: operationMilliseconds,
            dropReasons: dropReasons,
            resources: resources,
            renderSurface: renderSurface,
            memorySamples: memorySamples,
            memoryTrend: memoryTrend,
            cadenceDiagnostics: cadenceDiagnostics
        )
    }

    public func replacingMeasurementContext(
        scheduledFrameCount: Int,
        deadlineMissCount: Int,
        renderSurface: IdleScreenPerformanceRenderSurface?,
        memorySamples: [IdleScreenPerformanceMemorySample],
        cadenceDiagnostics: IdleScreenPerformanceCadenceDiagnostics? = nil
    ) throws -> Self {
        let memoryTrend = try IdleScreenPerformanceMemoryTrend(
            samples: memorySamples
        )
        return .init(
            workload: workload,
            durationSeconds: durationSeconds,
            attemptedFrameCount: attemptedFrameCount,
            submittedFrameCount: submittedFrameCount,
            completedFrameCount: completedFrameCount,
            droppedFrameCount: droppedFrameCount,
            droppedFrameRatio: droppedFrameRatio,
            scheduledFrameCount: scheduledFrameCount,
            deadlineMissCount: deadlineMissCount,
            cpuMilliseconds: cpuMilliseconds,
            gpuMilliseconds: gpuMilliseconds,
            frameIntervalMilliseconds: frameIntervalMilliseconds,
            operationMilliseconds: operationMilliseconds,
            dropReasons: dropReasons,
            resources: resources.replacingMemory(memoryTrend),
            renderSurface: renderSurface,
            memorySamples: memorySamples,
            memoryTrend: memoryTrend,
            cadenceDiagnostics: cadenceDiagnostics
        )
    }
}

public final class IdleScreenPerformanceRecorder:
    IdleScreenRendererPerformanceObserving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var attemptedFrameCount = 0
    private var submittedFrameCount = 0
    private var completedFrameCount = 0
    private var pendingFrameIDs: Set<UInt64> = []
    private var earlyGPUCompletions: [UInt64: Double] = [:]
    private let correlationCapacity: Int
    private var cpuSamples: [Double] = []
    private var gpuSamples: [Double] = []
    private var submittedTimes: [TimeInterval] = []
    private var dropReasons: [IdleScreenRendererFrameDropReason: Int] = [:]

    public init(
        expectedFrameCount: Int = 0,
        now: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.now = now
        let capacity = max(0, expectedFrameCount)
        correlationCapacity = max(1, capacity)
        cpuSamples = Self.prewarmedSamples(capacity: capacity)
        gpuSamples = Self.prewarmedSamples(capacity: capacity)
        submittedTimes = Self.prewarmedSamples(capacity: capacity)
    }

    var prewarmedFrameCapacity: Int {
        lock.withLock {
            min(cpuSamples.capacity, gpuSamples.capacity, submittedTimes.capacity)
        }
    }

    public func rendererDidRecordPerformance(
        _ event: IdleScreenRendererPerformanceEvent
    ) {
        lock.withLock {
            switch event {
            case let .submitted(frameID, duration):
                if pendingFrameIDs.insert(frameID).inserted {
                    attemptedFrameCount += 1
                    submittedFrameCount += 1
                    cpuSamples.append(duration)
                    submittedTimes.append(now())
                    if let gpuDuration = earlyGPUCompletions.removeValue(
                        forKey: frameID
                    ) {
                        pendingFrameIDs.remove(frameID)
                        completedFrameCount += 1
                        gpuSamples.append(gpuDuration)
                    }
                }
            case let .completed(frameID, duration):
                if pendingFrameIDs.remove(frameID) != nil {
                    completedFrameCount += 1
                    gpuSamples.append(duration)
                } else if earlyGPUCompletions[frameID] == nil,
                    earlyGPUCompletions.count < correlationCapacity
                {
                    earlyGPUCompletions[frameID] = duration
                }
            case let .dropped(frameID, reason):
                earlyGPUCompletions.removeValue(forKey: frameID)
                attemptedFrameCount += 1
                dropReasons[reason, default: 0] += 1
            }
        }
    }

    public var retainedCorrelationFrameCount: Int {
        lock.withLock {
            pendingFrameIDs.count + earlyGPUCompletions.count
        }
    }

    public var pendingGPUFrameCount: Int {
        lock.withLock { pendingFrameIDs.count }
    }

    func submittedTimesSnapshot() -> [TimeInterval] {
        lock.withLock { submittedTimes }
    }

    public func reset() {
        lock.withLock {
            attemptedFrameCount = 0
            submittedFrameCount = 0
            completedFrameCount = 0
            pendingFrameIDs.removeAll(keepingCapacity: true)
            earlyGPUCompletions.removeAll(keepingCapacity: true)
            cpuSamples.removeAll(keepingCapacity: true)
            gpuSamples.removeAll(keepingCapacity: true)
            submittedTimes.removeAll(keepingCapacity: true)
            dropReasons.removeAll(keepingCapacity: true)
        }
    }

    private static func prewarmedSamples(capacity: Int) -> [Double] {
        guard capacity > 0 else { return [] }
        var samples = Array(repeating: 0.0, count: capacity)
        samples.removeAll(keepingCapacity: true)
        return samples
    }

    public func frameResult(
        workload: IdleScreenPerformanceWorkload,
        durationSeconds: TimeInterval
    ) throws -> IdleScreenPerformanceWorkloadResult {
        try lock.withLock {
            let dropped = dropReasons.values.reduce(0, +)
            let intervals = zip(submittedTimes, submittedTimes.dropFirst()).map {
                pair in max(0, (pair.1 - pair.0) * 1_000)
            }
            return .init(
                workload: workload,
                durationSeconds: durationSeconds,
                attemptedFrameCount: attemptedFrameCount,
                submittedFrameCount: submittedFrameCount,
                completedFrameCount: completedFrameCount,
                droppedFrameCount: dropped,
                droppedFrameRatio: attemptedFrameCount == 0
                    ? 0
                    : Double(dropped) / Double(attemptedFrameCount),
                cpuMilliseconds: try Self.distribution(cpuSamples),
                gpuMilliseconds: try Self.distribution(gpuSamples),
                frameIntervalMilliseconds: try Self.distribution(intervals),
                operationMilliseconds: nil,
                dropReasons: dropReasons,
                resources: .zero
            )
        }
    }

    private static func distribution(
        _ samples: [Double]
    ) throws -> IdleScreenPerformanceDistribution? {
        samples.isEmpty ? nil : try .init(samples: samples)
    }
}
