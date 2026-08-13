import Darwin
import Foundation
import OSLog

private final class IdleScreenAgentProcessLock: @unchecked Sendable {
    let value = NSLock()
}

protocol IdleScreenAgentSignalStoreMonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
    func sleep(nanoseconds: UInt64)
}

private struct IdleScreenAgentSignalStoreSystemClock:
    IdleScreenAgentSignalStoreMonotonicClock {
    func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func sleep(nanoseconds: UInt64) {
        Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000)
    }
}

protocol IdleScreenAgentSignalStoreProcessLocking: Sendable {
    func tryLock() -> Bool
    func unlock()
}

extension IdleScreenAgentProcessLock: IdleScreenAgentSignalStoreProcessLocking {
    func tryLock() -> Bool {
        value.try()
    }

    func unlock() {
        value.unlock()
    }
}

public struct IdleScreenAgentSignalInbox: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct RecentEvent: Codable, Equatable, Hashable, Sendable {
        public let provider: IdleScreenAgentProvider
        public let sessionID: String
        public let eventID: String

        public init(
            provider: IdleScreenAgentProvider,
            sessionID: String,
            eventID: String
        ) {
            self.provider = provider
            self.sessionID = sessionID
            self.eventID = eventID
        }
    }

    public var schemaVersion: Int
    public var revision: UInt64
    public var updatedAt: Date
    public var signals: [IdleScreenAgentSignal]
    public var recentEvents: [RecentEvent]
    public var ignoredEventCounts: [IdleScreenAgentProvider: UInt64]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        revision: UInt64 = 0,
        updatedAt: Date = .distantPast,
        signals: [IdleScreenAgentSignal] = [],
        recentEvents: [RecentEvent] = [],
        ignoredEventCounts: [IdleScreenAgentProvider: UInt64] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.updatedAt = updatedAt
        self.signals = signals
        self.recentEvents = recentEvents
        self.ignoredEventCounts = ignoredEventCounts
    }

    public static let empty = Self()
}

public struct IdleScreenAgentSignalStore: Sendable {
    private static let processLock = IdleScreenAgentProcessLock()
    private static let coordinationTimeoutNanoseconds: UInt64 = 250_000_000
    private static let coordinationRetryNanoseconds: UInt64 = 1_000_000
    private static let logger = Logger(
        subsystem: "com.idlescreen.core",
        category: "AgentSignalStore"
    )
    enum FallbackReason: Equatable, Sendable {
        case malformedPayload
        case unsupportedSchema
        case payloadTooLarge
        case readFailure
    }

    enum Diagnostic: Equatable, Sendable {
        case recoveredPrevious(FallbackReason)
    }

    public enum Mutation: Equatable, Sendable {
        case set(IdleScreenAgentSignal)
        case clear(
            provider: IdleScreenAgentProvider,
            sessionID: String,
            eventID: String
        )
        case acknowledge(
            provider: IdleScreenAgentProvider,
            sessionID: String,
            eventID: String
        )
        case clearAll
        case recordIgnored(provider: IdleScreenAgentProvider)
    }

    public enum StoreError: Swift.Error, Equatable, Sendable {
        case unsupportedSchema(Int)
        case payloadTooLarge
        case coordinationTimedOut
        case symbolicLinkRejected(operation: String)
        case posix(operation: String, code: Int32)
    }

    public static let maximumSignalCount = 64
    public static let maximumRecentEventCount = 256
    public static let maximumInboxByteCount = 512 * 1_024

    public let fileURL: URL
    private let clock: any IdleScreenAgentSignalStoreMonotonicClock
    private let coordinationLock: any IdleScreenAgentSignalStoreProcessLocking
    private let diagnosticSink: @Sendable (Diagnostic) -> Void

    public init(fileURL: URL) {
        self.fileURL = fileURL
        clock = IdleScreenAgentSignalStoreSystemClock()
        coordinationLock = Self.processLock
        diagnosticSink = { diagnostic in
            Self.logger.notice(
                "Agent signal store recovery: \(String(describing: diagnostic), privacy: .public)"
            )
        }
    }

