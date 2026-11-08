import { Channel, invoke } from "@tauri-apps/api/core";

export type EntryKind = "dir" | "file" | "symlink" | "other";

export interface Entry {
  name: string;
  path: string;
  kind: EntryKind;
  size: number;
  modified: number | null;
  mode: number | null;
  hidden: boolean;
  linkTarget: string | null;
}

export interface DirListing {
  path: string;
  parent: string | null;
  entries: Entry[];
  freeSpace: number | null;
  totalSpace: number | null;
}

export interface Auth {
  type: string;
  keyPath?: string | null;
  passphraseRef?: string | null;
}

export interface Server {
  id: string;
  groupId: string | null;
  name: string;
  host: string;
  port: number;
  user: string;
  protocol?: string | null;
  tags: string[];
  notes?: string | null;
  color?: string | null;
  auth: Auth;
  passwordRef?: string | null;
}

export interface Group {
  id: string;
  name: string;
  parent: string | null;
  color: string | null;
  order: number;
  expanded: boolean;
  icon: string | null;
}

export interface ServerBook {
  version: number;
  groups: Group[];
  servers: Server[];
}

export interface ConnectResult {
  sessionId: string;
  startPath: string;
  home: string;
  fingerprint: string | null;
  warnings: string[];
  tools: string[];
}

export interface AppInfo {
  dataDir: string;
  keyWrap: string;
  vault: string;
  hasDeviceKey: boolean;
  version: string;
  platform: string;
}

export interface TransferEvent {
  id: string;
  name: string;
  total: number;
  done: number;
  state: string;
  message: string | null;
}

export interface Volume {
  path: string;
  name: string;
  kind: string;
  freeSpace: number | null;
  totalSpace: number | null;
}

export interface Appearance {
  fileIcons: string;
  folderIcons: string;
  uiFont: string;
  monoFont: string;
  panelFontSize: number;
  panelText: string;
  panelBackground: string;
}

export interface PanelSettings {
  showHidden: boolean;
  syncNavigation: boolean;
  comparePanels: boolean;
  tabsEnabled: boolean;
  quickFilter: boolean;
  rowDensity: string;
  layout: string;
}

export interface TransferSettings {
  concurrency: number;
  chunksPerFile: number;
  chunkKib: number;
  bandwidthLimitKibps: number;
  conflictPolicy: string;
  verifyChecksum: string;
  preserveTimes: boolean;
  resume: boolean;
}

export interface Settings {
  version: number;
  locale: string;
  keymapPreset: string;
  appearance: Appearance;
  window: { theme: string; solidMode: boolean; backdrop: string; restoreBounds: boolean };
  panels: PanelSettings;
  transfer: TransferSettings;
  editor: { external: string; fallbackBuiltin: boolean };
  terminal: {
    profiles: { id: string; name: string; command: string; args: string[]; allowPasswordArg: boolean }[];
    defaultProfile: string | null;
    androidMode: string;
    builtinXterm: boolean;
  };
  [key: string]: unknown;
}

export interface FileChecksum {
  algorithm: string;
  hash: string;
  size: number;
  computedBy: string;
}

export interface FoundFile {
  path: string;
  name: string;
  size: number;
  modified: number | null;
  isDir: boolean;
  matches: number;
}

export interface FileRef {
  sessionId: string | null;
  archivePath: string | null;
  path: string;
  label: string | null;
}

export interface Snippet {
  id: string;
  name: string;
  command: string;
  group: string;
  favorite: boolean;
  runImmediately: boolean;
  confirm: boolean;
  scope: string;
  [key: string]: unknown;
}

export interface AiSettings {
  provider: string;
  endpoint: string;
  model: string;
  [key: string]: unknown;
}

export interface ProfileImportReport {
  servers: number;
  groups: number;
  secrets: number;
  snippets: number;
  replaced: boolean;
  backupDir: string | null;
}

export interface SyncShare {
  url: string;
  ip: string;
  port: number;
  token: string;
}

export interface SyncReport {
  servers: number;
  groups: number;
  secrets: number;
  settings: boolean;
  snippets: number;
}

