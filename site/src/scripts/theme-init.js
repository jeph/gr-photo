// Inlined at the top of every page by Base.astro, so a picked theme applies before the page paints instead of
// flashing Auto's first. The theme menu (scripts/menus.ts) changes it through window.grTheme.
//
// The themes are the app's (AppTheme in app/lib/src/theme/tokens.dart). Auto, the default, leaves data-palette
// unset so the CSS follows the browser between Light and Dark, as the app follows the phone.
window.grTheme = (() => {
  const key = "gr-photo-theme";
  /** Each theme's colour scheme and page colour, which also tints the browser's address bar. */
  const themes = {
    light: { scheme: "light", page: "#ffffff" },
    dark: { scheme: "dark", page: "#0a0a0b" },
    darkroom: { scheme: "dark", page: "#0e0908" },
    paper: { scheme: "light", page: "#f7f2e8" },
    cyanotype: { scheme: "dark", page: "#071626" },
  };
  const root = document.documentElement;

  const stored = () => {
    try {
      const theme = localStorage.getItem(key);
      return theme !== null && Object.hasOwn(themes, theme) ? theme : "auto";
    } catch {
      return "auto";
    }
  };

  const apply = (choice) => {
    if (choice === "auto") delete root.dataset.palette;
    else root.dataset.palette = choice;
    for (const meta of document.querySelectorAll('meta[name="theme-color"]')) {
      const resolved = choice === "auto" ? (meta.media.includes("dark") ? "dark" : "light") : choice;
      meta.content = themes[resolved].page;
    }
  };

  root.classList.add("js");
  apply(stored());

  return {
    stored,
    choose(choice) {
      apply(choice);
      try {
        if (choice === "auto") localStorage.removeItem(key);
        else localStorage.setItem(key, choice);
      } catch {
        // Storage is blocked; the choice lasts until the page is left.
      }
    },
  };
})();
