import SwiftUI

/// The Status page drawn from a `StatusSummary`, so it renders without a model. The raw rows go in `technical`, collapsed under
/// "Technical details".
struct StatusPageContent<Technical: View>: View {
  let summary: StatusSummary
  var lastError: String?
  var isRefreshing = false
  var showsInspector = true
  var detailsInitiallyExpanded = false
  var perform: (StatusAction) -> Void = { _ in }
  var refresh: () -> Void = {}
  @ViewBuilder var technical: () -> Technical

  var body: some View {
    WorkbenchSplit(showsInspector: showsInspector) {
      VStack(spacing: 0) {
        WorkbenchHeader(title: "Setup & settings", summary: "Keep IdleScreen connected to macOS.") {
          Button("Refresh", action: refresh)
            .buttonStyle(.designSecondary)
            .accessibilityHint("Checks IdleScreen again")
            .disabled(isRefreshing)
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            if summary.isDevelopmentBuild {
              DesignNotice(kind: .attention, text: StatusSummary.developmentBuildNotice)
            }
            if let lastError, !lastError.isEmpty {
              DesignNotice(kind: .attention, text: lastError)
            }
            verdict
            cardSection(summary.saver)
            cardSection(summary.camera)
            DesignDetails(title: "Technical details", initiallyExpanded: detailsInitiallyExpanded) {
              technical()
            }
          }
          .padding(28)
        }
      }
    } inspector: {
      WorkbenchInspector(
        eyebrow: "IdleScreen", title: "Connections", summary: "Screen saver, camera and agents."
      ) {
        agentsSection
      }
    }
  }

  // MARK: Verdict

  private var verdict: some View {
    HStack(spacing: 12) {
      Image(systemName: verdictKind.symbol).font(.system(size: 22, weight: .semibold))
        .foregroundStyle(verdictKind.color).accessibilityHidden(true)
      Text(summary.verdict).font(DesignFont.display(22)).foregroundStyle(DesignPalette.ink)
        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
      if let action = summary.primaryAction {
        Button(action.title) { perform(action) }
          .buttonStyle(.designPrimary)
          .accessibilityHint("Fixes the first thing that needs your attention")
      }
    }
    .padding(.horizontal, 18).padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous).fill(
        DesignPalette.surface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous)
        .strokeBorder(DesignPalette.hair2, lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
  }

  private var verdictKind: DesignStatusKind {
    if !summary.problems.isEmpty { return .attention }
    return summary.isChecking ? .pending : .ok
  }

  // MARK: Cards

  private func cardSection(_ card: StatusCard) -> some View {
    DesignSection(eyebrow: card.title) {
      DesignRow(title: card.sentence) {
        DesignStatus(kind: card.kind, text: card.word)
        if let action = card.action {
          Button(action.title) { perform(action) }
            .buttonStyle(.designSecondary)
            .accessibilityLabel("\(action.title), \(card.title)")
        }
      }
    }
  }

  private var agentsSection: some View {
    DesignSection(eyebrow: "Agent signals") {
      DesignRow(title: summary.agentsSentence) {
        Button(summary.agentsAction.title) { perform(summary.agentsAction) }
          .buttonStyle(.designSecondary)
          .accessibilityLabel("\(summary.agentsAction.title), Agent signals")
      }
      ForEach(summary.agents, id: \.name) { agent in
        DesignRow(title: agent.name) {
          DesignStatus(kind: agent.state.kind, text: agent.state.word)
        }
      }
    }
  }
}
