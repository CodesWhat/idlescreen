import MetalKit
import Testing

@testable import IdleScreenRenderer

@Suite("Agent sprite poses")
struct AgentSpritePoseTests {
  private let metrics = AgentSpriteLayout.Metrics(columns: 120, rows: 40)

  private func pose(
    _ kind: IdleScreenAgentSpriteKind = .claude,
    _ state: IdleScreenAgentSpriteState,
    at elapsed: Double,
    reduceMotion: Bool = false,
    parkX: Double = 60
  ) -> AgentSpritePose {
    AgentSpriteLayout.pose(
      kind: kind, state: state, elapsed: elapsed, parkX: parkX,
      reduceMotion: reduceMotion, metrics: metrics)
  }

  @Test("the renderer configuration is neutral by default and capped at two sprites")
  func neutralDefault() {
    #expect(IdleScreenRendererConfiguration.default.agentSprites.isEmpty)
    let sprite = IdleScreenAgentSprite(kind: .claude, state: .working, startedAt: .distantPast)
    let configuration = IdleScreenRendererConfiguration(
      glyphScale: 0.4, contrast: 0.5, palette: "Ember",
      agentSprites: [sprite, sprite, sprite])
    #expect(configuration.agentSprites.count == 2)
    #expect(
      AgentSpriteLayout.overrides(
        sprites: [], now: Date(), columns: 120, rows: 40, parkFraction: 0.5, seed: 0
      ).isEmpty)
  }

  @Test("working runs left to right, alternates legs and wraps")
  func working() {
    let start = pose(.claude, .working, at: 0)
    let later = pose(.claude, .working, at: 5)
    #expect(later.x > start.x)
    #expect(pose(.claude, .working, at: 0.1).frame == 0)
    #expect(pose(.claude, .working, at: 0.3).frame == 1)
    #expect(pose(.claude, .working, at: 0).marks.isEmpty)
    let travel = Double(metrics.columns) + metrics.span
    let wrapped = pose(.claude, .working, at: travel / AgentSpriteLayout.workingSpeed + 1)
    #expect(wrapped.x < later.x)
    #expect(wrapped.x >= -metrics.span / 2)
  }

  @Test("needs attention parks, hops, blinks the bang and persists")
  func attention() {
    let arrived = 26 * metrics.scale / AgentSpriteLayout.runInSpeed
    let hop = pose(.claude, .needsAttention, at: arrived + 0.45)
    #expect(hop.x == 60)
    #expect(hop.up > 10)
    #expect(hop.marks.map(\.name) == ["!"])
    let blinkedOff = pose(.claude, .needsAttention, at: arrived + 1.0)
    #expect(blinkedOff.marks.isEmpty)
    let hours = pose(.claude, .needsAttention, at: 3_600.2)
    #expect(hours.x == 60 && hours.visible)
    #expect(hours.marks.count <= 1)
  }

  @Test("done sits with a check, then walks off after about 20 seconds")
  func done() {
    let sitting = pose(.codex, .done, at: 10)
    #expect(sitting.x == 60)
    #expect(sitting.marks.map(\.name) == ["check"])
    #expect(sitting.sparkle != nil)
    let leaving = pose(.codex, .done, at: 25)
    #expect(leaving.x > 60 && leaving.visible)
    #expect(pose(.codex, .done, at: 120).visible == false)
  }

  @Test("error tips Claude onto its side and deflates Codex")
  func error() {
    let tipped = pose(.claude, .error, at: 2)
    #expect(tipped.angle == 90)
    #expect(tipped.marks.map(\.name) == ["x"])
    let deflated = pose(.codex, .error, at: 2)
    #expect(deflated.squash < 0.6 && deflated.angle == 0)
    #expect(pose(.claude, .error, at: 0.1).angle < 90)
  }

  @Test("reduce motion holds a static pose per state at the park column")
  func reduceMotion() {
    for age in [0.0, 7.0, 500.0] {
      let working = pose(.claude, .working, at: age, reduceMotion: true)
      #expect(working.x == 60 && working.frame == 2 && working.up == 0)

      let attention = pose(.claude, .needsAttention, at: age, reduceMotion: true)
      #expect(attention.x == 60 && attention.up == 0)
      #expect(attention.marks.map(\.name) == ["!"])

      let done = pose(.codex, .done, at: age, reduceMotion: true)
      #expect(done.x == 60 && done.visible)
      #expect(done.marks.map(\.name) == ["check"] && done.sparkle == nil)

      let claudeError = pose(.claude, .error, at: age, reduceMotion: true)
      #expect(claudeError.angle == 90 && claudeError.brightness == 1)
      let codexError = pose(.codex, .error, at: age, reduceMotion: true)
      #expect(abs(codexError.squash - 0.55) < 1e-9)
    }
  }

  @Test("poses are deterministic and finite for hostile ages")
  func determinism() {
    for age in [-5.0, .nan, .infinity, 1e12] {
      let a = pose(.claude, .working, at: age)
      #expect(a == pose(.claude, .working, at: age))
      #expect(a.x.isFinite)
    }
  }

  @Test("two parked agents take separate slots and the runner draws behind them")
  func twoAgents() {
    let entries: [AgentSpriteLayout.Entry] = [
      .init(kind: .claude, state: .working, elapsed: 4, reduceMotion: false),
      .init(kind: .codex, state: .needsAttention, elapsed: 30, reduceMotion: false),
    ]
    let poses = AgentSpriteLayout.poses(
      entries: entries, columns: 120, rows: 40, parkFraction: 0.5)
    #expect(poses.map(\.kind) == [.claude, .codex])

    let both: [AgentSpriteLayout.Entry] = [
      .init(kind: .claude, state: .needsAttention, elapsed: 30, reduceMotion: false),
      .init(kind: .codex, state: .done, elapsed: 5, reduceMotion: false),
    ]
    let parked = AgentSpriteLayout.poses(
      entries: both, columns: 120, rows: 40, parkFraction: 0.5)
    #expect(abs(parked[0].x - parked[1].x) >= metrics.spacing - 0.001)

    let twoWorking = AgentSpriteLayout.poses(
      entries: [entries[0], .init(kind: .codex, state: .working, elapsed: 4, reduceMotion: false)],
      columns: 120, rows: 40, parkFraction: 0.5)
    #expect(abs(twoWorking[0].x - twoWorking[1].x) > metrics.span)

    let extra = AgentSpriteLayout.poses(
      entries: both + both, columns: 120, rows: 40, parkFraction: 0.5)
    #expect(extra.count == 2)
  }

  @Test("a parked sprite keeps its own cells when a runner crosses it")
  func runnerNeverPaintsOverParked() {
    let parkedEntry = AgentSpriteLayout.Entry(
      kind: .claude, state: .needsAttention, elapsed: 30, reduceMotion: false)
    let alone = AgentSpriteLayout.overrides(
      poses: AgentSpriteLayout.poses(
        entries: [parkedEntry], columns: 120, rows: 40, parkFraction: 0.5),
      columns: 120, rows: 40)
    let solidAlone = alone.filter { $0.mode == 1 }
    #expect(!solidAlone.isEmpty)
    for age in stride(from: 0.0, through: 24, by: 1.5) {
      let runner = AgentSpriteLayout.Entry(
        kind: .codex, state: .working, elapsed: age, reduceMotion: false)
      let together = AgentSpriteLayout.overrides(
        poses: AgentSpriteLayout.poses(
          entries: [parkedEntry, runner], columns: 120, rows: 40, parkFraction: 0.5),
        columns: 120, rows: 40)
      let byCell = Dictionary(uniqueKeysWithValues: together.map { ($0.cell, $0) })
      for cell in solidAlone {
        #expect(byCell[cell.cell]?.color == cell.color, "age \(age) cell \(cell.cell)")
      }
    }
  }

  @Test("overrides stay sparse, unique, in bounds and inside the bottom rows")
  func overrideShape() {
    let states: [IdleScreenAgentSpriteState] = [.working, .needsAttention, .done, .error]
    for kind in [IdleScreenAgentSpriteKind.claude, .codex] {
      for state in states {
        let overrides = AgentSpriteLayout.overrides(
          poses: AgentSpriteLayout.poses(
            entries: [.init(kind: kind, state: state, elapsed: 8, reduceMotion: false)],
            columns: 160, rows: 50, parkFraction: 0.5),
          columns: 160, rows: 50)
        #expect(overrides.count > 20 && overrides.count < 700, "\(kind) \(state)")
        #expect(Set(overrides.map(\.cell)).count == overrides.count)
        #expect(overrides.allSatisfy { Int($0.cell) < 160 * 50 })
        #expect(overrides.map(\.cell) == overrides.map(\.cell).sorted())
        let topRow = overrides.map { Int($0.cell) / 160 }.min() ?? 0
        #expect(topRow > 50 / 2)
      }
    }
  }

  @Test("camera mode parks right of centre, clear of the face")
  func cameraParks() {
    let poses = AgentSpriteLayout.poses(
      entries: [.init(kind: .claude, state: .needsAttention, elapsed: 30, reduceMotion: false)],
      columns: 200, rows: 60, parkFraction: AgentSpriteLayout.cameraParkFraction)
    #expect(abs(poses[0].x - 152) < 0.001)
  }
}

