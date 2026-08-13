import Foundation

public enum IdleScreenSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case camera
    case generative

    public var id: String { rawValue }

    /// Hybrid was retired in schema 6. Decode its persisted raw value as the
    /// generative source so the independently persisted creative pattern is
    /// preserved as the user's selected saver. New writes can only encode the
    /// two supported source values above.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let persistedValue = try container.decode(String.self)
        switch persistedValue {
        case Self.camera.rawValue:
            self = .camera
        case Self.generative.rawValue, "hybrid":
            self = .generative
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported IdleScreen source: \(persistedValue)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct IdleScreenAppearance: Codable, Equatable, Sendable {
    public var glyphScale: Double
    public var contrast: Double
    public var palette: String

    public init(glyphScale: Double, contrast: Double, palette: String) {
        self.glyphScale = glyphScale
        self.contrast = contrast
        self.palette = palette
    }
}

public struct IdleScreenConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 9

    public var schemaVersion: Int
    public var revision: UInt64
    public var modifiedAt: Date
    public var source: IdleScreenSource
    public var appearance: IdleScreenAppearance
    public var creative: IdleScreenCreativeConfiguration
    public var camera: IdleScreenCameraConfiguration
    public var display: DisplaySceneSettings
    public var materials: IdleScreenPixelMaterialsConfiguration
    public var agentIntegration: IdleScreenAgentIntegrationConfiguration
    public fileprivate(set) var savedLooks: [IdleScreenSavedLook]

    public init(
        schemaVersion: Int,
        revision: UInt64,
        modifiedAt: Date,
        source: IdleScreenSource,
        appearance: IdleScreenAppearance,
        creative: IdleScreenCreativeConfiguration = .default,
        camera: IdleScreenCameraConfiguration = .default,
        display: DisplaySceneSettings = .default,
        materials: IdleScreenPixelMaterialsConfiguration = .default,
        agentIntegration: IdleScreenAgentIntegrationConfiguration = .default,
        savedLooks: [IdleScreenSavedLook] = []
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.source = source
        self.appearance = appearance
        self.creative = creative
        self.camera = camera
        self.display = display
        self.materials = materials.normalized
        self.agentIntegration = agentIntegration.normalized
        self.savedLooks = IdleScreenSavedLook.normalizedCollection(savedLooks)
    }

    public static let `default` = IdleScreenConfiguration(
        schemaVersion: currentSchemaVersion,
        revision: 0,
        modifiedAt: .distantPast,
        source: .generative,
        appearance: IdleScreenAppearance(
            glyphScale: 0.38,
            contrast: 0.58,
            palette: "Ember"
        ),
        creative: .default,
        camera: .default,
        display: .default,
        materials: .default,
        agentIntegration: .default,
        savedLooks: []
    )

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case revision
        case modifiedAt
        case source
        case appearance
        case creative
        case camera
        case display
        case materials
        case agentIntegration
        case savedLooks
    }

    /// Schema 1 predates creative configuration; schemas 1 and 2 both predate
    /// Saved Looks; schemas 1 through 3 predate camera selection, and schemas
    /// 1 through 4 predate the camera mirror option, schema 6 retires the
    /// Hybrid source, schema 7 adds explicit display-scene policy, and schema
    /// 8 adds Pixel Materials, and schema 9 adds explicitly opted-out local
    /// agent integrations. A
    /// persisted Hybrid configuration decodes as Generative while retaining
    /// its creative pattern and settings. Missing fields gain their production
    /// defaults on read.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            revision: try values.decode(UInt64.self, forKey: .revision),
            modifiedAt: try values.decode(Date.self, forKey: .modifiedAt),
            source: try values.decode(IdleScreenSource.self, forKey: .source),
            appearance: try values.decode(
                IdleScreenAppearance.self,
                forKey: .appearance
            ),
            creative: try values.decodeIfPresent(
                IdleScreenCreativeConfiguration.self,
                forKey: .creative
            ) ?? .default,
            camera: try values.decodeIfPresent(
                IdleScreenCameraConfiguration.self,
                forKey: .camera
            ) ?? .default,
            display: try values.decodeIfPresent(
                DisplaySceneSettings.self,
                forKey: .display
            ) ?? .default,
            materials: try values.decodeIfPresent(
                IdleScreenPixelMaterialsConfiguration.self,
                forKey: .materials
            ) ?? .default,
            agentIntegration: try values.decodeIfPresent(
                IdleScreenAgentIntegrationConfiguration.self,
                forKey: .agentIntegration
            ) ?? .default,
            savedLooks: try values.decodeIfPresent(
                [IdleScreenSavedLook].self,
                forKey: .savedLooks
            ) ?? []
        )
    }

    /// Saves the exact current visual state under a caller-provided stable ID.
    /// UUID generation and persistence metadata remain the caller's concern.
    public func savingCurrentLook(
        id: UUID,
        named name: String
    ) throws -> Self {
        guard let normalizedName = IdleScreenSavedLook.validatedName(name) else {
            throw IdleScreenSavedLookError.invalidName
        }
        guard !savedLooks.contains(where: { $0.id == id }) else {
            throw IdleScreenSavedLookError.duplicateID(id)
        }
        guard savedLooks.count < IdleScreenSavedLook.maximumCount else {
            throw IdleScreenSavedLookError.collectionFull(
                maximumCount: IdleScreenSavedLook.maximumCount
            )
        }

        var result = self
        result.savedLooks.append(IdleScreenSavedLook(
            id: id,
            name: normalizedName,
            snapshot: currentLookSnapshot
        ))
        return result
    }

    /// Replaces only an existing look's snapshot. Its ID, normalized name, and
    /// position remain stable.
    public func replacingSavedLook(id: UUID) throws -> Self {
        guard let index = savedLooks.firstIndex(where: { $0.id == id }) else {
            throw IdleScreenSavedLookError.notFound(id)
        }
        var result = self
        let existing = savedLooks[index]
        result.savedLooks[index] = IdleScreenSavedLook(
            id: existing.id,
            name: existing.name,
            snapshot: currentLookSnapshot
        )
        return result
    }

    /// Applies only the saved visual state. Revision, modification date,
    /// schema, and the saved-look library remain exactly as they were.
    public func applyingSavedLook(id: UUID) throws -> Self {
        guard let savedLook = savedLooks.first(where: { $0.id == id }) else {
            throw IdleScreenSavedLookError.notFound(id)
        }
        var result = self
        result.source = savedLook.snapshot.source
        result.appearance = savedLook.snapshot.appearance
        result.creative = savedLook.snapshot.creative
        result.materials = savedLook.snapshot.materials
        return result
    }

    /// Changes only the normalized display name of an existing look.
    public func renamingSavedLook(
        id: UUID,
        to name: String
    ) throws -> Self {
        guard let index = savedLooks.firstIndex(where: { $0.id == id }) else {
            throw IdleScreenSavedLookError.notFound(id)
        }
        guard let normalizedName = IdleScreenSavedLook.validatedName(name) else {
            throw IdleScreenSavedLookError.invalidName
        }
        var result = self
        let savedLook = result.savedLooks[index]
        result.savedLooks[index] = IdleScreenSavedLook(
            id: savedLook.id,
            name: normalizedName,
            snapshot: savedLook.snapshot
        )
        return result
    }

    /// Removes only the matching saved look.
    public func removingSavedLook(id: UUID) throws -> Self {
        guard let index = savedLooks.firstIndex(where: { $0.id == id }) else {
            throw IdleScreenSavedLookError.notFound(id)
        }
        var result = self
        result.savedLooks.remove(at: index)
        return result
    }

    private var currentLookSnapshot: IdleScreenLookSnapshot {
        IdleScreenLookSnapshot(
            source: source,
            appearance: appearance,
            creative: creative,
            materials: materials
        )
    }
}

