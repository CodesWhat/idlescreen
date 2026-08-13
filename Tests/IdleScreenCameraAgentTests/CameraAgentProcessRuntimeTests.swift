import Foundation
import IdleScreenCamera
import Testing
@testable import IdleScreenCameraAgentCore

@Suite("Camera agent process runtime", .serialized)
struct CameraAgentProcessRuntimeTests {
    @Test("process epoch seed rejects masked zero and reserves high-half growth")
    func processEpochSeedUsesNonzeroLow63Bits() {
        var zeroThenValue = ScriptedRandomGenerator([0, UInt64.max])
        #expect(CameraAgentProcessEpochSeed.randomNonzero(using: &zeroThenValue) == UInt64.max >> 1)
        #expect(zeroThenValue.drawCount == 2)

        var highBitOnlyThenValue = ScriptedRandomGenerator([1 << 63, (1 << 63) | 42])
        #expect(CameraAgentProcessEpochSeed.randomNonzero(using: &highBitOnlyThenValue) == 42)
        #expect(highBitOnlyThenValue.drawCount == 2)
    }

    @Test("configuration accepts only exact release and debug identity tuples")
    func validatesExactConfigurationTuples() throws {
        let release = try #require(CameraAgentProcessConfiguration(
            infoDictionary: processInfo(environment: .release)
        ))
        let debug = try #require(CameraAgentProcessConfiguration(
            infoDictionary: processInfo(environment: .debug)
        ))

        #expect(release.agentBundleIdentifier == "com.idlescreen.camera-agent")
        #expect(release.machServiceName == "group.com.idlescreen.shared.camera-agent")
        #expect(release.appGroupIdentifier == "group.com.idlescreen.shared")
        #expect(debug.agentBundleIdentifier == "com.idlescreen.camera-agent.dev")
        #expect(debug.machServiceName == "group.com.idlescreen.dev.shared.camera-agent")
        #expect(debug.appGroupIdentifier == "group.com.idlescreen.dev.shared")
        #expect(release.mailboxFileName == "camera-frames-v1.mailbox")

        for (key, invalidValue) in [
            ("CFBundleIdentifier", "com.example.agent"),
            ("IdleScreenCameraAgentMachServiceName", "group.com.idlescreen.dev.shared.camera-agent"),
            ("IdleScreenCameraAgentAppGroupIdentifier", "group.com.idlescreen.dev.shared"),
            ("IdleScreenCameraAgentTeamIdentifier", "bad\" or true"),
            ("IdleScreenCameraAgentMailboxFileName", "other.mailbox"),
        ] {
            var invalid = processInfo(environment: .release)
            invalid[key] = invalidValue
            #expect(CameraAgentProcessConfiguration(infoDictionary: invalid) == nil)
        }
    }

    @Test("bootstrap assembles one complete graph using the shared lease policy")
    func assemblesOneCompleteGraph() throws {
        let harness = try ProcessRuntimeHarness()

        _ = try harness.bootstrap()

        #expect(harness.container.requestedIdentifiers == ["group.com.idlescreen.shared"])
        #expect(harness.components.operations == [
            "agent-identity",
            "authorization-checker",
            "authorization-requester",
            "device-inventory-monitor",
            "capture-controller",
            "mailbox-publisher",
            "runtime-driver",
            "service",
            "bind-driver",
            "listener",
        ])
        #expect(harness.components.serviceLeaseTimeToLive == CameraAgentLeasePolicy.production.leaseTimeToLive)
        #expect(harness.components.mailboxFileNames == ["camera-frames-v1.mailbox"])
        #expect(harness.components.listenerConfigurations.map(\.machServiceName) == [
            "group.com.idlescreen.shared.camera-agent",
        ])
        #expect(harness.components.servicePeerPolicies.map(\.companionBundleIdentifiers) == [[
            "com.idlescreen.app",
        ]])
        #expect(harness.components.servicePeerPolicies.map(\.screenSaverBundleIdentifiers) == [[
            "com.idlescreen.app.screensaver",
        ]])
        #expect(harness.components.initialAuthorizations == [.authorized])
        #expect(harness.components.producerStreamEpochSeeds == [41])
        #expect(harness.components.identityRequestEpochs == [41])
        #expect(harness.components.serviceAgentIdentities.first?.processIncarnationEpoch == 41)
        #expect(harness.components.captureReceivedSharedAuthorizationChecker)
        #expect(harness.components.serviceReceivedSharedAuthorizationChecker)
    }

    @Test("bootstrap fails closed before assembly when self identity is unavailable")
    func missingSelfIdentityFailsClosed() throws {
        let harness = try ProcessRuntimeHarness()
        harness.components.selfIdentityIsAvailable = false

        #expect(throws: CameraAgentProcessBootstrapError.assemblyFailed) {
            _ = try harness.bootstrap()
        }
        #expect(harness.components.operations == ["agent-identity"])
    }

    @Test("self identity hashes signed bundle evidence and derives the containing app")
    func selfIdentityHashesBundleEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceAppURL = root.appendingPathComponent("idlescreen.app", isDirectory: true)
        let agentBundleURL = sourceAppURL
            .appendingPathComponent("Contents/Helpers/IdleScreenCameraAgent.app", isDirectory: true)
        let executableURL = agentBundleURL
            .appendingPathComponent("Contents/MacOS/IdleScreenCameraAgent")
        let launchAgentURL = sourceAppURL
            .appendingPathComponent("Contents/Library/LaunchAgents/group.com.idlescreen.shared.camera-agent.plist")
        let profileURL = agentBundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        let sourceProfileURL = sourceAppURL.appendingPathComponent(
            "Contents/embedded.provisionprofile"
        )
        for url in [executableURL, launchAgentURL, profileURL, sourceProfileURL] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try Data("agent-executable".utf8).write(to: executableURL)
        try Data("launch-agent-plist".utf8).write(to: launchAgentURL)
        try Data("provisioning-profile".utf8).write(to: profileURL)
        try Data("source-profile-decoy".utf8).write(to: sourceProfileURL)
        let configuration = try #require(CameraAgentProcessConfiguration(
            infoDictionary: processInfo(environment: .release)
        ))
        let inspector = StubSignedCodeInspector(evidence: CameraAgentSignedCodeEvidence(
            signingIdentifier: "com.idlescreen.camera-agent",
            teamIdentifier: "3524374A2S",
            codeDirectoryHash: String(repeating: "1", count: 40)
        ))
        let provider = CameraAgentSelfIdentityProvider(
            agentBundleURL: agentBundleURL,
            executableURL: executableURL,
            infoDictionary: [
                "CFBundleIdentifier": "com.idlescreen.camera-agent",
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "0.1",
            ],
            processIdentifier: { 4_242 },
            signedCodeInspector: inspector
        )

        let identity = try provider.identity(
            configuration: configuration,
            processIncarnationEpoch: 41
        )

        #expect(identity.processIdentifier == 4_242)
        #expect(identity.processIncarnationEpoch == 41)
        #expect(identity.executableSHA256 == "fac9f4283d4be3984e07673e44cd7675606c4c61adf1a9c05d65a8a72d4f9119")
        #expect(identity.launchAgentSHA256 == configuration.launchAgentSHA256)
        #expect(identity.provisioningProfileSHA256 == "c0d2b26f0a2940820271816bd6ef0fbc1d01674cb0cded291cb269782ae6e666")
        #expect(identity.sourceAppPath == sourceAppURL.resolvingSymlinksInPath().path)
    }

    @Test("bootstrap checks authorization but never requests access or starts capture")
    func bootstrapHasNoPhysicalSideEffects() throws {
        let harness = try ProcessRuntimeHarness()

        _ = try harness.bootstrap()

        #expect(harness.components.checker.statusCount == 1)
        #expect(harness.components.requester.requestCount == 0)
        #expect(harness.components.capture.startCount == 0)
        #expect(harness.components.capture.stopCount == 0)
        #expect(harness.components.inventory.startCount == 0)
        #expect(harness.components.publisher.configureCount == 0)
        #expect(harness.components.publisher.publishCount == 0)
        #expect(harness.components.listener.activateCount == 0)
    }

    @Test("start activates one listener, reaps every second, and forwards sleep and wake")
    func startWiresRuntimeSources() throws {
        let harness = try ProcessRuntimeHarness()
        let runtime = try harness.bootstrap()

        runtime.start()
        runtime.start()

        #expect(harness.repeatingScheduler.intervals == [1])
        #expect(harness.sleepWake.startCount == 1)
        #expect(harness.components.inventory.startCount == 1)
        #expect(harness.components.driver.inventorySnapshots == [
            CameraDeviceInventorySnapshot(generation: 1, devices: []),
        ])
        #expect(harness.components.listener.activateCount == 1)

        harness.repeatingScheduler.fire()
        harness.repeatingScheduler.fire()
        harness.sleepWake.sendSleep()
        harness.sleepWake.sendWake()

        #expect(harness.components.inventory.refreshCount == 2)
        #expect(harness.components.service.reapCount == 2)
        #expect(harness.components.service.authorizationRefreshCount == 2)
        #expect(harness.components.driver.sleepCount == 1)
        #expect(harness.components.driver.wakeCount == 1)
    }

    @Test("shutdown cancels sources and invalidates listener and publisher exactly once")
    func shutdownIsCompleteAndIdempotent() throws {
        let harness = try ProcessRuntimeHarness()
        let runtime = try harness.bootstrap()
        runtime.start()

        runtime.shutdown()
        runtime.shutdown()

        #expect(harness.repeatingScheduler.token.cancelCount == 1)
        #expect(harness.sleepWake.token.cancelCount == 1)
        #expect(harness.components.inventory.stopCount == 1)
        #expect(harness.components.driver.inventoryCancellationCount == 1)
        #expect(harness.components.listener.invalidateCount == 1)
        #expect(harness.components.publisher.invalidateCount == 1)
        harness.repeatingScheduler.fire()
        harness.sleepWake.sendSleep()
        #expect(harness.components.service.reapCount == 0)
        #expect(harness.components.driver.sleepCount == 0)
    }

    @Test("termination signal shuts down the runtime before successful process exit")
    func terminationSignalGracefullyStopsProcess() throws {
        let harness = try ProcessRuntimeHarness()
        let runtime = try harness.bootstrap()
        let terminationSource = FakeTerminationSignalSource()
        let components = harness.components
        let repeatingScheduler = harness.repeatingScheduler
        let sleepWake = harness.sleepWake
        let processTerminator = FakeProcessTerminator {
            components.inventory.stopCount == 1
                && components.driver.inventoryCancellationCount == 1
                && components.listener.invalidateCount == 1
                && components.publisher.invalidateCount == 1
                && repeatingScheduler.token.cancelCount == 1
                && sleepWake.token.cancelCount == 1
                && terminationSource.token.cancelCount == 1
        }

        runtime.startForProcessLifetime(
            terminationSource: terminationSource,
            processTerminator: processTerminator
        )
        terminationSource.sendTermination()
        terminationSource.sendTermination()

        #expect(terminationSource.startCount == 1)
        #expect(harness.components.listener.activateCount == 1)
        #expect(processTerminator.terminationCount == 1)
        #expect(processTerminator.cleanupWasCompleteAtTermination)
    }

    @Test("the runtime retains every process owner after its factory is released")
    func retainsProcessOwners() throws {
        let configuration = try #require(CameraAgentProcessConfiguration(
            infoDictionary: processInfo(environment: .release)
        ))
        let container = FakeContainerLocator()
        let repeatingScheduler = FakeRepeatingScheduler()
        let sleepWake = FakeSleepWakeSource()
        var components: FakeProcessComponents? = FakeProcessComponents()
        let references = try #require(components).weakReferences
        var runtime: CameraAgentProcessRuntime? = try CameraAgentProcessRuntime.bootstrap(
            configuration: configuration,
            producerStreamEpochSeed: 41,
            containerLocator: container,
            components: try #require(components),
            repeatingScheduler: repeatingScheduler,
            sleepWakeSource: sleepWake
        )

        components = nil

        #expect(references.allAreAlive)
        runtime?.shutdown()
        runtime = nil
        #expect(references.allAreReleased)
    }

    @Test("bootstrap fails closed when the configured App Group has no container")
    func missingContainerFailsClosed() throws {
        let configuration = try #require(CameraAgentProcessConfiguration(
            infoDictionary: processInfo(environment: .release)
        ))
        let container = FakeContainerLocator()
        container.result = nil

        #expect(throws: CameraAgentProcessBootstrapError.containerUnavailable) {
            _ = try CameraAgentProcessRuntime.bootstrap(
                configuration: configuration,
                producerStreamEpochSeed: 41,
                containerLocator: container,
                components: FakeProcessComponents(),
                repeatingScheduler: FakeRepeatingScheduler(),
                sleepWakeSource: FakeSleepWakeSource()
            )
        }
        #expect(CameraAgentProcessBootstrapError.containerUnavailable.stderrToken == "container-unavailable")
        #expect(CameraAgentProcessBootstrapError.assemblyFailed.stderrToken == "assembly-failed")
    }

    @Test("bootstrap rejects a zero process epoch seed before assembling components")
    func zeroProcessEpochSeedFailsClosed() throws {
        let harness = try ProcessRuntimeHarness()

        #expect(throws: CameraAgentProcessBootstrapError.assemblyFailed) {
            _ = try harness.bootstrap(producerStreamEpochSeed: 0)
        }
        #expect(harness.container.requestedIdentifiers.isEmpty)
        #expect(harness.components.operations.isEmpty)
        #expect(harness.components.producerStreamEpochSeeds.isEmpty)
    }
}

