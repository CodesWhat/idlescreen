import MetalKit
import Testing
import simd

@testable import IdleScreenRenderer

@Suite("Agent sprite poses")
struct AgentSpritePoseTests {
  private let metrics = AgentSpriteLayout.Metrics(columns: 120)

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
      AgentSpriteLayout.layer(
        sprites: [], now: Date(), columns: 120, rows: 40, viewSize: (960, 504),
        groundRow: 40, parkFraction: 0.5, seed: 0
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
    let poses = AgentSpriteLayout.poses(entries: entries, columns: 120, parkFraction: 0.5)
    #expect(poses.map(\.kind) == [.claude, .codex])

    let both: [AgentSpriteLayout.Entry] = [
      .init(kind: .claude, state: .needsAttention, elapsed: 30, reduceMotion: false),
      .init(kind: .codex, state: .done, elapsed: 5, reduceMotion: false),
    ]
    let parked = AgentSpriteLayout.poses(entries: both, columns: 120, parkFraction: 0.5)
    #expect(abs(parked[0].x - parked[1].x) >= metrics.spacing - 0.001)

    let twoWorking = AgentSpriteLayout.poses(
      entries: [entries[0], .init(kind: .codex, state: .working, elapsed: 4, reduceMotion: false)],
      columns: 120, parkFraction: 0.5)
    #expect(abs(twoWorking[0].x - twoWorking[1].x) > metrics.span)

    let extra = AgentSpriteLayout.poses(entries: both + both, columns: 120, parkFraction: 0.5)
    #expect(extra.count == 2)
  }

  @Test("camera mode parks right of centre, clear of the face")
  func cameraParks() {
    let poses = AgentSpriteLayout.poses(
      entries: [.init(kind: .claude, state: .needsAttention, elapsed: 30, reduceMotion: false)],
      columns: 200, parkFraction: AgentSpriteLayout.cameraParkFraction)
    #expect(abs(poses[0].x - 152) < 0.001)
  }
}

@Suite("Agent sprite lattice")
struct AgentSpriteLatticeTests {
  static let geometry = AgentSpriteLayout.Geometry(
    columns: 160, rows: 50, sceneColumns: 160, originColumn: 0,
    width: 1_280, height: 630, groundY: 630)

  private func layer(
    _ kind: IdleScreenAgentSpriteKind, _ state: IdleScreenAgentSpriteState, elapsed: Double = 8,
    geometry: AgentSpriteLayout.Geometry = geometry, cap: Int = AgentSpriteLayout.hardCap
  ) -> AgentSpriteLayer {
    AgentSpriteLayout.layer(
      poses: AgentSpriteLayout.poses(
        entries: [.init(kind: kind, state: state, elapsed: elapsed, reduceMotion: false)],
        columns: geometry.sceneColumns, parkFraction: 0.5),
      geometry: geometry, cap: cap)
  }

  @Test("every sprite pixel is a square one cell wide, stacked on a shared lattice")
  func squarePixels() {
    let geometry = Self.geometry
    for kind in [IdleScreenAgentSpriteKind.claude, .codex] {
      for state in [IdleScreenAgentSpriteState.working, .needsAttention, .done, .error] {
        let quads = layer(kind, state).quads
        #expect(quads.count > 20 && quads.count < 900, "\(kind) \(state)")
        for quad in quads {
          let width = Double(quad.edges.z - quad.edges.x)
          let height = Double(quad.edges.w - quad.edges.y)
          #expect(abs(width - geometry.pixel) < 0.01 && abs(height - geometry.pixel) < 0.01)
          #expect(quad.color.w == 1)
          // Every edge is a multiple of the pixel from the ground and the origin.
          let rowsUp = (geometry.groundY - Double(quad.edges.w)) / geometry.pixel
          #expect(abs(rowsUp - rowsUp.rounded()) < 1e-3)
        }
      }
    }
  }

  @Test("sprites stand on the ground line and stay in the lower part of the frame")
  func standOnTheGround() {
    for groundY in [630.0, 400.0] {
      var geometry = Self.geometry
      geometry.groundY = groundY
      for kind in [IdleScreenAgentSpriteKind.claude, .codex] {
        let quads = layer(kind, .working, elapsed: 3, geometry: geometry).quads
        let bottom = quads.map { Double($0.edges.w) }.max() ?? 0
        let top = quads.map { Double($0.edges.y) }.min() ?? 0
        #expect(abs(bottom - groundY) < 0.01, "\(kind) feet at \(bottom), ground \(groundY)")
        #expect(top > groundY - 25 * geometry.pixel)
      }
    }
  }

