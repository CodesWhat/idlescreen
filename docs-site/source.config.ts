import { defineConfig, defineDocs } from "fumadocs-mdx/config";

export const docs = defineDocs({
  dir: "content/docs",
});

export default defineConfig({
  mdxOptions: {
    // Code blocks take the dark code surface in both modes (see globals.css).
    rehypeCodeOptions: { themes: { light: "github-dark", dark: "github-dark" } },
  },
});
