import Foundation

extension IdleScreenAquarium {
  static func objectSprite(kind: String, time: Double) -> IdleScreenAquariumSprite {
    let sizes: [String: (Int, Int)] = [
      "rock": (32, 12), "slate": (42, 25), "cave": (48, 30), "driftwood": (72, 46),
      "hollowLog": (56, 26), "moss": (30, 16), "grass": (22, 34), "fern": (32, 48),
      "purplePlant": (34, 66), "pirateChest": (34, 26), "skull": (28, 24),
      "shipwreck": (78, 44), "castle": (48, 58), "diver": (20, 32), "volcano": (42, 34),
    ]
    let size = sizes[kind] ?? (32, 12)
    var s = IdleScreenAquariumSprite(width: size.0, height: size.1)
    let stone = SIMD4<Float>(0.25, 0.31, 0.34, 1)
    let edge = SIMD4<Float>(0.09, 0.16, 0.18, 1)
    let pale = SIMD4<Float>(0.56, 0.63, 0.59, 1)
    let wood = SIMD4<Float>(0.37, 0.22, 0.15, 1)
    let grain = SIMD4<Float>(0.59, 0.36, 0.20, 1)
    let gold = SIMD4<Float>(0.86, 0.65, 0.25, 1)
    switch kind {
    case "driftwood":
      s.polygon(
        [
          (0, 44), (7, 37), (32, 30), (41, 16), (46, 2), (50, 0), (49, 19), (44, 30), (68, 29),
          (71, 34), (40, 39), (20, 43),
        ], wood)
      s.polygon([(30, 34), (19, 22), (12, 20), (17, 18), (29, 23), (39, 34)], wood)
      s.line(6, 40, 38, 34, grain)
      s.line(38, 34, 46, 17, grain)
      s.line(43, 34, 64, 32, grain)
    case "hollowLog":
      s.polygon([(6, 5), (44, 1), (54, 7), (55, 21), (43, 25), (5, 23), (0, 17), (0, 9)], wood)
      s.rect(5, 7, 9, 14, grain)
      s.rect(4, 9, 8, 10, edge)
      s.line(17, 7, 45, 5, grain)
      s.line(19, 19, 49, 18, grain)
    case "pirateChest":
      let lift = Int(time / 6) % 2 == 0 ? 0 : 2
      s.rect(2, 10, 30, 14, edge)
      s.rect(3, 11, 28, 12, wood)
      s.polygon([(2, 9 - lift), (5, 3 - lift), (27, 3 - lift), (31, 9 - lift)], wood)
      s.line(5, 4 - lift, 27, 4 - lift, grain)
      s.rect(7, 5 - lift, 3, 18 + lift, gold)
      s.rect(24, 5 - lift, 3, 18 + lift, gold)
      s.rect(3, 11, 28, 2, gold)
      s.rect(15, 11, 4, 5, gold)
      s.rect(16, 13, 2, 2, edge)
    case "skull":
      s.polygon(
        [
          (4, 5), (9, 1), (21, 1), (26, 6), (26, 16), (21, 19), (20, 23), (8, 23), (6, 18), (1, 15),
        ], pale)
      s.rect(5, 8, 6, 6, edge)
      s.rect(17, 8, 6, 6, edge)
      s.polygon([(14, 13), (11, 17), (16, 17)], edge)
      for x in stride(from: 9, to: 21, by: 4) { s.rect(x, 20, 2, 4, edge) }
    case "shipwreck":
      s.polygon([(2, 28), (69, 24), (77, 28), (64, 41), (17, 43)], wood)
      s.line(10, 33, 67, 30, grain)
      s.line(19, 39, 63, 36, grain)
      s.rect(29, 1, 4, 28, grain)
      s.line(14, 10, 48, 6, grain)
      s.polygon([(32, 5), (46, 9), (42, 20), (38, 17), (35, 23), (32, 19)], pale)
      for x in [20, 39, 58] { s.rect(x, 31, 5, 5, edge) }
    case "castle":
      s.rect(5, 19, 38, 38, stone)
      s.rect(18, 4, 13, 53, stone)
      for x in [3, 12, 21, 30, 39] { s.rect(x, 14, 6, 8, pale) }
      for x in [17, 25] { s.rect(x, 0, 6, 8, pale) }
      s.rect(19, 37, 11, 21, edge)
      s.rect(22, 16, 4, 8, edge)
      for y in stride(from: 25, to: 55, by: 8) { s.line(7, y, 40, y, pale) }
    case "diver":
      s.rect(5, 1, 11, 11, gold)
      s.rect(7, 3, 8, 6, edge)
      s.rect(7, 12, 9, 13, wood)
      s.rect(3, 13, 4, 12, stone)
      s.line(8, 24, 5, 30, grain)
      s.line(14, 24, 17, 30, grain)
      s.rect(2, 29, 6, 3, gold)
      s.rect(14, 29, 6, 3, gold)
      s.line(16, 14, 18, 22, gold)
    case "volcano":
      s.polygon([(0, 33), (13, 7), (29, 7), (41, 33)], stone)
      s.polygon([(13, 7), (20, 13), (29, 7), (25, 3), (17, 3)], edge)
      s.line(20, 13, 23, 21, SIMD4(0.85, 0.24, 0.22, 1))
      s.line(23, 21, 19, 31, SIMD4(0.85, 0.24, 0.22, 1))
    case "moss", "grass", "fern", "purplePlant":
      let green =
        kind == "purplePlant"
        ? SIMD4<Float>(0.42, 0.23, 0.56, 1) : SIMD4<Float>(0.20, 0.46, 0.31, 1)
      let dark =
        kind == "purplePlant"
        ? SIMD4<Float>(0.23, 0.13, 0.34, 1) : SIMD4<Float>(0.09, 0.29, 0.23, 1)
      let base = size.1 - 1
      for branch in -2...2 {
        let length = size.1 - 3 - abs(branch) * (kind == "moss" ? 2 : 6)
        for step in 0..<max(1, length) {
          let sway = Int(sin(Double(step) * 0.06 + time * 0.3) * Double(step) * 0.07)
          let x = size.0 / 2 + branch * step / 7 + sway
          s.rect(x, base - step, kind == "moss" ? 4 : 3, 1, dark)
          s.rect(x, base - step, 1, 1, green)
          if kind == "fern", step % 7 == 0 {
            s.line(x, base - step, x - 5, base - step - 3, green)
            s.line(x, base - step, x + 5, base - step - 4, green)
          }
        }
      }
    case "cave":
      s.polygon([(0, 29), (2, 12), (13, 2), (34, 0), (45, 12), (47, 29)], stone)
      s.polygon([(13, 29), (13, 15), (20, 9), (29, 10), (35, 17), (35, 29)], edge)
      s.line(9, 9, 20, 3, pale)
      s.line(20, 3, 34, 3, pale)
    case "slate":
      for layer in 0..<3 {
        s.rect(layer * 4, 21 - layer * 8, 40 - layer * 7, 4, edge)
        s.rect(layer * 4 + 1, 19 - layer * 8, 38 - layer * 7, 3, stone)
        s.rect(layer * 4 + 3, 18 - layer * 8, 32 - layer * 7, 1, pale)
      }
    default:
      s.polygon([(0, 10), (3, 4), (10, 1), (24, 0), (30, 4), (31, 11)], stone)
      s.line(6, 4, 24, 2, pale)
      s.rect(4, 10, 25, 2, edge)
    }
    return s
  }
}

