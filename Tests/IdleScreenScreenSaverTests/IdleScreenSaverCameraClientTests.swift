import AppKit
@testable import IdleScreenCamera
import IdleScreenCore
import IdleScreenDisplay
import Testing

@Suite("Tahoe global screen saver activity diagnostics")
struct IdleScreenSaverGlobalHostActivityTests {
    @Test("global controller states stay diagnostic and fail closed on ambiguity")
    func classifiesRuntimeSnapshot() {
        #expect(
            IdleScreenSaverGlobalHostActivity.classify(
                controllerAvailable: false,
                isRunning: nil,
                isRunningInBackground: nil
            ) == .unavailable
        )
        #expect(
            IdleScreenSaverGlobalHostActivity.classify(
                controllerAvailable: true,
                isRunning: false,
                isRunningInBackground: false
            ) == .inactive
        )
        #expect(
            IdleScreenSaverGlobalHostActivity.classify(
                controllerAvailable: true,
                isRunning: true,
                isRunningInBackground: false
            ) == .runningForeground
        )
        #expect(
            IdleScreenSaverGlobalHostActivity.classify(
                controllerAvailable: true,
                isRunning: true,
                isRunningInBackground: true
            ) == .runningBackground
        )
        #expect(
            IdleScreenSaverGlobalHostActivity.classify(
                controllerAvailable: true,
                isRunning: false,
                isRunningInBackground: true
            ) == .inconsistent
        )
    }

    @Test("the global observation never becomes camera authority by itself")
    func observationIsNotCameraAuthority() {
        for activity in IdleScreenSaverGlobalHostActivity.allCases {
            #expect(
                !IdleScreenSaverCameraDemandPolicy.permitsCamera(
                    source: .camera,
                    hostContext: .unverifiedHostedSurface,
                    isPreviewHint: false
                ),
                "global activity \(activity.rawValue) must remain diagnostic-only"
            )
        }
    }

    @Test("the checked-in shipping decision rejects every hosted observation")
    func checkedInShippingDecisionFailsClosed() {
        for activity in IdleScreenSaverGlobalHostActivity.allCases {
            #expect(
                !IdleScreenSaverShippingCameraDemand.permitsCamera(
                    source: .camera,
                    hostActivity: activity,
                    isPreviewHint: false
                ),
                "generated fail-closed decision accepted \(activity.rawValue)"
            )
        }
    }

    @Test("a verified foreground policy maps only the trustworthy observation")
    func verifiedForegroundDecisionUsesHostObservation() {
        let digest = String(repeating: "a", count: 64)
        let decision = IdleScreenSaverActivationDecisionInput(
            policy: .trustworthyActivationCapability,
            c6DecisionSHA256: digest,
            c6EvidenceSetSHA256: digest,
            generatedFromVerifiedC6Decision: true
        )

        for activity in IdleScreenSaverGlobalHostActivity.allCases {
            #expect(
                IdleScreenSaverShippingCameraDemand.permitsCamera(
                    source: .camera,
                    hostActivity: activity,
                    isPreviewHint: false,
                    decision: decision
                ) == (activity == .runningForeground)
            )
        }
        #expect(
            !IdleScreenSaverShippingCameraDemand.permitsCamera(
                source: .camera,
                hostActivity: .runningForeground,
                isPreviewHint: true,
                decision: decision
            )
        )
    }
}

@Suite("Hosted camera receipt diagnostics")
struct IdleScreenSaverCameraDiagnosticPolicyTests {
    @Test("receipt diagnostics emit at most once per second")
    func rateLimit() {
        var policy = IdleScreenSaverCameraDiagnosticPolicy()
        let first = IdleScreenSaverCameraDiagnosticEvent.available(
            producerStreamEpoch: 3,
            sequence: 5
        )
        let next = IdleScreenSaverCameraDiagnosticEvent.available(
            producerStreamEpoch: 3,
            sequence: 6
        )

        #expect(policy.emission(for: first, at: 10) == first)
        #expect(policy.emission(for: next, at: 10.999) == nil)
        #expect(policy.emission(for: next, at: 11) == next)
        #expect(policy.emission(for: next, at: 12) == nil)
        #expect(
            IdleScreenSaverCameraDiagnosticEvent.fallbackUnavailable.logMessage
                == "Camera receipt state=fallback-unavailable"
        )
    }

    @Test("availability state transitions emit immediately inside the rolling interval")
    func stateTransitionsBypassRollingRateLimit() {
        var policy = IdleScreenSaverCameraDiagnosticPolicy()
        let initial = IdleScreenSaverCameraDiagnosticEvent.available(
            producerStreamEpoch: 3,
            sequence: 5
        )
        let recovered = IdleScreenSaverCameraDiagnosticEvent.available(
            producerStreamEpoch: 9,
            sequence: 1
        )
        let rolling = IdleScreenSaverCameraDiagnosticEvent.available(
            producerStreamEpoch: 9,
            sequence: 2
        )

        #expect(policy.emission(for: initial, at: 10) == initial)
        #expect(policy.emission(for: .fallbackUnavailable, at: 10.1) == .fallbackUnavailable)
        #expect(policy.emission(for: recovered, at: 10.2) == recovered)
        #expect(policy.emission(for: rolling, at: 10.9) == nil)
        #expect(policy.emission(for: rolling, at: 11.2) == rolling)
    }
}

