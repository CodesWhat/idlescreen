import Foundation
import IdleScreenCamera
import IdleScreenCameraAgentCore
import IdleScreenCore
import IdleScreenRenderer
import MetalKit

struct IdleScreenPerformanceMeasurementActivity {
    typealias EndActivity = () -> Void

    private let begin: (ProcessInfo.ActivityOptions, String) -> EndActivity

    init(
        begin: @escaping (ProcessInfo.ActivityOptions, String) -> EndActivity = {
            options, reason in
            let token = ProcessInfo.processInfo.beginActivity(
                options: options,
                reason: reason
            )
            return {
                ProcessInfo.processInfo.endActivity(token)
            }
        }
    ) {
        self.begin = begin
    }

    func perform<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        let end = begin(
            .userInteractive,
            "IdleScreen R1 renderer measurement"
        )
        defer { end() }
        return try operation()
    }
}

public enum IdleScreenPerformanceHarnessError: Error, Equatable, Sendable {
    case unsupportedWorkload(IdleScreenPerformanceWorkload)
    case invalidDuration
    case invalidIterations
    case cameraSamplingFailed
    case mailboxSnapshotUnavailable
    case gpuCompletionTimedOut(Int)
    case rendererFrameNotSubmitted
    case rendererStartupIncomplete(submitted: Int, completed: Int)
    case incoherentFrameAccounting(attempted: Int, scheduled: Int)
}

