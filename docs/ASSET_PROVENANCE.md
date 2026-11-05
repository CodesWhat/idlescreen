# Asset provenance

The README logo (`docs/assets/idlescreen-logo.png`) and app icon use CRT Silver,
selected for IdleScreen on November 4, 2026. The original artwork was generated
for CodesWhat with OpenAI image generation, using this repository's earlier
silver CRT as the reference. It depicts a low-poly CRT with green, amber and
blue ASCII terrain on the glass.

The tracked source is `design/icon/AppIcon.icon/Assets/crt.png`, a transparent
1024 px foreground. `python3 -I design/icon/export.py` exports the app icon
fallback sizes, website and docs logos, and a monochrome Icon Composer layer.
See `design/icon/README.md`. The artwork is distributed under the repository's
MIT License.

The screen-saver thumbnail artwork was created for this repository by CodesWhat
on August 12, 2026. Its editable source is:

- `docs/assets/idlescreen-saver.svg`

`scripts/generate-brand-assets.sh` renders the screen-saver source into its
asset catalog. The generated PNG files are distributed under the
repository's MIT License.

The menu-bar item uses Apple's `square.grid.3x3.fill` SF Symbol as a template
image at runtime. It is not redistributed as an asset.

## Bundled app fonts

The Instrument fonts were copied unchanged from
[CodesWhat/mouthtype at commit `d7a7ede116426caceea0e7ca5194772dbb2476d0`](https://github.com/CodesWhat/mouthtype/tree/d7a7ede116426caceea0e7ca5194772dbb2476d0/Sources/MouthtypeMac/Resources/Fonts):
`InstrumentSerif-Regular.ttf`, `InstrumentSans-Regular.ttf`,
`InstrumentSans-Medium.ttf`, and `InstrumentSans-SemiBold.ttf`. All four
bundled binaries match that source byte for byte.

Their upstream projects are [Instrument Serif](https://github.com/Instrument/instrument-serif)
and [Instrument Sans](https://github.com/Instrument/instrument-sans). Both use
the SIL Open Font License 1.1; the app bundles the corresponding OFL notices.
See `THIRD_PARTY_NOTICES.md` for the other bundled font sources.
