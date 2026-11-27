import AppKit
import Foundation
import Testing

@testable import IdleScreenCameraAgentCore

@Suite("Camera agent system sources", .serialized)
struct CameraAgentSystemSourcesTests {
  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
  }

  private func wait(for condition: @autoclosure () -> Bool, seconds: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  @Test("the locator delegates to the system App Group lookup without creating the directory")
  func containerLocatorDelegatesToSystem() {
    let identifier = "group.com.idlescreen.tests.not-entitled"
    let url = FileManagerCameraAgentContainerLocator().containerURL(
      forAppGroupIdentifier: identifier)

    // Entitled processes get a container; others get nil or a path that is
    // not materialized. Either way the lookup itself must not create one.
    if let url {
      #expect(url.lastPathComponent == identifier)
      #expect(!FileManager.default.fileExists(atPath: url.path))
    }
  }

  @Test("the repeating scheduler fires until cancelled and then stops")
  func schedulerFiresAndCancels() async {
    let counter = Counter()
    let scheduler = DispatchCameraAgentRepeatingScheduler()

    let task = scheduler.scheduleRepeating(every: 0.02) { counter.increment() }
    #expect(await wait(for: counter.count >= 3))

    task.cancel()
    task.cancel()
    try? await Task.sleep(for: .milliseconds(100))
    let settled = counter.count
    try? await Task.sleep(for: .milliseconds(150))
    #expect(counter.count == settled)
  }

  @Test("the workspace source forwards sleep and wake until cancelled")
  func workspaceSleepWake() async {
    let sleeps = Counter()
    let wakes = Counter()
    let center = NSWorkspace.shared.notificationCenter
    let task = WorkspaceCameraAgentSleepWakeSource().start(
      sleepHandler: { sleeps.increment() },
      wakeHandler: { wakes.increment() }
    )

    center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
    center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
    center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
    #expect(sleeps.count == 1)
    #expect(wakes.count == 2)

    task.cancel()
    task.cancel()
    center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
    center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
    #expect(sleeps.count == 1)
    #expect(wakes.count == 2)
  }

  @Test("the termination source intercepts SIGTERM and restores the default on cancel")
  func terminationSignal() async {
    let terminations = Counter()
    let task = DispatchCameraAgentTerminationSignalSource().start {
      terminations.increment()
    }

    // The dispatch source installs its kevent asynchronously, and SIGTERM is
    // ignored until then, so keep signalling until the handler fires.
    let deadline = Date().addingTimeInterval(5)
    while terminations.count == 0 && Date() < deadline {
      kill(getpid(), SIGTERM)
      try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(terminations.count >= 1)

    task.cancel()
    var action = sigaction()
    sigaction(SIGTERM, nil, &action)
    #expect(unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == 0)  // SIG_DFL
    task.cancel()
  }
}
