import CoreVideo
import Foundation
import IdleScreenCamera
import Testing
@testable import IdleScreenCameraSyntheticAgentCore

@Suite("Synthetic camera-agent composition", .serialized)
struct SyntheticCameraCompositionTests {
    @Test("gate marker is explicit and versioned")
    func markerIsExplicit() {
        #expect(IdleScreenSyntheticGate.markerInfoKey == "IdleScreenSyntheticGateVersion")
        #expect(IdleScreenSyntheticGate.version == 1)
    }

    @Test("synthetic authorization never depends on camera permission")
    func authorizationIsDeterministic() {
        let authorization = SyntheticCameraAuthorizationProvider()
        let reply = LockedAuthorization()

        #expect(authorization.authorizationStatus() == .authorized)
        authorization.requestVideoAccess { reply.set($0) }
        #expect(reply.value == .authorized)
    }

    @Test("capture boundary publishes a deterministic BGRA frame without AVFoundation")
    func capturePublishesDeterministicFrames() throws {
        let scheduler = FakeSyntheticScheduler()
        let capture = SyntheticCameraCaptureController(scheduler: scheduler)
        let received = LockedFrames()

        let selected = try capture.start(
            CameraCaptureRequest(width: 8, height: 4, maximumFramesPerSecond: 10),
            frameHandler: { received.append($0) },
            eventHandler: { _ in }
        )
        #expect(scheduler.repeatingIntervals == [0.1])
        scheduler.fireActiveTick()
        scheduler.fireActiveTick()
        let frames = received.values
        let first = try #require(frames.first)
        let second = try #require(frames.last)

        #expect(selected == SyntheticCameraCaptureController.device)
        #expect(frames.map(\.metadata.sequence) == [1, 2])
        #expect(first.metadata.width == 8)
        #expect(first.metadata.height == 4)
        #expect(first.metadata.bytesPerRow >= 32)
        #expect(first.metadata.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(first.metadata.presentationTimeSeconds == 0.1)
        #expect(firstPixel(first) != firstPixel(second))

        let stopped = LockedCounter()
        capture.stop { stopped.increment() }
        #expect(stopped.value == 0)
        #expect(scheduler.cancelCount == 1)
        scheduler.runEnqueued()
        #expect(stopped.value == 1)
    }

