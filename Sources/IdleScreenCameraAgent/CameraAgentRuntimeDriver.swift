import Foundation
import IdleScreenCamera
import IdleScreenCore

public struct CameraAgentRuntimeDeviceSnapshot: Equatable, Sendable {
    public let inventoryGeneration: UInt64
    public let devices: [CameraCaptureDeviceDescriptor]
    public let preference: IdleScreenCameraSelection
    public let preferredDeviceIdentifier: String?
    public let resolvedDeviceIdentifier: String?
    public let activeDeviceIdentifier: String?
    public let reconfigurationPending: Bool

    public init(
        inventoryGeneration: UInt64,
        devices: [CameraCaptureDeviceDescriptor],
        preference: IdleScreenCameraSelection,
        preferredDeviceIdentifier: String? = nil,
        resolvedDeviceIdentifier: String?,
        activeDeviceIdentifier: String?,
        reconfigurationPending: Bool
    ) {
        self.inventoryGeneration = inventoryGeneration
        self.devices = devices
        self.preference = preference
        self.preferredDeviceIdentifier = preferredDeviceIdentifier
        self.resolvedDeviceIdentifier = resolvedDeviceIdentifier
        self.activeDeviceIdentifier = activeDeviceIdentifier
        self.reconfigurationPending = reconfigurationPending
    }
}

/// The serialized executor used by the runtime boundary. `enqueue` must never
/// execute its operation inline, and delayed work must run on the same serial
/// execution context as immediate work.
public protocol CameraAgentRuntimeScheduledWork: AnyObject, Sendable {
    func cancel()
}

public protocol CameraAgentRuntimeScheduling: Sendable {
    func enqueue(_ operation: @escaping @Sendable () -> Void)
    @discardableResult
    func enqueue(
        after delay: TimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) -> any CameraAgentRuntimeScheduledWork
}

public final class DispatchCameraAgentRuntimeScheduler: CameraAgentRuntimeScheduling,
    @unchecked Sendable {
    private final class ScheduledWork: CameraAgentRuntimeScheduledWork,
        @unchecked Sendable {
        private let lock = NSLock()
        private var source: DispatchSourceTimer?
        private var operation: (@Sendable () -> Void)?
        // Delayed work whose caller discards its cancellation token still has
        // to live until it fires. Cancellation breaks this private cycle and
        // releases the closure immediately instead of leaving it on the queue.
        private var lifetime: ScheduledWork?

        init(
            queue: DispatchQueue,
            delay: TimeInterval,
            operation: @escaping @Sendable () -> Void
        ) {
            self.operation = operation
            let source = DispatchSource.makeTimerSource(queue: queue)
            self.source = source
            lifetime = self
            source.setEventHandler { [weak self] in
                self?.fire()
            }
            source.schedule(deadline: .now() + delay)
            source.activate()
        }

        func cancel() {
            lock.withLock {
                operation = nil
                source?.setEventHandler {}
                source?.cancel()
                source = nil
                lifetime = nil
            }
        }

        private func fire() {
            let operation = lock.withLock { () -> (@Sendable () -> Void)? in
                let operation = self.operation
                self.operation = nil
                source?.setEventHandler {}
                source?.cancel()
                source = nil
                lifetime = nil
                return operation
            }
            operation?()
        }
    }

    private let queue: DispatchQueue

    public init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.idlescreen.camera-agent.runtime",
            qos: .userInitiated
        )
    ) {
        self.queue = queue
    }

    public func enqueue(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }

    @discardableResult
    public func enqueue(
        after delay: TimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) -> any CameraAgentRuntimeScheduledWork {
        ScheduledWork(queue: queue, delay: delay, operation: operation)
    }
}

public protocol CameraAgentAuthorizationRequesting: Sendable {
    func requestVideoAccess(
        completion: @escaping @Sendable (CameraAgentAuthorization) -> Void
    )
}

/// Async stop is deliberate: the platform session's stop operation is blocking, so
/// it must not stall the runtime queue that observes the two-second contract.
public protocol CameraAgentRuntimeCaptureControlling: AnyObject, Sendable {
    func start(
        _ request: CameraCaptureRequest,
        frameHandler: @escaping @Sendable (CameraCaptureFrame) -> Void,
        eventHandler: @escaping @Sendable (CameraCaptureSessionEvent) -> Void
    ) throws -> CameraCaptureDeviceDescriptor

