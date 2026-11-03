import type { MetadataRoute } from "next";
import { BASE_URL, SITE_CONFIG } from "@/lib/site-config";
import { source } from "@/lib/source";

export const dynamic = "force-static";

export default function sitemap(): MetadataRoute.Sitemap {
  return source.getPages().map((page) => ({
    url: new URL(
      `${SITE_CONFIG.basePath}${page.url === "/" ? "" : page.url}`,
      BASE_URL,
    ).toString(),
  }));
}
