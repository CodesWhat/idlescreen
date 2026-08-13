import Foundation
import ServiceManagement

public struct CameraAgentServiceIdentity: Equatable, Sendable {
    public enum Error: LocalizedError, Equatable {
        case unsupportedAppGroupIdentifier(String)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedAppGroupIdentifier(identifier):
                return "Unsupported idle screen app-group identifier: \(identifier)"
            }
        }
    }

    public let appGroupIdentifier: String
    public let serviceIdentifier: String
    public let plistName: String

    public init(appGroupIdentifier: String) throws {
        switch appGroupIdentifier {
        case "group.com.idlescreen.shared", "group.com.idlescreen.dev.shared":
            break
        default:
            throw Error.unsupportedAppGroupIdentifier(appGroupIdentifier)
        }

        let serviceIdentifier = appGroupIdentifier + ".camera-agent"
        self.appGroupIdentifier = appGroupIdentifier
        self.serviceIdentifier = serviceIdentifier
        plistName = serviceIdentifier + ".plist"
    }
}

public enum CameraAgentRegistrationState: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    public init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered:
            self = .notRegistered
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        @unknown default:
            self = .notFound
        }
    }
}

public struct CameraAgentArtifactFingerprint: Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidCanonicalBundlePath
        case invalidServiceIdentifier
        case invalidBundleIdentifier
        case invalidBundleVersion
        case invalidMarketingVersion
        case invalidSigningIdentifier
        case invalidTeamIdentifier
        case invalidCodeDirectoryHash
        case invalidExecutableSHA256
        case invalidLaunchAgentSHA256
        case invalidProvisioningProfileSHA256
    }

    public let canonicalBundlePath: String
    public let serviceIdentifier: String
    public let bundleIdentifier: String
    public let bundleVersion: String
    public let marketingVersion: String
    public let signingIdentifier: String
    public let teamIdentifier: String
    public let codeDirectoryHash: String
    public let executableSHA256: String
    public let launchAgentSHA256: String
    public let provisioningProfileSHA256: String

    public init(
        canonicalBundlePath: String,
        serviceIdentifier: String,
        bundleIdentifier: String,
        bundleVersion: String,
        marketingVersion: String,
        signingIdentifier: String,
        teamIdentifier: String,
        codeDirectoryHash: String,
        executableSHA256: String,
        launchAgentSHA256: String,
        provisioningProfileSHA256: String
    ) throws {
        guard Self.isCanonicalAbsolutePath(canonicalBundlePath) else {
            throw ValidationError.invalidCanonicalBundlePath
        }
        guard Self.isIdentifier(serviceIdentifier) else {
            throw ValidationError.invalidServiceIdentifier
        }
        guard Self.isIdentifier(bundleIdentifier) else {
            throw ValidationError.invalidBundleIdentifier
        }
        guard Self.isVersion(bundleVersion) else {
            throw ValidationError.invalidBundleVersion
        }
        guard Self.isVersion(marketingVersion) else {
            throw ValidationError.invalidMarketingVersion
        }
        guard Self.isIdentifier(signingIdentifier) else {
            throw ValidationError.invalidSigningIdentifier
        }
        guard Self.isTeamIdentifier(teamIdentifier) else {
            throw ValidationError.invalidTeamIdentifier
        }
        guard Self.isHexadecimal(codeDirectoryHash, length: 40) else {
            throw ValidationError.invalidCodeDirectoryHash
        }
        guard Self.isHexadecimal(executableSHA256, length: 64) else {
            throw ValidationError.invalidExecutableSHA256
        }
        guard Self.isHexadecimal(launchAgentSHA256, length: 64) else {
            throw ValidationError.invalidLaunchAgentSHA256
        }
        guard Self.isHexadecimal(provisioningProfileSHA256, length: 64) else {
            throw ValidationError.invalidProvisioningProfileSHA256
        }

        self.canonicalBundlePath = canonicalBundlePath
        self.serviceIdentifier = serviceIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.bundleVersion = bundleVersion
        self.marketingVersion = marketingVersion
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.codeDirectoryHash = codeDirectoryHash
        self.executableSHA256 = executableSHA256
        self.launchAgentSHA256 = launchAgentSHA256
        self.provisioningProfileSHA256 = provisioningProfileSHA256
    }

    private static func isCanonicalAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), !value.isEmpty else { return false }
        let url = URL(fileURLWithPath: value).standardizedFileURL
        return url.path == value && !url.pathComponents.contains("..")
    }

    private static func isIdentifier(_ value: String) -> Bool {
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }

        return segments.allSatisfy { segment in
            guard let first = segment.utf8.first,
                  let last = segment.utf8.last,
                  first != CharacterCode.hyphen,
                  last != CharacterCode.hyphen else {
                return false
            }
            return segment.utf8.allSatisfy { byte in
                isASCIILetter(byte) || isASCIIDigit(byte) || byte == CharacterCode.hyphen
            }
        }
    }

    private static func isVersion(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { byte in
            byte >= CharacterCode.exclamationMark && byte <= CharacterCode.tilde
        }
    }

    private static func isTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { byte in
            isASCIIUppercaseLetter(byte) || isASCIIDigit(byte)
        }
    }

    private static func isHexadecimal(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { byte in
            isASCIIDigit(byte)
                || (CharacterCode.uppercaseA ... CharacterCode.uppercaseF).contains(byte)
                || (CharacterCode.lowercaseA ... CharacterCode.lowercaseF).contains(byte)
        }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        isASCIIUppercaseLetter(byte)
            || (CharacterCode.lowercaseA ... CharacterCode.lowercaseZ).contains(byte)
    }

    private static func isASCIIUppercaseLetter(_ byte: UInt8) -> Bool {
        (CharacterCode.uppercaseA ... CharacterCode.uppercaseZ).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (CharacterCode.zero ... CharacterCode.nine).contains(byte)
    }

    private enum CharacterCode {
        static let exclamationMark = UInt8(ascii: "!")
        static let hyphen = UInt8(ascii: "-")
        static let zero = UInt8(ascii: "0")
        static let nine = UInt8(ascii: "9")
        static let uppercaseA = UInt8(ascii: "A")
        static let uppercaseF = UInt8(ascii: "F")
        static let uppercaseZ = UInt8(ascii: "Z")
        static let lowercaseA = UInt8(ascii: "a")
        static let lowercaseF = UInt8(ascii: "f")
        static let lowercaseZ = UInt8(ascii: "z")
        static let tilde = UInt8(ascii: "~")
    }
}