@Suite("Agent sprite GPU parity")
struct AgentSpriteParityTests {
  struct Instance: Equatable {
    var gridBrightnessGlyph: SIMD4<Float>
    var foreground: SIMD4<Float>
  }

  private struct CameraUniforms {
    var gridSize: SIMD2<UInt32>
    var cameraSize: SIMD2<UInt32>
    var contrast: Float
    var glyphCount: UInt32
    var mirrored: UInt32
    var usesCameraColor: UInt32
    var paletteForeground: SIMD4<Float>
  }

  private struct MaterialUniforms {
    var gridSize: SIMD2<UInt32>
    var worldSize: SIMD2<UInt32>
    var viewport: SIMD4<Float>
    var glyphCount: UInt32
    var sceneBrightness: Float
    var rockColor: SIMD4<Float>
    var soilColor: SIMD4<Float>
    var sandColor: SIMD4<Float>
    var waterColor: SIMD4<Float>
  }

  private static let columns = 120
  private static let rows = 40

  private static let entries: [AgentSpriteLayout.Entry] = [
    .init(kind: .claude, state: .needsAttention, elapsed: 30, reduceMotion: false),
    .init(kind: .codex, state: .error, elapsed: 4, reduceMotion: false),
  ]

  private static func overrides(parkFraction: Double = 0.5) -> [AgentSpriteCellOverride] {
    AgentSpriteLayout.overrides(
      poses: AgentSpriteLayout.poses(
        entries: entries, columns: columns, rows: rows, parkFraction: parkFraction),
      columns: columns, rows: rows)
  }

