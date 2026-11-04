# CRT Silver

IdleScreen uses a silver low-poly CRT in three-quarter view, with a deep graphite
case, curved glass, and green, amber and blue ASCII terrain. CodesWhat selected
this design on November 4, 2026, from artwork generated with OpenAI image
generation using the repository's original CRT as a reference.

The canonical source is `AppIcon.icon/Assets/crt.png`: a transparent 1024 px
foreground. Icon Composer places it over a midnight slate field (`#202C3D`).
macOS supplies the icon mask and platform treatment. The monochrome layer keeps
the bright case and terrain for tinted appearance.

Regenerate the fallback icon sizes, monochrome layer, README, website and docs
logos with Python 3 and ImageMagick:

    python3 -I design/icon/export.py

The generated files are checked in, so normal builds do not need these tools.
`sprites.py` and `canvas.py` retain the previous pixel drawing as source history;
they are not used to generate CRT Silver.
