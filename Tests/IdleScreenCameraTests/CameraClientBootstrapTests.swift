import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Camera client bootstrap", .serialized)
struct CameraClientBootstrapTests {
    @Test("exact release and debug Info tuples assemble one inert runtime")
    func exactProductTuplesAssembleInertRuntime() throws {
        for tuple in [
            (
                CameraClientRuntimeConfiguration.releaseAppGroupIdentifier,
                CameraAgentXPCClientConfiguration.releaseMachServiceName
            ),
            (
                CameraClientRuntimeConfiguration.debugAppGroupIdentifier,
                CameraAgentXPCClientConfiguration.debugMachServiceName
            ),
        ] {
            try withBootstrapHarness { harness in
                let result = CameraClientBootstrap.makeRuntime(
                    infoDictionary: bootstrapInfo(
                        appGroupIdentifier: tuple.0,
                        machServiceName: tuple.1
                    ),
                    containerLocator: harness.containerLocator,
                    scheduler: harness.scheduler,
                    connectionFactory: harness.connectionFactory.makeConnection,
                    frameSourceClock: harness.clock,
                    mappingFactory: harness.mappingFactory
                )
                let runtime = try #require(result.runtime)

                #expect(result.status == .ready)
                #expect(runtime.configuration.appGroupIdentifier == tuple.0)
                #expect(runtime.configuration.machServiceName == tuple.1)
                #expect(harness.containerLocator.requestedIdentifiers == [tuple.0])
                #expect(runtime.activeConsumerCount == 0)
                #expect(harness.connectionFactory.requestedServiceNames.isEmpty)
                #expect(harness.scheduler.scheduleCount == 0)
                #expect(harness.mappingFactory.requestedURLs.isEmpty)
            }
        }
    }

    @Test("a missing required Info value fails closed before container lookup")
    func missingConfigurationFailsClosed() {
        let requiredKeys = [
            CameraClientBootstrap.appGroupInfoKey,
            CameraClientBootstrap.machServiceInfoKey,
            CameraClientBootstrap.teamIdentifierInfoKey,
        ]

        for missingKey in requiredKeys {
            let harness = BootstrapHarness(containerURL: URL(fileURLWithPath: "/unused"))
            var info = bootstrapInfo()
            info.removeValue(forKey: missingKey)

            let result = harness.makeResult(infoDictionary: info)

            #expect(result.status == .missingConfiguration)
            #expect(result.runtime == nil)
            #expect(harness.containerLocator.requestedIdentifiers.isEmpty)
            #expect(harness.connectionFactory.requestedServiceNames.isEmpty)
            #expect(harness.scheduler.scheduleCount == 0)
            #expect(harness.mappingFactory.requestedURLs.isEmpty)
        }
    }

    @Test("wrong value types and mismatched product tuples are rejected exactly")
    func invalidConfigurationFailsClosed() {
        let invalidDictionaries: [[String: Any]] = [
            bootstrapInfo(overrides: [
                CameraClientBootstrap.appGroupInfoKey: NSNumber(value: 7),
            ]),
            bootstrapInfo(overrides: [
                CameraClientBootstrap.appGroupInfoKey:
                    CameraClientRuntimeConfiguration.releaseAppGroupIdentifier,
                CameraClientBootstrap.machServiceInfoKey:
                    CameraAgentXPCClientConfiguration.debugMachServiceName,
            ]),
            bootstrapInfo(overrides: [
                CameraClientBootstrap.teamIdentifierInfoKey: "AAAAAAAAAA",
            ]),
            bootstrapInfo(overrides: [
                CameraClientBootstrap.appGroupInfoKey:
                    " \(CameraClientRuntimeConfiguration.releaseAppGroupIdentifier)",
            ]),
        ]

        for info in invalidDictionaries {
            let harness = BootstrapHarness(containerURL: URL(fileURLWithPath: "/unused"))

            let result = harness.makeResult(infoDictionary: info)

            #expect(result.status == .invalidConfiguration)
            #expect(result.runtime == nil)
            #expect(harness.containerLocator.requestedIdentifiers.isEmpty)
            #expect(harness.connectionFactory.requestedServiceNames.isEmpty)
            #expect(harness.scheduler.scheduleCount == 0)
            #expect(harness.mappingFactory.requestedURLs.isEmpty)
        }
    }