    func stop(completion: @escaping @Sendable () -> Void)
}

/// Adapts the single process-owned capture controller without constructing a
/// second controller or session.
public final class CameraAgentCaptureControllerAdapter: CameraAgentRuntimeCaptureControlling,
    @unchecked Sendable {
    private let controller: CameraCaptureSessionController
    private let stopQueue: DispatchQueue

    public init(
        controller: CameraCaptureSessionController,
        stopQueue: DispatchQueue = DispatchQueue(
            label: "com.idlescreen.camera-agent.capture-stop",
            qos: .userInitiated
        )
    ) {
        self.controller = controller
        self.stopQueue = stopQueue
    }

    public func start(
        _ request: CameraCaptureRequest,
        frameHandler: @escaping @Sendable (CameraCaptureFrame) -> Void,
        eventHandler: @escaping @Sendable (CameraCaptureSessionEvent) -> Void
    ) throws -> CameraCaptureDeviceDescriptor {
        try controller.start(
            request,
            frameHandler: frameHandler,
            eventHandler: eventHandler
        )
    }

    public func stop(completion: @escaping @Sendable () -> Void) {
        stopQueue.async { [controller] in
            controller.stop()
            completion()
        }
    }
}

/// The mailbox writer plugs in here. The runtime passes the capture-owned
/// `CameraCaptureFrame` reference through unchanged, so this boundary does not
/// allocate or copy pixel storage.
public protocol CameraAgentRuntimeFramePublishing: AnyObject, Sendable {
    var transportIdentifier: String { get }

    func configure(
        generation: UInt64,
        configuration: CameraAgentStreamConfiguration
    ) throws

    func publish(
        _ frame: CameraCaptureFrame,
        generation: UInt64
    ) throws -> IdleScreenCameraFrameDescriptor
    func finish(generation: UInt64) throws
}

public protocol CameraFrameMailboxWriting: AnyObject, Sendable {
    var mailboxURL: URL { get }
    func startStream(streamEpoch: UInt64) throws
    func publish(_ frame: CameraCaptureFrame) throws -> IdleScreenCameraFrameDescriptor
    func stopStream() throws
    func invalidate() throws
}

extension CameraFrameMailboxWriter: CameraFrameMailboxWriting {}

public enum CameraFrameMailboxRuntimePublisherError: Swift.Error, Equatable, Sendable {
    case invalidMailboxURL
    case streamAlreadyActive(UInt64)
    case streamNotActive
    case generationMismatch(expected: UInt64, actual: UInt64)
}