public enum IdleScreenPerformanceHarness {
    @MainActor
    public static func measureRenderer(
        workload: IdleScreenPerformanceWorkload,
        durationSeconds: TimeInterval,
        logicalWidth: Int = 1_728,
        logicalHeight: Int = 1_117,
        drawableWidth: Int,
        drawableHeight: Int,
        targetFramesPerSecond: Int = 30
    ) throws -> IdleScreenPerformanceWorkloadResult {
        guard durationSeconds > 0, durationSeconds.isFinite,
            logicalWidth > 0, logicalHeight > 0,
            drawableWidth > 0, drawableHeight > 0,
            targetFramesPerSecond > 0
        else {
            throw IdleScreenPerformanceHarnessError.invalidDuration
        }
        return try IdleScreenPerformanceMeasurementActivity().perform {
            let expectedFrameCount = Int(
                (durationSeconds * Double(targetFramesPerSecond)).rounded(.up)
            ) + 1
            let configuration = try rendererConfiguration(for: workload)
            let mode: IdleScreenRendererMode =
                workload == .cameraSynthetic
                ? .camera
                : .generative
            let recorder = IdleScreenPerformanceRecorder(
                expectedFrameCount: expectedFrameCount
            )
            let view = renderView(
                logicalWidth: logicalWidth,
                logicalHeight: logicalHeight,
                drawableWidth: drawableWidth,
                drawableHeight: drawableHeight
            )
            let renderer = try IdleScreenRenderer(
                metalView: view,
                configuration: configuration,
                mode: mode,
                automaticallyDraws: false,
                pixelMaterialsCoordinator: .init(),
                performanceObserver: recorder
            )
            let cameraPixels =
                workload == .cameraSynthetic
                ? syntheticCameraPixels(width: 1_280, height: 720)
                : []
            var cameraSequence: UInt64 = 1
            let warmupStartedAt = ProcessInfo.processInfo.systemUptime
            for frameIndex in 0..<30 {
                if workload == .cameraSynthetic {
                    let frame = cameraPixels.withUnsafeBytes { pixels in
                        IdleScreenRendererCameraFrame.samplingBGRA(
                            producerStreamEpoch: 1,
                            sequence: cameraSequence,
                            width: 1_280,
                            height: 720,
                            bytesPerRow: 1_280 * 4,
                            pixels: pixels,
                            columns: IdleScreenRendererCameraFrame.productionColumns,
                            rows: IdleScreenRendererCameraFrame.productionRows
                        )
                    }
                    guard let frame else {
                        throw IdleScreenPerformanceHarnessError.cameraSamplingFailed
                    }
                    renderer.submit(cameraFrame: frame)
                    cameraSequence &+= 1
                }
                _ = renderer.draw(at: Double(frameIndex) / 30)
                let nextWarmupFrame =
                    warmupStartedAt
                    + Double(frameIndex + 1) / 30
                let warmupRemaining =
                    nextWarmupFrame
                    - ProcessInfo.processInfo.systemUptime
                if warmupRemaining > 0 {
                    Thread.sleep(forTimeInterval: warmupRemaining)
                }
            }
            try waitForGPU(recorder)
            recorder.reset()
            var operationSamples = prewarmedSamples(
                capacity: expectedFrameCount
            )
            var attemptStartedTimes = prewarmedSamples(
                capacity: expectedFrameCount
            )
            var attemptCompletedTimes = prewarmedSamples(
                capacity: expectedFrameCount
            )
            var submittedAttemptStartedTimes = prewarmedSamples(
                capacity: expectedFrameCount
            )
            let resourcesBefore = try IdleScreenPerformanceProcessSampler.snapshot()
            var memorySamples = [memorySample(resourcesBefore)]
            let startedAt = ProcessInfo.processInfo.systemUptime
            let deadline = startedAt + durationSeconds
            var frameSchedule = try IdleScreenPerformanceFrameSchedule(
                startedAt: startedAt,
                targetFramesPerSecond: targetFramesPerSecond
            )
            let framePacer = IdleScreenPerformanceAbsoluteFramePacer()
            var nextMemorySampleAt = startedAt + memorySamplingInterval

            while ProcessInfo.processInfo.systemUptime < deadline {
                let attemptStarted = ProcessInfo.processInfo.systemUptime
                let submitted: Bool = autoreleasepool {
                    if workload == .cameraSynthetic {
                        let sampleStartedAt = ProcessInfo.processInfo.systemUptime
                        let frame = cameraPixels.withUnsafeBytes { pixels in
                            IdleScreenRendererCameraFrame.samplingBGRA(
                                producerStreamEpoch: 1,
                                sequence: cameraSequence,
                                width: 1_280,
                                height: 720,
                                bytesPerRow: 1_280 * 4,
                                pixels: pixels,
                                columns: IdleScreenRendererCameraFrame
                                    .productionColumns,
                                rows: IdleScreenRendererCameraFrame.productionRows
                            )
                        }
                        guard let frame else { return false }
                        renderer.submit(cameraFrame: frame)
                        operationSamples.append(
                            (ProcessInfo.processInfo.systemUptime - sampleStartedAt)
                                * 1_000
                        )
                        cameraSequence &+= 1
                    }
                    return renderer.draw(
                        at: attemptStarted - startedAt
                    )
                }
                let attemptCompletedAt = ProcessInfo.processInfo.systemUptime
                attemptStartedTimes.append(attemptStarted)
                attemptCompletedTimes.append(attemptCompletedAt)
                if submitted {
                    submittedAttemptStartedTimes.append(attemptStarted)
                }
                let nextFrameAt = frameSchedule.recordAttemptCompleted(
                    at: attemptCompletedAt
                )
                if attemptCompletedAt >= nextMemorySampleAt {
                    let snapshot = try IdleScreenPerformanceProcessSampler.snapshot()
                    appendMemorySample(snapshot, to: &memorySamples)
                    repeat {
                        nextMemorySampleAt += memorySamplingInterval
                    } while nextMemorySampleAt <= snapshot.capturedAt
                }
                framePacer.wait(until: nextFrameAt)
            }
            try waitForGPU(recorder)
            let resourcesAfter = try IdleScreenPerformanceProcessSampler.snapshot()
            appendMemorySample(resourcesAfter, to: &memorySamples)
            renderer.shutdown()
            var result = try recorder.frameResult(
                workload: workload,
                durationSeconds: resourcesAfter.capturedAt
                    - resourcesBefore.capturedAt
            )
            result = replacingOperationSamples(result, samples: operationSamples)
            result = result.replacingResources(
                .init(start: resourcesBefore, end: resourcesAfter)
            )
            guard result.attemptedFrameCount == frameSchedule.scheduledFrameCount else {
                throw IdleScreenPerformanceHarnessError.incoherentFrameAccounting(
                    attempted: result.attemptedFrameCount,
                    scheduled: frameSchedule.scheduledFrameCount
                )
            }
            let cadenceDiagnostics = try IdleScreenPerformanceCadenceDiagnostics(
                scheduledStartTime: startedAt,
                targetFramesPerSecond: targetFramesPerSecond,
                slowIntervalThresholdMilliseconds:
                    1.2 * 1_000 / Double(targetFramesPerSecond),
                attemptStartedAt: attemptStartedTimes,
                attemptCompletedAt: attemptCompletedTimes,
                submittedAttemptStartedAt: submittedAttemptStartedTimes,
                submittedAt: recorder.submittedTimesSnapshot()
            )
            return try result.replacingMeasurementContext(
                scheduledFrameCount: frameSchedule.scheduledFrameCount,
                deadlineMissCount: frameSchedule.deadlineMissCount,
                renderSurface: renderSurface(for: view),
                memorySamples: memorySamples,
                cadenceDiagnostics: cadenceDiagnostics
            )
        }
    }

