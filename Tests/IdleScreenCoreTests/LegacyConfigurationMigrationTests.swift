import Foundation
import Testing

@testable import IdleScreenCore

@Suite("Legacy configuration migration")
struct LegacyConfigurationMigrationTests {
  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func legacyJSON(
    animationMode: String = "plasma",
    fontSize: Double = 14,
    contrast: Double = 1.5,
    colorMode: String = "uniform",
    colorRampPreset: String = "classicTerminal",
    gradientPreset: String = "matrixGreen",
    textColor: String = "[0, 1, 0, 1]",
    renderQuality: String = "auto",
    preferredCameraID: String = "auto",
    mirror: Bool = true
  ) -> String {
    """
    {"fontSize":\(fontSize),"textColorRGBA":\(textColor),"characterSetPreset":"ascii",
     "colorMode":"\(colorMode)","colorRampPreset":"\(colorRampPreset)",
     "animationMode":"\(animationMode)","contrast":\(contrast),
     "gradientPreset":"\(gradientPreset)","autoCycleInterval":12,"patternSpeed":2,
     "patternScale":1.5,"matrixTrailLength":0.8,"rainbowAmplitude":0.3,"fireDecay":0.2,
     "patternIntensity":0.9,"patternTrailing":0.1,"renderQuality":"\(renderQuality)",
     "preferredCameraID":"\(preferredCameraID)","mirrorCamera":\(mirror)}
    """
  }

  @discardableResult
  private func write(
    _ text: String,
    named name: String,
    in directory: URL,
    modifiedAt: Date? = nil
  ) throws -> URL {
    let url = directory.appending(path: name)
    try Data(text.utf8).write(to: url)
    if let modifiedAt {
      try FileManager.default.setAttributes(
        [.modificationDate: modifiedAt],
        ofItemAtPath: url.path
      )
    }
    return url
  }

  @Test("no candidate files yields nil, not an error")
  func noFiles() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = directory.appending(path: "missing.json")

