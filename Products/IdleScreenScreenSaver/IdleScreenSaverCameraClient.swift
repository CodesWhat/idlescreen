import Foundation
import IdleScreenCamera
import IdleScreenRenderer
import OSLog

enum IdleScreenSaverCameraDiagnosticEvent: Equatable, Sendable {
    case available(
        producerStreamEpoch: UInt64,
        sequence: UInt64
    )
    case fallbackUnavailable

    fileprivate enum AvailabilityState: Equatable, Sendable {
        case available
        case fallback
    }

    fileprivate var availabilityState: AvailabilityState {
        switch self {
        case .available: .available
        case .fallbackUnavailable: .fallback
        }
    }

    var logMessage: String {
        switch self {
        case let .available(producerStreamEpoch, sequence):
            "Camera receipt state=available epoch=\(producerStreamEpoch) sequence=\(sequence)"
        case .fallbackUnavailable:
            "Camera receipt state=fallback-unavailable"
        }
    }
}

struct IdleScreenSaverCameraDiagnosticPolicy: Sendable {
    static let minimumEmissionInterval: TimeInterval = 1

    private var lastEmissionTime: TimeInterval?
    private var lastEmittedEvent: IdleScreenSaverCameraDiagnosticEvent?

    mutating func emission(
        for event: IdleScreenSaverCameraDiagnosticEvent,
        at monotonicTime: TimeInterval
    ) -> IdleScreenSaverCameraDiagnosticEvent? {
        guard monotonicTime.isFinite, monotonicTime >= 0 else { return nil }
        guard event != lastEmittedEvent else { return nil }
        if let lastEmissionTime, let lastEmittedEvent {
            guard monotonicTime >= lastEmissionTime else { return nil }
            if event.availabilityState == lastEmittedEvent.availabilityState,
               monotonicTime - lastEmissionTime < Self.minimumEmissionInterval {
                return nil
            }
        }
        lastEmissionTime = monotonicTime
        lastEmittedEvent = event
        return event
    }
}

struct IdleScreenCameraGlyphSample: Equatable, Sendable {
    let producerStreamEpoch: UInt64
    let sequence: UInt64
    let glyphField: String
    let checksum: UInt64
    let sampledPixelCount: Int
    /// Production camera content for the shared Metal renderer. `glyphField`
    /// is retained for diagnostics compatibility and is never displayed.
    let rendererFrame: IdleScreenRendererCameraFrame?

    init(
        producerStreamEpoch: UInt64,
        sequence: UInt64,
        glyphField: String,
        checksum: UInt64,
        sampledPixelCount: Int,
        rendererFrame: IdleScreenRendererCameraFrame? = nil
    ) {
        self.producerStreamEpoch = producerStreamEpoch
        self.sequence = sequence
        self.glyphField = glyphField
        self.checksum = checksum
        self.sampledPixelCount = sampledPixelCount
        self.rendererFrame = rendererFrame
    }

    var diagnosticEvent: IdleScreenSaverCameraDiagnosticEvent {
        .available(
            producerStreamEpoch: producerStreamEpoch,
            sequence: sequence
        )
    }
}

enum IdleScreenSaverCameraSampleRead: Equatable, Sendable {
    case frame(IdleScreenCameraGlyphSample)
    case noNewFrame
    case unavailable
}

enum IdleScreenCameraGlyphSampler {
    static let maximumColumns = 54
    static let maximumRows = 18
    static let maximumSampledPixelCount = maximumColumns * maximumRows

    private static let glyphRamp: [Character] = [" ", "·", ":", "+", "#", "@"]

    /// Samples only the bounded frame consumed by the Metal renderer.
    ///
    /// Production rendering does not display `glyphField`, so avoiding the
    /// diagnostic grid here removes a second pixel pass and per-frame String
    /// construction while retaining live sequence, checksum, and sampled-pixel
    /// health values.
    static func rendererSample(
        descriptor: IdleScreenCameraFrameDescriptor,
        pixels: UnsafeRawBufferPointer
    ) -> IdleScreenCameraGlyphSample? {
        guard (try? descriptor.validated()) != nil,
              descriptor.pixelFormat == .bgra8Unorm,
              let width = Int(exactly: descriptor.width),
              let height = Int(exactly: descriptor.height),
              let bytesPerRow = Int(exactly: descriptor.bytesPerRow),
              let rendererFrame = IdleScreenRendererCameraFrame.samplingBGRA(
                  producerStreamEpoch: descriptor.streamEpoch,
                  sequence: descriptor.sequence,
                  width: width,
                  height: height,
                  bytesPerRow: bytesPerRow,
                  pixels: pixels,
                  columns: IdleScreenRendererCameraFrame.productionColumns,
                  rows: IdleScreenRendererCameraFrame.productionRows
              ) else {
            return nil
        }

        return IdleScreenCameraGlyphSample(
            producerStreamEpoch: descriptor.streamEpoch,
            sequence: descriptor.sequence,
            glyphField: "",
            checksum: rendererFrame.checksum,
            sampledPixelCount: rendererFrame.sampledPixelCount,
            rendererFrame: rendererFrame
        )
    }

