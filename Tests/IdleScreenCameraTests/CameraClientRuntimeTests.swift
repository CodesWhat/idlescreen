import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Camera client process runtime", .serialized)
struct CameraClientRuntimeTests {
    @Test("only exact release and debug identity tuples are accepted")
    func exactProductTuplesOnly() throws {
        let release = try #require(CameraClientRuntimeConfiguration(
            appGroupIdentifier: CameraClientRuntimeConfiguration.releaseAppGroupIdentifier,
            machServiceName: CameraAgentXPCClientConfiguration.releaseMachServiceName,
            expectedTeamIdentifier: CameraClientRuntimeConfiguration.productionTeamIdentifier
        ))
        let debug = try #require(CameraClientRuntimeConfiguration(
            appGroupIdentifier: CameraClientRuntimeConfiguration.debugAppGroupIdentifier,
            machServiceName: CameraAgentXPCClientConfiguration.debugMachServiceName,
            expectedTeamIdentifier: CameraClientRuntimeConfiguration.productionTeamIdentifier
        ))

        #expect(release.appGroupIdentifier == "group.com.idlescreen.shared")
        #expect(release.machServiceName == "group.com.idlescreen.shared.camera-agent")
        #expect(debug.appGroupIdentifier == "group.com.idlescreen.dev.shared")
        #expect(debug.machServiceName == "group.com.idlescreen.dev.shared.camera-agent")

        for tuple in [
            (
                CameraClientRuntimeConfiguration.releaseAppGroupIdentifier,
                CameraAgentXPCClientConfiguration.debugMachServiceName,
                CameraClientRuntimeConfiguration.productionTeamIdentifier
            ),
            (
                CameraClientRuntimeConfiguration.debugAppGroupIdentifier,
                CameraAgentXPCClientConfiguration.releaseMachServiceName,
                CameraClientRuntimeConfiguration.productionTeamIdentifier
            ),
            (
                CameraClientRuntimeConfiguration.releaseAppGroupIdentifier,
                CameraAgentXPCClientConfiguration.releaseMachServiceName,
                "AAAAAAAAAA"
            ),
            (
                "group.com.idlescreen.other",
                CameraAgentXPCClientConfiguration.releaseMachServiceName,
                CameraClientRuntimeConfiguration.productionTeamIdentifier
            ),
        ] {
            #expect(CameraClientRuntimeConfiguration(
                appGroupIdentifier: tuple.0,
                machServiceName: tuple.1,
                expectedTeamIdentifier: tuple.2
            ) == nil)
        }
    }

    @Test("assembly is inert until the first local consumer attaches")
    func initializationHasNoRemoteSideEffects() throws {
        try withCameraRuntimeHarness { harness in
            let runtime = try #require(harness.makeRuntime())

            #expect(harness.connections.requestedServiceNames.isEmpty)
            #expect(harness.scheduler.pendingJobCount == 0)
            #expect(harness.mappingFactory.requestedURLs.isEmpty)
            #expect(runtime.activeConsumerCount == 0)
            #expect(runtime.frameSource.availability == .unavailable(.leaseUnavailable))
        }
    }

    @Test("multiple local consumers share one production stream connection")
    func consumersShareOneConnection() throws {
        try withCameraRuntimeHarness { harness in
            let runtime = try #require(harness.makeRuntime())

            #expect(runtime.attach(consumerIdentifier: "display-one"))
            #expect(runtime.attach(consumerIdentifier: "display-two"))
            #expect(!runtime.attach(consumerIdentifier: "display-two"))

            #expect(harness.connections.requestedServiceNames == [
                CameraAgentXPCClientConfiguration.releaseMachServiceName
            ])
            #expect(harness.connections.transports.count == 1)
            #expect(harness.remote.beginRequests.count == 1)
            let request = try #require(harness.remote.beginRequests.first)
            #expect(request.maximumWidth == 1_280)
            #expect(request.maximumHeight == 720)
            #expect(request.maximumFramesPerSecond == 30)
            #expect(request.mailboxSlotCount == 3)
            #expect(runtime.activeConsumerCount == 2)

            #expect(runtime.detach(consumerIdentifier: "display-one"))
            #expect(harness.remote.endRequests.isEmpty)
            #expect(runtime.activeConsumerCount == 1)
        }
    }

    @Test("lease availability drives the frame source and final detach tears down")
    func leaseUpdatesDriveFramesAndFinalDetachStops() throws {
        try withCameraRuntimeHarness { harness in
            let runtime = try #require(harness.makeRuntime())
            #expect(runtime.attach(consumerIdentifier: "preview"))
            #expect(runtime.attach(consumerIdentifier: "saver"))

            harness.remote.completeBegin(with: acceptedRuntimeBeginReply())

            #expect(harness.mappingFactory.requestedURLs == [
                harness.containerURL.appendingPathComponent(
                    "camera-frames-v1.mailbox"
                )
            ])
            #expect(runtime.frameSource.availability == .waitingForFrame(epoch: 73))
            #expect(runtime.detach(consumerIdentifier: "preview"))
            #expect(harness.remote.endRequests.isEmpty)

            #expect(runtime.detach(consumerIdentifier: "saver"))
            #expect(runtime.frameSource.availability == .unavailable(.leaseUnavailable))
            #expect(harness.remote.endRequests.map(\.leaseIdentifier) == [
                "lease_runtime-private"
            ])
            #expect(harness.connections.transports[0].invalidationCount == 0)

            harness.remote.completeEnd(with: IdleScreenCameraEndStreamReply(
                accepted: true,
                errorCode: .none,
                errorMessage: nil
            )!)

            #expect(harness.connections.transports[0].invalidationCount == 1)
            harness.scheduler.advance(by: 30)
            #expect(harness.remote.heartbeatRequests.isEmpty)
            #expect(harness.connections.requestedServiceNames.count == 1)
        }
    }

    @Test("a transient mapping creation failure remaps the accepted lease and recovers")
    func transientMappingCreationFailureRecoversWithoutReplacingLease() throws {
        try withCameraRuntimeHarness { harness in
            harness.mappingFactory.failNextRequest()
            harness.mappingFactory.enqueue(RuntimeRecoveringFrameMapping())
            let runtime = try #require(harness.makeRuntime())

            #expect(runtime.attach(consumerIdentifier: "preview"))
            harness.remote.completeBegin(with: acceptedRuntimeBeginReply())

            #expect(runtime.frameSource.availability == .unavailable(.mappingFailure))
            #expect(harness.mappingFactory.requestedURLs.count == 1)
            #expect(harness.remote.beginRequests.count == 1)
            #expect(harness.connections.transports.count == 1)

            harness.clock.now = CameraFrameSource.mappingRecoveryDelay + 0.01
            let recovered = runtime.frameSource.withFrame { frame, pixels in
                #expect(Array(pixels) == [7, 3, 0, 1])
                return frame.sequence
            }

            guard case let .frame(frame, sequence) = recovered else {
                Issue.record("Expected the accepted lease to recover after remapping")
                return
            }
            #expect(frame.streamEpoch == 73)
            #expect(sequence == 1)
            #expect(harness.mappingFactory.requestedURLs.count == 2)
            #expect(harness.remote.beginRequests.count == 1)
            #expect(harness.connections.transports.count == 1)
        }
    }

    @Test("mapping creation recovery makes only one bounded remap attempt")
    func persistentMappingCreationFailureStopsAfterOneRemap() throws {
        try withCameraRuntimeHarness { harness in
            harness.mappingFactory.failNextRequest()
            harness.mappingFactory.failNextRequest()
            let runtime = try #require(harness.makeRuntime())

            #expect(runtime.attach(consumerIdentifier: "preview"))
            harness.remote.completeBegin(with: acceptedRuntimeBeginReply())
            #expect(harness.mappingFactory.requestedURLs.count == 1)

            harness.clock.now = CameraFrameSource.mappingRecoveryDelay - 0.01
            #expect(runtime.frameSource.withFrame { _, _ in () }.unavailableReason
                == .mappingFailure)
            #expect(harness.mappingFactory.requestedURLs.count == 1)

            harness.clock.now = CameraFrameSource.mappingRecoveryDelay + 0.01
            #expect(runtime.frameSource.withFrame { _, _ in () }.unavailableReason
                == .mappingFailure)
            #expect(harness.mappingFactory.requestedURLs.count == 2)

            harness.clock.now = 10
            #expect(runtime.frameSource.withFrame { _, _ in () }.unavailableReason
                == .mappingFailure)
            #expect(harness.mappingFactory.requestedURLs.count == 2)
            #expect(harness.remote.beginRequests.count == 1)
            #expect(harness.connections.transports.count == 1)
        }
    }

    @Test("a transient mapping read failure remaps the accepted lease and recovers")
    func transientMappingReadFailureRecoversWithoutReplacingLease() throws {
        try withCameraRuntimeHarness { harness in
            harness.mappingFactory.enqueue(RuntimeFailingFrameMapping())
            harness.mappingFactory.enqueue(RuntimeRecoveringFrameMapping())
            let runtime = try #require(harness.makeRuntime())

            #expect(runtime.attach(consumerIdentifier: "preview"))
            harness.remote.completeBegin(with: acceptedRuntimeBeginReply())
            #expect(runtime.frameSource.withFrame { _, _ in () }.unavailableReason
                == .mappingFailure)
            #expect(harness.mappingFactory.requestedURLs.count == 1)

            harness.clock.now = CameraFrameSource.mappingRecoveryDelay + 0.01
            guard case let .frame(frame, sequence) = runtime.frameSource.withFrame({
                frame,
                _ in frame.sequence
            }) else {
                Issue.record("Expected recovery after remapping a failed reader")
                return
            }
            #expect(frame.streamEpoch == 73)
            #expect(sequence == 1)
            #expect(harness.mappingFactory.requestedURLs.count == 2)
            #expect(harness.remote.beginRequests.count == 1)
            #expect(harness.connections.transports.count == 1)
        }
    }

    @Test("invalid containers fail before any connection or scheduling")
    func invalidContainersFailClosed() throws {
        let configuration = try #require(CameraClientRuntimeConfiguration(
            appGroupIdentifier: CameraClientRuntimeConfiguration.releaseAppGroupIdentifier,
            machServiceName: CameraAgentXPCClientConfiguration.releaseMachServiceName,
            expectedTeamIdentifier: CameraClientRuntimeConfiguration.productionTeamIdentifier
        ))
        let scheduler = RuntimeTestScheduler()
        let connections = RuntimeConnectionFactory(remote: RuntimeCameraRemote())
        let mappingFactory = RuntimeMappingFactory()
        let clock = RuntimeFrameClock()
        let regularFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idlescreen-runtime-file-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(
            atPath: regularFileURL.path,
            contents: Data()
        ))
        defer { try? FileManager.default.removeItem(at: regularFileURL) }

        for invalidURL in [
            URL(string: "https://example.invalid/group-container")!,
            regularFileURL,
            regularFileURL.appendingPathComponent("missing-container"),
        ] {
            #expect(CameraClientRuntime(
                configuration: configuration,
                appGroupContainerURL: invalidURL,
                scheduler: scheduler,
                connectionFactory: connections.makeConnection,
                frameSourceClock: clock,
                mappingFactory: mappingFactory
            ) == nil)
        }

        #expect(connections.requestedServiceNames.isEmpty)
        #expect(scheduler.pendingJobCount == 0)
        #expect(mappingFactory.requestedURLs.isEmpty)
    }
}

