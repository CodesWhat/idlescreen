import { expect, test as base } from '@playwright/test';

const stubImage = '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="400"><rect width="600" height="400" fill="#888"/></svg>';

// Every test fails on page errors, console errors (CSP violations included) and
// failed same-origin requests. Third-party images (Star History, Codecov) are
// stubbed so the suite doesn't depend on those services being up.
const test = base.extend({
  failures: [async ({ page, baseURL }, use) => {
    const origin = new URL(baseURL).origin;
    const problems = [];
    page.on('pageerror', error => problems.push(`pageerror: ${error.message}`));
    page.on('console', message => {
      if (message.type() === 'error') problems.push(`console error: ${message.text()}`);
    });
    page.on('requestfailed', request => {
      if (request.url().startsWith(origin)) problems.push(`request failed: ${request.url()}`);
    });
    page.on('response', response => {
      if (response.url().startsWith(origin) && response.status() >= 400) problems.push(`HTTP ${response.status()}: ${response.url()}`);
    });
    await page.addInitScript(() => {
      document.addEventListener('securitypolicyviolation', event => {
        console.error(`CSP violation: ${event.violatedDirective} blocked ${event.blockedURI}`);
      });
    });
    for (const host of ['api.star-history.com', 'codecov.io']) {
      await page.route(`https://${host}/**`, route => route.fulfill({ status: 200, contentType: 'image/svg+xml', body: stubImage }));
    }
    await use(undefined);
    expect(problems).toEqual([]);
  }, { auto: true }],
});

const patterns = [
  'Perlin Noise', 'Plasma', 'Sweep', 'Rain', 'Rainbow Cycle', 'Fire Effect', 'Ripple', 'Voronoi', 'Warp',
  'Static', 'Pulse', 'DVD Bounce', 'Metaballs', 'Starfield', 'Spiral Galaxy', 'Terrain', 'Rain on Glass', 'Aurora',
];

test.describe('content', () => {
  test('hero has the logo, a download link to the latest release and the brew command', async ({ page }) => {
    await page.goto('/');
    await expect(page.getByRole('heading', { level: 1 })).toContainText('animated characters');
    await expect(page.locator('.hero-art img')).toBeVisible();
    await expect(page.locator('[data-download]')).toHaveAttribute('href', 'https://github.com/CodesWhat/idlescreen/releases/latest');
    await expect(page.locator('#brew-command')).toHaveText('brew install --cask codeswhat/tap/idlescreen');
  });

  test('lists the 18 procedural patterns by name and Pixel Materials', async ({ page }) => {
    await page.goto('/');
    const chips = page.locator('.chips li');
    await expect(chips).toHaveCount(18);
    expect(await chips.allTextContents()).toEqual(patterns);
    await expect(page.getByRole('heading', { name: 'Pixel Materials' })).toBeVisible();
  });

  test('covers camera privacy, the display layouts and requirements', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#camera')).toContainText('sandboxed');
    await expect(page.locator('#camera')).toContainText("aren't sent over the network");
    for (const name of ['Panorama', 'Per Display', 'Focus Display']) {
      await expect(page.locator('#displays dt', { hasText: name })).toBeVisible();
    }
    await expect(page.locator('#install')).toContainText('macOS 26 Tahoe or newer');
    await expect(page.locator('#not-verified a')).toHaveAttribute('href', 'https://github.com/CodesWhat/idlescreen#not-verified-on-a-device');
  });

  test('screenshots are real renderer frames with honest captions', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('[data-placeholder]')).toHaveCount(0);
    await expect(page.locator('.shots')).not.toContainText('Capture to come');
    const shots = page.locator('.shot img');
    await expect(shots).toHaveCount(3);
    for (const image of await shots.all()) {
      await image.scrollIntoViewIfNeeded();
      await expect.poll(() => image.evaluate(node => node.complete && node.naturalWidth)).toBe(1600);
    }
    await expect(page.locator('.shot figcaption').nth(0)).toContainText("rendered by IdleScreen's own Metal renderer");
    await expect(page.locator('.shot figcaption').nth(2)).toContainText('synthetic generated image');
  });

  test('footer carries the CodesWhat entity line, Star History and the Codecov badge', async ({ page }) => {
    await page.goto('/');
    const note = page.locator('.site-footer .footer-note').first();
    await expect(note).toHaveText('CodesWhat: small, sharp tools from one developer and a lot of agents.');
    await expect(note.locator('a')).toHaveAttribute('href', 'https://codeswhat.com');
    await expect(page.locator('.chart')).toHaveAttribute('href', /star-history\.com\/#CodesWhat\/idlescreen/);
    await expect(page.locator('.chart img')).toHaveAttribute('alt', 'Star history chart for CodesWhat/idlescreen');
    await expect(page.locator('img[src*="codecov.io/gh/CodesWhat/idlescreen"]')).toHaveCount(1);
  });

  test('FAQ items expand and collapse', async ({ page }) => {
    await page.goto('/');
    const first = page.locator('.faq details').first();
    await expect(first).not.toHaveAttribute('open', '');
    await first.locator('summary').click();
    await expect(first).toHaveAttribute('open', '');
    await first.locator('summary').click();
    await expect(first).not.toHaveAttribute('open', '');
  });

  test('copy gives either the copied label or the fallback toast', async ({ page, context }) => {
    await context.grantPermissions(['clipboard-read', 'clipboard-write']).catch(() => {});
    await page.goto('/');
    await page.locator('[data-copy="#brew-command"]').click();
    await expect.poll(async () => {
      const label = await page.locator('[data-copy="#brew-command"]').textContent();
      const toast = await page.locator('#toast').textContent();
      return label === 'Copied' || toast.length > 0;
    }).toBe(true);
  });
});

