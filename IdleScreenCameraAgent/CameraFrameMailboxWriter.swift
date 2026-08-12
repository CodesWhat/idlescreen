import CoreVideo
import Darwin
import Foundation
import IdleScreenCamera
import IdleScreenCameraAtomics
import OSLog

public enum CameraFrameMailboxWriterError: Swift.Error, Equatable, Sendable {
    case invalidContainerURL
    case invalidMailboxFileName(String)
    case invalidMailboxSlotCount(expected: UInt64, actual: UInt64)
    case symbolicLinkRejected
    case containerOpenFailed(Int32)
    case containerStatFailed(Int32)
    case containerIsNotDirectory
    case invalidContainerOwner(expected: uid_t, actual: uid_t)
    case mailboxOpenFailed(Int32)
    case mailboxStatFailed(Int32)
    case mailboxIsNotRegularFile
    case invalidMailboxLinkCount(UInt64)
    case invalidMailboxOwner(expected: uid_t, actual: uid_t)
    case invalidMailboxPermissions(expected: UInt16, actual: UInt16)
    case truncatedMailbox(expected: Int, actual: UInt64)
    case oversizedMailbox(expected: Int, actual: UInt64)
    case mailboxAllocationFailed(Int32)
    case mailboxPermissionUpdateFailed(Int32)
    case mailboxMappingFailed(Int32)
    case atomicOperationFailed(Int32)
    case writerInvalidated
    case invalidStreamEpoch(UInt64)
    case nonmonotonicStreamEpoch(previous: UInt64, proposed: UInt64)
    case streamAlreadyActive(epoch: UInt64)
    case streamNotActive
    case invalidTimestamp
    case invalidDimensions(width: Int, height: Int)
    case sourceRowByteCountOverflow
    case invalidSourceBytesPerRow(minimum: Int, actual: Int)
    case sourceByteCountOverflow
    case sourceBufferTooSmall(required: Int, actual: Int)
    case frameExceedsSlotCapacity(required: Int, capacity: UInt64)
    case invalidGeneration(UInt64)
    case generationExhausted
    case sequenceExhausted
    case unsupportedPixelFormat(OSType)
    case planarPixelBuffer
    case frameMetadataMismatch
    case pixelBufferLockFailed(CVReturn)
    case missingPixelBufferBaseAddress
}

protocol CameraFrameMailboxAtomicOperations: Sendable {
    func loadAcquire(from address: UnsafeRawPointer) throws -> UInt64
    func fetchAddAcqRel(
        at address: UnsafeMutableRawPointer,
        operand: UInt64
    ) throws -> UInt64
    func storeRelease(_ value: UInt64, to address: UnsafeMutableRawPointer) throws
}

private struct C11CameraFrameMailboxAtomicOperations:
    CameraFrameMailboxAtomicOperations,
    Sendable
{
    func loadAcquire(from address: UnsafeRawPointer) throws -> UInt64 {
        var value: UInt64 = 0
        let status = idle_screen_camera_atomic_load_uint64_acquire(address, &value)
        guard status == IdleScreenCameraAtomicStatusOK else {
            throw CameraFrameMailboxWriterError.atomicOperationFailed(status)
        }
        return value
    }

    func fetchAddAcqRel(
        at address: UnsafeMutableRawPointer,
        operand: UInt64
    ) throws -> UInt64 {
        var previousValue: UInt64 = 0
        let status = idle_screen_camera_atomic_fetch_add_uint64_acq_rel(
            address,
            operand,
            &previousValue
        )
        guard status == IdleScreenCameraAtomicStatusOK else {
            throw CameraFrameMailboxWriterError.atomicOperationFailed(status)
        }
        return previousValue
    }

    func storeRelease(_ value: UInt64, to address: UnsafeMutableRawPointer) throws {
        let status = idle_screen_camera_atomic_store_uint64_release(address, value)
        guard status == IdleScreenCameraAtomicStatusOK else {
            throw CameraFrameMailboxWriterError.atomicOperationFailed(status)
        }
    }
}

/// Owns one fixed-size, private frame mailbox inside an injected App Group container.
///
/// The writer never derives a path or allocation size from a client request. The
/// container and leaf file are opened without following symbolic links, and the
/// mapped storage is allocated once for the lifetime of the writer.
public final class CameraFrameMailboxWriter: @unchecked Sendable {
    private static let performanceSignposter = OSSignposter(
        subsystem: "com.idlescreen.camera-agent",
        category: "Performance"
    )
    public let mailboxURL: URL

