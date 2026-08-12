import Foundation

public enum IdleScreenPerformanceContractError: Error, Equatable, Sendable {
    case emptySamples
    case nonfiniteSample
    case insufficientMemorySamples
    case invalidMemorySampleOrder
    case invalidCadenceSampleOrder
    case incoherentCadenceAccounting(
        attempts: Int,
        completions: Int,
        submittedAttempts: Int,
        submissions: Int
    )
}

public struct IdleScreenPerformanceDistribution: Codable, Equatable, Sendable {
    public let count: Int
    public let minimum: Double
    public let median: Double
    public let p95: Double
    public let p99: Double
    public let maximum: Double
    public let mean: Double

    public init(samples: [Double]) throws {
        guard !samples.isEmpty else {
            throw IdleScreenPerformanceContractError.emptySamples
        }
        guard samples.allSatisfy(\.isFinite) else {
            throw IdleScreenPerformanceContractError.nonfiniteSample
        }
        let ordered = samples.sorted()
        count = ordered.count
        minimum = ordered[0]
        median = Self.nearestRank(0.5, in: ordered)
        p95 = Self.nearestRank(0.95, in: ordered)
        p99 = Self.nearestRank(0.99, in: ordered)
        maximum = ordered[ordered.count - 1]
        mean = ordered.reduce(0, +) / Double(ordered.count)
    }

    private static func nearestRank(
        _ percentile: Double,
        in ordered: [Double]
    ) -> Double {
        let rank = Int(ceil(percentile * Double(ordered.count)))
        return ordered[min(ordered.count - 1, max(0, rank - 1))]
    }
}

public enum IdleScreenPerformanceWorkload: String, Codable, CaseIterable,
    Equatable, Hashable, Sendable
{
    case rendererStartupCold
    case rendererStartupWarm
    case generative
    case cameraSynthetic
    case pixelMaterialsSand
    case pixelMaterialsWater
    case pixelMaterialsMixed
    case mailboxTransport
    case agentSignalPolling
    case helperIdle
    case zeroConsumer
}

public enum IdleScreenPerformanceMetric: String, Codable, CaseIterable,
    Equatable, Hashable, Sendable
{
    case startupFirstFrameP95Milliseconds
    case cpuFrameP95Milliseconds
    case gpuFrameP95Milliseconds
    case frameIntervalP95Milliseconds
    /// Host attempt start through camera preparation and synchronous draw
    /// return. This excludes pacing wait, GPU completion, and presentation.
    case attemptDurationP95Milliseconds
    case droppedFrameRatio
    case deadlineMissRatio
    case averageCPUPercent
    case peakResidentMemoryBytes
    case residentMemoryGrowthBytesPerHour
    case wakeupsPerSecond
    case averageEnergyImpact
    case operationP95Milliseconds
}

public enum IdleScreenPerformanceUnit: String, Codable, Equatable, Hashable,
    Sendable
{
    case milliseconds
    case ratio
    case percent
    case bytes
    case bytesPerHour
    case eventsPerSecond
    case energyImpact
}

public struct IdleScreenPerformanceMeasurement: Codable, Equatable, Sendable {
    public let workload: IdleScreenPerformanceWorkload
    public let metric: IdleScreenPerformanceMetric
    public let value: Double
    public let unit: IdleScreenPerformanceUnit

    public init(
        workload: IdleScreenPerformanceWorkload,
        metric: IdleScreenPerformanceMetric,
        value: Double,
        unit: IdleScreenPerformanceUnit
    ) {
        self.workload = workload
        self.metric = metric
        self.value = value
        self.unit = unit
    }
}

public struct IdleScreenPerformanceBudgetLimit: Codable, Equatable, Sendable {
    public let workload: IdleScreenPerformanceWorkload
    public let metric: IdleScreenPerformanceMetric
    public let maximum: Double
    public let unit: IdleScreenPerformanceUnit

    public init(
        workload: IdleScreenPerformanceWorkload,
        metric: IdleScreenPerformanceMetric,
        maximum: Double,
        unit: IdleScreenPerformanceUnit
    ) {
        self.workload = workload
        self.metric = metric
        self.maximum = maximum
        self.unit = unit
    }
}

public enum IdleScreenPerformanceBudgetStatus: String, Codable, Equatable,
    Sendable
{
    case passed
    case overBudget
    case missing
    case unitMismatch
    case invalid
}

public struct IdleScreenPerformanceBudgetResult: Codable, Equatable, Sendable {
    public let limit: IdleScreenPerformanceBudgetLimit
    public let measurement: IdleScreenPerformanceMeasurement?
    public let status: IdleScreenPerformanceBudgetStatus
}

