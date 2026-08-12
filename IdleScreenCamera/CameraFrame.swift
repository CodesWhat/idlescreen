import Foundation

public enum IdleScreenCameraPixelFormat: UInt32, Codable, Sendable {
    case bgra8Unorm = 0x42475241
}

public struct IdleScreenCameraFrameDescriptor: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1
    public static let maximumSlotCount: UInt64 = 3

    /// The spike deliberately caps one BGRA mailbox frame at full HD. An 8 KiB
    /// row ceiling still admits alignment padding without permitting arbitrary allocations.
    public static let maximumWidth: UInt64 = 1_920
    public static let maximumHeight: UInt64 = 1_080
    public static let maximumBytesPerRow: UInt64 = 8_192
    public static let maximumFrameByteCount: UInt64 = 1_920 * 1_080 * 4

    public enum ValidationError: Swift.Error, Equatable, Sendable {
        case unsupportedProtocolVersion(Int)
        case zeroStreamEpoch
        case zeroSequence
        case invalidTimestamp
        case zeroDimensions
        case rowByteCountOverflow
        case invalidBytesPerRow
        case frameByteCountOverflow
        case dimensionsExceedLimit(width: UInt64, height: UInt64)
        case bytesPerRowExceedsLimit(UInt64)
        case frameByteCountExceedsLimit(UInt64)
        case invalidSlotCount(UInt64)
        case invalidSlotIndex(index: UInt64, count: UInt64)
    }

    public var protocolVersion: Int
    public var streamEpoch: UInt64
    public var sequence: UInt64
    public var timestamp: TimeInterval
    public var width: UInt64
    public var height: UInt64
    public var bytesPerRow: UInt64
    public var pixelFormat: IdleScreenCameraPixelFormat
    public var slotIndex: UInt64
    public var slotCount: UInt64

    public init(
        protocolVersion: Int,
        streamEpoch: UInt64,
        sequence: UInt64,
        timestamp: TimeInterval,
        width: UInt64,
        height: UInt64,
        bytesPerRow: UInt64,
        pixelFormat: IdleScreenCameraPixelFormat,
        slotIndex: UInt64,
        slotCount: UInt64
    ) {
        self.protocolVersion = protocolVersion
        self.streamEpoch = streamEpoch
        self.sequence = sequence
        self.timestamp = timestamp
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.slotIndex = slotIndex
        self.slotCount = slotCount
    }

    public func validated() throws -> Self {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw ValidationError.unsupportedProtocolVersion(protocolVersion)
        }
        guard streamEpoch > 0 else {
            throw ValidationError.zeroStreamEpoch
        }
        guard sequence > 0 else {
            throw ValidationError.zeroSequence
        }
        guard timestamp.isFinite, timestamp > 0 else {
            throw ValidationError.invalidTimestamp
        }
        guard width > 0, height > 0 else {
            throw ValidationError.zeroDimensions
        }

        let (minimumBytesPerRow, rowByteCountOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowByteCountOverflow else {
            throw ValidationError.rowByteCountOverflow
        }
        guard bytesPerRow >= minimumBytesPerRow, bytesPerRow.isMultiple(of: 4) else {
            throw ValidationError.invalidBytesPerRow
        }

        let (frameByteCount, frameByteCountOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !frameByteCountOverflow, frameByteCount <= UInt64(Int.max) else {
            throw ValidationError.frameByteCountOverflow
        }
        guard width <= Self.maximumWidth, height <= Self.maximumHeight else {
            throw ValidationError.dimensionsExceedLimit(width: width, height: height)
        }
        guard bytesPerRow <= Self.maximumBytesPerRow else {
            throw ValidationError.bytesPerRowExceedsLimit(bytesPerRow)
        }
        guard frameByteCount <= Self.maximumFrameByteCount else {
            throw ValidationError.frameByteCountExceedsLimit(frameByteCount)
        }
        guard (1...Self.maximumSlotCount).contains(slotCount) else {
            throw ValidationError.invalidSlotCount(slotCount)
        }
        guard slotIndex < slotCount else {
            throw ValidationError.invalidSlotIndex(index: slotIndex, count: slotCount)
        }

        return self
    }
}

public struct IdleScreenLatestFrameSelector: Sendable {
    public enum SelectionError: Swift.Error, Equatable, Sendable {
        case invalidCurrentTime
        case invalidMaximumAge
    }

    public private(set) var latest: IdleScreenCameraFrameDescriptor?

    public init() {
        latest = nil
    }

    @discardableResult
    public mutating func consider(
        _ candidate: IdleScreenCameraFrameDescriptor,
        currentTime: TimeInterval,
        maximumAge: TimeInterval
    ) throws -> Bool {
        _ = try candidate.validated()
        guard currentTime.isFinite, currentTime > 0 else {
            throw SelectionError.invalidCurrentTime
        }
        guard maximumAge.isFinite, maximumAge >= 0 else {
            throw SelectionError.invalidMaximumAge
        }

        let age = currentTime - candidate.timestamp
        guard age >= 0, age <= maximumAge else {
            return false
        }

        if let latest {
            guard candidate.streamEpoch > latest.streamEpoch
                    || (candidate.streamEpoch == latest.streamEpoch
                        && candidate.sequence > latest.sequence) else {
                return false
            }
        }

        latest = candidate
        return true
    }
}
