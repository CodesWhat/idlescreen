import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';

const text = await readFile(new URL('../dist/.well-known/security.txt', import.meta.url), 'utf8');
const fields = Object.fromEntries(text.trim().split('\n').map(line => {
  const index = line.indexOf(':');
  return [line.slice(0, index), line.slice(index + 1).trim()];
}));
const config = JSON.parse(await readFile(new URL('../vercel.json', import.meta.url), 'utf8'));
const headerFor = (source, key) => config.headers.find(item => item.source === source)?.headers.find(header => header.key === key)?.value;

test('security.txt carries the RFC 9116 fields', () => {
  assert.equal(fields.Contact, 'mailto:security@codeswhat.com');
  assert.equal(fields.Canonical, 'https://idlescreen.codeswhat.com/.well-known/security.txt');
  assert.equal(fields['Preferred-Languages'], 'en');
});

// This goes red when Expires passes. That is intended: renew the date before then.
test('security.txt Expires is a future UTC timestamp', () => {
  assert.match(fields.Expires, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.ok(Date.parse(fields.Expires) > Date.now(), `security.txt expired ${fields.Expires}; renew it`);
});

test('vercel.json serves security.txt as text/plain', () => {
  assert.match(headerFor('/.well-known/security.txt', 'Content-Type'), /^text\/plain/);
});

test('CSP is strict: self-only scripts and styles, no inline, only the two image hosts added', () => {
  const csp = headerFor('/((?!docs$|docs/).*)', 'Content-Security-Policy');
  const directives = Object.fromEntries(csp.split(';').map(part => {
    const [name, ...values] = part.trim().split(/\s+/);
    return [name, values];
  }));
  assert.deepEqual(directives['script-src'], ["'self'"]);
  assert.deepEqual(directives['style-src'], ["'self'"]);
  assert.deepEqual(directives['default-src'], ["'self'"]);
  assert.deepEqual(directives['frame-ancestors'], ["'none'"]);
  assert.deepEqual(directives['img-src'], ["'self'", 'https://api.star-history.com', 'https://codecov.io']);
  assert.doesNotMatch(csp, /unsafe-/);
});

test('the page has no inline scripts, styles or event handlers', async () => {
  const html = await readFile(new URL('../dist/index.html', import.meta.url), 'utf8');
  const scripts = [...html.matchAll(/<script\b([^>]*)>/g)].map(match => match[1]);
  for (const attributes of scripts) {
    assert.ok(/src=|type="application\/ld\+json"/.test(attributes), `inline script: ${attributes}`);
  }
  assert.doesNotMatch(html, /<style\b/);
  assert.doesNotMatch(html, /\sstyle="/);
  assert.doesNotMatch(html, /\son[a-z]+="/);
});

test('the /docs CSP leaves script-src to each page\'s own hashed meta and still locks everything else', () => {
  const csp = headerFor('/docs/:path*', 'Content-Security-Policy');
  const directives = Object.fromEntries(csp.split(';').map(part => {
    const [name, ...values] = part.trim().split(/\s+/);
    return [name, values];
  }));
  // A script-src here would intersect with the page's meta policy and block its hashed inline scripts.
  assert.equal(directives['script-src'], undefined);
  assert.equal(directives['default-src'], undefined);
  assert.deepEqual(directives['frame-ancestors'], ["'none'"]);
  assert.deepEqual(directives['object-src'], ["'none'"]);
  assert.deepEqual(directives['img-src'], ["'self'", 'data:']);
  assert.deepEqual(directives['connect-src'], ["'self'"]);
});

test('the site-wide CSP rule does not also match /docs, where the two policies would collide', () => {
  const source = config.headers.find(item => item.source.startsWith('/((?!docs')).source;
  const pattern = new RegExp(`^${source}$`);
  assert.ok(pattern.test('/'));
  assert.ok(pattern.test('/assets/logo.png'));
  assert.ok(pattern.test('/docsify'));
  assert.ok(!pattern.test('/docs'));
  assert.ok(!pattern.test('/docs/studio'));
});
