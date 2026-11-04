import { DocsLayout } from "fumadocs-ui/layouts/docs";
import type { ReactNode } from "react";
import { source } from "@/lib/source";

// The site header is ours (components/site-header.tsx), so the layout's own nav bar is off on
// desktop. Search sits at the top of the sidebar and the theme picker at its bottom, as in
// stock Fumadocs. Below md the layout's sub-header carries the button that opens the sidebar
// as a drawer; its brand is hidden in CSS because the site header already shows it.
export default function Layout({ children }: { children: ReactNode }) {
  return (
    <DocsLayout
      tree={source.getPageTree()}
      nav={{ title: <span className="subnav-label">IdleScreen docs</span> }}
      githubUrl={undefined}
    >
      {children}
    </DocsLayout>
  );
}
