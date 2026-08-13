import Foundation
import IdleScreenCamera
import Testing

private let fixtureAgentProcessIdentifier: Int32 = 4_242

enum IdentityHandshakeFailure: CaseIterable, Sendable {
    case nilReply
    case rejected
    case processMismatch
    case assessmentFailure
}

@MainActor
@Suite("Companion camera onboarding coordinator")
struct IdleScreenCompanionCameraClientTests {
    @Test("startup reads only service status and leaves every active effect inert")
    func startupReadsOnlyServiceStatus() {
        let harness = Harness(registration: .notRegistered)
        let client = harness.makeClient()

        #expect(harness.serviceStatusReadCount == 1)
        #expect(harness.registerCallCount == 0)
        #expect(harness.bootstrapCallCount == 0)
        #expect(harness.control.sessions.isEmpty)
        #expect(harness.openedSurfaces.isEmpty)
        #expect(harness.runtime.attachCalls.isEmpty)
        #expect(client.readinessSnapshot.serviceRegistration == .notRegistered)
        #expect(client.readinessSnapshot.authorization == .unknown)
        #expect(client.recommendedRepair == .registerAgent)
    }

    @Test("control connection is lazy and exists only for a visible Camera page")
    func visiblePageOwnsControlConnection() {
        let harness = Harness(registration: .enabled)
        let client = harness.makeClient()

        client.mainWindowDidOpen()
        client.mainWindowPresentationDidChange(isActive: true)
        #expect(harness.bootstrapCallCount == 0)
        #expect(harness.control.sessions.isEmpty)

        client.cameraPageDidAppear()
        client.cameraPageDidAppear()

        #expect(harness.bootstrapCallCount == 1)
        #expect(harness.control.sessions.count == 1)
        #expect(harness.control.sessions[0].statusRequestCount == 1)
        #expect(harness.control.sessions[0].diagnosticRequestCount == 1)
        #expect(harness.control.sessions[0].authorizationRequestCount == 0)

        client.cameraPageDidDisappear()
        client.cameraPageDidDisappear()

        #expect(harness.control.sessions[0].invalidateCallCount == 1)
        #expect(!client.isPreviewLeaseAttached)
    }

    @Test("nonprompting authorization status is required before permission repair")
    func statusPrecedesPermissionRepair() async throws {
        let harness = Harness(registration: .enabled)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)

        #expect(client.recommendedRepair == .refresh(.identity))
        #expect(session.authorizationRequestCount == 0)

        session.replyToNextHandshake(.notDetermined)
        await settleCallbacks()

