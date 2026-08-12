import Foundation

/// Allocation and schema limits shared by both sides of the camera-agent connection.
/// Caller identity is intentionally absent from every request: an agent must derive
/// the peer PID and effective user from its NSXPCConnection, then validate the
/// live Team ID and signing identifier through Security.framework.
public enum IdleScreenCameraWire {
    public static let currentSchemaVersion = 1
    public static let maximumWidth = 1_920
    public static let maximumHeight = 1_080
    public static let maximumFramesPerSecond = 60
    public static let maximumMailboxSlotCount = 3
    public static let maximumActiveLeaseCount = 64
    public static let maximumLeaseIdentifierUTF8ByteCount = 128
    public static let maximumTransportIdentifierUTF8ByteCount = 256
    public static let maximumErrorMessageUTF8ByteCount = 256
    public static let maximumDiagnosticSummaryUTF8ByteCount = 1_024
    public static let maximumIdentityIdentifierUTF8ByteCount = 256
    public static let maximumVersionUTF8ByteCount = 128
    public static let maximumSourceAppPathUTF8ByteCount = 4_096
    public static let maximumCameraDeviceCount = 64
    public static let maximumCameraDeviceIdentifierUTF8ByteCount = 1_024
    public static let maximumCameraDeviceNameUTF8ByteCount = 256
}

/// Privacy-safe identity of the exact camera-agent process that produced a
/// diagnostic snapshot. The client must correlate `processIdentifier` with the
/// PID observed on its authenticated NSXPC connection before trusting it.
@objcMembers
public final class IdleScreenCameraAgentIdentity: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let processIdentifier: Int32
    public let processIncarnationEpoch: UInt64
    public let bundleIdentifier: String
    public let serviceIdentifier: String
    public let bundleVersion: String
    public let marketingVersion: String
    public let signingIdentifier: String
    public let teamIdentifier: String
    public let codeDirectoryHash: String
    public let executableSHA256: String
    public let launchAgentSHA256: String
    public let provisioningProfileSHA256: String
    public let sourceAppPath: String

    public init?(
        processIdentifier: Int32,
        processIncarnationEpoch: UInt64,
        bundleIdentifier: String,
        serviceIdentifier: String,
        bundleVersion: String,
        marketingVersion: String,
        signingIdentifier: String,
        teamIdentifier: String,
        codeDirectoryHash: String,
        executableSHA256: String,
        launchAgentSHA256: String,
        provisioningProfileSHA256: String,
        sourceAppPath: String
    ) {
        guard Self.isValid(
            processIdentifier: processIdentifier,
            processIncarnationEpoch: processIncarnationEpoch,
            bundleIdentifier: bundleIdentifier,
            serviceIdentifier: serviceIdentifier,
            bundleVersion: bundleVersion,
            marketingVersion: marketingVersion,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            codeDirectoryHash: codeDirectoryHash,
            executableSHA256: executableSHA256,
            launchAgentSHA256: launchAgentSHA256,
            provisioningProfileSHA256: provisioningProfileSHA256,
            sourceAppPath: sourceAppPath
        ) else { return nil }

        self.processIdentifier = processIdentifier
        self.processIncarnationEpoch = processIncarnationEpoch
        self.bundleIdentifier = bundleIdentifier
        self.serviceIdentifier = serviceIdentifier
        self.bundleVersion = bundleVersion
        self.marketingVersion = marketingVersion
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.codeDirectoryHash = codeDirectoryHash
        self.executableSHA256 = executableSHA256
        self.launchAgentSHA256 = launchAgentSHA256
        self.provisioningProfileSHA256 = provisioningProfileSHA256
        self.sourceAppPath = sourceAppPath
        super.init()
    }

    public required init?(coder: NSCoder) {
        let stringKeys = [
            WireKey.bundleIdentifier,
            WireKey.serviceIdentifier,
            WireKey.bundleVersion,
            WireKey.marketingVersion,
            WireKey.signingIdentifier,
            WireKey.teamIdentifier,
            WireKey.codeDirectoryHash,
            WireKey.executableSHA256,
            WireKey.launchAgentSHA256,
            WireKey.provisioningProfileSHA256,
            WireKey.sourceAppPath,
        ]
        guard coder.containsValue(forKey: WireKey.processIdentifier),
              coder.containsValue(forKey: WireKey.processIncarnationEpoch),
              stringKeys.allSatisfy(coder.containsValue(forKey:)),
              let bundleIdentifier = decodeRequiredString(
                coder,
                key: WireKey.bundleIdentifier
              ),
              let serviceIdentifier = decodeRequiredString(
                coder,
                key: WireKey.serviceIdentifier
              ),
              let bundleVersion = decodeRequiredString(coder, key: WireKey.bundleVersion),
              let marketingVersion = decodeRequiredString(
                coder,
                key: WireKey.marketingVersion
              ),
              let signingIdentifier = decodeRequiredString(
                coder,
                key: WireKey.signingIdentifier
              ),
              let teamIdentifier = decodeRequiredString(coder, key: WireKey.teamIdentifier),
              let codeDirectoryHash = decodeRequiredString(
                coder,
                key: WireKey.codeDirectoryHash
              ),
              let executableSHA256 = decodeRequiredString(
                coder,
                key: WireKey.executableSHA256
              ),
              let launchAgentSHA256 = decodeRequiredString(
                coder,
                key: WireKey.launchAgentSHA256
              ),
              let provisioningProfileSHA256 = decodeRequiredString(
                coder,
                key: WireKey.provisioningProfileSHA256
              ),
              let sourceAppPath = decodeRequiredString(coder, key: WireKey.sourceAppPath) else {
            return nil
        }

        let processIdentifier = coder.decodeInt32(forKey: WireKey.processIdentifier)
        let signedEpoch = coder.decodeInt64(forKey: WireKey.processIncarnationEpoch)
        guard signedEpoch > 0 else { return nil }
        let processIncarnationEpoch = UInt64(signedEpoch)
        guard Self.isValid(
            processIdentifier: processIdentifier,
            processIncarnationEpoch: processIncarnationEpoch,
            bundleIdentifier: bundleIdentifier,
            serviceIdentifier: serviceIdentifier,
            bundleVersion: bundleVersion,
            marketingVersion: marketingVersion,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            codeDirectoryHash: codeDirectoryHash,
            executableSHA256: executableSHA256,
            launchAgentSHA256: launchAgentSHA256,
            provisioningProfileSHA256: provisioningProfileSHA256,
            sourceAppPath: sourceAppPath
        ) else { return nil }

        self.processIdentifier = processIdentifier
        self.processIncarnationEpoch = processIncarnationEpoch
        self.bundleIdentifier = bundleIdentifier
        self.serviceIdentifier = serviceIdentifier
        self.bundleVersion = bundleVersion
        self.marketingVersion = marketingVersion
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.codeDirectoryHash = codeDirectoryHash
        self.executableSHA256 = executableSHA256
        self.launchAgentSHA256 = launchAgentSHA256
        self.provisioningProfileSHA256 = provisioningProfileSHA256
        self.sourceAppPath = sourceAppPath
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(processIdentifier, forKey: WireKey.processIdentifier)
        coder.encode(Int64(processIncarnationEpoch), forKey: WireKey.processIncarnationEpoch)
        coder.encode(bundleIdentifier as NSString, forKey: WireKey.bundleIdentifier)
        coder.encode(serviceIdentifier as NSString, forKey: WireKey.serviceIdentifier)
        coder.encode(bundleVersion as NSString, forKey: WireKey.bundleVersion)
        coder.encode(marketingVersion as NSString, forKey: WireKey.marketingVersion)
        coder.encode(signingIdentifier as NSString, forKey: WireKey.signingIdentifier)
        coder.encode(teamIdentifier as NSString, forKey: WireKey.teamIdentifier)
        coder.encode(codeDirectoryHash as NSString, forKey: WireKey.codeDirectoryHash)
        coder.encode(executableSHA256 as NSString, forKey: WireKey.executableSHA256)
        coder.encode(launchAgentSHA256 as NSString, forKey: WireKey.launchAgentSHA256)
        coder.encode(
            provisioningProfileSHA256 as NSString,
            forKey: WireKey.provisioningProfileSHA256
        )
        coder.encode(sourceAppPath as NSString, forKey: WireKey.sourceAppPath)
    }

    public func matches(remoteProcessIdentifier: Int32) -> Bool {
        remoteProcessIdentifier > 0 && processIdentifier == remoteProcessIdentifier
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? IdleScreenCameraAgentIdentity else { return false }
        return processIdentifier == other.processIdentifier
            && processIncarnationEpoch == other.processIncarnationEpoch
            && bundleIdentifier == other.bundleIdentifier
            && serviceIdentifier == other.serviceIdentifier
            && bundleVersion == other.bundleVersion
            && marketingVersion == other.marketingVersion
            && signingIdentifier == other.signingIdentifier
            && teamIdentifier == other.teamIdentifier
            && codeDirectoryHash == other.codeDirectoryHash
            && executableSHA256 == other.executableSHA256
            && launchAgentSHA256 == other.launchAgentSHA256
            && provisioningProfileSHA256 == other.provisioningProfileSHA256
            && sourceAppPath == other.sourceAppPath
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(processIdentifier)
        hasher.combine(processIncarnationEpoch)
        hasher.combine(bundleIdentifier)
        hasher.combine(serviceIdentifier)
        hasher.combine(codeDirectoryHash)
        hasher.combine(executableSHA256)
        hasher.combine(sourceAppPath)
        return hasher.finalize()
    }

    private static func isValid(
        processIdentifier: Int32,
        processIncarnationEpoch: UInt64,
        bundleIdentifier: String,
        serviceIdentifier: String,
        bundleVersion: String,
        marketingVersion: String,
        signingIdentifier: String,
        teamIdentifier: String,
        codeDirectoryHash: String,
        executableSHA256: String,
        launchAgentSHA256: String,
        provisioningProfileSHA256: String,
        sourceAppPath: String
    ) -> Bool {
        processIdentifier > 0
            && processIncarnationEpoch > 0
            && processIncarnationEpoch <= UInt64(Int64.max)
            && isValidDottedIdentifier(bundleIdentifier)
            && isValidDottedIdentifier(serviceIdentifier)
            && isValidVersion(bundleVersion)
            && isValidVersion(marketingVersion)
            && isValidDottedIdentifier(signingIdentifier)
            && isValidTeamIdentifier(teamIdentifier)
            && isHexadecimal(codeDirectoryHash, length: 40)
            && isHexadecimal(executableSHA256, length: 64)
            && isHexadecimal(launchAgentSHA256, length: 64)
            && isHexadecimal(provisioningProfileSHA256, length: 64)
            && isCanonicalAppPath(sourceAppPath)
    }
}