/// Production mailbox adapter. Only the fixed leaf is disclosed to XPC peers;
/// the App Group container's absolute path never crosses the wire.
public final class CameraFrameMailboxRuntimePublisher: CameraAgentRuntimeFramePublishing,
    @unchecked Sendable {
    public let transportIdentifier: String

    private let writer: any CameraFrameMailboxWriting
    private let lock = NSLock()
    private var activeCaptureGeneration: UInt64?
    private var activeProducerStreamEpoch: UInt64?

    public init?(writer: any CameraFrameMailboxWriting) {
        let mailboxURL = writer.mailboxURL
        let leaf = mailboxURL.lastPathComponent
        guard mailboxURL.isFileURL,
              !leaf.isEmpty,
              leaf != ".",
              leaf != "..",
              !leaf.contains("/"),
              IdleScreenCameraBeginStreamReply(
                accepted: true,
                errorCode: .none,
                errorMessage: nil,
                leaseIdentifier: "mailbox-validation",
                producerStreamEpoch: 1,
                transportIdentifier: leaf
              ) != nil else {
            return nil
        }
        self.writer = writer
        transportIdentifier = leaf
    }

    public func configure(
        generation: UInt64,
        configuration: CameraAgentStreamConfiguration
    ) throws {
        try lock.withLock {
            guard let activeCaptureGeneration else {
                try writer.startStream(
                    streamEpoch: configuration.producerStreamEpoch
                )
                self.activeCaptureGeneration = generation
                activeProducerStreamEpoch = configuration.producerStreamEpoch
                return
            }
            throw CameraFrameMailboxRuntimePublisherError.streamAlreadyActive(
                activeCaptureGeneration
            )
        }
    }

    public func publish(
        _ frame: CameraCaptureFrame,
        generation: UInt64
    ) throws -> IdleScreenCameraFrameDescriptor {
        try lock.withLock {
            guard let activeCaptureGeneration,
                  let activeProducerStreamEpoch else {
                throw CameraFrameMailboxRuntimePublisherError.streamNotActive
            }
            guard activeCaptureGeneration == generation else {
                throw CameraFrameMailboxRuntimePublisherError.generationMismatch(
                    expected: activeCaptureGeneration,
                    actual: generation
                )
            }
            let descriptor = try writer.publish(frame)
            guard descriptor.streamEpoch == activeProducerStreamEpoch else {
                throw CameraFrameMailboxRuntimePublisherError.generationMismatch(
                    expected: activeProducerStreamEpoch,
                    actual: descriptor.streamEpoch
                )
            }
            return descriptor
        }
    }

    public func finish(generation: UInt64) throws {
        try lock.withLock {
            guard let activeCaptureGeneration else { return }
            guard activeCaptureGeneration == generation else {
                throw CameraFrameMailboxRuntimePublisherError.generationMismatch(
                    expected: activeCaptureGeneration,
                    actual: generation
                )
            }
            try writer.stopStream()
            self.activeCaptureGeneration = nil
            activeProducerStreamEpoch = nil
        }
    }

    public func invalidate() throws {
        try lock.withLock {
            try writer.invalidate()
            activeCaptureGeneration = nil
            activeProducerStreamEpoch = nil
        }
    }
}

public protocol CameraAgentRuntimeEventReceiving: AnyObject, Sendable {
    func receiveAuthorizationResult(_ result: CameraAgentAuthorization)
    func receiveCaptureDriverEvent(_ event: CameraAgentCaptureDriverEvent)
}

extension CameraAgentService: CameraAgentRuntimeEventReceiving {}

/// Bridges the pure service actions to permission, capture, and frame I/O.
///
/// The service invokes `perform` while holding its state lock. Every action is
/// therefore enqueued before returning; all callbacks are also funneled through
/// the same serial scheduler before they can re-enter the service.
public final class CameraAgentRuntimeDriver: CameraAgentServiceDriver, @unchecked Sendable {
    public static let maximumStopLatency = CameraAgentStateMachine.maximumStopLatency
    public static let maximumFirstFrameLatency: TimeInterval = 3
    /// Two seconds tolerates dozens of missed frames at supported rates while
    /// still recovering promptly from a capture session that silently stalls.
    public static let maximumFrameStallLatency: TimeInterval = 2

    private static let mediaServicesWereResetErrorCode = -11_819

    private final class StopAttempt: @unchecked Sendable {
        var isResolved = false
    }

    private let scheduler: any CameraAgentRuntimeScheduling
    private let permissionRequester: any CameraAgentAuthorizationRequesting
    private let captureController: any CameraAgentRuntimeCaptureControlling
    private let framePublisher: any CameraAgentRuntimeFramePublishing
    private let fixedTransportIdentifier: String
    private let mediaServicesResetErrorDomain: String?
    private let receiverLock = NSLock()
    private let inventoryCallbackLock = NSLock()
    private let deviceSnapshotLock = NSLock()
    private weak var receiver: (any CameraAgentRuntimeEventReceiving)?
    private var acceptsInventoryCallbacks = true
    private var publishedDeviceSnapshot = CameraAgentRuntimeDeviceSnapshot(
        inventoryGeneration: 0,
        devices: [],
        preference: .automatic,
        resolvedDeviceIdentifier: nil,
        activeDeviceIdentifier: nil,
        reconfigurationPending: false
    )

