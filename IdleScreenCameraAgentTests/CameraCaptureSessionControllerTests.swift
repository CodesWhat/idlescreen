import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import IdleScreenCameraAgentCore

@Suite("Camera capture session controller", .serialized)
struct CameraCaptureSessionControllerTests {
    @Test("background start never prompts when camera authorization is undetermined")
    func backgroundStartDoesNotPromptForAuthorization() {
        let authorization = FakeCameraCaptureAuthorization(status: .notDetermined)
        let discoverer = FakeCameraCaptureDeviceDiscoverer(devices: [])
        let factory = FakeCameraCaptureSessionFactory()
        let controller = CameraCaptureSessionController(
            authorizationChecker: authorization,
            deviceDiscoverer: discoverer,
            sessionFactory: factory,
            ownership: CameraCaptureOwnershipGate()
        )

        #expect(throws: CameraCaptureSessionControllerError.authorizationRequired(.notDetermined)) {
            try controller.start(
                CameraCaptureRequest(width: 640, height: 480),
                frameHandler: { _ in },
                eventHandler: { _ in }
            )
        }
        #expect(authorization.statusReadCount == 1)
        #expect(discoverer.discoveryCount == 0)
        #expect(factory.makeSessionCount == 0)
    }

    @Test("authorized start configures and starts one BGRA session in strict order")
    func configuresAndStartsBGRASession() throws {
        let builtIn = device("built-in", kind: .builtIn)
        let external = device("external", kind: .external)
        let session = FakeCameraCaptureSession()
        let harness = makeHarness(devices: [builtIn, external], session: session)

        let selected = try harness.controller.start(
            CameraCaptureRequest(width: 1_280, height: 720),
            frameHandler: { _ in },
            eventHandler: { _ in }
        )

        #expect(selected == external)
        #expect(session.calls == [
            .beginConfiguration,
            .setPreset(.hd1280x720),
            .addInput(deviceID: "external"),
            .addOutput(CameraCaptureVideoOutputConfiguration(
                pixelFormat: kCVPixelFormatType_32BGRA,
                alwaysDiscardsLateVideoFrames: true
            )),
            .commitConfiguration,
            .startObservingEvents,
            .startRunning
        ])
        #expect(harness.factory.makeSessionCount == 1)

        harness.controller.stop()
        #expect(session.calls.suffix(2) == [
            .stopObservingEvents,
            .stopRunning
        ])
    }

    @Test("the requested frame-rate ceiling reaches the AVFoundation output contract")
    func configuresMaximumFrameRate() throws {
        let session = FakeCameraCaptureSession()
        let harness = makeHarness(devices: [device("camera")], session: session)

        try harness.controller.start(
            CameraCaptureRequest(
                width: 1_280,
                height: 720,
                maximumFramesPerSecond: 24
            ),
            frameHandler: { _ in },
            eventHandler: { _ in }
        )

        #expect(session.calls.contains(.addOutput(
            CameraCaptureVideoOutputConfiguration(
                pixelFormat: kCVPixelFormatType_32BGRA,
                alwaysDiscardsLateVideoFrames: true,
                maximumFramesPerSecond: 24
            )
        )))
        harness.controller.stop()
    }

    @Test("a preferred connected camera wins before the external-camera default")
    func selectsPreferredCamera() throws {
        let preferred = device("preferred-built-in", kind: .builtIn)
        let harness = makeHarness(
            devices: [device("external", kind: .external), preferred],
            session: FakeCameraCaptureSession()
        )

        let selected = try harness.controller.start(
            CameraCaptureRequest(
                width: 640,
                height: 480,
                preferredDeviceID: preferred.uniqueID
            ),
            frameHandler: { _ in },
            eventHandler: { _ in }
        )

        #expect(selected == preferred)
        harness.controller.stop()
    }

    @Test("device selection is deterministic when only built-in cameras exist")
    func deterministicallySelectsBuiltInCamera() throws {
        let harness = makeHarness(
            devices: [
                device("z-camera", kind: .builtIn),
                device("a-camera", kind: .builtIn)
            ],
            session: FakeCameraCaptureSession()
        )

        let selected = try harness.controller.start(
            CameraCaptureRequest(width: 640, height: 480),
            frameHandler: { _ in },
            eventHandler: { _ in }
        )

        #expect(selected.uniqueID == "a-camera")
        harness.controller.stop()
    }

    @Test(arguments: [
        (0, 480),
        (640, 0),
        (-1, 480),
        (640, -1),
        (1_921, 1_080),
        (1_920, 1_081)
    ])
    func rejectsUnboundedDimensions(width: Int, height: Int) {
        let harness = makeHarness(devices: [device("camera")], session: FakeCameraCaptureSession())

        #expect(throws: CameraCaptureSessionControllerError.invalidDimensions(
            width: width,
            height: height
        )) {
            try harness.controller.start(
                CameraCaptureRequest(width: width, height: height),
                frameHandler: { _ in },
                eventHandler: { _ in }
            )
        }
        #expect(harness.authorization.statusReadCount == 0)
        #expect(harness.discoverer.discoveryCount == 0)
        #expect(harness.factory.makeSessionCount == 0)
    }

    @Test(arguments: [0, 61])
    func rejectsUnboundedFrameRates(maximumFramesPerSecond: Int) {
        let harness = makeHarness(devices: [device("camera")], session: FakeCameraCaptureSession())

        #expect(throws: CameraCaptureSessionControllerError.invalidFrameRate(
            maximumFramesPerSecond
        )) {
            try harness.controller.start(
                CameraCaptureRequest(
                    width: 640,
                    height: 480,
                    maximumFramesPerSecond: maximumFramesPerSecond
                ),
                frameHandler: { _ in },
                eventHandler: { _ in }
            )
        }
        #expect(harness.authorization.statusReadCount == 0)
        #expect(harness.factory.makeSessionCount == 0)
    }

    @Test("requests above 720p use the bounded 1080p preset")
    func choosesBounded1080pPreset() throws {
        let session = FakeCameraCaptureSession()
        let harness = makeHarness(devices: [device("camera")], session: session)

        try harness.controller.start(
            CameraCaptureRequest(width: 1_920, height: 1_080),
            frameHandler: { _ in },
            eventHandler: { _ in }
        )

        #expect(session.calls.contains(.setPreset(.hd1920x1080)))
        harness.controller.stop()
    }

    @Test("no connected camera fails before a capture session is constructed")
    func noConnectedCamera() {
        let harness = makeHarness(devices: [], session: FakeCameraCaptureSession())

        #expect(throws: CameraCaptureSessionControllerError.noVideoDevice) {
            try harness.controller.start(
                CameraCaptureRequest(width: 640, height: 480),
                frameHandler: { _ in },
                eventHandler: { _ in }
            )
        }
        #expect(harness.factory.makeSessionCount == 0)
    }

    @Test("the ownership gate prevents a second concurrent capture session")
    func preventsSecondConcurrentSession() throws {
        let ownership = CameraCaptureOwnershipGate()
        let first = makeHarness(
            devices: [device("camera")],
            session: FakeCameraCaptureSession(),
            ownership: ownership
        )
        let second = makeHarness(
            devices: [device("camera")],
            session: FakeCameraCaptureSession(),
            ownership: ownership
        )

        try first.controller.start(
            CameraCaptureRequest(width: 640, height: 480),
            frameHandler: { _ in },
            eventHandler: { _ in }
        )
        #expect(throws: CameraCaptureSessionControllerError.sessionAlreadyOwned) {
            try second.controller.start(
                CameraCaptureRequest(width: 640, height: 480),
                frameHandler: { _ in },
                eventHandler: { _ in }
            )
        }
        #expect(first.factory.makeSessionCount == 1)
        #expect(second.factory.makeSessionCount == 0)

        first.controller.stop()
        try second.controller.start(
            CameraCaptureRequest(width: 640, height: 480),
            frameHandler: { _ in },
            eventHandler: { _ in }
        )
        #expect(second.factory.makeSessionCount == 1)
        second.controller.stop()
    }

    @Test("repeated start and stop calls never create or stop a second session")
    func startAndStopAreIdempotent() throws {
        let session = FakeCameraCaptureSession()
        let harness = makeHarness(devices: [device("camera")], session: session)

        try harness.controller.start(
            CameraCaptureRequest(width: 640, height: 480),
            frameHandler: { _ in },
            eventHandler: { _ in }
        )
        #expect(throws: CameraCaptureSessionControllerError.alreadyRunning) {
            try harness.controller.start(
                CameraCaptureRequest(width: 640, height: 480),
                frameHandler: { _ in },
                eventHandler: { _ in }
            )
        }
        harness.controller.stop()
        harness.controller.stop()

        #expect(harness.factory.makeSessionCount == 1)
        #expect(session.calls.filter { $0 == .startRunning }.count == 1)
        #expect(session.calls.filter { $0 == .stopRunning }.count == 1)
    }

    @Test("configuration failure commits configuration and releases ownership")
    func failedConfigurationCleansUp() throws {
        let ownership = CameraCaptureOwnershipGate()
        let failedSession = FakeCameraCaptureSession(failure: .addOutput)
        let failed = makeHarness(
            devices: [device("camera")],
            session: failedSession,
            ownership: ownership
        )

        #expect(throws: CameraCaptureSessionControllerError.sessionConfigurationFailed(.videoOutput)) {
            try failed.controller.start(
                CameraCaptureRequest(width: 640, height: 480),
                frameHandler: { _ in },
                eventHandler: { _ in }
            )
        }
        #expect(failedSession.calls.last == .commitConfiguration)

        let replacement = makeHarness(
            devices: [device("replacement")],
            session: FakeCameraCaptureSession(),
            ownership: ownership
        )
        try replacement.controller.start(
            CameraCaptureRequest(width: 640, height: 480),
            frameHandler: { _ in },
            eventHandler: { _ in }
        )
        replacement.controller.stop()
    }

    @Test("device, interruption, and runtime-error hooks forward structured events only while active")
    func forwardsSessionEvents() throws {
        let session = FakeCameraCaptureSession()
        let sink = EventSink()
        let harness = makeHarness(devices: [device("camera")], session: session)
        let events: [CameraCaptureSessionEvent] = [
            .deviceConnected(device("new-external", kind: .external)),
            .deviceDisconnected(deviceID: "camera"),
            .interrupted(reasonCode: 4),
            .interruptionEnded,
            .runtimeError(domain: AVFoundationErrorDomain, code: -11_800)
        ]

        try harness.controller.start(
            CameraCaptureRequest(width: 640, height: 480),
            frameHandler: { _ in },
            eventHandler: { sink.append($0) }
        )
        events.forEach(session.emit)
        #expect(sink.events == events)

        harness.controller.stop()
        session.emit(.interruptionEnded)
        #expect(sink.events == events)
    }

    @Test("sample-buffer forwarding retains the original pixel-buffer reference and copies no pixels")
    func forwardsPixelBufferReferenceWithoutCopying() throws {
        let sample = try makeSampleBuffer(width: 4, height: 2, timestamp: CMTime(value: 7, timescale: 30))
        let originalPixelBuffer = try #require(CMSampleBufferGetImageBuffer(sample))
        let sink = FrameSink()
        let forwarder = AVFoundationCameraFrameForwarder { sink.append($0) }

        #expect(forwarder.forward(sampleBuffer: sample))

        let frame = try #require(sink.frame)
        #expect(frame.pixelBuffer === originalPixelBuffer)
        #expect(frame.metadata.sequence == 1)
        #expect(frame.metadata.width == 4)
        #expect(frame.metadata.height == 2)
        #expect(frame.metadata.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(frame.metadata.presentationTimeSeconds == 7.0 / 30.0)
    }

    @Test("sample buffers without an image buffer are ignored")
    func ignoresSampleBufferWithoutImageBuffer() throws {
        var sampleBuffer: CMSampleBuffer?
        #expect(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: nil,
            sampleCount: 0,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr)
        let sink = FrameSink()
        let forwarder = AVFoundationCameraFrameForwarder { sink.append($0) }

        #expect(!forwarder.forward(sampleBuffer: try #require(sampleBuffer)))
        #expect(sink.frame == nil)
    }

    private func device(
        _ id: String,
        kind: CameraCaptureDeviceKind = .builtIn
    ) -> CameraCaptureDeviceDescriptor {
        CameraCaptureDeviceDescriptor(uniqueID: id, name: id, kind: kind)
    }

    private func makeHarness(
        devices: [CameraCaptureDeviceDescriptor],
        session: FakeCameraCaptureSession,
        ownership: CameraCaptureOwnershipGate = CameraCaptureOwnershipGate()
    ) -> CaptureHarness {
        let authorization = FakeCameraCaptureAuthorization(status: .authorized)
        let discoverer = FakeCameraCaptureDeviceDiscoverer(devices: devices)
        let factory = FakeCameraCaptureSessionFactory(session: session)
        return CaptureHarness(
            controller: CameraCaptureSessionController(
                authorizationChecker: authorization,
                deviceDiscoverer: discoverer,
                sessionFactory: factory,
                ownership: ownership
            ),
            authorization: authorization,
            discoverer: discoverer,
            factory: factory
        )
    }

    private func makeSampleBuffer(
        width: Int,
        height: Int,
        timestamp: CMTime
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess)
        let imageBuffer = try #require(pixelBuffer)

        var formatDescription: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr)

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: try #require(formatDescription),
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr)
        return try #require(sampleBuffer)
    }
}

