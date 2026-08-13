import Foundation
import IdleScreenAgent
import IdleScreenCore

func runIdleScreenCtl() -> Int32 {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let groupIndices = arguments.indices.filter {
        arguments[$0] == "--app-group"
    }
    guard groupIndices.count == 1,
          let groupIndex = groupIndices.first,
          arguments.indices.contains(groupIndex + 1) else {
        return IdleScreenAgentCommandResult.usage.rawValue
    }
    let appGroupIdentifier = arguments[groupIndex + 1]
    arguments.removeSubrange(groupIndex...(groupIndex + 1))
    guard arguments.first != nil else {
        return IdleScreenAgentCommandResult.usage.rawValue
    }
    guard let paths = locateSharedPaths(
        appGroupIdentifier: appGroupIdentifier
    ) else {
        return IdleScreenAgentCommandResult.unavailable.rawValue
    }

    let input: Data
    if arguments.first == "hook" {
        do {
            var boundedInput = Data()
            let maximum = IdleScreenAgentHookAdapter.maximumPayloadByteCount + 1
            while boundedInput.count < maximum {
                let remaining = maximum - boundedInput.count
                guard let chunk = try FileHandle.standardInput.read(
                    upToCount: remaining
                ), !chunk.isEmpty else {
                    break
                }
                boundedInput.append(chunk)
            }
            input = boundedInput
        } catch {
            return IdleScreenAgentCommandResult.malformedInput.rawValue
        }
    } else {
        input = Data()
    }
    let result = IdleScreenAgentCommandExecutor(sharedPaths: paths).run(
        arguments: arguments,
        standardInput: input
    )
    return result.rawValue
}

private func locateSharedPaths(
    appGroupIdentifier: String
) -> IdleScreenSharedPaths? {
    if appGroupIdentifier == "group.com.idlescreen.shared"
        || appGroupIdentifier == "group.com.idlescreen.dev.shared" {
        return IdleScreenSharedContainer.locate(
            appGroupIdentifier: appGroupIdentifier
        )
    }

    #if DEBUG && IDLESCREEN_CTL_SCRATCH_GATE
    if appGroupIdentifier == "group.com.idlescreen.tests.scratch",
       let rootPath = ProcessInfo.processInfo.environment[
        "IDLESCREEN_CTL_SCRATCH_ROOT"
       ],
       (rootPath as NSString).isAbsolutePath {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        let resourceValues = try? rootURL.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        guard FileManager.default.fileExists(
            atPath: rootURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue,
        resourceValues?.isSymbolicLink == false else {
            return nil
        }
        return IdleScreenSharedPaths(rootURL: rootURL)
    }
    #endif

    return nil
}

exit(runIdleScreenCtl())