        #expect(client.readinessSnapshot.authorization == .observed(.notDetermined))
        #expect(client.controlReachability == .reachable)
        #expect(client.recommendedRepair == .requestCameraAuthorization)
        #expect(session.authorizationRequestCount == 0)
    }

    @Test("registration and permission request occur only through the visible repair action")
    func explicitRegistrationAndPermission() async throws {
        let harness = Harness(
            registration: .notRegistered,
            registrationAfterRegister: .enabled
        )
        let client = harness.makeVisibleClient()

        #expect(harness.registerCallCount == 0)
        client.performRecommendedRepair()
        #expect(harness.registerCallCount == 1)
        #expect(harness.control.sessions.count == 1)

        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.notDetermined)
        await settleCallbacks()

        #expect(session.authorizationRequestCount == 0)
        client.performRecommendedRepair()
        #expect(session.authorizationRequestCount == 1)
        #expect(harness.scheduler.pendingDelays == [
            CameraAuthorizationPollingPolicy.pollInterval,
            CameraAuthorizationPollingPolicy.maximumDuration,
        ])

        session.replyToNextAuthorization(authorizationReply(.notDetermined))
        await settleCallbacks()

        #expect(session.authorizationRequestCount == 1)
        #expect(harness.scheduler.pendingCount == 2)
        harness.scheduler.fireNext()
        #expect(session.statusRequestCount == 2)

        session.replyToNextStatus(authorizationReply(.authorized))
        await settleCallbacks()

        #expect(session.authorizationRequestCount == 1)
        #expect(client.readinessSnapshot.authorization == .observed(.authorized))
        #expect(!client.isPreviewLeaseAttached)
        #expect(harness.runtime.attachCalls.isEmpty)
    }

    @Test("authorized status remains capture-free until preview is explicitly requested")
    func previewDemandRequiresExplicitAction() async throws {
        let harness = Harness(registration: .enabled)
        harness.runtime.frameAvailability = .waitingForFrame(epoch: 11)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)

        client.startCameraPreview()
        #expect(!client.isPreviewLeaseRequested)
        #expect(harness.runtime.attachCalls.isEmpty)

        session.replyToNextHandshake(.authorized)
        await settleCallbacks()

        #expect(!client.isPreviewLeaseRequested)
        #expect(!client.isPreviewLeaseAttached)
        #expect(harness.runtime.attachCalls.isEmpty)

        client.startCameraPreview()

        #expect(client.isPreviewLeaseRequested)
        #expect(client.isPreviewLeaseAttached)
        #expect(harness.runtime.attachCalls == ["companion-camera-page-preview"])

        client.stopCameraPreview()

        #expect(!client.isPreviewLeaseRequested)
        #expect(!client.isPreviewLeaseAttached)
        #expect(harness.runtime.detachCalls == ["companion-camera-page-preview"])
    }

    @Test("Studio preview observes revoked permission and resumes after restoration")
    func studioPreviewRecoversFromAuthorizationChange() async throws {
        let harness = Harness(registration: .enabled)
        harness.runtime.frameAvailability = .waitingForFrame(epoch: 12)
        let client = harness.makeClient()

        client.mainWindowDidOpen()
        client.mainWindowPresentationDidChange(isActive: true)
        client.studioCameraPreviewDidAppear()

        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.authorized)
        await settleCallbacks()
        client.startCameraPreview()

        #expect(client.isPreviewLeaseRequested)
        #expect(client.isPreviewLeaseAttached)
        #expect(session.statusRequestCount == 1)

        #expect(harness.scheduler.fireNext(
            delay: IdleScreenCompanionCameraClient.authorizationRefreshInterval
        ))
        #expect(session.statusRequestCount == 2)
        session.replyToNextStatus(authorizationReply(.denied))
        await settleCallbacks()

        #expect(client.isPreviewLeaseRequested)
        #expect(!client.isPreviewLeaseAttached)
        #expect(client.readinessSnapshot.authorization == .observed(.denied))

        #expect(harness.scheduler.fireNext(
            delay: IdleScreenCompanionCameraClient.authorizationRefreshInterval
        ))
        #expect(session.statusRequestCount == 3)
        session.replyToNextStatus(authorizationReply(.authorized))
        await settleCallbacks()

        #expect(client.isPreviewLeaseRequested)
        #expect(client.isPreviewLeaseAttached)
        #expect(harness.runtime.attachCalls == [
            "companion-camera-page-preview",
            "companion-camera-page-preview",
        ])
    }

    @Test("Camera Privacy round trips replace only the helper and preserve preview intent")
    func privacyRoundTripRebindsHelperAndResumesPreview() async throws {
        let harness = Harness(registration: .enabled)
        harness.runtime.frameAvailability = .waitingForFrame(epoch: 13)
        let client = harness.makeClient()

        client.mainWindowDidOpen()
        client.mainWindowPresentationDidChange(isActive: true)
        client.studioCameraPreviewDidAppear()

        let initialSession = try #require(harness.control.sessions.first)
        initialSession.replyToNextHandshake(.authorized)
        await settleCallbacks()
        client.startCameraPreview()
        #expect(client.isPreviewLeaseAttached)

        client.openCameraPrivacySettings()
        #expect(harness.openedSurfaces == [.cameraPrivacySettings])
        client.mainWindowPresentationDidChange(isActive: false)
        #expect(client.isPreviewLeaseRequested)
        #expect(!client.isPreviewLeaseAttached)

        harness.control.remoteProcessIdentifier = fixtureAgentProcessIdentifier + 1
        harness.identityAssessment = Harness.verifiedIdentityAssessment(
            processIdentifier: fixtureAgentProcessIdentifier + 1,
            generationIdentifier: "helper-generation-privacy-denied",
            processEpoch: 70_002
        )
        client.mainWindowPresentationDidChange(isActive: true)
        let deniedSession = try #require(harness.control.sessions.last)
        deniedSession.replyToNextStatus(authorizationReply(.denied))
        await settleCallbacks()
        deniedSession.replyToNextDiagnostic(makeDiagnosticSnapshot(
            authorizationStatus: .denied,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "permission-denied",
            processIdentifier: deniedSession.remoteProcessIdentifier,
            processIncarnationEpoch: 70_002
        ))
        await settleCallbacks()

        #expect({
            if case .verified = client.cameraAgentRepairState { true } else { false }
        }())
        #expect(client.isPreviewLeaseRequested)
        #expect(!client.isPreviewLeaseAttached)
        #expect(client.readinessSnapshot.authorization == .observed(.denied))

        client.openCameraPrivacySettings()
        client.mainWindowPresentationDidChange(isActive: false)
        harness.control.remoteProcessIdentifier = fixtureAgentProcessIdentifier + 2
        harness.identityAssessment = Harness.verifiedIdentityAssessment(
            processIdentifier: fixtureAgentProcessIdentifier + 2,
            generationIdentifier: "helper-generation-privacy-restored",
            processEpoch: 70_003
        )
        client.mainWindowPresentationDidChange(isActive: true)
        let restoredSession = try #require(harness.control.sessions.last)
        restoredSession.replyToNextStatus(authorizationReply(.authorized))
        await settleCallbacks()
        restoredSession.replyToNextDiagnostic(makeDiagnosticSnapshot(
            authorizationStatus: .authorized,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "ready",
            processIdentifier: restoredSession.remoteProcessIdentifier,
            processIncarnationEpoch: 70_003
        ))
        await settleCallbacks()

        #expect({
            if case .verified = client.cameraAgentRepairState { true } else { false }
        }())
        #expect(client.isPreviewLeaseRequested)
        #expect(client.isPreviewLeaseAttached)
        #expect(harness.runtime.attachCalls == [
            "companion-camera-page-preview",
            "companion-camera-page-preview",
        ])
    }

    @Test("a failed Camera Privacy open does not arm helper replacement")
    func failedPrivacyOpenDoesNotReplaceHelper() {
        let harness = Harness(
            registration: .enabled,
            repairSurfaceOpenSucceeds: false
        )
        let client = harness.makeVisibleClient()

        client.openCameraPrivacySettings()
        #expect(harness.openedSurfaces.isEmpty)
        client.mainWindowPresentationDidChange(isActive: false)
        client.mainWindowPresentationDidChange(isActive: true)

        #expect(harness.registerCallCount == 0)
        #expect(client.cameraAgentRepairState == .idle)
    }

    @Test("hidden upgrade rebind authenticates a new helper without camera demand")
    func hiddenUpgradeRebindAuthenticatesNewHelper() async throws {
        let assessment = IdleScreenCompanionCameraIdentityAssessment(
            observation: .current,
            generationIdentifier: "helper-generation-upgraded",
            runningBundleVersion: "25",
            runningSourceAppPath: "/Applications/idlescreen.app",
            runningProcessIdentifier: fixtureAgentProcessIdentifier,
            runningProcessEpoch: 9_001,
            runningCodeDirectoryHash: String(repeating: "a", count: 40)
        )
        let harness = Harness(
            registration: .enabled,
            identityAssessment: assessment
        )
        let client = harness.makeClient()
        var receipt: IdleScreenCompanionCameraAgentRebindReceipt?
        var failureMessage: String?

        client.rebindCameraAgentForInstalledUpgrade(
            previousProcessIdentifier: 111
        ) { result, failure in
            receipt = result
            failureMessage = failure
        }

        #expect(harness.registerCallCount == 1)
        #expect(harness.control.sessions.count == 1)
        #expect(client.cameraAgentRepairState == .verifying)
        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.authorized)
        await settleCallbacks()

        #expect(failureMessage == nil)
        #expect(receipt?.previousProcessIdentifier == 111)
        #expect(receipt?.processIdentifier == fixtureAgentProcessIdentifier)
        #expect(receipt?.processEpoch == 9_001)
        #expect(receipt?.bundleVersion == "25")
        #expect(receipt?.sourceAppPath == "/Applications/idlescreen.app")
        #expect(receipt?.codeDirectoryHash == String(repeating: "a", count: 40))
        #expect(harness.runtime.attachCalls.isEmpty)
        #expect(!client.isPreviewLeaseRequested)
        #expect(!client.isPreviewLeaseAttached)
    }

    @Test(
        "Studio frame polling suppresses obsolete preview images while device inventory stays active"
    )
    func studioFramePollingSuppressesObsoletePreviewImages() async throws {
        let harness = Harness(registration: .enabled)
        harness.runtime.frameAvailability = .waitingForFrame(epoch: 14)
        let client = harness.makeClient()

        client.mainWindowDidOpen()
        client.mainWindowPresentationDidChange(isActive: true)
        client.studioCameraPreviewDidAppear()
        client.cameraPageDidAppear()

        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.authorized)
        await settleCallbacks()

        #expect(session.cameraDeviceRequestCount == 1)
        client.startCameraPreview()
        for _ in 0..<3 {
            #expect(harness.scheduler.fireNext(
                delay: IdleScreenCompanionCameraClient.framePollInterval
            ))
        }

        #expect(harness.runtime.previewImageRequests == [
            false,
            false,
            false,
            false,
        ])
        #expect(session.cameraDeviceRequestCount == 1)
    }

    @Test("silent helper replacement times out and completes hidden rebind once")
    func silentReplacementTimesOut() {
        let harness = Harness(
            registration: .enabled,
            defersReplacementCompletion: true
        )
        let client = harness.makeClient()
        var completionCallCount = 0
        var failureMessage: String?

        client.rebindCameraAgentForInstalledUpgrade(
            previousProcessIdentifier: 111
        ) { _, failure in
            completionCallCount += 1
            failureMessage = failure
        }

        #expect(client.cameraAgentRepairState == .replacing)
        #expect(harness.scheduler.pendingCount == 1)
        harness.scheduler.fireNext()

        #expect({
            if case .failed = client.cameraAgentRepairState { true } else { false }
        }())
        #expect(completionCallCount == 1)
        #expect(failureMessage?.contains("replacement") == true)
        #expect(harness.scheduler.pendingCount == 0)
    }

    @Test("late helper replacement callback cannot revive a timed-out rebind")
    func lateReplacementCallbackIsFenced() {
        let harness = Harness(
            registration: .enabled,
            defersReplacementCompletion: true
        )
        let client = harness.makeClient()
        var completionCallCount = 0

        client.rebindCameraAgentForInstalledUpgrade(
            previousProcessIdentifier: 111
        ) { _, _ in
            completionCallCount += 1
        }
        harness.scheduler.fireNext()
        harness.completeDeferredReplacement(.succeeded(.enabled))

        #expect({
            if case .failed = client.cameraAgentRepairState { true } else { false }
        }())
        #expect(completionCallCount == 1)
        #expect(harness.control.sessions.isEmpty)
        #expect(harness.scheduler.pendingCount == 0)
    }

    @Test("replacement success cancels its deadline before verification starts")
    func replacementSuccessCancelsReplacementDeadline() {
        let harness = Harness(
            registration: .enabled,
            defersReplacementCompletion: true
        )
        let client = harness.makeClient()
        var failureMessage: String?

        client.rebindCameraAgentForInstalledUpgrade(
            previousProcessIdentifier: 111
        ) { _, failure in
            failureMessage = failure
        }

        #expect(harness.scheduler.pendingCount == 1)
        harness.completeDeferredReplacement(.succeeded(.enabled))
        #expect(client.cameraAgentRepairState == .verifying)
        #expect(harness.scheduler.pendingCount == 1)

        harness.scheduler.fireNext()
        #expect({
            if case .failed = client.cameraAgentRepairState { true } else { false }
        }())
        #expect(failureMessage?.contains("verified helper identity") == true)
    }

    @Test("explicit preview demand consumes the mailbox before reporting frame readiness")
    func previewDemandActuallyReadsFrames() async throws {
        let harness = Harness(registration: .enabled)
        harness.runtime.frameAvailability = .waitingForFrame(epoch: 11)
        harness.runtime.frameAvailabilityAfterRefresh = [
            .available(epoch: 11, sequence: 1),
            .available(epoch: 11, sequence: 2),
        ]
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.authorized)
        await settleCallbacks()

        client.startCameraPreview()

        #expect(harness.runtime.refreshFrameAvailabilityCallCount == 1)
        #expect(client.frameReadiness == .ready)
        #expect(client.frameAvailability == .available(epoch: 11, sequence: 1))

        #expect(harness.scheduler.fireNext(
            delay: IdleScreenCompanionCameraClient.framePollInterval
        ))
        #expect(harness.runtime.refreshFrameAvailabilityCallCount == 2)
        #expect(client.frameAvailability == .available(epoch: 11, sequence: 2))
    }

    @Test("requires-approval and privacy surfaces open only from their explicit repairs")
    func repairSurfacesRequireClicks() async throws {
        let approvalHarness = Harness(registration: .requiresApproval)
        let approvalClient = approvalHarness.makeVisibleClient()

        #expect(approvalHarness.openedSurfaces.isEmpty)
        approvalClient.performRecommendedRepair()
        #expect(approvalHarness.openedSurfaces == [.backgroundItemsSettings])

        let privacyHarness = Harness(registration: .enabled)
        let privacyClient = privacyHarness.makeVisibleClient()
        let session = try #require(privacyHarness.control.sessions.first)
        session.replyToNextHandshake(.denied)
        await settleCallbacks()

        #expect(privacyHarness.openedSurfaces.isEmpty)
        #expect(privacyClient.recommendedRepair == .openRepairSurface(.cameraPrivacySettings))
        privacyClient.performRecommendedRepair()
        #expect(privacyHarness.openedSurfaces == [.cameraPrivacySettings])
        #expect(session.authorizationRequestCount == 0)
    }

    @Test("a missing agent offers and performs direct registration")
    func missingAgentRegistrationIsEffective() {
        let harness = Harness(registration: .notFound)
        let client = harness.makeVisibleClient()

        #expect(client.recommendedRepair == .registerAgent)
        #expect(harness.openedSurfaces.isEmpty)
        #expect(harness.registerCallCount == 0)

        client.performRecommendedRepair()

        #expect(harness.registerCallCount == 1)
        #expect(harness.openedSurfaces.isEmpty)
    }

    @Test("typed request failures distinguish timeout from unavailable transport", arguments: [
        (
            CameraAgentControlRequestFailure.timeout,
            CameraAgentControlReachability.timedOut
        ),
        (
            CameraAgentControlRequestFailure.transportUnavailable,
            CameraAgentControlReachability.unreachable
        ),
    ])
    func typedControlFailures(
        failure: CameraAgentControlRequestFailure,
        expected: CameraAgentControlReachability
    ) async throws {
        let harness = Harness(registration: .enabled)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.authorized)
        await settleCallbacks()

        harness.control.emit(.requestFailed(attempt: session.attempt, failure: failure))
        await settleCallbacks()

        #expect(client.controlReachability == expected)
        session.replayLastStatus(nil)
        await settleCallbacks()
        #expect(client.controlReachability == expected)
        #expect(client.readinessSnapshot.liveSnapshot == .unavailable)
        #expect(client.recommendedRepair == .refresh(.liveSnapshot))
        #expect(!client.isPreviewLeaseAttached)
        #expect(harness.scheduler.pendingCount == 0)

        client.performRecommendedRepair()
        #expect(session.diagnosticRequestCount == 2)
    }

    @Test("current interruption tears down preview and fences late replies")
    func currentInterruptionTearsDownControl() async throws {
        let harness = Harness(registration: .enabled)
        harness.runtime.frameAvailability = .waitingForFrame(epoch: 6)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.authorized)
        await settleCallbacks()
        client.startCameraPreview()

        #expect(client.isPreviewLeaseAttached)
        #expect(harness.scheduler.pendingCount == 2)

        harness.control.emit(.interrupted(attempt: session.attempt))
        await settleCallbacks()

        #expect(client.controlReachability == .unreachable)
        #expect(!client.isPreviewLeaseAttached)
        #expect(harness.scheduler.pendingCount == 0)
        #expect(session.invalidateCallCount == 1)

        session.replayLastStatus(authorizationReply(.authorized))
        harness.control.emit(.invalidated(attempt: session.attempt))
        await settleCallbacks()
        #expect(client.controlReachability == .unreachable)
    }

    @Test("nil or rejected authorization reply fails closed without repeating permission CTA")
    func rejectedPermissionReplyFailsClosed() async throws {
        let harness = Harness(registration: .enabled)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.notDetermined)
        await settleCallbacks()
        client.performRecommendedRepair()

        session.replyToNextAuthorization(nil)
        await settleCallbacks()

        #expect(client.controlReachability == .unreachable)
        #expect(client.recommendedRepair == .refresh(.control))
        #expect(session.authorizationRequestCount == 1)
        #expect(harness.scheduler.pendingCount == 0)

        let rejectedHarness = Harness(registration: .enabled)
        let rejectedClient = rejectedHarness.makeVisibleClient()
        let rejectedSession = try #require(rejectedHarness.control.sessions.first)
        rejectedSession.replyToNextHandshake(.notDetermined)
        await settleCallbacks()
        rejectedClient.performRecommendedRepair()
        rejectedSession.replyToNextAuthorization(rejectedAuthorizationReply())
        await settleCallbacks()

        #expect(rejectedClient.controlReachability == .unreachable)
        #expect(rejectedClient.recommendedRepair == .refresh(.control))
        #expect(rejectedSession.authorizationRequestCount == 1)
    }

    @Test("permission polling uses the shared finite policy budget")
    func permissionPollingUsesSharedPolicy() async throws {
        let harness = Harness(registration: .enabled)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.notDetermined)
        await settleCallbacks()

        client.performRecommendedRepair()
        session.replyToNextAuthorization(authorizationReply(.notDetermined))
        await settleCallbacks()

        for poll in 1...CameraAuthorizationPollingPolicy.maximumPollCount {
            #expect(harness.scheduler.fireNext(
                delay: CameraAuthorizationPollingPolicy.pollInterval
            ))
            #expect(session.statusRequestCount == Int(poll) + 1)
            session.replyToNextStatus(authorizationReply(.notDetermined))
            await settleCallbacks()
        }

        #expect(session.authorizationRequestCount == 1)
        #expect(harness.scheduler.pendingCount == 0)
        #expect(client.controlReachability == .timedOut)
        #expect(client.recommendedRepair == .refresh(.control))
    }

    @Test("a slow permission reply defers polling without escaping its generation")
    func slowPermissionReplyDefersAndTeardownFencesPolling() async throws {
        let harness = Harness(registration: .enabled)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.notDetermined)
        await settleCallbacks()

        client.performRecommendedRepair()
        let firedDeferredPoll = harness.scheduler.fireNext(
            delay: CameraAuthorizationPollingPolicy.pollInterval
        )
        #expect(firedDeferredPoll)
        guard firedDeferredPoll else { return }
        #expect(session.statusRequestCount == 1)
        #expect(harness.scheduler.pendingDelays.contains(
            CameraAuthorizationPollingPolicy.pollInterval
        ))

        session.replyToNextAuthorization(authorizationReply(.notDetermined))
        await settleCallbacks()
        let firedStatusPoll = harness.scheduler.fireNext(
            delay: CameraAuthorizationPollingPolicy.pollInterval
        )
        #expect(firedStatusPoll)
        guard firedStatusPoll else { return }
        #expect(session.statusRequestCount == 2)

        client.mainWindowWillClose()
        #expect(harness.scheduler.pendingCount == 0)
        session.replyToNextStatus(authorizationReply(.authorized))
        await settleCallbacks()

        #expect(!client.isPreviewLeaseAttached)
        #expect(client.controlReachability == .unknown)
    }

    @Test("first-frame polling advances waiting to ready and detects a stale frame")
    func firstFrameReadiness() async throws {
        let harness = Harness(registration: .enabled)
        harness.runtime.frameAvailability = .waitingForFrame(epoch: 8)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)

        session.replyToNextHandshake(.authorized)
        await settleCallbacks()
        client.startCameraPreview()

        #expect(client.frameReadiness == .awaitingFirstFrame)
        #expect(client.isPreviewLeaseAttached)

        harness.runtime.frameAvailability = .available(epoch: 8, sequence: 1)
        #expect(harness.scheduler.fireNext(
            delay: IdleScreenCompanionCameraClient.framePollInterval
        ))
        #expect(client.frameReadiness == .ready)

        harness.runtime.frameAvailability = .unavailable(
            .staleFrame(epoch: 8, sequence: 1)
        )
        #expect(harness.scheduler.fireNext(
            delay: IdleScreenCompanionCameraClient.framePollInterval
        ))
        #expect(client.frameReadiness == .stalled)
    }

    @Test("service epochs and control attempts fence late callbacks")
    func staleCallbacksAreFenced() async throws {
        let harness = Harness(registration: .enabled)
        let client = harness.makeVisibleClient()
        let oldSession = try #require(harness.control.sessions.first)

        client.mainWindowWillClose()
        harness.registration = .notRegistered
        client.mainWindowDidOpen()
        client.mainWindowPresentationDidChange(isActive: true)

        oldSession.replyToNextStatus(authorizationReply(.authorized))
        harness.control.emit(.requestFailed(
            attempt: oldSession.attempt,
            failure: .timeout
        ))
        await settleCallbacks()

        #expect(client.readinessSnapshot.serviceRegistration == .notRegistered)
        #expect(client.readinessSnapshot.authorization == .unknown)
        #expect(client.controlReachability == .unknown)
        #expect(!client.isPreviewLeaseAttached)
    }

    @Test("enabled status cannot become ready before current identity and live snapshot evidence")
    func identityHandshakeGatesCompanionReadiness() async throws {
        let harness = Harness(
            registration: .enabled,
            identityAssessment: IdleScreenCompanionCameraIdentityAssessment(
                observation: .current,
                generationIdentifier: "helper-generation-a"
            )
        )
        harness.runtime.frameAvailability = .available(epoch: 7, sequence: 1)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)

        session.replyToNextStatus(authorizationReply(.authorized))
        await settleCallbacks()

        #expect(client.readinessSnapshot.blocker == .identity(.unknown))
        #expect(!client.readinessSnapshot.isReady)
        #expect(!client.canStartCameraPreview)
        #expect(harness.identityAssessmentCallCount == 0)

        session.replyToNextDiagnostic(diagnosticSnapshot(
            authorizationStatus: .authorized,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "idle",
            processIncarnationEpoch: 70_001
        ))
        await settleCallbacks()

        #expect(harness.identityAssessmentCallCount == 1)
        #expect(client.readinessSnapshot.identity == .current)
        #expect(client.readinessSnapshot.liveSnapshot == .accepted)
        #expect(client.readinessSnapshot.blocker == .frame(.unknown))
        #expect(client.canStartCameraPreview)

        client.startCameraPreview()

        #expect(client.readinessSnapshot.isReady)
    }

    @Test("untrusted diagnostic handshakes fail closed", arguments: [
        IdentityHandshakeFailure.nilReply,
        IdentityHandshakeFailure.rejected,
        IdentityHandshakeFailure.processMismatch,
        IdentityHandshakeFailure.assessmentFailure,
    ])
    func untrustedDiagnosticHandshakesFailClosed(
        failure: IdentityHandshakeFailure
    ) async throws {
        let harness = Harness(
            registration: .enabled,
            identityAssessment: failure == .assessmentFailure
                ? nil
                : Harness.currentIdentityAssessment
        )
        harness.runtime.frameAvailability = .available(epoch: 7, sequence: 1)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)

        session.replyToNextStatus(authorizationReply(.authorized))
        await settleCallbacks()

        switch failure {
        case .nilReply:
            session.replyToNextDiagnostic(nil)
        case .rejected:
            session.replyToNextDiagnostic(rejectedDiagnosticSnapshot())
        case .processMismatch:
            session.replyToNextDiagnostic(diagnosticSnapshot(
                authorizationStatus: .authorized,
                captureActive: false,
                activeLeaseCount: 0,
                producerStreamEpoch: 0,
                summary: "wrong process",
                processIdentifier: session.remoteProcessIdentifier + 1
            ))
        case .assessmentFailure:
            session.replyToNextDiagnostic(diagnosticSnapshot(
                authorizationStatus: .authorized,
                captureActive: false,
                activeLeaseCount: 0,
                producerStreamEpoch: 0,
                summary: "unassessed"
            ))
        }
        await settleCallbacks()

        #expect(!client.readinessSnapshot.isReady)
        #expect(!client.canStartCameraPreview)
        #expect(!client.isPreviewLeaseRequested)
        #expect(!client.isPreviewLeaseAttached)
        #expect(client.readinessSnapshot.authorization == .unknown)
        #expect(client.controlReachability == .unreachable)
        #expect(harness.identityAssessmentCallCount == (
            failure == .assessmentFailure ? 1 : 0
        ))
        if failure == .processMismatch {
            #expect(client.readinessSnapshot.identity == .mismatched)
            #expect(client.recommendedRepair == .openRepairSurface(
                .cameraAgentDiagnostics
            ))
        }
    }

    @Test("helper generation replacement retires preview and fences old status callbacks")
    func helperGenerationReplacementRetiresDownstreamEvidence() async throws {
        let harness = Harness(registration: .enabled)
        harness.runtime.frameAvailability = .available(epoch: 7, sequence: 1)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.authorized)
        await settleCallbacks()
        client.startCameraPreview()

        let originalEpoch = client.readinessSnapshot
        #expect(client.readinessSnapshot.isReady)
        #expect(client.isPreviewLeaseAttached)

        harness.identityAssessment = IdleScreenCompanionCameraIdentityAssessment(
            observation: .current,
            generationIdentifier: "helper-generation-b"
        )
        client.cameraDiagnosticsDidAppear()
        #expect(session.statusRequestCount == 2)
        #expect(session.diagnosticRequestCount == 2)

        session.replyToNextDiagnostic(diagnosticSnapshot(
            authorizationStatus: .authorized,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "replacement",
            processIncarnationEpoch: 70_002
        ))
        await settleCallbacks()

        #expect(client.readinessSnapshot.identity == .current)
        #expect(client.readinessSnapshot.liveSnapshot == .accepted)
        #expect(client.readinessSnapshot.authorization == .observed(.authorized))
        #expect(client.readinessSnapshot.control == .reachable)
        #expect(client.readinessSnapshot.frame == .unknown)
        #expect(client.readinessSnapshot != originalEpoch)
        #expect(!client.isPreviewLeaseRequested)
        #expect(!client.isPreviewLeaseAttached)
        #expect(client.canStartCameraPreview)

        session.replyToNextStatus(authorizationReply(.denied))
        await settleCallbacks()
        #expect(client.readinessSnapshot.authorization == .observed(.authorized))

        client.startCameraPreview()
        #expect(client.readinessSnapshot.isReady)
    }

    @Test("accepted diagnostics with unavailable authorization invalidate prior readiness")
    func unavailableDiagnosticAuthorizationInvalidatesReadiness() async throws {
        let harness = Harness(registration: .enabled)
        harness.runtime.frameAvailability = .available(epoch: 7, sequence: 1)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.authorized)
        await settleCallbacks()
        client.startCameraPreview()
        #expect(client.readinessSnapshot.isReady)

        client.cameraDiagnosticsDidAppear()
        session.replyToNextDiagnostic(diagnosticSnapshot(
            authorizationStatus: .unavailable,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "authorization unavailable"
        ))
        await settleCallbacks()

        #expect(client.readinessSnapshot.identity == .current)
        #expect(client.readinessSnapshot.liveSnapshot == .accepted)
        #expect(client.readinessSnapshot.authorization == .unknown)
        #expect(client.readinessSnapshot.control == .unknown)
        #expect(client.readinessSnapshot.frame == .unknown)
        #expect(!client.readinessSnapshot.isReady)
        #expect(!client.isPreviewLeaseAttached)
        #expect(client.cameraAgentDiagnosticState == .live(
            IdleScreenCompanionCameraDiagnosticSnapshot(
                authorizationStatus: .unavailable,
                captureActive: false,
                activeLeaseCount: 0,
                producerStreamEpoch: 0,
                summary: "authorization unavailable"
            )
        ))

        session.replyToNextStatus(authorizationReply(.authorized))
        await settleCallbacks()
        #expect(client.readinessSnapshot.authorization == .unknown)
        #expect(client.readinessSnapshot.control == .unknown)
    }

    @Test("known identity distinguishes unavailable and rejected live diagnostics", arguments: [
        IdentityHandshakeFailure.nilReply,
        IdentityHandshakeFailure.rejected,
        IdentityHandshakeFailure.processMismatch,
        IdentityHandshakeFailure.assessmentFailure,
    ])
    func knownIdentityClassifiesLiveDiagnosticFailure(
        failure: IdentityHandshakeFailure
    ) async throws {
        let harness = Harness(registration: .enabled)
        harness.runtime.frameAvailability = .available(epoch: 7, sequence: 1)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.authorized)
        await settleCallbacks()
        #expect(client.readinessSnapshot.isReady == false)

        if failure == .assessmentFailure {
            harness.identityAssessment = nil
        }
        client.cameraDiagnosticsDidAppear()
        switch failure {
        case .nilReply:
            session.replyToNextDiagnostic(nil)
        case .rejected:
            session.replyToNextDiagnostic(rejectedDiagnosticSnapshot())
        case .processMismatch:
            session.replyToNextDiagnostic(diagnosticSnapshot(
                authorizationStatus: .authorized,
                captureActive: false,
                activeLeaseCount: 0,
                producerStreamEpoch: 0,
                summary: "wrong process",
                processIdentifier: session.remoteProcessIdentifier + 1
            ))
        case .assessmentFailure:
            session.replyToNextDiagnostic(diagnosticSnapshot(
                authorizationStatus: .authorized,
                captureActive: false,
                activeLeaseCount: 0,
                producerStreamEpoch: 0,
                summary: "unassessed"
            ))
        }
        await settleCallbacks()

        switch failure {
        case .nilReply:
            #expect(client.readinessSnapshot.identity == .current)
            #expect(client.readinessSnapshot.liveSnapshot == .unavailable)
            #expect(client.cameraAgentDiagnosticState == .unavailable(.control))
            #expect(client.recommendedRepair == .refresh(.liveSnapshot))
        case .rejected, .assessmentFailure:
            #expect(client.readinessSnapshot.identity == .current)
            #expect(client.readinessSnapshot.liveSnapshot == .rejected)
            #expect(client.cameraAgentDiagnosticState == .unavailable(.rejected))
            #expect(client.recommendedRepair == .openRepairSurface(
                .cameraAgentDiagnostics
            ))
        case .processMismatch:
            #expect(client.readinessSnapshot.identity == .mismatched)
            #expect(client.readinessSnapshot.liveSnapshot == .unknown)
            #expect(client.cameraAgentDiagnosticState == .unavailable(.rejected))
            #expect(client.recommendedRepair == .openRepairSurface(
                .cameraAgentDiagnostics
            ))
        }
    }

    @Test("known identity maps control request failure to unavailable live evidence")
    func knownIdentityControlFailureInvalidatesLiveEvidence() async throws {
        let harness = Harness(registration: .enabled)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.authorized)
        await settleCallbacks()

        client.cameraDiagnosticsDidAppear()
        harness.control.emit(.requestFailed(
            attempt: session.attempt,
            failure: .transportUnavailable
        ))
        await settleCallbacks()

        #expect(client.readinessSnapshot.identity == .current)
        #expect(client.readinessSnapshot.liveSnapshot == .unavailable)
        #expect(client.cameraAgentDiagnosticState == .unavailable(.control))
        #expect(client.recommendedRepair == .refresh(.liveSnapshot))
    }

    @Test("assessment registration boundary retires the control attempt before identity")
    func assessmentRegistrationBoundaryFencesHandshake() async throws {
        let harness = Harness(
            registration: .enabled,
            identityAssessment: IdleScreenCompanionCameraIdentityAssessment(
                observation: .current,
                generationIdentifier: "helper-generation-a",
                serviceRegistration: .requiresApproval
            )
        )
        let client = harness.makeClient()
        client.mainWindowDidOpen()
        client.mainWindowPresentationDidChange(isActive: true)
        client.cameraDiagnosticsDidAppear()
        let session = try #require(harness.control.sessions.first)

        session.replyToNextDiagnostic(diagnosticSnapshot(
            authorizationStatus: .authorized,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "registration changed"
        ))
        await settleCallbacks()

        #expect(client.readinessSnapshot.serviceRegistration == .requiresApproval)
        #expect(client.readinessSnapshot.identity == .unknown)
        #expect(client.readinessSnapshot.liveSnapshot == .unknown)
        #expect(client.readinessSnapshot.authorization == .unknown)
        #expect(client.readinessSnapshot.control == .unknown)
        #expect(session.invalidateCallCount == 1)
        #expect(client.cameraAgentDiagnosticState == .unavailable(
            .serviceRegistration
        ))

        session.replyToNextStatus(authorizationReply(.authorized))
        await settleCallbacks()
        #expect(client.readinessSnapshot.serviceRegistration == .requiresApproval)
        #expect(client.readinessSnapshot.authorization == .unknown)
    }

    @Test("visible Health diagnostics publish the authenticated live agent snapshot")
    func healthDiagnosticsPublishLiveAgentSnapshot() async throws {
        let harness = Harness(registration: .enabled)
        let client = harness.makeClient()

        client.mainWindowDidOpen()
        client.mainWindowPresentationDidChange(isActive: true)
        client.cameraDiagnosticsDidAppear()

        let session = try #require(harness.control.sessions.first)
        #expect(session.diagnosticRequestCount == 1)
        #expect(client.cameraAgentDiagnosticState == .loading)
        #expect(!client.isPreviewLeaseAttached)

        session.replyToNextDiagnostic(diagnosticSnapshot(
            authorizationStatus: .authorized,
            captureActive: true,
            activeLeaseCount: 2,
            producerStreamEpoch: 42,
            summary: "capture active"
        ))
        await settleCallbacks()

        #expect(client.cameraAgentDiagnosticState == .live(
            IdleScreenCompanionCameraDiagnosticSnapshot(
                authorizationStatus: .authorized,
                captureActive: true,
                activeLeaseCount: 2,
                producerStreamEpoch: 42,
                summary: "capture active"
            )
        ))
        #expect(!client.isPreviewLeaseAttached)
    }

    @Test("Health diagnostics expose client bootstrap failure without connecting control")
    func healthDiagnosticsExposeBootstrapFailure() {
        let harness = Harness(
            registration: .enabled,
            bootstrapStatus: .missingConfiguration,
            suppliesRuntime: false
        )
        let client = harness.makeClient()

        client.mainWindowDidOpen()
        client.mainWindowPresentationDidChange(isActive: true)
        client.cameraDiagnosticsDidAppear()

        #expect(harness.control.sessions.isEmpty)
        #expect(client.cameraAgentDiagnosticState == .unavailable(
            .clientRuntime(.missingConfiguration)
        ))
    }

    @Test("Health diagnostics expose an unavailable authenticated control channel")
    func healthDiagnosticsExposeControlFailure() {
        let harness = Harness(
            registration: .enabled,
            suppliesControl: false
        )
        let client = harness.makeClient()

        client.mainWindowDidOpen()
        client.mainWindowPresentationDidChange(isActive: true)
        client.cameraDiagnosticsDidAppear()

        #expect(client.cameraAgentDiagnosticState == .unavailable(.control))
    }

    @Test("Health diagnostics fence snapshots from retired control attempts")
    func healthDiagnosticsFenceStaleSnapshots() async throws {
        let harness = Harness(registration: .enabled)
        let client = harness.makeClient()
        client.mainWindowDidOpen()
        client.mainWindowPresentationDidChange(isActive: true)
        client.cameraDiagnosticsDidAppear()
        let oldSession = try #require(harness.control.sessions.first)

        client.cameraDiagnosticsDidDisappear()
        #expect(client.cameraAgentDiagnosticState == .notRequested)

        client.cameraDiagnosticsDidAppear()
        let currentSession = try #require(harness.control.sessions.last)
        #expect(currentSession.attempt != oldSession.attempt)
        #expect(client.cameraAgentDiagnosticState == .loading)

        oldSession.replyToNextDiagnostic(diagnosticSnapshot(
            authorizationStatus: .authorized,
            captureActive: true,
            activeLeaseCount: 9,
            producerStreamEpoch: 99,
            summary: "stale"
        ))
        await settleCallbacks()
        #expect(client.cameraAgentDiagnosticState == .loading)

        currentSession.replyToNextDiagnostic(diagnosticSnapshot(
            authorizationStatus: .authorized,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 100,
            summary: "current"
        ))
        await settleCallbacks()
        #expect(client.cameraAgentDiagnosticState == .live(
            IdleScreenCompanionCameraDiagnosticSnapshot(
                authorizationStatus: .authorized,
                captureActive: false,
                activeLeaseCount: 0,
                producerStreamEpoch: 100,
                summary: "current"
            )
        ))
    }

    @Test("window teardown cancels polling, invalidates control, and removes only preview demand")
    func teardownOwnsAllCompanionDemand() async throws {
        let harness = Harness(
            registration: .enabled,
            independentConsumers: ["screen-saver-fixture"]
        )
        harness.runtime.frameAvailability = .waitingForFrame(epoch: 2)
        let client = harness.makeVisibleClient()
        let session = try #require(harness.control.sessions.first)
        session.replyToNextHandshake(.authorized)
        await settleCallbacks()
        client.startCameraPreview()

        #expect(client.isPreviewLeaseAttached)
        #expect(harness.scheduler.pendingCount == 2)

        client.mainWindowWillClose()

        #expect(session.invalidateCallCount == 1)
        #expect(harness.scheduler.pendingCount == 0)
        #expect(!client.isPreviewLeaseRequested)
        #expect(!client.isPreviewLeaseAttached)
        #expect(harness.runtime.activeConsumerIdentifiers == ["screen-saver-fixture"])

        session.replayLastStatus(authorizationReply(.authorized))
        await settleCallbacks()
        #expect(!client.isPreviewLeaseAttached)
    }

    @Test("bootstrap failure stays blocked, makes no control demand, and offers a real retry")
    func bootstrapFailureStaysInert() {
        let harness = Harness(
            registration: .enabled,
            bootstrapStatus: .missingConfiguration,
            suppliesRuntime: false,
            suppliesControl: true
        )
        let client = harness.makeVisibleClient()

        #expect(harness.bootstrapCallCount == 1)
        #expect(harness.control.sessions.isEmpty)
        #expect(client.bootstrapStatus == .missingConfiguration)
        #expect(client.controlReachability == .unreachable)
        #expect(client.recommendedRepair == .refresh(.clientRuntime))
        #expect(!client.canStartCameraPreview)
        #expect(client.isUsingProceduralFallback)

        client.performRecommendedRepair()

        #expect(harness.bootstrapCallCount == 2)
        #expect(harness.control.sessions.isEmpty)
        #expect(client.bootstrapStatus == .missingConfiguration)
        #expect(client.recommendedRepair == .refresh(.clientRuntime))

        harness.bootstrapStatus = .ready
        harness.suppliesRuntime = true
        client.performRecommendedRepair()

        #expect(harness.bootstrapCallCount == 3)
        #expect(harness.control.sessions.count == 1)
        #expect(client.bootstrapStatus == .ready)
        #expect(client.recommendedRepair == .refresh(.identity))
    }
}

