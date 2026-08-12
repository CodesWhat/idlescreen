import CoreVideo
import Darwin
import Foundation
import IdleScreenCamera

public enum IdleScreenSyntheticGate {
    public static let markerInfoKey = "IdleScreenSyntheticGateVersion"
    public static let version = 1
}

public protocol SyntheticCameraScheduledWork: AnyObject, Sendable {
    func cancel()
}

public protocol SyntheticCameraScheduling: AnyObject, Sendable {
    func scheduleRepeating(
        every interval: TimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) -> any SyntheticCameraScheduledWork
    func enqueue(_ operation: @escaping @Sendable () -> Void)
}

public final class DispatchSyntheticCameraScheduler: SyntheticCameraScheduling,
    @unchecked Sendable {
    private final class Work: SyntheticCameraScheduledWork, @unchecked Sendable {
        private let lock = NSLock()
        private var source: DispatchSourceTimer?

        init(
            queue: DispatchQueue,
            interval: TimeInterval,
            operation: @escaping @Sendable () -> Void
        ) {
            let source = DispatchSource.makeTimerSource(queue: queue)
            self.source = source
            source.setEventHandler(handler: operation)
            source.schedule(deadline: .now(), repeating: interval)
            source.activate()
        }

        func cancel() {
            lock.withLock {
                source?.setEventHandler {}
                source?.cancel()
                source = nil
            }
        }
    }

    private let queue = DispatchQueue(
        label: "com.idlescreen.synthetic-gate.frames",
        qos: .userInitiated
    )

    public init() {}

    public func scheduleRepeating(
        every interval: TimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) -> any SyntheticCameraScheduledWork {
        Work(queue: queue, interval: interval, operation: operation)
    }

    public func enqueue(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}

public struct SyntheticCameraAuthorizationProvider:
    CameraCaptureAuthorizationChecking,
    CameraAgentAuthorizationRequesting
{
    public init() {}

    public func authorizationStatus() -> CameraCaptureAuthorization { .authorized }

    public func requestVideoAccess(
        completion: @escaping @Sendable (CameraAgentAuthorization) -> Void
    ) {
        completion(.authorized)
    }
}

public final class SyntheticCameraCaptureController: CameraAgentRuntimeCaptureControlling,
    @unchecked Sendable {
    public static let device = CameraCaptureDeviceDescriptor(
        uniqueID: "idlescreen-synthetic-gate-v1",
        name: "idlescreen synthetic gate",
        kind: .builtIn
    )

    private struct ActiveStream {
        let token: UUID
        let request: CameraCaptureRequest
        let frameHandler: @Sendable (CameraCaptureFrame) -> Void
        var nextSequence: UInt64
        var work: (any SyntheticCameraScheduledWork)?
    }

    private let scheduler: any SyntheticCameraScheduling
    private let lock = NSLock()
    private var active: ActiveStream?
    private var deliveriesInFlight = 0
    private var pendingStopCompletions: [@Sendable () -> Void] = []

    public init(
        scheduler: any SyntheticCameraScheduling = DispatchSyntheticCameraScheduler()
    ) {
        self.scheduler = scheduler
    }

    public func start(
        _ request: CameraCaptureRequest,
        frameHandler: @escaping @Sendable (CameraCaptureFrame) -> Void,
        eventHandler: @escaping @Sendable (CameraCaptureSessionEvent) -> Void
    ) throws -> CameraCaptureDeviceDescriptor {
        guard (1...CameraCaptureRequest.maximumWidth).contains(request.width),
              (1...CameraCaptureRequest.maximumHeight).contains(request.height) else {
            throw CameraCaptureSessionControllerError.invalidDimensions(
                width: request.width,
                height: request.height
            )
        }
        guard (1...CameraCaptureRequest.maximumFramesPerSecond).contains(
            request.maximumFramesPerSecond
        ) else {
            throw CameraCaptureSessionControllerError.invalidFrameRate(
                request.maximumFramesPerSecond
            )
        }
        let token = UUID()
        let accepted = lock.withLock { () -> Bool in
            guard active == nil, deliveriesInFlight == 0 else { return false }
            active = ActiveStream(
                token: token,
                request: request,
                frameHandler: frameHandler,
                nextSequence: 1,
                work: nil
            )
            return true
        }
        guard accepted else { throw CameraCaptureSessionControllerError.alreadyRunning }

        _ = eventHandler
        let interval = 1 / TimeInterval(request.maximumFramesPerSecond)
        let work = scheduler.scheduleRepeating(every: interval) { [weak self] in
            self?.emitFrame(streamToken: token)
        }
        let retained = lock.withLock { () -> Bool in
            guard active?.token == token else { return false }
            active?.work = work
            return true
        }
        if !retained { work.cancel() }
        return Self.device
    }

    public func stop(completion: @escaping @Sendable () -> Void) {
        let outcome = lock.withLock { () -> (
            work: (any SyntheticCameraScheduledWork)?,
            completions: [@Sendable () -> Void]
        ) in
            let work = active?.work
            active = nil
            pendingStopCompletions.append(completion)
            guard deliveriesInFlight == 0 else { return (work, []) }
            let completions = pendingStopCompletions
            pendingStopCompletions.removeAll(keepingCapacity: true)
            return (work, completions)
        }
        outcome.work?.cancel()
        outcome.completions.forEach(scheduler.enqueue)
    }

    private func emitFrame(streamToken: UUID) {
        let frameInput = lock.withLock { () -> (CameraCaptureRequest, UInt64)? in
            guard var stream = active, stream.token == streamToken else { return nil }
            let sequence = stream.nextSequence
            stream.nextSequence &+= 1
            active = stream
            return (stream.request, sequence)
        }
        guard let (request, sequence) = frameInput,
              let frame = Self.makeFrame(request: request, sequence: sequence) else {
            return
        }
        let handler = lock.withLock { () -> (@Sendable (CameraCaptureFrame) -> Void)? in
            guard let stream = active, stream.token == streamToken else { return nil }
            deliveriesInFlight += 1
            return stream.frameHandler
        }
        guard let handler else { return }
        handler(frame)
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            deliveriesInFlight -= 1
            guard deliveriesInFlight == 0, active == nil else { return [] }
            let completions = pendingStopCompletions
            pendingStopCompletions.removeAll(keepingCapacity: true)
            return completions
        }
        completions.forEach(scheduler.enqueue)
    }

    private static func makeFrame(
        request: CameraCaptureRequest,
        sequence: UInt64
    ) -> CameraCaptureFrame? {
        var storage: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            request.width,
            request.height,
            kCVPixelFormatType_32BGRA,
            nil,
            &storage
        )
        guard status == kCVReturnSuccess, let pixelBuffer = storage else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let byte = UInt8(truncatingIfNeeded: sequence)
        memset(baseAddress, Int32(byte), bytesPerRow * request.height)
        let firstPixel = baseAddress.assumingMemoryBound(to: UInt8.self)
        firstPixel[0] = byte
        firstPixel[1] = UInt8(truncatingIfNeeded: sequence &* 3)
        firstPixel[2] = UInt8(truncatingIfNeeded: sequence &* 7)
        firstPixel[3] = 255
        return CameraCaptureFrame(
            pixelBuffer: pixelBuffer,
            metadata: CameraCaptureFrameMetadata(
                sequence: sequence,
                presentationTimeSeconds: Double(sequence)
                    / Double(request.maximumFramesPerSecond),
                width: request.width,
                height: request.height,
                bytesPerRow: bytesPerRow,
                pixelFormat: kCVPixelFormatType_32BGRA
            )
        )
    }
}

