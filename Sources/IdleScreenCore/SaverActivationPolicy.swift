import Foundation

/// The only shipping outcomes a verified C6 decision may promote. The
/// unselected state is the checked-in and malformed-input default.
public enum IdleScreenShippingSaverActivationPolicy: String, Codable, Sendable {
    case unselectedFailClosed = "unselected-fail-closed"
    case trustworthyActivationCapability = "trustworthy-activation-capability"
    case disclosedPrewarmContinuation = "disclosed-prewarm-continuation"
    case cameraDisabledSaverFallback = "camera-disabled-saver-fallback"
}

/// Platform observations are inert until the selected shipping policy accepts
/// one. Geometry and preview hints are never represented as provenance.
public enum IdleScreenSaverActivationObservation: String, Codable, Sendable {
    case unavailable
    case inactive
    case runningForeground = "running-foreground"
    case runningBackground = "running-background"
    case inconsistent
}

public enum IdleScreenSaverCameraDemandDirective: String, Codable, Sendable {
    case disabled
    case leaseWhileTrustworthyActivation
    case continueAlreadyWarmProducer
}

/// Immutable source input generated from one verified C6 decision. Invalid or
/// absent hashes always reduce to fail-closed regardless of the named policy.
public struct IdleScreenSaverActivationDecisionInput: Equatable, Sendable {
    public let policy: IdleScreenShippingSaverActivationPolicy
    public let c6DecisionSHA256: String?
    public let c6EvidenceSetSHA256: String?
    public let generatedFromVerifiedC6Decision: Bool

    public init(
        policy: IdleScreenShippingSaverActivationPolicy,
        c6DecisionSHA256: String?,
        c6EvidenceSetSHA256: String?,
        generatedFromVerifiedC6Decision: Bool
    ) {
        self.policy = policy
        self.c6DecisionSHA256 = c6DecisionSHA256
        self.c6EvidenceSetSHA256 = c6EvidenceSetSHA256
        self.generatedFromVerifiedC6Decision = generatedFromVerifiedC6Decision
    }

    public static let failClosed = Self(
        policy: .unselectedFailClosed,
        c6DecisionSHA256: nil,
        c6EvidenceSetSHA256: nil,
        generatedFromVerifiedC6Decision: false
    )

    public var isVerified: Bool {
        generatedFromVerifiedC6Decision
            && policy != .unselectedFailClosed
            && Self.isLowercaseSHA256(c6DecisionSHA256)
            && Self.isLowercaseSHA256(c6EvidenceSetSHA256)
    }

    private static func isLowercaseSHA256(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

public struct IdleScreenShippingSaverCameraDemandPolicy: Sendable {
    public let decision: IdleScreenSaverActivationDecisionInput

    public init(decision: IdleScreenSaverActivationDecisionInput) {
        self.decision = decision
    }

    public static let failClosed = Self(decision: .failClosed)

    public func directive(
        source: IdleScreenSource,
        activation: IdleScreenSaverActivationObservation,
        isPreviewHint: Bool,
        producerAlreadyWarm: Bool
    ) -> IdleScreenSaverCameraDemandDirective {
        guard decision.isVerified, source != .generative else {
            return .disabled
        }

        switch decision.policy {
        case .unselectedFailClosed, .cameraDisabledSaverFallback:
            return .disabled

        case .trustworthyActivationCapability:
            guard !isPreviewHint, activation == .runningForeground else {
                return .disabled
            }
            return .leaseWhileTrustworthyActivation

        case .disclosedPrewarmContinuation:
            // The hosted saver may continue an already warm producer but may
            // never turn this policy into demand-start of a stopped producer.
            guard producerAlreadyWarm else { return .disabled }
            return .continueAlreadyWarmProducer
        }
    }
}
