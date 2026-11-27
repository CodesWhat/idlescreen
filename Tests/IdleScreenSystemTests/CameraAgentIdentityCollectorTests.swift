import Foundation
import Testing

@testable import IdleScreenSystem

@Suite("Camera agent identity collector")
struct CameraAgentIdentityCollectorTests {
  @Test("health mapping keeps absence staleness mismatch and incompleteness distinct")
  func healthMappingDistinguishesIdentityStates() throws {
    let fixture = try Fixture()
    let embedded = try fixture.fingerprint()

    let absent = CameraAgentIdentityHealthMapper.map(
      fixture.collector(
        embedded: embedded,
        registered: .unavailable
      ).collect(registrationState: .notRegistered, liveEvidence: nil)
    )
    #expect(absent.classification == .absent)

    let staleRegistered = try fixture.fingerprint(bundleVersion: "0")
    let stale = CameraAgentIdentityHealthMapper.map(
      fixture.collector(
        embedded: embedded,
        registered: .observed(
          bundleURL: fixture.helperURL,
          fingerprint: staleRegistered
        )
      ).collect(
        registrationState: .enabled,
        liveEvidence: try fixture.liveEvidence(fingerprint: embedded)
      )
    )
    #expect(stale.classification == .stale)

    let foreign = try fixture.fingerprint(teamIdentifier: "FOREIGN123")
    let mismatched = CameraAgentIdentityHealthMapper.map(
      fixture.collector(
        embedded: embedded,
        registered: .observed(
          bundleURL: fixture.helperURL,
          fingerprint: foreign
        )
      ).collect(
        registrationState: .enabled,
        liveEvidence: try fixture.liveEvidence(fingerprint: embedded)
      )
    )
    #expect(mismatched.classification == .mismatched)

    let incompleteCollection = fixture.collector(
      embedded: embedded,
      registered: .unavailable
    ).collect(registrationState: .enabled, liveEvidence: nil)
    let incomplete = CameraAgentIdentityHealthMapper.map(
      incompleteCollection
    )
    #expect(incompleteCollection.running == .unavailable)
    #expect(incomplete.classification == .unknown)
  }

  @Test("generation identifier binds process incarnation and immutable signed bytes")
  func generationIdentifierFencesReplacement() throws {
    let fixture = try Fixture()
    let embedded = try fixture.fingerprint()
    let registered: CameraAgentRegisteredArtifactEvidence = .observed(
      bundleURL: fixture.helperURL,
      fingerprint: embedded
    )
    let original = CameraAgentIdentityHealthMapper.map(
      fixture.collector(
        embedded: embedded,
        registered: registered
      ).collect(
        registrationState: .enabled,
        liveEvidence: try fixture.liveEvidence(
          processEpoch: 7_001,
          fingerprint: embedded
        )
      ))
    let replacementProcess = CameraAgentIdentityHealthMapper.map(
      fixture.collector(
        embedded: embedded,
        registered: registered
      ).collect(
        registrationState: .enabled,
        liveEvidence: try fixture.liveEvidence(
          processEpoch: 7_002,
          fingerprint: embedded
        )
      ))
    let changedBytes = try fixture.fingerprint(
      executableSHA256: String(repeating: "b", count: 64)
    )
    let replacementBytes = CameraAgentIdentityHealthMapper.map(
      fixture.collector(
        embedded: embedded,
        registered: registered,
        activeSource: changedBytes
      ).collect(
        registrationState: .enabled,
        liveEvidence: try fixture.liveEvidence(
          processEpoch: 7_001,
          fingerprint: changedBytes
        )
      ))

    #expect(original.classification == .current)
    #expect(original.generationIdentifier != nil)
    #expect(replacementProcess.generationIdentifier != original.generationIdentifier)
    #expect(replacementBytes.generationIdentifier != original.generationIdentifier)
  }