private final class CameraRuntimeHarness {
    let containerURL: URL
    let scheduler = RuntimeTestScheduler()
    let remote = RuntimeCameraRemote()
    let mappingFactory = RuntimeMappingFactory()
    let clock = RuntimeFrameClock()
    let connections: RuntimeConnectionFactory

    init(containerURL: URL) {
        self.containerURL = containerURL
        connections = RuntimeConnectionFactory(remote: remote)
    }

    func makeRuntime() -> CameraClientRuntime? {
        guard let configuration = CameraClientRuntimeConfiguration(
            appGroupIdentifier: CameraClientRuntimeConfiguration.releaseAppGroupIdentifier,
            machServiceName: CameraAgentXPCClientConfiguration.releaseMachServiceName,
            expectedTeamIdentifier: CameraClientRuntimeConfiguration.productionTeamIdentifier
        ) else {
            return nil
        }
        return CameraClientRuntime(
            configuration: configuration,
            appGroupContainerURL: containerURL,
            scheduler: scheduler,
            connectionFactory: connections.makeConnection,
            frameSourceClock: clock,
            mappingFactory: mappingFactory
        )
    }
}

private func withCameraRuntimeHarness<Result>(
    _ body: (CameraRuntimeHarness) throws -> Result
) throws -> Result {
    let containerURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "idlescreen-client-runtime-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: containerURL,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: containerURL) }
    return try body(CameraRuntimeHarness(containerURL: containerURL))
}

