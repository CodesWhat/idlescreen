import IdleScreenCamera
import IdleScreenSystem
import Testing

@Suite("Status summary")
struct StatusSummaryTests {
  private func summary(_ edit: (inout StatusInputs) -> Void = { _ in }) -> StatusSummary {
    var inputs = StatusInputs()
    edit(&inputs)
    return StatusSummary(inputs)
  }

  // MARK: Verdict

  @Test("everything fine reads as ready, with no primary action")
  func ready() {
    let result = summary()
    #expect(result.verdict == "IdleScreen is ready.")
    #expect(result.problems.isEmpty)
    #expect(result.primaryAction == nil)
    #expect(result.saver.word == "Ready")
    #expect(result.camera.word == "Ready")
    #expect(!result.isDevelopmentBuild)
  }

  @Test("Studio's pill is the verdict in short sentence case")
  func pillLabel() {
    #expect(summary().pillLabel == "IdleScreen is ready")
    #expect(summary().pillKind == .ok)
    #expect(summary { $0.saverStatusKnown = false }.pillLabel == "Checking IdleScreen")
    #expect(summary { $0.registrationLocation = .notRegistered }.pillLabel == "Needs setup")
    #expect(summary { $0.registrationLocation = .notRegistered }.pillKind == .attention)
    #expect(summary { $0.extensionEmbedded = false }.pillLabel == "Needs attention")
    #expect(summary { $0.extensionEmbedded = false }.pillKind == .error)
  }

