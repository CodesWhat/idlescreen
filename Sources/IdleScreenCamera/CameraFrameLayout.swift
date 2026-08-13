import Foundation

/// The on-disk shape of the fixed-size camera frame mailbox.
///
/// Every mailbox has one 128-byte, versioned header followed by three slots.
/// Each slot can contain at most one frame accepted by
/// `IdleScreenCameraFrameDescriptor`, so neither side derives an allocation
/// size from untrusted file contents.
public struct IdleScreenCameraFrameMailboxLayout: Equatable, Sendable {
    public enum LayoutError: Swift.Error, Equatable, Sendable {
        case invalidSlotCount(UInt64)
        case invalidSlotByteCapacity(UInt64)
        case byteCountOverflow
        case byteCountExceedsAddressSpace(UInt64)
        case invalidSlotIndex(UInt64)
    }

    public static let magic: UInt64 = 0x314D_4143_534C_4449 // "IDLSCAM1" on disk
    public static let currentSchemaVersion: UInt32 = 1
    public static let currentHeaderByteCount: UInt64 = 128

    public static let current = Self(
        validatedSlotCount: IdleScreenCameraFrameDescriptor.maximumSlotCount,
        validatedSlotByteCapacity: IdleScreenCameraFrameDescriptor.maximumFrameByteCount
    )

    public let headerByteCount: UInt64
    public let slotCount: UInt64
    public let slotByteCapacity: UInt64

    public init(slotCount: UInt64, slotByteCapacity: UInt64) throws {
        guard (1...IdleScreenCameraFrameDescriptor.maximumSlotCount).contains(slotCount) else {
            throw LayoutError.invalidSlotCount(slotCount)
        }
        guard slotByteCapacity > 0,
              slotByteCapacity <= IdleScreenCameraFrameDescriptor.maximumFrameByteCount else {
            throw LayoutError.invalidSlotByteCapacity(slotByteCapacity)
        }

        self.init(
            validatedSlotCount: slotCount,
            validatedSlotByteCapacity: slotByteCapacity
        )
        _ = try expectedFileByteCount()
    }

    private init(validatedSlotCount: UInt64, validatedSlotByteCapacity: UInt64) {
        headerByteCount = Self.currentHeaderByteCount
        slotCount = validatedSlotCount
        slotByteCapacity = validatedSlotByteCapacity
    }

    public func expectedFileByteCount() throws -> Int {
        try Self.checkedFileByteCount(
            headerByteCount: headerByteCount,
            slotByteCapacity: slotByteCapacity,
            slotCount: slotCount
        )
    }

    public static func checkedFileByteCount(
        headerByteCount: UInt64,
        slotByteCapacity: UInt64,
        slotCount: UInt64
    ) throws -> Int {
        let (payloadByteCount, multiplicationOverflow) = slotByteCapacity
            .multipliedReportingOverflow(by: slotCount)
        guard !multiplicationOverflow else {
            throw LayoutError.byteCountOverflow
        }
        let (fileByteCount, additionOverflow) = headerByteCount
            .addingReportingOverflow(payloadByteCount)
        guard !additionOverflow else {
            throw LayoutError.byteCountOverflow
        }
        guard fileByteCount <= UInt64(Int.max) else {
            throw LayoutError.byteCountExceedsAddressSpace(fileByteCount)
        }
        return Int(fileByteCount)
    }

    public func payloadOffset(forSlot slotIndex: UInt64) throws -> Int {
        guard slotIndex < slotCount else {
            throw LayoutError.invalidSlotIndex(slotIndex)
        }
        let (slotOffset, multiplicationOverflow) = slotByteCapacity
            .multipliedReportingOverflow(by: slotIndex)
        guard !multiplicationOverflow else {
            throw LayoutError.byteCountOverflow
        }
        let (payloadOffset, additionOverflow) = headerByteCount
            .addingReportingOverflow(slotOffset)
        guard !additionOverflow, payloadOffset <= UInt64(Int.max) else {
            throw LayoutError.byteCountOverflow
        }
        return Int(payloadOffset)
    }
}

/// A byte-for-byte header definition independent of Swift's native struct ABI.
/// All integer fields are encoded little-endian at explicit offsets.
public struct IdleScreenCameraFrameMailboxHeader: Equatable, Sendable {
    public enum ValidationError: Swift.Error, Equatable, Sendable {
        case truncatedHeader(expected: Int, actual: Int)
        case invalidMagic(UInt64)
        case unsupportedSchemaVersion(UInt32)
        case invalidHeaderByteCount(UInt32)
        case invalidGeneration(UInt64)
        case generationMismatch(header: UInt64, observed: UInt64)
        case unsupportedPixelFormat(UInt32)
        case slotCountMismatch(expected: UInt64, actual: UInt64)
        case invalidDescriptor(IdleScreenCameraFrameDescriptor.ValidationError)
        case payloadByteCountMismatch(expected: UInt64, actual: UInt64)
        case payloadExceedsSlotCapacity(payload: UInt64, capacity: UInt64)
    }

    public var magic: UInt64
    public var schemaVersion: UInt32
    public var headerByteCount: UInt32
    public var generation: UInt64
    public var streamEpoch: UInt64
    public var sequence: UInt64
    public var timestamp: TimeInterval
    public var width: UInt64
    public var height: UInt64
    public var bytesPerRow: UInt64
    public var pixelFormatRawValue: UInt32
    public var slotIndex: UInt64
    public var slotCount: UInt64
    public var payloadByteCount: UInt64

