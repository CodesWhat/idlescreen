import Darwin
import Foundation
import IdleScreenCamera
import CoreVideo
import Testing
@testable import IdleScreenCameraAgentCore

@Suite("Camera frame mailbox writer", .serialized)
struct CameraFrameMailboxWriterTests {
    @Test("creates one fixed-size private mailbox inside the injected container")
    func createsFixedPrivateMailbox() throws {
        try withTemporaryDirectory { containerURL in
            let layout = try IdleScreenCameraFrameMailboxLayout(
                slotCount: 3,
                slotByteCapacity: 256
            )

            let writer = try CameraFrameMailboxWriter(
                appGroupContainerURL: containerURL,
                mailboxFileName: "camera-frames-v1.mailbox",
                layout: layout
            )

            let mailboxURL = containerURL.appendingPathComponent(
                "camera-frames-v1.mailbox",
                isDirectory: false
            )
            let attributes = try FileManager.default.attributesOfItem(
                atPath: mailboxURL.path
            )
            #expect(writer.mailboxURL == mailboxURL)
            #expect(attributes[.type] as? FileAttributeType == .typeRegular)
            #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
            #expect(attributes[.size] as? NSNumber == NSNumber(
                value: try layout.expectedFileByteCount()
            ))
            #expect(try generation(at: mailboxURL) == 0)
        }
    }

    @Test("rejects a mailbox symbolic link without following it")
    func rejectsMailboxSymbolicLink() throws {
        try withTemporaryDirectory { containerURL in
            let targetURL = containerURL.appendingPathComponent("target.mailbox")
            let mailboxURL = containerURL.appendingPathComponent("camera-frames-v1.mailbox")
            #expect(FileManager.default.createFile(
                atPath: targetURL.path,
                contents: Data(),
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            ))
            try FileManager.default.createSymbolicLink(
                at: mailboxURL,
                withDestinationURL: targetURL
            )

            #expect(throws: CameraFrameMailboxWriterError.symbolicLinkRejected) {
                _ = try CameraFrameMailboxWriter(
                    appGroupContainerURL: containerURL,
                    mailboxFileName: "camera-frames-v1.mailbox"
                )
            }
        }
    }

    @Test("rejects a hard-linked mailbox that escapes the injected container")
    func rejectsMailboxHardLink() throws {
        try withTemporaryDirectory { containerURL in
            let layout = try IdleScreenCameraFrameMailboxLayout(
                slotCount: 3,
                slotByteCapacity: 256
            )
            let externalURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "idlescreen-mailbox-hardlink-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: externalURL) }
            try createSizedFile(
                at: externalURL,
                byteCount: layout.expectedFileByteCount(),
                permissions: 0o600
            )
            let mailboxURL = containerURL.appendingPathComponent("camera-frames-v1.mailbox")
            try FileManager.default.linkItem(at: externalURL, to: mailboxURL)

            #expect(throws: CameraFrameMailboxWriterError.invalidMailboxLinkCount(2)) {
                _ = try CameraFrameMailboxWriter(
                    appGroupContainerURL: containerURL,
                    layout: layout
                )
            }
        }
    }

    @Test("publishes one packed BGRA frame with a validated header")
    func publishesPackedBGRAFrame() throws {
        try withTemporaryDirectory { containerURL in
            let layout = try IdleScreenCameraFrameMailboxLayout(
                slotCount: 3,
                slotByteCapacity: 64
            )
            let writer = try CameraFrameMailboxWriter(
                appGroupContainerURL: containerURL,
                layout: layout
            )
            try writer.startStream(streamEpoch: 7)
            let source: [UInt8] = [
                1, 2, 3, 4, 5, 6, 7, 8, 201, 202, 203, 204,
                9, 10, 11, 12, 13, 14, 15, 16, 205, 206, 207, 208
            ]

            let descriptor = try source.withUnsafeBytes { bytes in
                try writer.publish(
                    bytes: bytes,
                    width: 2,
                    height: 2,
                    sourceBytesPerRow: 12,
                    timestamp: 123
                )
            }

            #expect(descriptor.streamEpoch == 7)
            #expect(descriptor.sequence == 1)
            #expect(descriptor.slotIndex == 0)
            #expect(descriptor.slotCount == 3)
            #expect(descriptor.width == 2)
            #expect(descriptor.height == 2)
            #expect(descriptor.bytesPerRow == 8)
            let snapshot = try mailboxSnapshot(
                at: writer.mailboxURL,
                layout: layout
            )
            #expect(snapshot.header.generation > 0)
            #expect(snapshot.header.generation.isMultiple(of: 2))
            #expect(try snapshot.header.validated(for: layout) == descriptor)
            #expect(snapshot.payload == [
                1, 2, 3, 4, 5, 6, 7, 8,
                9, 10, 11, 12, 13, 14, 15, 16
            ])
        }
    }

    @Test("keeps generation odd until the final release-store publishes the frame")
    func preservesAtomicGenerationDuringHeaderCopy() throws {
        try withTemporaryDirectory { containerURL in
            let layout = try IdleScreenCameraFrameMailboxLayout(
                slotCount: 3,
                slotByteCapacity: 64
            )
            let atomics = RecordingMailboxAtomics()
            let writer = try CameraFrameMailboxWriter(
                appGroupContainerURL: containerURL,
                layout: layout,
                atomicOperations: atomics
            )
            try writer.startStream(streamEpoch: 1)
            atomics.removeAllEvents()
            let source = [UInt8](repeating: 17, count: 16)

            _ = try source.withUnsafeBytes { bytes in
                try writer.publish(
                    bytes: bytes,
                    width: 2,
                    height: 2,
                    sourceBytesPerRow: 8,
                    timestamp: 1
                )
            }

            #expect(atomics.events == [
                .load(value: 0),
                .fetchAdd(previous: 0, resulting: 1),
                .storeRelease(value: 2, observedBeforeStore: 1)
            ])
        }
    }

    @Test("rotates three slots and invalidates stale frames between stream epochs")
    func rotatesSlotsAndInvalidatesStoppedStream() throws {
        try withTemporaryDirectory { containerURL in
            let layout = try IdleScreenCameraFrameMailboxLayout(
                slotCount: 3,
                slotByteCapacity: 64
            )
            let writer = try CameraFrameMailboxWriter(
                appGroupContainerURL: containerURL,
                layout: layout
            )
            try writer.startStream(streamEpoch: 4)
            let source = [UInt8](repeating: 33, count: 16)

            var descriptors: [IdleScreenCameraFrameDescriptor] = []
            for timestamp in 1...4 {
                descriptors.append(try source.withUnsafeBytes { bytes in
                    try writer.publish(
                        bytes: bytes,
                        width: 2,
                        height: 2,
                        sourceBytesPerRow: 8,
                        timestamp: TimeInterval(timestamp)
                    )
                })
            }
            #expect(descriptors.map(\.sequence) == [1, 2, 3, 4])
            #expect(descriptors.map(\.slotIndex) == [0, 1, 2, 0])

            try writer.stopStream()
            #expect(try generation(at: writer.mailboxURL) == 0)
            #expect(throws: CameraFrameMailboxWriterError.streamNotActive) {
                _ = try source.withUnsafeBytes { bytes in
                    try writer.publish(
                        bytes: bytes,
                        width: 2,
                        height: 2,
                        sourceBytesPerRow: 8,
                        timestamp: 5
                    )
                }
            }
            #expect(throws: CameraFrameMailboxWriterError.nonmonotonicStreamEpoch(
                previous: 4,
                proposed: 3
            )) {
                try writer.startStream(streamEpoch: 3)
            }

            try writer.startStream(streamEpoch: 5)
            #expect(try generation(at: writer.mailboxURL) == 0)
            let restarted = try source.withUnsafeBytes { bytes in
                try writer.publish(
                    bytes: bytes,
                    width: 2,
                    height: 2,
                    sourceBytesPerRow: 8,
                    timestamp: 6
                )
            }
            #expect(restarted.streamEpoch == 5)
            #expect(restarted.sequence == 1)
            #expect(restarted.slotIndex == 0)
        }
    }

    @Test("resumes one logical producer epoch without resetting its frame sequence")
    func resumesLogicalProducerEpoch() throws {
        try withTemporaryDirectory { containerURL in
            let layout = try IdleScreenCameraFrameMailboxLayout(
                slotCount: 3,
                slotByteCapacity: 64
            )
            let writer = try CameraFrameMailboxWriter(
                appGroupContainerURL: containerURL,
                layout: layout
            )
            let source = [UInt8](repeating: 44, count: 16)
            try writer.startStream(streamEpoch: 7)
            let first = try source.withUnsafeBytes { bytes in
                try writer.publish(
                    bytes: bytes,
                    width: 2,
                    height: 2,
                    sourceBytesPerRow: 8,
                    timestamp: 1
                )
            }
            #expect(first.streamEpoch == 7)
            #expect(first.sequence == 1)

            try writer.stopStream()
            #expect(try Data(contentsOf: writer.mailboxURL).allSatisfy { $0 == 0 })
            try writer.startStream(streamEpoch: 7)
            let resumed = try source.withUnsafeBytes { bytes in
                try writer.publish(
                    bytes: bytes,
                    width: 2,
                    height: 2,
                    sourceBytesPerRow: 8,
                    timestamp: 2
                )
            }
            #expect(resumed.streamEpoch == 7)
            #expect(resumed.sequence == 2)
            #expect(throws: CameraFrameMailboxWriterError.streamAlreadyActive(epoch: 7)) {
                try writer.startStream(streamEpoch: 7)
            }

            try writer.stopStream()
            #expect(throws: CameraFrameMailboxWriterError.nonmonotonicStreamEpoch(
                previous: 7,
                proposed: 6
            )) {
                try writer.startStream(streamEpoch: 6)
            }
            try writer.startStream(streamEpoch: 8)
            let newer = try source.withUnsafeBytes { bytes in
                try writer.publish(
                    bytes: bytes,
                    width: 2,
                    height: 2,
                    sourceBytesPerRow: 8,
                    timestamp: 3
                )
            }
            #expect(newer.streamEpoch == 8)
            #expect(newer.sequence == 1)
        }
    }

    @Test("terminal invalidation clears the frame and rejects every later publish")
    func terminalInvalidationClearsAndClosesWriter() throws {
        try withTemporaryDirectory { containerURL in
            let layout = try IdleScreenCameraFrameMailboxLayout(
                slotCount: 3,
                slotByteCapacity: 64
            )
            let writer = try CameraFrameMailboxWriter(
                appGroupContainerURL: containerURL,
                layout: layout
            )
            try writer.startStream(streamEpoch: 1)
            let source = [UInt8](repeating: 222, count: 16)
            _ = try source.withUnsafeBytes { bytes in
                try writer.publish(
                    bytes: bytes,
                    width: 2,
                    height: 2,
                    sourceBytesPerRow: 8,
                    timestamp: 1
                )
            }

            try writer.invalidate()

            #expect(try Data(contentsOf: writer.mailboxURL).allSatisfy { $0 == 0 })
            #expect(throws: CameraFrameMailboxWriterError.writerInvalidated) {
                try writer.startStream(streamEpoch: 2)
            }
            #expect(throws: CameraFrameMailboxWriterError.writerInvalidated) {
                _ = try source.withUnsafeBytes { bytes in
                    try writer.publish(
                        bytes: bytes,
                        width: 2,
                        height: 2,
                        sourceBytesPerRow: 8,
                        timestamp: 2
                    )
                }
            }
            try writer.invalidate()
            #expect(try generation(at: writer.mailboxURL) == 0)
        }
    }

    @Test("publishes a locked BGRA pixel buffer with stride-correct row copies")
    func publishesBGRAPixelBuffer() throws {
        try withTemporaryDirectory { containerURL in
            let layout = try IdleScreenCameraFrameMailboxLayout(
                slotCount: 3,
                slotByteCapacity: 128
            )
            let writer = try CameraFrameMailboxWriter(
                appGroupContainerURL: containerURL,
                layout: layout
            )
            try writer.startStream(streamEpoch: 9)
            let pixelBuffer = try makePixelBuffer(width: 2, height: 2)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            #expect(bytesPerRow >= 8)
            #expect(CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess)
            let baseAddress = try #require(CVPixelBufferGetBaseAddress(pixelBuffer))
            memset(baseAddress, 0, bytesPerRow * 2)
            let firstRow: [UInt8] = [1, 3, 5, 7, 9, 11, 13, 15]
            let secondRow: [UInt8] = [2, 4, 6, 8, 10, 12, 14, 16]
            _ = firstRow.withUnsafeBytes { memcpy(baseAddress, $0.baseAddress!, 8) }
            _ = secondRow.withUnsafeBytes {
                memcpy(baseAddress.advanced(by: bytesPerRow), $0.baseAddress!, 8)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let frame = CameraCaptureFrame(
                pixelBuffer: pixelBuffer,
                metadata: CameraCaptureFrameMetadata(
                    sequence: 500,
                    presentationTimeSeconds: 42,
                    width: 2,
                    height: 2,
                    bytesPerRow: bytesPerRow,
                    pixelFormat: kCVPixelFormatType_32BGRA
                )
            )

            let descriptor = try writer.publish(frame)

            #expect(descriptor.streamEpoch == 9)
            #expect(descriptor.sequence == 1)
            #expect(descriptor.bytesPerRow == 8)
            let snapshot = try mailboxSnapshot(at: writer.mailboxURL, layout: layout)
            #expect(snapshot.payload == firstRow + secondRow)
        }
    }

    @Test("rejects layouts that cannot rotate the required three mailbox slots")
    func rejectsNonTripleSlotLayout() throws {
        try withTemporaryDirectory { containerURL in
            let layout = try IdleScreenCameraFrameMailboxLayout(
                slotCount: 2,
                slotByteCapacity: 64
            )

            #expect(throws: CameraFrameMailboxWriterError.invalidMailboxSlotCount(
                expected: 3,
                actual: 2
            )) {
                _ = try CameraFrameMailboxWriter(
                    appGroupContainerURL: containerURL,
                    layout: layout
                )
            }
            #expect(try FileManager.default.contentsOfDirectory(
                at: containerURL,
                includingPropertiesForKeys: nil
            ).isEmpty)
        }
    }

    @Test(arguments: ["", ".", "..", "../escape", "nested/mailbox", "/tmp/escape"])
    func rejectsMailboxPathEscape(_ fileName: String) throws {
        _ = try withTemporaryDirectory { containerURL in
            #expect(throws: CameraFrameMailboxWriterError.invalidMailboxFileName(fileName)) {
                _ = try CameraFrameMailboxWriter(
                    appGroupContainerURL: containerURL,
                    mailboxFileName: fileName
                )
            }
        }
    }

    @Test(arguments: [-1, 1])
    func rejectsNonExactExistingMailboxSize(_ sizeDelta: Int) throws {
        try withTemporaryDirectory { containerURL in
            let layout = try IdleScreenCameraFrameMailboxLayout(
                slotCount: 3,
                slotByteCapacity: 64
            )
            let expectedByteCount = try layout.expectedFileByteCount()
            let mailboxURL = containerURL.appendingPathComponent("camera-frames-v1.mailbox")
            try createSizedFile(
                at: mailboxURL,
                byteCount: expectedByteCount + sizeDelta,
                permissions: 0o600
            )
            let expectedError: CameraFrameMailboxWriterError = sizeDelta < 0
                ? .truncatedMailbox(expected: expectedByteCount, actual: UInt64(expectedByteCount - 1))
                : .oversizedMailbox(expected: expectedByteCount, actual: UInt64(expectedByteCount + 1))

            #expect(throws: expectedError) {
                _ = try CameraFrameMailboxWriter(
                    appGroupContainerURL: containerURL,
                    layout: layout
                )
            }
        }
    }

    @Test("rejects an existing mailbox with broader permissions")
    func rejectsExistingMailboxPermissions() throws {
        try withTemporaryDirectory { containerURL in
            let layout = try IdleScreenCameraFrameMailboxLayout(
                slotCount: 3,
                slotByteCapacity: 64
            )
            let mailboxURL = containerURL.appendingPathComponent("camera-frames-v1.mailbox")
            try createSizedFile(
                at: mailboxURL,
                byteCount: layout.expectedFileByteCount(),
                permissions: 0o640
            )

            #expect(throws: CameraFrameMailboxWriterError.invalidMailboxPermissions(
                expected: 0o600,
                actual: 0o640
            )) {
                _ = try CameraFrameMailboxWriter(
                    appGroupContainerURL: containerURL,
                    layout: layout
                )
            }
        }
    }

    private func withTemporaryDirectory<Result>(
        _ body: (URL) throws -> Result
    ) throws -> Result {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "idlescreen-mailbox-writer-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    private func generation(at mailboxURL: URL) throws -> UInt64 {
        let data = try Data(contentsOf: mailboxURL)
        return data.withUnsafeBytes { bytes in
            var result: UInt64 = 0
            for index in 0..<MemoryLayout<UInt64>.size {
                result |= UInt64(bytes[16 + index]) << UInt64(index * 8)
            }
            return result
        }
    }

    private func createSizedFile(
        at url: URL,
        byteCount: Int,
        permissions: mode_t
    ) throws {
        let descriptor = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw POSIXError(.EINVAL) }
            let descriptor = Darwin.open(
                path,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
                permissions
            )
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
            return descriptor
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, permissions) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        guard Darwin.ftruncate(descriptor, off_t(byteCount)) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }

    private func mailboxSnapshot(
        at url: URL,
        layout: IdleScreenCameraFrameMailboxLayout
    ) throws -> (header: IdleScreenCameraFrameMailboxHeader, payload: [UInt8]) {
        let data = try Data(contentsOf: url)
        let header = try data.withUnsafeBytes { bytes in
            try IdleScreenCameraFrameMailboxHeader.decode(
                from: UnsafeRawBufferPointer(
                    start: bytes.baseAddress,
                    count: Int(layout.headerByteCount)
                )
            )
        }
        let payloadOffset = try layout.payloadOffset(forSlot: header.slotIndex)
        let payloadByteCount = Int(header.payloadByteCount)
        return (
            header,
            Array(data[payloadOffset..<(payloadOffset + payloadByteCount)])
        )
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferBytesPerRowAlignmentKey as String: NSNumber(value: 64)
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw POSIXError(.ENOMEM)
        }
        return pixelBuffer
    }
}