    static func sample(
        descriptor: IdleScreenCameraFrameDescriptor,
        pixels: UnsafeRawBufferPointer,
        columns requestedColumns: Int,
        rows requestedRows: Int
    ) -> IdleScreenCameraGlyphSample? {
        guard (try? descriptor.validated()) != nil,
              descriptor.pixelFormat == .bgra8Unorm,
              requestedColumns > 0,
              requestedRows > 0 else {
            return nil
        }

        let columns = min(requestedColumns, maximumColumns)
        let rows = min(requestedRows, maximumRows)
        guard let width = Int(exactly: descriptor.width),
              let height = Int(exactly: descriptor.height),
              let bytesPerRow = Int(exactly: descriptor.bytesPerRow),
              let diagnosticFrame = IdleScreenRendererCameraFrame.samplingBGRA(
                  producerStreamEpoch: descriptor.streamEpoch,
                  sequence: descriptor.sequence,
                  width: width,
                  height: height,
                  bytesPerRow: bytesPerRow,
                  pixels: pixels,
                  columns: columns,
                  rows: rows
              ),
              let rendererFrame = IdleScreenRendererCameraFrame.samplingBGRA(
                  producerStreamEpoch: descriptor.streamEpoch,
                  sequence: descriptor.sequence,
                  width: width,
                  height: height,
                  bytesPerRow: bytesPerRow,
                  pixels: pixels,
                  columns: IdleScreenRendererCameraFrame.productionColumns,
                  rows: IdleScreenRendererCameraFrame.productionRows
              ) else {
            return nil
        }

        var field = String()
        field.reserveCapacity(rows * (columns * 2))

        for row in 0..<rows {
            if row > 0 { field.append("\n") }
            for column in 0..<columns {
                if column > 0 { field.append(" ") }
                let luminance = Int(
                    diagnosticFrame.luminance[row * columns + column]
                )
                let glyphIndex = min(
                    glyphRamp.count - 1,
                    luminance * glyphRamp.count / 256
                )
                field.append(glyphRamp[glyphIndex])
            }
        }

        return IdleScreenCameraGlyphSample(
            producerStreamEpoch: descriptor.streamEpoch,
            sequence: descriptor.sequence,
            glyphField: field,
            checksum: diagnosticFrame.checksum,
            sampledPixelCount: diagnosticFrame.sampledPixelCount,
            rendererFrame: rendererFrame
        )
    }
}

/// Owns the production saver process's only mailbox read loop.
///
/// `CameraFrameSource.withFrame` takes a stable copy of the full mailbox frame
/// before invoking its callback. Keeping that work on this serial queue means
/// ScreenSaverView animation callbacks only retain an already-bounded 160x90
/// renderer sample. The small state lock is never held while reading or
/// sampling the mailbox, so a display's main thread cannot wait behind that
/// work. Every display view backed by `IdleScreenSaverCameraProcess.shared`
/// reads the same immutable sample.
final class IdleScreenSaverCameraFramePump: @unchecked Sendable {
    typealias MonotonicClock = @Sendable () -> TimeInterval

    private enum LatestState: Sendable {
        case waiting
        case available(IdleScreenCameraGlyphSample)
        case unavailable
    }

    /// Sample the mailbox twice per 30 fps render interval. Matching the
    /// producer and renderer at independent 30 Hz clocks caused phase aliasing:
    /// a render could repeat the previous frame and then skip the next one.
    /// The faster off-main poll keeps mailbox work away from ScreenSaverView's
    /// animation callback while making a fresh producer frame available within
    /// one half-render interval.
    private static let pollingInterval = DispatchTimeInterval.nanoseconds(
        16_666_667
    )
    /// The frame source already owns the one-second stale-frame deadline. This
    /// shorter presentation hold only prevents a recoverable mailbox read gap
    /// from flashing procedural fallback between healthy camera frames.
    /// Authoritative lease loss bypasses the hold and clears immediately.
    private static let transientUnavailableGraceInterval: TimeInterval = 0.25
    private static let logger = Logger(
        subsystem: "com.idlescreen.screensaver",
        category: "CameraFramePump"
    )

    private let runtime: CameraClientRuntime
    private let monotonicClock: MonotonicClock
    private let automaticallyPolls: Bool
    private let queue = DispatchQueue(
        label: "com.idlescreen.screensaver.camera-frame-pump",
        qos: .userInteractive
    )
    private let latestStateLock = NSLock()
    private var latestState: LatestState = .waiting

