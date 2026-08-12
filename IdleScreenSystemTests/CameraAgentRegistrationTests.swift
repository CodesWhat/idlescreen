import Foundation
import ServiceManagement
import Testing
@testable import IdleScreenSystem

@Suite("Camera agent registration adapter")
struct CameraAgentRegistrationTests {
    @Test("release app group derives the exact camera agent identity")
    func derivesReleaseIdentity() throws {
        let identity = try CameraAgentServiceIdentity(
            appGroupIdentifier: "group.com.idlescreen.shared"
        )

        #expect(identity.appGroupIdentifier == "group.com.idlescreen.shared")
        #expect(identity.serviceIdentifier == "group.com.idlescreen.shared.camera-agent")
        #expect(identity.plistName == "group.com.idlescreen.shared.camera-agent.plist")
    }

    @Test("debug app group derives the exact camera agent identity")
    func derivesDebugIdentity() throws {
        let identity = try CameraAgentServiceIdentity(
            appGroupIdentifier: "group.com.idlescreen.dev.shared"
        )

        #expect(identity.appGroupIdentifier == "group.com.idlescreen.dev.shared")
        #expect(identity.serviceIdentifier == "group.com.idlescreen.dev.shared.camera-agent")
        #expect(identity.plistName == "group.com.idlescreen.dev.shared.camera-agent.plist")
    }

