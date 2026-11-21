// The text of each language's page: the site's own messages (messages/<code>.json) and, for what the app already
// names, the app's (app/lib/l10n/app_<code>.arb), so a theme or a setting reads the same on the site as in the app.
// The build fails when a language lacks a message or has one English doesn't, as tool/check_translations.dart does
// for the app.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type en from "./messages/en.json";
import type { Locale } from "./locales.ts";
import { THEMES, type Theme } from "../themes.ts";

export type SiteMessages = typeof en;

export interface Messages extends SiteMessages {
  /** The language's own name for itself. */
  languageName: string;
  language: string;
  theme: string;
  themeNames: Record<Theme, string>;
  privacyPolicy: string;
  licenses: string;
}

const siteMessages = import.meta.glob<SiteMessages>("./messages/*.json", { eager: true, import: "default" });

function siteMessagesFor(code: string): SiteMessages {
  const english = siteMessages["./messages/en.json"];
  const messages = siteMessages[`./messages/${code}.json`];
  if (english === undefined || messages === undefined) throw new Error(`No site messages for ${code}`);
  if (Object.keys(messages).sort().join() !== Object.keys(english).sort().join()) {
    throw new Error(`messages/${code}.json does not have the same messages as messages/en.json`);
  }
  return messages;
}

/** The cases of an ICU select message, such as settingsThemeName. */
function selectCases(message: string): Record<string, string> {
  return Object.fromEntries([...message.matchAll(/(\w+)\{([^{}]*)\}/g)].map(([, name, text]) => [name, text]));
}

export function messagesFor(locale: Locale): Messages {
  // Astro builds from site/, so the app is next to it.
  const app = JSON.parse(readFileSync(resolve(`../app/lib/l10n/app_${locale.code}.arb`), "utf8")) as Record<
    string,
    string
  >;
  const get = (key: string) => {
    const message = app[key];
    if (message === undefined) throw new Error(`app_${locale.code}.arb has no ${key}`);
    return message;
  };
  // `other` is the app's System, the site's Auto.
  const themeCases = selectCases(get("settingsThemeName"));
  const themeNames = Object.fromEntries(
    THEMES.map((theme) => {
      const name = themeCases[theme === "auto" ? "other" : theme];
      if (name === undefined) throw new Error(`app_${locale.code}.arb's settingsThemeName has no ${theme}`);
      return [theme, name];
    }),
  ) as Record<Theme, string>;
  return {
    ...siteMessagesFor(locale.code),
    languageName: get("settingsLanguageName"),
    language: get("settingsLanguage"),
    theme: get("settingsTheme"),
    themeNames,
    privacyPolicy: get("privacyPolicyRow"),
    licenses: get("privacyLicensesRow"),
  };
}
