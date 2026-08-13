import CryptoKit
import Foundation
import Security

public struct CameraAgentIdentityCollectorConfiguration: Equatable, Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidTeamIdentifier(String)
    }

    public let containingApplicationURL: URL
    public let serviceIdentity: CameraAgentServiceIdentity
    public let expectedHelperBundleIdentifier: String
    public let expectedTeamIdentifier: String

    public init(
        containingApplicationURL: URL,
        serviceIdentity: CameraAgentServiceIdentity,
        expectedTeamIdentifier: String
    ) throws {
        guard expectedTeamIdentifier.utf8.count == 10,
              expectedTeamIdentifier.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (65 ... 90).contains($0)
              }) else {
            throw Error.invalidTeamIdentifier(expectedTeamIdentifier)
        }

        self.containingApplicationURL = containingApplicationURL
        self.serviceIdentity = serviceIdentity
        expectedHelperBundleIdentifier = serviceIdentity.appGroupIdentifier
            == "group.com.idlescreen.shared"
            ? "com.idlescreen.camera-agent"
            : "com.idlescreen.camera-agent.dev"
        self.expectedTeamIdentifier = expectedTeamIdentifier
    }
}

public struct CameraAgentEmbeddedArtifactRequest: Equatable, Sendable {
    public let containingApplicationURL: URL
    public let helperBundleURL: URL
    public let launchAgentURL: URL
    public let serviceIdentity: CameraAgentServiceIdentity

    public init(
        containingApplicationURL: URL,
        helperBundleURL: URL,
        launchAgentURL: URL,
        serviceIdentity: CameraAgentServiceIdentity
    ) {
        self.containingApplicationURL = containingApplicationURL
        self.helperBundleURL = helperBundleURL
        self.launchAgentURL = launchAgentURL
        self.serviceIdentity = serviceIdentity
    }

    public static func == (
        lhs: CameraAgentEmbeddedArtifactRequest,
        rhs: CameraAgentEmbeddedArtifactRequest
    ) -> Bool {
        equivalentFileURL(
            lhs.containingApplicationURL,
            rhs.containingApplicationURL
        ) && equivalentFileURL(lhs.helperBundleURL, rhs.helperBundleURL)
            && equivalentFileURL(lhs.launchAgentURL, rhs.launchAgentURL)
            && lhs.serviceIdentity == rhs.serviceIdentity
    }

    private static func equivalentFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.isFileURL, rhs.isFileURL else { return lhs == rhs }
        return lhs.path == rhs.path
    }
}

public enum CameraAgentArtifactProviderError: Swift.Error, Equatable, Sendable {
    case helperBundleMissing(String)
    case launchAgentMissing(String)
    case provisioningProfileMissing(String)
    case malformedBundle(String)
    case executableMissing(String)
    case invalidLaunchAgent(String)
    case containedArtifactEscapesBundle(String)
    case unreadableArtifact(String)
    case staticCodeUnavailable(OSStatus)
    case invalidStaticCode(OSStatus)
    case signingInformationUnavailable(OSStatus)
    case missingSigningIdentifier
    case missingTeamIdentifier
    case missingCodeDirectoryHash
    case invalidFingerprint(CameraAgentArtifactFingerprint.ValidationError)
}

public protocol CameraAgentEmbeddedArtifactProviding: AnyObject, Sendable {
    func fingerprint(
        for request: CameraAgentEmbeddedArtifactRequest
    ) throws -> CameraAgentArtifactFingerprint
}

public enum CameraAgentRegisteredArtifactEvidence: Equatable, Sendable {
    case absent
    case unavailable
    case observed(bundleURL: URL, fingerprint: CameraAgentArtifactFingerprint)
}

public protocol CameraAgentRegisteredArtifactProviding: Sendable {
    func registeredArtifact(
        for serviceIdentity: CameraAgentServiceIdentity
    ) -> CameraAgentRegisteredArtifactEvidence
}

/// ServiceManagement exposes status but no supported registered executable URL.
/// Production therefore reports this observation as unavailable rather than
/// scraping launchctl output and accidentally treating an unstable detail as API.
public struct CameraAgentRegisteredArtifactUnavailableProvider:
    CameraAgentRegisteredArtifactProviding
{
    public init() {}

    public func registeredArtifact(
        for serviceIdentity: CameraAgentServiceIdentity
    ) -> CameraAgentRegisteredArtifactEvidence {
        _ = serviceIdentity
        return .unavailable
    }
}

