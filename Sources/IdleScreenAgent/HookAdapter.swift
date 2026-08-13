import CryptoKit
import Foundation
import IdleScreenCore

public enum IdleScreenAgentHookAdapter {
    public enum Error: Swift.Error, Equatable, Sendable {
        case providerDisabled(IdleScreenAgentProvider)
        case payloadTooLarge
        case malformedPayload
        case missingField(String)
    }

    public static let maximumPayloadByteCount = 65_536

    public static func mutation(
        provider: IdleScreenAgentProvider,
        payload: Data,
        configuration: IdleScreenAgentIntegrationConfiguration,
        receivedAt: Date,
        nonce: String
    ) throws -> IdleScreenAgentSignalStore.Mutation {
        guard configuration.isEnabled(for: provider) else {
            throw Error.providerDisabled(provider)
        }
        guard payload.count <= maximumPayloadByteCount else {
            throw Error.payloadTooLarge
        }
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let fields = object as? [String: Any],
              let hookEventName = fields["hook_event_name"] as? String,
              !hookEventName.isEmpty else {
            throw Error.malformedPayload
        }

        guard let state = state(for: hookEventName, provider: provider) else {
            if hookEventName == "SessionEnd" {
                let sessionID = try requiredIdentifier("session_id", in: fields)
                return .clear(
                    provider: provider,
                    sessionID: sessionID,
                    eventID: eventIdentifier(
                        eventName: hookEventName,
                        sourceID: nil,
                        nonce: nonce
                    )
                )
            }
            return .recordIgnored(provider: provider)
        }

        let sessionID = try requiredIdentifier("session_id", in: fields)
        let sourceEventID = fields["turn_id"] as? String
        let eventID = eventIdentifier(
            eventName: hookEventName,
            sourceID: sourceEventID,
            nonce: nonce
        )
        let timeout = configuration.messageTimeout
        let signal = try IdleScreenAgentSignal.validated(
            provider: provider,
            sessionID: sessionID,
            eventID: eventID,
            state: state,
            title: title(provider: provider, state: state),
            message: nil,
            temporaryLookID: nil,
            priority: priority(for: state),
            createdAt: receivedAt,
            expiresAt: receivedAt.addingTimeInterval(timeout),
            acknowledgedAt: nil,
            nonce: normalizedIdentifier(nonce, prefix: "nonce"),
            validatedAt: receivedAt
        )
        return .set(signal)
    }

    private static func state(
        for eventName: String,
        provider: IdleScreenAgentProvider
    ) -> IdleScreenAgentSignalState? {
        switch eventName {
        case "SessionStart", "UserPromptSubmit": .working
        case "PermissionRequest": .needsAttention
        case "Stop": .done
        case "Notification" where provider == .claude: .needsAttention
        case "StopFailure" where provider == .claude: .error
        default: nil
        }
    }

    private static func title(
        provider: IdleScreenAgentProvider,
        state: IdleScreenAgentSignalState
    ) -> String {
        let providerName = provider == .codex ? "Codex" : "Claude"
        let status = switch state {
        case .working: "is working"
        case .needsAttention: "needs attention"
        case .done: "finished"
        case .error: "stopped with an error"
        case .idle: "is idle"
        }
        return "\(providerName) \(status)"
    }

    private static func priority(for state: IdleScreenAgentSignalState) -> Int {
        switch state {
        case .needsAttention: 50
        case .error: 40
        case .done: 20
        case .working: 10
        case .idle: 0
        }
    }

    private static func requiredIdentifier(
        _ key: String,
        in fields: [String: Any]
    ) throws -> String {
        guard let value = fields[key] as? String, !value.isEmpty else {
            throw Error.missingField(key)
        }
        return normalizedIdentifier(value, prefix: key.replacingOccurrences(of: "_", with: ""))
    }

    private static func eventIdentifier(
        eventName: String,
        sourceID: String?,
        nonce: String
    ) -> String {
        let event = eventName.lowercased().filter { $0.isLetter || $0.isNumber }
        let suffix = normalizedIdentifier(sourceID ?? nonce, prefix: "event")
        return normalizedIdentifier("\(event)-\(suffix)", prefix: "event")
    }

    private static func normalizedIdentifier(
        _ value: String,
        prefix: String
    ) -> String {
        let allowed = value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 58, 65...90, 95, 97...122: true
            default: false
            }
        }
        if !value.isEmpty, value.utf8.count <= 128, allowed {
            return value
        }
        let digest = SHA256.hash(data: Data(value.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix)-\(digest)"
    }
}
