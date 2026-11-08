<script lang="ts">
  import { onMount } from "svelte";
  import { open } from "@tauri-apps/plugin-dialog";
  import {
    ArrowRight,
    Folder,
    FolderPlus,
    Grid2x2,
    History,
    Lock,
    Pencil,
    Plus,
    RefreshCw,
    Search,
    Settings2,
    Trash2,
    Unlock,
    X,
  } from "lucide-svelte";
  import ServerEditor from "../lib/ServerEditor.svelte";
  import type { BrowserTab } from "../lib/browser";
  import {
    api,
    type Group,
    type OpenSession,
    type Server,
    type ServerBook,
    type WinscpImportReport,
  } from "../lib/api";

  let {
    book,
    openTabs = [],
    restore = [],
    onConnect,
    onOpenTab,
    onRestore,
    onHideRestore,
    onBookChanged,
    onSettings,
  }: {
    book: ServerBook | null;
    openTabs?: BrowserTab[];
    restore?: OpenSession[];
    onConnect: (server: Server) => void;
    onOpenTab: (id: string) => void;
    onRestore: () => void;
    onHideRestore: () => void;
    onBookChanged: () => Promise<void>;
    onSettings: () => void;
  } = $props();

  type Protocol = "all" | "up" | "down" | "badpass" | "ssh" | "ftp" | "s3";

  let search = $state("");
  let group = $state<string | null>(null);
  let protocol = $state<Protocol>("all");
  let selected = $state<string | null>(null);
  let editing = $state<Server | "new" | null>(null);
  let groupEditor = $state<{ id: string | null; name: string } | null>(null);
  let groupMenu = $state<{ x: number; y: number; group: Group | null } | null>(
    null,
  );
  let checked = $state<Set<string>>(new Set());
  let settingsBusy = $state(false);

  let reachable = $state<Record<string, boolean | null>>({});
  let probe = $state<{ done: number; total: number } | null>(null);
  let importReport = $state<WinscpImportReport | null>(null);
  let importError = $state<string | null>(null);
  let importBusy = $state(false);
  let locked = $state(false);
  let dragGroup = $state<string | null>(null);
  let dragServer = $state<string | null>(null);
  let serverMenu = $state<{
    x: number;
    y: number;
    server: Server;
  } | null>(null);
  let moveTarget = $state<Server | null>(null);
  let bulkMoveOpen = $state(false);
  let moveGroup = $state("");
  let unlockOpen = $state(false);
  let unlockPassword = $state("");
  let unlockError = $state<string | null>(null);
  let toast = $state<string | null>(null);

  $effect(() => {
    for (const server of book?.servers ?? []) {
      if (server.reachable != null) reachable[server.id] = server.reachable;
    }
  });

  onMount(async () => {
    try {
      locked = (await api.vaultInfo()).vault !== "unlocked";
    } catch {
      locked = false;
    }
  });

  async function toggleLock() {
    if (!locked) {
      try {
        await api.lockVault();
        locked = true;
        toast = "Хранилище заблокировано";
        setTimeout(() => (toast = null), 2200);
      } catch (e) {
        importError = String(e);
      }
      return;
    }
    unlockPassword = "";
    unlockError = null;
    unlockOpen = true;
  }

  async function submitUnlock() {
    try {
      await api.unlockVault(unlockPassword);
      locked = false;
      unlockOpen = false;
      await onBookChanged();
    } catch (e) {
      unlockError = String(e);
    }
  }

  let autoProbed = false;

  $effect(() => {
    // Quiet background check once the book is loaded: servers that were never
    // probed or whose result is older than 30 minutes.
    const servers = book?.servers ?? [];
    if (autoProbed || !servers.length) return;
    autoProbed = true;
    const stale = servers.filter(
      (server) =>
        server.reachable == null ||
        !server.checkedAt ||
        Date.now() - server.checkedAt > 30 * 60 * 1000,
    );
    if (stale.length) void probeServers(stale, true);
  });

  async function probeServers(list: Server[], quiet = false) {
    if (probe || !list.length) return;
    const startedAt = Date.now();
    probe = { done: 0, total: list.length };
    for (const server of list) reachable[server.id] = null;
    let index = 0;
    const worker = async () => {
      while (index < list.length) {
        const server = list[index++];
        let up: boolean | null = null;
        try {
          up = (await api.checkServerAccess(server.id)) !== "unreachable";
        } catch {
          up = false;
        }
        reachable[server.id] = up;
        if (probe) probe.done += 1;
      }
    };
    await Promise.all(Array.from({ length: Math.min(6, list.length) }, worker));
    // Keep the bar on screen long enough to be noticed on a fast LAN.
    const elapsed = Date.now() - startedAt;
    if (elapsed < 500) {
      await new Promise((resolve) => setTimeout(resolve, 500 - elapsed));
    }
    probe = null;
    if (!quiet) await onBookChanged();
  }

  async function probeAll() {
    await probeServers([...(book?.servers ?? [])]);
  }

  async function importWinscp() {
    const path = await open({
      multiple: false,
      directory: false,
      filters: [{ name: "WinSCP", extensions: ["ini"] }],
    });
    if (!path || Array.isArray(path)) return;
    importBusy = true;
    importError = null;
    try {
      importReport = await api.importWinscp(path);
      await onBookChanged();
    } catch (e) {
      importError = String(e);
    } finally {
      importBusy = false;
    }
  }

  function statusTitle(server: Server): string {
    if (reachable[server.id] === true) return "Доступен";
    if (reachable[server.id] === false)
      return server.authFailed ? "Логин отклонён" : "Недоступен";
    return "Доступность не проверена";
  }

  function statusKind(server: Server): string {
    if (reachable[server.id] === true) return "up";
    if (reachable[server.id] === false)
      return server.authFailed ? "badpass" : "down";
    return "unknown";
  }

  const groups: Group[] = $derived(book?.groups ?? []);
  const servers: Server[] = $derived(book?.servers ?? []);

  function serverProtocol(server: Server): Protocol {
    if (server.protocol === "s3") return "s3";
    if (server.protocol === "ftp" || server.protocol === "ftps") return "ftp";
    return "ssh";
  }

  function groupName(server: Server): string {
    return groups.find((item) => item.id === server.groupId)?.name ?? "";
  }

  function groupCount(id: string): number {
    return servers.filter((server) => server.groupId === id).length;
  }

  const visible = $derived.by(() => {
    const query = search.trim().toLowerCase();
    return servers.filter((server) => {
      if (group && server.groupId !== group) return false;
      if (protocol === "up" || protocol === "down" || protocol === "badpass") {
        const state =
          reachable[server.id] === true
            ? "up"
            : reachable[server.id] === false
              ? "down"
              : "unknown";
        if (protocol === "up" && (state === "down" || server.authFailed)) {
          return false;
        }
        if (protocol === "down" && state !== "down") return false;
        if (protocol === "badpass" && !server.authFailed) return false;
      } else if (protocol !== "all" && serverProtocol(server) !== protocol) {
        return false;
      }
      if (!query) return true;
      return (
        server.name.toLowerCase().includes(query) ||
        server.host.toLowerCase().includes(query) ||
        server.user.toLowerCase().includes(query) ||
        server.tags.some((tag) => tag.toLowerCase().includes(query)) ||
        groupName(server).toLowerCase().includes(query)
      );
    });
  });

  function openServerMenu(server: Server, event: MouseEvent) {
    event.preventDefault();
    serverMenu = {
      x: Math.min(event.clientX, window.innerWidth - 230),
      y: Math.min(event.clientY, window.innerHeight - 230),
      server,
    };
  }

  async function duplicateServer(server: Server) {
    const stamp = Date.now();
    const id = `s_${stamp}`;
    const copy: Server = {
      ...server,
      id,
      name: `${server.name || server.host} (копия)`,
      passwordRef: server.passwordRef ? `pwd_${id}` : null,
      auth: {
        ...server.auth,
        passphraseRef: server.auth?.passphraseRef ? `pass_${id}` : null,
      },
      s3AccessRef: server.s3AccessRef ? `s3a_${id}` : null,
      s3SecretRef: server.s3SecretRef ? `s3s_${id}` : null,
      lastConnected: null,
      reachable: null,
      checkedAt: null,
      authFailed: false,
    };
    try {
      const saved = await api.saveServer(copy);
      const transfers: [string | null | undefined, string | null | undefined][] =
        [
          [server.passwordRef, saved.passwordRef],
          [server.auth?.passphraseRef, saved.auth?.passphraseRef],
          [server.s3AccessRef, saved.s3AccessRef],
          [server.s3SecretRef, saved.s3SecretRef],
        ];
      for (const [from, to] of transfers) {
        if (!from || !to) continue;
        const value = await api.getSecret(from).catch(() => null);
        if (value) await api.setSecret(to, value);
      }
      await onBookChanged();
    } catch (e) {
      importError = String(e);
    }
  }

  async function confirmMove() {
    const server = moveTarget;
    moveTarget = null;
    if (!server) return;
    await moveServerToGroup(server.id, moveGroup || null);
  }

  async function deleteServer(server: Server) {
    if (!confirm(`Удалить «${server.name || server.host}»?`)) return;
    await api.deleteServer(server.id);
    await onBookChanged();
  }

  async function moveServerToGroup(serverId: string, groupId: string | null) {
    const server = servers.find((item) => item.id === serverId);
    if (!server || server.groupId === groupId) return;
    await api.saveServer({ ...server, groupId });
    await onBookChanged();
  }

  async function reorderGroup(movingId: string, targetId: string | null) {
    if (movingId === targetId) return;
    const ordered = [...groups]
      .filter((item) => item.id !== movingId)
      .sort((a, b) => a.order - b.order);
    const moving = groups.find((item) => item.id === movingId);
    if (!moving) return;
    const index = targetId
      ? Math.max(0, ordered.findIndex((item) => item.id === targetId))
      : 0;
    ordered.splice(index, 0, moving);
    for (const [position, item] of ordered.entries()) {
      if (item.order === position) continue;
      await api.saveGroup({ ...item, order: position });
    }
    await onBookChanged();
  }

  async function saveGroupEdit() {
    const editor = groupEditor;
    if (!editor) return;
    const name = editor.name.trim();
    if (!name) return;
    groupEditor = null;
    const existing = editor.id
      ? groups.find((item) => item.id === editor.id)
      : null;
    await api.saveGroup({
      id: editor.id ?? `g_${Date.now()}`,
      name,
      parent: existing?.parent ?? null,
      color: existing?.color ?? null,
      order: existing?.order ?? groups.length,
      expanded: existing?.expanded ?? true,
      icon: existing?.icon ?? null,
    });
    await onBookChanged();
  }

  async function deleteGroup(item: Group) {
    if (!confirm(`Удалить группу «${item.name}»? Серверы останутся без группы.`))
      return;
    await api.deleteGroup(item.id);
    if (group === item.id) group = null;
    await onBookChanged();
  }

  function openGroupMenu(item: Group | null, event: MouseEvent) {
    event.preventDefault();
    groupMenu = {
      x: Math.min(event.clientX, window.innerWidth - 230),
      y: Math.min(event.clientY, window.innerHeight - 170),
      group: item,
    };
  }

  function toggleChecked(id: string) {
    if (checked.has(id)) checked.delete(id);
    else checked.add(id);
    checked = new Set(checked);
  }

  async function deleteChecked() {
    const ids = [...checked];
    if (!ids.length) return;
    if (
      !confirm(
        `Удалить ${ids.length === 1 ? "выбранный сервер" : `${ids.length} выбранных серверов`}?`,
      )
    ) {
      return;
    }
    for (const id of ids) await api.deleteServer(id);
    checked = new Set();
    await onBookChanged();
  }

  async function confirmBulkMove() {
    const ids = [...checked];
    const target = moveGroup || null;
    moveTarget = null;
    if (!ids.length) return;
    for (const id of ids) await moveServerToGroup(id, target);
    checked = new Set();
  }

  function connect(server: Server) {
    selected = server.id;
    onConnect(server);
  }
