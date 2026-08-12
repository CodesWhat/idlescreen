import AppKit
import Darwin
import Foundation
import IdleScreenCamera
import IdleScreenCore

public struct CameraAgentProcessConfiguration: Equatable, Sendable {
    public static let machServiceInfoKey = "IdleScreenCameraAgentMachServiceName"
    public static let appGroupInfoKey = "IdleScreenCameraAgentAppGroupIdentifier"
    public static let teamIdentifierInfoKey = "IdleScreenCameraAgentTeamIdentifier"
    public static let mailboxFileNameInfoKey = "IdleScreenCameraAgentMailboxFileName"
    public static let launchAgentSHA256InfoKey = "IdleScreenCameraAgentLaunchAgentSHA256"
    public static let mailboxFileName = "camera-frames-v1.mailbox"

    public let agentBundleIdentifier: String
    public let machServiceName: String
    public let appGroupIdentifier: String
    public let expectedTeamIdentifier: String
    public let mailboxFileName: String
    public let launchAgentSHA256: String

    public init?(infoDictionary: [String: Any]) {
        guard let agentBundleIdentifier = infoDictionary["CFBundleIdentifier"] as? String,
              let machServiceName = infoDictionary[Self.machServiceInfoKey] as? String,
              let appGroupIdentifier = infoDictionary[Self.appGroupInfoKey] as? String,
              let expectedTeamIdentifier = infoDictionary[Self.teamIdentifierInfoKey] as? String,
              let mailboxFileName = infoDictionary[Self.mailboxFileNameInfoKey] as? String,
              let launchAgentSHA256 = infoDictionary[Self.launchAgentSHA256InfoKey] as? String,
              mailboxFileName == Self.mailboxFileName,
              Self.isValidTeamIdentifier(expectedTeamIdentifier),
              Self.isValidSHA256(launchAgentSHA256) else {
            return nil
        }

        let expectedTuple: (machService: String, appGroup: String)?
        switch agentBundleIdentifier {
        case "com.idlescreen.camera-agent":
            expectedTuple = (
                "group.com.idlescreen.shared.camera-agent",
                "group.com.idlescreen.shared"
            )
        case "com.idlescreen.camera-agent.dev":
            expectedTuple = (
                "group.com.idlescreen.dev.shared.camera-agent",
                "group.com.idlescreen.dev.shared"
            )
        default:
            expectedTuple = nil
        }
        guard let expectedTuple,
              machServiceName == expectedTuple.machService,
              appGroupIdentifier == expectedTuple.appGroup else {
            return nil
        }

        self.agentBundleIdentifier = agentBundleIdentifier
        self.machServiceName = machServiceName
        self.appGroupIdentifier = appGroupIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.mailboxFileName = mailboxFileName
        self.launchAgentSHA256 = launchAgentSHA256
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
        }
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0)
                || (0x41...0x46).contains($0)
                || (0x61...0x66).contains($0)
        }
    }
}

public enum CameraAgentProcessBootstrapError: Error, Equatable, Sendable {
    case containerUnavailable
    case identityUnavailable(CameraAgentIdentityBootstrapFailure)
    case frameTransportUnavailable
    case runtimeUnavailable
    case serviceUnavailable
    case listenerUnavailable
    case assemblyFailed

    public var stderrToken: String {
        switch self {
        case .containerUnavailable:
            "container-unavailable"
        case let .identityUnavailable(failure):
            "identity-\(failure.rawValue)"
        case .frameTransportUnavailable:
            "frame-transport-unavailable"
        case .runtimeUnavailable:
            "runtime-unavailable"
        case .serviceUnavailable:
            "service-unavailable"
        case .listenerUnavailable:
            "listener-unavailable"
        case .assemblyFailed:
            "assembly-failed"
        }
    }
}

/// Privacy-safe identity bootstrap boundaries emitted by the helper executable.
/// Raw values are fixed diagnostic tokens and never contain paths or signature data.
public enum CameraAgentIdentityBootstrapFailure: String, Error, Equatable, Sendable {
    case unknown
    case bundleMetadata = "bundle-metadata"
    case bundleLayout = "bundle-layout"
    case liveCode = "live-code"
    case helperSignature = "helper-signature"
    case liveCodePath = "live-code-path"
    case signingInformation = "signing-info"
    case signingTuple = "signing-tuple"
    case executableHash = "executable-hash"
    case launchAgentHash = "launch-agent-hash"
    case provisioningProfileHash = "profile-hash"
    case wireIdentity = "wire-identity"
}

