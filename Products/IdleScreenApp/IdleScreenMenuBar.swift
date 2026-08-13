import AppKit
import SwiftUI

struct IdleScreenMenuBar: View {
    @Environment(IdleScreenAppModel.self) private var model

    var body: some View {
        Button("Start idlescreen") {
            model.startScreenSaver()
        }
        .keyboardShortcut("s")
        .disabled(model.isRegistering || model.isStartingScreenSaver || !model.isExtensionEmbedded)
        .onAppear {
            model.refresh()
        }

        Divider()

        Button("Open idlescreen…") {
            (NSApp.delegate as? IdleScreenAppDelegate)?.showStudio()
        }

        Button("Screen Saver Settings…") {
            model.openScreenSaverSettings()
        }

        Button("Open Diagnostics…") {
            (NSApp.delegate as? IdleScreenAppDelegate)?.showDiagnostics()
        }

        Divider()

        if model.isRefreshing {
            Label("Checking idlescreen…", systemImage: "arrow.clockwise")
        } else if isReady {
            Label("idlescreen Is Ready", systemImage: "checkmark.circle.fill")
        } else {
            Button(registrationActionTitle) {
                model.registerExtension()
            }
            .disabled(
                model.isRegistering
                    || model.isStartingScreenSaver
                    || !model.isExtensionEmbedded
            )
        }

        Divider()

        Button("Quit idlescreen") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var isReady: Bool {
        model.hasFreshSaverStatus
            && model.registrationAssessment.isCurrentBuild
            && model.selection?.isSelectedEverywhere == true
    }

    private var registrationActionTitle: String {
        if model.registrationAssessment.isCurrentBuild {
            return "Choose idlescreen in Settings"
        }
        return switch model.registrationAssessment.location {
        case .currentBuild: "Choose idlescreen in Settings"
        case .differentCopy: "Repair Extension Registration"
        case .notRegistered: "Set Up idlescreen"
        }
    }
}
