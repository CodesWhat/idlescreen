// Full-page screenshots of the home page: light and dark, desktop and mobile.
// Usage (from website/): node scripts/screenshots.mjs <output-dir>
// Starts the same server the tests use. Third-party images are stubbed.
import { chromium } from '@playwright/test';
import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';

const out = process.argv[2];
if (!out) throw new Error('usage: node scripts/screenshots.mjs <output-dir>');
await mkdir(out, { recursive: true });

const port = 4793;
const server = spawn('node', ['e2e/serve.mjs'], { env: { ...process.env, PORT: String(port) }, stdio: 'ignore' });
await new Promise(resolve => setTimeout(resolve, 800));

const stub = '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="400"><rect width="600" height="400" fill="#8883"/></svg>';
const browser = await chromium.launch();
try {
  for (const [name, viewport] of [['desktop', { width: 1440, height: 900 }], ['mobile', { width: 390, height: 844 }]]) {
    for (const scheme of ['light', 'dark']) {
      const context = await browser.newContext({ viewport, colorScheme: scheme });
      const page = await context.newPage();
      for (const host of ['api.star-history.com', 'codecov.io']) {
        await page.route(`https://${host}/**`, route => route.fulfill({ status: 200, contentType: 'image/svg+xml', body: stub }));
      }
      await page.goto(`http://127.0.0.1:${port}/`);
      await page.evaluate(() => document.fonts.ready);
      await page.screenshot({ path: join(out, `home-${name}-${scheme}.png`), fullPage: true });
      await context.close();
    }
  }
} finally {
  await browser.close();
  server.kill();
}
