# Aquarium runtime

`Sources/IdleScreenRenderer/Resources/AquariumRuntime/` is the authoritative
Three.js aquarium source. Make future scene changes there. Development
prototypes are historical inputs, not a second source to synchronize back into
the product.

`IdleScreenAquariumRuntime.sceneURL` resolves the entry point from
`IdleScreenRenderer.framework` using a bundle class locator. The resource folder
retains the script hierarchy, including its pinned Three.js dependency and MIT
notice. It contains procedural artwork, not reference photographs or exported
study pages. Source citation strings in the scripts are inert metadata. The
entry point denies network connections and loads only local scripts.

`PROVENANCE.json` records the import date, original entry digest, ordered runtime
closure and each imported file's original digest. Those source digests remain
the import baseline when product code changes; git records subsequent edits.
The vendor digests identify unmodified Three.js r160 bytes verified against
upstream commit `d04539a76736ff500cae883d6a38b3dd8643c548`. An intentional vendor
upgrade must update the code, license, provenance and tests together. Update
`scriptOrder` when adding, removing or reordering a runtime script.

The native entry starts paused, selects saver interaction mode, hides study
controls and couples displayed water condition to the ecosystem. Native hosts
call `window.idleScreenScene.setAnimating(Boolean)` through the WebKit adapter.
That bridge delegates to the aquarium's existing motion controller. Visibility
may suspend a running scene; it cannot restart a scene the native host paused.
The native host owns reduced-motion policy.

`AquariumRuntimeBundleTests` loads the actual framework resource through
WKWebView. Its synthetic visible-document state and deterministic animation
clock exercise the real scene and WebGL renderer while checking tank dimensions,
draw activity, water/ecology coupling and preservation of life across
pause/resume. An unmodified hidden document is also checked for suspended life.
This is unsigned
test-host evidence. Signed screensaver-host compositing, WebKit subprocess
sandbox behavior and real idle lifecycle remain separate verification gates.

The companion app's Aquarium workspace embeds this runtime in its Planted tank
view. The Existing tanks view retains the earlier aquarium implementation. The
planted-tank checkpoint is separate from that library and is not yet shared with
the pop-out or screensaver presentation. Signed host integration remains
unverified.

## Editing existing preset objects

The runtime exposes `aquariumStudy.applyPresetObjects({expectedRevision, objects})`
for the existing preset plants and hardscape. Read `presetRevision` and
`presetObjects` from the scene state. The editor must be open in desktop mode;
playback rejects these operations. The complete object list also expresses
removal, and restoring a removed record restores its original scene resources.

Edits use the same bounds and triangle checks as added specimens. Invalid edits
restore the exact previous transforms, and stale revisions leave the scene
unchanged. Successful edits recapture actual wet collision sources, revalidate
added specimens and refresh navigation and breeding supports. They do not
rebuild animals, advance biology or replace the active feeding state. The
operation keeps each object's authored support height. The native editor exposes
preset editing, added specimens and basic equipment placement through the same
surface. Attached plants align with their support face; moving a support in a
way that invalidates a mounted plant is rejected. Parent-following mounts remain
open. See [equipment editing](AQUARIUM_EQUIPMENT.md) and
[checkpoint persistence](AQUARIUM_CHECKPOINTS.md) for their current limits.

## Finished animal inventory

`AquariumTankConfiguration.stockCatalog` is the shared immutable inventory for
supported individual animals. Stable `kind/variant` identities cover the 11 fish
variants, 21 shrimp variants, Otocinclus, assassin and nerite snails already
supported by the runtime. The native editor snapshot exposes the same entries.
The mixed-color `skittles` tank preset is not an individual animal, and
review-only forms are excluded. This registry does not implement purchases,
pricing or an economy.

## Living animal removal

The planted-tank inspector lists the retained animals. Removing a living animal
prepares a normalized replacement checkpoint without mutating the live scene.
Food motion, chemistry, feeding history, remaining actors and existing deposits
are preserved. A carried brood leaves with its mother; already deposited eggs
remain in the tank. Dead animals are excluded from this action.

The native editor pauses its current surface, restores the replacement into a
separate paused surface, and writes it through the existing store revision check
before swapping views. A restore or stale-save failure keeps the current surface
and file intact. The replacement remains paused if the workspace hides during
the operation. Layout history remains separate from animal removal. Purchasing
new stock and an animal-specific undo history remain unfinished.

## Isolated native QA

A Debug QA bundle with an identifier under `com.idlescreen.aquarium-qa.` can
provide an absolute private legacy-tank path in `IdleScreenAquariumQAStorePath`.
The planted-tank checkpoint uses the same directory. Normal app bundles ignore
this profile, and Release builds do not read it. This lets native automation
launch the actual app executable without a command-line wrapper. The existing
Debug `--aquarium-store-path` argument takes precedence.