private struct CaptureHarness {
    let controller: CameraCaptureSessionController
    let authorization: FakeCameraCaptureAuthorization
    let discoverer: FakeCameraCaptureDeviceDiscoverer
    let factory: FakeCameraCaptureSessionFactory
}

private final class FakeCameraCaptureAuthorization: CameraCaptureAuthorizationChecking, @unchecked Sendable {
    let status: CameraCaptureAuthorization
    private(set) var statusReadCount = 0

    init(status: CameraCaptureAuthorization) {
        self.status = status
    }

    func authorizationStatus() -> CameraCaptureAuthorization {
        statusReadCount += 1
        return status
    }
}

private final class FakeCameraCaptureDeviceDiscoverer: CameraCaptureDeviceDiscovering, @unchecked Sendable {
    let devices: [CameraCaptureDeviceDescriptor]
    private(set) var discoveryCount = 0

    init(devices: [CameraCaptureDeviceDescriptor]) {
        self.devices = devices
    }

    func discoverVideoDevices() -> [CameraCaptureDeviceDescriptor] {
        discoveryCount += 1
        return devices
    }
}

private final class FakeCameraCaptureSessionFactory: CameraCaptureSessionMaking, @unchecked Sendable {
    let session: FakeCameraCaptureSession
    private(set) var makeSessionCount = 0

