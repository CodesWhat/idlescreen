import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import Testing
import UniformTypeIdentifiers

@testable import IdleScreenRenderer

/// Renders the marketing-site screenshots with the real Metal renderer, offscreen.
///
/// Gated by `IDLESCREEN_SITE_CAPTURE_DIR` (pass it through xcodebuild as
/// `TEST_RUNNER_IDLESCREEN_SITE_CAPTURE_DIR`). Without it the test is a no-op, so
/// normal test runs write nothing. Output is deterministic: per-shot configuration
/// listed below, fixed scene seed, fixed timestamps. See `website/README.md`.
@Suite("Site capture")
struct SiteCaptureTests {
  private static let width = 1_600
  private static let height = 1_000

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

  private struct Shot {
    let name: String
    let configuration: IdleScreenRendererConfiguration
    let frames: Int
  }

  @MainActor
  @Test("writes site captures when IDLESCREEN_SITE_CAPTURE_DIR is set")
  func writeSiteCaptures() throws {
    guard
      let directory = ProcessInfo.processInfo.environment[
        "IDLESCREEN_SITE_CAPTURE_DIR"]
    else { return }
    let outputURL = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(
      at: outputURL, withIntermediateDirectories: true)

    func configuration(
      _ pattern: String,
      palette: String,
      glyphScale: Double,
      intensity: Double = 0.5,
      materials: IdleScreenPixelMaterialsRendererSettings = .init()
    ) -> IdleScreenRendererConfiguration {
      var value = IdleScreenRendererConfiguration.default
      value.patternRawValue = pattern
      value.sceneSeed = 7
      value.palette = palette
      // Smaller glyphs than a preview and full contrast so the frames fill the card
      // and still read at ~360px wide.
      value.glyphScale = glyphScale
      value.contrast = 1
      value.proceduralSettings.intensity = intensity
      value.pixelMaterialsSettings = materials
      return value
    }

    // Pixel Materials: sand and water together on terraces, coarser cells (cellScale 2),
    // three wide emitters, captured mid-flow (frame 480 at 30 fps, 16 seconds in).
    let sandAndWater = IdleScreenPixelMaterialsRendererSettings(
      material: .mixed, terrainStyle: .terraces,
      emitterCount: 3, emitterWidth: 8, emitterRate: 8,
      cellScale: 2, paletteRawValue: "canyon")

    let shots = [
      Shot(
        name: "warp-phosphor",
        configuration: configuration("warp", palette: "Phosphor", glyphScale: 0.6, intensity: 1),
        frames: 1),
      Shot(
        name: "pixel-materials-sand-water",
        configuration: configuration(
          "pixelMaterials", palette: "Ember", glyphScale: 0.9, materials: sandAndWater),
        frames: 480),
      Shot(
        name: "pulse-blueprint",
        configuration: configuration("pulse", palette: "Blueprint", glyphScale: 0.6, intensity: 1),
        frames: 1),
    ]
    for shot in shots {
      try render(shot, to: outputURL.appendingPathComponent("\(shot.name).png"))
    }
  }

  @MainActor
  private func render(_ shot: Shot, to url: URL) throws {
    let view = MTKView(
      frame: .init(x: 0, y: 0, width: Self.width / 2, height: Self.height / 2))
    view.autoResizeDrawable = false
    view.drawableSize = .init(width: Self.width, height: Self.height)
    view.framebufferOnly = false
    let counter = CompletionCounter()
    let renderer = try IdleScreenRenderer(
      metalView: view,
      configuration: shot.configuration,
      mode: .generative,
      automaticallyDraws: false,
      pixelMaterialsCoordinator: .init(),
      performanceObserver: counter
    )
    defer { renderer.shutdown() }
    view.drawableSize = .init(width: Self.width, height: Self.height)
    #expect(Int(view.drawableSize.width) == Self.width)
    (view.layer as? CAMetalLayer)?.drawableSize = .init(width: Self.width, height: Self.height)

    var lastTexture: (any MTLTexture)?
    for index in 0..<shot.frames {
      let drawable = try #require(view.currentDrawable)
      lastTexture = drawable.texture
      #expect(
        drawable.texture.width == Self.width,
        "drawable \(drawable.texture.width)x\(drawable.texture.height)")
      let before = counter.count
      let time = shot.frames == 1 ? 20.0 : Double(index) / 30
      #expect(renderer.draw(at: time))
      let deadline = Date().addingTimeInterval(10)
      while counter.count == before, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.002)
      }
      #expect(counter.count > before)
    }
    try write(texture: try #require(lastTexture), to: url)
  }

  private func write(texture: any MTLTexture, to url: URL) throws {
    let width = texture.width
    let height = texture.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(
      &bytes, bytesPerRow: width * 4,
      from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    // BGRA to opaque RGBA so the PNG is independent of the drawable's alpha.
    for index in stride(from: 0, to: bytes.count, by: 4) {
      bytes.swapAt(index, index + 2)
      bytes[index + 3] = 255
    }
    let image = try #require(
      bytes.withUnsafeMutableBytes { buffer in
        CGContext(
          data: buffer.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )?.makeImage()
      })
    let destination = try #require(
      CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }
}