    // Access is confined to `scheduler`.
    private var configuredGeneration: UInt64?
    private var configuredStream: CameraAgentStreamConfiguration?
    private var isPublisherConfigured = false
    private var activeGeneration: UInt64?
    private var selectedDeviceIdentifier: String?
    private var lastCaptureSequence: UInt64?
    private var publishedProducerStreamEpoch: UInt64?
    private var lastPublishedSequence: UInt64?
    private var hasPublishedFrameForCapture = false
    private var frameDeadlineSerial: UInt64 = 0
    private var frameDeadlineWork: (any CameraAgentRuntimeScheduledWork)?
    private var frameDeadlineFailureGeneration: UInt64?
    private var stoppingGeneration: UInt64?
    private var stopAttempt: StopAttempt?
    private var inventoryGeneration: UInt64 = 0
    private var latestDeviceInventory: CameraDeviceInventorySnapshot?
    private var inventoryAvailability: Bool?
    private var cameraSelection: IdleScreenCameraSelection = .automatic
    private var preferredCameraDeviceIdentifier: String?
    private var resolvedDeviceIdentifier: String?
    private var deviceReconfigurationPending = false

    public init?(
        scheduler: any CameraAgentRuntimeScheduling = DispatchCameraAgentRuntimeScheduler(),
        permissionRequester: any CameraAgentAuthorizationRequesting,
        captureController: any CameraAgentRuntimeCaptureControlling,
        framePublisher: any CameraAgentRuntimeFramePublishing,
        mediaServicesResetErrorDomain: String? = nil
    ) {
        let transportIdentifier = framePublisher.transportIdentifier
        guard Self.isValidTransportIdentifier(transportIdentifier) else {
            return nil
        }
        self.scheduler = scheduler
        self.permissionRequester = permissionRequester
        self.captureController = captureController
        self.framePublisher = framePublisher
        fixedTransportIdentifier = transportIdentifier
        self.mediaServicesResetErrorDomain = mediaServicesResetErrorDomain
    }

    public convenience init?(
        scheduler: any CameraAgentRuntimeScheduling = DispatchCameraAgentRuntimeScheduler(),
        permissionRequester: any CameraAgentAuthorizationRequesting,
        captureController: CameraCaptureSessionController,
        framePublisher: any CameraAgentRuntimeFramePublishing,
        mediaServicesResetErrorDomain: String? = nil
    ) {
        self.init(
            scheduler: scheduler,
            permissionRequester: permissionRequester,
            captureController: CameraAgentCaptureControllerAdapter(
                controller: captureController
            ),
            framePublisher: framePublisher,
            mediaServicesResetErrorDomain: mediaServicesResetErrorDomain
        )
    }

    public func bind(to receiver: any CameraAgentRuntimeEventReceiving) {
        receiverLock.withLock {
            self.receiver = receiver
        }
    }

    public func transportIdentifier(
        for configuration: CameraAgentStreamConfiguration
    ) -> String? {
        _ = configuration
        guard framePublisher.transportIdentifier == fixedTransportIdentifier else {
            return nil
        }
        return fixedTransportIdentifier
    }

    public func perform(
        _ action: CameraAgentAction,
        configuration: CameraAgentStreamConfiguration?
    ) {
        scheduler.enqueue { [weak self] in
            self?.execute(action, configuration: configuration)
        }
    }

    public func receiveSleep() {
        scheduler.enqueue { [weak self] in
            guard let self else { return }
            self.cancelFrameDeadline()
            self.emit(.sleep)
        }
    }

    public func receiveWake() {
        scheduler.enqueue { [weak self] in
            self?.emit(.wake)
        }
    }

    /// Routes process-lifetime inventory changes onto the same serialized
    /// executor as service actions and capture callbacks.
    public func receiveDeviceInventory(_ snapshot: CameraDeviceInventorySnapshot) {
        guard inventoryCallbackLock.withLock({ acceptsInventoryCallbacks }) else {
            return
        }
        scheduler.enqueue { [weak self] in
            guard let self else { return }
            self.inventoryCallbackLock.lock()
            guard self.acceptsInventoryCallbacks else {
                self.inventoryCallbackLock.unlock()
                return
            }
            defer { self.inventoryCallbackLock.unlock() }
            self.reconcileDeviceInventory(snapshot)
        }
    }

    public func receiveCameraSelection(_ selection: IdleScreenCameraSelection) {
        receiveCameraConfiguration(IdleScreenCameraConfiguration(
            selection: selection
        ))
    }

