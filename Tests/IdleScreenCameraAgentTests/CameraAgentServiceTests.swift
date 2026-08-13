import Testing
import Foundation
import IdleScreenCamera
#if canImport(IdleScreenCameraAgentCore)
@testable import IdleScreenCameraAgentCore
#else
@testable import IdleScreenCameraAgent
#endif

@Suite("Authenticated camera-agent service")
struct CameraAgentServiceTests {
    @Test("peer role is derived from the verified same-team bundle identity")
    func derivesRoleFromAuthenticatedIdentity() throws {
        let policy = try #require(CameraAgentPeerPolicy(
            expectedTeamIdentifier: "TEAM123",
            companionBundleIdentifiers: ["com.idlescreen.app"],
            screenSaverBundleIdentifiers: ["com.idlescreen.app.screensaver"]
        ))

        let role = policy.role(for: CameraAgentAuthenticatedPeer(
            processIdentifier: 42,
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.idlescreen.app.screensaver"
        ))

        #expect(role == .screenSaver)
    }

    @Test("malformed policies and identities cannot create an admitted connection")
    func rejectsMalformedOrUntrustedPeers() throws {
        #expect(CameraAgentPeerPolicy(
            expectedTeamIdentifier: "",
            companionBundleIdentifiers: ["com.idlescreen.app"],
            screenSaverBundleIdentifiers: ["com.idlescreen.app.screensaver"]
        ) == nil)
        #expect(CameraAgentPeerPolicy(
            expectedTeamIdentifier: "TEAM123",
            companionBundleIdentifiers: ["com.idlescreen.shared"],
            screenSaverBundleIdentifiers: ["com.idlescreen.shared"]
        ) == nil)

        let harness = try ServiceHarness()
        for peer in [
            CameraAgentAuthenticatedPeer(
                processIdentifier: 42,
                teamIdentifier: "OTHERTEAM",
                bundleIdentifier: "com.idlescreen.app"
            ),
            CameraAgentAuthenticatedPeer(
                processIdentifier: 42,
                teamIdentifier: "TEAM123",
                bundleIdentifier: "com.example.impostor"
            ),
            CameraAgentAuthenticatedPeer(
                processIdentifier: 0,
                teamIdentifier: "TEAM123",
                bundleIdentifier: "com.idlescreen.app"
            ),
        ] {
            #expect(throws: CameraAgentAdmissionError.unauthorizedPeer) {
                try harness.service.admit(peer: peer)
            }
        }
    }

    @Test("only the companion's explicit authorization request can ask for camera permission")
    func permissionRequestRequiresCompanionAction() throws {
        let harness = try ServiceHarness(authorization: .notDetermined)
        let companion = try harness.service.admit(peer: harness.companionPeer())
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let authorizationRequest = try #require(IdleScreenCameraAuthorizationRequest())

        let deniedReply = screenSaver.requestAuthorization(authorizationRequest)
        #expect(!deniedReply.accepted)
        #expect(deniedReply.errorCode == .notAuthorized)
        #expect(deniedReply.status == .notDetermined)
        #expect(harness.driver.invocations.isEmpty)

        let acceptedReply = companion.requestAuthorization(authorizationRequest)
        #expect(acceptedReply.accepted)
        #expect(acceptedReply.errorCode == .none)
        #expect(acceptedReply.status == .notDetermined)
        #expect(harness.driver.invocations.map(\.action) == [
            .requestPermission,
            .publish(CameraAgentSnapshot(
                status: .requestingPermission,
                authorization: .notDetermined,
                activeLeaseDemand: 0,
                generation: 0,
                sequence: 0
            )),
        ])
    }

    @Test("a stream request never triggers an implicit camera permission prompt")
    func streamCannotPromptForPermission() throws {
        let harness = try ServiceHarness(authorization: .notDetermined)
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 30,
            mailboxSlotCount: 2
        ))

        let reply = screenSaver.beginStream(request)

        #expect(!reply.accepted)
        #expect(reply.errorCode == .notAuthorized)
        #expect(reply.leaseIdentifier == nil)
        #expect(harness.driver.invocations.isEmpty)
    }

    @Test("an external grant is refreshed without prompting before demand starts")
    func externalGrantRefreshesBeforeDemand() throws {
        let harness = try ServiceHarness(authorization: .denied)
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let statusRequest = try #require(IdleScreenCameraStatusRequest())
        let beginRequest = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))

        harness.authorizationChecker.status = .authorized
        let refreshed = screenSaver.authorizationStatus(statusRequest)
        let reply = screenSaver.beginStream(beginRequest)

        #expect(refreshed.accepted)
        #expect(refreshed.status == .authorized)
        #expect(reply.accepted)
        #expect(harness.authorizationChecker.statusCount == 2)
        #expect(harness.driver.invocations.filter(\.action.isPermissionRequest).isEmpty)
        #expect(harness.driver.invocations.filter {
            if case .startCapture = $0.action { return true }
            return false
        }.count == 1)
    }

    @Test("an external revocation refresh stops active capture and publishes fallback")
    func externalRevocationStopsCapture() throws {
        let harness = try ServiceHarness(authorization: .authorized)
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let beginRequest = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        let statusRequest = try #require(IdleScreenCameraStatusRequest())
        _ = screenSaver.beginStream(beginRequest)
        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 1))

        harness.authorizationChecker.status = .denied
        let refreshed = screenSaver.authorizationStatus(statusRequest)
        let diagnostic = screenSaver.diagnosticSnapshot(try #require(
            IdleScreenCameraDiagnosticRequest()
        ))

        #expect(refreshed.status == .denied)
        #expect(stopActionCount(in: harness.driver.invocations) == 1)
        #expect(diagnostic.authorizationStatus == .denied)
        #expect(!diagnostic.captureActive)
        #expect(diagnostic.activeLeaseCount == 1)
        #expect(diagnostic.summary.contains("fallback-authorization-denied"))
        #expect(harness.driver.invocations.filter(\.action.isPermissionRequest).isEmpty)
    }

    @Test("the active-demand probe falls back on revocation and resumes after regrant")
    func activeDemandProbeRecoversAuthorization() throws {
        let harness = try ServiceHarness(authorization: .authorized)
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let beginRequest = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        _ = screenSaver.beginStream(beginRequest)
        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 1))

        harness.authorizationChecker.status = .denied
        harness.service.refreshAuthorizationForActiveDemand()
        harness.service.receiveCaptureDriverEvent(.captureStopped(generation: 1))

        #expect(stopActionCount(in: harness.driver.invocations) == 1)
        #expect(screenSaver.diagnosticSnapshot(try #require(
            IdleScreenCameraDiagnosticRequest()
        )).activeLeaseCount == 1)

        harness.authorizationChecker.status = .authorized
        harness.service.refreshAuthorizationForActiveDemand()

        #expect(harness.driver.invocations.filter {
            if case .startCapture = $0.action { return true }
            return false
        }.count == 2)
        #expect(harness.driver.invocations.filter(\.action.isPermissionRequest).isEmpty)
    }

    @Test("the authorization probe stays inert without active lease demand")
    func authorizationProbeRequiresDemand() throws {
        let harness = try ServiceHarness(authorization: .authorized)

        harness.authorizationChecker.status = .denied
        harness.service.refreshAuthorizationForActiveDemand()

        #expect(harness.authorizationChecker.statusCount == 0)
        #expect(harness.driver.invocations.isEmpty)
    }

    @Test("wake refreshes authorization before reconciling sleeping demand")
    func wakeRefreshesBeforeDemandReconciliation() throws {
        let harness = try ServiceHarness(authorization: .authorized)
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let beginRequest = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        _ = screenSaver.beginStream(beginRequest)
        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 1))
        harness.service.receiveCaptureDriverEvent(.sleep)
        harness.service.receiveCaptureDriverEvent(.captureStopped(generation: 1))

        harness.authorizationChecker.status = .denied
        harness.service.receiveCaptureDriverEvent(.wake)
        let diagnostic = screenSaver.diagnosticSnapshot(try #require(
            IdleScreenCameraDiagnosticRequest()
        ))

        #expect(harness.authorizationChecker.statusCount == 2)
        #expect(diagnostic.authorizationStatus == .denied)
        #expect(diagnostic.summary.contains("fallback-authorization-denied"))
        #expect(harness.driver.invocations.filter {
            if case .startCapture = $0.action { return true }
            return false
        }.count == 1)
        #expect(harness.driver.invocations.filter(\.action.isPermissionRequest).isEmpty)
    }

    @Test("multiple display leases share one clamped capture and stop only after the final release")
    func coalescesMultiDisplayLeases() throws {
        let harness = try ServiceHarness()
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: IdleScreenCameraWire.maximumWidth,
            maximumHeight: IdleScreenCameraWire.maximumHeight,
            maximumFramesPerSecond: IdleScreenCameraWire.maximumFramesPerSecond,
            mailboxSlotCount: IdleScreenCameraWire.maximumMailboxSlotCount
        ))

        let first = screenSaver.beginStream(request)
        let second = screenSaver.beginStream(request)

        #expect(first.accepted)
        #expect(second.accepted)
        #expect(first.leaseIdentifier != second.leaseIdentifier)
        #expect(first.producerStreamEpoch == 1)
        #expect(second.producerStreamEpoch == 1)
        #expect(first.transportIdentifier == "camera/frame-mailbox.bin")
        let expectedConfiguration = CameraAgentStreamConfiguration(
            maximumWidth: 1_280,
            maximumHeight: 720,
            maximumFramesPerSecond: 30,
            mailboxSlotCount: 2,
            producerStreamEpoch: 1
        )
        #expect(harness.driver.invocations.filter {
            if case .startCapture = $0.action { return true }
            return false
        }.count == 1)
        #expect(harness.driver.invocations.first {
            if case .configureCapture = $0.action { return true }
            return false
        }?.configuration == expectedConfiguration)

        let firstLease = try #require(first.leaseIdentifier)
        let firstEnd = try #require(IdleScreenCameraEndStreamRequest(
            leaseIdentifier: firstLease
        ))
        #expect(screenSaver.endStream(firstEnd).accepted)
        #expect(stopActionCount(in: harness.driver.invocations) == 0)

        let secondLease = try #require(second.leaseIdentifier)
        let secondEnd = try #require(IdleScreenCameraEndStreamRequest(
            leaseIdentifier: secondLease
        ))
        #expect(screenSaver.endStream(secondEnd).accepted)
        #expect(stopActionCount(in: harness.driver.invocations) == 1)
    }

    @Test("each service incarnation starts its lease epochs from its injected process seed")
    func processIncarnationSeedsProducerEpochs() throws {
        let processA = try ServiceHarness(producerStreamEpochSeed: 70_001)
        let processB = try ServiceHarness(producerStreamEpochSeed: 90_001)
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        let processAConnection = try processA.service.admit(
            peer: processA.screenSaverPeer()
        )
        let processBConnection = try processB.service.admit(
            peer: processB.screenSaverPeer()
        )

        let processAReply = processAConnection.beginStream(request)
        let processBReply = processBConnection.beginStream(request)

        #expect(processAReply.accepted)
        #expect(processAReply.producerStreamEpoch == 70_001)
        #expect(processBReply.accepted)
        #expect(processBReply.producerStreamEpoch == 90_001)
        #expect(processAReply.producerStreamEpoch != processBReply.producerStreamEpoch)
    }

    @Test("accepted diagnostics retain immutable process identity across stream epochs")
    func diagnosticsRetainProcessIdentityAcrossStreams() throws {
        let identity = try #require(makeTestAgentIdentity(processIncarnationEpoch: 70_001))
        let harness = try ServiceHarness(
            producerStreamEpochSeed: 70_001,
            agentIdentity: identity
        )
        let connection = try harness.service.admit(peer: harness.screenSaverPeer())
        let beginRequest = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        let diagnosticRequest = try #require(IdleScreenCameraDiagnosticRequest())

        let firstBegin = connection.beginStream(beginRequest)
        let firstDiagnostic = connection.diagnosticSnapshot(diagnosticRequest)
        let firstLeaseIdentifier = try #require(firstBegin.leaseIdentifier)
        _ = connection.endStream(try #require(IdleScreenCameraEndStreamRequest(
            leaseIdentifier: firstLeaseIdentifier
        )))
        let secondBegin = connection.beginStream(beginRequest)
        let secondDiagnostic = connection.diagnosticSnapshot(diagnosticRequest)

        #expect(firstBegin.producerStreamEpoch == 70_001)
        #expect(secondBegin.producerStreamEpoch == 70_002)
        #expect(firstDiagnostic.agentIdentity == identity)
        #expect(secondDiagnostic.agentIdentity == identity)
        #expect(secondDiagnostic.agentIdentity?.processIncarnationEpoch == 70_001)
    }

    @Test("a zero process epoch seed fails service construction closed")
    func rejectsZeroProcessEpochSeed() throws {
        let harness = try ServiceHarness()

        #expect(CameraAgentService(
            peerPolicy: harness.peerPolicy,
            captureLimits: harness.captureLimits,
            leaseTimeToLive: 5,
            initialAuthorization: .authorized,
            producerStreamEpochSeed: 0,
            agentIdentity: try #require(makeTestAgentIdentity(processIncarnationEpoch: 1)),
            clock: Date.init,
            identifierGenerator: UUID.init,
            driver: TestDriver()
        ) == nil)
    }

    @Test("a restarted process fences its old attempt and mailbox epoch")
    func restartedProcessFencesStaleAttemptAndMailboxFrame() throws {
        try withProcessEpochTemporaryContainer { containerURL in
            let processA = try ServiceHarness(producerStreamEpochSeed: 90_001)
            let processB = try ServiceHarness(producerStreamEpochSeed: 70_001)
            processA.driver.transportIdentifier = "camera-frames-v1.mailbox"
            processB.driver.transportIdentifier = "camera-frames-v1.mailbox"
            let processAConnection = try processA.service.admit(
                peer: processA.screenSaverPeer()
            )
            let processBConnection = try processB.service.admit(
                peer: processB.screenSaverPeer()
            )
            let connector = ProcessEpochServiceConnector(connections: [
                processAConnection,
                processBConnection,
            ])
            let scheduler = ProcessEpochLeaseScheduler()
            let source = try CameraFrameSource(appGroupContainerURL: containerURL)
            let updates = ProcessEpochLeaseUpdates(source: source)
            let configuration = try #require(CameraLeaseControllerConfiguration(
                maximumWidth: 640,
                maximumHeight: 480,
                maximumFramesPerSecond: 30,
                mailboxSlotCount: 2,
                leasePolicy: .production
            ))
            let controller = CameraLeaseController(
                client: connector,
                scheduler: scheduler,
                configuration: configuration,
                updateHandler: { updates.receive($0) }
            )
            let writerA = try CameraFrameMailboxWriter(
                appGroupContainerURL: containerURL
            )

            controller.start()
            let sessionA = try #require(connector.sessions.first)
            sessionA.deliverBegin()
            let epochA = try #require(sessionA.beginReply?.producerStreamEpoch)
            try writerA.startStream(streamEpoch: epochA)
            let pixelsA: [UInt8] = [10, 20, 30, 255]
            _ = try pixelsA.withUnsafeBytes { bytes in
                try writerA.publish(
                    bytes: bytes,
                    width: 1,
                    height: 1,
                    sourceBytesPerRow: 4,
                    timestamp: 1
                )
            }

            guard case let .frame(frameA, valueA) = source.withFrame({ _, pixels in
                pixels[0]
            }) else {
                Issue.record("Expected process A's mailbox frame")
                return
            }
            #expect(frameA.streamEpoch == 90_001)
            #expect(valueA == 10)

            connector.emit(.interrupted(attempt: 1))
            #expect(source.availability == .unavailable(.leaseUnavailable))
            _ = try pixelsA.withUnsafeBytes { bytes in
                try writerA.publish(
                    bytes: bytes,
                    width: 1,
                    height: 1,
                    sourceBytesPerRow: 4,
                    timestamp: 1.5
                )
            }
            let staleProcessAFrame = source.withFrame { _, _ in
                Issue.record("A fenced process-A mapping exposed stale pixels")
                return 0
            }
            #expect(staleProcessAFrame == .unavailable(.leaseUnavailable))

            scheduler.advance(by: 0.25)
            let sessionB = try #require(connector.sessions.last)
            let writerB = try CameraFrameMailboxWriter(
                appGroupContainerURL: containerURL
            )
            try writerB.startStream(streamEpoch: 70_001)
            let pixelsB: [UInt8] = [90, 80, 70, 255]
            _ = try pixelsB.withUnsafeBytes { bytes in
                try writerB.publish(
                    bytes: bytes,
                    width: 1,
                    height: 1,
                    sourceBytesPerRow: 4,
                    timestamp: 2
                )
            }

            sessionB.deliverBegin()
            let epochB = try #require(sessionB.beginReply?.producerStreamEpoch)
            #expect(epochB == 70_001)
            #expect(epochB != epochA)

            sessionA.deliverBegin()
            #expect(controller.state == .streaming(attempt: 2, streamEpoch: epochB))
            #expect(updates.availableEpochs == [epochA, epochB])

            guard case let .frame(frameB, valueB) = source.withFrame({ _, pixels in
                pixels[0]
            }) else {
                Issue.record("Expected process B's fresh mailbox frame")
                return
            }
            #expect(frameB.streamEpoch == epochB)
            #expect(frameB.sequence == 1)
            #expect(valueB == 90)

            controller.stop()
            try writerA.invalidate()
            try writerB.invalidate()
        }
    }

    @Test("capture restart waits for bounded recovery without rotating an active lease epoch")
    func captureRestartWaitsForRecoveryAndKeepsProducerEpoch() throws {
        let harness = try ServiceHarness()
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))

        let reply = screenSaver.beginStream(request)
        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 1))
        harness.service.receiveCaptureDriverEvent(.interrupted(generation: 1))
        harness.service.receiveCaptureDriverEvent(.captureStopped(generation: 1))

        #expect(harness.driver.invocations.compactMap(\.action.recoveryDelay) == [0.25])
        #expect(harness.driver.invocations.filter {
            if case .startCapture = $0.action { return true }
            return false
        }.count == 1)

        harness.environment.now.addTimeInterval(0.25)
        harness.service.receiveCaptureDriverEvent(
            .recoveryRetryDeadlineReached(generation: 1)
        )

        let configurations = harness.driver.invocations.compactMap { invocation -> (
            generation: UInt64,
            producerStreamEpoch: UInt64
        )? in
            guard case let .configureCapture(generation) = invocation.action,
                  let configuration = invocation.configuration else {
                return nil
            }
            return (generation, configuration.producerStreamEpoch)
        }
        #expect(reply.producerStreamEpoch == 1)
        #expect(configurations.map(\.generation) == [1, 2])
        #expect(configurations.map(\.producerStreamEpoch) == [1, 1])
    }

    @Test("a first frame queued behind a fatal event cannot cancel pending recovery")
    func rejectedFirstFrameDoesNotWedgeRecovery() throws {
        let harness = try ServiceHarness()
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        _ = screenSaver.beginStream(request)
        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 1))

        // Runtime callbacks and stop actions share an asynchronous serial queue.
        // A frame already queued behind the fatal event can therefore reach the
        // service while the reducer is stopping, before the stop action runs.
        harness.service.receiveCaptureDriverEvent(.interrupted(generation: 1))
        harness.service.receiveCaptureDriverEvent(.firstFrame(
            generation: 1,
            sequence: 1
        ))
        harness.service.receiveCaptureDriverEvent(.captureStopped(generation: 1))
        harness.environment.now.addTimeInterval(0.25)
        harness.service.receiveCaptureDriverEvent(
            .recoveryRetryDeadlineReached(generation: 1)
        )

        let configuredGenerations = harness.driver.invocations.compactMap {
            invocation -> UInt64? in
            guard case let .configureCapture(generation) = invocation.action else {
                return nil
            }
            return generation
        }
        #expect(configuredGenerations == [1, 2])
    }

    @Test("a healthy first frame resets backoff while device and permission waits schedule nothing")
    func recoveryPolicyUsesTypedWaitsAndHealthyReset() throws {
        let harness = try ServiceHarness()
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        _ = screenSaver.beginStream(request)
        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 1))
        harness.service.receiveCaptureDriverEvent(.recoveryFailure(
            generation: 1,
            cause: .startFailure,
            code: "capture-start-failed"
        ))
        harness.service.receiveCaptureDriverEvent(.captureStopped(generation: 1))
        harness.environment.now.addTimeInterval(0.25)
        harness.service.receiveCaptureDriverEvent(
            .recoveryRetryDeadlineReached(generation: 1)
        )
        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 2))
        harness.service.receiveCaptureDriverEvent(.firstFrame(generation: 2, sequence: 1))
        harness.service.receiveCaptureDriverEvent(.interrupted(generation: 2))

        #expect(harness.driver.invocations.compactMap(\.action.recoveryDelay) == [0.25, 0.25])

        let noDevice = try ServiceHarness()
        let noDeviceSaver = try noDevice.service.admit(peer: noDevice.screenSaverPeer())
        _ = noDeviceSaver.beginStream(request)
        noDevice.service.receiveCaptureDriverEvent(.recoveryFailure(
            generation: 1,
            cause: .noDevice,
            code: "camera-device-unavailable"
        ))
        #expect(noDevice.driver.invocations.compactMap(\.action.recoveryDelay).isEmpty)

        let permission = try ServiceHarness()
        let permissionSaver = try permission.service.admit(peer: permission.screenSaverPeer())
        _ = permissionSaver.beginStream(request)
        permission.service.receiveCaptureDriverEvent(.recoveryFailure(
            generation: 1,
            cause: .permissionUnavailable,
            code: "camera-permission-unavailable"
        ))
        #expect(permission.driver.invocations.compactMap(\.action.recoveryDelay).isEmpty)
    }

    @Test("a post-first-frame stall stops capture and enters bounded recovery")
    func frameStallUsesStopAndBackoffPath() throws {
        let harness = try ServiceHarness()
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        _ = screenSaver.beginStream(request)
        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 1))
        harness.service.receiveCaptureDriverEvent(.firstFrame(generation: 1, sequence: 1))

        harness.service.receiveCaptureDriverEvent(.recoveryFailure(
            generation: 1,
            cause: .frameStall,
            code: "capture-frame-stall"
        ))

        #expect(stopActionCount(in: harness.driver.invocations) == 1)
        #expect(harness.driver.invocations.compactMap(\.action.recoveryDelay) == [0.25])

        harness.service.receiveCaptureDriverEvent(.captureStopped(generation: 1))
        harness.environment.now.addTimeInterval(0.25)
        harness.service.receiveCaptureDriverEvent(
            .recoveryRetryDeadlineReached(generation: 1)
        )
        #expect(harness.driver.invocations.filter {
            if case .startCapture = $0.action { return true }
            return false
        }.count == 2)
    }

    @Test("media-services reset gets one immediate recovery per healthy run, then backoff")
    func mediaServicesResetCannotTightLoop() throws {
        let harness = try ServiceHarness()
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        _ = screenSaver.beginStream(request)
        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 1))
        harness.service.receiveCaptureDriverEvent(.firstFrame(generation: 1, sequence: 1))

        harness.service.receiveCaptureDriverEvent(.recoveryFailure(
            generation: 1,
            cause: .mediaServicesReset,
            code: "capture-runtime--11819"
        ))
        harness.service.receiveCaptureDriverEvent(.captureStopped(generation: 1))

        #expect(harness.driver.invocations.compactMap(\.action.recoveryDelay).isEmpty)
        #expect(harness.driver.invocations.filter {
            if case .startCapture = $0.action { return true }
            return false
        }.count == 2)

        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 2))
        harness.service.receiveCaptureDriverEvent(.recoveryFailure(
            generation: 2,
            cause: .mediaServicesReset,
            code: "capture-runtime--11819"
        ))

        #expect(harness.driver.invocations.compactMap(\.action.recoveryDelay) == [0.25])
    }

    @Test("leases are connection scoped and invalidation reclaims only that peer's demand")
    func scopesAndReclaimsConnectionLeases() throws {
        let harness = try ServiceHarness()
        let firstConnection = try harness.service.admit(peer: harness.screenSaverPeer(pid: 84))
        let secondConnection = try harness.service.admit(peer: harness.screenSaverPeer(pid: 85))
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        let first = firstConnection.beginStream(request)
        let second = secondConnection.beginStream(request)
        let secondLease = try #require(second.leaseIdentifier)
        let foreignEnd = try #require(IdleScreenCameraEndStreamRequest(
            leaseIdentifier: secondLease
        ))

        let rejected = firstConnection.endStream(foreignEnd)
        #expect(!rejected.accepted)
        #expect(rejected.errorCode == .invalidRequest)
        #expect(!firstConnection.heartbeat(leaseIdentifier: secondLease))
        #expect(stopActionCount(in: harness.driver.invocations) == 0)

        #expect(firstConnection.invalidate() == 1)
        #expect(firstConnection.invalidate() == 0)
        #expect(stopActionCount(in: harness.driver.invocations) == 0)
        #expect(!firstConnection.beginStream(request).accepted)

        #expect(secondConnection.invalidate() == 1)
        #expect(stopActionCount(in: harness.driver.invocations) == 1)
        #expect(first.accepted)
    }

    @Test("heartbeats extend a lease and expiration eventually stops abandoned demand")
    func heartbeatAndExpiration() throws {
        let harness = try ServiceHarness()
        let connection = try harness.service.admit(peer: harness.screenSaverPeer())
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        let reply = connection.beginStream(request)
        let lease = try #require(reply.leaseIdentifier)

        harness.environment.now.addTimeInterval(4)
        #expect(connection.heartbeat(leaseIdentifier: lease))
        harness.environment.now.addTimeInterval(4)
        #expect(harness.service.reapExpiredLeases() == 0)
        #expect(stopActionCount(in: harness.driver.invocations) == 0)

        harness.environment.now.addTimeInterval(2)
        #expect(harness.service.reapExpiredLeases() == 1)
        #expect(stopActionCount(in: harness.driver.invocations) == 1)
        #expect(!connection.heartbeat(leaseIdentifier: lease))
        #expect(harness.service.reapExpiredLeases() == 0)
    }

    @Test("the XPC heartbeat reply renews only a lease owned by that connection")
    func xpcHeartbeatIsConnectionScoped() throws {
        let harness = try ServiceHarness()
        let owner = try harness.service.admit(peer: harness.screenSaverPeer(pid: 84))
        let other = try harness.service.admit(peer: harness.screenSaverPeer(pid: 85))
        let begin = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        let lease = try #require(owner.beginStream(begin).leaseIdentifier)
        let heartbeat = try #require(
            IdleScreenCameraHeartbeatRequest(leaseIdentifier: lease)
        )

        #expect(owner.heartbeat(heartbeat).accepted)
        let rejected = other.heartbeat(heartbeat)
        #expect(!rejected.accepted)
        #expect(rejected.errorCode == .invalidRequest)
    }

    @Test("diagnostics are bounded, sanitized, and unavailable after invalidation")
    func diagnosticsAreBoundedAndSanitized() throws {
        let harness = try ServiceHarness()
        let connection = try harness.service.admit(peer: harness.screenSaverPeer())
        let beginRequest = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        let beginReply = connection.beginStream(beginRequest)
        let lease = try #require(beginReply.leaseIdentifier)
        let diagnosticRequest = try #require(IdleScreenCameraDiagnosticRequest())

        let snapshot = connection.diagnosticSnapshot(diagnosticRequest)

        #expect(snapshot.accepted)
        #expect(snapshot.authorizationStatus == .authorized)
        #expect(snapshot.captureActive)
        #expect(snapshot.activeLeaseCount == 1)
        #expect(snapshot.producerStreamEpoch == 1)
        #expect(snapshot.summary.utf8.count <= IdleScreenCameraWire.maximumDiagnosticSummaryUTF8ByteCount)
        #expect(!snapshot.summary.contains(lease))
        #expect(!snapshot.summary.contains("TEAM123"))
        #expect(!snapshot.summary.contains("com.idlescreen"))

        _ = connection.invalidate()
        let unavailable = connection.diagnosticSnapshot(diagnosticRequest)
        #expect(!unavailable.accepted)
        #expect(unavailable.errorCode == .notAuthorized)
        #expect(!unavailable.captureActive)
        #expect(unavailable.activeLeaseCount == 0)
        #expect(unavailable.producerStreamEpoch == 0)
    }

    @Test("invalid transport paths cannot create a lease or start capture")
    func rejectsInvalidTransportPath() throws {
        let harness = try ServiceHarness()
        harness.driver.transportIdentifier = "/tmp/claimed-by-client.bin"
        let connection = try harness.service.admit(peer: harness.screenSaverPeer())
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))

        let reply = connection.beginStream(request)

        #expect(!reply.accepted)
        #expect(reply.errorCode == .transportUnavailable)
        #expect(reply.leaseIdentifier == nil)
        #expect(harness.driver.invocations.isEmpty)
    }

    @Test("a driver authorization result enables streaming without another prompt")
    func authorizationResultEnablesStreaming() throws {
        let harness = try ServiceHarness(authorization: .notDetermined)
        let companion = try harness.service.admit(peer: harness.companionPeer())
        let screenSaver = try harness.service.admit(peer: harness.screenSaverPeer())
        let authorizationRequest = try #require(IdleScreenCameraAuthorizationRequest())
        _ = companion.requestAuthorization(authorizationRequest)

        harness.authorizationChecker.status = .authorized
        harness.service.receiveAuthorizationResult(.authorized)
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        let reply = screenSaver.beginStream(request)

        #expect(reply.accepted)
        #expect(harness.driver.invocations.filter(\.action.isPermissionRequest).count == 1)
    }

    @Test("capture callbacks advance the reducer but cannot inject permission or lease events")
    func captureCallbacksAreNarrowlyScoped() throws {
        let harness = try ServiceHarness()
        let connection = try harness.service.admit(peer: harness.screenSaverPeer())
        let request = try #require(IdleScreenCameraBeginStreamRequest(
            maximumWidth: 640,
            maximumHeight: 480,
            maximumFramesPerSecond: 24,
            mailboxSlotCount: 2
        ))
        _ = connection.beginStream(request)

        harness.service.receiveCaptureDriverEvent(.captureStarted(generation: 1))
        harness.service.receiveCaptureDriverEvent(.firstFrame(generation: 1, sequence: 1))
        let diagnosticRequest = try #require(IdleScreenCameraDiagnosticRequest())
        let streaming = connection.diagnosticSnapshot(diagnosticRequest)

        #expect(streaming.captureActive)
        #expect(streaming.summary.contains("status=streaming"))
        #expect(harness.driver.invocations.filter(\.action.isPermissionRequest).isEmpty)

        harness.service.receiveCaptureDriverEvent(.sleep)
        #expect(stopActionCount(in: harness.driver.invocations) == 1)
        #expect(harness.driver.invocations.filter(\.action.isPermissionRequest).isEmpty)
    }
}