private final class RuntimeConnectionFactory: @unchecked Sendable {
    private let remote: RuntimeCameraRemote
    private(set) var requestedServiceNames: [String] = []
    private(set) var transports: [RuntimeXPCTransport] = []

    init(remote: RuntimeCameraRemote) {
        self.remote = remote
    }

    func makeConnection(
        serviceName: String
    ) -> any CameraAgentXPCConnectionTransport {
        requestedServiceNames.append(serviceName)
        let transport = RuntimeXPCTransport(remote: remote)
        transports.append(transport)
        return transport
    }
}

private final class RuntimeXPCTransport:
    CameraAgentXPCConnectionTransport,
    @unchecked Sendable
{
    var remoteObjectInterface: NSXPCInterface?
    var interruptionHandler: (() -> Void)?
    var invalidationHandler: (() -> Void)?
    private let remote: RuntimeCameraRemote
    private(set) var signingRequirements: [String] = []
    private(set) var activationCount = 0
    private(set) var invalidationCount = 0

    init(remote: RuntimeCameraRemote) {
        self.remote = remote
    }

    func setCodeSigningRequirement(_ requirement: String) {
        signingRequirements.append(requirement)
    }

    func activate() {
        activationCount += 1
    }

    func invalidate() {
        invalidationCount += 1
    }

    func remoteCameraProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> (any IdleScreenCameraXPCProtocol)? {
        remote
    }
}

