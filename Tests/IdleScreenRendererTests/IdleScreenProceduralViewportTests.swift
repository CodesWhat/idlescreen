import MetalKit
import Testing

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

    #expect(
      left.coordinate(
        column: 99, row: 17, columns: 100, rows: 80
      )
        == full.coordinate(
          column: 99, row: 17, columns: 200, rows: 80
        ))
    #expect(
      right.coordinate(
        column: 0, row: 17, columns: 100, rows: 80
      )
        == full.coordinate(
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

    #expect(
      top.coordinate(
        column: 7, row: 0, columns: 100, rows: 50
      ) == .init(column: 7, row: 0, columns: 100, rows: 100))
    #expect(
      bottom.coordinate(
        column: 7, row: 0, columns: 100, rows: 50
      ) == .init(column: 7, row: 50, columns: 100, rows: 100))
  }

  @Test("seeded viewports join without a wrap seam")
  func seededViewportsJoin() {
    let left = IdleScreenRendererViewport(
      x: 0, y: 0, width: 0.5, height: 1
    )
    let right = IdleScreenRendererViewport(
      x: 0.5, y: 0, width: 0.5, height: 1
    )
    let seed: UInt64 = 0x1234_5678_9ABC_DEF0
    // Cell 99 of the left half and cell 0 of the right half are neighbours
    // in a 200 column scene. A toroidal shift used to wrap one of them to the
    // far edge of the scene; parameter variation keeps them adjacent.
    for pattern in IdleScreenProceduralPatterns.patternRawValues {
      let seam = IdleScreenProceduralPatterns.cellSample(
        patternRawValue: pattern,
        column: 0,
        row: 17,
        columns: 100,
        rows: 80,
        glyphCount: 10,
        time: 4,
        viewport: right,
        sceneSeed: seed
      )
      let full = IdleScreenProceduralPatterns.cellSample(
        patternRawValue: pattern,
        column: 100,
        row: 17,
        columns: 200,
        rows: 80,
        glyphCount: 10,
        time: 4,
        viewport: .full,
        sceneSeed: seed
      )
      #expect(seam == full, "\(pattern) differs across the join")
    }
    #expect(
      left.coordinate(column: 99, row: 17, columns: 100, rows: 80)
        == .init(column: 99, row: 17, columns: 200, rows: 80))
  }

  @Test("a seed varies the pattern field without moving cells")
  func seedVariesParametersNotCells() {
    #expect(IdleScreenSceneVariation(seed: 0) == .none)
    let variation = IdleScreenSceneVariation(seed: 41)
    #expect(variation == IdleScreenSceneVariation(seed: 41))
    #expect(variation != .none)
    #expect(abs(variation.center.x) <= 0.12)
    #expect(abs(variation.center.y) <= 0.12)

    let columns = 40
    let rows = 20
    func field(seed: UInt64) -> [Float] {
      (0..<rows).flatMap { row in
        (0..<columns).map { column in
          IdleScreenProceduralPatterns.cellSample(
            patternRawValue: "perlin",
            column: column,
            row: row,
            columns: columns,
            rows: rows,
            glyphCount: 10,
            time: 1,
            sceneSeed: seed
          ).brightness
        }
      }
    }
    #expect(field(seed: 0) != field(seed: 41))
    #expect(field(seed: 41) == field(seed: 41))

    // A fire's base stays on the bottom row whatever the seed.
    let base = IdleScreenProceduralPatterns.cellSample(
      patternRawValue: "fireEffect",
      column: 10,
      row: 19,
      columns: columns,
      rows: rows,
      glyphCount: 10,
      time: 1,
      sceneSeed: 0xFEED_FACE
    )
    let top = IdleScreenProceduralPatterns.cellSample(
      patternRawValue: "fireEffect",
      column: 10,
      row: 0,
      columns: columns,
      rows: rows,
      glyphCount: 10,
      time: 1,
      sceneSeed: 0xFEED_FACE
    )
    #expect(base.brightness > top.brightness)
  }

  @Test("radial patterns draw circles in screen space, not ellipses")
  func radialPatternsAreAspectCorrect() {
    // 100x50 cells at 0.636 aspect: 11 columns span the same distance as
    // 7 rows (11 * 0.636 = 6.996).
    let columns = 100
    let rows = 50
    func sample(_ pattern: String, column: Int, row: Int, time: Double)
      -> Float
    {
      IdleScreenProceduralPatterns.cellSample(
        patternRawValue: pattern,
        column: column,
        row: row,
        columns: columns,
        rows: rows,
        glyphCount: 10,
        time: time
      ).brightness
    }
    for pattern in ["pulse", "warp", "spiral"] {
      var strongest: Float = 0
      for step in 0..<24 {
        let time = Double(step) * 0.5
        let horizontal = sample(pattern, column: 50 + 11, row: 25, time: time)
        let vertical = sample(pattern, column: 50, row: 25 + 7, time: time)
        let mirrored = sample(pattern, column: 50 - 11, row: 25, time: time)
        strongest = max(strongest, horizontal, vertical)
        if pattern == "pulse" {
          #expect(abs(horizontal - vertical) < 0.01)
          #expect(abs(horizontal - mirrored) < 0.01)
        }
      }
      #expect(strongest > 0.2, "\(pattern) never lit the probe cells")
    }
  }

  @Test("Auto Cycle blends the next pattern in over the end of each slot")
  func autoCycleCrossfade() {
    let interval: TimeInterval = 10
    let settings = IdleScreenProceduralPatternSettings(
      autoCycleInterval: interval
    )
    let before = IdleScreenProceduralPatterns.autoCycleState(
      at: 6, autoCycleInterval: interval
    )
    let midpoint = IdleScreenProceduralPatterns.autoCycleState(
      at: 10 - IdleScreenProceduralPatterns.autoCycleCrossfadeDuration / 2,
      autoCycleInterval: interval
    )
    let after = IdleScreenProceduralPatterns.autoCycleState(
      at: 10, autoCycleInterval: interval
    )
    #expect(before.blend == 0)
    #expect(abs(midpoint.blend - 0.5) < 1e-6)
    #expect(midpoint.current == "perlin")
    #expect(midpoint.next == "plasma")
    #expect(after.current == "plasma")
    #expect(after.blend == 0)

    let time = 10 - IdleScreenProceduralPatterns.autoCycleCrossfadeDuration / 2
    for (column, row) in [(3, 2), (11, 5), (17, 9)] {
      func value(_ pattern: String) -> Float {
        IdleScreenProceduralPatterns.cellSample(
          patternRawValue: pattern,
          settings: settings,
          column: column,
          row: row,
          columns: 20,
          rows: 10,
          glyphCount: 10,
          time: time
        ).brightness
      }
      let blended = value("autoCycle")
      #expect(abs(blended - (value("perlin") + value("plasma")) / 2) < 1e-5)
    }
    // Short intervals never spend more than half the slot blending.
    let quick = IdleScreenProceduralPatterns.autoCycleState(
      at: 0.4, autoCycleInterval: 1
    )
    #expect(quick.blend == 0)
  }

  @Test("each pattern declares a 30, 20 or 12 fps tier")
  func framePacingTiers() {
    #expect(IdleScreenProceduralPatterns.framesPerSecond(patternRawValue: "terrain") == 12)
    #expect(IdleScreenProceduralPatterns.framesPerSecond(patternRawValue: "perlin") == 20)
    #expect(IdleScreenProceduralPatterns.framesPerSecond(patternRawValue: "matrixRain") == 30)
    #expect(IdleScreenProceduralPatterns.framesPerSecond(patternRawValue: "fireEffect") == 30)
    for pattern in IdleScreenProceduralPatterns.patternRawValues {
      #expect(
        [12, 20, 30].contains(
          IdleScreenProceduralPatterns.framesPerSecond(patternRawValue: pattern)
        ))
    }
    // Auto Cycle takes the faster tier while two patterns are blending.
    // Slot 0 is perlin (20), slot 1 plasma (20), slot 2 sweep (20),
    // slot 3 matrixRain (30): the end of slot 2 blends into 30 fps.
    #expect(
      IdleScreenProceduralPatterns.framesPerSecond(
        patternRawValue: "autoCycle", at: 25, autoCycleInterval: 10
      ) == 20)
    #expect(
      IdleScreenProceduralPatterns.framesPerSecond(
        patternRawValue: "autoCycle", at: 29.5, autoCycleInterval: 10
      ) == 30)
  }

  @Test("invalid viewport input falls back to one bounded full scene")
  func invalidViewportFallback() {
    let invalid = IdleScreenRendererViewport(
      x: .nan, y: -2, width: 0, height: 4
    )
    #expect(
      invalid.coordinate(
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

  @Test("time-driven hashes keep changing after long runtimes")
  func longRuntimeHashesKeepChanging() {
    let settings = IdleScreenProceduralPatternSettings(
      speed: 3,
      intensity: 1,
      qualityLevel: 1
    )
    let first = (0..<32).map { column in
      IdleScreenProceduralPatterns.cellSample(
        patternRawValue: "staticNoise",
        settings: settings,
        column: column,
        row: column % 8,
        columns: 32,
        rows: 8,
        glyphCount: 10,
        time: 6_000
      )
    }
    let second = (0..<32).map { column in
      IdleScreenProceduralPatterns.cellSample(
        patternRawValue: "staticNoise",
        settings: settings,
        column: column,
        row: column % 8,
        columns: 32,
        rows: 8,
        glyphCount: 10,
        time: 6_001
      )
    }

    #expect(first != second)
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
