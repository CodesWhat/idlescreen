# Building idlescreen

## Requirements

- Apple silicon Mac (M1 or later), macOS 26 Tahoe or later
- Xcode 26
- XcodeGen 2.46.0
- Python 3 for deterministic fixture tests
- Lefthook 2.1.12, Qlty 0.618.0, actionlint 1.7.12, and zizmor 1.29.0 for
  repository gates

Install the Homebrew-provided tools and Qlty's signed release CLI. Download the
Qlty installer and read it before running it rather than piping it into a shell,
so an upstream change to that script cannot execute unseen:

```sh
brew install xcodegen lefthook actionlint zizmor
curl -fsSL https://qlty.sh -o /tmp/qlty-install.sh
less /tmp/qlty-install.sh
sh /tmp/qlty-install.sh
```

Homebrew installs whatever is current, which is not necessarily the version the
gate expects. Check what you got against the versions listed above before
relying on a local pass:

```sh
./scripts/check-tool-versions.sh
```

CI does not depend on any of this. It installs the sha256-pinned XcodeGen 2.46.0
release with `scripts/install-xcodegen.sh` (not Homebrew), asserts
`xcodegen --version` exactly, and
installs Qlty from `qltysh/qlty-action/install` pinned to a full commit SHA, so
a local version mismatch shows up as a disagreement with CI rather than as a
silent pass.

Generate the checked-in project:

```sh
xcodegen generate
git diff --exit-code -- IdleScreen.xcodeproj
```

Open `IdleScreen.xcodeproj` and run the `IdleScreenApp` scheme for normal local
development.

Install the hooks and run the repository-owned gates with:

```sh
lefthook install
./scripts/check-swift-format.sh changed
./scripts/qlty-check-gate.sh all
./scripts/verify-workflows.sh
./scripts/test-modern-schemes.sh
```

`scripts/verify-workflows.sh` runs actionlint and zizmor when they are present.
It reports a skip when either tool is unavailable because CI remains the
authoritative workflow-security gate. Lefthook and Qlty are required for their
respective local commands and fail when unavailable.

## Safe deterministic checks

These checks do not install the app, register a helper or screen saver, request
camera access, open System Settings, or change power state:

```sh
./scripts/test-repository-layout.sh
./scripts/test-project-contracts.sh
python3 ./scripts/test_xccov_to_lcov.py
./scripts/test-companion-compile-gate.sh
python3 ./scripts/test_performance_r1_report.py
./scripts/test-run-performance-r1.sh
./scripts/test-camera-gate-c8-soak-planner.py
./scripts/test-controlled-physical-soak.py
./scripts/test-idlescreenctl-runtime.sh
./scripts/test-camera-agent-product-fixtures.sh
./scripts/test-synthetic-gate-product-fixtures.sh
./scripts/test-release-archive-provenance-fixtures.sh
./scripts/test-r1-release-candidate-fixtures.sh
./scripts/test-public-release-contract.sh
```

CI also runs the modern Xcode unit and integration schemes with Swift warnings
treated as errors, CodeQL, workflow security, Qlty, and Codecov coverage. The
companion compile gate prints the temporary directory
containing its disposable build log.

On trusted pushes, the coverage job exports each tested scheme's Xcode archive
line counts and converts them with `scripts/xccov_to_lcov.py` to one explicit
LCOV report. It includes instrumented files under `Sources/` and `Products/`,
excluding tests, support executables and build output. Across schemes, each
line keeps its highest execution count, so duplicate instrumentation does not
inflate counts and an uncovered line stays visible until exercised elsewhere.
Every input must contain executable production lines; malformed or empty data
fails before uploading. Codecov receives only that report, with automatic Xcode
rediscovery disabled and upload errors failing the job. This makes generation
and upload failures visible without imposing a numeric coverage target or
replacing provider-side project/patch settings.

## Physical checks

Scripts that install products, register services, open a camera, start the
screen saver, lock the session, change displays, or alter system state are
separately consent-gated. Their default behavior is to refuse the action.

Never run a physical script by copying an opt-in from a fixture or another test
session. Read the script's refusal message, confirm the exact candidate and
scope, and authorize only the action being performed.

The controlled C8 soak planner provides scheduling only. The separate
`run-controlled-physical-soak.py` entry point consumes a short-lived
signed-candidate plan after both physical-test and class-scoped authorization,
requires an attended TTY confirmation, bounds observation of an operator-driven
camera lifecycle, and records process-scoped energy samples. It starts only its
own log collector and sampler process groups. It never starts or stops a product
process and never sleeps, reboots, logs out, locks, changes displays, changes
TCC, installs, registers, or terminates a product process.
The planner and attended runner cannot claim C8 row completion, update a C8
matrix, or emit verifier-valid C8 evidence. The runner emits distinct
`IdleScreenControlledSoakPlan/v1`, `IdleScreenControlledSoakEnergy/v1`, and
`IdleScreenControlledSoakResult/v1` artifacts, with
`c8_evidence_completed:false`. C8 release evidence remains a separate
operator-collected and verified workflow.

Run `./scripts/test-controlled-physical-soak.py` after the C8 planner fixture
to verify the attended runner contracts.
Lifecycle evidence contains exactly one ordered `start` and `stop` event for
the same privacy-safe saver instance; reversed or cross-instance log records
are rejected.
Plan creation claims the final output name directly with an exclusive no-follow
open, keeping the inode at mode `000` until its content and durability checks
finish. A failed write may strand a mode-`000` partial file at that name; it is
not a valid plan and must be discarded before retrying. Every resolved output
ancestor must be owned by root or the current user, have no group/other write
permission, and have no extended ACL. No C8 schedule command initiates sleep,
reboot, logout, display, registration, installation, TCC, or process changes.

