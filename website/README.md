# IdleScreen website

Static site for https://idlescreen.codeswhat.com. It's plain HTML, CSS and one small
JavaScript module. `dist/` is the whole artifact: serve it from any static host.
Same approach as the Dilated site.

Not deployed from here yet. The Vercel project and DNS are set up separately.

## Look

Departure Mono for headings, Inter for text, cobalt `#3B6CF0` as the accent, the
pixel CRT logo. Light and dark follow the system setting. Both fonts are the
app's OFL files, subset to Latin and converted to WOFF2 with
`python3 website/scripts/build-fonts.py` (needs `fonttools` and `brotli`). The
OFL texts sit next to them in `dist/assets/fonts/`.

## Content rules

Every claim comes from the README, `docs/ARCHITECTURE.md`, `SECURITY.md` or the
code. The product name is IdleScreen in prose. Lowercase `idlescreen` stays only
where it is a literal identifier: the cask name, URLs, repo paths, `idlescreenctl`
and `/Applications/idlescreen.app`.

## Screenshots

The three images in `dist/assets/shots/` are real frames from IdleScreen's own
Metal renderer, drawn offscreen at 1600x1000 with the default Ember palette, a
fixed scene seed and fixed timestamps (Pixel Materials runs 420 steps at 30 fps).
Glyph scale and contrast are raised from the app defaults so the frames read at
thumbnail size. Nothing is composited or retouched. The camera image feeds the
renderer's camera glyph path a generated head-and-shoulders luminance image: no
camera is opened and it is not a photo. Captions say so.

Regenerate after a renderer or palette change (needs Xcode and `brew install webp`):

```sh
website/scripts/capture-site-images.sh
```

It runs `SiteCaptureTests` (`Tests/IdleScreenRendererTests`), which is a no-op
unless `TEST_RUNNER_IDLESCREEN_SITE_CAPTURE_DIR` is set, then converts the PNGs to
lossless WebP. Two runs produce identical files.

## Headers

`vercel.json` sets a strict CSP (`default-src 'self'`, no inline scripts or
styles). The only extra origins are `api.star-history.com` and `codecov.io`,
for the Star History chart and the Codecov badge. `e2e/serve.mjs` serves `dist/`
with the same headers, so the browser tests run under the production policy.

## Checks

```sh
cd website
npm ci
npx playwright install chromium firefox webkit
npm run test:unit   # CSP, security.txt, structured data, crawl files
npx playwright test # content, layout, fonts, light and dark, CSP, 3 engines
```

`scripts/verify-website-browsers.sh` runs all of that. CI runs it inside the
required `build-and-test` job, so a browser failure blocks merging.

`node scripts/screenshots.mjs <dir>` writes light and dark, desktop and mobile
screenshots. `npm run render:social` rebuilds `dist/assets/social-card.png`.

`security.txt` expires 2027-05-01. A unit test fails after that date, on purpose.

## Docs

There's no docs site yet. The header's Docs link goes to `docs/BUILDING.md` on
GitHub. Neither Dilated nor Mouthtype has a docs-site stack to mirror.
