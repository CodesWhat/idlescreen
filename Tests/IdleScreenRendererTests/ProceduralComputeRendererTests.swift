import MetalKit
import Testing

@testable import IdleScreenRenderer

@Suite("Procedural Metal renderer")
struct ProceduralComputeRendererTests {
  @MainActor
  @Test("generative rendering uses the bounded compute pipeline")
  func generativeRenderingUsesCompute() throws {
    let view = MTKView(
      frame: .init(x: 0, y: 0, width: 1_728, height: 1_117)
    )
    let renderer = try IdleScreenRenderer(
      metalView: view,
      configuration: .init(
        glyphScale: 0,
        contrast: 0.5,
        palette: "Ember",
        patternRawValue: "voronoi"
      ),
      automaticallyDraws: false
    )
    defer { renderer.shutdown() }

    #expect(renderer.draw(at: 1))
    let state = try #require(renderer.proceduralDebugState)
    #expect(state.usesComputePipeline)
    #expect(state.instanceCount == 47_121)
  }

  @Test("GPU output matches the CPU reference for every pattern")
  func gpuCPUParity() throws {
    let settings = IdleScreenProceduralPatternSettings(
      speed: 1.3,
      scale: 0.85,
      intensity: 0.62,
      trailing: 0.41,
      autoCycleInterval: 1,
      matrixTrailLength: 0.73,
      rainbowAmplitude: 0.36,
      fireDecay: 0.68,
      qualityLevel: 0.7
    )
    let patterns =
      IdleScreenProceduralPatterns.patternRawValues
      + ["autoCycle", "unsupported-pattern"]

    for pattern in patterns {
      try assertParity(
        pattern: pattern,
        settings: settings,
        columns: 9,
        rows: 7,
        elapsed: 7.25,
        viewport: .full,
        sceneSeed: 0,
        contrast: 0.58,
        sceneBrightness: 1
      )
    }
  }

  @Test("GPU parity includes viewport seed contrast brightness and glyph choice")
  func transformedParity() throws {
    try assertParity(
      pattern: "matrixRain",
      settings: .init(
        speed: 2.1,
        scale: 1.7,
        intensity: 0.9,
        trailing: 0.8,
        matrixTrailLength: 0.25,
        qualityLevel: 1
      ),
      columns: 11,
      rows: 8,
      elapsed: 3.125,
      viewport: .init(x: 0.5, y: 0, width: 0.5, height: 1),
      sceneSeed: 0x1234_5678_9ABC_DEF0,
      contrast: 0.93,
      sceneBrightness: 0.37
    )
  }

  @Test("GPU parity holds for every seeded pattern")
  func seededParityForEveryPattern() throws {
    let settings = IdleScreenProceduralPatternSettings(
      speed: 1.1,
      scale: 1.2,
      intensity: 0.8,
      trailing: 0.5,
      matrixTrailLength: 0.4,
      fireDecay: 0.6,
      qualityLevel: 1
    )
    for pattern in IdleScreenProceduralPatterns.patternRawValues {
      try assertParity(
        pattern: pattern,
        settings: settings,
        columns: 13,
        rows: 9,
        elapsed: 5.5,
        viewport: .init(x: 0.25, y: 0, width: 0.5, height: 1),
        sceneSeed: 0xDEAD_BEEF_CAFE_F00D,
        contrast: 0.58,
        sceneBrightness: 1
      )
    }
  }

  @Test("GPU parity holds inside an Auto Cycle crossfade")
  func crossfadeParity() throws {
    // Interval 1 s gives a 0.5 s window; 7.8 s is 60% through it.
    let settings = IdleScreenProceduralPatternSettings(
      autoCycleInterval: 1,
      qualityLevel: 0.7
    )
    for elapsed: Float in [7.8, 7.6, 3.9] {
      try assertParity(
        pattern: "autoCycle",
        settings: settings,
        columns: 12,
        rows: 8,
        elapsed: elapsed,
        viewport: .full,
        sceneSeed: 0,
        contrast: 0.58,
        sceneBrightness: 1
      )
    }
  }