protocol CameraAgentAppGroupContainerLocating: AnyObject, Sendable {
    func containerURL(forAppGroupIdentifier identifier: String) -> URL?
}

protocol CameraAgentProcessCancellable: AnyObject, Sendable {
    func cancel()
}

protocol CameraAgentProcessRepeatingScheduling: AnyObject, Sendable {
    func scheduleRepeating(
        every interval: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any CameraAgentProcessCancellable
}

protocol CameraAgentSleepWakeSourcing: AnyObject, Sendable {
    func start(
        sleepHandler: @escaping @Sendable () -> Void,
        wakeHandler: @escaping @Sendable () -> Void
    ) -> any CameraAgentProcessCancellable
}

protocol CameraAgentTerminationSignalSourcing: AnyObject, Sendable {
    func start(
        terminationHandler: @escaping @Sendable () -> Void
    ) -> any CameraAgentProcessCancellable
}

protocol CameraAgentProcessTerminating: AnyObject, Sendable {
    func terminateSuccessfully()
}

protocol CameraAgentProcessDeviceInventoryMonitoring: AnyObject, Sendable {
    @discardableResult
    func start(
        _ handler: @escaping @Sendable (CameraDeviceInventorySnapshot) -> Void
    ) -> Bool
    func refresh()
    func stop()
}

extension CameraDeviceInventoryMonitor: CameraAgentProcessDeviceInventoryMonitoring {}

protocol CameraAgentProcessFramePublishing: CameraAgentRuntimeFramePublishing {
    func invalidate() throws
}

extension CameraFrameMailboxRuntimePublisher: CameraAgentProcessFramePublishing {}

protocol CameraAgentProcessDriving: CameraAgentServiceDriver {
    func bind(to receiver: any CameraAgentRuntimeEventReceiving)
    func receiveSleep()
    func receiveWake()
    func receiveDeviceInventory(_ snapshot: CameraDeviceInventorySnapshot)
    func receiveCameraSelection(_ selection: IdleScreenCameraSelection)
    func receiveCameraConfiguration(
        _ configuration: IdleScreenCameraConfiguration
    )
    func cancelDeviceInventoryCallbacks()
}

extension CameraAgentProcessDriving {
    func receiveCameraSelection(_ selection: IdleScreenCameraSelection) {
        _ = selection
    }

    func receiveCameraConfiguration(
        _ configuration: IdleScreenCameraConfiguration
    ) {
        receiveCameraSelection(configuration.selection)
    }
}

extension CameraAgentRuntimeDriver: CameraAgentProcessDriving {}

protocol CameraAgentProcessServicing: CameraAgentRuntimeEventReceiving {
    @discardableResult
    func reapExpiredLeases() -> Int
    func refreshAuthorizationForActiveDemand()
}

extension CameraAgentService: CameraAgentProcessServicing {}

protocol CameraAgentProcessListening: AnyObject {
    func activate()
    func invalidate()
}

extension CameraAgentXPCListener: CameraAgentProcessListening {}

protocol CameraAgentProcessComponentBuilding: AnyObject, Sendable {
    func makeAgentIdentity(
        configuration: CameraAgentProcessConfiguration,
        processIncarnationEpoch: UInt64
    ) throws -> IdleScreenCameraAgentIdentity
    func makeAuthorizationChecker() -> any CameraCaptureAuthorizationChecking
    func makeAuthorizationRequester() -> any CameraAgentAuthorizationRequesting
    func makeDeviceInventoryMonitor() -> any CameraAgentProcessDeviceInventoryMonitoring
    func makeCaptureController(
        authorizationChecker: any CameraCaptureAuthorizationChecking
    ) -> any CameraAgentRuntimeCaptureControlling
    func makeFramePublisher(
        appGroupContainerURL: URL,
        mailboxFileName: String
    ) throws -> any CameraAgentProcessFramePublishing
    func makeRuntimeDriver(
        permissionRequester: any CameraAgentAuthorizationRequesting,
        captureController: any CameraAgentRuntimeCaptureControlling,
        framePublisher: any CameraAgentProcessFramePublishing
    ) throws -> any CameraAgentProcessDriving
    func makeService(
        peerPolicy: CameraAgentPeerPolicy,
        captureLimits: CameraAgentCaptureLimits,
        leaseTimeToLive: TimeInterval,
        producerStreamEpochSeed: UInt64,
        agentIdentity: IdleScreenCameraAgentIdentity,
        initialAuthorization: CameraAgentAuthorization,
        authorizationChecker: any CameraCaptureAuthorizationChecking,
        driver: any CameraAgentProcessDriving
    ) throws -> any CameraAgentProcessServicing
    func bind(
        driver: any CameraAgentProcessDriving,
        to service: any CameraAgentProcessServicing
    )
    func makeListener(
        configuration: CameraAgentXPCListenerConfiguration,
        service: any CameraAgentProcessServicing
    ) throws -> any CameraAgentProcessListening
}

enum CameraAgentProcessEpochSeed {
    static func randomNonzero() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        return randomNonzero(using: &generator)
    }

