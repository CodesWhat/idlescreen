import Foundation

public enum IdleScreenPixelMaterialsError: Error, Equatable, Sendable {
    case invalidDimensions
    case invalidCellStorage
    case insufficientTerrainSpace
}

public enum IdleScreenRenderedMaterial: String, Codable, CaseIterable,
    Equatable, Hashable, Sendable
{
    case sand
    case water
    case mixed
}

public enum IdleScreenPixelTerrainStyle: String, Codable, CaseIterable,
    Equatable, Hashable, Sendable
{
    case watershed
    case terraces
    case caverns
}

public enum IdleScreenPixelBoundaryBehavior: String, Codable, CaseIterable,
    Equatable, Hashable, Sendable
{
    case wall
    case drain
    case offWorld
}

public enum IdleScreenPixelMaterialsScenePhase: String, Codable, Equatable,
    Sendable
{
    case quiet
    case filling
    case settled
    case draining
}

public struct IdleScreenPixelMaterialsRendererPhaseDurations: Equatable,
    Hashable, Sendable
{
    public var quiet: TimeInterval
    public var filling: TimeInterval
    public var settled: TimeInterval
    public var draining: TimeInterval

    public var total: TimeInterval {
        quiet + filling + settled + draining
    }

    public init(
        quiet: TimeInterval = 2,
        filling: TimeInterval = 24,
        settled: TimeInterval = 8,
        draining: TimeInterval = 6
    ) {
        self.quiet = Self.bounded(quiet, fallback: 2)
        self.filling = Self.bounded(filling, fallback: 24)
        self.settled = Self.bounded(settled, fallback: 8)
        self.draining = Self.bounded(draining, fallback: 6)
    }

    private static func bounded(
        _ value: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else { return fallback }
        return min(300, max(0.25, value))
    }
}

/// Renderer-local, host-independent controls for the deterministic oracle.
/// Shared Core configuration maps into this value at the two product edges.
public struct IdleScreenPixelMaterialsRendererSettings: Equatable, Hashable,
    Sendable
{
    public var material: IdleScreenRenderedMaterial
    public var terrainStyle: IdleScreenPixelTerrainStyle
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
    public var paletteRawValue: String
    public var persistence: Double
    public var outerBoundaryBehavior: IdleScreenPixelBoundaryBehavior
    public var phaseDurations: IdleScreenPixelMaterialsRendererPhaseDurations
    public var regenerationCadence: TimeInterval
    public var fixedStep: TimeInterval
    public var maximumSubsteps: Int

    public init(
        material: IdleScreenRenderedMaterial = .water,
        terrainStyle: IdleScreenPixelTerrainStyle = .watershed,
        seed: UInt64 = 0x49444C45504D0001,
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
        paletteRawValue: String = "canyon",
        persistence: Double = 1,
        outerBoundaryBehavior: IdleScreenPixelBoundaryBehavior = .wall,
        phaseDurations: IdleScreenPixelMaterialsRendererPhaseDurations = .init(),
        regenerationCadence: TimeInterval = 40,
        fixedStep: TimeInterval = 1.0 / 30,
        maximumSubsteps: Int = 8
    ) {
        self.material = material
        self.terrainStyle = terrainStyle
        self.seed = seed == 0 ? 0x49444C45504D0001 : seed
        self.basinCount = min(8, max(2, basinCount))
        self.basinDepth = min(24, max(3, basinDepth))
        self.minimumBasinCapacity = min(
            4096,
            max(8, minimumBasinCapacity)
        )
        self.channelConnectivity = Self.unit(
            channelConnectivity,
            fallback: 0.75
        )
        self.channelWidth = min(6, max(1, channelWidth))
        self.rockRatio = Self.unit(rockRatio, fallback: 0.62)
        self.soilRatio = Self.unit(soilRatio, fallback: 0.38)
        self.emitterCount = min(4, max(1, emitterCount))
        self.emitterPosition = Self.unit(emitterPosition, fallback: 0.18)
        self.emitterWidth = min(8, max(1, emitterWidth))
        self.emitterRate = min(8, max(1, emitterRate))
        self.gravity = Self.unit(gravity, fallback: 1)
        self.cellScale = cellScale.isFinite
            ? min(4, max(0.25, cellScale))
            : 1
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
        self.paletteRawValue = paletteRawValue
        self.persistence = Self.unit(persistence, fallback: 1)
        self.outerBoundaryBehavior = outerBoundaryBehavior
        self.phaseDurations = phaseDurations
        let minimumCadence = phaseDurations.total
        if regenerationCadence.isFinite {
            self.regenerationCadence = min(
                600,
                max(minimumCadence, regenerationCadence)
            )
        } else {
            self.regenerationCadence = minimumCadence
        }
        self.fixedStep = fixedStep.isFinite
            ? min(0.25, max(1.0 / 120, fixedStep))
            : 1.0 / 30
        self.maximumSubsteps = min(16, max(1, maximumSubsteps))
    }

    public func phase(at elapsedTime: TimeInterval) -> IdleScreenPixelMaterialsScenePhase {
        let elapsed = elapsedTime.isFinite ? max(0, elapsedTime) : 0
        let loopTime = elapsed.truncatingRemainder(
            dividingBy: regenerationCadence
        )
        if loopTime < phaseDurations.quiet { return .quiet }
        if loopTime < phaseDurations.quiet + phaseDurations.filling {
            return .filling
        }
        if loopTime < phaseDurations.quiet
            + phaseDurations.filling
            + phaseDurations.settled {
            return .settled
        }
        return .draining
    }

    private static func unit(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(1, max(0, value))
    }
}

