# Saver thumbnails

The Studio saver chooser shows a real render of each pattern, drawn by IdleScreen's own Metal renderer, instead of a
gradient and a symbol. The PNGs are checked in under `Products/IdleScreenApp/Assets.xcassets/SaverThumbnails/` (one
`<pattern>.imageset` each, 720 x 360, the 2x of a 360 x 180 tile and the 2:1 of a Studio tile so nothing is cropped,
named by the pattern's raw value), so the app builds without running anything here.

Camera has no thumbnail: Studio draws a neutral dark tile with the camera symbol in cobalt. Auto Cycle has none either:
Studio tiles four of the others (`SaverTileArt.mosaicPatterns`).

## Regenerate

    design/thumbnails/generate.sh

It needs Xcode, a generated project (`xcodegen generate`) and a Mac with Metal. It runs `SaverThumbnailCaptureTests`
(`Tests/IdleScreenRendererTests`), which is a no-op unless `IDLESCREEN_THUMBNAIL_DIR` is set, then rewrites the
asset catalog. Output is deterministic: fixed scene seed 7, the default Ember palette, fixed timestamps, and the per pattern settings
in the `procedural` table in that test. Run it twice and the PNGs are byte-identical.

The tiles show at about 180 x 100 pt, so each one is a deliberately coarse, bright render rather than a screenshot:

- The view is laid out at 252 x 126 logical points while the drawable is 720 x 360, so the renderer's glyph grid is
  about 20 x 6 (roughly a third of the glyph density of a 320 x 200 view) and each glyph is drawn large and crisp.
- Glyph scale 1 (the largest), contrast 1 and scene brightness 1 for every pattern. Palette stays Ember.
- Intensity, pattern scale and trailing are tuned per pattern (table columns) so the pattern's shape survives the coarse
  grid: ripple and pulse read as rings, sweep and rainbow as diagonal bands, metaballs as blobs, spiral as arms, and so on.
- Starfield and Rain on Glass are sparse movers that a single frame cannot show, so the table's `exposure` column
  composites that many frames 0.25 s apart by per-pixel max, which turns the moving points into streaks.
- Pixel Materials is sand only on terraces with three wide emitters, captured at frame 480 (16 s at 30 fps).

To pick a pattern's timestamp, run the sweep:

    TEST_RUNNER_IDLESCREEN_THUMBNAIL_SWEEP=1 TEST_RUNNER_IDLESCREEN_THUMBNAIL_DIR=/tmp/thumbs xcodebuild test \
      -project IdleScreen.xcodeproj -scheme IdleScreenRenderer \
      -only-testing:IdleScreenRendererTests/SaverThumbnailCaptureTests -destination 'platform=macOS'

It writes every procedural pattern at 16 timestamps to `/tmp/thumbs/sweep/` and a `scores.csv` (mean luminance x edge
density of each frame). The table's times are the top scorers, then confirmed by eye. Change a setting in the test, rerun
`generate.sh`, and commit the PNGs it rewrites.

To change which patterns make up the Auto Cycle tile, edit `SaverTileArt.mosaicPatterns` in
`Products/IdleScreenApp/Design/DesignStudio.swift`.
