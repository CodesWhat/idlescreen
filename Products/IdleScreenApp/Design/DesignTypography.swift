import SwiftUI

/// The companion-app type scale. Two bundled faces, both OFL: Departure Mono for the display headings, Inter for everything else.
/// Both fall back to the system fonts if they fail to register. Readouts such as paths stay in the system monospace. 10 pt is
/// the floor anywhere in the app.
enum DesignFont {
  /// Page headline. Departure Mono is drawn on an 11 px grid, so it sits on multiples of 11.
  static let headline: CGFloat = 22
  static let body: CGFloat = 13
  static let detail: CGFloat = 12
  static let caption: CGFloat = 11.5
  /// Eyebrows, the smallest size anywhere.
  static let eyebrow: CGFloat = 10

  /// Eyebrow tracking, .12em at 10 pt.
  static let eyebrowTracking: CGFloat = 1.2

  enum Weight { case regular, medium, semibold }

  /// Departure Mono, one weight. Headings and large figures only.
  static func display(_ size: CGFloat = headline) -> Font {
    DesignFontRegistry.isAvailable
      ? .custom(DesignFontRegistry.displayName, fixedSize: size)
      : .system(size: size, weight: .semibold)
  }

  static func headlineFont(_ size: CGFloat = headline) -> Font { display(size) }

  /// Inter for titles, body and detail.
  static func sans(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
    guard DesignFontRegistry.isAvailable else {
      return .system(
        size: size, weight: weight == .regular ? .regular : weight == .medium ? .medium : .semibold)
    }
    let name =
      weight == .regular ? "Inter-Regular" : weight == .medium ? "Inter-Medium" : "Inter-SemiBold"
    return .custom(name, fixedSize: size)
  }

  static func mono(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
    .system(
      size: size, weight: weight == .regular ? .regular : weight == .medium ? .medium : .semibold,
      design: .monospaced)
  }
}

extension View {
  /// Inter Medium 10, uppercase, .12em tracking, the third ink. Pass the text as written; the uppercase is applied here.
  func designEyebrow() -> some View {
    font(DesignFont.sans(DesignFont.eyebrow, .medium)).tracking(DesignFont.eyebrowTracking)
      .textCase(.uppercase)
      .foregroundStyle(DesignPalette.ink3)
  }
}
