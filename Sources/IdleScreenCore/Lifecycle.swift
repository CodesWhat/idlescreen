public enum IdleScreenLifecyclePhase: String, Codable, CaseIterable, Sendable {
    case detached
    case attached
    case animating
}

public enum IdleScreenLifecycleEvent: Sendable {
    case attach
    case startAnimating
    case stopAnimating
    case detach
}

public struct IdleScreenLifecycleMachine: Sendable {
    public private(set) var phase: IdleScreenLifecyclePhase

    public init(phase: IdleScreenLifecyclePhase = .detached) {
        self.phase = phase
    }

    @discardableResult
    public mutating func apply(_ event: IdleScreenLifecycleEvent) -> Bool {
        let next: IdleScreenLifecyclePhase?
        switch (phase, event) {
        case (.detached, .attach):
            next = .attached
        case (.attached, .startAnimating):
            next = .animating
        case (.animating, .stopAnimating):
            next = .attached
        case (.attached, .detach), (.animating, .detach):
            next = .detached
        default:
            next = nil
        }

        guard let next else { return false }
        phase = next
        return true
    }
}
