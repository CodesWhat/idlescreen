# Project status and house audit

Audit date: August 28, 2026

## Classification

IdleScreen is a public CodesWhat Swift product. It publishes a signed and
notarized universal macOS app, a GitHub release DMG, and a Homebrew cask. It has
no hosted service, container image, package registry artifact, localization
pipeline, or web runtime.

## Audit status

| Control | Expected state | Current state | Verdict |
| --- | --- | --- | --- |
| Default branch | `main` is the latest GA tag | `main` is two commits past v0.1.1; v0.1.2 promotion will close the drift | Open until release |
| Development line | One active protected `dev/vX.Y` branch | `dev/v0.1` exists with deletion and force-push protection | Pass |
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
| Release engineering | Clean immutable candidate, Developer ID, notarization, Gatekeeper, manifest-derived cask | The clean development source, signing identity, and all three Developer ID profiles pass the builder preflight; the retained Apple ID notarization credential is locked and unused, while the team-scoped App Store Connect API key authenticates against submission history, and the Developer ID Application certificate is valid through 2027-02-01 | Ready for candidate creation |
| Build provenance | SBOM and workflow identity for shipped artifacts | A manifest-bound SPDX 2.3 SBOM is generated for the shipped DMG; GitHub Actions migration would require moving Apple signing and notary credentials | Local SBOM passes; Actions attestation tracked |
| Repository metadata | Public product description, topics, Discussions, detected MIT license | Description, topics, Discussions, and MIT license detection are live | Pass |

## App review status

The August 27 whole-app review accepted seven findings. All seven fixes and
their regression tests are committed on the release branch. The deterministic
scheme matrix, release fixtures, project generation, Release build, and
performance measurements passed before this audit. See [CHANGELOG.md](../CHANGELOG.md)
and the [roadmap](ROADMAP.md) for the user-facing scope.

## Release exit

The feature PR is merged and its stable checks are required on `main`. The
audit closes when refreshed notarization authentication produces one accepted
candidate, the promotion PR merges with required reviews, v0.1.2 exactly tags
`main`, the attached DMG and manifest replay, the SBOM and Homebrew cask bind
to that checksum, and the public badges and live rulesets are re-read after
publication.
