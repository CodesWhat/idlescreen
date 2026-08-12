enum IdleScreenLaunchPolicy {
    private static let lifecycleProbeArgumentPrefix = "--idlescreen-lifecycle-probe="
    private static let configurationContrastProbeArgumentPrefix =
        "--idlescreen-configuration-probe-contrast="
    private static let cameraAgentRebindResultArgumentPrefix =
        "--idlescreen-camera-agent-rebind-result="
    private static let cameraAgentRebindPreviousPIDArgumentPrefix =
        "--idlescreen-camera-agent-rebind-previous-pid="

    enum BackgroundProbe: Equatable {
        case lifecycle(String)
        case configurationContrast(Double)
        case cameraAgentRebind(resultPath: String, previousProcessIdentifier: Int32?)
    }

    static func backgroundProbe(arguments: [String]) -> BackgroundProbe? {
        if let resultArgument = arguments.first(where: {
            $0.hasPrefix(cameraAgentRebindResultArgumentPrefix)
        }) {
            let resultPath = String(resultArgument.dropFirst(
                cameraAgentRebindResultArgumentPrefix.count
            ))
            let previousProcessIdentifier = arguments.first(where: {
                $0.hasPrefix(cameraAgentRebindPreviousPIDArgumentPrefix)
            }).flatMap { argument in
                Int32(argument.dropFirst(
                    cameraAgentRebindPreviousPIDArgumentPrefix.count
                ))
            }.flatMap { $0 > 0 ? $0 : nil }
            if resultPath.hasPrefix("/tmp/idlescreen-phase1-install.") {
                return .cameraAgentRebind(
                    resultPath: resultPath,
                    previousProcessIdentifier: previousProcessIdentifier
                )
            }
        }
        for argument in arguments {
            if argument.hasPrefix(lifecycleProbeArgumentPrefix) {
                return .lifecycle(String(argument.dropFirst(lifecycleProbeArgumentPrefix.count)))
            }
            if argument.hasPrefix(configurationContrastProbeArgumentPrefix),
               let contrast = Double(argument.dropFirst(configurationContrastProbeArgumentPrefix.count)),
               (0 ... 1).contains(contrast) {
                return .configurationContrast(contrast)
            }
        }
        return nil
    }

    static func shouldShowMainWindow(arguments: [String]) -> Bool {
        backgroundProbe(arguments: arguments) == nil
    }
}