@MainActor
private final class Harness {
    static let currentIdentityAssessment = currentIdentityAssessment()

    static func currentIdentityAssessment(
        processIdentifier: Int32 = fixtureAgentProcessIdentifier,
        generationIdentifier: String = "helper-generation-a"
    ) -> IdleScreenCompanionCameraIdentityAssessment {
        IdleScreenCompanionCameraIdentityAssessment(
            observation: .current,
            generationIdentifier: generationIdentifier,
            runningProcessIdentifier: processIdentifier
        )
    }

    static func verifiedIdentityAssessment(
        processIdentifier: Int32,
        generationIdentifier: String,
        processEpoch: UInt64
    ) -> IdleScreenCompanionCameraIdentityAssessment {
        IdleScreenCompanionCameraIdentityAssessment(
            observation: .current,
            generationIdentifier: generationIdentifier,
            runningBundleVersion: "27",
            runningSourceAppPath: "/Applications/idlescreen.app",
            runningProcessIdentifier: processIdentifier,
            runningProcessEpoch: processEpoch,
            runningCodeDirectoryHash: String(repeating: "a", count: 40)
        )
    }

    var registration: CameraAgentServiceRegistration
    var registrationAfterRegister: CameraAgentServiceRegistration
    var bootstrapStatus: CameraClientBootstrapStatus
    var suppliesRuntime: Bool
    var identityAssessment: IdleScreenCompanionCameraIdentityAssessment?
    let suppliesControl: Bool
    let runtime: RuntimeSpy
    let control = ControlConnectorSpy()
    let scheduler = ManualCompanionScheduler()
    let repairSurfaceOpenSucceeds: Bool
    let defersReplacementCompletion: Bool

