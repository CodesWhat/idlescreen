// Copies the analytics vendor files into dist/assets/vendor/ so the site can load
// them same-origin under its script-src 'self' CSP. Run after bumping posthog-js
// or web-vitals in package.json: `npm run vendor:analytics`.
//
// posthog-js: the slim no-external ES module. Slim leaves out session replay,
// surveys and the other extensions; no-external guarantees it never loads a
// remote script. It has no bundled web vitals, so web-vitals is vendored separately.
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root = new URL('../', import.meta.url);
const out = new URL('dist/assets/vendor/', root);
const modules = new URL('node_modules/', root);
await mkdir(out, { recursive: true });

// Source map comments would 404 in production, and the maps aren't shipped.
async function copyJs(from, to) {
  const source = await readFile(new URL(from, modules), 'utf8');
  await writeFile(new URL(to, out), source.replace(/\n\/\/# sourceMappingURL=.*\n?$/u, '\n'));
}

await copyJs('posthog-js/dist/module.slim.no-external.js', 'posthog-js.slim.no-external.js');
await copyJs('web-vitals/dist/web-vitals.js', 'web-vitals.js');
await copyFile(new URL('posthog-js/LICENSE', modules), new URL('posthog-js.LICENSE', out));
await copyFile(new URL('web-vitals/LICENSE', modules), new URL('web-vitals.LICENSE', out));

for (const name of ['posthog-js', 'web-vitals']) {
  const { version } = JSON.parse(await readFile(new URL(`${name}/package.json`, modules), 'utf8'));
  console.log(`vendored ${name}@${version}`);
}
