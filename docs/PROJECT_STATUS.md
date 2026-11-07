# Project status and house audit

Full house audit: August 29, 2026. Release record updated November 7, 2026.
Controls below retain that audit scope unless a newer release record is stated.

## Classification

IdleScreen is a public CodesWhat Swift product. It publishes a signed and
notarized universal macOS app, a GitHub release DMG, and a Homebrew cask. It has
no hosted service, container image, package registry artifact, localization
pipeline, or web runtime.

## Audit status

| Control | Expected state | Current state | Verdict |
| --- | --- | --- | --- |
| Default branch | `main` is the latest GA tag | `main` matches the v0.3.0 GA tag at `c7095365` | Pass |
| Development line | One active protected `dev/vX.Y` branch | `dev/v0.1` requires PRs, two approvals, current-head approval, the six stable checks, and CodeQL, with no bypass actors | Pass |
| Release tags | `v*` tags cannot be deleted, updated, or force-pushed | Active tag ruleset, no bypass actors | Pass |
| Main protection | PRs, two approvals, code owners, current head approval, required checks, CodeQL | Active no-bypass ruleset requires the six stable PR contexts proven by the representative review | Pass |
| Contributor files | Repo-specific AGENTS, CONTRIBUTING, SECURITY, ownership, license | Present on protected `dev/v0.1` and aligned with the exact local gates | Pass |
| Local gates | Conventional Commits, clean-tree pre-push, formatter, Qlty, tests, build, workflow security | Lefthook and repository scripts passed before the protected development merge | Pass |
| Primary CI | Main and dev PR/push coverage, pinned actions, least privilege, hardened runners | The full Xcode schemes, deterministic fixtures, companion Release build, Qlty, and Swift format passed on the reviewed head; Codecov runs on development pushes | Pass |
| Workflow security | actionlint, zizmor, Gitleaks, dependency review | The representative PR passed all four pinned checks; actionlint, zizmor, and Gitleaks also passed after merge | Pass |
| Code scanning | CodeQL for Actions, C/C++, Python, and Swift | The SHA-pinned hardened matrix passed for the exact reviewed source tree on `dev/v0.1` | Pass |
| Public security | Private reporting, secret scanning, push protection, Dependabot | Enabled live; no open CodeQL or Dependabot alerts at audit time | Pass |
| Review automation | CodeRabbit on dev PRs; Greptile only by label | CodeRabbit reviewed and rechecked the corrected head; the label-gated Greptile path was exercised, but bot silence was not counted as review evidence | Pass |
| README | Product shape, live badges, install path, community routing | Product shape adopted; Scorecard and Codecov badges require their first default-branch run | Verify after release |
| Release engineering | Clean immutable candidate, Developer ID, notarization, Gatekeeper, manifest-derived cask | The clean development source, signing identity, and all three Developer ID profiles pass the builder preflight; the team-scoped App Store Connect API key authenticates against submission history, the stale Apple ID notary profile has been removed so one working credential remains, and the Developer ID Application certificate is valid through 2027-02-01 | v0.3.0 build 66 published; exact downloaded asset digests rechecked |
| Build provenance | SBOM and workflow identity for shipped artifacts | A manifest-bound SPDX 2.3 SBOM is generated for the shipped DMG; GitHub Actions migration would require moving Apple signing and notary credentials | Local SBOM passes; Actions attestation tracked |
| Repository metadata | Public product description, topics, Discussions, detected MIT license | Description, topics, Discussions, and MIT license detection are live | Pass |

## App review status

The August 27 whole-app review accepted seven findings. All seven fixes and
their regression tests are committed on the release branch. The deterministic
scheme matrix, release fixtures, project generation, Release build, and
performance measurements passed before this audit. See [CHANGELOG.md](../CHANGELOG.md)
and the [roadmap](ROADMAP.md) for the user-facing scope.

## Current release exit

v0.3.0 build 66 shipped on November 5, 2026 from
`c7095365badf5cfbc3e3b6a05f777110bde517b2` after promotion PR #44 and
provenance/appearance PR #46. The signed GA tag and `main` identify that commit.

The published release contains the DMG, `IdleScreenR1ReleaseCandidateV1.txt` and
SPDX SBOM. Downloaded asset digests match the GitHub release records:

- DMG: `b779db9af37add9cea2eeb301bdfde7db0dd64e77a8c3431fa78793c4573f360`
- Candidate manifest: `2bea088b5e4256473d648c6acf741d74802727be1cf024b7a5c7a87e9fe685b9`
- SPDX SBOM: `c4f4cd99414e89623e2c5a06385a52d98f47a2ed1e38520a21c23ef0ed312a3a`

The controlled-Mac release record includes accepted notarization, stapling,
Gatekeeper, mounted-app signature checks and manifest replay. The generated
Homebrew cask merged in CodesWhat/homebrew-tap#30. Physical camera lifecycle,
Intel and broader multi-display coverage remain explicitly unverified in the
README; release publication does not close those rows.

The v0.1.2 candidate/SBOM snapshot-binding follow-up was completed in the
v0.2.0 release work, including PR #21. Actions-hosted signing and attestations
remain tracked in issue #8 pending an approved Apple credential enrollment
path. No Apple signing credentials have been moved into GitHub.
