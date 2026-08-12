# Building idlescreen

## Requirements

- macOS 26 Tahoe or later
- Xcode 26
- XcodeGen 2.46.0
- Python 3 for deterministic fixture tests

Install XcodeGen and generate the checked-in project:

```sh
brew install xcodegen
xcodegen generate
git diff --exit-code -- IdleScreen.xcodeproj
```

Open `IdleScreen.xcodeproj` and run the `IdleScreenApp` scheme for normal local
development.

## Safe deterministic checks

These checks do not install the app, register a helper or screen saver, request
camera access, open System Settings, or change power state:

```sh
./scripts/test-repository-layout.sh
./scripts/test-project-contracts.sh
./scripts/test-companion-compile-gate.sh
python3 ./scripts/test_performance_r1_report.py
./scripts/test-run-performance-r1.sh
./scripts/test-idlescreenctl-runtime.sh
./scripts/test-camera-agent-product-fixtures.sh
./scripts/test-synthetic-gate-product-fixtures.sh
./scripts/test-release-archive-provenance-fixtures.sh
./scripts/test-r1-release-candidate-fixtures.sh
./scripts/test-public-release-contract.sh
```

CI also runs the modern Xcode unit and integration schemes with Swift warnings
treated as errors. The companion compile gate prints the temporary directory
containing its disposable build log.

## Physical checks

Scripts that install products, register services, open a camera, start the
screen saver, lock the session, change displays, or alter system state are
separately consent-gated. Their default behavior is to refuse the action.

Never run a physical script by copying an opt-in from a fixture or another test
session. Read the script's refusal message, confirm the exact candidate and
scope, and authorize only the action being performed.

## Release candidates

`scripts/build-r1-release-candidate.sh` is the Developer ID distribution
authority. A real run requires:

- a clean committed source tree;
- an absolute, nonexistent output directory outside the repository;
- the exact Developer ID Application identity SHA-1;
- separate Developer ID distribution profiles for the app, extension, and
  camera helper;
- an existing `notarytool` Keychain profile; and
- `IDLESCREEN_ALLOW_REAL_DISTRIBUTION=YES`.

The builder archives the app, verifies the development-signed provenance,
embeds release identity, signs nested code from the inside out, creates a UDZO
DMG, submits it for notarization, staples it, mounts it read-only, and asks
Gatekeeper to assess both the DMG and mounted app. It never creates or stores
credentials and never signs code after notarization.

Replay a completed candidate with:

```sh
./scripts/verify-r1-release-candidate.sh \
  /absolute/candidate/Distribution/idlescreen-0.1.0-build62.dmg \
  /absolute/candidate/IdleScreenR1ReleaseCandidateV1.txt
```

The verifier checks source identity, manifests, certificates, CodeDirectory
hashes, entitlements, profiles, notarization, extended attributes, symlinks,
and the exact mounted bytes.

Generate the exact Homebrew cask from that immutable candidate with:

```sh
./scripts/generate-homebrew-cask.sh \
  /absolute/candidate/IdleScreenR1ReleaseCandidateV1.txt \
  /absolute/output/idlescreen.rb
```

The generator accepts only a clean stable release candidate whose notarization,
stapling, Gatekeeper results, canonical filename, and final DMG checksum all
pass. Publish the DMG on the matching `v0.1.0` GitHub release before proposing
the generated cask to `CodesWhat/homebrew-tap`.

## Repository hygiene

Local roadmaps, raw test evidence, design exports, audit reports, and historical
recovery material belong in `.planning/`. That directory is ignored and must
never become tracked. Public documentation belongs under `docs/` and must not
contain personal filesystem paths or workstation inventories.
