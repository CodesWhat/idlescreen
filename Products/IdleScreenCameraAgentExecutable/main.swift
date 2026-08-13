import Darwin
import Dispatch
import Foundation
import IdleScreenCameraAgentCore

private func exitWithToken(_ token: String) -> Never {
    let boundedToken = String(token.prefix(32))
    FileHandle.standardError.write(Data("camera-agent:\(boundedToken)\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}

guard let configuration = CameraAgentProcessConfiguration(
    infoDictionary: Bundle.main.infoDictionary ?? [:]
) else {
    exitWithToken("config-invalid")
}

let runtime: CameraAgentProcessRuntime
do {
    runtime = try CameraAgentProcessRuntime.bootstrapProduction(
        configuration: configuration
    )
} catch let error as CameraAgentProcessBootstrapError {
    exitWithToken(error.stderrToken)
} catch {
    exitWithToken("assembly-failed")
}

runtime.startForProcessLifetime()
withExtendedLifetime(runtime) {
    dispatchMain()
}
