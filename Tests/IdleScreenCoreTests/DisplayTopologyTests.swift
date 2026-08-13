import Foundation
import Testing
@testable import IdleScreenCore

@Suite("Display topology v1")
struct DisplayTopologyTests {
    @Test("v1 round-trips without persisting derived or runtime state")
    func versionedRoundTrip() throws {
        let topology = try DisplayTopology(
            displays: DisplayTopologyFixtures.mixedMetadata
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(topology)
        let payload = try #require(String(data: data, encoding: .utf8))

        #expect(topology.schemaVersion == DisplayTopology.currentSchemaVersion)
        #expect(payload.contains("\"schemaVersion\":1"))
        #expect(!payload.contains("desktopBounds"))
        #expect(!payload.contains("adjacencies"))
        #expect(!payload.contains("runtime"))

        let decoded = try JSONDecoder().decode(DisplayTopology.self, from: data)
        #expect(decoded == topology)
        #expect(try encoder.encode(decoded) == data)

        let persistent = DisplayTopology.PersistentDisplayIdentifier(
            rawValue: "opaque-display-A"
        )
        let runtime = DisplayTopology.RuntimeDisplayIdentifier(rawValue: 42)
        #expect(persistent.rawValue == "opaque-display-A")
        #expect(runtime.rawValue == 42)
    }

    @Test("future topology schemas fail closed")
    func futureSchemaIsRejected() throws {
        let topology = try DisplayTopology(
            displays: DisplayTopologyFixtures.single
        )
        let data = try JSONEncoder().encode(topology)
        let payload = try #require(String(data: data, encoding: .utf8))
        let futurePayload = payload.replacingOccurrences(
            of: "\"schemaVersion\":1",
            with: "\"schemaVersion\":999"
        )
        let futureData = try #require(futurePayload.data(using: .utf8))

        #expect(throws: DisplayTopology.ValidationError.unsupportedSchemaVersion(999)) {
            try JSONDecoder().decode(DisplayTopology.self, from: futureData)
        }

        let unknownFutureData = Data(
            #"{"schemaVersion":999,"displays":[{"futureShape":true}]}"#.utf8
        )
        #expect(throws: DisplayTopology.ValidationError.unsupportedSchemaVersion(999)) {
            try JSONDecoder().decode(DisplayTopology.self, from: unknownFutureData)
        }
    }

    @Test("display order is canonical by opaque persistent identifier")
    func canonicalDisplayOrder() throws {
        let input = [
            DisplayTopologyFixtures.display(
                "zeta",
                x: 200,
                width: 100
            ),
            DisplayTopologyFixtures.display(
                "primary",
                x: 0,
                width: 100,
                isPrimary: true
            ),
            DisplayTopologyFixtures.display(
                "alpha",
                x: 100,
                width: 100
            ),
        ]

        let topology = try DisplayTopology(displays: input)
        let permuted = try DisplayTopology(displays: Array(input.reversed()))

        #expect(topology.displays.map(\.persistentIdentifier.rawValue) == [
            "alpha",
            "primary",
            "zeta",
        ])
        #expect(permuted == topology)
    }

    @Test("negative offset displays derive desktop bounds and partial edge overlap")
    func negativeOriginsAndPartialOverlap() throws {
        let topology = try DisplayTopology(
            displays: DisplayTopologyFixtures.negativeOffset
        )

        #expect(topology.desktopBounds == .init(
            x: -1_600,
            y: -200,
            width: 3_520,
            height: 1_280
        ))
        #expect(topology.adjacencies == [
            .init(
                firstDisplayIdentifier: .init(rawValue: "left"),
                firstEdge: .right,
                secondDisplayIdentifier: .init(rawValue: "primary"),
                secondEdge: .left,
                overlap: .init(axis: .vertical, lowerBound: 0, upperBound: 700)
            ),
        ])
    }

    @Test("positive-Y stacked displays share top and bottom edges")
    func stackedDisplays() throws {
        let topology = try DisplayTopology(
            displays: DisplayTopologyFixtures.stacked
        )

        #expect(topology.adjacencies == [
            .init(
                firstDisplayIdentifier: .init(rawValue: "primary"),
                firstEdge: .top,
                secondDisplayIdentifier: .init(rawValue: "upper"),
                secondEdge: .bottom,
                overlap: .init(
                    axis: .horizontal,
                    lowerBound: 320,
                    upperBound: 1_600
                )
            ),
        ])
    }

    @Test("gaps and corner-only contact do not create adjacency")
    func gapsAndCorners() throws {
        let gapped = try DisplayTopology(
            displays: DisplayTopologyFixtures.gapped
        )
        let corner = try DisplayTopology(
            displays: DisplayTopologyFixtures.cornerTouching
        )

        #expect(gapped.desktopBounds.width == 2_020)
        #expect(gapped.adjacencies.isEmpty)
        #expect(corner.adjacencies.isEmpty)
    }

    @Test("mirrored followers preserve physical metadata without duplicating adjacency")
    func mirroredDisplays() throws {
        let topology = try DisplayTopology(
            displays: DisplayTopologyFixtures.mirrored
        )

        #expect(topology.displays.count == 3)
        #expect(topology.desktopBounds == .init(
            x: 0,
            y: 0,
            width: 3_200,
            height: 1_080
        ))
        #expect(topology.adjacencies.count == 1)
        #expect(topology.adjacencies[0].firstDisplayIdentifier.rawValue == "primary")
        #expect(topology.adjacencies[0].secondDisplayIdentifier.rawValue == "right")
        let mirror = try #require(
            topology.displays.first {
                $0.persistentIdentifier.rawValue == "projector"
            }
        )
        #expect(mirror.mirrorTargetIdentifier?.rawValue == "primary")
        #expect(mirror.nativePixelSize == .init(width: 1_280, height: 720))
        #expect(mirror.backingScale == 1)
    }

    @Test("mixed scale rotation refresh and safe-area metadata remains exact")
    func mixedMetadata() throws {
        let topology = try DisplayTopology(
            displays: DisplayTopologyFixtures.mixedMetadata
        )
        let rotated = try #require(
            topology.displays.first {
                $0.persistentIdentifier.rawValue == "rotated-retina"
            }
        )
        let primary = try #require(
            topology.displays.first {
                $0.persistentIdentifier.rawValue == "primary"
            }
        )

        #expect(primary.refreshRateRange == nil)
        #expect(rotated.nativePixelSize == .init(width: 2_160, height: 3_840))
        #expect(rotated.backingScale == 2)
        #expect(rotated.rotationDegrees == 90)
        #expect(rotated.refreshRateRange == .init(
            minimumHz: 48,
            maximumHz: 120,
            currentHz: 60
        ))
        #expect(rotated.safeAreaInsets == .init(
            top: 24,
            left: 0,
            bottom: 0,
            right: 0
        ))
    }

    @Test("duplicate identifiers fail deterministically")
    func duplicateIdentifiers() {
        let duplicate = DisplayTopologyFixtures.display(
            "same",
            isPrimary: true
        )

        #expect(throws: DisplayTopology.ValidationError.duplicatePersistentIdentifier(
            .init(rawValue: "same")
        )) {
            try DisplayTopology(displays: [
                duplicate,
                DisplayTopologyFixtures.display("same", x: 1_000),
            ])
        }
    }

    @Test("malformed geometry and metadata fail closed")
    func malformedGeometry() {
        let identifier = DisplayTopology.PersistentDisplayIdentifier(
            rawValue: "primary"
        )

        #expect(throws: DisplayTopology.ValidationError.invalidLogicalFrame(identifier)) {
            try DisplayTopology(displays: [
                DisplayTopologyFixtures.display(
                    "primary",
                    width: 0,
                    isPrimary: true
                ),
            ])
        }
        #expect(throws: DisplayTopology.ValidationError.invalidNativePixelSize(identifier)) {
            try DisplayTopology(displays: [
                DisplayTopologyFixtures.display(
                    "primary",
                    isPrimary: true,
                    nativePixelWidth: 0
                ),
            ])
        }
        #expect(throws: DisplayTopology.ValidationError.invalidBackingScale(identifier)) {
            try DisplayTopology(displays: [
                DisplayTopologyFixtures.display(
                    "primary",
                    isPrimary: true,
                    backingScale: .infinity
                ),
            ])
        }
        #expect(throws: DisplayTopology.ValidationError.unsupportedRotation(
            identifier,
            degrees: 45
        )) {
            try DisplayTopology(displays: [
                DisplayTopologyFixtures.display(
                    "primary",
                    isPrimary: true,
                    rotationDegrees: 45
                ),
            ])
        }
        #expect(throws: DisplayTopology.ValidationError.invalidRefreshRateRange(identifier)) {
            try DisplayTopology(displays: [
                DisplayTopologyFixtures.display(
                    "primary",
                    isPrimary: true,
                    refreshRateRange: .init(
                        minimumHz: 120,
                        maximumHz: 60,
                        currentHz: 60
                    )
                ),
            ])
        }
        #expect(throws: DisplayTopology.ValidationError.invalidSafeAreaInsets(identifier)) {
            try DisplayTopology(displays: [
                DisplayTopologyFixtures.display(
                    "primary",
                    width: 100,
                    isPrimary: true,
                    safeAreaInsets: .init(
                        top: 0,
                        left: 50,
                        bottom: 0,
                        right: 50
                    )
                ),
            ])
        }
    }

    @Test("primary display errors are explicit and canonical")
    func primaryErrors() {
        #expect(throws: DisplayTopology.ValidationError.missingPrimaryDisplay) {
            try DisplayTopology(displays: [
                DisplayTopologyFixtures.display("only"),
            ])
        }
        #expect(throws: DisplayTopology.ValidationError.multiplePrimaryDisplays([
            .init(rawValue: "alpha"),
            .init(rawValue: "zeta"),
        ])) {
            try DisplayTopology(displays: [
                DisplayTopologyFixtures.display("zeta", isPrimary: true),
                DisplayTopologyFixtures.display("alpha", x: 1_000, isPrimary: true),
            ])
        }
    }

    @Test("invalid mirror relationships fail before overlap validation")
    func mirrorErrors() {
        let primary = DisplayTopologyFixtures.display(
            "primary",
            isPrimary: true
        )

        #expect(throws: DisplayTopology.ValidationError.primaryDisplayCannotMirror(
            .init(rawValue: "primary")
        )) {
            try DisplayTopology(displays: [
                DisplayTopologyFixtures.display(
                    "primary",
                    isPrimary: true,
                    mirrorTarget: "secondary"
                ),
                DisplayTopologyFixtures.display("secondary"),
            ])
        }
        #expect(throws: DisplayTopology.ValidationError.mirrorTargetMissing(
            display: .init(rawValue: "mirror"),
            target: .init(rawValue: "missing")
        )) {
            try DisplayTopology(displays: [
                primary,
                DisplayTopologyFixtures.display(
                    "mirror",
                    mirrorTarget: "missing"
                ),
            ])
        }
        #expect(throws: DisplayTopology.ValidationError.mirrorTargetIsSelf(
            .init(rawValue: "mirror")
        )) {
            try DisplayTopology(displays: [
                primary,
                DisplayTopologyFixtures.display(
                    "mirror",
                    mirrorTarget: "mirror"
                ),
            ])
        }
        #expect(throws: DisplayTopology.ValidationError.nestedMirror(
            display: .init(rawValue: "nested"),
            target: .init(rawValue: "mirror")
        )) {
            try DisplayTopology(displays: [
                primary,
                DisplayTopologyFixtures.display(
                    "mirror",
                    mirrorTarget: "primary"
                ),
                DisplayTopologyFixtures.display(
                    "nested",
                    mirrorTarget: "mirror"
                ),
            ])
        }
        #expect(throws: DisplayTopology.ValidationError.mirrorGeometryMismatch(
            display: .init(rawValue: "mirror"),
            target: .init(rawValue: "primary")
        )) {
            try DisplayTopology(displays: [
                primary,
                DisplayTopologyFixtures.display(
                    "mirror",
                    x: 10,
                    mirrorTarget: "primary"
                ),
            ])
        }
    }

    @Test("unrelated display overlap fails with canonical identifiers")
    func overlapErrors() {
        #expect(throws: DisplayTopology.ValidationError.overlappingDisplays(
            first: .init(rawValue: "alpha"),
            second: .init(rawValue: "primary")
        )) {
            try DisplayTopology(displays: [
                DisplayTopologyFixtures.display(
                    "primary",
                    isPrimary: true
                ),
                DisplayTopologyFixtures.display(
                    "alpha",
                    x: 500
                ),
            ])
        }
    }
}