@Suite("Hosted camera demand policy")
struct IdleScreenSaverCameraDemandPolicyTests {
    @Test("camera-backed sources require verified full-screen provenance")
    func requiresVerifiedFullScreenProvenance() {
        #expect(
            IdleScreenSaverCameraDemandPolicy.permitsCamera(
                source: .camera,
                hostContext: .explicitlyVerifiedFullScreen,
                isPreviewHint: false
            )
        )
        #expect(
            !IdleScreenSaverCameraDemandPolicy.permitsCamera(
                source: .generative,
                hostContext: .explicitlyVerifiedFullScreen,
                isPreviewHint: false
            )
        )
        #expect(
            !IdleScreenSaverCameraDemandPolicy.permitsCamera(
                source: .camera,
                hostContext: .unverifiedHostedSurface,
                isPreviewHint: false
            )
        )
        #expect(
            !IdleScreenSaverCameraDemandPolicy.permitsCamera(
                source: .camera,
                hostContext: .explicitlyVerifiedFullScreen,
                isPreviewHint: true
            )
        )
    }
}

@MainActor
@Suite("Hosted screen saver camera client")
struct IdleScreenSaverCameraClientTests {
    @Test("a quiet focus assignment never acquires an otherwise valid camera lease")
    func quietFocusSuppressesCameraDemand() throws {
        let recorder = CameraClientRecorder()
        let coordinator = DisplaySceneCoordinator(
            notificationCenter: NotificationCenter(),
            notificationName: .init("saver-quiet-focus"),
            readTopology: { try SaverDisplayFixtures.sideBySide() }
        )
        var configuration = configuration(source: .camera)
        configuration.display = .init(
            policy: .focusDisplay,
            focalDisplayIdentifier: .init(rawValue: "right"),
            quietTreatment: .black
        )
        let view = try #require(
            IdleScreenSaverView(
                frame: NSRect(x: 0, y: 0, width: 1_000, height: 800),
                isPreview: false,
                cameraClient: recorder.makeClient(),
                configuration: configuration,
                cameraHostContext: .explicitlyVerifiedFullScreen,
                displayCoordinator: coordinator,
                displayHostFrame: .init(
                    x: 0, y: 0, width: 1_000, height: 800
                )
            )
        )

        view.startAnimation()
        view.animateOneFrame()

        #expect(coordinator.activeHostCount == 1)
        #expect(view.diagnosticState.persistentDisplayIdentifier == "primary")
        #expect(view.diagnosticState.topologyGeneration == 1)
        #expect(view.diagnosticState.sceneRole == "quiet-black")
        #expect(view.diagnosticState.sceneBrightness == 0)
        #expect(recorder.attachedIdentifiers.isEmpty)
        #expect(recorder.sampleRequests.isEmpty)

