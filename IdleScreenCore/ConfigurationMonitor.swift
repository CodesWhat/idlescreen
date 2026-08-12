import Foundation

public struct IdleScreenConfigurationMonitor: Sendable {
    public let store: IdleScreenConfigurationStore
    public let pollingInterval: TimeInterval

    private var lastCheckedAt: TimeInterval?
    private var lastRevision: UInt64?

    public init(
        store: IdleScreenConfigurationStore,
        pollingInterval: TimeInterval = 1
    ) {
        precondition(pollingInterval >= 0)
        self.store = store
        self.pollingInterval = pollingInterval
    }

    public mutating func readChange(at monotonicTime: TimeInterval) throws -> IdleScreenConfiguration? {
        if let lastCheckedAt,
           monotonicTime - lastCheckedAt < pollingInterval {
            return nil
        }
        lastCheckedAt = monotonicTime

        guard let configuration = try store.read(),
              configuration.revision != lastRevision else {
            return nil
        }
        lastRevision = configuration.revision
        return configuration
    }
}