@objc public enum IdleScreenCameraAuthorizationStatus: Int {
    case notDetermined = 0
    case restricted = 1
    case denied = 2
    case authorized = 3
    case unavailable = 4
}

@objc public enum IdleScreenCameraXPCErrorCode: Int {
    case none = 0
    case unsupportedSchema = 1
    case invalidRequest = 2
    case notAuthorized = 3
    case cameraUnavailable = 4
    case transportUnavailable = 5
    case internalFailure = 6
}

@objc public enum IdleScreenCameraDeviceKind: Int, Sendable {
    case builtIn = 0
    case external = 1
    case continuity = 2
    case deskView = 3
}

@objc public enum IdleScreenCameraDeviceSelectionMode: Int, Sendable {
    case automatic = 0
    case explicitDevice = 1
}

/// A bounded, display-safe description of one video device discovered by the
/// sole camera agent. The identifier is opaque and must never be interpreted as
/// a path or caller identity.
@objcMembers
public final class IdleScreenCameraDeviceDescriptor: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let deviceIdentifier: String
    public let displayName: String
    public let kind: IdleScreenCameraDeviceKind

    public init?(
        deviceIdentifier: String,
        displayName: String,
        kind: IdleScreenCameraDeviceKind
    ) {
        guard isValidCameraDeviceIdentifier(deviceIdentifier),
              isValidCameraDeviceName(displayName) else {
            return nil
        }
        self.deviceIdentifier = deviceIdentifier
        self.displayName = displayName
        self.kind = kind
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let deviceIdentifier = decodeRequiredString(
            coder,
            key: WireKey.cameraDeviceIdentifier
        ),
        let displayName = decodeRequiredString(
            coder,
            key: WireKey.cameraDeviceName
        ),
        coder.containsValue(forKey: WireKey.cameraDeviceKind),
        let kind = IdleScreenCameraDeviceKind(
            rawValue: coder.decodeInteger(forKey: WireKey.cameraDeviceKind)
        ),
        isValidCameraDeviceIdentifier(deviceIdentifier),
        isValidCameraDeviceName(displayName) else {
            return nil
        }
        self.deviceIdentifier = deviceIdentifier
        self.displayName = displayName
        self.kind = kind
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(deviceIdentifier as NSString, forKey: WireKey.cameraDeviceIdentifier)
        coder.encode(displayName as NSString, forKey: WireKey.cameraDeviceName)
        coder.encode(kind.rawValue, forKey: WireKey.cameraDeviceKind)
    }
}

