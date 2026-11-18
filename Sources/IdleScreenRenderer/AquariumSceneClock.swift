import Foundation

/// One scene clock for every aquarium consumer in the process. Each display's
/// saver view used to sample `Date()` on its own callback, so panorama and
/// multi-display views asked for slightly different instants and each built its
/// own world raster. The clock quantizes time to a tick grid and publishes one
/// canonical sample per tick; every consumer that asks during that tick reads
/// the same frame ID and date, so their elapsed times are bit-identical and the
/// shared frame cache renders the world once.
@MainActor
public final class IdleScreenAquariumSceneClock {
  public struct Sample: Equatable, Sendable {
    /// Grid index of the tick. Increases monotonically for one clock.
    public let frameID: UInt64
    /// The tick's canonical instant, not the caller's.
    public let date: Date
  }

  public static let shared = IdleScreenAquariumSceneClock()
  /// Matches the aquarium's 60 fps presentation rate.
  public static let defaultCadence: TimeInterval = 1.0 / 60

  public let cadence: TimeInterval
  private let now: () -> Date
  private var consumers: Set<UUID> = []
  private var current: Sample?
  /// Ticks published so far, for tests and diagnostics.
  public private(set) var publishedCount = 0
  public var consumerCount: Int { consumers.count }

  public init(
    cadence: TimeInterval = IdleScreenAquariumSceneClock.defaultCadence,
    now: @escaping () -> Date = Date.init
  ) {
    self.cadence = cadence.isFinite && cadence > 0 ? cadence : Self.defaultCadence
    self.now = now
  }

  /// Registers a saver consumer. The last one to leave resets the clock so a
  /// later session starts from the wall clock rather than a stale tick.
  public func register() -> UUID {
    let token = UUID()
    consumers.insert(token)
    return token
  }

  public func unregister(_ token: UUID) {
    consumers.remove(token)
    if consumers.isEmpty { current = nil }
  }

  /// The canonical sample for the current tick. The first caller past a tick
  /// boundary publishes it; later callers in the same tick get the same value.
  /// A callback slightly before a boundary reads the previous tick, and the
  /// clock never moves backwards if the system time steps back.
  public func sample() -> Sample {
    let date = now()
    let seconds = date.timeIntervalSinceReferenceDate
    let tick = seconds.isFinite ? max(0, (seconds / cadence).rounded(.down)) : 0
    let frameID = tick < Double(UInt64.max) ? UInt64(tick) : UInt64.max
    if let current, frameID <= current.frameID { return current }
    let published = Sample(
      frameID: frameID, date: Date(timeIntervalSinceReferenceDate: tick * cadence))
    current = published
    publishedCount += 1
    return published
  }

  /// Elapsed scene time for a saved tank at the canonical tick, or `fallback`
  /// when the tank has no epoch to measure from.
  public func elapsed(
    for settings: IdleScreenAquariumRenderSettings?, fallback: TimeInterval
  ) -> TimeInterval {
    settings?.elapsed(at: sample().date) ?? fallback
  }
}
