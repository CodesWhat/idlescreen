// Postbuild for the static export. Hashes every inline script on each page and injects a
// per-page <meta http-equiv="Content-Security-Policy"> into out/**/*.html, so script-src needs
// no 'unsafe-inline' and website/vercel.json stays static (no page-dependent hashes to commit).
//
// Browsers enforce the intersection of the header and meta policies. The header for /docs in
// website/vercel.json therefore leaves out default-src and script-src: any script-src there
// would have to allow the same hashed inline scripts, which it can't know. The meta carries
// those two plus a copy of the rest. frame-ancestors is ignored in a meta element, so it lives
// in the header.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const SCRIPT_FILE = fileURLToPath(import.meta.url);
const PROJECT_DIR = path.resolve(path.dirname(SCRIPT_FILE), "..");

const META_PATTERN = /<meta\s+http-equiv=["']?Content-Security-Policy["']?[^>]*>/gi;

export function inlineScriptHashes(html) {
  const hashes = new Set();
  // The end tag mirrors the start tag and matching is case-insensitive, because that is what an
  // HTML parser accepts. A form this misses gets no hash and the CSP blocks a script the page
  // needs: silent at build time, fatal in the browser.
  for (const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script(?:\s[^>]*)?>/gi)) {
    if (/\ssrc=/i.test(match[0].slice(0, match[0].indexOf(">")))) continue;
    const digest = crypto.createHash("sha256").update(match[1]).digest("base64");
    hashes.add(`'sha256-${digest}'`);
  }
  return [...hashes].sort();
}

/** Meta policy for one page. No frame-ancestors: browsers ignore it in a meta element. */
export function cspForHTML(html) {
  return [
    "default-src 'self'",
    `script-src 'self' ${inlineScriptHashes(html).join(" ")}`.trim(),
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'none'",
  ].join("; ");
}

/** Strips any existing CSP meta, then inserts a fresh one as the first child of <head>. */
export function injectCspMeta(html) {
  const clean = html.replace(META_PATTERN, "");
  const head = /<head(?:\s[^>]*)?>/i.exec(clean);
  if (!head) throw new Error("page has no <head>; cannot place the CSP meta before scripts");
  const meta = `<meta http-equiv="Content-Security-Policy" content="${cspForHTML(clean)}"/>`;
  const at = head.index + head[0].length;
  return clean.slice(0, at) + meta + clean.slice(at);
}

export function htmlFiles(root) {
  const files = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const target = path.join(root, entry.name);
    if (entry.isDirectory()) files.push(...htmlFiles(target));
    else if (target.endsWith(".html")) files.push(target);
  }
  return files.sort();
}

function main() {
  const outputDir = path.join(PROJECT_DIR, "out");
  if (!fs.existsSync(outputDir)) {
    throw new Error(`static output not found: ${outputDir}; run next build first`);
  }
  const files = htmlFiles(outputDir);
  for (const file of files) {
    fs.writeFileSync(file, injectCspMeta(fs.readFileSync(file, "utf8")));
  }
  console.log(`Injected CSP meta into ${files.length} HTML files`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === SCRIPT_FILE) {
  main();
}
