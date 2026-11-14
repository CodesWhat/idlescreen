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
review-only forms are excluded. This registry does not define pricing or an economy.

The scene inventory derives living fish, shrimp and snail counts from retained
ecology records. Its legacy `*Species` fields count modeled species groups,
not color variants. Death removes an animal from these living counts while its
remains stay in the ecosystem. The `red-white` catalog item retains its original
`display-pattern` identity and is labeled Red / White Display Shrimp.

## Adding supported animals

The planted-tank animal picker adds one supported adult with a new stable stock
identity. The editor exports its paused current tank and restores that checkpoint
into an isolated candidate. Only that candidate receives `stageStockAddition`;
callers must discard it on failure, as with a failed checkpoint restoration.
The candidate is validated and revision-checked on disk before it replaces the
current surface. Existing animals, feeding state, water and simulation clocks
are preserved. Purchased adults are not marked as offspring.

The renderer chooses a bounded placement clear of conservative hardscape bounds
and existing bodies, using the selected form's metric anatomy. Floor animals
start grounded; glass cleaners use the front pane's attachment transform.
Population checks retain reserved brood slots as well as the 80-actor rendering
limit. `breeding.synchronizeRoster` updates the retained parents without
advancing time or starting a conception. Animal history is independent from layout undo.

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
the operation. Layout history remains separate from animal removal. Pricing remains unfinished.

## Selective animal history model

`AquariumRuntimeCheckpoint.removeStock` returns a replacement checkpoint and a
per-animal JSON archive. `restoreStock` applies that archive to a current
checkpoint. Archives contain only the individual's life and visual binding,
related parent/offspring records, carried brood and owned removal events. They
are limited to 64 KiB of UTF-8. The existing `removingAnimal` API retains its
checkpoint-only return value.

Restoration retains current water, food, other lives, deposits and global random
state and serials. The archived individual is paused outside the simulation;
its absolute life, brood and visual timers shift to the current clocks. Only
its own cancellation/removal effects are compensated. Deposited eggs remain in
the current tank. Duplicate identities, changed capacity, malformed archives
and a mismatched tank fail without mutating the input checkpoint.

The native animal picker exposes independent undo/redo, with at most 100
per-session inverse records. New stock edits clear redo; reopening a saved tank
clears animal history. Layout history remains separate. Every inverse uses a
paused candidate, the current store revision and the same commit-before-swap
ordering as stock edits. A failed restore or save keeps the current surface and
history. Later death or consumed capacity can reject an inverse; history never
silently resurrects a dead addition or deletes newer animals to make space.

Returned individuals keep a clear existing pose when possible. Otherwise the
candidate finds a safe pose using metric capsule bounds against conservative
hardscape bounds and existing bodies. Glass returns retain their front, left,
right or back pane. Only that individual's pose and related breeding positions
change. Native visual acceptance and signed-host checks remain separate gates.

## Isolated native QA

A Debug QA bundle with an identifier under `com.idlescreen.aquarium-qa.` can
provide an absolute private legacy-tank path in `IdleScreenAquariumQAStorePath`.
The planted-tank checkpoint uses the same directory. Normal app bundles ignore
this profile, and Release builds do not read it. This lets native automation
launch the actual app executable without a command-line wrapper. The existing
Debug `--aquarium-store-path` argument takes precedence.
