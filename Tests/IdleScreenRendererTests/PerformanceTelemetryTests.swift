import MetalKit
import Testing
@testable import IdleScreenRenderer

@Suite("Renderer performance telemetry")
struct PerformanceTelemetryTests {
    @MainActor
    @Test("an offscreen requested frame reports CPU and GPU timing")
    func offscreenFrameReportsTimings() async throws {
        let observer = PerformanceObserverSpy()
        let view = MTKView(frame: .init(x: 0, y: 0, width: 320, height: 180))
        let renderer = try IdleScreenRenderer(
            metalView: view,
            automaticallyDraws: false,
            performanceObserver: observer
        )

        #expect(renderer.draw(at: 1))
        let timings = try await withThrowingTaskGroup(
            of: PerformanceFrameTimings.self
        ) { group in
            group.addTask {
                guard let timings = await observer.firstCompletedFrame() else {
                    throw PerformanceObserverError.streamEnded
                }
                return timings
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw PerformanceObserverError.timedOut
            }
            defer { group.cancelAll() }
            guard let timings = try await group.next() else {
                throw PerformanceObserverError.streamEnded
            }
            return timings
        }
        #expect(timings.cpuDurationMilliseconds.isFinite)
        #expect(timings.cpuDurationMilliseconds >= 0)
        #expect(timings.gpuDurationMilliseconds.isFinite)
        #expect(timings.gpuDurationMilliseconds >= 0)
        renderer.shutdown()
    }

    @Test("frame events retain only timings and bounded reason labels")
    func eventPayload() {
        let submitted = IdleScreenRendererPerformanceEvent.submitted(
            frameID: 7,
            cpuDurationMilliseconds: 2.5
        )
        let completed = IdleScreenRendererPerformanceEvent.completed(
            frameID: 7,
            gpuDurationMilliseconds: 0.75
        )

        #expect(submitted.frameID == 7)
        #expect(completed.frameID == 7)
        #expect(IdleScreenRendererFrameDropReason.allCases.count == 4)
    }

    @Test("observer matches one frame across unrelated and reordered events")
    func matchingFrameEvents() async throws {
        let observer = PerformanceObserverSpy()
        observer.rendererDidRecordPerformance(
            .dropped(frameID: 1, reason: .renderResourcesUnavailable)
        )
        observer.rendererDidRecordPerformance(
            .completed(frameID: 2, gpuDurationMilliseconds: 0.75)
        )
        observer.rendererDidRecordPerformance(
            .submitted(frameID: 2, cpuDurationMilliseconds: 2.5)
        )

        let timings = try #require(await observer.firstCompletedFrame())
        #expect(timings.frameID == 2)
        #expect(timings.cpuDurationMilliseconds == 2.5)
        #expect(timings.gpuDurationMilliseconds == 0.75)
    }
}

private final class PerformanceObserverSpy:
    IdleScreenRendererPerformanceObserving,
    @unchecked Sendable
{
    private let stream: AsyncStream<IdleScreenRendererPerformanceEvent>
    private let continuation:
        AsyncStream<IdleScreenRendererPerformanceEvent>.Continuation

    init() {
        let pair = AsyncStream.makeStream(
            of: IdleScreenRendererPerformanceEvent.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func firstCompletedFrame() async -> PerformanceFrameTimings? {
        var submitted: [UInt64: Double] = [:]
        var completed: [UInt64: Double] = [:]
        for await event in stream {
            switch event {
            case let .submitted(frameID, duration):
                if let gpuDuration = completed.removeValue(forKey: frameID) {
                    return PerformanceFrameTimings(
                        frameID: frameID,
                        cpuDurationMilliseconds: duration,
                        gpuDurationMilliseconds: gpuDuration
                    )
                }
                submitted[frameID] = duration
            case let .completed(frameID, duration):
                if let cpuDuration = submitted.removeValue(forKey: frameID) {
                    return PerformanceFrameTimings(
                        frameID: frameID,
                        cpuDurationMilliseconds: cpuDuration,
                        gpuDurationMilliseconds: duration
                    )
                }
                completed[frameID] = duration
            case let .dropped(frameID, _):
                submitted.removeValue(forKey: frameID)
                completed.removeValue(forKey: frameID)
            }
        }
        return nil
    }

    func rendererDidRecordPerformance(
        _ event: IdleScreenRendererPerformanceEvent
    ) {
        continuation.yield(event)
    }
}

private struct PerformanceFrameTimings: Sendable {
    let frameID: UInt64
    let cpuDurationMilliseconds: Double
    let gpuDurationMilliseconds: Double
}

private enum PerformanceObserverError: Error {
    case timedOut
    case streamEnded
}