private struct ScriptedRandomGenerator: RandomNumberGenerator {
    private var values: [UInt64]
    private(set) var drawCount = 0

    init(_ values: [UInt64]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    mutating func next() -> UInt64 {
        defer { drawCount += 1 }
        return values[min(drawCount, values.count - 1)]
    }
}

private struct StubSignedCodeInspector: CameraAgentSignedCodeInspecting {
    let evidence: CameraAgentSignedCodeEvidence

    func inspectCurrentCode(
        agentBundleURL: URL,
        executableURL: URL,
        sourceAppURL: URL
    ) throws -> CameraAgentSignedCodeEvidence {
        _ = agentBundleURL
        _ = executableURL
        _ = sourceAppURL
        return evidence
    }
}

private enum ProcessEnvironment {
    case release
    case debug
}

private func processInfo(environment: ProcessEnvironment) -> [String: Any] {
    switch environment {
    case .release:
        [
            "CFBundleIdentifier": "com.idlescreen.camera-agent",
            "IdleScreenCameraAgentMachServiceName": "group.com.idlescreen.shared.camera-agent",
            "IdleScreenCameraAgentAppGroupIdentifier": "group.com.idlescreen.shared",
            "IdleScreenCameraAgentTeamIdentifier": "3524374A2S",
            "IdleScreenCameraAgentMailboxFileName": "camera-frames-v1.mailbox",
            "IdleScreenCameraAgentLaunchAgentSHA256":
                "151f0b19ff95aa853a3188f7e64c3eae8d159c5718658a4ba6e9518dcaa19e92",
        ]
    case .debug:
        [
            "CFBundleIdentifier": "com.idlescreen.camera-agent.dev",
            "IdleScreenCameraAgentMachServiceName": "group.com.idlescreen.dev.shared.camera-agent",
            "IdleScreenCameraAgentAppGroupIdentifier": "group.com.idlescreen.dev.shared",
            "IdleScreenCameraAgentTeamIdentifier": "3524374A2S",
            "IdleScreenCameraAgentMailboxFileName": "camera-frames-v1.mailbox",
            "IdleScreenCameraAgentLaunchAgentSHA256":
                "43adaaf96c2c1ea87365b2f46e33327005ecaa1fa4bdf8eb9e2edead682ad9cf",
        ]
    }
}

private final class ProcessRuntimeHarness {
    let configuration: CameraAgentProcessConfiguration
    let container = FakeContainerLocator()
    let components = FakeProcessComponents()
    let repeatingScheduler = FakeRepeatingScheduler()
    let sleepWake = FakeSleepWakeSource()

