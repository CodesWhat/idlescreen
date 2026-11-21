import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, readdir } from 'node:fs/promises';

import {
  POSTHOG_PROJECT_KEY,
  POSTHOG_PROXY_HOST,
  POSTHOG_UI_HOST,
  DOCS_OTHER_PATH,
  DOCS_SLUGS,
  WEB_VITALS_FLUSH_DELAY_MS,
  buildCtaEvent,
  buildPageleaveEvent,
  buildPageviewEvent,
  buildWebVitalsEvent,
  canonicalizeAnalyticsRoute,
  createPostHogOptions,
  createRouteTracker,
  createSanitizer,
  createWebVitalsReporter,
  isTrackingOptedOut,
  isValidCta,
  sanitizeEvent,
  shouldInitializeAnalytics,
} from '../dist/analytics-contract.mjs';

const BASE = { schema_version: 1, site: 'idlescreen', surface: 'marketing' };
const COOKIELESS = {
  token: POSTHOG_PROJECT_KEY,
  $cookieless_mode: true,
  $process_person_profile: false,
  $raw_user_agent: 'Mozilla/5.0 (Macintosh)',
  $host: 'idlescreen.codeswhat.com',
};

const DOCS = { schema_version: 1, site: 'idlescreen', surface: 'docs' };

test('docs routes canonicalize to the docs surface and a known-slug allowlist', () => {
  assert.deepEqual(canonicalizeAnalyticsRoute('/docs'), { normalizedPath: '/docs', path: '/docs', surface: 'docs' });
  assert.equal(canonicalizeAnalyticsRoute('/docs/').path, '/docs');
  assert.equal(canonicalizeAnalyticsRoute('/docs/studio').path, '/docs/studio');
  assert.equal(canonicalizeAnalyticsRoute('/docs/studio/').path, '/docs/studio');
  assert.equal(canonicalizeAnalyticsRoute('/docs/studio.html?a=1#frag').path, '/docs/studio');
  assert.equal(canonicalizeAnalyticsRoute('/docs/getting-started').surface, 'docs');
  for (const unknown of ['/docs/no-such-page', '/docs/studio/extra', '/docs/_next/static/x.js', '/docs/private/acme?token=secret', '/docs/STUDIO']) {
    assert.deepEqual(
      [canonicalizeAnalyticsRoute(unknown).path, canonicalizeAnalyticsRoute(unknown).surface],
      [DOCS_OTHER_PATH, 'docs'],
      unknown,
    );
  }
  assert.deepEqual(buildPageviewEvent('/docs/camera').properties, { ...DOCS, path: '/docs/camera', $pathname: '/docs/camera' });
});

test('the docs slug allowlist matches the pages in docs-site/content/docs', async () => {
  const dir = new URL('../../docs-site/content/docs/', import.meta.url);
  const slugs = (await readdir(dir)).filter(name => name.endsWith('.mdx')).map(name => name.slice(0, -4)).filter(name => name !== 'index');
  assert.deepEqual([...DOCS_SLUGS].sort(), slugs.sort());
});

test('the route tracker emits a pageview only when the canonical route changes', () => {
  const events = [];
  const track = createRouteTracker('/docs', event => events.push(event));
  track('/docs');
  track('/docs?q=1#x');
  assert.deepEqual(events, []);
  track('/docs/studio');
  track('/docs/studio/');
  track('/docs/never-heard-of-it?token=secret');
  assert.deepEqual(events.map(event => event.properties.path), ['/docs/studio', DOCS_OTHER_PATH]);
  assert.ok(events.every(event => event.event === '$pageview' && event.properties.surface === 'docs'));
});

test('docs events pass through before_send on the docs allowlist and opt-outs still drop them', () => {
  const docsEnvelope = (event, extra = {}) => fakeEnvelope(event, { $current_url: 'https://idlescreen.codeswhat.com/docs/studio?utm_source=x&token=secret#h', ...extra });
  const out = sanitizeEvent(docsEnvelope('$pageview'));
  assert.equal(out.properties.surface, 'docs');
  assert.equal(out.properties.path, '/docs/studio');
  assert.equal(out.properties.site, 'idlescreen');
  assert.ok(!JSON.stringify(out).includes('secret'));
  assert.equal(createSanitizer({ navigator: { doNotTrack: '1' }, window: {} })(docsEnvelope('$pageview')), null);
  assert.equal(createSanitizer({ navigator: { globalPrivacyControl: true }, window: {} })(docsEnvelope('$web_vitals', { $web_vitals_LCP_value: 1200 })), null);
});

