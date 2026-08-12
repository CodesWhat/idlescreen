import AVFoundation
import Dispatch
import Testing
@testable import IdleScreenCameraAgentCore

@Suite("Process-lifetime camera device inventory", .serialized)
struct CameraDeviceInventoryTests {
    @Test("an empty inventory recovers when a camera connects")
    func noDeviceThenConnect() {
        let discoverer = InventoryTestDiscoverer(devices: [])
        let events = InventoryTestEventObserver()
        let monitor = CameraDeviceInventoryMonitor(
            discoverer: discoverer,
            eventObserver: events
        )
        let snapshots = InventorySnapshotRecorder()

        #expect(monitor.start { snapshots.append($0) })
        #expect(snapshots.values == [snapshot(generation: 1, devices: [])])

        let builtIn = device("built-in", kind: .builtIn)
        discoverer.devices = [builtIn]
        events.sendChange()

        #expect(snapshots.values == [
            snapshot(generation: 1, devices: []),
            snapshot(generation: 2, devices: [builtIn]),
        ])
        #expect(events.observationCount == 1)
    }

    @Test("unchanged device events do not publish duplicate inventory generations")
    func duplicateEventIsCoalesced() {
        let builtIn = device("built-in", kind: .builtIn)
        let discoverer = InventoryTestDiscoverer(devices: [builtIn])
        let events = InventoryTestEventObserver()
        let monitor = CameraDeviceInventoryMonitor(
            discoverer: discoverer,
            eventObserver: events
        )
        let snapshots = InventorySnapshotRecorder()

        #expect(monitor.start { snapshots.append($0) })
        events.sendChange()

        #expect(snapshots.values == [snapshot(generation: 1, devices: [builtIn])])
        #expect(!monitor.start { _ in })
    }

    @Test("an explicit process probe republishes unchanged authoritative inventory")
    func explicitProbePublishesUnchangedInventory() {
        let builtIn = device("built-in", kind: .builtIn)
        let discoverer = InventoryTestDiscoverer(devices: [builtIn])
        let monitor = CameraDeviceInventoryMonitor(
            discoverer: discoverer,
            eventObserver: InventoryTestEventObserver()
        )
        let snapshots = InventorySnapshotRecorder()

        #expect(monitor.start { snapshots.append($0) })
        monitor.refresh()

        #expect(snapshots.values == [
            snapshot(generation: 1, devices: [builtIn]),
            snapshot(generation: 2, devices: [builtIn]),
        ])
    }

    @Test("stopping the inventory cancels process-level observation")
    func stopCancelsObservation() {
        let discoverer = InventoryTestDiscoverer(devices: [])
        let events = InventoryTestEventObserver()
        let monitor = CameraDeviceInventoryMonitor(
            discoverer: discoverer,
            eventObserver: events
        )
        let snapshots = InventorySnapshotRecorder()
        _ = monitor.start { snapshots.append($0) }

        monitor.stop()
        discoverer.devices = [device("late")]
        events.sendChange()

        #expect(events.token.cancelCount == 1)
        #expect(snapshots.values.count == 1)
    }

    @Test("concurrent change events cannot publish an older inventory last")
    func concurrentEventsPreserveDiscoveryOrder() {
        let initial = device("built-in", kind: .builtIn)
        let stale = device("usb-stale", kind: .external)
        let newest = device("usb-newest", kind: .external)
        let newestPublished = DispatchSemaphore(value: 0)
        let discoverer = OutOfOrderInventoryDiscoverer(
            initial: [initial],
            stale: [stale],
            newest: [newest],
            newestPublished: newestPublished
        )
        let events = InventoryTestEventObserver()
        let monitor = CameraDeviceInventoryMonitor(
            discoverer: discoverer,
            eventObserver: events
        )
        let snapshots = InventorySnapshotRecorder()
        _ = monitor.start { snapshot in
            snapshots.append(snapshot)
            if snapshot.devices == [newest] {
                newestPublished.signal()
            }
        }

        let refreshes = DispatchGroup()
        refreshes.enter()
        DispatchQueue.global().async {
            events.sendChange()
            refreshes.leave()
        }
        #expect(discoverer.staleDiscoveryStarted.wait(timeout: .now() + 1) == .success)

        refreshes.enter()
        DispatchQueue.global().async {
            events.sendChange()
            refreshes.leave()
        }
        #expect(refreshes.wait(timeout: .now() + 3) == .success)

        #expect(snapshots.values.map(\.devices) == [[initial], [stale], [newest]])
    }

    @Test("an active disconnect selects an already-connected physical fallback")
    func activeDisconnectUsesExistingFallback() {
        let builtIn = device("built-in", kind: .builtIn)
        let decision = CameraDeviceSelectionReducer.decision(
            preference: .automatic,
            currentDeviceID: "removed-external",
            inventory: snapshot(generation: 2, devices: [builtIn])
        )

        #expect(decision == .select(builtIn))
    }

    @Test("an unrelated disconnect keeps the active camera")
    func unrelatedDisconnectKeepsCurrent() {
        let current = device("usb-current", kind: .external)
        let decision = CameraDeviceSelectionReducer.decision(
            preference: .automatic,
            currentDeviceID: current.uniqueID,
            inventory: snapshot(generation: 2, devices: [current])
        )

        #expect(decision == .keepCurrent)
    }

    @Test("an explicit preferred camera replaces a connected fallback when it reappears")
    func preferredDeviceReappears() {
        let fallback = device("built-in", kind: .builtIn)
        let preferred = device("preferred-usb", kind: .external)
        let decision = CameraDeviceSelectionReducer.decision(
            preference: .device(uniqueID: preferred.uniqueID),
            currentDeviceID: fallback.uniqueID,
            inventory: snapshot(generation: 3, devices: [fallback, preferred])
        )

        #expect(decision == .select(preferred))
    }

    @Test("automatic mode upgrades a built-in camera to a physical external camera")
    func automaticUpgradesBuiltInToExternal() {
        let builtIn = device("built-in", kind: .builtIn)
        let external = device("usb-camera", kind: .external)
        let decision = CameraDeviceSelectionReducer.decision(
            preference: .automatic,
            currentDeviceID: builtIn.uniqueID,
            inventory: snapshot(generation: 2, devices: [builtIn, external])
        )

        #expect(decision == .select(external))
    }

    @Test("automatic mode keeps a connected physical external camera stable")
    func automaticKeepsCurrentExternal() {
        let current = device("usb-z", kind: .external)
        let newlyConnected = device("usb-a", kind: .external)
        let decision = CameraDeviceSelectionReducer.decision(
            preference: .automatic,
            currentDeviceID: current.uniqueID,
            inventory: snapshot(generation: 2, devices: [newlyConnected, current])
        )

        #expect(decision == .keepCurrent)
    }

    @Test("automatic mode never selects Continuity Camera or Desk View")
    func automaticExcludesOptInDevices() {
        let continuity = device("iphone", kind: .continuity)
        let deskView = device("desk-view", kind: .deskView)

        #expect(CameraDeviceSelectionReducer.decision(
            preference: .automatic,
            currentDeviceID: nil,
            inventory: snapshot(generation: 1, devices: [continuity, deskView])
        ) == .unavailable)
    }

    @Test(arguments: [
        CameraCaptureDeviceKind.continuity,
        CameraCaptureDeviceKind.deskView,
    ])
    func continuityAndDeskViewRequireExplicitSelection(kind: CameraCaptureDeviceKind) {
        let selected = device("explicit-opt-in", kind: kind)

        #expect(CameraDeviceSelectionReducer.decision(
            preference: .device(uniqueID: selected.uniqueID),
            currentDeviceID: nil,
            inventory: snapshot(generation: 1, devices: [selected])
        ) == .select(selected))
    }

    @Test("fallback selection is deterministic regardless of discovery order")
    func deterministicPhysicalFallback() {
        let externalB = device("usb-b", kind: .external)
        let builtIn = device("built-in", kind: .builtIn)
        let externalA = device("usb-a", kind: .external)

        #expect(CameraDeviceSelectionReducer.decision(
            preference: .automatic,
            currentDeviceID: nil,
            inventory: snapshot(
                generation: 1,
                devices: [externalB, builtIn, externalA]
            )
        ) == .select(externalA))
    }

    @Test("modern discovery covers every supported Mac camera category")
    func modernDiscoveryDeviceTypes() {
        #expect(AVFoundationCameraDeviceDiscoverer.supportedDeviceTypes == [
            .builtInWideAngleCamera,
            .external,
            .continuityCamera,
            .deskViewCamera,
        ])
    }

    @Test("device taxonomy distinguishes physical, Continuity, and Desk View cameras")
    func classifiesModernDeviceKinds() {
        #expect(AVFoundationCameraDeviceDiscoverer.classifyDeviceKind(
            deviceType: .builtInWideAngleCamera,
            isContinuityCamera: false
        ) == .builtIn)
        #expect(AVFoundationCameraDeviceDiscoverer.classifyDeviceKind(
            deviceType: .external,
            isContinuityCamera: false
        ) == .external)
        #expect(AVFoundationCameraDeviceDiscoverer.classifyDeviceKind(
            deviceType: .builtInWideAngleCamera,
            isContinuityCamera: true
        ) == .continuity)
        #expect(AVFoundationCameraDeviceDiscoverer.classifyDeviceKind(
            deviceType: .continuityCamera,
            isContinuityCamera: true
        ) == .continuity)
        #expect(AVFoundationCameraDeviceDiscoverer.classifyDeviceKind(
            deviceType: .deskViewCamera,
            isContinuityCamera: false
        ) == .deskView)
    }
}

