<script lang="ts">
  import { onMount } from "svelte";
  import { Channel } from "@tauri-apps/api/core";
  import ConnectionsPage from "./pages/ConnectionsPage.svelte";
  import BrowserPage from "./pages/BrowserPage.svelte";
  import TitleBar from "./lib/TitleBar.svelte";
  import { applyAppearance, setTheme } from "./lib/theme.svelte";
  import type { BrowserTab } from "./lib/browser";
  import {
    api,
    type AppInfo,
    type DirListing,
    type Server,
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
  let transfers = $state<TransferEvent[]>([]);

  let error = $state<string | null>(null);
  let notice = $state<string | null>(null);

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

      volumes = await api.volumes().catch(() => []);
      const home = await api.homeLocal();
      await loadLocal(home);
    } catch (e) {
      error = `Инициализация: ${e}`;
    }
  });

  async function loadLocal(path: string) {
    if (!path.trim()) return;
    try {
      local = await api.listLocal(path);
    } catch (e) {
      error = `Локально: ${e}`;
    }
  }

  async function loadRemote(tabId: string, path: string) {
    const tab = tabs.find((item) => item.id === tabId);
    if (!tab || !path.trim()) return;
    try {
      tab.listing = await api.listRemote(tab.sessionId, path);
    } catch (e) {
      error = `Сервер: ${e}`;
    }
  }

  function addTab(server: Server, sessionId: string) {
    const existing = tabs.find((item) => item.id === server.id);
    if (existing) {
      existing.sessionId = sessionId;
      existing.listing = null;
    } else {
      tabs.push({
        id: server.id,
        label: server.name || server.host,
        server,
        sessionId,
        listing: null,
      });
    }
    activeTabId = server.id;
    showConnections = false;
  }

  async function connect(server: Server, password: string | null = null) {
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
      addTab(server, result.sessionId);
      await loadRemote(server.id, result.startPath);
      if (result.warnings.length) notice = result.warnings.join(" · ");
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

  async function download(remotePath: string, targetDir: string) {
    const tab = tabs.find((item) => item.id === activeTabId);
    if (!tab) return;

    const channel = new Channel<TransferEvent>();
    channel.onmessage = (event) => {
      const index = transfers.findIndex((item) => item.id === event.id);
      if (index >= 0) transfers[index] = event;
      else transfers = [event, ...transfers];
    };

    try {
      await api.download(tab.sessionId, remotePath, targetDir, channel);
      await loadLocal(targetDir);
    } catch (e) {
      error = `Скачивание: ${e}`;
    }
  }
</script>

<div class="app">
  <TitleBar />

  {#if showConnections || tabs.length === 0}
    <ConnectionsPage
      {book}
      openTabs={tabs}
      onConnect={(server) => connect(server)}
      onOpenTab={(id) => {
        activeTabId = id;
        showConnections = false;
      }}
    />
  {:else}
    <BrowserPage
      {tabs}
      {activeTabId}
      {local}
      {volumes}
      {transfers}
      onSelectTab={(id) => (activeTabId = id)}
      onAddTab={() => (showConnections = true)}
      onBack={() => (showConnections = true)}
      onLocalPath={loadLocal}
      onRemotePath={loadRemote}
      onDownload={download}
    />
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
