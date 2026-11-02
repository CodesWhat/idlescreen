import AppKit
import SwiftUI

// Shared components for the companion app's settings pages. Page code reuses these instead of inventing its own:
//
//   DesignPage          scrolling page body: headline and one summary line over stacked sections
//   DesignPageHeader    the headline, a summary line and optional trailing status
//   DesignSection       eyebrow label over a card, with an optional footer note
//   DesignEyebrow       `── LABEL ────` SF Mono 10 uppercase with a trailing rule, marked as a heading
//   DesignCard          surface, 1 pt hair border, radius 3, corner ticks, no shadow; dashed rule between its rows
//   DesignGround        the page ground: bg with a faint dot grid
//   DesignRow           48 pt minimum row: title and detail left, controls right, wraps instead of truncating
//   DesignDetails       a collapsed "Details" section for diagnostics and raw values
//   DesignStatus        a glyph chip (● OK, ▲ WARN, ✕ FAIL, ○ OFF): glyph plus word, never colour alone
//   DesignNotice        an inline warning or error banner
//   DesignSwitchStyle   42x24 switch: `.toggleStyle(.designSwitch)`
//   DesignPopup         28 pt popup, radius 7, with a checkmarked menu
//   DesignSegmented     segmented control on a sel tint with a surface selected pill
//   DesignButtonStyle   primary (accent) and secondary (surface + hair border): `.buttonStyle(.designPrimary)`
//
// Colours come from DesignPalette, type from DesignFont. Text wraps or grows the container, never truncates. Every control takes
// an explicit accessibility title. Surfaces are opaque, so there is nothing to swap under Reduce Transparency, and motion is
// skipped under Reduce Motion.

// MARK: Layout

/// A horizontal dashed rule, the ASCII `- - -` between card rows.
private struct DashedRule: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    return path
  }
}

/// Dashed hairline between card rows.
struct DesignHairline: View {
  var body: some View {
    DashedRule().stroke(DesignPalette.hair2, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
      .frame(height: 1)
  }
}

/// L-shaped ticks at the four corners of a rect, drawn just outside it like registration marks on a drawing.
private struct CornerTicks: Shape {
  var length: CGFloat
  func path(in rect: CGRect) -> Path {
    var path = Path()
    for (x, dx) in [(rect.minX, length), (rect.maxX, -length)] {
      for (y, dy) in [(rect.minY, length), (rect.maxY, -length)] {
        path.move(to: CGPoint(x: x + dx, y: y))
        path.addLine(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x, y: y + dy))
      }
    }
    return path
  }
}

/// The page ground: `bg` with a dot every 16 pt. Decorative and hidden from accessibility; Increase Contrast drops the dots.
struct DesignGround: View {
  var body: some View {
    ZStack {
      DesignPalette.bg
      Canvas { context, size in
        let pitch = DesignMetrics.gridPitch
        let dot = DesignPalette.grid
        var path = Path()
        var y = pitch / 2
        while y < size.height {
          var x = pitch / 2
          while x < size.width {
            path.addRect(CGRect(x: x - 0.5, y: y - 0.5, width: 1.5, height: 1.5))
            x += pitch
          }
          y += pitch
        }
        context.fill(path, with: .color(dot))
      }
    }
    .accessibilityHidden(true)
  }
}

struct DesignCard<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    Group(subviews: content()) { rows in
      VStack(spacing: 0) {
        ForEach(rows.indices, id: \.self) { index in
          if index > 0 { DesignHairline() }
          rows[index]
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .designCardChrome()
  }
}

extension View {
  /// The blueprint card surface: opaque fill, 1 pt hair border, near-square corners, corner ticks, no shadow.
  func designCardChrome() -> some View {
    let shape = RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous)
    return
      self
      .clipShape(shape)
      .background(shape.fill(DesignPalette.surface))
      .overlay(shape.strokeBorder(DesignPalette.hair, lineWidth: 1))
      .overlay(
        CornerTicks(length: DesignMetrics.tickLength)
          .stroke(DesignPalette.ink3, style: StrokeStyle(lineWidth: 1.5, lineCap: .square))
          .padding(-3).allowsHitTesting(false).accessibilityHidden(true))
  }
}

