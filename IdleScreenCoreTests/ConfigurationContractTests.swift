import Foundation
import Testing
@testable import IdleScreenCore

@Suite("Versioned configuration contract")
struct ConfigurationContractTests {
    @Test("defaults are immediately readable by every process")
    func defaultConfiguration() {
        let configuration = IdleScreenConfiguration.default

        #expect(configuration.schemaVersion == IdleScreenConfiguration.currentSchemaVersion)
        #expect(configuration.revision == 0)
        #expect(configuration.source == .generative)
        #expect(configuration.appearance.glyphScale == 0.38)
        #expect(configuration.appearance.contrast == 0.58)
        #expect(configuration.display == .default)
        #expect(configuration.display.policy == .panorama)
    }

    @Test("configuration round-trips through the shared JSON store")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "configuration.json")
        let store = IdleScreenConfigurationStore(fileURL: url)
        let expected = IdleScreenConfiguration(
            schemaVersion: IdleScreenConfiguration.currentSchemaVersion,
            revision: 7,
            modifiedAt: Date(timeIntervalSince1970: 1_785_525_109),
            source: .camera,
            appearance: .init(glyphScale: 0.61, contrast: 0.72, palette: "Phosphor"),
            display: .init(
                policy: .focusDisplay,
                focalDisplayIdentifier: .init(rawValue: "opaque-display-a"),
                quietTreatment: .subdued,
                outerBoundaryBehavior: .drain,
                baseSeed: 42
            )
        )

        try store.write(expected)

        #expect(try store.read() == expected)
    }

    @Test("a future configuration version fails explicitly")
    func rejectsFutureSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "configuration.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        {"schemaVersion":999,"revision":1,"modifiedAt":"2026-07-31T12:00:00Z","source":"generative","appearance":{"glyphScale":0.38,"contrast":0.58,"palette":"Ember"}}
        """.utf8).write(to: url)

        let store = IdleScreenConfigurationStore(fileURL: url)

        #expect(throws: IdleScreenConfigurationStore.Error.unsupportedSchema(999)) {
            try store.read()
        }
    }

    @Test("schema six gains explicit Panorama defaults without changing visual settings")
    func migratesSchemaSixDisplayDefaults() throws {
        let payload = Data(#"""
        {
          "schemaVersion": 6,
          "revision": 19,
          "modifiedAt": "2026-08-08T20:00:00Z",
          "source": "generative",
          "appearance": {
            "glyphScale": 0.47,
            "contrast": 0.63,
            "palette": "Signal"
          }
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let configuration = try decoder.decode(
            IdleScreenConfiguration.self,
            from: payload
        )

        #expect(configuration.schemaVersion == 6)
        #expect(configuration.revision == 19)
        #expect(configuration.appearance.glyphScale == 0.47)
        #expect(configuration.appearance.palette == "Signal")
        #expect(configuration.display == .default)
    }

    @Test("display settings use stable versioned JSON names")
    func displaySettingsRoundTrip() throws {
        let settings = DisplaySceneSettings(
            policy: .perDisplay,
            focalDisplayIdentifier: .init(rawValue: "display:with punctuation"),
            quietTreatment: .black,
            outerBoundaryBehavior: .offWorld,
            baseSeed: UInt64.max
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        let payload = try #require(String(data: data, encoding: .utf8))

        #expect(payload.contains(#""policy":"perDisplay""#))
        #expect(payload.contains(#""quietTreatment":"black""#))
        #expect(payload.contains(#""outerBoundaryBehavior":"offWorld""#))
        #expect(try JSONDecoder().decode(DisplaySceneSettings.self, from: data) == settings)
    }
}
