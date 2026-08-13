import Foundation
import OSLog

public struct IdleScreenAgentSignalPresentationChange: Equatable, Sendable {
    public let inboxRevision: UInt64
    public let signal: IdleScreenAgentSignal?
    public let ignoredEventCounts: [IdleScreenAgentProvider: UInt64]

    public init(
        inboxRevision: UInt64,
        signal: IdleScreenAgentSignal?,
        ignoredEventCounts: [IdleScreenAgentProvider: UInt64]
    ) {
        self.inboxRevision = inboxRevision
        self.signal = signal
        self.ignoredEventCounts = ignoredEventCounts
    }
}

public struct IdleScreenAgentSignalMonitor: Sendable {
    public static let minimumPollingInterval: TimeInterval = 0.25
    public static let maximumPollingInterval: TimeInterval = 60
    private static let performanceSignposter = OSSignposter(
        subsystem: "com.idlescreen.core",
        category: "Performance"
    )

    private let store: IdleScreenAgentSignalStore?
    private let pollingInterval: TimeInterval
    private var nextPollAt: Date = .distantPast
    private var hasPolled = false
    private var lastSignal: IdleScreenAgentSignal?
    private var lastRevision: UInt64 = 0

    public init(
        store: IdleScreenAgentSignalStore,
        pollingInterval: TimeInterval = 1
    ) {
        self.store = store
        self.pollingInterval = min(
            max(pollingInterval, Self.minimumPollingInterval),
            Self.maximumPollingInterval
        )
    }

    public init(pollingInterval: TimeInterval = 1) {
        store = nil
        self.pollingInterval = min(
            max(pollingInterval, Self.minimumPollingInterval),
            Self.maximumPollingInterval
        )
    }

    public func canPoll(at date: Date) -> Bool {
        date >= nextPollAt
    }

    public mutating func poll(
        at date: Date
    ) throws -> IdleScreenAgentSignalPresentationChange? {
        let signpostState = Self.performanceSignposter.beginInterval(
            "AgentSignalPoll"
        )
        defer {
            Self.performanceSignposter.endInterval(
                "AgentSignalPoll",
                signpostState
            )
        }
        guard canPoll(at: date), let store else { return nil }
        let inbox = try store.read(at: date)
        return consume(inbox, at: date)
    }

    public mutating func consume(
        _ inbox: IdleScreenAgentSignalInbox,
        at date: Date
    ) -> IdleScreenAgentSignalPresentationChange? {
        guard canPoll(at: date) else { return nil }
        nextPollAt = date.addingTimeInterval(pollingInterval)
        let signal = IdleScreenAgentSignalArbitrator.activeSignal(
            in: inbox.signals,
            at: date
        )
        guard !hasPolled || signal != lastSignal || inbox.revision != lastRevision else {
            return nil
        }
        hasPolled = true
        lastSignal = signal
        lastRevision = inbox.revision
        return IdleScreenAgentSignalPresentationChange(
            inboxRevision: inbox.revision,
            signal: signal,
            ignoredEventCounts: inbox.ignoredEventCounts
        )
    }
}