public struct IdleScreenPixelCoordinate: Hashable, Codable, Sendable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

public enum IdleScreenPixelTerrainCell: UInt8, Codable, Equatable, Sendable {
    case air = 0
    case soil = 1
    case rock = 2
    case drain = 3

    public var isSolid: Bool {
        self == .soil || self == .rock
    }
}

public struct IdleScreenPixelBasin: Equatable, Sendable, Identifiable {
    public let id: Int
    public let columns: ClosedRange<Int>
    public let floorRow: Int
    public let lipRow: Int
    public let capacity: Int
    public let isReachableFromEmitter: Bool
    public let spillway: IdleScreenPixelCoordinate?
    public let downstreamBasinID: Int?
}

public struct IdleScreenPixelMaterialsTerrain: Equatable, Sendable {
    public static let minimumWidth = 4
    public static let minimumHeight = 4
    public static let maximumWidth = 256
    public static let maximumHeight = 160

    public let width: Int
    public let height: Int
    public let cells: [IdleScreenPixelTerrainCell]
    public let basins: [IdleScreenPixelBasin]
    public let emitters: [IdleScreenPixelCoordinate]
    public let terminalSinks: [IdleScreenPixelCoordinate]
    public let checksum: UInt64

    public init(
        width: Int,
        height: Int,
        cells: [IdleScreenPixelTerrainCell],
        basins: [IdleScreenPixelBasin] = [],
        emitters: [IdleScreenPixelCoordinate] = [],
        terminalSinks: [IdleScreenPixelCoordinate] = []
    ) throws {
        guard (Self.minimumWidth...Self.maximumWidth).contains(width),
              (Self.minimumHeight...Self.maximumHeight).contains(height) else {
            throw IdleScreenPixelMaterialsError.invalidDimensions
        }
        guard width <= Int.max / height, cells.count == width * height else {
            throw IdleScreenPixelMaterialsError.invalidCellStorage
        }
        self.width = width
        self.height = height
        self.cells = cells
        self.basins = basins
        self.emitters = emitters
        self.terminalSinks = terminalSinks
        checksum = Self.makeChecksum(
            width: width,
            height: height,
            cells: cells,
            basins: basins
        )
    }

    public subscript(_ coordinate: IdleScreenPixelCoordinate) -> IdleScreenPixelTerrainCell {
        guard contains(coordinate) else { return .rock }
        return cells[coordinate.row * width + coordinate.column]
    }

    public func contains(_ coordinate: IdleScreenPixelCoordinate) -> Bool {
        coordinate.column >= 0 && coordinate.column < width
            && coordinate.row >= 0 && coordinate.row < height
    }