    @Test("an unavailable or invalid App Group container returns one bounded reason")
    func unavailableContainerFailsWithoutLeakingItsPath() throws {
        let unavailable = BootstrapHarness(containerURL: nil)
        let unavailableResult = unavailable.makeResult()

        #expect(unavailableResult.status == .appGroupContainerUnavailable)
        #expect(unavailableResult.runtime == nil)
        #expect(unavailable.containerLocator.requestedIdentifiers == [
            CameraClientRuntimeConfiguration.releaseAppGroupIdentifier,
        ])

        let privatePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-bootstrap-container-\(UUID().uuidString)")
        let invalid = BootstrapHarness(containerURL: privatePath)
        let invalidResult = invalid.makeResult()

        #expect(invalidResult.status == .appGroupContainerUnavailable)
        #expect(invalidResult.runtime == nil)
        #expect(!String(describing: invalidResult.status).contains(privatePath.path))
        #expect(!invalidResult.status.rawValue.contains(privatePath.path))
        #expect(invalid.connectionFactory.requestedServiceNames.isEmpty)
        #expect(invalid.scheduler.scheduleCount == 0)
        #expect(invalid.mappingFactory.requestedURLs.isEmpty)
    }
}

private func bootstrapInfo(
    appGroupIdentifier: String =
        CameraClientRuntimeConfiguration.releaseAppGroupIdentifier,
    machServiceName: String =
        CameraAgentXPCClientConfiguration.releaseMachServiceName,
    overrides: [String: Any] = [:]
) -> [String: Any] {
    var info: [String: Any] = [
        CameraClientBootstrap.appGroupInfoKey: appGroupIdentifier,
        CameraClientBootstrap.machServiceInfoKey: machServiceName,
        CameraClientBootstrap.teamIdentifierInfoKey:
            CameraClientRuntimeConfiguration.productionTeamIdentifier,
    ]
    for (key, value) in overrides {
        info[key] = value
    }
    return info
}

private func withBootstrapHarness<Result>(
    _ body: (BootstrapHarness) throws -> Result
) throws -> Result {
    let containerURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "idlescreen-client-bootstrap-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: containerURL,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: containerURL) }
    return try body(BootstrapHarness(containerURL: containerURL))
}

private final class BootstrapHarness {
    let containerLocator: BootstrapContainerLocator
    let scheduler = BootstrapScheduler()
    let connectionFactory = BootstrapConnectionFactory()
    let clock = BootstrapClock()
    let mappingFactory = BootstrapMappingFactory()

    init(containerURL: URL?) {
        containerLocator = BootstrapContainerLocator(containerURL: containerURL)
    }

    func makeResult(
        infoDictionary: [String: Any] = bootstrapInfo()
    ) -> CameraClientBootstrapResult {
        CameraClientBootstrap.makeRuntime(
            infoDictionary: infoDictionary,
            containerLocator: containerLocator,
            scheduler: scheduler,
            connectionFactory: connectionFactory.makeConnection,
            frameSourceClock: clock,
            mappingFactory: mappingFactory
        )
    }
}

private final class BootstrapContainerLocator:
    CameraClientAppGroupContainerLocating,
    @unchecked Sendable
{
    private let containerURL: URL?
    private(set) var requestedIdentifiers: [String] = []

    init(containerURL: URL?) {
        self.containerURL = containerURL
    }

    func containerURL(
        forSecurityApplicationGroupIdentifier identifier: String
    ) -> URL? {
        requestedIdentifiers.append(identifier)
        return containerURL
    }
}

private final class BootstrapScheduler:
    CameraLeaseScheduling,
    @unchecked Sendable
{
    private final class Token: CameraLeaseScheduledTask, @unchecked Sendable {
        func cancel() {}
    }

    var now: TimeInterval = 0
    private(set) var scheduleCount = 0

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any CameraLeaseScheduledTask {
        scheduleCount += 1
        return Token()
    }
}

private final class BootstrapConnectionFactory: @unchecked Sendable {
    private(set) var requestedServiceNames: [String] = []

    func makeConnection(
        serviceName: String
    ) -> any CameraAgentXPCConnectionTransport {
        requestedServiceNames.append(serviceName)
        return BootstrapXPCTransport()
    }
}

private final class BootstrapXPCTransport:
    CameraAgentXPCConnectionTransport,
    @unchecked Sendable
{
    var remoteObjectInterface: NSXPCInterface?
    var interruptionHandler: (() -> Void)?
    var invalidationHandler: (() -> Void)?

    func setCodeSigningRequirement(_ requirement: String) {}
    func activate() {}
    func invalidate() {}

    func remoteCameraProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> (any IdleScreenCameraXPCProtocol)? {
        nil
    }
}

private final class BootstrapClock: CameraFrameSourceClock, @unchecked Sendable {
    var now: TimeInterval = 0
}

private final class BootstrapMappingFactory:
    CameraFrameSourceMappingFactory,
    @unchecked Sendable
{
    private(set) var requestedURLs: [URL] = []

    func makeMapping(contentsOf url: URL) throws -> any CameraFrameSourceMapping {
        requestedURLs.append(url)
        return BootstrapFrameMapping()
    }
}

private final class BootstrapFrameMapping:
    CameraFrameSourceMapping,
    @unchecked Sendable
{
    func withStableSnapshot<Result>(
        _ body: (
            IdleScreenCameraFrameDescriptor,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) throws -> Result? {
        nil
    }
}
