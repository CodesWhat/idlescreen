import IdleScreenCamera
import Testing

@Suite("Setup session")
struct SetupSessionTests {
  private func inputs(
    registered: Bool = false, selected: Bool = false, camera: SetupCameraAccess = .unknown,
    skipped: Bool = false
  ) -> SetupInputs {
    SetupInputs(
      registrationCurrent: registered, selectedEverywhere: selected, cameraAccess: camera,
      cameraSkipped: skipped)
  }

  // MARK: Gate (resolve and upgrade auto-skip)

  @Test("nothing is decided before the first answer")
  func waitsForFirstAnswer() {
    let decision = SetupGate.decide(
      session: SetupSession(), hasFreshStatus: false, hasError: false, requiredStepsDone: false)
    #expect(
      decision
        == SetupGateDecision(showsFlow: false, evaluatesAutoSkip: false, finishesSetup: false))
  }

  @Test("a finished refresh with no fresh status and no error shows the flow, auto-skip unspent")
  func idleWithoutStatusShowsFlow() {
    var session = SetupSession()
    let decision = SetupGate.decide(
      session: session, hasFreshStatus: false, hasError: false, requiredStepsDone: false,
      isRefreshing: false)
    #expect(decision.showsFlow)
    #expect(!decision.evaluatesAutoSkip)
    #expect(!decision.finishesSetup)
    session.apply(decision)
    #expect(!session.autoSkipEvaluated)
  }

  @Test("a refresh in flight with no fresh status is still checking")
  func refreshingWithoutStatusIsChecking() {
    let decision = SetupGate.decide(
      session: SetupSession(), hasFreshStatus: false, hasError: false, requiredStepsDone: false,
      isRefreshing: true)
    #expect(
      decision
        == SetupGateDecision(showsFlow: false, evaluatesAutoSkip: false, finishesSetup: false))
  }

  @Test("a missing screen saver tells the user to reinstall and disables registering")
  func missingExtensionCard() {
    let progress = SetupProgress(inputs())
    let card = SetupCardModel(
      progress: progress, cameraAccess: .unknown, isRegistering: false, extensionMissing: true)
    #expect(
      card.detail == "This copy of IdleScreen is missing its screen saver. Reinstall IdleScreen.")
    #expect(!card.primaryEnabled)
    #expect(card.offersLater)
  }

  @Test("an upgrader with the required steps done finishes silently on the first fresh status")
  func upgradeAutoSkip() {
    let decision = SetupGate.decide(
      session: SetupSession(), hasFreshStatus: true, hasError: false, requiredStepsDone: true)
    #expect(decision.finishesSetup)
    #expect(decision.evaluatesAutoSkip)
    #expect(!decision.showsFlow)
  }

  @Test("a first run shows the flow and spends the auto-skip")
  func firstRunShowsFlow() {
    var session = SetupSession()
    let decision = SetupGate.decide(
      session: session, hasFreshStatus: true, hasError: false, requiredStepsDone: false)
    #expect(decision.showsFlow && decision.evaluatesAutoSkip && !decision.finishesSetup)
    session.apply(decision)
    #expect(session.autoSkipEvaluated)
  }

  @Test("a stale error shows the flow but does not consume the auto-skip")
  func staleErrorKeepsAutoSkip() {
    var session = SetupSession()
    let stale = SetupGate.decide(
      session: session, hasFreshStatus: false, hasError: true, requiredStepsDone: false)
    #expect(stale.showsFlow)
    #expect(!stale.evaluatesAutoSkip)
    session.apply(stale)
    #expect(!session.autoSkipEvaluated)

    let fresh = SetupGate.decide(
      session: session, hasFreshStatus: true, hasError: false, requiredStepsDone: true)
    #expect(fresh.finishesSetup)
  }

  @Test("once judged, required steps flipping to done never finish setup on their own")
  func neverFinishesAfterJudgement() {
    var session = SetupSession()
    session.apply(
      SetupGate.decide(
        session: session, hasFreshStatus: true, hasError: false, requiredStepsDone: false))
    let later = SetupGate.decide(
      session: session, hasFreshStatus: true, hasError: false, requiredStepsDone: true)
    #expect(!later.finishesSetup)
    #expect(later.showsFlow)
  }

  // MARK: Session transitions

  @Test("skipping the camera survives navigating away, because it lives in the session")
  func skipPersists() {
    var session = SetupSession()
    session.skipCamera()
    let rebuilt = session  // a rebuilt view reads the same session
    #expect(rebuilt.cameraSkipped)
  }

  @Test("set up later and continue setup toggle the deferral")
  func deferAndContinue() {
    var session = SetupSession()
    session.deferSetup()
    #expect(session.isDeferred)
    session.continueSetup()
    #expect(!session.isDeferred)
  }

  @Test("reopening from the camera card lands on the camera step and cannot auto-finish")
  func reopenFromCard() {
    var session = SetupSession()
    session.skipCamera()
    session.deferSetup()
    session.reopenFromCameraCard()
    #expect(!session.isDeferred)
    #expect(!session.cameraSkipped)
    #expect(session.autoSkipEvaluated)

    let ready = inputs(registered: true, selected: true, camera: .notDetermined)
    let progress = SetupProgress(
      SetupInputs.settled(live: ready, lastFresh: nil, isFresh: true))
    #expect(progress.current == .camera)
    let decision = SetupGate.decide(
      session: session, hasFreshStatus: true, hasError: false, requiredStepsDone: true)
    #expect(!decision.finishesSetup)
    #expect(decision.showsFlow)
  }

  @Test("only a fresh read is recorded")
  func recordsFreshOnly() {
    var session = SetupSession()
    session.record(live: inputs(registered: true), isFresh: false)
    #expect(session.lastFreshInputs == nil)
    session.record(live: inputs(registered: true), isFresh: true)
    #expect(session.lastFreshInputs?.registrationCurrent == true)
  }

  @Test("the Studio banner shows only while setup is open and required steps are not done")
  func banner() {
    #expect(SetupGate.showsStudioBanner(setupCompleted: false, requiredStepsDone: false))
    #expect(!SetupGate.showsStudioBanner(setupCompleted: true, requiredStepsDone: false))
    #expect(!SetupGate.showsStudioBanner(setupCompleted: false, requiredStepsDone: true))
  }

  // MARK: Stale versus fresh

  @Test("a stale read keeps the last fresh registration and selection")
  func staleHoldsSteps() {
    let lastFresh = inputs(registered: true, selected: true, camera: .authorized)
    let failed = inputs(registered: false, selected: false, camera: .notDetermined)
    let held = SetupInputs.settled(live: failed, lastFresh: lastFresh, isFresh: false)
    #expect(held.registrationCurrent && held.selectedEverywhere)
    #expect(held.cameraAccess == .notDetermined)  // camera is observed separately
    #expect(SetupProgress(held).current == .camera)
  }

  @Test("a fresh read regresses a done step")
  func freshRegresses() {
    let lastFresh = inputs(registered: true, selected: true)
    let live = inputs(registered: true, selected: false)
    let result = SetupInputs.settled(live: live, lastFresh: lastFresh, isFresh: true)
    #expect(!result.selectedEverywhere)
    #expect(SetupProgress(result).current == .choose)
  }

  @Test("with nothing fresh yet, live values pass through")
  func noHistory() {
    let live = inputs(registered: true)
    #expect(SetupInputs.settled(live: live, lastFresh: nil, isFresh: false) == live)
  }
}

