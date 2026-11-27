# Changelog

All notable changes to idlescreen are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add GitHub provenance and SBOM attestations for the DMG, the candidate
  manifest and the SPDX SBOM of each release published from now on, through
  `release-attest.yml`. v0.4.0 predates it and has none.
- Add `scripts/check-release-reproducibility.sh <tag>`, which needs no signing
  credentials and checks a tag's source, project files and bundle version
  against the published candidate manifest. v0.4.0 matches on all six
  comparable fields.
- Add `scripts/check-promotion-codeql.sh <pr-number>`, which checks a promotion
  PR's merge ref for open code-scanning alerts that are high or critical (or
  error severity when an alert has no security severity), after confirming
  CodeQL has analyzed the current merge commit.
- Add a fixed 80% line-coverage floor to CI (`scripts/check_coverage_floor.py`
  and `codecov.yml`), and tests that bring line coverage above it.
- Add native stock editing for the aquarium: add supported adults and remove
  living animals through staged, validated edits, with undo and a live animal
  inspector, plus new tank controls and premium equipment.
- Add the Maintainability badge and enable shellcheck, zizmor and osv-scanner
  in Qlty.

### Changed

- State that macOS 26 (Tahoe) is supported and macOS 27 is untested.
- The release builder falls back to an App Store Connect API key when the
  notarytool Keychain profile is missing.
- CI installs XcodeGen 2.46.0 from a checksum-pinned release instead of
  Homebrew, and the shared CodesWhat workflows are pinned to a newer commit.
- Split the Pixel Materials terrain generation and sand movement code, with
  characterization tests that pin the output.

### Fixed

- Exporting an aquarium tank no longer fails after a feed pellet has settled
  on the gravel.
- Aquarium animals grazing at a lifted stop rest on the surface instead of
  hovering, and the frame cache drops an oversized donated raster so a
  narrower scene doesn't keep the wide capacity.
- A first camera mailbox read older than the frame age limit is rejected.
- Health report retention takes one locked inspection to classify and prune.
- Setup no longer skips the camera step and the all-set card on a Mac you
  finished by hand after a failed first refresh.
- A saved quiet-hours window outside the valid range is clamped when the agent
  configuration loads.
- Serialize the WebGL surface test suites and release leaked contexts, fix
  flaky aquarium, camera and notary tests, and time the renderer budget in
  thread CPU time.

## [0.4.0] - 2026-11-21

### Added

- Add the Aquarium pattern, a planted pixel-art tank with shrimp, fish and crabs.
  You can edit the tank natively (plants, hardscape, equipment, specimens and
  saved layouts), run it on the desktop or in a window, and it honors reduced
  motion.

### Changed

- IdleScreen now supports Apple silicon Macs only.
- The desktop aquarium caps itself at 30 fps on battery and reuses unchanged
  layers between frames, so it costs less to run.
- Camera sampling reads frames in place instead of copying each one whole.

### Fixed

- Toggling Low Power Mode no longer crashes the app while the aquarium runs.
- A malformed or newer configuration.json is no longer overwritten by the first
  Studio edit.
- Hooks installed from an app that was later moved are now found and removed,
  and a symlinked `~/.claude/settings.json` or `~/.codex/hooks.json` is written
  through instead of being replaced.
- Clear all repairs an unreadable agent inbox, agent sprites come back after a
  failed inbox read, and a second permission request in the same Codex turn is
  no longer dropped.
- Health reports are capped instead of accumulating forever.
- Saved tanks reopen with their saved layout.
- Remove failed C8 plan output entries after poisoning so a retry can use the
  same path, while retaining inode ownership checks and refusal errors.
- Distinguish renderer failures from allowed GPU back-pressure in the
  three-renderer submission benchmark.
- Correct the shipped 0.3.0 roadmap, current app install paths and private
  security-reporting guidance.
- Correct the procedural pattern count to 19 (Topograph was missing), add the
  current release to the README, refresh the project status record, and document
  how the camera frame mailbox is stored and cleared.

## [0.3.0] - 2026-11-04

### Added

- Added a docs site at `idlescreen.codeswhat.com/docs` (Fumadocs) next to the
  marketing website, with browser checks in the required build-and-test job.

- Added a Topograph scene, agent status sprites in the saver and the Agents
  preview, and a one-signal-per-agent feed that drives them.
- Added real saver thumbnails and a plain status pill to Studio.
- Added `scripts/test-release-sbom-symlinks.sh`, and CI plus `scripts/verify.sh`
  now run every offline release fixture.

### Changed

- Gave the companion a large display-shaped preview with compact bottom controls,
  a visible scene library, and an inspector available through More.
- Added top navigation for Scene, Displays, Agents and Settings, consistent
  Instrument typography, and simpler settings rows.
- Remembered inspector visibility, the library tab and the selected display;
  added keyboard shortcuts for navigation, the library and the inspector.
- Let the app window resize freely while previews keep each display's proportions,
  and fitted oversized restored windows to the available screen.
- Replaced the flat pixel CRT logo with CRT Silver across the app and website.
- Made Topograph honor Full Bleed and Horizon framing, and made Full Bleed the
  default for new configurations.


- Added optional horizon framing, with Cobalt as the default palette, a sprite
  lattice, Departure Mono glyphs, per-seed variation, aspect handling, a
  crossfade and steadier pacing.
- Brought Studio into the shared design language, with VoiceOver names for its
  fields.