test.describe('layout', () => {
  for (const width of [1280, 390, 320]) {
    test(`no horizontal overflow at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 });
      await page.goto('/');
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      expect(overflow).toBeLessThanOrEqual(0);
    });
  }

  test('the self-hosted fonts load', async ({ page }) => {
    await page.goto('/');
    await page.evaluate(() => document.fonts.ready);
    const loaded = await page.evaluate(() => [...document.fonts].filter(font => font.status === 'loaded').map(font => font.family.replaceAll('"', '')));
    expect(loaded).toContain('Departure Mono');
    expect(loaded).toContain('Inter');
  });

  test('buttons and copy controls are at least 44px tall at 390px', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/');
    for (const locator of [page.locator('.button').first(), page.locator('.copy').first(), page.locator('.faq summary').first()]) {
      const box = await locator.boundingBox();
      expect(box.height).toBeGreaterThanOrEqual(44);
    }
  });

  for (const scheme of ['light', 'dark']) {
    test(`renders in ${scheme} mode with readable body text`, async ({ page }) => {
      await page.emulateMedia({ colorScheme: scheme });
      await page.goto('/');
      const [bg, fg] = await page.evaluate(() => {
        const style = getComputedStyle(document.body);
        return [style.backgroundColor, style.color];
      });
      const luminance = value => {
        const [r, g, b] = value.match(/\d+(\.\d+)?/g).slice(0, 3).map(Number);
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
      };
      expect(luminance(bg) < 0.5).toBe(scheme === 'dark');
      expect(Math.abs(luminance(bg) - luminance(fg))).toBeGreaterThan(0.7);
    });
  }
});

test.describe('discoverability and security', () => {
  test('structured data is inert under the CSP and the crawl files are served', async ({ page, request }) => {
    await page.goto('/');
    const raw = await page.locator('script[type="application/ld+json"]').first().textContent();
    expect(JSON.parse(raw)['@type']).toBe('SoftwareApplication');
    for (const [path, type] of [
      ['/robots.txt', /text\/plain/], ['/sitemap.xml', /xml/], ['/llms.txt', /text\/plain/],
      ['/.well-known/security.txt', /text\/plain/], ['/assets/social-card.png', /image\/png/],
    ]) {
      const response = await request.get(path);
      expect(response.status(), path).toBe(200);
      expect(response.headers()['content-type'], path).toMatch(type);
    }
  });

  test('the page is served with the strict CSP and no inline script or style', async ({ page }) => {
    const response = await page.goto('/');
    const csp = response.headers()['content-security-policy'];
    expect(csp).toContain("script-src 'self'");
    expect(csp).toContain("style-src 'self'");
    expect(csp).not.toContain('unsafe-inline');
    expect(await page.locator('style').count()).toBe(0);
    expect(await page.locator('[style]').count()).toBe(0);
    expect(await page.locator('script:not([src]):not([type="application/ld+json"])').count()).toBe(0);
  });
});