final class SyntheticCameraInventoryMonitor:
    CameraAgentProcessDeviceInventoryMonitoring,
    @unchecked Sendable {
    private let lock = NSLock()
    private var isStarted = false

    @discardableResult
    func start(
        _ handler: @escaping @Sendable (CameraDeviceInventorySnapshot) -> Void
    ) -> Bool {
        let accepted = lock.withLock { () -> Bool in
            guard !isStarted else { return false }
            isStarted = true
            return true
        }
        if accepted {
            handler(CameraDeviceInventorySnapshot(
                generation: 1,
                devices: [SyntheticCameraCaptureController.device]
            ))
        }
        return accepted
    }

    func stop() {
        lock.withLock { isStarted = false }
    }

    func refresh() {
        // The synthetic inventory is immutable for the lifetime of the gate.
    }
}

extension CameraAgentProcessRuntime {
    public static func bootstrapSynthetic(
        configuration: CameraAgentProcessConfiguration
    ) throws -> CameraAgentProcessRuntime {
        try bootstrap(
            configuration: configuration,
            producerStreamEpochSeed: CameraAgentProcessEpochSeed.randomNonzero(),
            containerLocator: FileManagerCameraAgentContainerLocator(),
            components: SyntheticCameraAgentProcessComponents(),
            repeatingScheduler: DispatchCameraAgentRepeatingScheduler(),
            sleepWakeSource: WorkspaceCameraAgentSleepWakeSource()
        )
    }
}