        view.viewDidMoveToWindow()
        #expect(coordinator.activeHostCount == 0)
    }

    @Test("the default generative source never leases or samples camera")
    func generativeSourceDoesNotDemandCamera() throws {
        let recorder = CameraClientRecorder()
        let view = try #require(
            makeView(
                cameraClient: recorder.makeClient(),
                source: .generative
            )
        )

        view.startAnimation()
        view.animateOneFrame()
        view.stopAnimation()

        #expect(recorder.attachedIdentifiers.isEmpty)
        #expect(recorder.detachedIdentifiers.isEmpty)
        #expect(recorder.sampleRequests.isEmpty)
        #expect(view.diagnosticState.cameraProducerStreamEpoch == nil)
        #expect(view.diagnosticState.cameraFrameSequence == nil)
        #expect(view.diagnosticState.cameraFrameChecksum == nil)
    }

    @Test("a hosted preview hint never leases or samples camera")
    func previewHintDoesNotDemandCamera() throws {
        let recorder = CameraClientRecorder()
        let view = try #require(
            IdleScreenSaverView(
                frame: NSRect(x: 0, y: 0, width: 428, height: 260),
                isPreview: true,
                cameraClient: recorder.makeClient(),
                configuration: configuration(source: .camera),
                cameraHostContext: .explicitlyVerifiedFullScreen
            )
        )

        view.startAnimation()
        view.animateOneFrame()
        view.stopAnimation()

        #expect(recorder.attachedIdentifiers.isEmpty)
        #expect(recorder.detachedIdentifiers.isEmpty)
        #expect(recorder.sampleRequests.isEmpty)
    }

    @Test("full-display bounds and a false preview flag do not prove camera-safe activation")
    func unverifiedFullDisplayDoesNotDemandCamera() throws {
        let recorder = CameraClientRecorder()
        let view = try #require(
            IdleScreenSaverView(
                frame: NSRect(x: 0, y: 0, width: 3360, height: 1890),
                isPreview: false,
                cameraClient: recorder.makeClient(),
                configuration: configuration(source: .camera),
                cameraHostContext: .unverifiedHostedSurface
            )
        )

        view.startAnimation()
        view.animateOneFrame()
        view.stopAnimation()

        #expect(recorder.attachedIdentifiers.isEmpty)
        #expect(recorder.detachedIdentifiers.isEmpty)
        #expect(recorder.sampleRequests.isEmpty)
        #expect(view.diagnosticState.cameraFrameChecksum == nil)
    }

    @Test("the process bootstraps one inert runtime for every hosted view")
    func processBootstrapsOnce() throws {
        let recorder = CameraClientRecorder()
        let client = recorder.makeClient()
        var bootstrapCount = 0
        let process = IdleScreenSaverCameraProcess(
            infoDictionary: ["marker": "extension-info"],
            bootstrap: { infoDictionary in
                bootstrapCount += 1
                #expect(infoDictionary["marker"] as? String == "extension-info")
                return IdleScreenSaverCameraBootstrapOutcome(
                    status: .ready,
                    client: client
                )
            }
        )

        let first = try #require(makeView(cameraClient: process.client))
        let second = try #require(makeView(cameraClient: process.client))

        first.startAnimation()
        second.startAnimation()

        #expect(bootstrapCount == 1)
        #expect(Set(recorder.attachedIdentifiers).count == 2)
        #expect(recorder.attachedIdentifiers.count == 2)
    }

    @Test("a hosted view attaches only while animating and detaches idempotently")
    func animationOwnsConsumerAttachment() throws {
        let recorder = CameraClientRecorder()
        let view = try #require(makeView(cameraClient: recorder.makeClient()))

        view.startAnimation()
        view.startAnimation()
        #expect(recorder.attachedIdentifiers.count == 1)

        view.stopAnimation()
        view.stopAnimation()
        view.viewDidMoveToWindow()
        #expect(recorder.detachedIdentifiers == recorder.attachedIdentifiers)

        view.startAnimation()
        #expect(recorder.attachedIdentifiers.count == 2)
        #expect(recorder.attachedIdentifiers[0] == recorder.attachedIdentifiers[1])
    }

    @Test("deinitialization releases an attached hosted-view consumer")
    func deinitializationDetaches() {
        let recorder = CameraClientRecorder()
        var consumer: IdleScreenSaverCameraConsumer? =
            IdleScreenSaverCameraConsumer(
                client: recorder.makeClient(),
                identifier: "hosted-view"
            )
        consumer?.attach()
        consumer = nil

        #expect(recorder.attachedIdentifiers.count == 1)
        #expect(recorder.detachedIdentifiers == recorder.attachedIdentifiers)
    }

    @Test("a rejected lease never permits camera sampling")
    func rejectedAttachmentDoesNotSample() {
        let recorder = CameraClientRecorder(attachResult: false)
        let consumer = IdleScreenSaverCameraConsumer(
            client: recorder.makeClient(),
            identifier: "hosted-view"
        )

        consumer.attach()
        let read = consumer.sample(columns: 54, rows: 18)

        #expect(recorder.attachedIdentifiers == ["hosted-view"])
        #expect(recorder.sampleRequests.isEmpty)
        #expect(read == .unavailable)
    }

    @Test("missing configuration remains procedural without another bootstrap attempt")
    func missingConfigurationFailsClosed() throws {
        var bootstrapCount = 0
        let process = IdleScreenSaverCameraProcess(
            infoDictionary: [:],
            bootstrap: { _ in
                bootstrapCount += 1
                return IdleScreenSaverCameraBootstrapOutcome(
                    status: .missingConfiguration,
                    client: nil
                )
            }
        )
        let view = try #require(makeView(cameraClient: process.client))

        view.startAnimation()
        view.animateOneFrame()
        view.stopAnimation()
        view.startAnimation()
        view.animateOneFrame()

        #expect(process.status == .missingConfiguration)
        #expect(bootstrapCount == 1)
        #expect(view.diagnosticState.renderedGlyphField.isEmpty)
        #expect(view.diagnosticState.cameraFrameChecksum == nil)
    }

    @Test("animation consumes a scoped camera sample without retaining pixels")
    func animationConsumesScopedSample() throws {
        let expected = IdleScreenCameraGlyphSample(
            producerStreamEpoch: 7,
            sequence: 11,
            glyphField: "camera-glyphs",
            checksum: 42,
            sampledPixelCount: 1
        )
        let recorder = CameraClientRecorder(sample: expected)
        let view = try #require(makeView(cameraClient: recorder.makeClient()))

        view.startAnimation()
        view.animateOneFrame()

        #expect(recorder.sampleRequests.count == 1)
        #expect(recorder.sampleRequests.first?.columns == 54)
        #expect(recorder.sampleRequests.first?.rows == 18)
        #expect(view.diagnosticState.cameraProducerStreamEpoch == 7)
        #expect(view.diagnosticState.cameraFrameSequence == 11)
        #expect(view.diagnosticState.cameraFrameChecksum == 42)
        #expect(view.diagnosticState.cameraSampledPixelCount == 1)

        view.stopAnimation()
        view.animateOneFrame()

        #expect(view.diagnosticState.cameraProducerStreamEpoch == nil)
        #expect(view.diagnosticState.cameraFrameSequence == nil)
        #expect(view.diagnosticState.cameraFrameChecksum == nil)
        #expect(view.diagnosticState.cameraSampledPixelCount == nil)
    }

    @Test("a fresh sample survives no-new-frame and clears when unavailable")
    func noNewFrameDoesNotFlicker() throws {
        let sample = IdleScreenCameraGlyphSample(
            producerStreamEpoch: 8,
            sequence: 12,
            glyphField: "stable-camera-glyphs",
            checksum: 73,
            sampledPixelCount: 1
        )
        let recorder = CameraClientRecorder(sampleReads: [
            .frame(sample),
            .noNewFrame,
            .unavailable,
        ])
        let view = try #require(makeView(cameraClient: recorder.makeClient()))
        view.startAnimation()

        view.animateOneFrame()
        #expect(view.diagnosticState.cameraFrameChecksum == sample.checksum)

        view.animateOneFrame()
        #expect(view.diagnosticState.cameraFrameChecksum == sample.checksum)

        view.animateOneFrame()
        #expect(view.diagnosticState.cameraFrameChecksum == nil)
    }

    @Test("confirmed fallback clears the old sample and a fresh frame resumes")
    func fallbackThenFreshFrameRecovers() throws {
        let initial = IdleScreenCameraGlyphSample(
            producerStreamEpoch: 8,
            sequence: 12,
            glyphField: "old-camera-glyphs",
            checksum: 73,
            sampledPixelCount: 1
        )
        let recovered = IdleScreenCameraGlyphSample(
            producerStreamEpoch: 8,
            sequence: 13,
            glyphField: "recovered-camera-glyphs",
            checksum: 74,
            sampledPixelCount: 1
        )
        let recorder = CameraClientRecorder(sampleReads: [
            .frame(initial),
            .unavailable,
            .frame(recovered),
        ])
        let view = try #require(makeView(cameraClient: recorder.makeClient()))
        view.startAnimation()

        view.animateOneFrame()
        #expect(view.diagnosticState.cameraFrameChecksum == initial.checksum)

        view.animateOneFrame()
        #expect(view.diagnosticState.cameraFrameChecksum == nil)

        view.animateOneFrame()
        #expect(view.diagnosticState.cameraFrameChecksum == recovered.checksum)
        #expect(view.diagnosticState.cameraProducerStreamEpoch == 8)
        #expect(view.diagnosticState.cameraFrameSequence == 13)
        #expect(recorder.attachedIdentifiers.count == 1)
        #expect(recorder.detachedIdentifiers.isEmpty)
    }

    @Test("the hosted view emits bounded available and fallback receipt evidence")
    func hostedReceiptEvidence() throws {
        let sample = IdleScreenCameraGlyphSample(
            producerStreamEpoch: 21,
            sequence: 34,
            glyphField: "receipt-glyphs",
            checksum: 55,
            sampledPixelCount: 89
        )
        let recorder = CameraClientRecorder(sampleReads: [
            .frame(sample),
            .noNewFrame,
            .unavailable,
        ])
        var monotonicTime: TimeInterval = 100
        var receipts: [(String, UInt32?, IdleScreenSaverCameraDiagnosticEvent)] = []
        let view = try #require(
            IdleScreenSaverView(
                frame: NSRect(x: 0, y: 0, width: 640, height: 360),
                isPreview: false,
                cameraClient: recorder.makeClient(),
                configuration: configuration(source: .camera),
                cameraHostContext: .explicitlyVerifiedFullScreen,
                cameraDiagnosticClock: { monotonicTime },
                cameraDiagnosticSink: { instance, display, event in
                    receipts.append((instance, display, event))
                }
            )
        )
        view.startAnimation()

        view.animateOneFrame()
        monotonicTime = 101
        view.animateOneFrame()
        #expect(receipts.count == 1)
        #expect(receipts[0].0 == view.diagnosticState.instanceIdentifier)
        #expect(receipts[0].1 == view.diagnosticState.displayIdentifier)
        #expect(receipts[0].2 == sample.diagnosticEvent)

        monotonicTime = 102
        view.animateOneFrame()

        #expect(receipts.map { $0.2 } == [sample.diagnosticEvent, .fallbackUnavailable])
        #expect(view.diagnosticState.cameraFrameChecksum == nil)
    }

    @Test("host activity is refreshed for start but never enables unverified camera demand")
    func hostActivityRemainsDiagnostic() throws {
        let recorder = CameraClientRecorder()
        var now: CFTimeInterval = 10
        var observations: [IdleScreenSaverGlobalHostActivity] = [
            .inactive,
            .runningForeground,
            .runningBackground,
        ]
        let view = try #require(
            IdleScreenSaverView(
                frame: NSRect(x: 0, y: 0, width: 640, height: 360),
                isPreview: false,
                cameraClient: recorder.makeClient(),
                configuration: configuration(source: .camera),
                cameraHostContext: .unverifiedHostedSurface,
                hostActivityReader: {
                    observations.removeFirst()
                },
                hostActivityClock: { now }
            )
        )

        #expect(view.diagnosticState.globalHostActivity == .inactive)
        view.startAnimation()
        #expect(view.diagnosticState.globalHostActivity == .runningForeground)

        now = 10.499
        view.animateOneFrame()
        #expect(view.diagnosticState.globalHostActivity == .runningForeground)

        now = 10.5
        view.animateOneFrame()
        #expect(view.diagnosticState.globalHostActivity == .runningBackground)
        #expect(observations.isEmpty)
        #expect(recorder.attachedIdentifiers.isEmpty)
        #expect(recorder.sampleRequests.isEmpty)
    }

    private func makeView(
        cameraClient: IdleScreenSaverCameraClient?,
        source: IdleScreenSource = .camera,
        cameraHostContext: IdleScreenSaverCameraHostContext =
            .explicitlyVerifiedFullScreen
    ) -> IdleScreenSaverView? {
        IdleScreenSaverView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360),
            isPreview: false,
            cameraClient: cameraClient,
            configuration: configuration(source: source),
            cameraHostContext: cameraHostContext
        )
    }

    private func configuration(
        source: IdleScreenSource
    ) -> IdleScreenConfiguration {
        var configuration = IdleScreenConfiguration.default
        configuration.source = source
        return configuration
    }
}

