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
  private func render(_ shot: Shot, withSprites: Bool) throws -> [UInt8] {
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
  @Test("an empty sprite list renders bit-identically")
  func emptyIsIdentical() throws {
    let shot = Shot(name: "empty", pattern: "plasma", palette: "Ember", sprites: [])
    #expect(try render(shot, withSprites: false) == render(shot, withSprites: true))
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