/// The helper's current interpretation of the process-wide preference stored
/// in shared configuration. Explicit selections remain configured even while
/// the corresponding device is disconnected.
@objcMembers
public final class IdleScreenCameraDeviceSelectionState: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let mode: IdleScreenCameraDeviceSelectionMode
    public let deviceIdentifier: String?

    public init?(
        mode: IdleScreenCameraDeviceSelectionMode,
        deviceIdentifier: String?
    ) {
        guard Self.isValid(mode: mode, deviceIdentifier: deviceIdentifier) else {
            return nil
        }
        self.mode = mode
        self.deviceIdentifier = deviceIdentifier
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard coder.containsValue(forKey: WireKey.cameraDeviceSelectionMode),
              let mode = IdleScreenCameraDeviceSelectionMode(
                rawValue: coder.decodeInteger(forKey: WireKey.cameraDeviceSelectionMode)
              ),
              let deviceIdentifier = decodeOptionalString(
                coder,
                key: WireKey.cameraDeviceIdentifier
              ),
              Self.isValid(mode: mode, deviceIdentifier: deviceIdentifier) else {
            return nil
        }
        self.mode = mode
        self.deviceIdentifier = deviceIdentifier
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(mode.rawValue, forKey: WireKey.cameraDeviceSelectionMode)
        encodeOptionalString(
            deviceIdentifier,
            coder: coder,
            key: WireKey.cameraDeviceIdentifier
        )
    }

    private static func isValid(
        mode: IdleScreenCameraDeviceSelectionMode,
        deviceIdentifier: String?
    ) -> Bool {
        switch mode {
        case .automatic:
            return deviceIdentifier == nil
        case .explicitDevice:
            return deviceIdentifier.map(isValidCameraDeviceIdentifier) == true
        }
    }
}

/// The Objective-C-compatible surface shared by the agent, companion app, and
/// screen-saver extension. Leases are capabilities scoped to the connection that
/// created them; invalidating that connection must reclaim all of its leases.
@objc(IdleScreenCameraXPCProtocol)
public protocol IdleScreenCameraXPCProtocol: AnyObject {
    func authorizationStatus(
        _ request: IdleScreenCameraStatusRequest,
        withReply reply: @escaping (IdleScreenCameraAuthorizationReply) -> Void
    )

    func requestAuthorization(
        _ request: IdleScreenCameraAuthorizationRequest,
        withReply reply: @escaping (IdleScreenCameraAuthorizationReply) -> Void
    )

    func beginStream(
        _ request: IdleScreenCameraBeginStreamRequest,
        withReply reply: @escaping (IdleScreenCameraBeginStreamReply) -> Void
    )

    func heartbeat(
        _ request: IdleScreenCameraHeartbeatRequest,
        withReply reply: @escaping (IdleScreenCameraHeartbeatReply) -> Void
    )

    func endStream(
        _ request: IdleScreenCameraEndStreamRequest,
        withReply reply: @escaping (IdleScreenCameraEndStreamReply) -> Void
    )

    func diagnosticSnapshot(
        _ request: IdleScreenCameraDiagnosticRequest,
        withReply reply: @escaping (IdleScreenCameraDiagnosticSnapshot) -> Void
    )

    /// Returns the helper-owned inventory and its effective process-wide
    /// selection state. This read does not acquire a stream lease or touch the
    /// configured selection.
    func cameraDeviceSnapshot(
        _ request: IdleScreenCameraStatusRequest,
        withReply reply: @escaping (IdleScreenCameraDeviceSnapshotReply) -> Void
    )
}

/// Builds the one XPC interface used by both sides of the camera connection.
/// The explicit class allow-list is required for the descriptor collection
/// nested in the device-snapshot reply.
public enum IdleScreenCameraXPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: IdleScreenCameraXPCProtocol.self)
        let snapshotReplyClasses = NSSet(objects:
            NSArray.self,
            NSString.self,
            IdleScreenCameraDeviceDescriptor.self,
            IdleScreenCameraDeviceSelectionState.self,
            IdleScreenCameraDeviceSnapshotReply.self
        ) as! Set<AnyHashable>
        interface.setClasses(
            snapshotReplyClasses,
            for: #selector(
                IdleScreenCameraXPCProtocol.cameraDeviceSnapshot(_:withReply:)
            ),
            argumentIndex: 0,
            ofReply: true
        )
        return interface
    }
}

@objcMembers
public final class IdleScreenCameraStatusRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let schemaVersion: Int

    public init?(schemaVersion: Int = IdleScreenCameraWire.currentSchemaVersion) {
        guard isCurrentSchema(schemaVersion) else { return nil }
        self.schemaVersion = schemaVersion
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard coder.containsValue(forKey: WireKey.schemaVersion) else { return nil }
        let schemaVersion = coder.decodeInteger(forKey: WireKey.schemaVersion)
        guard isCurrentSchema(schemaVersion) else { return nil }
        self.schemaVersion = schemaVersion
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(schemaVersion, forKey: WireKey.schemaVersion)
    }
}

@objcMembers
public final class IdleScreenCameraAuthorizationRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let schemaVersion: Int

    public init?(schemaVersion: Int = IdleScreenCameraWire.currentSchemaVersion) {
        guard isCurrentSchema(schemaVersion) else { return nil }
        self.schemaVersion = schemaVersion
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard coder.containsValue(forKey: WireKey.schemaVersion) else { return nil }
        let schemaVersion = coder.decodeInteger(forKey: WireKey.schemaVersion)
        guard isCurrentSchema(schemaVersion) else { return nil }
        self.schemaVersion = schemaVersion
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(schemaVersion, forKey: WireKey.schemaVersion)
    }
}

