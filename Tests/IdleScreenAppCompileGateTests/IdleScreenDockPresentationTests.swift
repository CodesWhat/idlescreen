import AppKit
import Testing

@Suite("Dock presentation")
struct IdleScreenDockPresentationTests {
  private static let executable = "/Applications/idlescreen.app/Contents/MacOS/IdleScreen"
  private static let rebindResultPath = "/tmp/idlescreen-phase1-install.42/rebind.json"

  /// Resolves the launch-time policy the delegate applies, so these cover the
  /// composition the app actually performs rather than restating the ternary.
  private func launchPolicy(_ arguments: [String]) -> NSApplication.ActivationPolicy {
    IdleScreenDockPresentation.activationPolicy(
      showsMainWindow: IdleScreenLaunchPolicy.shouldShowMainWindow(arguments: arguments)
    )
  }

  @Test("an ordinary launch takes a Dock tile")
  func ordinaryLaunchIsRegular() {
    #expect(launchPolicy([Self.executable]) == .regular)
  }

  @Test("every background probe launches without a Dock tile")
  func backgroundProbesAreAccessory() {
    let probeArguments = [
      ["--idlescreen-lifecycle-probe=phase1-20"],
      ["--idlescreen-configuration-probe-contrast=0.61"],
      ["--idlescreen-camera-agent-rebind-result=\(Self.rebindResultPath)"],
      [
        "--idlescreen-camera-agent-rebind-result=\(Self.rebindResultPath)",
        "--idlescreen-camera-agent-rebind-previous-pid=4242",
      ],
    ]
    for arguments in probeArguments {
      #expect(
        launchPolicy([Self.executable] + arguments) == .accessory,
        "\(arguments) must not surface a Dock tile"
      )
    }
  }

  /// A probe argument the launch policy rejects is not a probe, so it must fall
  /// back to an ordinary windowed launch rather than a tile-less one the user
  /// cannot reach.
  @Test("an unparsable probe argument still launches windowed")
  func rejectedProbeArgumentIsRegular() {
    #expect(
      launchPolicy([
        Self.executable,
        "--idlescreen-configuration-probe-contrast=not-a-number",
      ]) == .regular
    )
  }

  /// The rebind probe only counts when its result path sits under the sanctioned
  /// install prefix, so an arbitrary path is an ordinary launch and has to keep
  /// its tile rather than becoming an unreachable background process.
  @Test("a rebind result path outside the install prefix launches windowed")
  func unsanctionedRebindPathIsRegular() {
    #expect(
      launchPolicy([
        Self.executable,
        "--idlescreen-camera-agent-rebind-result=/tmp/rebind.json",
      ]) == .regular
    )
  }

  @Test("closing the main window gives the Dock tile back")
  func closedWindowIsAccessory() {
    #expect(
      IdleScreenDockPresentation.activationPolicy(showsMainWindow: false) == .accessory
    )
  }

  /// `.prohibited` would take the menu bar item down along with the tile, which
  /// would leave the app running with no way to reach it at all.
  @Test("no input resolves to prohibited")
  func neverProhibited() {
    for showsMainWindow in [true, false] {
      #expect(
        IdleScreenDockPresentation.activationPolicy(
          showsMainWindow: showsMainWindow
        ) != .prohibited
      )
    }
  }
}
