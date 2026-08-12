import Testing
@testable import IdleScreenSystem

@Suite("Modern ScreenSaver runtime compatibility")
struct ScreenSaverCompatibilityTests {
    @Test("the supported macOS runtime exposes the extension host classes")
    func runtimeClasses() {
        let status = ScreenSaverCompatibilityProbe.check()

        #expect(status.frameworkLoaded)
        #expect(status.missingClassNames.isEmpty)
        #expect(status.missingSelectorNames.isEmpty)
        #expect(status.isCompatible)
    }

    @Test("a missing required selector blocks compatibility")
    func missingSelector() {
        let status = ScreenSaverCompatibilityStatus(
            frameworkLoaded: true,
            missingClassNames: [],
            missingSelectorNames: ["ScreenSaverViewController.startAnimation"]
        )

        #expect(status.isCompatible == false)
    }
}