@objcMembers
public final class IdleScreenCameraBeginStreamRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let schemaVersion: Int
    public let maximumWidth: Int
    public let maximumHeight: Int
    public let maximumFramesPerSecond: Int
    public let mailboxSlotCount: Int

    public init?(
        schemaVersion: Int = IdleScreenCameraWire.currentSchemaVersion,
        maximumWidth: Int,
        maximumHeight: Int,
        maximumFramesPerSecond: Int,
        mailboxSlotCount: Int
    ) {
        guard Self.isValid(
            schemaVersion: schemaVersion,
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            maximumFramesPerSecond: maximumFramesPerSecond,
            mailboxSlotCount: mailboxSlotCount
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.mailboxSlotCount = mailboxSlotCount
        super.init()
    }

    public required init?(coder: NSCoder) {
        let requiredKeys = [
            WireKey.schemaVersion,
            WireKey.maximumWidth,
            WireKey.maximumHeight,
            WireKey.maximumFramesPerSecond,
            WireKey.mailboxSlotCount,
        ]
        guard requiredKeys.allSatisfy(coder.containsValue(forKey:)) else { return nil }

        let schemaVersion = coder.decodeInteger(forKey: WireKey.schemaVersion)
        let maximumWidth = coder.decodeInteger(forKey: WireKey.maximumWidth)
        let maximumHeight = coder.decodeInteger(forKey: WireKey.maximumHeight)
        let maximumFramesPerSecond = coder.decodeInteger(forKey: WireKey.maximumFramesPerSecond)
        let mailboxSlotCount = coder.decodeInteger(forKey: WireKey.mailboxSlotCount)
        guard Self.isValid(
            schemaVersion: schemaVersion,
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            maximumFramesPerSecond: maximumFramesPerSecond,
            mailboxSlotCount: mailboxSlotCount
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.mailboxSlotCount = mailboxSlotCount
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(schemaVersion, forKey: WireKey.schemaVersion)
        coder.encode(maximumWidth, forKey: WireKey.maximumWidth)
        coder.encode(maximumHeight, forKey: WireKey.maximumHeight)
        coder.encode(maximumFramesPerSecond, forKey: WireKey.maximumFramesPerSecond)
        coder.encode(mailboxSlotCount, forKey: WireKey.mailboxSlotCount)
    }

    private static func isValid(
        schemaVersion: Int,
        maximumWidth: Int,
        maximumHeight: Int,
        maximumFramesPerSecond: Int,
        mailboxSlotCount: Int
    ) -> Bool {
        isCurrentSchema(schemaVersion)
            && (1...IdleScreenCameraWire.maximumWidth).contains(maximumWidth)
            && (1...IdleScreenCameraWire.maximumHeight).contains(maximumHeight)
            && (1...IdleScreenCameraWire.maximumFramesPerSecond).contains(maximumFramesPerSecond)
            && (1...IdleScreenCameraWire.maximumMailboxSlotCount).contains(mailboxSlotCount)
    }
}

@objcMembers
public final class IdleScreenCameraEndStreamRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let schemaVersion: Int
    public let leaseIdentifier: String

    public init?(
        schemaVersion: Int = IdleScreenCameraWire.currentSchemaVersion,
        leaseIdentifier: String
    ) {
        guard isCurrentSchema(schemaVersion), isValidOpaqueIdentifier(leaseIdentifier) else {
            return nil
        }
        self.schemaVersion = schemaVersion
        self.leaseIdentifier = leaseIdentifier
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard coder.containsValue(forKey: WireKey.schemaVersion),
              let leaseIdentifier = decodeRequiredString(coder, key: WireKey.leaseIdentifier) else {
            return nil
        }
        let schemaVersion = coder.decodeInteger(forKey: WireKey.schemaVersion)
        guard isCurrentSchema(schemaVersion), isValidOpaqueIdentifier(leaseIdentifier) else {
            return nil
        }
        self.schemaVersion = schemaVersion
        self.leaseIdentifier = leaseIdentifier
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(schemaVersion, forKey: WireKey.schemaVersion)
        coder.encode(leaseIdentifier as NSString, forKey: WireKey.leaseIdentifier)
    }
}

@objcMembers
public final class IdleScreenCameraHeartbeatRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let schemaVersion: Int
    public let leaseIdentifier: String

    public init?(
        schemaVersion: Int = IdleScreenCameraWire.currentSchemaVersion,
        leaseIdentifier: String
    ) {
        guard isCurrentSchema(schemaVersion), isValidOpaqueIdentifier(leaseIdentifier) else {
            return nil
        }
        self.schemaVersion = schemaVersion
        self.leaseIdentifier = leaseIdentifier
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard coder.containsValue(forKey: WireKey.schemaVersion),
              let leaseIdentifier = decodeRequiredString(coder, key: WireKey.leaseIdentifier) else {
            return nil
        }
        let schemaVersion = coder.decodeInteger(forKey: WireKey.schemaVersion)
        guard isCurrentSchema(schemaVersion), isValidOpaqueIdentifier(leaseIdentifier) else {
            return nil
        }
        self.schemaVersion = schemaVersion
        self.leaseIdentifier = leaseIdentifier
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(schemaVersion, forKey: WireKey.schemaVersion)
        coder.encode(leaseIdentifier as NSString, forKey: WireKey.leaseIdentifier)
    }
}

@objcMembers
public final class IdleScreenCameraDiagnosticRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let schemaVersion: Int

    public init?(schemaVersion: Int = IdleScreenCameraWire.currentSchemaVersion) {
        guard isCurrentSchema(schemaVersion) else { return nil }
        self.schemaVersion = schemaVersion
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard coder.containsValue(forKey: WireKey.schemaVersion) else { return nil }
        let schemaVersion = coder.decodeInteger(forKey: WireKey.schemaVersion)
        guard isCurrentSchema(schemaVersion) else { return nil }
        self.schemaVersion = schemaVersion
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(schemaVersion, forKey: WireKey.schemaVersion)
    }
}

@objcMembers
public final class IdleScreenCameraAuthorizationReply: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let schemaVersion: Int
    public let accepted: Bool
    public let status: IdleScreenCameraAuthorizationStatus
    public let errorCode: IdleScreenCameraXPCErrorCode
    public let errorMessage: String?

    public init?(
        schemaVersion: Int = IdleScreenCameraWire.currentSchemaVersion,
        accepted: Bool,
        status: IdleScreenCameraAuthorizationStatus,
        errorCode: IdleScreenCameraXPCErrorCode,
        errorMessage: String?
    ) {
        guard isValidReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.status = status
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        super.init()
    }

    public required init?(coder: NSCoder) {
        let requiredKeys = [WireKey.schemaVersion, WireKey.accepted, WireKey.status, WireKey.errorCode]
        guard requiredKeys.allSatisfy(coder.containsValue(forKey:)),
              let status = IdleScreenCameraAuthorizationStatus(
                rawValue: coder.decodeInteger(forKey: WireKey.status)
              ),
              let errorCode = IdleScreenCameraXPCErrorCode(
                rawValue: coder.decodeInteger(forKey: WireKey.errorCode)
              ),
              let optionalErrorMessage = decodeOptionalString(coder, key: WireKey.errorMessage) else {
            return nil
        }

        let schemaVersion = coder.decodeInteger(forKey: WireKey.schemaVersion)
        let accepted = coder.decodeBool(forKey: WireKey.accepted)
        guard isValidReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: optionalErrorMessage
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.status = status
        self.errorCode = errorCode
        self.errorMessage = optionalErrorMessage
        super.init()
    }

    public func encode(with coder: NSCoder) {
        encodeReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage,
            coder: coder
        )
        coder.encode(status.rawValue, forKey: WireKey.status)
    }
}

