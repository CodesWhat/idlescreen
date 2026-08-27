import Foundation
import Darwin
import OSLog

public enum IdleScreenCameraFrameFileKind: Equatable, Sendable {
    case regularFile
    case other
}

public struct IdleScreenCameraFrameFileMetadata: Equatable, Sendable {
    public let kind: IdleScreenCameraFrameFileKind
    public let ownerUserID: uid_t
    public let permissions: UInt16
    public let byteCount: UInt64

    public init(
        kind: IdleScreenCameraFrameFileKind,
        ownerUserID: uid_t,
        permissions: UInt16,
        byteCount: UInt64
    ) {
        self.kind = kind
        self.ownerUserID = ownerUserID
        self.permissions = permissions
        self.byteCount = byteCount
    }
}

public enum IdleScreenCameraFrameMappingError: Swift.Error, Equatable, Sendable {
    case invalidSnapshotAttemptLimit(Int)
    case openFailed(Int32)
    case symbolicLinkRejected
    case statFailed(Int32)
    case invalidFileSize(Int64)
    case notRegularFile
    case invalidOwner(expected: uid_t, actual: uid_t)
    case invalidPermissions(expected: UInt16, actual: UInt16)
    case truncatedFile(expected: Int, actual: UInt64)
    case oversizedFile(expected: Int, actual: UInt64)
    case mappingFailed(Int32)
    case mappedByteCountMismatch(expected: Int, actual: Int)
    case invalidCopyRange(offset: Int, count: Int, mappedByteCount: Int)
}

/// A read-only mapped region. The base address is exposed only so a sequence
/// loader can pass the generation field to a genuine interprocess atomic shim.
/// Reading that field with an ordinary Swift pointer load is not a supported
/// production implementation.
public protocol IdleScreenCameraMappedRegion: AnyObject {
    var byteCount: Int { get }
    var unsafeBaseAddress: UnsafeRawPointer { get }

    func copyBytes(
        at offset: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) throws
}

public protocol IdleScreenCameraFrameStorageFile: AnyObject {
    var metadata: IdleScreenCameraFrameFileMetadata { get }

    func mapReadOnly(byteCount: Int) throws -> any IdleScreenCameraMappedRegion
}

/// The storage seam makes security validation testable without touching the
/// real App Group. A production opener must implement the no-follow guarantee.
public protocol IdleScreenCameraFrameStorage {
    func openReadOnlyNoFollow(at url: URL) throws -> any IdleScreenCameraFrameStorageFile
}

/// Loads the seqlock generation using acquire semantics.
///
/// A later C/C++ shim should implement this with a portable interprocess atomic
/// primitive. Swift's ordinary `load(as:)` is deliberately not provided as a
/// default because it would make the mailbox appear safer than it is.
public protocol IdleScreenCameraGenerationLoading: AnyObject {
    func loadAcquireGeneration(
        from baseAddress: UnsafeRawPointer,
        byteOffset: Int
    ) throws -> UInt64
}

public struct IdleScreenCameraPOSIXFrameStorage: IdleScreenCameraFrameStorage {
    public init() {}

    public func openReadOnlyNoFollow(
        at url: URL
    ) throws -> any IdleScreenCameraFrameStorageFile {
        let descriptor: Int32 = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw IdleScreenCameraFrameMappingError.openFailed(EINVAL)
            }
            let opened = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard opened >= 0 else {
                let openError = errno
                if openError == ELOOP {
                    throw IdleScreenCameraFrameMappingError.symbolicLinkRejected
                }
                throw IdleScreenCameraFrameMappingError.openFailed(openError)
            }
            return opened
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            let statError = errno
            Darwin.close(descriptor)
            throw IdleScreenCameraFrameMappingError.statFailed(statError)
        }
        guard status.st_size >= 0 else {
            let invalidSize = status.st_size
            Darwin.close(descriptor)
            throw IdleScreenCameraFrameMappingError.invalidFileSize(invalidSize)
        }

        let fileKind: IdleScreenCameraFrameFileKind =
            (status.st_mode & S_IFMT) == S_IFREG ? .regularFile : .other
        let metadata = IdleScreenCameraFrameFileMetadata(
            kind: fileKind,
            ownerUserID: status.st_uid,
            permissions: UInt16(status.st_mode & 0o777),
            byteCount: UInt64(status.st_size)
        )
        return IdleScreenCameraPOSIXFrameStorageFile(
            descriptor: descriptor,
            metadata: metadata
        )
    }
}

private final class IdleScreenCameraPOSIXFrameStorageFile: IdleScreenCameraFrameStorageFile {
    let metadata: IdleScreenCameraFrameFileMetadata
    private let descriptor: Int32

    init(descriptor: Int32, metadata: IdleScreenCameraFrameFileMetadata) {
        self.descriptor = descriptor
        self.metadata = metadata
    }