    @Test("capture boundary rejects a second active start")
    func captureRejectsSecondStart() throws {
        let scheduler = FakeSyntheticScheduler()
        let capture = SyntheticCameraCaptureController(scheduler: scheduler)
        _ = try capture.start(
            CameraCaptureRequest(width: 8, height: 4),
            frameHandler: { _ in },
            eventHandler: { _ in }
        )

        #expect(throws: CameraCaptureSessionControllerError.alreadyRunning) {
            try capture.start(
                CameraCaptureRequest(width: 8, height: 4),
                frameHandler: { _ in },
                eventHandler: { _ in }
            )
        }
        capture.stop {}
        scheduler.runEnqueued()
    }

    @Test("stop is idempotent and fences a tick already queued for delivery")
    func stopFencesLateTicks() throws {
        let scheduler = FakeSyntheticScheduler()
        let capture = SyntheticCameraCaptureController(scheduler: scheduler)
        let received = LockedFrames()
        _ = try capture.start(
            CameraCaptureRequest(width: 8, height: 4, maximumFramesPerSecond: 30),
            frameHandler: { received.append($0) },
            eventHandler: { _ in }
        )
        scheduler.fireActiveTick()
        #expect(received.values.count == 1)

        let completions = LockedCounter()
        capture.stop { completions.increment() }
        capture.stop { completions.increment() }
        scheduler.fireCancelledTick()

        #expect(received.values.count == 1)
        #expect(scheduler.cancelCount == 1)
        #expect(completions.value == 0)
        scheduler.runEnqueued()
        #expect(completions.value == 2)
    }

    @Test("frame callback may synchronously stop without deadlocking")
    func frameCallbackMayStop() throws {
        let scheduler = FakeSyntheticScheduler()
        let capture = SyntheticCameraCaptureController(scheduler: scheduler)
        let frames = LockedCounter()
        let stops = LockedCounter()
        _ = try capture.start(
            CameraCaptureRequest(width: 8, height: 4, maximumFramesPerSecond: 30),
            frameHandler: { _ in
                frames.increment()
                capture.stop { stops.increment() }
            },
            eventHandler: { _ in }
        )

        scheduler.fireActiveTick()

        #expect(frames.value == 1)
        #expect(stops.value == 0)
        #expect(scheduler.cancelCount == 1)
        scheduler.runEnqueued()
        #expect(stops.value == 1)
        scheduler.fireCancelledTick()
        #expect(frames.value == 1)
    }

    @Test("synthetic frames cross the production service, runtime, and mailbox beyond the stall watchdog")
    func rollingFramesCrossProductionServiceRuntimeAndMailbox() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "idlescreen-synthetic-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let layout = try IdleScreenCameraFrameMailboxLayout(
            slotCount: 3,
            slotByteCapacity: 8 * 4 * 4
        )
        let writer = try CameraFrameMailboxWriter(
            appGroupContainerURL: temporaryRoot,
            layout: layout
        )
        let publisher = try #require(CameraFrameMailboxRuntimePublisher(writer: writer))
        let captureScheduler = FakeSyntheticScheduler()
        let capture = SyntheticCameraCaptureController(scheduler: captureScheduler)
        let runtimeScheduler = ManualSyntheticRuntimeScheduler()
        let driver = try #require(CameraAgentRuntimeDriver(
            scheduler: runtimeScheduler,
            permissionRequester: SyntheticCameraAuthorizationProvider(),
            captureController: capture,
            framePublisher: publisher
        ))
        let peerPolicy = try #require(CameraAgentPeerPolicy(
            expectedTeamIdentifier: "TEAM123",
            companionBundleIdentifiers: ["com.idlescreen.app"],
            screenSaverBundleIdentifiers: ["com.idlescreen.app.screensaver"]
        ))
        let captureLimits = try #require(CameraAgentCaptureLimits(
            maximumWidth: 8,
            maximumHeight: 4,
            maximumFramesPerSecond: 10,
            maximumMailboxSlotCount: 3
        ))
        let builtService = CameraAgentService(
            peerPolicy: peerPolicy,
            captureLimits: captureLimits,
            leaseTimeToLive: 5,
            initialAuthorization: .authorized,
            initialDeviceAvailability: true,
            producerStreamEpochSeed: 7,
            agentIdentity: try #require(syntheticTestAgentIdentity()),
            authorizationChecker: SyntheticCameraAuthorizationProvider(),
            recoveryClock: { runtimeScheduler.currentTime },
            clock: { Date(timeIntervalSinceReferenceDate: 1_000) },
            identifierGenerator: UUID.init,
            driver: driver
        )
        let service = try #require(builtService)
        driver.bind(to: service)
        let connection = try service.admit(peer: CameraAgentAuthenticatedPeer(
            processIdentifier: 84,
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.idlescreen.app.screensaver"
        ))
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 8,
            maximumHeight: 4,
            maximumFramesPerSecond: 10,
            mailboxSlotCount: 3
        ))
        let diagnosticRequest = try #require(IdleScreenCameraDiagnosticRequest())

        let beginReply = connection.beginStream(request)
        #expect(beginReply.accepted)
        #expect(beginReply.producerStreamEpoch == 7)
        #expect(beginReply.transportIdentifier == writer.mailboxURL.lastPathComponent)
        runtimeScheduler.runAllReady()
        #expect(captureScheduler.repeatingIntervals == [0.1])
        #expect(connection.diagnosticSnapshot(diagnosticRequest).activeLeaseCount == 1)

        let mapping = try IdleScreenCameraFrameMailboxMapping(
            contentsOf: writer.mailboxURL,
            generationLoader: IdleScreenCameraAtomicGenerationLoader(
                mappedByteCount: try layout.expectedFileByteCount()
            ),
            layout: layout
        )
        var observedDescriptors: [IdleScreenCameraFrameDescriptor] = []
        for tick in 1...22 {
            captureScheduler.fireActiveTick()
            runtimeScheduler.runAllReady()
            runtimeScheduler.advance(by: 0.1)

            if [1, 11, 22].contains(tick) {
                observedDescriptors.append(try #require(
                    try mapping.withStableSnapshot { descriptor, _ in descriptor }
                ))
            }
        }

        #expect(runtimeScheduler.currentTime > CameraAgentRuntimeDriver.maximumFrameStallLatency)
        #expect(observedDescriptors.map(\.streamEpoch) == [7, 7, 7])
        #expect(observedDescriptors.map(\.sequence) == [1, 11, 22])
        #expect(observedDescriptors.map(\.timestamp) == [0.1, 1.1, 2.2])
        #expect(runtimeScheduler.executedDelayedOperationCount == 0)
        #expect(runtimeScheduler.pendingDelayedOperationCount == 1)

        let rollingDiagnostic = connection.diagnosticSnapshot(diagnosticRequest)
        #expect(rollingDiagnostic.captureActive)
        #expect(rollingDiagnostic.activeLeaseCount == 1)
        #expect(rollingDiagnostic.producerStreamEpoch == 7)
        #expect(rollingDiagnostic.summary.contains("sequence=22"))
        #expect(!rollingDiagnostic.summary.contains("failed"))

        let leaseIdentifier = try #require(beginReply.leaseIdentifier)
        let endRequest = try #require(IdleScreenCameraEndStreamRequest(
            leaseIdentifier: leaseIdentifier
        ))
        #expect(connection.endStream(endRequest).accepted)
        runtimeScheduler.runAllReady()
        captureScheduler.runEnqueued()
        runtimeScheduler.runAllReady()

        let stoppedDiagnostic = connection.diagnosticSnapshot(diagnosticRequest)
        #expect(!stoppedDiagnostic.captureActive)
        #expect(stoppedDiagnostic.activeLeaseCount == 0)
        #expect(stoppedDiagnostic.summary.contains("status=idle"))
        #expect(connection.invalidate() == 0)
    }

    @Test("two client roles share one producer across scoped reads and recovery")
    func twoClientRolesShareOneProducerAcrossRecovery() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "idlescreen-camera-vertical-slice-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let layout = try IdleScreenCameraFrameMailboxLayout(
            slotCount: 3,
            slotByteCapacity: 8 * 4 * 4
        )
        let writer = try CameraFrameMailboxWriter(
            appGroupContainerURL: temporaryRoot,
            layout: layout
        )
        defer { try? writer.invalidate() }
        let publisher = try #require(CameraFrameMailboxRuntimePublisher(writer: writer))
        let captureScheduler = FakeSyntheticScheduler()
        let capture = InterruptibleSyntheticCaptureController(
            scheduler: captureScheduler
        )
        let runtimeScheduler = ManualSyntheticRuntimeScheduler()
        let driver = try #require(CameraAgentRuntimeDriver(
            scheduler: runtimeScheduler,
            permissionRequester: SyntheticCameraAuthorizationProvider(),
            captureController: capture,
            framePublisher: publisher
        ))
        let peerPolicy = try #require(CameraAgentPeerPolicy(
            expectedTeamIdentifier: "TEAM123",
            companionBundleIdentifiers: ["com.idlescreen.app"],
            screenSaverBundleIdentifiers: ["com.idlescreen.app.screensaver"]
        ))
        let captureLimits = try #require(CameraAgentCaptureLimits(
            maximumWidth: 8,
            maximumHeight: 4,
            maximumFramesPerSecond: 10,
            maximumMailboxSlotCount: 3
        ))
        let builtService = CameraAgentService(
            peerPolicy: peerPolicy,
            captureLimits: captureLimits,
            leaseTimeToLive: 5,
            initialAuthorization: .authorized,
            initialDeviceAvailability: true,
            producerStreamEpochSeed: 7,
            agentIdentity: try #require(syntheticTestAgentIdentity()),
            authorizationChecker: SyntheticCameraAuthorizationProvider(),
            recoveryClock: { runtimeScheduler.currentTime },
            clock: { Date(timeIntervalSinceReferenceDate: 1_000) },
            identifierGenerator: UUID.init,
            driver: driver
        )
        let service = try #require(builtService)
        driver.bind(to: service)

        let companionConnection = try service.admit(peer: CameraAgentAuthenticatedPeer(
            processIdentifier: 84,
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.idlescreen.app"
        ))
        let screenSaverConnection = try service.admit(peer: CameraAgentAuthenticatedPeer(
            processIdentifier: 85,
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.idlescreen.app.screensaver"
        ))
        let companionConnector = InProcessCameraAgentConnector(
            connection: companionConnection
        )
        let screenSaverConnector = InProcessCameraAgentConnector(
            connection: screenSaverConnection
        )
        let clientClock = PassiveSyntheticClientClock()
        let mappingFactory = IdleScreenCameraFrameSourceMappingFactory(layout: layout)
        let companionSource = try CameraFrameSource(
            appGroupContainerURL: temporaryRoot,
            clock: clientClock,
            mappingFactory: mappingFactory
        )
        let screenSaverSource = try CameraFrameSource(
            appGroupContainerURL: temporaryRoot,
            clock: clientClock,
            mappingFactory: mappingFactory
        )
        let clientConfiguration = try #require(CameraLeaseControllerConfiguration(
            maximumWidth: 8,
            maximumHeight: 4,
            maximumFramesPerSecond: 10,
            mailboxSlotCount: 3,
            leasePolicy: .production
        ))
        let companionController = CameraLeaseController(
            client: companionConnector,
            scheduler: clientClock,
            configuration: clientConfiguration,
            updateHandler: { companionSource.receive($0) }
        )
        let screenSaverController = CameraLeaseController(
            client: screenSaverConnector,
            scheduler: clientClock,
            configuration: clientConfiguration,
            updateHandler: { screenSaverSource.receive($0) }
        )
        let diagnosticRequest = try #require(IdleScreenCameraDiagnosticRequest())

        companionController.start()
        runtimeScheduler.runAllReady()
        #expect(capture.startCount == 1)
        #expect(companionConnection.diagnosticSnapshot(
            diagnosticRequest
        ).activeLeaseCount == 1)
        #expect(companionSource.availability == .waitingForFrame(epoch: 7))

        captureScheduler.fireActiveTick()
        runtimeScheduler.runAllReady()
        #expect(companionSource.readSequence == 1)
        #expect(companionSource.nextReadHasNoNewFrame)

        clientClock.advance(by: 0.01)
        captureScheduler.fireActiveTick()
        runtimeScheduler.runAllReady()
        #expect(companionSource.readSequence == 2)

        screenSaverController.start()
        #expect(capture.startCount == 1)
        #expect(screenSaverSource.readSequence == 2)
        #expect(screenSaverConnection.diagnosticSnapshot(
            diagnosticRequest
        ).activeLeaseCount == 2)

        clientClock.advance(by: 0.01)
        captureScheduler.fireActiveTick()
        runtimeScheduler.runAllReady()
        #expect(companionSource.readSequence == 3)
        #expect(screenSaverSource.readSequence == 3)

        companionController.stop()
        runtimeScheduler.runAllReady()
        #expect(companionSource.availability == .unavailable(.leaseUnavailable))
        #expect(capture.stopCount == 0)
        #expect(screenSaverConnection.diagnosticSnapshot(
            diagnosticRequest
        ).activeLeaseCount == 1)
        #expect(companionConnector.invalidationCount == 1)

        capture.emitInterruption(startIndex: 0)
        runtimeScheduler.runAllReady()
        #expect(capture.stopCount == 1)
        captureScheduler.runEnqueued()
        runtimeScheduler.runAllReady()
        runtimeScheduler.advance(by: 0.25)
        #expect(capture.startCount == 2)

        capture.replayLastFrame(startIndex: 0)
        runtimeScheduler.runAllReady()
        #expect(screenSaverSource.nextReadHasNoNewFrame)

        clientClock.advance(by: 0.01)
        captureScheduler.fireActiveTick()
        runtimeScheduler.runAllReady()
        #expect(screenSaverSource.readSequence == 4)
        let recovered = screenSaverConnection.diagnosticSnapshot(diagnosticRequest)
        #expect(recovered.activeLeaseCount == 1)
        #expect(recovered.producerStreamEpoch == 7)
        #expect(recovered.summary.contains("generation=2;sequence=4"))

        screenSaverController.stop()
        runtimeScheduler.runAllReady()
        #expect(capture.stopCount == 2)
        captureScheduler.runEnqueued()
        runtimeScheduler.runAllReady()
        #expect(screenSaverConnector.lastEndSnapshot?.activeLeaseCount == 0)
        #expect(screenSaverConnector.lastEndSnapshot?.captureActive == false)
        #expect(screenSaverConnector.invalidationCount == 1)
        #expect(screenSaverSource.availability == .unavailable(.leaseUnavailable))
        #expect(screenSaverSource.readUnavailableReason == .leaseUnavailable)
    }
}

