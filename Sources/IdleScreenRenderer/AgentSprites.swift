import Foundation
import simd

/// Which agent a sprite stands for. Claude is the orange spark creature,
/// Codex is the terminal bot.
public enum IdleScreenAgentSpriteKind: String, Equatable, Sendable {
  case claude
  case codex
}

public enum IdleScreenAgentSpriteState: String, Equatable, Sendable {
  case working
  case needsAttention
  case done
  case error
}

/// One agent sprite in the glyph scene. Neutral by default: the renderer
/// configuration carries an empty list and output is unchanged.
///
/// `startedAt` is when the current state began; the renderer derives the pose
/// from the time elapsed since then, so a host never has to push animation
/// frames.
public struct IdleScreenAgentSprite: Equatable, Sendable {
  public var kind: IdleScreenAgentSpriteKind
  public var state: IdleScreenAgentSpriteState
  public var startedAt: Date
  public var reduceMotion: Bool

  public init(
    kind: IdleScreenAgentSpriteKind,
    state: IdleScreenAgentSpriteState,
    startedAt: Date,
    reduceMotion: Bool = false
  ) {
    self.kind = kind
    self.state = state
    self.startedAt = startedAt
    self.reduceMotion = reduceMotion
  }

  /// The most sprites a scene ever draws.
  public static let maximumCount = 2
}

/// One sparse cell change applied after the main scene kernel. The layout is
/// shared byte for byte with the Metal `IdleScreenAgentSpriteOverride`.
///
/// The sprites use mode 0 only, to thin the glyphs around a sprite (a halo).
/// Mode 1 replaces brightness, glyph and foreground. Overrides are unique per
/// cell, so the GPU can apply them in parallel with no ordering.
struct AgentSpriteCellOverride: Equatable {
  var cell: UInt32
  var mode: UInt32
  var brightness: Float
  var glyph: Float
  var color: SIMD4<Float>

  /// The single definition of what an override does to one cell. The GPU
  /// kernel mirrors it and the CPU fallback calls it directly.
  func applied(
    brightness sceneBrightness: Float,
    glyph sceneGlyph: Float,
    color sceneColor: SIMD4<Float>
  ) -> (brightness: Float, glyph: Float, color: SIMD4<Float>) {
    if mode == 0 {
      return (sceneBrightness * brightness, sceneGlyph, sceneColor)
    }
    return (brightness, glyph, color)
  }
}

/// A pose of one sprite at one instant. A pure function of
/// (state, elapsed since, column count, reduce motion, seed).
///
/// Position is in scene cells; everything the sprite carries with it (markers,
/// sparkle) is in lattice pixels relative to the sprite, so a pose never
/// depends on the display it is drawn on.
struct AgentSpritePose: Equatable {
  struct Mark: Equatable {
    var name: String
    /// Left edge, in lattice pixels from the sprite's centre line.
    var dx: Int
    /// Bottom edge, in lattice pixels above the ground.
    var bottom: Int
    var color: SIMD3<Float>
  }

  struct Sparkle: Equatable {
    var pattern: [String]
    var dx: Int
    var bottom: Int
  }

  var kind: IdleScreenAgentSpriteKind
  /// Centre column in scene cells, fractional.
  var x: Double
  /// Hop height above the ground, in sprite units.
  var up = 0.0
  /// Rotation in degrees (tipped over = 90).
  var angle = 0.0
  /// 0 or 1 = a foot lifted, 2 = standing on both.
  var frame = 2
  var brightness = 1.0
  var squash = 1.0
  var marks: [Mark] = []
  var sparkle: Sparkle?
  var visible = true
}

/// One solid rectangle of the sprite layer, in view points from the top-left:
/// `edges` is (left, top, right, bottom) and `color` is final opaque RGBA.
/// The layout is shared byte for byte with the Metal `IdleScreenSpriteQuad`.
/// Edges, not sizes, so two neighbours share one computed value and the
/// rasteriser can never open a seam between them.
struct AgentSpriteQuad: Equatable {
  var edges: SIMD4<Float>
  var color: SIMD4<Float>
}