test('pageviews canonicalize "/" and collapse everything else to /_other', () => {
  assert.deepEqual(buildPageviewEvent('/?utm_source=x#hero'), {
    event: '$pageview',
    properties: { ...BASE, path: '/', $pathname: '/' },
  });
  assert.equal(canonicalizeAnalyticsRoute('/index.html').path, '/');
  assert.equal(canonicalizeAnalyticsRoute('/index.html?a=1#b').path, '/');
  assert.equal(canonicalizeAnalyticsRoute('/docsify').path, '/_other');
  assert.equal(canonicalizeAnalyticsRoute('/private/acme?token=secret').path, '/_other');
  assert.equal(canonicalizeAnalyticsRoute('no-leading-slash').path, '/');
  assert.equal(canonicalizeAnalyticsRoute('/').surface, 'marketing');
});

test('pageleave mirrors the pageview contract', () => {
  assert.deepEqual(buildPageleaveEvent('/index.html#x'), {
    event: '$pageleave',
    properties: { ...BASE, path: '/', $pathname: '/' },
  });
  assert.equal(buildPageleaveEvent('/nope').properties.$pathname, '/_other');
});

test('$pathname never diverges from the allowlisted path', () => {
  for (const raw of ['/', '/index.html', '/x/y?z=1', '/docs/a', '']) {
    for (const build of [buildPageviewEvent, buildPageleaveEvent]) {
      const { properties } = build(raw);
      assert.equal(properties.$pathname, properties.path);
    }
  }
});

test('CTA events accept only the allowed id and placement combinations', () => {
  const allowed = [
    'download:hero', 'install_brew:hero', 'install_brew:install', 'github_repository:header',
    'github_repository:hero', 'github_repository:footer', 'github_releases:footer', 'docs_root:header',
  ];
  for (const combo of allowed) {
    const [id, placement] = combo.split(':');
    assert.ok(isValidCta(id, placement));
    assert.deepEqual(buildCtaEvent('/', id, placement), {
      event: 'cta activated',
      properties: { ...BASE, path: '/', cta_id: id, placement },
    });
  }
  assert.equal(buildCtaEvent('/', 'download', 'footer'), null);
  assert.equal(buildCtaEvent('/', 'docs_root', 'hero'), null);
  assert.equal(buildCtaEvent('/', 'install_quick', 'get_started'), null);
  assert.equal(buildCtaEvent('/', 'github_repository', 'sidebar'), null);
  assert.equal(buildCtaEvent('/', undefined, undefined), null);
  assert.equal(buildCtaEvent('/', '__proto__', 'hero'), null);
});

test('web vitals events carry only finite non-negative CLS/FCP/INP/LCP values', () => {
  assert.deepEqual(buildWebVitalsEvent('/', { CLS: 0.01, FCP: 100, INP: 50, LCP: 1200 }), {
    event: '$web_vitals',
    properties: {
      ...BASE, path: '/',
      $web_vitals_CLS_value: 0.01, $web_vitals_FCP_value: 100,
      $web_vitals_INP_value: 50, $web_vitals_LCP_value: 1200,
    },
  });
  const partial = buildWebVitalsEvent('/', { LCP: 5, CLS: -1, FCP: Number.NaN, INP: Infinity, TTFB: 3 });
  assert.deepEqual(partial.properties, { ...BASE, path: '/', $web_vitals_LCP_value: 5 });
  assert.equal(buildWebVitalsEvent('/', {}), null);
  assert.equal(buildWebVitalsEvent('/', { CLS: -1 }), null);
});

