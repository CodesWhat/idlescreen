import IdleScreenCore
import IdleScreenDisplay
import Testing

@Suite("Studio camera preview reconciliation")
struct StudioCameraPreviewReconciliationTests {
    @Test("a generative source never holds the preview camera lease")
    func generativeSourceReleasesCamera() {
        for role in activeRoles + [.quiet(.black), .quiet(.subdued)] {
            #expect(!StudioCameraPreviewReconciliation.usesCamera(
                source: .generative,
                previewRole: role
            ))
        }
    }

    @Test("a camera source holds the lease while the previewed display renders")
    func activeRoleHoldsCamera() {
        for role in activeRoles {
            #expect(StudioCameraPreviewReconciliation.usesCamera(
                source: .camera,
                previewRole: role
            ))
        }
    }

    @Test("a quiet previewed display releases the lease with camera selected")
    func quietRoleReleasesCamera() {
        for treatment in DisplayQuietTreatment.allCases {
            #expect(!StudioCameraPreviewReconciliation.usesCamera(
                source: .camera,
                previewRole: .quiet(treatment)
            ))
        }
    }

    @Test("an absent plan keeps the camera source lease pending a first plan")
    func missingPlanHoldsCamera() {
        #expect(StudioCameraPreviewReconciliation.usesCamera(
            source: .camera,
            previewRole: nil
        ))
    }

    private var activeRoles: [DisplaySceneRole] {
        [.panorama, .independent, .focus]
    }
}