/// What the sprites contribute to one frame: solid lattice quads, drawn in
/// order with their own instance buffer, and the sparse cell halo that clears
/// the glyph field around them.
struct AgentSpriteLayer: Equatable {
  var quads: [AgentSpriteQuad] = []
  var halo: [AgentSpriteCellOverride] = []

  var isEmpty: Bool { quads.isEmpty && halo.isEmpty }
}

/// Pixel grids, poses and the pixel lattice for the agent sprites.
///
/// Geometry is defined in sprite units, where one lattice pixel is 4 units.
/// A lattice pixel is a square one cell wide (scaled down on narrow grids), so
/// a sprite is crisp pixel art that ignores the glyph grid's tall cells. Each
/// pixel is sampled four times and needs two hits, so rounded shapes keep
/// their outline at this resolution.
enum AgentSpriteLayout {
  static let terracotta = SIMD3<Float>(217, 119, 87) / 255
  static let codexWhite = SIMD3<Float>(236, 242, 250) / 255
  static let yellow = SIMD3<Float>(255, 214, 64) / 255
  static let mint = SIMD3<Float>(110, 255, 150) / 255
  static let red = SIMD3<Float>(255, 90, 79) / 255
  static let sparkleColor = SIMD3<Float>(255, 250, 220) / 255

  static let designColumns = 100.0
  /// Sprite units per lattice pixel.
  static let unitsPerPixel = 4.0
  /// The most halo cells and quads a frame draws between them.
  static let hardCap = 1_024

  static let workingSpeed = 6.0  // columns per second
  static let runInSpeed = 12.0
  static let sitDuration = 20.0
  static let spanColumns = 22.0
  static let hopDuration = 0.9
  static let walkOffSpeed = 10.0
  static let slotSpacing = 30.0

  static let centerParkFraction = 0.5
  /// Camera mode parks off-centre so the sprite does not cover the face.
  static let cameraParkFraction = 0.76

  // MARK: Metrics

  struct Metrics {
    let columns: Int
    /// Grid scale: 1 on grids at least 100 columns wide.
    let scale: Double

    /// `columns` is the width the sprites are laid out in. On one display of a
    /// multi-display scene that is the whole scene's width, so every display
    /// draws the same size.
    init(columns: Int) {
      self.columns = columns
      scale = AgentSpriteLayout.scale(sceneColumns: columns)
    }

    var span: Double { AgentSpriteLayout.spanColumns * scale }
    var spacing: Double { AgentSpriteLayout.slotSpacing * scale }
  }

  static func scale(sceneColumns: Int) -> Double {
    min(1, max(0.4, Double(sceneColumns) / designColumns))
  }

  // MARK: Shapes

  private static func rect(
    _ x: Double, _ y: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double
  ) -> Bool {
    x0 <= x && x < x1 && y0 <= y && y < y1
  }

  private static func roundedRect(
    _ x: Double, _ y: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
    _ radius: Double
  ) -> Bool {
    guard rect(x, y, x0, y0, x1, y1) else { return false }
    let cx = min(max(x, x0 + radius), x1 - radius)
    let cy = min(max(y, y0 + radius), y1 - radius)
    return hypot(x - cx, y - cy) <= radius
  }

  private static func segmentDistance(
    _ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ angle: Double, _ length: Double
  ) -> (distance: Double, along: Double) {
    let dx = cos(angle)
    let dy = sin(angle)
    let px = x - cx
    let py = y - cy
    let t = max(0, min(length, px * dx + py * dy))
    return (hypot(px - t * dx, py - t * dy), t)
  }

  /// Two legs, 2 columns wide; one lifted per run frame.
  private static func legs(_ x: Double, _ y: Double, _ frame: Int) -> Bool {
    let top = -12.0
    let left = frame != 1 ? 0.0 : -6.0
    let right = frame != 0 ? 0.0 : -6.0
    return rect(x, y, -20, top, -12, left) || rect(x, y, 12, top, 20, right)
  }