  @Test("the verdict counts the problems")
  func verdictWords() {
    #expect(StatusSummary.verdict(problemCount: 0, isChecking: false) == "IdleScreen is ready.")
    #expect(StatusSummary.verdict(problemCount: 0, isChecking: true) == "Checking IdleScreen…")
    #expect(
      StatusSummary.verdict(problemCount: 1, isChecking: false) == "One thing needs your attention."
    )
    #expect(
      StatusSummary.verdict(problemCount: 2, isChecking: false) == "2 things need your attention.")
  }

  // MARK: Screen saver

  @Test("each screen saver problem names one state and one action")
  func saverStates() {
    typealias Row = (String, (inout StatusInputs) -> Void, StatusSaverState, String, StatusAction?)
    let rows: [Row] = [
      (
        "not registered",
        {
          $0.registrationLocation = .notRegistered
          $0.selectedEverywhere = false
        }, .notRegistered, "Not registered", .registerSaver
      ),
      (
        "registered, not selected", { $0.selectedEverywhere = false }, .notSelected,
        "Not selected", .openScreenSaverSettings
      ),
      (
        "another copy registered", { $0.registrationLocation = .differentCopy }, .outOfDate,
        "Out of date", .repairSaver
      ),
      (
        "extension missing", { $0.extensionEmbedded = false }, .missing,
        "Missing from this copy", nil
      ),
      ("macOS too old", { $0.macOSCompatible = false }, .unsupported, "Not supported", nil),
    ]
    for (name, edit, state, word, action) in rows {
      let result = summary(edit)
      #expect(result.saverState == state, "\(name) state")
      #expect(result.saver.word == word, "\(name) word")
      #expect(result.saver.action == action, "\(name) action")
      #expect(result.verdict == "One thing needs your attention.", "\(name) verdict")
      #expect(result.primaryAction == action, "\(name) primary")
    }
  }

  @Test("the screen saver card agrees with setup's register and choose steps")
  func saverMatchesSetup() {
    for registered in [false, true] {
      for selected in [false, true] {
        let progress = SetupProgress(
          SetupInputs(
            registrationCurrent: registered, selectedEverywhere: selected, cameraAccess: .unknown,
            cameraSkipped: false))
        let result = summary {
          $0.registrationLocation = registered ? .currentBuild : .notRegistered
          $0.selectedEverywhere = selected
        }
        #expect((result.saverState == .ready) == progress.requiredStepsDone)
        #expect((progress.current == .register) == (result.saverState == .notRegistered))
        #expect((progress.current == .choose) == (result.saverState == .notSelected))
      }
    }
  }

  @Test("before the first fresh answer the page is checking, not alarmed")
  func checking() {
    let result = summary { $0.saverStatusKnown = false }
    #expect(result.saverState == .checking)
    #expect(result.problems.isEmpty)
    #expect(result.verdict == "Checking IdleScreen…")
  }

  // MARK: Camera

  @Test("a camera nothing uses is Off and never a problem")
  func cameraOff() {
    for authorization in [
      CameraAgentAuthorizationObservation.unknown, .observed(.notDetermined), .observed(.denied),
      .observed(.restricted),
    ] {
      let result = summary {
        $0.cameraInUse = false
        $0.cameraAuthorization = authorization
        $0.cameraHasFault = true
      }
      #expect(result.cameraState == .off)
      #expect(result.camera.word == "Off")
      #expect(result.verdict == "IdleScreen is ready.")
    }
  }

  @Test("a camera in use maps permission and faults to one state each")
  func cameraStates() {
    func camera(
      _ authorization: CameraAgentAuthorizationObservation, fault: Bool = false
    ) -> StatusSummary {
      summary {
        $0.cameraInUse = true
        $0.cameraAuthorization = authorization
        $0.cameraHasFault = fault
      }
    }
    #expect(camera(.observed(.authorized)).cameraState == .ready)
    #expect(camera(.unknown).cameraState == .checking)

    let ask = camera(.observed(.notDetermined))
    #expect(ask.cameraState == .needsPermission)
    #expect(ask.camera.word == "Needs permission")
    #expect(ask.camera.action == .allowCamera)
    #expect(ask.primaryAction == .allowCamera)

    let denied = camera(.observed(.denied))
    #expect(denied.cameraState == .needsPermission)
    #expect(denied.camera.action == .openCameraPrivacy)

    let restricted = camera(.observed(.restricted))
    #expect(restricted.cameraState == .blockedByPolicy)
    #expect(restricted.camera.word == "Blocked by policy")
    #expect(restricted.camera.action == nil)
    #expect(restricted.problems.count == 1)

    let broken = camera(.observed(.authorized), fault: true)
    #expect(broken.cameraState == .notWorking)
    #expect(broken.camera.word == "Not working")
    #expect(broken.camera.action == .fixCamera)
    #expect(broken.verdict == "One thing needs your attention.")
  }

  @Test("the camera card reuses the Studio and setup guidance copy")
  func cameraSharesGuidance() {
    for authorization in [
      CameraAgentAuthorizationObservation.observed(.notDetermined), .observed(.denied),
      .observed(.restricted),
    ] {
      for completed in [true, false] {
        let result = summary {
          $0.cameraInUse = true
          $0.cameraAuthorization = authorization
          $0.setupCompleted = completed
        }
        let guidance = CameraCardGuidance.make(
          authorization: authorization, setupCompleted: completed)
        #expect(result.camera.sentence == guidance.detail)
      }
    }
    let early = summary {
      $0.cameraInUse = true
      $0.cameraAuthorization = .observed(.notDetermined)
      $0.setupCompleted = false
    }
    #expect(early.camera.action == .openSetup)
  }

  // MARK: Agent signals

  @Test("agent signals are Installed, Not installed or Unavailable, and never a problem")
  func agents() {
    let mixed = summary {
      $0.codexHooksInstalled = true
      $0.claudeHooksInstalled = false
    }
    #expect(mixed.agents.map(\.name) == ["Codex", "Claude"])
    #expect(mixed.agents.map(\.state.word) == ["Installed", "Not installed"])
    #expect(mixed.agentsAction.title == "Set up in Agents")
    #expect(mixed.problems.isEmpty)

    let unsigned = summary { $0.sharedContainerAvailable = false }
    #expect(
      unsigned.agents.map(\.state.word)
        == ["Unavailable in this build", "Unavailable in this build"])
  }

  // MARK: Development build

  @Test("an unsigned build says so, and keeps the camera honest")
  func developmentBuild() {
    let off = summary { $0.sharedContainerAvailable = false }
    #expect(off.isDevelopmentBuild)
    #expect(
      StatusSummary.developmentBuildNotice
        == "This is a development build. Camera and agent signals need a signed copy of IdleScreen."
    )
    #expect(off.cameraState == .off)
    #expect(off.verdict == "IdleScreen is ready.")

    let used = summary {
      $0.sharedContainerAvailable = false
      $0.cameraInUse = true
    }
    #expect(used.cameraState == .notWorking)
    #expect(used.camera.sentence == "The camera needs a signed copy of IdleScreen.")
    #expect(used.camera.action == nil)
  }

  // MARK: Multiple problems

  @Test("two problems are counted, and the screen saver's action comes first")
  func multipleProblems() {
    let result = summary {
      $0.registrationLocation = .notRegistered
      $0.selectedEverywhere = false
      $0.cameraInUse = true
      $0.cameraAuthorization = .observed(.denied)
    }
    #expect(result.problems.map(\.title) == ["Screen saver", "Camera"])
    #expect(result.verdict == "2 things need your attention.")
    #expect(result.primaryAction == .registerSaver)
  }

  @Test("with an unfixable first problem, the primary action falls to the next one")
  func primarySkipsUnfixable() {
    let result = summary {
      $0.extensionEmbedded = false
      $0.cameraInUse = true
      $0.cameraAuthorization = .observed(.denied)
    }
    #expect(result.problems.count == 2)
    #expect(result.primaryAction == .openCameraPrivacy)
  }

  @Test("camera fault inputs follow Studio's definition of a stopped camera")
  func cameraFault() {
    var snapshot = CameraAgentOnboardingSnapshot(
      serviceRegistration: .enabled, authorization: .observed(.authorized), control: .reachable,
      frame: .unknown, identity: .current, liveSnapshot: .accepted)
    #expect(!StatusCameraFault.hasFault(snapshot: snapshot, bootstrap: .ready, control: .reachable))
    #expect(
      StatusCameraFault.hasFault(
        snapshot: snapshot, bootstrap: .missingConfiguration, control: .reachable))
    #expect(StatusCameraFault.hasFault(snapshot: snapshot, bootstrap: .ready, control: .timedOut))
    snapshot.serviceRegistration = .requiresApproval
    #expect(StatusCameraFault.hasFault(snapshot: snapshot, bootstrap: .ready, control: .reachable))
  }
}