    static func randomNonzero<Generator: RandomNumberGenerator>(
        using generator: inout Generator
    ) -> UInt64 {
        var candidate = UInt64.zero
        repeat {
            // A process incarnation has 63 bits of entropy. Collisions remain
            // probabilistic, while reserving the high half leaves each process
            // almost 2^63 strictly increasing producer epochs before exhaustion.
            candidate = generator.next() & (UInt64.max >> 1)
        } while candidate == 0
        return candidate
    }
}

public final class CameraAgentProcessRuntime: @unchecked Sendable {
    private enum Lifecycle {
        case assembled
        case running
        case stopped
    }

    private static let leaseReapInterval: TimeInterval = 1

    private let authorizationChecker: any CameraCaptureAuthorizationChecking
    private let authorizationRequester: any CameraAgentAuthorizationRequesting
    private let captureController: any CameraAgentRuntimeCaptureControlling
    private let deviceInventoryMonitor: any CameraAgentProcessDeviceInventoryMonitoring
    private let framePublisher: any CameraAgentProcessFramePublishing
    private let driver: any CameraAgentProcessDriving
    private let service: any CameraAgentProcessServicing
    private let listener: any CameraAgentProcessListening
    private let repeatingScheduler: any CameraAgentProcessRepeatingScheduling
    private let sleepWakeSource: any CameraAgentSleepWakeSourcing
    private let appGroupContainerURL: URL
    private let configurationStore: IdleScreenConfigurationStore
    private let lock = NSLock()
    private let cameraSelectionLock = NSLock()

    private var lifecycle: Lifecycle = .assembled
    private var reapTask: (any CameraAgentProcessCancellable)?
    private var sleepWakeTask: (any CameraAgentProcessCancellable)?
    private var terminationTask: (any CameraAgentProcessCancellable)?
    private var lastDeliveredCameraConfiguration:
        IdleScreenCameraConfiguration?

    private init(
        authorizationChecker: any CameraCaptureAuthorizationChecking,
        authorizationRequester: any CameraAgentAuthorizationRequesting,
        deviceInventoryMonitor: any CameraAgentProcessDeviceInventoryMonitoring,
        captureController: any CameraAgentRuntimeCaptureControlling,
        framePublisher: any CameraAgentProcessFramePublishing,
        driver: any CameraAgentProcessDriving,
        service: any CameraAgentProcessServicing,
        listener: any CameraAgentProcessListening,
        repeatingScheduler: any CameraAgentProcessRepeatingScheduling,
        sleepWakeSource: any CameraAgentSleepWakeSourcing,
        appGroupContainerURL: URL
    ) {
        self.authorizationChecker = authorizationChecker
        self.authorizationRequester = authorizationRequester
        self.deviceInventoryMonitor = deviceInventoryMonitor
        self.captureController = captureController
        self.framePublisher = framePublisher
        self.driver = driver
        self.service = service
        self.listener = listener
        self.repeatingScheduler = repeatingScheduler
        self.sleepWakeSource = sleepWakeSource
        self.appGroupContainerURL = appGroupContainerURL
        configurationStore = IdleScreenConfigurationStore(
            fileURL: IdleScreenSharedPaths(
                rootURL: appGroupContainerURL
            ).configurationURL
        )
    }