    @MainActor
    public static func measureRendererStartup(
        workload: IdleScreenPerformanceWorkload,
        iterations: Int,
        logicalWidth: Int = 1_728,
        logicalHeight: Int = 1_117,
        drawableWidth: Int,
        drawableHeight: Int
    ) throws -> IdleScreenPerformanceWorkloadResult {
        guard
            workload == .rendererStartupCold
                || workload == .rendererStartupWarm
        else {
            throw IdleScreenPerformanceHarnessError.unsupportedWorkload(workload)
        }
        guard iterations > 0, logicalWidth > 0, logicalHeight > 0,
            drawableWidth > 0, drawableHeight > 0
        else {
            throw IdleScreenPerformanceHarnessError.invalidIterations
        }
        let resourcesBefore = try IdleScreenPerformanceProcessSampler.snapshot()
        var measuredSurface: IdleScreenPerformanceRenderSurface?
        let operationSamples = try startupOperationSamples(
            workload: workload,
            iterations: iterations
        ) {
            let attempt = try rendererStartupAttempt(
                workload: workload,
                logicalWidth: logicalWidth,
                logicalHeight: logicalHeight,
                drawableWidth: drawableWidth,
                drawableHeight: drawableHeight
            )
            measuredSurface = attempt.surface
            return attempt.durationMilliseconds
        }
        let resourcesAfter = try IdleScreenPerformanceProcessSampler.snapshot()
        let memorySamples = [
            memorySample(resourcesBefore),
            memorySample(resourcesAfter),
        ]
        let memoryTrend = try IdleScreenPerformanceMemoryTrend(
            samples: memorySamples
        )
        return .init(
            workload: workload,
            durationSeconds: resourcesAfter.capturedAt
                - resourcesBefore.capturedAt,
            attemptedFrameCount: iterations,
            submittedFrameCount: iterations,
            completedFrameCount: iterations,
            droppedFrameCount: 0,
            droppedFrameRatio: 0,
            scheduledFrameCount: iterations,
            deadlineMissCount: 0,
            cpuMilliseconds: nil,
            gpuMilliseconds: nil,
            frameIntervalMilliseconds: nil,
            operationMilliseconds: try .init(samples: operationSamples),
            dropReasons: [:],
            resources: IdleScreenPerformanceResourceDelta(
                start: resourcesBefore,
                end: resourcesAfter
            ).replacingMemory(memoryTrend),
            renderSurface: measuredSurface,
            memorySamples: memorySamples,
            memoryTrend: memoryTrend
        )
    }

    static func startupOperationSamples(
        workload: IdleScreenPerformanceWorkload,
        iterations: Int,
        operation: () throws -> Double
    ) throws -> [Double] {
        guard
            workload == .rendererStartupCold
                || workload == .rendererStartupWarm
        else {
            throw IdleScreenPerformanceHarnessError.unsupportedWorkload(workload)
        }
        guard iterations > 0 else {
            throw IdleScreenPerformanceHarnessError.invalidIterations
        }
        if workload == .rendererStartupWarm {
            _ = try operation()
        }
        return try (0..<iterations).map { _ in try operation() }
    }

