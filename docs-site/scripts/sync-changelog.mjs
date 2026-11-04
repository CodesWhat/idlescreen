// Renders ../CHANGELOG.md as content/docs/changelog.mdx so the docs never hand-copy release
// notes. `npm run build` runs it first; scripts/changelog.test.mjs fails if the committed file
// has drifted from the changelog.

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const SCRIPT_FILE = fileURLToPath(import.meta.url);
const PROJECT_DIR = path.resolve(path.dirname(SCRIPT_FILE), "..");
const SOURCE = path.resolve(PROJECT_DIR, "..", "CHANGELOG.md");
const TARGET = path.join(PROJECT_DIR, "content", "docs", "changelog.mdx");

/** Escapes what MDX would read as JSX or an expression, leaving code spans and fences alone. */
function escapeMdx(markdown) {
  let inFence = false;
  return markdown
    .split("\n")
    .map((line) => {
      if (/^\s*```/.test(line)) {
        inFence = !inFence;
        return line;
      }
      if (inFence) return line;
      return line
        .split(/(`[^`]*`)/)
        .map((part, index) =>
          index % 2 === 1 ? part : part.replace(/</g, "&lt;").replace(/\{/g, "&#123;"),
        )
        .join("");
    })
    .join("\n");
}

export function renderChangelog(markdown) {
  const body = markdown
    .replace(/^# Changelog\s*\n/, "")
    // A `## [0.2.0]` heading is a reference link, which Fumadocs nests inside its own heading
    // anchor (an <a> in an <a>, a hydration error). The reference definitions stay unused.
    .replace(/^(##) \[([^\]]+)\]/gm, "$1 $2")
    .trim();
  return [
    "---",
    "title: Changelog",
    "description: Release notes for every IdleScreen version.",
    "---",
    "",
    escapeMdx(body),
    "",
  ].join("\n");
}

export const paths = { SOURCE, TARGET };

function main() {
  fs.writeFileSync(TARGET, renderChangelog(fs.readFileSync(SOURCE, "utf8")));
  console.log(`Wrote ${path.relative(PROJECT_DIR, TARGET)}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === SCRIPT_FILE) {
  main();
}
