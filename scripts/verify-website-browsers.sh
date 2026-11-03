#!/usr/bin/env bash
# Builds the docs app (docs-site/) into website/dist/docs, runs the docs and website node tests,
# then website/e2e (site and docs) in Chromium, Firefox and WebKit against dist/.
# website/dist is otherwise committed and needs no build.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

cd "$root/docs-site"
npm ci
npm run lint
npm run build
REQUIRE_OUT=1 npm run test:scripts
npm run assemble

cd "$root/website"
npm ci
npx playwright install chromium firefox webkit
npm run test:unit
npx playwright test
