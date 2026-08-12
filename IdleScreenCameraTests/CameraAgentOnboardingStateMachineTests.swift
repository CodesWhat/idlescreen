import Testing
@testable import IdleScreenCamera

@Suite("Camera agent onboarding readiness")
struct CameraAgentOnboardingStateMachineTests {
    @Test("truthful readiness matrix", arguments: [
        ReadinessMatrixFixture(
            name: "absent helper",
            identity: .absent,
            liveSnapshot: .unknown,
            authorization: .unknown,
            control: .unknown,
            frame: .unknown,
            expectedBlocker: .identity(.absent),
            expectedRepair: .openRepairSurface(.cameraAgentDiagnostics)
        ),
        ReadinessMatrixFixture(
            name: "stale helper",
            identity: .stale,
            liveSnapshot: .accepted,
            authorization: .observed(.authorized),
            control: .reachable,
            frame: .ready,
            expectedBlocker: .identity(.stale),
            expectedRepair: .openRepairSurface(.cameraAgentDiagnostics)
        ),
        ReadinessMatrixFixture(
            name: "mismatched helper",
            identity: .mismatched,
            liveSnapshot: .accepted,
            authorization: .observed(.authorized),
            control: .reachable,
            frame: .ready,
            expectedBlocker: .identity(.mismatched),
            expectedRepair: .openRepairSurface(.cameraAgentDiagnostics)
        ),
        ReadinessMatrixFixture(
            name: "live snapshot unavailable",
            identity: .current,
            liveSnapshot: .unavailable,
            authorization: .observed(.authorized),
            control: .reachable,
            frame: .ready,
            expectedBlocker: .liveSnapshot(.unavailable),
            expectedRepair: .refresh(.liveSnapshot)
        ),
        ReadinessMatrixFixture(
            name: "unauthorized",
            identity: .current,
            liveSnapshot: .accepted,
            authorization: .observed(.denied),
            control: .reachable,
            frame: .ready,
            expectedBlocker: .authorization(.observed(.denied)),
            expectedRepair: .openRepairSurface(.cameraPrivacySettings)
        ),
        ReadinessMatrixFixture(
            name: "unreachable control",
            identity: .current,
            liveSnapshot: .accepted,
            authorization: .observed(.authorized),
            control: .unreachable,
            frame: .ready,
            expectedBlocker: .control(.unreachable),
            expectedRepair: .refresh(.control)
        ),
        ReadinessMatrixFixture(
            name: "frame not ready",
            identity: .current,
            liveSnapshot: .accepted,
            authorization: .observed(.authorized),
            control: .reachable,
            frame: .awaitingFirstFrame,
            expectedBlocker: .frame(.awaitingFirstFrame),
            expectedRepair: .refresh(.frameReadiness)
        ),
        ReadinessMatrixFixture(
            name: "ready",
            identity: .current,
            liveSnapshot: .accepted,
            authorization: .observed(.authorized),
            control: .reachable,
            frame: .ready,
            expectedBlocker: nil,
            expectedRepair: nil
        ),
    ])
    func truthfulReadinessMatrix(fixture: ReadinessMatrixFixture) {
        let machine = CameraAgentOnboardingStateMachine(
            serviceRegistration: .enabled,
            authorization: fixture.authorization,
            control: fixture.control,
            frame: fixture.frame,
            identity: fixture.identity,
            liveSnapshot: fixture.liveSnapshot
        )

        #expect(machine.snapshot.blocker == fixture.expectedBlocker)
        #expect(machine.snapshot.recommendedRepair == fixture.expectedRepair)
        #expect(machine.snapshot.isReady == (fixture.expectedBlocker == nil))
    }