export const api = {
  initApp: () => invoke<AppInfo>("init_app"),
  ensureDeviceVault: () => invoke<boolean>("ensure_device_vault"),
  listServers: () => invoke<ServerBook>("list_servers"),
  loadSettings: () => invoke<Settings>("load_settings"),
  saveSettings: (settings: Settings) => invoke<void>("save_settings", { settings }),
  volumes: () => invoke<Volume[]>("volumes"),
  connectServer: (serverId: string, password: string | null) =>
    invoke<ConnectResult>("connect_server", { serverId, password }),
  cancelConnect: (serverId: string) =>
    invoke<void>("cancel_connect", { serverId }),
  connectStage: () => invoke<number>("connect_stage"),
  disconnect: (sessionId: string) =>
    invoke<void>("disconnect_session", { sessionId }),
  homeLocal: () => invoke<string>("home_local"),
  listLocal: (path: string, showHidden = true) =>
    invoke<DirListing>("list_local", { path, showHidden }),
  listRemote: (sessionId: string, path: string, showHidden = true) =>
    invoke<DirListing>("list_remote", { sessionId, path, showHidden }),
  mkdir: (sessionId: string | null, path: string) =>
    invoke<void>("mkdir", { sessionId, path }),
  rename: (sessionId: string | null, from: string, to: string) =>
    invoke<void>("rename", { sessionId, from, to }),
  remove: (sessionId: string | null, path: string, isDir: boolean) =>
    invoke<void>("remove", { sessionId, path, isDir }),
  copyLocal: (sources: string[], targetDir: string) =>
    invoke<number>("copy_local", { sources, targetDir }),
  transferFile: (
    sessionId: string,
    direction: "upload" | "download",
    sourcePath: string,
    targetDir: string,
    resumeFrom: number,
    limitKibps: number,
    verify: boolean,
    targetName: string | null,
    onEvent: Channel<TransferEvent>,
  ) =>
    invoke<void>("transfer_file", {
      sessionId,
      direction,
      sourcePath,
      targetDir,
      resumeFrom,
      limitKibps,
      verify,
      targetName,
      onEvent,
    }),
  cancelTransfer: (id: string) => invoke<boolean>("cancel_transfer", { id }),
  preview: (sessionId: string | null, path: string, maxBytes = 262144) =>
    invoke<string>("preview", { sessionId, path, maxBytes }),
  saveText: (file: FileRef, text: string) =>
    invoke<void>("save_text", { file, text }),
  checksum: (sessionId: string | null, path: string, algorithm = "sha256") =>
    invoke<FileChecksum>("checksum", { sessionId, path, algorithm }),
  findFiles: (
    sessionId: string | null,
    root: string,
    mask: string,
    content: string | null,
    maxResults = 500,
  ) =>
    invoke<FoundFile[]>("find_files", {
      sessionId,
      root,
      mask,
      content,
      maxResults,
    }),
  chmod: (sessionId: string | null, path: string, mode: number, recursive = false) =>
    invoke<number>("chmod", { sessionId, path, mode, recursive }),
  saveServer: (server: Server) => invoke<Server>("save_server", { server }),
  deleteServer: (id: string) => invoke<void>("delete_server", { id }),
  saveGroup: (group: Group) => invoke<Group>("save_group", { group }),
  deleteGroup: (id: string) => invoke<void>("delete_group", { id }),
  setSecret: (id: string, value: string) =>
    invoke<void>("set_secret", { id, value }),
  getSecret: (id: string) =>
    invoke<string | null>("get_secret", { id, masterPassword: null }),
  deleteSecret: (id: string) => invoke<void>("delete_secret", { id }),
  checkServerAccess: (serverId: string) =>
    invoke<string>("check_server_access", { serverId }),
  loadSnippets: () => invoke<Snippet[]>("load_snippets"),
  saveSnippet: (snippet: Snippet) => invoke<Snippet>("save_snippet", { snippet }),
  deleteSnippet: (id: string) => invoke<void>("delete_snippet", { id }),
  saveSnippetOrder: (ids: string[]) =>
    invoke<void>("save_snippet_order", { ids }),
  loadAiSettings: () => invoke<AiSettings>("load_ai_settings"),
  saveAiSettings: (settings: AiSettings) =>
    invoke<void>("save_ai_settings", { settings }),
  openShell: (sessionId: string, cols: number, rows: number) =>
    invoke<string>("open_shell", { sessionId, cols, rows }),
  shellWrite: (shellId: string, data: string) =>
    invoke<void>("shell_write", { shellId, data }),
  shellPoll: (shellId: string) => invoke<string>("shell_poll", { shellId }),
  shellClose: (shellId: string) => invoke<void>("shell_close", { shellId }),
  exportProfile: (path: string) => invoke<void>("export_profile", { path }),
  importProfile: (path: string, replace: boolean) =>
    invoke<ProfileImportReport>("import_profile", { path, replace }),
  credentialsPreview: () => invoke<string>("credentials_preview"),
  exportCredentials: (path: string) =>
    invoke<number>("export_credentials", { path }),
  syncExportJson: (includeSecrets: boolean) =>
    invoke<string>("sync_export_json", { includeSecrets }),
  importSync: (json: string) => invoke<SyncReport>("import_sync", { json }),
  startSyncShare: (includeSecrets: boolean) =>
    invoke<SyncShare>("start_sync_share", { includeSecrets }),
  stopSyncShare: () => invoke<void>("stop_sync_share"),
};

export function formatBytes(value: number | null | undefined): string {
  if (!value) return "";
  const units = ["Б", "КБ", "МБ", "ГБ", "ТБ"];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return unit === 0
    ? `${size} ${units[unit]}`
    : `${size.toFixed(size >= 10 ? 1 : 2)} ${units[unit]}`;
}

export function formatDate(ms: number | null | undefined): string {
  if (!ms) return "";
  const date = new Date(ms);
  if (Number.isNaN(date.getTime())) return "";
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${pad(date.getDate())}.${pad(date.getMonth() + 1)}.${date.getFullYear()} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function formatMode(mode: number | null | undefined): string {
  if (mode == null) return "";
  return (mode & 0o777).toString(8).padStart(3, "0");
}

export function sortEntries(list: Entry[]): Entry[] {
  return [...list].sort((a, b) => {
    const dir = Number(b.kind === "dir") - Number(a.kind === "dir");
    return dir || a.name.localeCompare(b.name, "ru", { sensitivity: "base" });
  });
}

export function joinPath(base: string, name: string): string {
  const windows = /^[A-Za-z]:/.test(base) || base.includes("\\");
  const separator = windows ? "\\" : "/";
  return `${base.replace(/[\\/]+$/, "")}${separator}${name}`;
}