    init() throws {
        configuration = try #require(CameraAgentProcessConfiguration(
            infoDictionary: processInfo(environment: .release)
        ))
    }

    func bootstrap(producerStreamEpochSeed: UInt64 = 41) throws -> CameraAgentProcessRuntime {
        try CameraAgentProcessRuntime.bootstrap(
            configuration: configuration,
            producerStreamEpochSeed: producerStreamEpochSeed,
            containerLocator: container,
            components: components,
            repeatingScheduler: repeatingScheduler,
            sleepWakeSource: sleepWake
        )
    }
}

private final class FakeContainerLocator: CameraAgentAppGroupContainerLocating,
    @unchecked Sendable
{
    var result: URL? = URL(fileURLWithPath: "/private/fake-app-group", isDirectory: true)
    private(set) var requestedIdentifiers: [String] = []

    func containerURL(forAppGroupIdentifier identifier: String) -> URL? {
        requestedIdentifiers.append(identifier)
        return result
    }
}

private final class FakeProcessComponents: CameraAgentProcessComponentBuilding,
    @unchecked Sendable
{
    let checker = FakeAuthorizationChecker()
    let requester = FakeAuthorizationRequester()
    let inventory = FakeProcessInventoryMonitor()
    let capture = FakeRuntimeCaptureController()
    let publisher = FakeRuntimePublisher()
    let driver = FakeProcessDriver()
    let service = FakeProcessService()
    let listener = FakeProcessListener()

    private(set) var operations: [String] = []
    var selfIdentityIsAvailable = true
    private(set) var identityRequestEpochs: [UInt64] = []
    private(set) var mailboxFileNames: [String] = []
    private(set) var serviceLeaseTimeToLive: TimeInterval?
    private(set) var servicePeerPolicies: [CameraAgentPeerPolicy] = []
    private(set) var initialAuthorizations: [CameraAgentAuthorization] = []
    private(set) var producerStreamEpochSeeds: [UInt64] = []
    private(set) var serviceAgentIdentities: [IdleScreenCameraAgentIdentity] = []
    private(set) var listenerConfigurations: [CameraAgentXPCListenerConfiguration] = []
    private(set) var captureReceivedSharedAuthorizationChecker = false
    private(set) var serviceReceivedSharedAuthorizationChecker = false

    var weakReferences: WeakProcessReferences {
        WeakProcessReferences(
            checker: checker,
            requester: requester,
            inventory: inventory,
            capture: capture,
            publisher: publisher,
            driver: driver,
            service: service,
            listener: listener
        )
    }

    func makeAgentIdentity(
        configuration: CameraAgentProcessConfiguration,
        processIncarnationEpoch: UInt64
    ) throws -> IdleScreenCameraAgentIdentity {
        operations.append("agent-identity")
        identityRequestEpochs.append(processIncarnationEpoch)
        guard selfIdentityIsAvailable,
              let identity = makeTestAgentIdentity(
                  processIncarnationEpoch: processIncarnationEpoch,
                  bundleIdentifier: configuration.agentBundleIdentifier,
                  serviceIdentifier: configuration.machServiceName,
                  teamIdentifier: configuration.expectedTeamIdentifier
              ) else {
            throw CameraAgentProcessBootstrapError.assemblyFailed
        }
        return identity
    }

    func makeAuthorizationChecker() -> any CameraCaptureAuthorizationChecking {
        operations.append("authorization-checker")
        return checker
    }

    func makeAuthorizationRequester() -> any CameraAgentAuthorizationRequesting {
        operations.append("authorization-requester")
        return requester
    }

    func makeDeviceInventoryMonitor() -> any CameraAgentProcessDeviceInventoryMonitoring {
        operations.append("device-inventory-monitor")
        return inventory
    }

    func makeCaptureController(
        authorizationChecker: any CameraCaptureAuthorizationChecking
    ) -> any CameraAgentRuntimeCaptureControlling {
        captureReceivedSharedAuthorizationChecker =
            (authorizationChecker as? FakeAuthorizationChecker) === checker
        operations.append("capture-controller")
        return capture
    }

    func makeFramePublisher(
        appGroupContainerURL: URL,
        mailboxFileName: String
    ) throws -> any CameraAgentProcessFramePublishing {
        _ = appGroupContainerURL
        operations.append("mailbox-publisher")
        mailboxFileNames.append(mailboxFileName)
        return publisher
    }

    func makeRuntimeDriver(
        permissionRequester: any CameraAgentAuthorizationRequesting,
        captureController: any CameraAgentRuntimeCaptureControlling,
        framePublisher: any CameraAgentProcessFramePublishing
    ) throws -> any CameraAgentProcessDriving {
        _ = permissionRequester
        _ = captureController
        _ = framePublisher
        operations.append("runtime-driver")
        return driver
    }

    func makeService(
        peerPolicy: CameraAgentPeerPolicy,
        captureLimits: CameraAgentCaptureLimits,
        leaseTimeToLive: TimeInterval,
        producerStreamEpochSeed: UInt64,
        agentIdentity: IdleScreenCameraAgentIdentity,
        initialAuthorization: CameraAgentAuthorization,
        authorizationChecker: any CameraCaptureAuthorizationChecking,
        driver: any CameraAgentProcessDriving
    ) throws -> any CameraAgentProcessServicing {
        _ = captureLimits
        _ = driver
        serviceReceivedSharedAuthorizationChecker =
            (authorizationChecker as? FakeAuthorizationChecker) === checker
        operations.append("service")
        serviceLeaseTimeToLive = leaseTimeToLive
        producerStreamEpochSeeds.append(producerStreamEpochSeed)
        serviceAgentIdentities.append(agentIdentity)
        servicePeerPolicies.append(peerPolicy)
        initialAuthorizations.append(initialAuthorization)
        return service
    }

    func bind(
        driver: any CameraAgentProcessDriving,
        to service: any CameraAgentProcessServicing
    ) {
        operations.append("bind-driver")
        driver.bind(to: service)
    }

    func makeListener(
        configuration: CameraAgentXPCListenerConfiguration,
        service: any CameraAgentProcessServicing
    ) throws -> any CameraAgentProcessListening {
        _ = service
        operations.append("listener")
        listenerConfigurations.append(configuration)
        return listener
    }
}