    public static func generate(
        width: Int,
        height: Int,
        settings: IdleScreenPixelMaterialsRendererSettings
    ) throws -> Self {
        guard (minimumWidth...maximumWidth).contains(width),
              (minimumHeight...maximumHeight).contains(height) else {
            throw IdleScreenPixelMaterialsError.invalidDimensions
        }
        let count = min(settings.basinCount, max(2, (width - 4) / 8))
        let usableWidth = width - 4
        guard count >= 2, usableWidth / count >= 4 else {
            throw IdleScreenPixelMaterialsError.insufficientTerrainSpace
        }

        let terrainSalt: UInt64 = switch settings.terrainStyle {
        case .watershed: 0x5741544552534844
        case .terraces: 0x5445525241434553
        case .caverns: 0x43415645524E5300
        }
        var random = SplitMix64(state: settings.seed ^ terrainSalt)
        var surfaceRows = Array(repeating: max(3, height / 2), count: width)
        var basins: [IdleScreenPixelBasin] = []
        let segmentWidth = usableWidth / count
        let connectedLinkCount = min(
            count - 1,
            max(
                0,
                Int(
                    (Double(count - 1) * settings.channelConnectivity)
                        .rounded()
                )
            )
        )
        let baseLip = max(
            3,
            height / 2 - settings.basinDepth / 2
                + (settings.terrainStyle == .caverns ? 2 : 0)
        )

        for index in 0..<count {
            let start = 2 + index * segmentWidth
            let end = index == count - 1
                ? width - 3
                : min(width - 3, start + segmentWidth - 1)
            let lipStep = settings.terrainStyle == .terraces ? 3 : 2
            let lipRow = min(height - 5, baseLip + index * lipStep)
            let jitter = Int(random.next() % 3)
            let floorRow = min(
                height - 2,
                lipRow + settings.basinDepth + jitter
            )
            let interiorStart = min(end - 1, start + 1)
            let interiorEnd = max(interiorStart, end - 1)
            surfaceRows[start] = lipRow
            surfaceRows[end] = lipRow
            for column in interiorStart...interiorEnd {
                let edgeDistance = min(column - start, end - column)
                let depth = min(
                    floorRow - lipRow,
                    max(1, edgeDistance * 2)
                )
                surfaceRows[column] = lipRow + depth
            }
            let isConnected = index < connectedLinkCount
            if isConnected {
                for offset in 0..<settings.channelWidth {
                    let channelColumn = max(start, end - offset)
                    surfaceRows[channelColumn] = lipRow
                }
            } else if index < count - 1 {
                // A disconnected segment is a real full-height dam, not only
                // metadata. This keeps later basin columns unreachable until
                // the saved connectivity explicitly opens their spillway.
                surfaceRows[end] = 0
            }
            var capacity = (interiorStart...interiorEnd).reduce(0) {
                $0 + max(0, surfaceRows[$1] - lipRow)
            } * IdleScreenPixelMaterialsSnapshot.maximumWaterPerCell
            if settings.obstacleDensity > 0 {
                for column in interiorStart...interiorEnd {
                    guard capacity
                        - IdleScreenPixelMaterialsSnapshot.maximumWaterPerCell
                        >= settings.minimumBasinCapacity,
                        surfaceRows[column] - lipRow > 1 else {
                        continue
                    }
                    let unit = Double(random.next() % 10_000) / 10_000
                    if unit < settings.obstacleDensity {
                        surfaceRows[column] -= 1
                        capacity -= IdleScreenPixelMaterialsSnapshot
                            .maximumWaterPerCell
                    }
                }
            }
            guard capacity >= settings.minimumBasinCapacity else {
                throw IdleScreenPixelMaterialsError.insufficientTerrainSpace
            }
            let spillway = isConnected
                ? IdleScreenPixelCoordinate(column: end, row: lipRow - 1)
                : nil
            basins.append(IdleScreenPixelBasin(
                id: index,
                columns: interiorStart...interiorEnd,
                floorRow: floorRow,
                lipRow: lipRow,
                capacity: capacity,
                isReachableFromEmitter: index <= connectedLinkCount,
                spillway: spillway,
                downstreamBasinID: isConnected ? index + 1 : nil
            ))
        }
        surfaceRows[0] = 0
        surfaceRows[1] = min(surfaceRows[1], baseLip)
        surfaceRows[width - 2] = min(surfaceRows[width - 2], height - 3)
        surfaceRows[width - 1] = 0

        var cells = Array(
            repeating: IdleScreenPixelTerrainCell.air,
            count: width * height
        )
        let solidRatioTotal = settings.rockRatio + settings.soilRatio
        let rockShare = solidRatioTotal > 0
            ? settings.rockRatio / solidRatioTotal
            : 0.62
        for column in 0..<width {
            for row in surfaceRows[column]..<height {
                let selector = random.next() % 100
                cells[row * width + column] = selector
                    < UInt64((rockShare * 100).rounded())
                    ? .rock : .soil
            }
        }
        let first = basins[0]
        let emitterCenter = first.columns.lowerBound + Int(
            Double(first.columns.count - 1) * settings.emitterPosition
        )
        let emitters = (0..<settings.emitterCount).map { offset in
            IdleScreenPixelCoordinate(
                column: min(
                    first.columns.upperBound,
                    emitterCenter + offset * settings.emitterWidth
                ),
                row: 0
            )
        }
        let last = basins[min(connectedLinkCount, basins.count - 1)]
        let sink = IdleScreenPixelCoordinate(
            column: last.columns.upperBound,
            row: max(0, last.floorRow - 1)
        )
        return try Self(
            width: width,
            height: height,
            cells: cells,
            basins: basins,
            emitters: emitters,
            terminalSinks: [sink]
        )
    }

