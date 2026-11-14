# Third-party notices

## Three.js

The aquarium renderer bundles Three.js r160 from upstream commit
`d04539a76736ff500cae883d6a38b3dd8643c548` under the MIT License.
Copyright © 2010-2023 three.js authors.

- Source: https://github.com/mrdoob/three.js/tree/d04539a76736ff500cae883d6a38b3dd8643c548
- Bundled code: `Sources/IdleScreenRenderer/Resources/AquariumRuntime/vendor/three.min.js`
- Full license: `Sources/IdleScreenRenderer/Resources/AquariumRuntime/vendor/LICENSE`
- Import and checksum provenance: `Sources/IdleScreenRenderer/Resources/AquariumRuntime/PROVENANCE.json`

The complete upstream license is included beside the library in the distributed
renderer framework. Aquarium artwork is original procedural CodesWhat code;
source-reference photographs are not bundled.

## AppexSaverMinimal

`Products/IdleScreenScreenSaver/Private/ScreenSaverPrivate.h` includes declarations
adapted from
[AerialScreensaver/AppexSaverMinimal](https://github.com/AerialScreensaver/AppexSaverMinimal)
at commit `6be6c85b49e827320711289853726e68d3fbd7ea`.

MIT License

Copyright (c) 2026 Guillaume Louel

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Bundled typefaces

The companion app bundles the following typefaces under `Products/IdleScreenApp/Resources/Fonts/`, each under the SIL Open Font
License 1.1. The fonts are bundled with the app and are not sold on their own. The full licence text for each sits beside
its font files.

### Departure Mono

Copyright 2022-2024 Helena Zhang (https://helenazhang.com)

- Licence: SIL OFL 1.1, `Products/IdleScreenApp/Resources/Fonts/OFL-DepartureMono.txt`
- Source: https://github.com/rektdeckard/departure-mono, release v1.500, `DepartureMono-Regular.otf`
- Used for: screen-saver glyph rendering

### Inter

Copyright (c) 2016 The Inter Project Authors (https://github.com/rsms/inter)

- Licence: SIL OFL 1.1, `Products/IdleScreenApp/Resources/Fonts/OFL-Inter.txt`
- Source: https://github.com/rsms/inter, release v4.1, `extras/ttf/Inter-{Regular,Medium,SemiBold}.ttf`
- Used for: legacy web and app assets

### Instrument Serif and Instrument Sans

Copyright 2022 The Instrument Serif Project Authors (https://github.com/Instrument/instrument-serif)

Copyright 2022 The Instrument Sans Project Authors (https://github.com/Instrument/instrument-sans)

- Licence: SIL OFL 1.1, `Products/IdleScreenApp/Resources/Fonts/OFL-InstrumentSerif.txt` and `OFL-InstrumentSans.txt`
- Source: [CodesWhat/mouthtype, commit `d7a7ede116426caceea0e7ca5194772dbb2476d0`](https://github.com/CodesWhat/mouthtype/tree/d7a7ede116426caceea0e7ca5194772dbb2476d0/Sources/MouthtypeMac/Resources/Fonts), `InstrumentSerif-Regular.ttf` and `InstrumentSans-{Regular,Medium,SemiBold}.ttf`
- Used for: companion app headings, controls, and body text
