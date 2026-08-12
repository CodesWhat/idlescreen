import CoreVideo
import Foundation

public enum CameraCaptureAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public protocol CameraCaptureAuthorizationChecking: Sendable {
    func authorizationStatus() -> CameraCaptureAuthorization
}

public enum CameraCaptureSessionPreset: Equatable, Sendable {
    case hd1280x720
    case hd1920x1080
}

public struct CameraCaptureVideoOutputConfiguration: Equatable, Sendable {
    public let pixelFormat: OSType
    public let alwaysDiscardsLateVideoFrames: Bool
    public let maximumFramesPerSecond: Int

    public init(
        pixelFormat: OSType,
        alwaysDiscardsLateVideoFrames: Bool,
        maximumFramesPerSecond: Int = 30
    ) {
        self.pixelFormat = pixelFormat
        self.alwaysDiscardsLateVideoFrames = alwaysDiscardsLateVideoFrames
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }
}

public struct CameraCaptureFrameMetadata: Equatable, Sendable {
    public let sequence: UInt64
    public let presentationTimeSeconds: Double
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: OSType

    public init(
        sequence: UInt64,
        presentationTimeSeconds: Double,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: OSType
    ) {
        self.sequence = sequence
        self.presentationTimeSeconds = presentationTimeSeconds
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
    }
}

/// Carries the capture-owned CVPixelBuffer reference without copying its pixel bytes.
/// The consumer must finish reading the reference during its callback or retain it explicitly.
public final class CameraCaptureFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let metadata: CameraCaptureFrameMetadata

    public init(pixelBuffer: CVPixelBuffer, metadata: CameraCaptureFrameMetadata) {
        self.pixelBuffer = pixelBuffer
        self.metadata = metadata
    }
}

public enum CameraCaptureSessionEvent: Equatable, Sendable {
    case deviceConnected(CameraCaptureDeviceDescriptor)
    case deviceDisconnected(deviceID: String)
    case interrupted(reasonCode: Int?)
    case interruptionEnded
    case runtimeError(domain: String, code: Int)
}

public protocol CameraCaptureSessionProtocol: AnyObject, Sendable {
    func beginConfiguration()
    func setSessionPreset(_ preset: CameraCaptureSessionPreset) throws
    func addVideoInput(deviceID: String) throws
    func addVideoDataOutput(
        configuration: CameraCaptureVideoOutputConfiguration,
        frameHandler: @escaping @Sendable (CameraCaptureFrame) -> Void
    ) throws
    func commitConfiguration()
    func startObservingEvents(
        _ handler: @escaping @Sendable (CameraCaptureSessionEvent) -> Void
    )
    func stopObservingEvents()
    func startRunning() throws
    func stopRunning()
}

public protocol CameraCaptureSessionMaking: Sendable {
    func makeSession() -> any CameraCaptureSessionProtocol
}

public struct CameraCaptureRequest: Equatable, Sendable {
    public static let maximumWidth = 1_920
    public static let maximumHeight = 1_080
    public static let maximumFramesPerSecond = 60

    public let width: Int
    public let height: Int
    public let maximumFramesPerSecond: Int
    public let preferredDeviceID: String?

    public init(
        width: Int,
        height: Int,
        maximumFramesPerSecond: Int = 30,
        preferredDeviceID: String? = nil
    ) {
        self.width = width
        self.height = height
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.preferredDeviceID = preferredDeviceID
    }

    fileprivate var hasValidDimensions: Bool {
        (1...Self.maximumWidth).contains(width)
            && (1...Self.maximumHeight).contains(height)
    }

    fileprivate var hasValidFrameRate: Bool {
        (1...Self.maximumFramesPerSecond).contains(maximumFramesPerSecond)
    }

    fileprivate var preset: CameraCaptureSessionPreset {
        width > 1_280 || height > 720 ? .hd1920x1080 : .hd1280x720
    }
}

public enum CameraCaptureConfigurationStage: Equatable, Sendable {
    case preset
    case videoInput
    case videoOutput
}

public enum CameraCaptureSessionControllerError: Error, Equatable {
    case invalidDimensions(width: Int, height: Int)
    case invalidFrameRate(Int)
    case authorizationRequired(CameraCaptureAuthorization)
    case noVideoDevice
    case sessionAlreadyOwned
    case alreadyRunning
    case sessionConfigurationFailed(CameraCaptureConfigurationStage)
    case sessionStartFailed
}

/// Process-scoped lease which guarantees that at most one controller can own an
/// system capture session at a time. A session is constructed only after this lease is acquired.
public final class CameraCaptureOwnershipGate: @unchecked Sendable {
    public static let shared = CameraCaptureOwnershipGate()

    private let lock = NSLock()
    private var owner: UUID?

    public init() {}

    fileprivate func acquire(ownerID: UUID) -> Bool {
        lock.withLock {
            guard owner == nil else { return false }
            owner = ownerID
            return true
        }
    }

    fileprivate func release(ownerID: UUID) {
        lock.withLock {
            guard owner == ownerID else { return }
            owner = nil
        }
    }
}

public final class CameraCaptureSessionController: @unchecked Sendable {
    private let authorizationChecker: any CameraCaptureAuthorizationChecking
    private let deviceDiscoverer: any CameraCaptureDeviceDiscovering
    private let sessionFactory: any CameraCaptureSessionMaking
    private let ownership: CameraCaptureOwnershipGate
    private let ownerID = UUID()
    private let operationQueue: DispatchQueue
    private let operationQueueKey = DispatchSpecificKey<UInt8>()

