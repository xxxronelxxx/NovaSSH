import type { Entry } from "./api";

const archives = ["zip","tar","gz","tgz","tbz2","tbz","txz","tzst","bz2","xz","zst","7z","rar","deb","rpm","iso","cab"];
const images = ["png","jpg","jpeg","gif","bmp","webp","svg","ico","tif","tiff","avif","heic"];
const scripts = ["sh","bash","zsh","fish","bat","cmd","ps1","vbs"];
const code = ["php","js","mjs","ts","tsx","jsx","json","html","htm","css","scss","less","dart","rs","go","py","rb","java","kt","c","h","cpp","hpp","cs","swift","vue","svelte","xml","yml","yaml","toml","sql","lua","pl","r"];
const text = ["txt","md","markdown","log","rtf","doc","docx","odt","pdf"];
const config = ["ini","conf","cfg","env","properties","htaccess","gitignore","editorconfig"];
const media = ["mp3","ogg","wav","flac","aac","m4a","opus","mp4","mkv","avi","mov","wmv","flv","webm"];

export function iconFor(entry: Entry): string {
  if (entry.kind === "dir") return "📁";
  if (entry.kind === "symlink") return "🔗";
  const ext = entry.name.toLowerCase().split(".").pop() ?? "";
  if (archives.includes(ext)) return "🗜";
  if (images.includes(ext)) return "🖼";
  if (scripts.includes(ext)) return "⌨";
  if (code.includes(ext)) return "‹›";
  if (text.includes(ext)) return "📄";
  if (config.includes(ext)) return "⚙";
  if (media.includes(ext)) return "♪";
  return "📄";
}

export function iconColor(entry: Entry): string {
  if (entry.kind === "dir") return "var(--dir)";
  if (entry.kind === "symlink") return "var(--archive)";
  const ext = entry.name.toLowerCase().split(".").pop() ?? "";
  if (archives.includes(ext)) return "var(--archive)";
  if (images.includes(ext)) return "#5fd68a";
  if (scripts.includes(ext)) return "#8be28b";
  if (code.includes(ext)) return "#6cb6ff";
  if (config.includes(ext)) return "#d7b36a";
  if (media.includes(ext)) return "#e0a4f5";
  return "var(--dim)";
}