public protocol CameraAgentPathCanonicalizing: Sendable {
    func canonicalFileURL(_ url: URL) -> URL
}

public struct FoundationCameraAgentPathCanonicalizer:
    CameraAgentPathCanonicalizing
{
    public init() {}

    public func canonicalFileURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

public struct CameraAgentAuthenticatedLiveIdentityEvidence: Equatable, Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidProcessIdentifier
        case processMismatch(authenticated: Int32, reported: Int32)
        case invalidProcessEpoch
        case invalidBundleURL
    }

    public let processIdentifier: Int32
    public let processEpoch: UInt64
    public let bundleURL: URL
    public let fingerprint: CameraAgentArtifactFingerprint

    public init(
        processIdentifier: Int32,
        authenticatedControlProcessIdentifier: Int32,
        processEpoch: UInt64,
        bundleURL: URL,
        fingerprint: CameraAgentArtifactFingerprint
    ) throws {
        guard processIdentifier > 0 else { throw Error.invalidProcessIdentifier }
        guard authenticatedControlProcessIdentifier > 0 else {
            throw Error.invalidProcessIdentifier
        }
        guard processIdentifier == authenticatedControlProcessIdentifier else {
            throw Error.processMismatch(
                authenticated: authenticatedControlProcessIdentifier,
                reported: processIdentifier
            )
        }
        guard processEpoch > 0 else { throw Error.invalidProcessEpoch }
        guard bundleURL.isFileURL else { throw Error.invalidBundleURL }
        self.processIdentifier = processIdentifier
        self.processEpoch = processEpoch
        self.bundleURL = bundleURL
        self.fingerprint = fingerprint
    }
}

public enum CameraAgentIdentityValidationFailure: Equatable, Sendable {
    case pathEscapesContainingApplication(path: String, applicationPath: String)
    case fingerprintPathMismatch(evidencePath: String, fingerprintPath: String)
    case embeddedServiceIdentifier(expected: String, actual: String)
    case embeddedBundleIdentifier(expected: String, actual: String)
    case embeddedSigningIdentifier(expected: String, actual: String)
    case embeddedTeamIdentifier(expected: String, actual: String)
    case activeSourceFingerprintMismatch
    case artifactProvider(CameraAgentArtifactProviderError)
}

public enum CameraAgentIdentityObservation: Equatable, Sendable {
    case absent
    case unavailable
    case invalid(CameraAgentIdentityValidationFailure)
    case observed(CameraAgentArtifactFingerprint)

    fileprivate var fingerprint: CameraAgentArtifactFingerprint? {
        guard case let .observed(fingerprint) = self else { return nil }
        return fingerprint
    }
}

public struct CameraAgentIdentityCollection: Equatable, Sendable {
    public let embedded: CameraAgentIdentityObservation
    public let registered: CameraAgentIdentityObservation
    public let running: CameraAgentIdentityObservation
    public let processIdentifier: Int32?
    public let processEpoch: UInt64?
    public let assessment: CameraAgentReplacementAssessment?

    public var isCurrent: Bool {
        guard let embeddedFingerprint = embedded.fingerprint,
              let runningFingerprint = running.fingerprint,
              embeddedFingerprint == runningFingerprint,
              let processIdentifier,
              processIdentifier > 0,
              let processEpoch,
              processEpoch > 0,
              let assessment else {
            return false
        }

        if assessment.classification == .current {
            return registered.fingerprint == embeddedFingerprint
        }

        // ServiceManagement exposes whether the agent is enabled, but has no
        // supported API for reading the registered executable URL. Accept that
        // one unavailable observation only after the authenticated live XPC
        // process has been fingerprinted from its active bundle and matches the
        // exact helper embedded in this app. Every other gap or mismatch stays
        // fail closed.
        return registered == .unavailable
            && assessment.classification == .observationIncomplete
            && assessment.mismatches.isEmpty
            && assessment.observationGaps == [.registeredArtifact]
    }
}

public enum CameraAgentIdentityHealthClassification: Equatable, Sendable {
    case unknown
    case absent
    case stale
    case mismatched
    case current
}

