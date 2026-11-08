<script lang="ts">
  import PaneCard from "../lib/PaneCard.svelte";
  import Toolbar from "../lib/Toolbar.svelte";
  import TransferPanel from "../lib/TransferPanel.svelte";
  import TerminalPanel from "../lib/TerminalPanel.svelte";
  import type { BrowserTab } from "../lib/browser";
  import {
    api,
    formatBytes,
    joinPath,
    type DirListing,
    type Entry,
    type FoundFile,
    type TransferEvent,
    type Volume,
  } from "../lib/api";

  let {
    tabs,
    activeTabId,
    local,
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
    onSettings,
  }: {
    tabs: BrowserTab[];
    activeTabId: string;
    local: DirListing | null;
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
    ) => void;
    onCancelTransfer: (id: string) => void;
    onSettings: () => void;
  } = $props();

  let focused = $state<"local" | "remote">("local");
  let localSel = $state<string | null>(null);
  let remoteSel = $state<string | null>(null);
  let filter = $state("");
  let transferCollapsed = $state(false);
  let error = $state<string | null>(null);
  let busy = $state<string | null>(null);

  let menu = $state<{ x: number; y: number; entry: Entry | null } | null>(null);
  let prompt = $state<{
    title: string;
    label: string;
    value: string;
    hint?: string;
    action: (value: string) => Promise<void>;
  } | null>(null);
  let promptValue = $state("");
  let confirm = $state<{
    title: string;
    message: string;
    action: () => Promise<void>;
  } | null>(null);
  let terminalOpen = $state(false);
  let editor = $state<{
    entry: Entry;
    text: string;
    mode: "view" | "edit";
    sessionId: string | null;
  } | null>(null);
  let info = $state<{ title: string; text: string } | null>(null);

  let findOpen = $state(false);
  let findMask = $state("*");
  let findContent = $state("");
  let findResults = $state<FoundFile[]>([]);

  const tab = $derived(tabs.find((item) => item.id === activeTabId) ?? null);
  const remote = $derived(tab?.listing ?? null);
  const listing = $derived(focused === "local" ? local : remote);
  const selectedPath = $derived(focused === "local" ? localSel : remoteSel);
  const selectedEntry = $derived(
    (listing?.entries ?? []).find((entry) => entry.path === selectedPath) ??
      null,
  );
  const isRemote = $derived(focused === "remote");
  const sessionId = $derived(isRemote ? (tab?.sessionId ?? null) : null);

  const localTabs = $derived(
    volumes.length
      ? volumes.map((volume) => ({ id: volume.path, label: volume.name }))
      : [{ id: "local", label: "Локально" }],
  );
  const localActive = $derived.by(() => {
    const path = local?.path?.toLowerCase() ?? "";
    const match = volumes.find((volume) =>
      path.startsWith(volume.path.toLowerCase()),
    );
    return match?.path ?? localTabs[0]?.id ?? "local";
  });

  const canCopy = $derived(
    !!selectedEntry &&
      selectedEntry.kind !== "dir" &&
      ((focused === "local" && !!tab && !!remote) ||
        (focused === "remote" && !!local)),
  );

  $effect(() => {
    activeTabId;
    remoteSel = null;
  });

  async function reload() {
    if (!listing) return;
    if (focused === "local") await onLocalPath(listing.path);
    else if (tab) await onRemotePath(tab.id, listing.path);
  }

  async function navigateLocal(path: string) {
    localSel = null;
    await onLocalPath(path);
  }

  async function navigateRemote(path: string) {
    if (!tab) return;
    remoteSel = null;
    await onRemotePath(tab.id, path);
  }

  function up() {
    if (focused === "local") {
      if (local?.parent) void navigateLocal(local.parent);
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
    if (entry.kind !== "dir") {
      void viewFile(entry);
      return;
    }
    if (focused === "local") void navigateLocal(entry.path);
    else void navigateRemote(entry.path);
  }

  function openLocal(entry: Entry) {
    if (entry.kind === "dir") void navigateLocal(entry.path);
    else void viewFile(entry);
  }

  function openRemote(entry: Entry) {
    if (entry.kind === "dir") void navigateRemote(entry.path);
    else void viewFile(entry);
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

  async function submitConfirm() {
    const current = confirm;
    if (!current) return;
    confirm = null;
    await run("Выполняю…", current.action);
  }

  function copyBetween() {
    const entry = selectedEntry;
    if (!entry) return;
    if (entry.kind === "dir") {
      error = "Перенос папок появится вместе с очередью передач";
      return;
    }
    if (focused === "local") {
      if (!tab || !remote) return;
      onTransfer("upload", entry.path, remote.path);
    } else if (local) {
      onTransfer("download", entry.path, local.path);
    }
  }

  function mkdirPrompt() {
    if (!listing) return;
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
    ask("Переименовать", "Новое имя", entry.name, async (value) => {
      const name = value.trim();
      if (!name || name === entry.name) return;
      await api.rename(sessionId, entry.path, joinPath(listing.path, name));
      await reload();
    });
  }

  function deleteSelected() {
    const entry = selectedEntry;
    if (!entry) return;
    askConfirm(
      "Удалить?",
      `${entry.kind === "dir" ? "Папка" : "Файл"} «${entry.name}» будет удалён без возможности отмены.`,
      async () => {
        await api.remove(sessionId, entry.path, entry.kind === "dir");
        await reload();
      },
    );
  }

  async function openEditor(entry: Entry, mode: "view" | "edit") {
    const sid = sessionId;
    await run("Читаю файл…", async () => {
      const text = await api.preview(sid, entry.path, 262144);
      editor = { entry, text, mode, sessionId: sid };
    });
  }

  function viewFile(entry: Entry) {
    void openEditor(entry, "view");
  }

  function viewSelected() {
    if (selectedEntry && selectedEntry.kind !== "dir") {
      void openEditor(selectedEntry, "view");
    }
  }

  function editSelected() {
    if (selectedEntry && selectedEntry.kind !== "dir") {
      void openEditor(selectedEntry, "edit");
    }
  }

  async function saveEditor() {
    const current = editor;
    if (!current) return;
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
      editor = null;
      await reload();
    });
  }

  const editorTruncated = $derived((editor?.text.length ?? 0) >= 262140);

  function checksumSelected() {
    const entry = selectedEntry;
    if (!entry || entry.kind === "dir") return;
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
    const current = entry.mode != null ? (entry.mode & 0o777).toString(8) : "644";
    ask("Права доступа", "Восьмерично, например 644", current, async (value) => {
      const mode = Number.parseInt(value.trim(), 8);
      if (Number.isNaN(mode)) throw new Error("Нужно восьмеричное число");
      await api.chmod(sessionId, entry.path, mode, false);
      await reload();
    });
  }

  function openFind() {
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

  function openMenu(entry: Entry | null, event: MouseEvent) {
    menu = {
      x: Math.min(event.clientX, window.innerWidth - 220),
      y: Math.min(event.clientY, window.innerHeight - 260),
      entry,
    };
  }

  function menuAction(action: () => void) {
    menu = null;
    action();
  }

  function selectLocalTab(id: string) {
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
    switch (event.key) {
      case "F5":
        event.preventDefault();
        copyBetween();
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
        viewSelected();
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
        filter = "";
        menu = null;
        break;
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
    canUp={isRemote ? !!remote?.parent : !!local?.parent}
    canCopy={canCopy}
    canRename={!!selectedEntry}
    canDelete={!!selectedEntry}
    canEdit={!!selectedEntry && selectedEntry.kind !== "dir"}
    {terminalOpen}
    {filter}
    onBack={onBack}
    onUp={up}
    onRefresh={refresh}
    onCopy={copyBetween}
    onRename={renameSelected}
    onDelete={deleteSelected}
    onMkdir={mkdirPrompt}
    onEdit={editSelected}
    onTerminal={() => (terminalOpen = !terminalOpen)}
    onSettings={onSettings}
    onFilter={(value) => (filter = value)}
  />

  <div class="panes">
    <PaneCard
      variant="local"
      tabs={localTabs}
      activeTab={localActive}
      listing={local}
      selected={localSel}
      focused={focused === "local"}
      filter={focused === "local" ? filter : ""}
      onSelectTab={selectLocalTab}
      onAdd={() => {}}
      onUp={() => local?.parent && navigateLocal(local.parent)}
      onRefresh={() => local && navigateLocal(local.path)}
      onPath={navigateLocal}
      onSelect={(entry) => {
        focused = "local";
        localSel = entry.path;
      }}
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
      onSelectTab={onSelectTab}
      onCloseTab={onCloseTab}
      onAdd={onAddTab}
      onUp={() => remote?.parent && navigateRemote(remote.parent)}
      onRefresh={() => remote && navigateRemote(remote.path)}
      onPath={navigateRemote}
      onSelect={(entry) => {
        focused = "remote";
        remoteSel = entry.path;
      }}
      onOpen={openRemote}
      onFocus={() => (focused = "remote")}
      onContextMenu={openMenu}
    />
  </div>

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
      {#if menu.entry.kind !== "dir"}
        <button onclick={() => menuAction(copyBetween)}>
          {focused === "local" ? "Загрузить (F5)" : "Скачать (F5)"}
        </button>
        <button onclick={() => menuAction(checksumSelected)}>
          SHA-256 файла
        </button>
      {/if}
      <div class="sep"></div>
      <button onclick={() => menuAction(renameSelected)}>
        Переименовать (F2)
      </button>
      <button onclick={() => menuAction(chmodSelected)}>
        Права доступа…
      </button>
      <div class="sep"></div>
      <button class="danger" onclick={() => menuAction(deleteSelected)}>
        Удалить (F8)
      </button>
    {:else}
      <button onclick={() => menuAction(mkdirPrompt)}>Новая папка (F7)</button>
      <button onclick={() => menuAction(openFind)}>Найти файлы…</button>
    {/if}
  </div>
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
        <span class="grow"></span>
        {#if editor.mode === "edit"}
          <button
            class="btn primary"
            disabled={editorTruncated}
            onclick={saveEditor}
          >
            Сохранить
          </button>
        {:else}
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
        <textarea bind:value={editor.text} spellcheck="false"></textarea>
        {#if editorTruncated}
          <div class="warn">Файл больше 256 КБ — сохранение отключено.</div>
        {/if}
      {:else}
        <pre>{editor.text}</pre>
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

{#if busy}
  <div class="overlay">
    <div class="dialog small">
      <div class="busy-row">
        <span class="spinner"></span>
        {busy}
      </div>
    </div>
  </div>
{/if}

{#if error}
  <div class="toast" onclick={() => (error = null)}>{error}</div>
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
    width: 210px;
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
  }

  .field span {
    font-size: 11px;
    color: var(--faint);
  }

  .field input {
    padding: 7px 9px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    outline: none;
    font-size: 12.5px;
  }

  .field input:focus {
    border-color: var(--accent);
  }

  .hint,
  .message {
    margin-top: 8px;
    color: var(--dim);
    font-size: 11.5px;
    line-height: 1.45;
  }

  .foot {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 14px;
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
    justify-content: space-between;
    padding: 10px 14px;
    border-bottom: 1px solid var(--border);
    font-size: 12.5px;
    font-weight: 600;
  }

  .viewer .grow {
    flex: 1;
  }

  .viewer textarea {
    flex: 1;
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
    flex: 1;
    margin: 0;
    padding: 12px 14px;
    overflow: auto;
    font-family: var(--mono);
    font-size: 12px;
    line-height: 1.5;
    white-space: pre-wrap;
    user-select: text;
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
    margin-top: 12px;
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
