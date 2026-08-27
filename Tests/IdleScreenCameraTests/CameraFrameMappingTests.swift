import Foundation
import Testing
@testable import IdleScreenCamera
#if canImport(Darwin)
import Darwin
#endif

private final class TemporaryCameraMailbox {
    let directoryURL: URL
    let fileURL: URL

    init(
        header: IdleScreenCameraFrameMailboxHeader,
        payload: [UInt8] = Array(0..<32),
        fileByteCount: Int? = nil,
        permissions: mode_t = 0o600
    ) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idlescreen-camera-mailbox-\(UUID().uuidString)", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("camera.frames")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard chmod(fileURL.path, permissions) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        let size: Int
        if let fileByteCount {
            size = fileByteCount
        } else {
            size = try IdleScreenCameraFrameMailboxLayout.current.expectedFileByteCount()
        }
        try handle.truncate(atOffset: UInt64(size))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header.encoded())
        if !payload.isEmpty {
            let payloadOffset = try IdleScreenCameraFrameMailboxLayout.current
                .payloadOffset(forSlot: header.slotIndex)
            try handle.seek(toOffset: UInt64(payloadOffset))
            try handle.write(contentsOf: Data(payload))
        }
        try handle.close()
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("idlescreen-camera-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class ScriptedGenerationLoader: IdleScreenCameraGenerationLoading {
    private let values: [UInt64]
    private(set) var callCount = 0

    init(_ values: [UInt64]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func loadAcquireGeneration(
        from baseAddress: UnsafeRawPointer,
        byteOffset: Int
    ) throws -> UInt64 {
        defer { callCount += 1 }
        return values[min(callCount, values.count - 1)]
    }
}

private final class MetadataOnlyFile: IdleScreenCameraFrameStorageFile {
    let metadata: IdleScreenCameraFrameFileMetadata
    private(set) var mapCallCount = 0

    init(metadata: IdleScreenCameraFrameFileMetadata) {
        self.metadata = metadata
    }

    func mapReadOnly(byteCount: Int) throws -> any IdleScreenCameraMappedRegion {
        mapCallCount += 1
        throw IdleScreenCameraFrameMappingError.mappingFailed(EIO)
    }
}

private struct MetadataOnlyStorage: IdleScreenCameraFrameStorage {
    let file: MetadataOnlyFile

    func openReadOnlyNoFollow(at url: URL) throws -> any IdleScreenCameraFrameStorageFile {
        file
    }
}

private struct RecordedCopy: Equatable {
    let offset: Int
    let count: Int
}

private final class RecordingMappedRegion: IdleScreenCameraMappedRegion {
    let byteCount: Int
    var unsafeBaseAddress: UnsafeRawPointer { UnsafeRawPointer(baseStorage) }
    private let baseStorage: UnsafeMutableRawPointer
    private let header: Data
    private let payload: Data
    private let payloadOffset: Int
    private(set) var copies: [RecordedCopy] = []

    init(
        byteCount: Int,
        header: Data,
        payload: Data,
        payloadOffset: Int
    ) {
        self.byteCount = byteCount
        self.header = header
        self.payload = payload
        self.payloadOffset = payloadOffset
        baseStorage = .allocate(
            byteCount: MemoryLayout<UInt64>.size,
            alignment: MemoryLayout<UInt64>.alignment
        )
    }

    deinit {
        baseStorage.deallocate()
    }

    func copyBytes(
        at offset: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) throws {
        copies.append(RecordedCopy(offset: offset, count: destination.count))
        let source: Data
        switch offset {
        case 0:
            source = header
        case payloadOffset:
            source = payload
        default:
            throw IdleScreenCameraFrameMappingError.invalidCopyRange(
                offset: offset,
                count: destination.count,
                mappedByteCount: byteCount
            )
        }
        guard source.count >= destination.count else {
            throw IdleScreenCameraFrameMappingError.invalidCopyRange(
                offset: offset,
                count: destination.count,
                mappedByteCount: byteCount
            )
        }
        _ = source.copyBytes(to: destination.bindMemory(to: UInt8.self))
    }
}

private final class RecordingMappedFile: IdleScreenCameraFrameStorageFile {
    let metadata: IdleScreenCameraFrameFileMetadata
    let region: RecordingMappedRegion

    init(metadata: IdleScreenCameraFrameFileMetadata, region: RecordingMappedRegion) {
        self.metadata = metadata
        self.region = region
    }

    func mapReadOnly(byteCount: Int) throws -> any IdleScreenCameraMappedRegion {
        region
    }
}

private struct RecordingMappedStorage: IdleScreenCameraFrameStorage {
    let file: RecordingMappedFile

    func openReadOnlyNoFollow(at url: URL) throws -> any IdleScreenCameraFrameStorageFile {
        file
    }
}

private enum SnapshotConsumerError: Swift.Error, Equatable {
    case stop
}

@Suite("Camera frame mailbox mapping")
struct CameraFrameMappingTests {
    private func descriptor(
        width: UInt64 = 4,
        height: UInt64 = 2,
        bytesPerRow: UInt64 = 16,
        slotIndex: UInt64 = 1,
        slotCount: UInt64 = 3
    ) -> IdleScreenCameraFrameDescriptor {
        IdleScreenCameraFrameDescriptor(
            protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
            streamEpoch: 7,
            sequence: 42,
            timestamp: 100,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: .bgra8Unorm,
            slotIndex: slotIndex,
            slotCount: slotCount
        )
    }

    @Test("the current mailbox has one fixed header and three bounded BGRA slots")
    func currentLayoutSize() throws {
        let layout = IdleScreenCameraFrameMailboxLayout.current

        #expect(layout.headerByteCount == 128)
        #expect(layout.slotCount == IdleScreenCameraFrameDescriptor.maximumSlotCount)
        #expect(layout.slotByteCapacity == IdleScreenCameraFrameDescriptor.maximumFrameByteCount)
        #expect(try layout.expectedFileByteCount() == 24_883_328)
    }

    @Test("mailbox size arithmetic reports overflow instead of wrapping")
    func layoutSizeOverflow() {
        #expect(throws: IdleScreenCameraFrameMailboxLayout.LayoutError.byteCountOverflow) {
            try IdleScreenCameraFrameMailboxLayout.checkedFileByteCount(
                headerByteCount: .max,
                slotByteCapacity: .max,
                slotCount: 3
            )
        }
    }

    @Test("a current header round-trips without native struct layout assumptions")
    func headerRoundTrip() throws {
        let source = IdleScreenCameraFrameMailboxHeader(
            generation: 2,
            descriptor: descriptor()
        )

        let encoded = source.encoded()
        let decoded = try encoded.withUnsafeBytes {
            try IdleScreenCameraFrameMailboxHeader.decode(from: $0)
        }

        #expect(encoded.count == 128)
        #expect(decoded == source)
        #expect(try decoded.validated(for: .current) == descriptor())
    }

    @Test("stable headers reject unsupported schema and odd generations")
    func headerIdentityValidation() throws {
        var unsupported = IdleScreenCameraFrameMailboxHeader(
            generation: 2,
            descriptor: descriptor()
        )
        unsupported.schemaVersion = 2
        var writing = unsupported
        writing.schemaVersion = IdleScreenCameraFrameMailboxLayout.currentSchemaVersion
        writing.generation = 3

        #expect(
            throws: IdleScreenCameraFrameMailboxHeader.ValidationError
                .unsupportedSchemaVersion(2)
        ) {
            try unsupported.validated(for: .current)
        }
        #expect(
            throws: IdleScreenCameraFrameMailboxHeader.ValidationError.invalidGeneration(3)
        ) {
            try writing.validated(for: .current)
        }
    }

    @Test("headers reject invalid geometry, pixel formats, and payload lengths")
    func headerPayloadValidation() throws {
        var geometry = IdleScreenCameraFrameMailboxHeader(
            generation: 2,
            descriptor: descriptor()
        )
        geometry.width = 0
        var pixelFormat = geometry
        pixelFormat.width = 4
        pixelFormat.pixelFormatRawValue = 0xDEAD_BEEF
        var payloadLength = pixelFormat
        payloadLength.pixelFormatRawValue = IdleScreenCameraPixelFormat.bgra8Unorm.rawValue
        payloadLength.payloadByteCount = 31

        #expect(
            throws: IdleScreenCameraFrameMailboxHeader.ValidationError.invalidDescriptor(.zeroDimensions)
        ) {
            try geometry.validated(for: .current)
        }
        #expect(
            throws: IdleScreenCameraFrameMailboxHeader.ValidationError
                .unsupportedPixelFormat(0xDEAD_BEEF)
        ) {
            try pixelFormat.validated(for: .current)
        }
        #expect(
            throws: IdleScreenCameraFrameMailboxHeader.ValidationError
                .payloadByteCountMismatch(expected: 32, actual: 31)
        ) {
            try payloadLength.validated(for: .current)
        }
    }

    @Test("a validated 0600 regular file yields one bounded stable BGRA snapshot")
    func stableSnapshot() throws {
        let header = IdleScreenCameraFrameMailboxHeader(
            generation: 2,
            descriptor: descriptor()
        )
        let mailbox = try TemporaryCameraMailbox(header: header)
        let generationLoader = ScriptedGenerationLoader([2, 2])
        let mapping = try IdleScreenCameraFrameMailboxMapping(
            contentsOf: mailbox.fileURL,
            generationLoader: generationLoader
        )

        var copiedPixels: [UInt8] = []
        let copiedByteCount = try mapping.withStableSnapshot { observed, pixels in
            #expect(observed == descriptor())
            copiedPixels = Array(pixels)
            return pixels.count
        }

        #expect(copiedByteCount == 32)
        #expect(copiedPixels == Array(0..<32))
        #expect(generationLoader.callCount == 2)
    }

    @Test("the snapshot destination is allocated once and reused")
    func preallocatedSnapshotDestination() throws {
        let mailbox = try TemporaryCameraMailbox(
            header: IdleScreenCameraFrameMailboxHeader(
                generation: 2,
                descriptor: descriptor()
            )
        )
        let mapping = try IdleScreenCameraFrameMailboxMapping(
            contentsOf: mailbox.fileURL,
            generationLoader: ScriptedGenerationLoader([2, 2, 2, 2])
        )

        let firstAddress = try mapping.withStableSnapshot { _, pixels in
            UInt(bitPattern: pixels.baseAddress)
        }
        let secondAddress = try mapping.withStableSnapshot { _, pixels in
            UInt(bitPattern: pixels.baseAddress)
        }

        #expect(firstAddress != nil)
        #expect(secondAddress == firstAddress)
    }

    @Test("a stable rejected descriptor does not copy its pixel payload")
    func rejectedDescriptorSkipsPayloadCopy() throws {
        let layout = IdleScreenCameraFrameMailboxLayout.current
        let header = IdleScreenCameraFrameMailboxHeader(
            generation: 2,
            descriptor: descriptor()
        )
        let payload = Data(Array(0..<32))
        let region = RecordingMappedRegion(
            byteCount: try layout.expectedFileByteCount(),
            header: header.encoded(),
            payload: payload,
            payloadOffset: try layout.payloadOffset(forSlot: header.slotIndex)
        )
        let file = RecordingMappedFile(
            metadata: IdleScreenCameraFrameFileMetadata(
                kind: .regularFile,
                ownerUserID: geteuid(),
                permissions: 0o600,
                byteCount: UInt64(try layout.expectedFileByteCount())
            ),
            region: region
        )
        let mapping = try IdleScreenCameraFrameMailboxMapping(
            contentsOf: URL(fileURLWithPath: "/unused-test-path"),
            storage: RecordingMappedStorage(file: file),
            generationLoader: ScriptedGenerationLoader([2, 2])
        )

        let read: CameraFrameSourceMappingRead<Void>? = try mapping.withStableSnapshot(
            copyingPixelsWhen: { _ in false },
            { _, _ in Issue.record("A rejected descriptor exposed its payload") }
        )

        guard case let .descriptor(observed) = read else {
            Issue.record("Expected a descriptor-only read")
            return
        }
        #expect(observed == descriptor())
        #expect(region.copies == [RecordedCopy(offset: 0, count: 128)])
    }

    @Test("a descriptor-only generation race retries before returning")
    func descriptorOnlyGenerationRace() throws {
        let layout = IdleScreenCameraFrameMailboxLayout.current
        let header = IdleScreenCameraFrameMailboxHeader(
            generation: 2,
            descriptor: descriptor()
        )
        let region = RecordingMappedRegion(
            byteCount: try layout.expectedFileByteCount(),
            header: header.encoded(),
            payload: Data(Array(0..<32)),
            payloadOffset: try layout.payloadOffset(forSlot: header.slotIndex)
        )
        let file = RecordingMappedFile(
            metadata: IdleScreenCameraFrameFileMetadata(
                kind: .regularFile,
                ownerUserID: geteuid(),
                permissions: 0o600,
                byteCount: UInt64(try layout.expectedFileByteCount())
            ),
            region: region
        )
        let loader = ScriptedGenerationLoader([2, 4, 2, 2])
        let mapping = try IdleScreenCameraFrameMailboxMapping(
            contentsOf: URL(fileURLWithPath: "/unused-test-path"),
            storage: RecordingMappedStorage(file: file),
            generationLoader: loader
        )

        let read: CameraFrameSourceMappingRead<Void>? = try mapping.withStableSnapshot(
            copyingPixelsWhen: { _ in false },
            { _, _ in Issue.record("A descriptor-only read exposed pixels") }
        )

        guard case .descriptor = read else {
            Issue.record("Expected a stable descriptor after one retry")
            return
        }
        #expect(loader.callCount == 4)
        #expect(region.copies == [
            RecordedCopy(offset: 0, count: 128),
            RecordedCopy(offset: 0, count: 128),
        ])
    }

    @Test("duplicate header fast path materially reduces mailbox read CPU work")
    func duplicateHeaderFastPathMeasurement() throws {
        let largeDescriptor = descriptor(
            width: 1_280,
            height: 720,
            bytesPerRow: 5_120,
            slotIndex: 0
        )
        let payloadByteCount = 1_280 * 720 * 4
        let mailbox = try TemporaryCameraMailbox(
            header: IdleScreenCameraFrameMailboxHeader(
                generation: 2,
                descriptor: largeDescriptor
            ),
            payload: [UInt8](repeating: 0x5A, count: payloadByteCount)
        )
        let mapping = try IdleScreenCameraFrameMailboxMapping(
            contentsOf: mailbox.fileURL,
            generationLoader: ScriptedGenerationLoader([2])
        )
        let iterations = 60
        let clock = ContinuousClock()

        let headerStartedAt = clock.now
        for _ in 0..<iterations {
            let read: CameraFrameSourceMappingRead<Void>? = try mapping
                .withStableSnapshot(
                    copyingPixelsWhen: { _ in false },
                    { _, _ in Issue.record("A duplicate exposed pixels") }
                )
            guard case .descriptor = read else {
                Issue.record("Expected a descriptor-only duplicate")
                return
            }
        }
        let headerDuration = headerStartedAt.duration(to: clock.now)

        var observedByteCount = 0
        let payloadStartedAt = clock.now
        for _ in 0..<iterations {
            observedByteCount += try #require(
                mapping.withStableSnapshot { _, pixels in pixels.count }
            )
        }
        let payloadDuration = payloadStartedAt.duration(to: clock.now)
        let headerMilliseconds = milliseconds(headerDuration)
        let payloadMilliseconds = milliseconds(payloadDuration)
        print(
            "camera_duplicate_copy_benchmark iterations=\(iterations) "
                + "payload_bytes=\(payloadByteCount) "
                + "header_ms=\(headerMilliseconds) "
                + "payload_ms=\(payloadMilliseconds)"
        )

        #expect(observedByteCount == payloadByteCount * iterations)
        #expect(headerMilliseconds * 3 < payloadMilliseconds)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
    }

    @Test("consumer errors escape once and are never folded into seqlock retries")
    func consumerErrorIsNotRetried() throws {
        let mailbox = try TemporaryCameraMailbox(
            header: IdleScreenCameraFrameMailboxHeader(
                generation: 2,
                descriptor: descriptor()
            )
        )
        let generationLoader = ScriptedGenerationLoader([2, 2, 4, 4])
        let mapping = try IdleScreenCameraFrameMailboxMapping(
            contentsOf: mailbox.fileURL,
            generationLoader: generationLoader
        )
        var callbackCount = 0

        #expect(throws: SnapshotConsumerError.stop) {
            try mapping.withStableSnapshot { _, _ in
                callbackCount += 1
                throw SnapshotConsumerError.stop
            }
        }
        #expect(callbackCount == 1)
        #expect(generationLoader.callCount == 2)
    }

    @Test("odd or changing generations exhaust a bounded attempt budget without waiting")
    func boundedUnstableSnapshotAttempts() throws {
        let mailbox = try TemporaryCameraMailbox(
            header: IdleScreenCameraFrameMailboxHeader(
                generation: 2,
                descriptor: descriptor()
            )
        )
        let generationLoader = ScriptedGenerationLoader([3, 3, 3])
        let mapping = try IdleScreenCameraFrameMailboxMapping(
            contentsOf: mailbox.fileURL,
            generationLoader: generationLoader,
            snapshotAttemptLimit: 3
        )

        let result: Int? = try mapping.withStableSnapshot { _, _ in 1 }

        #expect(result == nil)
        #expect(generationLoader.callCount == 3)
    }

    @Test("a stable generation must match the generation encoded in the header")
    func stableGenerationMismatch() throws {
        let mailbox = try TemporaryCameraMailbox(
            header: IdleScreenCameraFrameMailboxHeader(
                generation: 2,
                descriptor: descriptor()
            )
        )
        let mapping = try IdleScreenCameraFrameMailboxMapping(
            contentsOf: mailbox.fileURL,
            generationLoader: ScriptedGenerationLoader([4, 4])
        )

        #expect(
            throws: IdleScreenCameraFrameMailboxHeader.ValidationError
                .generationMismatch(header: 2, observed: 4)
        ) {
            try mapping.withStableSnapshot { _, _ in () }
        }
    }

    @Test("stable malformed headers are rejected instead of copied")
    func malformedStableHeader() throws {
        var header = IdleScreenCameraFrameMailboxHeader(
            generation: 2,
            descriptor: descriptor()
        )
        header.schemaVersion = 99
        let mailbox = try TemporaryCameraMailbox(header: header)
        let mapping = try IdleScreenCameraFrameMailboxMapping(
            contentsOf: mailbox.fileURL,
            generationLoader: ScriptedGenerationLoader([2, 2])
        )

        #expect(
            throws: IdleScreenCameraFrameMailboxHeader.ValidationError
                .unsupportedSchemaVersion(99)
        ) {
            try mapping.withStableSnapshot { _, _ in () }
        }
    }

    @Test("O_NOFOLLOW rejects a mailbox symlink")
    func symlinkRejected() throws {
        let mailbox = try TemporaryCameraMailbox(
            header: IdleScreenCameraFrameMailboxHeader(
                generation: 2,
                descriptor: descriptor()
            )
        )
        let links = try TemporaryDirectory()
        let linkURL = links.url.appendingPathComponent("camera-link.frames")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: mailbox.fileURL
        )

        #expect(throws: IdleScreenCameraFrameMappingError.symbolicLinkRejected) {
            try IdleScreenCameraFrameMailboxMapping(
                contentsOf: linkURL,
                generationLoader: ScriptedGenerationLoader([2])
            )
        }
    }

    @Test("directories and non-owner-only permissions are rejected")
    func fileTypeAndPermissionsRejected() throws {
        let directory = try TemporaryDirectory()
        let mailbox = try TemporaryCameraMailbox(
            header: IdleScreenCameraFrameMailboxHeader(
                generation: 2,
                descriptor: descriptor()
            ),
            permissions: 0o644
        )

        #expect(throws: IdleScreenCameraFrameMappingError.notRegularFile) {
            try IdleScreenCameraFrameMailboxMapping(
                contentsOf: directory.url,
                generationLoader: ScriptedGenerationLoader([2])
            )
        }
        #expect(
            throws: IdleScreenCameraFrameMappingError
                .invalidPermissions(expected: 0o600, actual: 0o644)
        ) {
            try IdleScreenCameraFrameMailboxMapping(
                contentsOf: mailbox.fileURL,
                generationLoader: ScriptedGenerationLoader([2])
            )
        }
    }

    @Test("wrong ownership and exact-size failures are rejected before mapping")
    func metadataRejectedBeforeMapping() throws {
        let expectedSize = try IdleScreenCameraFrameMailboxLayout.current.expectedFileByteCount()
        let metadataCases = [
            IdleScreenCameraFrameFileMetadata(
                kind: .regularFile,
                ownerUserID: geteuid() + 1,
                permissions: 0o600,
                byteCount: UInt64(expectedSize)
            ),
            IdleScreenCameraFrameFileMetadata(
                kind: .regularFile,
                ownerUserID: geteuid(),
                permissions: 0o600,
                byteCount: UInt64(expectedSize - 1)
            ),
            IdleScreenCameraFrameFileMetadata(
                kind: .regularFile,
                ownerUserID: geteuid(),
                permissions: 0o600,
                byteCount: UInt64(expectedSize + 1)
            ),
        ]

        for metadata in metadataCases {
            let file = MetadataOnlyFile(metadata: metadata)
            #expect(throws: IdleScreenCameraFrameMappingError.self) {
                try IdleScreenCameraFrameMailboxMapping(
                    contentsOf: URL(fileURLWithPath: "/unused-test-path"),
                    storage: MetadataOnlyStorage(file: file),
                    generationLoader: ScriptedGenerationLoader([2])
                )
            }
            #expect(file.mapCallCount == 0)
        }
    }

    @Test("snapshot attempt limits are positive and capped")
    func snapshotAttemptLimitValidation() throws {
        let metadata = IdleScreenCameraFrameFileMetadata(
            kind: .regularFile,
            ownerUserID: geteuid(),
            permissions: 0o600,
            byteCount: UInt64(try IdleScreenCameraFrameMailboxLayout.current.expectedFileByteCount())
        )

        for invalidLimit in [0, IdleScreenCameraFrameMailboxMapping.maximumSnapshotAttemptLimit + 1] {
            #expect(
                throws: IdleScreenCameraFrameMappingError.invalidSnapshotAttemptLimit(invalidLimit)
            ) {
                try IdleScreenCameraFrameMailboxMapping(
                    contentsOf: URL(fileURLWithPath: "/unused-test-path"),
                    storage: MetadataOnlyStorage(file: MetadataOnlyFile(metadata: metadata)),
                    generationLoader: ScriptedGenerationLoader([2]),
                    snapshotAttemptLimit: invalidLimit
                )
            }
        }
    }
}