    @Test(arguments: [
        "",
        "group.com.idlescreen.shared.camera-agent",
        "group.com.idlescreen.staging.shared",
        "com.idlescreen.shared"
    ])
    func rejectsUnknownIdentity(appGroupIdentifier: String) {
        #expect(throws: CameraAgentServiceIdentity.Error.unsupportedAppGroupIdentifier(
            appGroupIdentifier
        )) {
            try CameraAgentServiceIdentity(appGroupIdentifier: appGroupIdentifier)
        }
    }

    @Test(arguments: [
        (SMAppService.Status.notRegistered, CameraAgentRegistrationState.notRegistered),
        (SMAppService.Status.enabled, CameraAgentRegistrationState.enabled),
        (SMAppService.Status.requiresApproval, CameraAgentRegistrationState.requiresApproval),
        (SMAppService.Status.notFound, CameraAgentRegistrationState.notFound)
    ])
    func mapsServiceManagementStatus(
        systemStatus: SMAppService.Status,
        expectedState: CameraAgentRegistrationState
    ) {
        #expect(CameraAgentRegistrationState(systemStatus) == expectedState)
    }

    @Test("initialization does not create or register a service")
    func initializationHasNoServiceManagementSideEffects() throws {
        let service = FakeCameraAgentService(status: .notRegistered)
        let factory = RecordingCameraAgentServiceFactory(service: service)

        _ = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: factory
        )

        #expect(factory.requestedPlistNames.isEmpty)
        #expect(service.registerCallCount == 0)
        #expect(service.unregisterCallCount == 0)
    }

    @Test("refresh explicitly reads the current service state")
    func refreshesState() throws {
        let service = FakeCameraAgentService(status: .requiresApproval)
        let factory = RecordingCameraAgentServiceFactory(service: service)
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: factory
        )

        let outcome = client.refresh()

        #expect(outcome == .refreshed(.requiresApproval))
        #expect(factory.requestedPlistNames == [
            "group.com.idlescreen.shared.camera-agent.plist"
        ])
        #expect(service.registerCallCount == 0)
        #expect(service.unregisterCallCount == 0)
    }

    @Test("register acts only when called and returns the observed state")
    func registersExplicitly() throws {
        let service = FakeCameraAgentService(
            status: .notRegistered,
            statusAfterRegister: .enabled
        )
        let factory = RecordingCameraAgentServiceFactory(service: service)
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: factory
        )

        #expect(factory.requestedPlistNames.isEmpty)

        let outcome = client.register()

        #expect(outcome == .registered(.enabled))
        #expect(service.registerCallCount == 1)
        #expect(service.unregisterCallCount == 0)
    }

    @Test("a successful register can explicitly report pending user approval")
    func reportsApprovalAfterRegister() throws {
        let service = FakeCameraAgentService(
            status: .notRegistered,
            statusAfterRegister: .requiresApproval
        )
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: RecordingCameraAgentServiceFactory(service: service)
        )

        #expect(client.register() == .registered(.requiresApproval))
    }

    @Test("register failure retains its underlying diagnostic and never claims success")
    func reportsRegisterFailure() throws {
        let underlyingError = NSError(
            domain: "CameraAgentRegistrationTests",
            code: 91,
            userInfo: [NSLocalizedDescriptionKey: "registration denied"]
        )
        let service = FakeCameraAgentService(
            status: .requiresApproval,
            registerError: underlyingError
        )
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: RecordingCameraAgentServiceFactory(service: service)
        )

        let outcome = client.register()

        guard case let .failed(operation, state, diagnostic) = outcome else {
            Issue.record("Expected an explicit register failure, got \(outcome)")
            return
        }
        #expect(operation == .register)
        #expect(state == .requiresApproval)
        #expect(diagnostic.domain == underlyingError.domain)
        #expect(diagnostic.code == underlyingError.code)
        #expect(diagnostic.localizedDescription == "registration denied")
        #expect((diagnostic.underlyingError as NSError) === underlyingError)
    }

    @Test("unregister acts only when called and returns the observed state")
    func unregistersExplicitly() throws {
        let service = FakeCameraAgentService(
            status: .enabled,
            statusAfterUnregister: .notRegistered
        )
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: RecordingCameraAgentServiceFactory(service: service)
        )

        let outcome = client.unregister()

        #expect(outcome == .unregistered(.notRegistered))
        #expect(service.registerCallCount == 0)
        #expect(service.unregisterCallCount == 1)
    }

    @Test("unregister failure retains its underlying diagnostic and never claims success")
    func reportsUnregisterFailure() throws {
        let underlyingError = NSError(
            domain: "CameraAgentRegistrationTests",
            code: 92,
            userInfo: [NSLocalizedDescriptionKey: "unregistration failed"]
        )
        let service = FakeCameraAgentService(
            status: .enabled,
            unregisterError: underlyingError
        )
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: RecordingCameraAgentServiceFactory(service: service)
        )

        let outcome = client.unregister()

        guard case let .failed(operation, state, diagnostic) = outcome else {
            Issue.record("Expected an explicit unregister failure, got \(outcome)")
            return
        }
        #expect(operation == .unregister)
        #expect(state == .enabled)
        #expect(diagnostic.domain == underlyingError.domain)
        #expect(diagnostic.code == underlyingError.code)
        #expect(diagnostic.localizedDescription == "unregistration failed")
        #expect((diagnostic.underlyingError as NSError) === underlyingError)
    }

    @Test("replacement crosses a run-loop boundary before registering the new submission")
    func replacementWaitsForServiceManagementRemoval() async throws {
        let service = FakeCameraAgentService(
            status: .enabled,
            statusAfterRegister: .enabled,
            statusAfterUnregister: .notRegistered
        )
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: RecordingCameraAgentServiceFactory(service: service)
        )

        client.replace { _ in }
        #expect(service.unregisterCallCount == 1)
        #expect(service.registerCallCount == 0)

        for _ in 0 ..< 20 where service.registerCallCount == 0 {
            await Task.yield()
            await MainActor.run {}
        }
        #expect(service.unregisterCallCount == 1)
        #expect(service.registerCallCount == 1)
    }

    @Test("exact registered and running fingerprints prove the helper is current without mutation")
    func assessesCurrentHelperWithoutMutation() throws {
        let service = AssessmentCameraAgentService(status: .enabled)
        let factory = AssessmentCameraAgentServiceFactory(service: service)
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: factory
        )
        let embedded = try artifactFingerprint()

        let assessment = client.replacementAssessment(
            embedded: embedded,
            registered: embedded,
            running: embedded
        )

        #expect(assessment.registrationState == .enabled)
        #expect(assessment.classification == .current)
        #expect(assessment.mismatches.isEmpty)
        #expect(assessment.observationGaps.isEmpty)
        #expect(factory.requestedPlistNames == [
            "group.com.idlescreen.shared.camera-agent.plist"
        ])
        #expect(service.statusReadCount == 1)
        #expect(service.registerCallCount == 0)
        #expect(service.unregisterCallCount == 0)
    }

    @Test("an enabled service never proves replacement current without both observations")
    func keepsMissingArtifactObservationsInconclusive() throws {
        let service = AssessmentCameraAgentService(status: .enabled)
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: AssessmentCameraAgentServiceFactory(service: service)
        )

        let assessment = client.replacementAssessment(
            embedded: try artifactFingerprint(),
            registered: nil,
            running: nil
        )

        #expect(assessment.classification == .observationIncomplete)
        #expect(assessment.observationGaps == [.registeredArtifact, .runningProcess])
        #expect(assessment.mismatches.isEmpty)
        #expect(service.registerCallCount == 0)
        #expect(service.unregisterCallCount == 0)
    }

    @Test("a stale running executable hash requires helper replacement")
    func classifiesStaleRunningHelper() throws {
        let service = AssessmentCameraAgentService(status: .enabled)
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: AssessmentCameraAgentServiceFactory(service: service)
        )
        let embedded = try artifactFingerprint()
        let staleRunning = try artifactFingerprint(
            executableSHA256: String(repeating: "b", count: 64)
        )

        let assessment = client.replacementAssessment(
            embedded: embedded,
            registered: embedded,
            running: staleRunning
        )

        #expect(assessment.classification == .replacementRequired)
        #expect(assessment.mismatches == [
            CameraAgentArtifactMismatch(
                location: .runningProcess,
                differences: [.executableSHA256]
            )
        ])
        #expect(assessment.observationGaps.isEmpty)
    }

    @Test("a stale registered plist or helper version requires replacement even if the process is current")
    func classifiesStaleRegisteredArtifact() throws {
        let service = AssessmentCameraAgentService(status: .enabled)
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: AssessmentCameraAgentServiceFactory(service: service)
        )
        let embedded = try artifactFingerprint()
        let staleRegistered = try artifactFingerprint(
            bundleVersion: "0",
            launchAgentSHA256: String(repeating: "c", count: 64)
        )

        let assessment = client.replacementAssessment(
            embedded: embedded,
            registered: staleRegistered,
            running: embedded
        )

        #expect(assessment.classification == .replacementRequired)
        #expect(assessment.mismatches == [
            CameraAgentArtifactMismatch(
                location: .registeredArtifact,
                differences: [.bundleVersion, .launchAgentSHA256]
            )
        ])
    }

    @Test("signed identity drift is stale even when marketing versions match")
    func classifiesSignedIdentityDrift() throws {
        let service = AssessmentCameraAgentService(status: .enabled)
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: AssessmentCameraAgentServiceFactory(service: service)
        )
        let embedded = try artifactFingerprint()
        let foreign = try artifactFingerprint(
            signingIdentifier: "com.example.foreign-agent",
            teamIdentifier: "FOREIGN123",
            codeDirectoryHash: String(repeating: "d", count: 40)
        )

        let assessment = client.replacementAssessment(
            embedded: embedded,
            registered: foreign,
            running: foreign
        )

        #expect(assessment.classification == .replacementRequired)
        #expect(assessment.mismatches == [
            CameraAgentArtifactMismatch(
                location: .registeredArtifact,
                differences: [.signingIdentifier, .teamIdentifier, .codeDirectoryHash]
            ),
            CameraAgentArtifactMismatch(
                location: .runningProcess,
                differences: [.signingIdentifier, .teamIdentifier, .codeDirectoryHash]
            )
        ])
    }

    @Test(arguments: [
        (SMAppService.Status.notRegistered, CameraAgentRepairClassification.registrationRequired),
        (SMAppService.Status.requiresApproval, CameraAgentRepairClassification.approvalRequired),
        (SMAppService.Status.notFound, CameraAgentRepairClassification.serviceDefinitionMissing)
    ])
    func registrationStateTakesTruthfulRepairPrecedence(
        status: SMAppService.Status,
        expectedClassification: CameraAgentRepairClassification
    ) throws {
        let service = AssessmentCameraAgentService(status: status)
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: AssessmentCameraAgentServiceFactory(service: service)
        )
        let embedded = try artifactFingerprint()

        let assessment = client.replacementAssessment(
            embedded: embedded,
            registered: embedded,
            running: embedded
        )

        #expect(assessment.classification == expectedClassification)
        #expect(service.registerCallCount == 0)
        #expect(service.unregisterCallCount == 0)
    }

    @Test("malformed helper evidence is rejected at construction")
    func rejectsMalformedHelperEvidence() {
        #expect(throws: CameraAgentArtifactFingerprint.ValidationError.invalidCanonicalBundlePath) {
            try artifactFingerprint(canonicalBundlePath: "relative/helper.app")
        }
        #expect(throws: CameraAgentArtifactFingerprint.ValidationError.invalidServiceIdentifier) {
            try artifactFingerprint(serviceIdentifier: "")
        }
        #expect(throws: CameraAgentArtifactFingerprint.ValidationError.invalidBundleIdentifier) {
            try artifactFingerprint(bundleIdentifier: "com..idlescreen.camera-agent")
        }
        #expect(throws: CameraAgentArtifactFingerprint.ValidationError.invalidBundleVersion) {
            try artifactFingerprint(bundleVersion: " ")
        }
        #expect(throws: CameraAgentArtifactFingerprint.ValidationError.invalidMarketingVersion) {
            try artifactFingerprint(marketingVersion: "")
        }
        #expect(throws: CameraAgentArtifactFingerprint.ValidationError.invalidSigningIdentifier) {
            try artifactFingerprint(signingIdentifier: "invalid signing identifier")
        }
        #expect(throws: CameraAgentArtifactFingerprint.ValidationError.invalidTeamIdentifier) {
            try artifactFingerprint(teamIdentifier: "short")
        }
        #expect(throws: CameraAgentArtifactFingerprint.ValidationError.invalidTeamIdentifier) {
            try artifactFingerprint(teamIdentifier: "3524374a2s")
        }
        #expect(throws: CameraAgentArtifactFingerprint.ValidationError.invalidCodeDirectoryHash) {
            try artifactFingerprint(codeDirectoryHash: String(repeating: "g", count: 40))
        }
        #expect(throws: CameraAgentArtifactFingerprint.ValidationError.invalidExecutableSHA256) {
            try artifactFingerprint(executableSHA256: String(repeating: "a", count: 63))
        }
        #expect(throws: CameraAgentArtifactFingerprint.ValidationError.invalidLaunchAgentSHA256) {
            try artifactFingerprint(launchAgentSHA256: String(repeating: "z", count: 64))
        }
        #expect(throws: CameraAgentArtifactFingerprint.ValidationError.invalidProvisioningProfileSHA256) {
            try artifactFingerprint(
                provisioningProfileSHA256: String(repeating: "z", count: 64)
            )
        }
    }

    @Test("hexadecimal letter case does not make identical signed evidence stale")
    func comparesHexEvidenceCaseInsensitively() throws {
        let service = AssessmentCameraAgentService(status: .enabled)
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: AssessmentCameraAgentServiceFactory(service: service)
        )
        let embedded = try artifactFingerprint(
            codeDirectoryHash: String(repeating: "a", count: 40),
            executableSHA256: String(repeating: "b", count: 64),
            launchAgentSHA256: String(repeating: "c", count: 64)
        )
        let differentlyCased = try artifactFingerprint(
            codeDirectoryHash: String(repeating: "A", count: 40),
            executableSHA256: String(repeating: "B", count: 64),
            launchAgentSHA256: String(repeating: "C", count: 64)
        )

        let assessment = client.replacementAssessment(
            embedded: embedded,
            registered: differentlyCased,
            running: differentlyCased
        )

        #expect(assessment.classification == .current)
        #expect(assessment.mismatches.isEmpty)
        #expect(embedded.codeDirectoryHash == String(repeating: "a", count: 40))
        #expect(differentlyCased.codeDirectoryHash == String(repeating: "A", count: 40))
    }

    @Test("foreign running evidence takes precedence over a missing registered observation")
    func neverHidesForeignRunningEvidenceBehindIncompleteObservation() throws {
        let service = AssessmentCameraAgentService(status: .enabled)
        let client = CameraAgentRegistrationClient(
            identity: try releaseIdentity(),
            serviceFactory: AssessmentCameraAgentServiceFactory(service: service)
        )
        let embedded = try artifactFingerprint()
        let foreignRunning = try artifactFingerprint(
            serviceIdentifier: "com.example.foreign.camera-agent",
            bundleIdentifier: "com.example.foreign-camera-agent",
            signingIdentifier: "com.example.foreign-camera-agent",
            teamIdentifier: "FOREIGN123"
        )

        let assessment = client.replacementAssessment(
            embedded: embedded,
            registered: nil,
            running: foreignRunning
        )

        #expect(assessment.classification == .replacementRequired)
        #expect(assessment.observationGaps == [.registeredArtifact])
        #expect(assessment.mismatches == [
            CameraAgentArtifactMismatch(
                location: .runningProcess,
                differences: [
                    .serviceIdentifier,
                    .bundleIdentifier,
                    .signingIdentifier,
                    .teamIdentifier
                ]
            )
        ])
    }

    private func artifactFingerprint(
        canonicalBundlePath: String = "/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app",
        serviceIdentifier: String = "group.com.idlescreen.shared.camera-agent",
        bundleIdentifier: String = "com.idlescreen.camera-agent",
        bundleVersion: String = "1",
        marketingVersion: String = "0.1",
        signingIdentifier: String = "com.idlescreen.camera-agent",
        teamIdentifier: String = "3524374A2S",
        codeDirectoryHash: String = String(repeating: "1", count: 40),
        executableSHA256: String = String(repeating: "a", count: 64),
        launchAgentSHA256: String = String(repeating: "2", count: 64),
        provisioningProfileSHA256: String = String(repeating: "3", count: 64)
    ) throws -> CameraAgentArtifactFingerprint {
        try CameraAgentArtifactFingerprint(
            canonicalBundlePath: canonicalBundlePath,
            serviceIdentifier: serviceIdentifier,
            bundleIdentifier: bundleIdentifier,
            bundleVersion: bundleVersion,
            marketingVersion: marketingVersion,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            codeDirectoryHash: codeDirectoryHash,
            executableSHA256: executableSHA256,
            launchAgentSHA256: launchAgentSHA256,
            provisioningProfileSHA256: provisioningProfileSHA256
        )
    }

    private func releaseIdentity() throws -> CameraAgentServiceIdentity {
        try CameraAgentServiceIdentity(appGroupIdentifier: "group.com.idlescreen.shared")
    }
}

