import SwiftUI

extension EnvironmentValues {
  @Entry var workbenchInspector = false
}

struct WorkbenchSplit<Main: View, Inspector: View>: View {
  var showsInspector = true
  @ViewBuilder var main: () -> Main
  @ViewBuilder var inspector: () -> Inspector

  var body: some View {
    HStack(spacing: 0) {
      main().frame(maxWidth: .infinity, maxHeight: .infinity)
      if showsInspector {
        Divider()
        inspector()
          .frame(width: 264)
          .frame(maxHeight: .infinity, alignment: .top)
          .background(DesignPalette.surface)
          .environment(\.workbenchInspector, true)
      }
    }
    .background(DesignPalette.bg)
  }
}

struct WorkbenchHeader<Trailing: View>: View {
  let title: String
  var summary: String?
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    DesignPageHeader(title: title, summary: summary, trailing: trailing)
      .padding(.horizontal, 28)
      .padding(.vertical, 18)
      .background(DesignPalette.surface)
      .overlay(alignment: .bottom) { DesignHairline() }
  }
}

struct WorkbenchInspector<Content: View>: View {
  let eyebrow: String
  let title: String
  var summary: String?
  @ViewBuilder var content: () -> Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 8) {
          Text(eyebrow).designEyebrow()
          Text(title).font(DesignFont.sans(18, .semibold)).foregroundStyle(DesignPalette.ink)
            .accessibilityAddTraits(.isHeader)
          if let summary {
            Text(summary).font(DesignFont.sans(DesignFont.caption))
              .foregroundStyle(DesignPalette.ink2)
          }
        }
        content()
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
