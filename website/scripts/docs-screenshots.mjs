// Screenshots of the docs site: home in light and dark, and one content page.
// Usage (from website/, after the docs are assembled): node scripts/docs-screenshots.mjs <output-dir>
// Starts the same server the tests use.
import { chromium } from '@playwright/test';
import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';

const out = process.argv[2];
if (!out) throw new Error('usage: node scripts/docs-screenshots.mjs <output-dir>');
await mkdir(out, { recursive: true });

const port = 4794;
const server = spawn('node', ['e2e/serve.mjs'], { env: { ...process.env, PORT: String(port) }, stdio: 'ignore' });
await new Promise(resolve => setTimeout(resolve, 800));

const browser = await chromium.launch();
try {
  const shots = [
    ['docs-home-light', '/docs', 'light'],
    ['docs-home-dark', '/docs', 'dark'],
    ['docs-page-light', '/docs/agent-signals', 'light'],
    ['docs-page-dark', '/docs/agent-signals', 'dark'],
  ];
  for (const [name, path, scheme] of shots) {
    const context = await browser.newContext({ viewport: { width: 1728, height: 1000 }, colorScheme: scheme });
    const page = await context.newPage();
    await page.goto(`http://127.0.0.1:${port}${path}`);
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: join(out, `${name}.png`) });
    await context.close();
  }
} finally {
  await browser.close();
  server.kill();
}