  @Test("matching embedded registered and authenticated live evidence is current")
  func matchingEvidenceIsCurrent() throws {
    let fixture = try Fixture()
    let embedded = try fixture.fingerprint()
    let provider = StubEmbeddedArtifactProvider(results: [
      .success(embedded),
      .success(embedded),
    ])
    let registered = StubRegisteredArtifactProvider(
      evidence: .observed(
        bundleURL: fixture.helperURL,
        fingerprint: embedded
      )
    )
    let collector = CameraAgentIdentityCollector(
      configuration: fixture.configuration,
      embeddedArtifactProvider: provider,
      registeredArtifactProvider: registered
    )

    let result = collector.collect(
      registrationState: .enabled,
      liveEvidence: try fixture.liveEvidence(fingerprint: embedded)
    )

    #expect(result.embedded == .observed(embedded))
    #expect(result.registered == .observed(embedded))
    #expect(result.running == .observed(embedded))
    #expect(result.processEpoch == 7_001)
    #expect(result.assessment?.classification == .current)
    let expectedRequest = CameraAgentEmbeddedArtifactRequest(
      containingApplicationURL: fixture.applicationURL,
      helperBundleURL: fixture.helperURL,
      launchAgentURL: fixture.launchAgentURL,
      serviceIdentity: fixture.serviceIdentity
    )
    #expect(provider.requests == [expectedRequest, expectedRequest])
  }