public struct CameraAgentIdentityHealthAssessment: Equatable, Sendable {
    public let classification: CameraAgentIdentityHealthClassification
    public let generationIdentifier: String?

    public init(
        classification: CameraAgentIdentityHealthClassification,
        generationIdentifier: String?
    ) {
        self.classification = classification
        self.generationIdentifier = generationIdentifier
    }
}

public enum CameraAgentIdentityHealthMapper {
    public static func map(
        _ collection: CameraAgentIdentityCollection
    ) -> CameraAgentIdentityHealthAssessment {
        let classification: CameraAgentIdentityHealthClassification
        let observations = [
            collection.embedded,
            collection.registered,
            collection.running,
        ]

        if observations.contains(where: { observation in
            if case .invalid = observation { return true }
            return false
        }) {
            classification = .mismatched
        } else if observations.contains(.absent) {
            classification = .absent
        } else if collection.isCurrent {
            classification = .current
        } else if collection.assessment?.classification == .replacementRequired {
            let differences = collection.assessment?.mismatches
                .flatMap(\.differences) ?? []
            classification = differences.contains(where: mismatchDifference)
                ? .mismatched
                : .stale
        } else {
            classification = .unknown
        }

        return CameraAgentIdentityHealthAssessment(
            classification: classification,
            generationIdentifier: generationIdentifier(for: collection)
        )
    }

    private static func mismatchDifference(
        _ difference: CameraAgentArtifactDifference
    ) -> Bool {
        switch difference {
        case .serviceIdentifier, .bundleIdentifier, .signingIdentifier,
             .teamIdentifier, .codeDirectoryHash, .provisioningProfileSHA256:
            true
        case .bundlePath, .bundleVersion, .marketingVersion,
             .executableSHA256, .launchAgentSHA256:
            false
        }
    }

    private static func generationIdentifier(
        for collection: CameraAgentIdentityCollection
    ) -> String? {
        guard let processIdentifier = collection.processIdentifier,
              let processEpoch = collection.processEpoch,
              let running = collection.running.fingerprint else {
            return nil
        }
        return [
            "pid=\(processIdentifier)",
            "epoch=\(processEpoch)",
            "path=\(running.canonicalBundlePath)",
            "service=\(running.serviceIdentifier)",
            "bundle=\(running.bundleIdentifier)",
            "bundle-version=\(running.bundleVersion)",
            "marketing-version=\(running.marketingVersion)",
            "signing=\(running.signingIdentifier)",
            "team=\(running.teamIdentifier)",
            "cdhash=\(running.codeDirectoryHash.lowercased())",
            "executable=\(running.executableSHA256.lowercased())",
            "launch-agent=\(running.launchAgentSHA256.lowercased())",
            "profile=\(running.provisioningProfileSHA256.lowercased())",
        ].joined(separator: ";")
    }
}

public struct CameraAgentIdentityCollector: Sendable {
    private let configuration: CameraAgentIdentityCollectorConfiguration
    private let embeddedArtifactProvider: any CameraAgentEmbeddedArtifactProviding
    private let registeredArtifactProvider: any CameraAgentRegisteredArtifactProviding
    private let canonicalizer: any CameraAgentPathCanonicalizing

    public init(
        configuration: CameraAgentIdentityCollectorConfiguration,
        embeddedArtifactProvider: any CameraAgentEmbeddedArtifactProviding =
            SecurityCameraAgentEmbeddedArtifactProvider(),
        registeredArtifactProvider: any CameraAgentRegisteredArtifactProviding =
            CameraAgentRegisteredArtifactUnavailableProvider(),
        canonicalizer: any CameraAgentPathCanonicalizing =
            FoundationCameraAgentPathCanonicalizer()
    ) {
        self.configuration = configuration
        self.embeddedArtifactProvider = embeddedArtifactProvider
        self.registeredArtifactProvider = registeredArtifactProvider
        self.canonicalizer = canonicalizer
    }

