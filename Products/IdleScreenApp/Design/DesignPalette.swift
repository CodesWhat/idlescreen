import AppKit
import SwiftUI

/// IdleScreen's companion-app colours. Every token is a light/dark `NSColor(name:)` pair with an Increase Contrast variant, so a
/// view never checks the colour scheme. `DesignPalette.bg` is a SwiftUI `Color`; `DesignPalette.NS.bg` is the same colour as an
/// `NSColor` for AppKit code.
///
/// Identity: the accent is the phosphor green of the app icon's CRT glass (about #5CE07C at its brightest), used as a fill only.
/// Text and strokes in the accent hue use `accentMark`, which is darker in light mode so it clears the contrast floor.
///
/// Contrast, measured as WCAG 2.x ratios (4.5:1 text, 3:1 non-text):
///   accent #5CE07C       with onAccent #0B2412 9.7:1 (button labels); on dark bg #1F1F21 9.7:1, on dark surface #2A2A2C 8.5:1;
///                        on white only 1.7:1, so a light-mode accent shape that must be seen carries an accentMark edge
///   accentMark light     #0F6B2E on white 6.6:1, on bg #F3F3F5 6.0:1 (text and strokes)
///   accentMark dark      #5CE07C, same ratios as the accent fill on the dark ground
///   ink light #1D1D1F    on bg 15.2:1;  ink2 #5C5C61 on bg 6.0:1;  ink3 #6B6B70 on bg 4.8:1, on white 5.3:1
///   ink2 dark #B0B0B5    on dark surface 6.6:1;  ink3 #9A9A9F on dark surface 5.1:1
///   success light #1E7A3C on bg 4.9:1, dark #4CC76A on surface 6.6:1
///   warning light #A85A00 on bg 4.6:1, dark #F19A4B on surface 6.5:1
///   danger  light #D70015 on bg 4.9:1, dark #FF564C on surface 4.6:1
/// hair and hair2 are dividers and card edges. With Increase Contrast on they step up to about 3:1 against their ground, and the
/// secondary inks step up further.
enum DesignPalette {
  // MARK: Adaptive colours

  enum NS {
    static let bg = pair(light: 0xF3F3F5, dark: 0x1F1F21)
    static let surface = pair(light: 0xFFFFFF, dark: 0x2A2A2C)
    static let ink = pair(light: 0x1D1D1F, dark: 0xF2F2F2)
    static let ink2 = pair(
      light: 0x5C5C61, dark: 0xB0B0B5, contrastLight: 0x3A3A3E, contrastDark: 0xD8D8DC)
    static let ink3 = pair(
      light: 0x6B6B70, dark: 0x9A9A9F, contrastLight: 0x45454A, contrastDark: 0xC8C8CC)
    static let hair = pair(
      light: (0, 0, 0, 0.12), dark: (1, 1, 1, 0.14), contrastLight: (0, 0, 0, 0.45),
      contrastDark: (1, 1, 1, 0.5))
    static let hair2 = pair(
      light: (0, 0, 0, 0.07), dark: (1, 1, 1, 0.08), contrastLight: (0, 0, 0, 0.3),
      contrastDark: (1, 1, 1, 0.34))
    /// Phosphor green, a fill only. See the contrast notes above.
    static let accent = pair(light: 0x5CE07C, dark: 0x5CE07C)
    /// A quiet accent wash for selected and highlighted cells. Never carries text on its own.
    static let accentSoft = pair(
      light: (0x5C, 0xE0, 0x7C, 0.28), dark: (0x5C, 0xE0, 0x7C, 0.16), bytes: true)
    /// Non-text accent: edges, dots, strokes, and accent-hue text.
    static let accentMark = pair(light: 0x0F6B2E, dark: 0x5CE07C)
    static let onAccent = pair(light: 0x0B2412, dark: 0x0B2412)
    static let success = pair(light: 0x1E7A3C, dark: 0x4CC76A)
    /// Warnings only. Pair it with a symbol and a word.
    static let warning = pair(light: 0xA85A00, dark: 0xF19A4B)
    static let danger = pair(light: 0xD70015, dark: 0xFF564C)
    static let sel = pair(light: (0, 0, 0, 0.08), dark: (1, 1, 1, 0.10))
    static let track = pair(light: 0xD9D9DE, dark: 0x3C3C40)
    /// The ground under saver previews. The saver draws on black in both appearances, so this does not adapt.
    static let previewGround = pair(light: 0x0B0F0C, dark: 0x0B0F0C)
  }

