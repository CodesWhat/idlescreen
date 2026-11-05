import SwiftUI

/// Instrument Serif for page headings, Instrument Sans for controls and text.
enum DesignFont {
  /// Page headline.
  static let headline: CGFloat = 28
  static let body: CGFloat = 13
  static let detail: CGFloat = 12
  static let caption: CGFloat = 11.5
  /// Eyebrows, the smallest size anywhere.
  static let eyebrow: CGFloat = 10

  /// Eyebrow tracking, .12em at 10 pt.
  static let eyebrowTracking: CGFloat = 1.2

  enum Weight { case regular, medium, semibold }

  /// Instrument Serif, reserved for page headings and the wordmark.
  static func display(_ size: CGFloat = headline) -> Font {
    DesignFontRegistry.isAvailable
      ? .custom(DesignFontRegistry.displayName, fixedSize: size)
      : .system(size: size, weight: .semibold)
  }

  static func headlineFont(_ size: CGFloat = headline) -> Font { display(size) }

  /// Instrument Sans for titles, body and detail.
  static func sans(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
    guard DesignFontRegistry.isAvailable else {
      return .system(
        size: size, weight: weight == .regular ? .regular : weight == .medium ? .medium : .semibold)
    }
    let name =
      weight == .regular
      ? "InstrumentSans-Regular"
      : weight == .medium ? "InstrumentSans-Medium" : "InstrumentSans-SemiBold"
    return .custom(name, fixedSize: size)
  }

  static func mono(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
    .system(
      size: size, weight: weight == .regular ? .regular : weight == .medium ? .medium : .semibold,
      design: .monospaced)
  }
}

extension View {
  /// Instrument Sans Medium 10, uppercase, .12em tracking, the third ink. Pass the text as written; the uppercase is applied here.
  func designEyebrow() -> some View {
    font(DesignFont.sans(DesignFont.eyebrow, .medium)).tracking(DesignFont.eyebrowTracking)
      .textCase(.uppercase)
      .foregroundStyle(DesignPalette.ink3)
  }
}
