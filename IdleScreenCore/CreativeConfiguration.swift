import Foundation

/// A camera-independent animation available to both the Studio preview and
/// the screen saver renderer.
///
/// Raw values intentionally match the previous IdleScreen configuration so a
/// future schema migration can preserve a user's selected pattern verbatim.
public enum IdleScreenCreativePattern: String, Codable, CaseIterable,
    Equatable, Identifiable, Sendable
{
    case autoCycle
    case perlin
    case plasma
    case sweep
    case matrixRain
    case rainbowCycle
    case fireEffect
    case ripple
    case voronoi
    case warp
    case staticNoise
    case pulse
    case dvdBounce
    case metaballs
    case starfield
    case spiral
    case terrain
    case rainOnGlass
    case aurora
    case pixelMaterials

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoCycle: return "Auto Cycle"
        case .perlin: return "Perlin Noise"
        case .plasma: return "Plasma"
        case .sweep: return "Sweep"
        case .matrixRain: return "Rain"
        case .rainbowCycle: return "Rainbow Cycle"
        case .fireEffect: return "Fire Effect"
        case .ripple: return "Ripple"
        case .voronoi: return "Voronoi"
        case .warp: return "Warp"
        case .staticNoise: return "Static"
        case .pulse: return "Pulse"
        case .dvdBounce: return "DVD Bounce"
        case .metaballs: return "Metaballs"
        case .starfield: return "Starfield"
        case .spiral: return "Spiral Galaxy"
        case .terrain: return "Terrain"
        case .rainOnGlass: return "Rain on Glass"
        case .aurora: return "Aurora"
        case .pixelMaterials: return "Pixel Materials"
        }
    }

    public var symbolName: String {
        switch self {
        case .autoCycle: return "arrow.trianglehead.2.clockwise"
        case .perlin: return "cloud.fog"
        case .plasma: return "waveform.circle"
        case .sweep: return "wind"
        case .matrixRain: return "chevron.left.forwardslash.chevron.right"
        case .rainbowCycle: return "rainbow"
        case .fireEffect: return "flame"
        case .ripple: return "drop.circle"
        case .voronoi: return "circle.hexagongrid"
        case .warp: return "scope"
        case .staticNoise: return "tv"
        case .pulse: return "dot.radiowaves.right"
        case .dvdBounce: return "square.on.square.dashed"
        case .metaballs: return "circle.grid.cross"
        case .starfield: return "sparkles"
        case .spiral: return "hurricane"
        case .terrain: return "mountain.2"
        case .rainOnGlass: return "cloud.heavyrain"
        case .aurora: return "light.ribbon"
        case .pixelMaterials: return "drop.triangle"
        }
    }

    /// Concrete patterns in the stable order used by the legacy renderer.
    public static let patterns: [Self] = [
        .perlin,
        .plasma,
        .sweep,
        .matrixRain,
        .rainbowCycle,
        .fireEffect,
        .ripple,
        .voronoi,
        .warp,
        .staticNoise,
        .pulse,
        .dvdBounce,
        .metaballs,
        .starfield,
        .spiral,
        .terrain,
        .rainOnGlass,
        .aurora,
        .pixelMaterials,
    ]

    /// Resolves Auto Cycle without introducing randomness or persisted state.
    /// Non-finite or negative elapsed times safely resolve from the first slot.
    public func resolved(
        at elapsedTime: TimeInterval,
        autoCycleInterval: TimeInterval
    ) -> Self {
        guard self == .autoCycle else { return self }

        let interval = IdleScreenCreativeSettings.normalizedAutoCycleInterval(
            autoCycleInterval
        )
        let elapsed = elapsedTime.isFinite ? max(0, elapsedTime) : 0
        let cyclePosition = (elapsed / interval).truncatingRemainder(
            dividingBy: Double(Self.patterns.count)
        )
        let slot = Int(cyclePosition.rounded(.down))
        return Self.patterns[slot]
    }
}

/// Tunable inputs for procedural rendering.
///
/// The defaults and bounds are compatible with the previous IdleScreen
/// configuration. The three pattern-specific controls remain explicit so an
/// imported legacy configuration does not lose its visual behavior.
public struct IdleScreenCreativeSettings: Codable, Equatable, Sendable {
    public static let defaultSpeed = 1.0
    public static let defaultScale = 1.0
    public static let defaultIntensity = 0.5
    public static let defaultTrailing = 0.5
    public static let defaultAutoCycleInterval: TimeInterval = 30
    public static let defaultMatrixTrailLength = 0.5
    public static let defaultRainbowAmplitude = 0.5
    public static let defaultFireDecay = 0.5
    /// Legacy Auto and Balanced rendering both use a 0.7 quality multiplier.
    public static let defaultQualityLevel = 0.7

    public static let minimumSpeed = 0.1
    public static let maximumSpeed = 3.0
    public static let minimumScale = 0.25
    public static let maximumScale = 4.0
    public static let minimumAutoCycleInterval: TimeInterval = 1

    public var speed: Double
    public var scale: Double
    public var intensity: Double
    public var trailing: Double
    public var autoCycleInterval: TimeInterval
    public var matrixTrailLength: Double
    public var rainbowAmplitude: Double
    public var fireDecay: Double
    public var qualityLevel: Double

