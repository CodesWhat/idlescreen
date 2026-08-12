import Foundation
import IdleScreenCore

public enum IdleScreenAgentCommandResult: Int32, Equatable, Sendable {
    case success = 0
    case usage = 64
    case malformedInput = 65
    case unavailable = 69
    case storageFailure = 74
}

public struct IdleScreenAgentCommandExecutor {
    private let sharedPaths: IdleScreenSharedPaths
    private let now: () -> Date
    private let nonce: () -> String

    public init(
        sharedPaths: IdleScreenSharedPaths,
        now: @escaping () -> Date = Date.init,
        nonce: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.sharedPaths = sharedPaths
        self.now = now
        self.nonce = nonce
    }

    public func run(
        arguments: [String],
        standardInput: Data
    ) -> IdleScreenAgentCommandResult {
        guard let command = arguments.first else { return .usage }
        do {
            switch command {
            case "hook":
                return try runHook(
                    options: parseOptions(
                        Array(arguments.dropFirst()),
                        allowed: ["installation", "provider"]
                    ),
                    payload: standardInput
                )
            case "status":
                return try runStatus(options: parseOptions(
                    Array(arguments.dropFirst()),
                    allowed: [
                        "look", "message", "priority", "provider", "session",
                        "state", "timeout", "title",
                    ]
                ))
            case "clear":
                return try runClear(options: parseOptions(
                    Array(arguments.dropFirst()),
                    allowed: ["provider", "session"]
                ))
            case "clear-all":
                guard arguments.count == 1 else { throw CommandError.usage }
                _ = try store.apply(.clearAll, at: now())
                return .success
            default:
                return .usage
            }
        } catch IdleScreenAgentHookAdapter.Error.providerDisabled {
            // A disabled integration must never disturb the provider workflow.
            return .success
        } catch IdleScreenAgentHookAdapter.Error.payloadTooLarge,
                IdleScreenAgentHookAdapter.Error.malformedPayload,
                IdleScreenAgentHookAdapter.Error.missingField {
            return .malformedInput
        } catch CommandError.usage {
            return .usage
        } catch is IdleScreenAgentSignal.ValidationError {
            return .usage
        } catch {
            return .storageFailure
        }
    }

    private var store: IdleScreenAgentSignalStore {
        IdleScreenAgentSignalStore(fileURL: sharedPaths.agentSignalsInboxURL)
    }

    private func runHook(
        options: [String: String],
        payload: Data
    ) throws -> IdleScreenAgentCommandResult {
        if let installation = options["installation"],
           installation != "idlescreen-v1" {
            throw CommandError.usage
        }
        let provider = try provider(from: options)
        let configuration = try IdleScreenConfigurationStore(
            fileURL: sharedPaths.configurationURL
        ).read()?.agentIntegration ?? .default
        let mutation = try IdleScreenAgentHookAdapter.mutation(
            provider: provider,
            payload: payload,
            configuration: configuration,
            receivedAt: now(),
            nonce: nonce()
        )
        _ = try store.apply(mutation, at: now())
        return .success
    }

    private func runStatus(
        options: [String: String]
    ) throws -> IdleScreenAgentCommandResult {
        let provider = try provider(from: options)
        guard let sessionID = options["session"],
              isValidIdentifier(sessionID),
              let stateValue = options["state"],
              let state = IdleScreenAgentSignalState(rawValue: stateValue),
              state != .idle else {
            throw CommandError.usage
        }
        let date = now()
        let timeout: TimeInterval
        if let timeoutValue = options["timeout"] {
            guard let parsed = TimeInterval(timeoutValue), parsed.isFinite else {
                throw CommandError.usage
            }
            timeout = min(max(parsed, 15), IdleScreenAgentSignal.maximumTimeToLive)
        } else {
            timeout = IdleScreenAgentIntegrationConfiguration.default.messageTimeout
        }
        let temporaryLookID: UUID?
        if let value = options["look"] {
            guard let parsed = UUID(uuidString: value) else {
                throw CommandError.usage
            }
            temporaryLookID = parsed
        } else {
            temporaryLookID = nil
        }
        let priority: Int
        if let value = options["priority"] {
            guard let parsed = Int(value),
                  (IdleScreenAgentSignal.minimumPriority...IdleScreenAgentSignal.maximumPriority)
                    .contains(parsed) else {
                throw CommandError.usage
            }
            priority = parsed
        } else {
            priority = 0
        }
        let eventNonce = nonce()
        let signal = try IdleScreenAgentSignal.validated(
            provider: provider,
            sessionID: sessionID,
            eventID: "manual-\(eventNonce)",
            state: state,
            title: options["title"],
            message: options["message"],
            temporaryLookID: temporaryLookID,
            priority: priority,
            createdAt: date,
            expiresAt: date.addingTimeInterval(timeout),
            acknowledgedAt: nil,
            nonce: eventNonce,
            validatedAt: date
        )
        _ = try store.apply(.set(signal), at: date)
        return .success
    }

    private func runClear(
        options: [String: String]
    ) throws -> IdleScreenAgentCommandResult {
        let provider = try provider(from: options)
        guard let sessionID = options["session"],
              isValidIdentifier(sessionID) else {
            throw CommandError.usage
        }
        let date = now()
        _ = try store.apply(
            .clear(
                provider: provider,
                sessionID: sessionID,
                eventID: "manual-clear-\(nonce())"
            ),
            at: date
        )
        return .success
    }

    private func provider(
        from options: [String: String]
    ) throws -> IdleScreenAgentProvider {
        guard let value = options["provider"],
              let provider = IdleScreenAgentProvider(rawValue: value) else {
            throw CommandError.usage
        }
        return provider
    }

    private func isValidIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 58, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    private func parseOptions(
        _ arguments: [String],
        allowed: Set<String>
    ) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else { throw CommandError.usage }
        var result: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            let name = String(key.dropFirst(2))
            guard key.hasPrefix("--"),
                  !name.isEmpty,
                  allowed.contains(name),
                  result[name] == nil else {
                throw CommandError.usage
            }
            result[name] = arguments[index + 1]
        }
        return result
    }

    private enum CommandError: Swift.Error {
        case usage
    }
}