    init(session: FakeCameraCaptureSession = FakeCameraCaptureSession()) {
        self.session = session
    }

    func makeSession() -> any CameraCaptureSessionProtocol {
        makeSessionCount += 1
        return session
    }
}

private enum FakeSessionFailure {
    case addInput
    case addOutput
    case start
}

private enum FakeSessionError: Error {
    case injected
}

private enum FakeSessionCall: Equatable {
    case beginConfiguration
    case setPreset(CameraCaptureSessionPreset)
    case addInput(deviceID: String)
    case addOutput(CameraCaptureVideoOutputConfiguration)
    case commitConfiguration
    case startObservingEvents
    case startRunning
    case stopObservingEvents
    case stopRunning
}

private final class FakeCameraCaptureSession: CameraCaptureSessionProtocol, @unchecked Sendable {
    private(set) var calls: [FakeSessionCall] = []
    private let failure: FakeSessionFailure?
    private var eventHandler: (@Sendable (CameraCaptureSessionEvent) -> Void)?

    init(failure: FakeSessionFailure? = nil) {
        self.failure = failure
    }

    func beginConfiguration() {
        calls.append(.beginConfiguration)
    }

    func setSessionPreset(_ preset: CameraCaptureSessionPreset) throws {
        calls.append(.setPreset(preset))
    }

