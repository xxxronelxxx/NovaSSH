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
  authFailed?: boolean;
  reachable?: boolean | null;
  checkedAt?: number | null;
  ftpsMode?: string | null;
  ftpsInsecure?: boolean | null;
  passive?: boolean | null;
  s3Endpoint?: string | null;
  s3Region?: string | null;
  s3Bucket?: string | null;
  s3Prefix?: string | null;
  s3PathStyle?: boolean | null;
  s3AccessRef?: string | null;
  s3SecretRef?: string | null;
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
  localBookmarks?: string[];
  remoteBookmarks?: string[];
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
  description: string;
  favorite: boolean;
  runImmediately: boolean;
  confirm: boolean;
  scope: string;
  serverId: string | null;
  order: number;
  [key: string]: unknown;
}

export interface AiSettings {
  provider: string;
  endpoint: string;
  model: string;
  [key: string]: unknown;
}

export interface CompareOptions {
  ignoreWhitespace: boolean;
  ignoreCase: boolean;
  maxBytes: number | null;
}

export interface DiffWord {
  text: string;
  changed: boolean;
}

export interface DiffLine {
  number: number;
  text: string;
  words: DiffWord[];
}

export interface DiffRow {
  kind: "equal" | "add" | "del" | "mod";
  left: DiffLine | null;
  right: DiffLine | null;
}

export interface CompareResult {
  leftLabel: string;
  rightLabel: string;
  leftSize: number;
  rightSize: number;
  equal: boolean;
  binary: boolean;
  truncated: boolean;
  added: number;
  removed: number;
  changed: number;
  leftHash: string | null;
  rightHash: string | null;
  leftEol: string;
  rightEol: string;
  rows: DiffRow[];
}

export interface SyncEntry {
  relative: string;
  action: "upload" | "download" | "skip";
  reason: string;
  size: number;
  localPath: string;
  remotePath: string;
  localSize: number;
  remoteSize: number;
  localModified: number | null;
  remoteModified: number | null;
}

export interface OpenSession {
  serverId: string;
  name: string;
  localPath: string;
  remotePath: string;
}

export interface SessionState {
  version: number;
  lastServerId: string | null;
  servers: unknown[];
  history: unknown[];
  recentLocal: string[];
  openSessions: OpenSession[];
}

export interface ColorRule {
  id: string;
  name: string;
  enabled: boolean;
  priority: number;
  scope: string;
  pattern: string;
  isRegex: boolean;
  fg: string | null;
  bg: string | null;
  bold: boolean;
  italic: boolean;
  underline: boolean;
}

export interface ColorRules {
  version: number;
  rules: ColorRule[];
}

export interface LogFile {
  name: string;
  path: string;
  size: number;
  modified: number;
}

export interface LogSettings {
  editLog: boolean;
}

export interface WinscpImportReport {
  sessions: number;
  imported: number;
  skipped: number;
  groups: number;
  passwords: number;
  errors: string[];
}