struct DesignEyebrow: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    HStack(spacing: 6) {
      Text("──").font(DesignFont.mono(DesignFont.eyebrow)).foregroundStyle(DesignPalette.accentMark)
        .accessibilityHidden(true)
      Text(text).designEyebrow().fixedSize(horizontal: false, vertical: true)
      Rectangle().fill(DesignPalette.hair2).frame(height: 1).accessibilityHidden(true)
    }
    .padding(.leading, 2)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// An eyebrow over a card of rows, with an optional footer note.
struct DesignSection<Content: View>: View {
  let eyebrow: String
  var footer: String?
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      DesignEyebrow(eyebrow)
      DesignCard(content: content)
      if let footer {
        Text(footer).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
          .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
      }
    }
  }
}

/// One row of a card. Controls sit on the right; when they don't fit beside the label they wrap below it.
struct DesignRow<Controls: View>: View {
  let title: String
  var detail: String?
  @ViewBuilder var controls: () -> Controls

  private var label: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title).font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
        .fixedSize(horizontal: false, vertical: true)
      if let detail, !detail.isEmpty {
        Text(detail).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var trailing: some View { HStack(spacing: 8) { controls() } }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 16) {
        label.frame(minWidth: 180, idealWidth: 180, maxWidth: .infinity, alignment: .leading)
        trailing.layoutPriority(1)
      }
      VStack(alignment: .leading, spacing: 8) {
        label.frame(maxWidth: .infinity, alignment: .leading)
        trailing
      }
    }
    .padding(.horizontal, DesignMetrics.rowHorizontalPadding)
    .padding(.vertical, DesignMetrics.rowVerticalPadding)
    .frame(minHeight: DesignMetrics.rowMinHeight)
  }
}

struct DesignPageHeader<Trailing: View>: View {
  let title: String
  var summary: String?
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(DesignFont.headlineFont()).foregroundStyle(DesignPalette.ink)
          .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
        Rectangle().fill(DesignPalette.accentMark).frame(width: 28, height: 3)
          .padding(.vertical, 2).accessibilityHidden(true)
        if let summary {
          Text(summary).font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
      trailing()
    }
  }
}

/// A scrolling page: header, then sections 18 pt apart.
struct DesignPage<Trailing: View, Content: View>: View {
  let title: String
  var summary: String?
  @ViewBuilder var trailing: () -> Trailing
  @ViewBuilder var content: () -> Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignMetrics.sectionSpacing) {
        DesignPageHeader(title: title, summary: summary, trailing: trailing)
        content()
      }
      .padding(.horizontal, DesignMetrics.pageSideMargin)
      .padding(.top, DesignMetrics.pageTopMargin)
      .padding(.bottom, DesignMetrics.pageBottomMargin)
      .frame(maxWidth: DesignMetrics.pageMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .background(DesignGround())
  }
}

extension DesignPage where Trailing == EmptyView {
  init(title: String, summary: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.init(title: title, summary: summary, trailing: { EmptyView() }, content: content)
  }
}

/// A collapsed section for diagnostics and raw values. The header is a heading and a button; its value says whether it is open.
struct DesignDetails<Content: View>: View {
  let title: String
  @ViewBuilder var content: () -> Content
  @State private var expanded: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    title: String = "Details", initiallyExpanded: Bool = false,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.content = content
    _expanded = State(initialValue: initiallyExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { expanded.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(DesignPalette.ink3)
            .frame(width: 12).accessibilityHidden(true)
          Text(title).designEyebrow()
        }
        .padding(.leading, 4).frame(minHeight: 20).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title).accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityAddTraits(.isHeader)
      if expanded { DesignCard(content: content) }
    }
  }
}

// MARK: Status

/// What a status means, which sets its symbol and colour. The word always travels with the symbol.
enum DesignStatusKind {
  case ok, attention, error, pending, neutral, current

  var symbol: String {
    switch self {
    case .ok: "checkmark.circle.fill"
    case .attention: "exclamationmark.triangle.fill"
    case .error: "xmark.octagon.fill"
    case .pending: "ellipsis.circle.fill"
    case .neutral: "minus.circle.fill"
    case .current: "arrow.right.circle.fill"
    }
  }