private func syntheticTestAgentIdentity() -> IdleScreenCameraAgentIdentity? {
    IdleScreenCameraAgentIdentity(
        processIdentifier: 4_242,
        processIncarnationEpoch: 7,
        bundleIdentifier: "com.idlescreen.camera-agent",
        serviceIdentifier: "group.com.idlescreen.shared.camera-agent",
        bundleVersion: "1",
        marketingVersion: "0.1",
        signingIdentifier: "com.idlescreen.camera-agent",
        teamIdentifier: "3524374A2S",
        codeDirectoryHash: String(repeating: "1", count: 40),
        executableSHA256: String(repeating: "a", count: 64),
        launchAgentSHA256: String(repeating: "b", count: 64),
        provisioningProfileSHA256: String(repeating: "c", count: 64),
        sourceAppPath: "/Applications/idlescreen.app"
    )
}

private func firstPixel(_ frame: CameraCaptureFrame) -> UInt32 {
    CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }
    guard let address = CVPixelBufferGetBaseAddress(frame.pixelBuffer) else { return 0 }
    return address.load(as: UInt32.self)
}

private final class LockedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CameraCaptureFrame] = []

    var values: [CameraCaptureFrame] {
        lock.withLock { stored }
    }

    func append(_ frame: CameraCaptureFrame) {
        lock.withLock { stored.append(frame) }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }

    func increment() {
        lock.withLock { stored += 1 }
    }
}

