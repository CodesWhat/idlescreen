# IdleScreen contributor instructions

## Purpose

IdleScreen is a macOS 26 screen saver and companion app. It renders procedural
and camera-driven glyph scenes with Metal. The distributed product is one
signed app containing the screen-saver extension, camera agent, renderer
framework, and local integration command.

## Repository layout

- `Products/` contains the app, extension, helper, and command entry points.
- `Sources/` contains shared production modules.
- `Tests/` contains unit and integration test targets.
- `Support/` contains test-only performance and synthetic-gate executables.
- `project.yml` is the XcodeGen source of truth. Keep the checked-in
  `IdleScreen.xcodeproj` synchronized with it.
- `scripts/` owns deterministic, physical, signing, and release gates.
- `.planning/` is ignored local evidence and planning. It is never published.

## Setup and local gates

Install Xcode 26, XcodeGen 2.46.0, Lefthook, Qlty, actionlint, and zizmor. Then
run:

```sh
xcodegen generate
lefthook install
./scripts/test-repository-layout.sh
./scripts/test-project-contracts.sh
./scripts/check-swift-format.sh changed
./scripts/qlty-check-gate.sh all
./scripts/verify-workflows.sh
./scripts/test-modern-schemes.sh
./scripts/test-companion-compile-gate.sh
xcodebuild build -quiet -project IdleScreen.xcodeproj -scheme IdleScreenApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

Run the release fixture gates before changing signing, notarization, packaging,
or Homebrew behavior:

```sh
./scripts/test-release-archive-provenance-fixtures.sh
./scripts/test-r1-release-candidate-fixtures.sh
./scripts/test-public-release-contract.sh
```

The installed Lefthook pipeline enforces Conventional Commits, formats staged
Swift files, requires a clean pre-push tree, and mirrors the source, test,
workflow-security, fixture, and Release build gates.

## Test conventions

Add deterministic coverage for non-trivial behavior. Keep physical effects out
of ordinary tests. Camera, TCC, ScreenSaverEngine, registration, display,
sleep/wake, lock, and installation scripts must retain their explicit consent
guards. Never weaken a guard to make a fixture pass.

Swift formatting is ratcheted. `.swift-format-baseline` exempts only exact
reviewed file hashes that predate enforcement. Editing one of those files means
formatting it and removing its stale baseline entry.

## Architecture invariants

- Only `IdleScreenCameraAgent` may link AVFoundation or open a camera.
- Camera demand requires the generated fail-closed shipping activation policy.
- XPC peers, App Group paths, epochs, generations, and frame sequences remain
  fail closed.
- The companion and extension use the same configuration, display planner,
  renderer, and frame transport.
- Raw camera pixels and private agent content never enter logs or evidence.
- Release verification covers nested signatures, profiles, entitlements,
  notarization, Gatekeeper, and mounted DMG bytes.

## Git and review

Use plain Conventional Commits. Ordinary pull requests target the active
`dev/v0.1` branch. `main` advances only through a reviewed promotion pull
request from the active development branch and must immediately receive its GA
release tag. CodeRabbit reviews every pull request. The `second-opinion` label
is the only trigger for Greptile.

Never weaken branch or tag protection. Never commit `.planning/`, raw evidence,
credentials, personal paths, generated release artifacts, or design exports.

## Release

The current release authority is `scripts/build-r1-release-candidate.sh` on a
controlled Mac with the existing Developer ID identity, distribution profiles,
and notary profile. Follow [docs/BUILDING.md](docs/BUILDING.md). Publish only a
clean, committed candidate whose manifest replays exactly, then generate the
Homebrew cask from that immutable manifest. `main` must equal the final GA tag.
Generate the SPDX release SBOM from the same manifest and publish it beside the
DMG and candidate manifest.