  @Test("Claude and Codex have distinct silhouettes and colours")
  func distinct() {
    let claude = layer(.claude, .working, elapsed: 4).quads
    let codex = layer(.codex, .working, elapsed: 4).quads
    #expect(claude.count != codex.count)
    #expect(claude.contains { $0.color == AgentSpriteLayout.terracotta.asOpaque })
    #expect(codex.contains { $0.color == AgentSpriteLayout.codexWhite.asOpaque })
    // The terminal bot is wider than the spark creature.
    func width(_ quads: [AgentSpriteQuad]) -> Float {
      (quads.map(\.edges.z).max() ?? 0) - (quads.map(\.edges.x).min() ?? 0)
    }
    #expect(width(codex) > width(claude))
  }

  @Test("cut-outs punch the face through to the background colour")
  func cutOuts() {
    let background = SIMD3<Float>(0.02, 0.03, 0.05)
    let poses = AgentSpriteLayout.poses(
      entries: [.init(kind: .claude, state: .needsAttention, elapsed: 30, reduceMotion: true)],
      columns: 160, parkFraction: 0.5)
    let result = AgentSpriteLayout.layer(
      poses: poses, geometry: Self.geometry, background: background)
    let cutColor = SIMD4<Float>(background, 1)
    #expect(result.quads.contains { $0.color == cutColor })
    let body = AgentSpriteLayout.terracotta
    #expect(
      result.quads.contains {
        $0.color.w == 1 && simd_length($0.color.xyz - body) < 1e-5
      })
  }

  @Test("a parked sprite keeps its own pixels when a runner crosses it")
  func runnerNeverPaintsOverParked() {
    let parkedEntry = AgentSpriteLayout.Entry(
      kind: .claude, state: .needsAttention, elapsed: 30, reduceMotion: false)
    func finalColours(_ entries: [AgentSpriteLayout.Entry]) -> [SIMD4<Float>: SIMD4<Float>] {
      let poses = AgentSpriteLayout.poses(entries: entries, columns: 160, parkFraction: 0.5)
      var colours: [SIMD4<Float>: SIMD4<Float>] = [:]
      for quad in AgentSpriteLayout.layer(poses: poses, geometry: Self.geometry).quads {
        colours[quad.edges] = quad.color
      }
      return colours
    }
    let alone = finalColours([parkedEntry])
    #expect(!alone.isEmpty)
    for age in stride(from: 0.0, through: 24, by: 1.5) {
      let runner = AgentSpriteLayout.Entry(
        kind: .codex, state: .working, elapsed: age, reduceMotion: false)
      let together = finalColours([parkedEntry, runner])
      for (edges, colour) in alone {
        #expect(together[edges] == colour, "age \(age) quad \(edges)")
      }
    }
  }

  @Test("the halo thins the glyphs around a sprite, in bounds and unique")
  func haloShape() {
    let result = layer(.codex, .done)
    #expect(result.halo.count > 40)
    #expect(Set(result.halo.map(\.cell)).count == result.halo.count)
    #expect(result.halo.allSatisfy { Int($0.cell) < 160 * 50 && $0.mode == 0 })
    #expect(result.halo.map(\.cell) == result.halo.map(\.cell).sorted())
    #expect(result.halo.allSatisfy { $0.brightness == AgentSpriteLayout.haloFactor })
    // Every quad sits inside a halo cell.
    let cells = Set(result.halo.map { Int($0.cell) })
    let geometry = Self.geometry
    for quad in result.quads {
      let column = Int(quad.edges.x / Float(geometry.cellWidth))
      let row = Int(quad.edges.y / Float(geometry.cellHeight))
      #expect(cells.contains(row * 160 + column))
    }
  }

  @Test("past the cap the halo goes first, then the sparkle, then the cut-outs")
  func capKeepsTheBody() {
    let poses = AgentSpriteLayout.poses(
      entries: [
        .init(kind: .codex, state: .error, elapsed: 5, reduceMotion: false),
        .init(kind: .codex, state: .done, elapsed: 5, reduceMotion: false),
      ],
      columns: 200, parkFraction: 0.5)
    var geometry = Self.geometry
    geometry.columns = 200
    geometry.sceneColumns = 200
    geometry.width = 1_600
    let uncapped = AgentSpriteLayout.layer(poses: poses, geometry: geometry, cap: 100_000)
    #expect(uncapped.halo.count > 0 && uncapped.quads.count > 100)

    let quadsOnly = AgentSpriteLayout.layer(
      poses: poses, geometry: geometry, cap: uncapped.quads.count)
    #expect(quadsOnly.halo.isEmpty)
    #expect(quadsOnly.quads == uncapped.quads)

    let tighter = AgentSpriteLayout.layer(
      poses: poses, geometry: geometry, cap: uncapped.quads.count - 10)
    #expect(tighter.halo.isEmpty)
    #expect(tighter.quads.count == uncapped.quads.count - 10)
    // What was lost is lower priority than what stayed: the body is intact.
    let background = SIMD4<Float>(0, 0, 0, 1)
    let bodyColours: Set<SIMD4<Float>> = [
      AgentSpriteLayout.codexWhite.asOpaque, AgentSpriteLayout.mint.asOpaque,
      AgentSpriteLayout.red.asOpaque,
    ]
    func count(_ layer: AgentSpriteLayer) -> Int {
      layer.quads.filter { bodyColours.contains($0.color) }.count
    }
    #expect(count(tighter) == count(uncapped))
    #expect(
      tighter.quads.filter { $0.color == background }.count
        < uncapped.quads.filter { $0.color == background }.count)
  }
}