    public static func measureMailboxTransport(
        durationSeconds: TimeInterval,
        width: Int = 1_280,
        height: Int = 720,
        targetFramesPerSecond: Int = 30
    ) throws -> IdleScreenPerformanceWorkloadResult {
        guard durationSeconds > 0, durationSeconds.isFinite,
            width > 0, height > 0,
            targetFramesPerSecond > 0
        else {
            throw IdleScreenPerformanceHarnessError.invalidDuration
        }
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "idlescreen-r1-mailbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let layout = IdleScreenCameraFrameMailboxLayout.current
        let writer = try CameraFrameMailboxWriter(
            appGroupContainerURL: temporaryRoot,
            mailboxFileName: "r1.mailbox",
            layout: layout
        )
        try writer.startStream(streamEpoch: 1)
        let loader = try IdleScreenCameraAtomicGenerationLoader(
            mappedByteCount: layout.expectedFileByteCount()
        )
        let mapping = try IdleScreenCameraFrameMailboxMapping(
            contentsOf: writer.mailboxURL,
            generationLoader: loader,
            layout: layout
        )
        let pixels = syntheticCameraPixels(width: width, height: height)
        let resourcesBefore = try IdleScreenPerformanceProcessSampler.snapshot()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + durationSeconds
        var operationSamples: [Double] = []
        var timestamp: TimeInterval = 1
        var checksum: UInt64 = 0
        var nextFrameAt = startedAt

        while ProcessInfo.processInfo.systemUptime < deadline {
            let operationStartedAt = ProcessInfo.processInfo.systemUptime
            let sampled = try pixels.withUnsafeBytes { buffer in
                _ = try writer.publish(
                    bytes: buffer,
                    width: width,
                    height: height,
                    sourceBytesPerRow: width * 4,
                    timestamp: timestamp
                )
                return try mapping.withStableSnapshot { descriptor, payload in
                    IdleScreenRendererCameraFrame.samplingBGRA(
                        producerStreamEpoch: descriptor.streamEpoch,
                        sequence: descriptor.sequence,
                        width: Int(descriptor.width),
                        height: Int(descriptor.height),
                        bytesPerRow: Int(descriptor.bytesPerRow),
                        pixels: payload,
                        columns: IdleScreenRendererCameraFrame.productionColumns,
                        rows: IdleScreenRendererCameraFrame.productionRows
                    )
                }
            }
            guard let sampled, let frame = sampled else {
                throw IdleScreenPerformanceHarnessError
                    .mailboxSnapshotUnavailable
            }
            checksum &+= frame.checksum
            operationSamples.append(
                (ProcessInfo.processInfo.systemUptime - operationStartedAt)
                    * 1_000
            )
            timestamp += 1.0 / 30
            nextFrameAt += 1 / Double(targetFramesPerSecond)
            let remaining = nextFrameAt - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        }
        withExtendedLifetime(checksum) {}
        try writer.stopStream()
        let resourcesAfter = try IdleScreenPerformanceProcessSampler.snapshot()
        return try domainResult(
            workload: .mailboxTransport,
            samples: operationSamples,
            start: resourcesBefore,
            end: resourcesAfter
        )
    }

