import AppKit
import CoreText
import OSLog

/// Registers the bundled Instrument Serif and Instrument Sans for this process. Registration runs once, on first use or at launch, whichever
/// comes first. A failure is logged once and `DesignFont` falls back to the system fonts.
enum DesignFontRegistry {
  private final class BundleAnchor {}

  static let directory = "Fonts"
  static let displayName = "InstrumentSerif-Regular"
  static let textNames = [
    "InstrumentSans-Regular", "InstrumentSans-Medium", "InstrumentSans-SemiBold",
  ]

  private static let logger = Logger(subsystem: "com.idlescreen.app", category: "fonts")

  /// Whether every bundled face came up. Evaluated once, thread-safe by `static let`.
  static let isAvailable: Bool = {
    let bundle = Bundle(for: BundleAnchor.self)
    let urls = ["ttf", "otf"].flatMap {
      bundle.urls(forResourcesWithExtension: $0, subdirectory: directory) ?? []
    }
    for url in urls {
      var error: Unmanaged<CFError>?
      if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
        // Already registered is fine (a second registration in the same process).
        let code = error.map { CFErrorGetCode($0.takeUnretainedValue()) }
        if code != Int(CTFontManagerError.alreadyRegistered.rawValue) {
          logger.error("font registration failed for \(url.lastPathComponent, privacy: .public)")
        }
      }
    }
    let complete = ([displayName] + textNames).allSatisfy { NSFont(name: $0, size: 12) != nil }
    if !complete {
      logger.error("bundled fonts incomplete; falling back to system fonts")
    }
    return complete
  }()

  /// Call at launch so the first draw never waits on registration.
  static func registerAtLaunch() {
    _ = isAvailable
  }
}
