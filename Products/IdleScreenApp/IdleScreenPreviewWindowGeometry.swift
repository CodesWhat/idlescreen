import CoreGraphics

/// The window resizes freely; only the renderer surface follows the selected display.
enum IdleScreenPreviewWindowGeometry {
  static let absoluteMinimumContentSize = CGSize(width: 900, height: 600)

  static func minimumContentSize(previewAspectRatio: CGFloat) -> CGSize {
    absoluteMinimumContentSize
  }

  static func constrainedContentSize(
    proposed: CGSize, current: CGSize, previewAspectRatio: CGFloat
  ) -> CGSize {
    normalizedContentSize(
      current: CGSize(
        width: validLength(proposed.width) ? proposed.width : current.width,
        height: validLength(proposed.height) ? proposed.height : current.height),
      previewAspectRatio: previewAspectRatio
    )
  }

  static func normalizedContentSize(
    current: CGSize, previewAspectRatio: CGFloat, availableSize: CGSize? = nil
  ) -> CGSize {
    let minimum = absoluteMinimumContentSize
    let proposed = CGSize(
      width: validLength(current.width) ? current.width : minimum.width,
      height: validLength(current.height) ? current.height : minimum.height)
    let normalized = CGSize(
      width: max(minimum.width, proposed.width), height: max(minimum.height, proposed.height))
    guard let availableSize, validSize(availableSize) else { return normalized }
    return CGSize(
      width: max(minimum.width, min(normalized.width, availableSize.width)),
      height: max(minimum.height, min(normalized.height, availableSize.height)))
  }

  static func fittedPreviewSize(inside availableSize: CGSize, aspectRatio: CGFloat) -> CGSize {
    guard validSize(availableSize), aspectRatio.isFinite, aspectRatio > 0 else { return .zero }
    let width = min(availableSize.width, availableSize.height * aspectRatio)
    return CGSize(width: width, height: width / aspectRatio)
  }

  private static func validLength(_ value: CGFloat) -> Bool {
    value.isFinite && value > 0
  }

  private static func validSize(_ value: CGSize) -> Bool {
    value.width.isFinite && value.height.isFinite && value.width > 0 && value.height > 0
  }
}
