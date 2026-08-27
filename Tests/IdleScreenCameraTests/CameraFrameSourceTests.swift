import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Camera frame source", .serialized)
struct CameraFrameSourceTests {
    @Test("delivers one stable frame only inside the scoped callback")
    func deliversStableScopedFrame() throws {
        try withTemporaryContainer { containerURL in
            let clock = FrameSourceTestClock(now: 50_000)
            let mapping = ScriptedFrameSourceMapping([
                .frame(descriptor(epoch: 7, sequence: 1, timestamp: 0.001), [1, 2, 3, 4])
            ])
            let factory = ScriptedFrameSourceMappingFactory(mappings: [mapping])
            let source = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: clock,
                mappingFactory: factory
            )
            source.receive(.available(CameraAgentStreamDescriptor(
                producerStreamEpoch: 7,
                transportIdentifier: "camera-frames-v1.mailbox"
            )))

            let result = source.withFrame { observed, pixels in
                #expect(mapping.callbackIsActive)
                #expect(observed.streamEpoch == 7)
                #expect(observed.sequence == 1)
                #expect(Array(pixels) == [1, 2, 3, 4])
                return pixels.count
            }

            guard case let .frame(observed, byteCount) = result else {
                Issue.record("Expected one scoped frame, got \(result)")
                return
            }
            #expect(observed.streamEpoch == 7)
            #expect(observed.sequence == 1)
            #expect(byteCount == 4)
            #expect(!mapping.callbackIsActive)
            #expect(source.availability == .available(epoch: 7, sequence: 1))
            #expect(factory.requestedURLs == [
                containerURL.appendingPathComponent("camera-frames-v1.mailbox")
            ])
        }
    }

    @Test("duplicates are not redelivered and become stale by local arrival time")
    func duplicateAndLocalStaleCutoff() throws {
        try withTemporaryContainer { containerURL in
            let clock = FrameSourceTestClock(now: 100)
            let repeated = descriptor(epoch: 3, sequence: 4, timestamp: 9_000_000)
            let mapping = ScriptedFrameSourceMapping([
                .frame(repeated, [9, 8, 7, 6]),
                .frame(repeated, [9, 8, 7, 6]),
                .frame(repeated, [9, 8, 7, 6]),
                .frame(descriptor(epoch: 3, sequence: 5), [6, 7, 8, 9]),
            ])
            let source = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: clock,
                mappingFactory: ScriptedFrameSourceMappingFactory(mappings: [mapping])
            )
            source.receive(available(epoch: 3))
            var deliveryCount = 0

            _ = source.withFrame { _, _ in deliveryCount += 1 }
            clock.now = 100.5
            #expect(source.withFrame { _, _ in deliveryCount += 1 }.isNoNewFrame)
            #expect(deliveryCount == 1)

            clock.now = 101.001
            #expect(source.withFrame { _, _ in deliveryCount += 1 }.unavailableReason
                == .staleFrame(epoch: 3, sequence: 4))
            #expect(deliveryCount == 1)
            #expect(mapping.pixelReadCount == 1)
            #expect(source.availability == .unavailable(
                .staleFrame(epoch: 3, sequence: 4)
            ))

            clock.now = 101.1
            guard case let .frame(frame, pixels) = source.withFrame({ _, pixels in
                Array(pixels)
            }) else {
                Issue.record("Expected a fresh sequence after the duplicate")
                return
            }
            #expect(frame.sequence == 5)
            #expect(pixels == [6, 7, 8, 9])
            #expect(mapping.pixelReadCount == 2)
        }
    }

    @Test("out-of-order and wrong-epoch descriptors fail closed")
    func descriptorFencing() throws {
        try withTemporaryContainer { containerURL in
            let outOfOrderClock = FrameSourceTestClock(now: 10)
            let outOfOrderMapping = ScriptedFrameSourceMapping([
                .frame(descriptor(epoch: 5, sequence: 2), [1]),
                .frame(descriptor(epoch: 5, sequence: 1), [2]),
                .frame(descriptor(epoch: 5, sequence: 3), [3])
            ])
            let outOfOrderFactory = ScriptedFrameSourceMappingFactory(
                mappings: [outOfOrderMapping]
            )
            let outOfOrder = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: outOfOrderClock,
                mappingFactory: outOfOrderFactory
            )
            outOfOrder.receive(available(epoch: 5))
            _ = outOfOrder.withFrame { _, _ in () }
            #expect(outOfOrder.withFrame { _, _ in () }.unavailableReason
                == .outOfOrderSequence(last: 2, candidate: 1))
            #expect(outOfOrderMapping.pixelReadCount == 1)
            outOfOrderClock.now = 20
            #expect(outOfOrder.withFrame { _, _ in () }.unavailableReason
                == .outOfOrderSequence(last: 2, candidate: 1))
            #expect(outOfOrderFactory.requestedURLs.count == 1)

            let wrongEpochClock = FrameSourceTestClock(now: 10)
            let wrongEpochFactory = ScriptedFrameSourceMappingFactory(mappings: [
                ScriptedFrameSourceMapping([
                    .frame(descriptor(epoch: 6, sequence: 1), [3])
                ])
            ])
            let wrongEpoch = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: wrongEpochClock,
                mappingFactory: wrongEpochFactory
            )
            wrongEpoch.receive(available(epoch: 5))
            #expect(wrongEpoch.withFrame { _, _ in () }.unavailableReason
                == .wrongProducerEpoch(expected: 5, actual: 6))
            #expect(
                (wrongEpochFactory.lastCreatedMapping as? ScriptedFrameSourceMapping)?
                    .pixelReadCount == 0
            )
            wrongEpochClock.now = 20
            #expect(wrongEpoch.withFrame { _, _ in () }.unavailableReason
                == .wrongProducerEpoch(expected: 5, actual: 6))
            #expect(wrongEpochFactory.requestedURLs.count == 1)

            var invalidDescriptor = descriptor(epoch: 5, sequence: 1)
            invalidDescriptor.protocolVersion = 0
            let invalidDescriptorClock = FrameSourceTestClock(now: 10)
            let invalidDescriptorFactory = ScriptedFrameSourceMappingFactory(mappings: [
                ScriptedFrameSourceMapping([
                    .frame(invalidDescriptor, [4])
                ])
            ])
            let invalidDescriptorSource = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: invalidDescriptorClock,
                mappingFactory: invalidDescriptorFactory
            )
            invalidDescriptorSource.receive(available(epoch: 5))
            #expect(invalidDescriptorSource.withFrame { _, _ in () }.unavailableReason
                == .invalidFrameDescriptor)
            invalidDescriptorClock.now = 20
            #expect(invalidDescriptorSource.withFrame { _, _ in () }.unavailableReason
                == .invalidFrameDescriptor)
            #expect(invalidDescriptorFactory.requestedURLs.count == 1)
        }
    }

    @Test("mapping creation and structural snapshot failures are immediate fallback")
    func mappingFailuresFailClosed() throws {
        try withTemporaryContainer { containerURL in
            let clock = FrameSourceTestClock(now: 1)
            let creationFailure = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: clock,
                mappingFactory: ScriptedFrameSourceMappingFactory(errorOnMake: true)
            )
            creationFailure.receive(available(epoch: 1))
            #expect(creationFailure.availability == .unavailable(.mappingFailure))
            #expect(creationFailure.withFrame { _, _ in () }.unavailableReason
                == .mappingFailure)

            let snapshotFailure = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: clock,
                mappingFactory: ScriptedFrameSourceMappingFactory(mappings: [
                    ScriptedFrameSourceMapping([.failure])
                ])
            )
            snapshotFailure.receive(available(epoch: 1))
            #expect(snapshotFailure.withFrame { _, _ in () }.unavailableReason
                == .mappingFailure)

            let unstable = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: clock,
                mappingFactory: ScriptedFrameSourceMappingFactory(mappings: [
                    ScriptedFrameSourceMapping([.unstable])
                ])
            )
            unstable.receive(available(epoch: 1))
            #expect(unstable.withFrame { _, _ in () }.isNoNewFrame)
            #expect(unstable.availability == .waitingForFrame(epoch: 1))
        }
    }

    @Test("bounded busy snapshots remain waiting and a delayed first frame recovers")
    func delayedFirstFrameAfterBusySnapshots() throws {
        try withTemporaryContainer { containerURL in
            let clock = FrameSourceTestClock(now: 10)
            let mapping = ScriptedFrameSourceMapping([
                .unstable,
                .unstable,
                .unstable,
                .frame(descriptor(epoch: 4, sequence: 1), [4])
            ])
            let source = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: clock,
                mappingFactory: ScriptedFrameSourceMappingFactory(mappings: [mapping])
            )
            source.receive(available(epoch: 4))

            for now in [10.0, 10.2, 10.4] {
                clock.now = now
                #expect(source.withFrame { _, _ in () }.isNoNewFrame)
                #expect(source.availability == .waitingForFrame(epoch: 4))
            }
            clock.now = 10.5
            guard case let .frame(frame, value) = source.withFrame({ _, pixels in
                pixels[0]
            }) else {
                Issue.record("Expected the delayed first frame")
                return
            }
            #expect(frame.streamEpoch == 4)
            #expect(frame.sequence == 1)
            #expect(value == 4)
            #expect(mapping.readCount == 4)
        }
    }

    @Test("first-frame deadline falls back but retains the mapping for recovery")
    func firstFrameDeadlineAndRecovery() throws {
        try withTemporaryContainer { containerURL in
            let clock = FrameSourceTestClock(now: 100)
            let mapping = ScriptedFrameSourceMapping([
                .unstable,
                .unstable,
                .frame(descriptor(epoch: 6, sequence: 1), [6])
            ])
            let source = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: clock,
                mappingFactory: ScriptedFrameSourceMappingFactory(mappings: [mapping])
            )
            source.receive(available(epoch: 6))
            #expect(source.withFrame { _, _ in () }.isNoNewFrame)

            clock.now = 101.001
            #expect(source.withFrame { _, _ in () }.unavailableReason
                == .firstFrameTimedOut(epoch: 6))
            #expect(source.availability == .unavailable(.firstFrameTimedOut(epoch: 6)))

            clock.now = 101.1
            guard case let .frame(frame, value) = source.withFrame({ _, pixels in
                pixels[0]
            }) else {
                Issue.record("Expected recovery after the first-frame deadline")
                return
            }
            #expect(frame.sequence == 1)
            #expect(value == 6)
            #expect(source.availability == .available(epoch: 6, sequence: 1))
        }
    }

    @Test("a stale frame retains its mapping and a higher sequence recovers")
    func staleFrameToFreshRecovery() throws {
        try withTemporaryContainer { containerURL in
            let clock = FrameSourceTestClock(now: 1)
            let mapping = ScriptedFrameSourceMapping([
                .frame(descriptor(epoch: 8, sequence: 1), [1]),
                .frame(descriptor(epoch: 8, sequence: 1), [1]),
                .frame(descriptor(epoch: 8, sequence: 2), [2])
            ])
            let source = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: clock,
                mappingFactory: ScriptedFrameSourceMappingFactory(mappings: [mapping])
            )
            source.receive(available(epoch: 8))
            _ = source.withFrame { _, _ in () }

            clock.now = 2.001
            #expect(source.withFrame { _, _ in () }.unavailableReason
                == .staleFrame(epoch: 8, sequence: 1))

            clock.now = 2.1
            guard case let .frame(frame, value) = source.withFrame({ _, pixels in
                pixels[0]
            }) else {
                Issue.record("Expected a higher sequence to recover the stale source")
                return
            }
            #expect(frame.sequence == 2)
            #expect(value == 2)
            #expect(source.availability == .available(epoch: 8, sequence: 2))
        }
    }

    @Test("a cleared active mailbox falls back and recovers in the same epoch")
    func clearedMailboxToFreshRecovery() throws {
        try withTemporaryContainer { containerURL in
            let clock = FrameSourceTestClock(now: 1)
            let mapping = ScriptedFrameSourceMapping([
                .frame(descriptor(epoch: 9, sequence: 4), [4]),
                .unstable,
                .frame(descriptor(epoch: 9, sequence: 5), [5]),
            ])
            let source = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: clock,
                mappingFactory: ScriptedFrameSourceMappingFactory(mappings: [mapping])
            )
            source.receive(available(epoch: 9))
            _ = source.withFrame { _, _ in () }

            clock.now = 2.001
            #expect(source.withFrame { _, _ in () }.unavailableReason
                == .staleFrame(epoch: 9, sequence: 4))

            clock.now = 2.1
            guard case let .frame(frame, value) = source.withFrame({ _, pixels in
                pixels[0]
            }) else {
                Issue.record("Expected the restarted same-epoch stream to recover")
                return
            }
            #expect(frame.sequence == 5)
            #expect(value == 5)
            #expect(source.availability == .available(epoch: 9, sequence: 5))
        }
    }

    @Test("lease loss immediately fences the previous mapping")
    func leaseLossFencesMapping() throws {
        try withTemporaryContainer { containerURL in
            let mapping = ScriptedFrameSourceMapping([
                .frame(descriptor(epoch: 2, sequence: 1), [1, 2, 3, 4])
            ])
            let source = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: FrameSourceTestClock(now: 1),
                mappingFactory: ScriptedFrameSourceMappingFactory(mappings: [mapping])
            )
            source.receive(available(epoch: 2))
            source.receive(.unavailable)

            #expect(source.withFrame { _, _ -> Void in
                Issue.record("A lost lease must not expose old pixels")
            }.unavailableReason == .leaseUnavailable)
            #expect(mapping.readCount == 0)
        }
    }

    @Test("replacement generation fences an old mapping and a new epoch recovers cleanly")
    func replacementGenerationAndEpochRecovery() throws {
        try withTemporaryContainer { containerURL in
            let oldMapping = ScriptedFrameSourceMapping([
                .frame(descriptor(epoch: 7, sequence: 1), [7])
            ])
            let newMapping = ScriptedFrameSourceMapping([
                .frame(descriptor(epoch: 8, sequence: 1), [8])
            ])
            let source = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: FrameSourceTestClock(now: 20),
                mappingFactory: ScriptedFrameSourceMappingFactory(
                    mappings: [oldMapping, newMapping]
                )
            )
            source.receive(available(epoch: 7, leaf: "old.mailbox"))
            oldMapping.beforeSnapshot = {
                source.receive(available(epoch: 8, leaf: "new.mailbox"))
            }
            var oldDeliveryCount = 0

            #expect(source.withFrame { _, _ in oldDeliveryCount += 1 }.isNoNewFrame)
            #expect(oldDeliveryCount == 0)
            let recovered = source.withFrame { frame, pixels in
                #expect(Array(pixels) == [8])
                return frame.sequence
            }
            guard case let .frame(frame, sequence) = recovered else {
                Issue.record("Expected the replacement epoch frame, got \(recovered)")
                return
            }
            #expect(frame.streamEpoch == 8)
            #expect(sequence == 1)
        }
    }

    @Test("a new epoch recovers after descriptor validation failure")
    func newEpochRecoveryAfterFailure() throws {
        try withTemporaryContainer { containerURL in
            let source = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: FrameSourceTestClock(now: 1),
                mappingFactory: ScriptedFrameSourceMappingFactory(mappings: [
                    ScriptedFrameSourceMapping([
                        .frame(descriptor(epoch: 10, sequence: 1), [1])
                    ]),
                    ScriptedFrameSourceMapping([
                        .frame(descriptor(epoch: 10, sequence: 1), [2])
                    ])
                ])
            )
            source.receive(available(epoch: 9, leaf: "wrong.mailbox"))
            #expect(source.withFrame { _, _ in () }.unavailableReason
                == .wrongProducerEpoch(expected: 9, actual: 10))

            source.receive(available(epoch: 10, leaf: "recovered.mailbox"))
            guard case let .frame(frame, value) = source.withFrame({ _, pixels in
                pixels[0]
            }) else {
                Issue.record("Expected recovery on the new producer epoch")
                return
            }
            #expect(frame.streamEpoch == 10)
            #expect(value == 2)
        }
    }

    @Test(arguments: ["", ".", "..", "../escape", "nested/mailbox", "/tmp/escape"])
    func rejectsTransportPathEscape(_ transportIdentifier: String) throws {
        try withTemporaryContainer { containerURL in
            let factory = ScriptedFrameSourceMappingFactory(mappings: [])
            let source = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: FrameSourceTestClock(now: 1),
                mappingFactory: factory
            )

            source.receive(available(epoch: 1, leaf: transportIdentifier))

            #expect(source.availability == .unavailable(.invalidTransportIdentifier))
            #expect(factory.requestedURLs.isEmpty)
        }
    }

    @Test("lease loss permits a restarted producer to begin again at epoch one")
    func leaseLossResetsProducerEpochFloor() throws {
        try withTemporaryContainer { containerURL in
            let source = try CameraFrameSource(
                appGroupContainerURL: containerURL,
                clock: FrameSourceTestClock(now: 1),
                mappingFactory: ScriptedFrameSourceMappingFactory(mappings: [
                    ScriptedFrameSourceMapping([
                        .frame(descriptor(epoch: 7, sequence: 1), [7])
                    ]),
                    ScriptedFrameSourceMapping([
                        .frame(descriptor(epoch: 1, sequence: 1), [1])
                    ])
                ])
            )
            source.receive(available(epoch: 7, leaf: "before-restart.mailbox"))
            _ = source.withFrame { _, _ in () }

            source.receive(.unavailable)
            source.receive(available(epoch: 1, leaf: "after-restart.mailbox"))

            guard case let .frame(frame, value) = source.withFrame({ _, pixels in
                pixels[0]
            }) else {
                Issue.record("Expected epoch one after a fenced lease loss")
                return
            }
            #expect(frame.streamEpoch == 1)
            #expect(frame.sequence == 1)
            #expect(value == 1)
        }
    }

    private func withTemporaryContainer<Result>(
        _ body: (URL) throws -> Result
    ) throws -> Result {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "idlescreen-frame-source-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    private func available(
        epoch: UInt64,
        leaf: String = "camera-frames-v1.mailbox"
    ) -> CameraLeaseControllerUpdate {
        .available(CameraAgentStreamDescriptor(
            producerStreamEpoch: epoch,
            transportIdentifier: leaf
        ))
    }

    private func descriptor(
        epoch: UInt64,
        sequence: UInt64,
        timestamp: TimeInterval = 0.001
    ) -> IdleScreenCameraFrameDescriptor {
        IdleScreenCameraFrameDescriptor(
            protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
            streamEpoch: epoch,
            sequence: sequence,
            timestamp: timestamp,
            width: 1,
            height: 1,
            bytesPerRow: 4,
            pixelFormat: .bgra8Unorm,
            slotIndex: 0,
            slotCount: 3
        )
    }
}