  private final class Harness {
    let device: any MTLDevice
    let library: any MTLLibrary
    let queue: any MTLCommandQueue
    let spritePipeline: any MTLComputePipelineState

    init() throws {
      device = try #require(MTLCreateSystemDefaultDevice())
      library = try device.makeDefaultLibrary(bundle: Bundle(for: IdleScreenRenderer.self))
      queue = try #require(device.makeCommandQueue())
      spritePipeline = try device.makeComputePipelineState(
        function: try #require(library.makeFunction(name: "idleScreenAgentSpriteOverrides")))
    }

    func pipeline(_ name: String) throws -> any MTLComputePipelineState {
      try device.makeComputePipelineState(
        function: try #require(library.makeFunction(name: name)))
    }

    /// Runs `main` to fill an instance buffer, then optionally the sprite pass,
    /// in one command buffer, as the renderer does.
    func run(
      count: Int,
      overrides: [AgentSpriteCellOverride]?,
      main: (any MTLComputeCommandEncoder, any MTLBuffer) throws -> Void
    ) throws -> [Instance] {
      let output = try #require(
        device.makeBuffer(
          length: count * MemoryLayout<Instance>.stride, options: .storageModeShared))
      let commandBuffer = try #require(queue.makeCommandBuffer())
      var encoder = try #require(commandBuffer.makeComputeCommandEncoder())
      try main(encoder, output)
      encoder.endEncoding()
      if let overrides, !overrides.isEmpty {
        let buffer = try #require(
          device.makeBuffer(
            bytes: overrides,
            length: overrides.count * MemoryLayout<AgentSpriteCellOverride>.stride,
            options: .storageModeShared))
        encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        var limits = SIMD2<UInt32>(UInt32(overrides.count), UInt32(count))
        encoder.setComputePipelineState(spritePipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 1)
        encoder.setBytes(&limits, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        let width = min(overrides.count, spritePipeline.threadExecutionWidth)
        encoder.dispatchThreadgroups(
          MTLSize(width: (overrides.count + width - 1) / width, height: 1, depth: 1),
          threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
      }
      commandBuffer.commit()
      commandBuffer.waitUntilCompleted()
      #expect(commandBuffer.status == .completed)
      let pointer = output.contents().bindMemory(to: Instance.self, capacity: count)
      return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
  }

  /// With sprites the GPU output must equal the sprite-free GPU output with the
  /// CPU definition of each override applied, and every untouched cell must be
  /// bit-identical to the sprite-free frame.
  private func assertSpritesMatch(
    _ label: String,
    overrides: [AgentSpriteCellOverride],
    harness: Harness,
    main: (any MTLComputeCommandEncoder, any MTLBuffer) throws -> Void
  ) throws {
    let count = Self.columns * Self.rows
    let base = try harness.run(count: count, overrides: nil, main: main)
    let withSprites = try harness.run(count: count, overrides: overrides, main: main)
    var expected = base
    for entry in overrides {
      let index = Int(entry.cell)
      let result = entry.applied(
        brightness: base[index].gridBrightnessGlyph.z,
        glyph: base[index].gridBrightnessGlyph.w,
        color: base[index].foreground)
      expected[index].gridBrightnessGlyph.z = result.brightness
      expected[index].gridBrightnessGlyph.w = result.glyph
      expected[index].foreground = result.color
    }
    #expect(!overrides.isEmpty)
    #expect(withSprites == expected, "\(label) GPU sprite pass differs from the CPU definition")
    let touched = Set(overrides.map { Int($0.cell) })
    for index in 0..<count where !touched.contains(index) {
      #expect(withSprites[index] == base[index], "\(label) cell \(index) changed outside sprites")
    }
    #expect(withSprites != base, "\(label) sprites changed nothing")
  }

  private func proceduralMain(
    pattern: String, harness: Harness
  ) throws -> (any MTLComputeCommandEncoder, any MTLBuffer) throws -> Void {
    let pipeline = try harness.pipeline("idleScreenProceduralInstances")
    let settings = IdleScreenProceduralPatternSettings.default.normalized
    let index = UInt32(
      IdleScreenProceduralPatterns.patternRawValues.firstIndex(of: pattern) ?? 0)
    return { encoder, output in
      var uniforms = ProceduralComputeUniforms(
        gridSize: SIMD2(UInt32(Self.columns), UInt32(Self.rows)),
        sceneSize: SIMD2(UInt32(Self.columns), UInt32(Self.rows)),
        sceneOrigin: SIMD2(0, 0),
        patternIndex: index, glyphCount: 10, timestamp: 7.25, contrast: 1.5,
        sceneBrightness: 1, speed: Float(settings.speed), scale: Float(settings.scale),
        intensity: Float(settings.intensity * settings.qualityLevel),
        trailing: Float(settings.trailing),
        matrixTrailLength: Float(settings.matrixTrailLength),
        rainbowAmplitude: Float(settings.rainbowAmplitude),
        fireDecay: Float(settings.fireDecay), foreground: SIMD4(0.8, 0.6, 0.4, 1))
      encoder.setComputePipelineState(pipeline)
      encoder.setBuffer(output, offset: 0, index: 0)
      encoder.setBytes(&uniforms, length: MemoryLayout<ProceduralComputeUniforms>.stride, index: 1)
      encoder.dispatchThreads(
        MTLSize(width: Self.columns, height: Self.rows, depth: 1),
        threadsPerThreadgroup: MTLSize(
          width: min(Self.columns, pipeline.threadExecutionWidth), height: 1, depth: 1))
    }
  }

  @Test("sprites match the CPU definition on three procedural patterns")
  func proceduralPatterns() throws {
    let harness = try Harness()
    for pattern in ["warp", "matrixRain", "plasma"] {
      try assertSpritesMatch(
        pattern, overrides: Self.overrides(), harness: harness,
        main: try proceduralMain(pattern: pattern, harness: harness))
    }
  }

  @Test("sprites match the CPU definition over a synthetic camera frame")
  func syntheticCamera() throws {
    let harness = try Harness()
    let pipeline = try harness.pipeline("idleScreenCameraInstances")
    let cameraColumns = 64
    let cameraRows = 36
    var luminance = [UInt8]()
    var rgb = [UInt8]()
    for y in 0..<cameraRows {
      for x in 0..<cameraColumns {
        luminance.append(UInt8((x * 3 + y * 5) % 256))
        rgb.append(contentsOf: [UInt8(x * 4 % 256), UInt8(y * 7 % 256), UInt8((x + y) * 2 % 256)])
      }
    }
    let luminanceBuffer = try #require(
      harness.device.makeBuffer(
        bytes: luminance, length: luminance.count, options: .storageModeShared))
    let rgbBuffer = try #require(
      harness.device.makeBuffer(bytes: rgb, length: rgb.count, options: .storageModeShared))
    try assertSpritesMatch(
      "camera", overrides: Self.overrides(parkFraction: AgentSpriteLayout.cameraParkFraction),
      harness: harness
    ) { encoder, output in
      var uniforms = CameraUniforms(
        gridSize: SIMD2(UInt32(Self.columns), UInt32(Self.rows)),
        cameraSize: SIMD2(UInt32(cameraColumns), UInt32(cameraRows)),
        contrast: 1.4, glyphCount: 10, mirrored: 1, usesCameraColor: 1,
        paletteForeground: SIMD4(0.8, 0.6, 0.4, 1))
      encoder.setComputePipelineState(pipeline)
      encoder.setBuffer(luminanceBuffer, offset: 0, index: 0)
      encoder.setBuffer(rgbBuffer, offset: 0, index: 1)
      encoder.setBuffer(output, offset: 0, index: 2)
      encoder.setBytes(&uniforms, length: MemoryLayout<CameraUniforms>.stride, index: 3)
      encoder.dispatchThreads(
        MTLSize(width: Self.columns, height: Self.rows, depth: 1),
        threadsPerThreadgroup: MTLSize(
          width: min(Self.columns, pipeline.threadExecutionWidth), height: 1, depth: 1))
    }
  }