    public init(generation: UInt64, descriptor: IdleScreenCameraFrameDescriptor) {
        magic = IdleScreenCameraFrameMailboxLayout.magic
        schemaVersion = IdleScreenCameraFrameMailboxLayout.currentSchemaVersion
        headerByteCount = UInt32(IdleScreenCameraFrameMailboxLayout.currentHeaderByteCount)
        self.generation = generation
        streamEpoch = descriptor.streamEpoch
        sequence = descriptor.sequence
        timestamp = descriptor.timestamp
        width = descriptor.width
        height = descriptor.height
        bytesPerRow = descriptor.bytesPerRow
        pixelFormatRawValue = descriptor.pixelFormat.rawValue
        slotIndex = descriptor.slotIndex
        slotCount = descriptor.slotCount
        payloadByteCount = descriptor.bytesPerRow.multipliedReportingOverflow(by: descriptor.height).partialValue
    }

    public func encoded() -> Data {
        var bytes = [UInt8](
            repeating: 0,
            count: Int(IdleScreenCameraFrameMailboxLayout.currentHeaderByteCount)
        )
        Self.write(magic, into: &bytes, at: 0)
        Self.write(schemaVersion, into: &bytes, at: 8)
        Self.write(headerByteCount, into: &bytes, at: 12)
        Self.write(generation, into: &bytes, at: 16)
        Self.write(streamEpoch, into: &bytes, at: 24)
        Self.write(sequence, into: &bytes, at: 32)
        Self.write(timestamp.bitPattern, into: &bytes, at: 40)
        Self.write(width, into: &bytes, at: 48)
        Self.write(height, into: &bytes, at: 56)
        Self.write(bytesPerRow, into: &bytes, at: 64)
        Self.write(pixelFormatRawValue, into: &bytes, at: 72)
        Self.write(slotIndex, into: &bytes, at: 80)
        Self.write(slotCount, into: &bytes, at: 88)
        Self.write(payloadByteCount, into: &bytes, at: 96)
        return Data(bytes)
    }

    public static func decode(
        from bytes: UnsafeRawBufferPointer
    ) throws -> IdleScreenCameraFrameMailboxHeader {
        let expectedByteCount = Int(IdleScreenCameraFrameMailboxLayout.currentHeaderByteCount)
        guard bytes.count >= expectedByteCount else {
            throw ValidationError.truncatedHeader(expected: expectedByteCount, actual: bytes.count)
        }

        let pixelFormatRawValue: UInt32 = read(from: bytes, at: 72)
        var header = IdleScreenCameraFrameMailboxHeader(
            generation: read(from: bytes, at: 16),
            descriptor: IdleScreenCameraFrameDescriptor(
                protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
                streamEpoch: read(from: bytes, at: 24),
                sequence: read(from: bytes, at: 32),
                timestamp: TimeInterval(bitPattern: read(from: bytes, at: 40)),
                width: read(from: bytes, at: 48),
                height: read(from: bytes, at: 56),
                bytesPerRow: read(from: bytes, at: 64),
                pixelFormat: .bgra8Unorm,
                slotIndex: read(from: bytes, at: 80),
                slotCount: read(from: bytes, at: 88)
            )
        )
        header.magic = read(from: bytes, at: 0)
        header.schemaVersion = read(from: bytes, at: 8)
        header.headerByteCount = read(from: bytes, at: 12)
        header.pixelFormatRawValue = pixelFormatRawValue
        header.payloadByteCount = read(from: bytes, at: 96)
        return header
    }

    public func validated(
        for layout: IdleScreenCameraFrameMailboxLayout
    ) throws -> IdleScreenCameraFrameDescriptor {
        guard magic == IdleScreenCameraFrameMailboxLayout.magic else {
            throw ValidationError.invalidMagic(magic)
        }
        guard schemaVersion == IdleScreenCameraFrameMailboxLayout.currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard UInt64(headerByteCount) == layout.headerByteCount else {
            throw ValidationError.invalidHeaderByteCount(headerByteCount)
        }
        guard generation > 0, generation.isMultiple(of: 2) else {
            throw ValidationError.invalidGeneration(generation)
        }
        guard let pixelFormat = IdleScreenCameraPixelFormat(rawValue: pixelFormatRawValue) else {
            throw ValidationError.unsupportedPixelFormat(pixelFormatRawValue)
        }
        guard slotCount == layout.slotCount else {
            throw ValidationError.slotCountMismatch(expected: layout.slotCount, actual: slotCount)
        }

        let descriptor = IdleScreenCameraFrameDescriptor(
            protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
            streamEpoch: streamEpoch,
            sequence: sequence,
            timestamp: timestamp,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: pixelFormat,
            slotIndex: slotIndex,
            slotCount: slotCount
        )
        do {
            _ = try descriptor.validated()
        } catch let error as IdleScreenCameraFrameDescriptor.ValidationError {
            throw ValidationError.invalidDescriptor(error)
        }

        let expectedPayloadByteCount = bytesPerRow * height
        guard payloadByteCount == expectedPayloadByteCount else {
            throw ValidationError.payloadByteCountMismatch(
                expected: expectedPayloadByteCount,
                actual: payloadByteCount
            )
        }
        guard payloadByteCount <= layout.slotByteCapacity else {
            throw ValidationError.payloadExceedsSlotCapacity(
                payload: payloadByteCount,
                capacity: layout.slotByteCapacity
            )
        }
        return descriptor
    }

    private static func write<T: FixedWidthInteger>(
        _ value: T,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { encoded in
            for index in encoded.indices {
                bytes[offset + index] = encoded[index]
            }
        }
    }

    private static func read<T: FixedWidthInteger>(
        from bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> T {
        var result: T = 0
        for index in 0..<MemoryLayout<T>.size {
            result |= T(bytes[offset + index]) << T(index * 8)
        }
        return result
    }
}
