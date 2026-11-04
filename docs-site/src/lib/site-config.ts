const githubOwner = "CodesWhat";
const githubRepo = "idlescreen";

export const SITE_CONFIG = {
  /** Product name in prose. Lowercase `idlescreen` stays only where it is a literal identifier. */
  name: "IdleScreen",
  description:
    "Documentation for IdleScreen, a signed and notarized macOS Tahoe screen saver that turns procedural scenes or a live camera into a Metal-rendered field of animated characters.",
  /** Production domain (no protocol, no trailing slash). */
  domain: "idlescreen.codeswhat.com",
  githubOwner,
  githubRepo,
  /** Where /docs is mounted on the site. Must match basePath in next.config.ts. */
  basePath: "/docs",
} as const;

const REPO_SLUG = `${SITE_CONFIG.githubOwner}/${SITE_CONFIG.githubRepo}`;
export const GITHUB_URL = `https://github.com/${REPO_SLUG}`;
export const GITHUB_RELEASES_URL = `${GITHUB_URL}/releases`;
export const GITHUB_LICENSE_URL = `${GITHUB_URL}/blob/main/LICENSE`;
export const GITHUB_ORG_URL = `https://github.com/${SITE_CONFIG.githubOwner}`;
export const CODESWHAT_URL = "https://codeswhat.com";

export const BASE_URL = `https://${SITE_CONFIG.domain}`;
