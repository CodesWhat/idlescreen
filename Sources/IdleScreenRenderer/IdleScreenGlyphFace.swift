import CoreText
import Foundation

/// The typeface behind the glyph atlas.
///
/// Departure Mono ships inside this framework so a screen saver extension
/// never depends on the companion app having registered it. If the font is
/// missing or fails to load, the atlas falls back to Menlo.
struct IdleScreenGlyphFace {
  static let departureMonoFileName = "DepartureMono-Regular"
  static let departureMonoRamp = Array(" .,:;+*#%@")
  static let menloRamp = Array(" .:-=+*#%@")

  let descriptor: CTFontDescriptor
  let ramp: [Character]
  let isDepartureMono: Bool

  static func departureMonoURL(in bundle: Bundle? = nil) -> URL? {
    let bundle = bundle ?? Bundle(for: FrameworkAnchor.self)
    return bundle.url(
      forResource: departureMonoFileName,
      withExtension: "otf"
    )
  }

  static func resolve(bundle: Bundle? = nil) -> IdleScreenGlyphFace {
    if let url = departureMonoURL(in: bundle),
      let descriptors = CTFontManagerCreateFontDescriptorsFromURL(
        url as CFURL
      ) as? [CTFontDescriptor],
      let descriptor = descriptors.first
    {
      return IdleScreenGlyphFace(
        descriptor: descriptor,
        ramp: departureMonoRamp,
        isDepartureMono: true
      )
    }
    return IdleScreenGlyphFace(
      descriptor: CTFontDescriptorCreateWithNameAndSize(
        "Menlo" as CFString,
        0
      ),
      ramp: menloRamp,
      isDepartureMono: false
    )
  }

  private final class FrameworkAnchor {}
}