  @Test("artifact request identity ignores file URL directory hints")
  func artifactRequestDirectoryHint() throws {
    let applicationFileURL = try #require(
      URL(string: "file:///Applications/IdleScreen.app")
    )
    let applicationDirectoryURL = try #require(
      URL(string: "file:///Applications/IdleScreen.app/")
    )
    let fixture = try Fixture(applicationURL: applicationFileURL)

    let fileRequest = CameraAgentEmbeddedArtifactRequest(
      containingApplicationURL: applicationFileURL,
      helperBundleURL: fixture.helperURL,
      launchAgentURL: fixture.launchAgentURL,
      serviceIdentity: fixture.serviceIdentity
    )
    let directoryRequest = CameraAgentEmbeddedArtifactRequest(
      containingApplicationURL: applicationDirectoryURL,
      helperBundleURL: fixture.helperURL,
      launchAgentURL: fixture.launchAgentURL,
      serviceIdentity: fixture.serviceIdentity
    )

    #expect(fileRequest == directoryRequest)
  }

  @Test("an absent embedded helper is distinct from unavailable registration evidence")
  func absentEmbeddedHelperIsExplicit() throws {
    let fixture = try Fixture()
    let provider = StubEmbeddedArtifactProvider(
      result: .failure(.helperBundleMissing(fixture.helperURL.path))
    )
    let collector = CameraAgentIdentityCollector(
      configuration: fixture.configuration,
      embeddedArtifactProvider: provider,
      registeredArtifactProvider: CameraAgentRegisteredArtifactUnavailableProvider()
    )

    let result = collector.collect(
      registrationState: .enabled,
      liveEvidence: nil
    )

    #expect(result.embedded == .absent)
    #expect(result.registered == .unavailable)
    #expect(result.running == .unavailable)
    #expect(result.assessment == nil)
    #expect(!result.isCurrent)
  }

  @Test(
    "dormant production registration evidence remains unavailable instead of parsing launchd state")
  func dormantRegisteredIdentityIsTruthfullyUnavailable() throws {
    let fixture = try Fixture()
    let embedded = try fixture.fingerprint()
    let collector = CameraAgentIdentityCollector(
      configuration: fixture.configuration,
      embeddedArtifactProvider: StubEmbeddedArtifactProvider(
        result: .success(embedded)
      ),
      registeredArtifactProvider: CameraAgentRegisteredArtifactUnavailableProvider()
    )

    let result = collector.collect(
      registrationState: .enabled,
      liveEvidence: nil
    )

    #expect(result.embedded == .observed(embedded))
    #expect(result.registered == .unavailable)
    #expect(result.running == .unavailable)
    #expect(result.assessment?.classification == .observationIncomplete)
    #expect(
      result.assessment?.observationGaps == [
        .registeredArtifact,
        .runningProcess,
      ])
    #expect(!result.isCurrent)
  }

  @Test("an authenticated active source closes only the unsupported registered artifact gap")
  func authenticatedActiveHelperClosesUnsupportedRegistrationGap() throws {
    let fixture = try Fixture()
    let embedded = try fixture.fingerprint()
    let provider = StubEmbeddedArtifactProvider(results: [
      .success(embedded),
      .success(embedded),
    ])
    let collector = CameraAgentIdentityCollector(
      configuration: fixture.configuration,
      embeddedArtifactProvider: provider,
      registeredArtifactProvider: CameraAgentRegisteredArtifactUnavailableProvider()
    )

    let result = collector.collect(
      registrationState: .enabled,
      liveEvidence: try fixture.liveEvidence(fingerprint: embedded)
    )

    #expect(result.registered == .unavailable)
    #expect(result.running == .observed(embedded))
    #expect(result.assessment?.classification == .observationIncomplete)
    #expect(result.assessment?.observationGaps == [.registeredArtifact])
    #expect(CameraAgentIdentityHealthMapper.map(result).classification == .current)
    #expect(result.isCurrent)
    #expect(provider.requests.count == 2)
    #expect(
      provider.requests[1]
        == CameraAgentEmbeddedArtifactRequest(
          containingApplicationURL: fixture.applicationURL,
          helperBundleURL: fixture.helperURL,
          launchAgentURL: fixture.launchAgentURL,
          serviceIdentity: fixture.serviceIdentity
        ))
  }

  @Test("PID-bound running evidence fails closed when its active source rehash drifts")
  func activeSourceDriftInvalidatesRunningEvidence() throws {
    let fixture = try Fixture()
    let embedded = try fixture.fingerprint()
    let driftedSource = try fixture.fingerprint(
      executableSHA256: String(repeating: "b", count: 64)
    )
    let collector = fixture.collector(
      embedded: embedded,
      registered: .observed(
        bundleURL: fixture.helperURL,
        fingerprint: embedded
      ),
      activeSource: driftedSource
    )

    let result = collector.collect(
      registrationState: .enabled,
      liveEvidence: try fixture.liveEvidence(fingerprint: embedded)
    )

    guard case .invalid = result.running else {
      Issue.record("Expected active-source drift to invalidate running evidence")
      return
    }
    #expect(result.assessment?.classification == .observationIncomplete)
    #expect(result.assessment?.observationGaps == [.runningProcess])
    #expect(CameraAgentIdentityHealthMapper.map(result).classification == .mismatched)
    #expect(!result.isCurrent)
  }

  @Test("live evidence rejects a PID that is not the authenticated control peer")
  func liveEvidenceRequiresPIDCorrelation() throws {
    let fixture = try Fixture()

    #expect(
      throws: CameraAgentAuthenticatedLiveIdentityEvidence.Error.processMismatch(
        authenticated: 771,
        reported: 772
      )
    ) {
      try CameraAgentAuthenticatedLiveIdentityEvidence(
        processIdentifier: 772,
        authenticatedControlProcessIdentifier: 771,
        processEpoch: 7_001,
        bundleURL: fixture.helperURL,
        fingerprint: fixture.fingerprint()
      )
    }
  }

  @Test("provisioning profile drift requires replacement")
  func profileDriftRequiresReplacement() throws {
    let fixture = try Fixture()
    let embedded = try fixture.fingerprint()
    let staleProfile = try fixture.fingerprint(
      provisioningProfileSHA256: String(repeating: "9", count: 64)
    )
    let collector = fixture.collector(
      embedded: embedded,
      registered: .observed(
        bundleURL: fixture.helperURL,
        fingerprint: staleProfile
      )
    )

    let result = collector.collect(
      registrationState: .enabled,
      liveEvidence: try fixture.liveEvidence(fingerprint: embedded)
    )

    #expect(result.assessment?.classification == .replacementRequired)
    #expect(
      result.assessment?.mismatches == [
        CameraAgentArtifactMismatch(
          location: .registeredArtifact,
          differences: [.provisioningProfileSHA256]
        )
      ])
  }

  @Test("registered and running copies retain their separate mismatches")
  func registeredRunningMismatchIsExplicit() throws {
    let fixture = try Fixture()
    let embedded = try fixture.fingerprint()
    let staleRegisteredURL = URL(
      fileURLWithPath: "/Applications/Old IdleScreen.app/Contents/Helpers/IdleScreenCameraAgent.app"
    )
    let staleRegistered = try fixture.fingerprint(
      canonicalBundlePath: staleRegisteredURL.path,
      bundleVersion: "0"
    )
    let foreignRunningURL = URL(
      fileURLWithPath: "/Applications/Foreign.app/Contents/Helpers/IdleScreenCameraAgent.app"
    )
    let foreignRunning = try fixture.fingerprint(
      canonicalBundlePath: foreignRunningURL.path,
      signingIdentifier: "com.example.foreign-agent",
      teamIdentifier: "FOREIGN123"
    )
    let collector = fixture.collector(
      embedded: embedded,
      registered: .observed(
        bundleURL: staleRegisteredURL,
        fingerprint: staleRegistered
      ),
      activeSource: foreignRunning
    )

    let result = collector.collect(
      registrationState: .enabled,
      liveEvidence: try fixture.liveEvidence(
        bundleURL: foreignRunningURL,
        fingerprint: foreignRunning
      )
    )

    #expect(result.assessment?.classification == .replacementRequired)
    #expect(
      result.assessment?.mismatches == [
        CameraAgentArtifactMismatch(
          location: .registeredArtifact,
          differences: [.bundlePath, .bundleVersion]
        ),
        CameraAgentArtifactMismatch(
          location: .runningProcess,
          differences: [.bundlePath, .signingIdentifier, .teamIdentifier]
        ),
      ])
  }

  @Test("replacement race keeps an old active source distinct from the new registered target")
  func replacementRaceDoesNotCollapseActiveSourceIntoRegistration() throws {
    let fixture = try Fixture(
      applicationURL: URL(
        fileURLWithPath: "/Applications/Replacement.app"
      ))
    let embedded = try fixture.fingerprint()
    let oldApplicationURL = URL(
      fileURLWithPath: "/Applications/Old.app",
      isDirectory: true
    )
    let oldHelperURL = oldApplicationURL.appendingPathComponent(
      "Contents/Helpers/IdleScreenCameraAgent.app",
      isDirectory: true
    )
    let oldRunning = try fixture.fingerprint(
      canonicalBundlePath: oldHelperURL.path,
      bundleVersion: "0"
    )
    let provider = StubEmbeddedArtifactProvider(results: [
      .success(embedded),
      .success(oldRunning),
    ])
    let collector = CameraAgentIdentityCollector(
      configuration: fixture.configuration,
      embeddedArtifactProvider: provider,
      registeredArtifactProvider: StubRegisteredArtifactProvider(
        evidence: .observed(
          bundleURL: fixture.helperURL,
          fingerprint: embedded
        )
      )
    )

    let result = collector.collect(
      registrationState: .enabled,
      liveEvidence: try fixture.liveEvidence(
        bundleURL: oldHelperURL,
        fingerprint: oldRunning
      )
    )

    #expect(result.registered == .observed(embedded))
    #expect(result.running == .observed(oldRunning))
    #expect(result.assessment?.classification == .replacementRequired)
    #expect(
      result.assessment?.mismatches == [
        CameraAgentArtifactMismatch(
          location: .runningProcess,
          differences: [.bundlePath, .bundleVersion]
        )
      ])
    #expect(CameraAgentIdentityHealthMapper.map(result).classification == .stale)
    #expect(
      provider.requests == [
        CameraAgentEmbeddedArtifactRequest(
          containingApplicationURL: fixture.applicationURL,
          helperBundleURL: fixture.helperURL,
          launchAgentURL: fixture.launchAgentURL,
          serviceIdentity: fixture.serviceIdentity
        ),
        CameraAgentEmbeddedArtifactRequest(
          containingApplicationURL: oldApplicationURL,
          helperBundleURL: oldHelperURL,
          launchAgentURL: oldApplicationURL.appendingPathComponent(
            "Contents/Library/LaunchAgents/\(fixture.serviceIdentity.plistName)"
          ),
          serviceIdentity: fixture.serviceIdentity
        ),
      ])
  }

  @Test("canonical embedded paths must remain inside the containing application")
  func embeddedPathCannotEscapeApplication() throws {
    let fixture = try Fixture()
    let escapedPath = "/private/tmp/IdleScreenCameraAgent.app"
    let canonicalizer = MappingCanonicalizer(paths: [
      fixture.applicationURL.path: fixture.applicationURL.path,
      fixture.helperURL.path: escapedPath,
      fixture.launchAgentURL.path: fixture.launchAgentURL.path,
    ])
    let provider = StubEmbeddedArtifactProvider(
      result: .success(try fixture.fingerprint())
    )
    let collector = CameraAgentIdentityCollector(
      configuration: fixture.configuration,
      embeddedArtifactProvider: provider,
      registeredArtifactProvider: CameraAgentRegisteredArtifactUnavailableProvider(),
      canonicalizer: canonicalizer
    )

    let result = collector.collect(registrationState: .enabled, liveEvidence: nil)

    #expect(
      result.embedded
        == .invalid(
          .pathEscapesContainingApplication(
            path: escapedPath,
            applicationPath: fixture.applicationURL.path
          )))
    #expect(provider.requests.isEmpty)
    #expect(result.assessment == nil)
  }

  @Test("authenticated live evidence must bind its canonical path to its fingerprint")
  func liveEvidencePathMismatchFailsClosed() throws {
    let fixture = try Fixture()
    let embedded = try fixture.fingerprint()
    let evidenceURL = URL(
      fileURLWithPath: "/Applications/Replacement.app/Contents/Helpers/IdleScreenCameraAgent.app"
    )
    let collector = fixture.collector(
      embedded: embedded,
      registered: .observed(
        bundleURL: fixture.helperURL,
        fingerprint: embedded
      )
    )

    let result = collector.collect(
      registrationState: .enabled,
      liveEvidence: try fixture.liveEvidence(
        bundleURL: evidenceURL,
        fingerprint: embedded
      )
    )

    #expect(
      result.running
        == .invalid(
          .fingerprintPathMismatch(
            evidencePath: evidenceURL.path,
            fingerprintPath: embedded.canonicalBundlePath
          )))
    #expect(result.assessment?.classification == .observationIncomplete)
    #expect(result.assessment?.observationGaps == [.runningProcess])
    #expect(!result.isCurrent)
  }

  @Test("the production provider reports a missing helper without shelling out")
  func productionProviderRejectsMissingHelper() throws {
    let fixture = try Fixture(
      applicationURL: URL(
        fileURLWithPath: "/definitely-not-present/IdleScreen.app"
      )
    )
    let request = CameraAgentEmbeddedArtifactRequest(
      containingApplicationURL: fixture.applicationURL,
      helperBundleURL: fixture.helperURL,
      launchAgentURL: fixture.launchAgentURL,
      serviceIdentity: fixture.serviceIdentity
    )

    #expect(
      throws: CameraAgentArtifactProviderError.helperBundleMissing(
        fixture.helperURL.path
      )
    ) {
      try SecurityCameraAgentEmbeddedArtifactProvider().fingerprint(for: request)
    }
  }
}