@Suite("Agent sprite scene rules")
struct AgentSpriteSceneRuleTests {
  private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private static let background = SIMD3<Float>(0.016, 0.02, 0.035)

  private func sprites(
    _ kind: IdleScreenAgentSpriteKind = .claude,
    _ state: IdleScreenAgentSpriteState,
    age: Double
  ) -> [IdleScreenAgentSprite] {
    [
      IdleScreenAgentSprite(
        kind: kind, state: state, startedAt: Self.now.addingTimeInterval(-age))
    ]
  }

  private func layer(
    _ sprites: [IdleScreenAgentSprite],
    columns: Int = 120,
    width: Double? = nil,
    viewport: IdleScreenRendererViewport = .full,
    brightness: Double = 1,
    groundRow: Double = 40
  ) -> AgentSpriteLayer {
    AgentSpriteLayout.layer(
      sprites: sprites, now: Self.now, columns: columns, rows: 40,
      viewSize: (width ?? Double(columns) * 8, 504), groundRow: groundRow,
      parkFraction: 0.5, seed: 0, viewport: viewport, sceneBrightness: brightness,
      background: Self.background)
  }

  @Test("sprites follow the scene brightness and vanish at zero")
  func followsSceneBrightness() {
    let list = sprites(.codex, .needsAttention, age: 30)
    let full = layer(list)
    #expect(layer(list, brightness: 0).isEmpty)
    let subdued = layer(list, brightness: 0.18)
    #expect(subdued.quads.map(\.edges) == full.quads.map(\.edges))
    #expect(subdued.halo == full.halo)
    let cut = SIMD4<Float>(Self.background, 1)
    var solid = 0
    for (a, b) in zip(full.quads, subdued.quads) {
      if a.color == cut {
        #expect(b.color == cut)
        continue
      }
      solid += 1
      let expected = Self.background + (a.color.xyz - Self.background) * 0.18
      #expect(abs(b.color.x - expected.x) < 1e-5 && abs(b.color.y - expected.y) < 1e-5)
    }
    #expect(solid > 100)
  }

  private func keys(_ quads: [AgentSpriteQuad], shift: Float = 0) -> Set<[Int]> {
    Set(
      quads.map {
        [
          Int((($0.edges.x + shift) * 100).rounded()), Int(($0.edges.y * 100).rounded()),
          Int((($0.edges.z + shift) * 100).rounded()), Int(($0.edges.w * 100).rounded()),
        ] + [Int($0.color.x * 1000), Int($0.color.y * 1000), Int($0.color.z * 1000)]
      })
  }

  @Test("two display slices lay out one panorama, so a runner crosses the seam once")
  func panoramaAcrossDisplays() {
    let left = IdleScreenRendererViewport(x: 0, y: 0, width: 0.5, height: 1)
    let right = IdleScreenRendererViewport(x: 0.5, y: 0, width: 0.5, height: 1)
    for (state, age) in [
      (IdleScreenAgentSpriteState.needsAttention, 30.0), (.working, 18.0), (.error, 5.0),
    ] {
      let list = sprites(.claude, state, age: age)
      let whole = layer(list, columns: 200)
      let leftSlice = layer(list, columns: 100, viewport: left)
      let rightSlice = layer(list, columns: 100, viewport: right)
      let combined = keys(leftSlice.quads).union(keys(rightSlice.quads, shift: 800))
      #expect(combined == keys(whole.quads), "\(state)")
      #expect(!leftSlice.quads.isEmpty && !rightSlice.quads.isEmpty, "\(state) straddles the seam")
      // Halo cells line up too: the right slice's cell 0 is whole cell 100.
      let wholeCells = Set(whole.halo.map { Int($0.cell) })
      let sliceCells = Set(leftSlice.halo.map { Int($0.cell) })
        .union(rightSlice.halo.map { Int($0.cell) / 100 * 200 + Int($0.cell) % 100 + 100 })
        .union(leftSlice.halo.map { Int($0.cell) / 100 * 200 + Int($0.cell) % 100 })
      #expect(sliceCells.isSuperset(of: wholeCells))
    }
  }

