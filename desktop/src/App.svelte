<script lang="ts">
  import { onMount } from "svelte";
  import { Channel } from "@tauri-apps/api/core";
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import Pane from "./lib/Pane.svelte";
  import {
    api,
    formatBytes,
    type AppInfo,
    type ConnectResult,
    type DirListing,
    type Entry,
    type Server,
    type ServerBook,
    type TransferEvent,
  } from "./lib/api";

  const win = getCurrentWindow();

  let appInfo = $state<AppInfo | null>(null);
  let book = $state<ServerBook | null>(null);
  let server = $state<Server | null>(null);
  let password = $state("");
  let connecting = $state(false);
  let stage = $state(0);
  let sessionId = $state<string | null>(null);
  let error = $state<string | null>(null);
  let notice = $state<string | null>(null);

  let local = $state<DirListing | null>(null);
  let remote = $state<DirListing | null>(null);
  let localSel = $state<string | null>(null);
  let remoteSel = $state<string | null>(null);
  let transfer = $state<TransferEvent | null>(null);

  const stages = [
    "Поиск сервера",
    "Соединение",
    "Аутентификация",
    "Открываю SFTP",
  ];

  onMount(async () => {
    try {
      appInfo = await api.initApp();
      await api.ensureDeviceVault().catch(() => false);
      book = await api.listServers();
      server = book.servers[0] ?? null;
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
      localSel = null;
    } catch (e) {
      error = `Локально: ${e}`;
    }
  }

  async function loadRemote(path: string) {
    const sid = sessionId;
    if (!sid || !path.trim()) return;
    try {
      remote = await api.listRemote(sid, path);
      remoteSel = null;
    } catch (e) {
      error = `Сервер: ${e}`;
    }
  }

  async function connect() {
    if (!server) return;
    error = null;
    notice = null;
    connecting = true;
    stage = 0;
    const poll = setInterval(async () => {
      try {
        stage = await api.connectStage();
      } catch {
        // polling is best-effort
      }
    }, 150);

    try {
      const result: ConnectResult = await api.connectServer(
        server.id,
        password.trim() || null,
      );
      sessionId = result.sessionId;
      if (result.warnings.length) notice = result.warnings.join(" · ");
      await loadRemote(result.startPath);
    } catch (e) {
      error = String(e);
    } finally {
      clearInterval(poll);
      connecting = false;
      stage = 0;
    }
  }

  async function cancelConnect() {
    if (!server) return;
    await api.cancelConnect(server.id).catch(() => {});
  }

  async function disconnect() {
    const sid = sessionId;
    if (!sid) return;
    sessionId = null;
    remote = null;
    remoteSel = null;
    await api.disconnect(sid).catch(() => {});
  }

  async function downloadSelected() {
    const sid = sessionId;
    const entry = (remote?.entries ?? []).find((e) => e.path === remoteSel);
    if (!sid || !entry || entry.kind === "dir" || !local) return;

    const channel = new Channel<TransferEvent>();
    channel.onmessage = (event) => {
      transfer = event;
    };
    try {
      await api.download(sid, entry.path, local.path, channel);
      await loadLocal(local.path);
    } catch (e) {
      error = `Скачивание: ${e}`;
    }
  }

  function selectLocal(entry: Entry) {
    localSel = entry.path;
  }

  function selectRemote(entry: Entry) {
    remoteSel = entry.path;
  }

  function openLocal(entry: Entry) {
    if (entry.kind === "dir") loadLocal(entry.path);
  }

  function openRemote(entry: Entry) {
    if (entry.kind === "dir") loadRemote(entry.path);
  }

  function upLocal() {
    if (local?.parent) loadLocal(local.parent);
  }

  function upRemote() {
    if (remote?.parent) loadRemote(remote.parent);
  }

  function percent(): number {
    if (!transfer || !transfer.total) return 0;
    return Math.min(100, (transfer.done / transfer.total) * 100);
  }

  const canDownload = $derived(
    !!sessionId &&
      !!local &&
      (remote?.entries ?? []).some(
        (e) => e.path === remoteSel && e.kind !== "dir",
      ),
  );
</script>

<div class="shell">
  <header class="titlebar" data-tauri-drag-region>
    <div class="brand" data-tauri-drag-region>
      <span class="logo">N</span>
      <span class="name">NovaSSH</span>
      <span class="ver">{appInfo?.version ?? ""}</span>
    </div>
    <div class="grow" data-tauri-drag-region></div>
    <div class="win-actions">
      <button title="Свернуть" onclick={() => win.minimize()}>–</button>
      <button title="Развернуть" onclick={() => win.toggleMaximize()}>□</button>
      <button class="close" title="Закрыть" onclick={() => win.close()}>✕</button>
    </div>
  </header>

  <div class="body">
    <aside class="sidebar">
      <div class="side-title">Серверы</div>
      <div class="servers">
        {#each book?.servers ?? [] as item (item.id)}
          <button
            class="server"
            class:active={server?.id === item.id}
            onclick={() => (server = item)}
          >
            <span class="s-name">{item.name || item.host}</span>
            <span class="s-host">{item.user}@{item.host}:{item.port}</span>
          </button>
        {:else}
          <div class="empty">
            Профиль пуст.<br />
            <span class="mono">{appInfo?.dataDir ?? "…"}</span>
          </div>
        {/each}
      </div>

      <div class="connect">
        {#if server?.auth.type === "password"}
          <input
            type="password"
            placeholder="Пароль (если не сохранён)"
            bind:value={password}
            onkeydown={(e) => e.key === "Enter" && connect()}
          />
        {/if}

        {#if connecting}
          <div class="stages">
            {#each stages as label, i}
              <div
                class="stage"
                class:done={stage > i + 1 || stage >= 5}
                class:active={stage === i + 1}
              >
                <span class="dot"></span>
                {label}
              </div>
            {/each}
          </div>
          <button class="btn danger" onclick={cancelConnect}>Отмена</button>
        {:else}
          <button class="btn primary" disabled={!server} onclick={connect}>
            Подключиться
          </button>
        {/if}

        {#if sessionId}
          <button class="btn" onclick={disconnect}>Отключиться</button>
        {/if}
      </div>

      <div class="side-foot" title={appInfo?.dataDir ?? ""}>
        {appInfo?.dataDir ?? ""}
      </div>
    </aside>

    <main class="panes">
      <div class="pane-tools">
        <button
          class="btn small"
          disabled={!canDownload}
          onclick={downloadSelected}
        >
          ↓ Скачать в левую панель
        </button>
        {#if sessionId}
          <span class="badge">сессия {sessionId.slice(-6)}</span>
        {/if}
      </div>
      <div class="grid">
        <Pane
          title="Локально"
          listing={local}
          selected={localSel}
          onSelect={selectLocal}
          onOpen={openLocal}
          onUp={upLocal}
          onPath={loadLocal}
          onRefresh={() => local && loadLocal(local.path)}
        />
        <Pane
          title={server ? `Сервер · ${server.host}` : "Сервер"}
          listing={remote}
          selected={remoteSel}
          onSelect={selectRemote}
          onOpen={openRemote}
          onUp={upRemote}
          onPath={loadRemote}
          onRefresh={() => remote && loadRemote(remote.path)}
        />
      </div>
    </main>
  </div>

  {#if transfer}
    <footer class="transfer">
      <span class="t-name">{transfer.name}</span>
      <div class="bar"><div style:width={`${percent()}%`}></div></div>
      <span class="t-bytes">
        {formatBytes(transfer.done)}
        {transfer.total ? ` / ${formatBytes(transfer.total)}` : ""}
      </span>
      <span class="t-state">{transfer.state}</span>
    </footer>
  {/if}

  {#if notice}
    <div class="toast info" onclick={() => (notice = null)}>{notice}</div>
  {/if}

  {#if error}
    <div class="toast error" onclick={() => (error = null)}>{error}</div>
  {/if}
</div>

<style>
  .shell {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: rgba(15, 17, 21, 0.82);
    border: 1px solid var(--border-strong);
    border-radius: 10px;
    overflow: hidden;
  }

  .titlebar {
    display: flex;
    align-items: center;
    height: 36px;
    padding-left: 12px;
    background: rgba(21, 25, 34, 0.9);
    border-bottom: 1px solid var(--border);
    -webkit-user-select: none;
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .logo {
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    border-radius: 6px;
    background: var(--accent);
    color: #fff;
    font-size: 11px;
    font-weight: 700;
  }

  .brand .name {
    font-size: 12.5px;
    font-weight: 600;
  }

  .ver {
    font-size: 10.5px;
    color: var(--faint);
  }

  .grow {
    flex: 1;
    align-self: stretch;
  }

  .win-actions {
    display: flex;
    height: 100%;
  }

  .win-actions button {
    width: 44px;
    color: var(--dim);
    font-size: 13px;
  }

  .win-actions button:hover {
    background: rgba(255, 255, 255, 0.08);
    color: var(--text);
  }

  .win-actions .close:hover {
    background: #c42b1c;
    color: #fff;
  }

  .body {
    flex: 1;
    display: flex;
    min-height: 0;
    padding: 10px;
    gap: 10px;
  }

  .sidebar {
    display: flex;
    flex-direction: column;
    width: 280px;
    min-width: 240px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow: hidden;
  }

  .side-title {
    padding: 10px 12px 6px;
    font-size: 10.5px;
    letter-spacing: 0.9px;
    text-transform: uppercase;
    color: var(--faint);
  }

  .servers {
    flex: 1;
    overflow: auto;
    padding: 0 6px;
  }

  .server {
    display: flex;
    flex-direction: column;
    gap: 2px;
    width: 100%;
    padding: 7px 9px;
    border-radius: var(--radius-sm);
    text-align: left;
  }

  .server:hover {
    background: rgba(255, 255, 255, 0.05);
  }

  .server.active {
    background: var(--selection);
  }

  .s-name {
    font-size: 12.5px;
  }

  .s-host {
    font-size: 10.5px;
    color: var(--faint);
    font-family: var(--mono);
  }

  .empty {
    padding: 16px 8px;
    font-size: 11.5px;
    color: var(--faint);
    line-height: 1.5;
  }

  .mono {
    font-family: var(--mono);
    font-size: 10.5px;
    word-break: break-all;
  }

  .connect {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 10px;
    border-top: 1px solid var(--border);
  }

  .connect input {
    padding: 7px 9px;
    background: rgba(0, 0, 0, 0.28);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    font-size: 12px;
    outline: none;
  }

  .connect input:focus {
    border-color: var(--accent);
  }

  .btn {
    padding: 7px 10px;
    border-radius: var(--radius-sm);
    background: var(--raised);
    border: 1px solid var(--border);
    font-size: 12px;
  }

  .btn:hover:not(:disabled) {
    background: #232a36;
  }

  .btn:disabled {
    opacity: 0.45;
    cursor: default;
  }

  .btn.primary {
    background: var(--accent);
    border-color: transparent;
    color: #fff;
    font-weight: 600;
  }

  .btn.primary:hover:not(:disabled) {
    background: var(--accent-hover);
  }

  .btn.danger {
    color: var(--error);
    border-color: rgba(248, 81, 73, 0.4);
  }

  .btn.small {
    padding: 5px 9px;
    font-size: 11.5px;
  }

  .stages {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 4px 2px;
  }

  .stage {
    display: flex;
    align-items: center;
    gap: 7px;
    font-size: 11.5px;
    color: var(--faint);
  }

  .stage .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    border: 1px solid var(--faint);
  }

  .stage.done {
    color: var(--success);
  }

  .stage.done .dot {
    background: var(--success);
    border-color: var(--success);
  }

  .stage.active {
    color: var(--text);
    font-weight: 600;
  }

  .stage.active .dot {
    background: var(--accent);
    border-color: var(--accent);
  }

  .side-foot {
    padding: 6px 10px;
    border-top: 1px solid var(--border);
    font-size: 9.5px;
    color: var(--faint);
    font-family: var(--mono);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .panes {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
    gap: 8px;
  }

  .pane-tools {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .badge {
    padding: 3px 8px;
    border-radius: 99px;
    background: rgba(76, 141, 255, 0.14);
    color: var(--accent);
    font-size: 10.5px;
    font-family: var(--mono);
  }

  .grid {
    flex: 1;
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 10px;
    min-height: 0;
  }

  .transfer {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 7px 14px;
    border-top: 1px solid var(--border);
    background: rgba(21, 25, 34, 0.9);
    font-size: 11.5px;
  }

  .t-name {
    width: 200px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .bar {
    flex: 1;
    height: 4px;
    border-radius: 2px;
    background: rgba(255, 255, 255, 0.08);
    overflow: hidden;
  }

  .bar div {
    height: 100%;
    background: var(--accent);
    transition: width 0.12s linear;
  }

  .t-bytes {
    font-family: var(--mono);
    font-size: 10.5px;
    color: var(--dim);
  }

  .t-state {
    width: 70px;
    text-align: right;
    color: var(--faint);
  }

  .toast {
    position: fixed;
    left: 16px;
    right: 16px;
    bottom: 16px;
    padding: 9px 12px;
    border-radius: var(--radius-sm);
    font-size: 12px;
    background: var(--menu);
    border: 1px solid var(--border-strong);
    cursor: pointer;
    z-index: 10;
  }

  .toast.error {
    border-color: rgba(248, 81, 73, 0.55);
    color: #ffb4ac;
  }

  .toast.info {
    border-color: rgba(76, 141, 255, 0.45);
  }
</style>