private enum SaverDisplayFixtures {
    static func sideBySide() throws -> DisplayTopology {
        try DisplayTopology(displays: [
            display("primary", x: 0, isPrimary: true),
            display("right", x: 1_000),
        ])
    }

    static func display(
        _ identifier: String,
        x: Double,
        isPrimary: Bool = false
    ) -> DisplayTopology.Display {
        .init(
            persistentIdentifier: .init(rawValue: identifier),
            logicalFrame: .init(x: x, y: 0, width: 1_000, height: 800),
            nativePixelSize: .init(width: 2_000, height: 1_600),
            backingScale: 2,
            rotationDegrees: 0,
            refreshRateRange: nil,
            safeAreaInsets: .zero,
            isPrimary: isPrimary,
            mirrorTargetIdentifier: nil
        )
    }
}

@Suite("Runtime-backed saver camera frame pump", .serialized)
struct IdleScreenSaverCameraFramePumpTests {
    @Test("shared samples survive transient gaps and clear on lease loss")
    func cameraFramePumpLeaseLossAndTransientGap() throws {
        try withSaverPumpRuntime { harness in
            let initialMapping = SaverPumpFrameMapping(
                streamEpoch: 73,
                sequence: 1
            )
            harness.mappingFactory.enqueue(initialMapping)
            let runtime = try #require(harness.makeRuntime())
            let presentationClock = harness.presentationClock
            let pump = IdleScreenSaverCameraFramePump(
                runtime: runtime,
                monotonicClock: { presentationClock.now },
                automaticallyPolls: false
            )

            #expect(pump.attach(consumerIdentifier: "display-one"))
            #expect(pump.attach(consumerIdentifier: "display-two"))
            pump.synchronize()
            #expect(runtime.activeConsumerCount == 2)

            runtime.frameSource.receive(.available(.init(
                producerStreamEpoch: 73,
                transportIdentifier: "camera-frames-v1.mailbox"
            )))
            pump.pollOnce()
            let firstDisplay = pump.latestSample()
            let secondDisplay = pump.latestSample()
            #expect(firstDisplay == secondDisplay)
            #expect(firstDisplay.sequence == 1)

            initialMapping.failReads = true
            harness.frameClock.now = 0.01
            harness.presentationClock.now = 0.01
            pump.pollOnce()
            #expect(pump.latestSample().sequence == 1)

            let recoveredMapping = SaverPumpFrameMapping(
                streamEpoch: 73,
                sequence: 2
            )
            harness.mappingFactory.enqueue(recoveredMapping)
            harness.frameClock.now = 0.11
            harness.presentationClock.now = 0.11
            pump.pollOnce()
            #expect(pump.latestSample().sequence == 2)

            #expect(pump.detach(consumerIdentifier: "display-one"))
            pump.synchronize()
            #expect(runtime.activeConsumerCount == 1)
            #expect(pump.latestSample().sequence == 2)

            recoveredMapping.failReads = true
            harness.frameClock.now = 0.12
            harness.presentationClock.now = 0.12
            pump.pollOnce()
            #expect(pump.latestSample().sequence == 2)

            harness.frameClock.now = 0.13
            harness.presentationClock.now = 0.38
            pump.pollOnce()
            #expect(pump.latestSample() == .unavailable)

            let restoredMapping = SaverPumpFrameMapping(
                streamEpoch: 74,
                sequence: 1
            )
            harness.mappingFactory.enqueue(restoredMapping)
            harness.frameClock.now = 0.4
            harness.presentationClock.now = 0.4
            runtime.frameSource.receive(.available(.init(
                producerStreamEpoch: 74,
                transportIdentifier: "camera-frames-v1.mailbox"
            )))
            #expect(runtime.frameSource.availability == .waitingForFrame(epoch: 74))
            pump.pollOnce()
            #expect(runtime.frameSource.availability == .available(epoch: 74, sequence: 1))
            #expect(pump.latestSample().sequence == 1)

            harness.presentationClock.now = 0.41
            runtime.frameSource.receive(.unavailable)
            pump.pollOnce()
            #expect(pump.latestSample() == .unavailable)

            #expect(pump.detach(consumerIdentifier: "display-two"))
            pump.synchronize()
            #expect(runtime.activeConsumerCount == 0)
            #expect(pump.latestSample() == .noNewFrame)
        }
    }
}

