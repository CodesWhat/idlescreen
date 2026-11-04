import { GITHUB_URL, SITE_CONFIG } from "@/lib/site-config";

// The docs app runs under basePath="/docs". Next <Link> would prefix every href with /docs and
// send the logo to the wrong place, and next/image would do the same to the logo's src. Plain
// anchors and <img> resolve at the origin root, so they are used here on purpose.
export function SiteHeader() {
  return (
    <header className="top" id="top">
      <div className="wrap">
        <a className="brand" href="/" aria-label={`${SITE_CONFIG.name} home`}>
          {/* biome-ignore lint/performance/noImgElement: basePath makes next/image prepend /docs to root-relative src. */}
          <img src="/assets/logo.png" alt="" width={32} height={32} />
          <span>{SITE_CONFIG.name}</span>
        </a>
        <nav className="nav" aria-label="Main">
          <a href="/docs" aria-current="page">
            Docs
          </a>
          <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer">
            GitHub<span aria-hidden="true"> ↗</span>
          </a>
        </nav>
      </div>
    </header>
  );
}
