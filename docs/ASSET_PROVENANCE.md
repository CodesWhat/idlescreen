# Asset provenance

The README logo (`docs/assets/idlescreen-logo.png`) and the app icon are an
original pixel-art CRT created for this repository by CodesWhat. They are drawn
in code and regenerated with `python3 -I design/icon/export.py`; see
`design/icon/README.md`.

The screen-saver thumbnail artwork was created for this repository by CodesWhat
on August 12, 2026. Its editable source is:

- `docs/assets/idlescreen-saver.svg`

`scripts/generate-brand-assets.sh` renders the screen-saver source into its
asset catalog. The generated PNG files are distributed under the
repository's MIT License.

The menu-bar item uses Apple's `square.grid.3x3.fill` SF Symbol as a template
image at runtime. It is not redistributed as an asset.
