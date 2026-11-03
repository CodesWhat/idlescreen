import Darwin
import Foundation
import IdleScreenCore

private enum WorkerError: Error {
  case usage
  case invalidIndex
  case posix(Int32)
}

private func writeReadyAndWait() throws {
  try FileHandle.standardOutput.write(contentsOf: Data([0x52]))
  guard try FileHandle.standardInput.read(upToCount: 1)?.count == 1 else {
    throw WorkerError.usage
  }
}

private func holdLock(at path: String) throws {
  let descriptor = Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else {
    throw WorkerError.posix(errno)
  }
  defer { Darwin.close(descriptor) }
  guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
    throw WorkerError.posix(errno)
  }
  defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
  try writeReadyAndWait()
}

private func applySignal(filePath: String, indexText: String) throws {
  guard let index = Int(indexText), index >= 0 else {
    throw WorkerError.invalidIndex
  }
  try writeReadyAndWait()
  let now = Date(timeIntervalSince1970: 1_786_295_958)
  let signal = try IdleScreenAgentSignal.validated(
    provider: index.isMultiple(of: 2) ? .codex : .claude,
    sessionID: "process-session-\(index)",
    eventID: "process-event-\(index)",
    state: .working,
    title: nil,
    message: nil,
    temporaryLookID: nil,
    priority: 0,
    createdAt: now,
    expiresAt: now.addingTimeInterval(120),
    acknowledgedAt: nil,
    nonce: "process-nonce-\(index)",
    validatedAt: now
  )
  let store = IdleScreenAgentSignalStore(fileURL: URL(fileURLWithPath: filePath))
  // Eight workers are released at once and queue behind each other's fsyncs,
  // so on a loaded machine the store's 250 ms fail-closed timeout can fire
  // for the last in line. A timeout means no lock was held and nothing was
  // written, so a caller retrying until a generous deadline is correct.
  let deadline = Date().addingTimeInterval(30)
  while true {
    do {
      _ = try store.apply(.set(signal), at: now)
      return
    } catch IdleScreenAgentSignalStore.StoreError.coordinationTimedOut
      where Date() < deadline
    {
      continue
    }
  }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  switch arguments.first {
  case "hold-lock" where arguments.count == 2:
    try holdLock(at: arguments[1])
  case "apply-set" where arguments.count == 3:
    try applySignal(filePath: arguments[1], indexText: arguments[2])
  default:
    throw WorkerError.usage
  }
} catch {
  exit(1)
}
