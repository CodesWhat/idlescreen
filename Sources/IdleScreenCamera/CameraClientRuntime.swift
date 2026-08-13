import Foundation

/// Exact signed product identity accepted by the camera client assembly.
/// Release and Debug use separate App Groups and Mach services, but both are
/// bound to the production signing team used by the shipped products.
public struct CameraClientRuntimeConfiguration: Equatable, Sendable {
    public static let releaseAppGroupIdentifier =
        "group.com.idlescreen.shared"
    public static let debugAppGroupIdentifier =
        "group.com.idlescreen.dev.shared"
    public static let productionTeamIdentifier = "3524374A2S"

    public let appGroupIdentifier: String
    public let machServiceName: String
    public let expectedTeamIdentifier: String

    let xpcClientConfiguration: CameraAgentXPCClientConfiguration

    public init?(
        appGroupIdentifier: String,
        machServiceName: String,
        expectedTeamIdentifier: String
    ) {
        let expectedMachServiceName: String
        switch appGroupIdentifier {
        case Self.releaseAppGroupIdentifier:
            expectedMachServiceName =
                CameraAgentXPCClientConfiguration.releaseMachServiceName
        case Self.debugAppGroupIdentifier:
            expectedMachServiceName =
                CameraAgentXPCClientConfiguration.debugMachServiceName
        default:
            return nil
        }
        guard machServiceName == expectedMachServiceName,
              expectedTeamIdentifier == Self.productionTeamIdentifier,
              let xpcClientConfiguration = CameraAgentXPCClientConfiguration(
                machServiceName: machServiceName,
                expectedTeamIdentifier: expectedTeamIdentifier
              ) else {
            return nil
        }

        self.appGroupIdentifier = appGroupIdentifier
        self.machServiceName = machServiceName
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.xpcClientConfiguration = xpcClientConfiguration
    }
}

/// One process-wide camera client graph. Construction is inert: the first
/// local consumer starts the one XPC-backed lease, and the final consumer ends
/// it. Lease availability is fed directly into the retained frame source.
public final class CameraClientRuntime: @unchecked Sendable {
    public static let productionMaximumWidth = 1_280
    public static let productionMaximumHeight = 720
    public static let productionMaximumFramesPerSecond = 30
    public static let productionMailboxSlotCount = 3

    public let configuration: CameraClientRuntimeConfiguration
    public let frameSource: CameraFrameSource

    private let xpcClient: CameraAgentXPCClient
    private let leaseController: CameraLeaseController
    private let processLeaseCoordinator: CameraProcessLeaseCoordinator

    public convenience init?(
        configuration: CameraClientRuntimeConfiguration,
        appGroupContainerURL: URL,
        scheduler: any CameraLeaseScheduling = CameraLeaseDispatchScheduler()
    ) {
        self.init(
            configuration: configuration,
            appGroupContainerURL: appGroupContainerURL,
            scheduler: scheduler,
            connectionFactory: { machServiceName in
                NSXPCConnection(machServiceName: machServiceName, options: [])
            },
            frameSourceClock: CameraFrameSourceMonotonicClock(),
            mappingFactory: IdleScreenCameraFrameSourceMappingFactory()
        )
    }

    init?(
        configuration: CameraClientRuntimeConfiguration,
        appGroupContainerURL: URL,
        scheduler: any CameraLeaseScheduling,
        connectionFactory: @escaping
            @Sendable (String) -> any CameraAgentXPCConnectionTransport,
        frameSourceClock: any CameraFrameSourceClock,
        mappingFactory: any CameraFrameSourceMappingFactory
    ) {
        guard let validatedContainerURL = Self.validatedContainerURL(
            appGroupContainerURL
        ),
              let leaseConfiguration = CameraLeaseControllerConfiguration(
                maximumWidth: Self.productionMaximumWidth,
                maximumHeight: Self.productionMaximumHeight,
                maximumFramesPerSecond:
                    Self.productionMaximumFramesPerSecond,
                mailboxSlotCount: Self.productionMailboxSlotCount,
                leasePolicy: .production
              ) else {
            return nil
        }

        let frameSource: CameraFrameSource
        do {
            frameSource = try CameraFrameSource(
                appGroupContainerURL: validatedContainerURL,
                clock: frameSourceClock,
                mappingFactory: mappingFactory
            )
        } catch {
            return nil
        }

        let xpcClient = CameraAgentXPCClient(
            configuration: configuration.xpcClientConfiguration,
            connectionFactory: connectionFactory
        )
        let leaseController = CameraLeaseController(
            client: xpcClient,
            scheduler: scheduler,
            configuration: leaseConfiguration,
            updateHandler: { [weak frameSource] update in
                frameSource?.receive(update)
            }
        )
        guard let processLeaseCoordinator = CameraProcessLeaseCoordinator(
            controller: leaseController
        ) else {
            return nil
        }

        self.configuration = configuration
        self.frameSource = frameSource
        self.xpcClient = xpcClient
        self.leaseController = leaseController
        self.processLeaseCoordinator = processLeaseCoordinator
    }

    public var activeConsumerCount: Int {
        processLeaseCoordinator.activeConsumerCount
    }

    @discardableResult
    public func attach(consumerIdentifier: String) -> Bool {
        processLeaseCoordinator.attach(
            consumerIdentifier: consumerIdentifier
        )
    }

    @discardableResult
    public func detach(consumerIdentifier: String) -> Bool {
        processLeaseCoordinator.detach(
            consumerIdentifier: consumerIdentifier
        )
    }

    private static func validatedContainerURL(_ candidate: URL) -> URL? {
        guard candidate.isFileURL else { return nil }
        let standardized = candidate.standardizedFileURL
        guard let values = try? standardized.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return nil
        }
        return standardized
    }
}