@Suite("Bounded BGRA camera glyph sampler")
struct IdleScreenCameraGlyphSamplerTests {
    @Test("sampling is stride aware, deterministic, and bounded")
    func boundedStrideAwareSampling() throws {
        let descriptor = IdleScreenCameraFrameDescriptor(
            protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
            streamEpoch: 1,
            sequence: 1,
            timestamp: 1,
            width: 2,
            height: 2,
            bytesPerRow: 12,
            pixelFormat: .bgra8Unorm,
            slotIndex: 0,
            slotCount: 3
        )
        let pixels: [UInt8] = [
            0, 0, 0, 255, 255, 255, 255, 255, 91, 92, 93, 94,
            0, 0, 255, 255, 0, 255, 0, 255, 95, 96, 97, 98,
        ]

        let sample = pixels.withUnsafeBytes {
            IdleScreenCameraGlyphSampler.sample(
                descriptor: descriptor,
                pixels: $0,
                columns: 10_000,
                rows: 10_000
            )
        }

        let resolved = try #require(sample)
        #expect(resolved.producerStreamEpoch == descriptor.streamEpoch)
        #expect(resolved.sequence == descriptor.sequence)
        #expect(
            resolved.diagnosticEvent == .available(
                producerStreamEpoch: descriptor.streamEpoch,
                sequence: descriptor.sequence
            )
        )
        #expect(
            resolved.diagnosticEvent.logMessage
                == "Camera receipt state=available epoch=1 sequence=1"
        )
        #expect(!resolved.diagnosticEvent.logMessage.contains(String(resolved.checksum)))
        #expect(!resolved.diagnosticEvent.logMessage.contains(resolved.glyphField))
        #expect(
            !resolved.diagnosticEvent.logMessage.contains(
                "sampledPixels"
            )
        )
        #expect(resolved.sampledPixelCount == 54 * 18)
        #expect(resolved.glyphField.split(separator: "\n").count == 18)
        #expect(resolved.checksum == 1_866_234_548_541_714_342)
    }

    @Test("invalid or undersized frame storage is rejected")
    func rejectsUnsafeStorage() {
        let descriptor = IdleScreenCameraFrameDescriptor(
            protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
            streamEpoch: 1,
            sequence: 1,
            timestamp: 1,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixelFormat: .bgra8Unorm,
            slotIndex: 0,
            slotCount: 3
        )
        let pixels = [UInt8](repeating: 0, count: 15)

        let sample = pixels.withUnsafeBytes {
            IdleScreenCameraGlyphSampler.sample(
                descriptor: descriptor,
                pixels: $0,
                columns: 2,
                rows: 2
            )
        }

        #expect(sample == nil)
    }
}