  /// The `>` chevron and `_` underscore on the Codex face.
  private static func promptCut(_ x: Double, _ y: Double) -> Bool {
    for (index, x0) in [-28.0, -20, -12, -20, -28].enumerated() {
      let y0 = -48 + 6 * Double(index)
      if rect(x, y, x0, y0, x0 + 12, y0 + 6) { return true }
    }
    return rect(x, y, 8, -24, 32, -18)
  }

  /// 0 = empty, 1 = body, 2 = cut-out (eyes, prompt).
  private static func sample(
    _ kind: IdleScreenAgentSpriteKind, _ x: Double, _ y: Double, _ frame: Int
  ) -> Int {
    switch kind {
    case .claude:
      if legs(x, y, frame) && y > -22 { return 1 }
      let cx = 0.0
      let cy = -42.0
      if rect(x, y, -8, -48, -4, -36) || rect(x, y, 4, -48, 8, -36) { return 2 }
      if hypot((x - cx) * 0.8, y - cy) < 16 { return 1 }
      let offset = frame == 1 ? 22.5 : 0.0
      for k in 0..<8 {
        let angle = (Double(k) * 45 + offset) * .pi / 180
        let (distance, along) = segmentDistance(x, y, cx, cy, angle, 30)
        if distance <= 7.4 - 2.4 * along / 30 { return 1 }
      }
      return 0
    case .codex:
      if legs(x, y, frame) && y > -22 { return 1 }
      if rect(x, y, -4, -66, 4, -60) || rect(x, y, -8, -72, 8, -66) { return 1 }
      if rect(x, y, -48, -42, -40, -24) || rect(x, y, 40, -42, 48, -24) { return 1 }
      if roundedRect(x, y, -40, -60, 40, -12, 10) {
        return promptCut(x, y) ? 2 : 1
      }
      return 0
    }
  }

  private static func halfWidth(_ kind: IdleScreenAgentSpriteKind) -> Double {
    kind == .claude ? 30 : 40
  }

  /// Codex deflates when it falls over; Claude tips onto its side.
  private static func fallsBySquash(_ kind: IdleScreenAgentSpriteKind) -> Bool {
    kind == .codex
  }

  private static let pivotY = -36.0

  // MARK: Markers

  private static func markPattern(_ name: String) -> [String] {
    switch name {
    case "!": ["XX", "XX", "XX", "..", "XX"]
    case "check": ["....X", "...XX", "X.XX.", "XXX..", ".X..."]
    default: ["X...X", ".X.X.", "..X..", ".X.X.", "X...X"]  // "x"
    }
  }

  static func markSize(_ name: String) -> (width: Int, height: Int) {
    let pattern = markPattern(name)
    return (pattern[0].count, pattern.count)
  }

  private static let sparkleBig = ["..X..", ".XXX.", "..X.."]
  private static let sparkleSmall = ["X"]

  // MARK: Poses

  private static func legFrame(_ t: Double) -> Int { Int(t * 4) % 2 }

