import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

import {
  checkVendorAnalytics,
  jsArtifacts,
  licenseArtifacts,
  normalizeJs,
  vendorAnalytics,
} from '../scripts/vendor-analytics.mjs';

async function fixtureRoot() {
  const dir = await mkdtemp(join(tmpdir(), 'vendor-analytics-'));
  const root = pathToFileURL(`${dir}/`);
  for (const [from] of [...jsArtifacts, ...licenseArtifacts]) {
    const path = join(dir, 'node_modules', from);
    await mkdir(join(path, '..'), { recursive: true });
    const body = from.endsWith('.js')
      ? `export const name = '${from}';\n//# sourceMappingURL=x.js.map\n`
      : `license for ${from}\n`;
    await writeFile(path, body);
  }
  return { dir, root };
}

async function withFixture(run) {
  const fixture = await fixtureRoot();
  try {
    await run(fixture);
  } finally {
    await rm(fixture.dir, { recursive: true, force: true });
  }
}

const vendorPath = (dir, name) => join(dir, 'dist/assets/vendor', name);

test('normalizeJs strips only a trailing source map comment', () => {
  assert.equal(normalizeJs('a();\n//# sourceMappingURL=a.map\n'), 'a();\n');
  assert.equal(normalizeJs('a();\n// keep\n'), 'a();\n// keep\n');
});

test('check passes when committed vendor files match the installed packages', async () => {
  await withFixture(async ({ root }) => {
    await vendorAnalytics(root);
    assert.deepEqual(await checkVendorAnalytics(root), []);
  });
});

test('check fails on changed JS bytes and changed license bytes', async () => {
  await withFixture(async ({ dir, root }) => {
    await vendorAnalytics(root);
    const [, js] = jsArtifacts[0];
    const [, license] = licenseArtifacts[1];
    await writeFile(vendorPath(dir, js), 'export const tampered = 1;\n');
    await writeFile(vendorPath(dir, license), 'another license\n');
    const problems = await checkVendorAnalytics(root);
    assert.equal(problems.length, 2);
    assert.match(problems[0], new RegExp(js.replaceAll('.', '\\.')));
    assert.match(problems[1], new RegExp(license.replaceAll('.', '\\.')));
  });
});

test('check fails on a missing vendored artifact', async () => {
  await withFixture(async ({ dir, root }) => {
    await vendorAnalytics(root);
    await rm(vendorPath(dir, jsArtifacts[1][1]));
    const problems = await checkVendorAnalytics(root);
    assert.equal(problems.length, 1);
    assert.match(problems[0], /missing vendored artifact/u);
  });
});

test('check fails on a missing installed package', async () => {
  await withFixture(async ({ dir, root }) => {
    await vendorAnalytics(root);
    await rm(join(dir, 'node_modules/web-vitals'), { recursive: true });
    const problems = await checkVendorAnalytics(root);
    assert.equal(problems.length, 2);
    assert.ok(problems.every((problem) => /missing installed package file/u.test(problem)));
  });
});

test('check never rewrites or creates vendor files', async () => {
  await withFixture(async ({ dir, root }) => {
    const missing = await checkVendorAnalytics(root);
    assert.equal(missing.length, 4);
    await assert.rejects(stat(join(dir, 'dist')), { code: 'ENOENT' });

    await vendorAnalytics(root);
    const [, js] = jsArtifacts[0];
    await writeFile(vendorPath(dir, js), 'changed\n');
    await checkVendorAnalytics(root);
    assert.equal(await readFile(vendorPath(dir, js), 'utf8'), 'changed\n');
  });
});