public enum CameraAgentArtifactDifference: Equatable, Sendable {
    case bundlePath
    case serviceIdentifier
    case bundleIdentifier
    case bundleVersion
    case marketingVersion
    case signingIdentifier
    case teamIdentifier
    case codeDirectoryHash
    case executableSHA256
    case launchAgentSHA256
    case provisioningProfileSHA256
}

public enum CameraAgentArtifactLocation: Equatable, Sendable {
    case registeredArtifact
    case runningProcess
}

public struct CameraAgentArtifactMismatch: Equatable, Sendable {
    public let location: CameraAgentArtifactLocation
    public let differences: [CameraAgentArtifactDifference]

    public init(
        location: CameraAgentArtifactLocation,
        differences: [CameraAgentArtifactDifference]
    ) {
        self.location = location
        self.differences = differences
    }
}

public enum CameraAgentArtifactObservationGap: Equatable, Sendable {
    case registeredArtifact
    case runningProcess
}

public enum CameraAgentRepairClassification: Equatable, Sendable {
    case current
    case registrationRequired
    case approvalRequired
    case serviceDefinitionMissing
    case replacementRequired
    case observationIncomplete
}

public struct CameraAgentReplacementAssessment: Equatable, Sendable {
    public let registrationState: CameraAgentRegistrationState
    public let classification: CameraAgentRepairClassification
    public let mismatches: [CameraAgentArtifactMismatch]
    public let observationGaps: [CameraAgentArtifactObservationGap]

    fileprivate init(
        registrationState: CameraAgentRegistrationState,
        classification: CameraAgentRepairClassification,
        mismatches: [CameraAgentArtifactMismatch],
        observationGaps: [CameraAgentArtifactObservationGap]
    ) {
        self.registrationState = registrationState
        self.classification = classification
        self.mismatches = mismatches
        self.observationGaps = observationGaps
    }
}

enum CameraAgentReplacementAssessor {
    static func assess(
        registrationState: CameraAgentRegistrationState,
        embedded: CameraAgentArtifactFingerprint,
        registered: CameraAgentArtifactFingerprint?,
        running: CameraAgentArtifactFingerprint?
    ) -> CameraAgentReplacementAssessment {
        var mismatches: [CameraAgentArtifactMismatch] = []
        var observationGaps: [CameraAgentArtifactObservationGap] = []

        if let registered {
            let differences = differences(
                expected: embedded,
                observed: registered,
                includeLaunchAgent: true
            )
            if !differences.isEmpty {
                mismatches.append(CameraAgentArtifactMismatch(
                    location: .registeredArtifact,
                    differences: differences
                ))
            }
        } else {
            observationGaps.append(.registeredArtifact)
        }

        if let running {
            let differences = differences(
                expected: embedded,
                observed: running,
                includeLaunchAgent: false
            )
            if !differences.isEmpty {
                mismatches.append(CameraAgentArtifactMismatch(
                    location: .runningProcess,
                    differences: differences
                ))
            }
        } else {
            observationGaps.append(.runningProcess)
        }

        let classification: CameraAgentRepairClassification
        switch registrationState {
        case .notRegistered:
            classification = .registrationRequired
        case .requiresApproval:
            classification = .approvalRequired
        case .notFound:
            classification = .serviceDefinitionMissing
        case .enabled:
            if !mismatches.isEmpty {
                classification = .replacementRequired
            } else if !observationGaps.isEmpty {
                classification = .observationIncomplete
            } else {
                classification = .current
            }
        }

        return CameraAgentReplacementAssessment(
            registrationState: registrationState,
            classification: classification,
            mismatches: mismatches,
            observationGaps: observationGaps
        )
    }

