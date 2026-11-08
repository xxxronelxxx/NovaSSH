<script lang="ts">
  import { Channel } from "@tauri-apps/api/core";
  import { onMount } from "svelte";
  import { getCurrentWebview } from "@tauri-apps/api/webview";
  import BulkRenameDialog from "../lib/BulkRenameDialog.svelte";
  import BookmarksDialog from "../lib/BookmarksDialog.svelte";
  import TransferPromptDialog from "../lib/TransferPromptDialog.svelte";
  import hljs from "highlight.js/lib/common";
  import PaneCard from "../lib/PaneCard.svelte";
  import Toolbar from "../lib/Toolbar.svelte";
  import TransferPanel from "../lib/TransferPanel.svelte";
  import TerminalPanel from "../lib/TerminalPanel.svelte";
  import CompareDialog from "../lib/CompareDialog.svelte";
  import SyncDialog from "../lib/SyncDialog.svelte";
  import type { BrowserTab } from "../lib/browser";
  import {
    api,
    formatBytes,
    joinPath,
    type DirListing,
    type Entry,
    type FileRef,
    type FoundFile,
    type Settings,
    type TransferEvent,
    type Volume,
  } from "../lib/api";

  let {
    tabs,
    activeTabId,
    local,
    settings = null,
    volumes = [],
    transfers = [],
    onSelectTab,
    onCloseTab,
    onAddTab,
    onBack,
    onLocalPath,
    onRemotePath,
    onTransfer,
    onCancelTransfer,
    onTrackTransfer,
    onReconnect,
    onSettings,
  }: {
    tabs: BrowserTab[];
    activeTabId: string;
    local: DirListing | null;
    settings?: Settings | null;
    volumes?: Volume[];
    transfers?: TransferEvent[];
    onSelectTab: (id: string) => void;
    onCloseTab: (id: string) => void;
    onAddTab: () => void;
    onBack: () => void;
    onLocalPath: (path: string) => void | Promise<void>;
    onRemotePath: (tabId: string, path: string) => void | Promise<void>;
    onTransfer: (
      direction: "upload" | "download",
      sourcePath: string,
      targetDir: string,
      targetName?: string | null,
    ) => void;
    onCancelTransfer: (id: string) => void;
    onTrackTransfer: (event: TransferEvent) => void;
    onReconnect: (tabId: string) => void | Promise<void>;
    onSettings: () => void;
  } = $props();

  let focused = $state<"local" | "remote">("local");
  let localSel = $state<string[]>([]);
  let remoteSel = $state<string[]>([]);
  let filter = $state("");
  let transferCollapsed = $state(false);
  let terminalOpen = $state(false);
  let error = $state<string | null>(null);
  let notice = $state<string | null>(null);
  let busy = $state<string | null>(null);

  let archive = $state<{
    path: string;
    parent: string;
    inner: string;
    listing: DirListing | null;
  } | null>(null);

  let menu = $state<{ x: number; y: number; entry: Entry | null } | null>(null);
  let prompt = $state<{
    title: string;
    label: string;
    value: string;
    hint?: string;
    action: (value: string) => Promise<void>;
  } | null>(null);
  let promptValue = $state("");
  let secret = $state<{
    title: string;
    action: (value: string) => Promise<void>;
  } | null>(null);
  let secretValue = $state("");
  let confirm = $state<{
    title: string;
    message: string;
    action: () => Promise<void>;
  } | null>(null);
  let editor = $state<{
    entry: Entry;
    text: string;
    mode: "view" | "edit";
    sessionId: string | null;
    inArchive: boolean;
    saved: string;
  } | null>(null);
  let wrap = $state(false);
  let editorScroll = $state(0);
  let info = $state<{ title: string; text: string } | null>(null);

  const editWatchers = new Map<
    string,
    { timer: ReturnType<typeof setInterval>; baseline: number }
  >();

  let findOpen = $state(false);
  let findMask = $state("*");
  let findContent = $state("");
  let findResults = $state<FoundFile[]>([]);

  let compareOpen = $state(false);
  let bulkOpen = $state(false);
  let bookmarksOpen = $state(false);
  let transferPrompt = $state<{
    direction: "upload" | "download";
    items: Entry[];
    targetDir: string;
  } | null>(null);
  let syncOpen = $state(false);

  let createOpen = $state(false);
  let createName = $state("archive.zip");
  let createFormat = $state("zip");

  let task = $state<{ label: string; token: string | null } | null>(null);

  const tab = $derived(tabs.find((item) => item.id === activeTabId) ?? null);
  const remote = $derived(tab?.listing ?? null);
  const localListing = $derived(archive ? archive.listing : local);
  const listing = $derived(focused === "local" ? localListing : remote);
  const selectedPaths = $derived(focused === "local" ? localSel : remoteSel);
  const selectedPath = $derived(
    selectedPaths.length ? selectedPaths[selectedPaths.length - 1] : null,
  );
  const selectedEntry = $derived(
    (listing?.entries ?? []).find((entry) => entry.path === selectedPath) ??
      null,
  );
  const selectedEntries = $derived(
    (listing?.entries ?? []).filter((entry) =>
      selectedPaths.includes(entry.path),
    ),
  );
  const isRemote = $derived(focused === "remote");
  const sessionId = $derived(isRemote ? (tab?.sessionId ?? null) : null);

  const localTabs = $derived.by(() => {
    if (archive) {
      return [
        { id: "archive", label: archive.path.split(/[\\/]/).pop() ?? "архив" },
      ];
    }
    return volumes.length
      ? volumes.map((volume) => ({ id: volume.path, label: volume.name }))
      : [{ id: "local", label: "Локально" }];
  });
  const localActive = $derived.by(() => {
    if (archive) return "archive";
    const path = local?.path?.toLowerCase() ?? "";
    const match = volumes.find((volume) =>
      path.startsWith(volume.path.toLowerCase()),
    );
    return match?.path ?? localTabs[0]?.id ?? "local";
  });

  const localEntry = $derived(
    (localListing?.entries ?? []).find(
      (entry) => entry.path === localSel[localSel.length - 1],
    ) ?? null,
  );
  const remoteEntry = $derived(
    (remote?.entries ?? []).find(
      (entry) => entry.path === remoteSel[remoteSel.length - 1],
    ) ?? null,
  );
  const canCompare = $derived(
    !!localEntry &&
      !!remoteEntry &&
      localEntry.kind !== "dir" &&
      remoteEntry.kind !== "dir",
  );
  const canSync = $derived(
    !archive &&
      !!tab &&
      !!local?.path &&
      !!remote?.path &&
      localListing?.path === local?.path,
  );
  const canExtract = $derived(
    !!selectedEntry &&
      (archive
        ? true
        : isArchiveName(selectedEntry.name) && selectedEntry.kind === "file"),
  );

  const localNames = $derived(
    new Set((localListing?.entries ?? []).map((entry) => entry.name)),
  );
  const remoteNames = $derived(
    new Set((remote?.entries ?? []).map((entry) => entry.name)),
  );
  const comparePanels = $derived(settings?.panels?.comparePanels === true);

  const canCopy = $derived.by(() => {
    if (focused === "local") {
      if (!tab || !remote) return false;
      if (archive) return true;
      return !!selectedEntry && selectedEntry.kind !== "dir";
    }
    if (archive) return !!selectedEntry;
    return !!selectedEntry && selectedEntry.kind !== "dir" && !!local;
  });

  $effect(() => {
    activeTabId;
    remoteSel = [];
  });

  function applySelection(
    current: string[],
    entries: Entry[],
    entry: Entry,
    mode: "single" | "toggle" | "range",
  ): string[] {
    if (mode === "toggle") {
      return current.includes(entry.path)
        ? current.filter((path) => path !== entry.path)
        : [...current, entry.path];
    }
    if (mode === "range") {
      const anchor = current[current.length - 1] ?? entry.path;
      const start = entries.findIndex((item) => item.path === anchor);
      const end = entries.findIndex((item) => item.path === entry.path);
      if (start < 0 || end < 0) return [entry.path];
      const [from, to] = start <= end ? [start, end] : [end, start];
      return entries.slice(from, to + 1).map((item) => item.path);
    }
    return [entry.path];
  }

  function selectLocal(entry: Entry, mode: "single" | "toggle" | "range") {
    focused = "local";
    localSel = applySelection(localSel, localListing?.entries ?? [], entry, mode);
  }

  function selectRemote(entry: Entry, mode: "single" | "toggle" | "range") {
    focused = "remote";
    remoteSel = applySelection(remoteSel, remote?.entries ?? [], entry, mode);
  }

  function isArchiveName(name: string): boolean {
    const lower = name.toLowerCase();
    return [
      ".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz",
      ".tar.xz", ".txz", ".tar.zst", ".tzst", ".7z", ".gz", ".bz2", ".xz", ".zst",
    ].some((suffix) => lower.endsWith(suffix));
  }

  async function reload() {
    if (!listing) return;
    if (focused === "local") {
      if (archive) await loadArchive(archive.inner);
      else await onLocalPath(listing.path);
    } else if (tab) {
      await onRemotePath(tab.id, listing.path);
    }
  }

  async function syncOther(name: string) {
    if (!settings?.panels?.syncNavigation || !name) return;
    if (focused === "local" && tab && remote) {
      const match = remote.entries.find(
        (entry) =>
          entry.kind === "dir" &&
          entry.name.toLowerCase() === name.toLowerCase(),
      );
      if (match) await onRemotePath(tab.id, match.path);
    } else if (focused === "remote" && localListing) {
      const match = localListing.entries.find(
        (entry) =>
          entry.kind === "dir" &&
          entry.name.toLowerCase() === name.toLowerCase(),
      );
      if (match) await onLocalPath(match.path);
    }
  }

  function baseName(path: string): string {
    const parts = path.split(/[\\/]/).filter(Boolean);
    return parts[parts.length - 1] ?? "";
  }

  async function navigateLocal(path: string) {
    localSel = [];
    if (archive) {
      await loadArchive(path);
      return;
    }
    const name = baseName(path);
    focused = "local";
    await onLocalPath(path);
    await syncOther(name);
  }

  async function navigateRemote(path: string) {
    if (!tab) return;
    remoteSel = [];
    const name = baseName(path);
    focused = "remote";
    await onRemotePath(tab.id, path);
    await syncOther(name);
  }

  async function loadArchive(inner: string) {
    const current = archive;
    if (!current) return;
    try {
      const normalized = inner === "/" ? "" : inner;
      const listed = await api.listArchive(
        current.path,
        normalized,
        settings?.panels?.showHidden ?? true,
      );
      archive = { ...current, inner: normalized, listing: listed };
      localSel = [];
    } catch (e) {
      error = `Архив: ${e}`;
    }
  }

  async function openArchive(entry: Entry) {
    let needed = false;
    try {
      needed = await api.archiveNeedsPassword(entry.path);
    } catch {
      needed = false;
    }
    const open = async () => {
      archive = {
        path: entry.path,
        parent: local?.path ?? "",
        inner: "",
        listing: null,
      };
      localSel = [];
      await loadArchive("");
    };
    if (!needed) {
      await open();
      return;
    }
    secret = {
      title: `Пароль архива ${entry.name}`,
      action: async (password) => {
        await api.unlockArchive(entry.path, password);
        await open();
      },
    };
    secretValue = "";
  }

  async function closeArchive() {
    const current = archive;
    if (!current) return;
    archive = null;
    localSel = [];
    if (current.parent) await onLocalPath(current.parent);
  }

  function up() {
    if (focused === "local") {
      if (archive) {
        if (archive.inner) {
          const parent = archive.inner.replace(/\/[^/]+$/, "");
          void loadArchive(parent || "");
        } else {
          void closeArchive();
        }
      } else if (local?.parent) {
        localSel = [];
        void onLocalPath(local.parent);
      }
    } else if (remote?.parent) {
      void navigateRemote(remote.parent);
    }
  }

  function refresh() {
    void reload();
  }

  function openSelected() {
    const entry = selectedEntry;
    if (!entry) return;
    if (entry.kind === "dir") {
      if (focused === "local") {
        if (archive) void loadArchive(entry.path);
        else void navigateLocal(entry.path);
      } else {
        void navigateRemote(entry.path);
      }
      return;
    }
    if (!archive && isArchiveName(entry.name)) {
      void openArchive(entry);
      return;
    }
    void openEditor(entry, "view");
  }

  function openLocal(entry: Entry) {
    if (entry.kind === "dir") {
      if (archive) void loadArchive(entry.path);
      else void navigateLocal(entry.path);
      return;
    }
    if (!archive && isArchiveName(entry.name)) {
      void openArchive(entry);
      return;
    }
    void openEditor(entry, "view");
  }

  function openRemote(entry: Entry) {
    if (entry.kind === "dir") {
      void navigateRemote(entry.path);
      return;
    }
    if (isArchiveName(entry.name)) {
      void openRemoteArchive(entry);
      return;
    }
    void openEditor(entry, "view");
  }

  async function openRemoteArchive(entry: Entry) {
    if (!tab) return;
    await run(`Распаковываю ${entry.name}…`, async () => {
      const channel = new Channel<TransferEvent>();
      let target = "";
      channel.onmessage = (event) => {
        onTrackTransfer(event);
        if (event.state === "done" && event.message) target = event.message;
        if (event.message && !target) target = event.message;
      };
      await api.unpackServerArchive(
        tab!.sessionId,
        entry.path,
        "",
        "",
        null,
        channel,
      );
      if (target) {
        await onRemotePath(tab!.id, target);
        notice = `Архив развёрнут на сервере: ${target}`;
      }
    });
  }

  async function run(label: string, action: () => Promise<void>) {
    busy = label;
    error = null;
    try {
      await action();
    } catch (e) {
      error = String(e);
    } finally {
      busy = null;
    }
  }

  function ask(
    title: string,
    label: string,
    value: string,
    action: (value: string) => Promise<void>,
    hint?: string,
  ) {
    promptValue = value;
    prompt = { title, label, value, hint, action };
  }

  function askConfirm(
    title: string,
    message: string,
    action: () => Promise<void>,
  ) {
    confirm = { title, message, action };
  }

  async function submitPrompt() {
    const current = prompt;
    if (!current) return;
    const value = promptValue;
    prompt = null;
    await run("Выполняю…", () => current.action(value));
  }

  async function submitSecret() {
    const current = secret;
    if (!current) return;
    const value = secretValue;
    secret = null;
    secretValue = "";
    await run("Открываю…", () => current.action(value));
  }

  async function submitConfirm() {
    const current = confirm;
    if (!current) return;
    confirm = null;
    await run("Выполняю…", () => current.action());
  }

  function trackChannel(): { channel: Channel<TransferEvent>; } {
    const channel = new Channel<TransferEvent>();
    channel.onmessage = (event) => onTrackTransfer(event);
    return { channel };
  }

  async function copyOutOfArchive(inner: string, targetDir: string) {
    const current = archive;
    if (!current || !tab) return;
    const { channel } = trackChannel();
    await api.copyFromArchive(
      tab.sessionId,
      current.path,
      inner,
      targetDir,
      channel,
    );
    await onRemotePath(tab.id, targetDir);
  }

  async function copyBetween() {
    const items = selectedEntries;
    if (!items.length) return;

    if (focused === "local") {
      if (archive) {
        if (!tab || !remote) return;
        const inner = selectedEntry?.path ?? archive.inner;
        await run("Распаковываю…", () =>
          copyOutOfArchive(inner, remote.path),
        );
        return;
      }
      if (!tab || !remote) return;
      transferPrompt = {
        direction: "upload",
        items,
        targetDir: remote.path,
      };
      return;
    }

    if (archive) {
      if (!tab) return;
      await run("Добавляю в архив…", async () => {
        await api.copyToArchive(
          tab.sessionId,
          items.map((entry) => entry.path),
          archive!.path,
          archive!.inner,
          null,
          null,
        );
        await loadArchive(archive!.inner);
      });
      return;
    }

    if (!local) return;
    transferPrompt = {
      direction: "download",
      items,
      targetDir: local.path,
    };
  }

  function confirmTransfer(result: { dir: string; name: string | null }) {
    const prompt = transferPrompt;
    transferPrompt = null;
    if (!prompt) return;
    for (const entry of prompt.items) {
      onTransfer(
        prompt.direction,
        entry.path,
        result.dir,
        prompt.items.length === 1 ? result.name : null,
      );
    }
  }

  async function dropPaths(
    source: "local" | "remote" | "os",
    target: "local" | "remote",
    paths: string[],
  ) {
    if (!paths.length || source === target) return;
    const targetDir =
      target === "local" ? (local?.path ?? "") : (remote?.path ?? "");
    if (!targetDir) return;

    if (target === "local") {
      if (source === "remote") {
        for (const path of paths) onTransfer("download", path, targetDir);
      } else {
        await run("Копирую локально…", async () => {
          await api.copyLocal(paths, targetDir);
          await reload();
        });
      }
      return;
    }
    if (!tab) return;
    for (const path of paths) onTransfer("upload", path, targetDir);
  }

  onMount(() => {
    let unlisten: (() => void) | null = null;
    return () => {
      for (const watcher of editWatchers.values()) clearInterval(watcher.timer);
      editWatchers.clear();
      unlisten?.();
    };
  });

  onMount(() => {
    let unlisten: (() => void) | null = null;
    let disposed = false;
    try {
      void getCurrentWebview()
        .onDragDropEvent((event) => {
          if (event.payload.type !== "drop") return;
          const { paths, position } = event.payload;
          const scale = window.devicePixelRatio || 1;
          const element = document.elementFromPoint(
            position.x / scale,
            position.y / scale,
          );
          const pane = element?.closest("[data-pane]") as HTMLElement | null;
          const target = pane?.dataset.pane as "local" | "remote" | undefined;
          if (target) void dropPaths("os", target, paths);
        })
        .then((stop) => {
          if (disposed) stop();
          else unlisten = stop;
        })
        .catch(() => {});
    } catch {
      // The event plugin is unavailable outside a Tauri window.
    }
    return () => {
      disposed = true;
      unlisten?.();
    };
  });

  function openBookmarks() {
    if (!settings) return;
    bookmarksOpen = true;
  }

  function bulkRename() {
    if (archive) {
      error = "Внутри архива переименование недоступно";
      return;
    }
    if (!selectedEntries.length) return;
    bulkOpen = true;
  }

  async function applyBulk(renames: { from: string; to: string }[]) {
    if (!listing) return;
    for (const row of renames) {
      if (row.from === row.to) continue;
      await api.rename(
        sessionId,
        joinPath(listing.path, row.from),
        joinPath(listing.path, row.to),
      );
    }
    await reload();
  }

  async function extractSelected() {
    const entry = selectedEntry;
    if (!entry) return;

    if (focused === "local") {
      if (archive) {
        if (!tab || !remote) return;
        await run("Распаковываю…", () =>
          copyOutOfArchive(entry.path, remote.path),
        );
        return;
      }
      if (!isArchiveName(entry.name) || !tab || !remote) return;
      const { channel } = trackChannel();
      await run("Распаковываю…", async () => {
        await api.copyFromArchive(
          tab.sessionId,
          entry.path,
          "",
          remote.path,
          channel,
        );
        await onRemotePath(tab.id, remote.path);
      });
      return;
    }

    if (!isArchiveName(entry.name) || !tab) return;
    if (archive) {
      error = "Нельзя распаковать архив в архив";
      return;
    }
    if (!local) return;
    const { channel } = trackChannel();
    await run("Распаковываю…", async () => {
      const cached = await api.downloadToCache(
        tab.sessionId,
        tab.label,
        entry.path,
      );
      await api.copyFromArchive(null, cached, "", local.path, channel);
      await onLocalPath(local.path);
    });
  }

  function mkdirPrompt() {
    if (!listing) return;
    if (archive) {
      error = "В архиве нельзя создавать папки";
      return;
    }
    ask("Новая папка", "Имя", "новая папка", async (value) => {
      const name = value.trim();
      if (!name) return;
      await api.mkdir(sessionId, joinPath(listing.path, name));
      await reload();
    });
  }

  function renameSelected() {
    const entry = selectedEntry;
    if (!entry || !listing) return;
    if (archive) {
      error = "В архиве переименование недоступно";
      return;
    }
    ask("Переименовать", "Новое имя", entry.name, async (value) => {
      const name = value.trim();
      if (!name || name === entry.name) return;
      await api.rename(sessionId, entry.path, joinPath(listing.path, name));
      await reload();
    });
  }

  function deleteSelected() {
    const items = selectedEntries;
    if (!items.length) return;
    if (archive) {
      error = "Из архива можно только распаковать";
      return;
    }
    const single = items.length === 1 ? items[0] : null;
    const message = single
      ? `${single.kind === "dir" ? "Папка" : "Файл"} «${single.name}» будет удалён без возможности отмены.`
      : `${items.length} объектов будут удалены без возможности отмены.`;
    askConfirm("Удалить?", message, async () => {
      for (const entry of items) {
        await api.remove(sessionId, entry.path, entry.kind === "dir");
      }
      await reload();
    });
  }

  function logEdit(action: string) {
    const server = tab ? `${tab.server.user}@${tab.server.host}` : "локально";
    const serverName = tab?.label ?? "local";
    const entry = editor?.entry ?? selectedEntry;
    if (!entry) return;
    const now = new Date();
    const two = (value: number) => String(value).padStart(2, "0");
    const date = `${two(now.getDate())}-${two(now.getMonth() + 1)}-${now.getFullYear()}`;
    const time = `${two(now.getHours())}:${two(now.getMinutes())}:${two(now.getSeconds())}`;
    void api
      .appendEditLog(server, serverName, entry.path, action, date, time)
      .catch(() => {});
  }

  function watchExternal(localPath: string, remotePath: string, sid: string) {
    const previous = editWatchers.get(localPath);
    if (previous) clearInterval(previous.timer);
    let baseline = -1;
    let uploading = false;
    void api.fileMtimeMs(localPath).then((value) => (baseline = value)).catch(() => {});
    const timer = setInterval(async () => {
      if (uploading) return;
      let now = -1;
      try {
        now = await api.fileMtimeMs(localPath);
      } catch {
        return;
      }
      if (baseline < 0) {
        baseline = now;
        return;
      }
      if (now <= baseline) return;
      baseline = now;
      uploading = true;
      try {
        await api.uploadFromCache(sid, localPath, remotePath);
        logEdit("сохранён");
        if (tab?.listing?.path === remotePath.replace(/\/[^/]+$/, "") || true) {
          const dir = remotePath.replace(/\/[^/]+$/, "");
          if (remote?.path === dir) await onRemotePath(tab!.id, dir);
        }
      } catch (e) {
        error = `Загрузка изменений: ${e}`;
      } finally {
        uploading = false;
      }
    }, 2000);
    editWatchers.set(localPath, { timer, baseline });
  }

  async function openEditor(entry: Entry, mode: "view" | "edit") {
    const sid = sessionId;
    const current = archive;
    const external = (settings?.editor?.external ?? "").trim();
    if (mode === "edit" && !current && external) {
      await run("Открываю редактор…", async () => {
        const localPath =
          sid && tab
            ? await api.downloadToCache(sid, tab.label, entry.path)
            : entry.path;
        try {
          await api.launchEditor(external, localPath);
        } catch (e) {
          if (settings?.editor?.fallbackBuiltin === false) throw e;
          error = `Внешний редактор недоступен (${e}) — открыт встроенный`;
          editor = {
            entry,
            text:
              sid && tab
                ? await api.preview(sid, entry.path, 262144)
                : await api.preview(null, entry.path, 262144),
            mode: "edit",
            sessionId: sid,
            inArchive: false,
            saved: "",
          };
          return;
        }
        if (sid) {
          watchExternal(localPath, entry.path, sid);
        }
        logEdit("открыт во внешнем редакторе");
      });
      return;
    }
    await run("Читаю файл…", async () => {
      const text = current
        ? await api.previewArchive(current.path, entry.path, 262144, null)
        : await api.preview(sid, entry.path, 262144);
      editor = {
        entry,
        text,
        mode: current ? "view" : mode,
        sessionId: sid,
        inArchive: !!current,
        saved: text,
      };
    });
  }

  function editSelected() {
    if (selectedEntry && selectedEntry.kind !== "dir") {
      void openEditor(selectedEntry, "edit");
    }
  }

  async function saveEditor() {
    const current = editor;
    if (!current || current.inArchive) return;
    await run("Сохраняю…", async () => {
      await api.saveText(
        {
          sessionId: current.sessionId,
          archivePath: null,
          path: current.entry.path,
          label: null,
        },
        current.text,
      );
      logEdit("сохранён");
      editor = null;
      await reload();
    });
  }

  const highlighted = $derived.by(() => {
    if (!editor || editor.mode === "edit") return "";
    const name = editor.entry.name.toLowerCase();
    const ext = name.includes(".") ? name.split(".").pop() ?? "" : "";
    const language =
      ext === "php"
        ? "php"
        : ext === "js" || ext === "mjs" || ext === "cjs"
          ? "javascript"
          : ext === "ts"
            ? "typescript"
            : ext === "json"
              ? "json"
              : ext === "html" || ext === "htm"
                ? "xml"
                : ext === "css"
                  ? "css"
                  : ext === "md"
                    ? "markdown"
                    : ext === "sh" || ext === "bash"
                      ? "bash"
                      : ext === "yml" || ext === "yaml"
                        ? "yaml"
                        : ext === "xml"
                          ? "xml"
                          : ext === "rs"
                            ? "rust"
                            : ext === "py"
                              ? "python"
                              : ext === "sql"
                                ? "sql"
                                : ext === "ini" || ext === "conf"
                                  ? "ini"
                                  : "";
    const text = editor.text.slice(0, 200000);
    try {
      return language
        ? hljs.highlight(text, { language, ignoreIllegals: true }).value
        : hljs.highlightAuto(text).value;
    } catch {
      return "";
    }
  });

  const editorTruncated = $derived((editor?.text.length ?? 0) >= 262140);
  const editorDirty = $derived(
    !!editor && editor.mode === "edit" && editor.text !== editor.saved,
  );
  const editorLines = $derived(editor ? editor.text.split("\n").length : 0);

  function localRef(entry: Entry): FileRef {
    return {
      sessionId: null,
      archivePath: archive?.path ?? null,
      path: entry.path,
      label: archive
        ? `${archive.path.split(/[\\/]/).pop()}/${entry.name}`
        : entry.name,
    };
  }

  function remoteRef(entry: Entry): FileRef {
    return {
      sessionId: tab?.sessionId ?? null,
      archivePath: null,
      path: entry.path,
      label: `${tab?.label ?? "server"}:${entry.path}`,
    };
  }

  function openCompare() {
    if (!canCompare) return;
    compareOpen = true;
  }

  function openSync() {
    if (!canSync || !local || !remote || !tab) return;
    syncOpen = true;
  }

  async function afterSync() {
    if (local) await onLocalPath(local.path);
    if (tab && remote) await onRemotePath(tab.id, remote.path);
  }

  function checksumSelected() {
    const entry = selectedEntry;
    if (!entry || entry.kind === "dir") return;
    if (archive) {
      error = "SHA-256 для файлов внутри архива пока не считается";
      return;
    }
    void run("Считаю SHA-256…", async () => {
      const result = await api.checksum(sessionId, entry.path, "sha256");
      info = {
        title: `SHA-256 · ${entry.name}`,
        text: `${result.hash}\n\nРазмер: ${formatBytes(result.size)}\nКто считал: ${result.computedBy === "server" ? "сервер" : "локально"}`,
      };
    });
  }

  function chmodSelected() {
    const entry = selectedEntry;
    if (!entry) return;
    if (archive) {
      error = "В архиве права не меняются";
      return;
    }
    const current = entry.mode != null ? (entry.mode & 0o777).toString(8) : "644";
    ask("Права доступа", "Восьмерично, например 644", current, async (value) => {
      const mode = Number.parseInt(value.trim(), 8);
      if (Number.isNaN(mode)) throw new Error("Нужно восьмеричное число");
      await api.chmod(sessionId, entry.path, mode, false);
      await reload();
    });
  }

  async function copyPath() {
    const entry = selectedEntry;
    if (!entry) return;
    await navigator.clipboard.writeText(entry.path).catch(() => {});
    info = { title: "Путь скопирован", text: entry.path };
  }

  async function compareHashes() {
    const left = localEntry;
    const right = remoteEntry;
    if (!left || !right || !tab || left.kind === "dir" || right.kind === "dir") {
      error = "На другой панели нет файла для сравнения";
      return;
    }
    await run("Считаю SHA-256…", async () => {
      const [a, b] = await Promise.all([
        api.checksum(null, left.path, "sha256"),
        api.checksum(tab!.sessionId, right.path, "sha256"),
      ]);
      const same = a.hash === b.hash;
      info = {
        title: same ? "SHA-256 совпадает" : "SHA-256 отличается",
        text: [
          `Локально · ${left.name}`,
          a.hash,
          formatBytes(a.size),
          "",
          `Сервер · ${right.name}`,
          b.hash,
          formatBytes(b.size),
        ].join("\n"),
      };
    });
  }

  async function revealSelected() {
    const entry = selectedEntry;
    if (!entry) return;
    await api.revealInExplorer(entry.path).catch((e) => (error = String(e)));
  }

  async function terminalHere() {
    const path = focused === "local" ? (local?.path ?? "") : "";
    if (!path) return;
    await api.openTerminalAt(path).catch((e) => (error = String(e)));
  }

  let quick = "";
  let quickTimer: ReturnType<typeof setTimeout> | null = null;

  function quickSearch(character: string) {
    const entries = listing?.entries ?? [];
    if (!entries.length) return;
    quick += character.toLowerCase();
    if (quickTimer) clearTimeout(quickTimer);
    quickTimer = setTimeout(() => (quick = ""), 1200);
    const start = entries.findIndex((entry) => entry.path === selectedPath);
    for (let step = 1; step <= entries.length; step += 1) {
      const item = entries[(Math.max(0, start) + step) % entries.length];
      if (item.name.toLowerCase().startsWith(quick)) {
        if (focused === "local") localSel = [item.path];
        else remoteSel = [item.path];
        return;
      }
    }
  }

  function openFind() {
    if (archive) {
      error = "Поиск внутри архива пока не поддерживается";
      return;
    }
    findOpen = true;
    findResults = [];
  }

  async function runFind() {
    if (!listing) return;
    await run("Ищу…", async () => {
      findResults = await api.findFiles(
        sessionId,
        listing.path,
        findMask.trim() || "*",
        findContent.trim() || null,
        500,
      );
    });
  }

  function looksLikeVolume(name: string): boolean {
    return /\.\d{3,}$/.test(name) || /\.z\d{2}$/i.test(name);
  }

  async function assembleVolumes() {
    if (!listing) return;
    const parts = listing.entries
      .filter((entry) => looksLikeVolume(entry.name))
      .map((entry) => entry.path);
    if (parts.length < 2) {
      error = "Выделите все части архива";
      return;
    }
    await run("Собираю части…", async () => {
      const target = await api.assembleVolumes(sessionId, parts, null);
      info = { title: "Части собраны", text: target };
      await reload();
    });
  }

  function openCreate() {
    const entry = selectedEntry;
    if (!entry) return;
    const base = entry.name;
    createName = `${base}.zip`;
    createFormat = "zip";
    createOpen = true;
  }

  function replaceExtension(name: string, format: string): string {
    const lower = name.toLowerCase();
    for (const suffix of [
      ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".zip", ".tar", ".7z",
    ]) {
      if (lower.endsWith(suffix)) {
        return `${name.slice(0, -suffix.length)}.${format}`;
      }
    }
    return `${name}.${format}`;
  }

  async function createArchive() {
    const entry = selectedEntry;
    if (!entry || !listing) return;
    const name = createName.trim();
    if (!name) return;
    createOpen = false;
    const targetPath = joinPath(listing.path, name);
    const sources = [entry.path];
    const token = `create_${Date.now()}`;

    if (focused === "remote") {
      if (!tab) return;
      const { channel } = trackChannel();
      await run("Упаковываю на сервере…", async () => {
        await api.packServerArchive(
          tab.sessionId,
          sources,
          targetPath,
          createFormat,
          channel,
        );
        await onRemotePath(tab.id, listing.path);
      });
      return;
    }

    task = { label: "Упаковываю…", token };
    try {
      await api.createArchive(sources, targetPath, createFormat, token);
      await reload();
    } catch (e) {
      if (!String(e).includes("__cancelled__")) error = String(e);
    } finally {
      task = null;
    }
  }

  function cancelTask() {
    if (task?.token) void api.cancelArchiveTask(task.token).catch(() => {});
  }

  async function toggleTerminal() {
    const terminal = settings?.terminal;
    const profile = terminal?.profiles?.find(
      (item) => item.id === terminal.defaultProfile,
    );
    const command = profile?.command?.trim() ?? "";
    if (command && tab) {
      try {
        const explicit =
          command.includes("\\") || command.includes("/");
        if (!explicit || (await api.pathExists(command))) {
          let password = "";
          if (tab.server.auth?.type === "password") {
            const ref = tab.server.passwordRef ?? `pwd_${tab.server.id}`;
            password = (await api.getSecret(ref)) ?? "";
          }
          const args = (profile?.args ?? []).map((value) =>
            value
              .replaceAll("{user}", tab.server.user)
              .replaceAll("{host}", tab.server.host)
              .replaceAll("{port}", String(tab.server.port))
              .replaceAll("{password}", password),
          );
          if (
            command.toLowerCase().includes("putty") &&
            password &&
            !args.includes("-pw")
          ) {
            args.push("-pw", password);
          }
          await api.launchProcess(command, args);
          return;
        }
      } catch (e) {
        error = `Внешний терминал не запустился: ${e}`;
      }
    }
    terminalOpen = !terminalOpen;
  }

  function openMenu(entry: Entry | null, event: MouseEvent) {
    menu = {
      x: Math.min(event.clientX, window.innerWidth - 230),
      y: Math.min(event.clientY, window.innerHeight - 320),
      entry,
    };
  }

  function menuAction(action: () => void) {
    menu = null;
    action();
  }

  function selectLocalTab(id: string) {
    if (archive) return;
    void navigateLocal(id === "local" ? (local?.path ?? "") : id);
  }

  function onKey(event: KeyboardEvent) {
    const target = event.target as HTMLElement | null;
    if (
      target &&
      (/^(input|textarea|select)$/i.test(target.tagName) ||
        target.isContentEditable)
    ) {
      return;
    }
    if (event.ctrlKey && event.key.toLowerCase() === "d") {
      event.preventDefault();
      openBookmarks();
      return;
    }
    if (event.ctrlKey && event.key === "F3") {
      event.preventDefault();
      openCompare();
      return;
    }
    if (event.ctrlKey && event.key === "F5") {
      event.preventDefault();
      void extractSelected();
      return;
    }
    if (event.altKey && event.key === "F7") {
      event.preventDefault();
      openFind();
      return;
    }
    if (event.key === "Tab") {
      event.preventDefault();
      focused = focused === "local" ? "remote" : "local";
      return;
    }
    if (event.ctrlKey && event.key.toLowerCase() === "a") {
      event.preventDefault();
      const entries = listing?.entries ?? [];
      if (focused === "local") localSel = entries.map((entry) => entry.path);
      else remoteSel = entries.map((entry) => entry.path);
      return;
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const entries = listing?.entries ?? [];
      if (!entries.length) return;
      const index = entries.findIndex((entry) => entry.path === selectedPath);
      const next =
        event.key === "ArrowDown"
          ? Math.min(entries.length - 1, index + 1)
          : Math.max(0, index - 1);
      if (event.shiftKey) {
        if (focused === "local") {
          localSel = applySelection(
            localSel,
            entries,
            entries[next],
            "range",
          );
        } else {
          remoteSel = applySelection(
            remoteSel,
            entries,
            entries[next],
            "range",
          );
        }
      } else if (focused === "local") {
        localSel = [entries[next].path];
      } else {
        remoteSel = [entries[next].path];
      }
      return;
    }
    if (event.key === " ") {
      event.preventDefault();
      const entries = listing?.entries ?? [];
      const entry = selectedEntry;
      if (!entry) return;
      if (focused === "local") {
        localSel = applySelection(localSel, entries, entry, "toggle");
      } else {
        remoteSel = applySelection(remoteSel, entries, entry, "toggle");
      }
      return;
    }
    switch (event.key) {
      case "F5":
        event.preventDefault();
        void copyBetween();
        break;
      case "Delete":
        event.preventDefault();
        deleteSelected();
        break;
      case "F2":
        event.preventDefault();
        renameSelected();
        break;
      case "F7":
        event.preventDefault();
        mkdirPrompt();
        break;
      case "F8":
        event.preventDefault();
        deleteSelected();
        break;
      case "F3":
        event.preventDefault();
        if (selectedEntry && selectedEntry.kind !== "dir") {
          void openEditor(selectedEntry, "view");
        }
        break;
      case "F4":
        event.preventDefault();
        editSelected();
        break;
      case "Backspace":
        event.preventDefault();
        up();
        break;
      case "Enter":
        event.preventDefault();
        openSelected();
        break;
      case "Escape":
        if (focused === "local") localSel = [];
        else remoteSel = [];
        menu = null;
        break;
    }
    if (
      event.key.length === 1 &&
      !event.ctrlKey &&
      !event.altKey &&
      !event.metaKey
    ) {
      quickSearch(event.key);
      return;
    }
    if (event.ctrlKey && event.key.toLowerCase() === "f") {
      event.preventDefault();
      (
        document.querySelector(".filter input") as HTMLInputElement | null
      )?.focus();
    }
  }