private final class LockedAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CameraAgentAuthorization?

    var value: CameraAgentAuthorization? { lock.withLock { stored } }

    func set(_ authorization: CameraAgentAuthorization) {
        lock.withLock { stored = authorization }
    }
}

private final class ManualSyntheticRuntimeScheduler: CameraAgentRuntimeScheduling,
    @unchecked Sendable {
    private final class Work: CameraAgentRuntimeScheduledWork, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }

        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    private struct DelayedOperation: Sendable {
        let deadline: TimeInterval
        let serial: UInt64
        let work: Work
        let operation: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var ready: [@Sendable () -> Void] = []
    private var delayed: [DelayedOperation] = []
    private var now: TimeInterval = 0
    private var nextSerial: UInt64 = 0
    private var delayedExecutions = 0

    var currentTime: TimeInterval { lock.withLock { now } }
    var executedDelayedOperationCount: Int { lock.withLock { delayedExecutions } }
    var pendingDelayedOperationCount: Int {
        lock.withLock { delayed.filter { !$0.work.isCancelled }.count }
    }

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        lock.withLock { ready.append(operation) }
    }

    @discardableResult
    func enqueue(
        after delay: TimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) -> any CameraAgentRuntimeScheduledWork {
        let work = Work()
        lock.withLock {
            nextSerial &+= 1
            delayed.append(DelayedOperation(
                deadline: now + delay,
                serial: nextSerial,
                work: work,
                operation: operation
            ))
        }
        return work
    }

    func runAllReady() {
        while let operation = lock.withLock({ ready.isEmpty ? nil : ready.removeFirst() }) {
            operation()
        }
    }

    func advance(by interval: TimeInterval) {
        let due = lock.withLock { () -> [DelayedOperation] in
            now += interval
            let due = delayed
                .filter { $0.deadline <= now }
                .sorted {
                    ($0.deadline, $0.serial) < ($1.deadline, $1.serial)
                }
            delayed.removeAll { $0.deadline <= now }
            return due
        }
        for scheduled in due where !scheduled.work.isCancelled {
            lock.withLock { delayedExecutions += 1 }
            scheduled.operation()
            runAllReady()
        }
    }
}

