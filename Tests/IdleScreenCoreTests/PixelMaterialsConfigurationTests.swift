import Foundation
import Testing
@testable import IdleScreenCore

@Suite("Pixel Materials configuration")
struct PixelMaterialsConfigurationTests {
    @Test("current schema retains the bounded deterministic materials default")
    func defaults() {
        let configuration = IdleScreenConfiguration.default

        #expect(IdleScreenConfiguration.currentSchemaVersion == 9)
        #expect(configuration.materials == .default)
        #expect(configuration.materials.schemaVersion == 1)
        #expect(configuration.materials.material == .water)
        #expect(configuration.materials.terrainFamily == .watershed)
        #expect(configuration.materials.seed != 0)
        #expect(configuration.materials.basinCount >= 2)
        #expect(configuration.materials.phaseDurations.total > 0)
    }

    @Test("all persisted material controls round-trip with stable names")
    func roundTrip() throws {
        let expected = IdleScreenPixelMaterialsConfiguration(
            material: .mixed,
            terrainFamily: .terraces,
            seed: 0xC0FFEE,
            basinCount: 4,
            basinDepth: 9,
            minimumBasinCapacity: 48,
            channelConnectivity: 0.8,
            channelWidth: 3,
            rockRatio: 0.7,
            soilRatio: 0.3,
            emitterCount: 2,
            emitterPosition: 0.25,
            emitterWidth: 4,
            emitterRate: 3,
            gravity: 0.9,
            cellScale: 0.75,
            waterLateralFlow: 0.8,
            waterEqualization: 0.6,
            waterPressure: 0.4,
            spillRate: 0.7,
            drainRate: 0.2,
            evaporationRate: 0.01,
            obstacleDensity: 0.15,
            palette: .tidal,
            persistence: 0.9,
            phaseDurations: .init(
                quiet: 1,
                filling: 12,
                settled: 4,
                draining: 3
            ),
            regenerationCadence: 20
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(expected)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains(#""material":"mixed""#))
        #expect(json.contains(#""terrainFamily":"terraces""#))
        #expect(json.contains(#""palette":"tidal""#))
        #expect(try JSONDecoder().decode(
            IdleScreenPixelMaterialsConfiguration.self,
            from: data
        ) == expected)
    }

    @Test("schema seven gains materials without changing its saved visual state")
    func migratesSchemaSeven() throws {
        let payload = Data(#"""
        {
          "schemaVersion": 7,
          "revision": 21,
          "modifiedAt": "2026-08-09T12:00:00Z",
          "source": "generative",
          "appearance": {
            "glyphScale": 0.44,
            "contrast": 0.67,
            "palette": "Phosphor"
          },
          "creative": {
            "pattern": "terrain",
            "settings": {}
          },
          "display": {
            "schemaVersion": 1,
            "policy": "panorama",
            "quietTreatment": "subdued",
            "outerBoundaryBehavior": "wall",
            "baseSeed": 33
          }
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let configuration = try decoder.decode(
            IdleScreenConfiguration.self,
            from: payload
        )

        #expect(configuration.schemaVersion == 7)
        #expect(configuration.appearance.palette == "Phosphor")
        #expect(configuration.creative.pattern == .terrain)
        #expect(configuration.materials == .default)
    }

    @Test("normalization bounds adversarial material controls")
    func normalization() {
        let normalized = IdleScreenPixelMaterialsConfiguration(
            material: .sand,
            terrainFamily: .caverns,
            seed: 0,
            basinCount: -4,
            basinDepth: .max,
            minimumBasinCapacity: -1,
            channelConnectivity: .nan,
            channelWidth: 99,
            rockRatio: -1,
            soilRatio: 9,
            emitterCount: 99,
            emitterPosition: .infinity,
            emitterWidth: 0,
            emitterRate: 99,
            gravity: -.infinity,
            cellScale: 0,
            waterLateralFlow: 9,
            waterEqualization: -1,
            waterPressure: .nan,
            spillRate: 9,
            drainRate: -1,
            evaporationRate: .nan,
            obstacleDensity: 9,
            palette: .monochrome,
            persistence: -1,
            phaseDurations: .init(
                quiet: -1,
                filling: .infinity,
                settled: 0,
                draining: .nan
            ),
            regenerationCadence: 0
        )

        #expect(normalized.seed != 0)
        #expect((2...8).contains(normalized.basinCount))
        #expect((3...24).contains(normalized.basinDepth))
        #expect((8...4096).contains(normalized.minimumBasinCapacity))
        #expect((1...6).contains(normalized.channelWidth))
        #expect((1...4).contains(normalized.emitterCount))
        #expect((1...8).contains(normalized.emitterWidth))
        #expect((1...8).contains(normalized.emitterRate))
        #expect((0...1).contains(normalized.rockRatio))
        #expect((0...1).contains(normalized.soilRatio))
        #expect((0...1).contains(normalized.waterLateralFlow))
        #expect((0...1).contains(normalized.persistence))
        #expect(normalized.phaseDurations.quiet > 0)
        #expect(normalized.phaseDurations.filling > 0)
        #expect(normalized.regenerationCadence >= normalized.phaseDurations.total)
    }

    @Test("Saved Looks capture and restore the exact material seed and controls")
    func savedLookRoundTrip() throws {
        let id = UUID(uuidString: "6B2A8181-814F-44DE-958F-5A7347801C23")!
        var source = IdleScreenConfiguration.default
        source.creative.pattern = .pixelMaterials
        source.materials = .init(
            material: .mixed,
            terrainFamily: .watershed,
            seed: 77
        )
        let withLook = try source.savingCurrentLook(id: id, named: "Watershed")
        var changed = withLook
        changed.materials = .init(material: .sand, seed: 88)

        let restored = try changed.applyingSavedLook(id: id)

        #expect(restored.creative.pattern == .pixelMaterials)
        #expect(restored.materials == source.materials)
        #expect(restored.savedLooks == withLook.savedLooks)
    }
}