private final class FakeCameraAgentService: CameraAgentServicing {
    var status: SMAppService.Status
    let statusAfterRegister: SMAppService.Status?
    let statusAfterUnregister: SMAppService.Status?
    let registerError: (any Error)?
    let unregisterError: (any Error)?

    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(
        status: SMAppService.Status,
        statusAfterRegister: SMAppService.Status? = nil,
        statusAfterUnregister: SMAppService.Status? = nil,
        registerError: (any Error)? = nil,
        unregisterError: (any Error)? = nil
    ) {
        self.status = status
        self.statusAfterRegister = statusAfterRegister
        self.statusAfterUnregister = statusAfterUnregister
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        if let statusAfterRegister { status = statusAfterRegister }
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
        if let statusAfterUnregister { status = statusAfterUnregister }
    }
}

private final class RecordingCameraAgentServiceFactory: CameraAgentServiceCreating {
    let service: any CameraAgentServicing
    private(set) var requestedPlistNames: [String] = []

    init(service: any CameraAgentServicing) {
        self.service = service
    }

    func makeAgent(plistName: String) -> any CameraAgentServicing {
        requestedPlistNames.append(plistName)
        return service
    }
}

private final class AssessmentCameraAgentService: CameraAgentServicing {
    private let observedStatus: SMAppService.Status
    private(set) var statusReadCount = 0
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    var status: SMAppService.Status {
        statusReadCount += 1
        return observedStatus
    }

    init(status: SMAppService.Status) {
        observedStatus = status
    }

    func register() throws {
        registerCallCount += 1
    }

    func unregister() throws {
        unregisterCallCount += 1
    }
}

private final class AssessmentCameraAgentServiceFactory: CameraAgentServiceCreating {
    let service: any CameraAgentServicing
    private(set) var requestedPlistNames: [String] = []

    init(service: any CameraAgentServicing) {
        self.service = service
    }

    func makeAgent(plistName: String) -> any CameraAgentServicing {
        requestedPlistNames.append(plistName)
        return service
    }
}
