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
/// `mode` 0 multiplies the scene brightness by `brightness` (a halo or cut-out);
/// mode 1 replaces brightness, glyph and foreground. Overrides are unique per
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
struct AgentSpritePose: Equatable {
  struct Mark: Equatable {
    var name: String
    var column: Int
    var row: Int
    var color: SIMD3<Float>
  }

  struct Sparkle: Equatable {
    var pattern: [String]
    var column: Int
    var row: Int
  }

  var kind: IdleScreenAgentSpriteKind
  /// Centre column, fractional.
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

/// Pixel grids, poses and cell overrides for the agent sprites.
///
/// Geometry is defined in sprite units where the design cell is 4 x 6 units,
/// and sampled per grid cell, so round shapes stay round despite the tall cell.
/// On grids narrower than 100 columns the unit scale shrinks the sprite so a
/// small preview is not swamped.
enum AgentSpriteLayout {
  static let terracotta = SIMD3<Float>(217, 119, 87) / 255
  static let codexWhite = SIMD3<Float>(236, 242, 250) / 255
  static let yellow = SIMD3<Float>(255, 214, 64) / 255
  static let mint = SIMD3<Float>(110, 255, 150) / 255
  static let red = SIMD3<Float>(255, 90, 79) / 255
  static let sparkleColor = SIMD3<Float>(255, 250, 220) / 255

  /// Glyph index of the densest character in the renderer's ramp.
  static let solidGlyph: Float = 9
  static let designColumns = 100.0
  static let cellWidthUnits = 4.0
  static let cellHeightUnits = 6.0
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
    let rows: Int
    /// Grid scale: 1 on grids at least 100 columns wide.
    let scale: Double
    /// Sprite units covered by one cell.
    let cellWidth: Double
    let cellHeight: Double

    init(columns: Int, rows: Int) {
      self.columns = columns
      self.rows = rows
      scale = min(1, max(0.4, Double(columns) / AgentSpriteLayout.designColumns))
      cellWidth = AgentSpriteLayout.cellWidthUnits / scale
      cellHeight = AgentSpriteLayout.cellHeightUnits / scale
    }

    var ground: Double { Double(rows - 1) * cellHeight }
    var span: Double { AgentSpriteLayout.spanColumns * scale }
    var spacing: Double { AgentSpriteLayout.slotSpacing * scale }

    func row(forHeight units: Double) -> Int {
      Int(((ground - units) / cellHeight).rounded(.down))
    }
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
        if distance <= 5.6 - 1.8 * along / 30 { return 1 }
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

  private static func markPattern(_ name: String) -> (rows: [String], scaleX: Int) {
    switch name {
    case "!": (["X", "X", "X", ".", "X"], 3)
    case "check": (["...X", "..X.", "X.X.", ".X.."], 2)
    default: (["X.X", "X.X", ".X.", "X.X", "X.X"], 2)  // "x"
    }
  }

  static func markSize(_ name: String) -> (width: Int, height: Int) {
    let pattern = markPattern(name)
    return (pattern.rows[0].count * pattern.scaleX, pattern.rows.count)
  }

