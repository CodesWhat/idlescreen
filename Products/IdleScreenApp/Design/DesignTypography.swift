import SwiftUI

/// The companion-app type scale. System fonts only, nothing bundled: SF for text, SF Mono for the eyebrow and readouts, which
/// carries the CRT identity. 10 pt is the floor anywhere in the app.
enum DesignFont {
  /// Page headline.
  static let headline: CGFloat = 28
  static let body: CGFloat = 13
  static let detail: CGFloat = 12
  static let caption: CGFloat = 11.5
  /// Eyebrows and readouts, mono. Also the smallest size anywhere.
  static let eyebrow: CGFloat = 10

  /// Eyebrow tracking, .12em at 10 pt.
  static let eyebrowTracking: CGFloat = 1.2

  enum Weight { case regular, medium, semibold }

  static func headlineFont(_ size: CGFloat = headline) -> Font {
    .system(size: size, weight: .semibold)
  }

  static func sans(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
    .system(
      size: size, weight: weight == .regular ? .regular : weight == .medium ? .medium : .semibold)
  }

  static func mono(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
    .system(
      size: size, weight: weight == .regular ? .regular : weight == .medium ? .medium : .semibold,
      design: .monospaced)
  }
}

extension View {
  /// SF Mono 10, uppercase, .12em tracking, the third ink. Pass the text as written; the uppercase is applied here.
  func designEyebrow() -> some View {
    font(DesignFont.mono(DesignFont.eyebrow, .medium)).tracking(DesignFont.eyebrowTracking)
      .textCase(.uppercase)
      .foregroundStyle(DesignPalette.ink3)
  }
}
