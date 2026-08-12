import Testing
import MetalKit
@testable import IdleScreenRenderer

@Suite("Multi-display procedural viewport mapping")
struct IdleScreenProceduralViewportTests {
    @Test("horizontal panorama viewports join at the exact scene coordinate")
    func horizontalContinuity() throws {
        let full = IdleScreenRendererViewport.full
        let left = IdleScreenRendererViewport(
            x: 0, y: 0, width: 0.5, height: 1
        )
        let right = IdleScreenRendererViewport(
            x: 0.5, y: 0, width: 0.5, height: 1
        )

        #expect(left.coordinate(
            column: 99, row: 17, columns: 100, rows: 80
        ) == full.coordinate(
            column: 99, row: 17, columns: 200, rows: 80
        ))
        #expect(right.coordinate(
            column: 0, row: 17, columns: 100, rows: 80
        ) == full.coordinate(
            column: 100, row: 17, columns: 200, rows: 80
        ))

        let rightSample = IdleScreenProceduralPatterns.cellSample(
            patternRawValue: "plasma",
            column: 0,
            row: 17,
            columns: 100,
            rows: 80,
            glyphCount: 10,
            time: 4,
            viewport: right
        )
        let fullSample = IdleScreenProceduralPatterns.cellSample(
            patternRawValue: "plasma",
            column: 100,
            row: 17,
            columns: 200,
            rows: 80,
            glyphCount: 10,
            time: 4,
            viewport: full
        )
        #expect(rightSample == fullSample)
    }

    @Test("positive topology Y maps bottom-up into the renderer's top-down rows")
    func verticalCoordinateSemantics() {
        let top = IdleScreenRendererViewport(
            x: 0, y: 0.5, width: 1, height: 0.5
        )
        let bottom = IdleScreenRendererViewport(
            x: 0, y: 0, width: 1, height: 0.5
        )

        #expect(top.coordinate(
            column: 7, row: 0, columns: 100, rows: 50
        ) == .init(column: 7, row: 0, columns: 100, rows: 100))
        #expect(bottom.coordinate(
            column: 7, row: 0, columns: 100, rows: 50
        ) == .init(column: 7, row: 50, columns: 100, rows: 100))
    }

    @Test("scene seeds are deterministic and preserve joins between viewports")
    func seededContinuity() {
        let left = IdleScreenRendererViewport(
            x: 0, y: 0, width: 0.5, height: 1
        )
        let right = IdleScreenRendererViewport(
            x: 0.5, y: 0, width: 0.5, height: 1
        )
        let first = left.coordinate(
            column: 99, row: 17, columns: 100, rows: 80, sceneSeed: 41
        )
        let second = right.coordinate(
            column: 0, row: 17, columns: 100, rows: 80, sceneSeed: 41
        )
        let unseeded = left.coordinate(
            column: 99, row: 17, columns: 100, rows: 80
        )

        #expect(second.column == (first.column + 1) % first.columns)
        #expect(second.row == first.row)
        #expect(first != unseeded)
    }

    @Test("invalid viewport input falls back to one bounded full scene")
    func invalidViewportFallback() {
        let invalid = IdleScreenRendererViewport(
            x: .nan, y: -2, width: 0, height: 4
        )
        #expect(invalid.coordinate(
            column: 9, row: 4, columns: 20, rows: 10
        ) == .init(column: 9, row: 4, columns: 20, rows: 10))
    }

    @Test("scene brightness scales both procedural output and configuration bounds")
    func sceneBrightness() {
        let sample = IdleScreenProceduralPatterns.cellSample(
            patternRawValue: "plasma",
            column: 4,
            row: 3,
            columns: 20,
            rows: 10,
            glyphCount: 10,
            time: 2,
            sceneBrightness: 0
        )
        let configuration = IdleScreenRendererConfiguration(
            glyphScale: 0.5,
            contrast: 0.5,
            palette: "Ember",
            sceneBrightness: 4
        )

        #expect(sample == .zero)
        #expect(configuration.sceneBrightness == 1)
    }

    @MainActor
    @Test("a black scene has a black Metal clear color after palette selection")
    func blackSceneClearColor() throws {
        let view = MTKView(frame: .init(x: 0, y: 0, width: 64, height: 64))
        let renderer = try IdleScreenRenderer(
            metalView: view,
            configuration: .init(
                glyphScale: 0.5,
                contrast: 0,
                palette: "Ember",
                sceneBrightness: 0
            ),
            automaticallyDraws: false
        )
        defer { renderer.shutdown() }

        #expect(view.clearColor.red == 0)
        #expect(view.clearColor.green == 0)
        #expect(view.clearColor.blue == 0)
    }
}
