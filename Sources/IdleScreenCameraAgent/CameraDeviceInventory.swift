import Foundation

public enum CameraCaptureDeviceKind: Equatable, Sendable {
    case builtIn
    case external
    case continuity
    case deskView
}

public struct CameraCaptureDeviceDescriptor: Equatable, Sendable {
    public let uniqueID: String
    public let name: String
    public let kind: CameraCaptureDeviceKind

    public init(uniqueID: String, name: String, kind: CameraCaptureDeviceKind) {
        self.uniqueID = uniqueID
        self.name = name
        self.kind = kind
    }
}

public protocol CameraCaptureDeviceDiscovering: Sendable {
    func discoverVideoDevices() -> [CameraCaptureDeviceDescriptor]
}

public struct CameraDeviceInventorySnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let devices: [CameraCaptureDeviceDescriptor]

    public init(generation: UInt64, devices: [CameraCaptureDeviceDescriptor]) {
        self.generation = generation
        self.devices = devices.sorted(by: Self.deviceOrder)
    }

    private static func deviceOrder(
        _ lhs: CameraCaptureDeviceDescriptor,
        _ rhs: CameraCaptureDeviceDescriptor
    ) -> Bool {
        if lhs.uniqueID != rhs.uniqueID {
            return lhs.uniqueID < rhs.uniqueID
        }
        return lhs.name < rhs.name
    }
}

public protocol CameraDeviceInventoryObservation: AnyObject, Sendable {
    func cancel()
}

public protocol CameraDeviceInventoryEventObserving: Sendable {
    func observeChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> any CameraDeviceInventoryObservation
}

/// Maintains one device inventory independently of any AVCaptureSession.
/// A process owner starts this once and retains it for the process lifetime.
public final class CameraDeviceInventoryMonitor: @unchecked Sendable {
    private let discoverer: any CameraCaptureDeviceDiscovering
    private let eventObserver: any CameraDeviceInventoryEventObserving
    private let refreshLock = NSRecursiveLock()
    private let lock = NSLock()

    private var isRunning = false
    private var observation: (any CameraDeviceInventoryObservation)?
    private var handler: (@Sendable (CameraDeviceInventorySnapshot) -> Void)?
    private var lastDevices: [CameraCaptureDeviceDescriptor]?
    private var generation: UInt64 = 0

    public init(
        discoverer: any CameraCaptureDeviceDiscovering,
        eventObserver: any CameraDeviceInventoryEventObserving
    ) {
        self.discoverer = discoverer
        self.eventObserver = eventObserver
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start(
        _ handler: @escaping @Sendable (CameraDeviceInventorySnapshot) -> Void
    ) -> Bool {
        refreshLock.lock()
        defer { refreshLock.unlock() }

        let shouldStart = lock.withLock {
            guard !isRunning else { return false }
            isRunning = true
            self.handler = handler
            lastDevices = nil
            return true
        }
        guard shouldStart else { return false }

        let newObservation = eventObserver.observeChanges { [weak self] in
            self?.refreshIfChanged()
        }
        let retained = lock.withLock {
            guard isRunning else { return false }
            observation = newObservation
            return true
        }
        guard retained else {
            newObservation.cancel()
            return true
        }

        refreshSerialized(forcePublication: true)
        return true
    }

    /// Re-discovers and publishes an authoritative inventory even when the
    /// device identifiers match the last notification-driven snapshot. This
    /// gives process owners a bounded recovery probe when an AVFoundation
    /// connect/disconnect edge is delivered before discovery has converged.
    public func refresh() {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        refreshSerialized(forcePublication: true)
    }

    public func stop() {
        let oldObservation = refreshLock.withLock {
            lock.withLock {
                guard isRunning else {
                    return nil as (any CameraDeviceInventoryObservation)?
                }
                isRunning = false
                handler = nil
                lastDevices = nil
                let oldObservation = observation
                observation = nil
                return oldObservation
            }
        }
        // Notification observation removal may wait for a callback already in
        // flight, so never perform cancellation under the refresh-order lock.
        oldObservation?.cancel()
    }

    private func refreshIfChanged() {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        refreshSerialized(forcePublication: false)
    }

    /// Discovery and delivery share one ordering boundary so concurrent device
    /// notifications cannot publish an older snapshot after a newer snapshot.
    /// The state lock is released before invoking client code.
    private func refreshSerialized(forcePublication: Bool) {
        let devices = CameraDeviceInventorySnapshot(
            generation: 0,
            devices: discoverer.discoverVideoDevices()
        ).devices
        let update = lock.withLock { () -> (
            @Sendable (CameraDeviceInventorySnapshot) -> Void,
            CameraDeviceInventorySnapshot
        )? in
            guard isRunning,
                  forcePublication || devices != lastDevices,
                  let handler else {
                return nil
            }
            lastDevices = devices
            generation = generation == .max ? 1 : generation + 1
            return (handler, CameraDeviceInventorySnapshot(
                generation: generation,
                devices: devices
            ))
        }
        if let update {
            update.0(update.1)
        }
    }
}

public enum CameraDeviceSelectionPreference: Equatable, Sendable {
    case automatic
    case device(uniqueID: String)
}

public enum CameraDeviceSelectionDecision: Equatable, Sendable {
    case keepCurrent
    case select(CameraCaptureDeviceDescriptor)
    case unavailable
}

/// Pure device-selection policy. Automatic fallback considers only physical Mac
/// and external cameras. A soft preference may identify any connected device;
/// Continuity Camera and Desk View never enter fallback selection on their own.
public enum CameraDeviceSelectionReducer {
    public static func decision(
        preference: CameraDeviceSelectionPreference,
        preferredDeviceID: String? = nil,
        currentDeviceID: String?,
        inventory: CameraDeviceInventorySnapshot
    ) -> CameraDeviceSelectionDecision {
        if case let .device(preferredID) = preference {
            guard let preferred = inventory.devices.first(where: {
                $0.uniqueID == preferredID
            }) else {
                return .unavailable
            }
            return preferred.uniqueID == currentDeviceID
                ? .keepCurrent
                : .select(preferred)
        }

        // A preferred camera is deliberately softer than an explicit device
        // selection. It wins whenever connected, but its absence falls through
        // to the established external-then-built-in Automatic policy.
        if let preferredDeviceID,
           let preferred = inventory.devices.first(where: {
               $0.uniqueID == preferredDeviceID
           }) {
            return preferred.uniqueID == currentDeviceID
                ? .keepCurrent
                : .select(preferred)
        }

        let physicalDevices = inventory.devices.filter(\.isAutomaticCandidate)
        let current = physicalDevices.first { $0.uniqueID == currentDeviceID }

        if let current {
            if preference == .automatic,
               current.kind == .builtIn,
               let external = deterministicExternal(in: physicalDevices) {
                return .select(external)
            }
            return .keepCurrent
        }

        if let external = deterministicExternal(in: physicalDevices) {
            return .select(external)
        }
        if let builtIn = physicalDevices
            .filter({ $0.kind == .builtIn })
            .min(by: { $0.uniqueID < $1.uniqueID }) {
            return .select(builtIn)
        }
        return .unavailable
    }

    private static func deterministicExternal(
        in devices: [CameraCaptureDeviceDescriptor]
    ) -> CameraCaptureDeviceDescriptor? {
        devices
            .filter { $0.kind == .external }
            .min { $0.uniqueID < $1.uniqueID }
    }
}

private extension CameraCaptureDeviceDescriptor {
    var isAutomaticCandidate: Bool {
        kind == .builtIn || kind == .external
    }
}