  static let bg = Color(nsColor: NS.bg)
  static let surface = Color(nsColor: NS.surface)
  static let ink = Color(nsColor: NS.ink)
  static let ink2 = Color(nsColor: NS.ink2)
  static let ink3 = Color(nsColor: NS.ink3)
  static let hair = Color(nsColor: NS.hair)
  static let hair2 = Color(nsColor: NS.hair2)
  static let accent = Color(nsColor: NS.accent)
  static let accentSoft = Color(nsColor: NS.accentSoft)
  static let accentMark = Color(nsColor: NS.accentMark)
  static let onAccent = Color(nsColor: NS.onAccent)
  static let success = Color(nsColor: NS.success)
  static let warning = Color(nsColor: NS.warning)
  static let danger = Color(nsColor: NS.danger)
  static let sel = Color(nsColor: NS.sel)
  static let track = Color(nsColor: NS.track)
  static let previewGround = Color(nsColor: NS.previewGround)

  /// The card drop shadow.
  static func shadowColor(dark: Bool) -> Color { Color.black.opacity(dark ? 0.3 : 0.05) }

  // MARK: Builders

  private typealias RGBA = (CGFloat, CGFloat, CGFloat, CGFloat)

  private static func hex(_ value: Int) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  private static func rgba(_ value: RGBA, bytes: Bool) -> NSColor {
    let scale: CGFloat = bytes ? 255 : 1
    return NSColor(
      srgbRed: value.0 / scale, green: value.1 / scale, blue: value.2 / scale, alpha: value.3)
  }

  private static func pair(
    light: Int, dark: Int, contrastLight: Int? = nil, contrastDark: Int? = nil
  ) -> NSColor {
    let (l, d) = (hex(light), hex(dark))
    let (cl, cd) = (contrastLight.map(hex) ?? l, contrastDark.map(hex) ?? d)
    return NSColor(name: nil) { appearance in
      let high = appearance.isHighContrast
      return appearance.isDarkAqua ? (high ? cd : d) : (high ? cl : l)
    }
  }

  private static func pair(
    light: RGBA, dark: RGBA, contrastLight: RGBA? = nil, contrastDark: RGBA? = nil,
    bytes: Bool = false
  ) -> NSColor {
    let (l, d) = (rgba(light, bytes: bytes), rgba(dark, bytes: bytes))
    let (cl, cd) = (
      contrastLight.map { rgba($0, bytes: bytes) } ?? l,
      contrastDark.map { rgba($0, bytes: bytes) } ?? d
    )
    return NSColor(name: nil) { appearance in
      let high = appearance.isHighContrast
      return appearance.isDarkAqua ? (high ? cd : d) : (high ? cl : l)
    }
  }
}

extension NSAppearance {
  private static let variants: [NSAppearance.Name] = [
    .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua,
  ]

  /// The closest of the four Aqua variants, high-contrast ones first so they are not collapsed into their base.
  private var variant: NSAppearance.Name? {
    if Self.variants.contains(name) { return name }
    return bestMatch(from: Self.variants)
  }

  var isDarkAqua: Bool {
    variant == .darkAqua || variant == .accessibilityHighContrastDarkAqua
  }

  /// Increase Contrast, read from the appearance the colour is resolved for so it needs no main-actor state and follows live changes.
  var isHighContrast: Bool {
    variant == .accessibilityHighContrastAqua || variant == .accessibilityHighContrastDarkAqua
  }
}
