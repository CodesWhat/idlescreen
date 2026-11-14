import CoreGraphics
import Foundation

/// Shared inverse sampling keeps drawn pixels, obstruction masks and portal
/// openings on the same nearest-neighbor pixel lattice.
struct IdleScreenAquariumObjectTransform {
  let width: Int
  let height: Int
  private let sourceWidth: Int
  private let sourceHeight: Int
  private let rotatedWidth: Int
  private let rotatedHeight: Int
  private let cosine: Double
  private let sine: Double
  private let flipped: Bool

  init(object: IdleScreenAquariumRenderObject, sourceWidth: Int, sourceHeight: Int) {
    self.sourceWidth = sourceWidth
    self.sourceHeight = sourceHeight
    let degrees = object.tiltDegrees.isFinite ? min(15, max(-15, object.tiltDegrees)) : 0
    let angle = degrees * .pi / 180
    cosine = cos(angle)
    sine = sin(angle)
    flipped = object.flipped
    rotatedWidth = Int(ceil(Double(sourceWidth) * abs(cosine) + Double(sourceHeight) * abs(sine)))
    rotatedHeight = Int(ceil(Double(sourceWidth) * abs(sine) + Double(sourceHeight) * abs(cosine)))
    let scale = object.scale.isFinite ? min(1.5, max(0.5, object.scale)) : 1
    width = max(1, Int(Double(rotatedWidth) * scale))
    height = max(1, Int(Double(rotatedHeight) * scale))
  }

  func sourcePixel(column: Int, row: Int) -> SIMD2<Int>? {
    let x = (Double(column) + 0.5) * Double(rotatedWidth) / Double(width) - Double(rotatedWidth) / 2
    let y = (Double(row) + 0.5) * Double(rotatedHeight) / Double(height) - Double(rotatedHeight) / 2
    let sourceX = cosine * x + sine * y + Double(sourceWidth) / 2
    let sourceY = -sine * x + cosine * y + Double(sourceHeight) / 2
    guard sourceX >= 0, sourceY >= 0, sourceX < Double(sourceWidth), sourceY < Double(sourceHeight)
    else {
      return nil
    }
    let sx = Int(sourceX)
    return .init(flipped ? sourceWidth - sx - 1 : sx, Int(sourceY))
  }

  func bounds(of rect: CGRect) -> CGRect {
    let corners = [
      point(rect.minX, rect.minY), point(rect.maxX, rect.minY),
      point(rect.minX, rect.maxY), point(rect.maxX, rect.maxY),
    ]
    let left = corners.map(\.x).min() ?? 0
    let top = corners.map(\.y).min() ?? 0
    return CGRect(
      x: left, y: top, width: (corners.map(\.x).max() ?? left) - left,
      height: (corners.map(\.y).max() ?? top) - top)
  }

  private func point(_ x: Double, _ y: Double) -> CGPoint {
    let dx = (flipped ? Double(sourceWidth) - x : x) - Double(sourceWidth) / 2
    let dy = y - Double(sourceHeight) / 2
    return .init(
      x: (cosine * dx - sine * dy + Double(rotatedWidth) / 2) * Double(width)
        / Double(rotatedWidth),
      y: (sine * dx + cosine * dy + Double(rotatedHeight) / 2) * Double(height)
        / Double(rotatedHeight))
  }
}
