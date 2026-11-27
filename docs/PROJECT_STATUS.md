# Project status and house audit

Full house audit: August 29, 2026. Release record and CI notes updated November 27, 2026.
Controls below retain that audit scope unless a newer release record is stated.

## Classification

IdleScreen is a public CodesWhat Swift product. It publishes a signed and
notarized Apple silicon macOS app, a GitHub release DMG, and a Homebrew cask. It has
no hosted service, container image, package registry artifact, localization
pipeline, or web runtime.

## Audit status

| Control | Expected state | Current state | Verdict |
| --- | --- | --- | --- |
| Default branch | `main` is the latest GA tag | `main` matches the v0.4.0 GA tag at `4eeb36c0` | Pass |
| Development line | One active protected `dev/vX.Y` branch | `dev/v0.1` requires PRs, two approvals, current-head approval, the six stable checks, and CodeQL, with no bypass actors | Pass |
| Release tags | `v*` tags cannot be deleted, updated, or force-pushed | Active tag ruleset, no bypass actors | Pass |
| Main protection | PRs, two approvals, code owners, current head approval, required checks, CodeQL | Active no-bypass ruleset requires the six stable PR contexts proven by the representative review | Pass |
| Contributor files | Repo-specific AGENTS, CONTRIBUTING, SECURITY, ownership, license | Present on protected `dev/v0.1` and aligned with the exact local gates | Pass |
| Local gates | Conventional Commits, clean-tree pre-push, formatter, Qlty, tests, build, workflow security | Lefthook and repository scripts passed before the protected development merge | Pass |
| Primary CI | Main and dev PR/push coverage, pinned actions, least privilege, hardened runners | The full Xcode schemes, deterministic fixtures, companion Release build, Qlty, and Swift format passed on the reviewed head; Codecov runs on development pushes | Pass |
| Workflow security | actionlint, zizmor, Gitleaks, dependency review | The representative PR passed all four pinned checks; actionlint, zizmor, and Gitleaks also passed after merge | Pass |
| Code scanning | CodeQL for Actions, C/C++, Python, and Swift | The SHA-pinned hardened matrix passed for the exact reviewed source tree on `dev/v0.1` | Pass |
| Public security | Private reporting, secret scanning, push protection, Dependabot | Enabled live; no open CodeQL alerts. Two open Dependabot alerts (medium, both GHSA-mfr8-8qww-v76h on `next` in `docs-site`, patched in 16.4.5). `dev/v0.1` already has `next` 16.4.6 from #54, so they stay open until that reaches `main`. Three open Scorecard code-scanning alerts on `main`: CIIBestPracticesID, FuzzingID and TokenPermissionsID | Follow-up |
| Review automation | CodeRabbit on dev PRs; Greptile only by label | CodeRabbit reviewed and rechecked the corrected head; the label-gated Greptile path was exercised, but bot silence was not counted as review evidence | Pass |
| README | Product shape, live badges, install path, community routing | Product shape adopted; Scorecard and Codecov badges require their first default-branch run | Verify after release |
| Release engineering | Clean immutable candidate, Developer ID, notarization, Gatekeeper, manifest-derived cask | The clean development source, signing identity, and all three Developer ID profiles pass the builder preflight; the team-scoped App Store Connect API key authenticates against submission history, the stale Apple ID notary profile has been removed so one working credential remains (the builder also falls back to that API key when the profile is missing), and the Developer ID Application certificate is valid through 2027-02-01 | v0.4.0 build 67 published November 21, 2026; v0.4.0 asset digests recorded from the GitHub release |
| Build provenance | SBOM and workflow identity for shipped artifacts | A manifest-bound SPDX 2.3 SBOM is generated for the shipped DMG. `release-attest.yml` attaches GitHub provenance and SBOM attestations to a published release's assets without holding Apple credentials; moving signing into Actions would require moving the signing and notary credentials | Local SBOM passes; `release-attest.yml` attests the DMG, manifest and SBOM of releases published after v0.4.0, which has none |
| Repository metadata | Public product description, topics, Discussions, detected MIT license | Description, topics, Discussions, and MIT license detection are live | Pass |

## App review status

The August 27 whole-app review accepted seven findings. All seven fixes and
their regression tests are committed on the release branch. The deterministic
scheme matrix, release fixtures, project generation, Release build, and
performance measurements passed before this audit. See [CHANGELOG.md](../CHANGELOG.md)
and the [roadmap](ROADMAP.md) for the user-facing scope.

## Platform support

IdleScreen is supported on macOS 26 (Tahoe) on Apple silicon.
macOS 27 has not been tested yet, because no macOS 27 machine is available for a
smoke run. Reports are welcome as GitHub issues.

## Current release exit

The latest release is
[v0.4.0](https://github.com/CodesWhat/idlescreen/releases/tag/v0.4.0) build 67,
published November 21, 2026 (Apple silicon only, macOS 26 or later), from
`4eeb36c0340d7a4c9d028131adf2d4e0c630017e`. It ships the DMG,
`IdleScreenR1ReleaseCandidateV1.txt` and an SPDX SBOM. The GitHub release
records these asset digests:

- DMG: `ce5eb8082de7b2bda632ee057e79492c8e6bbeab3dcf4d41aec425a123eb478d`
- Candidate manifest: `a490fc1ce716a484c0e338f93a0c55e7d2e1359c7d3f561ba7e4bb4b6a795950`
- SPDX SBOM: `1a8d6b63b0b4a70fb442dfff3449c4144706af3856e4a1e2bb3db8c56df7778f`

`scripts/check-release-reproducibility.sh v0.4.0` reproduces all six
comparable fields (source commit and tree, `project.yml` and `project.pbxproj`
digests, bundle version and build). Signatures, cdhashes, the DMG and
notarization are not comparable from the manifest. v0.4.0 has no provenance
attestations, because `release-attest.yml` landed after it.

Physical camera lifecycle and broader multi-display coverage remain explicitly
unverified in the README; release publication does not close those rows.

## CI coverage

Pushes enforce a fixed 80% line-coverage floor on the LCOV report with
`scripts/check_coverage_floor.py`, as the last step of the `coverage` job after
the Codecov upload, so a miss still publishes the report. Promotion PRs to `main` are checked with
`scripts/check-promotion-codeql.sh`, which checks the PR's merge ref for open
high or critical code-scanning alerts (or error severity when an alert has no
security severity) after confirming CodeQL analyzed the current merge commit.

The v0.3.0 build 66 release (tag commit c7095365, cask in
CodesWhat/homebrew-tap#30) is recorded in the [roadmap](ROADMAP.md); it
followed promotion PR #44 and provenance PR #46. The v0.1.2
candidate/SBOM snapshot-binding follow-up was completed in the v0.2.0 release
work, including PR #21.