@objcMembers
public final class IdleScreenCameraBeginStreamReply: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let schemaVersion: Int
    public let accepted: Bool
    public let errorCode: IdleScreenCameraXPCErrorCode
    public let errorMessage: String?
    public let leaseIdentifier: String?
    public let producerStreamEpoch: UInt64
    public let transportIdentifier: String?

    public init?(
        schemaVersion: Int = IdleScreenCameraWire.currentSchemaVersion,
        accepted: Bool,
        errorCode: IdleScreenCameraXPCErrorCode,
        errorMessage: String?,
        leaseIdentifier: String?,
        producerStreamEpoch: UInt64,
        transportIdentifier: String?
    ) {
        guard Self.isValid(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage,
            leaseIdentifier: leaseIdentifier,
            producerStreamEpoch: producerStreamEpoch,
            transportIdentifier: transportIdentifier
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.leaseIdentifier = leaseIdentifier
        self.producerStreamEpoch = producerStreamEpoch
        self.transportIdentifier = transportIdentifier
        super.init()
    }

    public required init?(coder: NSCoder) {
        let requiredKeys = [
            WireKey.schemaVersion,
            WireKey.accepted,
            WireKey.errorCode,
            WireKey.producerStreamEpoch,
        ]
        guard requiredKeys.allSatisfy(coder.containsValue(forKey:)),
              let errorCode = IdleScreenCameraXPCErrorCode(
                rawValue: coder.decodeInteger(forKey: WireKey.errorCode)
              ),
              let errorMessage = decodeOptionalString(coder, key: WireKey.errorMessage),
              let leaseIdentifier = decodeOptionalString(coder, key: WireKey.leaseIdentifier),
              let transportIdentifier = decodeOptionalString(coder, key: WireKey.transportIdentifier) else {
            return nil
        }

        let schemaVersion = coder.decodeInteger(forKey: WireKey.schemaVersion)
        let accepted = coder.decodeBool(forKey: WireKey.accepted)
        let signedEpoch = coder.decodeInt64(forKey: WireKey.producerStreamEpoch)
        guard signedEpoch >= 0 else { return nil }
        let producerStreamEpoch = UInt64(signedEpoch)
        guard Self.isValid(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage,
            leaseIdentifier: leaseIdentifier,
            producerStreamEpoch: producerStreamEpoch,
            transportIdentifier: transportIdentifier
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.leaseIdentifier = leaseIdentifier
        self.producerStreamEpoch = producerStreamEpoch
        self.transportIdentifier = transportIdentifier
        super.init()
    }

    public func encode(with coder: NSCoder) {
        encodeReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage,
            coder: coder
        )
        encodeOptionalString(leaseIdentifier, coder: coder, key: WireKey.leaseIdentifier)
        coder.encode(Int64(producerStreamEpoch), forKey: WireKey.producerStreamEpoch)
        encodeOptionalString(transportIdentifier, coder: coder, key: WireKey.transportIdentifier)
    }

    private static func isValid(
        schemaVersion: Int,
        accepted: Bool,
        errorCode: IdleScreenCameraXPCErrorCode,
        errorMessage: String?,
        leaseIdentifier: String?,
        producerStreamEpoch: UInt64,
        transportIdentifier: String?
    ) -> Bool {
        guard producerStreamEpoch <= UInt64(Int64.max),
              isValidReplyEnvelope(
                schemaVersion: schemaVersion,
                accepted: accepted,
                errorCode: errorCode,
                errorMessage: errorMessage
              ) else {
            return false
        }

        if accepted {
            return leaseIdentifier.map(isValidOpaqueIdentifier) == true
                && producerStreamEpoch > 0
                && transportIdentifier.map(isValidRelativeTransportIdentifier) == true
        }
        return leaseIdentifier == nil && producerStreamEpoch == 0 && transportIdentifier == nil
    }
}

@objcMembers
public final class IdleScreenCameraEndStreamReply: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let schemaVersion: Int
    public let accepted: Bool
    public let errorCode: IdleScreenCameraXPCErrorCode
    public let errorMessage: String?

    public init?(
        schemaVersion: Int = IdleScreenCameraWire.currentSchemaVersion,
        accepted: Bool,
        errorCode: IdleScreenCameraXPCErrorCode,
        errorMessage: String?
    ) {
        guard isValidReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        super.init()
    }

    public required init?(coder: NSCoder) {
        let requiredKeys = [WireKey.schemaVersion, WireKey.accepted, WireKey.errorCode]
        guard requiredKeys.allSatisfy(coder.containsValue(forKey:)),
              let errorCode = IdleScreenCameraXPCErrorCode(
                rawValue: coder.decodeInteger(forKey: WireKey.errorCode)
              ),
              let errorMessage = decodeOptionalString(coder, key: WireKey.errorMessage) else {
            return nil
        }
        let schemaVersion = coder.decodeInteger(forKey: WireKey.schemaVersion)
        let accepted = coder.decodeBool(forKey: WireKey.accepted)
        guard isValidReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        super.init()
    }

    public func encode(with coder: NSCoder) {
        encodeReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage,
            coder: coder
        )
    }
}

@objcMembers
public final class IdleScreenCameraHeartbeatReply: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let schemaVersion: Int
    public let accepted: Bool
    public let errorCode: IdleScreenCameraXPCErrorCode
    public let errorMessage: String?

    public init?(
        schemaVersion: Int = IdleScreenCameraWire.currentSchemaVersion,
        accepted: Bool,
        errorCode: IdleScreenCameraXPCErrorCode,
        errorMessage: String?
    ) {
        guard isValidReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        super.init()
    }

    public required init?(coder: NSCoder) {
        let requiredKeys = [WireKey.schemaVersion, WireKey.accepted, WireKey.errorCode]
        guard requiredKeys.allSatisfy(coder.containsValue(forKey:)),
              let errorCode = IdleScreenCameraXPCErrorCode(
                rawValue: coder.decodeInteger(forKey: WireKey.errorCode)
              ),
              let errorMessage = decodeOptionalString(coder, key: WireKey.errorMessage) else {
            return nil
        }
        let schemaVersion = coder.decodeInteger(forKey: WireKey.schemaVersion)
        let accepted = coder.decodeBool(forKey: WireKey.accepted)
        guard isValidReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        super.init()
    }

    public func encode(with coder: NSCoder) {
        encodeReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage,
            coder: coder
        )
    }
}