    public func collect(
        registrationState: CameraAgentRegistrationState,
        liveEvidence: CameraAgentAuthenticatedLiveIdentityEvidence?
    ) -> CameraAgentIdentityCollection {
        let applicationURL = canonicalizer.canonicalFileURL(
            configuration.containingApplicationURL
        )
        let helperURL = canonicalizer.canonicalFileURL(
            configuration.containingApplicationURL.appendingPathComponent(
                "Contents/Helpers/IdleScreenCameraAgent.app",
                isDirectory: true
            )
        )
        let launchAgentURL = canonicalizer.canonicalFileURL(
            configuration.containingApplicationURL.appendingPathComponent(
                "Contents/Library/LaunchAgents/\(configuration.serviceIdentity.plistName)"
            )
        )

        let embedded: CameraAgentIdentityObservation
        if !Self.contains(helperURL, within: applicationURL) {
            embedded = .invalid(.pathEscapesContainingApplication(
                path: helperURL.path,
                applicationPath: applicationURL.path
            ))
        } else if !Self.contains(launchAgentURL, within: applicationURL) {
            embedded = .invalid(.pathEscapesContainingApplication(
                path: launchAgentURL.path,
                applicationPath: applicationURL.path
            ))
        } else {
            let request = CameraAgentEmbeddedArtifactRequest(
                containingApplicationURL: applicationURL,
                helperBundleURL: helperURL,
                launchAgentURL: launchAgentURL,
                serviceIdentity: configuration.serviceIdentity
            )
            do {
                let fingerprint = try embeddedArtifactProvider.fingerprint(for: request)
                embedded = validateEmbedded(fingerprint, expectedPath: helperURL.path)
            } catch let error as CameraAgentArtifactProviderError {
                if case .helperBundleMissing = error {
                    embedded = .absent
                } else {
                    embedded = .invalid(.artifactProvider(error))
                }
            } catch {
                embedded = .invalid(.artifactProvider(
                    .unreadableArtifact(helperURL.path)
                ))
            }
        }

        let running = runningObservation(liveEvidence)
        let registered = registeredObservation(
            registrationState: registrationState
        )
        let assessment = embedded.fingerprint.map { fingerprint in
            CameraAgentReplacementAssessor.assess(
                registrationState: registrationState,
                embedded: fingerprint,
                registered: registered.fingerprint,
                running: running.fingerprint
            )
        }

        return CameraAgentIdentityCollection(
            embedded: embedded,
            registered: registered,
            running: running,
            processIdentifier: liveEvidence?.processIdentifier,
            processEpoch: liveEvidence?.processEpoch,
            assessment: assessment
        )
    }

    private func validateEmbedded(
        _ fingerprint: CameraAgentArtifactFingerprint,
        expectedPath: String
    ) -> CameraAgentIdentityObservation {
        if fingerprint.canonicalBundlePath != expectedPath {
            return .invalid(.fingerprintPathMismatch(
                evidencePath: expectedPath,
                fingerprintPath: fingerprint.canonicalBundlePath
            ))
        }
        if fingerprint.serviceIdentifier != configuration.serviceIdentity.serviceIdentifier {
            return .invalid(.embeddedServiceIdentifier(
                expected: configuration.serviceIdentity.serviceIdentifier,
                actual: fingerprint.serviceIdentifier
            ))
        }
        if fingerprint.bundleIdentifier != configuration.expectedHelperBundleIdentifier {
            return .invalid(.embeddedBundleIdentifier(
                expected: configuration.expectedHelperBundleIdentifier,
                actual: fingerprint.bundleIdentifier
            ))
        }
        if fingerprint.signingIdentifier != configuration.expectedHelperBundleIdentifier {
            return .invalid(.embeddedSigningIdentifier(
                expected: configuration.expectedHelperBundleIdentifier,
                actual: fingerprint.signingIdentifier
            ))
        }
        if fingerprint.teamIdentifier != configuration.expectedTeamIdentifier {
            return .invalid(.embeddedTeamIdentifier(
                expected: configuration.expectedTeamIdentifier,
                actual: fingerprint.teamIdentifier
            ))
        }
        return .observed(fingerprint)
    }

    private func registeredObservation(
        registrationState: CameraAgentRegistrationState
    ) -> CameraAgentIdentityObservation {
        switch registrationState {
        case .notRegistered, .notFound:
            return .absent
        case .requiresApproval:
            return .unavailable
        case .enabled:
            let evidence = registeredArtifactProvider.registeredArtifact(
                for: configuration.serviceIdentity
            )
            switch evidence {
            case .absent:
                return .absent
            case .unavailable:
                return .unavailable
            case let .observed(bundleURL, fingerprint):
                return pathBoundObservation(bundleURL: bundleURL, fingerprint: fingerprint)
            }
        }
    }