private final class FakeAuthorizationChecker: CameraCaptureAuthorizationChecking,
    @unchecked Sendable
{
    var status: CameraCaptureAuthorization = .authorized
    private(set) var statusCount = 0

    func authorizationStatus() -> CameraCaptureAuthorization {
        statusCount += 1
        return status
    }
}

private final class FakeAuthorizationRequester: CameraAgentAuthorizationRequesting,
    @unchecked Sendable
{
    private(set) var requestCount = 0

    func requestVideoAccess(
        completion: @escaping @Sendable (CameraAgentAuthorization) -> Void
    ) {
        requestCount += 1
        completion(.authorized)
    }
}

private final class FakeProcessInventoryMonitor:
    CameraAgentProcessDeviceInventoryMonitoring,
    @unchecked Sendable
{
    private(set) var startCount = 0
    private(set) var refreshCount = 0
    private(set) var stopCount = 0
    private var handler: (@Sendable (CameraDeviceInventorySnapshot) -> Void)?

    @discardableResult
    func start(
        _ handler: @escaping @Sendable (CameraDeviceInventorySnapshot) -> Void
    ) -> Bool {
        guard self.handler == nil else { return false }
        startCount += 1
        self.handler = handler
        handler(CameraDeviceInventorySnapshot(generation: 1, devices: []))
        return true
    }

    func stop() {
        guard handler != nil else { return }
        stopCount += 1
        handler = nil
    }

    func refresh() {
        guard handler != nil else { return }
        refreshCount += 1
    }
}