export interface AiModel {
  id: string;
  name: string | null;
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
  downloadToCache: (sessionId: string, serverName: string, remotePath: string) =>
    invoke<string>("download_to_cache", { sessionId, serverName, remotePath }),
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
  archiveNeedsPassword: (archivePath: string) =>
    invoke<boolean>("archive_needs_password", { archivePath }),
  unlockArchive: (archivePath: string, password: string) =>
    invoke<void>("unlock_archive", { archivePath, password }),
  listArchive: (archivePath: string, inner: string, showHidden = true) =>
    invoke<DirListing>("list_archive", { archivePath, inner, showHidden }),
  previewArchive: (
    archivePath: string,
    inner: string,
    maxBytes = 262144,
    token: string | null = null,
  ) =>
    invoke<string>("preview_archive", { archivePath, inner, maxBytes, token }),
  createArchive: (
    sources: string[],
    targetPath: string,
    format: string | null = null,
    token: string | null = null,
  ) => invoke<number>("create_archive", { sources, targetPath, format, token }),
  copyToArchive: (
    sessionId: string | null,
    sources: string[],
    archivePath: string,
    inner: string,
    format: string | null,
    token: string | null,
  ) =>
    invoke<number>("copy_to_archive", {
      sessionId,
      sources,
      archivePath,
      inner,
      format,
      token,
    }),
  assembleVolumes: (
    sessionId: string | null,
    parts: string[],
    targetPath: string | null,
  ) => invoke<string>("assemble_volumes", { sessionId, parts, targetPath }),
  cancelArchiveTask: (token: string) =>
    invoke<void>("cancel_archive_task", { token }),
  cancelArchiveJob: (jobId: string) =>
    invoke<void>("cancel_archive_job", { jobId }),
  copyFromArchive: (
    sessionId: string | null,
    archivePath: string,
    inner: string,
    targetDir: string,
    onEvent: Channel<TransferEvent>,
  ) =>
    invoke<void>("copy_from_archive", {
      sessionId,
      archivePath,
      inner,
      targetDir,
      onEvent,
    }),
  packServerArchive: (
    sessionId: string,
    sources: string[],
    targetPath: string,
    format: string | null,
    onEvent: Channel<TransferEvent>,
  ) =>
    invoke<void>("pack_server_archive", {
      sessionId,
      sources,
      targetPath,
      format,
      onEvent,
    }),
  unpackServerArchive: (
    sessionId: string,
    archivePath: string,
    inner: string,
    targetDir: string,
    password: string | null,
    onEvent: Channel<TransferEvent>,
  ) =>
    invoke<void>("unpack_server_archive", {
      sessionId,
      archivePath,
      inner,
      targetDir,
      password,
      onEvent,
    }),
  loadSessionState: () => invoke<SessionState>("load_session_state"),
  saveOpenSessions: (sessions: OpenSession[]) =>
    invoke<void>("save_open_sessions", { sessions }),
  rememberSession: (
    serverId: string,
    remotePath: string,
    localPath: string,
  ) =>
    invoke<void>("remember_session", { serverId, remotePath, localPath }),
  loadColorRules: () => invoke<ColorRules>("load_color_rules"),
  saveColorRules: (rules: ColorRules) =>
    invoke<void>("save_color_rules", { rules }),
  listLogs: () => invoke<LogFile[]>("list_logs"),
  readLog: (path: string, maxBytes = 512 * 1024) =>
    invoke<string>("read_log", { path, maxBytes }),
  logDir: () => invoke<string | null>("log_dir"),
  loadLogSettings: () => invoke<LogSettings>("load_log_settings"),
  saveLogSettings: (settings: LogSettings) =>
    invoke<void>("save_log_settings", { settings }),
  importWinscp: (iniPath: string) =>
    invoke<WinscpImportReport>("import_winscp_ini", { iniPath }),
  compareFiles: (left: FileRef, right: FileRef, options: CompareOptions) =>
    invoke<CompareResult>("compare_files", { left, right, options }),
  syncScan: (
    sessionId: string,
    localRoot: string,
    remoteRoot: string,
    mode: string,
    maxFiles = 5000,
  ) =>
    invoke<SyncEntry[]>("sync_scan", {
      sessionId,
      localRoot,
      remoteRoot,
      mode,
      maxFiles,
    }),
  aiModels: (endpoint: string, apiKey: string) =>
    invoke<AiModel[]>("ai_models", { endpoint, apiKey }),
  aiAsk: (
    endpoint: string,
    apiKey: string,
    model: string,
    question: string,
    context: string,
  ) =>
    invoke<string>("ai_ask", { endpoint, apiKey, model, question, context }),
  startSyncShare: (includeSecrets: boolean) =>
    invoke<SyncShare>("start_sync_share", { includeSecrets }),
  stopSyncShare: () => invoke<void>("stop_sync_share"),
  lockVault: () => invoke<void>("lock_vault"),
  unlockVault: (password: string) =>
    invoke<void>("unlock_vault", { password }),
  vaultInfo: () => invoke<AppInfo>("vault_info"),
  revealInExplorer: (path: string) =>
    invoke<void>("reveal_in_explorer", { path }),
  openTerminalAt: (path: string) =>
    invoke<void>("open_terminal_at", { path }),
  launchProcess: (command: string, args: string[]) =>
    invoke<void>("launch_process", { command, args }),
  launchEditor: (editor: string, path: string) =>
    invoke<void>("launch_editor", { editor, path }),
  pathExists: (path: string) => invoke<boolean>("path_exists", { path }),
  uploadFromCache: (
    sessionId: string,
    localPath: string,
    remotePath: string,
  ) =>
    invoke<void>("upload_from_cache", { sessionId, localPath, remotePath }),
  fileMtimeMs: (path: string) => invoke<number>("file_mtime_ms", { path }),
  uiLog: (line: string) => invoke<void>("ui_log", { line }),
  setSolidMode: (solid: boolean) =>
    invoke<void>("set_solid_mode", { solid }),
  clearServerTmp: (serverName: string) =>
    invoke<void>("clear_server_tmp", { serverName }),
  clearAllTmp: () => invoke<void>("clear_all_tmp"),
  appendEditLog: (
    server: string,
    serverName: string,
    path: string,
    action: string,
    date: string,
    time: string,
  ) =>
    invoke<void>("append_edit_log", {
      server,
      serverName,
      path,
      action,
      date,
      time,
    }),
  importSyncUrl: (url: string) =>
    invoke<SyncReport>("import_sync_url", { url }),
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
