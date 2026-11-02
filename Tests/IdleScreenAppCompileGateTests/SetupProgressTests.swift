import Testing

@Suite("Setup progress")
struct SetupProgressTests {
  private func inputs(
    registered: Bool = false,
    selected: Bool = false,
    camera: SetupCameraAccess = .unknown,
    skipped: Bool = false
  ) -> SetupInputs {
    SetupInputs(
      registrationCurrent: registered,
      selectedEverywhere: selected,
      cameraAccess: camera,
      cameraSkipped: skipped
    )
  }

  private func statuses(_ progress: SetupProgress) -> [SetupStepStatus] {
    SetupStep.allCases.map(progress.status)
  }

  @Test("a fresh Mac starts at register with the rest waiting")
  func freshMac() {
    let progress = SetupProgress(inputs())
    #expect(progress.current == .register)
    #expect(statuses(progress) == [.current, .upcoming, .upcoming])
    #expect(!progress.isComplete)
    #expect(!progress.requiredStepsDone)
  }

  @Test("registering advances to choose")
  func registered() {
    let progress = SetupProgress(inputs(registered: true))
    #expect(progress.current == .choose)
    #expect(statuses(progress) == [.done, .current, .upcoming])
  }

  @Test("selecting the saver advances to the camera and the required steps are done")
  func selected() {
    let progress = SetupProgress(inputs(registered: true, selected: true, camera: .notDetermined))
    #expect(progress.current == .camera)
    #expect(statuses(progress) == [.done, .done, .current])
    #expect(progress.requiredStepsDone)
    #expect(!progress.isComplete)
  }

  @Test("a blocked camera keeps the camera step current")
  func blockedCamera() {
    let progress = SetupProgress(inputs(registered: true, selected: true, camera: .blocked))
    #expect(progress.current == .camera)
  }

  @Test("skipping the camera completes setup and shows it as skipped")
  func skippedCamera() {
    let progress = SetupProgress(inputs(registered: true, selected: true, skipped: true))
    #expect(progress.current == nil)
    #expect(progress.isComplete)
    #expect(statuses(progress) == [.done, .done, .skipped])
  }

  @Test("an allowed camera completes setup")
  func authorizedCamera() {
    let progress = SetupProgress(inputs(registered: true, selected: true, camera: .authorized))
    #expect(progress.isComplete)
    #expect(statuses(progress) == [.done, .done, .done])
  }

  @Test("an allowed camera wins over a skip")
  func authorizedBeatsSkip() {
    let progress = SetupProgress(
      inputs(registered: true, selected: true, camera: .authorized, skipped: true))
    #expect(progress.status(.camera) == .done)
  }

  @Test("a skipped camera does not hide an unfinished required step")
  func skipDoesNotHideRequired() {
    let progress = SetupProgress(inputs(registered: true, skipped: true))
    #expect(progress.current == .choose)
    #expect(statuses(progress) == [.done, .current, .skipped])
    #expect(!progress.isComplete)
  }

  @Test("a step that goes bad becomes current again, because nothing is stored")
  func registrationBreaks() {
    let progress = SetupProgress(inputs(registered: false, selected: true, camera: .authorized))
    #expect(progress.current == .register)
    #expect(statuses(progress) == [.current, .done, .done])
  }

  @Test("only the camera is optional")
  func optionalStep() {
    #expect(SetupStep.allCases.filter(\.isOptional) == [.camera])
  }
}