  /// The pose of one sprite. `parkX` is where a parked sprite stands and where a
  /// reduced-motion sprite holds still; `phase` offsets a working run.
  static func pose(
    kind: IdleScreenAgentSpriteKind,
    state: IdleScreenAgentSpriteState,
    elapsed rawElapsed: Double,
    parkX: Double,
    phase: Double = 0,
    reduceMotion: Bool,
    metrics: Metrics,
    seed: UInt64 = 0
  ) -> AgentSpritePose {
    let t = rawElapsed.isFinite ? max(0, rawElapsed) : 0
    let columns = Double(metrics.columns)
    let span = metrics.span
    var pose = AgentSpritePose(kind: kind, x: parkX)

    if state == .working {
      if reduceMotion { return pose }
      let travel = columns + span
      let raw = t * workingSpeed + phase * travel
      pose.x = raw.truncatingRemainder(dividingBy: travel) - span / 2
      pose.frame = legFrame(t)
      return pose
    }

    let startX = state == .error ? parkX : parkX - 26 * metrics.scale
    let runIn = abs(parkX - startX) / runInSpeed

    if !reduceMotion {
      if state == .done, t > sitDuration {
        pose.x = parkX + (t - sitDuration) * walkOffSpeed
        pose.frame = legFrame(t)
        pose.visible = pose.x < columns + span / 2
        return pose
      }
      if t < runIn {
        pose.x = startX + (parkX > startX ? 1 : -1) * runInSpeed * t
        pose.frame = legFrame(t)
        return pose
      }
    }
    let settled = reduceMotion ? 0 : t - runIn

    switch state {
    case .needsAttention:
      if !reduceMotion {
        pose.up = abs(sin(.pi * settled / hopDuration)) * 14
      }
      let on = reduceMotion || settled.truncatingRemainder(dividingBy: 1.2) < 0.85
      if on {
        let size = markSize("!")
        pose.marks.append(
          .init(name: "!", dx: -size.width / 2, bottom: 22, color: yellow))
      }
    case .done:
      pose.marks.append(.init(name: "check", dx: 6, bottom: 20, color: mint))
      if !reduceMotion {
        let spots = [(-12, -5), (14, -2), (-9, 1), (16, -7)]
        let index = (Int(settled * 2.5) + Int(seed % 4)) % 4
        let spot = spots[index]
        let big = Int(settled * 5) % 2 == 1
        pose.sparkle = .init(
          pattern: big ? sparkleBig : sparkleSmall,
          dx: spot.0,
          bottom: 12 - Int((Double(spot.1) * 1.5).rounded())
        )
      }
    case .error:
      let size = markSize("x")
      var k = 1.0
      if !reduceMotion {
        k = min(1, settled / 0.45)
        k = k * k * (3 - 2 * k)
        if settled > 0.6 {
          pose.brightness = Int((settled - 0.6) * 3) % 2 == 0 ? 1 : 0.7
        }
      }
      let top: Double
      if fallsBySquash(kind) {
        pose.squash = 1 - 0.45 * k
        top = 80 - 30 * k
      } else {
        let wobble = reduceMotion ? 0 : 6 * sin(settled * 40) * (1 - k)
        pose.angle = 90 * k + wobble
        top = k < 0.5 ? 74 : 60
      }
      pose.marks.append(
        .init(
          name: "x", dx: -size.width / 2,
          bottom: Int(((top + 6) / unitsPerPixel).rounded(.up)), color: red))
    case .working:
      break
    }
    return pose
  }

  struct Entry: Equatable {
    var kind: IdleScreenAgentSpriteKind
    var state: IdleScreenAgentSpriteState
    var elapsed: Double
    var reduceMotion: Bool
  }

  /// Poses for up to two agents, in draw order.
  ///
  /// Parked agents take slots spaced `spacing` apart around `parkX`; working
  /// agents run in the same lane out of phase. Working agents draw first, so a
  /// runner always passes behind a parked sprite and never over it.
  static func poses(
    entries rawEntries: [Entry],
    columns: Int,
    parkFraction: Double,
    seed: UInt64 = 0
  ) -> [AgentSpritePose] {
    let entries = Array(rawEntries.prefix(IdleScreenAgentSprite.maximumCount))
    guard columns > 0, !entries.isEmpty else { return [] }
    let metrics = Metrics(columns: columns)
    let centre = parkFraction * Double(columns)
    let parked = entries.indices.filter { entries[$0].state != .working }
    let lower = metrics.span / 2
    let upper = Double(columns) - metrics.span / 2

    var results: [(order: Int, pose: AgentSpritePose)] = []
    for (index, entry) in entries.enumerated() {
      var parkX = centre
      var phase = 0.0
      if entry.state == .working {
        phase = entries.count == 1 ? 0 : Double(index) / Double(entries.count)
        if entry.reduceMotion && entries.count > 1 {
          parkX += (Double(index) - Double(entries.count - 1) / 2) * metrics.spacing
        }
      } else if let slot = parked.firstIndex(of: index) {
        parkX += (Double(slot) - Double(parked.count - 1) / 2) * metrics.spacing
      }
      if upper > lower { parkX = min(upper, max(lower, parkX)) }
      let pose = pose(
        kind: entry.kind,
        state: entry.state,
        elapsed: entry.elapsed,
        parkX: parkX,
        phase: phase,
        reduceMotion: entry.reduceMotion,
        metrics: metrics,
        seed: seed
      )
      let order = entry.state == .working && !entry.reduceMotion ? 0 : 1
      results.append((order * 10 + index, pose))
    }
    return results.sorted { $0.order < $1.order }.map(\.pose)
  }