public struct IdleScreenPerformanceBudgetEvaluation: Codable, Equatable,
    Sendable
{
    public let passed: Bool
    public let results: [IdleScreenPerformanceBudgetResult]
}

public struct IdleScreenPerformanceBudgetSet: Codable, Equatable, Sendable {
    public let identifier: String
    public let hardwareClass: String
    public let displayCount: Int
    public let displayPixelWidth: Int
    public let displayPixelHeight: Int
    public let displayScale: Double
    public let metalDeviceName: String
    public let colorPixelFormat: String
    public let targetFramesPerSecond: Int
    public let limits: [IdleScreenPerformanceBudgetLimit]

    public init(
        identifier: String,
        hardwareClass: String,
        displayCount: Int,
        displayPixelWidth: Int = 0,
        displayPixelHeight: Int = 0,
        displayScale: Double = 0,
        metalDeviceName: String = "",
        colorPixelFormat: String = "",
        targetFramesPerSecond: Int,
        limits: [IdleScreenPerformanceBudgetLimit]
    ) {
        self.identifier = identifier
        self.hardwareClass = hardwareClass
        self.displayCount = displayCount
        self.displayPixelWidth = displayPixelWidth
        self.displayPixelHeight = displayPixelHeight
        self.displayScale = displayScale
        self.metalDeviceName = metalDeviceName
        self.colorPixelFormat = colorPixelFormat
        self.targetFramesPerSecond = targetFramesPerSecond
        self.limits = limits
    }

    public func evaluate(
        _ measurements: [IdleScreenPerformanceMeasurement]
    ) -> IdleScreenPerformanceBudgetEvaluation {
        let results = limits.map { limit in
            guard let measurement = measurements.first(where: {
                $0.workload == limit.workload && $0.metric == limit.metric
            }) else {
                return IdleScreenPerformanceBudgetResult(
                    limit: limit,
                    measurement: nil,
                    status: .missing
                )
            }
            let status: IdleScreenPerformanceBudgetStatus
            if measurement.unit != limit.unit {
                status = .unitMismatch
            } else if !measurement.value.isFinite || measurement.value < 0 {
                status = .invalid
            } else if measurement.value <= limit.maximum {
                status = .passed
            } else {
                status = .overBudget
            }
            return IdleScreenPerformanceBudgetResult(
                limit: limit,
                measurement: measurement,
                status: status
            )
        }
        return .init(
            passed: results.allSatisfy { $0.status == .passed },
            results: results
        )
    }

    public func validate(
        environment: IdleScreenPerformanceBudgetEnvironment
    ) -> IdleScreenPerformanceBudgetEnvironmentValidation {
        var mismatches: [IdleScreenPerformanceEnvironmentMismatch] = []
        func compare<T: CustomStringConvertible & Equatable>(
            _ field: String,
            _ expected: T,
            _ actual: T
        ) {
            guard expected != actual else { return }
            mismatches.append(.init(
                field: field,
                expected: expected.description,
                actual: actual.description
            ))
        }

        compare("hardwareClass", hardwareClass, environment.hardwareClass)
        compare("display.count", displayCount, environment.display.count)
        compare(
            "display.pixelWidth",
            displayPixelWidth,
            environment.display.pixelWidth
        )
        compare(
            "display.pixelHeight",
            displayPixelHeight,
            environment.display.pixelHeight
        )
        compare("display.scale", displayScale, environment.display.scale)
        compare(
            "targetFramesPerSecond",
            targetFramesPerSecond,
            environment.targetFramesPerSecond
        )
        compare(
            "renderSurface.drawableWidth",
            displayPixelWidth,
            environment.renderSurface.drawableWidth
        )
        compare(
            "renderSurface.drawableHeight",
            displayPixelHeight,
            environment.renderSurface.drawableHeight
        )
        compare(
            "renderSurface.deviceName",
            metalDeviceName,
            environment.renderSurface.deviceName
        )
        compare(
            "renderSurface.colorPixelFormat",
            colorPixelFormat,
            environment.renderSurface.colorPixelFormat
        )
        let expectedLogicalWidth = Int(
            (Double(displayPixelWidth) / max(displayScale, 0.000_001)).rounded()
        )
        let expectedLogicalHeight = Int(
            (Double(displayPixelHeight) / max(displayScale, 0.000_001)).rounded()
        )
        compare(
            "renderSurface.logicalWidth",
            expectedLogicalWidth,
            environment.renderSurface.logicalWidth
        )
        compare(
            "renderSurface.logicalHeight",
            expectedLogicalHeight,
            environment.renderSurface.logicalHeight
        )
        return .init(mismatches: mismatches)
    }
}