    func addVideoInput(deviceID: String) throws {
        calls.append(.addInput(deviceID: deviceID))
        if failure == .addInput { throw FakeSessionError.injected }
    }

    func addVideoDataOutput(
        configuration: CameraCaptureVideoOutputConfiguration,
        frameHandler: @escaping @Sendable (CameraCaptureFrame) -> Void
    ) throws {
        calls.append(.addOutput(configuration))
        if failure == .addOutput { throw FakeSessionError.injected }
    }

    func commitConfiguration() {
        calls.append(.commitConfiguration)
    }

    func startObservingEvents(
        _ handler: @escaping @Sendable (CameraCaptureSessionEvent) -> Void
    ) {
        calls.append(.startObservingEvents)
        eventHandler = handler
    }

    func stopObservingEvents() {
        calls.append(.stopObservingEvents)
        eventHandler = nil
    }

    func startRunning() throws {
        calls.append(.startRunning)
        if failure == .start { throw FakeSessionError.injected }
    }

    func stopRunning() {
        calls.append(.stopRunning)
    }

    func emit(_ event: CameraCaptureSessionEvent) {
        eventHandler?(event)
    }
}

private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CameraCaptureSessionEvent] = []

    var events: [CameraCaptureSessionEvent] {
        lock.withLock { storage }
    }

    func append(_ event: CameraCaptureSessionEvent) {
        lock.withLock { storage.append(event) }
    }
}

private final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: CameraCaptureFrame?

    var frame: CameraCaptureFrame? {
        lock.withLock { storage }
    }

    func append(_ frame: CameraCaptureFrame) {
        lock.withLock { storage = frame }
    }
}
