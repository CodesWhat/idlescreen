import Darwin
import Foundation

// Contents/Helpers/idlescreenctl is this shim. Hook commands installed in agent
// settings point at that path, but the tool itself needs a provisioning profile,
// which a bare Mach-O can't carry. It lives in Helpers/IdleScreenCtl.app and
// this shim replaces itself with it, keeping argv, stdin and the exit status.
// The shim has no entitlements, so AMFI has nothing to match against a profile.

private func nestedToolPath() -> String? {
  var size: UInt32 = 0
  _NSGetExecutablePath(nil, &size)
  var buffer = [CChar](repeating: 0, count: Int(size))
  guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
  return URL(fileURLWithPath: String(cString: buffer))
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()
    .appendingPathComponent("IdleScreenCtl.app/Contents/MacOS/idlescreenctl")
    .path
}

guard let target = nestedToolPath() else {
  FileHandle.standardError.write(Data("idlescreenctl: cannot locate itself\n".utf8))
  exit(71)
}

var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(target)]
for argument in CommandLine.arguments.dropFirst() {
  arguments.append(strdup(argument))
}
arguments.append(nil)
execv(target, &arguments)

FileHandle.standardError.write(
  Data("idlescreenctl: cannot launch \(target): \(String(cString: strerror(errno)))\n".utf8))
exit(71)
