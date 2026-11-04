// Copies the finished static export (out/) into website/dist/docs/, which is where the site
// serves it from. website/dist/docs is generated and gitignored.

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const SCRIPT_FILE = fileURLToPath(import.meta.url);
const PROJECT_DIR = path.resolve(path.dirname(SCRIPT_FILE), "..");
const OUT_DIR = path.join(PROJECT_DIR, "out");
const TARGET_DIR = path.resolve(PROJECT_DIR, "..", "website", "dist", "docs");

function main() {
  if (!fs.existsSync(path.join(OUT_DIR, "index.html"))) {
    throw new Error(`static output not found: ${OUT_DIR}; run npm run build first`);
  }
  fs.rmSync(TARGET_DIR, { recursive: true, force: true });
  fs.mkdirSync(TARGET_DIR, { recursive: true });
  fs.cpSync(OUT_DIR, TARGET_DIR, { recursive: true });
  console.log(`Copied ${path.relative(PROJECT_DIR, OUT_DIR)} to ${path.relative(PROJECT_DIR, TARGET_DIR)}`);
}

main();
