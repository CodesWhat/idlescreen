# Changelog

All notable changes to idlescreen are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/CodesWhat/idlescreen/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/CodesWhat/idlescreen/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/CodesWhat/idlescreen/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/CodesWhat/idlescreen/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/CodesWhat/idlescreen/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/CodesWhat/idlescreen/releases/tag/v0.1.0
