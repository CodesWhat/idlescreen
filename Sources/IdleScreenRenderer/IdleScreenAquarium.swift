import Foundation

/// A bounded pixel canvas shared by the preview and saver. Motion is sampled
/// from scene time so separate panorama views never advance independent worlds.
public enum IdleScreenAquarium {
  public static let width = 384
  public static let height = 216

  public static func frame(
    at elapsed: TimeInterval, seed: UInt64,
    settings: IdleScreenAquariumRenderSettings? = nil
  ) -> [SIMD4<Float>] {
    var storage: [SIMD4<Float>] = []
    return frame(
      at: elapsed, seed: seed, settings: settings,
      preparation: IdleScreenAquariumScenePreparation(),
      reusing: &storage)
  }

  /// Renders with scene data retained by `preparation` across timestamps.
  /// `reusing` donates storage for the raster and is left empty. The donor must
  /// be the only reference to move; copy-on-write keeps any other holder of that
  /// storage (a snapshot already handed out) unchanged.
  static func frame(
    at elapsed: TimeInterval, seed: UInt64,
    settings: IdleScreenAquariumRenderSettings?,
    preparation: IdleScreenAquariumScenePreparation,
    reusing storage: inout [SIMD4<Float>]
  ) -> [SIMD4<Float>] {
    let lightTime = elapsed.isFinite ? max(0, elapsed) : 0
    let elapsed = settings?.reduceMotion == true ? 0 : elapsed
    let time = elapsed.isFinite ? max(0, elapsed).truncatingRemainder(dividingBy: 86_400) : 0
    let requestedFlow = settings?.flow ?? 0.5
    let flow = requestedFlow.isFinite ? min(1, max(0, requestedFlow)) : 0.5
    let width = min(1152, max(384, settings?.worldWidth ?? Self.width))
    let phase = Double(seed % 997) / 997 * 6.28
    var canvas: Canvas
    if let settings {
      // Water and substrate don't move, so they're drawn once per scene.
      let base = preparation.base(seed: seed, settings: settings, width: width)
      canvas = Canvas(width: width, copying: base.pixels, reusing: &storage)
      particles(&canvas, time: time, flow: flow, cover: base.cover)
    } else {
      canvas = Canvas(width: width)
      water(&canvas)
      particles(&canvas, time: time, flow: flow, cover: nil)
    }
    if settings == nil {
      for layer in 0..<3 {
        for i in 0..<12 {
          plant(
            &canvas, x: i * 37 - 12 + layer * 14, base: 183 + layer * 8,
            length: 28 + (i * 19 + layer * 11) % 65, time: time,
            phase: Double(i) + phase, foreground: layer == 2)
        }
      }
    }
    if settings == nil {
      substrate(&canvas, seed: seed, phase: phase, depth: 0.14, kind: nil)
      // Flat, stepped stones give the shrimp places to graze.
      for i in 0..<7 {
        let x = i * 61 + 8
        let y = 181 + i % 3 * 6
        canvas.rect(x + 3, y, 21, 3, .init(0.26, 0.29, 0.31, 1))
        canvas.rect(x, y + 3, 28, 5, .init(0.18, 0.22, 0.24, 1))
        canvas.rect(x + 4, y + 8, 22, 2, .init(0.11, 0.16, 0.18, 1))
      }
    }
    if let settings {
      let navigation = preparation.navigation(settings: settings, width: width)
      for item in settings.objects.prefix(24) where !item.foreground {
        canvas.object(item, time: time, flow: flow)
      }
      for inhabitant in settings.inhabitants.prefix(32) {
        let pose = savedAnimal(
          inhabitant, at: time, seed: seed, settings: settings, worldWidth: width,
          navigation: navigation)
        let sprite = IdleScreenAquariumSpriteCache.shared.sprite(
          for: pose, variant: inhabitant.variant, eggs: inhabitant.carryingEggs)
        canvas.sprite(sprite, animal: pose, navigation: navigation)
      }
      for item in settings.objects.prefix(24) where item.foreground {
        canvas.object(item, time: time, flow: flow)
      }
      canvas.equipment(settings.equipment)
      if !settings.reduceMotion, let fedAt = settings.lastFeedingElapsed {
        canvas.food(
          at: lightTime - fedAt, floor: floorRow(depth: safeDepth(settings.substrateDepth)),
          flow: flow,
          feeder: settings.equipment.contains("feeder"))
      }
    } else {
      let animals = IdleScreenAquariumBehavior.animals(at: time, seed: seed)
      for animal in animals.sorted(by: { $0.scale < $1.scale }) {
        let sprite = animal.species.sprite(
          phase: animal.animationPhase, facingRight: animal.facingRight,
          activity: animal.activity, strikeProgress: animal.strikeProgress)
        canvas.sprite(sprite, animal: animal)
      }
    }
    if settings == nil || settings?.equipment.contains("airStone") == true
      || settings?.equipment.contains("spongeFilter") == true
    {
      for i in 0..<9 {
        let y = 178 - Int((time * 9 + Double(i * 23)).truncatingRemainder(dividingBy: 178))
        let x = width - 37 + Int(sin(time + Double(i)) * 3 - (178 - Double(y)) * flow * 0.08)
        let color = SIMD4<Float>(0.20, 0.37, 0.43, 1)
        canvas.rect(x + 1, y, 2, 1, color)
        canvas.rect(x, y + 1, 1, 2, color)
        canvas.rect(x + 3, y + 1, 1, 2, color)
        canvas.rect(x + 1, y + 3, 2, 1, color)
      }
    }
    if let settings { canvas.applyLight(settings, time: lightTime) }
    return canvas.pixels
  }

