import Darwin
import Foundation

/// A monotonic lease clock that advances while the machine sleeps.
///
/// Lease timestamps remain `Date` values so deterministic callers can inject
/// exact instants, but production time is derived from `mach_continuous_time`.
/// Wall-clock changes therefore cannot extend a camera lease, and a lease that
/// expires during sleep is already expired when the agent wakes.
public struct CameraLeaseContinuousClock: Sendable {
    private let origin: Date
    private let originTicks: UInt64
    private let secondsPerTick: Double

    public init(origin: Date = Date()) {
        var timebase = mach_timebase_info_data_t()
        let result = mach_timebase_info(&timebase)
        precondition(result == KERN_SUCCESS && timebase.denom != 0)

        self.origin = origin
        originTicks = mach_continuous_time()
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    public var now: Date {
        let ticks = mach_continuous_time()
        guard ticks >= originTicks else { return origin }
        let elapsed = Double(ticks - originTicks) * secondsPerTick
        guard elapsed.isFinite else { return origin }
        return origin.addingTimeInterval(elapsed)
    }
}

public enum CameraDesiredCaptureState: Equatable, Sendable {
    case stopped
    case running
}

public struct CameraLeaseCoordinator: Sendable {
    public private(set) var desiredCaptureState: CameraDesiredCaptureState = .stopped
    public private(set) var streamEpoch: UInt64 = 0

    private var leasesByConnection: [String: [String: Date]] = [:]
    private var nextStreamEpoch: UInt64?

    public init() {
        nextStreamEpoch = 1
    }

    public init?(streamEpochSeed: UInt64) {
        guard streamEpochSeed > 0 else { return nil }
        nextStreamEpoch = streamEpochSeed
    }

    public var activeLeaseCount: Int {
        leasesByConnection.values.reduce(0) { $0 + $1.count }
    }

    public func activeLeaseCount(for connection: String) -> Int {
        leasesByConnection[connection]?.count ?? 0
    }

    /// The epoch an accepted lease would use without mutating coordinator state.
    /// Active peers share the current producer epoch; an idle coordinator
    /// advertises its next process-seeded epoch, or `nil` after exhaustion.
    public var streamEpochForNextLease: UInt64? {
        activeLeaseCount > 0 ? streamEpoch : nextStreamEpoch
    }

    @discardableResult
    public mutating func acquireLease(
        connection: String,
        lease: String,
        now: Date,
        ttl: TimeInterval
    ) -> Bool {
        guard !connection.isEmpty,
              !lease.isEmpty,
              now.timeIntervalSinceReferenceDate.isFinite,
              ttl.isFinite,
              ttl > 0 else {
            return false
        }
        let expiration = now.addingTimeInterval(ttl)
        guard expiration.timeIntervalSinceReferenceDate.isFinite else { return false }
        expireLeases(now: now)

        guard activeLeaseCount > 0 || nextStreamEpoch != nil else {
            return false
        }

        let inserted = leasesByConnection[connection]?[lease] == nil
        leasesByConnection[connection, default: [:]][lease] = expiration
        synchronizeDesiredCaptureState()
        return inserted
    }

    @discardableResult
    public mutating func releaseLease(connection: String, lease: String, now: Date) -> Bool {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return false }
        expireLeases(now: now)

        guard leasesByConnection[connection]?.removeValue(forKey: lease) != nil else {
            return false
        }
        removeConnectionIfEmpty(connection)
        synchronizeDesiredCaptureState()
        return true
    }

    @discardableResult
    public mutating func heartbeat(
        connection: String,
        lease: String,
        now: Date,
        ttl: TimeInterval
    ) -> Bool {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              ttl.isFinite,
              ttl > 0 else {
            return false
        }
        let expiration = now.addingTimeInterval(ttl)
        guard expiration.timeIntervalSinceReferenceDate.isFinite else { return false }
        expireLeases(now: now)

        guard leasesByConnection[connection]?[lease] != nil else {
            return false
        }
        leasesByConnection[connection]?[lease] = expiration
        return true
    }

    @discardableResult
    public mutating func invalidateConnection(_ connection: String, now: Date) -> Int {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return 0 }
        expireLeases(now: now)

        let reclaimedLeaseCount = leasesByConnection.removeValue(forKey: connection)?.count ?? 0
        synchronizeDesiredCaptureState()
        return reclaimedLeaseCount
    }

    @discardableResult
    public mutating func expireLeases(now: Date) -> Int {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return 0 }
        let leaseCountBeforeExpiration = activeLeaseCount

        for connection in Array(leasesByConnection.keys) {
            leasesByConnection[connection] = leasesByConnection[connection]?.filter {
                $0.value > now
            }
            removeConnectionIfEmpty(connection)
        }

        synchronizeDesiredCaptureState()
        return leaseCountBeforeExpiration - activeLeaseCount
    }

    private mutating func removeConnectionIfEmpty(_ connection: String) {
        if leasesByConnection[connection]?.isEmpty == true {
            leasesByConnection.removeValue(forKey: connection)
        }
    }

    private mutating func synchronizeDesiredCaptureState() {
        let nextState: CameraDesiredCaptureState = activeLeaseCount == 0 ? .stopped : .running
        if desiredCaptureState == .stopped, nextState == .running {
            guard let nextStreamEpoch else { return }
            streamEpoch = nextStreamEpoch
            self.nextStreamEpoch = nextStreamEpoch == .max
                ? nil
                : nextStreamEpoch + 1
        }
        desiredCaptureState = nextState
    }
}
