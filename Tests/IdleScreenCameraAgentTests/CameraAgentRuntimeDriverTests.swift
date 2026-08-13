import CoreVideo
import Foundation
import IdleScreenCamera
import Testing
@testable import IdleScreenCameraAgentCore

@Suite("Camera agent runtime driver", .serialized)
struct CameraAgentRuntimeDriverTests {
    @Test("cancelling delayed scheduler work releases its closure captures")
    func cancelledDelayedWorkReleasesCaptures() throws {
        let scheduler = DispatchCameraAgentRuntimeScheduler(queue: DispatchQueue(
            label: "com.idlescreen.tests.cancelled-runtime-work"
        ))
        var retained: RuntimeLifetimeSentinel? = RuntimeLifetimeSentinel()
        weak let observed = retained
        _ = try #require(retained)
        let work = scheduler.enqueue(after: 60) { [retained] in
            _ = retained
        }
        retained = nil

        #expect(observed != nil)
        work.cancel()
        #expect(observed == nil)
    }

    @Test("inventory callbacks are serialized and select only an automatic physical camera")
    func inventoryCallbacksAreSerializedAndPhysicalOnly() throws {
        let harness = try RuntimeHarness()
        let continuity = CameraCaptureDeviceDescriptor(
            uniqueID: "iphone",
            name: "iPhone",
            kind: .continuity
        )
        let deskView = CameraCaptureDeviceDescriptor(
            uniqueID: "desk-view",
            name: "Desk View",
            kind: .deskView
        )
        let builtIn = CameraCaptureDeviceDescriptor(
            uniqueID: "built-in",
            name: "Built-in",
            kind: .builtIn
        )

        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 1,
            devices: []
        ))
        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 2,
            devices: [continuity, deskView]
        ))
        #expect(harness.receiver.captureEvents.isEmpty)
        harness.scheduler.runAllReady()
        #expect(harness.receiver.captureEvents == [.deviceUnavailable])

        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 3,
            devices: [continuity, deskView, builtIn]
        ))
        harness.scheduler.runAllReady()
        #expect(harness.receiver.captureEvents == [
            .deviceUnavailable,
            .deviceAvailable,
        ])

        harness.driver.perform(
            .configureCapture(generation: 1),
            configuration: harness.configuration
        )
        harness.driver.perform(
            .startCapture(generation: 1),
            configuration: harness.configuration
        )
        harness.scheduler.runAllReady()
        #expect(harness.controller.starts.map(\.request.preferredDeviceID) == ["built-in"])
    }

    @Test("shutdown fences queued and later inventory callbacks")
    func inventoryCallbacksAreCancelled() throws {
        let harness = try RuntimeHarness()
        let builtIn = CameraCaptureDeviceDescriptor(
            uniqueID: "built-in",
            name: "Built-in",
            kind: .builtIn
        )

        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 1,
            devices: []
        ))
        harness.driver.cancelDeviceInventoryCallbacks()
        harness.scheduler.runAllReady()
        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 2,
            devices: [builtIn]
        ))
        harness.scheduler.runAllReady()

        #expect(harness.receiver.captureEvents.isEmpty)
    }

    @Test("inventory drives no-device wait, external upgrade, stable disconnect, and fallback restart")
    func inventoryDrivesControlledServiceReselection() throws {
        let harness = try RuntimeHarness()
        let policy = try #require(CameraAgentPeerPolicy(
            expectedTeamIdentifier: "TEAM123",
            companionBundleIdentifiers: ["com.idlescreen.app"],
            screenSaverBundleIdentifiers: ["com.idlescreen.app.screensaver"]
        ))
        let limits = try #require(CameraAgentCaptureLimits(
            maximumWidth: 1_280,
            maximumHeight: 720,
            maximumFramesPerSecond: 30,
            maximumMailboxSlotCount: 3
        ))
        let recoveryScheduler = harness.scheduler
        let builtService = CameraAgentService(
            peerPolicy: policy,
            captureLimits: limits,
            leaseTimeToLive: 5,
            initialAuthorization: .authorized,
            initialDeviceAvailability: false,
            agentIdentity: makeTestAgentIdentity()!,
            recoveryClock: { recoveryScheduler.currentTime },
            clock: { Date(timeIntervalSinceReferenceDate: 1_000) },
            identifierGenerator: UUID.init,
            driver: harness.driver
        )
        let service = try #require(builtService)
        harness.driver.bind(to: service)
        let connection = try service.admit(peer: CameraAgentAuthenticatedPeer(
            processIdentifier: 84,
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.idlescreen.app.screensaver"
        ))
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 3
        ))
        let builtIn = CameraCaptureDeviceDescriptor(
            uniqueID: "built-in",
            name: "Built-in",
            kind: .builtIn
        )
        let external = CameraCaptureDeviceDescriptor(
            uniqueID: "external",
            name: "External",
            kind: .external
        )
        let continuity = CameraCaptureDeviceDescriptor(
            uniqueID: "iphone",
            name: "iPhone",
            kind: .continuity
        )

        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 1,
            devices: []
        ))
        _ = connection.beginStream(request)
        harness.scheduler.runAllReady()
        #expect(harness.controller.starts.isEmpty)

        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 2,
            devices: [continuity]
        ))
        harness.scheduler.runAllReady()
        #expect(harness.controller.starts.isEmpty)

        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 3,
            devices: [builtIn, continuity]
        ))
        harness.scheduler.runAllReady()
        #expect(harness.controller.starts.map(\.request.preferredDeviceID) == ["built-in"])

        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 4,
            devices: [builtIn, external, continuity]
        ))
        harness.scheduler.runAllReady()
        #expect(harness.controller.stopCount == 1)
        harness.controller.completeStop()
        harness.scheduler.runAllReady()
        #expect(harness.controller.starts.map(\.request.preferredDeviceID) == [
            "built-in",
            "external",
        ])

        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 5,
            devices: [external, continuity]
        ))
        harness.scheduler.runAllReady()
        #expect(harness.controller.stopCount == 1)

        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 6,
            devices: [builtIn, continuity]
        ))
        harness.scheduler.runAllReady()
        #expect(harness.controller.stopCount == 2)
        harness.controller.completeStop()
        harness.scheduler.runAllReady()
        #expect(harness.controller.starts.map(\.request.preferredDeviceID) == [
            "built-in",
            "external",
            "built-in",
        ])
    }

    @Test("perform always enqueues and preserves configure-before-start ordering")
    func performIsAsynchronousAndOrdered() throws {
        let harness = try RuntimeHarness()

        harness.driver.perform(.configureCapture(generation: 7), configuration: harness.configuration)
        harness.driver.perform(.startCapture(generation: 7), configuration: harness.configuration)

        #expect(harness.publisher.operations.isEmpty)
        #expect(harness.controller.starts.isEmpty)
        #expect(harness.receiver.events.isEmpty)

        harness.scheduler.runAllReady()

        #expect(harness.publisher.operations == [
            .configure(generation: 7, producerStreamEpoch: 1)
        ])
        #expect(harness.controller.starts.map(\.request) == [
            CameraCaptureRequest(
                width: 960,
                height: 540,
                maximumFramesPerSecond: 24
            )
        ])
        #expect(harness.receiver.events == [
            .capture(.captureStarted(generation: 7))
        ])
    }

    @Test("only the permission action may invoke AVFoundation authorization requesting")
    func permissionIsNeverRequestedByConfigureOrStart() throws {
        let harness = try RuntimeHarness()
        harness.permission.result = .authorized

        harness.driver.perform(.configureCapture(generation: 1), configuration: harness.configuration)
        harness.driver.perform(.startCapture(generation: 1), configuration: harness.configuration)
        harness.scheduler.runAllReady()

        #expect(harness.permission.requestCount == 0)

        harness.driver.perform(.requestPermission, configuration: nil)
        #expect(harness.permission.requestCount == 0)
        harness.scheduler.runNextReady()

        #expect(harness.permission.requestCount == 1)
        #expect(harness.receiver.events == [.capture(.captureStarted(generation: 1))])

        harness.scheduler.runAllReady()
        #expect(harness.receiver.events == [
            .capture(.captureStarted(generation: 1)),
            .authorization(.authorized),
        ])
    }

    @Test("frame publication keeps the CVPixelBuffer zero-copy and maps first then next metadata")
    func mapsFirstAndSubsequentFrames() throws {
        let harness = try RuntimeHarness()
        try harness.start(generation: 4)
        let first = try makeFrame(sequence: 11)
        let second = try makeFrame(sequence: 12)

        harness.controller.starts[0].frameHandler(first)
        harness.controller.starts[0].frameHandler(second)
        harness.scheduler.runAllReady()

        #expect(harness.publisher.frames.count == 2)
        #expect(harness.publisher.frames[0].frame === first)
        #expect(harness.publisher.frames[0].frame.pixelBuffer === first.pixelBuffer)
        #expect(harness.publisher.frames[1].frame === second)
        #expect(harness.receiver.events.suffix(2) == [
            .capture(.firstFrame(generation: 4, sequence: 1)),
            .capture(.nextFrame(generation: 4, sequence: 2)),
        ])

        harness.scheduler.fireNextScheduled()
        harness.scheduler.runAllReady()
        #expect(!harness.receiver.captureEvents.contains {
            if case .recoveryFailure(_, .firstFrameTimeout, _) = $0 { return true }
            return false
        })
    }

    @Test("first-frame timeout is fenced and reports one typed recovery failure")
    func firstFrameTimeoutIsTypedAndFenced() throws {
        let harness = try RuntimeHarness()
        try harness.start(generation: 4)

        #expect(harness.scheduler.scheduledDelays == [
            CameraAgentRuntimeDriver.maximumFirstFrameLatency,
        ])
        harness.scheduler.fireNextScheduled()
        harness.scheduler.runAllReady()

        #expect(harness.receiver.captureEvents.last == .recoveryFailure(
            generation: 4,
            cause: .firstFrameTimeout,
            code: "capture-first-frame-timeout"
        ))
    }

    @Test("the first published frame arms a typed two-second stall deadline")
    func firstPublishedFrameArmsStallDeadline() throws {
        let harness = try RuntimeHarness()
        try harness.start(generation: 4)

        harness.controller.starts[0].frameHandler(try makeFrame(sequence: 1))
        harness.scheduler.runAllReady()

        #expect(harness.scheduler.scheduledDelays == [
            CameraAgentRuntimeDriver.maximumFrameStallLatency,
        ])
        harness.scheduler.fireScheduled(
            delay: CameraAgentRuntimeDriver.maximumFrameStallLatency
        )
        harness.scheduler.runAllReady()

        #expect(harness.receiver.captureEvents.last == .recoveryFailure(
            generation: 4,
            cause: .frameStall,
            code: "capture-frame-stall"
        ))
    }

    @Test("higher published sequences replace one watchdog and fence its cancelled callback")
    func higherSequenceReplacesAndFencesWatchdog() throws {
        let harness = try RuntimeHarness()
        try harness.start(generation: 5)

        for sequence in 1...100 {
            harness.controller.starts[0].frameHandler(try makeFrame(
                sequence: UInt64(sequence)
            ))
        }
        harness.scheduler.runAllReady()

        #expect(harness.scheduler.scheduledDelays == [
            CameraAgentRuntimeDriver.maximumFrameStallLatency,
        ])
        harness.scheduler.forceCancelledScheduled(
            delay: CameraAgentRuntimeDriver.maximumFrameStallLatency
        )
        harness.scheduler.runAllReady()
        #expect(!harness.receiver.captureEvents.contains {
            if case .recoveryFailure(_, .frameStall, _) = $0 { return true }
            return false
        })

        harness.scheduler.fireScheduled(
            delay: CameraAgentRuntimeDriver.maximumFrameStallLatency
        )
        harness.scheduler.runAllReady()
        #expect(harness.receiver.captureEvents.filter {
            if case .recoveryFailure(5, .frameStall, "capture-frame-stall") = $0 {
                return true
            }
            return false
        }.count == 1)
    }

    @Test("stop sleep shutdown and generation changes fence old stall deadlines")
    func lifecycleFencesStallDeadlines() throws {
        let stopped = try RuntimeHarness()
        try stopped.start(generation: 1)
        stopped.controller.starts[0].frameHandler(try makeFrame(sequence: 1))
        stopped.scheduler.runAllReady()
        stopped.driver.perform(
            .stopCapture(generation: 1, within: 2),
            configuration: stopped.configuration
        )
        stopped.scheduler.runAllReady()
        stopped.scheduler.forceCancelledScheduled(
            delay: CameraAgentRuntimeDriver.maximumFrameStallLatency
        )
        stopped.scheduler.runAllReady()
        #expect(stopped.receiver.frameStallFailureCount == 0)

        let sleeping = try RuntimeHarness()
        try sleeping.start(generation: 2)
        sleeping.controller.starts[0].frameHandler(try makeFrame(sequence: 1))
        sleeping.scheduler.runAllReady()
        sleeping.driver.receiveSleep()
        sleeping.scheduler.runAllReady()
        sleeping.scheduler.forceCancelledScheduled(
            delay: CameraAgentRuntimeDriver.maximumFrameStallLatency
        )
        sleeping.scheduler.runAllReady()
        #expect(sleeping.receiver.frameStallFailureCount == 0)

        let shutdown = try RuntimeHarness()
        try shutdown.start(generation: 3)
        shutdown.controller.starts[0].frameHandler(try makeFrame(sequence: 1))
        shutdown.scheduler.runAllReady()
        shutdown.driver.cancelDeviceInventoryCallbacks()
        // Force the callback before the queued cancellation to prove the
        // synchronous shutdown fence is authoritative.
        shutdown.scheduler.forceActiveScheduled(
            delay: CameraAgentRuntimeDriver.maximumFrameStallLatency
        )
        shutdown.scheduler.runAllReady()
        #expect(shutdown.receiver.frameStallFailureCount == 0)

        let restarted = try RuntimeHarness()
        try restarted.start(generation: 4)
        restarted.controller.starts[0].frameHandler(try makeFrame(sequence: 1))
        restarted.scheduler.runAllReady()
        restarted.driver.perform(
            .stopCapture(generation: 4, within: 2),
            configuration: restarted.configuration
        )
        restarted.scheduler.runAllReady()
        restarted.controller.completeStop()
        restarted.scheduler.runAllReady()
        try restarted.start(generation: 5)
        restarted.controller.starts[1].frameHandler(try makeFrame(sequence: 1))
        restarted.scheduler.runAllReady()
        restarted.scheduler.forceCancelledScheduled(
            delay: CameraAgentRuntimeDriver.maximumFrameStallLatency
        )
        restarted.scheduler.runAllReady()
        #expect(restarted.receiver.frameStallFailureCount == 0)
        restarted.scheduler.fireScheduled(
            delay: CameraAgentRuntimeDriver.maximumFrameStallLatency
        )
        // The resolved stop deadline shares the two-second duration and is
        // deliberately inert; the second live item is generation 5's stall.
        restarted.scheduler.fireScheduled(
            delay: CameraAgentRuntimeDriver.maximumFrameStallLatency
        )
        restarted.scheduler.runAllReady()
        #expect(restarted.receiver.captureEvents.last == .recoveryFailure(
            generation: 5,
            cause: .frameStall,
            code: "capture-frame-stall"
        ))
    }

    @Test("start, device, permission, and media-services failures use typed recovery causes")
    func typedRecoveryFailures() throws {
        let startFailure = try RuntimeHarness()
        startFailure.controller.startError = CameraCaptureSessionControllerError.sessionStartFailed
        startFailure.driver.perform(
            .configureCapture(generation: 1),
            configuration: startFailure.configuration
        )
        startFailure.driver.perform(
            .startCapture(generation: 1),
            configuration: startFailure.configuration
        )
        startFailure.scheduler.runAllReady()
        #expect(startFailure.receiver.captureEvents.last == .recoveryFailure(
            generation: 1,
            cause: .startFailure,
            code: "capture-start-failed"
        ))

        let noDevice = try RuntimeHarness()
        noDevice.controller.startError = CameraCaptureSessionControllerError.noVideoDevice
        noDevice.driver.perform(
            .configureCapture(generation: 2),
            configuration: noDevice.configuration
        )
        noDevice.driver.perform(
            .startCapture(generation: 2),
            configuration: noDevice.configuration
        )
        noDevice.scheduler.runAllReady()
        #expect(noDevice.receiver.captureEvents.last == .recoveryFailure(
            generation: 2,
            cause: .noDevice,
            code: "camera-device-unavailable"
        ))

        let permission = try RuntimeHarness()
        permission.controller.startError = CameraCaptureSessionControllerError
            .authorizationRequired(.denied)
        permission.driver.perform(
            .configureCapture(generation: 3),
            configuration: permission.configuration
        )
        permission.driver.perform(
            .startCapture(generation: 3),
            configuration: permission.configuration
        )
        permission.scheduler.runAllReady()
        #expect(permission.receiver.events.suffix(2) == [
            .authorization(.denied),
            .capture(.recoveryFailure(
                generation: 3,
                cause: .permissionUnavailable,
                code: "camera-permission-unavailable"
            )),
        ])

        let mediaReset = try RuntimeHarness()
        try mediaReset.start(generation: 4)
        mediaReset.controller.starts[0].eventHandler(.runtimeError(
            domain: "AVFoundationErrorDomain",
            code: -11819
        ))
        mediaReset.scheduler.runAllReady()
        #expect(mediaReset.receiver.captureEvents.last == .recoveryFailure(
            generation: 4,
            cause: .mediaServicesReset,
            code: "capture-runtime--11819"
        ))
    }

    @Test("a no-device start failure re-arms recovery on an identical inventory probe")
    func noDeviceFailureAcceptsAuthoritativeProbe() throws {
        let harness = try RuntimeHarness()
        let camera = CameraCaptureDeviceDescriptor(
            uniqueID: "camera",
            name: "Camera",
            kind: .external
        )
        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 1,
            devices: [camera]
        ))
        harness.scheduler.runAllReady()

        harness.controller.startError = CameraCaptureSessionControllerError.noVideoDevice
        harness.driver.perform(
            .configureCapture(generation: 1),
            configuration: harness.configuration
        )
        harness.driver.perform(
            .startCapture(generation: 1),
            configuration: harness.configuration
        )
        harness.scheduler.runAllReady()

        harness.driver.receiveDeviceInventory(CameraDeviceInventorySnapshot(
            generation: 2,
            devices: [camera]
        ))
        harness.scheduler.runAllReady()

        #expect(harness.receiver.captureEvents.suffix(2) == [
            .recoveryFailure(
                generation: 1,
                cause: .noDevice,
                code: "camera-device-unavailable"
            ),
            .deviceAvailable,
        ])
    }

    @Test("a recovery schedule uses the serial scheduler and preserves generation")
    func recoveryScheduleUsesSerialScheduler() throws {
        let harness = try RuntimeHarness()

        harness.driver.perform(
            .scheduleRecovery(generation: 9, after: 0.25),
            configuration: nil
        )
        harness.scheduler.runAllReady()

        #expect(harness.scheduler.scheduledDelays == [0.25])
        #expect(harness.receiver.captureEvents.isEmpty)
        harness.scheduler.fireNextScheduled()
        harness.scheduler.runAllReady()
        #expect(harness.receiver.captureEvents == [
            .recoveryRetryDeadlineReached(generation: 9),
        ])
    }

    @Test("zero and non-finite presentation timestamps are rejected before publication")
    func rejectsInvalidPresentationTimestamps() throws {
        let harness = try RuntimeHarness()
        try harness.start(generation: 6)

        harness.controller.starts[0].frameHandler(try makeFrame(
            sequence: 1,
            presentationTimeSeconds: 0
        ))
        harness.controller.starts[0].frameHandler(try makeFrame(
            sequence: 2,
            presentationTimeSeconds: .infinity
        ))
        harness.scheduler.runAllReady()

        #expect(harness.publisher.frames.isEmpty)
        #expect(harness.receiver.captureEvents.suffix(2) == [
            .runtimeError(generation: 6, code: "invalid-frame-timestamp"),
            .runtimeError(generation: 6, code: "invalid-frame-timestamp"),
        ])
    }

    @Test("stale generations and non-advancing frame sequences never reach the publisher or service")
    func rejectsStaleGenerationCallbacks() throws {
        let harness = try RuntimeHarness()
        try harness.start(generation: 1)
        let staleFrameHandler = harness.controller.starts[0].frameHandler
        let staleEventHandler = harness.controller.starts[0].eventHandler

        harness.driver.perform(
            .stopCapture(generation: 1, within: CameraAgentStateMachine.maximumStopLatency),
            configuration: harness.configuration
        )
        harness.scheduler.runAllReady()
        harness.controller.completeStop()
        harness.scheduler.runAllReady()
        try harness.start(generation: 2)
        let currentFrameHandler = harness.controller.starts[1].frameHandler

        staleFrameHandler(try makeFrame(sequence: 90))
        staleEventHandler(.interrupted(reasonCode: 9))
        currentFrameHandler(try makeFrame(sequence: 3))
        currentFrameHandler(try makeFrame(sequence: 3))
        currentFrameHandler(try makeFrame(sequence: 2))
        currentFrameHandler(try makeFrame(sequence: 4))
        harness.scheduler.runAllReady()

        #expect(harness.publisher.frames.map(\.generation) == [2, 2])
        #expect(harness.publisher.frames.map { $0.frame.metadata.sequence } == [3, 4])
        #expect(harness.receiver.captureEvents.suffix(2) == [
            .firstFrame(generation: 2, sequence: 1),
            .nextFrame(generation: 2, sequence: 2),
        ])
        #expect(!harness.receiver.captureEvents.contains(.interrupted(generation: 1)))
    }

    @Test("capture callbacks defer device changes to inventory and map runtime lifecycle events")
    func mapsRuntimeCallbacks() throws {
        let harness = try RuntimeHarness()
        try harness.start(generation: 5, selectedDeviceID: "selected")
        let callback = harness.controller.starts[0].eventHandler

        callback(.deviceDisconnected(deviceID: "other"))
        callback(.deviceDisconnected(deviceID: "selected"))
        callback(.deviceConnected(.init(uniqueID: "replacement", name: "Replacement", kind: .external)))
        callback(.interrupted(reasonCode: 17))
        callback(.runtimeError(domain: "AVFoundationErrorDomain", code: -11819))
        harness.driver.receiveSleep()
        harness.driver.receiveWake()
        harness.scheduler.runAllReady()

        #expect(harness.receiver.captureEvents.suffix(4) == [
            .interrupted(generation: 5),
            .recoveryFailure(
                generation: 5,
                cause: .mediaServicesReset,
                code: "capture-runtime--11819"
            ),
            .sleep,
            .wake,
        ])
    }

    @Test("stop uses the requested two-second ceiling and reports a missed deadline")
    func stopDeadlineIsObservable() throws {
        let harness = try RuntimeHarness()
        try harness.start(generation: 8)

        harness.driver.perform(
            .stopCapture(generation: 8, within: 2),
            configuration: harness.configuration
        )
        harness.scheduler.runAllReady()

        #expect(harness.controller.stopCount == 1)
        #expect(harness.scheduler.scheduledDelays == [2])
        #expect(!harness.receiver.captureEvents.contains(
            .runtimeError(generation: 8, code: "capture-stop-timeout")
        ))

        harness.scheduler.fireScheduled(delay: 2)
        harness.scheduler.runAllReady()
        #expect(harness.receiver.captureEvents.contains(
            .runtimeError(generation: 8, code: "capture-stop-timeout")
        ))
        #expect(harness.publisher.operations.filter { $0 == .finish(generation: 8) }.count == 1)
        #expect(harness.receiver.captureEvents.filter { $0 == .captureStopped(generation: 8) }.count == 1)

        harness.controller.completeStop()
        harness.scheduler.runAllReady()
        #expect(harness.publisher.operations.last == .finish(generation: 8))
        #expect(harness.receiver.captureEvents.last == .captureStopped(generation: 8))
        #expect(harness.publisher.operations.filter { $0 == .finish(generation: 8) }.count == 1)
        #expect(harness.receiver.captureEvents.filter { $0 == .captureStopped(generation: 8) }.count == 1)
    }

    @Test("a missed final-stop deadline completes teardown instead of wedging stopping")
    func missedFinalStopDeadlineCompletesTeardown() throws {
        let harness = try RuntimeHarness()
        let policy = try #require(CameraAgentPeerPolicy(
            expectedTeamIdentifier: "TEAM123",
            companionBundleIdentifiers: ["com.idlescreen.app"],
            screenSaverBundleIdentifiers: ["com.idlescreen.app.screensaver"]
        ))
        let limits = try #require(CameraAgentCaptureLimits(
            maximumWidth: 1_280,
            maximumHeight: 720,
            maximumFramesPerSecond: 30,
            maximumMailboxSlotCount: 3
        ))
        let recoveryScheduler = harness.scheduler
        let builtService = CameraAgentService(
            peerPolicy: policy,
            captureLimits: limits,
            leaseTimeToLive: 5,
            initialAuthorization: .authorized,
            agentIdentity: makeTestAgentIdentity()!,
            recoveryClock: { recoveryScheduler.currentTime },
            clock: { Date(timeIntervalSinceReferenceDate: 1_000) },
            identifierGenerator: UUID.init,
            driver: harness.driver
        )
        let service = try #require(builtService)
        harness.driver.bind(to: service)
        let consumer = try service.admit(peer: CameraAgentAuthenticatedPeer(
            processIdentifier: 84,
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.idlescreen.app.screensaver"
        ))
        let observer = try service.admit(peer: CameraAgentAuthenticatedPeer(
            processIdentifier: 85,
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.idlescreen.app"
        ))
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 3
        ))

        _ = consumer.beginStream(request)
        harness.scheduler.runAllReady()
        #expect(consumer.invalidate() == 1)
        harness.scheduler.runAllReady()
        #expect(harness.controller.stopCount == 1)

        harness.scheduler.fireScheduled(
            delay: CameraAgentStateMachine.maximumStopLatency
        )
        harness.scheduler.runAllReady()

        let diagnostic = observer.diagnosticSnapshot(try #require(
            IdleScreenCameraDiagnosticRequest()
        ))
        #expect(harness.publisher.operations.contains(.finish(generation: 1)))
        #expect(diagnostic.activeLeaseCount == 0)
        #expect(diagnostic.summary.contains("status=idle"))
        #expect(harness.controller.starts.count == 1)
    }

    @Test("a completed stop cancels the observable deadline result")
    func completedStopDoesNotReportTimeout() throws {
        let harness = try RuntimeHarness()
        try harness.start(generation: 3)

        harness.driver.perform(.stopCapture(generation: 3, within: 2), configuration: nil)
        harness.scheduler.runAllReady()
        harness.controller.completeStop()
        harness.scheduler.runAllReady()
        harness.scheduler.fireScheduled(delay: 2)
        harness.scheduler.runAllReady()

        #expect(harness.receiver.captureEvents.last == .captureStopped(generation: 3))
        #expect(!harness.receiver.captureEvents.contains(
            .runtimeError(generation: 3, code: "capture-stop-timeout")
        ))
    }

    @Test("the driver owns one controller and cannot start it twice for one generation")
    func oneControllerHasOneActiveSession() throws {
        let harness = try RuntimeHarness()

        harness.driver.perform(.configureCapture(generation: 1), configuration: harness.configuration)
        harness.driver.perform(.startCapture(generation: 1), configuration: harness.configuration)
        harness.driver.perform(.startCapture(generation: 1), configuration: harness.configuration)
        harness.scheduler.runAllReady()

        #expect(harness.controller.starts.count == 1)
        #expect(harness.receiver.captureEvents.first == .captureStarted(generation: 1))
    }

    @Test("transport identity is fixed and rejects absolute, traversal, and mutable publisher values")
    func validatesFixedRelativeTransportIdentifier() throws {
        let valid = try RuntimeHarness(transportIdentifier: "mailboxes/camera-frames-v1.mailbox")
        #expect(valid.driver.transportIdentifier(for: valid.configuration) == "mailboxes/camera-frames-v1.mailbox")

        #expect(RuntimeHarness.makeDriver(transportIdentifier: "/tmp/camera") == nil)
        #expect(RuntimeHarness.makeDriver(transportIdentifier: "mailboxes/../camera") == nil)
        #expect(RuntimeHarness.makeDriver(transportIdentifier: "mailboxes//camera") == nil)

        valid.publisher.transportIdentifier = "mailboxes/replaced.mailbox"
        #expect(valid.driver.transportIdentifier(for: valid.configuration) == nil)
    }

    @Test("mailbox adapter exposes only the fixed leaf and maps its complete lifecycle")
    func mailboxPublisherAdapterLifecycle() throws {
        let writer = FakeMailboxWriter(
            mailboxURL: URL(fileURLWithPath: "/private/app-group/camera-frames-v1.mailbox")
        )
        let publisher = try #require(CameraFrameMailboxRuntimePublisher(writer: writer))
        let configuration = CameraAgentStreamConfiguration(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 30,
            mailboxSlotCount: 3,
            producerStreamEpoch: 5
        )
        let frame = try makeFrame(sequence: 400)

        #expect(publisher.transportIdentifier == "camera-frames-v1.mailbox")
        try publisher.configure(generation: 12, configuration: configuration)
        let descriptor = try publisher.publish(frame, generation: 12)
        try publisher.finish(generation: 12)
        try publisher.invalidate()

        #expect(writer.startedEpochs == [5])
        #expect(writer.frames.count == 1)
        #expect(writer.frames[0] === frame)
        #expect(descriptor.streamEpoch == 5)
        #expect(descriptor.sequence == 1)
        #expect(writer.stopCount == 1)
        #expect(writer.invalidateCount == 1)
    }

    @Test("an active lease keeps one producer epoch while interruption advances capture generation")
    func activeLeaseRestartKeepsMailboxEpochAndSequence() throws {
        let harness = try RuntimeHarness()
        let policy = try #require(CameraAgentPeerPolicy(
            expectedTeamIdentifier: "TEAM123",
            companionBundleIdentifiers: ["com.idlescreen.app"],
            screenSaverBundleIdentifiers: ["com.idlescreen.app.screensaver"]
        ))
        let limits = try #require(CameraAgentCaptureLimits(
            maximumWidth: 1_280,
            maximumHeight: 720,
            maximumFramesPerSecond: 30,
            maximumMailboxSlotCount: 3
        ))
        let recoveryScheduler = harness.scheduler
        let builtService = CameraAgentService(
            peerPolicy: policy,
            captureLimits: limits,
            leaseTimeToLive: 5,
            initialAuthorization: .authorized,
            agentIdentity: makeTestAgentIdentity()!,
            recoveryClock: { recoveryScheduler.currentTime },
            clock: { Date(timeIntervalSinceReferenceDate: 1_000) },
            identifierGenerator: UUID.init,
            driver: harness.driver
        )
        let service = try #require(builtService)
        harness.driver.bind(to: service)
        let connection = try service.admit(peer: CameraAgentAuthenticatedPeer(
            processIdentifier: 84,
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.idlescreen.app.screensaver"
        ))
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 3
        ))

        let reply = connection.beginStream(request)
        harness.scheduler.runAllReady()
        harness.controller.starts[0].frameHandler(try makeFrame(sequence: 80))
        harness.scheduler.runAllReady()
        harness.controller.starts[0].eventHandler(.interrupted(reasonCode: 1))
        harness.scheduler.runAllReady()
        harness.controller.completeStop()
        harness.scheduler.runAllReady()
        harness.scheduler.fireScheduled(delay: 0.25)
        harness.scheduler.runAllReady()
        harness.controller.starts[1].frameHandler(try makeFrame(sequence: 1))
        harness.scheduler.runAllReady()

        let configurations = harness.publisher.operations.compactMap { operation -> (
            generation: UInt64,
            producerStreamEpoch: UInt64
        )? in
            guard case let .configure(generation, producerStreamEpoch) = operation else {
                return nil
            }
            return (generation, producerStreamEpoch)
        }
        let diagnostic = connection.diagnosticSnapshot(try #require(
            IdleScreenCameraDiagnosticRequest()
        ))
        #expect(reply.producerStreamEpoch == 1)
        #expect(configurations.map(\.generation) == [1, 2])
        #expect(configurations.map(\.producerStreamEpoch) == [1, 1])
        #expect(harness.publisher.frames.map(\.generation) == [1, 2])
        #expect(diagnostic.producerStreamEpoch == 1)
        #expect(diagnostic.summary.contains("generation=2;sequence=2"))
    }

    @Test("two production-service peers share capture through frames, recovery, and final close")
    func productionServiceAndDriverComposeAcrossTwoPeers() throws {
        let harness = try RuntimeHarness()
        let policy = try #require(CameraAgentPeerPolicy(
            expectedTeamIdentifier: "TEAM123",
            companionBundleIdentifiers: ["com.idlescreen.app"],
            screenSaverBundleIdentifiers: ["com.idlescreen.app.screensaver"]
        ))
        let limits = try #require(CameraAgentCaptureLimits(
            maximumWidth: 1_280,
            maximumHeight: 720,
            maximumFramesPerSecond: 30,
            maximumMailboxSlotCount: 3
        ))
        let recoveryScheduler = harness.scheduler
        let builtService = CameraAgentService(
            peerPolicy: policy,
            captureLimits: limits,
            leaseTimeToLive: 5,
            initialAuthorization: .authorized,
            agentIdentity: makeTestAgentIdentity()!,
            recoveryClock: { recoveryScheduler.currentTime },
            clock: { Date(timeIntervalSinceReferenceDate: 1_000) },
            identifierGenerator: UUID.init,
            driver: harness.driver
        )
        let service = try #require(builtService)
        harness.driver.bind(to: service)
        let first = try service.admit(peer: CameraAgentAuthenticatedPeer(
            processIdentifier: 84,
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.idlescreen.app"
        ))
        let second = try service.admit(peer: CameraAgentAuthenticatedPeer(
            processIdentifier: 85,
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.idlescreen.app.screensaver"
        ))
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 3
        ))
        let diagnosticRequest = try #require(IdleScreenCameraDiagnosticRequest())

        let firstReply = first.beginStream(request)
        let secondReply = second.beginStream(request)
        harness.scheduler.runAllReady()

        #expect(firstReply.accepted)
        #expect(secondReply.accepted)
        #expect(firstReply.leaseIdentifier != secondReply.leaseIdentifier)
        #expect(firstReply.producerStreamEpoch == 1)
        #expect(secondReply.producerStreamEpoch == 1)
        #expect(harness.controller.starts.count == 1)

        harness.controller.starts[0].frameHandler(try makeFrame(sequence: 80))
        harness.scheduler.runAllReady()
        let initialDiagnostic = second.diagnosticSnapshot(diagnosticRequest)
        #expect(harness.publisher.frames.map(\.generation) == [1])
        #expect(initialDiagnostic.activeLeaseCount == 2)
        #expect(initialDiagnostic.summary.contains("generation=1;sequence=1"))

        #expect(first.invalidate() == 1)
        harness.scheduler.runAllReady()
        #expect(harness.controller.stopCount == 0)
        #expect(second.diagnosticSnapshot(diagnosticRequest).activeLeaseCount == 1)

        harness.controller.starts[0].eventHandler(.interrupted(reasonCode: 1))
        harness.scheduler.runAllReady()
        #expect(harness.controller.stopCount == 1)
        harness.controller.completeStop()
        harness.scheduler.runAllReady()
        harness.scheduler.fireScheduled(delay: 0.25)
        harness.scheduler.runAllReady()
        #expect(harness.controller.starts.count == 2)

        harness.controller.starts[1].frameHandler(try makeFrame(sequence: 1))
        harness.scheduler.runAllReady()
        let recoveredDiagnostic = second.diagnosticSnapshot(diagnosticRequest)
        let configurations = harness.publisher.operations.compactMap { operation -> (
            generation: UInt64,
            producerStreamEpoch: UInt64
        )? in
            guard case let .configure(generation, producerStreamEpoch) = operation else {
                return nil
            }
            return (generation, producerStreamEpoch)
        }
        #expect(configurations.map(\.generation) == [1, 2])
        #expect(configurations.map(\.producerStreamEpoch) == [1, 1])
        #expect(harness.publisher.frames.map(\.generation) == [1, 2])
        #expect(recoveredDiagnostic.activeLeaseCount == 1)
        #expect(recoveredDiagnostic.producerStreamEpoch == 1)
        #expect(recoveredDiagnostic.summary.contains("generation=2;sequence=2"))

        #expect(second.invalidate() == 1)
        harness.scheduler.runAllReady()
        #expect(harness.controller.stopCount == 2)
        harness.controller.completeStop()
        harness.scheduler.runAllReady()
        #expect(harness.publisher.operations.contains(.finish(generation: 2)))
    }
}