    private static func makeChecksum(
        width: Int,
        height: Int,
        cells: [IdleScreenPixelTerrainCell],
        basins: [IdleScreenPixelBasin]
    ) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func append(_ value: UInt64) {
            hash = (hash ^ value) &* 1_099_511_628_211
        }
        append(UInt64(width))
        append(UInt64(height))
        for cell in cells { append(UInt64(cell.rawValue)) }
        for basin in basins {
            append(UInt64(basin.id))
            append(UInt64(basin.floorRow))
            append(UInt64(basin.lipRow))
            append(UInt64(basin.capacity))
        }
        return hash
    }

    static func empty(width: Int, height: Int) -> Self {
        precondition(
            (minimumWidth...maximumWidth).contains(width)
                && (minimumHeight...maximumHeight).contains(height)
                && width <= Int.max / height
        )
        let cells = Array(
            repeating: IdleScreenPixelTerrainCell.air,
            count: width * height
        )
        return Self(
            uncheckedWidth: width,
            height: height,
            cells: cells
        )
    }

    private init(
        uncheckedWidth width: Int,
        height: Int,
        cells: [IdleScreenPixelTerrainCell]
    ) {
        self.width = width
        self.height = height
        self.cells = cells
        basins = []
        emitters = []
        terminalSinks = []
        checksum = Self.makeChecksum(
            width: width,
            height: height,
            cells: cells,
            basins: []
        )
    }
}

public struct IdleScreenPixelMaterialsCell: Equatable, Sendable {
    public let terrain: IdleScreenPixelTerrainCell
    public let sand: UInt8
    public let water: UInt8
}

public struct IdleScreenPixelMaterialsSnapshot: Equatable, Sendable {
    public static let maximumWaterPerCell = 8

    public let width: Int
    public let height: Int
    public let tick: UInt64
    public let cells: [IdleScreenPixelMaterialsCell]

    public var checksum: UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func append(_ value: UInt64) {
            hash = (hash ^ value) &* 1_099_511_628_211
        }
        append(UInt64(width))
        append(UInt64(height))
        append(tick)
        for cell in cells {
            append(UInt64(cell.terrain.rawValue))
            append(UInt64(cell.sand))
            append(UInt64(cell.water))
        }
        return hash
    }

    public var totalSand: Int {
        cells.reduce(0) { $0 + Int($1.sand) }
    }

    public var totalWater: Int {
        cells.reduce(0) { $0 + Int($1.water) }
    }

    public func sandAmount(at coordinate: IdleScreenPixelCoordinate) -> Int {
        guard let cell = cell(at: coordinate) else { return 0 }
        return Int(cell.sand)
    }

    public func waterAmount(at coordinate: IdleScreenPixelCoordinate) -> Int {
        guard let cell = cell(at: coordinate) else { return 0 }
        return Int(cell.water)
    }

    private func cell(
        at coordinate: IdleScreenPixelCoordinate
    ) -> IdleScreenPixelMaterialsCell? {
        guard coordinate.column >= 0, coordinate.column < width,
              coordinate.row >= 0, coordinate.row < height else {
            return nil
        }
        return cells[coordinate.row * width + coordinate.column]
    }
}

