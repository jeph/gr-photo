// Connects the theme and language menus (components/IconSelect.astro). The theme goes through window.grTheme, which
// scripts/theme-init.js defines inline so the theme applies before the page paints.

import { THEMES, type Theme } from "../themes.ts";

declare global {
  interface Window {
    grTheme: {
      /** The saved choice; auto when there is none. */
      stored(): Theme;
      /** Applies [theme] and saves it. */
      choose(theme: Theme): void;
    };
  }
}

for (const select of document.querySelectorAll<HTMLSelectElement>('[data-kind="theme"] select')) {
  select.value = window.grTheme.stored();
  select.addEventListener("change", () => {
    window.grTheme.choose(THEMES.find((theme) => theme === select.value) ?? "auto");
  });
}

for (const select of document.querySelectorAll<HTMLSelectElement>('[data-kind="language"] select')) {
  // Back from another language's page, the browser may restore the select as it was left.
  addEventListener("pageshow", () => {
    select.value = select.querySelector<HTMLOptionElement>("option[selected]")?.value ?? select.value;
  });
  select.addEventListener("change", () => {
    try {
      // Remembered so the English page, at the root, no longer follows the browser's language.
      localStorage.setItem("gr-photo-language", select.value);
    } catch {
      // Storage is blocked; the page still changes.
    }
    location.href = select.value;
  });
}