  // MARK: Lattice

  /// One lattice pixel: `column` counts pixels across the whole scene from its
  /// left edge, `level` counts pixels up from the ground.
  struct Pixel: Hashable {
    var column: Int
    var level: Int
  }

  /// The lattice column of a pose's centre line.
  static func centreColumn(_ pose: AgentSpritePose, scale: Double) -> Int {
    Int((pose.x / scale).rounded())
  }

  /// Fill and cut-out pixels for one pose.
  static func shapePixels(
    _ pose: AgentSpritePose,
    scale: Double
  ) -> (fill: Set<Pixel>, cut: Set<Pixel>) {
    let unit = unitsPerPixel
    let angle = pose.angle * .pi / 180
    let ca = cos(angle)
    let sa = sin(angle)
    let pivotUp = abs(pivotY) * abs(ca) + halfWidth(pose.kind) * abs(sa)
    let centre = centreColumn(pose, scale: scale)
    let reach = 100.0
    let across = Int((reach / unit).rounded(.up)) + 1
    let height = Int(((reach + pose.up) / unit).rounded(.down))
    var fill = Set<Pixel>()
    var cut = Set<Pixel>()
    let offsets: [(Double, Double)] = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
    for level in 0...height {
      for column in (centre - across)...(centre + across) {
        var hits = [0, 0, 0]
        for (fx, fy) in offsets {
          let wx = (Double(column - centre) + fx) * unit
          let h = (Double(level) + fy) * unit
          let localX: Double
          let localY: Double
          if pose.squash != 1 {
            localX = wx
            localY = -(h - pose.up) / pose.squash
          } else {
            let wy = -(h - pose.up - pivotUp)
            localX = ca * wx + sa * wy
            localY = -sa * wx + ca * wy + pivotY
          }
          hits[sample(pose.kind, localX, localY, pose.frame)] += 1
        }
        if hits[2] >= 2 {
          cut.insert(Pixel(column: column, level: level))
        } else if hits[1] + hits[2] >= 2 {
          fill.insert(Pixel(column: column, level: level))
        }
      }
    }
    return (fill, cut)
  }

  private static func patternPixels(
    _ rows: [String], centre: Int, dx: Int, bottom: Int
  ) -> Set<Pixel> {
    var pixels = Set<Pixel>()
    for (r, line) in rows.enumerated() {
      for (c, ch) in line.enumerated() where ch == "X" {
        pixels.insert(
          Pixel(column: centre + dx + c, level: bottom + rows.count - 1 - r))
      }
    }
    return pixels
  }

  // MARK: Layer

  /// Where one drawn view sits in the scene, in view points.
  struct Geometry: Equatable {
    var columns: Int
    var rows: Int
    /// The width the sprites are laid out in, and where this view's slice of it
    /// starts, in cells.
    var sceneColumns: Int
    var originColumn: Int
    var width: Double
    var height: Double
    /// Distance from the top of the view to the sprites' feet.
    var groundY: Double

    var cellWidth: Double { width / Double(max(1, columns)) }
    var cellHeight: Double { height / Double(max(1, rows)) }
    var scale: Double { AgentSpriteLayout.scale(sceneColumns: sceneColumns) }
    /// Side of one lattice pixel, in points.
    var pixel: Double { scale * cellWidth }

