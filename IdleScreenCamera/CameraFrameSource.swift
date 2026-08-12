import Darwin
import Foundation

public protocol CameraFrameSourceClock: Sendable {
    var now: TimeInterval { get }
}

public struct CameraFrameSourceMonotonicClock: CameraFrameSourceClock, Sendable {
    public init() {}

    public var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

/// A scoped view of a bounded mailbox snapshot. Pixel bytes are valid only
/// while `body` is executing and must never be retained by an implementation.
public protocol CameraFrameSourceMapping: AnyObject {
    func withStableSnapshot<Result>(
        _ body: (
            IdleScreenCameraFrameDescriptor,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) throws -> Result?
}

extension IdleScreenCameraFrameMailboxMapping: CameraFrameSourceMapping {}

public protocol CameraFrameSourceMappingFactory: Sendable {
    func makeMapping(contentsOf url: URL) throws -> any CameraFrameSourceMapping
}

/// Production mapping factory. The mapping itself enforces O_NOFOLLOW, exact
/// file size, regular-file ownership/mode checks, and a bounded seqlock budget.
public struct IdleScreenCameraFrameSourceMappingFactory:
    CameraFrameSourceMappingFactory,
    Sendable
{
    public let layout: IdleScreenCameraFrameMailboxLayout
    public let snapshotAttemptLimit: Int
    public let expectedOwnerUserID: uid_t

    public init(
        layout: IdleScreenCameraFrameMailboxLayout = .current,
        snapshotAttemptLimit: Int = 3,
        expectedOwnerUserID: uid_t = geteuid()
    ) {
        self.layout = layout
        self.snapshotAttemptLimit = snapshotAttemptLimit
        self.expectedOwnerUserID = expectedOwnerUserID
    }

    public func makeMapping(
        contentsOf url: URL
    ) throws -> any CameraFrameSourceMapping {
        let mappedByteCount = try layout.expectedFileByteCount()
        return try IdleScreenCameraFrameMailboxMapping(
            contentsOf: url,
            generationLoader: IdleScreenCameraAtomicGenerationLoader(
                mappedByteCount: mappedByteCount
            ),
            layout: layout,
            snapshotAttemptLimit: snapshotAttemptLimit,
            expectedOwnerUserID: expectedOwnerUserID
        )
    }
}

public enum CameraFrameSourceConfigurationError: Swift.Error, Equatable, Sendable {
    case invalidAppGroupContainerURL
    case invalidMaximumFrameAge(TimeInterval)
    case invalidMaximumFirstFrameWait(TimeInterval)
}

public enum CameraFrameSourceUnavailableReason: Equatable, Sendable {
    case leaseUnavailable
    case invalidTransportIdentifier
    case regressiveProducerEpoch(previous: UInt64, proposed: UInt64)
    case mappingFailure
    case invalidFrameDescriptor
    case wrongProducerEpoch(expected: UInt64, actual: UInt64)
    case outOfOrderSequence(last: UInt64, candidate: UInt64)
    case firstFrameTimedOut(epoch: UInt64)
    case staleFrame(epoch: UInt64, sequence: UInt64)
    case invalidMonotonicClock
}

public enum CameraFrameSourceAvailability: Equatable, Sendable {
    case unavailable(CameraFrameSourceUnavailableReason)
    case waitingForFrame(epoch: UInt64)
    case available(epoch: UInt64, sequence: UInt64)
}

public enum CameraFrameSourceRead<Result> {
    case frame(IdleScreenCameraFrameDescriptor, Result)
    case noNewFrame
    case unavailable(CameraFrameSourceUnavailableReason)
}

extension CameraFrameSourceRead: Equatable where Result: Equatable {}

/// Consumes lease-controller availability and exposes only validated, current
/// mailbox frames. The source stores descriptors and local arrival times, never
/// pixel bytes; consumers receive pixels only in `withFrame`'s scoped callback.
public final class CameraFrameSource: @unchecked Sendable {
    public static let defaultMaximumFrameAge: TimeInterval = 1
    public static let defaultMaximumFirstFrameWait: TimeInterval = 1
    public static let maximumPermittedFrameAge: TimeInterval = 10
    static let mappingRecoveryDelay: TimeInterval = 0.1
    static let maximumMappingRecoveryAttemptCount = 1