private final class SyntheticCameraAgentProcessComponents:
    CameraAgentProcessComponentBuilding,
    @unchecked Sendable {
    private let authorization = SyntheticCameraAuthorizationProvider()

    func makeAgentIdentity(
        configuration: CameraAgentProcessConfiguration,
        processIncarnationEpoch: UInt64
    ) throws -> IdleScreenCameraAgentIdentity {
        guard let identity = IdleScreenCameraAgentIdentity(
            processIdentifier: Darwin.getpid(),
            processIncarnationEpoch: processIncarnationEpoch,
            bundleIdentifier: configuration.agentBundleIdentifier,
            serviceIdentifier: configuration.machServiceName,
            bundleVersion: "1",
            marketingVersion: "0.1",
            signingIdentifier: configuration.agentBundleIdentifier,
            teamIdentifier: configuration.expectedTeamIdentifier,
            codeDirectoryHash: String(repeating: "0", count: 40),
            executableSHA256: String(repeating: "0", count: 64),
            launchAgentSHA256: String(repeating: "0", count: 64),
            provisioningProfileSHA256: String(repeating: "0", count: 64),
            sourceAppPath: "/Applications/idlescreen.app"
        ) else {
            throw CameraAgentProcessBootstrapError.assemblyFailed
        }
        return identity
    }

    func makeAuthorizationChecker() -> any CameraCaptureAuthorizationChecking { authorization }
    func makeAuthorizationRequester() -> any CameraAgentAuthorizationRequesting { authorization }
    func makeDeviceInventoryMonitor() -> any CameraAgentProcessDeviceInventoryMonitoring {
        SyntheticCameraInventoryMonitor()
    }
    func makeCaptureController(
        authorizationChecker: any CameraCaptureAuthorizationChecking
    ) -> any CameraAgentRuntimeCaptureControlling {
        _ = authorizationChecker
        return SyntheticCameraCaptureController()
    }
    func makeFramePublisher(
        appGroupContainerURL: URL,
        mailboxFileName: String
    ) throws -> any CameraAgentProcessFramePublishing {
        let writer = try CameraFrameMailboxWriter(
            appGroupContainerURL: appGroupContainerURL,
            mailboxFileName: mailboxFileName
        )
        guard let publisher = CameraFrameMailboxRuntimePublisher(writer: writer) else {
            throw CameraAgentProcessBootstrapError.assemblyFailed
        }
        return publisher
    }
    func makeRuntimeDriver(
        permissionRequester: any CameraAgentAuthorizationRequesting,
        captureController: any CameraAgentRuntimeCaptureControlling,
        framePublisher: any CameraAgentProcessFramePublishing
    ) throws -> any CameraAgentProcessDriving {
        guard let driver = CameraAgentRuntimeDriver(
            permissionRequester: permissionRequester,
            captureController: captureController,
            framePublisher: framePublisher
        ) else {
            throw CameraAgentProcessBootstrapError.assemblyFailed
        }
        return driver
    }
    func makeService(
        peerPolicy: CameraAgentPeerPolicy,
        captureLimits: CameraAgentCaptureLimits,
        leaseTimeToLive: TimeInterval,
        producerStreamEpochSeed: UInt64,
        agentIdentity: IdleScreenCameraAgentIdentity,
        initialAuthorization: CameraAgentAuthorization,
        authorizationChecker: any CameraCaptureAuthorizationChecking,
        driver: any CameraAgentProcessDriving
    ) throws -> any CameraAgentProcessServicing {
        guard let service = CameraAgentService(
            peerPolicy: peerPolicy,
            captureLimits: captureLimits,
            leaseTimeToLive: leaseTimeToLive,
            initialAuthorization: initialAuthorization,
            initialDeviceAvailability: false,
            producerStreamEpochSeed: producerStreamEpochSeed,
            agentIdentity: agentIdentity,
            authorizationChecker: authorizationChecker,
            clock: Date.init,
            identifierGenerator: UUID.init,
            driver: driver
        ) else {
            throw CameraAgentProcessBootstrapError.assemblyFailed
        }
        return service
    }
    func bind(
        driver: any CameraAgentProcessDriving,
        to service: any CameraAgentProcessServicing
    ) { driver.bind(to: service) }
    func makeListener(
        configuration: CameraAgentXPCListenerConfiguration,
        service: any CameraAgentProcessServicing
    ) throws -> any CameraAgentProcessListening {
        guard let service = service as? CameraAgentService else {
            throw CameraAgentProcessBootstrapError.assemblyFailed
        }
        return CameraAgentXPCListener(configuration: configuration, service: service)
    }
}
