import Foundation

public struct IdleScreenAgentDisplayContext: Equatable, Sendable {
    public let isPrimary: Bool
    public let isFocus: Bool

    public init(isPrimary: Bool, isFocus: Bool) {
        self.isPrimary = isPrimary
        self.isFocus = isFocus
    }
}

public struct IdleScreenAgentOverlayPresentation: Equatable, Sendable {
    public let provider: IdleScreenAgentProvider
    public let state: IdleScreenAgentSignalState
    public let providerLabel: String?
    public let title: String
    public let message: String?
    public let style: IdleScreenAgentVisualStyle
    public let position: IdleScreenAgentOverlayPosition
    public let accessibilityLabel: String
    public let expiresAt: Date

    public init(
        provider: IdleScreenAgentProvider,
        state: IdleScreenAgentSignalState,
        providerLabel: String?,
        title: String,
        message: String?,
        style: IdleScreenAgentVisualStyle,
        position: IdleScreenAgentOverlayPosition,
        accessibilityLabel: String,
        expiresAt: Date
    ) {
        self.provider = provider
        self.state = state
        self.providerLabel = providerLabel
        self.title = title
        self.message = message
        self.style = style
        self.position = position
        self.accessibilityLabel = accessibilityLabel
        self.expiresAt = expiresAt
    }
}

public enum IdleScreenAgentPresentationPolicy {
    public static func presentation(
        for signal: IdleScreenAgentSignal,
        configuration: IdleScreenAgentIntegrationConfiguration,
        at date: Date,
        minuteOfDay: Int
    ) -> IdleScreenAgentOverlayPresentation? {
        guard signal.expiresAt > date,
              signal.state != .idle,
              configuration.isEnabled(for: signal.provider),
              !(configuration.quietHours?.contains(minuteOfDay: minuteOfDay) ?? false) else {
            return nil
        }
        let style = configuration.stateVisuals.style(for: signal.state)
        guard style != .hidden else { return nil }
        let providerName = signal.provider == .codex ? "Codex" : "Claude"
        let title = signal.title ?? defaultTitle(
            providerName: providerName,
            state: signal.state
        )
        let providerLabel = configuration.showsProviderLabel ? providerName : nil
        let message = configuration.showsMessage ? signal.message : nil
        let accessibilityLabel = [providerLabel, title, message]
            .compactMap { $0 }
            .joined(separator: ", ")
        return IdleScreenAgentOverlayPresentation(
            provider: signal.provider,
            state: signal.state,
            providerLabel: providerLabel,
            title: title,
            message: message,
            style: style,
            position: configuration.overlayPosition,
            accessibilityLabel: accessibilityLabel,
            expiresAt: signal.expiresAt
        )
    }

    public static func isVisible(
        destination: IdleScreenAgentDisplayDestination,
        display: IdleScreenAgentDisplayContext
    ) -> Bool {
        switch destination {
        case .all: true
        case .primary: display.isPrimary
        case .focus: display.isFocus
        }
    }

    public static func configuration(
        _ durableConfiguration: IdleScreenConfiguration,
        applyingTemporaryLookFrom signal: IdleScreenAgentSignal?
    ) -> IdleScreenConfiguration {
        guard let lookID = signal?.temporaryLookID,
              let configured = try? durableConfiguration.applyingSavedLook(id: lookID) else {
            return durableConfiguration
        }
        return configured
    }

    private static func defaultTitle(
        providerName: String,
        state: IdleScreenAgentSignalState
    ) -> String {
        switch state {
        case .working: "\(providerName) is working"
        case .needsAttention: "\(providerName) needs attention"
        case .done: "\(providerName) finished"
        case .error: "\(providerName) stopped with an error"
        case .idle: "\(providerName) is idle"
        }
    }
}