    private struct ActiveMapping {
        let generation: UInt64
        let producerStreamEpoch: UInt64
        let mapping: any CameraFrameSourceMapping
    }

    private struct MappingRequest {
        let generation: UInt64
        let descriptor: CameraAgentStreamDescriptor
        let mailboxURL: URL
    }

    private let appGroupContainerURL: URL
    private let clock: any CameraFrameSourceClock
    private let mappingFactory: any CameraFrameSourceMappingFactory
    private let maximumFrameAge: TimeInterval
    private let maximumFirstFrameWait: TimeInterval
    private let lock = NSLock()

    private var mappingGeneration: UInt64 = 0
    private var activeMapping: ActiveMapping?
    private var currentAvailability: CameraFrameSourceAvailability =
        .unavailable(.leaseUnavailable)
    private var highestAdvertisedEpoch: UInt64 = 0
    private var lastAcceptedEpoch: UInt64?
    private var lastAcceptedSequence: UInt64?
    private var lastFrameArrivalTime: TimeInterval?
    private var mappingReadyTime: TimeInterval?
    private var lastClockObservation: TimeInterval?
    private var recoverableStreamDescriptor: CameraAgentStreamDescriptor?
    private var mappingRecoveryAttemptCount = 0
    private var nextMappingRecoveryTime: TimeInterval?

    public convenience init(
        appGroupContainerURL: URL,
        clock: any CameraFrameSourceClock = CameraFrameSourceMonotonicClock(),
        maximumFrameAge: TimeInterval = CameraFrameSource.defaultMaximumFrameAge,
        maximumFirstFrameWait: TimeInterval =
            CameraFrameSource.defaultMaximumFirstFrameWait
    ) throws {
        try self.init(
            appGroupContainerURL: appGroupContainerURL,
            clock: clock,
            mappingFactory: IdleScreenCameraFrameSourceMappingFactory(),
            maximumFrameAge: maximumFrameAge,
            maximumFirstFrameWait: maximumFirstFrameWait
        )
    }

    public init(
        appGroupContainerURL: URL,
        clock: any CameraFrameSourceClock,
        mappingFactory: any CameraFrameSourceMappingFactory,
        maximumFrameAge: TimeInterval = CameraFrameSource.defaultMaximumFrameAge,
        maximumFirstFrameWait: TimeInterval =
            CameraFrameSource.defaultMaximumFirstFrameWait
    ) throws {
        guard appGroupContainerURL.isFileURL else {
            throw CameraFrameSourceConfigurationError.invalidAppGroupContainerURL
        }
        guard maximumFrameAge.isFinite,
              maximumFrameAge > 0,
              maximumFrameAge <= Self.maximumPermittedFrameAge else {
            throw CameraFrameSourceConfigurationError
                .invalidMaximumFrameAge(maximumFrameAge)
        }
        guard maximumFirstFrameWait.isFinite,
              maximumFirstFrameWait > 0,
              maximumFirstFrameWait <= Self.maximumPermittedFrameAge else {
            throw CameraFrameSourceConfigurationError
                .invalidMaximumFirstFrameWait(maximumFirstFrameWait)
        }
        self.appGroupContainerURL = appGroupContainerURL.standardizedFileURL
        self.clock = clock
        self.mappingFactory = mappingFactory
        self.maximumFrameAge = maximumFrameAge
        self.maximumFirstFrameWait = maximumFirstFrameWait
    }

    public var availability: CameraFrameSourceAvailability {
        lock.withLock { currentAvailability }
    }

