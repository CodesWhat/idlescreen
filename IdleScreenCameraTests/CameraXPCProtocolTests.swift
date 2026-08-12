import Foundation
import Testing
@testable import IdleScreenCamera

@Suite("Camera XPC wire contract")
struct CameraXPCProtocolTests {
    @Test("every request has a strict secure-coding round trip")
    func requestRoundTrips() throws {
        let status = try #require(IdleScreenCameraStatusRequest())
        let authorization = try #require(IdleScreenCameraAuthorizationRequest())
        let begin = try #require(
            IdleScreenCameraBeginStreamRequest(
                maximumWidth: 1_280,
                maximumHeight: 720,
                maximumFramesPerSecond: 30,
                mailboxSlotCount: 3
            )
        )
        let end = try #require(
            IdleScreenCameraEndStreamRequest(leaseIdentifier: "lease_Qk7p-2")
        )
        let diagnostic = try #require(IdleScreenCameraDiagnosticRequest())

        let decodedStatus = try secureRoundTrip(status)
        let decodedAuthorization = try secureRoundTrip(authorization)
        let decodedBegin = try secureRoundTrip(begin)
        let decodedEnd = try secureRoundTrip(end)
        let decodedDiagnostic = try secureRoundTrip(diagnostic)

        #expect(decodedStatus.schemaVersion == IdleScreenCameraWire.currentSchemaVersion)
        #expect(decodedAuthorization.schemaVersion == IdleScreenCameraWire.currentSchemaVersion)
        #expect(decodedBegin.maximumWidth == 1_280)
        #expect(decodedBegin.maximumHeight == 720)
        #expect(decodedBegin.maximumFramesPerSecond == 30)
        #expect(decodedBegin.mailboxSlotCount == 3)
        #expect(decodedEnd.leaseIdentifier == "lease_Qk7p-2")
        #expect(decodedDiagnostic.schemaVersion == IdleScreenCameraWire.currentSchemaVersion)
    }

    @Test("authorization and operation replies have strict secure-coding round trips")
    func simpleReplyRoundTrips() throws {
        let authorization = try #require(
            IdleScreenCameraAuthorizationReply(
                accepted: true,
                status: .authorized,
                errorCode: .none,
                errorMessage: nil
            )
        )
        let operation = try #require(
            IdleScreenCameraEndStreamReply(
                accepted: false,
                errorCode: .notAuthorized,
                errorMessage: "Camera permission has not been granted."
            )
        )

        let decodedAuthorization = try secureRoundTrip(authorization)
        let decodedOperation = try secureRoundTrip(operation)

        #expect(decodedAuthorization.accepted)
        #expect(decodedAuthorization.status == .authorized)
        #expect(decodedAuthorization.errorCode == .none)
        #expect(decodedAuthorization.errorMessage == nil)
        #expect(!decodedOperation.accepted)
        #expect(decodedOperation.errorCode == .notAuthorized)
        #expect(decodedOperation.errorMessage == "Camera permission has not been granted.")
    }

    @Test("an accepted stream reply carries only a bounded capability and relative transport identity")
    func acceptedStreamReplyRoundTrip() throws {
        let reply = try #require(
            IdleScreenCameraBeginStreamReply(
                accepted: true,
                errorCode: .none,
                errorMessage: nil,
                leaseIdentifier: "lease_A9t-4x",
                producerStreamEpoch: 9,
                transportIdentifier: "mailboxes/stream_A9t-4x"
            )
        )

        let decoded = try secureRoundTrip(reply)

        #expect(decoded.accepted)
        #expect(decoded.errorCode == .none)
        #expect(decoded.leaseIdentifier == "lease_A9t-4x")
        #expect(decoded.producerStreamEpoch == 9)
        #expect(decoded.transportIdentifier == "mailboxes/stream_A9t-4x")
    }

    @Test("the diagnostic snapshot has fixed, bounded metadata and a strict round trip")
    func diagnosticSnapshotRoundTrip() throws {
        let identity = try #require(agentIdentity())
        let snapshot = try #require(
            IdleScreenCameraDiagnosticSnapshot(
                accepted: true,
                errorCode: .none,
                errorMessage: nil,
                agentIdentity: identity,
                authorizationStatus: .authorized,
                captureActive: true,
                activeLeaseCount: 2,
                producerStreamEpoch: 11,
                summary: "camera=FaceTime HD; state=streaming"
            )
        )

        let decoded = try secureRoundTrip(snapshot)

        #expect(decoded.accepted)
        #expect(decoded.authorizationStatus == .authorized)
        #expect(decoded.captureActive)
        #expect(decoded.activeLeaseCount == 2)
        #expect(decoded.producerStreamEpoch == 11)
        #expect(decoded.summary == "camera=FaceTime HD; state=streaming")
        #expect(decoded.agentIdentity == identity)
    }

    @Test("the agent identity has a strict secure-coding round trip")
    func agentIdentityRoundTrip() throws {
        let identity = try #require(agentIdentity())

        let decoded = try secureRoundTrip(identity)

        #expect(decoded == identity)
        #expect(decoded.processIdentifier == 4_242)
        #expect(decoded.processIncarnationEpoch == 70_001)
        #expect(decoded.bundleIdentifier == "com.idlescreen.camera-agent")
        #expect(decoded.serviceIdentifier == "group.com.idlescreen.shared.camera-agent")
        #expect(decoded.sourceAppPath == "/Applications/idlescreen.app")
    }

    @Test("malformed agent identity evidence is rejected before use")
    func rejectsMalformedAgentIdentityEvidence() {
        #expect(agentIdentity(processIdentifier: 0) == nil)
        #expect(agentIdentity(processIncarnationEpoch: 0) == nil)
        #expect(agentIdentity(bundleIdentifier: "com..idlescreen") == nil)
        #expect(agentIdentity(serviceIdentifier: "camera-agent") == nil)
        #expect(agentIdentity(bundleVersion: "") == nil)
        #expect(agentIdentity(marketingVersion: "0.1\nforeign") == nil)
        #expect(agentIdentity(signingIdentifier: "invalid signing identifier") == nil)
        #expect(agentIdentity(teamIdentifier: "wrongteam1") == nil)
        #expect(agentIdentity(codeDirectoryHash: String(repeating: "g", count: 40)) == nil)
        #expect(agentIdentity(executableSHA256: String(repeating: "a", count: 63)) == nil)
        #expect(agentIdentity(launchAgentSHA256: String(repeating: "b", count: 65)) == nil)
        #expect(agentIdentity(provisioningProfileSHA256: String(repeating: "z", count: 64)) == nil)
        #expect(agentIdentity(sourceAppPath: "relative/idlescreen.app") == nil)
        #expect(agentIdentity(sourceAppPath: "/Applications/../tmp/idlescreen.app") == nil)
        #expect(agentIdentity(sourceAppPath: "/Applications/idlescreen") == nil)
    }

    @Test("only a successful diagnostic snapshot requires agent identity")
    func diagnosticSnapshotIdentityInvariant() throws {
        #expect(IdleScreenCameraDiagnosticSnapshot(
            accepted: true,
            errorCode: .none,
            errorMessage: nil,
            agentIdentity: nil,
            authorizationStatus: .authorized,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "idle"
        ) == nil)

        let rejected = try #require(IdleScreenCameraDiagnosticSnapshot(
            accepted: false,
            errorCode: .notAuthorized,
            errorMessage: "Connection is not admitted",
            agentIdentity: nil,
            authorizationStatus: .unavailable,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "unavailable"
        ))
        #expect(rejected.agentIdentity == nil)

        let identifiedRejection = try #require(IdleScreenCameraDiagnosticSnapshot(
            accepted: false,
            errorCode: .notAuthorized,
            errorMessage: "Request is not admitted",
            agentIdentity: agentIdentity(),
            authorizationStatus: .unavailable,
            captureActive: false,
            activeLeaseCount: 0,
            producerStreamEpoch: 0,
            summary: "unavailable"
        ))
        #expect(identifiedRejection.agentIdentity != nil)
    }

    @Test("agent identity correlates only with the exact kernel-observed remote PID")
    func agentIdentityMatchesRemoteProcess() throws {
        let identity = try #require(agentIdentity())

        #expect(identity.matches(remoteProcessIdentifier: 4_242))
        #expect(!identity.matches(remoteProcessIdentifier: 4_243))
        #expect(!identity.matches(remoteProcessIdentifier: 0))
    }

    @Test("future schemas and allocation-shaped requests are rejected before use")
    func rejectsFutureAndOversizedRequests() {
        let future = IdleScreenCameraWire.currentSchemaVersion + 1

        #expect(IdleScreenCameraStatusRequest(schemaVersion: future) == nil)
        #expect(IdleScreenCameraAuthorizationRequest(schemaVersion: future) == nil)
        #expect(
            IdleScreenCameraBeginStreamRequest(
                schemaVersion: future,
                maximumWidth: 640,
                maximumHeight: 480,
                maximumFramesPerSecond: 30,
                mailboxSlotCount: 3
            ) == nil
        )
        #expect(IdleScreenCameraEndStreamRequest(schemaVersion: future, leaseIdentifier: "lease_1") == nil)
        #expect(IdleScreenCameraDiagnosticRequest(schemaVersion: future) == nil)

        #expect(
            IdleScreenCameraBeginStreamRequest(
                maximumWidth: IdleScreenCameraWire.maximumWidth + 1,
                maximumHeight: 1,
                maximumFramesPerSecond: 1,
                mailboxSlotCount: 1
            ) == nil
        )
        #expect(
            IdleScreenCameraBeginStreamRequest(
                maximumWidth: 1,
                maximumHeight: IdleScreenCameraWire.maximumHeight + 1,
                maximumFramesPerSecond: 1,
                mailboxSlotCount: 1
            ) == nil
        )
        #expect(
            IdleScreenCameraBeginStreamRequest(
                maximumWidth: 1,
                maximumHeight: 1,
                maximumFramesPerSecond: IdleScreenCameraWire.maximumFramesPerSecond + 1,
                mailboxSlotCount: 1
            ) == nil
        )
        #expect(
            IdleScreenCameraBeginStreamRequest(
                maximumWidth: 1,
                maximumHeight: 1,
                maximumFramesPerSecond: 1,
                mailboxSlotCount: IdleScreenCameraWire.maximumMailboxSlotCount + 1
            ) == nil
        )
    }

    @Test("lease, transport, and diagnostic text limits reject malformed wire values")
    func rejectsMalformedStrings() {
        let longLease = String(repeating: "a", count: IdleScreenCameraWire.maximumLeaseIdentifierUTF8ByteCount + 1)
        let longSummary = String(repeating: "s", count: IdleScreenCameraWire.maximumDiagnosticSummaryUTF8ByteCount + 1)

        #expect(IdleScreenCameraEndStreamRequest(leaseIdentifier: "../another-connection") == nil)
        #expect(IdleScreenCameraEndStreamRequest(leaseIdentifier: longLease) == nil)
        #expect(
            IdleScreenCameraBeginStreamReply(
                accepted: true,
                errorCode: .none,
                errorMessage: nil,
                leaseIdentifier: "lease_1",
                producerStreamEpoch: 1,
                transportIdentifier: "/tmp/absolute-mailbox"
            ) == nil
        )
        #expect(
            IdleScreenCameraBeginStreamReply(
                accepted: true,
                errorCode: .none,
                errorMessage: nil,
                leaseIdentifier: "lease_1",
                producerStreamEpoch: 1,
                transportIdentifier: "mailboxes/../other"
            ) == nil
        )
        #expect(
            IdleScreenCameraDiagnosticSnapshot(
                accepted: true,
                errorCode: .none,
                errorMessage: nil,
                agentIdentity: agentIdentity(),
                authorizationStatus: .authorized,
                captureActive: false,
                activeLeaseCount: 0,
                producerStreamEpoch: 0,
                summary: longSummary
            ) == nil
        )
    }

    @Test("success and failure reply invariants cannot be contradicted")
    func replyInvariants() {
        #expect(
            IdleScreenCameraBeginStreamReply(
                accepted: true,
                errorCode: .none,
                errorMessage: nil,
                leaseIdentifier: "lease_1",
                producerStreamEpoch: 0,
                transportIdentifier: "mailboxes/stream_1"
            ) == nil
        )
        #expect(
            IdleScreenCameraBeginStreamReply(
                accepted: false,
                errorCode: .none,
                errorMessage: nil,
                leaseIdentifier: nil,
                producerStreamEpoch: 0,
                transportIdentifier: nil
            ) == nil
        )
        #expect(
            IdleScreenCameraEndStreamReply(
                accepted: true,
                errorCode: .internalFailure,
                errorMessage: "contradiction"
            ) == nil
        )
        #expect(
            IdleScreenCameraDiagnosticSnapshot(
                accepted: true,
                errorCode: .none,
                errorMessage: nil,
                agentIdentity: agentIdentity(),
                authorizationStatus: .authorized,
                captureActive: true,
                activeLeaseCount: 0,
                producerStreamEpoch: 0,
                summary: "contradiction"
            ) == nil
        )
    }

    @Test("request DTOs carry no caller identity claims or frame payloads")
    func requestsCarryNoIdentityClaimsOrFrames() throws {
        let requests: [NSObject] = [
            try #require(IdleScreenCameraStatusRequest()),
            try #require(IdleScreenCameraAuthorizationRequest()),
            try #require(
                IdleScreenCameraBeginStreamRequest(
                    maximumWidth: 640,
                    maximumHeight: 480,
                    maximumFramesPerSecond: 30,
                    mailboxSlotCount: 3
                )
            ),
            try #require(IdleScreenCameraEndStreamRequest(leaseIdentifier: "lease_1")),
            try #require(IdleScreenCameraDiagnosticRequest()),
        ]

        for request in requests {
            let labels = Set(Mirror(reflecting: request).children.compactMap(\.label))
            #expect(labels.isDisjoint(with: ["pid", "processIdentifier", "teamIdentifier", "bundleIdentifier"]))
            #expect(Mirror(reflecting: request).children.allSatisfy { !($0.value is Data) })
        }
    }

    @Test("the protocol is directly consumable by NSXPCInterface")
    func objectiveCXPCSurface() {
        let interface = NSXPCInterface(with: IdleScreenCameraXPCProtocol.self)

        #expect(NSStringFromProtocol(interface.protocol) == "IdleScreenCameraXPCProtocol")
    }

    @Test("a bounded heartbeat renews one opaque lease over the XPC contract")
    func heartbeatRoundTrip() throws {
        let request = try #require(
            IdleScreenCameraHeartbeatRequest(leaseIdentifier: "lease_heartbeat-1")
        )
        let reply = try #require(
            IdleScreenCameraHeartbeatReply(
                accepted: true,
                errorCode: .none,
                errorMessage: nil
            )
        )

        let decodedRequest = try secureRoundTrip(request)
        let decodedReply = try secureRoundTrip(reply)

        #expect(decodedRequest.leaseIdentifier == "lease_heartbeat-1")
        #expect(decodedReply.accepted)
        #expect(decodedReply.errorCode == .none)
        #expect(
            IdleScreenCameraHeartbeatRequest(leaseIdentifier: "../foreign-lease") == nil
        )
    }

    @Test("secure decoding rejects future schemas and non-NSString lease payloads")
    func secureDecoderRejectsMalformedArchives() throws {
        let futureSchemaArchive = try mappedArchive(
            FutureSchemaPayload(schemaVersion: IdleScreenCameraWire.currentSchemaVersion + 1),
            as: IdleScreenCameraStatusRequest.self
        )
        let wrongLeaseClassArchive = try mappedArchive(
            WrongLeaseClassPayload(
                schemaVersion: IdleScreenCameraWire.currentSchemaVersion,
                leasePayload: Data("not-a-string".utf8)
            ),
            as: IdleScreenCameraEndStreamRequest.self
        )

        #expect(archiveIsRejected(futureSchemaArchive, as: IdleScreenCameraStatusRequest.self))
        #expect(archiveIsRejected(wrongLeaseClassArchive, as: IdleScreenCameraEndStreamRequest.self))
    }

    private func secureRoundTrip<Value: NSObject & NSSecureCoding>(_ value: Value) throws -> Value {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: value,
            requiringSecureCoding: true
        )
        let decoded = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: Value.self,
            from: data
        )
        return try #require(decoded)
    }

    private func agentIdentity(
        processIdentifier: Int32 = 4_242,
        processIncarnationEpoch: UInt64 = 70_001,
        bundleIdentifier: String = "com.idlescreen.camera-agent",
        serviceIdentifier: String = "group.com.idlescreen.shared.camera-agent",
        bundleVersion: String = "1",
        marketingVersion: String = "0.1",
        signingIdentifier: String = "com.idlescreen.camera-agent",
        teamIdentifier: String = "3524374A2S",
        codeDirectoryHash: String = String(repeating: "1", count: 40),
        executableSHA256: String = String(repeating: "a", count: 64),
        launchAgentSHA256: String = String(repeating: "b", count: 64),
        provisioningProfileSHA256: String = String(repeating: "c", count: 64),
        sourceAppPath: String = "/Applications/idlescreen.app"
    ) -> IdleScreenCameraAgentIdentity? {
        IdleScreenCameraAgentIdentity(
            processIdentifier: processIdentifier,
            processIncarnationEpoch: processIncarnationEpoch,
            bundleIdentifier: bundleIdentifier,
            serviceIdentifier: serviceIdentifier,
            bundleVersion: bundleVersion,
            marketingVersion: marketingVersion,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            codeDirectoryHash: codeDirectoryHash,
            executableSHA256: executableSHA256,
            launchAgentSHA256: launchAgentSHA256,
            provisioningProfileSHA256: provisioningProfileSHA256,
            sourceAppPath: sourceAppPath
        )
    }

    private func mappedArchive<Payload: NSObject & NSSecureCoding, Value: NSObject & NSSecureCoding>(
        _ payload: Payload,
        as valueType: Value.Type
    ) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName(NSStringFromClass(valueType), for: Payload.self)
        archiver.encode(payload, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private func archiveIsRejected<Value: NSObject & NSSecureCoding>(
        _ archive: Data,
        as valueType: Value.Type
    ) -> Bool {
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: valueType, from: archive) == nil
        } catch {
            return true
        }
    }
}