extension CameraAgentIdentityCollectorTests {
  private func embeddedObservation(
    fixture: Fixture,
    fingerprint: CameraAgentArtifactFingerprint
  ) -> CameraAgentIdentityObservation {
    fixture.collector(embedded: fingerprint, registered: .absent)
      .collect(registrationState: .notRegistered, liveEvidence: nil)
      .embedded
  }

  @Test("an embedded fingerprint is rejected for each identity field that disagrees")
  func embeddedFingerprintFieldMismatches() throws {
    let fixture = try Fixture()
    func fingerprint(
      path: String? = nil,
      service: String? = nil,
      bundle: String = "com.idlescreen.camera-agent",
      signing: String = "com.idlescreen.camera-agent",
      team: String = "3524374A2S"
    ) throws -> CameraAgentArtifactFingerprint {
      try CameraAgentArtifactFingerprint(
        canonicalBundlePath: path ?? fixture.helperURL.path,
        serviceIdentifier: service ?? fixture.serviceIdentity.serviceIdentifier,
        bundleIdentifier: bundle,
        bundleVersion: "1",
        marketingVersion: "0.1",
        signingIdentifier: signing,
        teamIdentifier: team,
        codeDirectoryHash: String(repeating: "1", count: 40),
        executableSHA256: String(repeating: "a", count: 64),
        launchAgentSHA256: String(repeating: "2", count: 64),
        provisioningProfileSHA256: String(repeating: "3", count: 64)
      )
    }

    #expect(
      embeddedObservation(
        fixture: fixture, fingerprint: try fingerprint(path: "/elsewhere/Helper.app"))
        == .invalid(
          .fingerprintPathMismatch(
            evidencePath: fixture.helperURL.path,
            fingerprintPath: "/elsewhere/Helper.app"
          ))
    )
    #expect(
      embeddedObservation(
        fixture: fixture,
        fingerprint: try fingerprint(service: "group.com.idlescreen.dev.shared.camera-agent")
      )
        == .invalid(
          .embeddedServiceIdentifier(
            expected: fixture.serviceIdentity.serviceIdentifier,
            actual: "group.com.idlescreen.dev.shared.camera-agent"
          ))
    )
    #expect(
      embeddedObservation(
        fixture: fixture, fingerprint: try fingerprint(bundle: "com.example.other"))
        == .invalid(
          .embeddedBundleIdentifier(
            expected: "com.idlescreen.camera-agent",
            actual: "com.example.other"
          ))
    )
    #expect(
      embeddedObservation(
        fixture: fixture, fingerprint: try fingerprint(signing: "com.example.other"))
        == .invalid(
          .embeddedSigningIdentifier(
            expected: "com.idlescreen.camera-agent",
            actual: "com.example.other"
          ))
    )
    #expect(
      embeddedObservation(fixture: fixture, fingerprint: try fingerprint(team: "FOREIGN123"))
        == .invalid(
          .embeddedTeamIdentifier(expected: "3524374A2S", actual: "FOREIGN123")
        )
    )
    let valid = try fingerprint()
    #expect(embeddedObservation(fixture: fixture, fingerprint: valid) == .observed(valid))
  }

  @Test("provider failures other than a missing helper are reported as invalid evidence")
  func providerFailureClassification() throws {
    let fixture = try Fixture()
    func embedded(
      _ result: Result<CameraAgentArtifactFingerprint, CameraAgentArtifactProviderError>
    ) -> CameraAgentIdentityObservation {
      CameraAgentIdentityCollector(
        configuration: fixture.configuration,
        embeddedArtifactProvider: StubEmbeddedArtifactProvider(result: result),
        registeredArtifactProvider: StubRegisteredArtifactProvider(evidence: .absent)
      ).collect(registrationState: .notRegistered, liveEvidence: nil).embedded
    }

    #expect(embedded(.failure(.helperBundleMissing("/x"))) == .absent)
    #expect(
      embedded(.failure(.launchAgentMissing("/x")))
        == .invalid(.artifactProvider(.launchAgentMissing("/x")))
    )
    #expect(
      embedded(.failure(.invalidStaticCode(-67_062)))
        == .invalid(.artifactProvider(.invalidStaticCode(-67_062)))
    )
  }

  @Test("registration states without an enabled service never consult the registered provider")
  func registrationStateMapping() throws {
    let fixture = try Fixture()
    let embedded = try fixture.fingerprint()
    func registered(_ state: CameraAgentRegistrationState) -> CameraAgentIdentityObservation {
      fixture.collector(
        embedded: embedded,
        registered: .observed(bundleURL: fixture.helperURL, fingerprint: embedded)
      ).collect(registrationState: state, liveEvidence: nil).registered
    }

    #expect(registered(.notRegistered) == .absent)
    #expect(registered(.notFound) == .absent)
    #expect(registered(.requiresApproval) == .unavailable)
    #expect(registered(.enabled) == .observed(embedded))
  }

  @Test("enabled registration maps each registered-provider answer")
  func enabledRegistrationEvidence() throws {
    let fixture = try Fixture()
    let embedded = try fixture.fingerprint()
    func registered(_ evidence: CameraAgentRegisteredArtifactEvidence)
      -> CameraAgentIdentityObservation
    {
      fixture.collector(embedded: embedded, registered: evidence)
        .collect(registrationState: .enabled, liveEvidence: nil).registered
    }

    #expect(registered(.absent) == .absent)
    #expect(registered(.unavailable) == .unavailable)
    #expect(
      registered(
        .observed(bundleURL: URL(fileURLWithPath: "/other/Helper.app"), fingerprint: embedded))
        == .invalid(
          .fingerprintPathMismatch(
            evidencePath: "/other/Helper.app",
            fingerprintPath: fixture.helperURL.path
          ))
    )
  }

  @Test(
    "a running helper outside the expected bundle layout has unavailable active-source evidence")
  func runningHelperWithUnexpectedLayout() throws {
    let fixture = try Fixture()
    let odd = URL(fileURLWithPath: "/private/tmp/odd/Elsewhere.app")
    let fingerprint = try fixture.fingerprint(canonicalBundlePath: odd.path)
    let collection = fixture.collector(embedded: try fixture.fingerprint(), registered: .absent)
      .collect(
        registrationState: .enabled,
        liveEvidence: try fixture.liveEvidence(bundleURL: odd, fingerprint: fingerprint)
      )

    #expect(collection.running == .unavailable)
    #expect(collection.processIdentifier == 771)
    #expect(collection.processEpoch == 7_001)
  }
}

