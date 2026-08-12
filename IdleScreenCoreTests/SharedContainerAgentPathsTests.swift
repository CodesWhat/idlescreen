import Foundation
import Testing
@testable import IdleScreenCore

@Suite("Shared AgentSignal paths")
struct SharedContainerAgentPathsTests {
    @Test("the inbox is isolated from durable visual configuration")
    func derivesAgentSignalPaths() {
        let paths = IdleScreenSharedPaths(
            rootURL: URL(fileURLWithPath: "/tmp/group.com.idlescreen.shared")
        )

        #expect(paths.agentSignalsDirectoryURL.lastPathComponent == "AgentSignals")
        #expect(paths.agentSignalsInboxURL.lastPathComponent == "inbox-v1.json")
        #expect(paths.agentSignalsInboxURL.deletingLastPathComponent()
            == paths.agentSignalsDirectoryURL)
        #expect(paths.agentSignalsInboxURL != paths.configurationURL)
    }
}