// A realistic envelope posthog-js hands to before_send, with everything we must not forward.
const fakeEnvelope = (event, extra = {}) => ({
  uuid: '018f0000-0000-7000-8000-000000000001',
  event,
  timestamp: new Date('2026-11-17T12:00:00Z'),
  properties: {
    ...COOKIELESS,
    distinct_id: '$posthog_cookieless',
    $current_url: 'https://idlescreen.codeswhat.com/?utm_source=hn&gclid=abc123&email=a@b.co#install',
    $pathname: '/secret/raw',
    $referrer: 'https://news.ycombinator.com/item?id=1',
    $referring_domain: 'news.ycombinator.com',
    $initial_referrer: 'https://x.test/private',
    $initial_referring_domain: 'x.test',
    $ip: '203.0.113.9',
    $set: { email: 'a@b.co' },
    $set_once: { first: 'x' },
    $device_id: 'dev-1',
    $session_id: 'sess-1',
    $window_id: 'win-1',
    $screen_width: 1440,
    $browser: 'Chrome',
    $os: 'Mac OS X',
    $lib: 'web',
    $lib_version: '1.449.2',
    gclid: 'abc123',
    fbclid: 'fb1',
    msclkid: 'ms1',
    utm_source: 'hn',
    utm_medium: 'https://evil.test/path',
    utm_campaign: '%2Fprivate',
    utm_content: 'launch',
    utm_term: 'a?b=c',
    ...extra,
  },
});

test('before_send rebuilds a strict allowlisted pageview and drops all junk', () => {
  const out = sanitizeEvent(fakeEnvelope('$pageview'));
  assert.deepEqual(out, {
    event: '$pageview',
    uuid: '018f0000-0000-7000-8000-000000000001',
    timestamp: new Date('2026-11-17T12:00:00Z'),
    properties: {
      ...BASE,
      path: '/',
      $pathname: '/',
      utm_source: 'hn',
      utm_content: 'launch',
      $referring_domain: 'news.ycombinator.com',
      ...COOKIELESS,
      distinct_id: '$posthog_cookieless',
    },
  });
  const keys = Object.keys(out.properties);
  for (const banned of ['$referrer', '$current_url', '$ip', '$set', '$set_once', 'gclid', 'fbclid', 'msclkid', '$device_id', '$session_id', '$initial_referrer', 'utm_medium', 'utm_campaign', 'utm_term']) {
    assert.ok(!keys.includes(banned), `${banned} leaked`);
  }
});

test('before_send rebuilds pageleave, cta and web vitals envelopes', () => {
  const leave = sanitizeEvent(fakeEnvelope('$pageleave'));
  assert.equal(leave.event, '$pageleave');
  assert.equal(leave.properties.path, '/');
  assert.equal(leave.properties.$pathname, '/');

  const cta = sanitizeEvent(fakeEnvelope('cta activated', { path: '/', cta_id: 'download', placement: 'hero', stray: 1 }));
  assert.equal(cta.event, 'cta activated');
  assert.equal(cta.properties.cta_id, 'download');
  assert.equal(cta.properties.placement, 'hero');
  assert.equal(cta.properties.stray, undefined);

  const vitals = sanitizeEvent(fakeEnvelope('$web_vitals', {
    path: '/', $web_vitals_LCP_value: 900, $web_vitals_CLS_value: 0.02, $web_vitals_LCP_event: { x: 1 }, $web_vitals_TTFB_value: 5,
  }));
  assert.equal(vitals.event, '$web_vitals');
  assert.equal(vitals.properties.$web_vitals_LCP_value, 900);
  assert.equal(vitals.properties.$web_vitals_CLS_value, 0.02);
  assert.equal(vitals.properties.$web_vitals_LCP_event, undefined);
  assert.equal(vitals.properties.$web_vitals_TTFB_value, undefined);
});

test('before_send derives the path from $current_url and canonicalizes it', () => {
  const env = fakeEnvelope('$pageview', { $current_url: 'https://idlescreen.codeswhat.com/index.html?x=1#y' });
  assert.equal(sanitizeEvent(env).properties.path, '/');
  const other = fakeEnvelope('$pageview', { $current_url: 'https://idlescreen.codeswhat.com/account/42?token=s' });
  assert.equal(sanitizeEvent(other).properties.path, '/_other');
  assert.equal(sanitizeEvent(fakeEnvelope('$pageview', { $current_url: 'not a url' })), null);
});