    public static func measureAgentSignalPolling(
        durationSeconds: TimeInterval,
        pollingInterval: TimeInterval = 1
    ) throws -> IdleScreenPerformanceWorkloadResult {
        guard durationSeconds > 0, durationSeconds.isFinite else {
            throw IdleScreenPerformanceHarnessError.invalidDuration
        }
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "idlescreen-r1-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let fileURL = temporaryRoot.appending(path: "inbox-v1.json")
        let store = IdleScreenAgentSignalStore(fileURL: fileURL)
        let now = Date()
        let signal = try IdleScreenAgentSignal.validated(
            provider: .codex,
            sessionID: "r1-session",
            eventID: "r1-event",
            state: .working,
            title: "Codex",
            message: nil,
            temporaryLookID: nil,
            priority: 0,
            createdAt: now,
            expiresAt: now.addingTimeInterval(3_600),
            acknowledgedAt: nil,
            nonce: "r1-nonce",
            validatedAt: now
        )
        _ = try store.apply(.set(signal), at: now)
        var monitor = IdleScreenAgentSignalMonitor(
            store: store,
            pollingInterval: pollingInterval
        )
        let resourcesBefore = try IdleScreenPerformanceProcessSampler.snapshot()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + durationSeconds
        let effectiveInterval = min(
            IdleScreenAgentSignalMonitor.maximumPollingInterval,
            max(
                IdleScreenAgentSignalMonitor.minimumPollingInterval,
                pollingInterval
            )
        )
        var nextPollAt = startedAt
        var samples: [Double] = []
        while ProcessInfo.processInfo.systemUptime < deadline {
            let operationStartedAt = ProcessInfo.processInfo.systemUptime
            _ = try monitor.poll(
                at: now.addingTimeInterval(operationStartedAt - startedAt)
            )
            samples.append(
                (ProcessInfo.processInfo.systemUptime - operationStartedAt)
                    * 1_000
            )
            nextPollAt += effectiveInterval
            let remaining =
                min(
                    deadline,
                    nextPollAt
                ) - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        }
        let resourcesAfter = try IdleScreenPerformanceProcessSampler.snapshot()
        return try domainResult(
            workload: .agentSignalPolling,
            samples: samples,
            start: resourcesBefore,
            end: resourcesAfter
        )
    }

    public static func measureZeroConsumer(
        durationSeconds: TimeInterval
    ) throws -> IdleScreenPerformanceWorkloadResult {
        guard durationSeconds > 0, durationSeconds.isFinite else {
            throw IdleScreenPerformanceHarnessError.invalidDuration
        }
        let resourceWindow = try sampleResourceWindow(
            durationSeconds: durationSeconds,
            snapshot: IdleScreenPerformanceProcessSampler.snapshot
        )
        return try domainResult(
            workload: .zeroConsumer,
            samples: [],
            start: resourceWindow.start,
            end: resourceWindow.end,
            memorySamples: resourceWindow.memorySamples
        )
    }

    /// Samples an already-running same-user process. It never starts, signals,
    /// registers, or otherwise mutates the target process.
    public static func measureExternalProcess(
        workload: IdleScreenPerformanceWorkload,
        processIdentifier: pid_t,
        durationSeconds: TimeInterval
    ) throws -> IdleScreenPerformanceWorkloadResult {
        guard workload == .helperIdle else {
            throw IdleScreenPerformanceHarnessError.unsupportedWorkload(workload)
        }
        guard processIdentifier > 0, durationSeconds > 0,
            durationSeconds.isFinite
        else {
            throw IdleScreenPerformanceHarnessError.invalidDuration
        }
        let resourceWindow = try sampleResourceWindow(
            durationSeconds: durationSeconds,
            snapshot: {
                try IdleScreenPerformanceProcessSampler.snapshot(
                    processIdentifier: processIdentifier
                )
            }
        )
        return try domainResult(
            workload: workload,
            samples: [],
            start: resourceWindow.start,
            end: resourceWindow.end,
            memorySamples: resourceWindow.memorySamples
        )
    }

    private static func rendererConfiguration(
        for workload: IdleScreenPerformanceWorkload
    ) throws -> IdleScreenRendererConfiguration {
        var configuration = IdleScreenRendererConfiguration.default
        switch workload {
        case .generative, .cameraSynthetic:
            configuration.patternRawValue = "autoCycle"
        case .pixelMaterialsSand:
            configuration.patternRawValue = "pixelMaterials"
            configuration.pixelMaterialsSettings = .init(material: .sand)
        case .pixelMaterialsWater:
            configuration.patternRawValue = "pixelMaterials"
            configuration.pixelMaterialsSettings = .init(material: .water)
        case .pixelMaterialsMixed:
            configuration.patternRawValue = "pixelMaterials"
            configuration.pixelMaterialsSettings = .init(material: .mixed)
        default:
            throw IdleScreenPerformanceHarnessError.unsupportedWorkload(workload)
        }
        return configuration
    }

