import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Camera frame mailbox contract")
struct CameraFrameContractTests {
    private func descriptor(
        protocolVersion: Int = IdleScreenCameraFrameDescriptor.currentProtocolVersion,
        streamEpoch: UInt64 = 7,
        sequence: UInt64 = 42,
        timestamp: TimeInterval = 100,
        width: UInt64 = 640,
        height: UInt64 = 480,
        bytesPerRow: UInt64 = 2_560,
        slotIndex: UInt64 = 1,
        slotCount: UInt64 = 3
    ) -> IdleScreenCameraFrameDescriptor {
        IdleScreenCameraFrameDescriptor(
            protocolVersion: protocolVersion,
            streamEpoch: streamEpoch,
            sequence: sequence,
            timestamp: timestamp,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: .bgra8Unorm,
            slotIndex: slotIndex,
            slotCount: slotCount
        )
    }

    @Test("a complete BGRA mailbox descriptor is valid")
    func validDescriptor() throws {
        let descriptor = IdleScreenCameraFrameDescriptor(
            protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
            streamEpoch: 7,
            sequence: 42,
            timestamp: 100,
            width: 640,
            height: 480,
            bytesPerRow: 2_560,
            pixelFormat: .bgra8Unorm,
            slotIndex: 1,
            slotCount: 3
        )

        #expect(try descriptor.validated() == descriptor)
    }