  /// The chip glyph, plain Unicode so it reads in SF Mono: ● ▲ ✕ ○ ▸.
  var glyph: String {
    switch self {
    case .ok: "●"
    case .attention: "▲"
    case .error: "✕"
    case .pending, .neutral: "○"
    case .current: "▸"
    }
  }

  var color: Color {
    switch self {
    case .ok: DesignPalette.success
    case .attention: DesignPalette.warning
    case .error: DesignPalette.danger
    case .pending, .neutral: DesignPalette.ink3
    case .current: DesignPalette.accentMark
    }
  }
}

/// A status as a glyph chip: glyph plus word in SF Mono, `● READY`. The word is in the primary ink so it holds contrast; the
/// glyph and the chip edge carry the hue.
struct DesignStatus: View {
  let kind: DesignStatusKind
  let text: String

  var body: some View {
    HStack(spacing: 6) {
      Text(kind.glyph).font(DesignFont.mono(DesignFont.eyebrow + 1, .semibold))
        .foregroundStyle(kind.color).accessibilityHidden(true)
      Text(text).font(DesignFont.mono(DesignFont.eyebrow + 1, .semibold)).textCase(.uppercase)
        .tracking(0.6).foregroundStyle(DesignPalette.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 7).padding(.vertical, 3)
    .overlay(
      RoundedRectangle(cornerRadius: DesignMetrics.controlRadius)
        .strokeBorder(kind.color.opacity(0.7), lineWidth: 1)
    )
    .accessibilityElement(children: .ignore).accessibilityLabel(text)
  }
}

/// A status chip for page headers.
struct DesignStatusPill: View {
  let kind: DesignStatusKind
  let text: String

  var body: some View {
    DesignStatus(kind: kind, text: text)
  }
}

/// An inline banner for an error or warning that has no row to live in.
struct DesignNotice: View {
  let kind: DesignStatusKind
  let text: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(kind.glyph).font(DesignFont.mono(DesignFont.detail, .semibold)).foregroundStyle(
        kind.color
      )
      .accessibilityHidden(true)
      Text(text).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous).fill(
        DesignPalette.surface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous)
        .strokeBorder(kind.color, lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
  }
}

/// A right-aligned readout, the value half of a key/value row: SF Mono, selectable, wrapping.
struct DesignValueText: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text).font(DesignFont.mono(DesignFont.detail)).foregroundStyle(DesignPalette.ink)
      .multilineTextAlignment(.trailing).textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: Controls

/// 42x24 square-cornered switch. A button underneath, so Space toggles it under Full Keyboard Access; VoiceOver sees a native toggle.
struct DesignSwitchStyle: ToggleStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let width: CGFloat = 42
    let height: CGFloat = 24
    let knob = height - 4
    Button {
      configuration.isOn.toggle()
    } label: {
      ZStack(alignment: configuration.isOn ? .trailing : .leading) {
        if configuration.isOn {
          RoundedRectangle(cornerRadius: DesignMetrics.controlRadius).fill(DesignPalette.accentMark)
          RoundedRectangle(cornerRadius: 1).fill(DesignPalette.accent).padding(1)
        } else {
          RoundedRectangle(cornerRadius: DesignMetrics.controlRadius).fill(DesignPalette.track)
          RoundedRectangle(cornerRadius: DesignMetrics.controlRadius)
            .strokeBorder(DesignPalette.hair, lineWidth: 1)
        }
        RoundedRectangle(cornerRadius: 1).fill(
          configuration.isOn ? DesignPalette.onAccent : DesignPalette.ink2
        )
        .frame(width: knob - 2, height: knob).padding(2)
      }
      .frame(width: width, height: height)
      .opacity(isEnabled ? 1 : 0.45)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isOn)
    }
    .buttonStyle(.plain)
    .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
  }
}

extension ToggleStyle where Self == DesignSwitchStyle {
  static var designSwitch: DesignSwitchStyle { DesignSwitchStyle() }
}

/// One choice for `DesignPopup` and `DesignSegmented`.
struct DesignChoice<Value: Hashable>: Identifiable {
  let label: String
  let value: Value
  var id: String { label }
  init(_ label: String, _ value: Value) {
    self.label = label
    self.value = value
  }
}

