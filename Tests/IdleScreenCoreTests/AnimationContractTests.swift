import Foundation
import Testing
@testable import IdleScreenCore

@Suite("Deterministic shell animation")
struct AnimationContractTests {
    @Test("the same elapsed time always produces the same frame")
    func deterministicFrame() {
        #expect(IdleScreenAnimationFrame.sample(at: 2.75) == IdleScreenAnimationFrame.sample(at: 2.75))
    }

    @Test("the animation loops without a discontinuity")
    func loopBoundary() {
        let start = IdleScreenAnimationFrame.sample(at: 0)
        let nextLoop = IdleScreenAnimationFrame.sample(at: IdleScreenAnimationFrame.loopDuration)

        #expect(start == nextLoop)
        #expect(start.glyph.isEmpty == false)
    }

    @Test("negative host time is clamped to the first frame")
    func negativeTime() {
        #expect(IdleScreenAnimationFrame.sample(at: -1) == IdleScreenAnimationFrame.sample(at: 0))
    }
}
