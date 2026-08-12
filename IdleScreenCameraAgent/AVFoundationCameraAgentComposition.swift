import AVFoundation
import CryptoKit
import Darwin
import Foundation
import IdleScreenCamera
import Security

struct CameraAgentSignedCodeEvidence: Equatable, Sendable {
    let signingIdentifier: String
    let teamIdentifier: String
    let codeDirectoryHash: String
}

protocol CameraAgentSignedCodeInspecting: Sendable {
    func inspectCurrentCode(
        agentBundleURL: URL,
        executableURL: URL,
        sourceAppURL: URL
    ) throws -> CameraAgentSignedCodeEvidence
}

enum CameraAgentSelfIdentityError: Error, Equatable, Sendable {
    case unavailable
}

struct SecurityCameraAgentSignedCodeInspector: CameraAgentSignedCodeInspecting {
    func inspectCurrentCode(
        agentBundleURL: URL,
        executableURL: URL,
        sourceAppURL: URL
    ) throws -> CameraAgentSignedCodeEvidence {
        // A sandboxed nested helper cannot create a static-code object for its
        // ancestor app bundle. The caller still hashes the signed LaunchAgent
        // from that bundle after this live helper identity check succeeds.
        _ = sourceAppURL
        var currentCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &currentCode) == errSecSuccess,
              let currentCode,
              SecCodeCheckValidity(
                  currentCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate),
                  nil
              ) == errSecSuccess else {
            throw CameraAgentIdentityBootstrapFailure.liveCode
        }

        guard staticCodeIsValid(at: agentBundleURL) else {
            throw CameraAgentIdentityBootstrapFailure.helperSignature
        }
        var currentStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            currentCode,
            SecCSFlags(),
            &currentStaticCode
        ) == errSecSuccess,
        let currentStaticCode else {
            throw CameraAgentIdentityBootstrapFailure.liveCode
        }

        var currentCodePath: CFURL?
        guard SecCodeCopyPath(currentStaticCode, SecCSFlags(), &currentCodePath) == errSecSuccess,
              let currentCodePath,
              (currentCodePath as URL).resolvingSymlinksInPath()
                == agentBundleURL.resolvingSymlinksInPath() else {
            throw CameraAgentIdentityBootstrapFailure.liveCodePath
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            currentStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [CFString: Any],
        let signingIdentifier = information[kSecCodeInfoIdentifier] as? String,
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
        let codeDirectoryHash = information[kSecCodeInfoUnique] as? Data else {
            throw CameraAgentIdentityBootstrapFailure.signingInformation
        }

        return CameraAgentSignedCodeEvidence(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            codeDirectoryHash: codeDirectoryHash.hexadecimalString
        )
    }

    private func staticCodeIsValid(at url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            return false
        }
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess
    }
}

struct CameraAgentSelfIdentityProvider {
    private static let maximumExecutableByteCount = 256 * 1_024 * 1_024
    private static let maximumProfileByteCount = 4 * 1_024 * 1_024

    private let agentBundleURL: URL
    private let executableURL: URL
    private let infoDictionary: [String: Any]
    private let processIdentifier: @Sendable () -> Int32
    private let signedCodeInspector: any CameraAgentSignedCodeInspecting

    init(
        agentBundleURL: URL,
        executableURL: URL,
        infoDictionary: [String: Any],
        processIdentifier: @escaping @Sendable () -> Int32,
        signedCodeInspector: any CameraAgentSignedCodeInspecting
    ) {
        self.agentBundleURL = agentBundleURL
        self.executableURL = executableURL
        self.infoDictionary = infoDictionary
        self.processIdentifier = processIdentifier
        self.signedCodeInspector = signedCodeInspector
    }

    init?(
        bundle: Bundle = .main,
        signedCodeInspector: any CameraAgentSignedCodeInspecting =
            SecurityCameraAgentSignedCodeInspector()
    ) {
        guard let executableURL = bundle.executableURL,
              let infoDictionary = bundle.infoDictionary else {
            return nil
        }
        self.init(
            agentBundleURL: bundle.bundleURL,
            executableURL: executableURL,
            infoDictionary: infoDictionary,
            processIdentifier: { Darwin.getpid() },
            signedCodeInspector: signedCodeInspector
        )
    }

