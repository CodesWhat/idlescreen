# Logo and app icon

The mark is a front-on pixel-art CRT: a cream case with an ink outline, a power LED and a stand, and a dithered
phosphor green glow on the screen, on a full-bleed cobalt field. The art is original to this project.

| Role | Colour |
| --- | --- |
| Field | cobalt `#3B6CF0` (Dark: charcoal `#26262B`) |
| Outline, screen, stand | ink `#1B1B1F` |
| Case | cream `#F6F0DC` |
| Glow, LED | phosphor green `#3DFF7A` |

The field is a flat full-bleed square with no baked shadow and no drawn corners. macOS 26 supplies the squircle mask,
depth and highlight. The 32 cell drawing in `sprites.py` (`grid32`) is the 1024 px master at 32 px per cell; the glow is
a Bayer 4x4 dithered ellipse. Sizes:

- 1024: the master.
- 512, 256, 128: box filtered from the master (exact integer factors, so the cells stay crisp).
- 64: the 32 cell drawing at 2x.
- 32: the 32 cell drawing at 1x (hand drawn on the pixel grid).
- 16: a separate hand drawn 16 cell drawing (`grid16`, with a hand tuned glow), since the 32 cell art does not
  survive halving.

`AppIcon.icon` is the Icon Composer bundle for macOS 26: a solid fill (cobalt, charcoal in Dark) and a transparent
`crt` layer. Tinted hides `crt` and shows `crt-mono`, a one colour CRT (case, stand, LED and glow) with the outline and
dark screen knocked out. `project.yml` lists it as a source of the app target, and Xcode compiles it into `Assets.car`
(`CFBundleIconName` = `AppIcon`). `Products/IdleScreenApp/Assets.xcassets/AppIcon.appiconset` is the fallback; its PNGs
also produce the legacy `AppIcon.icns`.

`export.py` writes the appiconset PNGs, `docs/assets/idlescreen-logo.png` (512 px, the README logo) and `AppIcon.icon/`.
The generated files are checked in, so builds do not need Python and nothing reads `.planning/`.

Regenerate after changing the art (Python 3, standard library only; output is deterministic):

    python3 -I design/icon/export.py

`sprites.py` holds the role grids, `canvas.py` the pixel canvas and PNG writer.