    func x(edge column: Int) -> Float {
      Float((Double(column) * scale - Double(originColumn)) * cellWidth)
    }

    func y(edge level: Int) -> Float {
      Float(groundY - Double(level) * pixel)
    }
  }

  private struct Item {
    var priority: Int
    var halo: Int?
    var quad: AgentSpriteQuad?
  }

  /// Resolves poses into the sprite layer for one view.
  ///
  /// `sceneBrightness` scales every solid pixel toward the background, so a
  /// dimmed display dims its sprites with it; at 0 nothing is drawn. Past `cap`
  /// halo cells plus quads, the halo goes first, then the sparkle, then the
  /// cut-outs, so the body and its markers survive.
  static func layer(
    poses: [AgentSpritePose],
    geometry: Geometry,
    sceneBrightness: Float = 1,
    background: SIMD3<Float> = .zero,
    cap: Int = hardCap
  ) -> AgentSpriteLayer {
    guard geometry.columns > 0, geometry.rows > 0, geometry.width > 0, geometry.height > 0,
      sceneBrightness > 0
    else { return AgentSpriteLayer() }

    let scale = geometry.scale
    var items: [Item] = []
    var touched = Set<Int>()
    let stride = 1_000_000

    func solid(_ color: SIMD3<Float>, _ level: Float) -> SIMD4<Float> {
      let k = min(1, max(0, level * sceneBrightness))
      return SIMD4(background + (color - background) * k, 1)
    }
    func edges(_ pixel: Pixel) -> SIMD4<Float> {
      SIMD4(
        geometry.x(edge: pixel.column), geometry.y(edge: pixel.level + 1),
        geometry.x(edge: pixel.column + 1), geometry.y(edge: pixel.level))
    }
    func visible(_ rect: SIMD4<Float>) -> Bool {
      rect.z > 0 && rect.x < Float(geometry.width) && rect.w > 0
        && rect.y < Float(geometry.height)
    }
    // One column of margin, so a neighbouring display's sprite still thins
    // this display's edge cells.
    func nearby(_ rect: SIMD4<Float>) -> Bool {
      let margin = Float(geometry.cellWidth)
      return rect.z > -margin && rect.x < Float(geometry.width) + margin && rect.w > 0
        && rect.y < Float(geometry.height)
    }
    func put(_ pixels: Set<Pixel>, color: SIMD4<Float>, priority: Int) {
      for pixel in pixels.sorted(by: { ($0.level, $0.column) < ($1.level, $1.column) }) {
        let rect = edges(pixel)
        guard visible(rect) else { continue }
        items.append(Item(priority: priority, quad: AgentSpriteQuad(edges: rect, color: color)))
      }
    }
    func touch(_ pixels: Set<Pixel>) {
      let epsilon: Float = 1e-3
      for pixel in pixels {
        let rect = edges(pixel)
        guard nearby(rect) else { continue }
        let c0 = Int((rect.x / Float(geometry.cellWidth)).rounded(.down))
        let c1 = Int(((rect.z - epsilon) / Float(geometry.cellWidth)).rounded(.down))
        let r0 = Int((rect.y / Float(geometry.cellHeight)).rounded(.down))
        let r1 = Int(((rect.w - epsilon) / Float(geometry.cellHeight)).rounded(.down))
        guard c0 <= c1, r0 <= r1 else { continue }
        for row in r0...r1 {
          for column in c0...c1 {
            touched.insert((row + 1) * stride + (column + 1))
          }
        }
      }
    }

    for pose in poses where pose.visible {
      let centre = centreColumn(pose, scale: scale)
      let (fill, cut) = shapePixels(pose, scale: scale)
      var marks: [(Set<Pixel>, SIMD3<Float>)] = []
      for mark in pose.marks {
        let pixels = patternPixels(
          markPattern(mark.name), centre: centre, dx: mark.dx, bottom: mark.bottom)
        marks.append((pixels, mark.color))
      }
      var sparkle = Set<Pixel>()
      if let spark = pose.sparkle {
        sparkle = patternPixels(spark.pattern, centre: centre, dx: spark.dx, bottom: spark.bottom)
      }
      touch(fill.union(cut))
      for (pixels, _) in marks { touch(pixels) }
      touch(sparkle)

      let body = pose.kind == .claude ? terracotta : codexWhite
      put(fill, color: solid(body, Float(pose.brightness)), priority: 3)
      put(cut, color: SIMD4(background, 1), priority: 2)
      for (pixels, color) in marks { put(pixels, color: solid(color, 1), priority: 3) }
      put(sparkle, color: solid(sparkleColor, 1), priority: 1)
    }

    // Dilate the touched cells by one so the glyphs beside a sprite thin out.
    var ring = Set<Int>()
    for key in touched {
      let row = key / stride - 1
      let column = key % stride - 1
      for dr in -1...1 {
        for dc in -1...1 {
          let r = row + dr
          let c = column + dc
          if r >= 0, r < geometry.rows, c >= 0, c < geometry.columns {
            ring.insert(r * geometry.columns + c)
          }
        }
      }
    }
    for cell in ring.sorted() { items.append(Item(priority: 0, halo: cell)) }

    if items.count > cap {
      let ranked = items.indices.sorted {
        let (a, b) = (items[$0].priority, items[$1].priority)
        return a != b ? a > b : $0 < $1
      }
      let keep = Set(ranked.prefix(max(0, cap)))
      items = items.indices.filter { keep.contains($0) }.map { items[$0] }
    }

    var result = AgentSpriteLayer()
    for item in items {
      if let quad = item.quad { result.quads.append(quad) }
      if let cell = item.halo {
        result.halo.append(
          AgentSpriteCellOverride(
            cell: UInt32(cell), mode: 0, brightness: haloFactor, glyph: 0, color: .zero))
      }
    }
    return result
  }

