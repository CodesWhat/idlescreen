# Planted tank checkpoints

The planted-tank workbench saves its layout, scene configuration and ecosystem
as one checkpoint. It uses a separate file from the existing native tank
library. Existing tank selections and files are not migrated or replaced.

The renderer restores only into a fresh, paused runtime. It validates the
checkpoint before reconstructing the scene, then binds visuals to the saved
animal and food identities. Rebuilding does not add the starter roster to a
saved population. Playback begins after loading finishes and only when the
workbench still wants to be visible.

## Contents

The outer runtime format is version 1. Its `tank` member contains the
`idlescreen.aquarium` version 1 envelope, including the centimeter-based version
2 tank document and version 1 scene configuration. The ecosystem checkpoint
contains the ecology, breeding and water models, plus their cumulative waste
accounting marker.

The runtime member retains scene time, feeding counters and the next feeding
time, food positions and velocities, animal poses, glass attachment panes and
molt timing. Validation rejects missing or duplicate visual bindings,
unsupported artwork, invalid mass or clocks, unsupported versions and
checkpoints beyond the native rendering capacity. The current physical tank is
60 × 36 × 36 cm; other dimensions are rejected rather than displayed at a
misleading scale.

Behavioral movement targets and temporary navigation paths are rebuilt. This
format preserves the biological models and visible state; it does not promise
identical future movement trajectories after reopening.

## Editing plants and hardscape

The native workbench exposes the 15 specimens in the runtime's designer
catalog. Added specimens and preset objects appear in separate list sections.
The chooser accepts positions in centimeters. Rooted plants and hardscape
anchor to the substrate, floaters anchor to the water surface, and epiphytes
mount on the highest eligible wood or rock below the chosen position. Height
is determined by that support. Across, depth and rotation remain editable.
Choose **Place in tank** to click a bed, water-surface or eligible hardscape
anchor. Added specimens can be selected in the scene and moved with **Move in
tank**. Preset objects still use the list and coordinate inspector. Cancel or
leave the workspace to exit a pointer tool. A rejected placement keeps the tool
active so another position can be tried.

Pointer messages are accepted only from the bundled main frame. The scene
stamps each hit with its layout revision and tool activation generation; the
native surface and editor reject old activations and hidden or replaced
surfaces. Pointer tool changes do not create layout history or rewind biology.

Added-object commands validate a separate staged layout against the actual
preset geometry before changing the live tank. Commands carry the current
layout revision; stale commands, glass crossings, unsupported mounts and hard
collisions are rejected. Failed commands leave the layout and undo history
intact. Undo and redo retain independent preset/added-object edits without
restoring an older ecosystem checkpoint. Successful edits save both sets of
objects through the existing checkpoint store.

The three original chest, wreck and diver-helmet assets remain review-only and
are excluded from this chooser. Preset pointer movement, shop stock and pricing
remain unfinished work.

## Native storage

The native store keeps the UTF-8 checkpoint beside the existing aquarium
library, in `planted-tank-v1.json`. Its file size is limited to 4 MiB. The renderer
validates the complete domain state; the store additionally checks the outer
format and size.

Writes take an exclusive, nonblocking file lock, compare the existing file's
SHA-256 revision with the caller's last observed revision, then replace the file
atomically. A stale writer cannot replace a newer checkpoint. Invalid or future
files are preserved when loading fails. An editor that failed to load a
checkpoint cannot save over it.

Successful layout edits, explicit saves and leaving the workspace save a
checkpoint. Reopening a saved tank prepares a fresh surface before replacing
the current one. A failed reload keeps the current tank and its undo history.
The checkpoint resumes its saved simulation time; offline advancement is not
implemented in this workbench. Final app-termination synchronization and desktop/screensaver
ownership remain integration work. A successful unit test or unsigned WebKit
restore is not evidence of installed screen-saver behavior.

The compile-gate workspace uses an in-memory editor. Storage tests explicitly
inject temporary file URLs, so offscreen UI tests cannot write the user's tank.
