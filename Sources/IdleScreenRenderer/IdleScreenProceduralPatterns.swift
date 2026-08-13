import Foundation

/// Renderer-local procedural controls. This type intentionally mirrors the
/// core model by value rather than importing IdleScreenCore, keeping the
/// renderer framework usable by both static and dynamic hosts.
public struct IdleScreenProceduralPatternSettings: Equatable, Sendable {
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
        speed: Double = 1,
        scale: Double = 1,
        intensity: Double = 0.5,
        trailing: Double = 0.5,
        autoCycleInterval: TimeInterval = 30,
        matrixTrailLength: Double = 0.5,
        rainbowAmplitude: Double = 0.5,
        fireDecay: Double = 0.5,
        qualityLevel: Double = 0.7
    ) {
        self.speed = speed
        self.scale = scale
        self.intensity = intensity
        self.trailing = trailing
        self.autoCycleInterval = autoCycleInterval
        self.matrixTrailLength = matrixTrailLength
        self.rainbowAmplitude = rainbowAmplitude
        self.fireDecay = fireDecay
        self.qualityLevel = qualityLevel
    }

    public static let `default` = Self()

    fileprivate var normalized: Self {
        Self(
            speed: Self.clamp(speed, fallback: 1, to: 0.1...3),
            scale: Self.clamp(scale, fallback: 1, to: 0.25...4),
            intensity: Self.clamp(intensity, fallback: 0.5, to: 0...1),
            trailing: Self.clamp(trailing, fallback: 0.5, to: 0...1),
            autoCycleInterval: Self.clamp(
                autoCycleInterval,
                fallback: 30,
                to: 1...TimeInterval.greatestFiniteMagnitude
            ),
            matrixTrailLength: Self.clamp(
                matrixTrailLength,
                fallback: 0.5,
                to: 0...1
            ),
            rainbowAmplitude: Self.clamp(
                rainbowAmplitude,
                fallback: 0.5,
                to: 0...1
            ),
            fireDecay: Self.clamp(fireDecay, fallback: 0.5, to: 0...1),
            qualityLevel: Self.clamp(qualityLevel, fallback: 0.7, to: 0...1)
        )
    }

    private static func clamp(
        _ value: Double,
        fallback: Double,
        to range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// The production procedural result for one character-grid cell.
public struct IdleScreenProceduralCellSample: Equatable, Sendable {
    public let brightness: Float
    public let glyphIndex: Int

    public init(brightness: Float, glyphIndex: Int) {
        self.brightness = brightness
        self.glyphIndex = glyphIndex
    }

    public static let zero = Self(brightness: 0, glyphIndex: 0)
}

/// CPU cell kernels matching the legacy production Metal renderer.
///
/// Every public brightness is finite and bounded to `0...1`, and every glyph
/// index is bounded by the supplied glyph count. Unknown pattern raw values use
/// Perlin noise, matching the legacy renderer's safe fallback.
public enum IdleScreenProceduralPatterns {
    /// Stable auto-cycle order shared with the previous renderer.
    public static let patternRawValues = [
        "perlin",
        "plasma",
        "sweep",
        "matrixRain",
        "rainbowCycle",
        "fireEffect",
        "ripple",
        "voronoi",
        "warp",
        "staticNoise",
        "pulse",
        "dvdBounce",
        "metaballs",
        "starfield",
        "spiral",
        "terrain",
        "rainOnGlass",
        "aurora",
    ]

    public static func resolvedPatternRawValue(
        _ patternRawValue: String,
        at elapsedTime: TimeInterval,
        autoCycleInterval: TimeInterval = 30
    ) -> String {
        guard patternRawValue == "autoCycle" else {
            return patternRawValues.contains(patternRawValue)
                ? patternRawValue
                : "perlin"
        }

        let interval = normalizedInterval(autoCycleInterval)
        let elapsed = elapsedTime.isFinite ? max(0, elapsedTime) : 0
        let cyclePosition = (elapsed / interval).truncatingRemainder(
            dividingBy: Double(patternRawValues.count)
        )
        let slot = Int(cyclePosition.rounded(.down))
        return patternRawValues[slot]
    }

    /// Returns the production brightness and glyph selection for one cell.
    public static func cellSample(
        patternRawValue: String,
        settings rawSettings: IdleScreenProceduralPatternSettings = .default,
        column rawColumn: Int,
        row rawRow: Int,
        columns: Int,
        rows: Int,
        glyphCount: Int,
        time: TimeInterval,
        viewport: IdleScreenRendererViewport = .full,
        sceneSeed: UInt64 = 0,
        sceneBrightness: Double = 1
    ) -> IdleScreenProceduralCellSample {
        guard columns > 0, rows > 0, glyphCount > 0 else { return .zero }

        let settings = rawSettings.normalized
        let coordinate = viewport.coordinate(
            column: rawColumn,
            row: rawRow,
            columns: columns,
            rows: rows,
            sceneSeed: sceneSeed
        )
        let column = coordinate.column
        let row = coordinate.row
        let columns = coordinate.columns
        let rows = coordinate.rows
        let elapsed = time.isFinite ? max(0, time) : 0
        let convertedTimestamp = Float(elapsed)
        let timestamp = convertedTimestamp.isFinite ? convertedTimestamp : 0
        let speed = Float(settings.speed)
        let scale = Float(settings.scale)
        let effectiveIntensity = Float(
            settings.intensity * settings.qualityLevel
        )
        let trailing = Float(settings.trailing)
        let pattern = resolvedPatternRawValue(
            patternRawValue,
            at: elapsed,
            autoCycleInterval: settings.autoCycleInterval
        )

        let value: Float
        switch pattern {
        case "plasma":
            value = plasma(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        case "sweep":
            value = sweep(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        case "matrixRain":
            value = matrixRain(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed,
                trailControl: Float(settings.matrixTrailLength),
                intensity: effectiveIntensity
            )
        case "rainbowCycle":
            value = rainbowCycle(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                amplitudeControl: Float(settings.rainbowAmplitude),
                intensity: effectiveIntensity, trailing: trailing
            )
        case "fireEffect":
            value = fireEffect(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                decayControl: Float(settings.fireDecay),
                intensity: effectiveIntensity, trailing: trailing
            )
        case "ripple":
            value = ripple(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        case "voronoi":
            value = voronoi(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        case "warp":
            value = warp(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        case "staticNoise":
            value = staticNoise(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed,
                intensity: effectiveIntensity, trailing: trailing
            )
        case "pulse":
            value = pulse(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        case "dvdBounce":
            value = dvdBounce(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                trailing: trailing
            )
        case "metaballs":
            value = metaballs(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        case "starfield":
            value = starfield(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        case "spiral":
            value = spiral(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        case "terrain":
            value = terrain(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        case "rainOnGlass":
            value = rainOnGlass(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        case "aurora":
            value = aurora(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        default:
            value = perlin(
                column: column, row: row, columns: columns, rows: rows,
                timestamp: timestamp, speed: speed, scale: scale,
                intensity: effectiveIntensity, trailing: trailing
            )
        }

        let brightnessScale = sceneBrightness.isFinite
            ? min(1, max(0, sceneBrightness))
            : 1
        let brightness = bounded(value) * Float(brightnessScale)
        let maximumGlyphIndex = min(glyphCount - 1, Int(UInt32.max))
        let glyphSignal: Float
        if pattern == "matrixRain" {
            let shuffleRate: Float = brightness > 0.01 ? 6 : 0.5
            let rawTick = floorf(timestamp * shuffleRate)
            let tick = rawTick.isFinite ? rawTick : 0
            glyphSignal = bounded(
                hash2D(
                    x: Float(column) * 3.17 + tick,
                    y: Float(row) * 5.23
                )
            )
        } else {
            glyphSignal = brightness
        }
        let glyphIndex = Int(
            (Double(glyphSignal) * Double(maximumGlyphIndex)).rounded(.down)
        )
        return IdleScreenProceduralCellSample(
            brightness: brightness,
            glyphIndex: min(maximumGlyphIndex, glyphIndex)
        )
    }

    /// Convenience for callers that do not need production glyph selection.
    public static func brightness(
        patternRawValue: String,
        settings: IdleScreenProceduralPatternSettings = .default,
        column: Int,
        row: Int,
        columns: Int,
        rows: Int,
        time: TimeInterval
    ) -> Float {
        cellSample(
            patternRawValue: patternRawValue,
            settings: settings,
            column: column,
            row: row,
            columns: columns,
            rows: rows,
            glyphCount: 1,
            time: time
        ).brightness
    }

    private static func perlin(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let x = u * 10 * scale + timestamp * 0.3 * speed
        let y = v * 10 * scale + timestamp * 0.3 * speed
        let octaves = 1 + Int(intensity * 3)
        let contrast = 0.5 + trailing * 1.5
        var noise: Float = 0
        var amplitude: Float = 1
        var frequency: Float = 1
        var totalAmplitude: Float = 0
        for _ in 0..<octaves {
            noise += amplitude * smoothNoise2D(x: x * frequency, y: y * frequency)
            totalAmplitude += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return powf(noise / totalAmplitude, 1 / contrast)
    }

    private static func plasma(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let x = Float(column) / Float(columns) * 10 * scale
        let y = Float(row) / Float(rows) * 10 * scale
        let t = timestamp * speed
        let waveCount = 3 + Int(intensity * 5)
        let amplitude = 0.3 + trailing * 0.7
        var sum: Float = 0
        for wave in 0..<waveCount {
            let w = Float(wave)
            let xWave = sinf(x * (1 + w * 0.3) + t * (1 + w * 0.2))
            let yWave = sinf(y * (1 + w * 0.2) + t * (1.3 + w * 0.15))
            let diagonal = sinf(
                (x + y) * (0.7 + w * 0.1) + t * (0.7 + w * 0.3)
            )
            sum += (xWave + yWave + diagonal) * amplitude
        }
        return sum / Float(waveCount * 3) * 0.5 + 0.5
    }

    private static func sweep(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let bandCount = 1 + Int(intensity * 5)
        let softness = 0.1 + trailing * 0.9
        let diagonal = (u + v) * Float(bandCount) * scale
            + timestamp * 0.2 * speed
        return smoothstep(0, softness, positiveRemainder(diagonal, divisor: 1))
    }

    private static func matrixRain(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, trailControl: Float,
        intensity: Float
    ) -> Float {
        _ = columns
        let trailLength = 2 + trailControl * 18
        let totalHeight = Float(rows) + trailLength
        let dropCount = 1 + Int(intensity * 5)
        var brightness: Float = 0
        for drop in 0..<dropCount {
            let seed = Float(column) * 1.71 + Float(drop) * 13.37
            let dropSpeed = (0.3 + hash2D(x: seed, y: 0) * 1.2) * speed
            let offset = hash2D(x: seed * 2.93, y: 1 + Float(drop))
                * totalHeight
            let head = positiveRemainder(
                timestamp * dropSpeed + offset,
                divisor: totalHeight
            )
            var distance = head - Float(row)
            if distance < 0 { distance += totalHeight }
            if distance <= trailLength {
                brightness = max(
                    brightness,
                    expf(-3 * distance / trailLength)
                )
            }
        }
        return brightness
    }

    private static func rainbowCycle(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        amplitudeControl: Float, intensity: Float, trailing: Float
    ) -> Float {
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let amplitude = 0.05 + amplitudeControl * 0.45
        let layers = 1 + Int(intensity * 3)
        let contrastBoost = 0.5 + trailing * 1.5
        var sum: Float = 0
        for layer in 0..<layers {
            let frequency = 1 + Float(layer) * 0.7
            let phase = Float(layer) * 0.5
            let hue = positiveRemainder(
                (u + v) * scale * frequency + timestamp * 0.3 * speed + phase,
                divisor: 1
            )
            sum += 0.5 + amplitude * sinf(hue * 2 * .pi)
        }
        return powf(sum / Float(layers), contrastBoost)
    }

    private static func fireEffect(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        decayControl: Float, intensity: Float, trailing: Float
    ) -> Float {
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let turbulence = 0.5 + intensity * 1.5
        let spreadWidth = 10 + trailing * 30
        let decay = 0.92 + decayControl * 0.075
        let baseHeat = smoothNoise2D(
            x: u * spreadWidth * scale + timestamp * 2 * speed,
            y: 0
        )
        let turbulence1 = smoothNoise2D(
            x: u * spreadWidth * 2 * scale + timestamp * 3 * speed,
            y: v * 5 + timestamp * speed
        )
        let turbulence2 = smoothNoise2D(
            x: u * spreadWidth * 3 * scale + timestamp * 4 * speed + 7,
            y: v * 8 - timestamp * speed * 0.5
        )
        let combined = bounded(
            baseHeat * 0.5
                + turbulence1 * 0.3 * turbulence
                + turbulence2 * 0.2 * turbulence
        )
        var heat = (0.4 + combined * 0.6)
            * powf(decay, Float(rows - 1 - row))
        heat = heat * heat * (3 - 2 * heat)
        let jitterRange = 0.05 + turbulence * 0.15
        let jitter = 1 - jitterRange + jitterRange * hash2D(
            x: Float(column) * 7.13,
            y: Float(row) * 11.37 + timestamp * 3 * speed
        )
        return heat * jitter
    }

    private static func ripple(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let sourceCount = 2 + Int(intensity * 6)
        let waveWidth = 4 + trailing * 12
        var sum: Float = 0
        for source in 0..<sourceCount {
            let centerX = hash2D(x: Float(source) * 7.13, y: 1)
            let centerY = hash2D(x: Float(source) * 3.71, y: 2)
            let dx = u - centerX
            let dy = v - centerY
            sum += sinf(sqrtf(dx * dx + dy * dy) * waveWidth * scale
                - timestamp * speed)
        }
        return sum / Float(sourceCount) * 0.5 + 0.5
    }

    private static func voronoi(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let seedCount = 3 + Int(intensity * 13)
        let edgeFactor = 2 + (1 - trailing) * 4
        var minimumDistanceSquared = Float.greatestFiniteMagnitude
        for seed in 0..<seedCount {
            let index = Float(seed)
            let baseX = hash2D(x: index * 5.17, y: 3)
            let baseY = hash2D(x: index * 9.31, y: 4)
            let deltaX = hash2D(x: index * 2.53, y: 5) - 0.5
            let deltaY = hash2D(x: index * 6.79, y: 6) - 0.5
            let seedX = baseX + deltaX * sinf(timestamp * speed * 0.3 + index)
            let seedY = baseY
                + deltaY * cosf(timestamp * speed * 0.4 + index * 1.3)
            let dx = (u - seedX) * scale
            let dy = (v - seedY) * scale
            minimumDistanceSquared = min(
                minimumDistanceSquared,
                dx * dx + dy * dy
            )
        }
        return 1 - sqrtf(minimumDistanceSquared) * edgeFactor
    }

    private static func warp(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let dx = Float(column) / Float(columns) - 0.5
        let dy = Float(row) / Float(rows) - 0.5
        let radius = sqrtf(dx * dx + dy * dy) + 0.001
        let angle = atan2f(dy, dx)
        let angularFrequency = 1 + intensity * 7
        let distortion = 5 + trailing * 15
        return sinf(
            logf(radius) * distortion * scale
                - timestamp * speed
                + angle * angularFrequency
        ) * 0.5 + 0.5
    }

    private static func staticNoise(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, intensity: Float, trailing: Float
    ) -> Float {
        _ = rows
        let glitchRate = 3 + intensity * 27
        let bandSize = 1 + trailing * 4
        let quantizedRow = floorf(Float(row) / bandSize) * bandSize
        let bandOffset = hash2D(
            x: quantizedRow + floorf(timestamp * glitchRate * speed),
            y: 0
        )
        return hash2D(
            x: Float(column) + bandOffset * Float(columns),
            y: quantizedRow + floorf(timestamp * glitchRate * 2 * speed)
        )
    }

    private static func pulse(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let dx = (Float(column) / Float(columns) - 0.5) * scale
        let dy = (Float(row) / Float(rows) - 0.5) * scale
        let distance = sqrtf(dx * dx + dy * dy)
        let ringCount = 2 + Int(intensity * 6)
        let ringWidth = 0.02 + trailing * 0.13
        let maximumRadius = 1.5 * scale
        let spacing = maximumRadius / Float(ringCount)
        var sum: Float = 0
        for ring in 0..<ringCount {
            let position = positiveRemainder(
                timestamp * speed * 0.5 + Float(ring) * spacing,
                divisor: maximumRadius
            )
            let brightness = smoothstep(
                ringWidth,
                0,
                abs(distance - position)
            )
            sum += brightness * (1 - position / maximumRadius)
        }
        return sum
    }

    private static func dvdBounce(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float, trailing: Float
    ) -> Float {
        let width = 0.15 / scale
        let height = 0.10 / scale
        let rangeX = 1 - width
        let rangeY = 1 - height
        var x = positiveRemainder(timestamp * speed * 0.31, divisor: rangeX * 2)
        var y = positiveRemainder(timestamp * speed * 0.23, divisor: rangeY * 2)
        if x > rangeX { x = rangeX * 2 - x }
        if y > rangeY { y = rangeY * 2 - y }
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let dx = max(0, max(x - u, u - (x + width)))
        let dy = max(0, max(y - v, v - (y + height)))
        let glowRadius = 0.02 + trailing * 0.08
        return smoothstep(glowRadius, 0, sqrtf(dx * dx + dy * dy)) + 0.03
    }

    private static func metaballs(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let blobCount = 3 + Int(intensity * 7)
        var field: Float = 0
        for blob in 0..<blobCount {
            let index = Float(blob)
            let x = hash2D(x: index * 5.17, y: 3)
                + 0.3 * sinf(timestamp * speed * 0.4 + index * 2.1)
            let y = hash2D(x: index * 9.31, y: 4)
                + 0.3 * cosf(timestamp * speed * 0.3 + index * 1.7)
            let dx = (u - x) * scale
            let dy = (v - y) * scale
            field += (0.005 + trailing * 0.02) / (dx * dx + dy * dy + 0.001)
        }
        return field
    }

    private static func starfield(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let layers = min(3 + Int(intensity * 5), 8)
        let glowSize = 0.15 + trailing * 0.25
        var result: Float = 0
        for layer in 0..<layers {
            let index = Float(layer)
            let layerSpeed = (0.3 + index * 0.2) * speed
            let depth = 1 + index * 0.5
            let tileSize = 0.08 / (scale * depth)
            let offset = timestamp * layerSpeed * 0.1
            let sampleU = positiveRemainder(
                u + offset * 0.3 + index * 0.13,
                divisor: 1
            )
            let sampleV = positiveRemainder(
                v + offset * 0.2 + index * 0.17,
                divisor: 1
            )
            let cellX = floorf(sampleU / tileSize)
            let cellY = floorf(sampleV / tileSize)
            let localU = positiveRemainder(sampleU, divisor: tileSize) / tileSize
            let localV = positiveRemainder(sampleV, divisor: tileSize) / tileSize
            let starU = hash2D(x: cellX * 7.13 + index * 31, y: cellY * 11.37)
            let starV = hash2D(x: cellX * 3.71 + index * 47, y: cellY * 13.91)
            let dx = localU - starU
            let dy = localV - starV
            let twinkle = 0.6 + 0.4 * sinf(
                timestamp * speed * 2 + cellX * 5 + cellY * 7
            )
            let star = smoothstep(glowSize, 0, sqrtf(dx * dx + dy * dy))
                * twinkle
            result = max(result, star / depth)
        }
        return result
    }

    private static func spiral(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let dx = (u - 0.5) * scale
        let dy = (v - 0.5) * scale
        let radius = sqrtf(dx * dx + dy * dy) + 0.001
        let angle = atan2f(dy, dx)
        let core = 0.3 / (radius * 8 + 0.1)
        let tightness = 3 + trailing * 4
        let armCount = 2 + floorf(intensity * 4)
        let spiralAngle = angle - tightness * logf(radius + 0.01)
            + timestamp * speed * 0.2
        let armBrightness = powf(0.5 + 0.5 * cosf(spiralAngle * armCount), 4)
        let fade = expf(-radius * 3)
        let noise = smoothNoise2D(
            x: u * 20 * scale + timestamp * 0.1,
            y: v * 20 * scale
        )
        return core + armBrightness * fade * (0.7 + 0.3 * noise)
    }

    private static func terrain(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let x = u * 6 * scale + timestamp * speed * 0.05
        let y = v * 6 * scale + timestamp * speed * 0.03
        let height = smoothNoise2D(x: x, y: y) * 0.6
            + smoothNoise2D(x: x * 2 + 5, y: y * 2 + 5) * 0.3
            + smoothNoise2D(x: x * 4 + 10, y: y * 4 + 10) * 0.1
        let contourCount = 5 + intensity * 15
        let lineWidth = 0.05 + trailing * 0.35
        let phase = positiveRemainder(height * contourCount, divisor: 1)
        let contour = smoothstep(lineWidth, 0, phase)
            + smoothstep(lineWidth, 0, 1 - phase)
        return contour * 0.85 + height * 0.15
    }

    private static func rainOnGlass(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let streakCount = 5 + Int(intensity * 10)
        let trailLength = 0.1 + trailing * 0.4
        var result: Float = 0
        for streak in 0..<streakCount {
            let index = Float(streak)
            let x = hash2D(x: index * 7.13, y: 1)
            let width = 0.01 + hash2D(x: index * 3.71, y: 2) * 0.03
            let streakSpeed = 0.1 + hash2D(x: index * 11.37, y: 3) * 0.3
            let wobble = 0.01 * sinf(
                v * 20 * scale + timestamp * speed + index * 5
            )
            let xDistance = abs(u - x - wobble)
            guard xDistance < width else { continue }
            let headY = positiveRemainder(
                timestamp * speed * streakSpeed + hash2D(x: index * 5, y: 4),
                divisor: 1.3
            )
            let yDistance = headY - v
            if yDistance > 0, yDistance < trailLength {
                let xFade = 1 - xDistance / width
                let yFade = 1 - yDistance / trailLength
                result = max(result, xFade * yFade * yFade)
            }
        }
        let wetness = 0.02 + 0.03 * smoothNoise2D(
            x: u * 30,
            y: v * 30 + timestamp * 0.5
        )
        return result + wetness
    }

    private static func aurora(
        column: Int, row: Int, columns: Int, rows: Int,
        timestamp: Float, speed: Float, scale: Float,
        intensity: Float, trailing: Float
    ) -> Float {
        let u = Float(column) / Float(columns)
        let v = Float(row) / Float(rows)
        let curtainCount = 2 + Int(intensity * 4)
        let curtainWidth = 0.03 + trailing * 0.08
        var result: Float = 0
        for curtain in 0..<curtainCount {
            let index = Float(curtain)
            let waveSpeed = (0.5 + index * 0.3) * speed
            let wave = 0.3 + index * 0.12
                + 0.08 * sinf(u * 8 * scale + timestamp * waveSpeed + index * 2)
                + 0.04 * sinf(
                    u * 15 * scale - timestamp * waveSpeed * 0.7 + index * 5
                )
                + 0.02 * sinf(
                    u * 25 * scale + timestamp * waveSpeed * 1.3
                )
            let curtainBrightness = smoothstep(curtainWidth, 0, abs(v - wave))
            let shimmer = 0.7 + 0.3 * sinf(
                u * 40 * scale + timestamp * speed * 3 + index * 11
            )
            result += curtainBrightness * shimmer * (0.6 + 0.4 / Float(curtain + 1))
        }
        return result
    }

    private static func normalizedInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 30 }
        return max(1, value)
    }

    private static func positiveRemainder(
        _ value: Float,
        divisor: Float
    ) -> Float {
        guard divisor.isFinite, divisor > 0 else { return 0 }
        let remainder = value.truncatingRemainder(dividingBy: divisor)
        return remainder < 0 ? remainder + divisor : remainder
    }

    private static func smoothNoise2D(x: Float, y: Float) -> Float {
        let integerX = floorf(x)
        let integerY = floorf(y)
        let fractionalX = x - integerX
        let fractionalY = y - integerY
        let xInterpolation = smootherStep(fractionalX)
        let yInterpolation = smootherStep(fractionalY)
        let lower = mix(
            hash2D(x: integerX, y: integerY),
            hash2D(x: integerX + 1, y: integerY),
            amount: xInterpolation
        )
        let upper = mix(
            hash2D(x: integerX, y: integerY + 1),
            hash2D(x: integerX + 1, y: integerY + 1),
            amount: xInterpolation
        )
        return mix(lower, upper, amount: yInterpolation)
    }

    private static func hash2D(x: Float, y: Float) -> Float {
        let sine = sinf(x * 127.1 + y * 311.7) * 43_758.5453123
        return sine - floorf(sine)
    }

    private static func mix(_ a: Float, _ b: Float, amount: Float) -> Float {
        a + (b - a) * amount
    }

    private static func smoothstep(
        _ edge0: Float,
        _ edge1: Float,
        _ value: Float
    ) -> Float {
        let denominator = edge1 - edge0
        guard denominator != 0 else { return value < edge0 ? 0 : 1 }
        let t = bounded((value - edge0) / denominator)
        return t * t * (3 - 2 * t)
    }

    private static func smootherStep(_ value: Float) -> Float {
        value * value * value * (value * (value * 6 - 15) + 10)
    }

    private static func bounded(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