private final class FakeRuntimeCaptureController: CameraAgentRuntimeCaptureControlling,
    @unchecked Sendable
{
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(
        _ request: CameraCaptureRequest,
        frameHandler: @escaping @Sendable (CameraCaptureFrame) -> Void,
        eventHandler: @escaping @Sendable (CameraCaptureSessionEvent) -> Void
    ) throws -> CameraCaptureDeviceDescriptor {
        _ = request
        _ = frameHandler
        _ = eventHandler
        startCount += 1
        return CameraCaptureDeviceDescriptor(uniqueID: "fake", name: "Fake", kind: .builtIn)
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        stopCount += 1
        completion()
    }
}

private final class FakeRuntimePublisher: CameraAgentProcessFramePublishing,
    @unchecked Sendable
{
    let transportIdentifier = "camera-frames-v1.mailbox"
    private(set) var configureCount = 0
    private(set) var publishCount = 0
    private(set) var invalidateCount = 0

    func configure(
        generation: UInt64,
        configuration: CameraAgentStreamConfiguration
    ) throws {
        _ = generation
        _ = configuration
        configureCount += 1
    }

    func publish(
        _ frame: CameraCaptureFrame,
        generation: UInt64
    ) throws -> IdleScreenCameraFrameDescriptor {
        _ = frame
        _ = generation
        publishCount += 1
        throw TestProcessError.unused
    }

    func finish(generation: UInt64) throws {
        _ = generation
    }

    func invalidate() throws {
        invalidateCount += 1
    }
}

