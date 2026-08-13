import Foundation

public enum IdleScreenPixelMaterial: String, Codable, CaseIterable,
    Equatable, Identifiable, Sendable
{
    case sand
    case water
    case mixed

    public var id: String { rawValue }

    public var label: String { rawValue.capitalized }
}

public enum IdleScreenPixelTerrainFamily: String, Codable, CaseIterable,
    Equatable, Identifiable, Sendable
{
    case watershed
    case terraces
    case caverns

    public var id: String { rawValue }

    public var label: String { rawValue.capitalized }
}

public enum IdleScreenPixelMaterialsPalette: String, Codable, CaseIterable,
    Equatable, Identifiable, Sendable
{
    case canyon
    case tidal
    case monochrome

    public var id: String { rawValue }

    public var label: String { rawValue.capitalized }
}

public struct IdleScreenPixelMaterialsPhaseDurations: Codable, Equatable,
    Sendable
{
    public static let `default` = Self(
        quiet: 2,
        filling: 24,
        settled: 8,
        draining: 6
    )

    public var quiet: TimeInterval
    public var filling: TimeInterval
    public var settled: TimeInterval
    public var draining: TimeInterval

    public var total: TimeInterval {
        quiet + filling + settled + draining
    }

    public init(
        quiet: TimeInterval,
        filling: TimeInterval,
        settled: TimeInterval,
        draining: TimeInterval
    ) {
        self.quiet = Self.bounded(quiet, fallback: 2)
        self.filling = Self.bounded(filling, fallback: 24)
        self.settled = Self.bounded(settled, fallback: 8)
        self.draining = Self.bounded(draining, fallback: 6)
    }

    private enum CodingKeys: String, CodingKey {
        case quiet
        case filling
        case settled
        case draining
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            quiet: try values.decodeIfPresent(TimeInterval.self, forKey: .quiet)
                ?? Self.default.quiet,
            filling: try values.decodeIfPresent(TimeInterval.self, forKey: .filling)
                ?? Self.default.filling,
            settled: try values.decodeIfPresent(TimeInterval.self, forKey: .settled)
                ?? Self.default.settled,
            draining: try values.decodeIfPresent(TimeInterval.self, forKey: .draining)
                ?? Self.default.draining
        )
    }

    private static func bounded(
        _ value: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else { return fallback }
        return min(300, max(0.25, value))
    }
}

