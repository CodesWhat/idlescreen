import Foundation

/// Panorama consumers share their scene time and snapshot. Keep a small number
/// of owned rasters so different crops don't each rebuild the same world.
@MainActor
final class IdleScreenAquariumFrameCache {
  static let shared = IdleScreenAquariumFrameCache()
  private struct Entry {
    let time: TimeInterval
    let seed: UInt64
    let settings: IdleScreenAquariumRenderSettings?
    let pixels: [SIMD4<Float>]
  }
  private var entries: [Entry] = []
  private(set) var generatedFrameCount = 0
  var cachedFrameCount: Int { entries.count }

  func frame(at time: TimeInterval, seed: UInt64, settings: IdleScreenAquariumRenderSettings?)
    -> [SIMD4<Float>]
  {
    if let index = entries.firstIndex(where: {
      $0.time == time && $0.seed == seed && $0.settings == settings
    }) {
      let entry = entries.remove(at: index)
      entries.append(entry)
      return entry.pixels
    }
    let pixels = IdleScreenAquarium.frame(at: time, seed: seed, settings: settings)
    generatedFrameCount += 1
    entries.append(.init(time: time, seed: seed, settings: settings, pixels: pixels))
    if entries.count > 8 { entries.removeFirst() }
    return pixels
  }

  func clear() { entries = [] }
}