    private var deferredReplacementCompletions: [
        @MainActor (IdleScreenCompanionCameraAgentReplacementOutcome) -> Void
    ] = []

    private(set) var serviceStatusReadCount = 0
    private(set) var registerCallCount = 0
    private(set) var bootstrapCallCount = 0
    private(set) var identityAssessmentCallCount = 0
    private(set) var openedSurfaces: [CameraAgentRepairSurface] = []

    init(
        registration: CameraAgentServiceRegistration,
        registrationAfterRegister: CameraAgentServiceRegistration? = nil,
        bootstrapStatus: CameraClientBootstrapStatus = .ready,
        suppliesRuntime: Bool = true,
        suppliesControl: Bool = true,
        identityAssessment: IdleScreenCompanionCameraIdentityAssessment? =
            Harness.currentIdentityAssessment,
        independentConsumers: Set<String> = [],
        repairSurfaceOpenSucceeds: Bool = true,
        defersReplacementCompletion: Bool = false
    ) {
        self.registration = registration
        self.registrationAfterRegister = registrationAfterRegister ?? registration
        self.bootstrapStatus = bootstrapStatus
        self.suppliesRuntime = suppliesRuntime
        self.suppliesControl = suppliesControl
        self.identityAssessment = identityAssessment
        self.repairSurfaceOpenSucceeds = repairSurfaceOpenSucceeds
        self.defersReplacementCompletion = defersReplacementCompletion
        runtime = RuntimeSpy(activeConsumerIdentifiers: independentConsumers)
    }