public struct IdleScreenConfigurationStore: Sendable {
    public enum Error: Swift.Error, Equatable {
        case unsupportedSchema(Int)
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func read() throws -> IdleScreenConfiguration? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let configuration = try decoder.decode(IdleScreenConfiguration.self, from: data)
        guard configuration.schemaVersion <= IdleScreenConfiguration.currentSchemaVersion else {
            throw Error.unsupportedSchema(configuration.schemaVersion)
        }
        return configuration
    }

    /// Reads the modern shared configuration first. Only when it does not yet
    /// exist does this import the newest readable legacy `config.json` into an
    /// in-memory modern value. Legacy files are never written or removed.
    public func read(
        importingLegacyConfigurationAt legacyFileURLs: [URL]
    ) throws -> IdleScreenConfiguration? {
        if let configuration = try read() {
            return configuration
        }
        return try IdleScreenLegacyConfigurationMigration.read(
            from: legacyFileURLs
        )
    }

    public func write(_ configuration: IdleScreenConfiguration) throws {
        guard configuration.schemaVersion <= IdleScreenConfiguration.currentSchemaVersion else {
            throw Error.unsupportedSchema(configuration.schemaVersion)
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var persistedConfiguration = configuration
        persistedConfiguration.schemaVersion =
            IdleScreenConfiguration.currentSchemaVersion
        persistedConfiguration.savedLooks =
            IdleScreenSavedLook.normalizedCollection(
                persistedConfiguration.savedLooks
            )
        persistedConfiguration.materials =
            persistedConfiguration.materials.normalized
        persistedConfiguration.agentIntegration =
            persistedConfiguration.agentIntegration.normalized
        let data = try encoder.encode(persistedConfiguration)
        try data.write(to: fileURL, options: [.atomic])
    }
}

public enum IdleScreenLegacyConfigurationMigration {
    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case noUsableLegacyConfiguration(candidatePaths: [String])

