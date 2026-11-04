import Foundation

enum IdleScreenAquariumSpecies: CaseIterable, Equatable {
  case cherryShrimp
  case mantisShrimp
  case lionfish
  case neonTetra, corydoras, snail

  func sprite(
    phase: Int, facingRight: Bool,
    activity: IdleScreenAquariumActivity = .walking, strikeProgress: Double = 0
  ) -> IdleScreenAquariumSprite {
    var sprite: IdleScreenAquariumSprite
    switch self {
    case .cherryShrimp: sprite = Self.cherry(phase: phase & 3, activity: activity)
    case .mantisShrimp:
      sprite = Self.mantis(phase: phase & 3, activity: activity, strikeProgress: strikeProgress)
    case .lionfish: sprite = Self.lion(phase: phase & 3)
    case .neonTetra: sprite = Self.smallFish(bottom: false, phase: phase & 3)
    case .corydoras: sprite = Self.smallFish(bottom: true, phase: phase & 3)
    case .snail: sprite = Self.snail(phase: phase & 3)
    }
    if facingRight {
      for y in 0..<sprite.height {
        let start = y * sprite.width
        sprite.pixels.replaceSubrange(
          start..<(start + sprite.width),
          with: sprite.pixels[start..<(start + sprite.width)].reversed())
      }
    }
    return sprite
  }

  private static func cherry(phase: Int, activity: IdleScreenAquariumActivity)
    -> IdleScreenAquariumSprite
  {
    var s = IdleScreenAquariumSprite(width: 32, height: 18)
    let edge = color(100, 25, 48)
    let shell = color(189, 40, 62)
    let light = color(242, 87, 87)
    let leg = color(204, 72, 83)
    // Roots remain on the belly. Only knees and feet move through the gait.
    for (i, root) in [(10, 10), (13, 11), (16, 12), (19, 12)].enumerated() {
      let step =
        activity == .grazing || activity == .resting || activity == .turning
        ? 0 : ((phase + i) % 4 < 2 ? -1 : 1)
      s.line(root.0, root.1, root.0 - 1, 14, leg)
      s.line(root.0 - 1, 14, root.0 + step, 15, leg)
    }
    s.polygon(
      [
        (5, 7), (9, 5), (14, 6), (18, 8), (23, 9), (27, 7), (28, 10), (24, 13), (18, 13), (12, 12),
        (7, 10),
      ], edge)
    s.polygon(
      [(7, 7), (10, 6), (14, 7), (19, 9), (24, 10), (25, 11), (21, 12), (13, 10), (8, 9)], shell)
    s.line(9, 6, 14, 7, light)
    s.line(15, 8, 18, 9, light)
    s.line(19, 10, 22, 10, light)
    s.line(13, 8, 12, 10, edge)
    s.line(17, 9, 16, 11, edge)
    s.line(21, 10, 20, 12, edge)
    s.polygon([(25, 10), (27, 5), (29, 4), (29, 7), (31, 6), (30, 10), (27, 12)], shell)
    s.line(27, 9, 29, 5, light)
    s.line(6, 7, 3, 3, leg)
    s.line(3, 3, 0, 2, leg)
    s.line(6, 7, 8, 2, leg)
    s.line(8, 2, 12, 1, leg)
    s.rect(7, 7, 2, 2, color(43, 25, 39))
    s.rect(7, 7, 1, 1, color(255, 233, 177))
    s.line(5, 8, 3, 8, shell)
    if activity == .grazing {
      s.line(7, 10, 5, 12, leg)
      s.line(5, 12, 4 + phase % 2, 13, leg)
    }
    return s
  }