  @Test("sprites match the CPU definition over Pixel Materials")
  func pixelMaterials() throws {
    let harness = try Harness()
    let pipeline = try harness.pipeline("idleScreenPixelMaterialInstances")
    var state = [UInt32]()
    for y in 0..<Self.rows {
      for x in 0..<Self.columns {
        let terrain: UInt32 = (x + y) % 7 == 0 ? 1 : 0
        state.append(terrain | UInt32((x * 2) % 40) << 8 | UInt32((y * 3) % 50) << 16)
      }
    }
    let stateBuffer = try #require(
      harness.device.makeBuffer(
        bytes: state, length: state.count * MemoryLayout<UInt32>.stride,
        options: .storageModeShared))
    try assertSpritesMatch(
      "pixel materials", overrides: Self.overrides(), harness: harness
    ) { encoder, output in
      var uniforms = MaterialUniforms(
        gridSize: SIMD2(UInt32(Self.columns), UInt32(Self.rows)),
        worldSize: SIMD2(UInt32(Self.columns), UInt32(Self.rows)),
        viewport: SIMD4(0, 0, 1, 1), glyphCount: 10, sceneBrightness: 1,
        rockColor: SIMD4(0.5, 0.4, 0.3, 1), soilColor: SIMD4(0.6, 0.4, 0.2, 1),
        sandColor: SIMD4(0.9, 0.7, 0.2, 1), waterColor: SIMD4(0.1, 0.6, 1, 1))
      encoder.setComputePipelineState(pipeline)
      encoder.setBuffer(stateBuffer, offset: 0, index: 0)
      encoder.setBuffer(output, offset: 0, index: 1)
      encoder.setBytes(&uniforms, length: MemoryLayout<MaterialUniforms>.stride, index: 2)
      encoder.dispatchThreads(
        MTLSize(width: Self.columns, height: Self.rows, depth: 1),
        threadsPerThreadgroup: MTLSize(
          width: min(Self.columns, pipeline.threadExecutionWidth), height: 1, depth: 1))
    }
  }