private final class FrameSourceTestClock: CameraFrameSourceClock, @unchecked Sendable {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}

private enum ScriptedFrameSourceSnapshot {
    case frame(IdleScreenCameraFrameDescriptor, [UInt8])
    case unstable
    case failure
}

private enum ScriptedFrameSourceError: Swift.Error {
    case failed
}

private final class ScriptedFrameSourceMapping:
    CameraFrameSourceMapping,
    @unchecked Sendable
{
    private var snapshots: [ScriptedFrameSourceSnapshot]
    var beforeSnapshot: (() -> Void)?
    private(set) var callbackIsActive = false
    private(set) var readCount = 0
    private(set) var pixelReadCount = 0

    init(_ snapshots: [ScriptedFrameSourceSnapshot]) {
        self.snapshots = snapshots
    }

    func withStableSnapshot<Result>(
        _ body: (
            IdleScreenCameraFrameDescriptor,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) throws -> Result? {
        let read = try withStableSnapshot(
            copyingPixelsWhen: { _ in true },
            body
        )
        switch read {
        case nil:
            return nil
        case let .frame(result):
            return result
        case .descriptor:
            preconditionFailure("An unconditional test snapshot omitted its payload")
        }
    }

    func withStableSnapshot<Result>(
        copyingPixelsWhen shouldCopyPixels: (
            IdleScreenCameraFrameDescriptor
        ) throws -> Bool,
        _ body: (
            IdleScreenCameraFrameDescriptor,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) throws -> CameraFrameSourceMappingRead<Result>? {
        readCount += 1
        beforeSnapshot?()
        beforeSnapshot = nil
        guard !snapshots.isEmpty else { return nil }
        switch snapshots.removeFirst() {
        case let .frame(descriptor, pixels):
            guard try shouldCopyPixels(descriptor) else {
                return .descriptor(descriptor)
            }
            pixelReadCount += 1
            return try pixels.withUnsafeBytes { bytes in
                callbackIsActive = true
                defer { callbackIsActive = false }
                return .frame(try body(descriptor, bytes))
            }
        case .unstable:
            return nil
        case .failure:
            throw ScriptedFrameSourceError.failed
        }
    }
}

private final class ScriptedFrameSourceMappingFactory:
    CameraFrameSourceMappingFactory,
    @unchecked Sendable
{
    private var mappings: [any CameraFrameSourceMapping]
    private let errorOnMake: Bool
    private(set) var requestedURLs: [URL] = []
    private(set) var lastCreatedMapping: (any CameraFrameSourceMapping)?

    init(
        mappings: [any CameraFrameSourceMapping] = [],
        errorOnMake: Bool = false
    ) {
        self.mappings = mappings
        self.errorOnMake = errorOnMake
    }

    func makeMapping(contentsOf url: URL) throws -> any CameraFrameSourceMapping {
        requestedURLs.append(url)
        guard !errorOnMake, !mappings.isEmpty else {
            throw ScriptedFrameSourceError.failed
        }
        let mapping = mappings.removeFirst()
        lastCreatedMapping = mapping
        return mapping
    }
}

private extension CameraFrameSourceRead {
    var isNoNewFrame: Bool {
        if case .noNewFrame = self { return true }
        return false
    }

    var unavailableReason: CameraFrameSourceUnavailableReason? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}