    func makeClient() -> IdleScreenCompanionCameraClient {
        let replaceAgent: IdleScreenCompanionCameraEffects.ReplaceAgent? =
            defersReplacementCompletion
            ? { [unowned self] completion in
                registerCallCount += 1
                registration = registrationAfterRegister
                deferredReplacementCompletions.append(completion)
            }
            : nil
        return IdleScreenCompanionCameraClient(
            infoDictionary: ["fixture": true],
            effects: IdleScreenCompanionCameraEffects(
                readServiceRegistration: { [unowned self] in
                    serviceStatusReadCount += 1
                    return registration
                },
                registerAgent: { [unowned self] in
                    registerCallCount += 1
                    registration = registrationAfterRegister
                    return registration
                },
                replaceAgent: replaceAgent,
                openRepairSurface: { [unowned self] surface in
                    if repairSurfaceOpenSucceeds {
                        openedSurfaces.append(surface)
                    }
                    return repairSurfaceOpenSucceeds
                },
                bootstrapPreview: { [unowned self] infoDictionary in
                    bootstrapCallCount += 1
                    #expect(infoDictionary["fixture"] as? Bool == true)
                    return IdleScreenCompanionCameraBootstrap(
                        status: bootstrapStatus,
                        runtime: suppliesRuntime ? runtime : nil
                    )
                },
                assessAgentIdentity: { [unowned self] identity, remotePID in
                    identityAssessmentCallCount += 1
                    #expect(identity.matches(
                        remoteProcessIdentifier: remotePID
                    ))
                    return identityAssessment
                },
                connectControl: { [unowned self] attempt, eventHandler in
                    guard suppliesControl else { return nil }
                    return control.connect(
                        attempt: attempt,
                        eventHandler: eventHandler
                    )
                }
            ),
            scheduler: scheduler
        )
    }

    func completeDeferredReplacement(
        _ outcome: IdleScreenCompanionCameraAgentReplacementOutcome
    ) {
        deferredReplacementCompletions.removeFirst()(outcome)
    }

    func makeVisibleClient() -> IdleScreenCompanionCameraClient {
        let client = makeClient()
        client.mainWindowDidOpen()
        client.mainWindowPresentationDidChange(isActive: true)
        client.cameraPageDidAppear()
        return client
    }
}