public enum IdleScreenPerformanceBudgets {
    /// R1.1 budgets for this named development/release floor. They are not
    /// presented as universal limits for every supported Mac. A later hardware
    /// matrix may add budget sets without silently weakening this one.
    public static let m4ProSingleDisplay = IdleScreenPerformanceBudgetSet(
        identifier:
            "m4-pro-4112x2658-single-display-r1.1-v2-render-capacity",
        hardwareClass: "Apple M4 Pro 20-core GPU",
        displayCount: 1,
        displayPixelWidth: 4_112,
        displayPixelHeight: 2_658,
        displayScale: 2,
        metalDeviceName: "Apple M4 Pro",
        colorPixelFormat: "bgra8Unorm",
        targetFramesPerSecond: 30,
        limits: [
            limit(.rendererStartupCold, .startupFirstFrameP95Milliseconds, 500, .milliseconds),
            limit(.rendererStartupWarm, .startupFirstFrameP95Milliseconds, 200, .milliseconds),
        ]
        + renderLimit(.generative)
        + renderLimit(.cameraSynthetic)
        + renderLimit(.pixelMaterialsSand)
        + renderLimit(.pixelMaterialsWater)
        + renderLimit(.pixelMaterialsMixed)
        + [
            limit(.mailboxTransport, .operationP95Milliseconds, 5, .milliseconds),
            limit(.agentSignalPolling, .operationP95Milliseconds, 2, .milliseconds),
            limit(.agentSignalPolling, .averageCPUPercent, 2, .percent),
            limit(.agentSignalPolling, .wakeupsPerSecond, 4, .eventsPerSecond),
            limit(.agentSignalPolling, .averageEnergyImpact, 1, .energyImpact),
            limit(.helperIdle, .averageCPUPercent, 1, .percent),
            limit(.helperIdle, .peakResidentMemoryBytes, 180 * 1_024 * 1_024, .bytes),
            limit(.helperIdle, .wakeupsPerSecond, 4, .eventsPerSecond),
            limit(.helperIdle, .averageEnergyImpact, 1, .energyImpact),
            limit(.zeroConsumer, .averageCPUPercent, 1, .percent),
            limit(.zeroConsumer, .residentMemoryGrowthBytesPerHour, 4 * 1_024 * 1_024, .bytesPerHour),
            limit(.zeroConsumer, .wakeupsPerSecond, 4, .eventsPerSecond),
            limit(.zeroConsumer, .averageEnergyImpact, 1, .energyImpact),
        ]
    )

    private static func renderLimit(
        _ workload: IdleScreenPerformanceWorkload
    ) -> [IdleScreenPerformanceBudgetLimit] {
        [
            limit(workload, .cpuFrameP95Milliseconds, 20, .milliseconds),
            limit(workload, .gpuFrameP95Milliseconds, 12, .milliseconds),
            limit(
                workload,
                .attemptDurationP95Milliseconds,
                20,
                .milliseconds
            ),
            limit(workload, .droppedFrameRatio, 0.01, .ratio),
            limit(workload, .deadlineMissRatio, 0.01, .ratio),
            limit(workload, .averageCPUPercent, 100, .percent),
            // The named baseline now binds an actual 4112x2658 drawable. One
            // BGRA surface is 43,718,784 bytes, so a three-surface presentation
            // pool adds about 125 MiB before renderer buffers and framework
            // residency. The prior 384 MiB limit was measured accidentally at
            // half-resolution and is not comparable to this physical surface.
            limit(workload, .peakResidentMemoryBytes, 512 * 1_024 * 1_024, .bytes),
            limit(workload, .residentMemoryGrowthBytesPerHour, 16 * 1_024 * 1_024, .bytesPerHour),
            limit(workload, .wakeupsPerSecond, 150, .eventsPerSecond),
            limit(workload, .averageEnergyImpact, 25, .energyImpact),
        ]
    }

    private static func limit(
        _ workload: IdleScreenPerformanceWorkload,
        _ metric: IdleScreenPerformanceMetric,
        _ maximum: Double,
        _ unit: IdleScreenPerformanceUnit
    ) -> IdleScreenPerformanceBudgetLimit {
        .init(
            workload: workload,
            metric: metric,
            maximum: maximum,
            unit: unit
        )
    }
}