    public func receive(_ update: CameraLeaseControllerUpdate) {
        switch update {
        case .unavailable:
            lock.withLock {
                fenceAndRetireLocked(reason: .leaseUnavailable)
                highestAdvertisedEpoch = 0
                lastAcceptedEpoch = nil
                lastAcceptedSequence = nil
                lastFrameArrivalTime = nil
                mappingReadyTime = nil
            }

        case let .available(descriptor):
            receiveAvailable(descriptor)
        }
    }

    public func withFrame<Result>(
        _ body: (
            IdleScreenCameraFrameDescriptor,
            UnsafeRawBufferPointer
        ) -> Result
    ) -> CameraFrameSourceRead<Result> {
        recoverMappingForReadIfEligible()

        let snapshot: ActiveMapping?
        let unavailableReason: CameraFrameSourceUnavailableReason?
        lock.lock()
        snapshot = activeMapping
        if case let .unavailable(reason) = currentAvailability {
            unavailableReason = reason
        } else {
            unavailableReason = nil
        }
        lock.unlock()

        guard let snapshot else {
            return .unavailable(unavailableReason ?? .leaseUnavailable)
        }

        do {
            let result = try snapshot.mapping.withStableSnapshot { descriptor, pixels in
                guard (try? descriptor.validated()) != nil else {
                    let failure: CameraFrameSourceRead<Result> = self.failCurrent(
                        generation: snapshot.generation,
                        reason: .invalidFrameDescriptor
                    )
                    return failure
                }
                return self.consumeStableFrame(
                    descriptor,
                    pixels: pixels,
                    snapshot: snapshot,
                    body: body
                )
            }
            guard let result else {
                return handleNoStableSnapshot(snapshot: snapshot)
            }
            return result
        } catch {
            return failCurrent(
                generation: snapshot.generation,
                reason: .mappingFailure
            )
        }
    }

    private func receiveAvailable(_ descriptor: CameraAgentStreamDescriptor) {
        guard descriptor.producerStreamEpoch > 0,
              let mailboxURL = resolvedMailboxURL(
                transportIdentifier: descriptor.transportIdentifier
              ) else {
            lock.withLock {
                fenceAndRetireLocked(reason: .invalidTransportIdentifier)
            }
            return
        }

        let requestedGeneration: UInt64? = lock.withLock {
            guard descriptor.producerStreamEpoch >= highestAdvertisedEpoch else {
                fenceAndRetireLocked(reason: .regressiveProducerEpoch(
                    previous: highestAdvertisedEpoch,
                    proposed: descriptor.producerStreamEpoch
                ))
                return nil
            }
            if descriptor.producerStreamEpoch > highestAdvertisedEpoch {
                highestAdvertisedEpoch = descriptor.producerStreamEpoch
                lastAcceptedEpoch = nil
                lastAcceptedSequence = nil
                lastFrameArrivalTime = nil
            }
            recoverableStreamDescriptor = descriptor
            mappingRecoveryAttemptCount = 0
            nextMappingRecoveryTime = nil
            mappingGeneration = nextGeneration(after: mappingGeneration)
            activeMapping = nil
            currentAvailability = .waitingForFrame(
                epoch: descriptor.producerStreamEpoch
            )
            return mappingGeneration
        }
        guard let requestedGeneration else { return }

        createAndInstallMapping(MappingRequest(
            generation: requestedGeneration,
            descriptor: descriptor,
            mailboxURL: mailboxURL
        ))
    }

    private func recoverMappingForReadIfEligible() {
        let request: MappingRequest? = lock.withLock {
            guard case .unavailable(.mappingFailure) = currentAvailability,
                  let descriptor = recoverableStreamDescriptor,
                  mappingRecoveryAttemptCount < Self.maximumMappingRecoveryAttemptCount,
                  let nextMappingRecoveryTime else {
                return nil
            }
            let now = clock.now
            guard now.isFinite,
                  now >= 0,
                  now >= nextMappingRecoveryTime,
                  let mailboxURL = resolvedMailboxURL(
                      transportIdentifier: descriptor.transportIdentifier
                  ) else {
                return nil
            }

            mappingRecoveryAttemptCount += 1
            mappingGeneration = nextGeneration(after: mappingGeneration)
            activeMapping = nil
            mappingReadyTime = nil
            currentAvailability = .waitingForFrame(
                epoch: descriptor.producerStreamEpoch
            )
            self.nextMappingRecoveryTime = nil
            return MappingRequest(
                generation: mappingGeneration,
                descriptor: descriptor,
                mailboxURL: mailboxURL
            )
        }
        guard let request else { return }
        createAndInstallMapping(request)
    }