private enum ReceivedRuntimeEvent: Equatable {
    case authorization(CameraAgentAuthorization)
    case capture(CameraAgentCaptureDriverEvent)
}

private final class RuntimeLifetimeSentinel: @unchecked Sendable {}

private final class RuntimeReceiver: CameraAgentRuntimeEventReceiving, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ReceivedRuntimeEvent] = []

    var events: [ReceivedRuntimeEvent] { lock.withLock { storage } }
    var captureEvents: [CameraAgentCaptureDriverEvent] {
        events.compactMap {
            guard case let .capture(event) = $0 else { return nil }
            return event
        }
    }
    var frameStallFailureCount: Int {
        captureEvents.count {
            if case .recoveryFailure(_, .frameStall, _) = $0 { return true }
            return false
        }
    }

    func receiveAuthorizationResult(_ result: CameraAgentAuthorization) {
        lock.withLock { storage.append(.authorization(result)) }
    }

    func receiveCaptureDriverEvent(_ event: CameraAgentCaptureDriverEvent) {
        lock.withLock { storage.append(.capture(event)) }
    }
}

private final class ManualRuntimeScheduler: CameraAgentRuntimeScheduling, @unchecked Sendable {
    private final class Work: CameraAgentRuntimeScheduledWork, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() {
            lock.withLock { cancelled = true }
        }
    }

    private struct Scheduled {
        let delay: TimeInterval
        let operation: @Sendable () -> Void
        let work: Work
    }

    private let lock = NSLock()
    private var ready: [@Sendable () -> Void] = []
    private var scheduled: [Scheduled] = []
    private var monotonicTime: TimeInterval = 1_000

    var scheduledDelays: [TimeInterval] {
        lock.withLock { scheduled.filter { !$0.work.isCancelled }.map(\.delay) }
    }
    var currentTime: TimeInterval { lock.withLock { monotonicTime } }

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
            scheduled.append(Scheduled(
                delay: delay,
                operation: operation,
                work: work
            ))
        }
        return work
    }

    func runNextReady() {
        let operation = lock.withLock { ready.isEmpty ? nil : ready.removeFirst() }
        operation?()
    }

    func runAllReady() {
        while lock.withLock({ !ready.isEmpty }) {
            runNextReady()
        }
    }

    func fireNextScheduled() {
        let operation = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let index = scheduled.indices.min(by: {
                let lhs = scheduled[$0]
                let rhs = scheduled[$1]
                if lhs.work.isCancelled != rhs.work.isCancelled {
                    return !lhs.work.isCancelled
                }
                return lhs.delay < rhs.delay
            }) else { return nil }
            let item = scheduled.remove(at: index)
            guard !item.work.isCancelled else { return nil }
            monotonicTime += item.delay
            return item.operation
        }
        operation?()
    }

    func fireScheduled(delay: TimeInterval) {
        let operation = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let index = scheduled.firstIndex(where: {
                $0.delay == delay && !$0.work.isCancelled
            }) else {
                return nil
            }
            let item = scheduled.remove(at: index)
            monotonicTime += item.delay
            return item.operation
        }
        operation?()
    }

    func forceCancelledScheduled(delay: TimeInterval) {
        forceScheduled(delay: delay, cancelled: true)
    }

    func forceActiveScheduled(delay: TimeInterval) {
        forceScheduled(delay: delay, cancelled: false)
    }

    private func forceScheduled(delay: TimeInterval, cancelled: Bool) {
        let operation = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let index = scheduled.firstIndex(where: {
                $0.delay == delay && $0.work.isCancelled == cancelled
            }) else {
                return nil
            }
            let item = scheduled.remove(at: index)
            monotonicTime += item.delay
            return item.operation
        }
        operation?()
    }
}

