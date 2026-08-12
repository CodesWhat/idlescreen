import Foundation

public struct IdleScreenSharedPaths: Equatable, Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public var configurationURL: URL {
        rootURL.appending(path: "configuration.json")
    }

    public var healthDirectoryURL: URL {
        rootURL.appending(path: "Health", directoryHint: .isDirectory)
    }

    public var agentSignalsDirectoryURL: URL {
        rootURL.appending(path: "AgentSignals", directoryHint: .isDirectory)
    }

    public var agentSignalsInboxURL: URL {
        agentSignalsDirectoryURL.appending(path: "inbox-v1.json")
    }
}

public enum IdleScreenSharedContainer {
    public static func locate(appGroupIdentifier: String) -> IdleScreenSharedPaths? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            .map(IdleScreenSharedPaths.init(rootURL:))
    }
}
