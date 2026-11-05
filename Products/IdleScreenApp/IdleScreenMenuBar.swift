import AppKit
import SwiftUI

struct IdleScreenMenuBar: View {
  @Environment(IdleScreenAppModel.self) private var model

  var body: some View {
    Button("Start IdleScreen") {
      model.startScreenSaver()
    }
    .keyboardShortcut("s")
    .disabled(model.isRegistering || model.isStartingScreenSaver || !model.isExtensionEmbedded)
    .onAppear {
      model.refresh()
    }

    Divider()

    Button("Open IdleScreen…") {
      (NSApp.delegate as? IdleScreenAppDelegate)?.showStudio()
    }

    Button("Aquarium Window…") { IdleScreenAquariumPresentationHost.shared.showWindowed() }
    Button(
      IdleScreenAquariumController.shared.library.desktopEnabled
        ? "Stop Aquarium Desktop" : "Start Aquarium Desktop"
    ) {
      IdleScreenAquariumPresentationHost.shared.toggleDesktop()
    }

    Button("Screen Saver Settings…") {
      model.openScreenSaverSettings()
    }

    Button("Open Diagnostics…") {
      (NSApp.delegate as? IdleScreenAppDelegate)?.showDiagnostics()
    }

    Divider()

    if model.isRefreshing {
      Label("Checking IdleScreen…", systemImage: "arrow.clockwise")
    } else if isReady {
      Label("IdleScreen Is Ready", systemImage: "checkmark.circle.fill")
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

    Button("Quit IdleScreen") {
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
      return "Choose IdleScreen in Settings"
    }
    return switch model.registrationAssessment.location {
    case .currentBuild: "Choose IdleScreen in Settings"
    case .differentCopy: "Repair Extension Registration"
    case .notRegistered: "Set Up IdleScreen"
    }
  }
}