@objc(IdleScreenCameraTestsFutureSchemaPayload)
private final class FutureSchemaPayload: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let schemaVersion: Int

    init(schemaVersion: Int) {
        self.schemaVersion = schemaVersion
    }

    required init?(coder: NSCoder) {
        schemaVersion = coder.decodeInteger(forKey: "schemaVersion")
    }

    func encode(with coder: NSCoder) {
        coder.encode(schemaVersion, forKey: "schemaVersion")
    }
}

@objc(IdleScreenCameraTestsWrongLeaseClassPayload)
private final class WrongLeaseClassPayload: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let schemaVersion: Int
    let leasePayload: Data

    init(schemaVersion: Int, leasePayload: Data) {
        self.schemaVersion = schemaVersion
        self.leasePayload = leasePayload
    }

    required init?(coder: NSCoder) {
        schemaVersion = coder.decodeInteger(forKey: "schemaVersion")
        guard let leasePayload = coder.decodeObject(of: NSData.self, forKey: "leaseIdentifier") else {
            return nil
        }
        self.leasePayload = leasePayload as Data
    }

    func encode(with coder: NSCoder) {
        coder.encode(schemaVersion, forKey: "schemaVersion")
        coder.encode(leasePayload as NSData, forKey: "leaseIdentifier")
    }
}