test('before_send rejects rejected CTA combinations and unknown events', () => {
  assert.equal(sanitizeEvent(fakeEnvelope('cta activated', { path: '/', cta_id: 'download', placement: 'footer' })), null);
  assert.equal(sanitizeEvent(fakeEnvelope('cta activated', { path: '/', cta_id: 1, placement: 'hero' })), null);
  assert.equal(sanitizeEvent(fakeEnvelope('$autocapture')), null);
  assert.equal(sanitizeEvent(fakeEnvelope('$identify')), null);
  assert.equal(sanitizeEvent(fakeEnvelope('$web_vitals', { path: '/' })), null);
  assert.equal(sanitizeEvent(null), null);
  assert.equal(sanitizeEvent({ event: '$pageview' }), null);
});

test('before_send requires the cookieless server-hash fields', () => {
  assert.equal(sanitizeEvent(fakeEnvelope('$pageview', { $cookieless_mode: false })), null);
  assert.equal(sanitizeEvent(fakeEnvelope('$pageview', { $cookieless_mode: undefined })), null);
  assert.equal(sanitizeEvent(fakeEnvelope('$pageview', { $process_person_profile: true })), null);
  assert.equal(sanitizeEvent(fakeEnvelope('$pageview', { $raw_user_agent: undefined })), null);
  assert.equal(sanitizeEvent(fakeEnvelope('$pageview', { $raw_user_agent: '' })), null);
  assert.equal(sanitizeEvent(fakeEnvelope('$pageview', { $host: undefined })), null);
  assert.equal(sanitizeEvent(fakeEnvelope('$pageview', { $host: '' })), null);
  assert.equal(sanitizeEvent(fakeEnvelope('$pageview', { token: 'not-a-key' })), null);
  assert.equal(sanitizeEvent(fakeEnvelope('$pageview', { token: undefined })), null);
});

test('before_send keeps the cookieless distinct_id only, and drops any other', () => {
  const real = sanitizeEvent(fakeEnvelope('$pageview', { distinct_id: 'person-123' }));
  assert.equal('distinct_id' in real.properties, false);
  const noTimestamp = fakeEnvelope('$pageview');
  noTimestamp.timestamp = 'yesterday';
  assert.equal('timestamp' in sanitizeEvent(noTimestamp), false);
});

test('before_send validates $referring_domain and never copies $referrer', () => {
  const run = (value) => sanitizeEvent(fakeEnvelope('$pageview', { $referring_domain: value })).properties.$referring_domain;
  assert.equal(run('$direct'), '$direct');
  assert.equal(run('example.com'), 'example.com');
  assert.equal(run('localhost:3000'), 'localhost:3000');
  assert.equal(run('example.com/path'), undefined);
  assert.equal(run('https://example.com'), undefined);
  assert.equal(run('example.com?x=1'), undefined);
  assert.equal(run('user@example.com'), undefined);
  assert.equal(run(''), undefined);
  assert.equal(run(42), undefined);
  assert.equal('$referrer' in sanitizeEvent(fakeEnvelope('$pageview')).properties, false);
});

test('before_send drops URL-shaped, escaped and oversize UTM values', () => {
  const run = (value) => sanitizeEvent(fakeEnvelope('$pageview', { utm_source: value })).properties.utm_source;
  assert.equal(run('newsletter'), 'newsletter');
  assert.equal(run('50% off'), '50% off');
  for (const bad of ['https://a.test', '//a.test/p', '/account/reset', 'a?b=1', 'a#b', 'a\\b', '%2Fprivate', '%252Facme', '', 'x'.repeat(201), 7]) {
    assert.equal(run(bad), undefined, String(bad));
  }
});