    private struct RendererStartupAttempt {
        let durationMilliseconds: Double
        let surface: IdleScreenPerformanceRenderSurface
    }

    @MainActor
    private static func rendererStartupAttempt(
        workload: IdleScreenPerformanceWorkload,
        logicalWidth: Int,
        logicalHeight: Int,
        drawableWidth: Int,
        drawableHeight: Int
    ) throws -> RendererStartupAttempt {
        let recorder = IdleScreenPerformanceRecorder()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let view = renderView(
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            drawableWidth: drawableWidth,
            drawableHeight: drawableHeight
        )
        let renderer = try IdleScreenRenderer(
            metalView: view,
            automaticallyDraws: false,
            pixelMaterialsCoordinator: .init(),
            performanceObserver: recorder
        )
        defer { renderer.shutdown() }
        guard renderer.draw(at: 0) else {
            throw IdleScreenPerformanceHarnessError.rendererFrameNotSubmitted
        }
        try waitForGPU(recorder)
        let durationMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        let frame = try recorder.frameResult(
            workload: workload,
            durationSeconds: 0
        )
        guard frame.submittedFrameCount == 1,
            frame.completedFrameCount == 1,
            frame.droppedFrameCount == 0
        else {
            throw IdleScreenPerformanceHarnessError.rendererStartupIncomplete(
                submitted: frame.submittedFrameCount,
                completed: frame.completedFrameCount
            )
        }
        return .init(
            durationMilliseconds: durationMilliseconds,
            surface: renderSurface(for: view)
        )
    }

    @MainActor
    private static func renderView(
        logicalWidth: Int,
        logicalHeight: Int,
        drawableWidth: Int,
        drawableHeight: Int
    ) -> MTKView {
        let view = MTKView(
            frame: .init(
                x: 0,
                y: 0,
                width: logicalWidth,
                height: logicalHeight
            ))
        view.autoResizeDrawable = false
        view.drawableSize = .init(
            width: drawableWidth,
            height: drawableHeight
        )
        return view
    }

    @MainActor
    private static func renderSurface(
        for view: MTKView
    ) -> IdleScreenPerformanceRenderSurface {
        return .init(
            logicalWidth: Int(view.bounds.width.rounded()),
            logicalHeight: Int(view.bounds.height.rounded()),
            drawableWidth: Int(view.drawableSize.width.rounded()),
            drawableHeight: Int(view.drawableSize.height.rounded()),
            deviceName: view.device?.name ?? "unavailable",
            deviceRegistryID: view.device?.registryID ?? 0,
            colorPixelFormat: pixelFormatName(view.colorPixelFormat)
        )
    }

    private static func pixelFormatName(_ pixelFormat: MTLPixelFormat) -> String {
        switch pixelFormat {
        case .bgra8Unorm:
            "bgra8Unorm"
        default:
            "raw:\(pixelFormat.rawValue)"
        }
    }