</script>

<div class="page">
  <div class="top">
    <label class="search">
      <Search size={15} />
      <input
        bind:value={search}
        placeholder="Поиск: имя, хост, тег"
        spellcheck="false"
      />
    </label>
    <button
      class="top-btn"
      title="Импорт из WinSCP"
      disabled={importBusy}
      onclick={importWinscp}
    >
      <FolderPlus size={17} />
    </button>
    <button
      class="top-btn"
      title="Проверить доступность всех серверов"
      disabled={!!probe}
      onclick={probeAll}
    >
      <span class="icon-wrap" class:spin={!!probe}>
        <RefreshCw size={17} />
      </span>
    </button>
    <button class="top-btn" title="Новый сервер" onclick={() => (editing = "new")}>
      <Plus size={17} />
    </button>
    <button
      class="top-btn"
      title="Продолжить прошлую сессию"
      disabled={!restore.length}
      onclick={onRestore}
    >
      <History size={17} />
    </button>
    <button class="top-btn" title="Настройки" onclick={onSettings}>
      <Settings2 size={17} />
    </button>
    <button
      class="top-btn"
      title={locked ? "Разблокировать хранилище" : "Заблокировать хранилище"}
      onclick={toggleLock}
    >
      {#if locked}<Unlock size={17} />{:else}<Lock size={17} />{/if}
    </button>
  </div>

  {#if probe}
    <div class="probe-wrap">
      <div class="probe-bar">
        <div
          class="probe-fill"
          style:width={`${Math.round((probe.done / Math.max(1, probe.total)) * 100)}%`}
        ></div>
      </div>
      <span class="probe-label">
        Проверка серверов: {probe.done} из {probe.total}
      </span>
    </div>
  {/if}

  {#if restore.length}
    <div class="restore">
      <History size={15} />
      <span class="restore-text">
        Прошлая сессия: {restore.map((item) => item.name || item.serverId).join(", ")}
      </span>
      <button class="restore-btn" onclick={onRestore}>Продолжить</button>
      <button class="restore-x" title="Скрыть" onclick={onHideRestore}>
        <X size={14} />
      </button>
    </div>
  {/if}

  {#if openTabs.length}
    <div class="open-tabs">
      <span class="open-label">Открытые сессии</span>
      {#each openTabs as tab (tab.id)}
        <button class="open-tab" onclick={() => onOpenTab(tab.id)}>
          <span class="dot"></span>
          {tab.label}
        </button>
      {/each}
    </div>
  {/if}

  <div class="content">
    <aside class="card groups">
      <div class="card-head">
        <span>Группы</span>
        <button
          class="tiny"
          title="Новая группа"
          onclick={() => (groupEditor = { id: null, name: "" })}
        >
          <Plus size={15} />
        </button>
      </div>
      <button
        class="group"
        class:active={group === null}
        ondragover={(event) => {
          if (dragGroup) event.preventDefault();
        }}
        ondrop={async (event) => {
          event.preventDefault();
          const server = dragServer;
          dragServer = null;
          if (server) {
            await moveServerToGroup(server, null);
            return;
          }
          const moving = dragGroup;
          dragGroup = null;
          if (moving) await reorderGroup(moving, null);
        }}
        onclick={() => (group = null)}
        oncontextmenu={(event) => openGroupMenu(null, event)}
      >
        <Grid2x2 size={15} class="g-icon" />
        <span class="g-name">Все серверы</span>
        <span class="g-count">{servers.length}</span>
      </button>
      {#each groups as item (item.id)}
        <button
          class="group"
          class:active={group === item.id}
          draggable="true"
          ondragstart={() => (dragGroup = item.id)}
          ondragover={(event) => {
            if (dragGroup) event.preventDefault();
          }}
          ondrop={async (event) => {
            event.preventDefault();
            const server = dragServer;
            dragServer = null;
            if (server) {
              await moveServerToGroup(server, item.id);
              return;
            }
            const moving = dragGroup;
            dragGroup = null;
            if (moving) await reorderGroup(moving, item.id);
          }}
          onclick={() => (group = item.id)}
          ondblclick={() => {
            groupEditor = { id: item.id, name: item.name };
          }}
          oncontextmenu={(event) => openGroupMenu(item, event)}
        >
          <span class="g-icon" style:color={item.color ?? "var(--dir)"}>
            <Folder size={15} />
          </span>
          <span class="g-name">{item.name}</span>
          <span class="g-count">{groupCount(item.id)}</span>
          <span class="grip">⠿</span>
        </button>
      {/each}
      <div class="grow"></div>
      <button
        class="new-group"
        onclick={() => (groupEditor = { id: null, name: "" })}
      >
        <FolderPlus size={15} />
        Новая группа
      </button>
    </aside>

    <section class="card servers">
      <div class="servers-head">
        <div class="servers-title">
          <span>Все серверы</span>
          <span class="count">{visible.length}</span>
          {#if probe}
            <span class="probe">{probe.done}/{probe.total}</span>
          {/if}
        </div>
        <div class="chips">
          {#each [["all", "Все"], ["up", "Работают"], ["down", "Не работают"], ["badpass", "Неверный доступ"], ["ssh", "SSH"], ["ftp", "FTP"], ["s3", "S3"]] as [value, label] (value)}
            <button
              class="chip"
              class:active={protocol === value}
              onclick={() => (protocol = value as Protocol)}
            >
              {label}
            </button>
          {/each}
        </div>
      </div>

      {#if checked.size}
        <div class="pick-bar">
          <span>Выбрано: {checked.size}</span>
          <span class="grow"></span>
          <button class="pick-btn" onclick={() => (checked = new Set())}>
            Снять
          </button>
          <button
            class="pick-btn"
            onclick={() =>
              (checked = new Set(visible.map((server) => server.id)))}
          >
            Выбрать все
          </button>
          <button
            class="pick-btn"
            onclick={() => {
              moveGroup = "";
              moveTarget = null;
              bulkMoveOpen = true;
            }}
          >
            В группу…
          </button>
          <button class="pick-btn danger" onclick={deleteChecked}>
            <Trash2 size={13} /> Удалить
          </button>
        </div>
      {/if}

      <div class="server-list">
        {#each visible as server (server.id)}
          <div
            class="server"
            class:active={selected === server.id}
            role="button"
            tabindex="0"
            draggable="true"
            ondragstart={() => (dragServer = server.id)}
            ondragend={() => (dragServer = null)}
            onpointerdown={() => (selected = server.id)}
            oncontextmenu={(event) => openServerMenu(server, event)}
            ondblclick={() => connect(server)}
            onkeydown={(e) => e.key === "Enter" && connect(server)}
          >
            <button
              class="check"
              class:on={checked.has(server.id)}
              title="Выбрать сервер"
              onclick={(event) => {
                event.stopPropagation();
                toggleChecked(server.id);
              }}
              onpointerdown={(event) => event.stopPropagation()}
            >
              {#if checked.has(server.id)}<span class="tick">✓</span>{/if}
            </button>
            <span
              class="status {statusKind(server)}"
              title={statusTitle(server)}
            ></span>
            <div class="info">
              <div class="s-name">{server.name || server.host}</div>
              <div class="s-sub">
                {server.user}@{server.host}:{server.port}
                {#if groupName(server)} · {groupName(server)}{/if}
              </div>
            </div>
            <div class="tags">
              {#each server.tags as tag (tag)}
                <span class="tag">{tag}</span>
              {/each}
            </div>
            <button
              class="edit"
              title="Изменить"
              onclick={() => (editing = server)}
            >
              <Pencil size={14} />
            </button>
            <button
              class="enter"
              title="Подключиться"
              onclick={() => connect(server)}
            >
              <ArrowRight size={16} />
            </button>
          </div>
        {:else}
          <div class="empty">Ничего не найдено</div>
        {/each}
      </div>
    </section>
  </div>
</div>

{#if editing}
  <ServerEditor
    server={editing === "new" ? null : editing}
    groups={groups}
    onClose={() => (editing = null)}
    onSaved={async () => {
      editing = null;
      await onBookChanged();
    }}
    onDeleted={async () => {
      editing = null;
      await onBookChanged();
    }}
  />
{/if}

{#if groupMenu}
  <div class="menu-backdrop" onclick={() => (groupMenu = null)}></div>
  <div
    class="context"
    style:left={`${groupMenu.x}px`}
    style:top={`${groupMenu.y}px`}
  >
    <button
      onclick={() => {
        groupEditor = { id: null, name: "" };
        groupMenu = null;
      }}
    >
      Новая группа
    </button>
    {#if groupMenu.group}
      <button
        onclick={() => {
          const item = groupMenu!.group!;
          groupEditor = { id: item.id, name: item.name };
          groupMenu = null;
        }}
      >
        Переименовать
      </button>
      <div class="sep"></div>
      <button
        class="danger"
        onclick={() => {
          const item = groupMenu!.group!;
          groupMenu = null;
          void deleteGroup(item);
        }}
      >
        Удалить группу
      </button>
    {/if}
  </div>
{/if}

{#if serverMenu}
  <div class="menu-backdrop" onclick={() => (serverMenu = null)}></div>
  <div
    class="context"
    style:left={`${serverMenu.x}px`}
    style:top={`${serverMenu.y}px`}
  >
    <button
      onclick={() => {
        const server = serverMenu!.server;
        serverMenu = null;
        connect(server);
      }}
    >
      Подключиться
    </button>
    <button
      onclick={() => {
        const server = serverMenu!.server;
        serverMenu = null;
        editing = server;
      }}
    >
      Изменить
    </button>
    <button
      onclick={() => {
        const server = serverMenu!.server;
        serverMenu = null;
        moveTarget = server;
        moveGroup = server.groupId ?? "";
      }}
    >
      Переместить в группу…
    </button>
    <button
      onclick={() => {
        const server = serverMenu!.server;
        serverMenu = null;
        void duplicateServer(server);
      }}
    >
      Дублировать
    </button>
    <button
      onclick={() => {
        const server = serverMenu!.server;
        serverMenu = null;
        void probeServers([server]);
      }}
    >
      Проверить доступ
    </button>
    <div class="sep"></div>
    <button
      class="danger"
      onclick={() => {
        const server = serverMenu!.server;
        serverMenu = null;
        void deleteServer(server);
      }}
    >
      Удалить
    </button>
  </div>
{/if}

{#if moveTarget || bulkMoveOpen}
  <div
    class="overlay"
    onclick={() => {
      moveTarget = null;
      bulkMoveOpen = false;
    }}
  >
    <div class="group-dialog" onclick={(e) => e.stopPropagation()}>
      <div class="group-title">
        {bulkMoveOpen
          ? `Переместить серверов: ${checked.size}`
          : `Переместить «${moveTarget?.name || moveTarget?.host}»`}
      </div>
      <select bind:value={moveGroup}>
        <option value="">Без группы</option>
        {#each groups as group (group.id)}
          <option value={group.id}>{group.name}</option>
        {/each}
      </select>
      <div class="group-foot">
        <button
          class="gbtn"
          onclick={() => {
            moveTarget = null;
            bulkMoveOpen = false;
          }}
        >
          Отмена
        </button>
        <button
          class="gbtn primary"
          onclick={() => {
            if (bulkMoveOpen) {
              bulkMoveOpen = false;
              void confirmBulkMove();
            } else {
              confirmMove();
            }
          }}
        >
          Переместить
        </button>
      </div>
    </div>
  </div>
{/if}

{#if unlockOpen}
  <div class="overlay" onclick={() => (unlockOpen = false)}>
    <div class="group-dialog" onclick={(e) => e.stopPropagation()}>
      <div class="group-title">Разблокировать хранилище</div>
      <input
        type="password"
        bind:value={unlockPassword}
        autofocus
        placeholder="Мастер-пароль"
        onkeydown={(e) => e.key === "Enter" && submitUnlock()}
      />
      {#if unlockError}<div class="import-errors">{unlockError}</div>{/if}
      <div class="group-foot">
        <button class="gbtn" onclick={() => (unlockOpen = false)}>Отмена</button>
        <button class="gbtn primary" onclick={submitUnlock}>Открыть</button>
      </div>
    </div>
  </div>
{/if}

{#if toast}<div class="toast">{toast}</div>{/if}

{#if importReport}
  <div class="overlay" onclick={() => (importReport = null)}>
    <div class="group-dialog import" onclick={(e) => e.stopPropagation()}>
      <div class="group-title">Импорт из WinSCP</div>
      <div class="import-line">Сессий в файле: {importReport.sessions}</div>
      <div class="import-line">Добавлено: {importReport.imported}</div>
      <div class="import-line">Пропущено: {importReport.skipped}</div>
      <div class="import-line">Групп создано: {importReport.groups}</div>
      <div class="import-line">Паролей перенесено: {importReport.passwords}</div>
      {#if importReport.errors.length}
        <div class="import-errors">
          {#each importReport.errors as message (message)}
            <div>{message}</div>
          {/each}
        </div>
      {/if}
      <div class="group-foot">
        <button class="gbtn primary" onclick={() => (importReport = null)}>
          Готово
        </button>
      </div>
    </div>
  </div>
{/if}

{#if importError}
  <div class="overlay" onclick={() => (importError = null)}>
    <div class="group-dialog" onclick={(e) => e.stopPropagation()}>
      <div class="group-title">Импорт не удался</div>
      <div class="import-errors">{importError}</div>
      <div class="group-foot">
        <button class="gbtn primary" onclick={() => (importError = null)}>
          Закрыть
        </button>
      </div>
    </div>
  </div>
{/if}

{#if groupEditor}
  <div class="overlay" onclick={() => (groupEditor = null)}>
    <div class="group-dialog" onclick={(e) => e.stopPropagation()}>
      <div class="group-title">
        {groupEditor.id ? "Группа" : "Новая группа"}
      </div>
      <input
        bind:value={groupEditor.name}
        autofocus
        placeholder="Название"
        onkeydown={(e) => e.key === "Enter" && saveGroupEdit()}
      />
      <div class="group-foot">
        <button class="gbtn" onclick={() => (groupEditor = null)}>Отмена</button>
        <button class="gbtn primary" onclick={saveGroupEdit}>
          {groupEditor.id ? "Сохранить" : "Создать"}
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .page {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 0;
    padding: 12px 22px 22px;
    gap: 12px;
  }

  .top {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
  }

  .search {
    display: flex;
    align-items: center;
    gap: 9px;
    width: 320px;
    height: 36px;
    margin-right: 6px;
    padding: 0 12px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--panel);
    color: var(--faint);
  }

  .search:focus-within {
    border-color: var(--accent);
  }

  .search input {
    flex: 1;
    min-width: 0;
    border: 0;
    outline: 0;
    background: transparent;
    font-size: 12.5px;
  }

  .search input::placeholder {
    color: var(--faint);
  }

  .top-btn {
    display: grid;
    place-items: center;
    width: 34px;
    height: 34px;
    border-radius: var(--radius-sm);
    color: var(--dim);
  }

  .top-btn:hover:not(:disabled) {
    background: var(--hover);
    color: var(--text);
  }

  .top-btn:disabled {
    opacity: 0.4;
    cursor: default;
  }

  .open-tabs {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .open-label {
    font-size: 11px;
    color: var(--faint);
  }

  .open-tab {
    display: flex;
    align-items: center;
    gap: 7px;
    padding: 5px 10px;
    border: 1px solid var(--border);
    border-radius: 99px;
    background: var(--panel);
    font-size: 11.5px;
  }

  .open-tab:hover {
    border-color: var(--accent);
  }

  .open-tab .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--success);
  }

  .content {
    flex: 1;
    display: grid;
    grid-template-columns: 292px 1fr;
    gap: 14px;
    min-height: 0;
  }

  .card {
    display: flex;
    flex-direction: column;
    min-height: 0;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow: hidden;
  }

  .card-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 13px 16px 9px;
    font-size: 11px;
    letter-spacing: 0.6px;
    text-transform: uppercase;
    color: var(--faint);
  }

  .tiny {
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    border-radius: 5px;
    color: var(--dim);
  }

  .tiny:hover {
    background: var(--hover);
  }

  .groups {
    padding-bottom: 10px;
  }

  .group {
    display: flex;
    align-items: center;
    gap: 9px;
    height: 34px;
    margin: 0 8px;
    padding: 0 10px;
    border-radius: 7px;
    color: var(--dim);
    font-size: 12.5px;
    text-align: left;
  }

  .group:hover {
    background: var(--hover);
  }

  .group.active {
    background: var(--selection);
    color: var(--text);
  }

  .g-icon {
    flex: 0 0 15px;
  }

  .g-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .g-count {
    font-size: 11px;
    color: var(--faint);
  }

  .grip {
    color: var(--faint);
    font-size: 11px;
  }

  .grow {
    flex: 1;
  }

  .new-group {
    display: flex;
    align-items: center;
    gap: 9px;
    height: 34px;
    margin: 0 8px;
    padding: 0 10px;
    border-radius: 7px;
    color: var(--dim);
    font-size: 12px;
  }

  .new-group:disabled {
    opacity: 0.6;
    cursor: default;
  }

  .servers-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px 10px;
    border-bottom: 1px solid var(--border);
  }

  .servers-title {
    display: flex;
    align-items: center;
    gap: 9px;
    font-size: 12.5px;
    font-weight: 600;
  }

  .servers-title .count {
    color: var(--faint);
    font-weight: 400;
  }

  .chips {
    display: flex;
    gap: 4px;
  }

  .chip {
    padding: 5px 11px;
    border-radius: 7px;
    color: var(--dim);
    font-size: 11.5px;
  }

  .chip:hover {
    background: var(--hover);
    color: var(--text);
  }

  .chip.active {
    background: var(--accent);
    color: #fff;
  }

  .server-list {
    flex: 1;
    overflow: auto;
    padding: 6px 0;
  }

  .server {
    display: flex;
    align-items: center;
    gap: 12px;
    height: 54px;
    padding: 0 16px;
    cursor: default;
  }

  .server:hover {
    background: var(--hover);
  }

  .server.active {
    background: var(--selection);
  }

  .check {
    display: grid;
    place-items: center;
    width: 16px;
    height: 16px;
    flex: 0 0 16px;
    padding: 0;
    border: 1px solid var(--border-strong);
    border-radius: 4px;
    background: transparent;
    color: #fff;
  }

  .check:hover {
    border-color: var(--accent);
  }

  .check.on {
    background: var(--accent);
    border-color: var(--accent);
  }

  .tick {
    font-size: 11px;
    line-height: 1;
  }

  .pick-bar {
    display: flex;
    align-items: center;
    gap: 6px;
    margin: 0 8px 6px;
    padding: 5px 9px;
    background: var(--selection);
    border: 1px solid color-mix(in srgb, var(--accent) 40%, transparent);
    border-radius: var(--radius-sm);
    color: var(--text);
    font-size: 11.5px;
  }

  .pick-bar .grow {
    flex: 1;
  }

  .pick-btn {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px 8px;
    border-radius: 4px;
    color: var(--dim);
    font-size: 11px;
  }

  .pick-btn:hover {
    background: var(--hover);
    color: var(--text);
  }

  .pick-btn.danger {
    color: var(--error);
  }

  .status {
    width: 8px;
    height: 8px;
    flex: 0 0 8px;
    border-radius: 50%;
    background: var(--faint);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--faint) 14%, transparent);
  }

  .status.up {
    background: var(--success);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--success) 16%, transparent);
  }

  .status.down {
    background: var(--error);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--error) 16%, transparent);
  }

  .status.badpass {
    background: var(--warn);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--warn) 16%, transparent);
  }

  .icon-wrap {
    display: grid;
    place-items: center;
  }

  .probe-wrap {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 0 2px;
  }

  .probe-bar {
    flex: 1;
    height: 5px;
    overflow: hidden;
    border-radius: 3px;
    background: var(--panel);
    border: 1px solid var(--border);
  }

  .probe-fill {
    height: 100%;
    background: var(--accent);
    transition: width 0.18s linear;
  }

  .probe-label {
    color: var(--faint);
    font-size: 10.5px;
    font-variant-numeric: tabular-nums;
  }

  .spin {
    animation: spin 0.9s linear infinite;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .probe {
    color: var(--faint);
    font-size: 10.5px;
    font-family: var(--mono);
  }

  .restore {
    display: flex;
    align-items: center;
    gap: 9px;
    padding: 8px 10px;
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    border: 1px solid color-mix(in srgb, var(--accent) 35%, transparent);
    border-radius: var(--radius-sm);
    color: var(--dim);
    font-size: 11.5px;
  }

  .restore-text {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .restore-btn {
    padding: 4px 9px;
    border-radius: var(--radius-sm);
    color: var(--accent);
    font-size: 11.5px;
    font-weight: 600;
  }

  .restore-btn:hover {
    background: var(--hover);
  }

  .restore-x {
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    border-radius: 4px;
    color: var(--faint);
  }

  .restore-x:hover {
    background: var(--hover);
    color: var(--text);
  }

  .info {
    flex: 1;
    min-width: 0;
  }

  .s-name {
    font-size: 12.5px;
    color: var(--text);
  }

  .s-sub {
    font-size: 11px;
    color: var(--faint);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .tags {
    display: flex;
    gap: 5px;
  }

  .tag {
    padding: 3px 7px;
    border-radius: 5px;
    background: var(--panel-subtle);
    color: var(--dim);
    font-size: 10.5px;
  }

  .edit {
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    border-radius: 5px;
    color: var(--faint);
    opacity: 0;
  }

  .server:hover .edit {
    opacity: 1;
  }

  .edit:hover {
    background: var(--selection);
    color: var(--accent);
  }

  .overlay {
    position: fixed;
    inset: 0;
    display: grid;
    place-items: center;
    background: rgba(0, 0, 0, 0.4);
    z-index: 90;
  }

  .group-dialog {
    width: 360px;
    padding: 16px 18px 12px;
    background: var(--menu);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
  }

  .group-title {
    margin-bottom: 12px;
    font-size: 13px;
    font-weight: 600;
  }

  .group-dialog input {
    width: 100%;
    height: 32px;
    padding: 0 9px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--text);
    outline: none;
  }

  .group-dialog input:focus {
    border-color: var(--accent);
  }

  .menu-backdrop {
    position: fixed;
    inset: 0;
    z-index: 100;
  }

  .context {
    position: fixed;
    z-index: 110;
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
    color: var(--text);
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

  .group-dialog select {
    width: 100%;
    height: 32px;
    margin-bottom: 8px;
    padding: 0 8px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--text);
    font-size: 12.5px;
  }

  .group-dialog.import {
    width: 400px;
  }

  .import-line {
    padding: 2px 0;
    color: var(--dim);
    font-size: 12px;
  }

  .import-errors {
    max-height: 180px;
    margin-top: 8px;
    padding: 8px 10px;
    overflow: auto;
    background: var(--panel);
    border: 1px solid rgba(248, 81, 73, 0.4);
    border-radius: var(--radius-sm);
    color: var(--error);
    font-family: var(--mono);
    font-size: 10.5px;
    line-height: 1.5;
  }

  .toast {
    position: fixed;
    right: 26px;
    bottom: 24px;
    padding: 8px 12px;
    background: var(--panel);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius-sm);
    color: var(--text);
    font-size: 11.5px;
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.35);
    z-index: 130;
  }

  .group-foot {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 14px;
  }

  .gbtn {
    padding: 6px 12px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--raised);
    font-size: 12px;
  }

  .gbtn:hover {
    background: var(--hover);
  }

  .gbtn.primary {
    background: var(--accent);
    border-color: transparent;
    color: #fff;
    font-weight: 600;
  }

  .enter {
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    border-radius: 5px;
    color: var(--dim);
  }

  .enter:hover {
    background: var(--selection);
    color: var(--accent);
  }

  .empty {
    padding: 28px;
    text-align: center;
    color: var(--faint);
    font-size: 12px;
  }
</style>
