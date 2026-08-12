@main
enum IdleScreenLaunchPolicyProbe {
    static func main() {
        precondition(
            IdleScreenLaunchPolicy.shouldShowMainWindow(arguments: ["/Applications/idlescreen.app/Contents/MacOS/IdleScreen"])
        )
        precondition(
            !IdleScreenLaunchPolicy.shouldShowMainWindow(
                arguments: [
                    "/Applications/idlescreen.app/Contents/MacOS/IdleScreen",
                    "--idlescreen-lifecycle-probe=phase1-20"
                ]
            )
        )
        precondition(
            IdleScreenLaunchPolicy.backgroundProbe(
                arguments: [
                    "/Applications/idlescreen.app/Contents/MacOS/IdleScreen",
                    "--idlescreen-configuration-probe-contrast=0.61"
                ]
            ) == .configurationContrast(0.61)
        )
        precondition(
            !IdleScreenLaunchPolicy.shouldShowMainWindow(
                arguments: [
                    "/Applications/idlescreen.app/Contents/MacOS/IdleScreen",
                    "--idlescreen-configuration-probe-contrast=0.61"
                ]
            )
        )
        precondition(
            IdleScreenLaunchPolicy.backgroundProbe(
                arguments: [
                    "/Applications/idlescreen.app/Contents/MacOS/IdleScreen",
                    "--idlescreen-configuration-probe-contrast=not-a-number"
                ]
            ) == nil
        )
        precondition(
            IdleScreenLaunchPolicy.shouldShowMainWindow(
                arguments: [
                    "/Applications/idlescreen.app/Contents/MacOS/IdleScreen",
                    "--idlescreen-configuration-probe-contrast=1.5"
                ]
            )
        )
        precondition(
            IdleScreenLaunchPolicy.backgroundProbe(
                arguments: [
                    "/Applications/idlescreen.app/Contents/MacOS/IdleScreen",
                    "--idlescreen-camera-agent-rebind-result=/tmp/idlescreen-phase1-install.ABC123/camera-agent-rebind.plist",
                    "--idlescreen-camera-agent-rebind-previous-pid=4242",
                ]
            ) == .cameraAgentRebind(
                resultPath: "/tmp/idlescreen-phase1-install.ABC123/camera-agent-rebind.plist",
                previousProcessIdentifier: 4242
            )
        )
        precondition(
            !IdleScreenLaunchPolicy.shouldShowMainWindow(
                arguments: [
                    "/Applications/idlescreen.app/Contents/MacOS/IdleScreen",
                    "--idlescreen-camera-agent-rebind-result=/tmp/idlescreen-phase1-install.ABC123/camera-agent-rebind.plist",
                ]
            )
        )
        precondition(
            IdleScreenLaunchPolicy.backgroundProbe(
                arguments: [
                    "/Applications/idlescreen.app/Contents/MacOS/IdleScreen",
                    "--idlescreen-camera-agent-rebind-result=/Users/example/forbidden.plist",
                ]
            ) == nil
        )
        precondition(
            IdleScreenLaunchPolicy.shouldShowMainWindow(
                arguments: [
                    "/Applications/idlescreen.app/Contents/MacOS/IdleScreen",
                    "--unrelated-probe=phase1-20"
                ]
            )
        )
        print("PASS: companion launch policy distinguishes normal and background-probe launches.")
    }
}
