// The app's languages (app/l10n.yaml), in its order: the site is in each of them. English is at the root and every
// other language under its own path.

export interface Locale {
  /** The app's name for it, as in its ARB files (app_<code>.arb) and the screenshot folders. */
  code: string;
  /** BCP 47, for lang and hreflang. */
  tag: string;
  /** The first path segment of its page; empty for English, at the root. */
  path: string;
}

const locale = (code: string, tag = code): Locale => ({
  code,
  tag,
  path: code === "en" ? "" : tag.toLowerCase(),
});

export const LOCALES: readonly Locale[] = [
  locale("en"),
  locale("fr"),
  locale("de"),
  locale("es"),
  locale("pt"),
  locale("it"),
  locale("nl"),
  locale("da"),
  locale("sv"),
  locale("fi"),
  locale("pl"),
  locale("cs"),
  locale("hu"),
  locale("tr"),
  locale("el"),
  locale("ru"),
  locale("th"),
  locale("ko"),
  locale("zh", "zh-Hans"),
  locale("zh_Hant", "zh-Hant"),
  locale("ja"),
];

/** The URL of [locale]'s page, from the site's root. */
export const pagePath = (locale: Locale): string => (locale.path === "" ? "/" : `/${locale.path}/`);
