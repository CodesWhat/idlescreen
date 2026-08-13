import Testing
@testable import IdleScreenCore

@Suite("Screen saver lifecycle contract")
struct LifecycleContractTests {
    @Test("host events move through one legal lifecycle")
    func legalLifecycle() {
        var lifecycle = IdleScreenLifecycleMachine()

        #expect(lifecycle.phase == .detached)
        #expect(lifecycle.apply(.attach) == true)
        #expect(lifecycle.phase == .attached)
        #expect(lifecycle.apply(.startAnimating) == true)
        #expect(lifecycle.phase == .animating)
        #expect(lifecycle.apply(.stopAnimating) == true)
        #expect(lifecycle.phase == .attached)
        #expect(lifecycle.apply(.detach) == true)
        #expect(lifecycle.phase == .detached)
    }

    @Test("out-of-order host events cannot invent an active instance")
    func rejectsOutOfOrderEvents() {
        var lifecycle = IdleScreenLifecycleMachine()

        #expect(lifecycle.apply(.startAnimating) == false)
        #expect(lifecycle.phase == .detached)
        #expect(lifecycle.apply(.stopAnimating) == false)
        #expect(lifecycle.phase == .detached)
    }
}
