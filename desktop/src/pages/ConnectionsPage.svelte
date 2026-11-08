<script lang="ts">
  import {
    ArrowRight,
    Folder,
    FolderPlus,
    Grid2x2,
    KeyRound,
    Lock,
    Plus,
    Search,
    Settings2,
  } from "lucide-svelte";
  import type { BrowserTab } from "../lib/browser";
  import type { Group, Server, ServerBook } from "../lib/api";

  let {
    book,
    openTabs = [],
    onConnect,
    onOpenTab,
  }: {
    book: ServerBook | null;
    openTabs?: BrowserTab[];
    onConnect: (server: Server) => void;
    onOpenTab: (id: string) => void;
  } = $props();

  type Protocol = "all" | "ssh" | "ftp" | "s3";

  let search = $state("");
  let group = $state<string | null>(null);
  let protocol = $state<Protocol>("all");
  let selected = $state<string | null>(null);

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
      if (protocol !== "all" && serverProtocol(server) !== protocol) {
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
    <button class="top-btn" title="Импорт из WinSCP" disabled>
      <FolderPlus size={17} />
    </button>
    <button class="top-btn" title="Новый сервер" disabled>
      <Plus size={17} />
    </button>
    <button class="top-btn" title="Продолжить сессию" disabled>
      <ArrowRight size={17} />
    </button>
    <button class="top-btn" title="Ключи" disabled>
      <KeyRound size={17} />
    </button>
    <button class="top-btn" title="Настройки" disabled>
      <Settings2 size={17} />
    </button>
    <button class="top-btn" title="Заблокировать" disabled>
      <Lock size={17} />
    </button>
  </div>

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
        <button class="tiny" title="Новая группа" disabled>
          <Plus size={15} />
        </button>
      </div>
      <button
        class="group"
        class:active={group === null}
        onclick={() => (group = null)}
      >
        <Grid2x2 size={15} class="g-icon" />
        <span class="g-name">Все серверы</span>
        <span class="g-count">{servers.length}</span>
      </button>
      {#each groups as item (item.id)}
        <button
          class="group"
          class:active={group === item.id}
          onclick={() => (group = item.id)}
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
      <button class="new-group" disabled>
        <FolderPlus size={15} />
        Новая группа
      </button>
    </aside>

    <section class="card servers">
      <div class="servers-head">
        <div class="servers-title">
          <span>Все серверы</span>
          <span class="count">{visible.length}</span>
        </div>
        <div class="chips">
          {#each [["all", "Все"], ["ssh", "SSH"], ["ftp", "FTP"], ["s3", "S3"]] as [value, label] (value)}
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

      <div class="server-list">
        {#each visible as server (server.id)}
          <div
            class="server"
            class:active={selected === server.id}
            role="button"
            tabindex="0"
            onpointerdown={() => (selected = server.id)}
            ondblclick={() => connect(server)}
            onkeydown={(e) => e.key === "Enter" && connect(server)}
          >
            <span class="check"></span>
            <span class="status" title="Доступность не проверена"></span>
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
    width: 16px;
    height: 16px;
    flex: 0 0 16px;
    border: 1px solid var(--border-strong);
    border-radius: 4px;
  }

  .status {
    width: 8px;
    height: 8px;
    flex: 0 0 8px;
    border-radius: 50%;
    background: var(--accent);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 16%, transparent);
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