    // Accessed only on `queue`.
    private var attachedConsumerIdentifiers = Set<String>()
    private var timer: DispatchSourceTimer?
    private var transientUnavailableStartedAt: TimeInterval?
    private var transientUnavailableReason: String?
    private var transientUnavailableReadCount = 0

    init(
        runtime: CameraClientRuntime,
        monotonicClock: @escaping MonotonicClock = {
            ProcessInfo.processInfo.systemUptime
        },
        automaticallyPolls: Bool = true
    ) {
        self.runtime = runtime
        self.monotonicClock = monotonicClock
        self.automaticallyPolls = automaticallyPolls
    }

    @discardableResult
    func attach(consumerIdentifier: String) -> Bool {
        guard runtime.attach(consumerIdentifier: consumerIdentifier) else {
            return false
        }
        queue.async { [self] in
            let inserted = attachedConsumerIdentifiers.insert(
                consumerIdentifier
            ).inserted
            guard inserted else { return }
            if attachedConsumerIdentifiers.count == 1 {
                publish(.waiting)
                startTimer()
            }
        }
        return true
    }

    @discardableResult
    func detach(consumerIdentifier: String) -> Bool {
        let detached = runtime.detach(consumerIdentifier: consumerIdentifier)
        queue.async { [self] in
            guard attachedConsumerIdentifiers.remove(consumerIdentifier) != nil,
                  attachedConsumerIdentifiers.isEmpty else {
                return
            }
            stopTimer()
            publish(.waiting)
        }
        return detached
    }

    func latestSample() -> IdleScreenSaverCameraSampleRead {
        latestStateLock.withLock {
            switch latestState {
            case .waiting:
                .noNewFrame
            case let .available(sample):
                .frame(sample)
            case .unavailable:
                .unavailable
            }
        }
    }

    func pollOnce() {
        queue.sync { readLatestFrame() }
    }

    func synchronize() {
        queue.sync {}
    }

    private func startTimer() {
        guard automaticallyPolls else { return }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: Self.pollingInterval,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.readLatestFrame()
        }
        self.timer = timer
        timer.activate()
    }

    private func stopTimer() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        resetTransientUnavailable()
    }

    private func readLatestFrame() {
        guard !attachedConsumerIdentifiers.isEmpty else { return }
        let read = runtime.frameSource.withFrame { descriptor, pixels in
            IdleScreenCameraGlyphSampler.rendererSample(
                descriptor: descriptor,
                pixels: pixels
            )
        }
        switch read {
        case let .frame(_, sample):
            guard let sample else {
                handleTransientUnavailable(reason: "invalid-renderer-sample")
                return
            }
            reportTransientRecoveryIfNeeded()
            publish(.available(sample))
        case .noNewFrame:
            // Retain the last bounded sample. This matches the prior view
            // behavior while making the same sample available to every
            // display, regardless of which view ticks first.
            break
        case let .unavailable(reason):
            if reason == .leaseUnavailable {
                resetTransientUnavailable()
                publish(.unavailable)
            } else {
                handleTransientUnavailable(reason: Self.reasonToken(reason))
            }
        }
    }

    private func handleTransientUnavailable(reason: String) {
        let retainsCameraSample = latestStateLock.withLock {
            if case .available = latestState { true } else { false }
        }
        guard retainsCameraSample else {
            resetTransientUnavailable()
            publish(.unavailable)
            return
        }

        let now = monotonicClock()
        guard now.isFinite, now >= 0 else {
            resetTransientUnavailable()
            publish(.unavailable)
            return
        }
        if transientUnavailableStartedAt == nil {
            transientUnavailableStartedAt = now
            transientUnavailableReason = reason
            transientUnavailableReadCount = 1
            Self.logger.notice(
                "Camera sample gap started reason=\(reason, privacy: .public)"
            )
            return
        }

        transientUnavailableReadCount += 1
        guard let startedAt = transientUnavailableStartedAt,
              now >= startedAt,
              now - startedAt >= Self.transientUnavailableGraceInterval else {
            return
        }
        let durationMilliseconds = Int((now - startedAt) * 1_000)
        Self.logger.error(
            "Camera sample gap committed fallback reason=\(reason, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public) reads=\(self.transientUnavailableReadCount, privacy: .public)"
        )
        resetTransientUnavailable()
        publish(.unavailable)
    }

    private func reportTransientRecoveryIfNeeded() {
        guard let startedAt = transientUnavailableStartedAt else { return }
        let now = monotonicClock()
        let durationMilliseconds = now.isFinite && now >= startedAt
            ? Int((now - startedAt) * 1_000)
            : -1
        let reason = transientUnavailableReason ?? "unknown"
        Self.logger.notice(
            "Camera sample gap recovered reason=\(reason, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public) reads=\(self.transientUnavailableReadCount, privacy: .public)"
        )
        resetTransientUnavailable()
    }

    private func resetTransientUnavailable() {
        transientUnavailableStartedAt = nil
        transientUnavailableReason = nil
        transientUnavailableReadCount = 0
    }

    private static func reasonToken(
        _ reason: CameraFrameSourceUnavailableReason
    ) -> String {
        switch reason {
        case .leaseUnavailable: "lease-unavailable"
        case .invalidTransportIdentifier: "invalid-transport"
        case .regressiveProducerEpoch: "regressive-epoch"
        case .mappingFailure: "mapping-failure"
        case .invalidFrameDescriptor: "invalid-descriptor"
        case .wrongProducerEpoch: "wrong-epoch"
        case .outOfOrderSequence: "out-of-order-sequence"
        case .firstFrameTimedOut: "first-frame-timeout"
        case .staleFrame: "stale-frame"
        case .invalidMonotonicClock: "invalid-clock"
        }
    }

    private func publish(_ state: LatestState) {
        latestStateLock.withLock {
            latestState = state
        }
    }
}

