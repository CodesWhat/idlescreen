import Darwin
import Foundation

@main
struct ScreenSaverSelectionProbeCommand {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard (1...2).contains(arguments.count) else {
            writeError("Usage: ScreenSaverSelectionProbe bundle-identifier [Index.plist]")
            exit(64)
        }

        let indexURL = arguments.count == 2
            ? URL(fileURLWithPath: arguments[1])
            : ScreenSaverSelectionClient.defaultIndexURL

        do {
            let report = try ScreenSaverSelectionClient(
                expectedBundleIdentifier: arguments[0],
                indexURL: indexURL
            ).status()
            print("providers=\(report.providers.joined(separator: ","))")
            print("selectedEverywhere=\(report.isSelectedEverywhere)")
            exit(report.isSelectedEverywhere ? 0 : 1)
        } catch {
            writeError("selectionError=\(error.localizedDescription)")
            exit(2)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
