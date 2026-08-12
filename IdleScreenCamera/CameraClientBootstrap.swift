import Foundation

public extension CameraClientRuntimeConfiguration {
    /// Canonical Info.plist keys shared by every camera client process.
    static let appGroupInfoKey =
        "IdleScreenCameraAgentAppGroupIdentifier"
    static let machServiceInfoKey =
        "IdleScreenCameraAgentMachServiceName"
    static let teamIdentifierInfoKey =
        "IdleScreenCameraAgentTeamIdentifier"
}

/// Stable, non-sensitive outcomes suitable for diagnostics and UI state.
/// Deliberately carries no identifiers, filesystem paths, or underlying errors.
public enum CameraClientBootstrapStatus:
    String,
    CaseIterable,
    Equatable,
    Sendable
{
    case ready
    case missingConfiguration
    case invalidConfiguration
    case appGroupContainerUnavailable
}

public struct CameraClientBootstrapResult: Sendable {
    public let status: CameraClientBootstrapStatus
    public let runtime: CameraClientRuntime?

    fileprivate init(
        status: CameraClientBootstrapStatus,
        runtime: CameraClientRuntime? = nil
    ) {
        self.status = status
        self.runtime = runtime
    }
}

public protocol CameraClientAppGroupContainerLocating: Sendable {
    func containerURL(
        forSecurityApplicationGroupIdentifier identifier: String
    ) -> URL?
}

public struct CameraClientFileManagerContainerLocator:
    CameraClientAppGroupContainerLocating,
    Sendable
{
    public init() {}

    public func containerURL(
        forSecurityApplicationGroupIdentifier identifier: String
    ) -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        )
    }
}

/// Shared fail-closed boundary used by both the companion and saver processes.
/// A successful bootstrap only assembles the graph; it does not connect,
/// schedule lease work, map the mailbox, or access the camera before `attach`.
public enum CameraClientBootstrap {
    public static let appGroupInfoKey =
        CameraClientRuntimeConfiguration.appGroupInfoKey
    public static let machServiceInfoKey =
        CameraClientRuntimeConfiguration.machServiceInfoKey
    public static let teamIdentifierInfoKey =
        CameraClientRuntimeConfiguration.teamIdentifierInfoKey

    public static func makeRuntime(
        infoDictionary: [String: Any],
        containerLocator: any CameraClientAppGroupContainerLocating =
            CameraClientFileManagerContainerLocator(),
        scheduler: any CameraLeaseScheduling = CameraLeaseDispatchScheduler()
    ) -> CameraClientBootstrapResult {
        makeRuntime(
            infoDictionary: infoDictionary,
            containerLocator: containerLocator,
            scheduler: scheduler,
            connectionFactory: { machServiceName in
                NSXPCConnection(machServiceName: machServiceName, options: [])
            },
            frameSourceClock: CameraFrameSourceMonotonicClock(),
            mappingFactory: IdleScreenCameraFrameSourceMappingFactory()
        )
    }

    static func makeRuntime(
        infoDictionary: [String: Any],
        containerLocator: any CameraClientAppGroupContainerLocating,
        scheduler: any CameraLeaseScheduling,
        connectionFactory: @escaping
            @Sendable (String) -> any CameraAgentXPCConnectionTransport,
        frameSourceClock: any CameraFrameSourceClock,
        mappingFactory: any CameraFrameSourceMappingFactory
    ) -> CameraClientBootstrapResult {
        guard infoDictionary[appGroupInfoKey] != nil,
              infoDictionary[machServiceInfoKey] != nil,
              infoDictionary[teamIdentifierInfoKey] != nil else {
            return CameraClientBootstrapResult(status: .missingConfiguration)
        }
        guard let appGroupIdentifier =
                infoDictionary[appGroupInfoKey] as? String,
              let machServiceName =
                infoDictionary[machServiceInfoKey] as? String,
              let expectedTeamIdentifier =
                infoDictionary[teamIdentifierInfoKey] as? String,
              let configuration = CameraClientRuntimeConfiguration(
                appGroupIdentifier: appGroupIdentifier,
                machServiceName: machServiceName,
                expectedTeamIdentifier: expectedTeamIdentifier
              ) else {
            return CameraClientBootstrapResult(status: .invalidConfiguration)
        }
        guard let containerURL = containerLocator.containerURL(
            forSecurityApplicationGroupIdentifier:
                configuration.appGroupIdentifier
        ),
              let runtime = CameraClientRuntime(
                configuration: configuration,
                appGroupContainerURL: containerURL,
                scheduler: scheduler,
                connectionFactory: connectionFactory,
                frameSourceClock: frameSourceClock,
                mappingFactory: mappingFactory
              ) else {
            return CameraClientBootstrapResult(
                status: .appGroupContainerUnavailable
            )
        }

        return CameraClientBootstrapResult(
            status: .ready,
            runtime: runtime
        )
    }
}