private final class RuntimeCameraRemote:
    NSObject,
    IdleScreenCameraXPCProtocol,
    @unchecked Sendable
{
    private(set) var statusRequests: [IdleScreenCameraStatusRequest] = []
    private(set) var authorizationRequests: [IdleScreenCameraAuthorizationRequest] = []
    private(set) var diagnosticRequests: [IdleScreenCameraDiagnosticRequest] = []
    private(set) var beginRequests: [IdleScreenCameraBeginStreamRequest] = []
    private(set) var heartbeatRequests: [IdleScreenCameraHeartbeatRequest] = []
    private(set) var endRequests: [IdleScreenCameraEndStreamRequest] = []
    private var beginReplies: [(IdleScreenCameraBeginStreamReply) -> Void] = []
    private var endReplies: [(IdleScreenCameraEndStreamReply) -> Void] = []

    func authorizationStatus(
        _ request: IdleScreenCameraStatusRequest,
        withReply reply: @escaping (IdleScreenCameraAuthorizationReply) -> Void
    ) {
        statusRequests.append(request)
    }

    func requestAuthorization(
        _ request: IdleScreenCameraAuthorizationRequest,
        withReply reply: @escaping (IdleScreenCameraAuthorizationReply) -> Void
    ) {
        authorizationRequests.append(request)
    }

    func diagnosticSnapshot(
        _ request: IdleScreenCameraDiagnosticRequest,
        withReply reply: @escaping (IdleScreenCameraDiagnosticSnapshot) -> Void
    ) {
        diagnosticRequests.append(request)
    }

    func cameraDeviceSnapshot(
        _ request: IdleScreenCameraStatusRequest,
        withReply reply: @escaping (IdleScreenCameraDeviceSnapshotReply) -> Void
    ) {
        _ = request
        _ = reply
    }

    func beginStream(
        _ request: IdleScreenCameraBeginStreamRequest,
        withReply reply: @escaping (IdleScreenCameraBeginStreamReply) -> Void
    ) {
        beginRequests.append(request)
        beginReplies.append(reply)
    }

    func heartbeat(
        _ request: IdleScreenCameraHeartbeatRequest,
        withReply reply: @escaping (IdleScreenCameraHeartbeatReply) -> Void
    ) {
        heartbeatRequests.append(request)
    }

    func endStream(
        _ request: IdleScreenCameraEndStreamRequest,
        withReply reply: @escaping (IdleScreenCameraEndStreamReply) -> Void
    ) {
        endRequests.append(request)
        endReplies.append(reply)
    }

    func completeBegin(with reply: IdleScreenCameraBeginStreamReply) {
        beginReplies.removeFirst()(reply)
    }

    func completeEnd(with reply: IdleScreenCameraEndStreamReply) {
        endReplies.removeFirst()(reply)
    }
}

