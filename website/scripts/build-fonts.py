#!/usr/bin/env python3
"""Rebuild website/dist/assets/fonts from the app's OFL font files.

Subsets each font to Basic Latin, Latin-1 and the punctuation the site uses,
then writes WOFF2. Needs fontTools and brotli (pip install fonttools brotli).
Run from the repository root: python3 website/scripts/build-fonts.py
"""
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont

root = Path(__file__).resolve().parents[2]
source = root / "Products/IdleScreenApp/Resources/Fonts"
target = root / "website/dist/assets/fonts"
target.mkdir(parents=True, exist_ok=True)

unicodes = (
    list(range(0x20, 0x7F))
    + list(range(0xA0, 0x100))
    + [0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026, 0x2190, 0x2191, 0x2192, 0x2193, 0x2197]
)

for name in ["DepartureMono-Regular.otf", "Inter-Regular.ttf", "Inter-Medium.ttf", "Inter-SemiBold.ttf"]:
    options = subset.Options()
    options.flavor = "woff2"
    options.layout_features = ["kern", "liga", "calt", "tnum"]
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
    font = TTFont(source / name)
    subsetter = subset.Subsetter(options)
    subsetter.populate(unicodes=unicodes)
    subsetter.subset(font)
    font.flavor = "woff2"
    out = target / (Path(name).stem + ".woff2")
    font.save(out)
    print(out.name, out.stat().st_size)
