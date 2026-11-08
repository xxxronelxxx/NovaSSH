<script lang="ts">
  import { onMount } from "svelte";
  import { Channel } from "@tauri-apps/api/core";
  import ConnectionsPage from "./pages/ConnectionsPage.svelte";
  import BrowserPage from "./pages/BrowserPage.svelte";
  import SettingsPage from "./pages/SettingsPage.svelte";
  import TitleBar from "./lib/TitleBar.svelte";
  import { applyAppearance, setTheme } from "./lib/theme.svelte";
  import type { BrowserTab } from "./lib/browser";
  import {
    api,
    type AppInfo,
    type DirListing,
    type OpenSession,
    type Server,
    type SessionState,
    type ServerBook,
    type Settings,
    type TransferEvent,
    type Volume,
  } from "./lib/api";

  let appInfo = $state<AppInfo | null>(null);
  let book = $state<ServerBook | null>(null);
  let settings = $state<Settings | null>(null);
  let volumes = $state<Volume[]>([]);

  let local = $state<DirListing | null>(null);
  let tabs = $state<BrowserTab[]>([]);
  let activeTabId = $state("");
  let showConnections = $state(true);
  let showSettings = $state(false);
  let transfers = $state<TransferEvent[]>([]);

  let error = $state<string | null>(null);
  let notice = $state<string | null>(null);

  let restoreList = $state<OpenSession[]>([]);
  let sessionState = $state<SessionState | null>(null);
  let restoreHidden = $state(false);

  let connecting = $state<{ server: Server; stage: number } | null>(null);
  let passwordPrompt = $state<Server | null>(null);
  let passwordError = $state<string | null>(null);
  let passwordInput = $state("");

  const stages = [
    "Ищу сервер…",
    "Соединяюсь с сервером…",
    "Аутентификация…",
    "Открываю SFTP-сессию…",
  ];

  if (typeof window !== "undefined") {
    window.addEventListener("error", (event) => {
      void api
        .uiLog(`ERROR ${event.message} @ ${event.filename}:${event.lineno}`)
        .catch(() => {});
    });
    window.addEventListener("unhandledrejection", (event) => {
      void api
        .uiLog(`REJECTION ${String(event.reason)}`)
        .catch(() => {});
    });
  }

  onMount(async () => {
    try {
      appInfo = await api.initApp();
      await api.ensureDeviceVault().catch(() => false);
      book = await api.listServers();
      settings = await api.loadSettings().catch(() => null);

      const theme = settings?.window?.theme ?? "dark";
      setTheme(
        theme === "light" ? "light" : theme === "system" ? "system" : "dark",
      );
      applyAppearance(settings?.appearance);
      void api.setSolidMode(settings?.window?.solidMode ?? false).catch(() => {});

      void api.clearAllTmp().catch(() => {});
      volumes = await api.volumes().catch(() => []);

      const state = await api.loadSessionState().catch(() => null);
      sessionState = state;
      const ids = new Set((book?.servers ?? []).map((server) => server.id));
      restoreList = (state?.openSessions ?? []).filter((item) =>
        ids.has(item.serverId),
      );
      const home = await api.homeLocal();
      const recent = state?.recentLocal?.[0] ?? "";
      await loadLocal(recent || home);
      if (!local) await loadLocal(home);
    } catch (e) {
      error = `Инициализация: ${e}`;
    }
  });

  async function reloadBook() {
    book = await api.listServers();
  }

  const listingCache = new Map<string, DirListing>();

  function rememberListing(key: string, listing: DirListing) {
    listingCache.set(key, listing);
    if (listingCache.size > 150) {
      const first = listingCache.keys().next().value;
      if (first) listingCache.delete(first);
    }
  }

  function localCacheKey(path: string, hidden: boolean) {
    return `local|${hidden ? 1 : 0}|${path.toLowerCase()}`;
  }

  function remoteCacheKey(
    sessionId: string,
    path: string,
    hidden: boolean,
  ) {
    return `remote|${sessionId}|${hidden ? 1 : 0}|${path}`;
  }

  async function loadLocal(
    path: string,
    showHidden?: boolean,
    tabId?: string,
  ) {
    if (!path.trim()) return;
    const hidden = showHidden ?? settings?.panels?.showHidden ?? true;
    const cacheKey = localCacheKey(path, hidden);
    const cached = listingCache.get(cacheKey);
    try {
      if (cached) {
        if (tabId) {
          const tab = tabs.find((item) => item.id === tabId);
          if (tab) tab.local = cached;
          if (tabId === activeTabId) local = cached;
        } else {
          local = cached;
        }
      }
      const listing = await api.listLocal(path, hidden);
      rememberListing(cacheKey, listing);
      if (tabId) {
        const tab = tabs.find((item) => item.id === tabId);
        if (tab) tab.local = listing;
        if (tabId === activeTabId) local = listing;
      } else {
        local = listing;
      }
      schedulePersist();
    } catch (e) {
      error = `Локально: ${e}`;
      if (tabId) return;
      const home = await api.homeLocal().catch(() => "");
      if (home && home !== path) {
        const listing = await api.listLocal(home).catch(() => null);
        if (listing) local = listing;
      }
    }
  }

  async function loadRemote(
    tabId: string,
    path: string,
    showHidden?: boolean,
  ) {
    const tab = tabs.find((item) => item.id === tabId);
    if (!tab || !path.trim()) return;
    const hidden = showHidden ?? settings?.panels?.showHidden ?? true;
    const cacheKey = remoteCacheKey(tab.sessionId, path, hidden);
    const cached = listingCache.get(cacheKey);
    if (cached) tab.listing = cached;
    try {
      const listing = await api.listRemote(tab.sessionId, path, hidden);
      rememberListing(cacheKey, listing);
      tab.listing = listing;
      tab.disconnected = false;
      tab.disconnectReason = undefined;
      schedulePersist();
    } catch (e) {
      tab.disconnected = true;
      tab.disconnectReason = String(e);
      error = `Сервер: ${e}`;
    }
  }

  let tabSeq = 0;

  function addTab(server: Server, sessionId: string): string {
    const id = `tab_${server.id}_${Date.now()}_${tabSeq++}`;
    tabs.push({
      id,
      label: server.name || server.host,
      server,
      sessionId,
      listing: null,
      local: local ? { ...local } : null,
      localSel: [],
      remoteSel: [],
      archive: null,
    });
    activeTabId = id;
    showConnections = false;
    showSettings = false;
    return id;
  }

  let persistTimer: ReturnType<typeof setTimeout> | null = null;

  function schedulePersist() {
    if (persistTimer) clearTimeout(persistTimer);
    persistTimer = setTimeout(() => {
      persistTimer = null;
      void persistSessions();
    }, 600);
  }

  async function persistSessions() {
    if (!tabs.length) {
      await api.saveOpenSessions([]).catch(() => {});
      return;
    }
    await api
      .saveOpenSessions(
        tabs.map((tab) => ({
          serverId: tab.server.id,
          name: tab.label,
          localPath: tab.local?.path ?? "",
          remotePath: tab.listing?.path ?? "",
        })),
      )
      .catch(() => {});
    // Remember each server's last folders so reopening a tab returns there.
    for (const tab of tabs) {
      if (!tab.listing?.path && !tab.local?.path) continue;
      updateSessionRecord(
        tab.server.id,
        tab.listing?.path ?? "",
        tab.local?.path ?? "",
      );
      await api
        .rememberSession(
          tab.server.id,
          tab.listing?.path ?? "",
          tab.local?.path ?? "",
        )
        .catch(() => {});
    }
  }

  async function loadUname(tabId: string, sessionId: string) {
    const output =
      (await api
        .execRemote(sessionId, "uname -a")
        .catch(() => "")) ?? "";
    const tab = tabs.find((item) => item.id === tabId);
    if (tab) tab.uname = output.trim();
  }

  async function connect(
    server: Server,
    password: string | null = null,
    restore: OpenSession | null = null,
  ) {
    error = null;
    notice = null;
    passwordPrompt = null;
    passwordError = null;
    connecting = { server, stage: 0 };

    const poll = setInterval(async () => {
      try {
        if (connecting) connecting.stage = await api.connectStage();
      } catch {
        // best-effort polling
      }
    }, 150);

    try {
      const result = await api.connectServer(server.id, password);
      const tabId = addTab(server, result.sessionId);
      void loadUname(tabId, result.sessionId);
      const remembered =
        sessionState?.servers?.find((record) => record.serverId === server.id)
          ?.localPath ?? "";
      const localPath =
        restore?.localPath ||
        remembered ||
        sessionState?.recentLocal?.[0] ||
        local?.path ||
        "";
      if (localPath) await loadLocal(localPath, undefined, tabId);
      if (restore) {
        await loadRemote(
          tabId,
          restore.remotePath || result.startPath,
        );
        await api
          .rememberSession(
            server.id,
            restore.remotePath || result.startPath,
            localPath,
          )
          .catch(() => {});
      } else {
        await loadRemote(tabId, result.startPath);
      }
      if (result.warnings.length) notice = result.warnings.join(" · ");
      await persistSessions();
    } catch (e) {
      const message = String(e);
      if (/отменено|cancelled/i.test(message)) {
        notice = "Соединение отменено";
      } else if (/password|пароль|auth|аутентиф/i.test(message)) {
        passwordPrompt = server;
        passwordError = message;
        passwordInput = "";
      } else {
        error = message;
      }
    } finally {
      clearInterval(poll);
      connecting = null;
    }
  }

  async function cancelConnect() {
    if (!connecting) return;
    await api.cancelConnect(connecting.server.id).catch(() => {});
  }

  function submitPassword() {
    const server = passwordPrompt;
    if (!server) return;
    const value = passwordInput;
    connect(server, value.trim() ? value : null);
  }

  async function reconnectTab(id: string) {
    const tab = tabs.find((item) => item.id === id);
    if (!tab) return;
    await api.disconnect(tab.sessionId).catch(() => {});
    connecting = { server: tab.server, stage: 0 };
    try {
      const result = await api.connectServer(tab.server.id, null);
      tab.sessionId = result.sessionId;
      tab.disconnected = false;
      tab.disconnectReason = undefined;
      void loadUname(id, result.sessionId);
      await loadRemote(id, tab.listing?.path || result.startPath);
    } catch (e) {
      const message = String(e);
      if (/password|пароль|auth|аутентиф/i.test(message)) {
        passwordPrompt = tab.server;
        passwordError = message;
        passwordInput = "";
      } else {
        error = `Переподключение: ${message}`;
      }
    } finally {
      connecting = null;
    }
  }

  function updateSessionRecord(
    serverId: string,
    remotePath: string,
    localPath: string,
  ) {
    if (!sessionState) return;
    const record = sessionState.servers.find(
      (item) => item.serverId === serverId,
    );
    if (record) {
      record.path = remotePath;
      record.localPath = localPath;
    } else {
      sessionState.servers.push({
        serverId,
        path: remotePath,
        localPath,
      });
    }
  }

  async function closeTab(id: string) {
    const tab = tabs.find((item) => item.id === id);
    if (tab) {
      const remotePath = tab.listing?.path ?? "";
      const localPath = tab.local?.path ?? "";
      updateSessionRecord(tab.server.id, remotePath, localPath);
      await api
        .rememberSession(tab.server.id, remotePath, localPath)
        .catch(() => {});
      await api.disconnect(tab.sessionId).catch(() => {});
    }
    tabs = tabs.filter((item) => item.id !== id);
    if (activeTabId === id) {
      activeTabId = tabs[0]?.id ?? "";
      if (!tabs.length) showConnections = true;
    }
    if (!tabs.some((item) => item.server.id === tab?.server.id)) {
      void api.clearServerTmp(tab?.label ?? "").catch(() => {});
    }
    await persistSessions();
  }

  async function restoreSessions() {
    const list = restoreList;
    restoreHidden = true;
    restoreList = [];
    for (const item of list) {
      const server = (book?.servers ?? []).find((s) => s.id === item.serverId);
      if (!server) continue;
      await connect(server, null, item);
    }
  }

  interface TransferJob {
    id: string;
    tabId: string;
    sessionId: string;
    direction: "upload" | "download";
    sourcePath: string;
    targetDir: string;
    targetName: string | null;
    background: boolean;
  }

  let queue: TransferJob[] = [];
  let activeTransfers = 0;
  let conflictAll: "overwrite" | "skip" | null = null;
  let foregroundIds = new Set<string>();
  let foreground = $state<{ total: number; done: number } | null>(null);
  let conflict = $state<{
    name: string;
    resolve: (choice: "overwrite" | "skip" | "cancel") => void;
  } | null>(null);

  function baseName(path: string): string {
    const parts = path.split(/[\\/]/).filter(Boolean);
    return parts[parts.length - 1] ?? path;
  }

  function askConflict(name: string): Promise<"overwrite" | "skip" | "cancel"> {
    return new Promise((resolve) => {
      conflict = { name, resolve };
    });
  }

  function resolveConflict(
    choice: "overwrite" | "skip" | "cancel",
    applyAll = false,
  ) {
    const current = conflict;
    if (!current) return;
    if (applyAll && (choice === "overwrite" || choice === "skip")) {
      conflictAll = choice;
    }
    conflict = null;
    current.resolve(choice);
  }

  function cancelForeground() {
    for (const id of foregroundIds) {
      void api.cancelTransfer(id).catch(() => {});
    }
    const remaining: TransferJob[] = [];
    for (const job of queue) {
      if (foregroundIds.has(job.id)) {
        foregroundIds.delete(job.id);
        if (foreground) foreground.done += 1;
      } else {
        remaining.push(job);
      }
    }
    queue = remaining;
    if (foreground && foreground.done >= foreground.total) foreground = null;
  }

  function transfer(
    direction: "upload" | "download",
    sourcePath: string,
    targetDir: string,
    targetName: string | null = null,
    background = false,
  ) {
    const tab = tabs.find((item) => item.id === activeTabId);
    if (!tab) return;
    const id = `job_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    if (!background) {
      if (!foreground) foreground = { total: 0, done: 0 };
      foreground.total += 1;
      foregroundIds.add(id);
    }
    queue.push({
      id,
      tabId: tab.id,
      sessionId: tab.sessionId,
      direction,
      sourcePath,
      targetDir,
      targetName,
      background,
    });
    void pumpTransfers();
  }

  function finishJob(job: TransferJob) {
    activeTransfers -= 1;
    if (foregroundIds.has(job.id)) {
      foregroundIds.delete(job.id);
      if (foreground) {
        foreground.done += 1;
        if (foreground.done >= foreground.total) {
          setTimeout(() => {
            if (foreground && foreground.done >= foreground.total) {
              foreground = null;
            }
          }, 700);
        }
      }
    }
    if (activeTransfers === 0 && queue.length === 0) conflictAll = null;
    void pumpTransfers();
  }

  async function pumpTransfers() {
    const limit = Math.max(1, Math.min(8, settings?.transfer.concurrency ?? 3));
    while (activeTransfers < limit && queue.length) {
      const job = queue.shift();
      if (!job) break;
      activeTransfers += 1;
      void runTransfer(job).finally(() => finishJob(job));
    }
  }

  async function existingTarget(
    job: TransferJob,
    name: string,
  ): Promise<number | null> {
    try {
      if (job.direction === "upload") {
        const listing = await api.listRemote(
          job.sessionId,
          job.targetDir,
          settings?.panels?.showHidden ?? true,
        );
        const found = listing.entries.find((entry) => entry.name === name);
        return found ? found.size : null;
      }
      const listing = await api.listLocal(job.targetDir);
      const found = listing.entries.find((entry) => entry.name === name);
      return found ? found.size : null;
    } catch {
      return null;
    }
  }

  async function runTransfer(job: TransferJob) {
    const name = baseName(job.sourcePath);
    const exists = await existingTarget(job, name);
    let resumeFrom = 0;
    let targetName: string | null = job.targetName;
    if (exists != null && !targetName) {
      const policy = conflictAll ?? settings?.transfer.conflictPolicy ?? "ask";
      if (policy === "skip") return;
      if (policy === "ask") {
        const choice = await askConflict(name);
        const applied = conflictAll ?? choice;
        if (applied === "skip") return;
        if (applied === "cancel") return;
      }
      if (policy === "rename") {
        const dot = name.lastIndexOf(".");
        const stem = dot > 0 ? name.slice(0, dot) : name;
        const ext = dot > 0 ? name.slice(dot) : "";
        for (let index = 2; index < 100; index += 1) {
          const candidate = `${stem} (${index})${ext}`;
          if ((await existingTarget(job, candidate)) == null) {
            targetName = candidate;
            break;
          }
        }
        if (!targetName) targetName = `${stem} (${Date.now()})${ext}`;
      } else if (settings?.transfer.resume) {
        resumeFrom = exists;
      }
    }

    const channel = new Channel<TransferEvent>();
    channel.onmessage = (event) => trackTransfer(event);

    const limit = settings?.transfer.bandwidthLimitKibps ?? 0;
    const verify = (settings?.transfer.verifyChecksum ?? "off") !== "off";

    try {
      await api.transferFile(
        job.sessionId,
        job.direction,
        job.sourcePath,
        job.targetDir,
        resumeFrom,
        limit,
        verify,
        targetName,
        channel,
      );
      if (job.direction === "download") {
        const tab = tabs.find((item) => item.id === job.tabId);
        if (tab?.local?.path === job.targetDir) {
          await loadLocal(job.targetDir, undefined, job.tabId);
        }
      } else {
        const tab = tabs.find((item) => item.id === job.tabId);
        if (tab?.listing?.path === job.targetDir) {
          await loadRemote(job.tabId, job.targetDir);
        }
      }
    } catch (e) {
      error = `${job.direction === "download" ? "Скачивание" : "Загрузка"}: ${e}`;
    }
  }

  function cancelConflict() {
    resolveConflict("cancel");
    queue = [];
  }

  function trackTransfer(event: TransferEvent) {
    const index = transfers.findIndex((item) => item.id === event.id);
    if (index >= 0) transfers[index] = event;
    else transfers = [event, ...transfers];
    if (
      event.state === "done" ||
      event.state === "failed" ||
      event.state === "cancelled"
    ) {
      const id = event.id;
      setTimeout(() => {
        transfers = transfers.filter((item) => item.id !== id);
      }, 3000);
    }
  }

  async function cancelTransfer(id: string) {
    // A archиве job and a regular transfer share the panel; both calls are
    // harmless when the id belongs to the other kind.
    await api.cancelTransfer(id).catch(() => {});
    await api.cancelArchiveJob(id).catch(() => {});
  }

  async function toggleAppTheme() {
    const next =
      document.documentElement.dataset.theme === "dark" ? "light" : "dark";
    setTheme(next);
    if (!settings) return;
    settings = {
      ...settings,
      window: { ...settings.window, theme: next },
    };
    await api.saveSettings(settings).catch((e) => {
      error = `Тема: ${e}`;
    });
  }

  async function saveSettings(next: Settings) {
    await api.saveSettings(next);
    settings = await api.loadSettings();
    const theme = settings?.window?.theme ?? "dark";
    setTheme(
      theme === "light" ? "light" : theme === "system" ? "system" : "dark",
    );
    applyAppearance(settings?.appearance);
    void api.setSolidMode(settings?.window?.solidMode ?? false).catch(() => {});
    const activeTab = tabs.find((item) => item.id === activeTabId);
    if (activeTab?.local?.path) {
      await loadLocal(activeTab.local.path, undefined, activeTab.id);
    } else if (local) {
      await loadLocal(local.path);
    }
    if (tabs.length) {
      const tab = tabs.find((item) => item.id === activeTabId);
      if (tab?.listing) await loadRemote(tab.id, tab.listing.path);
    }
  }
</script>

<div class="app">
  <TitleBar onToggleTheme={toggleAppTheme} />

  {#if showSettings && settings}
    <SettingsPage
      {settings}
      onClose={() => (showSettings = false)}
      onSave={saveSettings}
      onImported={async () => {
        book = await api.listServers();
        settings = await api.loadSettings();
        const theme = settings?.window?.theme ?? "dark";
        setTheme(
          theme === "light" ? "light" : theme === "system" ? "system" : "dark",
        );
        applyAppearance(settings?.appearance);
        if (local) await loadLocal(local.path);
      }}
    />
  {:else if showConnections || tabs.length === 0}
    <ConnectionsPage
      {book}
      openTabs={tabs}
      restore={restoreHidden ? [] : restoreList}
      onRestore={restoreSessions}
      onHideRestore={() => {
        restoreHidden = true;
        restoreList = [];
      }}
      onConnect={(server) => connect(server)}
      onOpenTab={(id) => {
        activeTabId = id;
        showConnections = false;
      }}
      onBookChanged={reloadBook}
      onSettings={() => (showSettings = true)}
    />
  {:else}
    <BrowserPage
      {tabs}
      {activeTabId}
      local={tabs.find((item) => item.id === activeTabId)?.local ?? local}
      {settings}
      {volumes}
      {transfers}
      onSelectTab={(id) => (activeTabId = id)}
      onCloseTab={closeTab}
      onSwapTabs={(fromId, toId) => {
        const from = tabs.findIndex((tab) => tab.id === fromId);
        const to = tabs.findIndex((tab) => tab.id === toId);
        if (from < 0 || to < 0 || from === to) return;
        [tabs[from], tabs[to]] = [tabs[to], tabs[from]];
        tabs = [...tabs];
      }}
      onReorderTab={(fromId, toId) => {
        const from = tabs.findIndex((tab) => tab.id === fromId);
        const to = tabs.findIndex((tab) => tab.id === toId);
        if (from < 0 || to < 0 || from === to) return;
        const [moved] = tabs.splice(from, 1);
        tabs.splice(to, 0, moved);
        tabs = [...tabs];
      }}
      onAddTab={() => (showConnections = true)}
      onBack={() => {
        showConnections = true;
        void persistSessions();
      }}
      onLocalPath={(path, showHidden) =>
        loadLocal(path, showHidden, activeTabId)}
      onRemotePath={loadRemote}
      onReconnect={reconnectTab}
      onTransfer={transfer}
      onCancelTransfer={cancelTransfer}
      onTrackTransfer={trackTransfer}
      onSettings={() => (showSettings = true)}
    />
  {/if}

  {#if foreground}
    <div class="overlay">
      <div class="dialog">
        <div class="dialog-title">Передача файлов</div>
        <div class="foreground-line">
          Выполнено {foreground.done} из {foreground.total}
        </div>
        <div class="foreground-bar">
          <div
            class="foreground-fill"
            style:width={`${Math.round((foreground.done / Math.max(1, foreground.total)) * 100)}%`}
          ></div>
        </div>
        <div class="dialog-foot">
          <button class="btn" onclick={cancelForeground}>Отмена всех</button>
        </div>
      </div>
    </div>
  {/if}

  {#if conflict}
    <div class="overlay">
      <div class="dialog">
        <div class="dialog-title">Файл уже существует</div>
        <div class="conflict-name">{conflict.name}</div>
        <div class="dialog-foot">
          <button class="btn" onclick={() => resolveConflict("cancel")}>
            Отмена
          </button>
          <button class="btn" onclick={() => resolveConflict("skip")}>
            Пропустить
          </button>
          <button class="btn" onclick={() => resolveConflict("skip", true)}>
            Пропустить все
          </button>
          <button class="btn" onclick={() => resolveConflict("overwrite", true)}>
            Перезаписать все
          </button>
          <button class="btn primary" onclick={() => resolveConflict("overwrite")}>
            Перезаписать
          </button>
        </div>
      </div>
    </div>
  {/if}

  {#if connecting}
    <div class="overlay">
      <div class="dialog">
        <div class="dialog-title">
          <span class="key">🔑</span>
          {connecting.server.name || connecting.server.host}
        </div>
        <div class="stages">
          {#each stages as label, index}
            <div
              class="stage"
              class:done={connecting.stage > index + 1 || connecting.stage >= 5}
              class:active={connecting.stage === index + 1}
            >
              <span class="mark"></span>
              {label}
            </div>
          {/each}
        </div>
        <div class="dialog-foot">
          <span class="addr">
            {connecting.server.user}@{connecting.server.host}:{connecting.server.port}
          </span>
          <button class="btn" onclick={cancelConnect}>Отмена</button>
        </div>
      </div>
    </div>
  {/if}

  {#if passwordPrompt}
    <div class="overlay">
      <div class="dialog">
        <div class="dialog-title">
          Пароль для {passwordPrompt.name || passwordPrompt.host}
        </div>
        <input
          class="pwd"
          type="password"
          autofocus
          bind:value={passwordInput}
          placeholder="Пароль"
          onkeydown={(e) => e.key === "Enter" && submitPassword()}
        />
        {#if passwordError}
          <div class="pwd-error">{passwordError}</div>
        {/if}
        <div class="dialog-foot end">
          <button
            class="btn"
            onclick={() => {
              passwordPrompt = null;
              passwordError = null;
            }}
          >
            Отмена
          </button>
          <button class="btn primary" onclick={submitPassword}>Подключиться</button>
        </div>
      </div>
    </div>
  {/if}

  {#if notice}
    <div class="toast info" onclick={() => (notice = null)}>{notice}</div>
  {/if}

  {#if error}
    <div class="toast error" onclick={() => (error = null)}>{error}</div>
  {/if}
</div>

<style>
  .app {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: var(--window);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
    overflow: hidden;
  }

  .overlay {
    position: fixed;
    inset: 0;
    display: grid;
    place-items: center;
    background: rgba(0, 0, 0, 0.35);
    z-index: 20;
  }

  .dialog {
    width: 420px;
    padding: 18px 20px 14px;
    background: var(--menu);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.45);
  }

  .dialog-title {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 14px;
    font-size: 13px;
    font-weight: 600;
  }

  .key {
    font-size: 14px;
  }

  .stages {
    display: flex;
    flex-direction: column;
    gap: 7px;
    padding: 2px 0 14px;
  }

  .stage {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: 12.5px;
    color: var(--faint);
  }

  .mark {
    width: 14px;
    height: 14px;
    border-radius: 50%;
    border: 1px solid var(--border-strong);
  }

  .stage.done {
    color: var(--success);
  }

  .stage.done .mark {
    background: var(--success);
    border-color: var(--success);
  }

  .stage.active {
    color: var(--text);
    font-weight: 600;
  }

  .stage.active .mark {
    border-color: var(--accent);
    border-top-color: transparent;
    animation: spin 0.9s linear infinite;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .foreground-line {
    margin-bottom: 8px;
    color: var(--dim);
    font-size: 12px;
  }

  .foreground-bar {
    height: 6px;
    overflow: hidden;
    border-radius: 3px;
    background: var(--panel);
    border: 1px solid var(--border);
  }

  .foreground-fill {
    height: 100%;
    background: var(--accent);
    transition: width 0.18s linear;
  }

  .conflict-name {
    margin-bottom: 4px;
    font-family: var(--mono);
    font-size: 12px;
    word-break: break-all;
  }

  .dialog-foot {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-top: 10px;
    border-top: 1px solid var(--border);
  }

  .dialog-foot.end {
    justify-content: flex-end;
    gap: 8px;
    border-top: 0;
  }

  .addr {
    font-family: var(--mono);
    font-size: 10.5px;
    color: var(--faint);
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

  .pwd {
    width: 100%;
    padding: 8px 10px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    outline: none;
    font-size: 12.5px;
  }

  .pwd:focus {
    border-color: var(--accent);
  }

  .pwd-error {
    margin-top: 8px;
    color: var(--error);
    font-size: 11.5px;
  }

  .toast {
    position: fixed;
    left: 18px;
    right: 18px;
    bottom: 18px;
    padding: 10px 13px;
    border-radius: var(--radius-sm);
    background: var(--menu);
    border: 1px solid var(--border-strong);
    font-size: 12px;
    cursor: pointer;
    z-index: 30;
  }

  .toast.error {
    border-color: rgba(248, 81, 73, 0.55);
    color: #ffb4ac;
  }

  .toast.info {
    border-color: rgba(76, 141, 255, 0.45);
  }
</style>
