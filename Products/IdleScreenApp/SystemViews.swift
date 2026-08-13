import AppKit
import IdleScreenCore
import IdleScreenCamera
import SwiftUI

@MainActor
struct SystemView: View {
    @Environment(IdleScreenAppModel.self) private var model
    @Environment(IdleScreenCompanionCameraClient.self) private var cameraClient

    @State private var processReportsAreExpanded = false

    private enum CameraCheckLayer: Equatable {
        case client
        case service
        case identity
        case snapshot
        case authorization
        case control
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                HStack(alignment: .top, spacing: 18) {
                    checkSection(title: "SCREEN SAVER") {
                        SystemCheckRow(
                            title: "Extension",
                            value: model.isExtensionEmbedded ? "Ready" : "Missing",
                            detail: model.embeddedExtensionVersion.map { "Version \($0)" }
                                ?? "No embedded extension was found",
                            tone: model.isExtensionEmbedded ? .green : .red
                        )
                        SystemCheckRow(
                            title: "Registration",
                            value: registrationValue,
                            detail: registrationDetail,
                            tone: registrationTone,
                            actionTitle: registrationRepairTitle,
                            action: registrationRepairAction
                        )
                        SystemCheckRow(
                            title: "macOS selection",
                            value: selectionValue,
                            detail: selectionDetail,
                            tone: selectionTone,
                            actionTitle: selectionRepairTitle,
                            action: selectionRepairAction
                        )
                        SystemCheckRow(
                            title: "Runtime",
                            value: model.compatibility.isCompatible ? "Compatible" : "Blocked",
                            detail: compatibilityDetail,
                            tone: model.compatibility.isCompatible ? .green : .red
                        )
                        SystemCheckRow(
                            title: "Shared state",
                            value: model.hasSharedContainer ? "Connected" : "Unavailable",
                            detail: model.appGroupIdentifier ?? "No App Group identifier",
                            tone: model.hasSharedContainer ? .green : .orange
                        )
                    }

                    checkSection(title: "CAMERA", trailing: AnyView(cameraCheckButton)) {
                        SystemCheckRow(
                            title: "Camera client",
                            value: cameraClientValue,
                            detail: cameraClientDetail,
                            tone: cameraClientTone,
                            actionTitle: cameraRepairTitle(for: .client),
                            action: cameraRepairAction(for: .client)
                        )
                        SystemCheckRow(
                            title: "Camera agent",
                            value: cameraServiceValue,
                            detail: cameraServiceDetail,
                            tone: cameraServiceTone,
                            actionTitle: cameraRepairTitle(for: .service),
                            action: cameraRepairAction(for: .service)
                        )
                        SystemCheckRow(
                            title: "Identity",
                            value: identityValue,
                            detail: identityDetail,
                            tone: identityTone,
                            actionTitle: cameraRepairTitle(for: .identity),
                            action: cameraRepairAction(for: .identity)
                        )
                        SystemCheckRow(
                            title: "Live snapshot",
                            value: liveSnapshotValue,
                            detail: liveSnapshotDetail,
                            tone: liveSnapshotTone,
                            actionTitle: cameraRepairTitle(for: .snapshot),
                            action: cameraRepairAction(for: .snapshot)
                        )
                        SystemCheckRow(
                            title: "Camera access",
                            value: authorizationValue,
                            detail: authorizationDetail,
                            tone: authorizationTone,
                            actionTitle: cameraRepairTitle(for: .authorization),
                            action: cameraRepairAction(for: .authorization)
                        )
                        SystemCheckRow(
                            title: "Control channel",
                            value: controlValue,
                            detail: controlDetail,
                            tone: controlTone,
                            actionTitle: cameraRepairTitle(for: .control),
                            action: cameraRepairAction(for: .control)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                processReports

                if let lastError = model.lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(32)
        }
        .background(systemBackground)
        .onAppear {
            model.refresh()
            cameraClient.cameraDiagnosticsDidAppear()
        }
        .onDisappear {
            cameraClient.cameraDiagnosticsDidDisappear()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("System")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Spacer()
            SystemSummaryPill(
                title: saverIsReady ? "Saver ready" : "Saver needs setup",
                tone: saverIsReady ? .green : .orange
            )
            SystemSummaryPill(title: cameraSummaryTitle, tone: cameraSummaryTone)
        }
    }

    private func checkSection<Content: View>(
        title: String,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            .frame(minHeight: 36)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var cameraCheckButton: some View {
        HStack(spacing: 8) {
            Button("Camera Privacy…") {
                cameraClient.openCameraPrivacySettings()
            }
            .buttonStyle(.bordered)

            Button {
                cameraClient.retryCameraDiagnostics()
            } label: {
                if cameraDiagnosticsAreLoading {
                    Label("Checking…", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Run checks", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(
                cameraDiagnosticsAreLoading
                    || cameraClient.cameraAgentRepairState.isInProgress
            )
        }
        .controlSize(.small)
    }

    private var processReports: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        processReportsAreExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: processReportsAreExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                        Text("Process reports").font(.headline)
                        Text(processReportSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button("Refresh") { model.refresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isRefreshing)
            }
            .padding(.vertical, 12)

            if processReportsAreExpanded {
                Divider()
                if model.processHealth.isEmpty {
                    Text("No shared reports yet. Signed builds publish companion, saver, and camera-agent lifecycle reports here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 14)
                } else {
                    ForEach(model.processHealth, id: \.reportIdentifier) { report in
                        ProcessHealthRow(
                            report: report,
                            isLive: model.isProcessReportLive(report)
                        )
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent("App", value: Bundle.main.bundleIdentifier ?? "Unknown")
                    LabeledContent("Extension", value: model.embeddedExtensionBundleIdentifier ?? "Missing")
                    LabeledContent("Configuration revision", value: String(model.configuration.revision))
                    LabeledContent("Schema", value: String(model.configuration.schemaVersion))
                }
                .font(.caption)
                .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var saverIsReady: Bool {
        model.isExtensionEmbedded && registrationIsCurrent && selectionIsCurrent
    }

    private var registrationIsCurrent: Bool {
        model.registrationAssessment.isCurrentBuild
    }

    private var selectionIsCurrent: Bool {
        model.selection?.isSelectedEverywhere == true
    }

    private var registrationValue: String {
        switch model.registrationAssessment.location {
        case .currentBuild: "Current build"
        case .differentCopy: "Different copy"
        case .notRegistered: "Not registered"
        }
    }

    private var registrationDetail: String {
        switch model.registrationAssessment.location {
        case .currentBuild:
            "This app's embedded extension is registered"
        case .differentCopy:
            model.registrationAssessment.isSelectedBuild
                ? "The current build is selected, but stale copies are also registered"
                : "macOS points to \(model.registration.path ?? "another copy")"
        case .notRegistered:
            "macOS has no idlescreen registration"
        }
    }

    private var registrationTone: Color {
        registrationIsCurrent ? .green : .orange
    }

    private var registrationRepairTitle: String? {
        if registrationIsCurrent { return "Repair Screen Saver" }
        return model.registrationAssessment.location == .differentCopy
            ? "Repair"
            : "Set Up"
    }

    private var registrationRepairAction: (() -> Void)? {
        guard registrationRepairTitle != nil else { return nil }
        return registrationIsCurrent
            ? { model.forceRepairExtension() }
            : { model.registerExtension() }
    }

    private var selectionValue: String {
        guard let selection = model.selection else { return "Unknown" }
        if selection.isSelectedEverywhere { return "idlescreen" }
        if selection.isSelectedAnywhere { return "Mixed" }
        return "Another saver"
    }

    private var selectionDetail: String {
        guard let selection = model.selection else {
            return "The current macOS selection could not be read"
        }
        return selection.providers.isEmpty
            ? "No provider is recorded in the wallpaper store"
            : selection.providers.joined(separator: ", ")
    }

    private var selectionTone: Color {
        guard let selection = model.selection else { return .secondary }
        if selection.isSelectedEverywhere { return .green }
        if selection.isSelectedAnywhere { return .orange }
        return .secondary
    }

    private var selectionRepairTitle: String? {
        selectionIsCurrent ? nil : "Screen Saver Settings…"
    }

    private var selectionRepairAction: (() -> Void)? {
        guard selectionRepairTitle != nil else { return nil }
        return { model.openScreenSaverSettings() }
    }

    private var compatibilityDetail: String {
        let missingSymbols = model.compatibility.missingClassNames
            + model.compatibility.missingSelectorNames
        return missingSymbols.isEmpty
            ? "Modern host classes and selectors are loaded"
            : missingSymbols.joined(separator: ", ")
    }

    private var cameraSummaryTitle: String {
        if cameraIsAvailable { return "Camera available" }
        if cameraDiagnosticsAreLoading { return "Camera checking" }
        if cameraClient.readinessSnapshot.serviceRegistration == .unknown {
            return "Camera checks pending"
        }
        return "Camera needs attention"
    }

    private var cameraSummaryTone: Color {
        if cameraIsAvailable { return .green }
        if cameraDiagnosticsAreLoading
            || cameraClient.readinessSnapshot.serviceRegistration == .unknown {
            return .secondary
        }
        return .orange
    }

    private var cameraIsAvailable: Bool {
        cameraClient.bootstrapStatus == .ready
            && cameraClient.readinessSnapshot.serviceRegistration == .enabled
            && cameraClient.readinessSnapshot.identity == .current
            && cameraClient.readinessSnapshot.liveSnapshot == .accepted
            && cameraClient.readinessSnapshot.authorization == .observed(.authorized)
            && cameraClient.controlReachability == .reachable
    }

    private var cameraDiagnosticsAreLoading: Bool {
        if case .loading = cameraClient.cameraAgentDiagnosticState { return true }
        return false
    }

    private var cameraClientValue: String {
        guard let status = cameraClient.bootstrapStatus else { return "Checking" }
        return switch status {
        case .ready: "Ready"
        case .missingConfiguration: "Configuration missing"
        case .invalidConfiguration: "Configuration invalid"
        case .appGroupContainerUnavailable: "Shared state unavailable"
        }
    }

    private var cameraClientDetail: String {
        guard let status = cameraClient.bootstrapStatus else {
            return "Camera runtime has not finished loading"
        }
        return switch status {
        case .ready: "The companion camera runtime is ready"
        case .missingConfiguration: "Camera client configuration is missing"
        case .invalidConfiguration: "Camera client configuration is invalid"
        case .appGroupContainerUnavailable: "The signed App Group container is unavailable"
        }
    }

    private var cameraClientTone: Color {
        guard let status = cameraClient.bootstrapStatus else { return .secondary }
        return status == .ready ? .green : .red
    }

    private var cameraServiceValue: String {
        switch cameraClient.readinessSnapshot.serviceRegistration {
        case .unknown: "Not checked"
        case .notRegistered: "Not enabled"
        case .enabled: "Enabled"
        case .requiresApproval: "Needs approval"
        case .notFound: "Missing"
        case .failed: "Failed"
        }
    }

    private var cameraServiceDetail: String {
        switch cameraClient.readinessSnapshot.serviceRegistration {
        case .unknown: "Service status has not been read"
        case .notRegistered: "The camera agent is inactive"
        case .enabled: "The per-user camera agent is enabled"
        case .requiresApproval: "Allow the camera agent in Login Items"
        case .notFound: "The embedded camera agent is unavailable"
        case .failed: "Service Management could not read the camera agent"
        }
    }

    private var cameraServiceTone: Color {
        cameraClient.readinessSnapshot.serviceRegistration == .enabled ? .green : .orange
    }

    private var identityValue: String {
        switch cameraClient.cameraAgentRepairState {
        case .replacing: return "Replacing"
        case .verifying: return "Verifying"
        case let .verified(bundleVersion, _, _)
            where cameraClient.readinessSnapshot.identity == .current:
            return "Current · build \(bundleVersion)"
        case .idle, .verified, .failed: break
        }
        return switch cameraClient.readinessSnapshot.identity {
        case .unknown: "Not verified"
        case .absent: "Absent"
        case .stale: "Stale"
        case .mismatched: "Mismatch"
        case .current: "Current"
        }
    }

    private var identityDetail: String {
        switch cameraClient.cameraAgentRepairState {
        case .replacing:
            return "Stopping the stale helper and registering this app's copy"
        case .verifying:
            return "Checking signed bytes, source path, and live process"
        case let .verified(_, sourceAppPath, processIdentifier)
            where cameraClient.readinessSnapshot.identity == .current:
            return "Running from \(sourceAppPath) · PID \(processIdentifier)"
        case let .failed(message):
            return "Repair failed: \(message)"
        case .idle, .verified:
            break
        }
        return switch cameraClient.readinessSnapshot.identity {
        case .unknown: "Awaiting complete identity evidence"
        case .absent: "Embedded or registered helper evidence is absent"
        case .stale: "Enabled bytes, version, or path do not match this app"
        case .mismatched: "Signed identity or evidence validation failed"
        case .current: "Embedded, enabled, and running helper identities match"
        }
    }

    private var identityTone: Color {
        switch cameraClient.readinessSnapshot.identity {
        case .current: .green
        case .mismatched: .red
        case .absent, .stale: .orange
        case .unknown: .secondary
        }
    }

    private var liveSnapshotValue: String {
        switch cameraClient.readinessSnapshot.liveSnapshot {
        case .unknown: "Not checked"
        case .unavailable: "Unavailable"
        case .rejected: "Rejected"
        case .accepted: "Accepted"
        }
    }

    private var liveSnapshotDetail: String {
        switch cameraClient.cameraAgentDiagnosticState {
        case .notRequested: return "No authenticated snapshot has been requested"
        case .loading: return "Requesting an authenticated agent snapshot"
        case let .live(snapshot):
            let capture = snapshot.captureActive ? "capture active" : "capture idle"
            let leases = snapshot.activeLeaseCount == 1
                ? "1 active lease"
                : "\(snapshot.activeLeaseCount) active leases"
            return "Authenticated · \(snapshot.summary) · \(capture) · \(leases) · stream epoch \(snapshot.producerStreamEpoch)"
        case .unavailable(.serviceRegistration): return "Camera agent service is not enabled"
        case .unavailable(.clientRuntime): return "The companion camera runtime is unavailable"
        case .unavailable(.control): return "Authenticated camera-agent control is unavailable"
        case .unavailable(.rejected): return "The diagnostic reply was rejected"
        }
    }

    private var liveSnapshotTone: Color {
        switch cameraClient.readinessSnapshot.liveSnapshot {
        case .accepted: .green
        case .rejected: .red
        case .unavailable: .orange
        case .unknown: .secondary
        }
    }

    private var authorizationValue: String {
        switch cameraClient.readinessSnapshot.authorization {
        case .unknown: "Not checked"
        case .observed(.notDetermined): "Not requested"
        case .observed(.authorized): "Authorized"
        case .observed(.denied): "Denied"
        case .observed(.restricted): "Restricted"
        }
    }

    private var authorizationDetail: String {
        switch cameraClient.readinessSnapshot.authorization {
        case .unknown: "A nonprompting status check runs while System is visible"
        case .observed(.notDetermined): "Camera access requires your explicit action"
        case .observed(.authorized): "The current camera agent reports authorization"
        case .observed(.denied): "Camera access is off in Privacy & Security"
        case .observed(.restricted): "System policy restricts camera access"
        }
    }

    private var authorizationTone: Color {
        cameraClient.readinessSnapshot.authorization == .observed(.authorized)
            ? .green
            : .orange
    }

    private var controlValue: String {
        switch cameraClient.controlReachability {
        case .unknown: "Not connected"
        case .reachable: "Reachable"
        case .unreachable: "Unavailable"
        case .timedOut: "Timed out"
        }
    }

    private var controlDetail: String {
        switch cameraClient.controlReachability {
        case .unknown: "No current bounded control request"
        case .reachable: "The signed XPC control channel replied"
        case .unreachable: "The transport or signed camera agent is unavailable"
        case .timedOut: "The control request exceeded its deadline"
        }
    }

    private var controlTone: Color {
        cameraClient.controlReachability == .reachable ? .green : .orange
    }

    private func cameraRepairTitle(for layer: CameraCheckLayer) -> String? {
        guard !cameraDiagnosticsAreLoading,
              !cameraClient.cameraAgentRepairState.isInProgress else {
            return nil
        }
        if layer == .snapshot,
           cameraClient.readinessSnapshot.identity == .current,
           cameraClient.readinessSnapshot.liveSnapshot != .accepted {
            return "Retry"
        }
        guard repairBelongs(to: layer) else { return nil }
        if layer == .identity && cameraClient.isCameraAgentReplacementRecommended {
            return "Replace"
        }
        return switch cameraClient.recommendedRepair {
        case .refresh(.clientRuntime): "Retry"
        case .registerAgent: "Enable"
        case .requestCameraAuthorization: "Allow"
        case .refresh(.serviceRegistration): "Refresh"
        case .refresh(.identity): "Verify"
        case .refresh(.liveSnapshot): "Retry"
        case .refresh(.authorization): "Check"
        case .refresh(.control): "Retry"
        case .refresh(.frameReadiness): nil
        case .openRepairSurface(.backgroundItemsSettings): "Open Login Items"
        case .openRepairSurface(.cameraPrivacySettings): "Open Privacy"
        case .openRepairSurface(.cameraAgentDiagnostics): "Repair"
        case nil: nil
        }
    }

    private func cameraRepairAction(for layer: CameraCheckLayer) -> (() -> Void)? {
        guard cameraRepairTitle(for: layer) != nil else { return nil }
        if layer == .snapshot,
           cameraClient.readinessSnapshot.identity == .current,
           cameraClient.readinessSnapshot.liveSnapshot != .accepted {
            return { cameraClient.retryCameraDiagnostics() }
        }
        return { cameraClient.performRecommendedRepair() }
    }

    private func repairBelongs(to layer: CameraCheckLayer) -> Bool {
        if layer == .identity && cameraClient.isCameraAgentReplacementRecommended {
            return true
        }
        return switch cameraClient.recommendedRepair {
        case .refresh(.clientRuntime): layer == .client
        case .registerAgent,
             .refresh(.serviceRegistration),
             .openRepairSurface(.backgroundItemsSettings):
            layer == .service
        case .refresh(.identity): layer == .identity
        case .openRepairSurface(.cameraAgentDiagnostics):
            cameraClient.readinessSnapshot.identity == .current
                ? layer == .snapshot
                : layer == .identity
        case .refresh(.liveSnapshot): layer == .snapshot
        case .requestCameraAuthorization,
             .refresh(.authorization),
             .openRepairSurface(.cameraPrivacySettings):
            layer == .authorization
        case .refresh(.control): layer == .control
        case .refresh(.frameReadiness), nil: false
        }
    }

    private var processReportSummary: String {
        guard !model.processHealth.isEmpty else { return "No reports yet" }
        let liveCount = model.processHealth.filter(model.isProcessReportLive).count
        let newest = model.processHealth.map(\.updatedAt).max()
        let timestamp = newest?.formatted(date: .omitted, time: .standard) ?? ""
        return "\(liveCount) live · \(model.processHealth.count) reports · \(timestamp)"
    }
}

private struct SystemCheckRow: View {
    let title: String
    let value: String
    let detail: String
    let tone: Color
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(tone)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Divider().opacity(0.45)
        }
    }
}

private struct SystemSummaryPill: View {
    let title: String
    let tone: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tone)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct ProcessHealthRow: View {
    let report: IdleScreenProcessHealth
    let isLive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isLive ? (report.issue == nil ? Color.green : .orange) : .secondary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(processName).font(.headline)
                Text(report.build.bundleIdentifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let executionDetail {
                    Text(executionDetail).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(isLive ? report.lifecycle.rawValue.capitalized : "Exited")
                if let revision = report.configurationRevision {
                    Text("Config r\(revision)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(report.updatedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
    }

    private var processName: String {
        switch report.process {
        case .companionApp: "Companion app"
        case .screenSaverExtension: "Screen saver extension"
        case .cameraAgent: "Camera agent"
        }
    }

    private var executionDetail: String? {
        guard let processIdentifier = report.processIdentifier else { return nil }
        var components = ["PID \(processIdentifier)"]
        if let displayIdentifier = report.displayIdentifier {
            components.append("Display \(displayIdentifier)")
        }
        if let instanceIdentifier = report.instanceIdentifier {
            components.append("View \(instanceIdentifier.prefix(8))")
        }
        return components.joined(separator: " · ")
    }
}

private var systemBackground: some View {
    LinearGradient(
        colors: [Color(nsColor: .windowBackgroundColor), Color.orange.opacity(0.035), Color.black.opacity(0.18)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    .ignoresSafeArea()
}