private final class FakePermissionRequester: CameraAgentAuthorizationRequesting, @unchecked Sendable {
    var result: CameraAgentAuthorization = .denied
    private(set) var requestCount = 0

    func requestVideoAccess(
        completion: @escaping @Sendable (CameraAgentAuthorization) -> Void
    ) {
        requestCount += 1
        completion(result)
    }
}

private final class FakeRuntimeCaptureController: CameraAgentRuntimeCaptureControlling, @unchecked Sendable {
    struct Start {
        let request: CameraCaptureRequest
        let frameHandler: @Sendable (CameraCaptureFrame) -> Void
        let eventHandler: @Sendable (CameraCaptureSessionEvent) -> Void
    }

    var selectedDevice = CameraCaptureDeviceDescriptor(
        uniqueID: "camera",
        name: "Camera",
        kind: .builtIn
    )
    var startError: Error?
    private(set) var starts: [Start] = []
    private(set) var stopCount = 0
    private var stopCompletion: (@Sendable () -> Void)?

    func start(
        _ request: CameraCaptureRequest,
        frameHandler: @escaping @Sendable (CameraCaptureFrame) -> Void,
        eventHandler: @escaping @Sendable (CameraCaptureSessionEvent) -> Void
    ) throws -> CameraCaptureDeviceDescriptor {
        if let startError { throw startError }
        starts.append(Start(
            request: request,
            frameHandler: frameHandler,
            eventHandler: eventHandler
        ))
        guard let preferredDeviceID = request.preferredDeviceID else {
            return selectedDevice
        }
        return CameraCaptureDeviceDescriptor(
            uniqueID: preferredDeviceID,
            name: preferredDeviceID,
            kind: selectedDevice.kind
        )
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        stopCount += 1
        stopCompletion = completion
    }

