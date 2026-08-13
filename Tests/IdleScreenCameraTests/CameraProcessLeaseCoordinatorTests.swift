import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Camera process lease coordinator", .serialized)
struct CameraProcessLeaseCoordinatorTests {
    @Test("the first view starts one process lease and the final view stops it")
    func firstAndFinalViewOwnTheProcessLease() throws {
        let controller = RecordingProcessLeaseController()
        let coordinator = try #require(CameraProcessLeaseCoordinator(controller: controller))

        #expect(coordinator.attach(consumerIdentifier: "display-a"))
        #expect(coordinator.attach(consumerIdentifier: "display-b"))
        #expect(controller.operations == [.start])
        #expect(coordinator.activeConsumerCount == 2)

        #expect(coordinator.detach(consumerIdentifier: "display-a"))
        #expect(controller.operations == [.start])
        #expect(coordinator.activeConsumerCount == 1)

        #expect(coordinator.detach(consumerIdentifier: "display-b"))
        #expect(controller.operations == [.start, .stop])
        #expect(coordinator.activeConsumerCount == 0)
    }

    @Test("duplicate attachment and unknown detachment are idempotent")
    func duplicateAndUnknownConsumersAreIdempotent() throws {
        let controller = RecordingProcessLeaseController()
        let coordinator = try #require(CameraProcessLeaseCoordinator(controller: controller))

        #expect(coordinator.attach(consumerIdentifier: "preview"))
        #expect(!coordinator.attach(consumerIdentifier: "preview"))
        #expect(!coordinator.detach(consumerIdentifier: "not-present"))
        #expect(coordinator.activeConsumerCount == 1)
        #expect(controller.operations == [.start])

        #expect(coordinator.detach(consumerIdentifier: "preview"))
        #expect(!coordinator.detach(consumerIdentifier: "preview"))
        #expect(controller.operations == [.start, .stop])
    }

    @Test("invalid identifiers cannot create camera demand")
    func invalidIdentifiersFailClosed() throws {
        let controller = RecordingProcessLeaseController()
        let coordinator = try #require(CameraProcessLeaseCoordinator(controller: controller))

        for identifier in ["", "   ", String(repeating: "x", count: 129)] {
            #expect(!coordinator.attach(consumerIdentifier: identifier))
        }

        #expect(coordinator.activeConsumerCount == 0)
        #expect(controller.operations.isEmpty)
    }

    @Test("consumer capacity is bounded without disturbing existing demand")
    func boundedConsumerCapacity() throws {
        let controller = RecordingProcessLeaseController()
        let coordinator = try #require(CameraProcessLeaseCoordinator(
            controller: controller,
            maximumConsumerCount: 2
        ))

        #expect(coordinator.attach(consumerIdentifier: "a"))
        #expect(coordinator.attach(consumerIdentifier: "b"))
        #expect(!coordinator.attach(consumerIdentifier: "c"))
        #expect(coordinator.activeConsumerCount == 2)
        #expect(controller.operations == [.start])
    }

    @Test("invalid capacity is rejected before it can alter lease demand")
    func invalidCapacityIsRejected() {
        let controller = RecordingProcessLeaseController()

        #expect(CameraProcessLeaseCoordinator(
            controller: controller,
            maximumConsumerCount: 0
        ) == nil)
        #expect(CameraProcessLeaseCoordinator(
            controller: controller,
            maximumConsumerCount: IdleScreenCameraWire.maximumActiveLeaseCount + 1
        ) == nil)
        #expect(controller.operations.isEmpty)
    }
}

private final class RecordingProcessLeaseController: CameraProcessLeaseControlling,
    @unchecked Sendable
{
    enum Operation: Equatable {
        case start
        case stop
    }

    private(set) var operations: [Operation] = []

    func start() {
        operations.append(.start)
    }

    func stop() {
        operations.append(.stop)
    }
}
