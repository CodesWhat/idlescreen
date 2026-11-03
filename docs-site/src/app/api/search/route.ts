import { createFromSource } from "fumadocs-core/search/server";
import { source } from "@/lib/source";

// Static export: the search index is built once at build time and served as a file.
// RootProvider (layout.tsx) loads it with the static client.
export const revalidate = false;
export const dynamic = "force-static";

export const { staticGET: GET } = createFromSource(source);