    deinit {
        shutdown()
    }

    static func bootstrap(
        configuration: CameraAgentProcessConfiguration,
        producerStreamEpochSeed: UInt64,
        containerLocator: any CameraAgentAppGroupContainerLocating,
        components: any CameraAgentProcessComponentBuilding,
        repeatingScheduler: any CameraAgentProcessRepeatingScheduling,
        sleepWakeSource: any CameraAgentSleepWakeSourcing
    ) throws -> CameraAgentProcessRuntime {
        guard producerStreamEpochSeed > 0 else {
            throw CameraAgentProcessBootstrapError.assemblyFailed
        }
        guard let appGroupContainerURL = containerLocator.containerURL(
            forAppGroupIdentifier: configuration.appGroupIdentifier
        ) else {
            throw CameraAgentProcessBootstrapError.containerUnavailable
        }

        do {
            let agentIdentity: IdleScreenCameraAgentIdentity
            do {
                agentIdentity = try components.makeAgentIdentity(
                    configuration: configuration,
                    processIncarnationEpoch: producerStreamEpochSeed
                )
            } catch let failure as CameraAgentIdentityBootstrapFailure {
                throw CameraAgentProcessBootstrapError.identityUnavailable(failure)
            } catch let error as CameraAgentProcessBootstrapError {
                throw error
            } catch {
                throw CameraAgentProcessBootstrapError.identityUnavailable(.unknown)
            }
            guard agentIdentity.processIncarnationEpoch == producerStreamEpochSeed,
                  agentIdentity.bundleIdentifier == configuration.agentBundleIdentifier,
                  agentIdentity.serviceIdentifier == configuration.machServiceName,
                  agentIdentity.teamIdentifier == configuration.expectedTeamIdentifier else {
                throw CameraAgentProcessBootstrapError.assemblyFailed
            }
            let authorizationChecker = components.makeAuthorizationChecker()
            let authorizationRequester = components.makeAuthorizationRequester()
            let deviceInventoryMonitor = components.makeDeviceInventoryMonitor()
            let captureController = components.makeCaptureController(
                authorizationChecker: authorizationChecker
            )
            let framePublisher: any CameraAgentProcessFramePublishing
            do {
                framePublisher = try components.makeFramePublisher(
                    appGroupContainerURL: appGroupContainerURL,
                    mailboxFileName: configuration.mailboxFileName
                )
            } catch let error as CameraAgentProcessBootstrapError {
                throw error
            } catch {
                throw CameraAgentProcessBootstrapError.frameTransportUnavailable
            }
            let driver: any CameraAgentProcessDriving
            do {
                driver = try components.makeRuntimeDriver(
                    permissionRequester: authorizationRequester,
                    captureController: captureController,
                    framePublisher: framePublisher
                )
            } catch let error as CameraAgentProcessBootstrapError {
                throw error
            } catch {
                throw CameraAgentProcessBootstrapError.runtimeUnavailable
            }
            guard let listenerConfiguration = CameraAgentXPCListenerConfiguration(
                machServiceName: configuration.machServiceName,
                expectedTeamIdentifier: configuration.expectedTeamIdentifier
            ),
                let peerPolicy = CameraAgentPeerPolicy(
                    expectedTeamIdentifier: configuration.expectedTeamIdentifier,
                    companionBundleIdentifiers: [
                        listenerConfiguration.companionBundleIdentifier,
                    ],
                    screenSaverBundleIdentifiers: [
                        listenerConfiguration.screenSaverBundleIdentifier,
                    ]
                ),
                let captureLimits = CameraAgentCaptureLimits(
                    maximumWidth: IdleScreenCameraWire.maximumWidth,
                    maximumHeight: IdleScreenCameraWire.maximumHeight,
                    maximumFramesPerSecond: IdleScreenCameraWire.maximumFramesPerSecond,
                    maximumMailboxSlotCount: IdleScreenCameraWire.maximumMailboxSlotCount
                ) else {
                throw CameraAgentProcessBootstrapError.assemblyFailed
            }

            let initialAuthorization = CameraAgentAuthorization(
                captureAuthorization: authorizationChecker.authorizationStatus()
            )
            let service: any CameraAgentProcessServicing
            do {
                service = try components.makeService(
                    peerPolicy: peerPolicy,
                    captureLimits: captureLimits,
                    leaseTimeToLive: CameraAgentLeasePolicy.production.leaseTimeToLive,
                    producerStreamEpochSeed: producerStreamEpochSeed,
                    agentIdentity: agentIdentity,
                    initialAuthorization: initialAuthorization,
                    authorizationChecker: authorizationChecker,
                    driver: driver
                )
            } catch let error as CameraAgentProcessBootstrapError {
                throw error
            } catch {
                throw CameraAgentProcessBootstrapError.serviceUnavailable
            }
            components.bind(driver: driver, to: service)
            let listener: any CameraAgentProcessListening
            do {
                listener = try components.makeListener(
                    configuration: listenerConfiguration,
                    service: service
                )
            } catch let error as CameraAgentProcessBootstrapError {
                throw error
            } catch {
                throw CameraAgentProcessBootstrapError.listenerUnavailable
            }

            return CameraAgentProcessRuntime(
                authorizationChecker: authorizationChecker,
                authorizationRequester: authorizationRequester,
                deviceInventoryMonitor: deviceInventoryMonitor,
                captureController: captureController,
                framePublisher: framePublisher,
                driver: driver,
                service: service,
                listener: listener,
                repeatingScheduler: repeatingScheduler,
                sleepWakeSource: sleepWakeSource,
                appGroupContainerURL: appGroupContainerURL
            )
        } catch let error as CameraAgentProcessBootstrapError {
            throw error
        } catch {
            throw CameraAgentProcessBootstrapError.assemblyFailed
        }
    }

