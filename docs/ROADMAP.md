# IdleScreen roadmap

Last updated: November 3, 2026

IdleScreen 0.1 is a released public product. The companion app, modern
screen-saver extension, Metal renderer, camera agent, multi-display planner,
Pixel Materials, Saved Looks, and optional local agent signals are implemented.
This roadmap tracks the current release and the compatibility work that remains
useful after it ships.

## v0.3.0

Status: in progress. The last GA is `v0.2.0` (build 65, November 3, 2026). This
release is prepared as `0.3.0` build 66.

- Frame the saver on a horizon with a Cobalt default palette, a sprite lattice,
  Departure Mono glyphs, per-seed variation, aspect handling and a crossfade.
- Add a Topograph scene, agent status sprites in the saver and the Agents
  preview, and a one-signal-per-agent feed that drives them.
- Add real saver thumbnails and a plain status pill to Studio, and bring Studio
  into the shared design language.
- Add a docs site (Fumadocs) next to the marketing website.
- Run every offline release fixture from CI and `scripts/verify.sh`.

## v0.2.0

Status: released as `0.2.0` build 65 on November 3, 2026.

- Add a CRT menu bar icon with setup, attention, camera preview, running and
  idle states, and pin a frame under Reduce Motion.
- Add a first-run setup flow: register the saver, choose it in Screen Saver
  settings, then optionally set up a camera.
- Rebuild the Displays, Integrations and System settings pages on a shared
  design language that follows the system appearance and Increase Contrast.
- Show "IdleScreen" as the app, saver and camera agent name in macOS. The
  installed path is now `/Applications/IdleScreen.app`.
- Keep the companion in the menu bar and drop its Dock tile when the main
  window closes.
- Give the app icon a phosphor background so the CRT chassis reads at Dock size.
- Fix the Codecov upload, run syntax checks per file, let the CI contract accept
  Renovate action pin bumps, and slim the pre-push hook down to
  `scripts/verify.sh` with a stall and zero-test guard on the scheme runner.
- Stage the generated SBOM through a temporary file so an interrupted run
  cannot strand a partial `.spdx.json`.
- Scope the renderer zero-drop budget to the named benchmark host, matching the
  camera duplicate-copy benchmark.
- Bind the candidate verifier and SBOM generator to one descriptor-held
  immutable snapshot, closing the X48 TOCTOU finding from the v0.1.2 promotion
  review.
- Add a consent-gated attended runner that consumes short-lived
  signed-candidate plans, bounds camera lifecycle soaks, and records
  process-scoped energy samples.

The physical lifecycle matrix does not gate this release. The README lists what
was not verified on a device instead.

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

These are not required to withhold a release from existing users, but remain
useful coverage and product work:

- Run the physical lifecycle matrix (sleep/wake, reboot, Background Items,
  app replacement, camera permission, contention and device changes, multiple
  views, displays, Spaces and users, crash recovery, soak) on a device and move
  each row out of the README's not-verified list.
- Rename the installed app path to IdleScreen.app with a cask migration.
- Repeat the full mixed-scale multi-display, hot-plug, Spaces, and sleep/wake
  matrix on additional physical Mac configurations.
- Smoke-test the next macOS beta and Intel hardware while universal support is
  advertised.
- Move signed-release construction and artifact attestations into GitHub Actions
  after Apple signing and notary credentials have an approved enrollment path.
- Consider the optional custom-pet importer only with explicit user-owned art
  and provenance-safe inputs.
- Consider a local MCP surface only if it remains content-minimal and does not
  duplicate the bundled command integration.

Detailed local execution evidence and consent-gated physical procedures stay
under the git-ignored `.planning/` tree.