    private let descriptor: Int32
    private let mappedAddress: UnsafeMutableRawPointer
    private let mappedByteCount: Int
    private let layout: IdleScreenCameraFrameMailboxLayout
    private let atomicOperations: any CameraFrameMailboxAtomicOperations
    private let lock = NSLock()
    private var activeStreamEpoch: UInt64?
    private var lastStreamEpoch: UInt64 = 0
    private var nextSequence: UInt64 = 1
    private var nextSlotIndex: UInt64 = 0
    private var isInvalidated = false

    public convenience init(
        appGroupContainerURL: URL,
        mailboxFileName: String = "camera-frames-v1.mailbox",
        layout: IdleScreenCameraFrameMailboxLayout = .current,
        expectedOwnerUserID: uid_t = geteuid()
    ) throws {
        try self.init(
            appGroupContainerURL: appGroupContainerURL,
            mailboxFileName: mailboxFileName,
            layout: layout,
            expectedOwnerUserID: expectedOwnerUserID,
            atomicOperations: C11CameraFrameMailboxAtomicOperations()
        )
    }

    init(
        appGroupContainerURL: URL,
        mailboxFileName: String = "camera-frames-v1.mailbox",
        layout: IdleScreenCameraFrameMailboxLayout = .current,
        expectedOwnerUserID: uid_t = geteuid(),
        atomicOperations: any CameraFrameMailboxAtomicOperations
    ) throws {
        guard appGroupContainerURL.isFileURL else {
            throw CameraFrameMailboxWriterError.invalidContainerURL
        }
        guard Self.isValidLeafFileName(mailboxFileName) else {
            throw CameraFrameMailboxWriterError.invalidMailboxFileName(mailboxFileName)
        }
        guard layout.slotCount == IdleScreenCameraFrameDescriptor.maximumSlotCount else {
            throw CameraFrameMailboxWriterError.invalidMailboxSlotCount(
                expected: IdleScreenCameraFrameDescriptor.maximumSlotCount,
                actual: layout.slotCount
            )
        }

        let expectedByteCount = try layout.expectedFileByteCount()
        let containerDescriptor: Int32 = try appGroupContainerURL
            .withUnsafeFileSystemRepresentation { path in
                guard let path else {
                    throw CameraFrameMailboxWriterError.invalidContainerURL
                }
                let opened = Darwin.open(
                    path,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
                )
                guard opened >= 0 else {
                    if errno == ELOOP {
                        throw CameraFrameMailboxWriterError.symbolicLinkRejected
                    }
                    throw CameraFrameMailboxWriterError.containerOpenFailed(errno)
                }
                return opened
            }
        defer { Darwin.close(containerDescriptor) }

        var containerStatus = stat()
        guard Darwin.fstat(containerDescriptor, &containerStatus) == 0 else {
            throw CameraFrameMailboxWriterError.containerStatFailed(errno)
        }
        guard (containerStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw CameraFrameMailboxWriterError.containerIsNotDirectory
        }
        guard containerStatus.st_uid == expectedOwnerUserID else {
            throw CameraFrameMailboxWriterError.invalidContainerOwner(
                expected: expectedOwnerUserID,
                actual: containerStatus.st_uid
            )
        }

        var created = false
        let openedDescriptor: Int32 = try mailboxFileName.withCString { fileName in
            let newlyCreated = Darwin.openat(
                containerDescriptor,
                fileName,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL,
                mode_t(0o600)
            )
            if newlyCreated >= 0 {
                created = true
                return newlyCreated
            }
            guard errno == EEXIST else {
                throw CameraFrameMailboxWriterError.mailboxOpenFailed(errno)
            }
            let existing = Darwin.openat(
                containerDescriptor,
                fileName,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
            guard existing >= 0 else {
                if errno == ELOOP {
                    throw CameraFrameMailboxWriterError.symbolicLinkRejected
                }
                throw CameraFrameMailboxWriterError.mailboxOpenFailed(errno)
            }
            return existing
        }

        do {
            var mailboxStatus = stat()
            guard Darwin.fstat(openedDescriptor, &mailboxStatus) == 0 else {
                throw CameraFrameMailboxWriterError.mailboxStatFailed(errno)
            }
            guard (mailboxStatus.st_mode & S_IFMT) == S_IFREG else {
                throw CameraFrameMailboxWriterError.mailboxIsNotRegularFile
            }
            guard mailboxStatus.st_nlink == 1 else {
                throw CameraFrameMailboxWriterError.invalidMailboxLinkCount(
                    UInt64(mailboxStatus.st_nlink)
                )
            }
            guard mailboxStatus.st_uid == expectedOwnerUserID else {
                throw CameraFrameMailboxWriterError.invalidMailboxOwner(
                    expected: expectedOwnerUserID,
                    actual: mailboxStatus.st_uid
                )
            }

            if created {
                guard Darwin.fchmod(openedDescriptor, mode_t(0o600)) == 0 else {
                    throw CameraFrameMailboxWriterError
                        .mailboxPermissionUpdateFailed(errno)
                }
                guard Darwin.ftruncate(openedDescriptor, off_t(expectedByteCount)) == 0 else {
                    throw CameraFrameMailboxWriterError.mailboxAllocationFailed(errno)
                }
            } else {
                let permissions = UInt16(mailboxStatus.st_mode & 0o777)
                guard permissions == 0o600 else {
                    throw CameraFrameMailboxWriterError.invalidMailboxPermissions(
                        expected: 0o600,
                        actual: permissions
                    )
                }
                guard mailboxStatus.st_size >= 0 else {
                    throw CameraFrameMailboxWriterError.truncatedMailbox(
                        expected: expectedByteCount,
                        actual: 0
                    )
                }
                let actualByteCount = UInt64(mailboxStatus.st_size)
                guard actualByteCount >= UInt64(expectedByteCount) else {
                    throw CameraFrameMailboxWriterError.truncatedMailbox(
                        expected: expectedByteCount,
                        actual: actualByteCount
                    )
                }
                guard actualByteCount <= UInt64(expectedByteCount) else {
                    throw CameraFrameMailboxWriterError.oversizedMailbox(
                        expected: expectedByteCount,
                        actual: actualByteCount
                    )
                }
            }

            let mapping = Darwin.mmap(
                nil,
                expectedByteCount,
                PROT_READ | PROT_WRITE,
                MAP_SHARED,
                openedDescriptor,
                0
            )
            guard mapping != MAP_FAILED, let mapping else {
                throw CameraFrameMailboxWriterError.mailboxMappingFailed(errno)
            }

            let generationAddress = mapping.advanced(
                by: IdleScreenCameraFrameMailboxMapping.generationByteOffset
            )
            do {
                try atomicOperations.storeRelease(0, to: generationAddress)
            } catch {
                Darwin.munmap(mapping, expectedByteCount)
                throw error
            }
            Self.clearNonAtomicBytes(
                at: mapping,
                mappedByteCount: expectedByteCount
            )

            descriptor = openedDescriptor
            mappedAddress = mapping
            mappedByteCount = expectedByteCount
            self.layout = layout
            self.atomicOperations = atomicOperations
            mailboxURL = appGroupContainerURL.appendingPathComponent(
                mailboxFileName,
                isDirectory: false
            )
        } catch {
            Darwin.close(openedDescriptor)
            throw error
        }
    }

    deinit {
        let generationAddress = mappedAddress.advanced(
            by: IdleScreenCameraFrameMailboxMapping.generationByteOffset
        )
        try? atomicOperations.storeRelease(0, to: generationAddress)
        Self.clearNonAtomicBytes(
            at: mappedAddress,
            mappedByteCount: mappedByteCount
        )
        Darwin.munmap(mappedAddress, mappedByteCount)
        Darwin.close(descriptor)
    }

    public func startStream(streamEpoch: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else {
            throw CameraFrameMailboxWriterError.writerInvalidated
        }
        if let activeStreamEpoch {
            throw CameraFrameMailboxWriterError.streamAlreadyActive(
                epoch: activeStreamEpoch
            )
        }
        guard streamEpoch > 0 else {
            throw CameraFrameMailboxWriterError.invalidStreamEpoch(streamEpoch)
        }
        guard streamEpoch >= lastStreamEpoch else {
            throw CameraFrameMailboxWriterError.nonmonotonicStreamEpoch(
                previous: lastStreamEpoch,
                proposed: streamEpoch
            )
        }
        try storeReleaseGeneration(0)
        Self.clearNonAtomicBytes(
            at: mappedAddress,
            mappedByteCount: mappedByteCount
        )
        if streamEpoch > lastStreamEpoch {
            lastStreamEpoch = streamEpoch
            nextSequence = 1
            nextSlotIndex = 0
        }
        activeStreamEpoch = streamEpoch
    }

    public func stopStream() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else { return }
        try storeReleaseGeneration(0)
        Self.clearNonAtomicBytes(
            at: mappedAddress,
            mappedByteCount: mappedByteCount
        )
        activeStreamEpoch = nil
    }