  @Test("an override outside the grid is ignored by the GPU pass")
  func outOfRangeIgnored() throws {
    let harness = try Harness()
    let bogus = AgentSpriteCellOverride(
      cell: UInt32(Self.columns * Self.rows + 5), mode: 1, brightness: 1, glyph: 9,
      color: SIMD4(1, 0, 0, 1))
    let main = try proceduralMain(pattern: "warp", harness: harness)
    let count = Self.columns * Self.rows
    let base = try harness.run(count: count, overrides: nil, main: main)
    let result = try harness.run(count: count, overrides: [bogus], main: main)
    #expect(result == base)
  }
}

@Suite("Agent sprite scene rules")
struct AgentSpriteSceneRuleTests {
  private func sprites(
    _ kind: IdleScreenAgentSpriteKind = .claude,
    _ state: IdleScreenAgentSpriteState,
    age: Double
  ) -> [IdleScreenAgentSprite] {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    return [
      IdleScreenAgentSprite(kind: kind, state: state, startedAt: now.addingTimeInterval(-age))
    ]
  }

  private func overrides(
    _ sprites: [IdleScreenAgentSprite],
    columns: Int = 120,
    viewport: IdleScreenRendererViewport = .full,
    brightness: Double = 1
  ) -> [AgentSpriteCellOverride] {
    AgentSpriteLayout.overrides(
      sprites: sprites, now: Date(timeIntervalSinceReferenceDate: 800_000_000),
      columns: columns, rows: 40, parkFraction: 0.5, seed: 0,
      viewport: viewport, sceneBrightness: brightness)
  }