    deinit {
        Darwin.close(descriptor)
    }

    func mapReadOnly(byteCount: Int) throws -> any IdleScreenCameraMappedRegion {
        let address = Darwin.mmap(nil, byteCount, PROT_READ, MAP_SHARED, descriptor, 0)
        guard address != MAP_FAILED, let address else {
            throw IdleScreenCameraFrameMappingError.mappingFailed(errno)
        }
        return IdleScreenCameraPOSIXMappedRegion(
            address: UnsafeRawPointer(address),
            byteCount: byteCount
        )
    }
}

private final class IdleScreenCameraPOSIXMappedRegion: IdleScreenCameraMappedRegion {
    let byteCount: Int
    let unsafeBaseAddress: UnsafeRawPointer

    init(address: UnsafeRawPointer, byteCount: Int) {
        unsafeBaseAddress = address
        self.byteCount = byteCount
    }

    deinit {
        Darwin.munmap(UnsafeMutableRawPointer(mutating: unsafeBaseAddress), byteCount)
    }

    func copyBytes(
        at offset: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) throws {
        let (end, overflow) = offset.addingReportingOverflow(destination.count)
        guard offset >= 0, !overflow, end <= byteCount else {
            throw IdleScreenCameraFrameMappingError.invalidCopyRange(
                offset: offset,
                count: destination.count,
                mappedByteCount: byteCount
            )
        }
        guard destination.count > 0 else { return }
        guard let destinationAddress = destination.baseAddress else {
            throw IdleScreenCameraFrameMappingError.invalidCopyRange(
                offset: offset,
                count: destination.count,
                mappedByteCount: byteCount
            )
        }
        memcpy(
            destinationAddress,
            unsafeBaseAddress.advanced(by: offset),
            destination.count
        )
    }
}

/// A read-only mailbox mapping with a bounded, non-blocking seqlock snapshot.
///
/// The callback's pixel buffer is valid only for the duration of the callback.
/// The buffer is preallocated once and reused; this type never logs pixel data.
public final class IdleScreenCameraFrameMailboxMapping {
    public static let maximumSnapshotAttemptLimit = 8
    public static let generationByteOffset = 16
    private static let performanceSignposter = OSSignposter(
        subsystem: "com.idlescreen.camera",
        category: "Performance"
    )

    private let layout: IdleScreenCameraFrameMailboxLayout
    private let region: any IdleScreenCameraMappedRegion
    private let generationLoader: any IdleScreenCameraGenerationLoading
    private let snapshotAttemptLimit: Int
    private let headerStorage: UnsafeMutableRawPointer
    private let frameStorage: UnsafeMutableRawPointer
    private let headerStorageByteCount: Int
    private let frameStorageByteCount: Int

    public convenience init(
        contentsOf url: URL,
        generationLoader: any IdleScreenCameraGenerationLoading,
        layout: IdleScreenCameraFrameMailboxLayout = .current,
        snapshotAttemptLimit: Int = 3,
        expectedOwnerUserID: uid_t = geteuid()
    ) throws {
        try self.init(
            contentsOf: url,
            storage: IdleScreenCameraPOSIXFrameStorage(),
            generationLoader: generationLoader,
            layout: layout,
            snapshotAttemptLimit: snapshotAttemptLimit,
            expectedOwnerUserID: expectedOwnerUserID
        )
    }

    public init(
        contentsOf url: URL,
        storage: any IdleScreenCameraFrameStorage,
        generationLoader: any IdleScreenCameraGenerationLoading,
        layout: IdleScreenCameraFrameMailboxLayout = .current,
        snapshotAttemptLimit: Int = 3,
        expectedOwnerUserID: uid_t = geteuid()
    ) throws {
        guard (1...Self.maximumSnapshotAttemptLimit).contains(snapshotAttemptLimit) else {
            throw IdleScreenCameraFrameMappingError
                .invalidSnapshotAttemptLimit(snapshotAttemptLimit)
        }

        let expectedByteCount = try layout.expectedFileByteCount()
        let file = try storage.openReadOnlyNoFollow(at: url)
        let metadata = file.metadata
        guard metadata.kind == .regularFile else {
            throw IdleScreenCameraFrameMappingError.notRegularFile
        }
        guard metadata.ownerUserID == expectedOwnerUserID else {
            throw IdleScreenCameraFrameMappingError.invalidOwner(
                expected: expectedOwnerUserID,
                actual: metadata.ownerUserID
            )
        }
        let expectedPermissions: UInt16 = 0o600
        guard metadata.permissions == expectedPermissions else {
            throw IdleScreenCameraFrameMappingError.invalidPermissions(
                expected: expectedPermissions,
                actual: metadata.permissions
            )
        }
        guard metadata.byteCount >= UInt64(expectedByteCount) else {
            throw IdleScreenCameraFrameMappingError.truncatedFile(
                expected: expectedByteCount,
                actual: metadata.byteCount
            )
        }
        guard metadata.byteCount <= UInt64(expectedByteCount) else {
            throw IdleScreenCameraFrameMappingError.oversizedFile(
                expected: expectedByteCount,
                actual: metadata.byteCount
            )
        }

        let region = try file.mapReadOnly(byteCount: expectedByteCount)
        guard region.byteCount == expectedByteCount else {
            throw IdleScreenCameraFrameMappingError.mappedByteCountMismatch(
                expected: expectedByteCount,
                actual: region.byteCount
            )
        }

        self.layout = layout
        self.region = region
        self.generationLoader = generationLoader
        self.snapshotAttemptLimit = snapshotAttemptLimit
        headerStorageByteCount = Int(layout.headerByteCount)
        frameStorageByteCount = Int(layout.slotByteCapacity)
        headerStorage = UnsafeMutableRawPointer.allocate(
            byteCount: headerStorageByteCount,
            alignment: MemoryLayout<UInt64>.alignment
        )
        frameStorage = UnsafeMutableRawPointer.allocate(
            byteCount: frameStorageByteCount,
            alignment: 64
        )
    }