    public func start() {
        lock.withLock {
            startLocked()
        }
    }

    public func startForProcessLifetime() {
        startForProcessLifetime(
            terminationSource: DispatchCameraAgentTerminationSignalSource(),
            processTerminator: DarwinCameraAgentProcessTerminator()
        )
    }

    func startForProcessLifetime(
        terminationSource: any CameraAgentTerminationSignalSourcing,
        processTerminator: any CameraAgentProcessTerminating
    ) {
        lock.withLock {
            guard lifecycle == .assembled else { return }
            terminationTask = terminationSource.start { [weak self] in
                guard let self else { return }
                self.shutdown()
                processTerminator.terminateSuccessfully()
            }
            startLocked()
        }
    }

    public func shutdown() {
        lock.withLock {
            guard lifecycle != .stopped else { return }
            lifecycle = .stopped
            deviceInventoryMonitor.stop()
            driver.cancelDeviceInventoryCallbacks()
            reapTask?.cancel()
            reapTask = nil
            sleepWakeTask?.cancel()
            sleepWakeTask = nil
            terminationTask?.cancel()
            terminationTask = nil
            listener.invalidate()
            try? framePublisher.invalidate()
        }
    }

    private func startLocked() {
        guard lifecycle == .assembled else { return }
        refreshCameraSelection()
        _ = deviceInventoryMonitor.start { [weak driver] snapshot in
            driver?.receiveDeviceInventory(snapshot)
        }
        reapTask = repeatingScheduler.scheduleRepeating(
            every: Self.leaseReapInterval
        ) { [weak self, weak service] in
            // Notifications remain the fast path. This bounded probe prevents
            // a missed or early AVFoundation edge from stranding no-device
            // recovery until the helper is restarted.
            self?.deviceInventoryMonitor.refresh()
            self?.refreshCameraSelection()
            _ = service?.reapExpiredLeases()
            service?.refreshAuthorizationForActiveDemand()
        }
        sleepWakeTask = sleepWakeSource.start(
            sleepHandler: { [weak driver] in
                driver?.receiveSleep()
            },
            wakeHandler: { [weak driver] in
                driver?.receiveWake()
            }
        )
        listener.activate()
        lifecycle = .running
    }