private final class FakeProcessDriver: CameraAgentProcessDriving, @unchecked Sendable {
    private(set) var bindCount = 0
    private(set) var sleepCount = 0
    private(set) var wakeCount = 0
    private(set) var inventorySnapshots: [CameraDeviceInventorySnapshot] = []
    private(set) var inventoryCancellationCount = 0
    weak var receiver: (any CameraAgentRuntimeEventReceiving)?

    func transportIdentifier(for configuration: CameraAgentStreamConfiguration) -> String? {
        _ = configuration
        return "camera-frames-v1.mailbox"
    }

    func perform(
        _ action: CameraAgentAction,
        configuration: CameraAgentStreamConfiguration?
    ) {
        _ = action
        _ = configuration
    }

    func bind(to receiver: any CameraAgentRuntimeEventReceiving) {
        bindCount += 1
        self.receiver = receiver
    }

    func receiveSleep() {
        sleepCount += 1
    }

    func receiveWake() {
        wakeCount += 1
    }

    func receiveDeviceInventory(_ snapshot: CameraDeviceInventorySnapshot) {
        inventorySnapshots.append(snapshot)
    }

    func cancelDeviceInventoryCallbacks() {
        inventoryCancellationCount += 1
    }
}

private final class FakeProcessService: CameraAgentProcessServicing, @unchecked Sendable {
    private(set) var reapCount = 0
    private(set) var authorizationRefreshCount = 0