final class IdleScreenSaverCameraClient {
    typealias AttachmentHandler = (String) -> Bool
    typealias SampleHandler = (Int, Int) -> IdleScreenSaverCameraSampleRead

    private let attachHandler: AttachmentHandler
    private let detachHandler: AttachmentHandler
    private let sampleHandler: SampleHandler

    init(
        attach: @escaping AttachmentHandler,
        detach: @escaping AttachmentHandler,
        sample: @escaping SampleHandler
    ) {
        attachHandler = attach
        detachHandler = detach
        sampleHandler = sample
    }

    convenience init(runtime: CameraClientRuntime) {
        let framePump = IdleScreenSaverCameraFramePump(runtime: runtime)
        self.init(
            attach: { identifier in
                framePump.attach(consumerIdentifier: identifier)
            },
            detach: { identifier in
                framePump.detach(consumerIdentifier: identifier)
            },
            sample: { _, _ in
                framePump.latestSample()
            }
        )
    }

    @discardableResult
    func attach(consumerIdentifier: String) -> Bool {
        attachHandler(consumerIdentifier)
    }

    @discardableResult
    func detach(consumerIdentifier: String) -> Bool {
        detachHandler(consumerIdentifier)
    }

    func sample(columns: Int, rows: Int) -> IdleScreenSaverCameraSampleRead {
        sampleHandler(columns, rows)
    }
}

final class IdleScreenSaverCameraConsumer {
    private let client: IdleScreenSaverCameraClient
    private let identifier: String
    private var attached = false

    init(client: IdleScreenSaverCameraClient, identifier: String) {
        self.client = client
        self.identifier = identifier
    }

    deinit {
        guard attached else { return }
        _ = client.detach(consumerIdentifier: identifier)
    }

    func attach() {
        guard !attached else { return }
        attached = client.attach(consumerIdentifier: identifier)
    }

    func detach() {
        guard attached else { return }
        _ = client.detach(consumerIdentifier: identifier)
        attached = false
    }

    func sample(columns: Int, rows: Int) -> IdleScreenSaverCameraSampleRead {
        guard attached else { return .unavailable }
        return client.sample(columns: columns, rows: rows)
    }
}

struct IdleScreenSaverCameraBootstrapOutcome {
    let status: CameraClientBootstrapStatus
    let client: IdleScreenSaverCameraClient?
}

@MainActor
final class IdleScreenSaverCameraProcess {
    typealias Bootstrap = @MainActor ([String: Any]) ->
        IdleScreenSaverCameraBootstrapOutcome

    static let shared = IdleScreenSaverCameraProcess(
        infoDictionary: Bundle(for: IdleScreenSaverView.self).infoDictionary ?? [:]
    )

    let status: CameraClientBootstrapStatus
    let client: IdleScreenSaverCameraClient?

    init(
        infoDictionary: [String: Any],
        bootstrap: Bootstrap = IdleScreenSaverCameraProcess.bootstrap
    ) {
        let outcome = bootstrap(infoDictionary)
        status = outcome.status
        client = outcome.client
    }

    private static func bootstrap(
        infoDictionary: [String: Any]
    ) -> IdleScreenSaverCameraBootstrapOutcome {
        let result = CameraClientBootstrap.makeRuntime(
            infoDictionary: infoDictionary
        )
        return IdleScreenSaverCameraBootstrapOutcome(
            status: result.status,
            client: result.runtime.map(IdleScreenSaverCameraClient.init(runtime:))
        )
    }
}
