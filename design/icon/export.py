"""Export CRT Silver assets from the tracked Icon Composer foreground layer.

Run with Python 3 and ImageMagick: python3 -I design/icon/export.py.
"""
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ICON_BUNDLE = ROOT / "design/icon/AppIcon.icon"
SOURCE = ICON_BUNDLE / "Assets/crt.png"
APPICONSET = ROOT / "Products/IdleScreenApp/Assets.xcassets/AppIcon.appiconset"
FIELD = "#202C3D"


def convert(*arguments):
    subprocess.run(["magick", *map(str, arguments)], check=True)


def main():
    if shutil.which("magick") is None:
        raise SystemExit("ImageMagick is required: brew install imagemagick")
    for size in (16, 32, 64, 128, 256, 512, 1024):
        convert(SOURCE, "-background", FIELD, "-alpha", "remove", "-alpha", "off",
                "-resize", f"{size}x{size}!", "-strip",
                "-define", "png:exclude-chunks=date,time",
                f"PNG32:{APPICONSET / f'AppIcon-{size}.png'}")
    for destination in (ROOT / "docs/assets/idlescreen-logo.png",
                        ROOT / "website/dist/assets/logo.png",
                        ROOT / "docs-site/public/logo.png"):
        shutil.copyfile(APPICONSET / "AppIcon-512.png", destination)
    convert(SOURCE, "-colorspace", "Gray", "-threshold", "35%", "-alpha", "copy",
            "-channel", "RGB", "-evaluate", "set", "100%", "+channel", "-strip",
            "-define", "png:exclude-chunks=date,time",
            f"PNG32:{ICON_BUNDLE / 'Assets/crt-mono.png'}")
    spec = {
        "fill": {"solid": "srgb:0.12549,0.17255,0.23922,1.00000"},
        "groups": [{"layers": [
            {"name": "crt-mono", "image-name": "crt-mono.png",
             "hidden-specializations": [{"value": True}, {"appearance": "tinted", "value": False}]},
            {"name": "crt", "image-name": "crt.png",
             "hidden-specializations": [{"value": False}, {"appearance": "tinted", "value": True}]},
        ]}],
        "supported-platforms": {"squares": ["macOS"]},
    }
    (ICON_BUNDLE / "icon.json").write_text(json.dumps(spec, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
