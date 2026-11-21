/** AppTheme's names, in Settings › Theme's order; auto is the app's System. */
export const THEMES = ["auto", "light", "dark", "darkroom", "paper", "cyanotype"] as const;

export type Theme = (typeof THEMES)[number];