    func completeStop() {
        let completion = stopCompletion
        stopCompletion = nil
        completion?()
    }
}

private final class FakeFramePublisher: CameraAgentRuntimeFramePublishing, @unchecked Sendable {
    enum Operation: Equatable {
        case configure(generation: UInt64, producerStreamEpoch: UInt64)
        case publish(generation: UInt64, sequence: UInt64)
        case finish(generation: UInt64)
    }

    struct PublishedFrame {
        let frame: CameraCaptureFrame
        let generation: UInt64
    }

    var transportIdentifier: String
    private(set) var operations: [Operation] = []
    private(set) var frames: [PublishedFrame] = []
    private var streamEpoch: UInt64 = 0
    private var nextSequence: UInt64 = 1

    init(transportIdentifier: String) {
        self.transportIdentifier = transportIdentifier
    }

    func configure(
        generation: UInt64,
        configuration: CameraAgentStreamConfiguration
    ) throws {
        _ = configuration
        if streamEpoch != configuration.producerStreamEpoch {
            nextSequence = 1
        }
        streamEpoch = configuration.producerStreamEpoch
        operations.append(.configure(
            generation: generation,
            producerStreamEpoch: configuration.producerStreamEpoch
        ))
    }

    func publish(
        _ frame: CameraCaptureFrame,
        generation: UInt64
    ) throws -> IdleScreenCameraFrameDescriptor {
        frames.append(PublishedFrame(frame: frame, generation: generation))
        operations.append(.publish(
            generation: generation,
            sequence: frame.metadata.sequence
        ))
        defer { nextSequence += 1 }
        return IdleScreenCameraFrameDescriptor(
            protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
            streamEpoch: streamEpoch,
            sequence: nextSequence,
            timestamp: frame.metadata.presentationTimeSeconds,
            width: UInt64(frame.metadata.width),
            height: UInt64(frame.metadata.height),
            bytesPerRow: UInt64(frame.metadata.width * 4),
            pixelFormat: .bgra8Unorm,
            slotIndex: (nextSequence - 1) % 3,
            slotCount: 3
        )
    }