    init(
        fileURL: URL,
        clock: any IdleScreenAgentSignalStoreMonotonicClock,
        processLock: any IdleScreenAgentSignalStoreProcessLocking,
        diagnosticSink: @escaping @Sendable (Diagnostic) -> Void = { _ in }
    ) {
        self.fileURL = fileURL
        self.clock = clock
        coordinationLock = processLock
        self.diagnosticSink = diagnosticSink
    }

    public func read(at date: Date) throws -> IdleScreenAgentSignalInbox {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        let inbox: IdleScreenAgentSignalInbox
        do {
            inbox = try decode(readData(at: fileURL))
        } catch {
            let primaryError = error
            guard FileManager.default.fileExists(atPath: previousFileURL.path) else {
                throw primaryError
            }
            inbox = try decode(readData(at: previousFileURL))
            diagnosticSink(.recoveredPrevious(fallbackReason(for: primaryError)))
        }
        return pruningExpiredSignals(from: inbox, at: date)
    }

    @discardableResult
    public func apply(
        _ mutation: Mutation,
        at date: Date
    ) throws -> IdleScreenAgentSignalInbox {
        try withExclusiveLock { directoryDescriptor in
            try applyLocked(
                mutation,
                at: date,
                directoryDescriptor: directoryDescriptor
            )
        }
    }

    private func applyLocked(
        _ mutation: Mutation,
        at date: Date,
        directoryDescriptor: Int32
    ) throws -> IdleScreenAgentSignalInbox {
        var inbox = try read(at: date)

        switch mutation {
        case let .set(signal):
            let event = IdleScreenAgentSignalInbox.RecentEvent(
                provider: signal.provider,
                sessionID: signal.sessionID,
                eventID: signal.eventID
            )
            guard !inbox.recentEvents.contains(event) else { return inbox }
            inbox.signals.removeAll {
                $0.provider == signal.provider && $0.sessionID == signal.sessionID
            }
            if signal.state != .idle, signal.expiresAt > date {
                inbox.signals.append(signal)
            }
            inbox.signals.sort(by: Self.signalOrder)
            if inbox.signals.count > Self.maximumSignalCount {
                inbox.signals.removeFirst(inbox.signals.count - Self.maximumSignalCount)
            }
            inbox.recentEvents.append(event)
            if inbox.recentEvents.count > Self.maximumRecentEventCount {
                inbox.recentEvents.removeFirst(
                    inbox.recentEvents.count - Self.maximumRecentEventCount
                )
            }
        case let .clear(provider, sessionID, eventID):
            let event = IdleScreenAgentSignalInbox.RecentEvent(
                provider: provider,
                sessionID: sessionID,
                eventID: eventID
            )
            guard !inbox.recentEvents.contains(event) else { return inbox }
            inbox.signals.removeAll {
                $0.provider == provider && $0.sessionID == sessionID
            }
            inbox.recentEvents.append(event)
            if inbox.recentEvents.count > Self.maximumRecentEventCount {
                inbox.recentEvents.removeFirst(
                    inbox.recentEvents.count - Self.maximumRecentEventCount
                )
            }
        case let .recordIgnored(provider):
            let count = inbox.ignoredEventCounts[provider, default: 0]
            if count < UInt64.max {
                inbox.ignoredEventCounts[provider] = count + 1
            }
        case let .acknowledge(provider, sessionID, eventID):
            let event = IdleScreenAgentSignalInbox.RecentEvent(
                provider: provider,
                sessionID: sessionID,
                eventID: eventID
            )
            guard !inbox.recentEvents.contains(event) else { return inbox }
            if let index = inbox.signals.firstIndex(where: {
                $0.provider == provider && $0.sessionID == sessionID
            }) {
                inbox.signals[index] = try inbox.signals[index].acknowledging(at: date)
            }
            inbox.recentEvents.append(event)
            if inbox.recentEvents.count > Self.maximumRecentEventCount {
                inbox.recentEvents.removeFirst(
                    inbox.recentEvents.count - Self.maximumRecentEventCount
                )
            }
        case .clearAll:
            inbox.signals.removeAll(keepingCapacity: false)
        }

        inbox.schemaVersion = IdleScreenAgentSignalInbox.currentSchemaVersion
        inbox.revision &+= 1
        inbox.updatedAt = date
        try write(inbox, directoryDescriptor: directoryDescriptor)
        return inbox
    }