  private static func mantis(
    phase: Int, activity: IdleScreenAquariumActivity, strikeProgress: Double
  ) -> IdleScreenAquariumSprite {
    var s = IdleScreenAquariumSprite(width: 58, height: 30)
    let edge = color(21, 63, 70)
    let green = color(49, 155, 113)
    let lime = color(144, 203, 110)
    let blue = color(45, 146, 180)
    let red = color(202, 67, 63)
    let orange = color(245, 140, 76)
    for (i, root) in [(18, 18), (23, 20), (29, 21), (35, 22)].enumerated() {
      let step =
        activity == .resting || activity == .striking || activity == .turning
        ? 0 : ((phase + i) % 4 < 2 ? -2 : 1)
      s.line(root.0, root.1, root.0 - 3, 25, red)
      s.line(root.0 - 3, 25, root.0 + step, 27, orange)
    }
    // Broad tail fan and overlapping abdominal plates, rather than a scaled-up cherry shrimp.
    s.polygon([(44, 20), (52, 15), (56, 16), (54, 20), (57, 21), (54, 25), (46, 25)], edge)
    s.polygon([(46, 21), (53, 17), (54, 18), (51, 22), (55, 22), (52, 24), (46, 24)], blue)
    s.line(48, 22, 53, 19, orange)
    s.polygon(
      [
        (9, 11), (15, 7), (24, 8), (30, 12), (36, 15), (42, 17), (48, 20), (47, 24), (39, 24),
        (29, 22), (20, 20), (12, 18),
      ], edge)
    s.polygon([(11, 11), (16, 8), (23, 9), (27, 12), (24, 17), (16, 17), (12, 15)], green)
    s.line(15, 9, 23, 10, lime)
    for (x, y) in [(25, 12), (30, 15), (35, 17), (40, 19)] {
      s.polygon([(x, y), (x + 5, y + 1), (x + 7, y + 5), (x + 5, y + 6), (x, y + 4)], green)
      s.line(x, y, x + 4, y + 1, lime)
      s.line(x + 1, y + 4, x + 5, y + 5, blue)
    }
    for (x, y) in [(15, 12), (20, 14), (29, 17), (35, 20), (41, 22)] {
      s.rect(x, y, 2, 1, orange)
    }
    // Folded raptorial arms connect the red clubs to the thorax.
    let extensionAmount =
      activity == .striking && strikeProgress.isFinite ? min(1, max(0, strikeProgress)) : 0
    let reach = Int((extensionAmount * 4).rounded())
    let lift = Int((extensionAmount * 4).rounded())
    s.line(16, 15, 11 - reach, 21 - lift, red)
    s.line(11 - reach, 21 - lift, 7 - reach, 18 - lift, orange)
    s.polygon(
      [
        (4 - reach, 15 - lift), (8 - reach, 14 - lift), (11 - reach, 17 - lift),
        (9 - reach, 20 - lift), (5 - reach, 19 - lift),
      ], red)
    s.line(5 - reach, 15 - lift, 8 - reach, 15 - lift, orange)
    s.line(19, 17, 16, 23, red)
    s.line(16, 23, 12, 22, orange)
    s.line(11, 11, 3, 7, red)
    s.line(3, 7, 0, 7, orange)
    s.line(12, 10, 7, 3, red)
    s.line(7, 3, 3, 2, orange)
    let glance = phase == 2 ? 1 : 0
    s.line(12, 11, 11, 6, lime)
    s.line(17, 10, 18, 5, lime)
    s.rect(8, 3, 6, 4, blue)
    s.rect(15, 2, 6, 4, blue)
    s.rect(9, 3, 4, 1, color(185, 230, 206))
    s.rect(16, 2, 4, 1, color(185, 230, 206))
    s.rect(9 + glance, 4, 2, 2, edge)
    s.rect(16 + glance, 3, 2, 2, edge)
    return s
  }

  private static func lion(phase: Int) -> IdleScreenAquariumSprite {
    var s = IdleScreenAquariumSprite(width: 64, height: 52)
    let edge = color(74, 43, 46)
    let rust = color(167, 73, 57)
    let cream = color(236, 201, 159)
    let shade = color(124, 65, 62)
    let sway = phase % 2
    s.polygon([(43, 25), (60, 17 + sway), (62, 21 + sway), (61, 37 + sway), (46, 32)], shade)
    for y in stride(from: 19, through: 36, by: 4) {
      s.line(46, 28, 60, y + sway, cream)
      s.rect(57, y + sway, 2, 2, rust)
    }
    // Narrow dorsal rays have water between their tips, retaining a spiny silhouette.
    for (i, tip) in [(15, 8), (20, 3), (27, 1), (34, 3), (41, 7), (47, 12)].enumerated() {
      let rootX = 20 + i * 4
      s.polygon([(rootX - 3, 23), (tip.0 + 1, tip.1 + 6), (rootX + 4, 24)], shade)
      s.line(rootX, 23, tip.0 + sway, tip.1, cream)
      s.line(rootX, 22, (rootX + tip.0) / 2, (23 + tip.1) / 2, rust)
    }
    s.polygon(
      [
        (9, 25), (14, 19), (22, 16), (34, 18), (43, 23), (49, 27), (44, 32), (30, 35), (17, 32),
        (12, 29),
      ], edge)
    s.polygon(
      [(11, 25), (16, 20), (23, 18), (33, 20), (42, 24), (45, 28), (41, 31), (29, 33), (18, 30)],
      cream)
    // Clip oblique bands to the filled body before drawing the foreground fin.
    for y in 18...33 {
      for x in 11...45 where s.pixels[y * s.width + x] == cream {
        if (x + y / 3) % 8 < 4 { s.rect(x, y, 1, 1, rust) }
      }
    }
    s.line(21, 21, 20, 29, shade)
    s.polygon(
      [(25, 26), (32, 28), (48, 42 + sway), (44, 47 + sway), (37, 48), (28, 43), (21, 35)], shade)
    for (i, tip) in [(23, 36), (29, 43), (37, 47), (44, 46), (48, 41)].enumerated() {
      s.line(25, 27, tip.0, tip.1 + sway, cream)
      s.line(29, 31 + i, (25 + tip.0) / 2, (27 + tip.1) / 2, rust)
    }
    s.rect(14, 22, 5, 5, edge)
    s.rect(15, 22, 3, 3, cream)
    s.rect(15, 23, 2, 2, color(23, 32, 41))
    s.rect(15, 23, 1, 1, color(255, 239, 202))
    s.line(10, 26, 13, 26, edge)
    s.line(13, 21, 11, 17, cream)
    s.line(14, 30, 12, 34, cream)
    return s
  }