    private static func syntheticCameraPixels(
        width: Int,
        height: Int
    ) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let pixel = index / 4
            pixels[index] = UInt8(truncatingIfNeeded: pixel)
            pixels[index + 1] = UInt8(truncatingIfNeeded: pixel / width)
            pixels[index + 2] = UInt8(truncatingIfNeeded: pixel % width)
            pixels[index + 3] = 255
        }
        return pixels
    }

    private static func waitForGPU(
        _ recorder: IdleScreenPerformanceRecorder
    ) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while recorder.pendingGPUFrameCount > 0,
            ProcessInfo.processInfo.systemUptime < deadline
        {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let pending = recorder.pendingGPUFrameCount
        guard pending == 0 else {
            throw IdleScreenPerformanceHarnessError.gpuCompletionTimedOut(
                pending
            )
        }
    }

    private static func replacingOperationSamples(
        _ result: IdleScreenPerformanceWorkloadResult,
        samples: [Double]
    ) -> IdleScreenPerformanceWorkloadResult {
        .init(
            workload: result.workload,
            durationSeconds: result.durationSeconds,
            attemptedFrameCount: result.attemptedFrameCount,
            submittedFrameCount: result.submittedFrameCount,
            completedFrameCount: result.completedFrameCount,
            droppedFrameCount: result.droppedFrameCount,
            droppedFrameRatio: result.droppedFrameRatio,
            scheduledFrameCount: result.scheduledFrameCount,
            deadlineMissCount: result.deadlineMissCount,
            cpuMilliseconds: result.cpuMilliseconds,
            gpuMilliseconds: result.gpuMilliseconds,
            frameIntervalMilliseconds: result.frameIntervalMilliseconds,
            operationMilliseconds: samples.isEmpty
                ? nil
                : try? .init(samples: samples),
            dropReasons: result.dropReasons,
            resources: result.resources,
            renderSurface: result.renderSurface,
            memorySamples: result.memorySamples,
            memoryTrend: result.memoryTrend
        )
    }

    private static func domainResult(
        workload: IdleScreenPerformanceWorkload,
        samples: [Double],
        start: IdleScreenPerformanceResourceSnapshot,
        end: IdleScreenPerformanceResourceSnapshot,
        memorySamples: [IdleScreenPerformanceMemorySample]? = nil
    ) throws -> IdleScreenPerformanceWorkloadResult {
        let samplesForTrend =
            memorySamples ?? [
                memorySample(start),
                memorySample(end),
            ]
        let memoryTrend = try IdleScreenPerformanceMemoryTrend(
            samples: samplesForTrend
        )
        return .init(
            workload: workload,
            durationSeconds: end.capturedAt - start.capturedAt,
            attemptedFrameCount: 0,
            submittedFrameCount: 0,
            completedFrameCount: 0,
            droppedFrameCount: 0,
            droppedFrameRatio: 0,
            cpuMilliseconds: nil,
            gpuMilliseconds: nil,
            frameIntervalMilliseconds: nil,
            operationMilliseconds: samples.isEmpty
                ? nil
                : try? .init(samples: samples),
            dropReasons: [:],
            resources: IdleScreenPerformanceResourceDelta(
                start: start,
                end: end
            ).replacingMemory(memoryTrend),
            memorySamples: samplesForTrend,
            memoryTrend: memoryTrend
        )
    }

    private static let memorySamplingInterval: TimeInterval = 1

    private struct ResourceWindow {
        let start: IdleScreenPerformanceResourceSnapshot
        let end: IdleScreenPerformanceResourceSnapshot
        let memorySamples: [IdleScreenPerformanceMemorySample]
    }

    private static func sampleResourceWindow(
        durationSeconds: TimeInterval,
        snapshot: () throws -> IdleScreenPerformanceResourceSnapshot
    ) throws -> ResourceWindow {
        let start = try snapshot()
        let deadline = start.capturedAt + durationSeconds
        var memorySamples = [memorySample(start)]
        var end = start
        while ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                Thread.sleep(
                    forTimeInterval: min(
                        memorySamplingInterval,
                        remaining
                    ))
            }
            end = try snapshot()
            appendMemorySample(end, to: &memorySamples)
        }
        return .init(
            start: start,
            end: end,
            memorySamples: memorySamples
        )
    }

    private static func memorySample(
        _ snapshot: IdleScreenPerformanceResourceSnapshot
    ) -> IdleScreenPerformanceMemorySample {
        .init(
            capturedAt: snapshot.capturedAt,
            physicalFootprintBytes: snapshot.residentMemoryBytes
        )
    }

    private static func appendMemorySample(
        _ snapshot: IdleScreenPerformanceResourceSnapshot,
        to samples: inout [IdleScreenPerformanceMemorySample]
    ) {
        guard snapshot.capturedAt > (samples.last?.capturedAt ?? -.infinity) else {
            return
        }
        samples.append(memorySample(snapshot))
    }

    private static func prewarmedSamples(capacity: Int) -> [Double] {
        guard capacity > 0 else { return [] }
        var samples = Array(repeating: 0.0, count: capacity)
        samples.removeAll(keepingCapacity: true)
        return samples
    }
}
