import { expect, test as base } from '@playwright/test';

// Same guard as site.spec.mjs: every test fails on page errors, console errors (CSP violations
// included) and failed or 4xx/5xx same-origin requests. The docs are served under the /docs
// header rule from vercel.json, with the per-page hashed CSP meta from the build.
const test = base.extend({
  failures: [async ({ page, baseURL }, use) => {
    const origin = new URL(baseURL).origin;
    const problems = [];
    page.on('pageerror', error => problems.push(`pageerror: ${error.message}`));
    page.on('console', message => {
      if (message.type() === 'error') problems.push(`console error: ${message.text()}`);
    });
    page.on('requestfailed', request => {
      if (request.url().startsWith(origin) && !/abort|cancel/i.test(request.failure()?.errorText ?? '')) {
        problems.push(`request failed: ${request.url()}`);
      }
    });
    page.on('response', response => {
      if (response.url().startsWith(origin) && response.status() >= 400) problems.push(`HTTP ${response.status()}: ${response.url()}`);
    });
    await page.addInitScript(() => {
      document.addEventListener('securitypolicyviolation', event => {
        console.error(`CSP violation: ${event.violatedDirective} blocked ${event.blockedURI}`);
      });
    });
    // The marketing page loads third-party images; CI blocks that egress, so stub them as site.spec.mjs does.
    for (const host of ['api.star-history.com', 'codecov.io']) {
      await page.route(`https://${host}/**`, route => route.fulfill({ status: 200, contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>' }));
    }
    await use(undefined);
    expect(problems).toEqual([]);
  }, { auto: true }],
});

const pages = [
  '/docs', '/docs/getting-started', '/docs/studio', '/docs/displays', '/docs/camera', '/docs/agent-signals',
  '/docs/menu-bar', '/docs/troubleshooting', '/docs/building', '/docs/architecture', '/docs/security', '/docs/changelog',
];

test.describe('docs pages', () => {
  for (const path of pages) {
    test(`${path} renders with a heading, a canonical link and no overflow`, async ({ page }) => {
      const response = await page.goto(path);
      expect(response.status()).toBe(200);
      await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
      await expect(page.locator('link[rel="canonical"]')).toHaveAttribute('href', `https://idlescreen.codeswhat.com${path}`);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      expect(overflow).toBeLessThanOrEqual(0);
    });
  }

  test('a page that does not exist answers 404 with the docs 404 page', async ({ page, baseURL }) => {
    const response = await page.request.get(`${baseURL}/docs/no-such-page`);
    expect(response.status()).toBe(404);
    expect(response.headers()['content-type']).toContain('text/html');
    expect(await response.text()).toContain('404');
  });

  test('the marketing site Docs link goes to /docs', async ({ page }) => {
    await page.goto('/');
    const link = page.locator('.site-header nav a', { hasText: 'Docs' });
    await expect(link).toHaveAttribute('href', '/docs');
    await link.click();
    await expect(page).toHaveURL(/\/docs$/);
    await expect(page.getByRole('heading', { level: 1 })).toHaveText('IdleScreen documentation');
  });
});

test.describe('chrome', () => {
  test.use({ viewport: { width: 1728, height: 1000 } });

  test('header is logo, Docs and GitHub only, and the layout is 1600px wide', async ({ page }) => {
    await page.goto('/docs');
    const header = page.locator('#top');
    await expect(header.locator('a')).toHaveText(['IdleScreen', 'Docs', 'GitHub ↗']);
    await expect(header.locator('a').nth(2)).toHaveAttribute('href', 'https://github.com/CodesWhat/idlescreen');
    await expect(header.locator('input, button')).toHaveCount(0);
    expect(await page.locator('#nd-docs-layout').evaluate(node => getComputedStyle(node).getPropertyValue('--fd-layout-width'))).toBe('1600px');
  });

  test('search is at the top of the sidebar and the theme picker at its bottom', async ({ page }) => {
    await page.goto('/docs');
    const sidebar = page.locator('#nd-sidebar');
    await expect(sidebar.getByRole('button', { name: /search/i })).toBeVisible();
    const searchBox = await sidebar.getByRole('button', { name: /search/i }).boundingBox();
    const linkBox = await sidebar.locator('a[href="/docs/getting-started"]').boundingBox();
    expect(searchBox.y).toBeLessThan(linkBox.y);
    const picker = sidebar.getByRole('button', { name: 'Toggle Theme' });
    await expect(picker).toBeVisible();
    expect((await picker.boundingBox()).y).toBeGreaterThan(linkBox.y);
  });

  test('footer carries the CodesWhat entity line', async ({ page }) => {
    await page.goto('/docs');
    const note = page.locator('#footer .fnote').first();
    await expect(note).toHaveText('CodesWhat: small, sharp tools from one developer and a lot of agents.');
    await expect(note.locator('a')).toHaveAttribute('href', 'https://codeswhat.com');
  });

  test('the self-hosted fonts load', async ({ page }) => {
    await page.goto('/docs');
    await page.evaluate(() => document.fonts.ready);
    const loaded = await page.evaluate(() => [...document.fonts].filter(font => font.status === 'loaded').map(font => font.family.replaceAll('"', '')));
    // next/font renames the faces, so match on the family each element resolves to.
    expect(loaded.some(name => /departure/i.test(name))).toBe(true);
    expect(loaded.some(name => /inter/i.test(name))).toBe(true);
    const heading = await page.getByRole('heading', { level: 1 }).evaluate(node => getComputedStyle(node).fontFamily);
    expect(heading).toMatch(/departure/i);
    const body = await page.locator('#nd-page p').first().evaluate(node => getComputedStyle(node).fontFamily);
    expect(body).toMatch(/inter/i);
  });
});

test.describe('search', () => {
  test('finds a page by what is in it and opens it', async ({ page }) => {
    await page.goto('/docs');
    await page.locator('#nd-sidebar').getByRole('button', { name: /search/i }).click();
    const dialog = page.getByRole('dialog');
    await expect(dialog).toBeVisible();
    await dialog.getByRole('combobox').fill('idlescreenctl');
    const option = dialog.getByRole('option').first();
    await expect(option).toBeVisible();
    await option.click();
    await expect(page).toHaveURL(/\/docs\/(agent-signals|architecture)/);
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  });

  test('closes on Escape', async ({ page }) => {
    await page.goto('/docs');
    await page.locator('#nd-sidebar').getByRole('button', { name: /search/i }).click();
    const dialog = page.getByRole('dialog');
    await expect(dialog).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(dialog).toBeHidden();
  });
});

test.describe('theme picker', () => {
  test.use({ viewport: { width: 1440, height: 900 }, colorScheme: 'light' });

  test('follows the system, switches to dark and keeps the choice across a reload', async ({ page }) => {
    await page.goto('/docs');
    const html = page.locator('html');
    await expect(html).not.toHaveClass(/dark/);
    const bg = () => page.evaluate(() => getComputedStyle(document.body).backgroundColor);
    expect(await bg()).toBe('rgb(255, 255, 255)');

    await page.locator('#nd-sidebar').getByRole('button', { name: 'Toggle Theme' }).click();
    await expect(html).toHaveClass(/dark/);
    expect(await bg()).toBe('rgb(14, 17, 23)');

    // The sidebar prefetches every page; reloading mid-prefetch makes WebKit cancel them, and Next
    // reports a cancelled prefetch as a page error. Let them finish so only real errors count.
    await page.waitForLoadState('networkidle');
    await page.reload();
    await expect(html).toHaveClass(/dark/);
    await page.locator('#nd-sidebar').getByRole('button', { name: 'Toggle Theme' }).click();
    await expect(html).not.toHaveClass(/dark/);
  });
});

test.describe('phone', () => {
  test.use({ viewport: { width: 390, height: 780 } });

  test('the sidebar drawer opens, navigates and closes', async ({ page }) => {
    await page.goto('/docs');
    const drawer = page.locator('#nd-sidebar-mobile');
    const open = page.getByRole('button', { name: 'Open Sidebar' }).first();
    await open.click();
    await expect(drawer).toHaveAttribute('data-state', 'open');
    const link = drawer.locator('a[href="/docs/camera"]');
    await expect(link).toBeVisible();
    await link.click();
    await expect(page).toHaveURL(/\/docs\/camera$/);
    await expect(drawer).toBeHidden();
  });
});