    func identity(
        configuration: CameraAgentProcessConfiguration,
        processIncarnationEpoch: UInt64
    ) throws -> IdleScreenCameraAgentIdentity {
        let canonicalAgentBundleURL = agentBundleURL.resolvingSymlinksInPath()
        let canonicalExecutableURL = executableURL.resolvingSymlinksInPath()
        let helpersURL = canonicalAgentBundleURL.deletingLastPathComponent()
        let contentsURL = helpersURL.deletingLastPathComponent()
        let sourceAppURL = contentsURL.deletingLastPathComponent()
        guard canonicalAgentBundleURL.pathExtension == "app",
              helpersURL.lastPathComponent == "Helpers",
              contentsURL.lastPathComponent == "Contents",
              sourceAppURL.pathExtension == "app",
              canonicalExecutableURL.path.hasPrefix(
                  canonicalAgentBundleURL.appendingPathComponent("Contents/MacOS").path + "/"
              ),
              let bundleIdentifier = infoDictionary["CFBundleIdentifier"] as? String,
              let bundleVersion = infoDictionary["CFBundleVersion"] as? String,
              let marketingVersion = infoDictionary["CFBundleShortVersionString"] as? String,
              bundleIdentifier == configuration.agentBundleIdentifier else {
            throw CameraAgentIdentityBootstrapFailure.bundleLayout
        }

        let evidence = try signedCodeInspector.inspectCurrentCode(
            agentBundleURL: canonicalAgentBundleURL,
            executableURL: canonicalExecutableURL,
            sourceAppURL: sourceAppURL
        )
        guard evidence.signingIdentifier == bundleIdentifier,
              evidence.teamIdentifier == configuration.expectedTeamIdentifier else {
            throw CameraAgentIdentityBootstrapFailure.signingTuple
        }

        let profileURL = canonicalAgentBundleURL.appendingPathComponent(
            "Contents/embedded.provisionprofile"
        )
        let executableSHA256: String
        do {
            executableSHA256 = try sha256(
                of: canonicalExecutableURL,
                maximumByteCount: Self.maximumExecutableByteCount
            )
        } catch {
            throw CameraAgentIdentityBootstrapFailure.executableHash
        }
        let profileSHA256: String
        do {
            profileSHA256 = try sha256(
                of: profileURL,
                maximumByteCount: Self.maximumProfileByteCount
            )
        } catch {
            throw CameraAgentIdentityBootstrapFailure.provisioningProfileHash
        }

        guard let identity = IdleScreenCameraAgentIdentity(
            processIdentifier: processIdentifier(),
            processIncarnationEpoch: processIncarnationEpoch,
            bundleIdentifier: bundleIdentifier,
            serviceIdentifier: configuration.machServiceName,
            bundleVersion: bundleVersion,
            marketingVersion: marketingVersion,
            signingIdentifier: evidence.signingIdentifier,
            teamIdentifier: evidence.teamIdentifier,
            codeDirectoryHash: evidence.codeDirectoryHash,
            executableSHA256: executableSHA256,
            launchAgentSHA256: configuration.launchAgentSHA256,
            provisioningProfileSHA256: profileSHA256,
            sourceAppPath: sourceAppURL.path
        ) else {
            throw CameraAgentIdentityBootstrapFailure.wireIdentity
        }
        return identity
    }

    private func sha256(of url: URL, maximumByteCount: Int) throws -> String {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumByteCount else {
            throw CameraAgentSelfIdentityError.unavailable
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount = 0
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            byteCount += data.count
            guard byteCount <= maximumByteCount else {
                throw CameraAgentSelfIdentityError.unavailable
            }
            hasher.update(data: data)
        }
        guard byteCount == fileSize else {
            throw CameraAgentSelfIdentityError.unavailable
        }
        return Data(hasher.finalize()).hexadecimalString
    }
}

private extension Data {
    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// The only production type that invokes the camera permission API. The shared
/// runtime calls it only for the existing explicit authorization request.
@available(macOS 15.0, *)
public struct AVFoundationCameraAuthorizationRequester: CameraAgentAuthorizationRequesting {
    public init() {}

    public func requestVideoAccess(
        completion: @escaping @Sendable (CameraAgentAuthorization) -> Void
    ) {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            completion(Self.currentAuthorization)
        }
    }

    private static var currentAuthorization: CameraAgentAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
}

extension CameraAgentProcessRuntime {
    public static func bootstrapProduction(
        configuration: CameraAgentProcessConfiguration
    ) throws -> CameraAgentProcessRuntime {
        try bootstrap(
            configuration: configuration,
            producerStreamEpochSeed: CameraAgentProcessEpochSeed.randomNonzero(),
            containerLocator: FileManagerCameraAgentContainerLocator(),
            components: ProductionCameraAgentProcessComponents(),
            repeatingScheduler: DispatchCameraAgentRepeatingScheduler(),
            sleepWakeSource: WorkspaceCameraAgentSleepWakeSource()
        )
    }
}

