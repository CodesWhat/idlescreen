import {
  CODESWHAT_URL,
  GITHUB_LICENSE_URL,
  GITHUB_RELEASES_URL,
  GITHUB_URL,
  SITE_CONFIG,
} from "@/lib/site-config";

const YEAR = process.env.NEXT_PUBLIC_COPYRIGHT_YEAR;

// Plain anchors: the docs app runs under basePath="/docs", so these must resolve at the origin root.
export function Footer() {
  return (
    <footer id="footer">
      <div className="wrap fgrid">
        <div>
          <a className="brand" href="/">
            {/* biome-ignore lint/performance/noImgElement: basePath makes next/image prepend /docs to root-relative src. */}
            <img src="/assets/logo.png" alt="" width={28} height={28} loading="lazy" />
            <span>{SITE_CONFIG.name}</span>
          </a>
          <p className="fnote">
            <a href={CODESWHAT_URL}>CodesWhat</a>: small, sharp tools from one developer and a lot
            of agents.
          </p>
          <p className="fnote">
            Free software under the <a href={GITHUB_LICENSE_URL}>MIT License</a>. © {YEAR}{" "}
            CodesWhat.
          </p>
        </div>
        <nav aria-label="Project links">
          <p className="fh">Project</p>
          <ul>
            <li>
              <a href="/docs">Documentation</a>
            </li>
            <li>
              <a href={GITHUB_URL}>GitHub</a>
            </li>
            <li>
              <a href={GITHUB_RELEASES_URL}>Releases</a>
            </li>
            <li>
              <a href="/">idlescreen.codeswhat.com</a>
            </li>
          </ul>
        </nav>
      </div>
    </footer>
  );
}