@Suite("Camera card guidance")
struct CameraCardGuidanceTests {
  @Test("not determined asks for access")
  func notDetermined() {
    let card = CameraCardGuidance.make(
      authorization: .observed(.notDetermined), setupCompleted: true)
    #expect(card.title == "Allow camera access")
    #expect(card.action == .allowAccess)
    #expect(card.actionTitle == "Allow camera access")
  }

  @Test("denied opens camera privacy")
  func denied() {
    let card = CameraCardGuidance.make(authorization: .observed(.denied), setupCompleted: true)
    #expect(card.action == .openCameraPrivacy)
    #expect(card.actionTitle == "Open camera privacy")
  }

  @Test("restricted explains the policy and offers nothing futile, even before setup is done")
  func restricted() {
    for done in [true, false] {
      let card = CameraCardGuidance.make(
        authorization: .observed(.restricted), setupCompleted: done)
      #expect(card.action == .none)
      #expect(card.actionTitle == nil)
      #expect(card.detail.contains("policy"))
    }
  }

  @Test("a runtime fault with access granted or unknown opens Settings")
  func runtimeFault() {
    for authorization in [CameraAgentAuthorizationObservation.unknown, .observed(.authorized)] {
      let card = CameraCardGuidance.make(authorization: authorization, setupCompleted: true)
      #expect(card.title == "The camera isn't working")
      #expect(card.action == .openStatus)
      #expect(card.actionTitle == "Open Settings")
    }
  }

  @Test("an unknown camera before setup asks to finish setup without reporting a camera fault")
  func unknownBeforeSetup() {
    let card = CameraCardGuidance.make(authorization: .unknown, setupCompleted: false)
    #expect(card.title == "Finish camera setup")
    #expect(card.action == .openSetup)
  }

  @Test("before setup is finished, actionable states point back to setup")
  func beforeSetupCompleted() {
    for authorization in [
      CameraAgentAuthorizationObservation.unknown, .observed(.notDetermined), .observed(.denied),
    ] {
      let card = CameraCardGuidance.make(authorization: authorization, setupCompleted: false)
      #expect(card.action == .openSetup)
      #expect(card.actionTitle == "Open setup")
      #expect(card.detail == "Finish setup to turn the camera on.")
    }
  }
}