@objcMembers
public final class IdleScreenCameraDiagnosticSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let schemaVersion: Int
    public let accepted: Bool
    public let errorCode: IdleScreenCameraXPCErrorCode
    public let errorMessage: String?
    public let agentIdentity: IdleScreenCameraAgentIdentity?
    public let authorizationStatus: IdleScreenCameraAuthorizationStatus
    public let captureActive: Bool
    public let activeLeaseCount: Int
    public let producerStreamEpoch: UInt64
    public let summary: String

    public init?(
        schemaVersion: Int = IdleScreenCameraWire.currentSchemaVersion,
        accepted: Bool,
        errorCode: IdleScreenCameraXPCErrorCode,
        errorMessage: String?,
        agentIdentity: IdleScreenCameraAgentIdentity? = nil,
        authorizationStatus: IdleScreenCameraAuthorizationStatus,
        captureActive: Bool,
        activeLeaseCount: Int,
        producerStreamEpoch: UInt64,
        summary: String
    ) {
        guard Self.isValid(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage,
            agentIdentity: agentIdentity,
            captureActive: captureActive,
            activeLeaseCount: activeLeaseCount,
            producerStreamEpoch: producerStreamEpoch,
            summary: summary
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.agentIdentity = agentIdentity
        self.authorizationStatus = authorizationStatus
        self.captureActive = captureActive
        self.activeLeaseCount = activeLeaseCount
        self.producerStreamEpoch = producerStreamEpoch
        self.summary = summary
        super.init()
    }

    public required init?(coder: NSCoder) {
        let requiredKeys = [
            WireKey.schemaVersion,
            WireKey.accepted,
            WireKey.errorCode,
            WireKey.authorizationStatus,
            WireKey.captureActive,
            WireKey.activeLeaseCount,
            WireKey.producerStreamEpoch,
            WireKey.summary,
        ]
        guard requiredKeys.allSatisfy(coder.containsValue(forKey:)),
              let errorCode = IdleScreenCameraXPCErrorCode(
                rawValue: coder.decodeInteger(forKey: WireKey.errorCode)
              ),
              let authorizationStatus = IdleScreenCameraAuthorizationStatus(
                rawValue: coder.decodeInteger(forKey: WireKey.authorizationStatus)
              ),
              let errorMessage = decodeOptionalString(coder, key: WireKey.errorMessage),
              let summary = decodeRequiredString(coder, key: WireKey.summary) else {
            return nil
        }

        let agentIdentity: IdleScreenCameraAgentIdentity?
        if coder.containsValue(forKey: WireKey.agentIdentity) {
            guard let decodedIdentity = coder.decodeObject(
                of: IdleScreenCameraAgentIdentity.self,
                forKey: WireKey.agentIdentity
            ) else { return nil }
            agentIdentity = decodedIdentity
        } else {
            agentIdentity = nil
        }

        let schemaVersion = coder.decodeInteger(forKey: WireKey.schemaVersion)
        let accepted = coder.decodeBool(forKey: WireKey.accepted)
        let captureActive = coder.decodeBool(forKey: WireKey.captureActive)
        let activeLeaseCount = coder.decodeInteger(forKey: WireKey.activeLeaseCount)
        let signedEpoch = coder.decodeInt64(forKey: WireKey.producerStreamEpoch)
        guard signedEpoch >= 0 else { return nil }
        let producerStreamEpoch = UInt64(signedEpoch)
        guard Self.isValid(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage,
            agentIdentity: agentIdentity,
            captureActive: captureActive,
            activeLeaseCount: activeLeaseCount,
            producerStreamEpoch: producerStreamEpoch,
            summary: summary
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.agentIdentity = agentIdentity
        self.authorizationStatus = authorizationStatus
        self.captureActive = captureActive
        self.activeLeaseCount = activeLeaseCount
        self.producerStreamEpoch = producerStreamEpoch
        self.summary = summary
        super.init()
    }

    public func encode(with coder: NSCoder) {
        encodeReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage,
            coder: coder
        )
        if let agentIdentity {
            coder.encode(agentIdentity, forKey: WireKey.agentIdentity)
        }
        coder.encode(authorizationStatus.rawValue, forKey: WireKey.authorizationStatus)
        coder.encode(captureActive, forKey: WireKey.captureActive)
        coder.encode(activeLeaseCount, forKey: WireKey.activeLeaseCount)
        coder.encode(Int64(producerStreamEpoch), forKey: WireKey.producerStreamEpoch)
        coder.encode(summary as NSString, forKey: WireKey.summary)
    }

    private static func isValid(
        schemaVersion: Int,
        accepted: Bool,
        errorCode: IdleScreenCameraXPCErrorCode,
        errorMessage: String?,
        agentIdentity: IdleScreenCameraAgentIdentity?,
        captureActive: Bool,
        activeLeaseCount: Int,
        producerStreamEpoch: UInt64,
        summary: String
    ) -> Bool {
        guard isValidReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage
        ),
        (0...IdleScreenCameraWire.maximumActiveLeaseCount).contains(activeLeaseCount),
        producerStreamEpoch <= UInt64(Int64.max),
        isBoundedWireText(
            summary,
            maximumUTF8ByteCount: IdleScreenCameraWire.maximumDiagnosticSummaryUTF8ByteCount
        ) else {
            return false
        }

        if accepted {
            return agentIdentity != nil
                && (!captureActive || (activeLeaseCount > 0 && producerStreamEpoch > 0))
        }
        return !captureActive && activeLeaseCount == 0 && producerStreamEpoch == 0
    }
}