  static let haloFactor: Float = 0.10

  /// Entry point used by the renderer. `groundRow` is the row boundary the
  /// feet stand on: the horizon when the scene has one, `rows` for the bottom.
  static func layer(
    sprites: [IdleScreenAgentSprite],
    now: Date,
    columns: Int,
    rows: Int,
    viewSize: (width: Double, height: Double),
    groundRow: Double,
    parkFraction: Double,
    seed: UInt64,
    viewport: IdleScreenRendererViewport = .full,
    sceneBrightness: Double = 1,
    background: SIMD3<Float> = .zero
  ) -> AgentSpriteLayer {
    guard !sprites.isEmpty, sceneBrightness > 0 else { return AgentSpriteLayer() }
    let (sceneColumns, origin) = sceneSpan(columns: columns, viewport: viewport)
    let entries = sprites.prefix(IdleScreenAgentSprite.maximumCount).map {
      Entry(
        kind: $0.kind, state: $0.state,
        elapsed: max(0, now.timeIntervalSince($0.startedAt)),
        reduceMotion: $0.reduceMotion)
    }
    let poses = poses(
      entries: entries, columns: sceneColumns, parkFraction: parkFraction, seed: seed)
    let geometry = Geometry(
      columns: columns, rows: rows, sceneColumns: sceneColumns, originColumn: origin,
      width: viewSize.width, height: viewSize.height,
      groundY: groundRow * viewSize.height / Double(max(1, rows)))
    return layer(
      poses: poses, geometry: geometry, sceneBrightness: Float(sceneBrightness),
      background: background)
  }

  /// The scene-wide column count and where this display's slice starts in it,
  /// matching how the procedural field maps a viewport onto the scene. A full
  /// viewport is the identity, so a single display is unchanged.
  static func sceneSpan(
    columns: Int,
    viewport: IdleScreenRendererViewport
  ) -> (sceneColumns: Int, origin: Int) {
    guard columns > 0 else { return (columns, 0) }
    let viewport = viewport.normalized
    let sceneColumns = max(columns, Int((Double(columns) / viewport.width).rounded()))
    let origin = Int((viewport.x * Double(sceneColumns)).rounded())
    return (sceneColumns, origin)
  }
}