private final class RecordingMailboxAtomics:
    CameraFrameMailboxAtomicOperations,
    @unchecked Sendable
{
    enum Event: Equatable {
        case load(value: UInt64)
        case fetchAdd(previous: UInt64, resulting: UInt64)
        case storeRelease(value: UInt64, observedBeforeStore: UInt64)
    }

    private let lock = NSLock()
    private(set) var events: [Event] = []

    func removeAllEvents() {
        lock.withLock { events.removeAll(keepingCapacity: true) }
    }

    func loadAcquire(from address: UnsafeRawPointer) throws -> UInt64 {
        lock.withLock {
            let value = read(from: address)
            events.append(.load(value: value))
            return value
        }
    }

    func fetchAddAcqRel(
        at address: UnsafeMutableRawPointer,
        operand: UInt64
    ) throws -> UInt64 {
        lock.withLock {
            let previous = read(from: UnsafeRawPointer(address))
            let resulting = previous &+ operand
            write(resulting, to: address)
            events.append(.fetchAdd(previous: previous, resulting: resulting))
            return previous
        }
    }

    func storeRelease(_ value: UInt64, to address: UnsafeMutableRawPointer) throws {
        lock.withLock {
            let previous = read(from: UnsafeRawPointer(address))
            events.append(.storeRelease(value: value, observedBeforeStore: previous))
            write(value, to: address)
        }
    }

    private func read(from address: UnsafeRawPointer) -> UInt64 {
        var value: UInt64 = 0
        memcpy(&value, address, MemoryLayout<UInt64>.size)
        return UInt64(littleEndian: value)
    }

    private func write(_ value: UInt64, to address: UnsafeMutableRawPointer) {
        var littleEndian = value.littleEndian
        memcpy(address, &littleEndian, MemoryLayout<UInt64>.size)
    }
}
