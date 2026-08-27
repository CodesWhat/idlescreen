import Testing
@testable import IdleScreenCore

@Suite("Shipping saver activation policy")
struct SaverActivationPolicyTests {
    @Test("the checked-in and malformed decisions remain fail closed")
    func unverifiedDecisionsStayDisabled() {
        let malformed = IdleScreenSaverActivationDecisionInput(
            policy: .trustworthyActivationCapability,
            c6DecisionSHA256: "not-a-digest",
            c6EvidenceSetSHA256: String(repeating: "a", count: 64),
            generatedFromVerifiedC6Decision: true
        )

        for decision in [IdleScreenSaverActivationDecisionInput.failClosed, malformed] {
            let policy = IdleScreenShippingSaverCameraDemandPolicy(decision: decision)
            for activation in [
                IdleScreenSaverActivationObservation.unavailable,
                .inactive,
                .runningForeground,
                .runningBackground,
                .inconsistent,
            ] {
                #expect(
                    policy.directive(
                        source: .camera,
                        activation: activation,
                        isPreviewHint: false,
                        producerAlreadyWarm: true
                    ) == .disabled
                )
            }
        }
    }

    @Test("a verified activation policy requires foreground non-preview camera use")
    func trustworthyActivationRequiresForegroundCamera() {
        let policy = IdleScreenShippingSaverCameraDemandPolicy(
            decision: verifiedDecision(.trustworthyActivationCapability)
        )

        #expect(
            policy.directive(
                source: .camera,
                activation: .runningForeground,
                isPreviewHint: false,
                producerAlreadyWarm: false
            ) == .leaseWhileTrustworthyActivation
        )
        #expect(
            policy.directive(
                source: .camera,
                activation: .runningBackground,
                isPreviewHint: false,
                producerAlreadyWarm: false
            ) == .disabled
        )
        #expect(
            policy.directive(
                source: .camera,
                activation: .runningForeground,
                isPreviewHint: true,
                producerAlreadyWarm: false
            ) == .disabled
        )
        #expect(
            policy.directive(
                source: .generative,
                activation: .runningForeground,
                isPreviewHint: false,
                producerAlreadyWarm: false
            ) == .disabled
        )
    }

    @Test("prewarm continuation cannot start a stopped producer")
    func prewarmContinuationRequiresWarmProducer() {
        let policy = IdleScreenShippingSaverCameraDemandPolicy(
            decision: verifiedDecision(.disclosedPrewarmContinuation)
        )

        #expect(
            policy.directive(
                source: .camera,
                activation: .unavailable,
                isPreviewHint: false,
                producerAlreadyWarm: false
            ) == .disabled
        )
        #expect(
            policy.directive(
                source: .camera,
                activation: .unavailable,
                isPreviewHint: true,
                producerAlreadyWarm: true
            ) == .continueAlreadyWarmProducer
        )
    }

    @Test("camera-disabled fallback remains disabled after verified promotion")
    func cameraDisabledFallbackStaysDisabled() {
        let policy = IdleScreenShippingSaverCameraDemandPolicy(
            decision: verifiedDecision(.cameraDisabledSaverFallback)
        )

        #expect(
            policy.directive(
                source: .camera,
                activation: .runningForeground,
                isPreviewHint: false,
                producerAlreadyWarm: true
            ) == .disabled
        )
    }

    private func verifiedDecision(
        _ policy: IdleScreenShippingSaverActivationPolicy
    ) -> IdleScreenSaverActivationDecisionInput {
        let digest = String(repeating: "a", count: 64)
        return IdleScreenSaverActivationDecisionInput(
            policy: policy,
            c6DecisionSHA256: digest,
            c6EvidenceSetSHA256: digest,
            generatedFromVerifiedC6Decision: true
        )
    }
}
