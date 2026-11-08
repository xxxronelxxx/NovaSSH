import type { Appearance } from "./api";

/// Visual preferences shared by every component. Icons read `fileIcons` and
/// `folderIcons`; the palette lives in CSS variables on <html>.
export const prefs = $state({
  mode: "dark" as "dark" | "light" | "system",
  fileIcons: "colored",
  folderIcons: "filled",
});

const media =
  typeof window !== "undefined"
    ? window.matchMedia("(prefers-color-scheme: dark)")
    : null;

export function applyTheme() {
  if (typeof document === "undefined") return;
  const dark =
    prefs.mode === "dark" || (prefs.mode === "system" && !!media?.matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
}

if (media) {
  media.addEventListener("change", () => {
    if (prefs.mode === "system") applyTheme();
  });
}

export function setTheme(mode: "dark" | "light" | "system") {
  prefs.mode = mode;
  applyTheme();
}

export function toggleTheme() {
  setTheme(document.documentElement.dataset.theme === "dark" ? "light" : "dark");
}

/// Applies Settings.appearance: fonts, row size, panel colours and icon style.
export function applyAppearance(appearance: Appearance | null | undefined) {
  if (!appearance || typeof document === "undefined") return;
  const root = document.documentElement;

  prefs.fileIcons = appearance.fileIcons === "mono" ? "mono" : "colored";
  prefs.folderIcons = appearance.folderIcons === "outline" ? "outline" : "filled";

  const ui = appearance.uiFont?.trim();
  const mono = appearance.monoFont?.trim();
  root.style.setProperty(
    "--ui",
    ui ? `"${ui}", var(--ui-system)` : "var(--ui-system)",
  );
  root.style.setProperty(
    "--mono",
    mono ? `"${mono}", var(--mono-system)` : "var(--mono-system)",
  );

  const size = Math.min(16, Math.max(10, appearance.panelFontSize || 12));
  root.style.setProperty("--row-font", `${size}px`);
  root.style.setProperty(
    "--row-height",
    `${Math.min(33, Math.max(26, size + 14))}px`,
  );

  if (appearance.panelText?.trim()) {
    root.style.setProperty("--text", appearance.panelText);
  } else {
    root.style.removeProperty("--text");
  }
  if (appearance.panelBackground?.trim()) {
    root.style.setProperty("--panel", appearance.panelBackground);
  } else {
    root.style.removeProperty("--panel");
  }
}
