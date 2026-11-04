import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { cspForHTML, htmlFiles, injectCspMeta, inlineScriptHashes } from "./csp-meta.mjs";

const hash = (body) => `'sha256-${crypto.createHash("sha256").update(body).digest("base64")}'`;

test("hashes inline scripts and skips external ones", () => {
  const html = '<head><script src="/a.js"></script><script>self.x=1</script><SCRIPT >self.y=2</SCRIPT ></head>';
  assert.deepEqual(inlineScriptHashes(html), [hash("self.x=1"), hash("self.y=2")].sort());
});

test("the policy has no unsafe-inline for scripts and no frame-ancestors (a meta ignores it)", () => {
  const csp = cspForHTML("<head><script>1</script></head>");
  const scriptSrc = csp.split("; ").find((part) => part.startsWith("script-src"));
  assert.doesNotMatch(scriptSrc, /unsafe-/);
  assert.doesNotMatch(csp, /frame-ancestors/);
});

test("injection is first in <head> and replaces an earlier meta", () => {
  const once = injectCspMeta("<html><head><title>t</title><script>a</script></head></html>");
  const twice = injectCspMeta(once);
  assert.equal(twice, once);
  assert.match(once, /<head><meta http-equiv="Content-Security-Policy"/);
});

test("a page with no head is an error, not a silently unprotected page", () => {
  assert.throws(() => injectCspMeta("<p>x</p>"), /no <head>/);
});

// Needs out/ from `npm run build`: every exported page carries a meta that covers its own scripts.
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "out");
test("every exported page has a CSP meta covering its inline scripts", { skip: !fs.existsSync(out) && !process.env.REQUIRE_OUT }, () => {
  const files = htmlFiles(out);
  assert.ok(files.length > 10);
  for (const file of files) {
    const html = fs.readFileSync(file, "utf8");
    const meta = /<meta http-equiv="Content-Security-Policy" content="([^"]+)"/.exec(html);
    assert.ok(meta, `${file} has no CSP meta`);
    for (const digest of inlineScriptHashes(html)) assert.ok(meta[1].includes(digest), `${file} misses ${digest}`);
  }
});