private extension CameraAgentAction {
    var isPermissionRequest: Bool {
        if case .requestPermission = self { return true }
        return false
    }

    var recoveryDelay: TimeInterval? {
        guard case let .scheduleRecovery(_, after) = self else { return nil }
        return after
    }
}

private func stopActionCount(in invocations: [TestDriver.Invocation]) -> Int {
    invocations.filter {
        if case .stopCapture = $0.action { return true }
        return false
    }.count
}

private final class TestDriver: CameraAgentServiceDriver, @unchecked Sendable {
    struct Invocation: Equatable {
        let action: CameraAgentAction
        let configuration: CameraAgentStreamConfiguration?
    }

    var transportIdentifier = "camera/frame-mailbox.bin"
    private(set) var invocations: [Invocation] = []

    func transportIdentifier(for configuration: CameraAgentStreamConfiguration) -> String? {
        transportIdentifier
    }

    func perform(
        _ action: CameraAgentAction,
        configuration: CameraAgentStreamConfiguration?
    ) {
        invocations.append(Invocation(action: action, configuration: configuration))
    }
}

private final class TestEnvironment: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 1_000)
    private var nextIdentifier = UInt64(1)

    func makeIdentifier() -> UUID {
        defer { nextIdentifier += 1 }
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llu", nextIdentifier))!
    }
}

