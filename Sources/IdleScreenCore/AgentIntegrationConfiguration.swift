import Foundation

public enum IdleScreenAgentDisplayDestination: String, Codable, CaseIterable, Sendable {
    case all
    case primary
    case focus
}

public enum IdleScreenAgentOverlayPosition: String, Codable, CaseIterable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

public enum IdleScreenAgentVisualStyle: String, Codable, CaseIterable, Sendable {
    case subtle
    case active
    case attention
    case success
    case failure
    case hidden
}

public struct IdleScreenAgentStateVisuals: Codable, Equatable, Sendable {
    public var working: IdleScreenAgentVisualStyle
    public var needsAttention: IdleScreenAgentVisualStyle
    public var done: IdleScreenAgentVisualStyle
    public var error: IdleScreenAgentVisualStyle

    public init(
        working: IdleScreenAgentVisualStyle = .active,
        needsAttention: IdleScreenAgentVisualStyle = .attention,
        done: IdleScreenAgentVisualStyle = .success,
        error: IdleScreenAgentVisualStyle = .failure
    ) {
        self.working = working
        self.needsAttention = needsAttention
        self.done = done
        self.error = error
    }

    public static let `default` = Self()

    public func style(for state: IdleScreenAgentSignalState) -> IdleScreenAgentVisualStyle {
        switch state {
        case .working: working
        case .needsAttention: needsAttention
        case .done: done
        case .error: error
        case .idle: .hidden
        }
    }
}

public struct IdleScreenAgentQuietHours: Codable, Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = min(max(startMinute, 0), 1_439)
        self.endMinute = min(max(endMinute, 0), 1_439)
    }

    public func contains(minuteOfDay: Int) -> Bool {
        let minute = min(max(minuteOfDay, 0), 1_439)
        if startMinute == endMinute { return false }
        if startMinute < endMinute {
            return (startMinute..<endMinute).contains(minute)
        }
        return minute >= startMinute || minute < endMinute
    }
}

public struct IdleScreenAgentIntegrationConfiguration: Codable, Equatable, Sendable {
    public static let minimumMessageTimeout: TimeInterval = 15
    public static let maximumMessageTimeout: TimeInterval = 60 * 60

    public var codexEnabled: Bool
    public var claudeEnabled: Bool
    public var messageTimeout: TimeInterval
    public var quietHours: IdleScreenAgentQuietHours?
    public var displayDestination: IdleScreenAgentDisplayDestination
    public var overlayPosition: IdleScreenAgentOverlayPosition
    public var showsProviderLabel: Bool
    public var showsMessage: Bool
    public var stateVisuals: IdleScreenAgentStateVisuals

    public init(
        codexEnabled: Bool = false,
        claudeEnabled: Bool = false,
        messageTimeout: TimeInterval = 120,
        quietHours: IdleScreenAgentQuietHours? = nil,
        displayDestination: IdleScreenAgentDisplayDestination = .primary,
        overlayPosition: IdleScreenAgentOverlayPosition = .topTrailing,
        showsProviderLabel: Bool = true,
        showsMessage: Bool = true,
        stateVisuals: IdleScreenAgentStateVisuals = .default
    ) {
        self.codexEnabled = codexEnabled
        self.claudeEnabled = claudeEnabled
        self.messageTimeout = Self.normalizedTimeout(messageTimeout)
        self.quietHours = quietHours
        self.displayDestination = displayDestination
        self.overlayPosition = overlayPosition
        self.showsProviderLabel = showsProviderLabel
        self.showsMessage = showsMessage
        self.stateVisuals = stateVisuals
    }

    public static let `default` = Self()

    public var normalized: Self {
        Self(
            codexEnabled: codexEnabled,
            claudeEnabled: claudeEnabled,
            messageTimeout: messageTimeout,
            quietHours: quietHours,
            displayDestination: displayDestination,
            overlayPosition: overlayPosition,
            showsProviderLabel: showsProviderLabel,
            showsMessage: showsMessage,
            stateVisuals: stateVisuals
        )
    }

    public func isEnabled(for provider: IdleScreenAgentProvider) -> Bool {
        switch provider {
        case .codex: codexEnabled
        case .claude: claudeEnabled
        }
    }

    private static func normalizedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite else { return Self.default.messageTimeout }
        return min(max(timeout, minimumMessageTimeout), maximumMessageTimeout)
    }
}
