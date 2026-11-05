import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import Testing
import UniformTypeIdentifiers

@testable import IdleScreenRenderer

/// Renders full frames offscreen with the real Metal renderer, with and without
/// agent sprites, across the procedural, camera and Pixel Materials paths.
///
/// The ungated tests assert the sprite pass changes only the bottom of the
/// frame. Setting `IDLESCREEN_SPRITE_CAPTURE_DIR` (pass it through xcodebuild as
/// `TEST_RUNNER_IDLESCREEN_SPRITE_CAPTURE_DIR`) also writes PNGs of each shot.
@Suite("Agent sprite rendering")
struct AgentSpriteRenderTests {
  private static let width = 1_600
  private static let height = 1_000
  private static let pinned = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private final class CompletionCounter: IdleScreenRendererPerformanceObserving,
    @unchecked Sendable
  {
    private let lock = NSLock()
    private var completed = 0
    func rendererDidRecordPerformance(_ event: IdleScreenRendererPerformanceEvent) {
      if case .completed = event {
        lock.lock()
        completed += 1
        lock.unlock()
      }
    }
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return completed
    }
  }

  private typealias SpriteSpec = (
    IdleScreenAgentSpriteKind, IdleScreenAgentSpriteState, Double, Bool
  )

  private struct Shot {
    var name: String
    var pattern: String
    var palette: String
    var sprites: [SpriteSpec]
    var frames = 1
    var time = 20.0
    var camera = false
    var glyphScale = 0.38
    var brightness = 1.0
    var framing = IdleScreenRendererFraming.none
  }

  private static func configuration(
    _ shot: Shot, withSprites: Bool
  ) -> IdleScreenRendererConfiguration {
    var value = IdleScreenRendererConfiguration.default
    value.patternRawValue = shot.pattern
    value.sceneSeed = 7
    value.palette = shot.palette
    value.glyphScale = shot.glyphScale
    value.contrast = 1
    value.sceneBrightness = shot.brightness
    value.framing = shot.framing
    value.proceduralSettings.intensity = 1
    if shot.pattern == "pixelMaterials" {
      value.pixelMaterialsSettings = .init(
        material: .mixed, terrainStyle: .terraces, emitterCount: 3, emitterWidth: 8,
        emitterRate: 8, cellScale: 2, paletteRawValue: "canyon")
    }
    if withSprites {
      value.agentSprites = shot.sprites.map { kind, state, age, reduceMotion in
        IdleScreenAgentSprite(
          kind: kind, state: state, startedAt: pinned.addingTimeInterval(-age),
          reduceMotion: reduceMotion)
      }
    }
    return value
  }

  /// A synthetic BGRA frame: a soft bright oval on a dim gradient.
  private static func syntheticCameraFrame() throws -> IdleScreenRendererCameraFrame {
    let w = 320
    let h = 180
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
      for x in 0..<w {
        let dx = (Double(x) - 160) / 55
        let dy = (Double(y) - 80) / 70
        let face = max(0, 1 - (dx * dx + dy * dy))
        let level = UInt8(min(255, 40 + 40 * Double(y) / Double(h) + 190 * face))
        let i = (y * w + x) * 4
        pixels[i] = level
        pixels[i + 1] = level
        pixels[i + 2] = level
        pixels[i + 3] = 255
      }
    }
    return try #require(
      pixels.withUnsafeBytes {
        IdleScreenRendererCameraFrame.samplingBGRA(
          producerStreamEpoch: 1, sequence: 1, width: w, height: h, bytesPerRow: w * 4,
          pixels: $0, columns: 160, rows: 90)
      })
  }

  @MainActor
  private func render(
    _ shot: Shot, withSprites: Bool, onCPU: Bool = false,
    frame: ((IdleScreenRenderer) -> Void)? = nil
  ) throws -> [UInt8] {
    let view = MTKView(frame: .init(x: 0, y: 0, width: Self.width / 2, height: Self.height / 2))
    view.autoResizeDrawable = false
    view.drawableSize = .init(width: Self.width, height: Self.height)
    view.framebufferOnly = false
    let counter = CompletionCounter()
    let renderer = try IdleScreenRenderer(
      metalView: view,
      configuration: Self.configuration(shot, withSprites: withSprites),
      mode: shot.camera ? .camera : .generative,
      automaticallyDraws: false,
      pixelMaterialsCoordinator: .init(),
      performanceObserver: counter)
    defer { renderer.shutdown() }
    renderer.agentSpriteReferenceDate = Self.pinned
    renderer.forcesCPUGlyphFill = onCPU
    (view.layer as? CAMetalLayer)?.drawableSize = .init(width: Self.width, height: Self.height)
    if shot.camera {
      renderer.submit(cameraFrame: try Self.syntheticCameraFrame())
    }

    var last: (any MTLTexture)?
    for index in 0..<shot.frames {
      let drawable = try #require(view.currentDrawable)
      last = drawable.texture
      let before = counter.count
      let time = shot.frames == 1 ? shot.time : Double(index) / 30
      #expect(renderer.draw(at: time))
      let deadline = Date().addingTimeInterval(10)
      while counter.count == before, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.002)
      }
      #expect(counter.count > before)
    }
    frame?(renderer)
    let texture = try #require(last)
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
      &bytes, bytesPerRow: texture.width * 4,
      from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    return bytes
  }

  /// Count of differing pixels and the topmost differing pixel row.
  private func diff(_ a: [UInt8], _ b: [UInt8]) -> (changed: Int, topRow: Int) {
    var changed = 0
    var top = Int.max
    for pixel in 0..<(a.count / 4) {
      let i = pixel * 4
      if a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] {
        changed += 1
        top = min(top, pixel / Self.width)
      }
    }
    return (changed, top)
  }

  private static let attention: [SpriteSpec] = [(.claude, .needsAttention, 30, false)]

  @MainActor
  @Test("sprites only change the bottom of the frame on every render path")
  func spritesStayAtTheBottom() throws {
    let shots = [
      Shot(name: "procedural", pattern: "warp", palette: "Phosphor", sprites: Self.attention),
      Shot(
        name: "materials", pattern: "pixelMaterials", palette: "Ember",
        sprites: [(.codex, .working, 6, false)], frames: 20),
      Shot(
        name: "camera", pattern: "warp", palette: "Phosphor", sprites: Self.attention,
        camera: true),
    ]
    for shot in shots {
      let plain = try render(shot, withSprites: false)
      let drawn = try render(shot, withSprites: true)
      let result = diff(plain, drawn)
      #expect(result.changed > 2_000, "\(shot.name) sprites drew nothing")
      #expect(result.topRow > Self.height * 2 / 5, "\(shot.name) changed above the bottom 60%")
    }
  }

  @MainActor
  @Test("aquarium solid pixels retain the agent halo on GPU and CPU fill paths")
  func aquariumAgentHalo() throws {
    let shot = Shot(
      name: "aquarium", pattern: "aquarium", palette: "Cobalt", sprites: Self.attention)
    for cpu in [false, true] {
      let plain = try render(shot, withSprites: false, onCPU: cpu)
      var spriteFrame: (columns: Int, rows: Int, layer: AgentSpriteLayer)?
      let drawn = try render(shot, withSprites: true, onCPU: cpu) {
        spriteFrame = $0.lastSpriteFrame
      }
      let frame = try #require(spriteFrame)
      var sampled = 0
      for halo in frame.layer.halo {
        let x =
          (Double(Int(halo.cell) % frame.columns) + 0.5) / Double(frame.columns)
          * Double(Self.width)
        let y =
          (Double(Int(halo.cell) / frame.columns) + 0.5) / Double(frame.rows) * Double(Self.height)
        guard
          !frame.layer.quads.contains(where: {
            Float(x / 2) >= $0.edges.x && Float(x / 2) <= $0.edges.z
              && Float(y / 2) >= $0.edges.y && Float(y / 2) <= $0.edges.w
          })
        else { continue }
        let offset = (Int(y) * Self.width + Int(x)) * 4
        let before = Int(plain[offset]) + Int(plain[offset + 1]) + Int(plain[offset + 2])
        let after = Int(drawn[offset]) + Int(drawn[offset + 1]) + Int(drawn[offset + 2])
        if before > 15 {
          #expect(after < before / 3, "aquarium halo did not dim a solid pixel")
          sampled += 1
        }
      }
      #expect(sampled > 5)
    }
  }

  @MainActor
  @Test("Topograph honors full bleed and horizon on both render paths")
  func topographHonorsFraming() throws {
    for cpu in [false, true] {
      var frames: [[UInt8]] = []
      for framing in [IdleScreenRendererFraming.none, .horizon] {
        var topograph = Shot(
          name: "topograph", pattern: "topograph", palette: "Cobalt", sprites: [])
        topograph.framing = framing
        var terrain = topograph
        terrain.pattern = "terrain"
        let actual = try render(topograph, withSprites: false, onCPU: cpu)
        let expected = try render(terrain, withSprites: false, onCPU: cpu)
        #expect(actual == expected)
        frames.append(actual)
      }
      #expect(frames[0] != frames[1], "changing framing must change the rendered scene")
    }
  }

  @MainActor
  @Test("an empty sprite list renders the same frame as no sprite pass at all")
  func emptyIsIdentical() throws {
    let shot = Shot(name: "empty", pattern: "plasma", palette: "Ember", sprites: [])
    let plain = try render(shot, withSprites: false)
    #expect(plain.contains { $0 != 0 }, "the frame must not be blank")
    #expect(try render(shot, withSprites: true) == plain)
    // A real sprite changes the same frame, so equality above is meaningful.
    let drawn = Shot(
      name: "drawn", pattern: "plasma", palette: "Ember", sprites: Self.attention)
    #expect(try render(drawn, withSprites: true) != plain)
  }

  @MainActor
  @Test("sprites dim with the scene and disappear at zero brightness")
  func spritesFollowSceneBrightness() throws {
    func peak(_ brightness: Double) throws -> Int {
      var shot = Shot(
        name: "dim", pattern: "plasma", palette: "Ember", sprites: Self.attention)
      shot.brightness = brightness
      let plain = try render(shot, withSprites: false)
      let drawn = try render(shot, withSprites: true)
      var best = 0
      for pixel in 0..<(plain.count / 4) {
        let i = pixel * 4
        if plain[i] != drawn[i] || plain[i + 1] != drawn[i + 1] || plain[i + 2] != drawn[i + 2] {
          best = max(best, Int(drawn[i]) + Int(drawn[i + 1]) + Int(drawn[i + 2]))
        }
      }
      return best
    }
    let full = try peak(1)
    let subdued = try peak(0.18)
    #expect(full > 0)
    #expect(subdued * 2 < full, "a subdued display still shows a full-bright sprite")
    #expect(try peak(0) == 0)
  }

  /// The sprite lattice goes through the real renderer on both fill paths. The
  /// quads are laid out on the CPU and rasterised by the GPU, so every pixel
  /// inside a quad must be exactly that quad's colour, whichever path filled
  /// the glyph grid underneath.
  @MainActor
  @Test("the GPU draws the CPU sprite lattice exactly, on both glyph fill paths")
  func latticeMatchesCPULayout() throws {
    let shot = Shot(
      name: "parity", pattern: "plasma", palette: "Ember",
      sprites: [(.claude, .done, 8, false), (.codex, .error, 8, false)])
    var gpuFrame: (columns: Int, rows: Int, layer: AgentSpriteLayer)?
    var cpuFrame: (columns: Int, rows: Int, layer: AgentSpriteLayer)?
    let gpu = try render(shot, withSprites: true) { gpuFrame = $0.lastSpriteFrame }
    let cpu = try render(shot, withSprites: true, onCPU: true) { cpuFrame = $0.lastSpriteFrame }
    let plainCPU = try render(shot, withSprites: false, onCPU: true)
    #expect(cpu != plainCPU, "the CPU-filled frame shows no sprites")
    let frame = try #require(gpuFrame)
    #expect(frame.layer == cpuFrame?.layer)
    #expect(frame.layer.quads.count > 100)
    let scale = Float(Self.width) / Float(Self.width / 2)
    var compared = 0
    for quad in frame.layer.quads {
      let expected = quad.color.rgbBytes
      let x0 = Int((quad.edges.x * scale).rounded(.up)) + 1
      let x1 = Int((quad.edges.z * scale).rounded(.down)) - 1
      let y0 = Int((quad.edges.y * scale).rounded(.up)) + 1
      let y1 = Int((quad.edges.w * scale).rounded(.down)) - 1
      guard x1 > x0, y1 > y0, x0 >= 0, y0 >= 0, x1 < Self.width, y1 < Self.height else {
        continue
      }
      for (name, pixels) in [("GPU", gpu), ("CPU", cpu)] {
        for y in y0..<y1 {
          for x in x0..<x1 {
            let i = (y * Self.width + x) * 4
            let actual = [pixels[i + 2], pixels[i + 1], pixels[i]]
            guard zip(actual, expected).allSatisfy({ abs(Int($0) - Int($1)) <= 1 }) else {
              Issue.record("\(name) pixel (\(x), \(y)) is \(actual), quad is \(expected)")
              return
            }
          }
        }
      }
      compared += 1
    }
    #expect(compared > 100)
  }

  @MainActor
  @Test("the horizon frames the scene: a quiet sky, a ground, an accent line, feet on the line")
  func horizonFraming() throws {
    var shot = Shot(
      name: "horizon", pattern: "terrain", palette: "Cobalt",
      sprites: [(.claude, .needsAttention, 30, false), (.codex, .done, 8, false)])
    shot.framing = .horizon
    var open = shot
    open.framing = IdleScreenRendererFraming.none
    var layerFrame: (columns: Int, rows: Int, layer: AgentSpriteLayer)?
    let framed = try render(shot, withSprites: true) { layerFrame = $0.lastSpriteFrame }
    let unframed = try render(open, withSprites: true)
    #expect(framed != unframed)

    let frame = try #require(layerFrame)
    let horizonRow = IdleScreenSceneFramingMask.horizonRow(
      viewport: .full, columns: frame.columns, rows: frame.rows)
    let horizonY = Int(Float(horizonRow) / Float(frame.rows) * Float(Self.height))

    // Sprite feet stand on the horizon: the lowest sprite pixel is at it.
    let feet = frame.layer.quads.map(\.edges.w).max() ?? 0
    #expect(abs(Int(feet * 2) - horizonY) <= 1, "feet \(feet * 2) vs horizon \(horizonY)")

    // The accent line spans the frame on the horizon row.
    let accent = SIMD3<Float>(0.231, 0.424, 0.941)
    let background = SIMD3<Float>(0.016, 0.02, 0.035)
    let expected = (background + (accent - background) * 1.0).rgbBytes
    var lineRows = 0
    for y in horizonY..<min(Self.height, horizonY + 2) {
      var matches = 0
      for x in 0..<Self.width {
        let i = (y * Self.width + x) * 4
        let actual = [framed[i + 2], framed[i + 1], framed[i]]
        if zip(actual, expected).allSatisfy({ abs(Int($0) - Int($1)) <= 1 }) { matches += 1 }
      }
      if matches > Self.width * 8 / 10 { lineRows += 1 }
    }
    #expect(lineRows >= 1, "no accent line on the horizon row")

    // Quiet sky, busier ground.
    func lit(_ bytes: [UInt8], rows: Range<Int>) -> Int {
      var total = 0
      for y in rows {
        for x in stride(from: 0, to: Self.width, by: 2) {
          let i = (y * Self.width + x) * 4
          // Count only what rises above the Cobalt background (4, 5, 9).
          total +=
            max(0, Int(bytes[i]) - 4) + max(0, Int(bytes[i + 1]) - 5)
            + max(0, Int(bytes[i + 2]) - 9)
        }
      }
      return total
    }
    let skyRows = 0..<horizonY
    let groundRows = (horizonY + 4)..<Self.height
    let bare = try render(shot, withSprites: false)
    let skyPerRow = Double(lit(bare, rows: skyRows)) / Double(skyRows.count)
    let groundPerRow = Double(lit(bare, rows: groundRows)) / Double(groundRows.count)
    #expect(skyPerRow * 3 < groundPerRow, "sky \(skyPerRow) ground \(groundPerRow)")
  }

  @MainActor
  @Test("writes sprite captures when IDLESCREEN_SPRITE_CAPTURE_DIR is set")
  func writeCaptures() throws {
    guard
      let directory = ProcessInfo.processInfo.environment["IDLESCREEN_SPRITE_CAPTURE_DIR"]
    else { return }
    let outputURL = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    let shots = [
      Shot(
        name: "claude-walk-0", pattern: "topograph", palette: "Cobalt",
        sprites: [(.claude, .working, 4.1, false)], framing: .horizon),
      Shot(
        name: "claude-walk-1", pattern: "topograph", palette: "Cobalt",
        sprites: [(.claude, .working, 4.3, false)], framing: .horizon),
      Shot(
        name: "attention-warp-phosphor", pattern: "warp", palette: "Phosphor",
        sprites: Self.attention),
      Shot(
        name: "attention-codex-plasma", pattern: "plasma", palette: "Ember",
        sprites: [(.codex, .needsAttention, 30, false)]),
      Shot(
        name: "working-pixel-materials", pattern: "pixelMaterials", palette: "Ember",
        sprites: [(.claude, .working, 6, false)], frames: 120, glyphScale: 0.9),
      Shot(
        name: "two-agents-working-and-attention", pattern: "matrixRain", palette: "Phosphor",
        sprites: [(.claude, .working, 9, false), (.codex, .needsAttention, 30, false)]),
      Shot(
        name: "two-agents-done-and-error", pattern: "aurora", palette: "Ember",
        sprites: [(.claude, .done, 8, false), (.codex, .error, 8, false)]),
      Shot(
        name: "camera-synthetic-attention", pattern: "warp", palette: "Phosphor",
        sprites: Self.attention, camera: true),
      Shot(
        name: "reduce-motion-done-and-error", pattern: "plasma", palette: "Blueprint",
        sprites: [(.claude, .done, 5, true), (.codex, .error, 5, true)]),
    ]
    for shot in shots {
      let bytes = try render(shot, withSprites: true)
      try write(bytes, to: outputURL.appendingPathComponent("\(shot.name).png"))
    }
  }

  private func write(_ source: [UInt8], to url: URL) throws {
    var bytes = source
    for index in stride(from: 0, to: bytes.count, by: 4) {
      bytes.swapAt(index, index + 2)
      bytes[index + 3] = 255
    }
    let image = try #require(
      bytes.withUnsafeMutableBytes { buffer in
        CGContext(
          data: buffer.baseAddress, width: Self.width, height: Self.height,
          bitsPerComponent: 8, bytesPerRow: Self.width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )?.makeImage()
      })
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }
}

extension SIMD3 where Scalar == Float {
  fileprivate var rgbBytes: [UInt8] {
    [x, y, z].map { UInt8(Swift.min(255, Swift.max(0, $0 * 255)).rounded()) }
  }
}

extension SIMD4 where Scalar == Float {
  fileprivate var rgbBytes: [UInt8] { SIMD3(x, y, z).rgbBytes }
}
