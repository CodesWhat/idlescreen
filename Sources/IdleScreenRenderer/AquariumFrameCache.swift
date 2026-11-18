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
  let preparation = IdleScreenAquariumScenePreparation()
  private(set) var generatedFrameCount = 0
  var cachedFrameCount: Int { entries.count }

  func frame(at time: TimeInterval, seed: UInt64, settings: IdleScreenAquariumRenderSettings?)
    -> [SIMD4<Float>]
  {
    let time: TimeInterval = {
      guard settings?.reduceMotion == true else { return time }
      guard settings?.light == "automatic", time.isFinite else { return 0 }
      return floor(max(0, time) / 60) * 60
    }()
    if let index = entries.firstIndex(where: {
      $0.time == time && $0.seed == seed && $0.settings == settings
    }) {
      let entry = entries.remove(at: index)
      entries.append(entry)
      return entry.pixels
    }
    let pixels = IdleScreenAquarium.frame(
      at: time, seed: seed, settings: settings, preparation: preparation)
    generatedFrameCount += 1
    entries.append(.init(time: time, seed: seed, settings: settings, pixels: pixels))
    if entries.count > 8 { entries.removeFirst() }
    return pixels
  }

  func clear() {
    entries = []
    preparation.clear()
  }
}
