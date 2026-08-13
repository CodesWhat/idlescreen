import AppKit
import ColorSync
import CoreGraphics
import Foundation
import IdleScreenCore

public enum MacDisplayTopologyReaderError: Error, Equatable, Sendable {
    case displayList(code: Int32)
    case noActiveDisplays
    case missingPersistentIdentifier(
        DisplayTopology.RuntimeDisplayIdentifier
    )
    case missingLogicalScreen(
        DisplayTopology.RuntimeDisplayIdentifier
    )
}

/// Reads one coherent-enough macOS display observation for validation and
/// publication. AppKit supplies the positive-Y-up logical desktop coordinates;
/// Core Graphics supplies runtime identity, pixels, rotation, and mirroring.
/// A hardware mirror omitted by `NSScreen.screens` inherits its leader's
/// logical frame, scale, and safe area while retaining its own physical pixels,
/// rotation, refresh rate, and persistent ColorSync UUID.
@MainActor
public struct MacDisplayTopologyReader {
    public typealias ObservationReader = @MainActor () throws -> [DisplayTopologyObservation]

    private let readObservations: ObservationReader

    public init() {
        readObservations = Self.liveObservations
    }

    init(readObservations: @escaping ObservationReader) {
        self.readObservations = readObservations
    }

    public func readTopology() throws -> DisplayTopology {
        try DisplayTopologyObservationAdapter().topology(
            from: readObservations()
        )
    }
}

extension MacDisplayTopologyReader {
    fileprivate struct ScreenMetadata {
        let frame: CGRect
        let backingScale: Double
        let safeAreaInsets: NSEdgeInsets
        let minimumRefreshInterval: TimeInterval
        let maximumRefreshInterval: TimeInterval
    }

    fileprivate static func liveObservations() throws -> [DisplayTopologyObservation] {
        let onlineDisplayIdentifiers = try onlineDisplayIdentifiers()
        let activeOrMirrored = onlineDisplayIdentifiers.filter {
            CGDisplayIsActive($0) != 0
                || CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay
        }
        guard !activeOrMirrored.isEmpty else {
            throw MacDisplayTopologyReaderError.noActiveDisplays
        }

        let screensByIdentifier: [CGDirectDisplayID: ScreenMetadata] =
            Dictionary(
                uniqueKeysWithValues: NSScreen.screens.compactMap {
                    screen -> (CGDirectDisplayID, ScreenMetadata)? in
                    guard
                        let number = screen.deviceDescription[
                            NSDeviceDescriptionKey("NSScreenNumber")
                        ] as? NSNumber
                    else {
                        return nil
                    }
                    return (
                        CGDirectDisplayID(number.uint32Value),
                        ScreenMetadata(
                            frame: screen.frame,
                            backingScale: Double(screen.backingScaleFactor),
                            safeAreaInsets: screen.safeAreaInsets,
                            minimumRefreshInterval: screen.minimumRefreshInterval,
                            maximumRefreshInterval: screen.maximumRefreshInterval
                        )
                    )
                }
            )
        let mainDisplayIdentifier = CGMainDisplayID()

        return try activeOrMirrored.map { displayIdentifier in
            let runtimeIdentifier = DisplayTopology.RuntimeDisplayIdentifier(
                rawValue: displayIdentifier
            )
            let mirroredDisplayIdentifier = CGDisplayMirrorsDisplay(
                displayIdentifier
            )
            let mirrorTarget =
                mirroredDisplayIdentifier
                    == kCGNullDirectDisplay
                ? nil
                : DisplayTopology.RuntimeDisplayIdentifier(
                    rawValue: mirroredDisplayIdentifier
                )
            let exactScreen = screensByIdentifier[displayIdentifier]
            guard
                let screen = exactScreen
                    ?? screensByIdentifier[mirroredDisplayIdentifier]
            else {
                throw MacDisplayTopologyReaderError.missingLogicalScreen(
                    runtimeIdentifier
                )
            }
            guard
                let persistentIdentifier = persistentIdentifier(
                    for: displayIdentifier
                )
            else {
                throw
                    MacDisplayTopologyReaderError
                    .missingPersistentIdentifier(runtimeIdentifier)
            }

            let frame = screen.frame
            let insets = screen.safeAreaInsets
            return DisplayTopologyObservation(
                runtimeIdentifier: runtimeIdentifier,
                persistentIdentifier: persistentIdentifier,
                logicalFrame: .init(
                    x: Double(frame.origin.x),
                    y: Double(frame.origin.y),
                    width: Double(frame.size.width),
                    height: Double(frame.size.height)
                ),
                nativePixelSize: .init(
                    width: Int(CGDisplayPixelsWide(displayIdentifier)),
                    height: Int(CGDisplayPixelsHigh(displayIdentifier))
                ),
                backingScale: screen.backingScale,
                rotationDegrees: Int(
                    CGDisplayRotation(displayIdentifier).rounded()
                ),
                refreshRateRange: refreshRateRange(
                    for: displayIdentifier,
                    screen: exactScreen
                ),
                safeAreaInsets: .init(
                    top: Double(insets.top),
                    left: Double(insets.left),
                    bottom: Double(insets.bottom),
                    right: Double(insets.right)
                ),
                isPrimary: displayIdentifier == mainDisplayIdentifier,
                mirrorTargetRuntimeIdentifier: mirrorTarget
            )
        }
    }

    fileprivate static func onlineDisplayIdentifiers() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let countError = CGGetOnlineDisplayList(0, nil, &count)
        guard countError == .success else {
            throw MacDisplayTopologyReaderError.displayList(
                code: Int32(countError.rawValue)
            )
        }
        guard count > 0 else { return [] }

        var identifiers = Array(
            repeating: CGDirectDisplayID(0),
            count: Int(count)
        )
        var returnedCount = count
        let listError = identifiers.withUnsafeMutableBufferPointer { buffer in
            CGGetOnlineDisplayList(
                count,
                buffer.baseAddress,
                &returnedCount
            )
        }
        guard listError == .success else {
            throw MacDisplayTopologyReaderError.displayList(
                code: Int32(listError.rawValue)
            )
        }
        return Array(identifiers.prefix(Int(min(count, returnedCount))))
    }

    fileprivate static func persistentIdentifier(
        for displayIdentifier: CGDirectDisplayID
    ) -> DisplayTopology.PersistentDisplayIdentifier? {
        guard
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayIdentifier)?
                .takeRetainedValue(),
            let rawValue = CFUUIDCreateString(nil, uuid) as String?
        else {
            return nil
        }
        return .init(rawValue: rawValue.lowercased())
    }

    fileprivate static func refreshRateRange(
        for displayIdentifier: CGDirectDisplayID,
        screen: ScreenMetadata?
    ) -> DisplayTopology.RefreshRateRange? {
        guard let mode = CGDisplayCopyDisplayMode(displayIdentifier) else {
            return nil
        }
        let currentHz = mode.refreshRate
        guard currentHz.isFinite, currentHz > 0 else { return nil }

        guard let screen,
            screen.minimumRefreshInterval.isFinite,
            screen.maximumRefreshInterval.isFinite,
            screen.minimumRefreshInterval > 0,
            screen.maximumRefreshInterval > 0
        else {
            return .init(
                minimumHz: currentHz,
                maximumHz: currentHz,
                currentHz: currentHz
            )
        }

        let observedMinimumHz = 1 / screen.maximumRefreshInterval
        let observedMaximumHz = 1 / screen.minimumRefreshInterval
        return .init(
            minimumHz: min(observedMinimumHz, currentHz),
            maximumHz: max(observedMaximumHz, currentHz),
            currentHz: currentHz
        )
    }
}