private struct ServiceHarness {
    let driver: TestDriver
    let environment: TestEnvironment
    let authorizationChecker: TestAuthorizationChecker
    let peerPolicy: CameraAgentPeerPolicy
    let captureLimits: CameraAgentCaptureLimits
    let agentIdentity: IdleScreenCameraAgentIdentity
    let service: CameraAgentService

    init(
        authorization: CameraAgentAuthorization = .authorized,
        producerStreamEpochSeed: UInt64 = 1,
        agentIdentity suppliedAgentIdentity: IdleScreenCameraAgentIdentity? = nil
    ) throws {
        driver = TestDriver()
        environment = TestEnvironment()
        authorizationChecker = TestAuthorizationChecker(
            status: CameraCaptureAuthorization(authorization)
        )
        peerPolicy = try #require(CameraAgentPeerPolicy(
            expectedTeamIdentifier: "TEAM123",
            companionBundleIdentifiers: ["com.idlescreen.app"],
            screenSaverBundleIdentifiers: ["com.idlescreen.app.screensaver"]
        ))
        captureLimits = try #require(CameraAgentCaptureLimits(
            maximumWidth: 1_280,
            maximumHeight: 720,
            maximumFramesPerSecond: 30,
            maximumMailboxSlotCount: 2
        ))
        agentIdentity = try #require(
            suppliedAgentIdentity
                ?? makeTestAgentIdentity(processIncarnationEpoch: producerStreamEpochSeed)
        )
        let builtService = CameraAgentService(
            peerPolicy: peerPolicy,
            captureLimits: captureLimits,
            leaseTimeToLive: 5,
            initialAuthorization: authorization,
            producerStreamEpochSeed: producerStreamEpochSeed,
            agentIdentity: agentIdentity,
            authorizationChecker: authorizationChecker,
            recoveryClock: { [environment] in
                environment.now.timeIntervalSinceReferenceDate
            },
            clock: { [environment] in environment.now },
            identifierGenerator: { [environment] in environment.makeIdentifier() },
            driver: driver
        )
        service = try #require(builtService)
    }

    func companionPeer(pid: Int32 = 42) -> CameraAgentAuthenticatedPeer {
        CameraAgentAuthenticatedPeer(
            processIdentifier: pid,
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.idlescreen.app"
        )
    }

    func screenSaverPeer(pid: Int32 = 84) -> CameraAgentAuthenticatedPeer {
        CameraAgentAuthenticatedPeer(
            processIdentifier: pid,
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.idlescreen.app.screensaver"
        )
    }
}