## Release candidates

`scripts/build-r1-release-candidate.sh` is the Developer ID distribution
authority. A real run requires:

- a clean committed source tree;
- an absolute, nonexistent output directory outside the repository;
- the exact Developer ID Application identity SHA-1;
- separate Developer ID distribution profiles for the app, extension, and
  camera helper;
- an existing `notarytool` Keychain profile (or the App Store Connect API key
  fallback described below); and
- `IDLESCREEN_ALLOW_REAL_DISTRIBUTION=YES`.

The builder archives the app, verifies the development-signed provenance,
embeds release identity, signs nested code from the inside out, creates a UDZO
DMG, submits it for notarization, staples it, mounts it read-only, and asks
Gatekeeper to assess both the DMG and mounted app. It never creates or stores
credentials and never signs code after notarization.

### Notarization credential fallback

The builder tries `--keychain-profile $IDLESCREEN_NOTARY_KEYCHAIN_PROFILE`
first. If `notarytool` reports that the profile is missing (the
`idlescreen-notary-2026` profile has vanished from the login Keychain before),
it retries with the App Store Connect API key from these variables:

- `IDLESCREEN_ASC_KEY_PATH`: absolute path to the `AuthKey_<id>.p8` file;
- `IDLESCREEN_ASC_KEY_ID`: the 10-character key ID; and
- `IDLESCREEN_ASC_ISSUER_ID`: the issuer UUID.

All three must be set, and `IDLESCREEN_NOTARY_KEYCHAIN_PROFILE` must still
name a profile (it can be one whose Keychain item is absent). The builder copies
the key into its private scratch directory once and uses that copy for every
later `notarytool` call in the run. Any other profile failure (network, revoked credentials) stops the
run without falling back, and if neither credential works the run exits with a
`BLOCKED` message. Secret values are never printed.
`scripts/test-notary-credential-fallback.sh` covers the three cases with a stub
`notarytool`.

Replay a completed candidate with:

```sh
./scripts/verify-r1-release-candidate.sh \
  /absolute/candidate/Distribution/idlescreen-0.4.0-build67.dmg \
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
pass. Publish the DMG on the matching GitHub release before proposing
the generated cask to `CodesWhat/homebrew-tap`.

Generate and publish the SPDX 2.3 SBOM from the same verified manifest:

```sh
./scripts/generate-release-sbom.sh \
  /absolute/candidate/IdleScreenR1ReleaseCandidateV1.txt \
  /absolute/output/idlescreen-0.4.0-build67.spdx.json
```

The SBOM generator replays the candidate verifier, binds the final DMG SHA-256,
and records the adapted AppexSaverMinimal declarations from the third-party
notice.

Attach that file to the matching GitHub release under exactly the name
`idlescreen-<version>-build<build>.spdx.json`, alongside the DMG and
`IdleScreenR1ReleaseCandidateV1.txt`. The name is load-bearing: the published
download URL is derived from it, so a release whose SBOM is attached under any
other name reads as having no SBOM at all.

### Provenance attestations

Publishing the GitHub release triggers `.github/workflows/release-attest.yml`.
It downloads the DMG, `IdleScreenR1ReleaseCandidateV1.txt` and the SPDX SBOM,
checks the DMG SHA-256 against the manifest's `stapled_dmg_sha256`, and then
attaches GitHub build provenance attestations to all three plus an SBOM
attestation for the DMG. It never signs, modifies or re-uploads anything and
holds no secrets or Apple credentials. It also requires the manifest's
`source_commit` to equal the tag's commit and the SBOM's `idlescreen` package to
carry the DMG's SHA-256 as its checksum. To retry a release whose tag already
contains the workflow, dispatch it from the tag. Releases cut before the
workflow existed (v0.4.0 included) can't be backfilled this way, because
`--ref` picks the workflow file at that tag:

```sh
gh workflow run release-attest.yml --ref v0.4.0 -f tag=v0.4.0
```

Verify a downloaded DMG with:

```sh
gh attestation verify idlescreen-0.4.0-build67.dmg --repo CodesWhat/idlescreen
gh attestation verify idlescreen-0.4.0-build67.dmg --repo CodesWhat/idlescreen \
  --predicate-type https://spdx.dev/Document/v2.3
```

Ordinary changes target the protected `dev/v0.1` branch. `main` advances only
through a reviewed promotion pull request and must immediately receive the GA
tag so `git describe --exact-match origin/main` succeeds.

Before opening the promotion pull request, check `dev/v0.1` for open high
CodeQL alerts. The `main` ruleset has a `code_scanning` rule (errors, high or
higher) that blocks the promotion even when every dev pull request passed:

```sh
gh api --paginate "repos/CodesWhat/idlescreen/code-scanning/alerts?state=open&ref=refs/heads/dev/v0.1&per_page=100" \
  -q '.[] | select(if .rule.security_severity_level then (.rule.security_severity_level == "high" or .rule.security_severity_level == "critical") else .rule.severity == "error" end) | {number, rule: .rule.id, severity: (.rule.security_severity_level // .rule.severity), path: .most_recent_instance.location.path}'
```

`--paginate` reads every page. Security alerts are judged by their security
severity; error severity only counts for alerts without one, matching the
ruleset's thresholds.

Fix each alert, or dismiss it with a reason once it is verified as a false
positive. Never change the ruleset to get past it.

When rerunning CI, rerun all jobs, not only the failed ones. The quality report
aggregate only counts artifacts from the current attempt.

## Repository hygiene

Local roadmaps, raw test evidence, design exports, audit reports, and historical
recovery material belong in `.planning/`. That directory is ignored and must
never become tracked. Public documentation belongs under `docs/` and must not
contain personal filesystem paths or workstation inventories.