extension IdleScreenAquarium {
  static func savedAnimal(
    _ item: IdleScreenAquariumRenderInhabitant, at time: Double, seed: UInt64,
    settings: IdleScreenAquariumRenderSettings, worldWidth: Int = 384
  ) -> IdleScreenAquariumAnimal {
    let offset = Double(item.identity % 997) * 0.13
    let prototypes = IdleScreenAquariumBehavior.animals(at: time + offset, seed: seed)
    let species: IdleScreenAquariumSpecies
    let base: IdleScreenAquariumAnimal
    switch item.species {
    case "mantisShrimp":
      species = .mantisShrimp
      base = prototypes[8]
    case "lionfish":
      species = .lionfish
      base = prototypes[9]
    case "neonTetra":
      species = .neonTetra
      base = prototypes[5 + Int(item.identity % 3)]
    case "corydoras":
      species = .corydoras
      base = prototypes[Int(item.identity % 5)]
    case "snail":
      species = .snail
      base =
        IdleScreenAquariumBehavior.animals(at: time * 0.15 + offset, seed: seed)[
          Int(item.identity % 5)]
    default:
      species = .cherryShrimp
      base = prototypes[Int(item.identity % 8)]
    }
    let depth =
      settings.substrateDepth.isFinite ? min(0.24, max(0.08, settings.substrateDepth)) : 0.14
    let positionX = base.x * Double(worldWidth) / 384
    var y = base.y
    if y > 170 {
      y += (1 - depth) * 216 - 186
      for object in settings.objects.prefix(24)
      where !["grass", "fern", "purplePlant", "moss"].contains(object.kind) {
        guard object.x.isFinite, object.y.isFinite, object.scale.isFinite else { continue }
        let sprite = objectSprite(kind: object.kind, time: 0)
        let center = object.x * Double(worldWidth)
        let half = Double(sprite.width) * min(1.5, max(0.5, object.scale)) / 2
        let ramp = max(0, min(1, (half + 16 - abs(positionX - center)) / 16))
        let climb = Double(sprite.height) * ramp * ramp * (3 - 2 * ramp)
        y = min(y, base.y + (1 - depth) * 216 - 186 - climb)
      }
    }
    return .init(
      species: species, x: positionX, y: y,
      scale: base.scale * (item.juvenile ? 0.55 : 1), horizontalScale: base.horizontalScale,
      facingRight: base.facingRight, activity: base.activity,
      animationPhase: base.animationPhase, strikeProgress: base.strikeProgress)
  }

