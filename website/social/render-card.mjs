// Renders social/card.html to dist/assets/social-card.png (1200x630).
// Run from website/ after `npm ci` and `npx playwright install chromium`: node social/render-card.mjs
import { chromium } from '@playwright/test';
import { fileURLToPath } from 'node:url';

const page = fileURLToPath(new URL('./card.html', import.meta.url));
const out = fileURLToPath(new URL('../dist/assets/social-card.png', import.meta.url));
const browser = await chromium.launch();
const tab = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
await tab.goto(`file://${page}`);
await tab.evaluate(() => document.fonts.ready);
await tab.screenshot({ path: out, clip: { x: 0, y: 0, width: 1200, height: 630 } });
await browser.close();
console.log(`wrote ${out}`);
