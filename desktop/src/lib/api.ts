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
  auth: Auth;
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

export interface Settings {
  version: number;
  locale: string;
  keymapPreset: string;
  appearance: Appearance;
  window: { theme: string; solidMode: boolean; backdrop: string };
}

export const api = {
  initApp: () => invoke<AppInfo>("init_app"),
  ensureDeviceVault: () => invoke<boolean>("ensure_device_vault"),
  listServers: () => invoke<ServerBook>("list_servers"),
  loadSettings: () => invoke<Settings>("load_settings"),
  volumes: () => invoke<Volume[]>("volumes"),
  connectServer: (serverId: string, password: string | null) =>
    invoke<ConnectResult>("connect_server", { serverId, password }),
  cancelConnect: (serverId: string) =>
    invoke<void>("cancel_connect", { serverId }),
  connectStage: () => invoke<number>("connect_stage"),
  homeLocal: () => invoke<string>("home_local"),
  listLocal: (path: string, showHidden = true) =>
    invoke<DirListing>("list_local", { path, showHidden }),
  listRemote: (sessionId: string, path: string, showHidden = true) =>
    invoke<DirListing>("list_remote", { sessionId, path, showHidden }),
  disconnect: (sessionId: string) =>
    invoke<void>("disconnect_session", { sessionId }),
  download: (
    sessionId: string,
    sourcePath: string,
    targetDir: string,
    onEvent: Channel<TransferEvent>,
  ) =>
    invoke<void>("download_file", {
      sessionId,
      sourcePath,
      targetDir,
      onEvent,
    }),
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