- Setup now fills the window in two columns, pages use wider columns, and
  registration errors are plain with a note on development builds.
- Installed the app at `/Applications/IdleScreen.app` instead of
  `/Applications/idlescreen.app`. `brew upgrade --cask idlescreen` removes the
  old copy first; the camera agent re-registers from the new path on launch.

### Fixed

- Remembered an Allow camera access click made before the camera helper is
  ready, and fired it once when the helper verifies.
- Made the SBOM snapshot root canonical under `/tmp`.
- The accessibility-label check now catches empty control titles on their own
  line.

## [0.2.0] - 2026-11-03

### Added

- Added a CRT menu bar icon with setup, attention, camera preview, running and
  idle states. Reduce Motion pins a single frame.
- Added a first-run setup flow: register the saver, choose it in Screen Saver
  settings, then optionally set up a camera.
- Added a plain-language Status page. It says in a sentence or two whether the
  saver, the screen saver choice and the camera are working, and keeps the raw
  diagnostics under Details. The System page is now Status and the Integrations
  page is now Agents in the sidebar.
- Added a pixel CRT logo and app icon, replacing the earlier icon.
- Added `scripts/check-tool-versions.sh`, reporting where locally installed gate
  tools disagree with the versions `docs/BUILDING.md` declares.
- Added `scripts/verify.sh` and a stall and zero-test guard on the scheme runner.

### Changed

- Switched the app to Departure Mono for headings and Inter for body text, with
  a cobalt accent. Both fonts are bundled under the OFL.
- Rebuilt the Displays, Agents and Status settings pages on a shared
  design language. They follow the system light and dark appearance and
  Increase Contrast, Studio stays dark, copy is in plain language, raw
  diagnostics sit under Details, and controls have accessibility labels.
- Showed "IdleScreen" as the app, screen saver and camera agent name in the
  Camera privacy list, Login Items and the screen saver picker. The installed
  path stays `/Applications/idlescreen.app`.
- Slimmed the pre-push hook down to `scripts/verify.sh`.
- Ran syntax checks per file, and let the CI contract accept Renovate action pin
  bumps.
- Kept the companion in the menu bar and dropped its Dock tile when the main
  window closes, so the tile no longer outlives the window it belongs to.
- Pointed the Codecov upload at the coverage reports the preceding job writes,
  so a failed upload can no longer pass silently.
- Described the Homebrew integration as installing the signed, notarized DMG
  rather than calling the generated cask itself signed.
- Documented the exact SBOM attachment name the published download URL depends
  on, and stopped recommending that the Qlty installer be piped into a shell.

- Scoped the renderer zero-drop budget to the named benchmark host, matching the
  camera duplicate-copy benchmark.
- Bound the candidate verifier and SBOM generator to one descriptor-held
  immutable snapshot, closing a time-of-check/time-of-use gap in release
  verification.
- Added a consent-gated attended runner that consumes short-lived signed
  candidate plans, bounds camera lifecycle soaks, and records process-scoped
  energy samples.

### Fixed

- Staged the generated SBOM through a temporary file so an interrupted run
  cannot leave a short `.spdx.json` that blocks every later generation.

## [0.1.2] - 2026-08-29

### Added

- Added a manifest-bound SPDX 2.3 SBOM for the signed release DMG and adapted
  third-party declarations.

### Changed

- Moved procedural glyph generation to a bounded Metal compute pass while
  preserving the CPU renderer as the deterministic fallback and test oracle.
- Reduced live-camera mailbox work by rejecting duplicate frames before copying
  their pixel payloads.

### Fixed

- Enforced the generated fail-closed camera activation policy in the shipping
  screen-saver host instead of starting capture from an unverified preview
  hint.
- Preserved the last valid camera frame through short read gaps, cleared it on
  lease loss, and stopped the shared frame pump after its final consumer exits.
- Strengthened screen-saver registration repair and WallpaperAgent refresh
  checks against stale, multiple, or identity-mismatched host processes.
- Rendered the initial fallback frame synchronously so the saver never starts
  with an empty view while Metal initializes.
- Released the Studio camera preview lease when a display-plan change alone
  quiets the previewed display, so the camera indicator no longer stays lit
  after a scene-policy or display-topology change.
- Aligned the bundled camera agent's bundle and marketing versions with the
  shipping app so upgrade staleness checks can distinguish one release's
  helper from another's.

## [0.1.1] - 2026-08-13

### Fixed

- Restored the original CRT artwork as the installed app icon.
- Allowed fresh Developer ID installs to request camera access through the
  responsible companion while keeping all capture APIs inside the camera agent.

## [0.1.0] - 2026-08-12

Initial public release.

### Added

- A signed and notarized universal macOS app with 19 Metal-rendered procedural
  patterns, live camera effects, multi-display layouts, and saved looks.
- Distribution through the official `codeswhat/tap/idlescreen` Homebrew cask.
- Public repository documentation, contribution guidance, security reporting,
  and project governance files.

### Changed

- Private planning, raw evidence, design exports, and legacy recovery material
  are no longer part of the public source tree.

[Unreleased]: https://github.com/CodesWhat/idlescreen/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/CodesWhat/idlescreen/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/CodesWhat/idlescreen/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/CodesWhat/idlescreen/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/CodesWhat/idlescreen/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/CodesWhat/idlescreen/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/CodesWhat/idlescreen/releases/tag/v0.1.0
