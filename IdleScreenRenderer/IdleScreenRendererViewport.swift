import Foundation

public struct IdleScreenProceduralCoordinate: Equatable, Sendable {
    public let column: Int
    public let row: Int
    public let columns: Int
    public let rows: Int

    public init(column: Int, row: Int, columns: Int, rows: Int) {
        self.column = column
        self.row = row
        self.columns = columns
        self.rows = rows
    }
}

/// A normalized slice of one logical scene.
///
/// X and Y use the topology coordinate system: the origin is the scene's
/// bottom-left corner and positive Y points up. Renderer rows are top-down, so
/// `coordinate` performs that conversion exactly once at the framework edge.
public struct IdleScreenRendererViewport: Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = Self(x: 0, y: 0, width: 1, height: 1)

    /// A fail-closed viewport suitable for direct GPU uniforms.
    public var normalized: Self { validated }

    public func coordinate(
        column rawColumn: Int,
        row rawRow: Int,
        columns: Int,
        rows: Int,
        sceneSeed: UInt64 = 0
    ) -> IdleScreenProceduralCoordinate {
        guard columns > 0, rows > 0 else {
            return .init(column: 0, row: 0, columns: 0, rows: 0)
        }

        let viewport = validated
        let sceneColumns = max(
            columns,
            Int((Double(columns) / viewport.width).rounded())
        )
        let sceneRows = max(
            rows,
            Int((Double(rows) / viewport.height).rounded())
        )
        let localColumn = min(columns - 1, max(0, rawColumn))
        let localRow = min(rows - 1, max(0, rawRow))
        let columnOrigin = Int(
            (viewport.x * Double(sceneColumns)).rounded()
        )
        let topOrigin = 1 - viewport.y - viewport.height
        let rowOrigin = Int((topOrigin * Double(sceneRows)).rounded())

        let columnOffset = Int(sceneSeed % UInt64(sceneColumns))
        let mixedSeed = sceneSeed ^ (sceneSeed >> 32)
        let rowOffset = Int(mixedSeed % UInt64(sceneRows))
        return .init(
            column: (columnOrigin + localColumn + columnOffset) % sceneColumns,
            row: (rowOrigin + localRow + rowOffset) % sceneRows,
            columns: sceneColumns,
            rows: sceneRows
        )
    }
}

private extension IdleScreenRendererViewport {
    var validated: Self {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else {
            return .full
        }
        return self
    }
}