private final class RuntimeTestScheduler:
    CameraLeaseScheduling,
    @unchecked Sendable
{
    private final class Token: CameraLeaseScheduledTask, @unchecked Sendable {
        private(set) var isCancelled = false

        func cancel() {
            isCancelled = true
        }
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

    var pendingJobCount: Int {
        jobs.count { !$0.token.isCancelled }
    }

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
            .min(by: {
                ($0.deadline, $0.serial) < ($1.deadline, $1.serial)
            }) {
            jobs.removeAll { $0.serial == next.serial }
            now = next.deadline
            next.operation()
        }
        now = target
    }
}

private final class RuntimeFrameClock: CameraFrameSourceClock, @unchecked Sendable {
    var now: TimeInterval = 0
}

private final class RuntimeMappingFactory:
    CameraFrameSourceMappingFactory,
    @unchecked Sendable
{
    private enum Result {
        case failure
        case mapping(any CameraFrameSourceMapping)
    }

    private(set) var requestedURLs: [URL] = []
    private var results: [Result] = []

    func failNextRequest() {
        results.append(.failure)
    }

    func enqueue(_ mapping: any CameraFrameSourceMapping) {
        results.append(.mapping(mapping))
    }

    func makeMapping(contentsOf url: URL) throws -> any CameraFrameSourceMapping {
        requestedURLs.append(url)
        guard !results.isEmpty else { return RuntimeFrameMapping() }
        switch results.removeFirst() {
        case .failure:
            throw RuntimeMappingFailure.transient
        case let .mapping(mapping):
            return mapping
        }
    }
}

private enum RuntimeMappingFailure: Error {
    case transient
}

private final class RuntimeFailingFrameMapping:
    CameraFrameSourceMapping,
    @unchecked Sendable
{
    func withStableSnapshot<Result>(
        _ body: (
            IdleScreenCameraFrameDescriptor,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) throws -> Result? {
        _ = body
        throw RuntimeMappingFailure.transient
    }
}

private final class RuntimeRecoveringFrameMapping:
    CameraFrameSourceMapping,
    @unchecked Sendable
{
    func withStableSnapshot<Result>(
        _ body: (
            IdleScreenCameraFrameDescriptor,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) throws -> Result? {
        let descriptor = IdleScreenCameraFrameDescriptor(
            protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
            streamEpoch: 73,
            sequence: 1,
            timestamp: 1,
            width: 1,
            height: 1,
            bytesPerRow: 4,
            pixelFormat: .bgra8Unorm,
            slotIndex: 0,
            slotCount: 3
        )
        return try [UInt8(7), 3, 0, 1].withUnsafeBytes { pixels in
            try body(descriptor, pixels)
        }
    }
}

private final class RuntimeFrameMapping:
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

private func acceptedRuntimeBeginReply() -> IdleScreenCameraBeginStreamReply {
    IdleScreenCameraBeginStreamReply(
        accepted: true,
        errorCode: .none,
        errorMessage: nil,
        leaseIdentifier: "lease_runtime-private",
        producerStreamEpoch: 73,
        transportIdentifier: "camera-frames-v1.mailbox"
    )!
}

private extension CameraFrameSourceRead {
    var unavailableReason: CameraFrameSourceUnavailableReason? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }
}