  static func coloredShrimp(_ original: IdleScreenAquariumSprite, variant: String, eggs: Bool)
    -> IdleScreenAquariumSprite
  {
    var sprite = original
    for index in sprite.pixels.indices {
      let old = sprite.pixels[index]
      guard old.w > 0, old.x > old.y * 1.5, old.y < 0.5 else { continue }
      let shade = max(0.35, old.x)
      let color: SIMD3<Float>
      switch variant {
      case "orange": color = .init(1, 0.48, 0.13)
      case "yellow": color = .init(1, 0.82, 0.23)
      case "blue": color = .init(0.23, 0.65, 1)
      case "dark": color = .init(0.28, 0.34, 0.46)
      case "rili":
        color =
          (index % sprite.width > 11 && index % sprite.width < 20)
          ? .init(0.52, 0.67, 0.66) : .init(1, 0.25, 0.36)
      default: continue
      }
      sprite.pixels[index] = .init(color.x * shade, color.y * shade, color.z * shade, 1)
    }
    if eggs { sprite.rect(12, 12, 5, 2, SIMD4(0.92, 0.69, 0.23, 1)) }
    return sprite
  }
}

extension IdleScreenAquarium.Canvas {
  mutating func object(_ object: IdleScreenAquariumRenderObject, time: Double) {
    guard object.x.isFinite, object.y.isFinite, object.scale.isFinite else { return }
    var sprite = IdleScreenAquarium.objectSprite(kind: object.kind, time: time)
    if object.flipped {
      for y in 0..<sprite.height {
        let range = (y * sprite.width)..<((y + 1) * sprite.width)
        sprite.pixels.replaceSubrange(range, with: sprite.pixels[range].reversed())
      }
    }
    let scale = min(1.5, max(0.5, object.scale))
    let w = max(1, Int(Double(sprite.width) * scale))
    let h = max(1, Int(Double(sprite.height) * scale))
    let x = Int(min(1, max(0, object.x)) * Double(width)) - w / 2
    let y = Int(min(1, max(0, object.y)) * 216) - h
    for row in 0..<h {
      for column in 0..<w {
        let color = sprite.pixels[
          (row * sprite.height / h) * sprite.width + column * sprite.width / w]
        if color.w > 0 { rect(x + column, y + row, 1, 1, color) }
      }
    }
  }

