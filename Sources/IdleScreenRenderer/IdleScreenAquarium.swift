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
    let elapsed = settings?.reduceMotion == true ? 0 : elapsed
    let time = elapsed.isFinite ? max(0, elapsed).truncatingRemainder(dividingBy: 86_400) : 0
    let width = min(1152, max(384, settings?.worldWidth ?? Self.width))
    var canvas = Canvas(width: width)
    let phase = Double(seed % 997) / 997 * 6.28
    for y in 0..<height {
      let depth = Float(y) / Float(height)
      let water = SIMD4<Float>(0.035 + depth * 0.015, 0.12 + depth * 0.025, 0.19 + depth * 0.025, 1)
      canvas.rect(0, y, width, 1, water)
    }
    // Backlit suspended particles, kept sparse enough to leave open water.
    for i in 0..<32 {
      let x = Int(
        (Double(i * 71) + sin(time * 0.12 + Double(i)) * 4).truncatingRemainder(
          dividingBy: Double(width - 4)))
      let y = Int((Double(i * 43) - time * 1.8).truncatingRemainder(dividingBy: 180) + 180) % 180
      canvas.rect(x, y, 1, 1, .init(0.10, 0.24, 0.30, 1))
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
    let depth = settings?.substrateDepth ?? 0.14
    let safeDepth = depth.isFinite ? min(0.24, max(0.08, depth)) : 0.14
    let floor = Int(Double(height) * (1 - safeDepth))
    for y in max(0, floor - 5)..<height {
      for x in stride(from: 0, to: width, by: 3) {
        let ridge = floor + Int(sin(Double(x) * 0.032 + phase) * 4)
        guard y >= ridge else { continue }
        let shade = Float(hash(x / 3, y / 2, seed) % 7) / 6
        var color = SIMD4<Float>(0.16 + shade * 0.18, 0.16 + shade * 0.13, 0.19 + shade * 0.14, 1)
        switch settings?.substrate {
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
    if settings == nil {
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
      for item in settings.objects.prefix(24) where !item.foreground {
        canvas.object(item, time: time)
      }
      for inhabitant in settings.inhabitants.prefix(32) {
        let pose = savedAnimal(
          inhabitant, at: time, seed: seed, settings: settings, worldWidth: width)
        var sprite = pose.species.sprite(
          phase: pose.animationPhase, facingRight: pose.facingRight,
          activity: pose.activity, strikeProgress: pose.strikeProgress)
        if pose.species == .cherryShrimp {
          sprite = coloredShrimp(sprite, variant: inhabitant.variant, eggs: inhabitant.carryingEggs)
        }
        canvas.sprite(sprite, animal: pose)
      }
      for item in settings.objects.prefix(24) where item.foreground {
        canvas.object(item, time: time)
      }
      canvas.equipment(settings.equipment)
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
        let x = width - 37 + Int(sin(time + Double(i)) * 3)
        let color = SIMD4<Float>(0.20, 0.37, 0.43, 1)
        canvas.rect(x + 1, y, 2, 1, color)
        canvas.rect(x, y + 1, 1, 2, color)
        canvas.rect(x + 3, y + 1, 1, 2, color)
        canvas.rect(x + 1, y + 3, 2, 1, color)
      }
    }
    if let settings { canvas.applyLight(settings, time: time) }
    return canvas.pixels
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

    mutating func sprite(_ sprite: IdleScreenAquariumSprite, animal: IdleScreenAquariumAnimal) {
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