func makeTestAgentIdentity(
    processIdentifier: Int32 = 4_242,
    processIncarnationEpoch: UInt64 = 1,
    bundleIdentifier: String = "com.idlescreen.camera-agent",
    serviceIdentifier: String = "group.com.idlescreen.shared.camera-agent",
    teamIdentifier: String = "3524374A2S"
) -> IdleScreenCameraAgentIdentity? {
    IdleScreenCameraAgentIdentity(
        processIdentifier: processIdentifier,
        processIncarnationEpoch: processIncarnationEpoch,
        bundleIdentifier: bundleIdentifier,
        serviceIdentifier: serviceIdentifier,
        bundleVersion: "1",
        marketingVersion: "0.1",
        signingIdentifier: bundleIdentifier,
        teamIdentifier: teamIdentifier,
        codeDirectoryHash: String(repeating: "1", count: 40),
        executableSHA256: String(repeating: "a", count: 64),
        launchAgentSHA256: String(repeating: "b", count: 64),
        provisioningProfileSHA256: String(repeating: "c", count: 64),
        sourceAppPath: "/Applications/idlescreen.app"
    )
}

private final class TestAuthorizationChecker: CameraCaptureAuthorizationChecking,
    @unchecked Sendable
{
    var status: CameraCaptureAuthorization
    private(set) var statusCount = 0

    init(status: CameraCaptureAuthorization) {
        self.status = status
    }

    func authorizationStatus() -> CameraCaptureAuthorization {
        statusCount += 1
        return status
    }
}