test('PostHog options match the cookieless contract and gate on the exact proxy', () => {
  const options = createPostHogOptions(POSTHOG_PROJECT_KEY, POSTHOG_PROXY_HOST, POSTHOG_UI_HOST);
  assert.equal(options.api_host, 'https://e.codeswhat.com');
  assert.equal(options.ui_host, 'https://us.posthog.com');
  assert.equal(options.cookieless_mode, 'always');
  assert.equal(options.person_profiles, 'never');
  assert.equal(options.persistence, 'memory');
  assert.equal(options.disable_persistence, true);
  assert.equal(options.autocapture, false);
  assert.equal(options.capture_pageview, false);
  assert.equal(options.capture_pageleave, true);
  assert.equal(options.save_referrer, true);
  assert.equal(options.save_campaign_params, true);
  assert.equal(options.disable_session_recording, true);
  assert.equal(options.capture_heatmaps, false);
  assert.equal(options.before_send, sanitizeEvent);
  assert.equal(createPostHogOptions(undefined, POSTHOG_PROXY_HOST, POSTHOG_UI_HOST), null);
  assert.equal(createPostHogOptions('bad', POSTHOG_PROXY_HOST, POSTHOG_UI_HOST), null);
  assert.equal(createPostHogOptions(POSTHOG_PROJECT_KEY, 'https://us.i.posthog.com', POSTHOG_UI_HOST), null);
  assert.equal(createPostHogOptions(POSTHOG_PROJECT_KEY, POSTHOG_PROXY_HOST, 'https://eu.posthog.com'), null);
});

test('analytics initialize only on the production host', () => {
  assert.equal(shouldInitializeAnalytics('idlescreen.codeswhat.com'), true);
  for (const host of ['localhost', '127.0.0.1', 'idlescreen-git-x.vercel.app', 'idlescreen.codeswhat.com.evil.test', 'codeswhat.com', '', undefined]) {
    assert.equal(shouldInitializeAnalytics(host), false, String(host));
  }
});

test('the web vitals reporter emits one complete event once all four arrive', () => {
  const events = [];
  const scheduled = [];
  const reporter = createWebVitalsReporter('/index.html?x=1', (e) => events.push(e), (cb, ms) => { scheduled.push(ms); return cb; }, () => {});
  for (const [name, value] of [['CLS', 0.1], ['FCP', 10], ['INP', 20], ['LCP', 30]]) reporter.record(name, value);
  assert.equal(events.length, 1);
  assert.equal(events[0].properties.path, '/');
  assert.deepEqual(scheduled, [WEB_VITALS_FLUSH_DELAY_MS]);
  reporter.record('LCP', 99);
  reporter.flush();
  assert.equal(events.length, 1);
});

test('the web vitals reporter flushes on flush(), keeps late metrics for the next flush, and sends each name once', () => {
  const events = [];
  let timerCallback;
  let cancelled = 0;
  const reporter = createWebVitalsReporter('/', (e) => events.push(e), (cb) => { timerCallback = cb; return 'timer'; }, () => { cancelled += 1; });
  reporter.record('TTFB', 5);
  reporter.record('LCP', -1);
  reporter.record('FCP', Number.NaN);
  assert.equal(timerCallback, undefined);
  reporter.record('LCP', 800);
  reporter.flush();
  assert.equal(cancelled, 1);
  assert.equal(events.length, 1);
  assert.deepEqual(events[0].properties, { ...BASE, path: '/', $web_vitals_LCP_value: 800 });
  reporter.record('LCP', 900);
  reporter.flush();
  assert.equal(events.length, 1);
  reporter.record('CLS', 0.2);
  reporter.flush();
  assert.equal(events.length, 2);
  assert.deepEqual(events[1].properties, { ...BASE, path: '/', $web_vitals_CLS_value: 0.2 });

  const empty = [];
  createWebVitalsReporter('/', (e) => empty.push(e)).flush();
  assert.deepEqual(empty, []);
});

test('the timer sends LCP+FCP, then the hide flush sends only the late CLS and INP', () => {
  const events = [];
  let timerCallback;
  const reporter = createWebVitalsReporter('/', (e) => events.push(e), (cb) => { timerCallback = cb; return 'timer'; }, () => {});
  reporter.record('LCP', 640);
  reporter.record('FCP', 300);
  timerCallback();
  assert.equal(events.length, 1);
  assert.deepEqual(events[0].properties, { ...BASE, path: '/', $web_vitals_LCP_value: 640, $web_vitals_FCP_value: 300 });
  reporter.record('CLS', 0.3);
  reporter.record('INP', 80);
  reporter.record('LCP', 700);
  reporter.flush();
  assert.equal(events.length, 2);
  assert.deepEqual(events[1].properties, { ...BASE, path: '/', $web_vitals_CLS_value: 0.3, $web_vitals_INP_value: 80 });
  reporter.flush();
  assert.equal(events.length, 2);
});