</script>

<svelte:window onkeydown={onKey} />

<div class="browser">
  <Toolbar
    canUp={isRemote ? !!remote?.parent : !!localListing?.parent}
    canCopy={canCopy}
    canRename={!!selectedEntry}
    canDelete={!!selectedEntry}
    canEdit={!!selectedEntry && selectedEntry.kind !== "dir"}
    {canCompare}
    {canSync}
    {canExtract}
    {terminalOpen}
    {filter}
    onBack={onBack}
    onUp={up}
    onRefresh={refresh}
    onCopy={copyBetween}
    onCompare={openCompare}
    onSync={openSync}
    onExtract={extractSelected}
    onRename={renameSelected}
    onDelete={deleteSelected}
    onMkdir={mkdirPrompt}
    onEdit={editSelected}
    onTerminal={toggleTerminal}
    onSettings={onSettings}
    onFilter={(value) => (filter = value)}
  />

  <div class="panes">
    <PaneCard
      variant="local"
      tabs={localTabs}
      activeTab={localActive}
      listing={localListing}
      selected={localSel}
      focused={focused === "local"}
      filter={focused === "local" ? filter : ""}
      rootLabel={archive ? (archive.path.split(/[\\/]/).pop() ?? "архив") : undefined}
      onSelectTab={selectLocalTab}
      onAdd={() => {}}
      onUp={up}
      onRefresh={refresh}
      onPath={navigateLocal}
      onSelect={selectLocal}
      onDrop={(source, paths) => dropPaths(source, "local", paths)}
      onOpen={openLocal}
      onFocus={() => (focused = "local")}
      onContextMenu={openMenu}
    />

    <PaneCard
      variant="remote"
      tabs={tabs.map((item) => ({
        id: item.id,
        label: item.label,
        hint: `${item.server.user}@${item.server.host}`,
      }))}
      activeTab={activeTabId}
      listing={remote}
      selected={remoteSel}
      focused={focused === "remote"}
      filter={focused === "remote" ? filter : ""}
      canAdd
      otherNames={comparePanels ? localNames : undefined}
      onSelectTab={onSelectTab}
      onCloseTab={onCloseTab}
      onAdd={onAddTab}
      onUp={() => remote?.parent && navigateRemote(remote.parent)}
      onRefresh={() => remote && navigateRemote(remote.path)}
      onPath={navigateRemote}
      onSelect={selectRemote}
      onDrop={(source, paths) => dropPaths(source, "remote", paths)}
      onOpen={openRemote}
      onFocus={() => (focused = "remote")}
      onContextMenu={openMenu}
    />
  </div>

  {#if tab?.disconnected}
    <div class="offline">
      <span>Соединение с сервером потеряно.</span>
      <button class="btn primary" onclick={() => onReconnect(tab!.id)}>
        Переподключиться
      </button>
    </div>
  {/if}

  {#if terminalOpen && tab}
    <div class="terminal-wrap">
      <TerminalPanel
        sessionId={tab.sessionId}
        title={tab.label}
        onClose={() => (terminalOpen = false)}
      />
    </div>
  {:else}
    <div class="transfer-wrap">
      <TransferPanel
        {transfers}
        collapsed={transferCollapsed}
        onToggle={() => (transferCollapsed = !transferCollapsed)}
        onCancel={onCancelTransfer}
      />
    </div>
  {/if}
</div>

{#if menu}
  <div class="menu-backdrop" onclick={() => (menu = null)}></div>
  <div class="context" style:left={`${menu.x}px`} style:top={`${menu.y}px`}>
    {#if menu.entry}
      <button onclick={() => menuAction(openSelected)}>
        {menu.entry.kind === "dir" ? "Открыть" : "Просмотр (F3)"}
      </button>
      <button onclick={() => menuAction(copyPath)}>Копировать путь</button>
      {#if menu.entry.kind !== "dir"}
        <button onclick={() => menuAction(copyBetween)}>
          {focused === "local" ? "Загрузить (F5)" : "Скачать (F5)"}
        </button>
        {#if focused === "local" && !archive && isArchiveName(menu.entry.name)}
          <button onclick={() => menuAction(() => extractSelected())}>
            Распаковать (Ctrl+F5)
          </button>
        {/if}
        {#if !archive}
          <button onclick={() => menuAction(checksumSelected)}>
            SHA-256 файла
          </button>
          {#if canCompare}
            <button onclick={() => menuAction(compareHashes)}>
              Сравнить SHA-256 с другой панелью
            </button>
          {/if}
        {/if}
      {/if}
      {#if menu.entry.kind === "dir" && !archive}
        <button onclick={() => menuAction(openCreate)}>Создать архив…</button>
      {/if}
      {#if focused === "local" && !archive}
        <div class="sep"></div>
        <button onclick={() => menuAction(revealSelected)}>
          Открыть в проводнике
        </button>
        <button onclick={() => menuAction(terminalHere)}>
          Терминал в этой папке
        </button>
      {/if}
      {#if !archive}
        <div class="sep"></div>
        <button onclick={() => menuAction(renameSelected)}>
          Переименовать (F2)
        </button>
        <button onclick={() => menuAction(bulkRename)}>
          Массовое переименование…
        </button>
        <button onclick={() => menuAction(chmodSelected)}>
          Права доступа…
        </button>
        <div class="sep"></div>
        <button class="danger" onclick={() => menuAction(deleteSelected)}>
          Удалить (F8)
        </button>
      {/if}
    {:else}
      <button onclick={() => menuAction(mkdirPrompt)}>Новая папка (F7)</button>
      <button onclick={() => menuAction(openFind)}>Найти файлы…</button>
      <button onclick={() => menuAction(openBookmarks)}>
        Закладки (Ctrl+D)
      </button>
      {#if selectedEntry && looksLikeVolume(selectedEntry.name)}
        <button onclick={() => menuAction(assembleVolumes)}>
          Собрать части в архив…
        </button>
      {/if}
    {/if}
  </div>
{/if}

{#if transferPrompt}
  <TransferPromptDialog
    title={transferPrompt.direction === "upload" ? "Отправить" : "Скачать"}
    items={transferPrompt.items.map((entry) => entry.name)}
    initialDir={transferPrompt.targetDir}
    dirLabel={transferPrompt.direction === "upload" ? "Каталог на сервере" : "Каталог на компьютере"}
    allowRename={!archive}
    onClose={() => (transferPrompt = null)}
    onConfirm={confirmTransfer}
  />
{/if}

{#if bookmarksOpen && settings}
  <BookmarksDialog
    {settings}
    remote={focused === "remote"}
    current={focused === "local" ? (local?.path ?? "") : (remote?.path ?? "")}
    onClose={() => (bookmarksOpen = false)}
    onOpen={(path) => {
      if (focused === "local") void navigateLocal(path);
      else void navigateRemote(path);
    }}
  />
{/if}

{#if bulkOpen}
  <BulkRenameDialog
    names={selectedEntries.map((entry) => entry.name)}
    onClose={() => (bulkOpen = false)}
    onApply={applyBulk}
  />
{/if}

{#if compareOpen && localEntry && remoteEntry}
  <CompareDialog
    left={localRef(localEntry)}
    right={remoteRef(remoteEntry)}
    onClose={() => (compareOpen = false)}
  />
{/if}

{#if syncOpen && tab && local && remote}
  <SyncDialog
    sessionId={tab.sessionId}
    localRoot={local.path}
    remoteRoot={remote.path}
    onClose={() => (syncOpen = false)}
    onDone={afterSync}
  />
{/if}

{#if prompt}
  <div class="overlay" onclick={() => (prompt = null)}>
    <div class="dialog" onclick={(e) => e.stopPropagation()}>
      <div class="dialog-title">{prompt.title}</div>
      <label class="field">
        <span>{prompt.label}</span>
        <input
          bind:value={promptValue}
          autofocus
          onkeydown={(e) => e.key === "Enter" && submitPrompt()}
        />
      </label>
      {#if prompt.hint}
        <div class="hint">{prompt.hint}</div>
      {/if}
      <div class="foot">
        <button class="btn" onclick={() => (prompt = null)}>Отмена</button>
        <button class="btn primary" onclick={submitPrompt}>ОК</button>
      </div>
    </div>
  </div>
{/if}

{#if secret}
  <div class="overlay" onclick={() => (secret = null)}>
    <div class="dialog" onclick={(e) => e.stopPropagation()}>
      <div class="dialog-title">{secret.title}</div>
      <label class="field">
        <span>Пароль</span>
        <input
          type="password"
          bind:value={secretValue}
          autofocus
          onkeydown={(e) => e.key === "Enter" && submitSecret()}
        />
      </label>
      <div class="foot">
        <button class="btn" onclick={() => (secret = null)}>Отмена</button>
        <button class="btn primary" onclick={submitSecret}>Открыть</button>
      </div>
    </div>
  </div>
{/if}

{#if confirm}
  <div class="overlay" onclick={() => (confirm = null)}>
    <div class="dialog" onclick={(e) => e.stopPropagation()}>
      <div class="dialog-title">{confirm.title}</div>
      <div class="message">{confirm.message}</div>
      <div class="foot">
        <button class="btn" onclick={() => (confirm = null)}>Отмена</button>
        <button class="btn danger" onclick={submitConfirm}>Удалить</button>
      </div>
    </div>
  </div>
{/if}

{#if editor}
  <div class="overlay" onclick={() => (editor = null)}>
    <div class="viewer" onclick={(e) => e.stopPropagation()}>
      <div class="viewer-head">
        <span>{editor.entry.name}</span>
        {#if editor.inArchive}
          <span class="muted">из архива · только просмотр</span>
        {/if}
        <span class="grow"></span>
        {#if editorDirty}
          <span class="dirty">не сохранено</span>
        {/if}
        {#if editor.mode === "edit"}
          <button
            class="btn"
            title="Перенос строк"
            onclick={() => (wrap = !wrap)}
          >
            {wrap ? "Перенос вкл." : "Перенос выкл."}
          </button>
          <button
            class="btn primary"
            disabled={editorTruncated || !editorDirty}
            onclick={saveEditor}
          >
            Сохранить
          </button>
        {:else if !editor.inArchive}
          <button
            class="btn"
            onclick={() => {
              if (editor) editor.mode = "edit";
            }}
          >
            Изменить
          </button>
        {/if}
        <button class="btn" onclick={() => (editor = null)}>Закрыть</button>
      </div>
      {#if editor.mode === "edit"}
        <div class="edit-body">
          <div class="gutter" style:transform={`translateY(-${editorScroll}px)`}>
            {#each Array(editorLines) as _, index (index)}
              <div>{index + 1}</div>
            {/each}
          </div>
          <textarea
            bind:value={editor.text}
            class:wrap
            spellcheck="false"
            onscroll={(e) =>
              (editorScroll = (e.target as HTMLTextAreaElement).scrollTop)}
            onkeydown={(e) => {
              if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") {
                e.preventDefault();
                void saveEditor();
              }
            }}
          ></textarea>
        </div>
        {#if editorTruncated}
          <div class="warn">Файл больше 256 КБ — сохранение отключено.</div>
        {/if}
      {:else}
        <pre class="code" class:wrap>{@html highlighted || editor.text}</pre>
      {/if}
    </div>
  </div>
{/if}

{#if info}
  <div class="overlay" onclick={() => (info = null)}>
    <div class="dialog" onclick={(e) => e.stopPropagation()}>
      <div class="dialog-title">{info.title}</div>
      <pre class="info-text">{info.text}</pre>
      <div class="foot">
        <button class="btn primary" onclick={() => (info = null)}>ОК</button>
      </div>
    </div>
  </div>
{/if}

{#if createOpen}
  <div class="overlay" onclick={() => (createOpen = false)}>
    <div class="dialog" onclick={(e) => e.stopPropagation()}>
      <div class="dialog-title">Создать архив</div>
      <label class="field">
        <span>Имя</span>
        <input bind:value={createName} autofocus />
      </label>
      <label class="field">
        <span>Формат</span>
        <select
          bind:value={createFormat}
          onchange={() => (createName = replaceExtension(createName, createFormat))}
        >
          <option value="zip">ZIP (.zip)</option>
          <option value="tar.gz">TAR.GZ (.tar.gz)</option>
          <option value="tar.bz2">TAR.BZ2 (.tar.bz2)</option>
          <option value="tar.xz">TAR.XZ (.tar.xz)</option>
          <option value="tar.zst">TAR.ZST (.tar.zst)</option>
          <option value="7z">7Z (.7z)</option>
          <option value="tar">TAR (.tar)</option>
        </select>
      </label>
      <div class="foot">
        <button class="btn" onclick={() => (createOpen = false)}>Отмена</button>
        <button class="btn primary" onclick={createArchive}>Создать</button>
      </div>
    </div>
  </div>
{/if}

{#if findOpen}
  <div class="overlay" onclick={() => (findOpen = false)}>
    <div class="dialog wide" onclick={(e) => e.stopPropagation()}>
      <div class="dialog-title">Найти файлы</div>
      <div class="find-row">
        <label class="field">
          <span>Маска</span>
          <input bind:value={findMask} />
        </label>
        <label class="field">
          <span>Текст внутри (необязательно)</span>
          <input bind:value={findContent} />
        </label>
        <button class="btn primary" onclick={runFind}>Искать</button>
      </div>
      <div class="find-results">
        {#each findResults as found (found.path)}
          <div class="found">
            <span class="found-name">{found.name}</span>
            <span class="found-path">{found.path}</span>
            <span class="found-size">{found.isDir ? "" : formatBytes(found.size)}</span>
          </div>
        {:else}
          <div class="empty">Ничего не найдено</div>
        {/each}
      </div>
      <div class="foot">
        <button class="btn" onclick={() => (findOpen = false)}>Закрыть</button>
      </div>
    </div>
  </div>
{/if}

{#if busy || task}
  <div class="overlay">
    <div class="dialog small">
      <div class="busy-row">
        <span class="spinner"></span>
        {task?.label ?? busy}
      </div>
      {#if task}
        <div class="foot">
          <button class="btn" onclick={cancelTask}>Отмена</button>
        </div>
      {/if}
    </div>
  </div>
{/if}

{#if error}
  <div class="toast" onclick={() => (error = null)}>{error}</div>
{:else if notice}
  <div class="toast info" onclick={() => (notice = null)}>{notice}</div>
{/if}

<style>
  .browser {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 0;
  }

  .panes {
    flex: 1;
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 10px;
    min-height: 0;
    padding: 0 18px 10px;
  }

  .offline {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 12px;
    margin: 0 18px 10px;
    padding: 8px 12px;
    border: 1px solid rgba(248, 81, 73, 0.4);
    border-radius: var(--radius-sm);
    background: rgba(248, 81, 73, 0.08);
    color: var(--dim);
    font-size: 11.5px;
  }

  .transfer-wrap,
  .terminal-wrap {
    padding: 0 18px 14px;
  }

  .menu-backdrop {
    position: fixed;
    inset: 0;
    z-index: 40;
  }

  .context {
    position: fixed;
    z-index: 50;
    width: 220px;
    padding: 5px;
    background: var(--menu);
    border: 1px solid var(--border-strong);
    border-radius: 8px;
    box-shadow: 0 15px 40px rgba(0, 0, 0, 0.5);
  }

  .context button {
    display: block;
    width: 100%;
    padding: 7px 10px;
    border-radius: 5px;
    text-align: left;
    font-size: 12px;
  }

  .context button:hover {
    background: var(--selection);
  }

  .context .danger {
    color: var(--error);
  }

  .context .sep {
    height: 1px;
    margin: 4px 6px;
    background: var(--border);
  }

  .overlay {
    position: fixed;
    inset: 0;
    display: grid;
    place-items: center;
    background: rgba(0, 0, 0, 0.4);
    z-index: 60;
  }

  .dialog {
    width: 420px;
    padding: 16px 18px 12px;
    background: var(--menu);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.45);
  }

  .dialog.small {
    width: 320px;
  }

  .dialog.wide {
    width: 760px;
  }

  .dialog-title {
    margin-bottom: 12px;
    font-size: 13px;
    font-weight: 600;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 5px;
    margin-bottom: 10px;
  }

  .field span {
    font-size: 11px;
    color: var(--faint);
  }

  .field input,
  .field select {
    height: 32px;
    padding: 0 9px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--text);
    font-size: 12.5px;
    outline: none;
  }

  .field input:focus,
  .field select:focus {
    border-color: var(--accent);
  }

  .hint,
  .message {
    margin-top: 4px;
    color: var(--dim);
    font-size: 11.5px;
    line-height: 1.45;
  }

  .muted {
    margin-left: 8px;
    color: var(--faint);
    font-size: 10.5px;
    font-weight: 400;
  }

  .foot {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 12px;
  }

  .btn {
    padding: 6px 12px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--raised);
    font-size: 12px;
  }

  .btn:hover {
    background: var(--hover);
  }

  .btn.primary {
    background: var(--accent);
    border-color: transparent;
    color: #fff;
    font-weight: 600;
  }

  .btn.primary:hover {
    background: var(--accent-hover);
  }

  .btn.danger {
    color: var(--error);
    border-color: rgba(248, 81, 73, 0.4);
  }

  .viewer {
    width: min(920px, 88vw);
    height: min(640px, 82vh);
    display: flex;
    flex-direction: column;
    background: var(--menu);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
    overflow: hidden;
  }

  .viewer-head {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    border-bottom: 1px solid var(--border);
    font-size: 12.5px;
    font-weight: 600;
  }

  .viewer .grow {
    flex: 1;
  }

  .edit-body {
    flex: 1;
    min-height: 0;
    display: flex;
    background: var(--panel);
    overflow: hidden;
  }

  .gutter {
    flex: 0 0 44px;
    padding: 12px 6px 12px 0;
    overflow: hidden;
    text-align: right;
    color: var(--faint);
    font-family: var(--mono);
    font-size: 12px;
    line-height: 1.5;
    user-select: none;
    border-right: 1px solid var(--border);
  }

  .dirty {
    padding: 2px 7px;
    border-radius: 4px;
    background: rgba(210, 153, 34, 0.16);
    color: var(--warn);
    font-size: 10.5px;
    font-weight: 500;
  }

  .viewer textarea.wrap,
  .viewer pre.code :global(.hljs-keyword),
  .viewer pre.code :global(.hljs-selector-tag),
  .viewer pre.code :global(.hljs-built_in) {
    color: #c792ea;
  }

  .viewer pre.code :global(.hljs-string),
  .viewer pre.code :global(.hljs-attr) {
    color: #a5e075;
  }

  .viewer pre.code :global(.hljs-number),
  .viewer pre.code :global(.hljs-literal) {
    color: #f0c04a;
  }

  .viewer pre.code :global(.hljs-comment) {
    color: var(--faint);
    font-style: italic;
  }

  .viewer pre.code :global(.hljs-title),
  .viewer pre.code :global(.hljs-function) {
    color: #6cb6ff;
  }

  .viewer pre.wrap {
    white-space: pre-wrap;
    word-break: break-all;
  }

  .viewer textarea {
    flex: 1;
    min-width: 0;
    padding: 12px 14px;
    border: 0;
    outline: 0;
    resize: none;
    background: var(--panel);
    color: var(--text);
    font-family: var(--mono);
    font-size: 12px;
    line-height: 1.5;
    user-select: text;
  }

  .warn {
    padding: 6px 14px;
    border-top: 1px solid var(--border);
    color: var(--warn);
    font-size: 11px;
  }

  .viewer pre,
  .info-text {
    margin: 0;
    padding: 12px 14px;
    overflow: auto;
    font-family: var(--mono);
    font-size: 12px;
    line-height: 1.5;
    white-space: pre-wrap;
    user-select: text;
  }

  .viewer pre {
    flex: 1;
  }

  .info-text {
    max-height: 260px;
    background: var(--panel);
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
    word-break: break-all;
  }

  .find-row {
    display: grid;
    grid-template-columns: 180px 1fr auto;
    gap: 10px;
    align-items: end;
  }

  .find-results {
    height: 320px;
    margin-top: 2px;
    overflow: auto;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
  }

  .found {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px 10px;
    font-size: 11.5px;
  }

  .found:hover {
    background: var(--hover);
  }

  .found-name {
    width: 180px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .found-path {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--faint);
    font-family: var(--mono);
    font-size: 10.5px;
  }

  .found-size {
    width: 80px;
    text-align: right;
    color: var(--faint);
    font-family: var(--mono);
    font-size: 10.5px;
  }

  .empty {
    padding: 30px;
    text-align: center;
    color: var(--faint);
    font-size: 12px;
  }

  .busy-row {
    display: flex;
    align-items: center;
    gap: 12px;
    font-size: 12.5px;
  }

  .spinner {
    width: 16px;
    height: 16px;
    border-radius: 50%;
    border: 2px solid var(--border-strong);
    border-top-color: var(--accent);
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .toast.info {
    border-color: color-mix(in srgb, var(--accent) 55%, transparent);
    color: var(--text);
  }

  .toast {
    position: fixed;
    left: 18px;
    right: 18px;
    bottom: 18px;
    padding: 10px 13px;
    border-radius: var(--radius-sm);
    background: var(--menu);
    border: 1px solid rgba(248, 81, 73, 0.55);
    color: #ffb4ac;
    font-size: 12px;
    cursor: pointer;
    z-index: 70;
  }
</style>