    public func invalidate() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else { return }
        try storeReleaseGeneration(0)
        Self.clearNonAtomicBytes(
            at: mappedAddress,
            mappedByteCount: mappedByteCount
        )
        activeStreamEpoch = nil
        nextSequence = 1
        nextSlotIndex = 0
        isInvalidated = true
    }

    @discardableResult
    public func publish(
        _ frame: CameraCaptureFrame
    ) throws -> IdleScreenCameraFrameDescriptor {
        let pixelBuffer = frame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_32BGRA else {
            throw CameraFrameMailboxWriterError.unsupportedPixelFormat(pixelFormat)
        }
        guard !CVPixelBufferIsPlanar(pixelBuffer) else {
            throw CameraFrameMailboxWriterError.planarPixelBuffer
        }
        guard frame.metadata.width == width,
              frame.metadata.height == height,
              frame.metadata.bytesPerRow == bytesPerRow,
              frame.metadata.pixelFormat == pixelFormat else {
            throw CameraFrameMailboxWriterError.frameMetadataMismatch
        }
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw CameraFrameMailboxWriterError.pixelBufferLockFailed(lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw CameraFrameMailboxWriterError.missingPixelBufferBaseAddress
        }
        let (sourceByteCount, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow else {
            throw CameraFrameMailboxWriterError.sourceByteCountOverflow
        }
        return try publish(
            bytes: UnsafeRawBufferPointer(start: baseAddress, count: sourceByteCount),
            width: width,
            height: height,
            sourceBytesPerRow: bytesPerRow,
            timestamp: frame.metadata.presentationTimeSeconds
        )
    }

    @discardableResult
    public func publish(
        bytes: UnsafeRawBufferPointer,
        width: Int,
        height: Int,
        sourceBytesPerRow: Int,
        timestamp: TimeInterval
    ) throws -> IdleScreenCameraFrameDescriptor {
        let signpostState = Self.performanceSignposter.beginInterval(
            "MailboxPublish"
        )
        defer {
            Self.performanceSignposter.endInterval(
                "MailboxPublish",
                signpostState
            )
        }
        lock.lock()
        defer { lock.unlock() }

        guard !isInvalidated else {
            throw CameraFrameMailboxWriterError.writerInvalidated
        }
        guard let streamEpoch = activeStreamEpoch else {
            throw CameraFrameMailboxWriterError.streamNotActive
        }
        guard timestamp.isFinite, timestamp > 0 else {
            throw CameraFrameMailboxWriterError.invalidTimestamp
        }
        guard width > 0,
              height > 0,
              width <= Int(IdleScreenCameraFrameDescriptor.maximumWidth),
              height <= Int(IdleScreenCameraFrameDescriptor.maximumHeight) else {
            throw CameraFrameMailboxWriterError.invalidDimensions(
                width: width,
                height: height
            )
        }

        let (packedBytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow else {
            throw CameraFrameMailboxWriterError.sourceRowByteCountOverflow
        }
        guard sourceBytesPerRow >= packedBytesPerRow,
              sourceBytesPerRow <= Int(IdleScreenCameraFrameDescriptor.maximumBytesPerRow) else {
            throw CameraFrameMailboxWriterError.invalidSourceBytesPerRow(
                minimum: packedBytesPerRow,
                actual: sourceBytesPerRow
            )
        }
        let (requiredSourceByteCount, sourceOverflow) = sourceBytesPerRow
            .multipliedReportingOverflow(by: height)
        guard !sourceOverflow else {
            throw CameraFrameMailboxWriterError.sourceByteCountOverflow
        }
        guard bytes.count >= requiredSourceByteCount else {
            throw CameraFrameMailboxWriterError.sourceBufferTooSmall(
                required: requiredSourceByteCount,
                actual: bytes.count
            )
        }
        let (payloadByteCount, payloadOverflow) = packedBytesPerRow
            .multipliedReportingOverflow(by: height)
        guard !payloadOverflow else {
            throw CameraFrameMailboxWriterError.sourceByteCountOverflow
        }
        guard UInt64(payloadByteCount) <= layout.slotByteCapacity else {
            throw CameraFrameMailboxWriterError.frameExceedsSlotCapacity(
                required: payloadByteCount,
                capacity: layout.slotByteCapacity
            )
        }
        guard nextSequence > 0 else {
            throw CameraFrameMailboxWriterError.sequenceExhausted
        }

        let frameDescriptor = IdleScreenCameraFrameDescriptor(
            protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
            streamEpoch: streamEpoch,
            sequence: nextSequence,
            timestamp: timestamp,
            width: UInt64(width),
            height: UInt64(height),
            bytesPerRow: UInt64(packedBytesPerRow),
            pixelFormat: .bgra8Unorm,
            slotIndex: nextSlotIndex,
            slotCount: layout.slotCount
        )
        _ = try frameDescriptor.validated()

        let generationAddress = mappedAddress.advanced(
            by: IdleScreenCameraFrameMailboxMapping.generationByteOffset
        )
        let generation = try atomicOperations.loadAcquire(
            from: UnsafeRawPointer(generationAddress)
        )
        guard generation.isMultiple(of: 2) else {
            throw CameraFrameMailboxWriterError.invalidGeneration(generation)
        }
        guard generation <= UInt64.max - 2 else {
            throw CameraFrameMailboxWriterError.generationExhausted
        }

        let previousGeneration = try atomicOperations.fetchAddAcqRel(
            at: generationAddress,
            operand: 1
        )
        guard previousGeneration == generation,
              previousGeneration.isMultiple(of: 2) else {
            try? storeReleaseGeneration(0)
            throw CameraFrameMailboxWriterError.invalidGeneration(previousGeneration)
        }
        let finalGeneration = previousGeneration + 2

        guard let sourceBaseAddress = bytes.baseAddress else {
            try? storeReleaseGeneration(0)
            throw CameraFrameMailboxWriterError.sourceBufferTooSmall(
                required: requiredSourceByteCount,
                actual: bytes.count
            )
        }
        let payloadOffset = try layout.payloadOffset(forSlot: nextSlotIndex)
        let destinationBaseAddress = mappedAddress.advanced(by: payloadOffset)
        for row in 0..<height {
            memcpy(
                destinationBaseAddress.advanced(by: row * packedBytesPerRow),
                sourceBaseAddress.advanced(by: row * sourceBytesPerRow),
                packedBytesPerRow
            )
        }

        let header = IdleScreenCameraFrameMailboxHeader(
            generation: finalGeneration,
            descriptor: frameDescriptor
        )
        writeHeaderExcludingGeneration(header)
        try storeReleaseGeneration(finalGeneration)

        nextSlotIndex = (nextSlotIndex + 1) % layout.slotCount
        if nextSequence == UInt64.max {
            nextSequence = 0
        } else {
            nextSequence += 1
        }
        return frameDescriptor
    }

    private func storeReleaseGeneration(_ generation: UInt64) throws {
        try atomicOperations.storeRelease(
            generation,
            to: mappedAddress.advanced(
                by: IdleScreenCameraFrameMailboxMapping.generationByteOffset
            )
        )
    }

    private func writeHeaderExcludingGeneration(
        _ header: IdleScreenCameraFrameMailboxHeader
    ) {
        writeLittleEndian(header.magic, at: 0)
        writeLittleEndian(header.schemaVersion, at: 8)
        writeLittleEndian(header.headerByteCount, at: 12)
        // Byte range 16..<24 is the C11 atomic generation field. It is changed
        // only through `atomicOperations`, never through an ordinary copy.
        writeLittleEndian(header.streamEpoch, at: 24)
        writeLittleEndian(header.sequence, at: 32)
        writeLittleEndian(header.timestamp.bitPattern, at: 40)
        writeLittleEndian(header.width, at: 48)
        writeLittleEndian(header.height, at: 56)
        writeLittleEndian(header.bytesPerRow, at: 64)
        writeLittleEndian(header.pixelFormatRawValue, at: 72)
        writeLittleEndian(header.slotIndex, at: 80)
        writeLittleEndian(header.slotCount, at: 88)
        writeLittleEndian(header.payloadByteCount, at: 96)
        memset(mappedAddress.advanced(by: 104), 0, Int(layout.headerByteCount) - 104)
    }

    private func writeLittleEndian<Value: FixedWidthInteger>(
        _ value: Value,
        at byteOffset: Int
    ) {
        var littleEndian = value.littleEndian
        _ = withUnsafeBytes(of: &littleEndian) { bytes in
            memcpy(
                mappedAddress.advanced(by: byteOffset),
                bytes.baseAddress!,
                bytes.count
            )
        }
    }

    private static func clearNonAtomicBytes(
        at address: UnsafeMutableRawPointer,
        mappedByteCount: Int
    ) {
        memset(address, 0, 16)
        memset(address.advanced(by: 24), 0, mappedByteCount - 24)
    }

    private static func isValidLeafFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }
}