/// A single, bounded view of helper-owned camera selection state. Generation is
/// scoped to the current helper inventory monitor and may restart after the
/// helper relaunches; clients must not treat it as durable configuration.
@objcMembers
public final class IdleScreenCameraDeviceSnapshotReply: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let schemaVersion: Int
    public let accepted: Bool
    public let errorCode: IdleScreenCameraXPCErrorCode
    public let errorMessage: String?
    public let inventoryGeneration: UInt64
    public let connectedDevices: [IdleScreenCameraDeviceDescriptor]
    public let configuredSelection: IdleScreenCameraDeviceSelectionState?
    public let preferredDeviceIdentifier: String?
    public let resolvedDeviceIdentifier: String?
    public let activeDeviceIdentifier: String?
    public let reconfigurationPending: Bool

    public init?(
        schemaVersion: Int = IdleScreenCameraWire.currentSchemaVersion,
        accepted: Bool,
        errorCode: IdleScreenCameraXPCErrorCode,
        errorMessage: String?,
        inventoryGeneration: UInt64,
        connectedDevices: [IdleScreenCameraDeviceDescriptor],
        configuredSelection: IdleScreenCameraDeviceSelectionState?,
        preferredDeviceIdentifier: String? = nil,
        resolvedDeviceIdentifier: String?,
        activeDeviceIdentifier: String?,
        reconfigurationPending: Bool
    ) {
        guard Self.isValid(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage,
            inventoryGeneration: inventoryGeneration,
            connectedDevices: connectedDevices,
            configuredSelection: configuredSelection,
            preferredDeviceIdentifier: preferredDeviceIdentifier,
            resolvedDeviceIdentifier: resolvedDeviceIdentifier,
            activeDeviceIdentifier: activeDeviceIdentifier,
            reconfigurationPending: reconfigurationPending
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.inventoryGeneration = inventoryGeneration
        self.connectedDevices = connectedDevices
        self.configuredSelection = configuredSelection
        self.preferredDeviceIdentifier = preferredDeviceIdentifier
        self.resolvedDeviceIdentifier = resolvedDeviceIdentifier
        self.activeDeviceIdentifier = activeDeviceIdentifier
        self.reconfigurationPending = reconfigurationPending
        super.init()
    }

    public required init?(coder: NSCoder) {
        let requiredKeys = [
            WireKey.schemaVersion,
            WireKey.accepted,
            WireKey.errorCode,
            WireKey.cameraInventoryGeneration,
            WireKey.connectedCameraDevices,
            WireKey.cameraDeviceReconfigurationPending,
        ]
        guard requiredKeys.allSatisfy(coder.containsValue(forKey:)),
              let errorCode = IdleScreenCameraXPCErrorCode(
                rawValue: coder.decodeInteger(forKey: WireKey.errorCode)
              ),
              let errorMessage = decodeOptionalString(coder, key: WireKey.errorMessage),
              let connectedDevices = coder.decodeObject(
                of: [NSArray.self, IdleScreenCameraDeviceDescriptor.self],
                forKey: WireKey.connectedCameraDevices
              ) as? [IdleScreenCameraDeviceDescriptor],
              let activeDeviceIdentifier = decodeOptionalString(
                  coder,
                  key: WireKey.activeCameraDeviceIdentifier
              ),
              let resolvedDeviceIdentifier = decodeOptionalString(
                  coder,
                  key: WireKey.resolvedCameraDeviceIdentifier
              ),
              let preferredDeviceIdentifier = decodeOptionalString(
                  coder,
                  key: WireKey.preferredCameraDeviceIdentifier
              ) else {
            return nil
        }

        let configuredSelection: IdleScreenCameraDeviceSelectionState?
        if coder.containsValue(forKey: WireKey.configuredCameraDeviceSelection) {
            guard let selection = coder.decodeObject(
                of: IdleScreenCameraDeviceSelectionState.self,
                forKey: WireKey.configuredCameraDeviceSelection
            ) else { return nil }
            configuredSelection = selection
        } else {
            configuredSelection = nil
        }

        let schemaVersion = coder.decodeInteger(forKey: WireKey.schemaVersion)
        let accepted = coder.decodeBool(forKey: WireKey.accepted)
        let reconfigurationPending = coder.decodeBool(
            forKey: WireKey.cameraDeviceReconfigurationPending
        )
        let signedGeneration = coder.decodeInt64(
            forKey: WireKey.cameraInventoryGeneration
        )
        guard signedGeneration >= 0 else { return nil }
        let inventoryGeneration = UInt64(signedGeneration)
        guard Self.isValid(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage,
            inventoryGeneration: inventoryGeneration,
            connectedDevices: connectedDevices,
            configuredSelection: configuredSelection,
            preferredDeviceIdentifier: preferredDeviceIdentifier,
            resolvedDeviceIdentifier: resolvedDeviceIdentifier,
            activeDeviceIdentifier: activeDeviceIdentifier,
            reconfigurationPending: reconfigurationPending
        ) else { return nil }

        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.inventoryGeneration = inventoryGeneration
        self.connectedDevices = connectedDevices
        self.configuredSelection = configuredSelection
        self.preferredDeviceIdentifier = preferredDeviceIdentifier
        self.resolvedDeviceIdentifier = resolvedDeviceIdentifier
        self.activeDeviceIdentifier = activeDeviceIdentifier
        self.reconfigurationPending = reconfigurationPending
        super.init()
    }

    public func encode(with coder: NSCoder) {
        encodeReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage,
            coder: coder
        )
        coder.encode(
            Int64(inventoryGeneration),
            forKey: WireKey.cameraInventoryGeneration
        )
        coder.encode(connectedDevices as NSArray, forKey: WireKey.connectedCameraDevices)
        if let configuredSelection {
            coder.encode(
                configuredSelection,
                forKey: WireKey.configuredCameraDeviceSelection
            )
        }
        encodeOptionalString(
            preferredDeviceIdentifier,
            coder: coder,
            key: WireKey.preferredCameraDeviceIdentifier
        )
        encodeOptionalString(
            resolvedDeviceIdentifier,
            coder: coder,
            key: WireKey.resolvedCameraDeviceIdentifier
        )
        encodeOptionalString(
            activeDeviceIdentifier,
            coder: coder,
            key: WireKey.activeCameraDeviceIdentifier
        )
        coder.encode(
            reconfigurationPending,
            forKey: WireKey.cameraDeviceReconfigurationPending
        )
    }

    private static func isValid(
        schemaVersion: Int,
        accepted: Bool,
        errorCode: IdleScreenCameraXPCErrorCode,
        errorMessage: String?,
        inventoryGeneration: UInt64,
        connectedDevices: [IdleScreenCameraDeviceDescriptor],
        configuredSelection: IdleScreenCameraDeviceSelectionState?,
        preferredDeviceIdentifier: String?,
        resolvedDeviceIdentifier: String?,
        activeDeviceIdentifier: String?,
        reconfigurationPending: Bool
    ) -> Bool {
        guard isValidReplyEnvelope(
            schemaVersion: schemaVersion,
            accepted: accepted,
            errorCode: errorCode,
            errorMessage: errorMessage
        ),
        inventoryGeneration <= UInt64(Int64.max),
        connectedDevices.count <= IdleScreenCameraWire.maximumCameraDeviceCount,
        Set(connectedDevices.map(\.deviceIdentifier)).count == connectedDevices.count,
        preferredDeviceIdentifier.map(isValidCameraDeviceIdentifier) ?? true,
        resolvedDeviceIdentifier.map(isValidCameraDeviceIdentifier) ?? true,
        activeDeviceIdentifier.map(isValidCameraDeviceIdentifier) ?? true else {
            return false
        }

        if accepted {
            return configuredSelection != nil
        }
        return inventoryGeneration == 0
            && connectedDevices.isEmpty
            && configuredSelection == nil
            && preferredDeviceIdentifier == nil
            && resolvedDeviceIdentifier == nil
            && activeDeviceIdentifier == nil
            && !reconfigurationPending
    }
}

private enum WireKey {
    static let schemaVersion = "schemaVersion"
    static let maximumWidth = "maximumWidth"
    static let maximumHeight = "maximumHeight"
    static let maximumFramesPerSecond = "maximumFramesPerSecond"
    static let mailboxSlotCount = "mailboxSlotCount"
    static let accepted = "accepted"
    static let status = "status"
    static let authorizationStatus = "authorizationStatus"
    static let errorCode = "errorCode"
    static let errorMessage = "errorMessage"
    static let agentIdentity = "agentIdentity"
    static let processIdentifier = "processIdentifier"
    static let processIncarnationEpoch = "processIncarnationEpoch"
    static let bundleIdentifier = "bundleIdentifier"
    static let serviceIdentifier = "serviceIdentifier"
    static let bundleVersion = "bundleVersion"
    static let marketingVersion = "marketingVersion"
    static let signingIdentifier = "signingIdentifier"
    static let teamIdentifier = "teamIdentifier"
    static let codeDirectoryHash = "codeDirectoryHash"
    static let executableSHA256 = "executableSHA256"
    static let launchAgentSHA256 = "launchAgentSHA256"
    static let provisioningProfileSHA256 = "provisioningProfileSHA256"
    static let sourceAppPath = "sourceAppPath"
    static let leaseIdentifier = "leaseIdentifier"
    static let producerStreamEpoch = "producerStreamEpoch"
    static let transportIdentifier = "transportIdentifier"
    static let captureActive = "captureActive"
    static let activeLeaseCount = "activeLeaseCount"
    static let summary = "summary"
    static let cameraDeviceIdentifier = "cameraDeviceIdentifier"
    static let cameraDeviceName = "cameraDeviceName"
    static let cameraDeviceKind = "cameraDeviceKind"
    static let cameraDeviceSelectionMode = "cameraDeviceSelectionMode"
    static let cameraInventoryGeneration = "cameraInventoryGeneration"
    static let connectedCameraDevices = "connectedCameraDevices"
    static let configuredCameraDeviceSelection = "configuredCameraDeviceSelection"
    static let preferredCameraDeviceIdentifier = "preferredCameraDeviceIdentifier"
    static let resolvedCameraDeviceIdentifier = "resolvedCameraDeviceIdentifier"
    static let activeCameraDeviceIdentifier = "activeCameraDeviceIdentifier"
    static let cameraDeviceReconfigurationPending = "cameraDeviceReconfigurationPending"
}