    public func receiveCameraConfiguration(
        _ configuration: IdleScreenCameraConfiguration
    ) {
        guard inventoryCallbackLock.withLock({ acceptsInventoryCallbacks }) else {
            return
        }
        scheduler.enqueue { [weak self] in
            guard let self,
                  self.inventoryCallbackLock.withLock({
                      self.acceptsInventoryCallbacks
                  }) else {
                return
            }
            guard self.cameraSelection != configuration.selection
                    || self.preferredCameraDeviceIdentifier
                        != configuration.preferredDeviceIdentifier else {
                return
            }
            self.cameraSelection = configuration.selection
            self.preferredCameraDeviceIdentifier =
                configuration.preferredDeviceIdentifier
            self.reconcileCameraSelection()
        }
    }

    public func cameraDeviceSnapshot() -> CameraAgentRuntimeDeviceSnapshot {
        deviceSnapshotLock.withLock { publishedDeviceSnapshot }
    }

    /// Fences callbacks already queued when the process begins shutdown.
    public func cancelDeviceInventoryCallbacks() {
        inventoryCallbackLock.withLock {
            acceptsInventoryCallbacks = false
        }
        scheduler.enqueue { [weak self] in
            self?.cancelFrameDeadline()
        }
    }

    private func execute(
        _ action: CameraAgentAction,
        configuration: CameraAgentStreamConfiguration?
    ) {
        switch action {
        case .requestPermission:
            requestPermission()

        case let .configureCapture(generation):
            configure(generation: generation, configuration: configuration)

        case let .startCapture(generation):
            start(generation: generation, configuration: configuration)

        case let .stopCapture(generation, within):
            stop(generation: generation, within: within)

        case let .scheduleRecovery(generation, after):
            scheduleRecovery(generation: generation, after: after)

        case .publish:
            break
        }
    }

    private func requestPermission() {
        permissionRequester.requestVideoAccess { [weak self] result in
            self?.scheduler.enqueue { [weak self] in
                self?.authorizationReceiver()?.receiveAuthorizationResult(result)
            }
        }
    }

    private func configure(
        generation: UInt64,
        configuration: CameraAgentStreamConfiguration?
    ) {
        guard generation > 0,
              activeGeneration == nil,
              configuredGeneration == nil,
              let configuration else {
            return
        }

        configuredGeneration = generation
        configuredStream = configuration
        isPublisherConfigured = false
        cancelFrameDeadline()
        frameDeadlineFailureGeneration = nil
        lastCaptureSequence = nil
        hasPublishedFrameForCapture = false
        if publishedProducerStreamEpoch != configuration.producerStreamEpoch {
            publishedProducerStreamEpoch = configuration.producerStreamEpoch
            lastPublishedSequence = nil
        }
        do {
            try framePublisher.configure(
                generation: generation,
                configuration: configuration
            )
            isPublisherConfigured = true
        } catch {
            emit(.runtimeError(
                generation: generation,
                code: "frame-configure-failed"
            ))
        }
    }

    private func start(
        generation: UInt64,
        configuration: CameraAgentStreamConfiguration?
    ) {
        guard activeGeneration == nil,
              stoppingGeneration == nil,
              configuredGeneration == generation,
              isPublisherConfigured,
              let configuredStream,
              configuration == configuredStream else {
            return
        }

        activeGeneration = generation
        do {
            let selectedDevice = try captureController.start(
                CameraCaptureRequest(
                    width: configuredStream.maximumWidth,
                    height: configuredStream.maximumHeight,
                    maximumFramesPerSecond: configuredStream.maximumFramesPerSecond,
                    preferredDeviceID: resolvedDeviceIdentifier
                ),
                frameHandler: { [weak self] frame in
                    self?.scheduler.enqueue { [weak self] in
                        self?.receive(frame: frame, generation: generation)
                    }
                },
                eventHandler: { [weak self] event in
                    self?.scheduler.enqueue { [weak self] in
                        self?.receive(sessionEvent: event, generation: generation)
                    }
                }
            )
            selectedDeviceIdentifier = selectedDevice.uniqueID
            publishDeviceSnapshot()
            emit(.captureStarted(generation: generation))
            scheduleFirstFrameDeadline(generation: generation)
        } catch let failure as CameraCaptureSessionControllerError {
            handleStartFailure(failure, generation: generation)
        } catch {
            emit(.recoveryFailure(
                generation: generation,
                cause: .startFailure,
                code: "capture-start-failed"
            ))
        }
    }