  static func safeDepth(_ depth: Double) -> Double {
    depth.isFinite ? min(0.24, max(0.08, depth)) : 0.14
  }

  static func floorRow(depth: Double) -> Int { Int(Double(height) * (1 - depth)) }

  static func water(_ canvas: inout Canvas) {
    for y in 0..<height {
      let depth = Float(y) / Float(height)
      let water = SIMD4<Float>(0.035 + depth * 0.015, 0.12 + depth * 0.025, 0.19 + depth * 0.025, 1)
      canvas.rect(0, y, canvas.width, 1, water)
    }
  }

  /// Backlit suspended particles, kept sparse enough to leave open water.
  /// `cover` holds the first substrate row per column so a prepared base,
  /// which already has the substrate drawn, still lets it hide the particles.
  static func particles(_ canvas: inout Canvas, time: Double, flow: Double, cover: [Int]?) {
    let width = canvas.width
    for i in 0..<32 {
      let x = Int(
        (Double(i * 71) + sin(time * 0.12 + Double(i)) * 4 + time * flow * 4).truncatingRemainder(
          dividingBy: Double(width - 4)))
      let y = Int((Double(i * 43) - time * 1.8).truncatingRemainder(dividingBy: 180) + 180) % 180
      if let cover, (0..<width).contains(x), y >= cover[x] { continue }
      canvas.rect(x, y, 1, 1, .init(0.10, 0.24, 0.30, 1))
    }
  }

  static func substrate(
    _ canvas: inout Canvas, seed: UInt64, phase: Double, depth: Double, kind: String?
  ) {
    let width = canvas.width
    let floor = floorRow(depth: depth)
    for y in max(0, floor - 5)..<height {
      for x in stride(from: 0, to: width, by: 3) {
        let ridge = floor + Int(sin(Double(x) * 0.032 + phase) * 4)
        guard y >= ridge else { continue }
        let shade = Float(hash(x / 3, y / 2, seed) % 7) / 6
        var color = SIMD4<Float>(0.16 + shade * 0.18, 0.16 + shade * 0.13, 0.19 + shade * 0.14, 1)
        switch kind {
        case "creamSand":
          color = .init(0.46 + shade * 0.25, 0.40 + shade * 0.22, 0.29 + shade * 0.19, 1)
        case "riverGravel":
          color = .init(0.25 + shade * 0.22, 0.23 + shade * 0.19, 0.20 + shade * 0.15, 1)
        case "plantedSoil":
          color = .init(0.12 + shade * 0.12, 0.09 + shade * 0.08, 0.08 + shade * 0.07, 1)
        case "neonGravel":
          color =
            (x / 3 + y / 2) % 3 == 0
            ? .init(0.30, 0.19 + shade * 0.23, 0.49, 1) : .init(0.08, 0.23 + shade * 0.15, 0.30, 1)
        default: break
        }
        canvas.rect(x, y, 3, 1, color)
      }
    }
  }

  /// Per column, the first row the substrate paints (the ridge, never above
  /// the band's top). Particles below it are hidden by the substrate.
  static func substrateCover(width: Int, seed: UInt64, depth: Double) -> [Int] {
    let phase = Double(seed % 997) / 997 * 6.28
    let floor = floorRow(depth: depth)
    let top = max(0, floor - 5)
    return (0..<width).map { column in
      let x = column / 3 * 3
      return max(top, floor + Int(sin(Double(x) * 0.032 + phase) * 4))
    }
  }