    #expect(try IdleScreenLegacyConfigurationMigration.read(from: [missing]) == nil)
    #expect(try IdleScreenLegacyConfigurationMigration.read(from: []) == nil)
  }

  @Test("default candidate locations are the two prior saver paths")
  func defaultURLs() {
    let urls = IdleScreenLegacyConfigurationMigration.defaultFileURLs()

    #expect(urls.count == 2)
    #expect(urls.allSatisfy { $0.lastPathComponent == "config.json" })
    #expect(urls[0].path.hasSuffix("Library/Application Support/Idlescreen/config.json"))
    #expect(urls[1].path.contains("com.apple.ScreenSaver.Engine.legacyScreenSaver"))
  }

  @Test("a full legacy file maps onto the modern configuration")
  func fullMapping() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let url = try write(
      legacyJSON(
        animationMode: "matrixRain",
        fontSize: 14,
        contrast: 1.5,
        renderQuality: "eco",
        preferredCameraID: "camera-7",
        mirror: false
      ),
      named: "config.json",
      in: directory,
      modifiedAt: modifiedAt
    )

    let configuration = try #require(
      try IdleScreenLegacyConfigurationMigration.read(from: [url])
    )

    #expect(configuration.source == .generative)
    #expect(configuration.appearance.glyphScale == 0.5)
    #expect(configuration.appearance.contrast == 0.5)
    #expect(configuration.creative.pattern == .matrixRain)
    #expect(configuration.creative.settings.speed == 2)
    #expect(configuration.creative.settings.scale == 1.5)
    #expect(configuration.creative.settings.autoCycleInterval == 12)
    #expect(configuration.creative.settings.qualityLevel == 0.4)
    #expect(configuration.camera.preferredDeviceIdentifier == "camera-7")
    #expect(configuration.camera.isMirrored == false)
    #expect(configuration.revision == 1)
    #expect(abs(configuration.modifiedAt.timeIntervalSince(modifiedAt)) < 1)
  }

  @Test("legacy camera mode becomes the camera source on the Perlin pattern")
  func cameraMode() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try write(legacyJSON(animationMode: "camera"), named: "config.json", in: directory)

    let configuration = try #require(
      try IdleScreenLegacyConfigurationMigration.read(from: [url])
    )

    #expect(configuration.source == .camera)
    #expect(configuration.creative.pattern == .perlin)
  }

  @Test("unknown animation modes fall back to generative Auto Cycle")
  func unknownMode() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try write(legacyJSON(animationMode: "bogus"), named: "config.json", in: directory)

    let configuration = try #require(
      try IdleScreenLegacyConfigurationMigration.read(from: [url])
    )

    #expect(configuration.source == .generative)
    #expect(configuration.creative.pattern == .autoCycle)
  }

  @Test("render quality names map to quality levels")
  func qualityLevels() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let expectations: [(String, Double)] = [
      ("eco", 0.4),
      ("performance", 1),
      ("auto", 0.7),
      ("balanced", 0.7),
      ("mystery", IdleScreenCreativeSettings.defaultQualityLevel),
    ]
    for (quality, level) in expectations {
      let url = try write(
        legacyJSON(renderQuality: quality),
        named: "quality-\(quality).json",
        in: directory
      )
      let configuration = try #require(
        try IdleScreenLegacyConfigurationMigration.read(from: [url])
      )
      #expect(configuration.creative.settings.qualityLevel == level, "quality \(quality)")
    }
  }

  @Test("palette selection follows the colour mode, then the text colour")
  func paletteSelection() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    func palette(_ json: String, _ name: String) throws -> String {
      let url = try write(json, named: name, in: directory)
      return try #require(
        try IdleScreenLegacyConfigurationMigration.read(from: [url])
      ).appearance.palette
    }

    #expect(
      try palette(legacyJSON(colorMode: "proceduralGradient", gradientPreset: "amber"), "a.json")
        == "Ember"
    )
    #expect(
      try palette(legacyJSON(colorMode: "brightnessRamp", colorRampPreset: "cyberpunk"), "b.json")
        == "Blueprint"
    )
    // Uniform colours resolve to the nearest published palette.
    #expect(try palette(legacyJSON(textColor: "[1, 0.2, 0.1, 1]"), "c.json") == "Signal")
    #expect(try palette(legacyJSON(textColor: "[1, 0.95, 0.8, 1]"), "d.json") == "Ivory")
    #expect(try palette(legacyJSON(textColor: "[0.3, 0.8, 1, 1]"), "e.json") == "Blueprint")
    #expect(try palette(legacyJSON(textColor: "[0.3, 1, 0.4, 1]"), "f.json") == "Phosphor")
    // Out-of-range channels are clamped before matching.
    #expect(try palette(legacyJSON(textColor: "[9, -4, -4, 1]"), "g.json") == "Signal")
    // An unmapped gradient on a procedural-gradient file uses the text colour.
    #expect(
      try palette(
        legacyJSON(
          colorMode: "proceduralGradient", gradientPreset: "nope", textColor: "[1, 0.75, 0.42, 1]"),
        "h.json"
      ) == "Ember"
    )
    // Too few colour channels fall back to the preset tables, then Phosphor.
    #expect(try palette(legacyJSON(textColor: "[1]"), "i.json") == "Phosphor")
    #expect(
      try palette(
        legacyJSON(colorRampPreset: "amberMonochrome", gradientPreset: "unknown", textColor: "[]"),
        "j.json")
        == "Ember"
    )
    #expect(
      try palette(
        legacyJSON(colorRampPreset: "unknown", gradientPreset: "unknown", textColor: "[]"), "k.json"
      )
        == "Phosphor"
    )
  }

  @Test("glyph scale and contrast are clamped into the modern range")
  func clampsRanges() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try write(
      legacyJSON(fontSize: 40, contrast: -2),
      named: "config.json",
      in: directory
    )

    let configuration = try #require(
      try IdleScreenLegacyConfigurationMigration.read(from: [url])
    )

    #expect(configuration.appearance.glyphScale == 1)
    #expect(configuration.appearance.contrast == 0)
  }

  @Test("missing legacy keys take their documented defaults")
  func decodesDefaults() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try write("{}", named: "config.json", in: directory)

    let configuration = try #require(
      try IdleScreenLegacyConfigurationMigration.read(from: [url])
    )

    #expect(configuration.source == .generative)
    #expect(configuration.creative.pattern == .autoCycle)
    #expect(configuration.appearance.glyphScale == (12.0 - 8) / 12)
    #expect(configuration.appearance.contrast == 1.0 / 3)
    #expect(configuration.appearance.palette == "Phosphor")
    #expect(configuration.camera.isMirrored == true)
    #expect(configuration.camera.preferredDeviceIdentifier == nil)
    #expect(
      configuration.creative.settings.autoCycleInterval
        == IdleScreenCreativeSettings.defaultAutoCycleInterval
    )
  }

  @Test("an invalid preferred camera identifier is dropped")
  func invalidPreferredCamera() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try write(
      legacyJSON(preferredCameraID: "bad\\u0007id"),
      named: "config.json",
      in: directory
    )

    let configuration = try #require(
      try IdleScreenLegacyConfigurationMigration.read(from: [url])
    )

    #expect(configuration.camera.preferredDeviceIdentifier == nil)
  }

  @Test("the newest readable mirror wins and broken newer mirrors are skipped")
  func newestReadableWins() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = try write(
      legacyJSON(animationMode: "plasma"),
      named: "old.json",
      in: directory,
      modifiedAt: Date(timeIntervalSince1970: 1_000_000)
    )
    let newer = try write(
      legacyJSON(animationMode: "aurora"),
      named: "newer.json",
      in: directory,
      modifiedAt: Date(timeIntervalSince1970: 2_000_000)
    )
    let broken = try write(
      "not json",
      named: "broken.json",
      in: directory,
      modifiedAt: Date(timeIntervalSince1970: 3_000_000)
    )

    let configuration = try #require(
      try IdleScreenLegacyConfigurationMigration.read(from: [old, broken, newer, newer])
    )

    #expect(configuration.creative.pattern == .aurora)
  }

  @Test("equal timestamps break ties by path")
  func tieBreaksByPath() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stamp = Date(timeIntervalSince1970: 1_500_000)
    let b = try write(
      legacyJSON(animationMode: "warp"), named: "b.json", in: directory, modifiedAt: stamp)
    let a = try write(
      legacyJSON(animationMode: "pulse"), named: "a.json", in: directory, modifiedAt: stamp)

    let configuration = try #require(
      try IdleScreenLegacyConfigurationMigration.read(from: [b, a])
    )

    #expect(configuration.creative.pattern == .pulse)
  }

  @Test("existing but unusable files throw and are listed")
  func unusableFilesThrow() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let garbage = try write("not json", named: "garbage.json", in: directory)
    let empty = try write("", named: "empty.json", in: directory)
    let target = try write(legacyJSON(), named: "target.json", in: directory)
    let link = directory.appending(path: "link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let oversized = try write(
      String(repeating: " ", count: 1_048_577),
      named: "huge.json",
      in: directory
    )

    let candidates = [garbage, empty, link, oversized]
    do {
      _ = try IdleScreenLegacyConfigurationMigration.read(from: candidates)
      Issue.record("expected the import to fail")
    } catch let error as IdleScreenLegacyConfigurationMigration.Error {
      guard case .noUsableLegacyConfiguration(let paths) = error else {
        Issue.record("unexpected case")
        return
      }
      #expect(paths == candidates.map { $0.standardizedFileURL.path })
      #expect(error.errorDescription?.contains("left unchanged") == true)
      #expect(error.errorDescription?.contains(garbage.standardizedFileURL.path) == true)
    }
  }

  @Test("the store imports legacy data only when no modern file exists")
  func storeImport() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = try write(legacyJSON(animationMode: "ripple"), named: "legacy.json", in: directory)
    let store = IdleScreenConfigurationStore(fileURL: directory.appending(path: "modern.json"))

    let imported = try #require(
      try store.read(importingLegacyConfigurationAt: [legacy])
    )
    #expect(imported.creative.pattern == .ripple)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

    var modern = IdleScreenConfiguration.default
    modern.revision = 4
    try store.write(modern)
    let preferred = try #require(
      try store.read(importingLegacyConfigurationAt: [legacy])
    )
    #expect(preferred.revision == 4)
    #expect(preferred.creative.pattern == IdleScreenConfiguration.default.creative.pattern)
  }

  @Test("the store refuses to write a future schema")
  func storeRejectsFutureWrite() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IdleScreenConfigurationStore(fileURL: directory.appending(path: "modern.json"))
    var future = IdleScreenConfiguration.default
    future.schemaVersion = IdleScreenConfiguration.currentSchemaVersion + 1

    #expect(throws: IdleScreenConfigurationStore.Error.unsupportedSchema(future.schemaVersion)) {
      try store.write(future)
    }
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
  }

  @Test("the legacy source retires Hybrid but rejects unknown values")
  func sourceDecoding() throws {
    func decode(_ raw: String) throws -> IdleScreenSource {
      try JSONDecoder().decode([IdleScreenSource].self, from: Data("[\"\(raw)\"]".utf8))[0]
    }
    #expect(try decode("hybrid") == .generative)
    #expect(try decode("camera") == .camera)
    #expect(throws: DecodingError.self) { try decode("holographic") }
    #expect(
      String(decoding: try JSONEncoder().encode([IdleScreenSource.camera]), as: UTF8.self)
        == "[\"camera\"]"
    )
  }
}