private final class ProcessEpochServiceConnector: CameraAgentClientConnecting,
    @unchecked Sendable
{
    private var connections: [CameraAgentConnectionService]
    private var handlers: [UInt64: @Sendable (CameraAgentClientConnectionEvent) -> Void] = [:]
    private(set) var sessions: [ProcessEpochServiceSession] = []

    init(connections: [CameraAgentConnectionService]) {
        self.connections = connections
    }

    func connect(
        attempt: UInt64,
        eventHandler: @escaping @Sendable (CameraAgentClientConnectionEvent) -> Void
    ) -> any CameraAgentClientSession {
        let connection = connections.removeFirst()
        let session = ProcessEpochServiceSession(
            attempt: attempt,
            connection: connection
        )
        sessions.append(session)
        handlers[attempt] = eventHandler
        return session
    }

    func emit(_ event: CameraAgentClientConnectionEvent) {
        handlers[event.attempt]?(event)
    }
}

private final class ProcessEpochServiceSession: CameraAgentClientSession,
    @unchecked Sendable
{
    let attempt: UInt64
    private let connection: CameraAgentConnectionService
    private var beginRequest: IdleScreenCameraBeginStreamRequest?
    private var beginCallback: (@Sendable (IdleScreenCameraBeginStreamReply?) -> Void)?
    private(set) var beginReply: IdleScreenCameraBeginStreamReply?

    init(attempt: UInt64, connection: CameraAgentConnectionService) {
        self.attempt = attempt
        self.connection = connection
    }

    func beginStream(
        _ request: IdleScreenCameraBeginStreamRequest,
        reply: @escaping @Sendable (IdleScreenCameraBeginStreamReply?) -> Void
    ) {
        beginRequest = request
        beginCallback = reply
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
        reply(connection.endStream(request))
    }

    func invalidate() {}

    func deliverBegin() {
        guard let beginRequest, let beginCallback else { return }
        if beginReply == nil {
            beginReply = connection.beginStream(beginRequest)
        }
        beginCallback(beginReply)
    }
}