private final class StubEmbeddedArtifactProvider:
  CameraAgentEmbeddedArtifactProviding,
  @unchecked Sendable
{
  private var results: [Result<CameraAgentArtifactFingerprint, CameraAgentArtifactProviderError>]
  private(set) var requests: [CameraAgentEmbeddedArtifactRequest] = []

  init(
    result: Result<CameraAgentArtifactFingerprint, CameraAgentArtifactProviderError>
  ) {
    results = [result]
  }

  init(
    results: [Result<CameraAgentArtifactFingerprint, CameraAgentArtifactProviderError>]
  ) {
    self.results = results
  }

  func fingerprint(
    for request: CameraAgentEmbeddedArtifactRequest
  ) throws -> CameraAgentArtifactFingerprint {
    requests.append(request)
    return try results.removeFirst().get()
  }
}

private struct StubRegisteredArtifactProvider:
  CameraAgentRegisteredArtifactProviding
{
  let evidence: CameraAgentRegisteredArtifactEvidence

  func registeredArtifact(
    for serviceIdentity: CameraAgentServiceIdentity
  ) -> CameraAgentRegisteredArtifactEvidence {
    _ = serviceIdentity
    return evidence
  }
}

private struct MappingCanonicalizer: CameraAgentPathCanonicalizing {
  let paths: [String: String]

