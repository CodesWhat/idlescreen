# Aquarium runtime

`Sources/IdleScreenRenderer/Resources/AquariumRuntime/` is the authoritative
Three.js aquarium source. Make future scene changes there. Development
prototypes are historical inputs, not a second source to synchronize back into
the product.

`IdleScreenAquariumRuntime.sceneURL` resolves the entry point from
`IdleScreenRenderer.framework` using a bundle class locator. The resource folder
retains the script hierarchy, including its pinned Three.js dependency and MIT
notice. It contains procedural artwork, not reference photographs or exported
study pages. Source citation strings in the scripts are inert metadata. The
entry point denies network connections and loads only local scripts.

`PROVENANCE.json` records the import date, original entry digest, ordered runtime
closure and each imported file's original digest. Those source digests remain
the import baseline when product code changes; git records subsequent edits.
The vendor digests identify unmodified Three.js r160 bytes verified against
upstream commit `d04539a76736ff500cae883d6a38b3dd8643c548`. An intentional vendor
upgrade must update the code, license, provenance and tests together. Update
`scriptOrder` when adding, removing or reordering a runtime script.

The native entry starts paused, selects saver interaction mode, hides study
controls and couples displayed water condition to the ecosystem. Native hosts
call `window.idleScreenScene.setAnimating(Boolean)` through the WebKit adapter.
That bridge delegates to the aquarium's existing motion controller. Visibility
may suspend a running scene; it cannot restart a scene the native host paused.
The native host owns reduced-motion policy.

`AquariumRuntimeBundleTests` loads the actual framework resource through
WKWebView. Its synthetic visible-document state and deterministic animation
clock exercise the real scene and WebGL renderer while checking tank dimensions,
draw activity, water/ecology coupling and preservation of life across
pause/resume. An unmodified hidden document is also checked for suspended life.
This is unsigned
test-host evidence. Signed screensaver-host compositing, WebKit subprocess
sandbox behavior and real idle lifecycle remain separate verification gates.

The runtime is not yet selected by the shipping app or screensaver presentation.
