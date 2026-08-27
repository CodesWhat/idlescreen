# IdleScreen roadmap

Last updated: August 27, 2026

IdleScreen 0.1 is a released public product. The companion app, modern
screen-saver extension, Metal renderer, camera agent, multi-display planner,
Pixel Materials, Saved Looks, and optional local agent signals are implemented.
This roadmap tracks the current patch and the compatibility work that remains
useful after it ships.

## v0.1.2 patch release

Status: implementation and reviewed development merge complete. Publication is
blocked before artifact creation until Apple notarization authentication is
renewed.

- Enforce the generated fail-closed saver camera activation policy.
- Move procedural glyph generation from the main actor to bounded Metal
  compute while preserving deterministic CPU parity.
- Avoid copying duplicate camera payloads and preserve safe transient-frame
  behavior in the shared saver pump.
- Cover WallpaperAgent refresh, registration repair, and the initial saver
  frame with direct regression tests.
- Align contributor docs, hooks, CI, code scanning, coverage, dependency
  review, secret scanning, Scorecard, release-tag protection, and review
  automation with the current CodesWhat standards.
- Build, sign, notarize, verify, publish, and install one immutable candidate.
- Generate an SPDX 2.3 SBOM from the accepted candidate manifest.
- Update the Homebrew cask from the verified candidate manifest.

## Completed product foundation

- One native companion containing the extension, renderer framework, camera
  agent, and local integration command
- 18 procedural patterns plus live camera glyph rendering
- Panorama, Per Display, and Focus Display scene planning
- Deterministic Pixel Materials sand and water scenes
- Saved Looks, camera selection, mirroring, and native Studio controls
- Expiring privacy-minimal Codex and Claude lifecycle signals
- Developer ID signing, notarization, Gatekeeper, mounted-byte verification,
  and generated Homebrew distribution

## Compatibility and product follow-up

These are not required to withhold a corrective patch from existing users, but
remain useful coverage and product work:

- Repeat the full mixed-scale multi-display, hot-plug, Spaces, and sleep/wake
  matrix on additional physical Mac configurations.
- Smoke-test the next macOS beta and Intel hardware while universal support is
  advertised.
- Add a controlled physical runner for scheduled lifecycle and energy soaks.
- Move signed-release construction and artifact attestations into GitHub Actions
  after Apple signing and notary credentials have an approved enrollment path.
- Consider the optional custom-pet importer only with explicit user-owned art
  and provenance-safe inputs.
- Consider a local MCP surface only if it remains content-minimal and does not
  duplicate the bundled command integration.

Detailed local execution evidence and consent-gated physical procedures stay
under the git-ignored `.planning/` tree.
