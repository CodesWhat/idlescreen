// Cookieless PostHog loader. Runs only on the production host, so localhost, the
// e2e server and preview deployments send nothing. The SDK is vendored same-origin
// (the CSP has no remote script origins) and every event goes through the
// allowlist sanitizer in analytics-contract.mjs.
import {
  POSTHOG_PROJECT_KEY,
  POSTHOG_PROXY_HOST,
  POSTHOG_UI_HOST,
  buildCtaEvent,
  buildPageviewEvent,
  createPostHogOptions,
  createWebVitalsReporter,
  shouldInitializeAnalytics,
} from './analytics-contract.mjs';

async function start() {
  const options = createPostHogOptions(POSTHOG_PROJECT_KEY, POSTHOG_PROXY_HOST, POSTHOG_UI_HOST);
  if (!options) return;
  const { default: posthog } = await import('./assets/vendor/posthog-js.slim.no-external.js');
  posthog.init(POSTHOG_PROJECT_KEY, options);

  const capture = (event) => {
    if (event) posthog.capture(event.event, event.properties);
  };
  capture(buildPageviewEvent(location.pathname));

  document.addEventListener('click', (event) => {
    const element = event.target instanceof Element ? event.target.closest('[data-cta]') : null;
    if (!element) return;
    capture(buildCtaEvent(location.pathname, element.dataset.cta, element.dataset.ctaPlacement));
  });

  const reporter = createWebVitalsReporter(location.pathname, capture);
  const vitals = await import('./assets/vendor/web-vitals.js');
  for (const [name, observe] of [['CLS', vitals.onCLS], ['FCP', vitals.onFCP], ['INP', vitals.onINP], ['LCP', vitals.onLCP]]) {
    observe((metric) => reporter.record(name, metric.value));
  }
  // CLS, INP and LCP settle when the page is hidden, so flush then rather than wait out the timer.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') reporter.flush();
  });
}

if (typeof location !== 'undefined' && shouldInitializeAnalytics(location.hostname)) {
  start().catch(() => {});
}
