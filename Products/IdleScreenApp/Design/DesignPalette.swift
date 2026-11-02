import AppKit
import SwiftUI

/// IdleScreen's companion-app colours. Every token is a light/dark `NSColor(name:)` pair with an Increase Contrast variant, so a
/// view never checks the colour scheme. `DesignPalette.bg` is a SwiftUI `Color`; `DesignPalette.NS.bg` is the same colour as an
/// `NSColor` for AppKit code.
///
/// Identity (blueprint): a spec sheet. Off-white (light) or graphite (dark) ground with a faint dot grid, square corners, ASCII rules
/// and corner ticks instead of shadows, mono for labels and values, phosphor green used sparingly. The accent is the phosphor green of the app icon's CRT glass (about #5CE07C at its brightest), used as a fill only.
/// Text and strokes in the accent hue use `accentMark`, which is darker in light mode so it clears the contrast floor.
///
/// Contrast, measured as WCAG 2.x ratios (4.5:1 text, 3:1 non-text). Ratios are on bg / surface:
///   accent #5CE07C       with onAccent #0B2412 9.7:1 (button labels); on dark 10.6 / 9.7;
///                        on light only ~1.6:1, so a light-mode accent shape that must be seen carries an accentMark edge
///   accentMark light     #0F6B2E 6.0 / 6.4 (text and strokes);  dark #5CE07C 10.6 / 9.7
///   ink   light #111418  16.7 / 17.8;   dark #E8ECE9 15.1 / 13.7
///   ink2  light #4A4F55  7.5 / 8.0;     dark #A9B0B5 8.2 / 7.5
///   ink3  light #5C636A  5.5 / 5.9;     dark #8F979C 6.1 / 5.5
///   success light #1E7A3C 4.9 / 5.2;    dark #4CC76A 8.3 / 7.6
///   warning light #A85A00 4.6 / 4.9;    dark #F19A4B 8.1 / 7.4
///   danger  light #D70015 4.9 / 5.2;    dark #FF564C 5.7 / 5.2
/// Status chips put the word in ink and the glyph in the status hue; the chip edge in that hue is non-text and clears 3:1 on
/// surface in every row above except the accent in light mode, which uses accentMark.
/// hair and hair2 are dividers and card edges. With Increase Contrast on they step up to about 3:1 against their ground, and the
/// secondary inks step up further.
enum DesignPalette {
  // MARK: Adaptive colours

  enum NS {
    static let bg = pair(light: 0xF4F4F0, dark: 0x151718)
    static let surface = pair(light: 0xFBFBF8, dark: 0x1D2022)
    static let ink = pair(light: 0x111418, dark: 0xE8ECE9)
    static let ink2 = pair(
      light: 0x4A4F55, dark: 0xA9B0B5, contrastLight: 0x30343A, contrastDark: 0xD4DADD)
    static let ink3 = pair(
      light: 0x5C636A, dark: 0x8F979C, contrastLight: 0x3C4248, contrastDark: 0xC4CBCF)
    static let hair = pair(
      light: (0, 0, 0, 0.22), dark: (1, 1, 1, 0.20), contrastLight: (0, 0, 0, 0.45),
      contrastDark: (1, 1, 1, 0.5))
    static let hair2 = pair(
      light: (0, 0, 0, 0.14), dark: (1, 1, 1, 0.12), contrastLight: (0, 0, 0, 0.3),
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
    static let track = pair(light: 0xD6D8D4, dark: 0x363B3E)
    /// The ground under saver previews. The saver draws on black in both appearances, so this does not adapt.
    /// The dot grid on the page ground. Decorative, so it carries no contrast requirement; text sits on opaque surfaces or clear ground.
    static let grid = pair(
      light: (0, 0, 0, 0.13), dark: (1, 1, 1, 0.09), contrastLight: (0, 0, 0, 0.0),
      contrastDark: (1, 1, 1, 0.0))
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
  static let grid = Color(nsColor: NS.grid)
  static let previewGround = Color(nsColor: NS.previewGround)

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
  static let variants: [NSAppearance.Name] = [
    .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua,
  ]

  /// The closest of the four Aqua variants, high-contrast ones first so they are not collapsed into their base.
  var variant: NSAppearance.Name? {
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