    private func createAndInstallMapping(_ request: MappingRequest) {
        let mapping: any CameraFrameSourceMapping
        do {
            mapping = try mappingFactory.makeMapping(contentsOf: request.mailboxURL)
        } catch {
            _ = failCurrentCreation(generation: request.generation)
            return
        }

        lock.withLock {
            guard mappingGeneration == request.generation,
                  case let .waitingForFrame(epoch) = currentAvailability,
                  epoch == request.descriptor.producerStreamEpoch else {
                return
            }
            activeMapping = ActiveMapping(
                generation: request.generation,
                producerStreamEpoch: request.descriptor.producerStreamEpoch,
                mapping: mapping
            )
            mappingReadyTime = clock.now
        }
    }

    private func consumeStableFrame<Result>(
        _ descriptor: IdleScreenCameraFrameDescriptor,
        pixels: UnsafeRawBufferPointer,
        snapshot: ActiveMapping,
        body: (
            IdleScreenCameraFrameDescriptor,
            UnsafeRawBufferPointer
        ) -> Result
    ) -> CameraFrameSourceRead<Result> {
        lock.lock()
        defer { lock.unlock() }

        guard activeMapping?.generation == snapshot.generation,
              mappingGeneration == snapshot.generation else {
            return .noNewFrame
        }
        guard descriptor.streamEpoch == snapshot.producerStreamEpoch else {
            return failCurrentLocked(reason: .wrongProducerEpoch(
                expected: snapshot.producerStreamEpoch,
                actual: descriptor.streamEpoch
            ))
        }

        let now = clock.now
        guard now.isFinite,
              now >= 0,
              lastClockObservation.map({ now >= $0 }) ?? true else {
            currentAvailability = .unavailable(.invalidMonotonicClock)
            return .unavailable(.invalidMonotonicClock)
        }
        lastClockObservation = now

        if lastAcceptedEpoch == descriptor.streamEpoch,
           let lastAcceptedSequence {
            if descriptor.sequence < lastAcceptedSequence {
                return failCurrentLocked(reason: .outOfOrderSequence(
                    last: lastAcceptedSequence,
                    candidate: descriptor.sequence
                ))
            }
            if descriptor.sequence == lastAcceptedSequence {
                guard let lastFrameArrivalTime,
                      now - lastFrameArrivalTime <= maximumFrameAge else {
                    let reason = CameraFrameSourceUnavailableReason.staleFrame(
                        epoch: descriptor.streamEpoch,
                        sequence: descriptor.sequence
                    )
                    currentAvailability = .unavailable(reason)
                    return .unavailable(reason)
                }
                return .noNewFrame
            }
        }

        lastAcceptedEpoch = descriptor.streamEpoch
        lastAcceptedSequence = descriptor.sequence
        lastFrameArrivalTime = now
        currentAvailability = .available(
            epoch: descriptor.streamEpoch,
            sequence: descriptor.sequence
        )

        // The lock fences replacements until the callback finishes, so an old
        // mapping can never expose pixels after a newer generation is installed.
        return .frame(descriptor, body(descriptor, pixels))
    }