  private static func markCells(_ name: String, column: Int, row: Int) -> Set<Cell> {
    let pattern = markPattern(name)
    var cells = Set<Cell>()
    for (r, line) in pattern.rows.enumerated() {
      for (c, ch) in line.enumerated() where ch == "X" {
        for k in 0..<pattern.scaleX {
          cells.insert(Cell(column: column + c * pattern.scaleX + k, row: row + r))
        }
      }
    }
    return cells
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
    let markColumn = Int(parkX.rounded())

    switch state {
    case .needsAttention:
      if !reduceMotion {
        pose.up = abs(sin(.pi * settled / hopDuration)) * 14
      }
      let on = reduceMotion || settled.truncatingRemainder(dividingBy: 1.2) < 0.85
      if on {
        let size = markSize("!")
        pose.marks.append(
          .init(
            name: "!",
            column: markColumn - size.width / 2,
            row: metrics.row(forHeight: 78 + 6) - size.height + 1 - 1,
            color: yellow
          ))
      }
    case .done:
      let size = markSize("check")
      pose.marks.append(
        .init(
          name: "check",
          column: markColumn + 6,
          row: metrics.row(forHeight: 80) - size.height + 2,
          color: mint
        ))
      if !reduceMotion {
        let spots = [(-12, -5), (14, -2), (-9, 1), (16, -7)]
        let index = (Int(settled * 2.5) + Int(seed % 4)) % 4
        let spot = spots[index]
        let big = Int(settled * 5) % 2 == 1
        pose.sparkle = .init(
          pattern: big ? sparkleBig : sparkleSmall,
          column: markColumn + spot.0,
          row: metrics.row(forHeight: 50) + spot.1
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
          name: "x",
          column: markColumn - size.width / 2,
          row: metrics.row(forHeight: top + 6) - size.height + 1,
          color: red
        ))
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
    rows: Int,
    parkFraction: Double,
    seed: UInt64 = 0
  ) -> [AgentSpritePose] {
    let entries = Array(rawEntries.prefix(IdleScreenAgentSprite.maximumCount))
    guard columns > 0, rows > 1, !entries.isEmpty else { return [] }
    let metrics = Metrics(columns: columns, rows: rows)
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

  // MARK: Cells

  struct Cell: Hashable {
    var column: Int
    var row: Int
  }

  /// Fill and cut-out cells for one pose, by sampling the sprite shape four
  /// times per cell and requiring two hits.
  static func shapeCells(
    _ pose: AgentSpritePose,
    metrics: Metrics
  ) -> (fill: Set<Cell>, cut: Set<Cell>) {
    let cw = metrics.cellWidth
    let ch = metrics.cellHeight
    let angle = pose.angle * .pi / 180
    let ca = cos(angle)
    let sa = sin(angle)
    let halfWidth = halfWidth(pose.kind)
    let pivotUp = abs(pivotY) * abs(ca) + halfWidth * abs(sa)
    let pivotWorldY = metrics.ground - pose.up - pivotUp
    let pivotWorldX = pose.x * cw
    let reach = 100.0
    let c0 = Int(((pivotWorldX - reach) / cw).rounded(.down))
    let c1 = Int(((pivotWorldX + reach) / cw).rounded(.down)) + 1
    let r0 = Int(((metrics.ground - reach - pose.up) / ch).rounded(.down))
    var fill = Set<Cell>()
    var cut = Set<Cell>()
    let offsets: [(Double, Double)] = [(0.3, 0.25), (0.7, 0.25), (0.3, 0.75), (0.7, 0.75)]
    for row in max(0, r0)..<max(max(0, r0), metrics.rows) {
      for column in max(0, c0)..<max(max(0, c0), min(metrics.columns, c1)) {
        var hits = [0, 0, 0]
        for (fx, fy) in offsets {
          let wx = Double(column) * cw + fx * cw - pivotWorldX
          let localX: Double
          let localY: Double
          if pose.squash != 1 {
            localX = wx
            localY = (Double(row) * ch + fy * ch - metrics.ground + pose.up) / pose.squash
          } else {
            let wy = Double(row) * ch + fy * ch - pivotWorldY
            localX = ca * wx + sa * wy
            localY = -sa * wx + ca * wy + pivotY
          }
          hits[sample(pose.kind, localX, localY, pose.frame)] += 1
        }
        if hits[2] >= 2 {
          cut.insert(Cell(column: column, row: row))
        } else if hits[1] + hits[2] >= 2 {
          fill.insert(Cell(column: column, row: row))
        }
      }
    }
    return (fill, cut)
  }

  // MARK: Overrides

  private struct Accumulator {
    var scale: Float = 1
    var solid: (brightness: Float, glyph: Float, color: SIMD4<Float>)?
  }

  /// Resolves poses into one override per cell, ordered by cell index.
  /// Draw order is preserved: later sprites multiply or replace earlier ones.
  static func overrides(
    poses: [AgentSpritePose],
    columns: Int,
    rows: Int
  ) -> [AgentSpriteCellOverride] {
    guard columns > 0, rows > 0 else { return [] }
    let metrics = Metrics(columns: columns, rows: rows)
    var cells: [Int: Accumulator] = [:]

    func inBounds(_ cell: Cell) -> Bool {
      cell.column >= 0 && cell.column < columns && cell.row >= 0 && cell.row < rows
    }
    func index(_ cell: Cell) -> Int { cell.row * columns + cell.column }
    func multiply(_ cell: Cell, _ factor: Float) {
      guard inBounds(cell) else { return }
      var entry = cells[index(cell)] ?? Accumulator()
      if entry.solid != nil {
        entry.solid!.brightness *= factor
      } else {
        entry.scale *= factor
      }
      cells[index(cell)] = entry
    }
    func put(_ cell: Cell, brightness: Float, color: SIMD3<Float>) {
      guard inBounds(cell) else { return }
      var entry = cells[index(cell)] ?? Accumulator()
      entry.solid = (brightness, solidGlyph, SIMD4(color, 1))
      cells[index(cell)] = entry
    }
    func halo(_ hull: Set<Cell>, keep: Set<Cell>) {
      var ring = Set<Cell>()
      for cell in hull {
        for dc in -1...1 {
          for dr in -1...1 {
            let neighbour = Cell(column: cell.column + dc, row: cell.row + dr)
            if !hull.contains(neighbour) && !keep.contains(neighbour) {
              ring.insert(neighbour)
            }
          }
        }
      }
      for cell in ring { multiply(cell, 0.10) }
    }

    for pose in poses where pose.visible {
      let (fill, cut) = shapeCells(pose, metrics: metrics)
      let hull = fill.union(cut)
      var markSets: [(Set<Cell>, SIMD3<Float>)] = []
      var keep = Set<Cell>()
      for mark in pose.marks {
        let cells = markCells(mark.name, column: mark.column, row: mark.row)
        markSets.append((cells, mark.color))
        keep.formUnion(cells)
      }
      for (cells, _) in markSets { halo(cells, keep: []) }
      halo(hull, keep: keep)
      for cell in cut { multiply(cell, 0.04) }
      let color = pose.kind == .claude ? terracotta : codexWhite
      for cell in fill { put(cell, brightness: Float(pose.brightness), color: color) }
      for (cells, markColor) in markSets {
        for cell in cells { put(cell, brightness: 1, color: markColor) }
      }
      if let sparkle = pose.sparkle {
        var cells = Set<Cell>()
        for (r, line) in sparkle.pattern.enumerated() {
          for (c, ch) in line.enumerated() where ch == "X" {
            cells.insert(Cell(column: sparkle.column + c, row: sparkle.row + r))
          }
        }
        halo(cells, keep: [])
        for cell in cells { put(cell, brightness: 1, color: sparkleColor) }
      }
    }

    let sorted = cells.keys.sorted().prefix(hardCap)
    return sorted.map { key in
      let entry = cells[key]!
      if let solid = entry.solid {
        return AgentSpriteCellOverride(
          cell: UInt32(key), mode: 1, brightness: solid.brightness,
          glyph: solid.glyph, color: solid.color)
      }
      return AgentSpriteCellOverride(
        cell: UInt32(key), mode: 0, brightness: entry.scale, glyph: 0, color: .zero)
    }
  }

  /// Entry point used by the renderer.
  static func overrides(
    sprites: [IdleScreenAgentSprite],
    now: Date,
    columns: Int,
    rows: Int,
    parkFraction: Double,
    seed: UInt64
  ) -> [AgentSpriteCellOverride] {
    guard !sprites.isEmpty else { return [] }
    let entries = sprites.prefix(IdleScreenAgentSprite.maximumCount).map {
      Entry(
        kind: $0.kind, state: $0.state,
        elapsed: max(0, now.timeIntervalSince($0.startedAt)),
        reduceMotion: $0.reduceMotion)
    }
    let poses = poses(
      entries: entries, columns: columns, rows: rows,
      parkFraction: parkFraction, seed: seed)
    return overrides(poses: poses, columns: columns, rows: rows)
  }
}