@MainActor
private final class ControlConnectorSpy {
    private(set) var sessions: [ControlSessionSpy] = []
    private var eventHandlers: [UInt64: @Sendable (CameraAgentControlConnectionEvent) -> Void] = [:]
    var remoteProcessIdentifier = fixtureAgentProcessIdentifier

    func connect(
        attempt: UInt64,
        eventHandler: @escaping @Sendable (CameraAgentControlConnectionEvent) -> Void
    ) -> ControlSessionSpy {
        let session = ControlSessionSpy(
            attempt: attempt,
            remoteProcessIdentifier: remoteProcessIdentifier
        )
        sessions.append(session)
        eventHandlers[attempt] = eventHandler
        return session
    }

    func emit(_ event: CameraAgentControlConnectionEvent) {
        eventHandlers[event.attempt]?(event)
    }
}

private final class ControlSessionSpy: CameraAgentControlSession, @unchecked Sendable {
    let attempt: UInt64
    let remoteProcessIdentifier: Int32

    private let lock = NSLock()
    private var statusReplies: [@Sendable (IdleScreenCameraAuthorizationReply?) -> Void] = []
    private var authorizationReplies: [@Sendable (IdleScreenCameraAuthorizationReply?) -> Void] = []
    private var diagnosticReplies: [@Sendable (IdleScreenCameraDiagnosticSnapshot?) -> Void] = []
    private var cameraDeviceReplies: [@Sendable (IdleScreenCameraDeviceSnapshotReply?) -> Void] = []
    private var lastStatusReply: (@Sendable (IdleScreenCameraAuthorizationReply?) -> Void)?
    private(set) var statusRequestCount = 0
    private(set) var authorizationRequestCount = 0
    private(set) var diagnosticRequestCount = 0
    private(set) var cameraDeviceRequestCount = 0
    private(set) var invalidateCallCount = 0