private final class ProductionCameraAgentProcessComponents:
    CameraAgentProcessComponentBuilding,
    @unchecked Sendable
{
    func makeAgentIdentity(
        configuration: CameraAgentProcessConfiguration,
        processIncarnationEpoch: UInt64
    ) throws -> IdleScreenCameraAgentIdentity {
        guard let provider = CameraAgentSelfIdentityProvider() else {
            throw CameraAgentIdentityBootstrapFailure.bundleMetadata
        }
        return try provider.identity(
            configuration: configuration,
            processIncarnationEpoch: processIncarnationEpoch
        )
    }

    func makeAuthorizationChecker() -> any CameraCaptureAuthorizationChecking {
        AVFoundationCameraAuthorizationChecker()
    }

    func makeAuthorizationRequester() -> any CameraAgentAuthorizationRequesting {
        AVFoundationCameraAuthorizationRequester()
    }

    func makeDeviceInventoryMonitor() -> any CameraAgentProcessDeviceInventoryMonitoring {
        CameraDeviceInventoryMonitor(
            discoverer: AVFoundationCameraDeviceDiscoverer(),
            eventObserver: AVFoundationCameraDeviceInventoryEventObserver()
        )
    }

    func makeCaptureController(
        authorizationChecker: any CameraCaptureAuthorizationChecking
    ) -> any CameraAgentRuntimeCaptureControlling {
        let controller = CameraCaptureSessionController(
            authorizationChecker: authorizationChecker,
            deviceDiscoverer: AVFoundationCameraDeviceDiscoverer(),
            sessionFactory: AVFoundationCameraCaptureSessionFactory()
        )
        return CameraAgentCaptureControllerAdapter(controller: controller)
    }

    func makeFramePublisher(
        appGroupContainerURL: URL,
        mailboxFileName: String
    ) throws -> any CameraAgentProcessFramePublishing {
        let writer = try CameraFrameMailboxWriter(
            appGroupContainerURL: appGroupContainerURL,
            mailboxFileName: mailboxFileName
        )
        guard let publisher = CameraFrameMailboxRuntimePublisher(writer: writer) else {
            throw CameraAgentProcessBootstrapError.frameTransportUnavailable
        }
        return publisher
    }

    func makeRuntimeDriver(
        permissionRequester: any CameraAgentAuthorizationRequesting,
        captureController: any CameraAgentRuntimeCaptureControlling,
        framePublisher: any CameraAgentProcessFramePublishing
    ) throws -> any CameraAgentProcessDriving {
        guard let driver = CameraAgentRuntimeDriver(
            permissionRequester: permissionRequester,
            captureController: captureController,
            framePublisher: framePublisher,
            mediaServicesResetErrorDomain: AVFoundationErrorDomain
        ) else {
            throw CameraAgentProcessBootstrapError.runtimeUnavailable
        }
        return driver
    }

    func makeService(
        peerPolicy: CameraAgentPeerPolicy,
        captureLimits: CameraAgentCaptureLimits,
        leaseTimeToLive: TimeInterval,
        producerStreamEpochSeed: UInt64,
        agentIdentity: IdleScreenCameraAgentIdentity,
        initialAuthorization: CameraAgentAuthorization,
        authorizationChecker: any CameraCaptureAuthorizationChecking,
        driver: any CameraAgentProcessDriving
    ) throws -> any CameraAgentProcessServicing {
        let leaseClock = CameraLeaseContinuousClock()
        guard let service = CameraAgentService(
            peerPolicy: peerPolicy,
            captureLimits: captureLimits,
            leaseTimeToLive: leaseTimeToLive,
            initialAuthorization: initialAuthorization,
            initialDeviceAvailability: false,
            producerStreamEpochSeed: producerStreamEpochSeed,
            agentIdentity: agentIdentity,
            authorizationChecker: authorizationChecker,
            clock: { leaseClock.now },
            identifierGenerator: UUID.init,
            driver: driver
        ) else {
            throw CameraAgentProcessBootstrapError.serviceUnavailable
        }
        return service
    }

    func bind(
        driver: any CameraAgentProcessDriving,
        to service: any CameraAgentProcessServicing
    ) {
        driver.bind(to: service)
    }

    func makeListener(
        configuration: CameraAgentXPCListenerConfiguration,
        service: any CameraAgentProcessServicing
    ) throws -> any CameraAgentProcessListening {
        guard let service = service as? CameraAgentService else {
            throw CameraAgentProcessBootstrapError.listenerUnavailable
        }
        return CameraAgentXPCListener(
            configuration: configuration,
            service: service
        )
    }
}