    private enum FrameDeadlineKind: Equatable, Sendable {
        case firstFrame
        case nextFrame(afterSequence: UInt64)
    }

    private func scheduleFirstFrameDeadline(generation: UInt64) {
        scheduleFrameDeadline(
            generation: generation,
            kind: .firstFrame,
            after: Self.maximumFirstFrameLatency
        )
    }

    private func scheduleFrameStallDeadline(
        generation: UInt64,
        afterSequence sequence: UInt64
    ) {
        scheduleFrameDeadline(
            generation: generation,
            kind: .nextFrame(afterSequence: sequence),
            after: Self.maximumFrameStallLatency
        )
    }

    private func scheduleFrameDeadline(
        generation: UInt64,
        kind: FrameDeadlineKind,
        after delay: TimeInterval
    ) {
        frameDeadlineWork?.cancel()
        frameDeadlineSerial &+= 1
        let deadlineSerial = frameDeadlineSerial
        frameDeadlineWork = scheduler.enqueue(after: delay) { [weak self] in
            guard let self,
                  self.inventoryCallbackLock.withLock({
                      self.acceptsInventoryCallbacks
                  }),
                  self.frameDeadlineSerial == deadlineSerial,
                  self.activeGeneration == generation,
                  self.stoppingGeneration == nil,
                  self.frameDeadlineFailureGeneration != generation else {
                return
            }

            let failure: (cause: CameraCaptureRecoveryCause, code: String)?
            switch kind {
            case .firstFrame where !self.hasPublishedFrameForCapture:
                failure = (.firstFrameTimeout, "capture-first-frame-timeout")
            case let .nextFrame(afterSequence)
                where self.hasPublishedFrameForCapture
                    && self.lastPublishedSequence == afterSequence:
                failure = (.frameStall, "capture-frame-stall")
            case .firstFrame, .nextFrame:
                failure = nil
            }
            guard let failure else { return }

            self.frameDeadlineWork = nil
            self.frameDeadlineFailureGeneration = generation
            self.emit(.recoveryFailure(
                generation: generation,
                cause: failure.cause,
                code: failure.code
            ))
        }
    }

    private func cancelFrameDeadline() {
        frameDeadlineSerial &+= 1
        frameDeadlineWork?.cancel()
        frameDeadlineWork = nil
    }

    private func scheduleRecovery(generation: UInt64, after delay: TimeInterval) {
        guard let maximumDelay = CameraCaptureRecoveryPolicy.boundedBackoffDelays.last,
              generation > 0,
              delay.isFinite,
              delay > 0,
              delay <= maximumDelay else {
            return
        }
        scheduler.enqueue(after: delay) { [weak self] in
            self?.emit(.recoveryRetryDeadlineReached(generation: generation))
        }
    }

    private func stop(generation: UInt64, within: TimeInterval) {
        guard activeGeneration == generation || configuredGeneration == generation,
              stoppingGeneration == nil else {
            return
        }
        guard within.isFinite,
              within > 0,
              within <= Self.maximumStopLatency else {
            emit(.runtimeError(generation: generation, code: "invalid-stop-deadline"))
            return
        }

        cancelFrameDeadline()
        stoppingGeneration = generation
        let attempt = StopAttempt()
        stopAttempt = attempt

        scheduler.enqueue(after: within) { [weak self, weak attempt] in
            guard let self,
                  let attempt,
                  self.stopAttempt === attempt,
                  !attempt.isResolved else {
                return
            }
            self.emit(.runtimeError(
                generation: generation,
                code: "capture-stop-timeout"
            ))
            self.resolveStop(generation: generation, attempt: attempt)
        }

        captureController.stop { [weak self, weak attempt] in
            self?.scheduler.enqueue { [weak self, weak attempt] in
                guard let self,
                      let attempt else {
                    return
                }
                self.resolveStop(generation: generation, attempt: attempt)
            }
        }
    }