private final class FakeSyntheticScheduler: SyntheticCameraScheduling, @unchecked Sendable {
    private final class Work: SyntheticCameraScheduledWork, @unchecked Sendable {
        private let onCancel: @Sendable () -> Void

        init(onCancel: @escaping @Sendable () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() { onCancel() }
    }

    private let lock = NSLock()
    private var tick: (@Sendable () -> Void)?
    private var cancelledTick: (@Sendable () -> Void)?
    private var queued: [@Sendable () -> Void] = []
    private var intervals: [TimeInterval] = []
    private var cancellations = 0

    var repeatingIntervals: [TimeInterval] { lock.withLock { intervals } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func scheduleRepeating(
        every interval: TimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) -> any SyntheticCameraScheduledWork {
        lock.withLock {
            intervals.append(interval)
            tick = operation
        }
        return Work { [weak self] in
            self?.lock.withLock {
                self?.cancellations += 1
                self?.cancelledTick = self?.tick
                self?.tick = nil
            }
        }
    }

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        lock.withLock { queued.append(operation) }
    }

    func fireActiveTick() {
        lock.withLock { tick }?()
    }

    func fireCancelledTick() {
        lock.withLock { cancelledTick }?()
    }

    func runEnqueued() {
        let operations = lock.withLock { () -> [@Sendable () -> Void] in
            defer { queued.removeAll() }
            return queued
        }
        operations.forEach { $0() }
    }
}

private final class InterruptibleSyntheticCaptureController:
    CameraAgentRuntimeCaptureControlling,
    @unchecked Sendable {
    private struct Start {
        let frameHandler: @Sendable (CameraCaptureFrame) -> Void
        let eventHandler: @Sendable (CameraCaptureSessionEvent) -> Void
        var lastFrame: CameraCaptureFrame?
    }

    private let capture: SyntheticCameraCaptureController
    private let lock = NSLock()
    private var starts: [Start] = []
    private var stops = 0

    init(scheduler: any SyntheticCameraScheduling) {
        capture = SyntheticCameraCaptureController(scheduler: scheduler)
    }

    var startCount: Int { lock.withLock { starts.count } }
    var stopCount: Int { lock.withLock { stops } }

    func start(
        _ request: CameraCaptureRequest,
        frameHandler: @escaping @Sendable (CameraCaptureFrame) -> Void,
        eventHandler: @escaping @Sendable (CameraCaptureSessionEvent) -> Void
    ) throws -> CameraCaptureDeviceDescriptor {
        let startIndex = lock.withLock { () -> Int in
            starts.append(Start(
                frameHandler: frameHandler,
                eventHandler: eventHandler,
                lastFrame: nil
            ))
            return starts.index(before: starts.endIndex)
        }
        do {
            return try capture.start(
                request,
                frameHandler: { [weak self] frame in
                    self?.lock.withLock {
                        guard self?.starts.indices.contains(startIndex) == true else {
                            return
                        }
                        self?.starts[startIndex].lastFrame = frame
                    }
                    frameHandler(frame)
                },
                eventHandler: eventHandler
            )
        } catch {
            _ = lock.withLock { starts.remove(at: startIndex) }
            throw error
        }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        lock.withLock { stops += 1 }
        capture.stop(completion: completion)
    }

    func emitInterruption(startIndex: Int) {
        lock.withLock {
            starts.indices.contains(startIndex) ? starts[startIndex].eventHandler : nil
        }?(.interrupted(reasonCode: 1))
    }

    func replayLastFrame(startIndex: Int) {
        let replay = lock.withLock { () -> (
            (@Sendable (CameraCaptureFrame) -> Void),
            CameraCaptureFrame
        )? in
            guard starts.indices.contains(startIndex),
                  let frame = starts[startIndex].lastFrame else {
                return nil
            }
            return (starts[startIndex].frameHandler, frame)
        }
        guard let replay else { return }
        replay.0(replay.1)
    }
}

private final class InProcessCameraAgentConnector: CameraAgentClientConnecting,
    @unchecked Sendable {
    private let connection: CameraAgentConnectionService
    private let lock = NSLock()
    private var storedLastEndSnapshot: IdleScreenCameraDiagnosticSnapshot?
    private var storedInvalidationCount = 0

    init(connection: CameraAgentConnectionService) {
        self.connection = connection
    }

    var lastEndSnapshot: IdleScreenCameraDiagnosticSnapshot? {
        lock.withLock { storedLastEndSnapshot }
    }

    var invalidationCount: Int { lock.withLock { storedInvalidationCount } }

    func connect(
        attempt: UInt64,
        eventHandler: @escaping @Sendable (CameraAgentClientConnectionEvent) -> Void
    ) -> any CameraAgentClientSession {
        InProcessCameraAgentSession(
            attempt: attempt,
            connection: connection,
            eventHandler: eventHandler,
            recordEnd: { [weak self] snapshot in
                self?.lock.withLock { self?.storedLastEndSnapshot = snapshot }
            },
            recordInvalidation: { [weak self] in
                self?.lock.withLock { self?.storedInvalidationCount += 1 }
            }
        )
    }
}

private final class InProcessCameraAgentSession: CameraAgentClientSession,
    @unchecked Sendable {
    let attempt: UInt64

    private let connection: CameraAgentConnectionService
    private let eventHandler: @Sendable (CameraAgentClientConnectionEvent) -> Void
    private let recordEnd: @Sendable (IdleScreenCameraDiagnosticSnapshot) -> Void
    private let recordInvalidation: @Sendable () -> Void
    private let lock = NSLock()
    private var isInvalidated = false

    init(
        attempt: UInt64,
        connection: CameraAgentConnectionService,
        eventHandler: @escaping @Sendable (CameraAgentClientConnectionEvent) -> Void,
        recordEnd: @escaping @Sendable (IdleScreenCameraDiagnosticSnapshot) -> Void,
        recordInvalidation: @escaping @Sendable () -> Void
    ) {
        self.attempt = attempt
        self.connection = connection
        self.eventHandler = eventHandler
        self.recordEnd = recordEnd
        self.recordInvalidation = recordInvalidation
    }

    func beginStream(
        _ request: IdleScreenCameraBeginStreamRequest,
        reply: @escaping @Sendable (IdleScreenCameraBeginStreamReply?) -> Void
    ) {
        reply(connection.beginStream(request))
    }

    func heartbeat(
        _ request: IdleScreenCameraHeartbeatRequest,
        reply: @escaping @Sendable (IdleScreenCameraHeartbeatReply?) -> Void
    ) {
        reply(connection.heartbeat(request))
    }

    func endStream(
        _ request: IdleScreenCameraEndStreamRequest,
        reply: @escaping @Sendable (IdleScreenCameraEndStreamReply?) -> Void
    ) {
        let response = connection.endStream(request)
        if let diagnosticRequest = IdleScreenCameraDiagnosticRequest() {
            recordEnd(connection.diagnosticSnapshot(diagnosticRequest))
        }
        reply(response)
    }

    func invalidate() {
        let shouldInvalidate = lock.withLock { () -> Bool in
            guard !isInvalidated else { return false }
            isInvalidated = true
            return true
        }
        guard shouldInvalidate else { return }
        _ = connection.invalidate()
        recordInvalidation()
        eventHandler(.invalidated(attempt: attempt))
    }
}

private final class PassiveSyntheticClientClock:
    CameraLeaseScheduling,
    CameraFrameSourceClock,
    @unchecked Sendable {
    private final class Work: CameraLeaseScheduledTask, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }
    }

    private let lock = NSLock()
    private var currentTime: TimeInterval = 0
    private var retainedWork: [Work] = []

    var now: TimeInterval { lock.withLock { currentTime } }

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any CameraLeaseScheduledTask {
        _ = delay
        _ = operation
        let work = Work()
        lock.withLock { retainedWork.append(work) }
        return work
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { currentTime += interval }
    }
}

private extension CameraFrameSource {
    var readSequence: UInt64? {
        guard case let .frame(_, sequence) = withFrame({ descriptor, pixels in
            #expect(!pixels.isEmpty)
            return descriptor.sequence
        }) else {
            return nil
        }
        return sequence
    }

    var nextReadHasNoNewFrame: Bool {
        if case .noNewFrame = withFrame({ descriptor, _ in descriptor.sequence }) {
            return true
        }
        return false
    }

    var readUnavailableReason: CameraFrameSourceUnavailableReason? {
        if case let .unavailable(reason) = withFrame({ descriptor, _ in
            descriptor.sequence
        }) {
            return reason
        }
        return nil
    }
}
