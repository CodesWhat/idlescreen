import Foundation
import Testing
@testable import IdleScreenCore

@Suite("Live configuration monitor")
struct ConfigurationMonitorTests {
    @Test("publishes the initial revision and only later revisions after the polling interval")
    func observesRevisionChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdleScreenConfigurationStore(fileURL: root.appending(path: "configuration.json"))
        var initial = IdleScreenConfiguration.default
        initial.revision = 7
        initial.appearance.palette = "Ember"
        try store.write(initial)

        var monitor = IdleScreenConfigurationMonitor(store: store, pollingInterval: 1)

        #expect(try monitor.readChange(at: 10) == initial)
        #expect(try monitor.readChange(at: 10.5) == nil)

        var updated = initial
        updated.revision = 8
        updated.appearance.palette = "Aurora"
        try store.write(updated)

        #expect(try monitor.readChange(at: 10.75) == nil)
        #expect(try monitor.readChange(at: 11) == updated)
        #expect(try monitor.readChange(at: 12) == nil)
    }

    @Test("observes a configuration created after the monitor starts")
    func observesLateConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdleScreenConfigurationStore(fileURL: root.appending(path: "configuration.json"))
        var monitor = IdleScreenConfigurationMonitor(store: store, pollingInterval: 0.5)

        #expect(try monitor.readChange(at: 20) == nil)

        var configuration = IdleScreenConfiguration.default
        configuration.revision = 1
        try store.write(configuration)

        #expect(try monitor.readChange(at: 20.25) == nil)
        #expect(try monitor.readChange(at: 20.5) == configuration)
    }
}