public struct IdleScreenPixelMaterialsAccounting: Equatable, Sendable {
    public var injectedSand = 0
    public var injectedWater = 0
    public var drainedSand = 0
    public var drainedWater = 0
    public var evaporatedWater = 0
    public var currentSand = 0
    public var currentWater = 0

    public var isConserved: Bool {
        injectedSand == currentSand + drainedSand
            && injectedWater
                == currentWater + drainedWater + evaporatedWater
    }
}

public struct IdleScreenPixelMaterialsReferenceModel: Sendable {
    private var settings: IdleScreenPixelMaterialsRendererSettings
    private var terrain: IdleScreenPixelMaterialsTerrain
    private var initialTerrain: IdleScreenPixelMaterialsTerrain
    private var sand: [UInt8]
    private var water: [UInt8]
    private var lastElapsedTime: TimeInterval?
    private var accumulator: TimeInterval = 0
    private var paused = false
    public private(set) var tick: UInt64 = 0
    public private(set) var sceneGeneration: UInt64 = 0
    public private(set) var overflowedBasinIDs: Set<Int> = []
    public private(set) var isShutdown = false
    public private(set) var accounting = IdleScreenPixelMaterialsAccounting()

    public init(
        settings: IdleScreenPixelMaterialsRendererSettings,
        terrain: IdleScreenPixelMaterialsTerrain
    ) {
        self.settings = settings
        self.terrain = terrain
        initialTerrain = terrain
        sand = Array(repeating: 0, count: terrain.cells.count)
        water = Array(repeating: 0, count: terrain.cells.count)
    }

    public init(
        settings: IdleScreenPixelMaterialsRendererSettings,
        width: Int,
        height: Int
    ) throws {
        self.init(
            settings: settings,
            terrain: try .generate(
                width: width,
                height: height,
                settings: settings
            )
        )
    }

    public var snapshot: IdleScreenPixelMaterialsSnapshot {
        guard !isShutdown else {
            return .init(width: 0, height: 0, tick: tick, cells: [])
        }
        let cells = terrain.cells.indices.map { index in
            IdleScreenPixelMaterialsCell(
                terrain: terrain.cells[index],
                sand: sand[index],
                water: water[index]
            )
        }
        return .init(
            width: terrain.width,
            height: terrain.height,
            tick: tick,
            cells: cells
        )
    }

    @discardableResult
    public mutating func inject(
        _ material: IdleScreenRenderedMaterial,
        at coordinate: IdleScreenPixelCoordinate
    ) -> Bool {
        guard !isShutdown, terrain.contains(coordinate),
              !terrain[coordinate].isSolid,
              terrain[coordinate] != .drain else {
            return false
        }
        let index = self.index(coordinate)
        switch material {
        case .sand:
            guard sand[index] == 0 else { return false }
            sand[index] = 1
            accounting.injectedSand += 1
        case .water:
            guard water[index]
                    < UInt8(IdleScreenPixelMaterialsSnapshot.maximumWaterPerCell) else {
                return false
            }
            water[index] += 1
            accounting.injectedWater += 1
        case .mixed:
            if tick.isMultiple(of: 2) {
                return inject(.water, at: coordinate)
            }
            return inject(.sand, at: coordinate)
        }
        refreshAccounting()
        return true
    }

    public mutating func step(emitting: Bool, draining: Bool = false) {
        guard !isShutdown, !paused else { return }
        if emitting { emitConfiguredMaterial() }
        moveSand()
        moveWater()
        detectOverflow()
        if draining { drainMaterials() }
        tick &+= 1
        refreshAccounting()
    }

    @discardableResult
    public mutating func advance(to elapsedTime: TimeInterval) -> Int {
        guard !isShutdown, !paused, elapsedTime.isFinite else { return 0 }
        let boundedTime = max(0, elapsedTime)
        let targetGeneration = UInt64(
            (boundedTime / settings.regenerationCadence).rounded(.down)
        )
        if targetGeneration > sceneGeneration {
            regenerate(generation: targetGeneration)
            lastElapsedTime = boundedTime
            return 0
        }
        guard let previous = lastElapsedTime else {
            lastElapsedTime = boundedTime
            return 0
        }
        guard boundedTime >= previous else {
            lastElapsedTime = boundedTime
            accumulator = 0
            return 0
        }
        accumulator += boundedTime - previous
        lastElapsedTime = boundedTime
        let available = Int(
            ((accumulator + settings.fixedStep * 1e-9) / settings.fixedStep)
                .rounded(.down)
        )
        let steps = min(settings.maximumSubsteps, available)
        let phase = settings.phase(at: boundedTime)
        for _ in 0..<steps {
            step(
                emitting: phase == .filling,
                draining: phase == .draining
            )
        }
        accumulator -= Double(steps) * settings.fixedStep
        if available > settings.maximumSubsteps {
            accumulator = min(accumulator, settings.fixedStep)
        }
        return steps
    }

