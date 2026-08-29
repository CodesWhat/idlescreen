# Changelog

All notable changes to idlescreen are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/CodesWhat/idlescreen/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/CodesWhat/idlescreen/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/CodesWhat/idlescreen/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/CodesWhat/idlescreen/releases/tag/v0.1.0
