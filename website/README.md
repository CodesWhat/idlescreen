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
Metal renderer, drawn offscreen at 1600x1000 with a fixed scene seed (7) and fixed
timestamps. Nothing is composited or retouched. Contrast is 1 and the scene
brightness is the default 1 for all three. Settings per image (everything else is
`IdleScreenRendererConfiguration.default`):

| File | Pattern | Palette | Glyph scale | Other |
| --- | --- | --- | --- | --- |
| `warp-phosphor.webp` | Warp | Phosphor | 0.6 | procedural intensity 1, t = 20 s |
| `pixel-materials-sand-water.webp` | Pixel Materials | Ember (the sim uses its own `canyon` material palette) | 0.9 | mixed material, terraces, cellScale 2, 3 emitters, width 8, rate 8, frame 480 at 30 fps |
| `pulse-blueprint.webp` | Pulse | Blueprint | 0.6 | procedural intensity 1, t = 20 s |

Glyph scale is above the app default (0.38), so characters are larger and the frames
stay readable at the card's ~360px width. The camera glyph path isn't captured: the
synthetic portrait didn't read as a face at thumbnail size, so the camera section is
text only.

Regenerate after a renderer or palette change (needs Xcode and `brew install webp`):

```sh
website/scripts/capture-site-images.sh
```

It runs `SiteCaptureTests` (`Tests/IdleScreenRendererTests`), which is a no-op
unless `TEST_RUNNER_IDLESCREEN_SITE_CAPTURE_DIR` is set, then converts the PNGs to
lossless WebP. Two runs produce identical files.

## Headers

`vercel.json` sets a strict CSP (`default-src 'self'`, no inline scripts or
styles). The only extra origins are `api.star-history.com` and `codecov.io`
(`img-src`, for the Star History chart and the Codecov badge) and
`https://e.codeswhat.com` (`connect-src`, the PostHog proxy for analytics).
`script-src` stays `'self'`: the analytics SDK is vendored, not loaded remotely.
`e2e/serve.mjs` reads `vercel.json` and serves `dist/` with the same headers, so
the browser tests run under the production policy.

## Analytics

Cookieless PostHog on the landing page and on `/docs`. Both load the same loader
(`/analytics.mjs`) and the same contract module, so the privacy rules can't drift. The docs
app (`docs-site/src/app/layout.tsx`) just adds the script tag; its `/docs` CSP rule allows
`connect-src https://e.codeswhat.com` too. The loader initializes only when
`location.hostname` is `idlescreen.codeswhat.com`, so localhost, the e2e server and preview deployments send nothing.

Events go to `https://e.codeswhat.com` (project key in `dist/analytics-contract.mjs`;
it's a public client key). PostHog runs with `cookieless_mode: "always"`, no
persistence, no person profiles, no autocapture, no session replay. Every event is
rebuilt by a `before_send` allowlist, so nothing else PostHog attaches can leave the
browser. What is collected:

- `$pageview` and `$pageleave`, with `schema_version`, `site: "idlescreen"`,
  `surface: "marketing"`, and a canonical `path` (`/`, or `/_other`; no query or fragment).
  On `/docs` the surface is `"docs"` and `path` is `/docs` or `/docs/<slug>` for a slug in
  `DOCS_SLUGS` (a test keeps it equal to `docs-site/content/docs`), else `/docs/_other`.
  The docs are a client-side router, so a pageview also fires on each route change.
  Adding a docs page means adding its slug to `DOCS_SLUGS`.
- `$web_vitals`: CLS, FCP, INP and LCP. Sent 5 seconds after the first metric, and
  again at page hide for metrics that arrive late (CLS and INP usually do), each
  metric at most once per page load. The `web-vitals` package produces them and
  `analytics-contract.mjs` buffers them.
- `cta activated` with `cta_id` and `placement`, from the `data-cta` and
  `data-cta-placement` attributes in `index.html`: `download:hero`,
  `install_brew:hero`, `install_brew:install`, `github_repository:header|hero|footer`,
  `github_releases:footer`, `docs_root:header`.
- Do Not Track and Global Privacy Control are respected: with either set, the SDK
  isn't loaded and `before_send` drops anything that still comes through
  (posthog-js ignores `respect_dnt` in cookieless mode, so the contract checks).
- Acquisition: `utm_*` labels that look like plain labels, and `$referring_domain`
  (a hostname or `$direct`). Never the full referrer, URL or click ids.
- The browser payload never includes an IP. It does carry `$raw_user_agent` and
  `$host`, because PostHog's cookieless mode hashes those with the connection's IP
  and a daily salt to count visitors. PostHog sees the IP when it processes the
  request; the hash is what it keeps, not a person profile.

`dist/analytics.mjs` is the loader and `dist/analytics-contract.mjs` is the pure
contract (tested in `tests/analytics-contract.test.mjs`). The SDK is vendored into
`dist/assets/vendor/`: posthog-js's slim `no-external` build (it never fetches a
remote script) plus `web-vitals`, both pinned exactly in `package.json`, with their
licenses. After bumping either, run `npm run vendor:analytics` and commit the output.

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

The docs are a separate app in `docs-site/` (Next.js static export, Fumadocs, 1600px layout:
logo, Docs and GitHub in the header, search and the theme picker in the sidebar). They are served
at `https://idlescreen.codeswhat.com/docs`, the same path the other CodesWhat product sites use,
and the header's Docs link points there. Content is MDX in `docs-site/content/docs/`, grounded in
the README, `docs/`, `SECURITY.md` and the app's own strings. The changelog page is generated
from `CHANGELOG.md`.

`website/dist/docs/` is generated and gitignored. Build it with:

```sh
cd docs-site && npm ci && npm run build && npm run assemble
```

`vercel.json`'s `buildCommand` does the same on deploy (the Vercel project needs "Include source
files outside of the Root Directory" on, as the root directory is `website`). Next's inline
bootstrap scripts need a per-page CSP, so the build injects a hashed `<meta>` policy into each
docs page and the `/docs` header rule leaves out `default-src` and `script-src`. The site-wide
strict rule excludes `/docs`. `scripts/docs-screenshots.mjs <dir>` writes light and dark screenshots.