private final class CameraClientRecorder {
    private(set) var attachedIdentifiers: [String] = []
    private(set) var detachedIdentifiers: [String] = []
    private(set) var sampleRequests: [(columns: Int, rows: Int)] = []
    private let attachResult: Bool
    private var sampleReads: [IdleScreenSaverCameraSampleRead]

    init(
        sample: IdleScreenCameraGlyphSample? = nil,
        attachResult: Bool = true
    ) {
        self.attachResult = attachResult
        sampleReads = [sample.map(IdleScreenSaverCameraSampleRead.frame) ?? .unavailable]
    }

    init(
        sampleReads: [IdleScreenSaverCameraSampleRead],
        attachResult: Bool = true
    ) {
        self.attachResult = attachResult
        self.sampleReads = sampleReads
    }

    func makeClient() -> IdleScreenSaverCameraClient {
        IdleScreenSaverCameraClient(
            attach: { [weak self] identifier in
                self?.attachedIdentifiers.append(identifier)
                return self?.attachResult ?? false
            },
            detach: { [weak self] identifier in
                self?.detachedIdentifiers.append(identifier)
                return true
            },
            sample: { [weak self] columns, rows in
                self?.sampleRequests.append((columns, rows))
                guard let self, !sampleReads.isEmpty else {
                    return .unavailable
                }
                return sampleReads.removeFirst()
            }
        )
    }
}

