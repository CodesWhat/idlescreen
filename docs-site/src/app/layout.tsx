import { RootProvider } from "fumadocs-ui/provider/next";
import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";
import type { ReactNode } from "react";
import { Footer } from "@/components/footer";
import { SiteHeader } from "@/components/site-header";
import { BASE_URL, SITE_CONFIG } from "@/lib/site-config";
import "./globals.css";

// Same OFL files as the marketing site (website/dist/assets/fonts). next/font emits the URLs
// itself, so they pick up the /docs basePath.
const departureMono = localFont({
  src: "../fonts/DepartureMono-Regular.woff2",
  weight: "400",
  variable: "--font-departure-mono",
  display: "swap",
});
const inter = localFont({
  src: [
    { path: "../fonts/Inter-Regular.woff2", weight: "400", style: "normal" },
    { path: "../fonts/Inter-Medium.woff2", weight: "500", style: "normal" },
    { path: "../fonts/Inter-SemiBold.woff2", weight: "600", style: "normal" },
  ],
  variable: "--font-inter",
  display: "swap",
});

const SHARE_IMAGE = {
  url: new URL("/assets/social-card.png", BASE_URL).toString(),
  width: 1200,
  height: 630,
  alt: `${SITE_CONFIG.name} docs`,
};

export const metadata: Metadata = {
  title: {
    default: `${SITE_CONFIG.name} docs`,
    template: `%s | ${SITE_CONFIG.name} docs`,
  },
  description: SITE_CONFIG.description,
  metadataBase: new URL(BASE_URL),
  openGraph: {
    siteName: `${SITE_CONFIG.name} docs`,
    type: "website",
    images: [SHARE_IMAGE],
  },
  twitter: {
    card: "summary_large_image",
    images: [SHARE_IMAGE.url],
  },
  icons: { icon: [{ url: `${SITE_CONFIG.basePath}/logo.png`, type: "image/png" }] },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#0e1117" },
  ],
};

export default function RootLayout({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html
      lang="en"
      className={`${departureMono.variable} ${inter.variable}`}
      suppressHydrationWarning
    >
      <body>
        <a className="skip" href="#main-content">
          Skip to content
        </a>
        {/*
         * RootProvider carries next-themes (class attribute, follows the system scheme until the
         * visitor picks one) and the search dialog. The index is a static file built by
         * api/search/route.ts, so the client is the static one and needs the basePath.
         */}
        <RootProvider
          search={{ options: { type: "static", api: `${SITE_CONFIG.basePath}/api/search` } }}
        >
          <SiteHeader />
          <main id="main-content">{children}</main>
          <Footer />
        </RootProvider>
      </body>
    </html>
  );
}
