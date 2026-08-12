import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Reads current TCC state only. Camera permission must be requested by a visible app action,
/// never by the background camera agent's capture-start path.
@available(macOS 15.0, *)
public struct AVFoundationCameraAuthorizationChecker: CameraCaptureAuthorizationChecking {
    public init() {}

    public func authorizationStatus() -> CameraCaptureAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
}

@available(macOS 15.0, *)
public struct AVFoundationCameraCaptureSessionFactory: CameraCaptureSessionMaking {
    public init() {}

    public func makeSession() -> any CameraCaptureSessionProtocol {
        AVFoundationCameraCaptureSession()
    }
}

private enum AVFoundationCameraCaptureSessionError: Error {
    case unsupportedPreset
    case deviceUnavailable
    case cannotAddInput
    case unsupportedOutputConfiguration
    case cannotAddOutput
}

@available(macOS 15.0, *)
private final class AVFoundationCameraCaptureSession: CameraCaptureSessionProtocol, @unchecked Sendable {
    private let captureSession = AVCaptureSession()
    private let notificationCenter: NotificationCenter
    private let frameDeliveryQueue = DispatchQueue(
        label: "com.idlescreen.camera-agent.frame-delivery",
        qos: .userInteractive
    )
    private var frameForwarder: AVFoundationCameraFrameForwarder?
    private var notificationTokens: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func beginConfiguration() { captureSession.beginConfiguration() }

    func setSessionPreset(_ preset: CameraCaptureSessionPreset) throws {
        let avPreset: AVCaptureSession.Preset = switch preset {
        case .hd1280x720: .hd1280x720
        case .hd1920x1080: .hd1920x1080
        }
        guard captureSession.canSetSessionPreset(avPreset) else {
            throw AVFoundationCameraCaptureSessionError.unsupportedPreset
        }
        captureSession.sessionPreset = avPreset
    }

    func addVideoInput(deviceID: String) throws {
        guard let device = AVFoundationCameraDeviceDiscoverer.discoverySession().devices.first(
            where: { $0.uniqueID == deviceID }
        ) else {
            throw AVFoundationCameraCaptureSessionError.deviceUnavailable
        }
        try? configureModernDefaults(on: device)
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw AVFoundationCameraCaptureSessionError.cannotAddInput
        }
        captureSession.addInput(input)
    }

    func addVideoDataOutput(
        configuration: CameraCaptureVideoOutputConfiguration,
        frameHandler: @escaping @Sendable (CameraCaptureFrame) -> Void
    ) throws {
        guard configuration.pixelFormat == kCVPixelFormatType_32BGRA,
              configuration.alwaysDiscardsLateVideoFrames,
              (1...CameraCaptureRequest.maximumFramesPerSecond).contains(
                configuration.maximumFramesPerSecond
              ) else {
            throw AVFoundationCameraCaptureSessionError.unsupportedOutputConfiguration
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: configuration.pixelFormat
        ]
        output.alwaysDiscardsLateVideoFrames = true
        let forwarder = AVFoundationCameraFrameForwarder(frameHandler: frameHandler)
        output.setSampleBufferDelegate(forwarder, queue: frameDeliveryQueue)
        guard captureSession.canAddOutput(output) else {
            throw AVFoundationCameraCaptureSessionError.cannotAddOutput
        }
        captureSession.addOutput(output)
        guard let connection = output.connection(with: .video),
              connection.isVideoMinFrameDurationSupported else {
            throw AVFoundationCameraCaptureSessionError.unsupportedOutputConfiguration
        }
        connection.videoMinFrameDuration = CMTime(
            value: 1,
            timescale: Int32(configuration.maximumFramesPerSecond)
        )
        frameForwarder = forwarder
    }

    func commitConfiguration() { captureSession.commitConfiguration() }
    func startRunning() throws { captureSession.startRunning() }
    func stopRunning() { captureSession.stopRunning() }

    func startObservingEvents(
        _ handler: @escaping @Sendable (CameraCaptureSessionEvent) -> Void
    ) {
        stopObservingEvents()
        notificationTokens = [
            notificationCenter.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: nil
            ) { notification in
                guard let device = notification.object as? AVCaptureDevice,
                      device.hasMediaType(.video) else { return }
                handler(.deviceConnected(AVFoundationCameraDeviceDiscoverer.descriptor(for: device)))
            },
            notificationCenter.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: nil
            ) { notification in
                guard let device = notification.object as? AVCaptureDevice,
                      device.hasMediaType(.video) else { return }
                handler(.deviceDisconnected(deviceID: device.uniqueID))
            },
            notificationCenter.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: captureSession,
                queue: nil
            ) { _ in handler(.interrupted(reasonCode: nil)) },
            notificationCenter.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: captureSession,
                queue: nil
            ) { _ in handler(.interruptionEnded) },
            notificationCenter.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: captureSession,
                queue: nil
            ) { notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                handler(.runtimeError(
                    domain: error?.domain ?? AVFoundationErrorDomain,
                    code: error?.code ?? 0
                ))
            },
        ]
    }

    func stopObservingEvents() {
        notificationTokens.forEach(notificationCenter.removeObserver)
        notificationTokens.removeAll(keepingCapacity: true)
    }

    private func configureModernDefaults(on device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }
}

final class AVFoundationCameraFrameForwarder: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    private let frameHandler: @Sendable (CameraCaptureFrame) -> Void
    private let sequenceLock = NSLock()
    private var nextSequence: UInt64 = 1

    init(frameHandler: @escaping @Sendable (CameraCaptureFrame) -> Void) {
        self.frameHandler = frameHandler
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        _ = forward(sampleBuffer: sampleBuffer)
    }

    @discardableResult
    func forward(sampleBuffer: CMSampleBuffer) -> Bool {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return false
        }
        let sequence = sequenceLock.withLock {
            defer { nextSequence &+= 1 }
            return nextSequence
        }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let metadata = CameraCaptureFrameMetadata(
            sequence: sequence,
            presentationTimeSeconds: seconds.isFinite ? seconds : 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )
        frameHandler(CameraCaptureFrame(pixelBuffer: pixelBuffer, metadata: metadata))
        return true
    }
}
