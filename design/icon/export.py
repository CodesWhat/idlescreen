"""Draws the idlescreen logo and app icon. Python 3 stdlib only; run as `python3 -I design/icon/export.py`.

The mark is a front-on cream CRT with a power LED and stand, a dithered phosphor green glow on the screen, on a
full-bleed cobalt (#3B6CF0) field: no baked shadow, no drawn corners. macOS 26 applies its own squircle mask.
The 32 cell drawing is the 1024 master at 32 px per cell. 512, 256 and 128 are box filtered from the master,
64 is the drawing at 2x, and 32 and 16 are the 32 cell drawing at 1x and a separate hand drawn 16 cell one.

Written: the AppIcon.appiconset PNGs, docs/assets/idlescreen-logo.png (512 px), and the Icon Composer bundle
design/icon/AppIcon.icon (crt layer with a Dark fill, crt-mono for Tinted). Output is deterministic."""
import json
import os
import shutil
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from canvas import Canvas, rgba
from sprites import PALETTE, grid16, grid32

ROOT = os.path.join(HERE, "..", "..")
APPICONSET = os.path.join(ROOT, "Products", "IdleScreenApp", "Assets.xcassets", "AppIcon.appiconset")
LOGO = os.path.join(ROOT, "docs", "assets", "idlescreen-logo.png")
ICON_BUNDLE = os.path.join(HERE, "AppIcon.icon")
MASTER = 1024
FIELD, FIELD_DARK = "#3B6CF0", "#26262B"


def render(grid, scale, colors=PALETTE, skip_bg=False):
    cv = Canvas(grid.n * scale, grid.n * scale)
    for y, row in enumerate(grid.c):
        for x, role in enumerate(row):
            if role == "." and skip_bg:
                continue
            c = rgba(colors[role])
            for dy in range(scale):
                for dx in range(scale):
                    cv.p[y * scale + dy][x * scale + dx] = c
    return cv


def mono_grid():
    """One colour CRT for Tinted: body, stand, LED and glow in one colour; outline and dark screen knocked out."""
    g = grid32()
    for row in g.c:
        for x, r in enumerate(row):
            row[x] = "g" if r in ("b", "d", "l", "g") else "."
    return g


def srgb(c):
    r, g, b, _ = rgba(c)
    return "srgb:%.5f,%.5f,%.5f,1.00000" % (r / 255, g / 255, b / 255)


def write_icon_bundle():
    """Icon Composer bundle, 1024 px layers over a solid fill (cobalt, charcoal in Dark). Tinted hides the
    coloured CRT and shows the one colour sprite."""
    assets = os.path.join(ICON_BUNDLE, "Assets")
    shutil.rmtree(ICON_BUNDLE, ignore_errors=True)
    os.makedirs(assets)
    render(grid32(), 32, skip_bg=True).png(os.path.join(assets, "crt.png"))
    render(mono_grid(), 32, {"g": "#FFFFFF"}, skip_bg=True).png(os.path.join(assets, "crt-mono.png"))
    spec = {
        "fill": {"solid": srgb(FIELD)},
        "fill-specializations": [{"appearance": "dark", "value": {"solid": srgb(FIELD_DARK)}}],
        "groups": [{
            "layers": [
                {
                    "name": "crt-mono",
                    "image-name": "crt-mono.png",
                    "hidden-specializations": [
                        {"value": True},
                        {"appearance": "tinted", "value": False},
                    ],
                },
                {
                    "name": "crt",
                    "image-name": "crt.png",
                    "hidden-specializations": [
                        {"value": False},
                        {"appearance": "tinted", "value": True},
                    ],
                },
            ],
        }],
        "supported-platforms": {"squares": ["macOS"]},
    }
    with open(os.path.join(ICON_BUNDLE, "icon.json"), "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


def main():
    master = render(grid32(), MASTER // 32)
    sizes = {1024: master, 512: master.boxed(2), 256: master.boxed(4), 128: master.boxed(8),
             64: render(grid32(), 2), 32: render(grid32(), 1), 16: render(grid16(), 1)}
    for size, cv in sizes.items():
        cv.png(os.path.join(APPICONSET, "AppIcon-%d.png" % size))
    sizes[512].png(LOGO)
    write_icon_bundle()


if __name__ == "__main__":
    main()