  @Test("sprites follow the scene brightness and vanish at zero")
  func followsSceneBrightness() {
    let list = sprites(.codex, .needsAttention, age: 30)
    let full = overrides(list)
    #expect(overrides(list, brightness: 0).isEmpty)
    let subdued = overrides(list, brightness: 0.18)
    #expect(subdued.map(\.cell) == full.map(\.cell))
    let solidFull = full.filter { $0.mode == 1 }
    let solidSubdued = subdued.filter { $0.mode == 1 }
    #expect(!solidFull.isEmpty)
    for (a, b) in zip(solidFull, solidSubdued) {
      #expect(abs(b.brightness - a.brightness * 0.18) < 1e-6)
      #expect(a.color == b.color && a.glyph == b.glyph)
    }
    #expect(solidSubdued.allSatisfy { $0.brightness <= 0.18 + 1e-6 })
    let haloFull = full.filter { $0.mode == 0 }
    let haloSubdued = subdued.filter { $0.mode == 0 }
    #expect(haloFull == haloSubdued)
  }

  private struct Key: Hashable {
    var column: Int
    var row: Int
  }

  private func keyed(
    _ list: [AgentSpriteCellOverride], columns: Int, shift: Int = 0
  ) -> [Key: AgentSpriteCellOverride] {
    var result: [Key: AgentSpriteCellOverride] = [:]
    for entry in list {
      var copy = entry
      copy.cell = 0
      result[Key(column: Int(entry.cell) % columns + shift, row: Int(entry.cell) / columns)] = copy
    }
    return result
  }

  @Test("two display slices lay out one panorama, so a runner crosses the seam once")
  func panoramaAcrossDisplays() {
    let left = IdleScreenRendererViewport(x: 0, y: 0, width: 0.5, height: 1)
    let right = IdleScreenRendererViewport(x: 0.5, y: 0, width: 0.5, height: 1)
    for (state, age) in [
      (IdleScreenAgentSpriteState.needsAttention, 30.0), (.working, 18.0), (.error, 5.0),
    ] {
      let list = sprites(.claude, state, age: age)
      let whole = keyed(overrides(list, columns: 200), columns: 200)
      let leftSlice = keyed(overrides(list, columns: 100, viewport: left), columns: 100)
      let rightSlice = keyed(
        overrides(list, columns: 100, viewport: right), columns: 100, shift: 100)
      let combined = leftSlice.merging(rightSlice) { a, _ in a }
      #expect(Set(leftSlice.keys).isDisjoint(with: rightSlice.keys))
      #expect(combined == whole, "\(state)")
      #expect(!leftSlice.isEmpty && !rightSlice.isEmpty, "\(state) should straddle the seam")
    }
  }

  @Test("a single display is unchanged by the panorama layout")
  func fullViewportIsIdentity() {
    let list = sprites(.codex, .done, age: 8)
    #expect(
      overrides(list, columns: 140)
        == overrides(list, columns: 140, viewport: .init(x: 0, y: 0, width: 1, height: 1)))
  }

  @Test("past the cell cap the body survives and the halo goes first")
  func capKeepsTheBody() {
    let poses = AgentSpriteLayout.poses(
      entries: [
        .init(kind: .codex, state: .error, elapsed: 5, reduceMotion: false),
        .init(kind: .codex, state: .error, elapsed: 5, reduceMotion: false),
      ],
      columns: 200, rows: 60, parkFraction: 0.5)
    let uncapped = AgentSpriteLayout.overrides(poses: poses, columns: 200, rows: 60, cap: 10_000)
    let body = uncapped.filter { $0.mode == 1 }
    #expect(uncapped.count > body.count)
    #expect(body.count > 100)
    let capped = AgentSpriteLayout.overrides(
      poses: poses, columns: 200, rows: 60, cap: body.count)
    #expect(capped.count == body.count)
    #expect(capped == body)
    let tighter = AgentSpriteLayout.overrides(
      poses: poses, columns: 200, rows: 60, cap: body.count - 10)
    #expect(tighter.count == body.count - 10)
    #expect(tighter.allSatisfy { $0.mode == 1 })
  }
}