    func finish(generation: UInt64) throws {
        operations.append(.finish(generation: generation))
    }
}

private final class FakeMailboxWriter: CameraFrameMailboxWriting, @unchecked Sendable {
    let mailboxURL: URL
    private(set) var startedEpochs: [UInt64] = []
    private(set) var frames: [CameraCaptureFrame] = []
    private(set) var stopCount = 0
    private(set) var invalidateCount = 0
    private var activeEpoch: UInt64 = 0

    init(mailboxURL: URL) {
        self.mailboxURL = mailboxURL
    }

    func startStream(streamEpoch: UInt64) throws {
        activeEpoch = streamEpoch
        startedEpochs.append(streamEpoch)
    }

    func publish(_ frame: CameraCaptureFrame) throws -> IdleScreenCameraFrameDescriptor {
        frames.append(frame)
        return IdleScreenCameraFrameDescriptor(
            protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
            streamEpoch: activeEpoch,
            sequence: UInt64(frames.count),
            timestamp: frame.metadata.presentationTimeSeconds,
            width: UInt64(frame.metadata.width),
            height: UInt64(frame.metadata.height),
            bytesPerRow: UInt64(frame.metadata.width * 4),
            pixelFormat: .bgra8Unorm,
            slotIndex: UInt64(frames.count - 1) % 3,
            slotCount: 3
        )
    }