    init(attempt: UInt64, remoteProcessIdentifier: Int32) {
        self.attempt = attempt
        self.remoteProcessIdentifier = remoteProcessIdentifier
    }

    func authorizationStatus(
        _ request: IdleScreenCameraStatusRequest,
        reply: @escaping @Sendable (IdleScreenCameraAuthorizationReply?) -> Void
    ) {
        _ = request
        lock.withLock {
            statusRequestCount += 1
            statusReplies.append(reply)
        }
    }

    func requestAuthorization(
        _ request: IdleScreenCameraAuthorizationRequest,
        reply: @escaping @Sendable (IdleScreenCameraAuthorizationReply?) -> Void
    ) {
        _ = request
        lock.withLock {
            authorizationRequestCount += 1
            authorizationReplies.append(reply)
        }
    }

    func diagnosticSnapshot(
        _ request: IdleScreenCameraDiagnosticRequest,
        reply: @escaping @Sendable (IdleScreenCameraDiagnosticSnapshot?) -> Void
    ) {
        _ = request
        lock.withLock {
            diagnosticRequestCount += 1
            diagnosticReplies.append(reply)
        }
    }

    func cameraDeviceSnapshot(
        _ request: IdleScreenCameraStatusRequest,
        reply: @escaping @Sendable (IdleScreenCameraDeviceSnapshotReply?) -> Void
    ) {
        _ = request
        lock.withLock {
            cameraDeviceRequestCount += 1
            cameraDeviceReplies.append(reply)
        }
    }

    func invalidate() {
        lock.withLock { invalidateCallCount += 1 }
    }

    func replyToNextStatus(_ reply: IdleScreenCameraAuthorizationReply?) {
        let callback = lock.withLock {
            let callback = statusReplies.removeFirst()
            lastStatusReply = callback
            return callback
        }
        callback(reply)
    }

    func replyToNextHandshake(
        _ status: IdleScreenCameraAuthorizationStatus,
        processIncarnationEpoch: UInt64 = 70_001
    ) {
        replyToNextStatus(authorizationReply(status))
        replyToNextDiagnostic(makeDiagnosticSnapshot(
            authorizationStatus: status,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "idle",
            processIdentifier: remoteProcessIdentifier,
            processIncarnationEpoch: processIncarnationEpoch
        ))
    }

