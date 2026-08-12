import IdleScreenCore
import SwiftUI

struct AgentSignalOverlayView: View {
    let presentation: IdleScreenAgentOverlayPresentation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let providerLabel = presentation.providerLabel {
                    Text(providerLabel.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                }
                Text(presentation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let message = presentation.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(tint.opacity(0.42), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var tint: Color {
        switch presentation.style {
        case .subtle: .secondary
        case .active: .cyan
        case .attention: .orange
        case .success: .green
        case .failure: .red
        case .hidden: .clear
        }
    }

    private var symbol: String {
        switch presentation.state {
        case .working: "sparkles"
        case .needsAttention: "bell.badge.fill"
        case .done: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .idle: "moon.zzz"
        }
    }
}

extension IdleScreenAgentOverlayPosition {
    var swiftUIAlignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}
