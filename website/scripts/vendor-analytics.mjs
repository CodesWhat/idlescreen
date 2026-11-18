// Copies the analytics vendor files into dist/assets/vendor/ so the site can load
// them same-origin under its script-src 'self' CSP. Run after bumping posthog-js
// or web-vitals in package.json: `npm run vendor:analytics`.
//
// `--check` (`npm run vendor:analytics:check`) is read-only: it compares the committed
// vendor files against the installed packages and fails on a missing package, a missing
// artifact or any byte difference. It never writes.
//
// posthog-js: the slim no-external ES module. Slim leaves out session replay,
// surveys and the other extensions; no-external guarantees it never loads a
// remote script. It has no bundled web vitals, so web-vitals is vendored separately.
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const defaultRoot = new URL('../', import.meta.url);

// Source map comments would 404 in production, and the maps aren't shipped.
export function normalizeJs(source) {
  return source.replace(/\n\/\/# sourceMappingURL=.*\n?$/u, '\n');
}

export const jsArtifacts = [
  ['posthog-js/dist/module.slim.no-external.js', 'posthog-js.slim.no-external.js'],
  ['web-vitals/dist/web-vitals.js', 'web-vitals.js'],
];
export const licenseArtifacts = [
  ['posthog-js/LICENSE', 'posthog-js.LICENSE'],
  ['web-vitals/LICENSE', 'web-vitals.LICENSE'],
];

function directories(root) {
  return {
    out: new URL('dist/assets/vendor/', root),
    modules: new URL('node_modules/', root),
  };
}

export async function vendorAnalytics(root = defaultRoot) {
  const { out, modules } = directories(root);
  await mkdir(out, { recursive: true });
  for (const [from, to] of jsArtifacts) {
    const source = await readFile(new URL(from, modules), 'utf8');
    await writeFile(new URL(to, out), normalizeJs(source));
  }
  for (const [from, to] of licenseArtifacts) {
    await copyFile(new URL(from, modules), new URL(to, out));
  }
}

// Returns a list of problems; an empty list means the committed files match the installed packages.
export async function checkVendorAnalytics(root = defaultRoot) {
  const { out, modules } = directories(root);
  const problems = [];
  async function read(url, encoding) {
    try {
      return { data: await readFile(url, encoding) };
    } catch (error) {
      return { error };
    }
  }
  const comparisons = [
    ...jsArtifacts.map(([from, to]) => [from, to, 'utf8', normalizeJs]),
    ...licenseArtifacts.map(([from, to]) => [from, to, undefined, (data) => data]),
  ];
  for (const [from, to, encoding, normalize] of comparisons) {
    const expected = await read(new URL(from, modules), encoding);
    if (expected.error) {
      problems.push(`missing installed package file node_modules/${from} (run npm ci)`);
      continue;
    }
    const committed = await read(new URL(to, out), encoding);
    if (committed.error) {
      problems.push(`missing vendored artifact dist/assets/vendor/${to}`);
      continue;
    }
    const wanted = normalize(expected.data);
    const same =
      typeof wanted === 'string' ? wanted === committed.data : wanted.equals(committed.data);
    if (!same) {
      problems.push(
        `dist/assets/vendor/${to} differs from node_modules/${from}; run npm run vendor:analytics and commit the output`,
      );
    }
  }
  return problems;
}

async function packageVersion(name, root = defaultRoot) {
  const { modules } = directories(root);
  const { version } = JSON.parse(await readFile(new URL(`${name}/package.json`, modules), 'utf8'));
  return version;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv.includes('--check')) {
    const problems = await checkVendorAnalytics();
    if (problems.length > 0) {
      for (const problem of problems) console.error(`FAIL: ${problem}`);
      process.exit(1);
    }
    console.log('PASS: vendored analytics files match the installed packages.');
  } else {
    await vendorAnalytics();
    for (const name of ['posthog-js', 'web-vitals']) {
      console.log(`vendored ${name}@${await packageVersion(name)}`);
    }
  }
}