private extension IdleScreenSaverCameraSampleRead {
    var sequence: UInt64? {
        guard case let .frame(sample) = self else { return nil }
        return sample.sequence
    }
}

private func withSaverPumpRuntime<Result>(
    _ body: (SaverPumpRuntimeHarness) throws -> Result
) throws -> Result {
    let containerURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "idlescreen-saver-pump-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: containerURL,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: containerURL) }
    return try body(SaverPumpRuntimeHarness(containerURL: containerURL))
}

private final class SaverPumpRuntimeHarness {
    let containerURL: URL
    let scheduler = SaverPumpLeaseScheduler()
    let remote = SaverPumpCameraRemote()
    let mappingFactory = SaverPumpMappingFactory()
    let frameClock = SaverPumpClock()
    let presentationClock = SaverPumpClock()
    private lazy var connections = SaverPumpConnectionFactory(remote: remote)

    init(containerURL: URL) {
        self.containerURL = containerURL
    }

    func makeRuntime() -> CameraClientRuntime? {
        guard let configuration = CameraClientRuntimeConfiguration(
            appGroupIdentifier: CameraClientRuntimeConfiguration.releaseAppGroupIdentifier,
            machServiceName: CameraAgentXPCClientConfiguration.releaseMachServiceName,
            expectedTeamIdentifier: CameraClientRuntimeConfiguration.productionTeamIdentifier
        ) else {
            return nil
        }
        return CameraClientRuntime(
            configuration: configuration,
            appGroupContainerURL: containerURL,
            scheduler: scheduler,
            connectionFactory: connections.makeConnection,
            frameSourceClock: frameClock,
            mappingFactory: mappingFactory
        )
    }
}

private final class SaverPumpClock: CameraFrameSourceClock, @unchecked Sendable {
    var now: TimeInterval = 0
}

