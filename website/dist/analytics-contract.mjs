// Privacy contract for PostHog analytics on idlescreen.codeswhat.com: the marketing
// page and the /docs app share this one module, so the privacy rules can't drift. Pure: no DOM, no
// network, importable in node. Ported from the portwing analytics contract.
// The before_send sanitizer rebuilds every envelope from an allowlist, so
// nothing PostHog attaches by default (full URL, referrer, click ids, person
// properties) can leave the browser.

export const POSTHOG_PROJECT_KEY = 'phc_mav2oHZzTVaC4mAFEqaLbGEff65uvGMy47LcWSNBFp9J';
export const POSTHOG_PROXY_HOST = 'https://e.codeswhat.com';
export const POSTHOG_UI_HOST = 'https://us.posthog.com';
export const PRODUCTION_HOSTNAME = 'idlescreen.codeswhat.com';

const SCHEMA_VERSION = 1;
const SITE = 'idlescreen';
const MARKETING_SURFACE = 'marketing';
const DOCS_SURFACE = 'docs';
const PROJECT_KEY_PATTERN = /^phc_[A-Za-z0-9_-]+$/u;
const COOKIELESS_DISTINCT_ID = '$posthog_cookieless';

const MARKETING_PATHS = new Set(['/']);

// Docs routes, one per page in docs-site/content/docs (tests keep this in step with
// the content). Any other /docs path reports as DOCS_OTHER_PATH, never verbatim.
export const DOCS_ROOT = '/docs';
export const DOCS_OTHER_PATH = '/docs/_other';
export const DOCS_SLUGS = [
  'agent-signals',
  'architecture',
  'building',
  'camera',
  'changelog',
  'displays',
  'getting-started',
  'menu-bar',
  'security',
  'studio',
  'troubleshooting',
];
const DOCS_PATHS = new Set([DOCS_ROOT, ...DOCS_SLUGS.map(slug => `${DOCS_ROOT}/${slug}`)]);

const CTA_COMBINATIONS = new Set([
  'download:hero',
  'install_brew:hero',
  'install_brew:install',
  'github_repository:header',
  'github_repository:hero',
  'github_repository:footer',
  'github_releases:footer',
  'docs_root:header',
]);

const WEB_VITAL_NAMES = ['CLS', 'FCP', 'INP', 'LCP'];

// Only the real production host reports. Localhost, the e2e server and preview
// deployments send nothing, which keeps test traffic out of the data.
export function shouldInitializeAnalytics(hostname) {
  return hostname === PRODUCTION_HOSTNAME;
}

export function isValidCta(ctaId, placement) {
  return CTA_COMBINATIONS.has(`${ctaId}:${placement}`);
}