    @Test("zero and future protocol versions are rejected", arguments: [0, 2])
    func invalidProtocolVersion(version: Int) {
        #expect(
            throws: IdleScreenCameraFrameDescriptor.ValidationError.unsupportedProtocolVersion(version)
        ) {
            try descriptor(protocolVersion: version).validated()
        }
    }

    @Test("zero identity, timestamp, dimensions, stride, and slot count are rejected")
    func zeroFields() {
        let invalidDescriptors = [
            descriptor(streamEpoch: 0),
            descriptor(sequence: 0),
            descriptor(timestamp: 0),
            descriptor(width: 0),
            descriptor(height: 0),
            descriptor(bytesPerRow: 0),
            descriptor(slotIndex: 0, slotCount: 0),
        ]

        for invalidDescriptor in invalidDescriptors {
            #expect(throws: IdleScreenCameraFrameDescriptor.ValidationError.self) {
                try invalidDescriptor.validated()
            }
        }
    }

    @Test("non-finite timestamps are rejected", arguments: [TimeInterval.infinity, -.infinity, .nan])
    func nonFiniteTimestamp(timestamp: TimeInterval) {
        #expect(throws: IdleScreenCameraFrameDescriptor.ValidationError.invalidTimestamp) {
            try descriptor(timestamp: timestamp).validated()
        }
    }

    @Test("stride must fit and contain whole BGRA pixels")
    func inconsistentStride() {
        #expect(throws: IdleScreenCameraFrameDescriptor.ValidationError.invalidBytesPerRow) {
            try descriptor(width: 4, bytesPerRow: 15).validated()
        }
        #expect(throws: IdleScreenCameraFrameDescriptor.ValidationError.invalidBytesPerRow) {
            try descriptor(width: 4, bytesPerRow: 18).validated()
        }
        #expect(throws: IdleScreenCameraFrameDescriptor.ValidationError.rowByteCountOverflow) {
            try descriptor(width: .max, bytesPerRow: .max).validated()
        }
        #expect(throws: IdleScreenCameraFrameDescriptor.ValidationError.frameByteCountOverflow) {
            try descriptor(width: 1, height: .max, bytesPerRow: 4).validated()
        }
    }

    @Test("the allocation ceiling admits 1080p BGRA and padded rows at smaller sizes")
    func allocationCeiling() throws {
        let fullHD = descriptor(
            width: IdleScreenCameraFrameDescriptor.maximumWidth,
            height: IdleScreenCameraFrameDescriptor.maximumHeight,
            bytesPerRow: 7_680
        )
        let padded = descriptor(width: 641, height: 360, bytesPerRow: 2_816)

        #expect(try fullHD.validated() == fullHD)
        #expect(try padded.validated() == padded)
        #expect(IdleScreenCameraFrameDescriptor.maximumFrameByteCount == 8_294_400)
    }

    @Test("dimensions beyond 1080p are rejected before allocation")
    func oversizedDimensions() {
        #expect(
            throws: IdleScreenCameraFrameDescriptor.ValidationError.dimensionsExceedLimit(
                width: 1_921,
                height: 1_080
            )
        ) {
            try descriptor(width: 1_921, height: 1_080, bytesPerRow: 7_684).validated()
        }
        #expect(
            throws: IdleScreenCameraFrameDescriptor.ValidationError.dimensionsExceedLimit(
                width: 1_920,
                height: 1_081
            )
        ) {
            try descriptor(width: 1_920, height: 1_081, bytesPerRow: 7_680).validated()
        }
    }

    @Test("oversized stride is rejected even when the frame byte count is small")
    func oversizedStride() {
        #expect(throws: IdleScreenCameraFrameDescriptor.ValidationError.bytesPerRowExceedsLimit(8_196)) {
            try descriptor(width: 640, height: 1, bytesPerRow: 8_196).validated()
        }
    }

    @Test("oversized frame bytes are rejected without relying on integer overflow")
    func oversizedFrameByteCount() {
        #expect(
            throws: IdleScreenCameraFrameDescriptor.ValidationError.frameByteCountExceedsLimit(
                8_298_720
            )
        ) {
            try descriptor(width: 1_920, height: 1_080, bytesPerRow: 7_684).validated()
        }
    }

    @Test("mailbox slots are bounded and the selected index must exist")
    func boundedSlots() {
        #expect(throws: IdleScreenCameraFrameDescriptor.ValidationError.invalidSlotCount(4)) {
            try descriptor(slotIndex: 0, slotCount: 4).validated()
        }
        #expect(
            throws: IdleScreenCameraFrameDescriptor.ValidationError.invalidSlotIndex(index: 3, count: 3)
        ) {
            try descriptor(slotIndex: 3, slotCount: 3).validated()
        }
    }

    @Test("a newer sequence replaces the latest frame in the same stream epoch")
    func selectsNewerSequence() throws {
        var selector = IdleScreenLatestFrameSelector()
        let first = descriptor(sequence: 41, timestamp: 99)
        let newer = descriptor(sequence: 42, timestamp: 99.5)

        #expect(try selector.consider(first, currentTime: 100, maximumAge: 2))
        #expect(try selector.consider(newer, currentTime: 100, maximumAge: 2))
        #expect(selector.latest == newer)
        let acceptedDuplicate = try selector.consider(
            descriptor(sequence: 42, timestamp: 99.75),
            currentTime: 100,
            maximumAge: 2
        )
        let acceptedOlder = try selector.consider(
            descriptor(sequence: 40, timestamp: 99.75),
            currentTime: 100,
            maximumAge: 2
        )
        #expect(!acceptedDuplicate)
        #expect(!acceptedOlder)
        #expect(selector.latest == newer)
    }

    @Test("a newer stream epoch resets sequence while an older epoch cannot return")
    func selectsNewerEpoch() throws {
        var selector = IdleScreenLatestFrameSelector()
        let original = descriptor(streamEpoch: 7, sequence: 42, timestamp: 99)
        let restarted = descriptor(streamEpoch: 8, sequence: 1, timestamp: 99.5)

        #expect(try selector.consider(original, currentTime: 100, maximumAge: 2))
        #expect(try selector.consider(restarted, currentTime: 100, maximumAge: 2))
        #expect(selector.latest == restarted)
        let acceptedOlderEpoch = try selector.consider(
            descriptor(streamEpoch: 7, sequence: 99, timestamp: 99.75),
            currentTime: 100,
            maximumAge: 2
        )
        #expect(!acceptedOlderEpoch)
        #expect(selector.latest == restarted)
    }

    @Test("stale and future frames are rejected using only the injected clock")
    func rejectsFramesOutsideAgeWindow() throws {
        var selector = IdleScreenLatestFrameSelector()

        let acceptedStale = try selector.consider(
            descriptor(timestamp: 94.99),
            currentTime: 100,
            maximumAge: 5
        )
        #expect(!acceptedStale)
        #expect(selector.latest == nil)
        #expect(try selector.consider(descriptor(timestamp: 95), currentTime: 100, maximumAge: 5))
        let acceptedFuture = try selector.consider(
            descriptor(sequence: 43, timestamp: 100.01),
            currentTime: 100,
            maximumAge: 5
        )
        #expect(!acceptedFuture)
        #expect(selector.latest?.sequence == 42)
    }

    @Test("invalid injected clock values fail explicitly")
    func rejectsInvalidClockInputs() {
        var selector = IdleScreenLatestFrameSelector()

        #expect(throws: IdleScreenLatestFrameSelector.SelectionError.invalidCurrentTime) {
            try selector.consider(descriptor(), currentTime: .nan, maximumAge: 5)
        }
        #expect(throws: IdleScreenLatestFrameSelector.SelectionError.invalidMaximumAge) {
            try selector.consider(descriptor(), currentTime: 100, maximumAge: -1)
        }
        #expect(throws: IdleScreenLatestFrameSelector.SelectionError.invalidMaximumAge) {
            try selector.consider(descriptor(), currentTime: 100, maximumAge: .infinity)
        }
    }
}
