import Foundation
import IdleScreenCamera
import IdleScreenCore

public enum CameraAgentPeerRole: Equatable, Sendable {
    case companion
    case screenSaver
}

/// Identity resolved from the connection's public PID and effective UID after
/// the listener installs its exact signing requirement, then validated against
/// the live process with Security.framework.
///
/// This type is deliberately absent from the wire protocol: callers cannot
/// supply or override their process, team, or bundle identity in a request.
public struct CameraAgentAuthenticatedPeer: Equatable, Sendable {
    public let processIdentifier: Int32
    public let teamIdentifier: String
    public let bundleIdentifier: String

    public init(
        processIdentifier: Int32,
        teamIdentifier: String,
        bundleIdentifier: String
    ) {
        self.processIdentifier = processIdentifier
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct CameraAgentPeerPolicy: Equatable, Sendable {
    public let expectedTeamIdentifier: String
    public let companionBundleIdentifiers: Set<String>
    public let screenSaverBundleIdentifiers: Set<String>

    public init?(
        expectedTeamIdentifier: String,
        companionBundleIdentifiers: Set<String>,
        screenSaverBundleIdentifiers: Set<String>
    ) {
        guard !expectedTeamIdentifier.isEmpty,
              !companionBundleIdentifiers.isEmpty,
              !screenSaverBundleIdentifiers.isEmpty,
              companionBundleIdentifiers.isDisjoint(with: screenSaverBundleIdentifiers),
              companionBundleIdentifiers.union(screenSaverBundleIdentifiers).allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.companionBundleIdentifiers = companionBundleIdentifiers
        self.screenSaverBundleIdentifiers = screenSaverBundleIdentifiers
    }

    public func role(for peer: CameraAgentAuthenticatedPeer) -> CameraAgentPeerRole? {
        guard peer.processIdentifier > 0,
              peer.teamIdentifier == expectedTeamIdentifier else {
            return nil
        }
        if companionBundleIdentifiers.contains(peer.bundleIdentifier) {
            return .companion
        }
        if screenSaverBundleIdentifiers.contains(peer.bundleIdentifier) {
            return .screenSaver
        }
        return nil
    }
}

public enum CameraAgentAdmissionError: Error, Equatable, Sendable {
    case unauthorizedPeer
    case identifierExhausted
}

public struct CameraAgentStreamConfiguration: Equatable, Sendable {
    public let maximumWidth: Int
    public let maximumHeight: Int
    public let maximumFramesPerSecond: Int
    public let mailboxSlotCount: Int
    public let producerStreamEpoch: UInt64

    public init(
        maximumWidth: Int,
        maximumHeight: Int,
        maximumFramesPerSecond: Int,
        mailboxSlotCount: Int,
        producerStreamEpoch: UInt64 = 1
    ) {
        precondition(producerStreamEpoch > 0, "Producer stream epoch must be positive")
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.mailboxSlotCount = mailboxSlotCount
        self.producerStreamEpoch = producerStreamEpoch
    }
}

public struct CameraAgentCaptureLimits: Equatable, Sendable {
    public let maximumWidth: Int
    public let maximumHeight: Int
    public let maximumFramesPerSecond: Int
    public let maximumMailboxSlotCount: Int

    public init?(
        maximumWidth: Int,
        maximumHeight: Int,
        maximumFramesPerSecond: Int,
        maximumMailboxSlotCount: Int
    ) {
        guard (1...IdleScreenCameraWire.maximumWidth).contains(maximumWidth),
              (1...IdleScreenCameraWire.maximumHeight).contains(maximumHeight),
              (1...IdleScreenCameraWire.maximumFramesPerSecond).contains(maximumFramesPerSecond),
              (1...IdleScreenCameraWire.maximumMailboxSlotCount).contains(maximumMailboxSlotCount) else {
            return nil
        }
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.maximumMailboxSlotCount = maximumMailboxSlotCount
    }

    func clamped(
        _ request: IdleScreenCameraBeginStreamRequest,
        producerStreamEpoch: UInt64
    ) -> CameraAgentStreamConfiguration {
        CameraAgentStreamConfiguration(
            maximumWidth: min(request.maximumWidth, maximumWidth),
            maximumHeight: min(request.maximumHeight, maximumHeight),
            maximumFramesPerSecond: min(request.maximumFramesPerSecond, maximumFramesPerSecond),
            mailboxSlotCount: min(request.mailboxSlotCount, maximumMailboxSlotCount),
            producerStreamEpoch: producerStreamEpoch
        )
    }
}

/// I/O boundary driven while the service's serialized state is held. A driver
/// must enqueue callbacks instead of synchronously re-entering the service.
public protocol CameraAgentServiceDriver: AnyObject, Sendable {
    func transportIdentifier(for configuration: CameraAgentStreamConfiguration) -> String?
    func cameraDeviceSnapshot() -> CameraAgentRuntimeDeviceSnapshot
    func perform(
        _ action: CameraAgentAction,
        configuration: CameraAgentStreamConfiguration?
    )
}

public extension CameraAgentServiceDriver {
    func cameraDeviceSnapshot() -> CameraAgentRuntimeDeviceSnapshot {
        CameraAgentRuntimeDeviceSnapshot(
            inventoryGeneration: 0,
            devices: [],
            preference: .automatic,
            resolvedDeviceIdentifier: nil,
            activeDeviceIdentifier: nil,
            reconfigurationPending: false
        )
    }
}

/// Events the capture implementation may report back to the serialized core.
/// Permission-request and lease-demand events are intentionally not representable.
public enum CameraAgentCaptureDriverEvent: Equatable, Sendable {
    case captureStarted(generation: UInt64)
    case captureStopped(generation: UInt64)
    case firstFrame(generation: UInt64, sequence: UInt64)
    case nextFrame(generation: UInt64, sequence: UInt64)
    case interrupted(generation: UInt64)
    case runtimeError(generation: UInt64, code: String)
    case recoveryFailure(
        generation: UInt64,
        cause: CameraCaptureRecoveryCause,
        code: String
    )
    case recoveryRetryDeadlineReached(generation: UInt64)
    case deviceUnavailable
    case deviceAvailable
    case sleep
    case wake
}

public final class CameraAgentService: @unchecked Sendable {
    private let peerPolicy: CameraAgentPeerPolicy
    private let captureLimits: CameraAgentCaptureLimits
    private let leaseTimeToLive: TimeInterval
    private let agentIdentity: IdleScreenCameraAgentIdentity
    private let clock: () -> Date
    private let identifierGenerator: () -> UUID
    private let authorizationChecker: (any CameraCaptureAuthorizationChecking)?
    private let recoveryClock: @Sendable () -> TimeInterval
    private let driver: any CameraAgentServiceDriver
    private let diagnosticSink: any CameraAgentDiagnosticEventSink
    private let lock = NSLock()

    private var stateMachine: CameraAgentStateMachine
    private var leaseCoordinator: CameraLeaseCoordinator
    private var admittedConnectionIdentifiers: Set<String> = []
    private var leaseExpirationsByConnection: [String: [String: Date]] = [:]
    private var activeConfiguration: CameraAgentStreamConfiguration?
    private var activeTransportIdentifier: String?
    private var identifierSerial: UInt64 = 0
    private var explicitAuthorizationRequestIsOutstanding = false

    public init?(
        peerPolicy: CameraAgentPeerPolicy,
        captureLimits: CameraAgentCaptureLimits,
        leaseTimeToLive: TimeInterval,
        initialAuthorization: CameraAgentAuthorization,
        initialDeviceAvailability: Bool = true,
        producerStreamEpochSeed: UInt64 = 1,
        agentIdentity: IdleScreenCameraAgentIdentity,
        authorizationChecker: (any CameraCaptureAuthorizationChecking)? = nil,
        recoveryClock: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        clock: @escaping () -> Date,
        identifierGenerator: @escaping () -> UUID,
        driver: any CameraAgentServiceDriver,
        diagnosticSink: any CameraAgentDiagnosticEventSink = CameraAgentOSLogDiagnosticSink.shared
    ) {
        guard leaseTimeToLive.isFinite,
              leaseTimeToLive > 0,
              agentIdentity.processIncarnationEpoch == producerStreamEpochSeed,
              let leaseCoordinator = CameraLeaseCoordinator(
                  streamEpochSeed: producerStreamEpochSeed
              ) else {
            return nil
        }
        self.peerPolicy = peerPolicy
        self.captureLimits = captureLimits
        self.leaseTimeToLive = leaseTimeToLive
        self.agentIdentity = agentIdentity
        self.clock = clock
        self.identifierGenerator = identifierGenerator
        self.authorizationChecker = authorizationChecker
        self.recoveryClock = recoveryClock
        self.driver = driver
        self.diagnosticSink = diagnosticSink
        self.leaseCoordinator = leaseCoordinator
        stateMachine = CameraAgentStateMachine(
            authorization: initialAuthorization,
            deviceIsAvailable: initialDeviceAvailability
        )
        diagnosticSink.record(.authorizationStatus(
            status: diagnosticAuthorizationStatus(initialAuthorization),
            source: .startup
        ))
    }

    private var recoveryPolicy = CameraCaptureRecoveryPolicy()

    public func admit(
        peer: CameraAgentAuthenticatedPeer
    ) throws -> CameraAgentConnectionService {
        guard let role = peerPolicy.role(for: peer) else {
            throw CameraAgentAdmissionError.unauthorizedPeer
        }

        return try lock.withLock {
            let connectionIdentifier = try nextIdentifier(prefix: "connection")
            guard admittedConnectionIdentifiers.insert(connectionIdentifier).inserted else {
                throw CameraAgentAdmissionError.identifierExhausted
            }
            return CameraAgentConnectionService(
                owner: self,
                connectionIdentifier: connectionIdentifier,
                role: role
            )
        }
    }

    fileprivate func requestAuthorization(
        connectionIdentifier: String,
        role: CameraAgentPeerRole
    ) -> IdleScreenCameraAuthorizationReply {
        lock.withLock {
            guard admittedConnectionIdentifiers.contains(connectionIdentifier),
                  role == .companion else {
                return authorizationReply(
                    accepted: false,
                    errorCode: .notAuthorized,
                    errorMessage: "Companion authorization action required"
                )
            }

            let actions = stateMachine.handle(.visiblePermissionAction)
            perform(actions, configuration: nil)
            return authorizationReply(accepted: true, errorCode: .none, errorMessage: nil)
        }
    }

    fileprivate func authorizationStatus(
        connectionIdentifier: String
    ) -> IdleScreenCameraAuthorizationReply {
        lock.withLock {
            guard admittedConnectionIdentifiers.contains(connectionIdentifier) else {
                return IdleScreenCameraAuthorizationReply(
                    accepted: false,
                    status: .unavailable,
                    errorCode: .notAuthorized,
                    errorMessage: "Connection is not admitted"
                )!
            }
            _ = reapExpiredLeasesLocked(now: clock())
            perform(refreshAuthorizationLocked(), configuration: activeConfiguration)
            return authorizationReply(accepted: true, errorCode: .none, errorMessage: nil)
        }
    }

    fileprivate func beginStream(
        connectionIdentifier: String,
        request: IdleScreenCameraBeginStreamRequest
    ) -> IdleScreenCameraBeginStreamReply {
        lock.withLock {
            guard admittedConnectionIdentifiers.contains(connectionIdentifier) else {
                return beginStreamFailure(
                    errorCode: .notAuthorized,
                    message: "Connection is not admitted"
                )
            }
            _ = reapExpiredLeasesLocked(now: clock())
            perform(refreshAuthorizationLocked(), configuration: activeConfiguration)
            guard stateMachine.authorization == .authorized else {
                return beginStreamFailure(
                    errorCode: .notAuthorized,
                    message: "Camera authorization is required"
                )
            }

            guard leaseCoordinator.activeLeaseCount < IdleScreenCameraWire.maximumActiveLeaseCount else {
                return beginStreamFailure(
                    errorCode: .invalidRequest,
                    message: "Active camera lease limit reached"
                )
            }

            guard let predictedProducerStreamEpoch = predictedProducerStreamEpochForNextLease()
            else {
                return beginStreamFailure(
                    errorCode: .internalFailure,
                    message: "Camera producer epoch is unavailable"
                )
            }
            let configuration = activeConfiguration ?? captureLimits.clamped(
                request,
                producerStreamEpoch: predictedProducerStreamEpoch
            )
            guard configuration.producerStreamEpoch == predictedProducerStreamEpoch else {
                return beginStreamFailure(
                    errorCode: .internalFailure,
                    message: "Camera producer epoch is inconsistent"
                )
            }
            guard let transportIdentifier = activeTransportIdentifier
                    ?? driver.transportIdentifier(for: configuration),
                  IdleScreenCameraBeginStreamReply(
                    accepted: true,
                    errorCode: .none,
                    errorMessage: nil,
                    leaseIdentifier: "validation-lease",
                    producerStreamEpoch: predictedProducerStreamEpoch,
                    transportIdentifier: transportIdentifier
                  ) != nil else {
                return beginStreamFailure(
                    errorCode: .transportUnavailable,
                    message: "Camera transport is not ready"
                )
            }

            let leaseIdentifier: String
            do {
                leaseIdentifier = try nextIdentifier(prefix: "lease")
            } catch {
                return beginStreamFailure(
                    errorCode: .internalFailure,
                    message: "Lease identifier is unavailable"
                )
            }
            let now = clock()
            let previousLeaseCount = leaseCoordinator.activeLeaseCount
            guard leaseCoordinator.acquireLease(
                connection: connectionIdentifier,
                lease: leaseIdentifier,
                now: now,
                ttl: leaseTimeToLive
            ) else {
                return beginStreamFailure(
                    errorCode: .internalFailure,
                    message: "Camera lease could not be created"
                )
            }
            guard leaseCoordinator.streamEpoch == configuration.producerStreamEpoch else {
                _ = leaseCoordinator.releaseLease(
                    connection: connectionIdentifier,
                    lease: leaseIdentifier,
                    now: now
                )
                return beginStreamFailure(
                    errorCode: .internalFailure,
                    message: "Camera producer epoch changed unexpectedly"
                )
            }
            recordLeaseCountTransition(previous: previousLeaseCount)

            leaseExpirationsByConnection[connectionIdentifier, default: [:]][leaseIdentifier] =
                now.addingTimeInterval(leaseTimeToLive)
            if activeConfiguration == nil {
                activeConfiguration = configuration
                activeTransportIdentifier = transportIdentifier
            }
            let actions = stateMachine.handle(.leaseDemandChanged(
                count: leaseCoordinator.activeLeaseCount
            ))
            perform(actions, configuration: activeConfiguration)

            guard let reply = IdleScreenCameraBeginStreamReply(
                accepted: true,
                errorCode: .none,
                errorMessage: nil,
                leaseIdentifier: leaseIdentifier,
                producerStreamEpoch: configuration.producerStreamEpoch,
                transportIdentifier: activeTransportIdentifier
            ) else {
                _ = releaseLease(
                    connectionIdentifier: connectionIdentifier,
                    leaseIdentifier: leaseIdentifier,
                    now: now
                )
                return beginStreamFailure(
                    errorCode: .internalFailure,
                    message: "Camera reply could not be created"
                )
            }
            return reply
        }
    }

    fileprivate func endStream(
        connectionIdentifier: String,
        leaseIdentifier: String
    ) -> IdleScreenCameraEndStreamReply {
        lock.withLock {
            guard admittedConnectionIdentifiers.contains(connectionIdentifier),
                  releaseLease(
                    connectionIdentifier: connectionIdentifier,
                    leaseIdentifier: leaseIdentifier,
                    now: clock()
                  ) else {
                return IdleScreenCameraEndStreamReply(
                    accepted: false,
                    errorCode: .invalidRequest,
                    errorMessage: "Lease is not active for this connection"
                )!
            }
            return IdleScreenCameraEndStreamReply(
                accepted: true,
                errorCode: .none,
                errorMessage: nil
            )!
        }
    }

    fileprivate func heartbeat(
        connectionIdentifier: String,
        leaseIdentifier: String
    ) -> Bool {
        lock.withLock {
            guard admittedConnectionIdentifiers.contains(connectionIdentifier) else {
                return false
            }
            let now = clock()
            _ = reapExpiredLeasesLocked(now: now)
            guard leaseExpirationsByConnection[connectionIdentifier]?[leaseIdentifier] != nil,
                  leaseCoordinator.heartbeat(
                    connection: connectionIdentifier,
                    lease: leaseIdentifier,
                    now: now,
                    ttl: leaseTimeToLive
                  ) else {
                return false
            }
            leaseExpirationsByConnection[connectionIdentifier]?[leaseIdentifier] =
                now.addingTimeInterval(leaseTimeToLive)
            return true
        }
    }

    fileprivate func invalidate(connectionIdentifier: String) -> Int {
        lock.withLock {
            let now = clock()
            _ = reapExpiredLeasesLocked(now: now)
            guard admittedConnectionIdentifiers.remove(connectionIdentifier) != nil else {
                return 0
            }

            let reclaimed = leaseCoordinator.invalidateConnection(
                connectionIdentifier,
                now: now
            )
            let currentLeaseCount = leaseCoordinator.activeLeaseCount
            leaseExpirationsByConnection.removeValue(forKey: connectionIdentifier)
            if reclaimed > 0 {
                diagnosticSink.record(.leaseCountChanged(
                    previous: currentLeaseCount + reclaimed,
                    current: currentLeaseCount,
                    producerStreamEpoch: leaseCoordinator.streamEpoch
                ))
                synchronizeLeaseDemand()
            }
            return reclaimed
        }
    }

    @discardableResult
    public func reapExpiredLeases() -> Int {
        lock.withLock {
            reapExpiredLeasesLocked(now: clock())
        }
    }

    /// Re-reads TCC without prompting while a live consumer still wants the
    /// camera. AVFoundation exposes a current-status query but no matching
    /// authorization-change notification, so the process-lifetime one-second
    /// probe is the autonomous recovery boundary for saver-only demand.
    public func refreshAuthorizationForActiveDemand() {
        lock.withLock {
            guard stateMachine.activeLeaseDemand > 0,
                  let authorizationChecker else { return }
            let authorization = CameraAgentAuthorization(
                captureAuthorization: authorizationChecker.authorizationStatus()
            )
            guard authorization != stateMachine.authorization else { return }
            diagnosticSink.record(.authorizationStatus(
                status: diagnosticAuthorizationStatus(authorization),
                source: .statusRefresh
            ))
            perform(
                handleAuthorizationRefreshLocked(authorization),
                configuration: activeConfiguration
            )
        }
    }

    /// Delivers the result of the single permission request performed by the
    /// capture driver. Lease and permission-request events cannot be injected
    /// through this callback.
    public func receiveAuthorizationResult(_ result: CameraAgentAuthorization) {
        lock.withLock {
            let source: CameraAgentDiagnosticAuthorizationSource =
                explicitAuthorizationRequestIsOutstanding
                    ? .explicitRequestCompletion
                    : .runtimeObservation
            explicitAuthorizationRequestIsOutstanding = false
            diagnosticSink.record(.authorizationStatus(
                status: diagnosticAuthorizationStatus(result),
                source: source
            ))
            let actions = handleAuthorizationRefreshLocked(result)
            perform(actions, configuration: activeConfiguration)
        }
    }

    public func receiveCaptureDriverEvent(_ event: CameraAgentCaptureDriverEvent) {
        lock.withLock {
            let previousStatus = stateMachine.status
            let previousGeneration = stateMachine.generation
            var actions: [CameraAgentAction] = []
            if event == .wake {
                actions += refreshAuthorizationLocked()
            }
            switch event {
            case let .recoveryFailure(generation, cause, _):
                actions += stateMachine.handle(stateMachineEvent(for: event))
                actions += handleRecoveryDecisionLocked(recoveryPolicy.handle(
                    .failure(generation: generation, cause: cause),
                    now: recoveryClock()
                ))

            case let .recoveryRetryDeadlineReached(generation):
                actions += handleRecoveryDecisionLocked(recoveryPolicy.handle(
                    .retryDeadlineReached(generation: generation),
                    now: recoveryClock()
                ))

            case let .interrupted(generation):
                actions += stateMachine.handle(stateMachineEvent(for: event))
                actions += handleRecoveryDecisionLocked(recoveryPolicy.handle(
                    .failure(generation: generation, cause: .interruption),
                    now: recoveryClock()
                ))

            case let .runtimeError(generation, _):
                actions += stateMachine.handle(stateMachineEvent(for: event))
                actions += handleRecoveryDecisionLocked(recoveryPolicy.handle(
                    .failure(generation: generation, cause: .startFailure),
                    now: recoveryClock()
                ))

            case let .firstFrame(generation, _):
                actions += stateMachine.handle(stateMachineEvent(for: event))
                if stateMachine.generation == generation,
                   stateMachine.status == .streaming {
                    _ = recoveryPolicy.handle(
                        .freshFrame(generation: generation),
                        now: recoveryClock()
                    )
                }

            case .deviceUnavailable:
                actions += stateMachine.handle(stateMachineEvent(for: event))
                if let generation = recoveryPolicy.currentGeneration {
                    actions += handleRecoveryDecisionLocked(recoveryPolicy.handle(
                        .failure(generation: generation, cause: .noDevice),
                        now: recoveryClock()
                    ))
                }

            case .deviceAvailable:
                actions += stateMachine.handle(stateMachineEvent(for: event))
                if let generation = recoveryPolicy.currentGeneration {
                    actions += handleRecoveryDecisionLocked(recoveryPolicy.handle(
                        .deviceInventoryChanged(
                            generation: generation,
                            hasUsableDevice: true
                        ),
                        now: recoveryClock()
                    ))
                }

            case .captureStarted, .captureStopped, .nextFrame, .sleep, .wake:
                actions += stateMachine.handle(stateMachineEvent(for: event))
            }
            recordCaptureDriverEvent(
                event,
                previousStatus: previousStatus,
                previousGeneration: previousGeneration,
                actions: actions
            )
            perform(actions, configuration: activeConfiguration)
        }
    }

    fileprivate func diagnosticSnapshot(
        connectionIdentifier: String
    ) -> IdleScreenCameraDiagnosticSnapshot {
        lock.withLock {
            guard admittedConnectionIdentifiers.contains(connectionIdentifier) else {
                return IdleScreenCameraDiagnosticSnapshot(
                    accepted: false,
                    errorCode: .notAuthorized,
                    errorMessage: "Connection is not admitted",
                    authorizationStatus: .unavailable,
                    captureActive: false,
                    activeLeaseCount: 0,
                    producerStreamEpoch: 0,
                    summary: "unavailable"
                )!
            }
            _ = reapExpiredLeasesLocked(now: clock())

            let snapshot = CameraAgentSnapshot(
                status: stateMachine.status,
                authorization: stateMachine.authorization,
                activeLeaseDemand: stateMachine.activeLeaseDemand,
                generation: stateMachine.generation,
                sequence: stateMachine.sequence
            )
            return IdleScreenCameraDiagnosticSnapshot(
                accepted: true,
                errorCode: .none,
                errorMessage: nil,
                agentIdentity: agentIdentity,
                authorizationStatus: wireAuthorizationStatus,
                captureActive: isCaptureActive(snapshot.status)
                    && leaseCoordinator.activeLeaseCount > 0,
                activeLeaseCount: leaseCoordinator.activeLeaseCount,
                producerStreamEpoch: leaseCoordinator.streamEpoch,
                summary: diagnosticSummary(snapshot)
            )!
        }
    }

    fileprivate func cameraDeviceSnapshot(
        connectionIdentifier: String
    ) -> IdleScreenCameraDeviceSnapshotReply {
        lock.withLock {
            guard admittedConnectionIdentifiers.contains(connectionIdentifier) else {
                return cameraDeviceSnapshotFailure(
                    errorCode: .notAuthorized,
                    message: "Connection is not admitted"
                )
            }

            let runtimeSnapshot = driver.cameraDeviceSnapshot()
            let boundedDevices = Array(runtimeSnapshot.devices.prefix(
                IdleScreenCameraWire.maximumCameraDeviceCount
            ))
            let wireDevices = boundedDevices.compactMap { device in
                IdleScreenCameraDeviceDescriptor(
                    deviceIdentifier: device.uniqueID,
                    displayName: device.name,
                    kind: wireDeviceKind(device.kind)
                )
            }
            guard wireDevices.count == boundedDevices.count else {
                return cameraDeviceSnapshotFailure(
                    errorCode: .internalFailure,
                    message: "Camera inventory contains an invalid descriptor"
                )
            }

            let selection: IdleScreenCameraDeviceSelectionState?
            switch runtimeSnapshot.preference {
            case .automatic:
                selection = IdleScreenCameraDeviceSelectionState(
                    mode: .automatic,
                    deviceIdentifier: nil
                )
            case let .device(uniqueID):
                selection = IdleScreenCameraDeviceSelectionState(
                    mode: .explicitDevice,
                    deviceIdentifier: uniqueID
                )
            }
            guard let selection,
                  let reply = IdleScreenCameraDeviceSnapshotReply(
                      accepted: true,
                      errorCode: .none,
                      errorMessage: nil,
                      inventoryGeneration: runtimeSnapshot.inventoryGeneration,
                      connectedDevices: wireDevices,
                      configuredSelection: selection,
                      preferredDeviceIdentifier:
                          runtimeSnapshot.preferredDeviceIdentifier,
                      resolvedDeviceIdentifier: runtimeSnapshot.resolvedDeviceIdentifier,
                      activeDeviceIdentifier: runtimeSnapshot.activeDeviceIdentifier,
                      reconfigurationPending: runtimeSnapshot.reconfigurationPending
                  ) else {
                return cameraDeviceSnapshotFailure(
                    errorCode: .internalFailure,
                    message: "Camera inventory could not be encoded"
                )
            }
            return reply
        }
    }

    private func cameraDeviceSnapshotFailure(
        errorCode: IdleScreenCameraXPCErrorCode,
        message: String
    ) -> IdleScreenCameraDeviceSnapshotReply {
        IdleScreenCameraDeviceSnapshotReply(
            accepted: false,
            errorCode: errorCode,
            errorMessage: message,
            inventoryGeneration: 0,
            connectedDevices: [],
            configuredSelection: nil,
            preferredDeviceIdentifier: nil,
            resolvedDeviceIdentifier: nil,
            activeDeviceIdentifier: nil,
            reconfigurationPending: false
        )!
    }

    private func wireDeviceKind(
        _ kind: CameraCaptureDeviceKind
    ) -> IdleScreenCameraDeviceKind {
        switch kind {
        case .builtIn: .builtIn
        case .external: .external
        case .continuity: .continuity
        case .deskView: .deskView
        }
    }

    private func authorizationReply(
        accepted: Bool,
        errorCode: IdleScreenCameraXPCErrorCode,
        errorMessage: String?
    ) -> IdleScreenCameraAuthorizationReply {
        IdleScreenCameraAuthorizationReply(
            accepted: accepted,
            status: wireAuthorizationStatus,
            errorCode: errorCode,
            errorMessage: errorMessage
        )!
    }

    private func beginStreamFailure(
        errorCode: IdleScreenCameraXPCErrorCode,
        message: String
    ) -> IdleScreenCameraBeginStreamReply {
        IdleScreenCameraBeginStreamReply(
            accepted: false,
            errorCode: errorCode,
            errorMessage: message,
            leaseIdentifier: nil,
            producerStreamEpoch: 0,
            transportIdentifier: nil
        )!
    }

    private var wireAuthorizationStatus: IdleScreenCameraAuthorizationStatus {
        switch stateMachine.authorization {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .authorized:
            .authorized
        }
    }

    private func perform(
        _ actions: [CameraAgentAction],
        configuration: CameraAgentStreamConfiguration?
    ) {
        for action in actions {
            switch action {
            case let .configureCapture(generation):
                _ = recoveryPolicy.handle(
                    .activateAttempt(generation: generation),
                    now: recoveryClock()
                )
            case .requestPermission:
                explicitAuthorizationRequestIsOutstanding = true
            case let .startCapture(generation):
                recordCaptureEvent { epoch in
                    .captureStartRequested(
                        generation: generation,
                        producerStreamEpoch: epoch
                    )
                }
            case let .stopCapture(generation, _):
                recordCaptureEvent { epoch in
                    .captureStopRequested(
                        generation: generation,
                        producerStreamEpoch: epoch
                    )
                }
            case let .scheduleRecovery(generation, _):
                recordCaptureEvent { epoch in
                    .recoveryRetryScheduled(
                        generation: generation,
                        producerStreamEpoch: epoch
                    )
                }
            case .publish:
                break
            }
            driver.perform(action, configuration: configuration)
        }
    }

    /// Re-reads TCC state without requesting access. The only prompting path
    /// remains an authenticated companion's explicit authorization request.
    private func refreshAuthorizationLocked() -> [CameraAgentAction] {
        guard let authorizationChecker else { return [] }
        let authorization = CameraAgentAuthorization(
            captureAuthorization: authorizationChecker.authorizationStatus()
        )
        diagnosticSink.record(.authorizationStatus(
            status: diagnosticAuthorizationStatus(authorization),
            source: .statusRefresh
        ))
        return handleAuthorizationRefreshLocked(authorization)
    }

    private func handleAuthorizationRefreshLocked(
        _ authorization: CameraAgentAuthorization
    ) -> [CameraAgentAction] {
        var actions = stateMachine.handle(.permissionResult(authorization))
        guard stateMachine.activeLeaseDemand > 0,
              let generation = recoveryPolicy.currentGeneration else {
            return actions
        }
        let recoveryEvent: CameraCaptureRecoveryEvent = authorization == .authorized
            ? .authorizationRefreshed(
                generation: generation,
                authorization: authorization
            )
            : .failure(generation: generation, cause: .permissionUnavailable)
        actions += handleRecoveryDecisionLocked(recoveryPolicy.handle(
            recoveryEvent,
            now: recoveryClock()
        ))
        return actions
    }

    private func handleRecoveryDecisionLocked(
        _ decision: CameraCaptureRecoveryDecision
    ) -> [CameraAgentAction] {
        switch decision {
        case let .scheduleRetry(generation, _, _, after, _):
            return [.scheduleRecovery(generation: generation, after: after)]
        case let .retryImmediately(generation, _):
            return stateMachine.handle(.recoveryRetryReady(generation: generation))
        case .none,
             .waitForDeviceInventory,
             .waitForAuthorizationRefresh,
             .healthy,
             .ignoredStaleCallback,
             .invalidGeneration,
             .invalidTime:
            return []
        }
    }

    private func releaseLease(
        connectionIdentifier: String,
        leaseIdentifier: String,
        now: Date
    ) -> Bool {
        _ = reapExpiredLeasesLocked(now: now)
        let previousLeaseCount = leaseCoordinator.activeLeaseCount
        guard leaseCoordinator.releaseLease(
            connection: connectionIdentifier,
            lease: leaseIdentifier,
            now: now
        ) else {
            leaseExpirationsByConnection[connectionIdentifier]?.removeValue(
                forKey: leaseIdentifier
            )
            removeEmptyLeaseMap(for: connectionIdentifier)
            return false
        }

        leaseExpirationsByConnection[connectionIdentifier]?.removeValue(
            forKey: leaseIdentifier
        )
        removeEmptyLeaseMap(for: connectionIdentifier)
        recordLeaseCountTransition(previous: previousLeaseCount)
        synchronizeLeaseDemand()
        return true
    }

    private func removeEmptyLeaseMap(for connectionIdentifier: String) {
        if leaseExpirationsByConnection[connectionIdentifier]?.isEmpty == true {
            leaseExpirationsByConnection.removeValue(forKey: connectionIdentifier)
        }
    }

    private func reapExpiredLeasesLocked(now: Date) -> Int {
        let previousLeaseCount = leaseCoordinator.activeLeaseCount
        let expired = leaseCoordinator.expireLeases(now: now)
        guard expired > 0 else { return 0 }

        for connectionIdentifier in Array(leaseExpirationsByConnection.keys) {
            leaseExpirationsByConnection[connectionIdentifier] =
                leaseExpirationsByConnection[connectionIdentifier]?.filter {
                    $0.value > now
                }
            removeEmptyLeaseMap(for: connectionIdentifier)
        }
        recordLeaseCountTransition(previous: previousLeaseCount)
        synchronizeLeaseDemand()
        return expired
    }

    private func synchronizeLeaseDemand() {
        let configuration = activeConfiguration
        let actions = stateMachine.handle(.leaseDemandChanged(
            count: leaseCoordinator.activeLeaseCount
        ))
        perform(actions, configuration: configuration)
        if leaseCoordinator.activeLeaseCount == 0 {
            activeConfiguration = nil
            activeTransportIdentifier = nil
        }
    }

    private func recordLeaseCountTransition(previous: Int) {
        let current = leaseCoordinator.activeLeaseCount
        guard previous != current else { return }
        diagnosticSink.record(.leaseCountChanged(
            previous: previous,
            current: current,
            producerStreamEpoch: leaseCoordinator.streamEpoch
        ))
    }

    private func recordCaptureDriverEvent(
        _ event: CameraAgentCaptureDriverEvent,
        previousStatus: CameraAgentStatus,
        previousGeneration: UInt64,
        actions: [CameraAgentAction]
    ) {
        switch event {
        case let .captureStarted(generation):
            guard previousGeneration == generation,
                  previousStatus == .starting,
                  stateMachine.status == .awaitingFirstFrame else { return }
            recordCaptureEvent { epoch in
                .captureStarted(generation: generation, producerStreamEpoch: epoch)
            }

        case let .captureStopped(generation):
            guard previousGeneration == generation,
                  previousStatus != .idle,
                  !actions.isEmpty else { return }
            recordCaptureEvent { epoch in
                .captureStopped(generation: generation, producerStreamEpoch: epoch)
            }

        case let .firstFrame(generation, sequence):
            guard previousGeneration == generation,
                  previousStatus == .awaitingFirstFrame,
                  stateMachine.status == .streaming,
                  stateMachine.sequence == sequence else { return }
            recordCaptureEvent { epoch in
                .firstFramePublished(
                    generation: generation,
                    producerStreamEpoch: epoch,
                    sequence: sequence
                )
            }

        case let .interrupted(generation):
            guard isActiveDiagnosticCallback(
                generation: generation,
                previousGeneration: previousGeneration,
                previousStatus: previousStatus
            ) else { return }
            recordCaptureEvent { epoch in
                .captureInterrupted(generation: generation, producerStreamEpoch: epoch)
            }
            recordCaptureEvent { epoch in
                .recoveryFailure(
                    generation: generation,
                    producerStreamEpoch: epoch,
                    cause: .interruption
                )
            }

        case let .runtimeError(generation, _):
            guard isActiveDiagnosticCallback(
                generation: generation,
                previousGeneration: previousGeneration,
                previousStatus: previousStatus
            ) else { return }
            recordCaptureEvent { epoch in
                .captureRuntimeError(generation: generation, producerStreamEpoch: epoch)
            }
            recordCaptureEvent { epoch in
                .recoveryFailure(
                    generation: generation,
                    producerStreamEpoch: epoch,
                    cause: .startFailure
                )
            }

        case let .recoveryFailure(generation, cause, _):
            guard isActiveDiagnosticCallback(
                generation: generation,
                previousGeneration: previousGeneration,
                previousStatus: previousStatus
            ) else { return }
            recordCaptureEvent { epoch in
                .recoveryFailure(
                    generation: generation,
                    producerStreamEpoch: epoch,
                    cause: cause
                )
            }

        case .recoveryRetryDeadlineReached:
            guard let retryGeneration = actions.compactMap({ action -> UInt64? in
                if case let .configureCapture(retryGeneration) = action {
                    return retryGeneration
                }
                return nil
            }).first else { return }
            recordCaptureEvent { epoch in
                .recoveryRetryStarted(
                    generation: retryGeneration,
                    producerStreamEpoch: epoch
                )
            }

        case .nextFrame, .deviceUnavailable, .deviceAvailable, .sleep, .wake:
            break
        }
    }

    private func isActiveDiagnosticCallback(
        generation: UInt64,
        previousGeneration: UInt64,
        previousStatus: CameraAgentStatus
    ) -> Bool {
        guard generation == previousGeneration else { return false }
        switch previousStatus {
        case .starting, .awaitingFirstFrame, .streaming:
            return true
        case .idle, .permissionRequired, .requestingPermission, .stopping, .fallback, .failed:
            return false
        }
    }

    private func recordCaptureEvent(
        _ event: (UInt64) -> CameraAgentDiagnosticEvent
    ) {
        let epoch = leaseCoordinator.streamEpoch
        guard epoch > 0 else { return }
        diagnosticSink.record(event(epoch))
    }

    private func diagnosticAuthorizationStatus(
        _ authorization: CameraAgentAuthorization
    ) -> CameraAgentDiagnosticAuthorizationStatus {
        switch authorization {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        }
    }

    private func nextIdentifier(prefix: String) throws -> String {
        guard identifierSerial < .max else {
            throw CameraAgentAdmissionError.identifierExhausted
        }
        identifierSerial += 1
        return "\(prefix)-\(identifierGenerator().uuidString)-\(identifierSerial)"
    }

    private func predictedProducerStreamEpochForNextLease() -> UInt64? {
        leaseCoordinator.streamEpochForNextLease
    }

    private func isCaptureActive(_ status: CameraAgentStatus) -> Bool {
        switch status {
        case .starting, .awaitingFirstFrame, .streaming:
            true
        case .idle, .permissionRequired, .requestingPermission, .stopping, .fallback, .failed:
            false
        }
    }

    private func diagnosticSummary(_ snapshot: CameraAgentSnapshot) -> String {
        "status=\(statusToken(snapshot.status));authorization=\(authorizationToken(snapshot.authorization));leases=\(snapshot.activeLeaseDemand);generation=\(snapshot.generation);sequence=\(snapshot.sequence)"
    }

    private func statusToken(_ status: CameraAgentStatus) -> String {
        switch status {
        case .idle: "idle"
        case .permissionRequired: "permission-required"
        case .requestingPermission: "requesting-permission"
        case .starting: "starting"
        case .awaitingFirstFrame: "awaiting-first-frame"
        case .streaming: "streaming"
        case .stopping: "stopping"
        case let .fallback(reason): "fallback-\(fallbackToken(reason))"
        case let .failed(error): "failed-\(boundedDiagnosticToken(error.code))"
        }
    }

    private func fallbackToken(_ reason: CameraAgentFallbackReason) -> String {
        switch reason {
        case .authorizationDenied: "authorization-denied"
        case .authorizationRestricted: "authorization-restricted"
        case .deviceUnavailable: "device-unavailable"
        case .interrupted: "interrupted"
        case .sleeping: "sleeping"
        }
    }

    private func authorizationToken(_ authorization: CameraAgentAuthorization) -> String {
        switch authorization {
        case .notDetermined: "not-determined"
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        }
    }

    private func boundedDiagnosticToken(_ value: String) -> String {
        String(value.unicodeScalars.prefix(64).map { scalar in
            scalar.isASCII && scalar.value >= 0x20 ? Character(scalar) : "?"
        })
    }

    private func stateMachineEvent(
        for event: CameraAgentCaptureDriverEvent
    ) -> CameraAgentEvent {
        switch event {
        case let .captureStarted(generation):
            .captureStarted(generation: generation)
        case let .captureStopped(generation):
            .captureStopped(generation: generation)
        case let .firstFrame(generation, sequence):
            .firstFrame(generation: generation, sequence: sequence)
        case let .nextFrame(generation, sequence):
            .nextFrame(generation: generation, sequence: sequence)
        case let .interrupted(generation):
            .runtimeInterrupted(generation: generation)
        case let .runtimeError(generation, code):
            .runtimeError(
                generation: generation,
                failure: CameraAgentRuntimeError(code: code)
            )
        case let .recoveryFailure(generation, cause, code):
            switch cause {
            case .noDevice:
                .deviceUnavailable
            case .permissionUnavailable,
                 .firstFrameTimeout,
                 .frameStall,
                 .startFailure,
                 .interruption,
                 .mediaServicesReset:
                .runtimeError(
                    generation: generation,
                    failure: CameraAgentRuntimeError(code: code)
                )
            }
        case let .recoveryRetryDeadlineReached(generation):
            .recoveryRetryReady(generation: generation)
        case .deviceUnavailable:
            .deviceUnavailable
        case .deviceAvailable:
            .deviceAvailable
        case .sleep:
            .sleep
        case .wake:
            .wake
        }
    }
}

extension CameraAgentAuthorization {
    init(captureAuthorization: CameraCaptureAuthorization) {
        switch captureAuthorization {
        case .notDetermined:
            self = .notDetermined
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        }
    }
}

public final class CameraAgentConnectionService: @unchecked Sendable {
    public let role: CameraAgentPeerRole

    private weak var owner: CameraAgentService?
    fileprivate let connectionIdentifier: String

    var diagnosticConnectionIdentifier: String {
        connectionIdentifier
    }

    fileprivate init(
        owner: CameraAgentService,
        connectionIdentifier: String,
        role: CameraAgentPeerRole
    ) {
        self.owner = owner
        self.connectionIdentifier = connectionIdentifier
        self.role = role
    }

    public func requestAuthorization(
        _ request: IdleScreenCameraAuthorizationRequest
    ) -> IdleScreenCameraAuthorizationReply {
        _ = request
        guard let owner else {
            return IdleScreenCameraAuthorizationReply(
                accepted: false,
                status: .unavailable,
                errorCode: .notAuthorized,
                errorMessage: "Camera agent is unavailable"
            )!
        }
        return owner.requestAuthorization(
            connectionIdentifier: connectionIdentifier,
            role: role
        )
    }

    public func authorizationStatus(
        _ request: IdleScreenCameraStatusRequest
    ) -> IdleScreenCameraAuthorizationReply {
        _ = request
        guard let owner else {
            return IdleScreenCameraAuthorizationReply(
                accepted: false,
                status: .unavailable,
                errorCode: .notAuthorized,
                errorMessage: "Camera agent is unavailable"
            )!
        }
        return owner.authorizationStatus(connectionIdentifier: connectionIdentifier)
    }

    public func beginStream(
        _ request: IdleScreenCameraBeginStreamRequest
    ) -> IdleScreenCameraBeginStreamReply {
        guard let owner else {
            return IdleScreenCameraBeginStreamReply(
                accepted: false,
                errorCode: .notAuthorized,
                errorMessage: "Camera agent is unavailable",
                leaseIdentifier: nil,
                producerStreamEpoch: 0,
                transportIdentifier: nil
            )!
        }
        return owner.beginStream(
            connectionIdentifier: connectionIdentifier,
            request: request
        )
    }

    public func endStream(
        _ request: IdleScreenCameraEndStreamRequest
    ) -> IdleScreenCameraEndStreamReply {
        guard let owner else {
            return IdleScreenCameraEndStreamReply(
                accepted: false,
                errorCode: .notAuthorized,
                errorMessage: "Camera agent is unavailable"
            )!
        }
        return owner.endStream(
            connectionIdentifier: connectionIdentifier,
            leaseIdentifier: request.leaseIdentifier
        )
    }

    public func heartbeat(leaseIdentifier: String) -> Bool {
        guard let owner else { return false }
        return owner.heartbeat(
            connectionIdentifier: connectionIdentifier,
            leaseIdentifier: leaseIdentifier
        )
    }

    public func heartbeat(
        _ request: IdleScreenCameraHeartbeatRequest
    ) -> IdleScreenCameraHeartbeatReply {
        guard let owner else {
            return IdleScreenCameraHeartbeatReply(
                accepted: false,
                errorCode: .notAuthorized,
                errorMessage: "Camera agent is unavailable"
            )!
        }
        guard owner.heartbeat(
            connectionIdentifier: connectionIdentifier,
            leaseIdentifier: request.leaseIdentifier
        ) else {
            return IdleScreenCameraHeartbeatReply(
                accepted: false,
                errorCode: .invalidRequest,
                errorMessage: "Lease is not active for this connection"
            )!
        }
        return IdleScreenCameraHeartbeatReply(
            accepted: true,
            errorCode: .none,
            errorMessage: nil
        )!
    }

    /// Reclaims every lease created by this connection. The listener's
    /// invalidation handler should call this exactly once; repeated calls are
    /// harmless and reclaim no additional demand.
    @discardableResult
    public func invalidate() -> Int {
        guard let owner else { return 0 }
        return owner.invalidate(connectionIdentifier: connectionIdentifier)
    }

    public func diagnosticSnapshot(
        _ request: IdleScreenCameraDiagnosticRequest
    ) -> IdleScreenCameraDiagnosticSnapshot {
        _ = request
        guard let owner else {
            return IdleScreenCameraDiagnosticSnapshot(
                accepted: false,
                errorCode: .notAuthorized,
                errorMessage: "Camera agent is unavailable",
                authorizationStatus: .unavailable,
                captureActive: false,
                activeLeaseCount: 0,
                producerStreamEpoch: 0,
                summary: "unavailable"
            )!
        }
        return owner.diagnosticSnapshot(connectionIdentifier: connectionIdentifier)
    }

    public func cameraDeviceSnapshot(
        _ request: IdleScreenCameraStatusRequest
    ) -> IdleScreenCameraDeviceSnapshotReply {
        _ = request
        guard role == .companion else {
            return IdleScreenCameraDeviceSnapshotReply(
                accepted: false,
                errorCode: .notAuthorized,
                errorMessage: "Companion camera inventory action required",
                inventoryGeneration: 0,
                connectedDevices: [],
                configuredSelection: nil,
                resolvedDeviceIdentifier: nil,
                activeDeviceIdentifier: nil,
                reconfigurationPending: false
            )!
        }
        guard let owner else {
            return IdleScreenCameraDeviceSnapshotReply(
                accepted: false,
                errorCode: .notAuthorized,
                errorMessage: "Camera agent is unavailable",
                inventoryGeneration: 0,
                connectedDevices: [],
                configuredSelection: nil,
                resolvedDeviceIdentifier: nil,
                activeDeviceIdentifier: nil,
                reconfigurationPending: false
            )!
        }
        return owner.cameraDeviceSnapshot(
            connectionIdentifier: connectionIdentifier
        )
    }
}
