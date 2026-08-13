import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Serialized camera agent capture reducer")
struct CameraAgentStateMachineTests {
    @Test("camera permission is requested only by an explicit visible action")
    func permissionRequiresVisibleAction() {
        var machine = CameraAgentStateMachine(authorization: .notDetermined)

        #expect(machine.handle(.leaseDemandChanged(count: 1)) == [
            .publish(snapshot(
                status: .permissionRequired,
                authorization: .notDetermined,
                demand: 1
            )),
        ])
        #expect(machine.handle(.visiblePermissionAction) == [
            .requestPermission,
            .publish(snapshot(
                status: .requestingPermission,
                authorization: .notDetermined,
                demand: 1
            )),
        ])
        #expect(machine.handle(.visiblePermissionAction) == [])
    }

    @Test("authorization starts one configured generation when demand already exists")
    func authorizationStartsPendingDemand() {
        var machine = CameraAgentStateMachine(authorization: .notDetermined)
        _ = machine.handle(.leaseDemandChanged(count: 1))
        _ = machine.handle(.visiblePermissionAction)

        #expect(machine.handle(.permissionResult(.authorized)) == [
            .configureCapture(generation: 1),
            .startCapture(generation: 1),
            .publish(snapshot(
                status: .starting,
                authorization: .authorized,
                demand: 1,
                generation: 1
            )),
        ])
        #expect(machine.generation == 1)
    }

    @Test("multiple leases neither multiply starts nor let one release stop capture")
    func leaseDemandIsCoalesced() {
        var machine = CameraAgentStateMachine(authorization: .authorized)

        #expect(machine.handle(.leaseDemandChanged(count: 1)).prefix(2) == [
            .configureCapture(generation: 1),
            .startCapture(generation: 1),
        ])
        #expect(machine.handle(.leaseDemandChanged(count: 3)) == [
            .publish(snapshot(
                status: .starting,
                authorization: .authorized,
                demand: 3,
                generation: 1
            )),
        ])
        #expect(machine.handle(.leaseDemandChanged(count: 2)) == [
            .publish(snapshot(
                status: .starting,
                authorization: .authorized,
                demand: 2,
                generation: 1
            )),
        ])
        #expect(machine.generation == 1)
    }

    @Test("session start waits for the first frame before publishing streaming")
    func firstFrameDefinesReadiness() {
        var machine = CameraAgentStateMachine(authorization: .authorized)
        _ = machine.handle(.leaseDemandChanged(count: 1))

        #expect(machine.handle(.captureStarted(generation: 1)) == [
            .publish(snapshot(
                status: .awaitingFirstFrame,
                authorization: .authorized,
                demand: 1,
                generation: 1
            )),
        ])
        #expect(machine.status == .awaitingFirstFrame)
        #expect(machine.handle(.nextFrame(generation: 1, sequence: 1)) == [])

        #expect(machine.handle(.firstFrame(generation: 1, sequence: 1)) == [
            .publish(snapshot(
                status: .streaming,
                authorization: .authorized,
                demand: 1,
                generation: 1,
                sequence: 1
            )),
        ])
        #expect(machine.status == .streaming)
    }

    @Test("only increasing frames from the current generation are published")
    func staleFramesAreIgnored() {
        var machine = streamingMachine()

        #expect(machine.handle(.nextFrame(generation: 1, sequence: 2)) == [
            .publish(snapshot(
                status: .streaming,
                authorization: .authorized,
                demand: 1,
                generation: 1,
                sequence: 2
            )),
        ])
        #expect(machine.handle(.nextFrame(generation: 1, sequence: 2)) == [])
        #expect(machine.handle(.nextFrame(generation: 1, sequence: 1)) == [])
        #expect(machine.handle(.nextFrame(generation: 99, sequence: 3)) == [])
    }

    @Test("final demand emits one bounded stop and duplicate releases are ignored")
    func finalDemandStopsOnce() {
        var machine = streamingMachine(demand: 2)
        _ = machine.handle(.leaseDemandChanged(count: 1))

        #expect(machine.handle(.leaseDemandChanged(count: 0)) == [
            .stopCapture(generation: 1, within: 2),
            .publish(snapshot(
                status: .stopping,
                authorization: .authorized,
                demand: 0,
                generation: 1,
                sequence: 1
            )),
        ])
        #expect(machine.handle(.leaseDemandChanged(count: 0)) == [])
        #expect(machine.handle(.captureStopped(generation: 1)) == [
            .publish(snapshot(
                status: .idle,
                authorization: .authorized,
                demand: 0,
                generation: 1
            )),
        ])
        #expect(machine.handle(.captureStopped(generation: 1)) == [])
    }

    @Test("an interruption waits for a fenced recovery signal before reconfiguring")
    func interruptionWaitsForRecoverySignal() {
        var machine = streamingMachine()

        #expect(machine.handle(.runtimeInterrupted(generation: 1)) == [
            .publish(snapshot(
                status: .fallback(.interrupted),
                authorization: .authorized,
                demand: 1,
                generation: 1,
                sequence: 1
            )),
            .stopCapture(generation: 1, within: 2),
        ])
        #expect(machine.handle(.runtimeInterrupted(generation: 1)) == [])
        #expect(machine.handle(.captureStopped(generation: 1)) == [
            .publish(snapshot(
                status: .fallback(.interrupted),
                authorization: .authorized,
                demand: 1,
                generation: 1
            )),
        ])
        #expect(machine.handle(.recoveryRetryReady(generation: 99)) == [])
        #expect(machine.handle(.recoveryRetryReady(generation: 1)) == [
            .configureCapture(generation: 2),
            .startCapture(generation: 2),
            .publish(snapshot(
                status: .starting,
                authorization: .authorized,
                demand: 1,
                generation: 2
            )),
        ])
    }

    @Test("a runtime error remains failed until bounded recovery becomes ready")
    func runtimeErrorWaitsForRecoverySignal() {
        var machine = streamingMachine()
        let failure = CameraAgentRuntimeError(code: "media-services-reset")

        #expect(machine.handle(.runtimeError(generation: 1, failure: failure)) == [
            .publish(snapshot(
                status: .failed(failure),
                authorization: .authorized,
                demand: 1,
                generation: 1,
                sequence: 1
            )),
            .stopCapture(generation: 1, within: 2),
        ])
        #expect(machine.handle(.captureStopped(generation: 1)) == [
            .publish(snapshot(
                status: .failed(failure),
                authorization: .authorized,
                demand: 1,
                generation: 1
            )),
        ])
        #expect(machine.handle(.recoveryRetryReady(generation: 1)).prefix(2) == [
            .configureCapture(generation: 2),
            .startCapture(generation: 2),
        ])
    }

    @Test("device loss waits for availability before reconfiguring")
    func deviceAvailabilityControlsRestart() {
        var machine = streamingMachine()

        #expect(machine.handle(.deviceUnavailable) == [
            .publish(snapshot(
                status: .fallback(.deviceUnavailable),
                authorization: .authorized,
                demand: 1,
                generation: 1,
                sequence: 1
            )),
            .stopCapture(generation: 1, within: 2),
        ])
        #expect(machine.handle(.captureStopped(generation: 1)) == [
            .publish(snapshot(
                status: .fallback(.deviceUnavailable),
                authorization: .authorized,
                demand: 1,
                generation: 1
            )),
        ])
        #expect(machine.handle(.deviceAvailable) == [
            .publish(snapshot(
                status: .fallback(.deviceUnavailable),
                authorization: .authorized,
                demand: 1,
                generation: 1
            )),
        ])
        #expect(machine.handle(.deviceAvailable) == [])
        #expect(machine.handle(.recoveryRetryReady(generation: 1)) == [
            .configureCapture(generation: 2),
            .startCapture(generation: 2),
            .publish(snapshot(
                status: .starting,
                authorization: .authorized,
                demand: 1,
                generation: 2
            )),
        ])
    }

    @Test("sleep stops capture and wake restarts only when demand remains")
    func sleepWakeReconcilesDemand() {
        var demanded = streamingMachine()

        #expect(demanded.handle(.sleep) == [
            .publish(snapshot(
                status: .fallback(.sleeping),
                authorization: .authorized,
                demand: 1,
                generation: 1,
                sequence: 1
            )),
            .stopCapture(generation: 1, within: 2),
        ])
        _ = demanded.handle(.captureStopped(generation: 1))
        #expect(demanded.handle(.wake).prefix(2) == [
            .configureCapture(generation: 2),
            .startCapture(generation: 2),
        ])

        var released = streamingMachine()
        _ = released.handle(.sleep)
        _ = released.handle(.leaseDemandChanged(count: 0))
        _ = released.handle(.captureStopped(generation: 1))
        #expect(released.handle(.wake) == [])
        #expect(released.status == .idle)
    }

    @Test("denied and restricted authorization never start capture")
    func unavailableAuthorizationFallsBack() {
        for (authorization, reason) in [
            (CameraAgentAuthorization.denied, CameraAgentFallbackReason.authorizationDenied),
            (.restricted, .authorizationRestricted),
        ] {
            var machine = CameraAgentStateMachine(authorization: authorization)
            #expect(machine.handle(.leaseDemandChanged(count: 1)) == [
                .publish(snapshot(
                    status: .fallback(reason),
                    authorization: authorization,
                    demand: 1
                )),
            ])
            #expect(machine.handle(.visiblePermissionAction) == [])
            #expect(machine.generation == 0)
        }
    }

    @Test("stale callbacks cannot stop or revive a newer generation")
    func staleCaptureCallbacksAreIgnored() {
        var machine = streamingMachine()
        _ = machine.handle(.runtimeInterrupted(generation: 1))
        _ = machine.handle(.captureStopped(generation: 1))
        _ = machine.handle(.recoveryRetryReady(generation: 1))

        #expect(machine.generation == 2)
        #expect(machine.handle(.captureStarted(generation: 1)) == [])
        #expect(machine.handle(.captureStopped(generation: 1)) == [])
        #expect(machine.handle(.firstFrame(generation: 1, sequence: 100)) == [])
        #expect(machine.handle(.runtimeError(
            generation: 1,
            failure: CameraAgentRuntimeError(code: "stale")
        )) == [])
        #expect(machine.status == .starting)
    }

    @Test("negative lease demand is rejected without mutation")
    func negativeDemandIsIgnored() {
        var machine = CameraAgentStateMachine(authorization: .authorized)

        #expect(machine.handle(.leaseDemandChanged(count: -1)) == [])
        #expect(machine.activeLeaseDemand == 0)
        #expect(machine.generation == 0)
        #expect(machine.status == .idle)
    }

}

private func snapshot(
    status: CameraAgentStatus,
    authorization: CameraAgentAuthorization,
    demand: Int,
    generation: UInt64 = 0,
    sequence: UInt64 = 0
) -> CameraAgentSnapshot {
    CameraAgentSnapshot(
        status: status,
        authorization: authorization,
        activeLeaseDemand: demand,
        generation: generation,
        sequence: sequence
    )
}

private func streamingMachine(demand: Int = 1) -> CameraAgentStateMachine {
    var machine = CameraAgentStateMachine(authorization: .authorized)
    _ = machine.handle(.leaseDemandChanged(count: demand))
    _ = machine.handle(.captureStarted(generation: 1))
    _ = machine.handle(.firstFrame(generation: 1, sequence: 1))
    return machine
}
