import Foundation

/// Minimal boundary used by one process-wide coordinator. The real lease
/// controller owns one XPC connection and one agent lease; hosted views only
/// contribute local demand to that single controller.
public protocol CameraProcessLeaseControlling: AnyObject, Sendable {
    func start()
    func stop()
}

extension CameraLeaseController: CameraProcessLeaseControlling {}

/// Reference-counts independently hosted preview or display views inside one
/// client process. The first view starts the one remote lease and the final
/// view ends it. Consumer identifiers are local lifecycle tokens and never
/// cross the XPC boundary.
public final class CameraProcessLeaseCoordinator: @unchecked Sendable {
    public static let maximumConsumerIdentifierUTF8ByteCount = 128

    private let controller: any CameraProcessLeaseControlling
    private let maximumConsumerCount: Int
    private let lock = NSRecursiveLock()
    private var consumerIdentifiers: Set<String> = []

    public init?(
        controller: any CameraProcessLeaseControlling,
        maximumConsumerCount: Int = IdleScreenCameraWire.maximumActiveLeaseCount
    ) {
        guard (1...IdleScreenCameraWire.maximumActiveLeaseCount)
            .contains(maximumConsumerCount) else {
            return nil
        }
        self.controller = controller
        self.maximumConsumerCount = maximumConsumerCount
    }

    deinit {
        if lock.withLock({ !consumerIdentifiers.isEmpty }) {
            controller.stop()
        }
    }

    public var activeConsumerCount: Int {
        lock.withLock { consumerIdentifiers.count }
    }

    @discardableResult
    public func attach(consumerIdentifier: String) -> Bool {
        guard Self.isValidConsumerIdentifier(consumerIdentifier) else {
            return false
        }
        return lock.withLock {
            guard !consumerIdentifiers.contains(consumerIdentifier),
                  consumerIdentifiers.count < maximumConsumerCount else {
                return false
            }
            let shouldStart = consumerIdentifiers.isEmpty
            consumerIdentifiers.insert(consumerIdentifier)
            if shouldStart {
                controller.start()
            }
            return true
        }
    }

    @discardableResult
    public func detach(consumerIdentifier: String) -> Bool {
        lock.withLock {
            guard consumerIdentifiers.remove(consumerIdentifier) != nil else {
                return false
            }
            if consumerIdentifiers.isEmpty {
                controller.stop()
            }
            return true
        }
    }

    private static func isValidConsumerIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumConsumerIdentifierUTF8ByteCount
    }
}
