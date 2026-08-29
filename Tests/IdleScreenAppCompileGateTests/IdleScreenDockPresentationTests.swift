import AppKit
import Testing

@Suite("Dock presentation")
struct IdleScreenDockPresentationTests {
  @Test("an open main window earns a Dock tile")
  func mainWindowIsRegular() {
    #expect(
      IdleScreenDockPresentation.activationPolicy(showsMainWindow: true) == .regular
    )
  }

  @Test("no main window means menu bar only")
  func noMainWindowIsAccessory() {
    #expect(
      IdleScreenDockPresentation.activationPolicy(showsMainWindow: false) == .accessory
    )
  }

  @Test("the policy never resolves to prohibited, which would hide the menu bar item")
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