function normalizedPath(rawPath) {
  const withoutQuery = String(rawPath).split(/[?#]/u, 1)[0] || '/';
  if (!withoutQuery.startsWith('/')) return '/';
  if (withoutQuery === '/index.html') return '/';
  const withoutHtml = withoutQuery.replace(/\.html$/u, '');
  if (withoutHtml.length > 1 && withoutHtml.endsWith('/')) return withoutHtml.slice(0, -1);
  return withoutHtml;
}

function isDocsRoute(normalized) {
  return normalized === DOCS_ROOT || normalized.startsWith(`${DOCS_ROOT}/`);
}

export function canonicalizeAnalyticsRoute(rawPath) {
  const normalized = normalizedPath(rawPath);
  if (isDocsRoute(normalized)) {
    return {
      normalizedPath: normalized,
      path: DOCS_PATHS.has(normalized) ? normalized : DOCS_OTHER_PATH,
      surface: DOCS_SURFACE,
    };
  }
  return {
    normalizedPath: normalized,
    path: MARKETING_PATHS.has(normalized) ? normalized : '/_other',
    surface: MARKETING_SURFACE,
  };
}

function baseProperties(rawPath) {
  const { path, surface } = canonicalizeAnalyticsRoute(rawPath);
  return { schema_version: SCHEMA_VERSION, site: SITE, surface, path };
}

// PostHog's Web analytics tables key off $pathname. It mirrors the already
// allowlisted `path`, so it carries nothing the event was not sending anyway.
function navigationProperties(rawPath) {
  const base = baseProperties(rawPath);
  return { ...base, $pathname: base.path };
}

export function buildPageviewEvent(rawPath) {
  return { event: '$pageview', properties: navigationProperties(rawPath) };
}

// posthog-js emits $pageleave itself once capture_pageleave is true.
export function buildPageleaveEvent(rawPath) {
  return { event: '$pageleave', properties: navigationProperties(rawPath) };
}

export function buildCtaEvent(rawPath, ctaId, placement) {
  if (!isValidCta(ctaId, placement)) return null;
  return {
    event: 'cta activated',
    properties: { ...baseProperties(rawPath), cta_id: ctaId, placement },
  };
}

export function buildWebVitalsEvent(rawPath, metrics) {
  const properties = baseProperties(rawPath);
  let metricCount = 0;
  for (const name of WEB_VITAL_NAMES) {
    const value = metrics[name];
    if (typeof value === 'number' && Number.isFinite(value) && value >= 0) {
      properties[`$web_vitals_${name}_value`] = value;
      metricCount += 1;
    }
  }
  return metricCount === 0 ? null : { event: '$web_vitals', properties };
}

// Plain campaign labels only. Platform click ids (gclid, fbclid, ...) are
// per-click identifiers and are never named here, so the rebuild cannot forward them.
const UTM_PARAM_KEYS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term'];

// $referring_domain is "$direct" or a bare host. Anything else is dropped, not
// trimmed, so an unexpected shape can't leak a path.
const HOSTNAME_PATTERN = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:\d{1,5})?$/iu;
const DIRECT_REFERRING_DOMAIN = '$direct';

function isAcceptableReferringDomain(value) {
  return typeof value === 'string' && (value === DIRECT_REFERRING_DOMAIN || HOSTNAME_PATTERN.test(value));
}

// UTM values are labels, not URLs. Anything with path/query/fragment structure,
// a percent-escape (a doubly-encoded path survives one decode) or an over-long
// value is dropped. A bare "%" passes so "50% off" still works.
const MAX_UTM_VALUE_LENGTH = 200;
const UTM_URL_STRUCTURE_PATTERN = /[\\/?#]/u;
const UTM_PERCENT_ESCAPE_PATTERN = /%[0-9a-fA-F]{2}/u;

function isAcceptableUtmValue(value) {
  return (
    typeof value === 'string' &&
    value !== '' &&
    value.length <= MAX_UTM_VALUE_LENGTH &&
    !UTM_URL_STRUCTURE_PATTERN.test(value) &&
    !UTM_PERCENT_ESCAPE_PATTERN.test(value)
  );
}

function acquisitionProperties(properties) {
  const acquisition = {};
  for (const key of UTM_PARAM_KEYS) {
    if (isAcceptableUtmValue(properties[key])) acquisition[key] = properties[key];
  }
  if (isAcceptableReferringDomain(properties.$referring_domain)) {
    acquisition.$referring_domain = properties.$referring_domain;
  }
  return acquisition;
}

function rawPathFromProperties(properties) {
  if (typeof properties.path === 'string') return properties.path;
  if (typeof properties.$current_url !== 'string') return undefined;
  try {
    return new URL(properties.$current_url).pathname;
  } catch {
    return undefined;
  }
}

// posthog-js ignores respect_dnt in cookieless_mode "always", so the contract
// checks the browser's own opt-out signals (DNT, GPC) itself.
export function isTrackingOptedOut(nav, win) {
  if (nav && (nav.doNotTrack === '1' || nav.doNotTrack === 'yes' || nav.msDoNotTrack === '1' || nav.globalPrivacyControl === true)) {
    return true;
  }
  return Boolean(win && win.doNotTrack === '1');
}

// The navigator is injectable for tests; by default it is read from globalThis at call time.
export function createSanitizer(options = {}) {
  return function sanitize(envelope) {
    const nav = 'navigator' in options ? options.navigator : globalThis.navigator;
    const win = 'window' in options ? options.window : globalThis;
    if (isTrackingOptedOut(nav, win)) return null;
    return rebuildEnvelope(envelope);
  };
}

function rebuildEnvelope(envelope) {
  if (!envelope || typeof envelope.event !== 'string' || !envelope.properties) return null;
  const rawPath = rawPathFromProperties(envelope.properties);
  const projectKey = envelope.properties.token;
  // PostHog's cookieless server hash reads $raw_user_agent and $host off the
  // event properties and drops the event without them, so both survive the
  // rebuild. $ip is never forwarded: the capture service fills it in itself.
  const rawUserAgent = envelope.properties.$raw_user_agent;
  const host = envelope.properties.$host;
  if (
    typeof rawPath !== 'string' ||
    typeof projectKey !== 'string' ||
    !PROJECT_KEY_PATTERN.test(projectKey) ||
    envelope.properties.$cookieless_mode !== true ||
    envelope.properties.$process_person_profile !== false ||
    typeof rawUserAgent !== 'string' ||
    rawUserAgent === '' ||
    typeof host !== 'string' ||
    host === ''
  ) {
    return null;
  }

  let sanitized;
  if (envelope.event === '$pageview') {
    sanitized = buildPageviewEvent(rawPath);
  } else if (envelope.event === '$pageleave') {
    sanitized = buildPageleaveEvent(rawPath);
  } else if (envelope.event === 'cta activated') {
    const { cta_id: ctaId, placement } = envelope.properties;
    if (typeof ctaId !== 'string' || typeof placement !== 'string') return null;
    sanitized = buildCtaEvent(rawPath, ctaId, placement);
  } else if (envelope.event === '$web_vitals') {
    const metrics = {};
    for (const name of WEB_VITAL_NAMES) {
      const value = envelope.properties[`$web_vitals_${name}_value`];
      if (typeof value === 'number') metrics[name] = value;
    }
    sanitized = buildWebVitalsEvent(rawPath, metrics);
  } else {
    return null;
  }

  if (!sanitized) return null;
  const output = {
    event: sanitized.event,
    properties: {
      ...sanitized.properties,
      ...acquisitionProperties(envelope.properties),
      token: projectKey,
      $cookieless_mode: true,
      $process_person_profile: false,
      $raw_user_agent: rawUserAgent,
      $host: host,
    },
    uuid: envelope.uuid,
  };
  if (envelope.properties.distinct_id === COOKIELESS_DISTINCT_ID) {
    output.properties.distinct_id = COOKIELESS_DISTINCT_ID;
  }
  if (envelope.timestamp instanceof Date && Number.isFinite(envelope.timestamp.getTime())) {
    output.timestamp = envelope.timestamp;
  }
  return output;
}

export const sanitizeEvent = createSanitizer();

export function createPostHogOptions(projectKey, proxyHost, uiHost) {
  if (
    !projectKey ||
    !PROJECT_KEY_PATTERN.test(projectKey) ||
    proxyHost !== POSTHOG_PROXY_HOST ||
    uiHost !== POSTHOG_UI_HOST
  ) {
    return null;
  }
  return {
    api_host: POSTHOG_PROXY_HOST,
    ui_host: POSTHOG_UI_HOST,
    autocapture: false,
    rageclick: false,
    capture_pageview: false,
    capture_pageleave: true,
    capture_heatmaps: false,
    capture_dead_clicks: false,
    capture_exceptions: false,
    disable_session_recording: true,
    disable_surveys: true,
    disable_surveys_automatic_display: true,
    disable_product_tours: true,
    disable_web_experiments: true,
    advanced_disable_flags: true,
    cookieless_mode: 'always',
    person_profiles: 'never',
    persistence: 'memory',
    disable_persistence: true,
    respect_dnt: true,
    save_campaign_params: true,
    save_referrer: true,
    disable_capture_url_hashes: true,
    disable_scroll_properties: true,
    mask_all_element_attributes: true,
    mask_all_text: true,
    capture_performance: false,
    before_send: sanitizeEvent,
  };
}

// Fires a pageview when the canonical path changes. The docs app is a Next app router
// SPA: client-side navigation never reloads the page, so it has to be noticed. Query and
// fragment changes on the same route are not new pageviews.
export function createRouteTracker(initialPath, emit) {
  let current = canonicalizeAnalyticsRoute(initialPath).normalizedPath;
  return function onNavigate(nextPath) {
    const next = canonicalizeAnalyticsRoute(nextPath).normalizedPath;
    if (next === current) return;
    current = next;
    emit(buildPageviewEvent(next));
  };
}

export const WEB_VITALS_FLUSH_DELAY_MS = 5_000;

// Collects CLS/FCP/INP/LCP. A flush (timer, explicit flush() on page hide, or all
// four arrived) sends the metrics not yet sent as one $web_vitals event. Late
// metrics stay buffered for the next flush. Each metric name is sent at most
// once per page: a repeat of a sent metric is ignored, and an unsent metric's
// value updates to the latest.
export function createWebVitalsReporter(
  initialPath,
  emit,
  schedule = (callback, delayMs) => setTimeout(callback, delayMs),
  cancel = (timer) => clearTimeout(timer),
) {
  const path = canonicalizeAnalyticsRoute(initialPath).normalizedPath;
  const pending = {};
  const sent = new Set();
  let timer;

  const flush = () => {
    if (timer !== undefined) {
      cancel(timer);
      timer = undefined;
    }
    const event = buildWebVitalsEvent(path, pending);
    if (!event) return;
    for (const name of Object.keys(pending)) {
      sent.add(name);
      delete pending[name];
    }
    emit(event);
  };

  return {
    record(name, value) {
      if (!WEB_VITAL_NAMES.includes(name) || sent.has(name)) return;
      if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return;
      pending[name] = value;
      if (WEB_VITAL_NAMES.length === sent.size + Object.keys(pending).length) {
        flush();
      } else if (timer === undefined) {
        timer = schedule(flush, WEB_VITALS_FLUSH_DELAY_MS);
      }
    },
    flush,
  };
}