/// Versioned controls for the camera-independent Pixel Materials family.
///
/// The initializer and decoder both restore every bound. Callers can persist
/// this value directly without depending on renderer or host lifecycle types.
public struct IdleScreenPixelMaterialsConfiguration: Codable, Equatable,
    Sendable
{
    public static let currentSchemaVersion = 1
    public static let defaultSeed: UInt64 = 0x49444C45504D0001

    public var schemaVersion: Int
    public var material: IdleScreenPixelMaterial
    public var terrainFamily: IdleScreenPixelTerrainFamily
    public var seed: UInt64
    public var basinCount: Int
    public var basinDepth: Int
    public var minimumBasinCapacity: Int
    public var channelConnectivity: Double
    public var channelWidth: Int
    public var rockRatio: Double
    public var soilRatio: Double
    public var emitterCount: Int
    public var emitterPosition: Double
    public var emitterWidth: Int
    public var emitterRate: Int
    public var gravity: Double
    public var cellScale: Double
    public var waterLateralFlow: Double
    public var waterEqualization: Double
    public var waterPressure: Double
    public var spillRate: Double
    public var drainRate: Double
    public var evaporationRate: Double
    public var obstacleDensity: Double
    public var palette: IdleScreenPixelMaterialsPalette
    public var persistence: Double
    public var phaseDurations: IdleScreenPixelMaterialsPhaseDurations
    public var regenerationCadence: TimeInterval

    public init(
        schemaVersion: Int = currentSchemaVersion,
        material: IdleScreenPixelMaterial = .water,
        terrainFamily: IdleScreenPixelTerrainFamily = .watershed,
        seed: UInt64 = defaultSeed,
        basinCount: Int = 3,
        basinDepth: Int = 8,
        minimumBasinCapacity: Int = 32,
        channelConnectivity: Double = 0.75,
        channelWidth: Int = 2,
        rockRatio: Double = 0.62,
        soilRatio: Double = 0.38,
        emitterCount: Int = 1,
        emitterPosition: Double = 0.18,
        emitterWidth: Int = 2,
        emitterRate: Int = 2,
        gravity: Double = 1,
        cellScale: Double = 1,
        waterLateralFlow: Double = 0.8,
        waterEqualization: Double = 0.8,
        waterPressure: Double = 0.5,
        spillRate: Double = 1,
        drainRate: Double = 0.25,
        evaporationRate: Double = 0,
        obstacleDensity: Double = 0.12,
        palette: IdleScreenPixelMaterialsPalette = .canyon,
        persistence: Double = 1,
        phaseDurations: IdleScreenPixelMaterialsPhaseDurations = .default,
        regenerationCadence: TimeInterval = 40
    ) {
        self.schemaVersion = min(
            Self.currentSchemaVersion,
            max(1, schemaVersion)
        )
        self.material = material
        self.terrainFamily = terrainFamily
        self.seed = seed == 0 ? Self.defaultSeed : seed
        self.basinCount = Self.bounded(basinCount, 2...8)
        self.basinDepth = Self.bounded(basinDepth, 3...24)
        self.minimumBasinCapacity = Self.bounded(
            minimumBasinCapacity,
            8...4096
        )
        self.channelConnectivity = Self.unit(
            channelConnectivity,
            fallback: 0.75
        )
        self.channelWidth = Self.bounded(channelWidth, 1...6)
        self.rockRatio = Self.unit(rockRatio, fallback: 0.62)
        self.soilRatio = Self.unit(soilRatio, fallback: 0.38)
        self.emitterCount = Self.bounded(emitterCount, 1...4)
        self.emitterPosition = Self.unit(emitterPosition, fallback: 0.18)
        self.emitterWidth = Self.bounded(emitterWidth, 1...8)
        self.emitterRate = Self.bounded(emitterRate, 1...8)
        self.gravity = Self.unit(gravity, fallback: 1)
        self.cellScale = Self.bounded(
            cellScale,
            fallback: 1,
            range: 0.25...4
        )
        self.waterLateralFlow = Self.unit(
            waterLateralFlow,
            fallback: 0.8
        )
        self.waterEqualization = Self.unit(
            waterEqualization,
            fallback: 0.8
        )
        self.waterPressure = Self.unit(waterPressure, fallback: 0.5)
        self.spillRate = Self.unit(spillRate, fallback: 1)
        self.drainRate = Self.unit(drainRate, fallback: 0.25)
        self.evaporationRate = Self.unit(evaporationRate, fallback: 0)
        self.obstacleDensity = Self.unit(obstacleDensity, fallback: 0.12)
        self.palette = palette
        self.persistence = Self.unit(persistence, fallback: 1)
        self.phaseDurations = phaseDurations
        self.regenerationCadence = Self.bounded(
            regenerationCadence,
            fallback: phaseDurations.total,
            range: phaseDurations.total...max(phaseDurations.total, 600)
        )
    }

    public static let `default` = Self()

    public var normalized: Self {
        Self(
            schemaVersion: schemaVersion,
            material: material,
            terrainFamily: terrainFamily,
            seed: seed,
            basinCount: basinCount,
            basinDepth: basinDepth,
            minimumBasinCapacity: minimumBasinCapacity,
            channelConnectivity: channelConnectivity,
            channelWidth: channelWidth,
            rockRatio: rockRatio,
            soilRatio: soilRatio,
            emitterCount: emitterCount,
            emitterPosition: emitterPosition,
            emitterWidth: emitterWidth,
            emitterRate: emitterRate,
            gravity: gravity,
            cellScale: cellScale,
            waterLateralFlow: waterLateralFlow,
            waterEqualization: waterEqualization,
            waterPressure: waterPressure,
            spillRate: spillRate,
            drainRate: drainRate,
            evaporationRate: evaporationRate,
            obstacleDensity: obstacleDensity,
            palette: palette,
            persistence: persistence,
            phaseDurations: phaseDurations,
            regenerationCadence: regenerationCadence
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case material
        case terrainFamily
        case seed
        case basinCount
        case basinDepth
        case minimumBasinCapacity
        case channelConnectivity
        case channelWidth
        case rockRatio
        case soilRatio
        case emitterCount
        case emitterPosition
        case emitterWidth
        case emitterRate
        case gravity
        case cellScale
        case waterLateralFlow
        case waterEqualization
        case waterPressure
        case spillRate
        case drainRate
        case evaporationRate
        case obstacleDensity
        case palette
        case persistence
        case phaseDurations
        case regenerationCadence
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        self.init(
            schemaVersion: try values.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? defaults.schemaVersion,
            material: try values.decodeIfPresent(
                IdleScreenPixelMaterial.self,
                forKey: .material
            ) ?? defaults.material,
            terrainFamily: try values.decodeIfPresent(
                IdleScreenPixelTerrainFamily.self,
                forKey: .terrainFamily
            ) ?? defaults.terrainFamily,
            seed: try values.decodeIfPresent(UInt64.self, forKey: .seed)
                ?? defaults.seed,
            basinCount: try values.decodeIfPresent(Int.self, forKey: .basinCount)
                ?? defaults.basinCount,
            basinDepth: try values.decodeIfPresent(Int.self, forKey: .basinDepth)
                ?? defaults.basinDepth,
            minimumBasinCapacity: try values.decodeIfPresent(
                Int.self,
                forKey: .minimumBasinCapacity
            ) ?? defaults.minimumBasinCapacity,
            channelConnectivity: try values.decodeIfPresent(
                Double.self,
                forKey: .channelConnectivity
            ) ?? defaults.channelConnectivity,
            channelWidth: try values.decodeIfPresent(Int.self, forKey: .channelWidth)
                ?? defaults.channelWidth,
            rockRatio: try values.decodeIfPresent(Double.self, forKey: .rockRatio)
                ?? defaults.rockRatio,
            soilRatio: try values.decodeIfPresent(Double.self, forKey: .soilRatio)
                ?? defaults.soilRatio,
            emitterCount: try values.decodeIfPresent(Int.self, forKey: .emitterCount)
                ?? defaults.emitterCount,
            emitterPosition: try values.decodeIfPresent(
                Double.self,
                forKey: .emitterPosition
            ) ?? defaults.emitterPosition,
            emitterWidth: try values.decodeIfPresent(Int.self, forKey: .emitterWidth)
                ?? defaults.emitterWidth,
            emitterRate: try values.decodeIfPresent(Int.self, forKey: .emitterRate)
                ?? defaults.emitterRate,
            gravity: try values.decodeIfPresent(Double.self, forKey: .gravity)
                ?? defaults.gravity,
            cellScale: try values.decodeIfPresent(Double.self, forKey: .cellScale)
                ?? defaults.cellScale,
            waterLateralFlow: try values.decodeIfPresent(
                Double.self,
                forKey: .waterLateralFlow
            ) ?? defaults.waterLateralFlow,
            waterEqualization: try values.decodeIfPresent(
                Double.self,
                forKey: .waterEqualization
            ) ?? defaults.waterEqualization,
            waterPressure: try values.decodeIfPresent(
                Double.self,
                forKey: .waterPressure
            ) ?? defaults.waterPressure,
            spillRate: try values.decodeIfPresent(Double.self, forKey: .spillRate)
                ?? defaults.spillRate,
            drainRate: try values.decodeIfPresent(Double.self, forKey: .drainRate)
                ?? defaults.drainRate,
            evaporationRate: try values.decodeIfPresent(
                Double.self,
                forKey: .evaporationRate
            ) ?? defaults.evaporationRate,
            obstacleDensity: try values.decodeIfPresent(
                Double.self,
                forKey: .obstacleDensity
            ) ?? defaults.obstacleDensity,
            palette: try values.decodeIfPresent(
                IdleScreenPixelMaterialsPalette.self,
                forKey: .palette
            ) ?? defaults.palette,
            persistence: try values.decodeIfPresent(Double.self, forKey: .persistence)
                ?? defaults.persistence,
            phaseDurations: try values.decodeIfPresent(
                IdleScreenPixelMaterialsPhaseDurations.self,
                forKey: .phaseDurations
            ) ?? defaults.phaseDurations,
            regenerationCadence: try values.decodeIfPresent(
                TimeInterval.self,
                forKey: .regenerationCadence
            ) ?? defaults.regenerationCadence
        )
    }

    private static func bounded(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private static func unit(_ value: Double, fallback: Double) -> Double {
        bounded(value, fallback: fallback, range: 0...1)
    }

    private static func bounded(
        _ value: Double,
        fallback: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
