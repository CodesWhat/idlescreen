import AppKit
import IdleScreenCore
import Testing

@Suite("Saver tile art")
struct SaverTileArtTests {
  private final class BundleMarker {}

  @Test("every saver except Auto Cycle resolves its thumbnail asset")
  func everyPatternResolvesItsThumbnail() {
    let bundle = Bundle(for: BundleMarker.self)
    for pattern in IdleScreenCreativePattern.allCases where pattern != .autoCycle {
      let name = SaverTileArt.assetName(pattern)
      #expect(
        bundle.image(forResource: NSImage.Name(name)) != nil,
        "missing thumbnail asset \(name)")
    }
  }

  @Test("the Auto Cycle mosaic draws from savers that have thumbnails")
  func mosaicInputsResolve() {
    let bundle = Bundle(for: BundleMarker.self)
    for pattern in SaverTileArt.mosaicPatterns {
      #expect(pattern != .autoCycle)
      #expect(
        bundle.image(forResource: NSImage.Name(SaverTileArt.assetName(pattern))) != nil,
        "missing mosaic asset for \(pattern.rawValue)")
    }
  }
}