  @Test("GPU and CPU hashes stay identical after long runtimes")
  func longRuntimeParity() throws {
    try assertParity(
      pattern: "staticNoise",
      settings: .init(
        speed: 3,
        intensity: 1,
        qualityLevel: 1
      ),
      columns: 9,
      rows: 7,
      elapsed: 6_001,
      viewport: .full,
      sceneSeed: 0,
      contrast: 0.58,
      sceneBrightness: 1
    )
  }

  @Test("submission drops retain distinct renderer-failure reasons")
  func submissionDropAccounting() {
    let counter = SubmissionDropCounter()
    counter.rendererDidRecordPerformance(.submitted(frameID: 1, cpuDurationMilliseconds: 1))
    counter.rendererDidRecordPerformance(.dropped(frameID: 2, reason: .inFlightSaturated))
    counter.rendererDidRecordPerformance(.dropped(frameID: 3, reason: .renderResourcesUnavailable))
    counter.rendererDidRecordPerformance(.dropped(frameID: 4, reason: .instanceBufferUnavailable))
    counter.rendererDidRecordPerformance(.dropped(frameID: 5, reason: .encodingFailed))
    #expect(
      counter.snapshot == [
        "inFlightSaturated": 1, "renderResourcesUnavailable": 1,
        "instanceBufferUnavailable": 1, "encodingFailed": 1,
      ])
  }

  @MainActor
  @Test("three worst-case renderers stay inside the main-thread frame budget")
  func threeRendererSubmissionBudget() throws {
    let dropCounter = SubmissionDropCounter()
    let views = (0..<3).map { _ in
      MTKView(frame: .init(x: 0, y: 0, width: 1_728, height: 1_117))
    }
    let renderers = try views.map { view in
      try IdleScreenRenderer(
        metalView: view,
        configuration: .init(
          glyphScale: 0,
          contrast: 0.5,
          palette: "Ember",
          patternRawValue: "voronoi"
        ),
        automaticallyDraws: false,
        performanceObserver: dropCounter
      )
    }
    defer {
      renderers.forEach { $0.shutdown() }
    }

    for renderer in renderers {
      #expect(renderer.draw(at: 0))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))

    var submissionMilliseconds: [Double] = []
    var deadlineMissCount = 0
    var droppedFrameCount = 0
    for frame in 1...60 {
      let roundStart = CACurrentMediaTime()
      for renderer in renderers {
        let startedAt = CACurrentMediaTime()
        if !renderer.draw(at: Double(frame) / 30) {
          droppedFrameCount += 1
        }
        submissionMilliseconds.append(
          (CACurrentMediaTime() - startedAt) * 1_000
        )
      }
      if CACurrentMediaTime() - roundStart > 1.0 / 30.0 {
        deadlineMissCount += 1
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.034))
    }

    let ordered = submissionMilliseconds.sorted()
    let percentileIndex = min(
      ordered.count - 1,
      Int((Double(ordered.count) * 0.95).rounded(.up)) - 1
    )
    let cpuP95 = ordered[percentileIndex]
    let missRatio = Double(deadlineMissCount) / 60
    let deviceName = MTLCreateSystemDefaultDevice()?.name ?? "unknown"
    let enforcesNamedHostBudget = deviceName == "Apple M4 Pro"
    print(
      "procedural_compute_benchmark device=\(deviceName) "
        + "renderers=3 frames=60 cpu_p95_ms=\(cpuP95) "
        + "deadline_miss_ratio=\(missRatio) dropped=\(droppedFrameCount) "
        + "named_host_enforced=\(enforcesNamedHostBudget)"
    )
    let dropCounts = dropCounter.snapshot
    #expect(dropCounts["instanceBufferUnavailable", default: 0] == 0)
    #expect(dropCounts["encodingFailed", default: 0] == 0)
    let backPressureCount =
      dropCounts["inFlightSaturated", default: 0]
      + dropCounts["renderResourcesUnavailable", default: 0]
    #expect(backPressureCount == droppedFrameCount)
    #expect(backPressureCount * 2 < submissionMilliseconds.count)
    if enforcesNamedHostBudget {
      #expect(droppedFrameCount == 0)
      #expect(cpuP95 < 5)
      #expect(missRatio <= 0.01)
    }
  }

  private func assertParity(
    pattern: String,
    settings rawSettings: IdleScreenProceduralPatternSettings,
    columns: Int,
    rows: Int,
    elapsed: Float,
    viewport: IdleScreenRendererViewport,
    sceneSeed: UInt64,
    contrast: Double,
    sceneBrightness: Double
  ) throws {
    let settings = rawSettings.normalized
    let origin = viewport.coordinate(
      column: 0,
      row: 0,
      columns: columns,
      rows: rows
    )
    let variation = IdleScreenSceneVariation(seed: sceneSeed)
    let cycle = IdleScreenProceduralPatterns.autoCycleState(
      at: TimeInterval(elapsed),
      autoCycleInterval: settings.autoCycleInterval
    )
    let isAutoCycle = pattern == "autoCycle"
    let resolvedPattern =
      isAutoCycle
      ? cycle.current
      : IdleScreenProceduralPatterns.resolvedPatternRawValue(pattern)
    let patternIndex = UInt32(
      IdleScreenProceduralPatterns.patternRawValues
        .firstIndex(of: resolvedPattern) ?? 0
    )
    let nextPatternIndex = UInt32(
      IdleScreenProceduralPatterns.patternRawValues
        .firstIndex(of: isAutoCycle ? cycle.next : resolvedPattern) ?? 0
    )
    let foreground = SIMD4<Float>(0.8, 0.6, 0.4, 1)
    let uniforms = ProceduralComputeUniforms(
      gridSize: SIMD2(UInt32(columns), UInt32(rows)),
      sceneSize: SIMD2(UInt32(origin.columns), UInt32(origin.rows)),
      sceneOrigin: SIMD2(UInt32(origin.column), UInt32(origin.row)),
      patternIndex: patternIndex,
      glyphCount: 10,
      timestamp: elapsed,
      contrast: Float(0.6 + contrast * 1.6),
      sceneBrightness: Float(sceneBrightness),
      speed: Float(settings.speed),
      scale: Float(settings.scale),
      intensity: Float(settings.intensity * settings.qualityLevel),
      trailing: Float(settings.trailing),
      matrixTrailLength: Float(settings.matrixTrailLength),
      rainbowAmplitude: Float(settings.rainbowAmplitude),
      fireDecay: Float(settings.fireDecay),
      nextPatternIndex: nextPatternIndex,
      blend: isAutoCycle ? cycle.blend : 0,
      foreground: foreground,
      seedOffset: variation.offset,
      seedCenter: variation.center,
      sceneAspect: Float(
        Double(origin.columns) * IdleScreenProceduralPatterns.cellAspect
          / Double(origin.rows)
      )
    )
    let gpu = try gpuSamples(uniforms: uniforms)
    var maximumBrightnessDifference: Float = 0
    var glyphMismatchCount = 0
    var maximumGlyphIndexDifference = 0
    var maximumMismatchBoundaryDistance: Float = 0

    for row in 0..<rows {
      for column in 0..<columns {
        let reference = IdleScreenProceduralPatterns.cellSample(
          patternRawValue: pattern,
          settings: rawSettings,
          column: column,
          row: row,
          columns: columns,
          rows: rows,
          glyphCount: 10,
          time: TimeInterval(elapsed),
          viewport: viewport,
          sceneSeed: sceneSeed,
          sceneBrightness: 1
        )
        let expectedBrightness =
          min(
            1,
            max(
              0,
              (reference.brightness - 0.5) * uniforms.contrast + 0.5
            )
          ) * uniforms.sceneBrightness
        let actual = gpu[row * columns + column]
        maximumBrightnessDifference = max(
          maximumBrightnessDifference,
          abs(actual.gridBrightnessGlyph.z - expectedBrightness)
        )
        let actualGlyphIndex = Int(actual.gridBrightnessGlyph.w)
        let glyphIndexDifference = abs(actualGlyphIndex - reference.glyphIndex)
        if glyphIndexDifference != 0 {
          glyphMismatchCount += 1
          maximumGlyphIndexDifference = max(
            maximumGlyphIndexDifference,
            glyphIndexDifference
          )
          let scaledReferenceBrightness = reference.brightness * 9
          maximumMismatchBoundaryDistance = max(
            maximumMismatchBoundaryDistance,
            abs(
              scaledReferenceBrightness
                - scaledReferenceBrightness.rounded()
            )
          )
        }
        #expect(actual.foreground == foreground)
      }
    }
    print(
      "procedural_parity pattern=\(pattern) "
        + "max_brightness_difference=\(maximumBrightnessDifference) "
        + "glyph_mismatches=\(glyphMismatchCount) "
        + "max_glyph_index_difference=\(maximumGlyphIndexDifference) "
        + "max_mismatch_boundary_distance=\(maximumMismatchBoundaryDistance)"
    )
    #expect(
      maximumBrightnessDifference < 0.004,
      "brightness mismatch for \(pattern)"
    )
    let shuffledPattern =
      isAutoCycle && cycle.blend >= 0.5 ? cycle.next : resolvedPattern
    if shuffledPattern == "matrixRain" {
      #expect(glyphMismatchCount == 0, "glyph mismatch for \(pattern)")
    } else {
      #expect(
        maximumGlyphIndexDifference <= 1,
        "glyph precision mismatch for \(pattern)"
      )
      #expect(
        maximumMismatchBoundaryDistance < 0.036,
        "glyph mismatch was not adjacent to a brightness boundary for \(pattern)"
      )
    }
  }

  @Test("GPU framing mask and accent band match the CPU definition")
  func gpuFramingParity() throws {
    let columns = 40
    let rows = 30
    let settings = IdleScreenProceduralPatternSettings.default.normalized
    let foreground = SIMD4<Float>(0.7, 0.74, 0.82, 1)
    let accent = SIMD4<Float>(0.23, 0.42, 0.94, 1)
    for pattern in ["terrain", "perlin", "plasma"] {
      let index = UInt32(
        IdleScreenProceduralPatterns.patternRawValues.firstIndex(of: pattern) ?? 0)
      func uniforms(framing: Bool, accent: SIMD4<Float>) -> ProceduralComputeUniforms {
        ProceduralComputeUniforms(
          gridSize: SIMD2(UInt32(columns), UInt32(rows)),
          sceneSize: SIMD2(UInt32(columns), UInt32(rows)),
          sceneOrigin: SIMD2(0, 0),
          patternIndex: index, glyphCount: 10, timestamp: 5.5, contrast: 1.53,
          sceneBrightness: 1, speed: Float(settings.speed), scale: Float(settings.scale),
          intensity: Float(settings.intensity * settings.qualityLevel),
          trailing: Float(settings.trailing),
          matrixTrailLength: Float(settings.matrixTrailLength),
          rainbowAmplitude: Float(settings.rainbowAmplitude),
          fireDecay: Float(settings.fireDecay), nextPatternIndex: index, blend: 0,
          foreground: foreground, seedOffset: .zero, seedCenter: .zero,
          sceneAspect: Float(
            Double(columns) * IdleScreenProceduralPatterns.cellAspect / Double(rows)),
          horizonRow: IdleScreenSceneFramingMask.horizonRow(
            viewport: .full, columns: columns, rows: rows),
          framingEnabled: framing ? 1 : 0, accent: accent)
      }
      let plain = try gpuSamples(uniforms: uniforms(framing: false, accent: .zero))
      let framed = try gpuSamples(uniforms: uniforms(framing: true, accent: accent))
      let horizon = IdleScreenSceneFramingMask.horizonRow(
        viewport: .full, columns: columns, rows: rows)
      #expect(horizon == 18)
      for row in 0..<rows {
        for column in 0..<columns {
          let i = row * columns + column
          let mask = IdleScreenSceneFramingMask.mask(row: row, horizonRow: horizon)
          let expected = plain[i].gridBrightnessGlyph.z * mask
          let actual = framed[i].gridBrightnessGlyph.z
          #expect(abs(actual - expected) < 1e-5, "\(pattern) (\(column), \(row)) brightness")
          let isAccent = IdleScreenSceneFramingMask.isAccent(actual)
          #expect(
            framed[i].foreground == (isAccent ? accent : foreground),
            "\(pattern) (\(column), \(row)) accent")
          #expect(plain[i].foreground == foreground)
          // The mask only ever thins the field: no cell gets a denser glyph.
          #expect(framed[i].gridBrightnessGlyph.w <= plain[i].gridBrightnessGlyph.w)
        }
      }
    }
  }

  @Test("the horizon snaps to a row and follows a display slice")
  func horizonRowSnapsToViewport() {
    #expect(IdleScreenSceneFramingMask.horizonRow(viewport: .full, columns: 100, rows: 50) == 30)
    // The scene is 100 rows tall across two stacked displays, so the horizon
    // is scene row 60: ten rows into the lower display, below the upper one.
    let lower = IdleScreenRendererViewport(x: 0, y: 0, width: 1, height: 0.5)
    #expect(IdleScreenSceneFramingMask.horizonRow(viewport: lower, columns: 100, rows: 50) == 10)
    let upper = IdleScreenRendererViewport(x: 0, y: 0.5, width: 1, height: 0.5)
    #expect(IdleScreenSceneFramingMask.horizonRow(viewport: upper, columns: 100, rows: 50) == 60)
    // The sky is dim, the ground ramps to full, and the horizon is a step up.
    let mask = { IdleScreenSceneFramingMask.mask(row: $0, horizonRow: 30) }
    #expect(mask(0) == IdleScreenSceneFramingMask.skyTop)
    #expect(mask(29) < IdleScreenSceneFramingMask.skyHorizon + 1e-6)
    #expect(mask(30) == IdleScreenSceneFramingMask.groundHorizon)
    #expect(mask(38) == 1 && mask(49) == 1)
    #expect(mask(29) < mask(30))
  }

  @Test("the sky gradient runs over scene rows, so stacked displays share one ramp")
  func skyContinuesAcrossStackedDisplays() {
    // Two 50-row displays, horizon at scene row 60. The upper one holds scene
    // rows 0..<50 and the lower one 50..<100.
    let upper = IdleScreenRendererViewport(x: 0, y: 0.5, width: 1, height: 0.5)
    let lower = IdleScreenRendererViewport(x: 0, y: 0, width: 1, height: 0.5)
    let upperHorizon = IdleScreenSceneFramingMask.horizonRow(
      viewport: upper, columns: 100, rows: 50)
    let lowerHorizon = IdleScreenSceneFramingMask.horizonRow(
      viewport: lower, columns: 100, rows: 50)
    let whole = IdleScreenSceneFramingMask.horizonRow(viewport: .full, columns: 100, rows: 100)
    #expect(whole == 60)
    for row in 0..<50 {
      let top = IdleScreenSceneFramingMask.mask(
        row: row, horizonRow: upperHorizon, originRow: 0)
      let single = IdleScreenSceneFramingMask.mask(row: row, horizonRow: whole)
      #expect(abs(top - single) < 1e-6)
    }
    for row in 0..<50 {
      let bottom = IdleScreenSceneFramingMask.mask(
        row: row, horizonRow: lowerHorizon, originRow: 50)
      let single = IdleScreenSceneFramingMask.mask(row: row + 50, horizonRow: whole)
      #expect(abs(bottom - single) < 1e-6)
    }
    // No seam: the lower display's first sky row continues the upper's last.
    let lastUpper = IdleScreenSceneFramingMask.mask(row: 49, horizonRow: upperHorizon)
    let firstLower = IdleScreenSceneFramingMask.mask(
      row: 0, horizonRow: lowerHorizon, originRow: 50)
    #expect(firstLower > lastUpper && firstLower - lastUpper < 0.01)
  }

  @Test("GPU sky gradient follows scene rows on a lower stacked display")
  func gpuFramingParityOnStackedDisplay() throws {
    let columns = 40
    let rows = 30
    let settings = IdleScreenProceduralPatternSettings.default.normalized
    let foreground = SIMD4<Float>(0.7, 0.74, 0.82, 1)
    let index = UInt32(IdleScreenProceduralPatterns.patternRawValues.firstIndex(of: "plasma") ?? 0)
    // Two 30-row displays; this is the one holding scene rows 30..<60, with
    // the horizon at scene row 36 (6 rows in).
    let viewport = IdleScreenRendererViewport(x: 0, y: 0, width: 1, height: 0.5)
    let horizon = IdleScreenSceneFramingMask.horizonRow(
      viewport: viewport, columns: columns, rows: rows)
    let originRow = viewport.coordinate(column: 0, row: 0, columns: columns, rows: rows).row
    #expect(originRow == 30)
    func uniforms(framing: Bool) -> ProceduralComputeUniforms {
      ProceduralComputeUniforms(
        gridSize: SIMD2(UInt32(columns), UInt32(rows)),
        sceneSize: SIMD2(UInt32(columns), UInt32(rows * 2)),
        sceneOrigin: SIMD2(0, UInt32(originRow)),
        patternIndex: index, glyphCount: 10, timestamp: 5.5, contrast: 1.53,
        sceneBrightness: 1, speed: Float(settings.speed), scale: Float(settings.scale),
        intensity: Float(settings.intensity * settings.qualityLevel),
        trailing: Float(settings.trailing),
        matrixTrailLength: Float(settings.matrixTrailLength),
        rainbowAmplitude: Float(settings.rainbowAmplitude),
        fireDecay: Float(settings.fireDecay), nextPatternIndex: index, blend: 0,
        foreground: foreground, seedOffset: .zero, seedCenter: .zero,
        sceneAspect: Float(
          Double(columns) * IdleScreenProceduralPatterns.cellAspect / Double(rows * 2)),
        horizonRow: horizon, framingEnabled: framing ? 1 : 0, accent: .zero)
    }
    let plain = try gpuSamples(uniforms: uniforms(framing: false))
    let framed = try gpuSamples(uniforms: uniforms(framing: true))
    for row in 0..<rows {
      let mask = IdleScreenSceneFramingMask.mask(
        row: row, horizonRow: horizon, originRow: originRow)
      for column in 0..<columns {
        let i = row * columns + column
        let expected = plain[i].gridBrightnessGlyph.z * mask
        #expect(abs(framed[i].gridBrightnessGlyph.z - expected) < 1e-5, "(\(column), \(row))")
      }
    }
  }

  private func gpuSamples(
    uniforms sourceUniforms: ProceduralComputeUniforms
  ) throws -> [TestProceduralGlyphInstance] {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let library = try device.makeDefaultLibrary(
      bundle: Bundle(for: IdleScreenRenderer.self)
    )
    let function = try #require(
      library.makeFunction(name: "idleScreenProceduralInstances")
    )
    let pipeline = try device.makeComputePipelineState(function: function)
    let queue = try #require(device.makeCommandQueue())
    let count = Int(sourceUniforms.gridSize.x * sourceUniforms.gridSize.y)
    let output = try #require(
      device.makeBuffer(
        length: count * MemoryLayout<TestProceduralGlyphInstance>.stride,
        options: .storageModeShared
      ))
    var uniforms = sourceUniforms
    let commandBuffer = try #require(queue.makeCommandBuffer())
    let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(output, offset: 0, index: 0)
    encoder.setBytes(
      &uniforms,
      length: MemoryLayout<ProceduralComputeUniforms>.stride,
      index: 1
    )
    encoder.dispatchThreads(
      MTLSize(
        width: Int(uniforms.gridSize.x),
        height: Int(uniforms.gridSize.y),
        depth: 1
      ),
      threadsPerThreadgroup: MTLSize(
        width: min(Int(uniforms.gridSize.x), pipeline.threadExecutionWidth),
        height: 1,
        depth: 1
      )
    )
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)

    let pointer = output.contents().bindMemory(
      to: TestProceduralGlyphInstance.self,
      capacity: count
    )
    return Array(UnsafeBufferPointer(start: pointer, count: count))
  }
}

private struct TestProceduralGlyphInstance {
  let gridBrightnessGlyph: SIMD4<Float>
  let foreground: SIMD4<Float>
}

private final class SubmissionDropCounter: IdleScreenRendererPerformanceObserving,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var counts: [String: Int] = [:]

  func rendererDidRecordPerformance(_ event: IdleScreenRendererPerformanceEvent) {
    guard case .dropped(_, let reason) = event else { return }
    lock.lock()
    defer { lock.unlock() }
    counts[reason.rawValue, default: 0] += 1
  }

  var snapshot: [String: Int] {
    lock.lock()
    defer { lock.unlock() }
    return counts
  }
}
