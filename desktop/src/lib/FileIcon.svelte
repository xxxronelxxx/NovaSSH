<script lang="ts">
  import {
    Archive,
    Database,
    File,
    FileCode,
    FileCog,
    FileImage,
    FileJson,
    FileSpreadsheet,
    FileText,
    FileType,
    Folder,
    Music,
    MoveUpRight,
    SquareTerminal,
    Video,
  } from "lucide-svelte";
  import type { Entry } from "./api";
  import { prefs } from "./theme.svelte";

  let { entry, size = 15 }: { entry: Entry; size?: number } = $props();

  const archives = new Set(["zip","tar","gz","tgz","tbz2","tbz","txz","tzst","bz2","xz","zst","7z","rar","deb","rpm","iso","cab","jar","war","apk","ipa","dmg"]);
  const images = new Set(["png","jpg","jpeg","gif","bmp","webp","svg","ico","tif","tiff","avif","heic","psd"]);
  const video = new Set(["mp4","mkv","avi","mov","wmv","flv","webm","m4v","mpg","mpeg","ogv"]);
  const audio = new Set(["mp3","ogg","wav","flac","aac","m4a","opus","wma","mid","midi"]);
  const code = new Set(["php","js","mjs","cjs","ts","tsx","jsx","html","htm","css","scss","sass","less","dart","rs","go","py","rb","java","kt","kts","c","h","cpp","cc","hpp","cs","swift","vue","svelte","xml","yml","yaml","toml","sql","graphql","proto","lua","pl","r","scala"]);
  const scripts = new Set(["sh","bash","zsh","fish","bat","cmd","ps1","psm1","vbs"]);
  const config = new Set(["ini","conf","cfg","env","properties","htaccess","gitignore","dockerignore","editorconfig","npmrc","cnf","service"]);
  const text = new Set(["txt","md","markdown","rst","log","rtf","doc","docx","odt","tex"]);
  const database = new Set(["db","sqlite","sqlite3","mdb","accdb","dbf"]);
  const sheets = new Set(["xls","xlsx","ods","csv","tsv"]);
  const fonts = new Set(["ttf","otf","woff","woff2","eot"]);
  const json = new Set(["json"]);

  const COLOR = {
    folder: "#f0c04a",
    archive: "#c08cff",
    image: "#5fd68a",
    video: "#f07a9b",
    audio: "#e0a4f5",
    code: "#6cb6ff",
    script: "#8be28b",
    text: "#b9c2cf",
    config: "#d7b36a",
    database: "#63c7c9",
    sheet: "#7fcf9b",
    font: "#9bb7e8",
    binary: "#a8b0bd",
  };

  const ext = $derived(entry.name.toLowerCase().split(".").pop() ?? "");
  const link = $derived(
    entry.kind === "symlink" || entry.linkTarget != null,
  );
  const colored = $derived(prefs.fileIcons === "colored");

  type Category =
    | "archive" | "image" | "video" | "audio" | "code" | "script"
    | "text" | "config" | "database" | "sheet" | "font" | "json" | "binary";

  const category = $derived.by((): Category => {
    if (archives.has(ext)) return "archive";
    if (images.has(ext)) return "image";
    if (video.has(ext)) return "video";
    if (audio.has(ext)) return "audio";
    if (scripts.has(ext)) return "script";
    if (code.has(ext)) return "code";
    if (json.has(ext)) return "json";
    if (database.has(ext)) return "database";
    if (sheets.has(ext)) return "sheet";
    if (fonts.has(ext)) return "font";
    if (text.has(ext)) return "text";
    if (config.has(ext)) return "config";
    if (entry.mode != null && (entry.mode & 0o111) !== 0) return "script";
    return "binary";
  });

  const color = $derived.by(() => {
    if (!colored) {
      if (entry.kind === "dir") return "var(--dir)";
      if (link) return "var(--symlink)";
      if (category === "archive") return "var(--archive)";
      if (category === "script") return "var(--exec)";
      return "var(--faint)";
    }
    return COLOR[category];
  });
</script>

{#if entry.kind === "dir"}
  <span class="ico" style:color={colored ? COLOR.folder : "var(--dir)"}>
    {#if prefs.folderIcons === "outline"}
      <Folder size={size} strokeWidth={1.8} />
    {:else}
      <svg
        width={size}
        height={size}
        viewBox="0 0 24 24"
        fill="currentColor"
        aria-hidden="true"
      >
        <path
          d="M3 6.5A2.5 2.5 0 0 1 5.5 4h3.2l2 2.2h7.8A2.5 2.5 0 0 1 21 8.7v8.8a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z"
        />
      </svg>
    {/if}
    {#if link}
      <MoveUpRight class="badge" size={7} strokeWidth={2.8} />
    {/if}
  </span>
{:else}
  {@const Icon = category === "archive"
    ? Archive
    : category === "image"
      ? FileImage
      : category === "video"
        ? Video
        : category === "audio"
          ? Music
          : category === "code"
            ? FileCode
            : category === "script"
              ? SquareTerminal
              : category === "config"
                ? FileCog
                : category === "database"
                  ? Database
                  : category === "sheet"
                    ? FileSpreadsheet
                    : category === "font"
                      ? FileType
                      : category === "json"
                        ? FileJson
                        : category === "text"
                          ? FileText
                          : File}
  <span class="ico" style:color={color}>
    <Icon size={size} strokeWidth={1.8} />
    {#if link}
      <MoveUpRight class="badge" size={7} strokeWidth={2.8} />
    {/if}
  </span>
{/if}

<style>
  .ico {
    position: relative;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    flex: 0 0 18px;
  }

  .badge {
    position: absolute;
    right: -1px;
    bottom: -1px;
    padding: 0.5px;
    border-radius: 50%;
    background: var(--panel);
    box-sizing: content-box;
  }
</style>
