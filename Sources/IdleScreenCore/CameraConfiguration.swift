import Foundation

/// The user's process-wide camera choice. This is intentionally independent of
/// stream leases and Saved Looks: every consumer uses the one camera selected
/// by the sole camera agent.
public enum IdleScreenCameraSelection: Equatable, Sendable {
    case automatic
    case device(uniqueID: String)

    public static let maximumDeviceIdentifierUTF8ByteCount = 1_024

    public var deviceIdentifier: String? {
        guard case let .device(uniqueID) = self else { return nil }
        return uniqueID
    }

    public static func deviceIfValid(uniqueID: String) -> Self? {
        guard isValidDeviceIdentifier(uniqueID) else { return nil }
        return .device(uniqueID: uniqueID)
    }

    private static func isValidDeviceIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumDeviceIdentifierUTF8ByteCount
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

extension IdleScreenCameraSelection: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case deviceIdentifier
    }

    private enum Mode: String, Codable {
        case automatic
        case device
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Mode.self, forKey: .mode) {
        case .automatic:
            self = .automatic
        case .device:
            let identifier = try values.decode(String.self, forKey: .deviceIdentifier)
            guard let selection = Self.deviceIfValid(uniqueID: identifier) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .deviceIdentifier,
                    in: values,
                    debugDescription: "Camera device identifier is invalid"
                )
            }
            self = selection
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try values.encode(Mode.automatic, forKey: .mode)
        case let .device(uniqueID):
            guard Self.deviceIfValid(uniqueID: uniqueID) != nil else {
                throw EncodingError.invalidValue(
                    uniqueID,
                    EncodingError.Context(
                        codingPath: values.codingPath + [CodingKeys.deviceIdentifier],
                        debugDescription: "Camera device identifier is invalid"
                    )
                )
            }
            try values.encode(Mode.device, forKey: .mode)
            try values.encode(uniqueID, forKey: .deviceIdentifier)
        }
    }
}

public struct IdleScreenCameraConfiguration: Codable, Equatable, Sendable {
    /// Whether camera pixels are reflected horizontally for a familiar
    /// self-view. This affects presentation only; it never changes capture or
    /// the selected device.
    public var isMirrored: Bool
    public var selection: IdleScreenCameraSelection
    /// A soft preference used only while `selection` is Automatic. When this
    /// device is absent, the agent follows its normal automatic policy and
    /// automatically returns here when the device reappears.
    public var preferredDeviceIdentifier: String?

    public init(
        selection: IdleScreenCameraSelection,
        preferredDeviceIdentifier: String? = nil,
        isMirrored: Bool = true
    ) {
        self.isMirrored = isMirrored
        self.selection = selection
        self.preferredDeviceIdentifier = Self.validatedPreferredIdentifier(
            preferredDeviceIdentifier
        )
    }

    public static let `default` = IdleScreenCameraConfiguration(
        selection: .automatic
    )

    private enum CodingKeys: String, CodingKey {
        case isMirrored
        case selection
        case preferredDeviceIdentifier
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let selection = try values.decode(
            IdleScreenCameraSelection.self,
            forKey: .selection
        )
        let preferredDeviceIdentifier = try values.decodeIfPresent(
            String.self,
            forKey: .preferredDeviceIdentifier
        )
        if let preferredDeviceIdentifier,
           Self.validatedPreferredIdentifier(preferredDeviceIdentifier) == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .preferredDeviceIdentifier,
                in: values,
                debugDescription: "Preferred camera device identifier is invalid"
            )
        }
        self.init(
            selection: selection,
            preferredDeviceIdentifier: preferredDeviceIdentifier,
            // Schema 4 and older documents predate this field. Mirroring them
            // preserves the legacy product's selfie-view default.
            isMirrored: try values.decodeIfPresent(
                Bool.self,
                forKey: .isMirrored
            ) ?? true
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isMirrored, forKey: .isMirrored)
        try values.encode(selection, forKey: .selection)
        if let preferredDeviceIdentifier {
            guard Self.validatedPreferredIdentifier(
                preferredDeviceIdentifier
            ) != nil else {
                throw EncodingError.invalidValue(
                    preferredDeviceIdentifier,
                    EncodingError.Context(
                        codingPath: values.codingPath
                            + [CodingKeys.preferredDeviceIdentifier],
                        debugDescription: "Preferred camera device identifier is invalid"
                    )
                )
            }
            try values.encode(
                preferredDeviceIdentifier,
                forKey: .preferredDeviceIdentifier
            )
        }
    }

    public static func validatedPreferredIdentifier(
        _ identifier: String?
    ) -> String? {
        guard let identifier else { return nil }
        return IdleScreenCameraSelection.deviceIfValid(uniqueID: identifier)?
            .deviceIdentifier
    }
}
