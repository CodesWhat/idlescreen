# Project status and house audit

Audit date: August 29, 2026

## Classification

IdleScreen is a public CodesWhat Swift product. It publishes a signed and
notarized universal macOS app, a GitHub release DMG, and a Homebrew cask. It has
no hosted service, container image, package registry artifact, localization
pipeline, or web runtime.

## Audit status

| Control | Expected state | Current state | Verdict |
| --- | --- | --- | --- |
| Default branch | `main` is the latest GA tag | `main` exactly matches the v0.1.2 GA tag at `1d357b82` | Pass |
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
| Release engineering | Clean immutable candidate, Developer ID, notarization, Gatekeeper, manifest-derived cask | The clean development source, signing identity, and all three Developer ID profiles pass the builder preflight; the team-scoped App Store Connect API key authenticates against submission history, the stale Apple ID notary profile has been removed so one working credential remains, and the Developer ID Application certificate is valid through 2027-02-01 | v0.1.2 candidate built, notarized, stapled and published |
| Build provenance | SBOM and workflow identity for shipped artifacts | A manifest-bound SPDX 2.3 SBOM is generated for the shipped DMG; GitHub Actions migration would require moving Apple signing and notary credentials | Local SBOM passes; Actions attestation tracked |
| Repository metadata | Public product description, topics, Discussions, detected MIT license | Description, topics, Discussions, and MIT license detection are live | Pass |

## App review status

The August 27 whole-app review accepted seven findings. All seven fixes and
their regression tests are committed on the release branch. The deterministic
scheme matrix, release fixtures, project generation, Release build, and
performance measurements passed before this audit. See [CHANGELOG.md](../CHANGELOG.md)
and the [roadmap](ROADMAP.md) for the user-facing scope.

## Release exit

v0.1.2 shipped on 2026-08-29. Every exit condition is met:

- Notarization authenticated through the team-scoped App Store Connect API key
  and produced one accepted candidate, 0 issues, stapled and Gatekeeper-checked.
- Promotion PR #15 merged with two non-author approvals and every required
  check green, after all seven CodeRabbit threads were answered and resolved.
- `v0.1.2` tags `main` exactly at `1d357b82`, `main` and `dev/v0.1` are
  tree-equal, and `main-is-released` passed on that commit.
- The published DMG was downloaded and re-hashed to
  `2e5ebbf222a060bba900baa7738c87bf4df58b7c9648b4885ab3ff5b78c7e687`, matching
  the manifest, the SBOM binding, and the generated cask.
- DMG, `IdleScreenR1ReleaseCandidateV1.txt` and the SPDX SBOM are attached to
  the release; the cask bump is CodesWhat/homebrew-tap#8.

Carried forward, none release-blocking: binding the candidate verifier and the
SBOM generator to a single immutable snapshot so the two cannot be pointed at
different bytes by a local principal, raised as a TOCTOU finding on #15 and
deferred rather than landed in a promotion PR.