private func isCurrentSchema(_ schemaVersion: Int) -> Bool {
    schemaVersion == IdleScreenCameraWire.currentSchemaVersion
}

private func isValidOpaqueIdentifier(_ value: String) -> Bool {
    guard isBoundedASCII(
        value,
        maximumUTF8ByteCount: IdleScreenCameraWire.maximumLeaseIdentifierUTF8ByteCount
    ) else { return false }

    return value.unicodeScalars.allSatisfy { scalar in
        CharacterSet.alphanumerics.contains(scalar) || "_-".unicodeScalars.contains(scalar)
    }
}

private func isValidCameraDeviceIdentifier(_ value: String) -> Bool {
    !value.isEmpty
        && value.utf8.count <= IdleScreenCameraWire.maximumCameraDeviceIdentifierUTF8ByteCount
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}

private func isValidCameraDeviceName(_ value: String) -> Bool {
    !value.isEmpty
        && isBoundedWireText(
            value,
            maximumUTF8ByteCount: IdleScreenCameraWire.maximumCameraDeviceNameUTF8ByteCount
        )
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}

private func isValidRelativeTransportIdentifier(_ value: String) -> Bool {
    guard isBoundedASCII(
        value,
        maximumUTF8ByteCount: IdleScreenCameraWire.maximumTransportIdentifierUTF8ByteCount
    ),
    !value.hasPrefix("/") else {
        return false
    }

    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty else { return false }
    return components.allSatisfy { component in
        component != "."
            && component != ".."
            && !component.isEmpty
            && component.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || "_.-".unicodeScalars.contains(scalar)
            }
    }
}

private func isBoundedASCII(_ value: String, maximumUTF8ByteCount: Int) -> Bool {
    !value.isEmpty
        && value.utf8.count <= maximumUTF8ByteCount
        && value.unicodeScalars.allSatisfy(\.isASCII)
}

private func isValidDottedIdentifier(_ value: String) -> Bool {
    guard isBoundedASCII(
        value,
        maximumUTF8ByteCount: IdleScreenCameraWire.maximumIdentityIdentifierUTF8ByteCount
    ) else { return false }

    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count >= 2 else { return false }
    return components.allSatisfy { component in
        guard let first = component.utf8.first,
              let last = component.utf8.last,
              first != 0x2D,
              last != 0x2D else {
            return false
        }
        return component.utf8.allSatisfy {
            (0x30...0x39).contains($0)
                || (0x41...0x5A).contains($0)
                || (0x61...0x7A).contains($0)
                || $0 == 0x2D
        }
    }
}

private func isValidVersion(_ value: String) -> Bool {
    isBoundedASCII(
        value,
        maximumUTF8ByteCount: IdleScreenCameraWire.maximumVersionUTF8ByteCount
    ) && value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
}

private func isValidTeamIdentifier(_ value: String) -> Bool {
    value.utf8.count == 10 && value.utf8.allSatisfy {
        (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
    }
}

private func isHexadecimal(_ value: String, length: Int) -> Bool {
    value.utf8.count == length && value.utf8.allSatisfy {
        (0x30...0x39).contains($0)
            || (0x41...0x46).contains($0)
            || (0x61...0x66).contains($0)
    }
}

private func isCanonicalAppPath(_ value: String) -> Bool {
    guard isBoundedWireText(
        value,
        maximumUTF8ByteCount: IdleScreenCameraWire.maximumSourceAppPathUTF8ByteCount
    ),
    value.hasPrefix("/"),
    (value as NSString).standardizingPath == value,
    (value as NSString).pathExtension == "app",
    !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        return false
    }
    return true
}

private func isBoundedWireText(_ value: String, maximumUTF8ByteCount: Int) -> Bool {
    value.utf8.count <= maximumUTF8ByteCount
        && !value.unicodeScalars.contains(where: { $0.value == 0 })
}

private func isValidReplyEnvelope(
    schemaVersion: Int,
    accepted: Bool,
    errorCode: IdleScreenCameraXPCErrorCode,
    errorMessage: String?
) -> Bool {
    guard isCurrentSchema(schemaVersion),
          errorMessage.map({
              isBoundedWireText(
                $0,
                maximumUTF8ByteCount: IdleScreenCameraWire.maximumErrorMessageUTF8ByteCount
              )
          }) ?? true else {
        return false
    }

    if accepted {
        return errorCode == .none && errorMessage == nil
    }
    return errorCode != .none
}

private func decodeRequiredString(_ coder: NSCoder, key: String) -> String? {
    guard coder.containsValue(forKey: key),
          let value = coder.decodeObject(of: NSString.self, forKey: key) else {
        return nil
    }
    return value as String
}

/// An outer optional distinguishes an absent optional value from a present value
/// whose archived class was not the explicitly allowed NSString class.
private func decodeOptionalString(_ coder: NSCoder, key: String) -> String?? {
    guard coder.containsValue(forKey: key) else { return .some(nil) }
    guard let value = coder.decodeObject(of: NSString.self, forKey: key) else { return nil }
    return .some(value as String)
}

private func encodeOptionalString(_ value: String?, coder: NSCoder, key: String) {
    if let value {
        coder.encode(value as NSString, forKey: key)
    }
}

private func encodeReplyEnvelope(
    schemaVersion: Int,
    accepted: Bool,
    errorCode: IdleScreenCameraXPCErrorCode,
    errorMessage: String?,
    coder: NSCoder
) {
    coder.encode(schemaVersion, forKey: WireKey.schemaVersion)
    coder.encode(accepted, forKey: WireKey.accepted)
    coder.encode(errorCode.rawValue, forKey: WireKey.errorCode)
    encodeOptionalString(errorMessage, coder: coder, key: WireKey.errorMessage)
}