    func stopStream() throws {
        stopCount += 1
    }

    func invalidate() throws {
        invalidateCount += 1
    }
}

private final class RuntimeHarness {
    let scheduler = ManualRuntimeScheduler()
    let permission = FakePermissionRequester()
    let controller = FakeRuntimeCaptureController()
    let publisher: FakeFramePublisher
    let receiver = RuntimeReceiver()
    let driver: CameraAgentRuntimeDriver
    let configuration = CameraAgentStreamConfiguration(
        maximumWidth: 960,
        maximumHeight: 540,
        maximumFramesPerSecond: 24,
        mailboxSlotCount: 3
    )

    init(transportIdentifier: String = "mailboxes/camera-frames-v1.mailbox") throws {
        publisher = FakeFramePublisher(transportIdentifier: transportIdentifier)
        driver = try #require(Self.makeDriver(
            transportIdentifier: transportIdentifier,
            scheduler: scheduler,
            permission: permission,
            controller: controller,
            publisher: publisher
        ))
        driver.bind(to: receiver)
    }

    static func makeDriver(
        transportIdentifier: String,
        scheduler: ManualRuntimeScheduler = ManualRuntimeScheduler(),
        permission: FakePermissionRequester = FakePermissionRequester(),
        controller: FakeRuntimeCaptureController = FakeRuntimeCaptureController(),
        publisher: FakeFramePublisher? = nil
    ) -> CameraAgentRuntimeDriver? {
        CameraAgentRuntimeDriver(
            scheduler: scheduler,
            permissionRequester: permission,
            captureController: controller,
            framePublisher: publisher ?? FakeFramePublisher(
                transportIdentifier: transportIdentifier
            ),
            mediaServicesResetErrorDomain: "AVFoundationErrorDomain"
        )
    }

    func start(generation: UInt64, selectedDeviceID: String = "camera") throws {
        let previousStartCount = controller.starts.count
        controller.selectedDevice = CameraCaptureDeviceDescriptor(
            uniqueID: selectedDeviceID,
            name: "Camera",
            kind: .builtIn
        )
        driver.perform(.configureCapture(generation: generation), configuration: configuration)
        driver.perform(.startCapture(generation: generation), configuration: configuration)
        scheduler.runAllReady()
        #expect(controller.starts.count == previousStartCount + 1)
    }
}

private func makeFrame(
    sequence: UInt64,
    presentationTimeSeconds: Double? = nil
) throws -> CameraCaptureFrame {
    var storage: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        2,
        2,
        kCVPixelFormatType_32BGRA,
        nil,
        &storage
    )
    #expect(status == kCVReturnSuccess)
    let pixelBuffer = try #require(storage)
    return CameraCaptureFrame(
        pixelBuffer: pixelBuffer,
        metadata: CameraCaptureFrameMetadata(
            sequence: sequence,
            presentationTimeSeconds: presentationTimeSeconds ?? Double(sequence),
            width: 2,
            height: 2,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            pixelFormat: kCVPixelFormatType_32BGRA
        )
    )
}
