import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { paths, renderChangelog } from "./sync-changelog.mjs";

test("the committed changelog page matches ../CHANGELOG.md", () => {
  const expected = renderChangelog(fs.readFileSync(paths.SOURCE, "utf8"));
  assert.equal(
    fs.readFileSync(paths.TARGET, "utf8"),
    expected,
    "content/docs/changelog.mdx is stale; run: node scripts/sync-changelog.mjs",
  );
});

test("release headings are plain text, not links nested in the heading anchor", () => {
  const page = renderChangelog("# Changelog\n\n## [0.2.0] - 2026-01-01\n\n## [Unreleased]\n");
  assert.match(page, /^## 0\.2\.0 - 2026-01-01$/m);
  assert.match(page, /^## Unreleased$/m);
});

test("JSX and expression characters outside code are escaped, code is left alone", () => {
  const page = renderChangelog("# Changelog\n\nUse <name> and {x} with `<code> {kept}`.\n\n```sh\necho <a> {b}\n```\n");
  assert.match(page, /Use &lt;name> and &#123;x} with `<code> \{kept\}`\./);
  assert.match(page, /echo <a> \{b\}/);
});