private func device(
    _ id: String,
    kind: CameraCaptureDeviceKind = .builtIn
) -> CameraCaptureDeviceDescriptor {
    CameraCaptureDeviceDescriptor(uniqueID: id, name: id, kind: kind)
}

private func snapshot(
    generation: UInt64,
    devices: [CameraCaptureDeviceDescriptor]
) -> CameraDeviceInventorySnapshot {
    CameraDeviceInventorySnapshot(generation: generation, devices: devices)
}

private final class InventoryTestDiscoverer: CameraCaptureDeviceDiscovering,
    @unchecked Sendable
{
    var devices: [CameraCaptureDeviceDescriptor]
    private(set) var discoveryCount = 0

    init(devices: [CameraCaptureDeviceDescriptor]) {
        self.devices = devices
    }

    func discoverVideoDevices() -> [CameraCaptureDeviceDescriptor] {
        discoveryCount += 1
        return devices
    }
}

/// Forces the stale discovery to wait for a newer publication when refreshes
/// are concurrent. A serialized monitor times out that wait, publishes stale,
/// and only then discovers/publishes newest.
private final class OutOfOrderInventoryDiscoverer: CameraCaptureDeviceDiscovering,
    @unchecked Sendable
{
    let staleDiscoveryStarted = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private let initial: [CameraCaptureDeviceDescriptor]
    private let stale: [CameraCaptureDeviceDescriptor]
    private let newest: [CameraCaptureDeviceDescriptor]
    private let newestPublished: DispatchSemaphore
    private var discoveryCount = 0

    init(
        initial: [CameraCaptureDeviceDescriptor],
        stale: [CameraCaptureDeviceDescriptor],
        newest: [CameraCaptureDeviceDescriptor],
        newestPublished: DispatchSemaphore
    ) {
        self.initial = initial
        self.stale = stale
        self.newest = newest
        self.newestPublished = newestPublished
    }

    func discoverVideoDevices() -> [CameraCaptureDeviceDescriptor] {
        let call = lock.withLock {
            discoveryCount += 1
            return discoveryCount
        }
        switch call {
        case 1:
            return initial
        case 2:
            staleDiscoveryStarted.signal()
            _ = newestPublished.wait(timeout: .now() + 1)
            return stale
        default:
            return newest
        }
    }
}

private final class InventorySnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [CameraDeviceInventorySnapshot] = []

    var values: [CameraDeviceInventorySnapshot] {
        lock.withLock { snapshots }
    }

    func append(_ snapshot: CameraDeviceInventorySnapshot) {
        lock.withLock {
            snapshots.append(snapshot)
        }
    }
}

private final class InventoryTestObservation: CameraDeviceInventoryObservation,
    @unchecked Sendable
{
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

private final class InventoryTestEventObserver: CameraDeviceInventoryEventObserving,
    @unchecked Sendable
{
    let token = InventoryTestObservation()
    private(set) var observationCount = 0
    private var handler: (@Sendable () -> Void)?

    func observeChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> any CameraDeviceInventoryObservation {
        observationCount += 1
        self.handler = handler
        return token
    }

    func sendChange() {
        handler?()
    }
}
