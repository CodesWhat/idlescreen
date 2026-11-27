import Foundation

/// Scene data that outlives a single timestamp: the water and substrate base
/// and the navigation geometry. Each piece is keyed by exactly the settings it
/// reads, so animating time or editing unrelated settings never rebuilds it.
final class IdleScreenAquariumScenePreparation {
  struct NavigationKey: Equatable {
    let worldWidth: Int
    let seed: UInt64
    let substrateDepth: Double
    let objects: [IdleScreenAquariumRenderObject]
    let school: [UInt64]
  }
  struct BaseKey: Equatable {
    let width: Int
    let seed: UInt64
    let substrateDepth: Double
    let substrate: String
  }
  final class Base {
    let pixels: [SIMD4<Float>]
    let cover: [Int]
    init(pixels: [SIMD4<Float>], cover: [Int]) {
      self.pixels = pixels
      self.cover = cover
    }
  }
  static let capacity = 4
  private var navigations: [(key: NavigationKey, value: IdleScreenAquariumNavigation)] = []
  private var bases: [(key: BaseKey, value: Base)] = []
  private(set) var navigationBuildCount = 0
  private(set) var baseBuildCount = 0
  var cachedNavigationCount: Int { navigations.count }
  var cachedBaseCount: Int { bases.count }

  func navigation(settings: IdleScreenAquariumRenderSettings, width: Int)
    -> IdleScreenAquariumNavigation
  {
    let worldWidth = min(1152, max(384, width))
    let key = NavigationKey(
      worldWidth: worldWidth, seed: settings.seed,
      substrateDepth: IdleScreenAquarium.safeDepth(settings.substrateDepth),
      objects: Array(settings.objects.prefix(24)),
      school: Set(
        settings.inhabitants.prefix(32).filter { $0.species == "neonTetra" }.map(\.identity)
      ).sorted())
    if let index = navigations.firstIndex(where: { $0.key == key }) {
      let entry = navigations.remove(at: index)
      navigations.append(entry)
      return entry.value
    }
    let built = IdleScreenAquariumNavigation(settings: settings, worldWidth: worldWidth)
    navigationBuildCount += 1
    navigations.append((key, built))
    if navigations.count > Self.capacity { navigations.removeFirst() }
    return built
  }

  func base(seed: UInt64, settings: IdleScreenAquariumRenderSettings, width: Int) -> Base {
    let key = BaseKey(
      width: width, seed: seed,
      substrateDepth: IdleScreenAquarium.safeDepth(settings.substrateDepth),
      substrate: settings.substrate)
    if let index = bases.firstIndex(where: { $0.key == key }) {
      let entry = bases.remove(at: index)
      bases.append(entry)
      return entry.value
    }
    let built = IdleScreenAquarium.staticBase(seed: seed, settings: settings, width: width)
    baseBuildCount += 1
    let value = Base(pixels: built.pixels, cover: built.cover)
    bases.append((key, value))
    if bases.count > Self.capacity { bases.removeFirst() }
    return value
  }

  func clear() {
    navigations = []
    bases = []
  }
}

/// Panorama consumers share their scene time and snapshot. Each distinct scene
/// (seed plus settings) keeps only its latest raster, so an animating tank holds
/// one frame instead of a history. A byte bound caps what several active scenes
/// can hold, and an evicted or superseded raster's storage renders the next
/// frame when nothing else still references it.
@MainActor
final class IdleScreenAquariumFrameCache {
  static let shared = IdleScreenAquariumFrameCache()
  /// Four 1152-wide scenes.
  static let defaultByteLimit =
    4 * 1152 * IdleScreenAquarium.height * MemoryLayout<SIMD4<Float>>.stride

  private struct Entry {
    var time: TimeInterval
    let seed: UInt64
    let settings: IdleScreenAquariumRenderSettings?
    var pixels: [SIMD4<Float>]
    var bytes: Int { pixels.count * MemoryLayout<SIMD4<Float>>.stride }
  }
  /// Least recently used first.
  private var entries: [Entry] = []
  let preparation = IdleScreenAquariumScenePreparation()
  let byteLimit: Int
  private(set) var generatedFrameCount = 0
  var cachedFrameCount: Int { entries.count }
  var cachedByteCount: Int { entries.reduce(0) { $0 + $1.bytes } }

  init(byteLimit: Int = IdleScreenAquariumFrameCache.defaultByteLimit) {
    self.byteLimit = byteLimit
  }

  func frame(at time: TimeInterval, seed: UInt64, settings: IdleScreenAquariumRenderSettings?)
    -> [SIMD4<Float>]
  {
    let time: TimeInterval = {
      guard settings?.reduceMotion == true else { return time.isFinite ? max(0, time) : 0 }
      guard settings?.light == "automatic", time.isFinite else { return 0 }
      return floor(max(0, time) / 60) * 60
    }()
    var storage: [SIMD4<Float>] = []
    var entry: Entry
    if let index = entries.firstIndex(where: { $0.seed == seed && $0.settings == settings }) {
      entry = entries.remove(at: index)
      if entry.time == time {
        entries.append(entry)
        return entry.pixels
      }
      // The scene advanced: its superseded raster becomes the render target.
      swap(&storage, &entry.pixels)
    } else {
      entry = .init(time: time, seed: seed, settings: settings, pixels: [])
    }
    entry.time = time
    let needed = Self.byteCount(settings: settings)
    while !entries.isEmpty, cachedByteCount + needed > byteLimit {
      var evicted = entries.removeFirst()
      if storage.isEmpty { swap(&storage, &evicted.pixels) }
    }
    // A donor from a wider scene keeps its capacity through the render, so a
    // narrower scene would hold (and be charged for) the wider allocation.
    let stride = MemoryLayout<SIMD4<Float>>.stride
    if storage.capacity * stride > needed + needed / 4 { storage = [] }
    entry.pixels = IdleScreenAquarium.frame(
      at: time, seed: seed, settings: settings, preparation: preparation, reusing: &storage)
    generatedFrameCount += 1
    entries.append(entry)
    return entry.pixels
  }

  private static func byteCount(settings: IdleScreenAquariumRenderSettings?) -> Int {
    let width = min(1152, max(384, settings?.worldWidth ?? IdleScreenAquarium.width))
    return width * IdleScreenAquarium.height * MemoryLayout<SIMD4<Float>>.stride
  }

  func clear() {
    entries = []
    preparation.clear()
  }
}