    private func resolveStop(generation: UInt64, attempt: StopAttempt) {
        guard stopAttempt === attempt,
              !attempt.isResolved else {
            return
        }
        attempt.isResolved = true
        do {
            try framePublisher.finish(generation: generation)
        } catch {
            emit(.runtimeError(
                generation: generation,
                code: "frame-finish-failed"
            ))
        }
        configuredGeneration = nil
        configuredStream = nil
        isPublisherConfigured = false
        activeGeneration = nil
        selectedDeviceIdentifier = nil
        lastCaptureSequence = nil
        hasPublishedFrameForCapture = false
        frameDeadlineFailureGeneration = nil
        stoppingGeneration = nil
        stopAttempt = nil
        let shouldPublishDeviceAvailable = deviceReconfigurationPending
            && resolvedDeviceIdentifier != nil
        deviceReconfigurationPending = false
        if shouldPublishDeviceAvailable {
            inventoryAvailability = true
        }
        publishDeviceSnapshot()
        if shouldPublishDeviceAvailable {
            emit(.deviceAvailable)
        }
        emit(.captureStopped(generation: generation))
    }

    private func receive(frame: CameraCaptureFrame, generation: UInt64) {
        let sequence = frame.metadata.sequence
        guard activeGeneration == generation,
              stoppingGeneration == nil,
              frameDeadlineFailureGeneration != generation,
              sequence > 0,
              lastCaptureSequence.map({ sequence > $0 }) ?? true else {
            return
        }
        guard frame.metadata.presentationTimeSeconds.isFinite,
              frame.metadata.presentationTimeSeconds > 0 else {
            emit(.runtimeError(
                generation: generation,
                code: "invalid-frame-timestamp"
            ))
            return
        }

        do {
            let descriptor = try framePublisher
                .publish(frame, generation: generation)
                .validated()
            guard descriptor.streamEpoch == configuredStream?.producerStreamEpoch,
                  lastPublishedSequence.map({ descriptor.sequence > $0 }) ?? true else {
                emit(.runtimeError(
                    generation: generation,
                    code: "invalid-frame-descriptor"
                ))
                return
            }
            let isFirstFrame = !hasPublishedFrameForCapture
            lastCaptureSequence = sequence
            lastPublishedSequence = descriptor.sequence
            hasPublishedFrameForCapture = true
            scheduleFrameStallDeadline(
                generation: generation,
                afterSequence: descriptor.sequence
            )
            emit(isFirstFrame
                ? .firstFrame(generation: generation, sequence: descriptor.sequence)
                : .nextFrame(generation: generation, sequence: descriptor.sequence))
        } catch {
            emit(.runtimeError(generation: generation, code: "frame-publish-failed"))
        }
    }

    private func receive(
        sessionEvent: CameraCaptureSessionEvent,
        generation: UInt64
    ) {
        guard activeGeneration == generation,
              stoppingGeneration == nil else {
            return
        }

        switch sessionEvent {
        case .deviceDisconnected, .deviceConnected, .interruptionEnded:
            // The process-lifetime inventory monitor is authoritative. Session
            // notifications and interruption-end hints are intentionally
            // ignored to prevent duplicate or false availability transitions.
            break

        case .interrupted:
            emit(.interrupted(generation: generation))

        case let .runtimeError(domain, code):
            let failureCode = "capture-runtime-\(code)"
            if domain == mediaServicesResetErrorDomain,
               code == Self.mediaServicesWereResetErrorCode {
                emit(.recoveryFailure(
                    generation: generation,
                    cause: .mediaServicesReset,
                    code: failureCode
                ))
            } else {
                emit(.runtimeError(
                    generation: generation,
                    code: failureCode
                ))
            }
        }
    }

    private func reconcileDeviceInventory(_ snapshot: CameraDeviceInventorySnapshot) {
        guard snapshot.generation > inventoryGeneration else { return }
        inventoryGeneration = snapshot.generation
        latestDeviceInventory = snapshot
        reconcileCameraSelection()
    }