    private static func differences(
        expected: CameraAgentArtifactFingerprint,
        observed: CameraAgentArtifactFingerprint,
        includeLaunchAgent: Bool
    ) -> [CameraAgentArtifactDifference] {
        var differences: [CameraAgentArtifactDifference] = []
        if expected.canonicalBundlePath != observed.canonicalBundlePath {
            differences.append(.bundlePath)
        }
        if expected.serviceIdentifier != observed.serviceIdentifier {
            differences.append(.serviceIdentifier)
        }
        if expected.bundleIdentifier != observed.bundleIdentifier {
            differences.append(.bundleIdentifier)
        }
        if expected.bundleVersion != observed.bundleVersion {
            differences.append(.bundleVersion)
        }
        if expected.marketingVersion != observed.marketingVersion {
            differences.append(.marketingVersion)
        }
        if expected.signingIdentifier != observed.signingIdentifier {
            differences.append(.signingIdentifier)
        }
        if expected.teamIdentifier != observed.teamIdentifier {
            differences.append(.teamIdentifier)
        }
        if !hexadecimalValuesMatch(expected.codeDirectoryHash, observed.codeDirectoryHash) {
            differences.append(.codeDirectoryHash)
        }
        if !hexadecimalValuesMatch(expected.executableSHA256, observed.executableSHA256) {
            differences.append(.executableSHA256)
        }
        if includeLaunchAgent,
           !hexadecimalValuesMatch(expected.launchAgentSHA256, observed.launchAgentSHA256) {
            differences.append(.launchAgentSHA256)
        }
        if !hexadecimalValuesMatch(
            expected.provisioningProfileSHA256,
            observed.provisioningProfileSHA256
        ) {
            differences.append(.provisioningProfileSHA256)
        }
        return differences
    }

    private static func hexadecimalValuesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }
}

public protocol CameraAgentServicing: AnyObject {
    var status: SMAppService.Status { get }

    func register() throws
    func unregister() throws
    func unregisterForReplacement(
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    )
}

