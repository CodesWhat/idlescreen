#!/usr/bin/env bash
# Builds nothing (website/dist is the artifact), runs the website node tests and
# then website/e2e in Chromium, Firefox and WebKit against dist/.
set -euo pipefail
cd "$(dirname "$0")/../website"
npm ci
npx playwright install chromium firefox webkit
npm run test:unit
npx playwright test