private final class ProcessEpochLeaseScheduler: CameraLeaseScheduling,
    @unchecked Sendable
{
    private final class Token: CameraLeaseScheduledTask, @unchecked Sendable {
        var isCancelled = false
        func cancel() { isCancelled = true }
    }

    private struct Job {
        let serial: UInt64
        let deadline: TimeInterval
        let token: Token
        let operation: @Sendable () -> Void
    }

    private(set) var now: TimeInterval = 0
    private var serial: UInt64 = 0
    private var jobs: [Job] = []

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any CameraLeaseScheduledTask {
        serial += 1
        let token = Token()
        jobs.append(Job(
            serial: serial,
            deadline: now + delay,
            token: token,
            operation: operation
        ))
        return token
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = jobs
            .filter({ !$0.token.isCancelled && $0.deadline <= target })
            .min(by: { ($0.deadline, $0.serial) < ($1.deadline, $1.serial) }) {
            jobs.removeAll { $0.serial == next.serial }
            now = next.deadline
            next.operation()
        }
        now = target
    }
}

private final class ProcessEpochLeaseUpdates: @unchecked Sendable {
    private let source: CameraFrameSource
    private let lock = NSLock()
    private var storage: [CameraLeaseControllerUpdate] = []

    init(source: CameraFrameSource) {
        self.source = source
    }

    var availableEpochs: [UInt64] {
        lock.withLock {
            storage.compactMap {
                guard case let .available(descriptor) = $0 else { return nil }
                return descriptor.producerStreamEpoch
            }
        }
    }

    func receive(_ update: CameraLeaseControllerUpdate) {
        lock.withLock { storage.append(update) }
        source.receive(update)
    }
}

private func withProcessEpochTemporaryContainer<Result>(
    _ body: (URL) throws -> Result
) throws -> Result {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "idlescreen-process-epoch-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

private extension CameraCaptureAuthorization {
    init(_ authorization: CameraAgentAuthorization) {
        switch authorization {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        }
    }
}