    private func refreshCameraSelection() {
        let cameraConfiguration: IdleScreenCameraConfiguration
        do {
            cameraConfiguration = try configurationStore.read()?.camera
                ?? .default
        } catch {
            // A partially-written, malformed, or temporarily unreadable file
            // must not replace the last valid process-wide camera policy.
            return
        }

        let shouldDeliver = cameraSelectionLock.withLock {
            guard lastDeliveredCameraConfiguration != cameraConfiguration else {
                return false
            }
            lastDeliveredCameraConfiguration = cameraConfiguration
            return true
        }
        if shouldDeliver {
            driver.receiveCameraConfiguration(cameraConfiguration)
        }
    }
}

final class FileManagerCameraAgentContainerLocator:
    CameraAgentAppGroupContainerLocating,
    @unchecked Sendable
{
    func containerURL(forAppGroupIdentifier identifier: String) -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        )
    }
}

final class DispatchCameraAgentRepeatingScheduler:
    CameraAgentProcessRepeatingScheduling,
    @unchecked Sendable
{
    private final class Task: CameraAgentProcessCancellable, @unchecked Sendable {
        private let lock = NSLock()
        private var source: DispatchSourceTimer?

        init(source: DispatchSourceTimer) {
            self.source = source
        }

        func cancel() {
            lock.withLock {
                source?.setEventHandler {}
                source?.cancel()
                source = nil
            }
        }
    }

    private let queue = DispatchQueue(
        label: "com.idlescreen.camera-agent.lease-reaper",
        qos: .utility
    )

    func scheduleRepeating(
        every interval: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any CameraAgentProcessCancellable {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(100)
        )
        source.setEventHandler(handler: operation)
        let task = Task(source: source)
        source.activate()
        return task
    }
}

final class WorkspaceCameraAgentSleepWakeSource:
    CameraAgentSleepWakeSourcing,
    @unchecked Sendable
{
    private final class Task: CameraAgentProcessCancellable, @unchecked Sendable {
        private let lock = NSLock()
        private var observers: [NSObjectProtocol]
        private let notificationCenter: NotificationCenter

        init(
            observers: [NSObjectProtocol],
            notificationCenter: NotificationCenter
        ) {
            self.observers = observers
            self.notificationCenter = notificationCenter
        }

        func cancel() {
            lock.withLock {
                for observer in observers {
                    notificationCenter.removeObserver(observer)
                }
                observers.removeAll()
            }
        }
    }

    func start(
        sleepHandler: @escaping @Sendable () -> Void,
        wakeHandler: @escaping @Sendable () -> Void
    ) -> any CameraAgentProcessCancellable {
        let center = NSWorkspace.shared.notificationCenter
        let observers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil
            ) { _ in sleepHandler() },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in wakeHandler() },
        ]
        return Task(observers: observers, notificationCenter: center)
    }
}

final class DispatchCameraAgentTerminationSignalSource:
    CameraAgentTerminationSignalSourcing,
    @unchecked Sendable
{
    private final class Task: CameraAgentProcessCancellable, @unchecked Sendable {
        private let lock = NSLock()
        private var source: DispatchSourceSignal?

        init(source: DispatchSourceSignal) {
            self.source = source
        }

        func cancel() {
            lock.withLock {
                guard let source else { return }
                source.setEventHandler {}
                source.cancel()
                self.source = nil
                Darwin.signal(SIGTERM, SIG_DFL)
            }
        }
    }

    private let queue = DispatchQueue(
        label: "com.idlescreen.camera-agent.termination",
        qos: .userInitiated
    )

    func start(
        terminationHandler: @escaping @Sendable () -> Void
    ) -> any CameraAgentProcessCancellable {
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler(handler: terminationHandler)
        let task = Task(source: source)
        source.activate()
        return task
    }
}

final class DarwinCameraAgentProcessTerminator:
    CameraAgentProcessTerminating,
    @unchecked Sendable
{
    func terminateSuccessfully() {
        Darwin.exit(EXIT_SUCCESS)
    }
}