    @Test("readiness requires current helper identity and a live authenticated snapshot")
    func identityAndLiveSnapshotGateReadiness() {
        var machine = CameraAgentOnboardingStateMachine()
        _ = machine.handle(.serviceRegistrationObserved(.enabled))
        let registrationEpoch = machine.serviceEpoch
        _ = machine.handle(.authorizationObserved(
            .authorized,
            serviceEpoch: registrationEpoch
        ))
        _ = machine.handle(.controlObserved(
            .reachable,
            serviceEpoch: registrationEpoch
        ))
        _ = machine.handle(.frameObserved(
            .ready,
            serviceEpoch: registrationEpoch
        ))

        #expect(machine.snapshot.blocker == .identity(.unknown))
        #expect(!machine.snapshot.isReady)

        _ = machine.handle(.identityObserved(
            .current,
            generationIdentifier: "helper-generation-a"
        ))
        let identityEpoch = machine.serviceEpoch
        #expect(identityEpoch > registrationEpoch)
        #expect(machine.snapshot.blocker == .liveSnapshot(.unknown))

        _ = machine.handle(.authorizationObserved(
            .authorized,
            serviceEpoch: identityEpoch
        ))
        _ = machine.handle(.controlObserved(
            .reachable,
            serviceEpoch: identityEpoch
        ))
        _ = machine.handle(.liveSnapshotObserved(
            .accepted,
            serviceEpoch: identityEpoch
        ))
        _ = machine.handle(.frameObserved(
            .ready,
            serviceEpoch: identityEpoch
        ))
        #expect(machine.snapshot.isReady)

        _ = machine.handle(.identityObserved(
            .current,
            generationIdentifier: "helper-generation-b"
        ))
        let replacementEpoch = machine.serviceEpoch
        #expect(replacementEpoch > identityEpoch)
        #expect(machine.snapshot.liveSnapshot == .unknown)
        #expect(machine.snapshot.authorization == .unknown)
        #expect(machine.snapshot.control == .unknown)
        #expect(machine.snapshot.frame == .unknown)

        _ = machine.handle(.authorizationObserved(
            .authorized,
            serviceEpoch: identityEpoch
        ))
        _ = machine.handle(.controlObserved(
            .reachable,
            serviceEpoch: identityEpoch
        ))
        _ = machine.handle(.liveSnapshotObserved(
            .accepted,
            serviceEpoch: identityEpoch
        ))
        _ = machine.handle(.frameObserved(
            .ready,
            serviceEpoch: identityEpoch
        ))
        #expect(machine.snapshot.blocker == .liveSnapshot(.unknown))
        #expect(!machine.snapshot.isReady)
    }

