import defaultMdxComponents from "fumadocs-ui/mdx";
import { DocsBody, DocsDescription, DocsPage, DocsTitle, EditOnGitHub } from "fumadocs-ui/page";
import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { BASE_URL, GITHUB_URL, SITE_CONFIG } from "@/lib/site-config";
import { getDocsPage, source } from "@/lib/source";

function canonicalFor(slugs: string[]): string {
  const path = slugs.length === 0 ? "" : `/${slugs.join("/")}`;
  return new URL(`${SITE_CONFIG.basePath}${path}`, BASE_URL).toString();
}

export default async function Page(props: { params: Promise<{ slug?: string[] }> }) {
  const params = await props.params;
  const page = getDocsPage(params.slug);
  if (!page) notFound();

  const MDX = page.data.body;

  return (
    <DocsPage toc={page.data.toc} full={page.data.full} breadcrumb={{ enabled: true }}>
      <DocsTitle>{page.data.title}</DocsTitle>
      <DocsDescription>{page.data.description}</DocsDescription>
      <DocsBody>
        <MDX components={defaultMdxComponents} />
      </DocsBody>
      <EditOnGitHub
        href={`${GITHUB_URL}/edit/main/docs-site/content/docs/${page.path}`}
        target="_blank"
        rel="noopener noreferrer"
      />
    </DocsPage>
  );
}

export function generateStaticParams() {
  return source.generateParams();
}

export async function generateMetadata(props: {
  params: Promise<{ slug?: string[] }>;
}): Promise<Metadata> {
  const params = await props.params;
  const page = getDocsPage(params.slug);
  if (!page) notFound();

  // The landing page's own title is "Introduction", which says nothing in a tab or a result.
  const title =
    page.slugs.length === 0 ? { absolute: `${SITE_CONFIG.name} docs` } : page.data.title;

  return {
    title,
    description: page.data.description,
    alternates: { canonical: canonicalFor(page.slugs) },
  };
}