    func replayLastStatus(_ reply: IdleScreenCameraAuthorizationReply?) {
        lock.withLock { lastStatusReply }?(reply)
    }

    func replyToNextAuthorization(_ reply: IdleScreenCameraAuthorizationReply?) {
        let callback = lock.withLock { authorizationReplies.removeFirst() }
        callback(reply)
    }

    func replyToNextDiagnostic(_ reply: IdleScreenCameraDiagnosticSnapshot?) {
        let callback = lock.withLock { diagnosticReplies.removeFirst() }
        callback(reply)
    }
}

@MainActor
private final class RuntimeSpy: IdleScreenCompanionCameraRuntime {
    var frameAvailability: CameraFrameSourceAvailability =
        .unavailable(.leaseUnavailable)
    var frameAvailabilityAfterRefresh: [CameraFrameSourceAvailability] = []
    private(set) var activeConsumerIdentifiers: Set<String>
    private(set) var attachCalls: [String] = []
    private(set) var detachCalls: [String] = []
    private(set) var refreshFrameAvailabilityCallCount = 0
    private(set) var previewImageRequests: [Bool] = []

    init(activeConsumerIdentifiers: Set<String> = []) {
        self.activeConsumerIdentifiers = activeConsumerIdentifiers
    }

    func attach(consumerIdentifier: String) -> Bool {
        attachCalls.append(consumerIdentifier)
        return activeConsumerIdentifiers.insert(consumerIdentifier).inserted
    }

    func detach(consumerIdentifier: String) -> Bool {
        detachCalls.append(consumerIdentifier)
        return activeConsumerIdentifiers.remove(consumerIdentifier) != nil
    }

    func refreshFrameAvailability() -> IdleScreenCompanionCameraFrameRefresh {
        refreshFrameAvailabilityCallCount += 1
        if !frameAvailabilityAfterRefresh.isEmpty {
            frameAvailability = frameAvailabilityAfterRefresh.removeFirst()
        }
        return IdleScreenCompanionCameraFrameRefresh(
            availability: frameAvailability,
            consumedFrame: nil
        )
    }

    func refreshFrameAvailability(
        includePreviewImage: Bool
    ) -> IdleScreenCompanionCameraFrameRefresh {
        previewImageRequests.append(includePreviewImage)
        return refreshFrameAvailability()
    }
}

@MainActor
private final class ManualCompanionScheduler: IdleScreenCompanionCameraScheduling {
    private var work: [ManualCompanionScheduledWork] = []

    var pendingCount: Int {
        work.filter { !$0.isCancelled && !$0.hasFired }.count
    }

    var pendingDelays: [TimeInterval] {
        work.filter { !$0.isCancelled && !$0.hasFired }.map(\.delay)
    }

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> any IdleScreenCompanionCameraScheduledWork {
        let item = ManualCompanionScheduledWork(delay: delay, operation: operation)
        work.append(item)
        return item
    }

    func fireNext() {
        work.first { !$0.isCancelled && !$0.hasFired }?.fire()
    }

    @discardableResult
    func fireNext(delay: TimeInterval) -> Bool {
        guard let item = work.first(where: {
            !$0.isCancelled && !$0.hasFired && $0.delay == delay
        }) else {
            return false
        }
        item.fire()
        return true
    }
}

@MainActor
private final class ManualCompanionScheduledWork: IdleScreenCompanionCameraScheduledWork {
    let delay: TimeInterval
    private var operation: (@MainActor () -> Void)?
    private(set) var hasFired = false

    init(delay: TimeInterval, operation: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.operation = operation
    }

    var isCancelled: Bool { operation == nil && !hasFired }

    func cancel() {
        operation = nil
    }

    func fire() {
        guard let operation else { return }
        self.operation = nil
        hasFired = true
        operation()
    }
}

private func authorizationReply(
    _ status: IdleScreenCameraAuthorizationStatus
) -> IdleScreenCameraAuthorizationReply {
    IdleScreenCameraAuthorizationReply(
        accepted: true,
        status: status,
        errorCode: .none,
        errorMessage: nil
    )!
}

private func rejectedAuthorizationReply() -> IdleScreenCameraAuthorizationReply {
    IdleScreenCameraAuthorizationReply(
        accepted: false,
        status: .unavailable,
        errorCode: .notAuthorized,
        errorMessage: "Camera agent rejected the request"
    )!
}

private func rejectedDiagnosticSnapshot() -> IdleScreenCameraDiagnosticSnapshot {
    IdleScreenCameraDiagnosticSnapshot(
        accepted: false,
        errorCode: .notAuthorized,
        errorMessage: "Camera agent rejected the diagnostic request",
        authorizationStatus: .unavailable,
        captureActive: false,
        activeLeaseCount: 0,
        producerStreamEpoch: 0,
        summary: "rejected"
    )!
}

private func diagnosticSnapshot(
    authorizationStatus: IdleScreenCameraAuthorizationStatus,
    captureActive: Bool,
    activeLeaseCount: Int,
    producerStreamEpoch: UInt64,
    summary: String,
    processIdentifier: Int32 = fixtureAgentProcessIdentifier,
    processIncarnationEpoch: UInt64 = 70_001
) -> IdleScreenCameraDiagnosticSnapshot {
    IdleScreenCameraDiagnosticSnapshot(
        accepted: true,
        errorCode: .none,
        errorMessage: nil,
        agentIdentity: cameraAgentIdentity(
            processIdentifier: processIdentifier,
            processIncarnationEpoch: processIncarnationEpoch
        ),
        authorizationStatus: authorizationStatus,
        captureActive: captureActive,
        activeLeaseCount: activeLeaseCount,
        producerStreamEpoch: producerStreamEpoch,
        summary: summary
    )!
}

private func makeDiagnosticSnapshot(
    authorizationStatus: IdleScreenCameraAuthorizationStatus,
    captureActive: Bool,
    activeLeaseCount: Int,
    producerStreamEpoch: UInt64,
    summary: String,
    processIdentifier: Int32 = fixtureAgentProcessIdentifier,
    processIncarnationEpoch: UInt64 = 70_001
) -> IdleScreenCameraDiagnosticSnapshot {
    diagnosticSnapshot(
        authorizationStatus: authorizationStatus,
        captureActive: captureActive,
        activeLeaseCount: activeLeaseCount,
        producerStreamEpoch: producerStreamEpoch,
        summary: summary,
        processIdentifier: processIdentifier,
        processIncarnationEpoch: processIncarnationEpoch
    )
}

private func cameraAgentIdentity(
    processIdentifier: Int32,
    processIncarnationEpoch: UInt64
) -> IdleScreenCameraAgentIdentity {
    IdleScreenCameraAgentIdentity(
        processIdentifier: processIdentifier,
        processIncarnationEpoch: processIncarnationEpoch,
        bundleIdentifier: "com.idlescreen.camera-agent.dev",
        serviceIdentifier: "com.idlescreen.camera-agent.dev",
        bundleVersion: "1",
        marketingVersion: "1.0",
        signingIdentifier: "com.idlescreen.camera-agent.dev",
        teamIdentifier: "ABCDE12345",
        codeDirectoryHash: String(repeating: "a", count: 40),
        executableSHA256: String(repeating: "b", count: 64),
        launchAgentSHA256: String(repeating: "c", count: 64),
        provisioningProfileSHA256: String(repeating: "d", count: 64),
        sourceAppPath: "/Applications/IdleScreen.app"
    )!
}

@MainActor
private func settleCallbacks() async {
    await Task.yield()
    await Task.yield()
}