private enum DisplayTopologyFixtures {
    static let single = [
        display("primary", isPrimary: true),
    ]

    static let negativeOffset = [
        display(
            "primary",
            x: 0,
            y: 0,
            width: 1_920,
            height: 1_080,
            isPrimary: true
        ),
        display(
            "left",
            x: -1_600,
            y: -200,
            width: 1_600,
            height: 900
        ),
    ]

    static let stacked = [
        display(
            "primary",
            width: 1_920,
            height: 1_080,
            isPrimary: true
        ),
        display(
            "upper",
            x: 320,
            y: 1_080,
            width: 1_280,
            height: 1_024
        ),
    ]

    static let gapped = [
        display("primary", width: 1_000, isPrimary: true),
        display("gapped", x: 1_020, width: 1_000),
    ]

    static let cornerTouching = [
        display(
            "primary",
            width: 1_000,
            height: 1_000,
            isPrimary: true
        ),
        display(
            "corner",
            x: 1_000,
            y: 1_000,
            width: 1_000,
            height: 1_000
        ),
    ]

    static let mirrored = [
        display(
            "primary",
            width: 1_920,
            height: 1_080,
            isPrimary: true,
            nativePixelWidth: 3_840,
            nativePixelHeight: 2_160,
            backingScale: 2
        ),
        display(
            "projector",
            width: 1_920,
            height: 1_080,
            nativePixelWidth: 1_280,
            nativePixelHeight: 720,
            backingScale: 1,
            mirrorTarget: "primary"
        ),
        display(
            "right",
            x: 1_920,
            width: 1_280,
            height: 1_024
        ),
    ]

