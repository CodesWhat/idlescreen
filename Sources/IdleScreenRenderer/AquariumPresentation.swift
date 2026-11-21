import CoreGraphics
import Foundation

public enum IdleScreenAquariumFrameClock {
  public static func resolve(
    explicit: TimeInterval?, automatic: TimeInterval,
    settings: IdleScreenAquariumRenderSettings?, now: Date
  ) -> TimeInterval {
    let value = explicit ?? settings?.elapsed(at: now) ?? automatic
    return value.isFinite ? min(1_000_000_000_000, max(0, value)) : 0
  }
}

/// Fits one world into the entire logical scene before a display crops it.
/// View-local fitting would resize the same fish differently at panorama seams.
public struct IdleScreenAquariumFraming: Sendable {
  public let contentRect: CGRect
  public let columns: Int
  public let rows: Int
  public let worldWidth: Int
  private let viewport: IdleScreenRendererViewport

  public init(logicalSize: CGSize, viewport: IdleScreenRendererViewport, worldWidth: Int) {
    self.viewport = viewport.normalized
    self.worldWidth = min(1152, max(384, worldWidth))
    let size =
      logicalSize.width.isFinite && logicalSize.height.isFinite && logicalSize.width > 0
        && logicalSize.height > 0 ? logicalSize : CGSize(width: 384, height: 216)
    let aspect = max(
      0.1, min(12, (size.width / self.viewport.width) / (size.height / self.viewport.height)))
    let sourceAspect = Double(self.worldWidth) / 216
    if aspect > sourceAspect {
      let width = sourceAspect / aspect
      contentRect = CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    } else {
      let height = aspect / sourceAspect
      contentRect = CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
    }
    let sceneColumns = min(1152, max(96, Int((216 * aspect).rounded())))
    let sceneRows = min(432, max(48, Int((Double(sceneColumns) / aspect).rounded())))
    columns = max(1, Int((Double(sceneColumns) * self.viewport.width).rounded()))
    rows = max(1, Int((Double(sceneRows) * self.viewport.height).rounded()))
  }

  public func coordinate(u: Double, v: Double) -> SIMD2<Int>? {
    guard u.isFinite, v.isFinite else { return nil }
    let sceneU = viewport.x + u * viewport.width
    let sceneV = 1 - viewport.y - viewport.height + v * viewport.height
    let x = (sceneU - contentRect.minX) / contentRect.width
    let y = (sceneV - contentRect.minY) / contentRect.height
    guard x >= 0, x < 1, y >= 0, y < 1 else { return nil }
    return .init(min(worldWidth - 1, Int(x * Double(worldWidth))), min(215, Int(y * 216)))
  }
}