        public var errorDescription: String? {
            switch self {
            case let .noUsableLegacyConfiguration(candidatePaths):
                return "Legacy IdleScreen configuration exists but could not be imported from: \(candidatePaths.joined(separator: ", ")). The legacy files were left unchanged so the import can be retried."
            }
        }
    }

    private static let maximumLegacyFileByteCount = 1_048_576

    private struct LegacyConfiguration: Decodable {
        let fontSize: Double
        let textColorRGBA: [Double]
        let characterSetPreset: String
        let colorMode: String
        let colorRampPreset: String
        let animationMode: String
        let contrast: Double
        let gradientPreset: String
        let autoCycleInterval: TimeInterval
        let patternSpeed: Double
        let patternScale: Double
        let matrixTrailLength: Double
        let rainbowAmplitude: Double
        let fireDecay: Double
        let patternIntensity: Double
        let patternTrailing: Double
        let renderQuality: String
        let preferredCameraID: String
        let mirrorCamera: Bool

        private enum CodingKeys: String, CodingKey {
            case fontSize
            case textColorRGBA
            case characterSetPreset
            case colorMode
            case colorRampPreset
            case animationMode
            case contrast
            case gradientPreset
            case autoCycleInterval
            case patternSpeed
            case patternScale
            case matrixTrailLength
            case rainbowAmplitude
            case fireDecay
            case patternIntensity
            case patternTrailing
            case renderQuality
            case preferredCameraID
            case mirrorCamera
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fontSize = try container.decodeIfPresent(
                Double.self,
                forKey: .fontSize
            ) ?? 12
            textColorRGBA = try container.decodeIfPresent(
                [Double].self,
                forKey: .textColorRGBA
            ) ?? [0, 1, 0, 1]
            characterSetPreset = try container.decodeIfPresent(
                String.self,
                forKey: .characterSetPreset
            ) ?? "ascii"
            colorMode = try container.decodeIfPresent(
                String.self,
                forKey: .colorMode
            ) ?? "uniform"
            colorRampPreset = try container.decodeIfPresent(
                String.self,
                forKey: .colorRampPreset
            ) ?? "classicTerminal"
            animationMode = try container.decodeIfPresent(
                String.self,
                forKey: .animationMode
            ) ?? "autoCycle"
            contrast = try container.decodeIfPresent(
                Double.self,
                forKey: .contrast
            ) ?? 1
            gradientPreset = try container.decodeIfPresent(
                String.self,
                forKey: .gradientPreset
            ) ?? "matrixGreen"
            autoCycleInterval = try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .autoCycleInterval
            ) ?? IdleScreenCreativeSettings.defaultAutoCycleInterval
            patternSpeed = try container.decodeIfPresent(
                Double.self,
                forKey: .patternSpeed
            ) ?? IdleScreenCreativeSettings.defaultSpeed
            patternScale = try container.decodeIfPresent(
                Double.self,
                forKey: .patternScale
            ) ?? IdleScreenCreativeSettings.defaultScale
            matrixTrailLength = try container.decodeIfPresent(
                Double.self,
                forKey: .matrixTrailLength
            ) ?? IdleScreenCreativeSettings.defaultMatrixTrailLength
            rainbowAmplitude = try container.decodeIfPresent(
                Double.self,
                forKey: .rainbowAmplitude
            ) ?? IdleScreenCreativeSettings.defaultRainbowAmplitude
            fireDecay = try container.decodeIfPresent(
                Double.self,
                forKey: .fireDecay
            ) ?? IdleScreenCreativeSettings.defaultFireDecay
            patternIntensity = try container.decodeIfPresent(
                Double.self,
                forKey: .patternIntensity
            ) ?? IdleScreenCreativeSettings.defaultIntensity
            patternTrailing = try container.decodeIfPresent(
                Double.self,
                forKey: .patternTrailing
            ) ?? IdleScreenCreativeSettings.defaultTrailing
            renderQuality = try container.decodeIfPresent(
                String.self,
                forKey: .renderQuality
            ) ?? "auto"
            preferredCameraID = try container.decodeIfPresent(
                String.self,
                forKey: .preferredCameraID
            ) ?? "auto"
            mirrorCamera = try container.decodeIfPresent(
                Bool.self,
                forKey: .mirrorCamera
            ) ?? true
        }
    }

    private struct Candidate {
        let url: URL
        let modifiedAt: Date
    }

    private static let generativeAnimationModes: Set<String> = [
        "autoCycle", "perlin", "plasma", "sweep", "matrixRain",
        "rainbowCycle", "fireEffect", "ripple", "voronoi", "warp",
        "staticNoise", "pulse", "dvdBounce", "metaballs", "starfield",
        "spiral", "terrain", "rainOnGlass", "aurora",
    ]

    /// The two locations written by the prior saver/settings implementation.
    /// The returned URLs are candidates only; this method performs no I/O.
    public static func defaultFileURLs(
        fileManager: FileManager = .default
    ) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Library/Application Support/Idlescreen/config.json"),
            home.appending(
                path: "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/Idlescreen/config.json"
            ),
        ]
    }

    /// Imports settings with a direct modern equivalent, including the full
    /// legacy procedural pattern controls. Legacy files remain untouched.
    public static func read(
        from fileURLs: [URL],
        fileManager: FileManager = .default
    ) throws -> IdleScreenConfiguration? {
        var candidates: [Candidate] = []
        var existingCandidatePaths: [String] = []
        var seenPaths: Set<String> = []

        for url in fileURLs {
            let standardizedURL = url.standardizedFileURL
            guard seenPaths.insert(standardizedURL.path).inserted,
                  fileManager.fileExists(atPath: standardizedURL.path) else {
                continue
            }
            existingCandidatePaths.append(standardizedURL.path)

            do {
                let values = try standardizedURL.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let fileSize = values.fileSize,
                      (1...maximumLegacyFileByteCount).contains(fileSize),
                      let modifiedAt = values.contentModificationDate else {
                    continue
                }
                candidates.append(Candidate(
                    url: standardizedURL,
                    modifiedAt: modifiedAt
                ))
            } catch {
                // A broken mirror must not hide another valid legacy copy.
                continue
            }
        }

        candidates.sort {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.url.path < $1.url.path
        }

        for candidate in candidates {
            do {
                let data = try Data(contentsOf: candidate.url, options: .mappedIfSafe)
                let legacy = try JSONDecoder().decode(
                    LegacyConfiguration.self,
                    from: data
                )
                return migrate(
                    legacy,
                    modifiedAt: candidate.modifiedAt
                )
            } catch {
                // Candidates are newest-first; keep looking for the newest
                // mirror that is both readable and valid legacy JSON.
                continue
            }
        }
        if !existingCandidatePaths.isEmpty {
            throw Error.noUsableLegacyConfiguration(
                candidatePaths: existingCandidatePaths
            )
        }
        return nil
    }

    private static func migrate(
        _ legacy: LegacyConfiguration,
        modifiedAt: Date
    ) -> IdleScreenConfiguration {
        var configuration = IdleScreenConfiguration.default

        configuration.source = source(for: legacy.animationMode)
        if legacy.fontSize.isFinite {
            // The modern renderer spans 8...20 points. Preserve the legacy
            // point size as closely as that intentionally bounded range allows.
            configuration.appearance.glyphScale = clamp(
                (legacy.fontSize - 8) / 12
            )
        }
        if legacy.contrast.isFinite {
            // Legacy contrast was a 0...3 slider; modern contrast is 0...1.
            configuration.appearance.contrast = clamp(legacy.contrast / 3)
        }
        configuration.appearance.palette = palette(for: legacy)
        configuration.creative = IdleScreenCreativeConfiguration(
            pattern: creativePattern(for: legacy.animationMode),
            settings: IdleScreenCreativeSettings(
                speed: legacy.patternSpeed,
                scale: legacy.patternScale,
                intensity: legacy.patternIntensity,
                trailing: legacy.patternTrailing,
                autoCycleInterval: legacy.autoCycleInterval,
                matrixTrailLength: legacy.matrixTrailLength,
                rainbowAmplitude: legacy.rainbowAmplitude,
                fireDecay: legacy.fireDecay,
                qualityLevel: qualityLevel(for: legacy.renderQuality)
            )
        )
        if legacy.preferredCameraID != "auto",
           let preferredIdentifier =
               IdleScreenCameraConfiguration.validatedPreferredIdentifier(
                   legacy.preferredCameraID
               ) {
            configuration.camera.preferredDeviceIdentifier = preferredIdentifier
        }
        configuration.camera.isMirrored = legacy.mirrorCamera

        configuration.revision = 1
        configuration.modifiedAt = modifiedAt
        return configuration
    }

    private static func source(for animationMode: String) -> IdleScreenSource {
        if animationMode == "camera" {
            return .camera
        }
        if generativeAnimationModes.contains(animationMode) {
            return .generative
        }
        // The archived runtime fell back to autoCycle for unknown raw values.
        return .generative
    }

    private static func creativePattern(
        for animationMode: String
    ) -> IdleScreenCreativePattern {
        // Legacy Camera used production pattern index 0 whenever its live
        // input was unavailable, which is the Perlin kernel.
        if animationMode == "camera" {
            return .perlin
        }
        guard generativeAnimationModes.contains(animationMode) else {
            return .autoCycle
        }
        return IdleScreenCreativePattern(rawValue: animationMode) ?? .autoCycle
    }

    private static func qualityLevel(for renderQuality: String) -> Double {
        switch renderQuality {
        case "eco": return 0.4
        case "performance": return 1
        case "auto", "balanced": return 0.7
        default: return IdleScreenCreativeSettings.defaultQualityLevel
        }
    }

    private static func palette(
        for legacy: LegacyConfiguration
    ) -> String {
        if legacy.colorMode == "proceduralGradient",
           let mapped = gradientPalettes[legacy.gradientPreset] {
            return mapped
        }
        if legacy.colorMode == "brightnessRamp",
           let mapped = colorRampPalettes[legacy.colorRampPreset] {
            return mapped
        }
        if legacy.textColorRGBA.count >= 3,
           legacy.textColorRGBA.prefix(3).allSatisfy({ $0.isFinite }) {
            return nearestPalette(
                red: clamp(legacy.textColorRGBA[0]),
                green: clamp(legacy.textColorRGBA[1]),
                blue: clamp(legacy.textColorRGBA[2])
            )
        }
        return gradientPalettes[legacy.gradientPreset]
            ?? colorRampPalettes[legacy.colorRampPreset]
            ?? "Phosphor"
    }

    private static let gradientPalettes: [String: String] = [
        "matrixGreen": "Phosphor",
        "amber": "Ember",
        "cyan": "Blueprint",
        "ocean": "Blueprint",
        "fire": "Signal",
        "rainbow": "Ember",
        "nebula": "Ember",
        "thermal": "Signal",
    ]

    private static let colorRampPalettes: [String: String] = [
        "classicTerminal": "Phosphor",
        "amberMonochrome": "Ember",
        "matrix": "Phosphor",
        "cyberpunk": "Blueprint",
    ]

    private static func nearestPalette(
        red: Double,
        green: Double,
        blue: Double
    ) -> String {
        let palettes: [(String, Double, Double, Double)] = [
            ("Ember", 1, 0.75, 0.42),
            ("Phosphor", 0.28, 1, 0.38),
            ("Ivory", 1, 0.94, 0.78),
            ("Blueprint", 0.35, 0.78, 1),
            ("Signal", 1, 0.22, 0.14),
        ]
        return palettes.min { left, right in
            colorDistance(red, green, blue, left)
                < colorDistance(red, green, blue, right)
        }?.0 ?? "Ember"
    }

    private static func colorDistance(
        _ red: Double,
        _ green: Double,
        _ blue: Double,
        _ palette: (String, Double, Double, Double)
    ) -> Double {
        let redDistance = red - palette.1
        let greenDistance = green - palette.2
        let blueDistance = blue - palette.3
        return redDistance * redDistance
            + greenDistance * greenDistance
            + blueDistance * blueDistance
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