    public mutating func pause() {
        paused = true
    }

    public mutating func resume(at elapsedTime: TimeInterval) {
        guard !isShutdown else { return }
        paused = false
        lastElapsedTime = elapsedTime.isFinite ? max(0, elapsedTime) : nil
        accumulator = 0
    }

    public mutating func reset() {
        guard !isShutdown else { return }
        terrain = initialTerrain
        sand = Array(repeating: 0, count: terrain.cells.count)
        water = Array(repeating: 0, count: terrain.cells.count)
        accounting = .init()
        tick = 0
        sceneGeneration = 0
        overflowedBasinIDs = []
        lastElapsedTime = nil
        accumulator = 0
        paused = false
    }

    public mutating func resize(width: Int, height: Int) throws {
        guard !isShutdown else { return }
        let replacement = try IdleScreenPixelMaterialsTerrain.generate(
            width: width,
            height: height,
            settings: settings
        )
        terrain = replacement
        initialTerrain = replacement
        sand = Array(repeating: 0, count: replacement.cells.count)
        water = Array(repeating: 0, count: replacement.cells.count)
        accounting = .init()
        tick = 0
        sceneGeneration = 0
        overflowedBasinIDs = []
        lastElapsedTime = nil
        accumulator = 0
    }

    public mutating func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        sand.removeAll(keepingCapacity: false)
        water.removeAll(keepingCapacity: false)
        lastElapsedTime = nil
        accumulator = 0
    }

    private mutating func emitConfiguredMaterial() {
        for emitter in terrain.emitters {
            for offset in 0..<settings.emitterWidth {
                let coordinate = IdleScreenPixelCoordinate(
                    column: min(terrain.width - 1, emitter.column + offset),
                    row: emitter.row
                )
                for _ in 0..<settings.emitterRate {
                    _ = inject(settings.material, at: coordinate)
                }
            }
        }
    }

    private mutating func moveSand() {
        guard shouldApply(rate: settings.gravity, salt: 0x53414E44) else {
            return
        }
        guard terrain.height >= 2 else { return }
        for row in stride(from: terrain.height - 2, through: 0, by: -1) {
            let leftFirst = ((UInt64(row) &+ tick &+ settings.seed) & 1) == 0
            let columns = leftFirst
                ? Array(0..<terrain.width)
                : Array((0..<terrain.width).reversed())
            for column in columns {
                let source = IdleScreenPixelCoordinate(column: column, row: row)
                let sourceIndex = index(source)
                guard sand[sourceIndex] > 0 else { continue }
                let candidates = [
                    IdleScreenPixelCoordinate(column: column, row: row + 1),
                    IdleScreenPixelCoordinate(
                        column: column + (leftFirst ? -1 : 1),
                        row: row + 1
                    ),
                    IdleScreenPixelCoordinate(
                        column: column + (leftFirst ? 1 : -1),
                        row: row + 1
                    ),
                ]
                if let destination = candidates.first(where: canAcceptSand) {
                    sand[sourceIndex] = 0
                    sand[index(destination)] = 1
                } else if settings.outerBoundaryBehavior != .wall,
                          row == terrain.height - 1 {
                    sand[sourceIndex] = 0
                    accounting.drainedSand += 1
                }
            }
        }
    }

    private func canAcceptSand(_ coordinate: IdleScreenPixelCoordinate) -> Bool {
        guard terrain.contains(coordinate),
              !terrain[coordinate].isSolid,
              terrain[coordinate] != .drain else {
            return false
        }
        let destination = index(coordinate)
        return sand[destination] == 0 && water[destination] == 0
    }

    private mutating func moveWater() {
        let capacity = IdleScreenPixelMaterialsSnapshot.maximumWaterPerCell
        var next = water
        if terrain.height >= 2,
           shouldApply(rate: settings.gravity, salt: 0x57415445) {
            for row in stride(from: terrain.height - 2, through: 0, by: -1) {
                for column in 0..<terrain.width {
                    let source = IdleScreenPixelCoordinate(
                        column: column,
                        row: row
                    )
                    let sourceIndex = index(source)
                    guard next[sourceIndex] > 0 else { continue }
                    let below = IdleScreenPixelCoordinate(
                        column: column,
                        row: row + 1
                    )
                    guard canAcceptWater(below) else { continue }
                    let destinationIndex = index(below)
                    let room = capacity - Int(next[destinationIndex])
                    let transfer = min(Int(next[sourceIndex]), room)
                    guard transfer > 0 else { continue }
                    next[sourceIndex] -= UInt8(transfer)
                    next[destinationIndex] += UInt8(transfer)
                }
            }
        }

        // Equalize only within a contiguous open run, expanding an occupied
        // pool by at most one cell on either edge per fixed step. Pressure can
        // settle a connected pool without crossing or indexing past a wall,
        // while the bounded expansion prevents long-distance teleportation.
        if shouldApply(
            rate: min(
                settings.waterLateralFlow,
                settings.waterEqualization,
                settings.spillRate
            ),
            salt: 0x464C4F57
        ) {
        for row in 0..<terrain.height {
            var segmentStart = 0
            while segmentStart < terrain.width {
                while segmentStart < terrain.width,
                      !canAcceptWater(.init(column: segmentStart, row: row)) {
                    segmentStart += 1
                }
                guard segmentStart < terrain.width else { break }
                var segmentEnd = segmentStart
                while segmentEnd + 1 < terrain.width,
                      canAcceptWater(.init(column: segmentEnd + 1, row: row)) {
                    segmentEnd += 1
                }
                let occupied = (segmentStart...segmentEnd).filter { column in
                    next[index(.init(column: column, row: row))] > 0
                }
                if let first = occupied.first, let last = occupied.last {
                    let expands = shouldApply(
                        rate: settings.waterPressure,
                        salt: 0x5052455353555245 ^ UInt64(row)
                    )
                    let activeStart = max(
                        segmentStart,
                        first - (expands ? 1 : 0)
                    )
                    let activeEnd = min(
                        segmentEnd,
                        last + (expands ? 1 : 0)
                    )
                    let activeCount = activeEnd - activeStart + 1
                    let total = (activeStart...activeEnd).reduce(0) {
                        $0 + Int(next[index(.init(column: $1, row: row))])
                    }
                    let base = min(capacity, total / activeCount)
                    let remainder = total - base * activeCount
                    let remainderOffset = Int(
                        (tick &+ settings.seed &+ UInt64(row))
                            % UInt64(activeCount)
                    )
                    for offset in 0..<activeCount {
                        let column = activeStart + offset
                        let rotated = (offset - remainderOffset + activeCount)
                            % activeCount
                        next[index(.init(column: column, row: row))] = UInt8(
                            base + (rotated < remainder ? 1 : 0)
                        )
                    }
                }
                segmentStart = segmentEnd + 1
            }
        }
        }

        for index in next.indices where terrain.cells[index] == .drain {
            accounting.drainedWater += Int(next[index])
            next[index] = 0
        }
        if settings.outerBoundaryBehavior != .wall {
            let bottomRow = terrain.height - 1
            for column in 0..<terrain.width {
                let coordinate = IdleScreenPixelCoordinate(
                    column: column,
                    row: bottomRow
                )
                let cellIndex = index(coordinate)
                guard !terrain.cells[cellIndex].isSolid else { continue }
                accounting.drainedWater += Int(next[cellIndex])
                next[cellIndex] = 0
            }
        }
        water = next
    }

    private mutating func detectOverflow() {
        guard terrain.basins.count > 1 else { return }
        for basin in terrain.basins {
            guard !overflowedBasinIDs.contains(basin.id),
                  let downstreamID = basin.downstreamBasinID,
                  let downstream = terrain.basins.first(where: {
                      $0.id == downstreamID
                  }) else {
                continue
            }
            let containsWater = downstream.columns.contains { column in
                (0..<terrain.height).contains { row in
                    water[self.index(.init(column: column, row: row))] > 0
                }
            }
            if containsWater { overflowedBasinIDs.insert(basin.id) }
        }
    }

    private mutating func drainMaterials() {
        let waterCount = water.reduce(0) { $0 + Int($1) }
        let sandCount = sand.reduce(0) { $0 + Int($1) }
        let waterRemoval = boundedRemoval(
            count: waterCount,
            rate: settings.drainRate
        )
        let sandRemoval = boundedRemoval(
            count: sandCount,
            rate: settings.drainRate
        )
        accounting.drainedWater += removeUnits(
            waterRemoval,
            from: &water
        )
        accounting.drainedSand += removeUnits(
            sandRemoval,
            from: &sand
        )
        let remainingWater = water.reduce(0) { $0 + Int($1) }
        let evaporated = removeUnits(
            boundedRemoval(
                count: remainingWater,
                rate: settings.evaporationRate
            ),
            from: &water
        )
        accounting.evaporatedWater += evaporated
    }

    private func boundedRemoval(count: Int, rate: Double) -> Int {
        guard count > 0, rate > 0 else { return 0 }
        return min(count, max(1, Int((Double(count) * rate).rounded(.up))))
    }

    private func removeUnits(
        _ requested: Int,
        from storage: inout [UInt8]
    ) -> Int {
        guard requested > 0 else { return 0 }
        var remaining = requested
        for index in storage.indices.reversed() where remaining > 0 {
            let amount = min(remaining, Int(storage[index]))
            storage[index] -= UInt8(amount)
            remaining -= amount
        }
        return requested - remaining
    }

    private mutating func regenerate(generation: UInt64) {
        let previousSand = sand
        let previousWater = water
        var generatedSettings = settings
        generatedSettings.seed = settings.seed
            ^ (generation &* 0x9E3779B97F4A7C15)
        if generatedSettings.seed == 0 {
            generatedSettings.seed = 0x49444C45504D0001
        }
        guard let replacement = try? IdleScreenPixelMaterialsTerrain.generate(
            width: terrain.width,
            height: terrain.height,
            settings: generatedSettings
        ) else { return }
        terrain = replacement
        sand = Array(repeating: 0, count: replacement.cells.count)
        water = Array(repeating: 0, count: replacement.cells.count)
        accounting = .init()
        if settings.persistence > 0 {
            let count = min(replacement.cells.count, previousSand.count)
            for index in 0..<count where
                !replacement.cells[index].isSolid
                    && replacement.cells[index] != .drain
                    && shouldPersist(index: index, generation: generation) {
                sand[index] = previousSand[index]
                water[index] = previousWater[index]
            }
            accounting.injectedSand = sand.reduce(0) { $0 + Int($1) }
            accounting.injectedWater = water.reduce(0) { $0 + Int($1) }
        }
        tick = 0
        sceneGeneration = generation
        overflowedBasinIDs = []
        accumulator = 0
        refreshAccounting()
    }

    private func shouldPersist(index: Int, generation: UInt64) -> Bool {
        guard settings.persistence > 0 else { return false }
        guard settings.persistence < 1 else { return true }
        var random = SplitMix64(
            state: settings.seed
                ^ generation
                ^ (UInt64(index) &* 0x9E3779B97F4A7C15)
                ^ 0x5045525349535400
        )
        let unit = Double(random.next() % 10_000) / 10_000
        return unit < settings.persistence
    }

    private func shouldApply(rate: Double, salt: UInt64) -> Bool {
        guard rate > 0 else { return false }
        guard rate < 1 else { return true }
        var random = SplitMix64(
            state: settings.seed ^ tick ^ salt
        )
        let unit = Double(random.next() % 10_000) / 10_000
        return unit < rate
    }

    private func canAcceptWater(_ coordinate: IdleScreenPixelCoordinate) -> Bool {
        terrain.contains(coordinate)
            && !terrain[coordinate].isSolid
            && terrain[coordinate] != .drain
            && sand[index(coordinate)] == 0
    }

    private func index(_ coordinate: IdleScreenPixelCoordinate) -> Int {
        coordinate.row * terrain.width + coordinate.column
    }

    private mutating func refreshAccounting() {
        accounting.currentSand = sand.reduce(0) { $0 + Int($1) }
        accounting.currentWater = water.reduce(0) { $0 + Int($1) }
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
