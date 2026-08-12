import IdleScreenCameraAtomics

public enum IdleScreenCameraAtomicGenerationLoaderError: Swift.Error, Equatable, Sendable {
    case invalidMappedByteCount(Int)
    case negativeByteOffset(Int)
    case byteRangeOverflow(byteOffset: Int, valueByteCount: Int)
    case unalignedByteOffset(byteOffset: Int, requiredAlignment: Int)
    case outOfBounds(byteOffset: Int, valueByteCount: Int, mappedByteCount: Int)
    case unalignedAddress(requiredAlignment: Int)
    case atomicLoadFailed(status: Int32)
}

/// Loads a mailbox generation through the C11 interprocess-atomic boundary.
///
/// The mapped byte count is captured when the mapping is created so pointer
/// arithmetic is rejected before an address is formed. This type never uses
/// an ordinary Swift load for the generation field.
public final class IdleScreenCameraAtomicGenerationLoader:
    IdleScreenCameraGenerationLoading,
    @unchecked Sendable
{
    private static let valueByteCount = MemoryLayout<UInt64>.size

    public let mappedByteCount: Int

    public init(mappedByteCount: Int) throws {
        guard mappedByteCount >= 0 else {
            throw IdleScreenCameraAtomicGenerationLoaderError
                .invalidMappedByteCount(mappedByteCount)
        }
        self.mappedByteCount = mappedByteCount
    }

    public func loadAcquireGeneration(
        from baseAddress: UnsafeRawPointer,
        byteOffset: Int
    ) throws -> UInt64 {
        guard byteOffset >= 0 else {
            throw IdleScreenCameraAtomicGenerationLoaderError
                .negativeByteOffset(byteOffset)
        }

        let valueByteCount = Self.valueByteCount
        let (rangeEnd, rangeOverflow) = byteOffset.addingReportingOverflow(valueByteCount)
        guard !rangeOverflow else {
            throw IdleScreenCameraAtomicGenerationLoaderError.byteRangeOverflow(
                byteOffset: byteOffset,
                valueByteCount: valueByteCount
            )
        }

        let requiredAlignment = Int(idle_screen_camera_atomic_uint64_alignment())
        guard byteOffset.isMultiple(of: requiredAlignment) else {
            throw IdleScreenCameraAtomicGenerationLoaderError.unalignedByteOffset(
                byteOffset: byteOffset,
                requiredAlignment: requiredAlignment
            )
        }
        guard rangeEnd <= mappedByteCount else {
            throw IdleScreenCameraAtomicGenerationLoaderError.outOfBounds(
                byteOffset: byteOffset,
                valueByteCount: valueByteCount,
                mappedByteCount: mappedByteCount
            )
        }

        let valueAddress = baseAddress.advanced(by: byteOffset)
        guard Int(bitPattern: valueAddress).isMultiple(of: requiredAlignment) else {
            throw IdleScreenCameraAtomicGenerationLoaderError.unalignedAddress(
                requiredAlignment: requiredAlignment
            )
        }

        var generation: UInt64 = 0
        let status = idle_screen_camera_atomic_load_uint64_acquire(
            valueAddress,
            &generation
        )
        guard status == IdleScreenCameraAtomicStatusOK else {
            throw IdleScreenCameraAtomicGenerationLoaderError.atomicLoadFailed(
                status: status
            )
        }
        return generation
    }
}