/// 28 pt popup, radius 7. `title` is the accessibility label; the current choice is its value.
struct DesignPopup<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let choices: [DesignChoice<Value>]

  private var current: String { choices.first { $0.value == selection }?.label ?? "" }

  var body: some View {
    Menu {
      Picker(title, selection: $selection) {
        ForEach(choices) { Text($0.label).tag($0.value) }
      }
      .pickerStyle(.inline).labelsHidden().accessibilityLabel(title)
    } label: {
      HStack(spacing: 8) {
        Text(current).font(DesignFont.mono(DesignFont.detail)).foregroundStyle(DesignPalette.ink)
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(DesignPalette.ink2).accessibilityHidden(true)
      }
      .padding(.leading, 10).padding(.trailing, 8).frame(minHeight: DesignMetrics.controlHeight)
      .background(
        RoundedRectangle(cornerRadius: DesignMetrics.controlRadius).fill(DesignPalette.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignMetrics.controlRadius).strokeBorder(
          DesignPalette.hair, lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: DesignMetrics.controlRadius))
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .accessibilityLabel(title).accessibilityValue(current)
  }
}

/// Segmented control on the sel tint with a surface selected pill. Left and right arrows move the selection when a segment has focus.
struct DesignSegmented<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let choices: [DesignChoice<Value>]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(choices) { choice in
        let selected = choice.value == selection
        Button {
          selection = choice.value
        } label: {
          Text(choice.label).font(
            DesignFont.mono(DesignFont.detail - 0.5, selected ? .semibold : .regular)
          )
          .foregroundStyle(selected ? DesignPalette.ink : DesignPalette.ink2).fixedSize()
          .padding(.horizontal, 12).frame(minHeight: 24)
          .background {
            if selected {
              RoundedRectangle(cornerRadius: DesignMetrics.segmentRadius).fill(
                DesignPalette.surface
              )
              .overlay(
                RoundedRectangle(cornerRadius: DesignMetrics.segmentRadius)
                  .strokeBorder(DesignPalette.hair, lineWidth: 1))
            }
          }
          .contentShape(RoundedRectangle(cornerRadius: DesignMetrics.segmentRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.label).accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(2)
    .background(RoundedRectangle(cornerRadius: DesignMetrics.cardRadius).fill(DesignPalette.sel))
    .onKeyPress(.leftArrow) { step(-1) }
    .onKeyPress(.rightArrow) { step(1) }
    .accessibilityElement(children: .contain).accessibilityLabel(title)
  }

  private func step(_ offset: Int) -> KeyPress.Result {
    guard let index = choices.firstIndex(where: { $0.value == selection }) else { return .ignored }
    let next = min(max(index + offset, 0), choices.count - 1)
    selection = choices[next].value
    return .handled
  }
}

/// Primary (accent fill) and secondary (surface with a hair border) buttons, 28 pt high, radius 7. Destructive tints the label.
struct DesignButtonStyle: ButtonStyle {
  enum Kind { case primary, secondary, destructive }
  var kind: Kind = .secondary
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: DesignMetrics.controlRadius)
    configuration.label
      .font(DesignFont.mono(DesignFont.detail - 0.5, .semibold))
      .foregroundStyle(
        kind == .primary
          ? DesignPalette.onAccent : kind == .destructive ? DesignPalette.danger : DesignPalette.ink
      )
      .padding(.horizontal, 10).frame(minHeight: DesignMetrics.controlHeight)
      .background(shape.fill(kind == .primary ? DesignPalette.accent : DesignPalette.surface))
      .overlay {
        shape.strokeBorder(
          kind == .primary ? DesignPalette.accentMark : DesignPalette.hair, lineWidth: 1)
      }
      .overlay { if configuration.isPressed { shape.fill(Color.black.opacity(0.1)) } }
      .contentShape(shape)
      .opacity(isEnabled ? 1 : 0.45)
  }
}

extension ButtonStyle where Self == DesignButtonStyle {
  static var designPrimary: DesignButtonStyle { DesignButtonStyle(kind: .primary) }
  static var designSecondary: DesignButtonStyle { DesignButtonStyle(kind: .secondary) }
  static var designDestructive: DesignButtonStyle { DesignButtonStyle(kind: .destructive) }
}