  @Test("a single display is unchanged by the panorama layout")
  func fullViewportIsIdentity() {
    let list = sprites(.codex, .done, age: 8)
    #expect(
      layer(list, columns: 140)
        == layer(list, columns: 140, viewport: .init(x: 0, y: 0, width: 1, height: 1)))
  }

  @Test("the ground row moves the feet and leaves everything else alone")
  func groundRow() {
    let list = sprites(.codex, .done, age: 8)
    let bottom = layer(list, groundRow: 40)
    let horizon = layer(list, groundRow: 24)
    #expect(bottom.quads.count == horizon.quads.count)
    let drop = Float(24.0 * 504 / 40)
    let lift = Float(40.0 * 504 / 40) - drop
    for (a, b) in zip(bottom.quads, horizon.quads) {
      #expect(abs(a.edges.y - b.edges.y - lift) < 0.01)
      #expect(a.edges.x == b.edges.x && a.color == b.color)
    }
    #expect(
      abs((horizon.quads.map(\.edges.w).max() ?? 0) - drop) < 0.01)
  }
}

@Suite("Agent sprite halo GPU parity")
struct AgentSpriteHaloParityTests {
  struct Instance: Equatable {
    var gridBrightnessGlyph: SIMD4<Float>
    var foreground: SIMD4<Float>
  }

  private static let columns = 120
  private static let rows = 40

  private static func halo() -> [AgentSpriteCellOverride] {
    let geometry = AgentSpriteLayout.Geometry(
      columns: columns, rows: rows, sceneColumns: columns, originColumn: 0,
      width: 960, height: 504, groundY: 504)
    return AgentSpriteLayout.layer(
      poses: AgentSpriteLayout.poses(
        entries: [
          .init(kind: .claude, state: .needsAttention, elapsed: 30, reduceMotion: false),
          .init(kind: .codex, state: .error, elapsed: 4, reduceMotion: false),
        ], columns: columns, parkFraction: 0.5),
      geometry: geometry
    ).halo
  }

  /// The halo is the one cell-override use left, so one GPU pass over a
  /// synthetic scene must equal the CPU definition cell for cell.
  @Test("the GPU halo pass matches the CPU definition and touches nothing else")
  func haloMatchesCPU() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let library = try device.makeDefaultLibrary(bundle: Bundle(for: IdleScreenRenderer.self))
    let queue = try #require(device.makeCommandQueue())
    let pipeline = try device.makeComputePipelineState(
      function: try #require(library.makeFunction(name: "idleScreenAgentSpriteOverrides")))
    let overrides = Self.halo()
    #expect(overrides.count > 100)
    let count = Self.columns * Self.rows
    var base: [Instance] = []
    for index in 0..<count {
      base.append(
        Instance(
          gridBrightnessGlyph: SIMD4(
            Float(index % Self.columns), Float(index / Self.columns),
            Float(index % 13) / 12, Float(index % 10)),
          foreground: SIMD4(0.7, 0.74, 0.82, 1)))
    }
    let instanceBuffer = try #require(
      device.makeBuffer(
        bytes: base, length: count * MemoryLayout<Instance>.stride, options: .storageModeShared))
    let overrideBuffer = try #require(
      device.makeBuffer(
        bytes: overrides, length: overrides.count * MemoryLayout<AgentSpriteCellOverride>.stride,
        options: .storageModeShared))
    var limits = SIMD2<UInt32>(UInt32(overrides.count), UInt32(count))
    let commandBuffer = try #require(queue.makeCommandBuffer())
    let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(instanceBuffer, offset: 0, index: 0)
    encoder.setBuffer(overrideBuffer, offset: 0, index: 1)
    encoder.setBytes(&limits, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
    let width = min(overrides.count, pipeline.threadExecutionWidth)
    encoder.dispatchThreadgroups(
      MTLSize(width: (overrides.count + width - 1) / width, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)

    let pointer = instanceBuffer.contents().bindMemory(to: Instance.self, capacity: count)
    let gpu = Array(UnsafeBufferPointer(start: pointer, count: count))
    var expected = base
    for entry in overrides {
      let index = Int(entry.cell)
      let result = entry.applied(
        brightness: base[index].gridBrightnessGlyph.z, glyph: base[index].gridBrightnessGlyph.w,
        color: base[index].foreground)
      expected[index].gridBrightnessGlyph.z = result.brightness
      expected[index].gridBrightnessGlyph.w = result.glyph
      expected[index].foreground = result.color
    }
    #expect(gpu == expected)
    #expect(gpu != base)
  }
}

extension SIMD3 where Scalar == Float {
  fileprivate var asOpaque: SIMD4<Float> { SIMD4(self, 1) }
}

extension SIMD4 where Scalar == Float {
  fileprivate var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