    private func withExclusiveLock<T>(
        _ body: (Int32) throws -> T
    ) throws -> T {
        let start = clock.nowNanoseconds()
        let (candidateDeadline, overflow) = start.addingReportingOverflow(
            Self.coordinationTimeoutNanoseconds
        )
        let deadline = overflow ? UInt64.max : candidateDeadline
        while true {
            guard clock.nowNanoseconds() <= deadline else {
                throw StoreError.coordinationTimedOut
            }
            if coordinationLock.tryLock() {
                guard clock.nowNanoseconds() <= deadline else {
                    coordinationLock.unlock()
                    throw StoreError.coordinationTimedOut
                }
                break
            }
            let current = clock.nowNanoseconds()
            guard current < deadline else {
                throw StoreError.coordinationTimedOut
            }
            clock.sleep(
                nanoseconds: min(
                    Self.coordinationRetryNanoseconds,
                    deadline - current
                )
            )
        }
        defer { coordinationLock.unlock() }
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try setPermissions(0o700, at: directoryURL)
        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard directoryDescriptor >= 0 else {
            if errno == ELOOP {
                throw StoreError.symbolicLinkRejected(operation: "open-directory")
            }
            throw StoreError.posix(operation: "open-directory", code: errno)
        }
        defer { Darwin.close(directoryDescriptor) }
        var directoryStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0 else {
            throw StoreError.posix(operation: "stat-directory", code: errno)
        }
        guard (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
              directoryStatus.st_uid == geteuid() else {
            throw StoreError.posix(operation: "validate-directory", code: EPERM)
        }
        let lockLeaf = fileURL.appendingPathExtension("lock").lastPathComponent
        var descriptor = Darwin.openat(
            directoryDescriptor,
            lockLeaf,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        if descriptor < 0, errno == EEXIST {
            descriptor = Darwin.openat(
                directoryDescriptor,
                lockLeaf,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw StoreError.symbolicLinkRejected(operation: "open-lock")
            }
            throw StoreError.posix(operation: "open-lock", code: errno)
        }
        defer { Darwin.close(descriptor) }
        try validatePrivateRegularFile(
            descriptor: descriptor,
            operation: "validate-lock"
        )
        while true {
            guard clock.nowNanoseconds() <= deadline else {
                throw StoreError.coordinationTimedOut
            }
            if Darwin.lockf(descriptor, F_TLOCK, 0) == 0 {
                guard clock.nowNanoseconds() <= deadline else {
                    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
                    throw StoreError.coordinationTimedOut
                }
                break
            }
            let lockError = errno
            guard lockError == EAGAIN || lockError == EACCES || lockError == EINTR else {
                throw StoreError.posix(operation: "lock", code: lockError)
            }
            let current = clock.nowNanoseconds()
            guard current < deadline else {
                throw StoreError.coordinationTimedOut
            }
            clock.sleep(
                nanoseconds: min(
                    Self.coordinationRetryNanoseconds,
                    deadline - current
                )
            )
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body(directoryDescriptor)
    }

    private func write(
        _ inbox: IdleScreenAgentSignalInbox,
        directoryDescriptor: Int32
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if FileManager.default.fileExists(atPath: fileURL.path),
           let currentData = try? readData(at: fileURL),
           (try? decode(currentData)) != nil {
            try publishPrivateSnapshot(
                currentData,
                destinationLeaf: previousFileURL.lastPathComponent,
                directoryDescriptor: directoryDescriptor
            )
        }
        let encoded = try encoder.encode(inbox)
        guard encoded.count <= Self.maximumInboxByteCount else {
            throw StoreError.payloadTooLarge
        }
        try publishPrivateSnapshot(
            encoded,
            destinationLeaf: fileURL.lastPathComponent,
            directoryDescriptor: directoryDescriptor
        )
    }

    private func publishPrivateSnapshot(
        _ data: Data,
        destinationLeaf: String,
        directoryDescriptor: Int32
    ) throws {
        let temporaryLeaf = ".\(destinationLeaf).tmp"
        if Darwin.unlinkat(directoryDescriptor, temporaryLeaf, 0) != 0,
           errno != ENOENT {
            throw StoreError.posix(operation: "remove-stale-temporary", code: errno)
        }
        let descriptor = Darwin.openat(
            directoryDescriptor,
            temporaryLeaf,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw StoreError.symbolicLinkRejected(operation: "create-temporary")
            }
            throw StoreError.posix(operation: "create-temporary", code: errno)
        }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary {
                _ = Darwin.unlinkat(directoryDescriptor, temporaryLeaf, 0)
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw StoreError.posix(operation: "secure-temporary", code: errno)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw StoreError.posix(
                        operation: "write-temporary",
                        code: written < 0 ? errno : EIO
                    )
                }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw StoreError.posix(operation: "sync-temporary", code: errno)
        }
        try validatePrivateRegularFile(
            descriptor: descriptor,
            operation: "validate-temporary"
        )
        guard Darwin.renameat(
            directoryDescriptor,
            temporaryLeaf,
            directoryDescriptor,
            destinationLeaf
        ) == 0 else {
            if errno == ELOOP {
                throw StoreError.symbolicLinkRejected(operation: "publish-snapshot")
            }
            throw StoreError.posix(operation: "publish-snapshot", code: errno)
        }
        shouldRemoveTemporary = false
    }

    private func validatePrivateRegularFile(
        descriptor: Int32,
        operation: String
    ) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw StoreError.posix(operation: operation, code: errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == geteuid() else {
            throw StoreError.posix(operation: operation, code: EPERM)
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw StoreError.posix(operation: operation, code: errno)
        }
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw StoreError.posix(operation: operation, code: errno)
        }
        guard UInt16(status.st_mode & 0o777) == 0o600 else {
            throw StoreError.posix(operation: operation, code: EPERM)
        }
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private var previousFileURL: URL {
        fileURL.appendingPathExtension("previous")
    }

    private func decode(_ data: Data) throws -> IdleScreenAgentSignalInbox {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let inbox = try decoder.decode(IdleScreenAgentSignalInbox.self, from: data)
        guard inbox.schemaVersion == IdleScreenAgentSignalInbox.currentSchemaVersion else {
            throw StoreError.unsupportedSchema(inbox.schemaVersion)
        }
        return inbox
    }

    private func readData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        let maximumRead = Self.maximumInboxByteCount + 1
        while result.count < maximumRead {
            guard let chunk = try handle.read(
                upToCount: maximumRead - result.count
            ), !chunk.isEmpty else {
                break
            }
            result.append(chunk)
        }
        guard result.count <= Self.maximumInboxByteCount else {
            throw StoreError.payloadTooLarge
        }
        return result
    }

    private func fallbackReason(for error: any Error) -> FallbackReason {
        if let storeError = error as? StoreError {
            switch storeError {
            case .unsupportedSchema:
                return .unsupportedSchema
            case .payloadTooLarge:
                return .payloadTooLarge
            case .coordinationTimedOut, .symbolicLinkRejected, .posix:
                return .readFailure
            }
        }
        if error is DecodingError {
            return .malformedPayload
        }
        return .readFailure
    }

    private func pruningExpiredSignals(
        from inbox: IdleScreenAgentSignalInbox,
        at date: Date
    ) -> IdleScreenAgentSignalInbox {
        var result = inbox
        let latestAcceptedCreation = date.addingTimeInterval(5 * 60)
        result.signals.removeAll {
            $0.expiresAt <= date
                || $0.createdAt > latestAcceptedCreation
                || $0.state == .idle
        }
        return result
    }

    private static func signalOrder(
        _ lhs: IdleScreenAgentSignal,
        _ rhs: IdleScreenAgentSignal
    ) -> Bool {
        let lhsKey = "\(lhs.provider.rawValue):\(lhs.sessionID)"
        let rhsKey = "\(rhs.provider.rawValue):\(rhs.sessionID)"
        return lhsKey < rhsKey
    }
}