  private static func smallFish(bottom: Bool, phase: Int) -> IdleScreenAquariumSprite {
    var s = IdleScreenAquariumSprite(width: 30, height: 16)
    let edge = color(30, 65, 72)
    let body = bottom ? color(174, 161, 116) : color(100, 175, 184)
    let tail = phase % 2
    s.polygon([(18, 7), (28, 2 + tail), (29, 12 + tail), (19, 10)], edge)
    s.line(20, 8, 27, 5 + tail, body)
    s.line(20, 9, 27, 11 + tail, body)
    s.polygon([(1, 8), (6, 4), (13, 3), (22, 7), (22, 10), (14, 13), (6, 12)], body)
    s.polygon([(10, 4), (13, 0), (17, 5)], edge)
    s.line(10, 12, 15, 15, edge)
    s.line(4, 8, 20, 8, bottom ? color(91, 76, 55) : color(42, 215, 239))
    if bottom {
      s.line(2, 9, 0, 13, body)
      for x in [8, 12, 17] { s.rect(x, 5, 2, 1, edge) }
    } else {
      s.line(12, 10, 21, 10, color(227, 53, 78))
    }
    s.rect(4, 6, 2, 2, edge)
    s.rect(4, 6, 1, 1, color(245, 239, 192))
    return s
  }

  private static func snail(phase: Int) -> IdleScreenAquariumSprite {
    var s = IdleScreenAquariumSprite(width: 24, height: 20)
    let shell = color(182, 130, 76)
    let dark = color(88, 64, 54)
    let body = color(140, 157, 120)
    s.polygon([(4, 17), (3, 7), (8, 2), (16, 1), (21, 6), (22, 14), (18, 17)], shell)
    s.line(8, 6, 16, 5, dark)
    s.line(16, 5, 18, 12, dark)
    s.line(18, 12, 11, 14, dark)
    s.line(11, 14, 9, 9, dark)
    s.rect(11, 8, 4, 3, dark)
    s.polygon([(0, 18), (4, 14), (11, 16), (22, 17), (23, 19), (0, 19)], body)
    s.line(4, 15, 2, 9 + phase % 2, body)
    s.line(5, 15, 6, 10 - phase % 2, body)
    return s
  }

  private static func color(_ r: Float, _ g: Float, _ b: Float) -> SIMD4<Float> {
    .init(r / 255, g / 255, b / 255, 1)
  }
}

struct IdleScreenAquariumSprite {
  let width: Int
  let height: Int
  var pixels: [SIMD4<Float>]

  init(width: Int, height: Int) {
    self.width = width
    self.height = height
    pixels = .init(repeating: .zero, count: width * height)
  }

  mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: SIMD4<Float>) {
    guard max(0, x) < min(width, x + w), max(0, y) < min(height, y + h) else { return }
    for row in max(0, y)..<min(height, y + h) {
      for column in max(0, x)..<min(width, x + w) { pixels[row * width + column] = color }
    }
  }

  mutating func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ color: SIMD4<Float>) {
    var x = x0
    var y = y0
    let dx = abs(x1 - x0)
    let dy = -abs(y1 - y0)
    let sx = x0 < x1 ? 1 : -1
    let sy = y0 < y1 ? 1 : -1
    var error = dx + dy
    while true {
      rect(x, y, 1, 1, color)
      if x == x1, y == y1 { break }
      let twice = 2 * error
      if twice >= dy {
        error += dy
        x += sx
      }
      if twice <= dx {
        error += dx
        y += sy
      }
    }
  }

  mutating func polygon(_ points: [(Int, Int)], _ color: SIMD4<Float>) {
    guard let minY = points.map({ $0.1 }).min(), let maxY = points.map({ $0.1 }).max() else {
      return
    }
    for y in minY...maxY {
      var crossings: [Double] = []
      for i in points.indices {
        let a = points[i]
        let b = points[(i + 1) % points.count]
        if (a.1 <= y && b.1 > y) || (b.1 <= y && a.1 > y) {
          crossings.append(Double(a.0) + Double(y - a.1) * Double(b.0 - a.0) / Double(b.1 - a.1))
        }
      }
      crossings.sort()
      for i in stride(from: 0, to: crossings.count - 1, by: 2) {
        let left = Int(crossings[i].rounded(.up))
        let right = Int(crossings[i + 1].rounded(.down))
        rect(left, y, right - left + 1, 1, color)
      }
    }
    for i in points.indices {
      let a = points[i]
      let b = points[(i + 1) % points.count]
      line(a.0, a.1, b.0, b.1, color)
    }
  }
}
