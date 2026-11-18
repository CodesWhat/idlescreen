import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';

const CANONICAL = 'https://idlescreen.codeswhat.com/';
const read = name => readFile(new URL(`../dist/${name}`, import.meta.url), 'utf8');
const html = await read('index.html');

function jsonLd() {
  const blocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)];
  assert.equal(blocks.length, 1, 'expected exactly one JSON-LD block');
  return JSON.parse(blocks[0][1]);
}

test('JSON-LD parses as a SoftwareApplication with the required fields', () => {
  const data = jsonLd();
  assert.equal(data['@context'], 'https://schema.org');
  assert.equal(data['@type'], 'SoftwareApplication');
  assert.equal(data.name, 'IdleScreen');
  assert.equal(data.operatingSystem, 'macOS 26 or later');
  assert.equal(data.url, CANONICAL);
  assert.equal(data.downloadUrl, 'https://github.com/CodesWhat/idlescreen/releases/latest');
  assert.match(data.license, /MIT/);
  assert.equal(data.offers.price, '0');
  assert.equal(data.publisher.name, 'CodesWhat');
  assert.match(data.publisher.url, /^https:\/\/codeswhat\.com/);
});

test('JSON-LD carries no version that a release could leave stale', () => {
  assert.equal(jsonLd().softwareVersion, undefined);
});

test('social meta uses absolute URLs and a card image', () => {
  const metas = [...html.matchAll(/<meta (?:property|name)="((?:og|twitter):[^"]+)" content="([^"]*)"/g)];
  const byName = Object.fromEntries(metas.map(([, name, content]) => [name, content]));
  for (const key of ['og:url', 'og:image', 'twitter:image']) {
    assert.match(byName[key], /^https:\/\/idlescreen\.codeswhat\.com\//, `${key} must be absolute`);
  }
  assert.equal(byName['og:url'], CANONICAL);
  assert.equal(byName['twitter:card'], 'summary_large_image');
  assert.equal(byName['og:image'], byName['twitter:image']);
});

test('canonical link, sitemap and robots agree', async () => {
  assert.match(html, /<link rel="canonical" href="https:\/\/idlescreen\.codeswhat\.com\/">/);
  assert.match(await read('sitemap.xml'), /<loc>https:\/\/idlescreen\.codeswhat\.com\/<\/loc>/);
  assert.match(await read('robots.txt'), /Sitemap: https:\/\/idlescreen\.codeswhat\.com\/sitemap\.xml/);
});

test('llms.txt names the product, the install command and the source', async () => {
  const llms = await read('llms.txt');
  assert.match(llms, /^# IdleScreen/);
  assert.match(llms, /brew install --cask codeswhat\/tap\/idlescreen/);
  assert.match(llms, /github\.com\/CodesWhat\/idlescreen/);
});

test('copy has no em dashes', () => {
  assert.doesNotMatch(html, /—/);
});

test('current install guidance uses the case-correct released app path', async () => {
  assert.match(html, /\/Applications\/IdleScreen\.app/);
  assert.doesNotMatch(html, /\/Applications\/idlescreen\.app/);
  for (const name of ['getting-started', 'agent-signals']) {
    const content = await readFile(new URL(`../../docs-site/content/docs/${name}.mdx`, import.meta.url), 'utf8');
    assert.match(content, /\/Applications\/IdleScreen\.app/);
    assert.doesNotMatch(content, /\/Applications\/idlescreen\.app/);
  }
});