  /// Water and substrate only: everything in a saved scene that never moves.
  static func staticBase(
    seed: UInt64, settings: IdleScreenAquariumRenderSettings, width: Int
  ) -> (pixels: [SIMD4<Float>], cover: [Int]) {
    let depth = safeDepth(settings.substrateDepth)
    var canvas = Canvas(width: width)
    water(&canvas)
    substrate(
      &canvas, seed: seed, phase: Double(seed % 997) / 997 * 6.28, depth: depth,
      kind: settings.substrate)
    return (canvas.pixels, substrateCover(width: width, seed: seed, depth: depth))
  }

  private static func hash(_ x: Int, _ y: Int, _ seed: UInt64) -> UInt64 {
    var value = UInt64(x) &* 73_856_093 ^ UInt64(y) &* 19_349_663 ^ seed
    value = (value ^ (value >> 13)) &* 1_274_126_177
    return value ^ (value >> 16)
  }

  private static func plant(
    _ canvas: inout Canvas, x: Int, base: Int, length: Int,
    time: Double, phase: Double, foreground: Bool
  ) {
    let dark = SIMD4<Float>(foreground ? 0.24 : 0.12, 0.12, foreground ? 0.36 : 0.23, 1)
    let light = SIMD4<Float>(
      foreground ? 0.43 : 0.22, foreground ? 0.24 : 0.17, foreground ? 0.57 : 0.33, 1)
    for branch in -1...1 {
      let branchLength = length - abs(branch) * 12
      for step in 0..<branchLength {
        let bend = Int(sin(Double(step) * 0.045 + time * 0.35 + phase) * Double(step) * 0.13)
        let px = x + branch * step / 4 + bend
        canvas.rect(px, base - step, 5, 1, dark)
        canvas.rect(px, base - step, 2, 1, light)
      }
    }
  }

  struct Canvas {
    let width: Int
    let height = IdleScreenAquarium.height
    var pixels: [SIMD4<Float>]
    init(width: Int = IdleScreenAquarium.width) {
      self.width = width
      pixels = .init(repeating: .zero, count: width * height)
    }

    /// Starts from a copy of `base`, reusing `storage`'s allocation when this
    /// is its only owner. A shared buffer is never written: append on a
    /// non-unique array allocates a fresh one.
    init(width: Int, copying base: [SIMD4<Float>], reusing storage: inout [SIMD4<Float>]) {
      self.width = width
      var pixels: [SIMD4<Float>] = []
      swap(&pixels, &storage)
      pixels.removeAll(keepingCapacity: true)
      pixels.append(contentsOf: base)
      self.pixels = pixels
    }

    mutating func sprite(
      _ sprite: IdleScreenAquariumSprite, animal: IdleScreenAquariumAnimal,
      navigation: IdleScreenAquariumNavigation? = nil
    ) {
      let drawnWidth = max(
        1, Int((Double(sprite.width) * animal.scale * animal.horizontalScale).rounded()))
      let drawnHeight = max(1, Int((Double(sprite.height) * animal.scale).rounded()))
      let x = Int(animal.x.rounded()) - drawnWidth / 2
      let y = Int(animal.y.rounded()) - drawnHeight
      let light = Float(0.75 + animal.scale * 0.25)
      for row in 0..<drawnHeight {
        for column in 0..<drawnWidth {
          var color = sprite.pixels[
            (row * sprite.height / drawnHeight) * sprite.width + column * sprite.width / drawnWidth]
          if color.w > 0 {
            let behind =
              animal.species == .lionfish || animal.species == .neonTetra
              || animal.species == .codexFish
              || animal.shelterIndex != nil
            if behind,
              navigation?.masks(
                x: x + column, y: y + row,
                shelterIndex: animal.shelterIndex, hiding: animal.activity == .hiding) == true
            {
              continue
            }
            color *= light
            color.w = 1
            rect(x + column, y + row, 1, 1, color)
          }
        }
      }
    }

    mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: SIMD4<Float>) {
      let left = max(0, x)
      let right = min(width, x + w)
      let top = max(0, y)
      let bottom = min(height, y + h)
      guard left < right, top < bottom else { return }
      for row in top..<bottom {
        for column in left..<right { pixels[row * width + column] = color }
      }
    }
  }
}
