import AppKit
import IdleScreenCamera
import IdleScreenCore
import Testing

@MainActor
@Suite("Synthetic hosted topology gate")
struct IdleScreenSyntheticHostedGateViewControllerTests {
    @Test("idle accepted diagnostic is correlated to the connection PID")
    func preflightAcceptsOnlyCorrelatedIdleSnapshot() throws {
        let observation = try #require(
            IdleScreenSyntheticHostedGatePreflightProbe.assess(
                snapshot: diagnosticSnapshot(processIdentifier: 4_242),
                remoteProcessIdentifier: 4_242
            )
        )

        #expect(observation.helperProcessIdentifier == 4_242)
        #expect(observation.accepted)
        #expect(observation.activeLeaseCount == 0)
        #expect(!observation.captureActive)
        #expect(
            observation.logMessage
                == "Synthetic hosted gate preflight helper_pid=4242 accepted=true active_lease_count=0 capture_active=false"
        )
    }

    @Test("preflight rejects timeout, PID mismatch, and non-idle snapshots")
    func preflightFailsClosed() {
        #expect(
            IdleScreenSyntheticHostedGatePreflightProbe.assess(
                snapshot: nil,
                remoteProcessIdentifier: 4_242
            ) == nil
        )
        #expect(
            IdleScreenSyntheticHostedGatePreflightProbe.assess(
                snapshot: diagnosticSnapshot(processIdentifier: 4_242),
                remoteProcessIdentifier: 4_243
            ) == nil
        )
        #expect(
            IdleScreenSyntheticHostedGatePreflightProbe.assess(
                snapshot: diagnosticSnapshot(
                    processIdentifier: 4_242,
                    captureActive: false,
                    activeLeaseCount: 1,
                    producerStreamEpoch: 0
                ),
                remoteProcessIdentifier: 4_242
            ) == nil
        )
        #expect(
            IdleScreenSyntheticHostedGatePreflightProbe.assess(
                snapshot: diagnosticSnapshot(
                    processIdentifier: 4_242,
                    captureActive: true,
                    activeLeaseCount: 1,
                    producerStreamEpoch: 7
                ),
                remoteProcessIdentifier: 4_242
            ) == nil
        )
    }

    @Test("injected probe completes with assessed diagnostic evidence")
    func preflightProbeIsInjectable() async {
        let snapshot = diagnosticSnapshot(processIdentifier: 4_242)
        let probe = IdleScreenSyntheticHostedGatePreflightProbe { reply in
            reply(snapshot, 4_242, {})
        }

        let observation = await withCheckedContinuation { continuation in
            probe.run { observation in
                continuation.resume(returning: observation)
            }
        }

        #expect(observation?.helperProcessIdentifier == 4_242)
    }

    @Test("gate-only factory grants demand to a non-preview camera source")
    func gateFactoryInjectsVerifiedHostContext() throws {
        var attachedIdentifiers: [String] = []
        let client = IdleScreenSaverCameraClient(
            attach: { identifier in
                attachedIdentifiers.append(identifier)
                return true
            },
            detach: { _ in true },
            sample: { _, _ in .unavailable }
        )

        let view = try #require(
            IdleScreenSyntheticHostedGateViewFactory.make(
                frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                isPreview: false,
                cameraClient: client,
                configuration: cameraConfiguration(source: .camera)
            )
        )
        view.startAnimation()

        #expect(attachedIdentifiers.count == 1)
        view.stopAnimation()
    }

    @Test("gate-only factory preserves preview denial")
    func gateFactoryStillDeniesPreviewDemand() throws {
        var attachmentCount = 0
        let client = IdleScreenSaverCameraClient(
            attach: { _ in
                attachmentCount += 1
                return true
            },
            detach: { _ in true },
            sample: { _, _ in .unavailable }
        )

        let view = try #require(
            IdleScreenSyntheticHostedGateViewFactory.make(
                frame: NSRect(x: 0, y: 0, width: 428, height: 260),
                isPreview: true,
                cameraClient: client,
                configuration: cameraConfiguration(source: .camera)
            )
        )
        view.startAnimation()

        #expect(attachmentCount == 0)
        view.stopAnimation()
    }

    private func cameraConfiguration(source: IdleScreenSource) -> IdleScreenConfiguration {
        IdleScreenConfiguration(
            schemaVersion: 1,
            revision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            source: source,
            appearance: .init(
                glyphScale: 0.5,
                contrast: 0.5,
                palette: "Ember"
            )
        )
    }

    private func diagnosticSnapshot(
        processIdentifier: Int32,
        captureActive: Bool = false,
        activeLeaseCount: Int = 0,
        producerStreamEpoch: UInt64 = 0
    ) -> IdleScreenCameraDiagnosticSnapshot {
        let identity = IdleScreenCameraAgentIdentity(
            processIdentifier: processIdentifier,
            processIncarnationEpoch: 7,
            bundleIdentifier: "com.idlescreen.camera-agent",
            serviceIdentifier: "group.com.idlescreen.shared.camera-agent",
            bundleVersion: "1",
            marketingVersion: "0.1",
            signingIdentifier: "com.idlescreen.camera-agent",
            teamIdentifier: "3524374A2S",
            codeDirectoryHash: String(repeating: "a", count: 40),
            executableSHA256: String(repeating: "b", count: 64),
            launchAgentSHA256: String(repeating: "c", count: 64),
            provisioningProfileSHA256: String(repeating: "d", count: 64),
            sourceAppPath: "/Applications/idlescreen.app"
        )!
        return IdleScreenCameraDiagnosticSnapshot(
            accepted: true,
            errorCode: .none,
            errorMessage: nil,
            agentIdentity: identity,
            authorizationStatus: .authorized,
            captureActive: captureActive,
            activeLeaseCount: activeLeaseCount,
            producerStreamEpoch: producerStreamEpoch,
            summary: "fixture"
        )!
    }
}
