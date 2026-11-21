import sitemap from "@astrojs/sitemap";
import { defineConfig } from "astro/config";
import { LOCALES } from "./src/i18n/locales.ts";

// Canonical URLs, the sitemap and hreflang links need an absolute origin. SITE_URL wins when set; on Vercel the
// project's production domain is the fallback.
const productionHost = process.env.VERCEL_PROJECT_PRODUCTION_URL;
const site = process.env.SITE_URL ?? (productionHost ? `https://${productionHost}` : "http://localhost:4321");

export default defineConfig({
  site,
  trailingSlash: "always",
  integrations: [
    sitemap({
      i18n: {
        defaultLocale: "en",
        locales: Object.fromEntries(LOCALES.map((locale) => [locale.path || "en", locale.tag])),
      },
    }),
  ],
});