    static let mixedMetadata = [
        display(
            "primary",
            width: 1_920,
            height: 1_080,
            isPrimary: true,
            nativePixelWidth: 1_920,
            nativePixelHeight: 1_080,
            backingScale: 1,
            refreshRateRange: nil
        ),
        display(
            "rotated-retina",
            x: 1_920,
            width: 1_080,
            height: 1_920,
            nativePixelWidth: 2_160,
            nativePixelHeight: 3_840,
            backingScale: 2,
            rotationDegrees: 90,
            refreshRateRange: .init(
                minimumHz: 48,
                maximumHz: 120,
                currentHz: 60
            ),
            safeAreaInsets: .init(
                top: 24,
                left: 0,
                bottom: 0,
                right: 0
            )
        ),
    ]

    static func display(
        _ identifier: String,
        x: Double = 0,
        y: Double = 0,
        width: Double = 1_000,
        height: Double = 800,
        isPrimary: Bool = false,
        nativePixelWidth: Int = 1_000,
        nativePixelHeight: Int = 800,
        backingScale: Double = 1,
        rotationDegrees: Int = 0,
        refreshRateRange: DisplayTopology.RefreshRateRange? = .init(
            minimumHz: 60,
            maximumHz: 60,
            currentHz: 60
        ),
        safeAreaInsets: DisplayTopology.SafeAreaInsets = .zero,
        mirrorTarget: String? = nil
    ) -> DisplayTopology.Display {
        .init(
            persistentIdentifier: .init(rawValue: identifier),
            logicalFrame: .init(x: x, y: y, width: width, height: height),
            nativePixelSize: .init(
                width: nativePixelWidth,
                height: nativePixelHeight
            ),
            backingScale: backingScale,
            rotationDegrees: rotationDegrees,
            refreshRateRange: refreshRateRange,
            safeAreaInsets: safeAreaInsets,
            isPrimary: isPrimary,
            mirrorTargetIdentifier: mirrorTarget.map {
                .init(rawValue: $0)
            }
        )
    }
}
