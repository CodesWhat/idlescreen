import { createMDX } from "fumadocs-mdx/next";

const withMDX = createMDX();

// A separate Next.js app mounted at /docs on the marketing site. `output: "export"` writes
// static HTML to out/, and scripts/assemble.mjs copies it into website/dist/docs/.
// `basePath: "/docs"` prefixes every internal link and asset URL so navigation keeps working
// once the site serves the export at idlescreen.codeswhat.com/docs.
export default withMDX({
  output: "export",
  basePath: "/docs",
  images: { unoptimized: true },
  poweredByHeader: false,
  // Keeps the exported inline bootstrap scripts deterministic, so the per-page CSP hashes
  // only change when page content does. Static assets stay content-hashed.
  generateBuildId: async () => "idlescreen-docs-static",
  // Baked once at build time. A footer that calls new Date() would run twice (build and
  // hydration) and can disagree across New Year.
  env: {
    NEXT_PUBLIC_COPYRIGHT_YEAR: String(new Date().getFullYear()),
  },
  turbopack: {
    root: import.meta.dirname,
  },
});