    private func activeSourceObservation(
        for liveEvidence: CameraAgentAuthenticatedLiveIdentityEvidence
    ) -> CameraAgentIdentityObservation {
        let helperURL = canonicalizer.canonicalFileURL(liveEvidence.bundleURL)
        let components = helperURL.pathComponents
        let suffix = ["Contents", "Helpers", "IdleScreenCameraAgent.app"]
        guard components.count > suffix.count,
              Array(components.suffix(suffix.count)) == suffix else {
            return .unavailable
        }

        var sourceApplicationURL = helperURL
        for _ in suffix {
            sourceApplicationURL.deleteLastPathComponent()
        }
        let applicationURL = canonicalizer.canonicalFileURL(sourceApplicationURL)
        let launchAgentURL = canonicalizer.canonicalFileURL(
            applicationURL.appendingPathComponent(
                "Contents/Library/LaunchAgents/\(configuration.serviceIdentity.plistName)"
            )
        )
        guard Self.contains(helperURL, within: applicationURL),
              Self.contains(launchAgentURL, within: applicationURL) else {
            return .unavailable
        }

        let request = CameraAgentEmbeddedArtifactRequest(
            containingApplicationURL: applicationURL,
            helperBundleURL: helperURL,
            launchAgentURL: launchAgentURL,
            serviceIdentity: configuration.serviceIdentity
        )
        do {
            let fingerprint = try embeddedArtifactProvider.fingerprint(for: request)
            return pathBoundObservation(bundleURL: helperURL, fingerprint: fingerprint)
        } catch let error as CameraAgentArtifactProviderError {
            if case .helperBundleMissing = error {
                return .absent
            }
            return .invalid(.artifactProvider(error))
        } catch {
            return .invalid(.artifactProvider(.unreadableArtifact(helperURL.path)))
        }
    }

    private func runningObservation(
        _ liveEvidence: CameraAgentAuthenticatedLiveIdentityEvidence?
    ) -> CameraAgentIdentityObservation {
        guard let liveEvidence else { return .unavailable }
        let reported = pathBoundObservation(
            bundleURL: liveEvidence.bundleURL,
            fingerprint: liveEvidence.fingerprint
        )
        guard case let .observed(reportedFingerprint) = reported else {
            return reported
        }

        let activeSource = activeSourceObservation(for: liveEvidence)
        guard case let .observed(activeSourceFingerprint) = activeSource else {
            return activeSource
        }
        guard reportedFingerprint == activeSourceFingerprint else {
            return .invalid(.activeSourceFingerprintMismatch)
        }
        return reported
    }

    private func pathBoundObservation(
        bundleURL: URL,
        fingerprint: CameraAgentArtifactFingerprint
    ) -> CameraAgentIdentityObservation {
        let canonicalURL = canonicalizer.canonicalFileURL(bundleURL)
        guard canonicalURL.path == fingerprint.canonicalBundlePath else {
            return .invalid(.fingerprintPathMismatch(
                evidencePath: canonicalURL.path,
                fingerprintPath: fingerprint.canonicalBundlePath
            ))
        }
        return .observed(fingerprint)
    }

    fileprivate static func contains(_ child: URL, within parent: URL) -> Bool {
        let parentComponents = parent.pathComponents
        let childComponents = child.pathComponents
        return childComponents.count > parentComponents.count
            && childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    }
}

