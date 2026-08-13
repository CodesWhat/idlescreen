import AVFoundation
import Foundation

@available(macOS 15.0, *)
public struct AVFoundationCameraDeviceDiscoverer: CameraCaptureDeviceDiscovering {
    public static let supportedDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .external,
        .continuityCamera,
        .deskViewCamera,
    ]

    public init() {}

    public func discoverVideoDevices() -> [CameraCaptureDeviceDescriptor] {
        Self.discoverySession().devices.map(Self.descriptor(for:))
    }

    static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: supportedDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
    }

    static func descriptor(for device: AVCaptureDevice) -> CameraCaptureDeviceDescriptor {
        CameraCaptureDeviceDescriptor(
            uniqueID: device.uniqueID,
            name: device.localizedName,
            kind: classifyDeviceKind(
                deviceType: device.deviceType,
                isContinuityCamera: device.isContinuityCamera
            )
        )
    }

    static func classifyDeviceKind(
        deviceType: AVCaptureDevice.DeviceType,
        isContinuityCamera: Bool
    ) -> CameraCaptureDeviceKind {
        if deviceType == .deskViewCamera {
            return .deskView
        }
        if deviceType == .continuityCamera || isContinuityCamera {
            return .continuity
        }
        return deviceType == .external ? .external : .builtIn
    }
}

/// Observes process-wide AVFoundation inventory changes without depending on a
/// capture session. The monitor refreshes the full inventory for every video event.
@available(macOS 15.0, *)
public final class AVFoundationCameraDeviceInventoryEventObserver:
    CameraDeviceInventoryEventObserving,
    @unchecked Sendable
{
    private final class Observation: CameraDeviceInventoryObservation, @unchecked Sendable {
        private let lock = NSLock()
        private let notificationCenter: NotificationCenter
        private var tokens: [NSObjectProtocol]

        init(notificationCenter: NotificationCenter, tokens: [NSObjectProtocol]) {
            self.notificationCenter = notificationCenter
            self.tokens = tokens
        }

        deinit {
            cancel()
        }

        func cancel() {
            lock.withLock {
                tokens.forEach(notificationCenter.removeObserver)
                tokens.removeAll()
            }
        }
    }

    private let notificationCenter: NotificationCenter

    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    public func observeChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> any CameraDeviceInventoryObservation {
        let tokens = [
            notificationCenter.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: nil
            ) { _ in
                // Re-run the video-filtered discovery for every capture-device
                // edge. A disconnected device can no longer reliably answer
                // capability queries by the time this callback runs.
                handler()
            },
            notificationCenter.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: nil
            ) { _ in
                handler()
            },
        ]
        return Observation(notificationCenter: notificationCenter, tokens: tokens)
    }
}