    func receiveAuthorizationResult(_ result: CameraAgentAuthorization) {
        _ = result
    }

    func receiveCaptureDriverEvent(_ event: CameraAgentCaptureDriverEvent) {
        _ = event
    }

    @discardableResult
    func reapExpiredLeases() -> Int {
        reapCount += 1
        return 0
    }

    func refreshAuthorizationForActiveDemand() {
        authorizationRefreshCount += 1
    }
}

private final class FakeProcessListener: CameraAgentProcessListening, @unchecked Sendable {
    private(set) var activateCount = 0
    private(set) var invalidateCount = 0

    func activate() {
        activateCount += 1
    }

    func invalidate() {
        invalidateCount += 1
    }
}

private final class FakeRepeatingScheduler: CameraAgentProcessRepeatingScheduling,
    @unchecked Sendable
{
    let token = FakeProcessToken()
    private(set) var intervals: [TimeInterval] = []
    private var operation: (@Sendable () -> Void)?

    func scheduleRepeating(
        every interval: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any CameraAgentProcessCancellable {
        intervals.append(interval)
        self.operation = operation
        return token
    }

    func fire() {
        guard !token.isCancelled else { return }
        operation?()
    }
}

private final class FakeSleepWakeSource: CameraAgentSleepWakeSourcing, @unchecked Sendable {
    let token = FakeProcessToken()
    private(set) var startCount = 0
    private var sleepHandler: (@Sendable () -> Void)?
    private var wakeHandler: (@Sendable () -> Void)?

    func start(
        sleepHandler: @escaping @Sendable () -> Void,
        wakeHandler: @escaping @Sendable () -> Void
    ) -> any CameraAgentProcessCancellable {
        startCount += 1
        self.sleepHandler = sleepHandler
        self.wakeHandler = wakeHandler
        return token
    }

    func sendSleep() {
        guard !token.isCancelled else { return }
        sleepHandler?()
    }

    func sendWake() {
        guard !token.isCancelled else { return }
        wakeHandler?()
    }
}

private final class FakeTerminationSignalSource:
    CameraAgentTerminationSignalSourcing,
    @unchecked Sendable
{
    let token = FakeProcessToken()
    private(set) var startCount = 0
    private var terminationHandler: (@Sendable () -> Void)?

    func start(
        terminationHandler: @escaping @Sendable () -> Void
    ) -> any CameraAgentProcessCancellable {
        startCount += 1
        self.terminationHandler = terminationHandler
        return token
    }

    func sendTermination() {
        guard !token.isCancelled else { return }
        terminationHandler?()
    }
}

private final class FakeProcessTerminator:
    CameraAgentProcessTerminating,
    @unchecked Sendable
{
    private let cleanupObservation: @Sendable () -> Bool
    private(set) var terminationCount = 0
    private(set) var cleanupWasCompleteAtTermination = false

    init(cleanupObservation: @escaping @Sendable () -> Bool) {
        self.cleanupObservation = cleanupObservation
    }

    func terminateSuccessfully() {
        terminationCount += 1
        cleanupWasCompleteAtTermination = cleanupObservation()
    }
}

private final class FakeProcessToken: CameraAgentProcessCancellable, @unchecked Sendable {
    private(set) var cancelCount = 0
    private(set) var isCancelled = false

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelCount += 1
    }
}

private struct WeakProcessReferences {
    private let references: [WeakProcessReference]

    init(
        checker: AnyObject,
        requester: AnyObject,
        inventory: AnyObject,
        capture: AnyObject,
        publisher: AnyObject,
        driver: AnyObject,
        service: AnyObject,
        listener: AnyObject
    ) {
        references = [
            checker,
            requester,
            inventory,
            capture,
            publisher,
            driver,
            service,
            listener,
        ].map(WeakProcessReference.init)
    }

    var allAreAlive: Bool {
        references.allSatisfy { $0.value != nil }
    }

    var allAreReleased: Bool {
        references.allSatisfy { $0.value == nil }
    }
}

private final class WeakProcessReference {
    weak var value: AnyObject?

    init(_ value: AnyObject) {
        self.value = value
    }
}

private enum TestProcessError: Error {
    case unused
}