test('an unsent metric updates to its latest value before the flush', () => {
  const events = [];
  const reporter = createWebVitalsReporter('/', (e) => events.push(e), () => 'timer', () => {});
  reporter.record('CLS', 0.1);
  reporter.record('CLS', 0.4);
  reporter.flush();
  assert.equal(events[0].properties.$web_vitals_CLS_value, 0.4);
});

test('a visit shorter than the flush delay gets everything on the hide flush', () => {
  const events = [];
  let timerCallback;
  const reporter = createWebVitalsReporter('/', (e) => events.push(e), (cb) => { timerCallback = cb; return 'timer'; }, () => {});
  reporter.record('FCP', 200);
  reporter.record('LCP', 500);
  reporter.record('CLS', 0.05);
  assert.equal(events.length, 0);
  reporter.flush();
  assert.equal(events.length, 1);
  assert.deepEqual(events[0].properties, {
    ...BASE, path: '/', $web_vitals_CLS_value: 0.05, $web_vitals_FCP_value: 200, $web_vitals_LCP_value: 500,
  });
});

test('all four arriving across sends still sends immediately when the last lands', () => {
  const events = [];
  const reporter = createWebVitalsReporter('/', (e) => events.push(e), () => 'timer', () => {});
  reporter.record('LCP', 1);
  reporter.flush();
  reporter.record('FCP', 2);
  reporter.record('CLS', 3);
  assert.equal(events.length, 1);
  reporter.record('INP', 4);
  assert.equal(events.length, 2);
  assert.deepEqual(Object.keys(events[1].properties).filter((k) => k.startsWith('$web_vitals')).sort(),
    ['$web_vitals_CLS_value', '$web_vitals_FCP_value', '$web_vitals_INP_value']);
});

test('isTrackingOptedOut honors DNT, msDoNotTrack, window DNT and GPC', () => {
  assert.equal(isTrackingOptedOut({ doNotTrack: '1' }), true);
  assert.equal(isTrackingOptedOut({ doNotTrack: 'yes' }), true);
  assert.equal(isTrackingOptedOut({ msDoNotTrack: '1' }), true);
  assert.equal(isTrackingOptedOut({ globalPrivacyControl: true }), true);
  assert.equal(isTrackingOptedOut({}, { doNotTrack: '1' }), true);
  assert.equal(isTrackingOptedOut({ doNotTrack: '0', msDoNotTrack: '0', globalPrivacyControl: false }, { doNotTrack: '0' }), false);
  assert.equal(isTrackingOptedOut({ doNotTrack: 'unspecified' }), false);
  assert.equal(isTrackingOptedOut({}), false);
  assert.equal(isTrackingOptedOut(undefined), false);
  assert.equal(isTrackingOptedOut(null, undefined), false);
});

test('the sanitizer returns null for a valid envelope when the navigator opts out', () => {
  const envelope = fakeEnvelope('$pageview');
  assert.equal(createSanitizer({ navigator: { doNotTrack: '1' }, window: {} })(envelope), null);
  assert.equal(createSanitizer({ navigator: { globalPrivacyControl: true }, window: {} })(envelope), null);
  const allowed = createSanitizer({ navigator: { doNotTrack: '0' }, window: {} })(envelope);
  assert.equal(allowed.event, '$pageview');
  assert.deepEqual(createSanitizer({ navigator: undefined, window: {} })(envelope), sanitizeEvent(envelope));
});

test('the loader module is inert off the production host', async () => {
  // Importing in node (no location) must not start anything or throw.
  await import('../dist/analytics.mjs');
  const html = await readFile(new URL('../dist/index.html', import.meta.url), 'utf8');
  assert.match(html, /<script type="module" src="\.\/analytics\.mjs"><\/script>/);
});
