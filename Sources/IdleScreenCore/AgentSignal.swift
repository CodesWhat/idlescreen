import Foundation

public enum IdleScreenAgentProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public enum IdleScreenAgentSignalState: String, Codable, CaseIterable, Sendable {
    case working
    case needsAttention
    case done
    case error
    case idle
}

public struct IdleScreenAgentSignal: Codable, Equatable, Sendable {
    public enum ValidationError: Swift.Error, Equatable, Sendable {
        case unsupportedSchema(Int)
        case invalidIdentifier(field: String)
        case invalidPriority(Int)
        case invalidTimeline
        case expirationTooDistant
    }

    public static let currentSchemaVersion = 1
    public static let minimumPriority = -100
    public static let maximumPriority = 100
    public static let maximumTimeToLive: TimeInterval = 24 * 60 * 60

    public let schemaVersion: Int
    public let provider: IdleScreenAgentProvider
    public let sessionID: String
    public let eventID: String
    public let state: IdleScreenAgentSignalState
    public let title: String?
    public let message: String?
    public let temporaryLookID: UUID?
    public let priority: Int
    public let createdAt: Date
    public let expiresAt: Date
    public let acknowledgedAt: Date?
    public let nonce: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case provider
        case sessionID
        case eventID
        case state
        case title
        case message
        case temporaryLookID
        case priority
        case createdAt
        case expiresAt
        case acknowledgedAt
        case nonce
    }

    public static func validated(
        provider: IdleScreenAgentProvider,
        sessionID: String,
        eventID: String,
        state: IdleScreenAgentSignalState,
        title: String?,
        message: String?,
        temporaryLookID: UUID?,
        priority: Int,
        createdAt: Date,
        expiresAt: Date,
        acknowledgedAt: Date?,
        nonce: String,
        validatedAt: Date
    ) throws -> Self {
        guard Self.isValidIdentifier(sessionID) else {
            throw ValidationError.invalidIdentifier(field: "sessionID")
        }
        guard Self.isValidIdentifier(eventID) else {
            throw ValidationError.invalidIdentifier(field: "eventID")
        }
        guard Self.isValidIdentifier(nonce) else {
            throw ValidationError.invalidIdentifier(field: "nonce")
        }
        guard (minimumPriority...maximumPriority).contains(priority) else {
            throw ValidationError.invalidPriority(priority)
        }
        guard createdAt <= validatedAt.addingTimeInterval(5 * 60),
              expiresAt > createdAt,
              acknowledgedAt.map({ $0 >= createdAt }) ?? true else {
            throw ValidationError.invalidTimeline
        }
        guard expiresAt.timeIntervalSince(createdAt) <= maximumTimeToLive else {
            throw ValidationError.expirationTooDistant
        }

        return Self(
            schemaVersion: currentSchemaVersion,
            provider: provider,
            sessionID: sessionID,
            eventID: eventID,
            state: state,
            title: IdleScreenAgentTextSanitizer.sanitize(
                title,
                maximumUTF8Bytes: 80,
                maximumLines: 1
            ),
            message: IdleScreenAgentTextSanitizer.sanitize(
                message,
                maximumUTF8Bytes: 280,
                maximumLines: 3
            ),
            temporaryLookID: temporaryLookID,
            priority: priority,
            createdAt: createdAt,
            expiresAt: expiresAt,
            acknowledgedAt: acknowledgedAt,
            nonce: nonce
        )
    }

    private init(
        schemaVersion: Int,
        provider: IdleScreenAgentProvider,
        sessionID: String,
        eventID: String,
        state: IdleScreenAgentSignalState,
        title: String?,
        message: String?,
        temporaryLookID: UUID?,
        priority: Int,
        createdAt: Date,
        expiresAt: Date,
        acknowledgedAt: Date?,
        nonce: String
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.sessionID = sessionID
        self.eventID = eventID
        self.state = state
        self.title = title
        self.message = message
        self.temporaryLookID = temporaryLookID
        self.priority = priority
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.acknowledgedAt = acknowledgedAt
        self.nonce = nonce
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedSchema(schemaVersion)
        }
        self = try Self.validated(
            provider: values.decode(IdleScreenAgentProvider.self, forKey: .provider),
            sessionID: values.decode(String.self, forKey: .sessionID),
            eventID: values.decode(String.self, forKey: .eventID),
            state: values.decode(IdleScreenAgentSignalState.self, forKey: .state),
            title: values.decodeIfPresent(String.self, forKey: .title),
            message: values.decodeIfPresent(String.self, forKey: .message),
            temporaryLookID: values.decodeIfPresent(UUID.self, forKey: .temporaryLookID),
            priority: values.decode(Int.self, forKey: .priority),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            expiresAt: values.decode(Date.self, forKey: .expiresAt),
            acknowledgedAt: values.decodeIfPresent(Date.self, forKey: .acknowledgedAt),
            nonce: values.decode(String.self, forKey: .nonce),
            validatedAt: values.decode(Date.self, forKey: .createdAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(provider, forKey: .provider)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(eventID, forKey: .eventID)
        try values.encode(state, forKey: .state)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(message, forKey: .message)
        try values.encodeIfPresent(temporaryLookID, forKey: .temporaryLookID)
        try values.encode(priority, forKey: .priority)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(expiresAt, forKey: .expiresAt)
        try values.encodeIfPresent(acknowledgedAt, forKey: .acknowledgedAt)
        try values.encode(nonce, forKey: .nonce)
    }

    public func acknowledging(at date: Date) throws -> Self {
        try Self.validated(
            provider: provider,
            sessionID: sessionID,
            eventID: eventID,
            state: state,
            title: title,
            message: message,
            temporaryLookID: temporaryLookID,
            priority: priority,
            createdAt: createdAt,
            expiresAt: expiresAt,
            acknowledgedAt: date,
            nonce: nonce,
            validatedAt: max(date, createdAt)
        )
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
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
}

public enum IdleScreenAgentSignalArbitrator {
    public static func activeSignal(
        in signals: [IdleScreenAgentSignal],
        at date: Date
    ) -> IdleScreenAgentSignal? {
        signals
            .filter { signal in
                signal.expiresAt > date
                    && signal.state != .idle
                    && !(signal.state == .done && signal.acknowledgedAt != nil)
            }
            .max(by: isLowerPriority)
    }

    private static func isLowerPriority(
        _ lhs: IdleScreenAgentSignal,
        _ rhs: IdleScreenAgentSignal
    ) -> Bool {
        let lhsRank = rank(lhs.state)
        let rhsRank = rank(rhs.state)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        let lhsKey = "\(lhs.provider.rawValue):\(lhs.sessionID):\(lhs.eventID)"
        let rhsKey = "\(rhs.provider.rawValue):\(rhs.sessionID):\(rhs.eventID)"
        return lhsKey > rhsKey
    }

    private static func rank(_ state: IdleScreenAgentSignalState) -> Int {
        switch state {
        case .needsAttention: 4
        case .error: 3
        case .done: 2
        case .working: 1
        case .idle: 0
        }
    }
}

private enum IdleScreenAgentTextSanitizer {
    static func sanitize(
        _ value: String?,
        maximumUTF8Bytes: Int,
        maximumLines: Int
    ) -> String? {
        guard let value else { return nil }
        let withoutEscapes = removingTerminalEscapes(from: value)
        let withoutTags = removingAngleBracketTags(from: withoutEscapes)
        let markupScalars = CharacterSet(charactersIn: "*_`#~[]")
        var normalized = ""

        for scalar in withoutTags.unicodeScalars {
            if scalar == "\n" {
                normalized.append("\n")
            } else if scalar == "\t" || scalar.properties.isWhitespace {
                normalized.append(" ")
            } else if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
                continue
            } else if markupScalars.contains(scalar) {
                continue
            } else {
                normalized.unicodeScalars.append(scalar)
            }
        }

        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(maximumLines)
            .map { line in
                line.split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        let collapsed = lines.joined(separator: maximumLines == 1 ? " " : "\n")
        let bounded = truncate(collapsed, maximumUTF8Bytes: maximumUTF8Bytes)
        return bounded.isEmpty ? nil : bounded
    }

    private static func removingAngleBracketTags(from value: String) -> String {
        var output = ""
        var insideTag = false
        for character in value {
            if character == "<" {
                insideTag = true
            } else if character == ">", insideTag {
                insideTag = false
            } else if !insideTag {
                output.append(character)
            }
        }
        return output
    }

    private static func removingTerminalEscapes(from value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index].value == 0x1B else {
                output.append(scalars[index])
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { break }
            if scalars[index] == "[" {
                index += 1
                while index < scalars.count {
                    let value = scalars[index].value
                    index += 1
                    if (0x40...0x7E).contains(value) { break }
                }
            } else if scalars[index] == "]" {
                index += 1
                while index < scalars.count {
                    if scalars[index].value == 0x07 {
                        index += 1
                        break
                    }
                    if scalars[index].value == 0x1B,
                       index + 1 < scalars.count,
                       scalars[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return String(output)
    }

    private static func truncate(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> String {
        guard value.utf8.count > maximumUTF8Bytes else { return value }
        var result = ""
        var byteCount = 0
        for character in value {
            let addition = String(character)
            let additionBytes = addition.utf8.count
            guard byteCount + additionBytes <= maximumUTF8Bytes else { break }
            result.append(character)
            byteCount += additionBytes
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
