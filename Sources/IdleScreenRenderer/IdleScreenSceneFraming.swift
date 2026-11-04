import Foundation

/// A composition layer applied on top of a procedural pattern.
///
/// `none` leaves the full-bleed field alone. `horizon` gives the scene negative
/// space: a quiet sky above a horizon line, the pattern as ground below, and a
/// thin accent line on the horizon. It applies to any procedural pattern.
public enum IdleScreenRendererFraming: String, Equatable, Sendable, CaseIterable {
  case none
  case horizon
}

/// The CPU definition of the framing mask. The Metal kernel mirrors it, and the
/// CPU glyph fill calls it directly.
enum IdleScreenSceneFramingMask {
  /// Where the horizon sits in scene space, measured from the top.
  static let horizonFraction = 0.6
  /// Brightness multiplier at the top of the sky, and just above the horizon.
  static let skyTop: Float = 0.10
  static let skyHorizon: Float = 0.24
  /// Ground multiplier at the horizon, easing to 1 over `groundRamp` rows.
  static let groundHorizon: Float = 0.55
  static let groundRamp: Float = 8
  /// Brightness band (after contrast and framing) that takes the accent colour.
  static let accentBand: ClosedRange<Float> = 0.80...0.905

  /// The horizon in this grid's row coordinates, snapped to a row boundary so
  /// the horizon line and the sprites' feet sit exactly between two rows. May
  /// fall outside `0...rows` on one display of a multi-display scene.
  static func horizonRow(
    viewport: IdleScreenRendererViewport,
    columns: Int,
    rows: Int
  ) -> Float {
    let origin = viewport.coordinate(column: 0, row: 0, columns: columns, rows: rows)
    guard origin.rows > 0 else { return Float(rows) }
    let sceneRow = (horizonFraction * Double(origin.rows)).rounded()
    return Float(sceneRow - Double(origin.row))
  }

  /// `row` and `horizonRow` are in this grid's coordinates. `originRow` is the
  /// grid's first row in the scene, so the sky gradient runs over scene rows
  /// and stacked displays share one continuous ramp.
  static func mask(row: Int, horizonRow: Float, originRow: Int = 0) -> Float {
    let row = Float(row)
    if row < horizonRow {
      let origin = Float(originRow)
      let sceneHorizon = horizonRow + origin
      let t = sceneHorizon > 0 ? min(1, max(0, (row + origin) / sceneHorizon)) : 1
      return skyTop + (skyHorizon - skyTop) * t
    }
    let t = min(1, max(0, (row - horizonRow) / groundRamp))
    let eased = t * t * (3 - 2 * t)
    return groundHorizon + (1 - groundHorizon) * eased
  }

  static func isAccent(_ brightness: Float) -> Bool {
    accentBand.contains(brightness)
  }
}