    private func reconcileCameraSelection() {
        guard let inventory = latestDeviceInventory else {
            publishDeviceSnapshot()
            return
        }

        let currentDeviceIdentifier = selectedDeviceIdentifier
            ?? resolvedDeviceIdentifier
        let preference: CameraDeviceSelectionPreference = switch cameraSelection {
        case .automatic:
            .automatic
        case let .device(uniqueID):
            .device(uniqueID: uniqueID)
        }
        switch CameraDeviceSelectionReducer.decision(
            preference: preference,
            preferredDeviceID: preferredCameraDeviceIdentifier,
            currentDeviceID: currentDeviceIdentifier,
            inventory: inventory
        ) {
        case .keepCurrent:
            resolvedDeviceIdentifier = currentDeviceIdentifier
            publishDeviceSnapshot()
            if inventoryAvailability != true,
               !deviceReconfigurationPending,
               stoppingGeneration == nil {
                inventoryAvailability = true
                emit(.deviceAvailable)
            }

        case let .select(device):
            let previouslyAvailable = inventoryAvailability == true
            let resolvedDeviceChanged = resolvedDeviceIdentifier != device.uniqueID
            let changesActiveDevice = activeGeneration != nil
                && selectedDeviceIdentifier != device.uniqueID
            resolvedDeviceIdentifier = device.uniqueID
            if changesActiveDevice {
                deviceReconfigurationPending = true
                inventoryAvailability = false
                publishDeviceSnapshot()
                emit(.deviceUnavailable)
            } else if !previouslyAvailable || resolvedDeviceChanged {
                inventoryAvailability = true
                publishDeviceSnapshot()
                emit(.deviceAvailable)
            } else {
                publishDeviceSnapshot()
            }

        case .unavailable:
            resolvedDeviceIdentifier = nil
            deviceReconfigurationPending = activeGeneration != nil
                || stoppingGeneration != nil
            publishDeviceSnapshot()
            if inventoryAvailability != false {
                inventoryAvailability = false
                emit(.deviceUnavailable)
            }
        }
    }

    private func publishDeviceSnapshot() {
        let inventory = latestDeviceInventory
        let snapshot = CameraAgentRuntimeDeviceSnapshot(
            inventoryGeneration: inventory?.generation ?? 0,
            devices: inventory?.devices ?? [],
            preference: cameraSelection,
            preferredDeviceIdentifier: preferredCameraDeviceIdentifier,
            resolvedDeviceIdentifier: resolvedDeviceIdentifier,
            activeDeviceIdentifier: selectedDeviceIdentifier,
            reconfigurationPending: deviceReconfigurationPending
        )
        deviceSnapshotLock.withLock {
            publishedDeviceSnapshot = snapshot
        }
    }

    private func handleStartFailure(
        _ failure: CameraCaptureSessionControllerError,
        generation: UInt64
    ) {
        switch failure {
        case let .authorizationRequired(authorization):
            authorizationReceiver()?.receiveAuthorizationResult(
                Self.agentAuthorization(authorization)
            )
            emit(.recoveryFailure(
                generation: generation,
                cause: .permissionUnavailable,
                code: "camera-permission-unavailable"
            ))
        case .noVideoDevice:
            // Capture is the final authority. Mark the cached selection
            // unavailable so the next authoritative inventory probe emits a
            // device-available transition even if the device IDs are unchanged.
            inventoryAvailability = false
            publishDeviceSnapshot()
            emit(.recoveryFailure(
                generation: generation,
                cause: .noDevice,
                code: "camera-device-unavailable"
            ))
        case .invalidDimensions,
             .invalidFrameRate,
             .sessionAlreadyOwned,
             .alreadyRunning,
             .sessionConfigurationFailed,
             .sessionStartFailed:
            emit(.recoveryFailure(
                generation: generation,
                cause: .startFailure,
                code: "capture-start-failed"
            ))
        }
    }

    private func emit(_ event: CameraAgentCaptureDriverEvent) {
        authorizationReceiver()?.receiveCaptureDriverEvent(event)
    }

    private func authorizationReceiver() -> (any CameraAgentRuntimeEventReceiving)? {
        receiverLock.withLock { receiver }
    }

    private static func agentAuthorization(
        _ authorization: CameraCaptureAuthorization
    ) -> CameraAgentAuthorization {
        switch authorization {
        case .notDetermined:
            .notDetermined
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        }
    }

    private static func isValidTransportIdentifier(_ value: String) -> Bool {
        IdleScreenCameraBeginStreamReply(
            accepted: true,
            errorCode: .none,
            errorMessage: nil,
            leaseIdentifier: "runtime-validation",
            producerStreamEpoch: 1,
            transportIdentifier: value
        ) != nil
    }
}