    deinit {
        headerStorage.deallocate()
        frameStorage.deallocate()
    }

    public func withStableSnapshot<Result>(
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
            preconditionFailure("An unconditional snapshot omitted its payload")
        }
    }

    public func withStableSnapshot<Result>(
        copyingPixelsWhen shouldCopyPixels: (
            IdleScreenCameraFrameDescriptor
        ) throws -> Bool,
        _ body: (
            IdleScreenCameraFrameDescriptor,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) throws -> CameraFrameSourceMappingRead<Result>? {
        let signpostState = Self.performanceSignposter.beginInterval(
            "MailboxRead"
        )
        defer {
            Self.performanceSignposter.endInterval(
                "MailboxRead",
                signpostState
            )
        }
        for _ in 0..<snapshotAttemptLimit {
            let generationBefore = try generationLoader.loadAcquireGeneration(
                from: region.unsafeBaseAddress,
                byteOffset: Self.generationByteOffset
            )
            guard generationBefore > 0, generationBefore.isMultiple(of: 2) else {
                continue
            }

            var stableDescriptor: IdleScreenCameraFrameDescriptor?
            var stablePayloadByteCount = 0
            var copiedPixels = false
            do {
                let headerDestination = UnsafeMutableRawBufferPointer(
                    start: headerStorage,
                    count: headerStorageByteCount
                )
                try region.copyBytes(at: 0, into: headerDestination)
                let header = try IdleScreenCameraFrameMailboxHeader.decode(
                    from: UnsafeRawBufferPointer(headerDestination)
                )
                guard header.generation == generationBefore else {
                    throw IdleScreenCameraFrameMailboxHeader.ValidationError
                        .generationMismatch(
                            header: header.generation,
                            observed: generationBefore
                        )
                }
                let descriptor = try header.validated(for: layout)
                let payloadByteCount = Int(header.payloadByteCount)
                guard payloadByteCount <= frameStorageByteCount else {
                    throw IdleScreenCameraFrameMailboxHeader.ValidationError
                        .payloadExceedsSlotCapacity(
                            payload: header.payloadByteCount,
                            capacity: layout.slotByteCapacity
                        )
                }
                if try shouldCopyPixels(descriptor) {
                    let frameDestination = UnsafeMutableRawBufferPointer(
                        start: frameStorage,
                        count: payloadByteCount
                    )
                    try region.copyBytes(
                        at: layout.payloadOffset(forSlot: header.slotIndex),
                        into: frameDestination
                    )
                    copiedPixels = true
                }

                let generationAfter = try generationLoader.loadAcquireGeneration(
                    from: region.unsafeBaseAddress,
                    byteOffset: Self.generationByteOffset
                )
                guard generationAfter == generationBefore,
                      generationAfter.isMultiple(of: 2) else {
                    continue
                }
                stableDescriptor = descriptor
                stablePayloadByteCount = payloadByteCount
            } catch {
                let generationAfterFailure = try generationLoader.loadAcquireGeneration(
                    from: region.unsafeBaseAddress,
                    byteOffset: Self.generationByteOffset
                )
                if generationAfterFailure == generationBefore,
                   generationAfterFailure.isMultiple(of: 2) {
                    throw error
                }
            }
            if let stableDescriptor {
                if copiedPixels {
                    return .frame(try body(
                        stableDescriptor,
                        UnsafeRawBufferPointer(
                            start: frameStorage,
                            count: stablePayloadByteCount
                        )
                    ))
                } else {
                    return .descriptor(stableDescriptor)
                }
            }
        }
        return nil
    }
}