public struct IdleScreenPerformanceHardware: Codable, Equatable, Sendable {
    public let modelIdentifier: String
    public let chip: String
    public let cpuCoreCount: Int
    public let gpuCoreCount: Int
    public let memoryBytes: UInt64

    public init(
        modelIdentifier: String,
        chip: String,
        cpuCoreCount: Int,
        gpuCoreCount: Int,
        memoryBytes: UInt64
    ) {
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.cpuCoreCount = cpuCoreCount
        self.gpuCoreCount = gpuCoreCount
        self.memoryBytes = memoryBytes
    }
}

public struct IdleScreenPerformanceOperatingSystem: Codable, Equatable,
    Sendable
{
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }
}

public struct IdleScreenPerformanceDisplay: Codable, Equatable, Sendable {
    public let count: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: Double

    public init(
        count: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: Double
    ) {
        self.count = count
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }
}

public struct IdleScreenPerformanceRenderSurface: Codable, Equatable, Sendable {
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let drawableWidth: Int
    public let drawableHeight: Int
    public let deviceName: String
    public let deviceRegistryID: UInt64
    public let colorPixelFormat: String

    public init(
        logicalWidth: Int,
        logicalHeight: Int,
        drawableWidth: Int,
        drawableHeight: Int,
        deviceName: String,
        deviceRegistryID: UInt64,
        colorPixelFormat: String
    ) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.drawableWidth = drawableWidth
        self.drawableHeight = drawableHeight
        self.deviceName = deviceName
        self.deviceRegistryID = deviceRegistryID
        self.colorPixelFormat = colorPixelFormat
    }
}

public struct IdleScreenPerformanceBudgetEnvironment: Codable, Equatable,
    Sendable
{
    public let hardwareClass: String
    public let display: IdleScreenPerformanceDisplay
    public let targetFramesPerSecond: Int
    public let renderSurface: IdleScreenPerformanceRenderSurface

    public init(
        hardwareClass: String,
        display: IdleScreenPerformanceDisplay,
        targetFramesPerSecond: Int,
        renderSurface: IdleScreenPerformanceRenderSurface
    ) {
        self.hardwareClass = hardwareClass
        self.display = display
        self.targetFramesPerSecond = targetFramesPerSecond
        self.renderSurface = renderSurface
    }
}

public struct IdleScreenPerformanceEnvironmentMismatch: Codable, Equatable,
    Sendable
{
    public let field: String
    public let expected: String
    public let actual: String

    public init(field: String, expected: String, actual: String) {
        self.field = field
        self.expected = expected
        self.actual = actual
    }
}

public struct IdleScreenPerformanceBudgetEnvironmentValidation: Codable,
    Equatable, Sendable
{
    public let passed: Bool
    public let mismatches: [IdleScreenPerformanceEnvironmentMismatch]

    public init(mismatches: [IdleScreenPerformanceEnvironmentMismatch]) {
        passed = mismatches.isEmpty
        self.mismatches = mismatches
    }
}

public struct IdleScreenPerformanceReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runIdentifier: String
    public let capturedAt: Date
    public let commit: String
    public let artifactSHA256: String
    public let hardware: IdleScreenPerformanceHardware
    public let operatingSystem: IdleScreenPerformanceOperatingSystem
    public let display: IdleScreenPerformanceDisplay
    public let budgetsIdentifier: String
    public let measurements: [IdleScreenPerformanceMeasurement]
    public let budgetEvaluation: IdleScreenPerformanceBudgetEvaluation?
    public let notes: [String]

    public init(
        schemaVersion: Int,
        runIdentifier: String,
        capturedAt: Date,
        commit: String,
        artifactSHA256: String,
        hardware: IdleScreenPerformanceHardware,
        operatingSystem: IdleScreenPerformanceOperatingSystem,
        display: IdleScreenPerformanceDisplay,
        budgetsIdentifier: String,
        measurements: [IdleScreenPerformanceMeasurement],
        budgetEvaluation: IdleScreenPerformanceBudgetEvaluation? = nil,
        notes: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.runIdentifier = runIdentifier
        self.capturedAt = capturedAt
        self.commit = commit
        self.artifactSHA256 = artifactSHA256
        self.hardware = hardware
        self.operatingSystem = operatingSystem
        self.display = display
        self.budgetsIdentifier = budgetsIdentifier
        self.measurements = measurements
        self.budgetEvaluation = budgetEvaluation
        self.notes = notes
    }
}

public extension JSONEncoder {
    static var idleScreenPerformance: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var idleScreenPerformance: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
