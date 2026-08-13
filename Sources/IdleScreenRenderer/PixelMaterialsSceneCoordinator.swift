import Foundation

public struct IdleScreenPixelMaterialsSceneToken: Hashable, Sendable {
    fileprivate let consumerID: UUID
    fileprivate let settings: IdleScreenPixelMaterialsRendererSettings
    fileprivate let viewport: IdleScreenRendererViewport
}

/// One renderer-process authority for Pixel Materials scenes. Matching views
/// attach to the same seeded model and receive crops from one fixed-size world;
/// the final detach synchronously tears that model down.
@MainActor
public final class IdleScreenPixelMaterialsSceneCoordinator {
    public static let shared = IdleScreenPixelMaterialsSceneCoordinator()

    private struct Entry {
        var model: IdleScreenPixelMaterialsReferenceModel
        var consumers: [UUID: IdleScreenRendererViewport]
    }

    private var entries: [IdleScreenPixelMaterialsRendererSettings: Entry] = [:]

    public init() {}

    public var activeSceneCount: Int { entries.count }

    public var consumerCount: Int {
        entries.values.reduce(0) { $0 + $1.consumers.count }
    }

    public func attach(
        settings: IdleScreenPixelMaterialsRendererSettings,
        viewport: IdleScreenRendererViewport = .full
    ) -> IdleScreenPixelMaterialsSceneToken {
        let consumerID = UUID()
        if var entry = entries[settings] {
            entry.consumers[consumerID] = viewport.normalized
            entry.model = Self.makeModel(
                settings: settings,
                viewports: Array(entry.consumers.values)
            )
            entries[settings] = entry
        } else {
            let normalizedViewport = viewport.normalized
            let model = Self.makeModel(
                settings: settings,
                viewports: [normalizedViewport]
            )
            entries[settings] = Entry(
                model: model,
                consumers: [consumerID: normalizedViewport]
            )
        }
        return .init(
            consumerID: consumerID,
            settings: settings,
            viewport: viewport.normalized
        )
    }

    public func snapshot(
        for token: IdleScreenPixelMaterialsSceneToken,
        at elapsedTime: TimeInterval
    ) throws -> IdleScreenPixelMaterialsSnapshot {
        guard var entry = entries[token.settings],
              entry.consumers[token.consumerID] != nil else {
            throw IdleScreenPixelMaterialsError.invalidCellStorage
        }
        _ = entry.model.advance(to: elapsedTime)
        let snapshot = entry.model.snapshot
        entries[token.settings] = entry
        return snapshot
    }

    public func detach(_ token: IdleScreenPixelMaterialsSceneToken) {
        guard var entry = entries[token.settings] else { return }
        entry.consumers[token.consumerID] = nil
        if entry.consumers.isEmpty {
            entry.model.shutdown()
            entries[token.settings] = nil
        } else {
            entry.model = Self.makeModel(
                settings: token.settings,
                viewports: Array(entry.consumers.values)
            )
            entries[token.settings] = entry
        }
    }

    private static func worldDimensions(
        for cellScale: Double
    ) -> (width: Int, height: Int) {
        let scale = min(4, max(0.25, cellScale))
        return (
            width: min(160, max(32, Int((160 / scale).rounded()))),
            height: min(90, max(24, Int((90 / scale).rounded())))
        )
    }

    private static func makeModel(
        settings: IdleScreenPixelMaterialsRendererSettings,
        viewports: [IdleScreenRendererViewport]
    ) -> IdleScreenPixelMaterialsReferenceModel {
        let dimensions = worldDimensions(for: settings.cellScale)
        do {
            let generated = try IdleScreenPixelMaterialsTerrain.generate(
                width: dimensions.width,
                height: dimensions.height,
                settings: settings
            )
            let terrain = try applyingCoverage(
                viewports,
                behavior: settings.outerBoundaryBehavior,
                to: generated
            )
            return .init(settings: settings, terrain: terrain)
        } catch {
            // Normalized settings and bounded dimensions make this path
            // unreachable in production. A future stricter generator still
            // receives one valid, bounded, fully covered oracle.
            let terrain = IdleScreenPixelMaterialsTerrain.empty(
                width: 32,
                height: 24
            )
            return .init(settings: settings, terrain: terrain)
        }
    }

    private static func applyingCoverage(
        _ viewports: [IdleScreenRendererViewport],
        behavior: IdleScreenPixelBoundaryBehavior,
        to terrain: IdleScreenPixelMaterialsTerrain
    ) throws -> IdleScreenPixelMaterialsTerrain {
        guard !viewports.contains(.full) else { return terrain }
        var cells = terrain.cells
        let boundaryCell: IdleScreenPixelTerrainCell = behavior == .wall
            ? .rock : .drain
        for row in 0..<terrain.height {
            let normalizedY = 1
                - (Double(row) + 0.5) / Double(terrain.height)
            for column in 0..<terrain.width {
                let normalizedX = (Double(column) + 0.5)
                    / Double(terrain.width)
                let covered = viewports.contains { viewport in
                    let viewport = viewport.normalized
                    return normalizedX >= viewport.x
                        && normalizedX < viewport.x + viewport.width
                        && normalizedY >= viewport.y
                        && normalizedY < viewport.y + viewport.height
                }
                if !covered {
                    cells[row * terrain.width + column] = boundaryCell
                }
            }
        }
        func isCovered(_ coordinate: IdleScreenPixelCoordinate) -> Bool {
            cells[coordinate.row * terrain.width + coordinate.column]
                != boundaryCell
        }
        return try .init(
            width: terrain.width,
            height: terrain.height,
            cells: cells,
            basins: terrain.basins,
            emitters: terrain.emitters.filter(isCovered),
            terminalSinks: terrain.terminalSinks.filter(isCovered)
        )
    }
}

public struct IdleScreenPixelMaterialsRenderSample: Equatable, Sendable {
    public let terrain: IdleScreenPixelTerrainCell
    public let sand: UInt8
    public let water: UInt8
}

public enum IdleScreenPixelMaterialsRenderHarness {
    public static func samples(
        snapshot: IdleScreenPixelMaterialsSnapshot,
        viewport: IdleScreenRendererViewport,
        columns: Int,
        rows: Int
    ) -> [IdleScreenPixelMaterialsRenderSample] {
        guard snapshot.width > 0, snapshot.height > 0,
              columns > 0, rows > 0,
              columns <= Int.max / rows else {
            return []
        }
        var result: [IdleScreenPixelMaterialsRenderSample] = []
        result.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let coordinate = viewport.coordinate(
                    column: column,
                    row: row,
                    columns: columns,
                    rows: rows
                )
                let sourceColumn = min(
                    snapshot.width - 1,
                    coordinate.column * snapshot.width / coordinate.columns
                )
                let sourceRow = min(
                    snapshot.height - 1,
                    coordinate.row * snapshot.height / coordinate.rows
                )
                let cell = snapshot.cells[
                    sourceRow * snapshot.width + sourceColumn
                ]
                result.append(.init(
                    terrain: cell.terrain,
                    sand: cell.sand,
                    water: cell.water
                ))
            }
        }
        return result
    }
}
