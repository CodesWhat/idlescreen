# Project status and house audit

Audit date: August 27, 2026

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
| Main protection | PRs, two approvals, code owners, current head approval, required checks, CodeQL | Active ruleset with no bypass actors; new checks await a representative PR before becoming required | In progress |
| Contributor files | Repo-specific AGENTS, CONTRIBUTING, SECURITY, ownership, license | Present and aligned to `dev/v0.1` and the exact local gates | Pass in branch |
| Local gates | Conventional Commits, clean-tree pre-push, formatter, Qlty, tests, build, workflow security | Lefthook and repository scripts added | Pass in branch |
| Primary CI | Main and dev PR/push coverage, pinned actions, least privilege, hardened runners | `ci-verify.yml` covers full Xcode schemes, fixtures, Release build, Qlty, Swift format, and Codecov | Pass in branch |
| Workflow security | actionlint, zizmor, Gitleaks, dependency review | Pinned dedicated workflow added; local actionlint, zizmor, Qlty, and Gitleaks are green | Pass in branch |
| Code scanning | CodeQL for Actions, C/C++, Python, and Swift | SHA-pinned, hardened workflow covers `main` and `dev/**` | Pass in branch |
| Public security | Private reporting, secret scanning, push protection, Dependabot | Enabled live; no open CodeQL or Dependabot alerts at audit time | Pass |
| Review automation | CodeRabbit on dev PRs; Greptile only by label | Dev base configured; `second-opinion` is label-gated and automatic only for named high-risk changes | Pass in branch |
| README | Product shape, live badges, install path, community routing | Product shape adopted; Scorecard and Codecov badges require their first default-branch run | Verify after release |
| Release engineering | Clean immutable candidate, Developer ID, notarization, Gatekeeper, manifest-derived cask | Existing fail-closed local release authority and fixture matrix remain canonical | Pass |
| Build provenance | SBOM and workflow identity for shipped artifacts | A manifest-bound SPDX 2.3 SBOM is generated for the shipped DMG; GitHub Actions migration would require moving Apple signing and notary credentials | Local SBOM passes; Actions attestation tracked |
| Repository metadata | Public product description, topics, Discussions, detected MIT license | Description, topics, Discussions, and MIT license detection are live | Pass |

## App review status

The August 27 whole-app review accepted seven findings. All seven fixes and
their regression tests are committed on the release branch. The deterministic
scheme matrix, release fixtures, project generation, Release build, and
performance measurements passed before this audit. See [CHANGELOG.md](../CHANGELOG.md)
and the [roadmap](ROADMAP.md) for the user-facing scope.

## Release exit

The audit closes when the feature PR and promotion PR are merged with required
reviews, v0.1.2 exactly tags `main`, the attached DMG and manifest replay, the
SBOM and Homebrew cask bind to that checksum, and the public badges and live
rulesets are re-read after publication.
