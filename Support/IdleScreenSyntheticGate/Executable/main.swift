import Darwin
import Dispatch
import Foundation
import IdleScreenCameraSyntheticAgentCore

private func exitWithToken(_ token: String) -> Never {
    let boundedToken = String(token.prefix(32))
    FileHandle.standardError.write(Data("synthetic-camera-agent:\(boundedToken)\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}

guard let configuration = CameraAgentProcessConfiguration(
    infoDictionary: Bundle.main.infoDictionary ?? [:]
) else {
    exitWithToken("config-invalid")
}

let runtime: CameraAgentProcessRuntime
do {
    runtime = try CameraAgentProcessRuntime.bootstrapSynthetic(
        configuration: configuration
    )
} catch let error as CameraAgentProcessBootstrapError {
    exitWithToken(error.stderrToken)
} catch {
    exitWithToken("assembly-failed")
}

runtime.start()
withExtendedLifetime(runtime) { dispatchMain() }
