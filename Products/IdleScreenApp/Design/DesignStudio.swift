import IdleScreenCore
import SwiftUI

// Shared controls for the scene inspector and camera setup guidance.

extension DesignFont {
  /// Panel and card titles inside Studio.
  static let panelTitle: CGFloat = 13
}

private struct StudioPanelModifier: ViewModifier {
  let radius: CGFloat
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content
      .background {
        if reduceTransparency {
          shape.fill(DesignPalette.surface)
        } else {
          shape.fill(.regularMaterial)
        }
      }
      .overlay { shape.strokeBorder(DesignPalette.hair, lineWidth: 1) }
  }
}

extension View {
  /// A floating Studio panel: a material over the preview, the opaque surface when Reduce Transparency is on, a hairline edge.
  func studioPanel(radius: CGFloat = 14) -> some View {
    modifier(StudioPanelModifier(radius: radius))
  }
}

/// A vertical hairline between items in the compact dock.
struct StudioDivider: View {
  var body: some View {
    Rectangle().fill(DesignPalette.hair).frame(width: 1, height: 22).accessibilityHidden(true)
  }
}

/// An eyebrow over a tinted inset group of controls.
struct StudioSection<Content: View>: View {
  let title: String
  var minHeight: CGFloat = 0
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).designEyebrow().accessibilityAddTraits(.isHeader)
      content()
    }
    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
    .padding(.bottom, 12)
    .overlay(alignment: .bottom) { DesignHairline() }
  }
}

/// A button styled as an eyebrow that opens more controls. It is a heading and a button; its value says whether it is open.
struct StudioDisclosure<Content: View>: View {
  let title: String
  @Binding var isExpanded: Bool
  @ViewBuilder var content: () -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isExpanded.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(DesignPalette.ink3)
            .frame(width: 12).accessibilityHidden(true)
          Text(title).designEyebrow()
        }
        .frame(minHeight: 20).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title).accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityAddTraits(.isHeader)
      if isExpanded { content() }
    }
  }
}

/// A title on the left and one control on the right. The control carries the accessibility label, so the visible title is hidden
/// from VoiceOver rather than read twice.
struct StudioField<Control: View>: View {
  let title: String
  @ViewBuilder var control: () -> Control

  var body: some View {
    HStack(spacing: 8) {
      Text(title).font(DesignFont.sans(DesignFont.caption, .medium)).foregroundStyle(
        DesignPalette.ink
      )
      .fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
      Spacer(minLength: 8)
      control()
    }
  }
}

/// The one Studio slider. `inline` is the compact dock's title-slider-value row; `stacked` is the expanded panels' title and value
/// over a full-width slider. Both label the slider with its visible title and read the value text as its value.
struct StudioSlider: View {
  enum Layout {
    case inline(width: CGFloat)
    case stacked
  }

  let title: String
  @Binding var value: Double
  var range: ClosedRange<Double> = 0...1
  var valueText: String?
  var step: Double?
  var layout: Layout = .stacked
  var hint: String?

  var body: some View {
    switch layout {
    case .inline(let width):
      HStack(spacing: 6) {
        Text(title).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
          .fixedSize().accessibilityHidden(true)
        slider.controlSize(.mini).frame(width: width)
        if let valueText {
          readout(valueText).fixedSize()
        }
      }
    case .stacked:
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(title).font(DesignFont.sans(DesignFont.caption, .medium))
            .foregroundStyle(DesignPalette.ink)
          Spacer()
          if let valueText { readout(valueText) }
        }
        .accessibilityHidden(true)
        slider.controlSize(.small)
      }
      .frame(maxWidth: .infinity)
    }
  }

  private func readout(_ text: String) -> some View {
    Text(text).font(DesignFont.sans(DesignFont.caption)).monospacedDigit()
      .foregroundStyle(DesignPalette.ink2)
  }

  private var slider: some View {
    Group {
      if let step {
        Slider(value: $value, in: range, step: step) { Text(title) }
      } else {
        Slider(value: $value, in: range) { Text(title) }
      }
    }
    .labelsHidden()
    .tint(DesignPalette.accent)
    .accessibilityLabel(title)
    .accessibilityValue(valueText ?? value.formatted(.number.precision(.fractionLength(2))))
    .accessibilityHint(hint ?? "")
  }
}

/// What a saver chooser tile shows. Every pattern is a real render from IdleScreen's own renderer, checked in as the
/// `SaverThumbnails` asset catalog (see `design/thumbnails/README.md`), so the chooser carries the product's own look and
/// no colour of its own. The camera is a neutral tile with its symbol in cobalt, because there is nothing to render.
enum SaverTileArt: Equatable {
  case camera
  case pattern(IdleScreenCreativePattern)

  /// Auto Cycle rotates through the styles, so its tile is four of them.
  static let mosaicPatterns: [IdleScreenCreativePattern] = [.metaballs, .pulse, .warp, .perlin]

  static func assetName(_ pattern: IdleScreenCreativePattern) -> String {
    "SaverThumbnails/\(pattern.rawValue)"
  }
}

/// Resolves the bundle that holds the asset catalog: the app, or the test bundle that compiles this file for renders.
private final class SaverTileBundleMarker {}

struct SaverTile: View {
  let art: SaverTileArt
  let cornerRadius: CGFloat

  var body: some View {
    ZStack {
      switch art {
      case .camera:
        DesignPalette.previewGround
        Image(systemName: "camera.fill")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(DesignPalette.accentMark)
      case .pattern(.autoCycle):
        mosaic
      case .pattern(let pattern):
        thumbnail(pattern)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(DesignPalette.hair2, lineWidth: 1)
    )
    .accessibilityHidden(true)
  }

  private var mosaic: some View {
    let patterns = SaverTileArt.mosaicPatterns
    return VStack(spacing: 1) {
      HStack(spacing: 1) {
        thumbnail(patterns[0])
        thumbnail(patterns[1])
      }
      HStack(spacing: 1) {
        thumbnail(patterns[2])
        thumbnail(patterns[3])
      }
    }
    .background(DesignPalette.previewGround)
  }

  private func thumbnail(_ pattern: IdleScreenCreativePattern) -> some View {
    Color.clear
      .overlay(
        Image(SaverTileArt.assetName(pattern), bundle: Bundle(for: SaverTileBundleMarker.self))
          .resizable()
          .interpolation(.high)
          .scaledToFill()
      )
      .clipped()
  }
}