/// Read-only Foundation/Security implementation for the helper embedded in the
/// companion. It hashes bytes directly and invokes Security.framework APIs; it
/// never launches a process, registers a service, or shells out.
public final class SecurityCameraAgentEmbeddedArtifactProvider:
    CameraAgentEmbeddedArtifactProviding,
    @unchecked Sendable
{
    public init() {}

    public func fingerprint(
        for request: CameraAgentEmbeddedArtifactRequest
    ) throws -> CameraAgentArtifactFingerprint {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: request.helperBundleURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw CameraAgentArtifactProviderError.helperBundleMissing(
                request.helperBundleURL.path
            )
        }
        guard FileManager.default.fileExists(atPath: request.launchAgentURL.path) else {
            throw CameraAgentArtifactProviderError.launchAgentMissing(
                request.launchAgentURL.path
            )
        }
        guard let bundle = Bundle(url: request.helperBundleURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              let bundleVersion = bundle.object(
                  forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              let marketingVersion = bundle.object(
                  forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String else {
            throw CameraAgentArtifactProviderError.malformedBundle(
                request.helperBundleURL.path
            )
        }
        guard let executableURL = bundle.executableURL else {
            throw CameraAgentArtifactProviderError.executableMissing(
                request.helperBundleURL.path
            )
        }

        let helperURL = request.helperBundleURL.resolvingSymlinksInPath()
            .standardizedFileURL
        let canonicalExecutableURL = executableURL.resolvingSymlinksInPath()
            .standardizedFileURL
        guard CameraAgentIdentityCollector.contains(
            canonicalExecutableURL,
            within: helperURL
        ) else {
            throw CameraAgentArtifactProviderError.containedArtifactEscapesBundle(
                canonicalExecutableURL.path
            )
        }

        let profileURL = helperURL.appendingPathComponent(
            "Contents/embedded.provisionprofile"
        ).resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            throw CameraAgentArtifactProviderError.provisioningProfileMissing(
                profileURL.path
            )
        }
        guard CameraAgentIdentityCollector.contains(profileURL, within: helperURL) else {
            throw CameraAgentArtifactProviderError.containedArtifactEscapesBundle(
                profileURL.path
            )
        }

        let launchData = try data(at: request.launchAgentURL)
        guard let plist = try? PropertyListSerialization.propertyList(
            from: launchData,
            options: [],
            format: nil
        ) as? [String: Any],
              let serviceIdentifier = plist["Label"] as? String,
              serviceIdentifier == request.serviceIdentity.serviceIdentifier,
              plist["BundleProgram"] as? String
                == "Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent" else {
            throw CameraAgentArtifactProviderError.invalidLaunchAgent(
                request.launchAgentURL.path
            )
        }

        let signing = try signingIdentity(at: helperURL)
        do {
            return try CameraAgentArtifactFingerprint(
                canonicalBundlePath: helperURL.path,
                serviceIdentifier: serviceIdentifier,
                bundleIdentifier: bundleIdentifier,
                bundleVersion: bundleVersion,
                marketingVersion: marketingVersion,
                signingIdentifier: signing.identifier,
                teamIdentifier: signing.teamIdentifier,
                codeDirectoryHash: signing.codeDirectoryHash,
                executableSHA256: Self.sha256(try data(at: canonicalExecutableURL)),
                launchAgentSHA256: Self.sha256(launchData),
                provisioningProfileSHA256: Self.sha256(try data(at: profileURL))
            )
        } catch let error as CameraAgentArtifactFingerprint.ValidationError {
            throw CameraAgentArtifactProviderError.invalidFingerprint(error)
        }
    }

    private func data(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw CameraAgentArtifactProviderError.unreadableArtifact(url.path)
        }
    }

    private func signingIdentity(
        at bundleURL: URL
    ) throws -> (identifier: String, teamIdentifier: String, codeDirectoryHash: String) {
        var staticCode: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard creationStatus == errSecSuccess, let staticCode else {
            throw CameraAgentArtifactProviderError.staticCodeUnavailable(creationStatus)
        }
        let validityStatus = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil)
        guard validityStatus == errSecSuccess else {
            throw CameraAgentArtifactProviderError.invalidStaticCode(validityStatus)
        }

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard informationStatus == errSecSuccess,
              let values = information as? [CFString: Any] else {
            throw CameraAgentArtifactProviderError.signingInformationUnavailable(
                informationStatus
            )
        }
        guard let identifier = values[kSecCodeInfoIdentifier] as? String else {
            throw CameraAgentArtifactProviderError.missingSigningIdentifier
        }
        guard let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String else {
            throw CameraAgentArtifactProviderError.missingTeamIdentifier
        }
        guard let codeDirectoryHash = values[kSecCodeInfoUnique] as? Data else {
            throw CameraAgentArtifactProviderError.missingCodeDirectoryHash
        }
        return (identifier, teamIdentifier, Self.hex(codeDirectoryHash))
    }

    private static func sha256(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