    @Test("observations update each readiness dimension without causing side effects")
    func observationsAreInert() {
        var machine = CameraAgentOnboardingStateMachine()

        #expect(machine.snapshot.blocker == .serviceRegistration(.unknown))
        #expect(machine.snapshot.recommendedRepair == .refresh(.serviceRegistration))
        #expect(machine.handle(.serviceRegistrationObserved(.enabled)) == [])
        #expect(machine.handle(.identityObserved(
            .current,
            generationIdentifier: "helper-generation-a"
        )) == [])
        let serviceEpoch = machine.serviceEpoch
        #expect(machine.handle(.liveSnapshotObserved(
            .accepted,
            serviceEpoch: serviceEpoch
        )) == [])
        #expect(machine.handle(.authorizationObserved(
            .authorized,
            serviceEpoch: serviceEpoch
        )) == [])
        #expect(machine.handle(.controlObserved(
            .reachable,
            serviceEpoch: serviceEpoch
        )) == [])
        #expect(machine.handle(.frameObserved(
            .ready,
            serviceEpoch: serviceEpoch
        )) == [])

        #expect(machine.snapshot == CameraAgentOnboardingSnapshot(
            serviceRegistration: .enabled,
            authorization: .observed(.authorized),
            control: .reachable,
            frame: .ready,
            identity: .current,
            liveSnapshot: .accepted
        ))
        #expect(machine.snapshot.blocker == nil)
        #expect(machine.snapshot.recommendedRepair == nil)
        #expect(machine.snapshot.isReady)
    }

    @Test("unknown authorization requires a nonprompting refresh before permission intent")
    func unknownAuthorizationRefreshesBeforePermissionIntent() {
        var machine = CameraAgentOnboardingStateMachine(
            serviceRegistration: .enabled,
            identity: .current,
            liveSnapshot: .accepted
        )

        #expect(machine.snapshot.authorization == .unknown)
        #expect(machine.snapshot.blocker == .authorization(.unknown))
        #expect(machine.snapshot.recommendedRepair == .refresh(.authorization))
        #expect(machine.handle(.visibleRepair(.requestCameraAuthorization)) == [])
        #expect(machine.handle(.visibleRepair(.refresh(.authorization))) == [
            .refresh(
                .authorization,
                within: CameraAgentOnboardingStateMachine.maximumRepairLatency
            ),
        ])

        #expect(machine.handle(
            .authorizationObserved(.notDetermined, serviceEpoch: 0)
        ) == [])
        #expect(machine.snapshot.authorization == .observed(.notDetermined))
        #expect(machine.snapshot.recommendedRepair == .requestCameraAuthorization)
    }

    @Test("routine enabled refresh preserves observations within one service epoch")
    func routineEnabledRefreshPreservesReadiness() {
        var machine = CameraAgentOnboardingStateMachine()
        _ = machine.handle(.serviceRegistrationObserved(.enabled))
        _ = machine.handle(.identityObserved(
            .current,
            generationIdentifier: "helper-generation-a"
        ))
        let serviceEpoch = machine.serviceEpoch
        _ = machine.handle(.liveSnapshotObserved(
            .accepted,
            serviceEpoch: serviceEpoch
        ))
        _ = machine.handle(.authorizationObserved(.authorized, serviceEpoch: serviceEpoch))
        _ = machine.handle(.controlObserved(.reachable, serviceEpoch: serviceEpoch))
        _ = machine.handle(.frameObserved(.ready, serviceEpoch: serviceEpoch))

        #expect(machine.handle(
            .serviceRegistrationObserved(.enabled)
        ) == [])
        #expect(machine.serviceEpoch == serviceEpoch)
        #expect(machine.snapshot.isReady)
    }

    @Test("service loss and re-enable invalidate every downstream observation")
    func serviceLossInvalidatesDownstreamReadiness() {
        var machine = CameraAgentOnboardingStateMachine()
        _ = machine.handle(.serviceRegistrationObserved(.enabled))
        _ = machine.handle(.identityObserved(
            .current,
            generationIdentifier: "helper-generation-a"
        ))
        let originalEpoch = machine.serviceEpoch
        _ = machine.handle(.liveSnapshotObserved(
            .accepted,
            serviceEpoch: originalEpoch
        ))
        _ = machine.handle(.authorizationObserved(.authorized, serviceEpoch: originalEpoch))
        _ = machine.handle(.controlObserved(.reachable, serviceEpoch: originalEpoch))
        _ = machine.handle(.frameObserved(.ready, serviceEpoch: originalEpoch))

        _ = machine.handle(.serviceRegistrationObserved(.notRegistered))
        #expect(machine.serviceEpoch > originalEpoch)
        #expect(machine.snapshot == CameraAgentOnboardingSnapshot(
            serviceRegistration: .notRegistered,
            authorization: .unknown,
            control: .unknown,
            frame: .unknown,
            identity: .unknown,
            liveSnapshot: .unknown
        ))

        _ = machine.handle(.serviceRegistrationObserved(.enabled))
        let replacementEpoch = machine.serviceEpoch
        _ = machine.handle(.authorizationObserved(.authorized, serviceEpoch: originalEpoch))
        _ = machine.handle(.controlObserved(.reachable, serviceEpoch: originalEpoch))
        _ = machine.handle(.frameObserved(.ready, serviceEpoch: originalEpoch))
        #expect(machine.snapshot == CameraAgentOnboardingSnapshot(
            serviceRegistration: .enabled,
            authorization: .unknown,
            control: .unknown,
            frame: .unknown,
            identity: .unknown,
            liveSnapshot: .unknown
        ))
        #expect(replacementEpoch > originalEpoch)
        #expect(!machine.snapshot.isReady)
    }

    @Test("a new service epoch invalidates readiness and fences stale observations")
    func serviceEpochFencesStaleObservations() {
        var machine = CameraAgentOnboardingStateMachine()
        _ = machine.handle(.serviceRegistrationObserved(.enabled))
        _ = machine.handle(.identityObserved(
            .current,
            generationIdentifier: "helper-generation-a"
        ))
        let originalEpoch = machine.serviceEpoch
        _ = machine.handle(.liveSnapshotObserved(
            .accepted,
            serviceEpoch: originalEpoch
        ))
        _ = machine.handle(.authorizationObserved(.authorized, serviceEpoch: originalEpoch))
        _ = machine.handle(.controlObserved(.reachable, serviceEpoch: originalEpoch))
        _ = machine.handle(.frameObserved(.ready, serviceEpoch: originalEpoch))

        _ = machine.handle(.serviceRegistrationBoundaryObserved(.enabled))
        _ = machine.handle(.authorizationObserved(.authorized, serviceEpoch: originalEpoch))
        _ = machine.handle(.controlObserved(.reachable, serviceEpoch: originalEpoch))
        _ = machine.handle(.frameObserved(.ready, serviceEpoch: originalEpoch))

        #expect(machine.serviceEpoch > originalEpoch)
        #expect(machine.snapshot == CameraAgentOnboardingSnapshot(
            serviceRegistration: .enabled,
            authorization: .unknown,
            control: .unknown,
            frame: .unknown,
            identity: .unknown,
            liveSnapshot: .unknown
        ))
    }

    @Test("authorization and control regressions invalidate dependent readiness")
    func lowerLayerRegressionsInvalidateDependents() {
        var machine = CameraAgentOnboardingStateMachine()
        _ = machine.handle(.serviceRegistrationObserved(.enabled))
        _ = machine.handle(.identityObserved(
            .current,
            generationIdentifier: "helper-generation-a"
        ))
        let serviceEpoch = machine.serviceEpoch
        _ = machine.handle(.liveSnapshotObserved(
            .accepted,
            serviceEpoch: serviceEpoch
        ))
        _ = machine.handle(.authorizationObserved(.authorized, serviceEpoch: serviceEpoch))
        _ = machine.handle(.controlObserved(.reachable, serviceEpoch: serviceEpoch))
        _ = machine.handle(.frameObserved(.ready, serviceEpoch: serviceEpoch))

        _ = machine.handle(.authorizationObserved(.denied, serviceEpoch: serviceEpoch))
        #expect(machine.snapshot.authorization == .observed(.denied))
        #expect(machine.snapshot.control == .unknown)
        #expect(machine.snapshot.frame == .unknown)

        _ = machine.handle(.authorizationObserved(.authorized, serviceEpoch: serviceEpoch))
        _ = machine.handle(.controlObserved(.reachable, serviceEpoch: serviceEpoch))
        _ = machine.handle(.frameObserved(.ready, serviceEpoch: serviceEpoch))
        _ = machine.handle(.controlObserved(.timedOut, serviceEpoch: serviceEpoch))

        #expect(machine.snapshot.authorization == .observed(.authorized))
        #expect(machine.snapshot.control == .timedOut)
        #expect(machine.snapshot.frame == .unknown)

        _ = machine.handle(.controlObserved(.reachable, serviceEpoch: serviceEpoch))
        _ = machine.handle(.frameObserved(.ready, serviceEpoch: serviceEpoch))
        _ = machine.handle(.liveSnapshotObserved(
            .unavailable,
            serviceEpoch: serviceEpoch
        ))

        #expect(machine.snapshot.liveSnapshot == .unavailable)
        #expect(machine.snapshot.authorization == .unknown)
        #expect(machine.snapshot.control == .unknown)
        #expect(machine.snapshot.frame == .unknown)
    }

    @Test("registration blockers retain distinct repairs", arguments: [
        (
            CameraAgentServiceRegistration.unknown,
            CameraAgentReadinessRepair.refresh(.serviceRegistration)
        ),
        (
            CameraAgentServiceRegistration.notRegistered,
            CameraAgentReadinessRepair.registerAgent
        ),
        (
            CameraAgentServiceRegistration.requiresApproval,
            CameraAgentReadinessRepair.openRepairSurface(.backgroundItemsSettings)
        ),
        (
            CameraAgentServiceRegistration.notFound,
            CameraAgentReadinessRepair.registerAgent
        ),
        (
            CameraAgentServiceRegistration.failed,
            CameraAgentReadinessRepair.openRepairSurface(.cameraAgentDiagnostics)
        ),
    ])
    func registrationRepairs(
        registration: CameraAgentServiceRegistration,
        expectedRepair: CameraAgentReadinessRepair
    ) {
        let machine = CameraAgentOnboardingStateMachine(
            serviceRegistration: registration,
            authorization: .observed(.authorized),
            control: .reachable,
            frame: .ready
        )

        #expect(machine.snapshot.blocker == .serviceRegistration(registration))
        #expect(machine.snapshot.recommendedRepair == expectedRepair)
    }

    @Test("authorization blockers retain distinct repairs", arguments: [
        (
            CameraAgentAuthorization.notDetermined,
            CameraAgentReadinessRepair.requestCameraAuthorization
        ),
        (
            CameraAgentAuthorization.denied,
            CameraAgentReadinessRepair.openRepairSurface(.cameraPrivacySettings)
        ),
        (
            CameraAgentAuthorization.restricted,
            CameraAgentReadinessRepair.openRepairSurface(.cameraPrivacySettings)
        ),
    ])
    func authorizationRepairs(
        authorization: CameraAgentAuthorization,
        expectedRepair: CameraAgentReadinessRepair
    ) {
        let machine = CameraAgentOnboardingStateMachine(
            serviceRegistration: .enabled,
            authorization: .observed(authorization),
            control: .reachable,
            frame: .ready,
            identity: .current,
            liveSnapshot: .accepted
        )

        #expect(machine.snapshot.blocker == .authorization(.observed(authorization)))
        #expect(machine.snapshot.recommendedRepair == expectedRepair)
    }

    @Test("control blockers keep unreachable and timeout failures distinct", arguments: [
        CameraAgentControlReachability.unknown,
        .unreachable,
        .timedOut,
    ])
    func controlRepairs(control: CameraAgentControlReachability) {
        let machine = CameraAgentOnboardingStateMachine(
            serviceRegistration: .enabled,
            authorization: .observed(.authorized),
            control: control,
            frame: .ready,
            identity: .current,
            liveSnapshot: .accepted
        )

        #expect(machine.snapshot.blocker == .control(control))
        #expect(machine.snapshot.recommendedRepair == .refresh(.control))
    }

    @Test("frame blockers keep startup and runtime failures distinct", arguments: [
        CameraAgentFrameReadiness.unknown,
        .awaitingFirstFrame,
        .unavailable,
        .stalled,
    ])
    func frameRepairs(frame: CameraAgentFrameReadiness) {
        let machine = CameraAgentOnboardingStateMachine(
            serviceRegistration: .enabled,
            authorization: .observed(.authorized),
            control: .reachable,
            frame: frame,
            identity: .current,
            liveSnapshot: .accepted
        )

        #expect(machine.snapshot.blocker == .frame(frame))
        #expect(machine.snapshot.recommendedRepair == .refresh(.frameReadiness))
    }

    @Test("only the currently visible repair intent emits one action")
    func visibleRepairIsRequired() {
        var machine = CameraAgentOnboardingStateMachine(
            serviceRegistration: .notRegistered,
            authorization: .observed(.notDetermined),
            control: .unknown,
            frame: .unknown
        )

        #expect(machine.handle(.visibleRepair(.requestCameraAuthorization)) == [])
        #expect(machine.handle(.visibleRepair(.refresh(.control))) == [])
        #expect(machine.handle(.visibleRepair(.registerAgent)) == [
            .registerAgent(within: CameraAgentOnboardingStateMachine.maximumRepairLatency),
        ])

        #expect(machine.handle(
            .serviceRegistrationObserved(.enabled)
        ) == [])
        #expect(machine.snapshot.authorization == .unknown)
        #expect(machine.handle(.visibleRepair(.requestCameraAuthorization)) == [])
        #expect(machine.handle(.identityObserved(
            .current,
            generationIdentifier: "helper-generation-a"
        )) == [])
        let serviceEpoch = machine.serviceEpoch
        #expect(machine.handle(.liveSnapshotObserved(
            .accepted,
            serviceEpoch: serviceEpoch
        )) == [])
        #expect(machine.handle(
            .authorizationObserved(.notDetermined, serviceEpoch: serviceEpoch)
        ) == [])
        #expect(machine.handle(.visibleRepair(.requestCameraAuthorization)) == [
            .requestCameraAuthorization,
        ])
    }

    @Test("refresh and repair-surface actions remain explicit and bounded")
    func explicitRepairActions() {
        var controlMachine = CameraAgentOnboardingStateMachine(
            serviceRegistration: .enabled,
            authorization: .observed(.authorized),
            control: .timedOut,
            frame: .unknown,
            identity: .current,
            liveSnapshot: .accepted
        )
        #expect(controlMachine.handle(.visibleRepair(.refresh(.control))) == [
            .refresh(
                .control,
                within: CameraAgentOnboardingStateMachine.maximumRepairLatency
            ),
        ])

        var approvalMachine = CameraAgentOnboardingStateMachine(
            serviceRegistration: .requiresApproval
        )
        #expect(approvalMachine.handle(
            .visibleRepair(.openRepairSurface(.backgroundItemsSettings))
        ) == [
            .openRepairSurface(.backgroundItemsSettings),
        ])
    }

    @Test("the earliest blocked layer is the sole recommended repair")
    func blockerPriorityIsStable() {
        var machine = CameraAgentOnboardingStateMachine(
            serviceRegistration: .notRegistered,
            authorization: .observed(.denied),
            control: .timedOut,
            frame: .stalled
        )

        #expect(machine.snapshot.blocker == .serviceRegistration(.notRegistered))
        #expect(machine.snapshot.recommendedRepair == .registerAgent)

        _ = machine.handle(.serviceRegistrationObserved(.enabled))
        _ = machine.handle(.identityObserved(
            .current,
            generationIdentifier: "helper-generation-a"
        ))
        let serviceEpoch = machine.serviceEpoch
        _ = machine.handle(.liveSnapshotObserved(
            .accepted,
            serviceEpoch: serviceEpoch
        ))
        _ = machine.handle(.authorizationObserved(.denied, serviceEpoch: serviceEpoch))
        #expect(machine.snapshot.blocker == .authorization(.observed(.denied)))
        #expect(machine.snapshot.recommendedRepair == .openRepairSurface(.cameraPrivacySettings))

        _ = machine.handle(.authorizationObserved(.authorized, serviceEpoch: serviceEpoch))
        _ = machine.handle(.controlObserved(.timedOut, serviceEpoch: serviceEpoch))
        #expect(machine.snapshot.blocker == .control(.timedOut))

        _ = machine.handle(.controlObserved(.reachable, serviceEpoch: serviceEpoch))
        _ = machine.handle(.frameObserved(.stalled, serviceEpoch: serviceEpoch))
        #expect(machine.snapshot.blocker == .frame(.stalled))
    }
}

struct ReadinessMatrixFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let identity: CameraAgentHelperIdentityObservation
    let liveSnapshot: CameraAgentLiveSnapshotObservation
    let authorization: CameraAgentAuthorizationObservation
    let control: CameraAgentControlReachability
    let frame: CameraAgentFrameReadiness
    let expectedBlocker: CameraAgentReadinessBlocker?
    let expectedRepair: CameraAgentReadinessRepair?

    var testDescription: String { name }
}