  func canonicalFileURL(_ url: URL) -> URL {
    URL(fileURLWithPath: paths[url.path] ?? url.path)
  }
}

private struct Fixture {
  let applicationURL: URL
  let serviceIdentity: CameraAgentServiceIdentity
  let configuration: CameraAgentIdentityCollectorConfiguration

  init(
    applicationURL: URL = URL(
      fileURLWithPath: "/private/tmp/idlescreen-identity-collector-tests/IdleScreen.app"
    )
  ) throws {
    self.applicationURL = applicationURL
    serviceIdentity = try CameraAgentServiceIdentity(
      appGroupIdentifier: "group.com.idlescreen.shared"
    )
    configuration = try CameraAgentIdentityCollectorConfiguration(
      containingApplicationURL: applicationURL,
      serviceIdentity: serviceIdentity,
      expectedTeamIdentifier: "3524374A2S"
    )
  }

  var helperURL: URL {
    applicationURL.appendingPathComponent(
      "Contents/Helpers/IdleScreenCameraAgent.app",
      isDirectory: true
    )
  }

  var launchAgentURL: URL {
    applicationURL.appendingPathComponent(
      "Contents/Library/LaunchAgents/\(serviceIdentity.plistName)",
      isDirectory: false
    )
  }

  func fingerprint(
    canonicalBundlePath: String? = nil,
    bundleVersion: String = "1",
    signingIdentifier: String = "com.idlescreen.camera-agent",
    teamIdentifier: String = "3524374A2S",
    executableSHA256: String = String(repeating: "a", count: 64),
    provisioningProfileSHA256: String = String(repeating: "3", count: 64)
  ) throws -> CameraAgentArtifactFingerprint {
    try CameraAgentArtifactFingerprint(
      canonicalBundlePath: canonicalBundlePath ?? helperURL.path,
      serviceIdentifier: serviceIdentity.serviceIdentifier,
      bundleIdentifier: "com.idlescreen.camera-agent",
      bundleVersion: bundleVersion,
      marketingVersion: "0.1",
      signingIdentifier: signingIdentifier,
      teamIdentifier: teamIdentifier,
      codeDirectoryHash: String(repeating: "1", count: 40),
      executableSHA256: executableSHA256,
      launchAgentSHA256: String(repeating: "2", count: 64),
      provisioningProfileSHA256: provisioningProfileSHA256
    )
  }

  func liveEvidence(
    bundleURL: URL? = nil,
    processEpoch: UInt64 = 7_001,
    fingerprint: CameraAgentArtifactFingerprint
  ) throws -> CameraAgentAuthenticatedLiveIdentityEvidence {
    try CameraAgentAuthenticatedLiveIdentityEvidence(
      processIdentifier: 771,
      authenticatedControlProcessIdentifier: 771,
      processEpoch: processEpoch,
      bundleURL: bundleURL ?? helperURL,
      fingerprint: fingerprint
    )
  }

  func collector(
    embedded: CameraAgentArtifactFingerprint,
    registered: CameraAgentRegisteredArtifactEvidence,
    activeSource: CameraAgentArtifactFingerprint? = nil
  ) -> CameraAgentIdentityCollector {
    CameraAgentIdentityCollector(
      configuration: configuration,
      embeddedArtifactProvider: StubEmbeddedArtifactProvider(results: [
        .success(embedded),
        .success(activeSource ?? embedded),
      ]),
      registeredArtifactProvider: StubRegisteredArtifactProvider(
        evidence: registered
      )
    )
  }
}