public extension CameraAgentServicing {
    func unregisterForReplacement(
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        do {
            try unregister()
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

public protocol CameraAgentServiceCreating: AnyObject {
    func makeAgent(plistName: String) -> any CameraAgentServicing
}

public final class SystemCameraAgentServiceFactory: CameraAgentServiceCreating {
    public init() {}

    public func makeAgent(plistName: String) -> any CameraAgentServicing {
        SMAppService.agent(plistName: plistName)
    }
}

extension SMAppService: CameraAgentServicing {
    public func unregisterForReplacement(
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        unregister(completionHandler: completionHandler)
    }
}

public enum CameraAgentRegistrationOperation: Equatable, Sendable {
    case register
    case unregister
    case replace
}

public struct CameraAgentRegistrationDiagnostic: Error, CustomStringConvertible {
    public let domain: String
    public let code: Int
    public let localizedDescription: String
    public let underlyingError: any Error

    public var description: String {
        "\(domain) (\(code)): \(localizedDescription)"
    }

    init(underlyingError: any Error) {
        let nsError = underlyingError as NSError
        domain = nsError.domain
        code = nsError.code
        localizedDescription = nsError.localizedDescription
        self.underlyingError = underlyingError
    }
}

public enum CameraAgentRegistrationOutcome: Equatable {
    case refreshed(CameraAgentRegistrationState)
    case registered(CameraAgentRegistrationState)
    case unregistered(CameraAgentRegistrationState)
    case replaced(CameraAgentRegistrationState)
    case failed(
        operation: CameraAgentRegistrationOperation,
        state: CameraAgentRegistrationState,
        diagnostic: CameraAgentRegistrationDiagnostic
    )

    public static func == (
        lhs: CameraAgentRegistrationOutcome,
        rhs: CameraAgentRegistrationOutcome
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.refreshed(lhsState), .refreshed(rhsState)),
             let (.registered(lhsState), .registered(rhsState)),
             let (.unregistered(lhsState), .unregistered(rhsState)),
             let (.replaced(lhsState), .replaced(rhsState)):
            return lhsState == rhsState
        case let (
            .failed(lhsOperation, lhsState, lhsDiagnostic),
            .failed(rhsOperation, rhsState, rhsDiagnostic)
        ):
            return lhsOperation == rhsOperation
                && lhsState == rhsState
                && lhsDiagnostic.domain == rhsDiagnostic.domain
                && lhsDiagnostic.code == rhsDiagnostic.code
                && lhsDiagnostic.localizedDescription == rhsDiagnostic.localizedDescription
        default:
            return false
        }
    }
}

/// The unregister callback can arrive off the main actor while Tahoe requires
/// re-registration on a later main-run-loop turn. This context owns the entire
/// ordered callback-to-main-queue handoff, and its state is never accessed by
/// both queues concurrently.
private final class CameraAgentReplacementRegistrationContext:
    @unchecked Sendable
{
    private let service: any CameraAgentServicing
    private let completionHandler: (CameraAgentRegistrationOutcome) -> Void

    init(
        service: any CameraAgentServicing,
        completionHandler: @escaping (CameraAgentRegistrationOutcome) -> Void
    ) {
        self.service = service
        self.completionHandler = completionHandler
    }

    func completeUnregistration(_ error: (any Error)?) {
        if let error {
            completionHandler(.failed(
                operation: .replace,
                state: CameraAgentRegistrationState(service.status),
                diagnostic: CameraAgentRegistrationDiagnostic(
                    underlyingError: error
                )
            ))
            return
        }

        // Service Management's completion means the old process has been
        // terminated. Tahoe can still reject an immediate re-registration
        // from inside that callback, however. Crossing one main-run-loop
        // boundary lets smd finish removing the old submission before the
        // exact same app submits its newly embedded helper.
        DispatchQueue.main.async {
            self.register()
        }
    }

    private func register() {
        do {
            try service.register()
            completionHandler(.replaced(
                CameraAgentRegistrationState(service.status)
            ))
        } catch {
            completionHandler(.failed(
                operation: .replace,
                state: CameraAgentRegistrationState(service.status),
                diagnostic: CameraAgentRegistrationDiagnostic(
                    underlyingError: error
                )
            ))
        }
    }
}

public struct CameraAgentRegistrationClient {
    public let identity: CameraAgentServiceIdentity
    private let serviceFactory: any CameraAgentServiceCreating

    public init(
        identity: CameraAgentServiceIdentity,
        serviceFactory: any CameraAgentServiceCreating = SystemCameraAgentServiceFactory()
    ) {
        self.identity = identity
        self.serviceFactory = serviceFactory
    }

    public func refresh() -> CameraAgentRegistrationOutcome {
        let service = makeService()
        return .refreshed(CameraAgentRegistrationState(service.status))
    }

    public func register() -> CameraAgentRegistrationOutcome {
        let service = makeService()
        do {
            try service.register()
            return .registered(CameraAgentRegistrationState(service.status))
        } catch {
            return .failed(
                operation: .register,
                state: CameraAgentRegistrationState(service.status),
                diagnostic: CameraAgentRegistrationDiagnostic(underlyingError: error)
            )
        }
    }

    public func unregister() -> CameraAgentRegistrationOutcome {
        let service = makeService()
        do {
            try service.unregister()
            return .unregistered(CameraAgentRegistrationState(service.status))
        } catch {
            return .failed(
                operation: .unregister,
                state: CameraAgentRegistrationState(service.status),
                diagnostic: CameraAgentRegistrationDiagnostic(underlyingError: error)
            )
        }
    }

    public func replace(
        completionHandler: @escaping (CameraAgentRegistrationOutcome) -> Void
    ) {
        let service = makeService()
        let context = CameraAgentReplacementRegistrationContext(
            service: service,
            completionHandler: completionHandler
        )
        service.unregisterForReplacement { error in
            context.completeUnregistration(error)
        }
    }

    public func replacementAssessment(
        embedded: CameraAgentArtifactFingerprint,
        registered: CameraAgentArtifactFingerprint?,
        running: CameraAgentArtifactFingerprint?
    ) -> CameraAgentReplacementAssessment {
        let registrationState = CameraAgentRegistrationState(makeService().status)
        return CameraAgentReplacementAssessor.assess(
            registrationState: registrationState,
            embedded: embedded,
            registered: registered,
            running: running
        )
    }

    private func makeService() -> any CameraAgentServicing {
        serviceFactory.makeAgent(plistName: identity.plistName)
    }
}