    public init(
        speed: Double = defaultSpeed,
        scale: Double = defaultScale,
        intensity: Double = defaultIntensity,
        trailing: Double = defaultTrailing,
        autoCycleInterval: TimeInterval = defaultAutoCycleInterval,
        matrixTrailLength: Double = defaultMatrixTrailLength,
        rainbowAmplitude: Double = defaultRainbowAmplitude,
        fireDecay: Double = defaultFireDecay,
        qualityLevel: Double = defaultQualityLevel
    ) {
        self.speed = Self.normalized(
            speed,
            default: Self.defaultSpeed,
            range: Self.minimumSpeed...Self.maximumSpeed
        )
        self.scale = Self.normalized(
            scale,
            default: Self.defaultScale,
            range: Self.minimumScale...Self.maximumScale
        )
        self.intensity = Self.normalizedUnit(
            intensity,
            default: Self.defaultIntensity
        )
        self.trailing = Self.normalizedUnit(
            trailing,
            default: Self.defaultTrailing
        )
        self.autoCycleInterval = Self.normalizedAutoCycleInterval(
            autoCycleInterval
        )
        self.matrixTrailLength = Self.normalizedUnit(
            matrixTrailLength,
            default: Self.defaultMatrixTrailLength
        )
        self.rainbowAmplitude = Self.normalizedUnit(
            rainbowAmplitude,
            default: Self.defaultRainbowAmplitude
        )
        self.fireDecay = Self.normalizedUnit(
            fireDecay,
            default: Self.defaultFireDecay
        )
        self.qualityLevel = Self.normalizedUnit(
            qualityLevel,
            default: Self.defaultQualityLevel
        )
    }

    public static let `default` = Self()

    /// Re-establishes invariants after callers mutate individual properties.
    public var normalized: Self {
        Self(
            speed: speed,
            scale: scale,
            intensity: intensity,
            trailing: trailing,
            autoCycleInterval: autoCycleInterval,
            matrixTrailLength: matrixTrailLength,
            rainbowAmplitude: rainbowAmplitude,
            fireDecay: fireDecay,
            qualityLevel: qualityLevel
        )
    }

    public static func normalizedAutoCycleInterval(
        _ value: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else { return defaultAutoCycleInterval }
        return max(minimumAutoCycleInterval, value)
    }

    private enum CodingKeys: String, CodingKey {
        case speed
        case scale
        case intensity
        case trailing
        case autoCycleInterval
        case matrixTrailLength
        case rainbowAmplitude
        case fireDecay
        case qualityLevel
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            speed: try values.decodeIfPresent(Double.self, forKey: .speed)
                ?? Self.defaultSpeed,
            scale: try values.decodeIfPresent(Double.self, forKey: .scale)
                ?? Self.defaultScale,
            intensity: try values.decodeIfPresent(Double.self, forKey: .intensity)
                ?? Self.defaultIntensity,
            trailing: try values.decodeIfPresent(Double.self, forKey: .trailing)
                ?? Self.defaultTrailing,
            autoCycleInterval: try values.decodeIfPresent(
                TimeInterval.self,
                forKey: .autoCycleInterval
            ) ?? Self.defaultAutoCycleInterval,
            matrixTrailLength: try values.decodeIfPresent(
                Double.self,
                forKey: .matrixTrailLength
            ) ?? Self.defaultMatrixTrailLength,
            rainbowAmplitude: try values.decodeIfPresent(
                Double.self,
                forKey: .rainbowAmplitude
            ) ?? Self.defaultRainbowAmplitude,
            fireDecay: try values.decodeIfPresent(Double.self, forKey: .fireDecay)
                ?? Self.defaultFireDecay,
            qualityLevel: try values.decodeIfPresent(
                Double.self,
                forKey: .qualityLevel
            ) ?? Self.defaultQualityLevel
        )
    }

    private static func normalizedUnit(
        _ value: Double,
        default defaultValue: Double
    ) -> Double {
        normalized(value, default: defaultValue, range: 0...1)
    }

    private static func normalized(
        _ value: Double,
        default defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// The creative portion of a future shared configuration schema.
public struct IdleScreenCreativeConfiguration: Codable, Equatable, Sendable {
    public var pattern: IdleScreenCreativePattern
    public var settings: IdleScreenCreativeSettings

    public init(
        pattern: IdleScreenCreativePattern = .autoCycle,
        settings: IdleScreenCreativeSettings = .default
    ) {
        self.pattern = pattern
        self.settings = settings.normalized
    }

    public static let `default` = Self()

    public var resolvedPattern: IdleScreenCreativePattern {
        pattern.resolved(
            at: 0,
            autoCycleInterval: settings.autoCycleInterval
        )
    }

    public func resolvedPattern(
        at elapsedTime: TimeInterval
    ) -> IdleScreenCreativePattern {
        pattern.resolved(
            at: elapsedTime,
            autoCycleInterval: settings.autoCycleInterval
        )
    }

    private enum CodingKeys: String, CodingKey {
        case pattern
        case settings
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawPattern = try values.decodeIfPresent(String.self, forKey: .pattern)
        pattern = rawPattern.flatMap(IdleScreenCreativePattern.init(rawValue:))
            ?? .autoCycle
        settings = try values.decodeIfPresent(
            IdleScreenCreativeSettings.self,
            forKey: .settings
        ) ?? .default
    }
}
