import CoreText
import Metal
import Testing

@testable import IdleScreenRenderer

@Suite("Glyph tone curve and atlas face")
struct GlyphToneTests {
  @Test("fragment tone lifts mid-tones, keeps a floor, and keeps zero dark")
  func toneCurve() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    func render(brightness: Float) throws -> SIMD4<Float> {
      try renderCell(device: device, brightness: brightness)
    }

    let dark = try render(brightness: 0)
    #expect(dark.x < 0.01 && dark.w < 0.01)

    // gamma 0.7 with colour floor 0.22 and alpha floor 0.35.
    let low = try render(brightness: 0.1)
    let lum = powf(0.1, 0.7)
    #expect(abs(low.x - (0.22 + 0.78 * lum)) < 0.01)
    #expect(abs(low.w - (0.35 + 0.65 * lum)) < 0.01)
    #expect(low.w >= 0.35)

    let mid = try render(brightness: 0.5)
    #expect(mid.w > 0.7)
    #expect(mid.x > 0.65)

    let full = try render(brightness: 1)
    #expect(full.x > 0.99 && full.w > 0.99)
  }

  @Test("Departure Mono is bundled in the renderer framework and loads")
  func departureMonoLoads() throws {
    let face = IdleScreenGlyphFace.resolve()
    #expect(face.isDepartureMono)
    #expect(face.ramp == Array(" .,:;+*#%@"))
    #expect(!face.ramp.contains("-"))
    #expect(!face.ramp.contains("="))
    let font = CTFontCreateWithFontDescriptor(face.descriptor, 24, nil)
    let name = CTFontCopyFullName(font) as String
    #expect(name.contains("Departure"))
  }

  @Test("a missing font falls back to Menlo with the legacy ramp")
  func menloFallback() {
    // The test bundle does not carry the font.
    let face = IdleScreenGlyphFace.resolve(
      bundle: Bundle(for: BundleAnchor.self)
    )
    #expect(!face.isDepartureMono)
    #expect(face.ramp == Array(" .:-=+*#%@"))
  }

  private final class BundleAnchor {}

  private func renderCell(
    device: any MTLDevice,
    brightness: Float
  ) throws -> SIMD4<Float> {
    let library = try device.makeDefaultLibrary(
      bundle: Bundle(for: IdleScreenRenderer.self)
    )
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(
      name: "idleScreenCharacterVertex"
    )
    descriptor.fragmentFunction = library.makeFunction(
      name: "idleScreenCharacterFragment"
    )
    descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

    let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
    )
    atlasDescriptor.usage = .shaderRead
    let atlas = try #require(device.makeTexture(descriptor: atlasDescriptor))
    var white: [UInt8] = [255, 255, 255, 255]
    atlas.replace(
      region: MTLRegionMake2D(0, 0, 1, 1),
      mipmapLevel: 0,
      withBytes: &white,
      bytesPerRow: 4
    )

    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false
    )
    targetDescriptor.usage = [.renderTarget, .shaderRead]
    targetDescriptor.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: targetDescriptor))
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: 0, green: 0, blue: 0, alpha: 0
    )
    pass.colorAttachments[0].storeAction = .store

    var geometry = SIMD4<Float>(1, 1, 1, 1)
    var instance = [SIMD4<Float>(0, 0, brightness, 0), SIMD4<Float>(1, 1, 1, 1)]
    var glyphRect = SIMD4<Float>(0, 0, 1, 1)
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())
    let encoder = try #require(
      commandBuffer.makeRenderCommandEncoder(descriptor: pass)
    )
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(&geometry, length: 16, index: 0)
    encoder.setVertexBytes(&instance, length: 32, index: 1)
    encoder.setVertexBytes(&glyphRect, length: 16, index: 2)
    encoder.setFragmentTexture(atlas, index: 0)
    encoder.drawPrimitives(
      type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1
    )
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)

    var pixel = [UInt8](repeating: 0, count: 4)
    target.getBytes(
      &pixel,
      bytesPerRow: 16,
      from: MTLRegionMake2D(1, 1, 1, 1),
      mipmapLevel: 0
    )
    return SIMD4<Float>(
      Float(pixel[0]) / 255,
      Float(pixel[1]) / 255,
      Float(pixel[2]) / 255,
      Float(pixel[3]) / 255
    )
  }
}