private final class SaverPumpMappingFactory:
    CameraFrameSourceMappingFactory,
    @unchecked Sendable
{
    private var mappings: [any CameraFrameSourceMapping] = []

    func enqueue(_ mapping: any CameraFrameSourceMapping) {
        mappings.append(mapping)
    }

    func makeMapping(contentsOf url: URL) throws -> any CameraFrameSourceMapping {
        _ = url
        return mappings.removeFirst()
    }
}

private final class SaverPumpFrameMapping:
    CameraFrameSourceMapping,
    @unchecked Sendable
{
    private enum MappingError: Error {
        case unavailable
    }

    let streamEpoch: UInt64
    let sequence: UInt64
    var failReads: Bool

    init(streamEpoch: UInt64, sequence: UInt64, failReads: Bool = false) {
        self.streamEpoch = streamEpoch
        self.sequence = sequence
        self.failReads = failReads
    }

    func withStableSnapshot<Result>(
        _ body: (
            IdleScreenCameraFrameDescriptor,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) throws -> Result? {
        guard !failReads else { throw MappingError.unavailable }
        let descriptor = IdleScreenCameraFrameDescriptor(
            protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
            streamEpoch: streamEpoch,
            sequence: sequence,
            timestamp: TimeInterval(sequence),
            width: 1,
            height: 1,
            bytesPerRow: 4,
            pixelFormat: .bgra8Unorm,
            slotIndex: 0,
            slotCount: 3
        )
        return try [UInt8(7), 3, 0, 255].withUnsafeBytes { pixels in
            try body(descriptor, pixels)
        }
    }
}

private final class SaverPumpConnectionFactory: @unchecked Sendable {
    private let remote: SaverPumpCameraRemote

    init(remote: SaverPumpCameraRemote) {
        self.remote = remote
    }

    func makeConnection(
        serviceName: String
    ) -> any CameraAgentXPCConnectionTransport {
        _ = serviceName
        return SaverPumpXPCTransport(remote: remote)
    }
}

private final class SaverPumpXPCTransport:
    CameraAgentXPCConnectionTransport,
    @unchecked Sendable
{
    var remoteObjectInterface: NSXPCInterface?
    var interruptionHandler: (() -> Void)?
    var invalidationHandler: (() -> Void)?
    private let remote: SaverPumpCameraRemote

    init(remote: SaverPumpCameraRemote) {
        self.remote = remote
    }

    func setCodeSigningRequirement(_ requirement: String) {
        _ = requirement
    }

    func activate() {}
    func invalidate() {}

    func remoteCameraProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> (any IdleScreenCameraXPCProtocol)? {
        _ = errorHandler
        return remote
    }
}

private final class SaverPumpCameraRemote:
    NSObject,
    IdleScreenCameraXPCProtocol,
    @unchecked Sendable
{
    func authorizationStatus(
        _ request: IdleScreenCameraStatusRequest,
        withReply reply: @escaping (IdleScreenCameraAuthorizationReply) -> Void
    ) {
        _ = request
        _ = reply
    }

    func requestAuthorization(
        _ request: IdleScreenCameraAuthorizationRequest,
        withReply reply: @escaping (IdleScreenCameraAuthorizationReply) -> Void
    ) {
        _ = request
        _ = reply
    }

    func diagnosticSnapshot(
        _ request: IdleScreenCameraDiagnosticRequest,
        withReply reply: @escaping (IdleScreenCameraDiagnosticSnapshot) -> Void
    ) {
        _ = request
        _ = reply
    }

    func cameraDeviceSnapshot(
        _ request: IdleScreenCameraStatusRequest,
        withReply reply: @escaping (IdleScreenCameraDeviceSnapshotReply) -> Void
    ) {
        _ = request
        _ = reply
    }

    func beginStream(
        _ request: IdleScreenCameraBeginStreamRequest,
        withReply reply: @escaping (IdleScreenCameraBeginStreamReply) -> Void
    ) {
        _ = request
        _ = reply
    }

    func heartbeat(
        _ request: IdleScreenCameraHeartbeatRequest,
        withReply reply: @escaping (IdleScreenCameraHeartbeatReply) -> Void
    ) {
        _ = request
        _ = reply
    }

    func endStream(
        _ request: IdleScreenCameraEndStreamRequest,
        withReply reply: @escaping (IdleScreenCameraEndStreamReply) -> Void
    ) {
        _ = request
        _ = reply
    }
}

private final class SaverPumpLeaseScheduler:
    CameraLeaseScheduling,
    @unchecked Sendable
{
    private final class Task: CameraLeaseScheduledTask, @unchecked Sendable {
        func cancel() {}
    }

    var now: TimeInterval = 0

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any CameraLeaseScheduledTask {
        _ = delay
        _ = operation
        return Task()
    }
}