  mutating func equipment(_ equipment: Set<String>) {
    let edge = SIMD4<Float>(0.08, 0.13, 0.15, 1)
    let body = SIMD4<Float>(0.22, 0.28, 0.30, 1)
    if equipment.contains("spongeFilter") {
      rect(width - 41, 156, 18, 28, edge)
      rect(width - 39, 158, 14, 24, body)
      rect(width - 34, 120, 4, 40, body)
      for y in stride(from: 160, to: 182, by: 4) { rect(width - 39, y, 14, 1, edge) }
    }
    if equipment.contains("externalFilter") {
      rect(width - 16, 24, 4, 156, body)
      rect(width - 20, 174, 10, 6, edge)
      rect(width - 60, 18, 48, 4, body)
    }
    if equipment.contains("heater") {
      rect(8, 92, 5, 76, body)
      rect(10, 111, 1, 46, SIMD4(0.72, 0.25, 0.21, 1))
    }
    if equipment.contains("feeder") {
      rect(26, 0, 25, 9, edge)
      rect(31, 8, 14, 4, body)
    }
    if equipment.contains("lightTimer") { rect(90, 1, 205, 3, body) }
    if equipment.contains("waterChanger") { rect(18, 0, 3, 70, body) }
    if equipment.contains("dosingController") { rect(3, 21, 11, 18, body) }
    if equipment.contains("uvClarifier") { rect(width - 8, 50, 6, 28, SIMD4(0.25, 0.20, 0.38, 1)) }
  }

  mutating func applyLight(_ settings: IdleScreenAquariumRenderSettings, time: Double) {
    var daylight = 1.0
    if settings.light == "automatic" {
      let seconds = time + (settings.epoch ?? 0) + Double(settings.hourOffset)
      let hour =
        ((seconds.truncatingRemainder(dividingBy: 86_400) + 86_400).truncatingRemainder(
          dividingBy: 86_400)) / 3600
      let sinceStart = (hour - Double(settings.lightStartHour) + 24).truncatingRemainder(
        dividingBy: 24)
      let duration = Double(settings.lightDurationHours)
      let ramp = min(1, max(0, min(sinceStart, duration - sinceStart) / 0.5))
      daylight = ramp * ramp * (3 - 2 * ramp)
    }
    let tint: SIMD3<Float>
    switch settings.light {
    case "sunset": tint = .init(1.1, 0.72, 0.56)
    case "moonBlue": tint = .init(0.43, 0.63, 1)
    case "blacklight": tint = .init(0.85, 0.47, 1.5)
    case "automatic":
      let night = SIMD3<Float>(0.43, 0.63, 1)
      tint = night + (SIMD3<Float>(repeating: 1) - night) * Float(daylight)
    default: tint = .init(repeating: 1)
    }
    let brightness =
      settings.brightness.isFinite ? Float(min(1, max(0.15, settings.brightness))) : 0.9
    let haze = settings.cloudiness.isFinite ? Float(min(0.25, max(0, settings.cloudiness))) : 0
    for index in pixels.indices {
      let old = pixels[index]
      let rgb =
        SIMD3(old.x, old.y, old.z) * tint * brightness * (1 - haze) + SIMD3<Float>(0.12, 0.22, 0.20)
        * haze
      pixels[index] = .init(min(1, rgb.x), min(1, rgb.y), min(1, rgb.z), 1)
    }
  }
}