    private var session: (any CameraCaptureSessionProtocol)?
    private var eventHandler: (@Sendable (CameraCaptureSessionEvent) -> Void)?

    public init(
        authorizationChecker: any CameraCaptureAuthorizationChecking,
        deviceDiscoverer: any CameraCaptureDeviceDiscovering,
        sessionFactory: any CameraCaptureSessionMaking,
        ownership: CameraCaptureOwnershipGate = .shared
    ) {
        self.authorizationChecker = authorizationChecker
        self.deviceDiscoverer = deviceDiscoverer
        self.sessionFactory = sessionFactory
        self.ownership = ownership
        operationQueue = DispatchQueue(
            label: "com.idlescreen.camera-agent.capture-session",
            qos: .userInitiated
        )
        operationQueue.setSpecific(key: operationQueueKey, value: 1)
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start(
        _ request: CameraCaptureRequest,
        frameHandler: @escaping @Sendable (CameraCaptureFrame) -> Void,
        eventHandler: @escaping @Sendable (CameraCaptureSessionEvent) -> Void
    ) throws -> CameraCaptureDeviceDescriptor {
        try onOperationQueue {
            guard request.hasValidDimensions else {
                throw CameraCaptureSessionControllerError.invalidDimensions(
                    width: request.width,
                    height: request.height
                )
            }
            guard request.hasValidFrameRate else {
                throw CameraCaptureSessionControllerError.invalidFrameRate(
                    request.maximumFramesPerSecond
                )
            }
            guard session == nil else {
                throw CameraCaptureSessionControllerError.alreadyRunning
            }

            let authorization = authorizationChecker.authorizationStatus()
            guard authorization == .authorized else {
                throw CameraCaptureSessionControllerError.authorizationRequired(authorization)
            }
            guard ownership.acquire(ownerID: ownerID) else {
                throw CameraCaptureSessionControllerError.sessionAlreadyOwned
            }

            do {
                let devices = deviceDiscoverer.discoverVideoDevices()
                guard let selectedDevice = Self.selectDevice(
                    from: devices,
                    preferredDeviceID: request.preferredDeviceID
                ) else {
                    throw CameraCaptureSessionControllerError.noVideoDevice
                }

                let newSession = sessionFactory.makeSession()
                try configure(
                    newSession,
                    request: request,
                    device: selectedDevice,
                    frameHandler: frameHandler
                )

                session = newSession
                self.eventHandler = eventHandler
                newSession.startObservingEvents { [weak self] event in
                    self?.forward(event: event)
                }
                do {
                    try newSession.startRunning()
                } catch {
                    newSession.stopObservingEvents()
                    session = nil
                    self.eventHandler = nil
                    throw CameraCaptureSessionControllerError.sessionStartFailed
                }
                return selectedDevice
            } catch {
                ownership.release(ownerID: ownerID)
                throw error
            }
        }
    }

    public func stop() {
        onOperationQueue {
            guard let session else { return }
            eventHandler = nil
            session.stopObservingEvents()
            session.stopRunning()
            self.session = nil
            ownership.release(ownerID: ownerID)
        }
    }

    private func configure(
        _ session: any CameraCaptureSessionProtocol,
        request: CameraCaptureRequest,
        device: CameraCaptureDeviceDescriptor,
        frameHandler: @escaping @Sendable (CameraCaptureFrame) -> Void
    ) throws {
        session.beginConfiguration()
        do {
            do {
                try session.setSessionPreset(request.preset)
            } catch {
                throw CameraCaptureSessionControllerError.sessionConfigurationFailed(.preset)
            }
            do {
                try session.addVideoInput(deviceID: device.uniqueID)
            } catch {
                throw CameraCaptureSessionControllerError.sessionConfigurationFailed(.videoInput)
            }
            do {
                try session.addVideoDataOutput(
                    configuration: CameraCaptureVideoOutputConfiguration(
                        pixelFormat: kCVPixelFormatType_32BGRA,
                        alwaysDiscardsLateVideoFrames: true,
                        maximumFramesPerSecond: request.maximumFramesPerSecond
                    ),
                    frameHandler: frameHandler
                )
            } catch {
                throw CameraCaptureSessionControllerError.sessionConfigurationFailed(.videoOutput)
            }
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
    }

    private func forward(event: CameraCaptureSessionEvent) {
        onOperationQueue {
            guard session != nil else { return }
            eventHandler?(event)
        }
    }

    private static func selectDevice(
        from devices: [CameraCaptureDeviceDescriptor],
        preferredDeviceID: String?
    ) -> CameraCaptureDeviceDescriptor? {
        let preference = preferredDeviceID.map {
            CameraDeviceSelectionPreference.device(uniqueID: $0)
        } ?? .automatic
        switch CameraDeviceSelectionReducer.decision(
            preference: preference,
            currentDeviceID: nil,
            inventory: CameraDeviceInventorySnapshot(generation: 1, devices: devices)
        ) {
        case let .select(device):
            return device
        case .keepCurrent, .unavailable:
            return nil
        }
    }

    private func onOperationQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: operationQueueKey) != nil {
            return try operation()
        }
        return try operationQueue.sync(execute: operation)
    }
}
