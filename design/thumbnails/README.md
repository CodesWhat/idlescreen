# Saver thumbnails

The Studio saver chooser shows a real render of each pattern, drawn by IdleScreen's own Metal renderer, instead of a
gradient and a symbol. The PNGs are checked in under `Products/IdleScreenApp/Assets.xcassets/SaverThumbnails/` (one
`<pattern>.imageset` each, 640 x 400, the 2x of a 320 x 200 tile, named by the pattern's raw value), so the app builds
without running anything here.

Camera has no thumbnail: Studio draws a neutral dark tile with the camera symbol in cobalt. Auto Cycle has none either:
Studio tiles four of the others (`SaverTileArt.mosaicPatterns`).

## Regenerate

    design/thumbnails/generate.sh

It needs Xcode, a generated project (`xcodegen generate`) and a Mac with Metal. It runs `SaverThumbnailCaptureTests`
(`Tests/IdleScreenRendererTests`), which is a no-op unless `IDLESCREEN_THUMBNAIL_DIR` is set, then rewrites the
asset catalog. Output is deterministic: fixed scene seed 7, the default Ember palette, fixed timestamps, and the per
pattern settings in the `procedural` table in that test (glyph scale, intensity, speed, start time, frames rendered,
pattern scale, trailing). Pixel Materials is sand on terraces with three wide emitters, captured at frame 480 (16 s at
30 fps). Change a setting in the test, rerun the script, and commit the PNGs it rewrites.

To change which patterns make up the Auto Cycle tile, edit `SaverTileArt.mosaicPatterns` in
`Products/IdleScreenApp/Design/DesignStudio.swift`.