    private func handleNoStableSnapshot<Result>(
        snapshot: ActiveMapping
    ) -> CameraFrameSourceRead<Result> {
        lock.withLock {
            guard activeMapping?.generation == snapshot.generation,
                  mappingGeneration == snapshot.generation else {
                return .noNewFrame
            }
            let now = clock.now
            guard now.isFinite,
                  now >= 0,
                  lastClockObservation.map({ now >= $0 }) ?? true else {
                currentAvailability = .unavailable(.invalidMonotonicClock)
                return .unavailable(.invalidMonotonicClock)
            }
            lastClockObservation = now

            if lastAcceptedEpoch == snapshot.producerStreamEpoch,
               let lastAcceptedSequence,
               let lastFrameArrivalTime {
                guard now - lastFrameArrivalTime <= maximumFrameAge else {
                    let reason = CameraFrameSourceUnavailableReason.staleFrame(
                        epoch: snapshot.producerStreamEpoch,
                        sequence: lastAcceptedSequence
                    )
                    currentAvailability = .unavailable(reason)
                    return .unavailable(reason)
                }
                // The first-frame deadline no longer applies after this
                // mapping has delivered a valid frame. A bounded seqlock miss
                // during an otherwise fresh stream means the producer won the
                // current read race; retain the accepted frame and try again.
                return .noNewFrame
            }

            guard let mappingReadyTime,
                  now - mappingReadyTime <= maximumFirstFrameWait else {
                let reason = CameraFrameSourceUnavailableReason.firstFrameTimedOut(
                    epoch: snapshot.producerStreamEpoch
                )
                currentAvailability = .unavailable(reason)
                return .unavailable(reason)
            }
            return .noNewFrame
        }
    }

    private func failCurrent<Result>(
        generation: UInt64,
        reason: CameraFrameSourceUnavailableReason
    ) -> CameraFrameSourceRead<Result> {
        lock.withLock {
            guard activeMapping?.generation == generation,
                  mappingGeneration == generation else {
                return .noNewFrame
            }
            return failCurrentLocked(reason: reason)
        }
    }

    private func failCurrentLocked<Result>(
        reason: CameraFrameSourceUnavailableReason
    ) -> CameraFrameSourceRead<Result> {
        fenceAndRetireLocked(reason: reason)
        if reason == .mappingFailure {
            scheduleMappingRecoveryLocked()
        }
        return .unavailable(reason)
    }

    private func failCurrentCreation(generation: UInt64) -> Bool {
        lock.withLock {
            guard mappingGeneration == generation else { return false }
            mappingGeneration = nextGeneration(after: mappingGeneration)
            activeMapping = nil
            mappingReadyTime = nil
            currentAvailability = .unavailable(.mappingFailure)
            scheduleMappingRecoveryLocked()
            return true
        }
    }

    private func fenceAndRetireLocked(reason: CameraFrameSourceUnavailableReason) {
        mappingGeneration = nextGeneration(after: mappingGeneration)
        activeMapping = nil
        mappingReadyTime = nil
        currentAvailability = .unavailable(reason)
        if reason != .mappingFailure {
            recoverableStreamDescriptor = nil
            mappingRecoveryAttemptCount = 0
            nextMappingRecoveryTime = nil
        }
    }

    private func scheduleMappingRecoveryLocked() {
        let now = clock.now
        let recoveryTime = now + Self.mappingRecoveryDelay
        guard now.isFinite,
              now >= 0,
              recoveryTime.isFinite else {
            nextMappingRecoveryTime = nil
            return
        }
        nextMappingRecoveryTime = recoveryTime
    }

    private func resolvedMailboxURL(transportIdentifier: String) -> URL? {
        guard !transportIdentifier.isEmpty,
              transportIdentifier.utf8.count
                <= IdleScreenCameraWire.maximumTransportIdentifierUTF8ByteCount,
              transportIdentifier != ".",
              transportIdentifier != "..",
              !transportIdentifier.contains("/"),
              !transportIdentifier.contains("\\"),
              !transportIdentifier.contains("\0") else {
            return nil
        }
        let mailboxURL = appGroupContainerURL.appendingPathComponent(
            transportIdentifier,
            isDirectory: false
        ).standardizedFileURL
        guard mailboxURL.deletingLastPathComponent() == appGroupContainerURL else {
            return nil
        }
        return mailboxURL
    }

    private func nextGeneration(after current: UInt64) -> UInt64 {
        current == UInt64.max ? 1 : current + 1
    }
}
