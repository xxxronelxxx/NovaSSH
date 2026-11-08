<script lang="ts">
  import { HardDrive, Network, PanelLeft, Plus } from "lucide-svelte";
  import FileIcon from "./FileIcon.svelte";
  import {
    formatBytes,
    formatDate,
    formatMode,
    sortEntries,
    type DirListing,
    type Entry,
  } from "./api";

  export interface PaneTab {
    id: string;
    label: string;
    hint?: string;
  }

  let {
    variant,
    tabs,
    activeTab,
    listing,
    selected = null,
    focused = false,
    filter = "",
    canAdd = false,
    onSelectTab,
    onAdd,
    onUp,
    onRefresh,
    onPath,
    onSelect,
    onOpen,
    onFocus,
  }: {
    variant: "local" | "remote";
    tabs: PaneTab[];
    activeTab: string;
    listing: DirListing | null;
    selected?: string | null;
    focused?: boolean;
    filter?: string;
    canAdd?: boolean;
    onSelectTab: (id: string) => void;
    onAdd: () => void;
    onUp: () => void;
    onRefresh: () => void;
    onPath: (path: string) => void;
    onSelect: (entry: Entry) => void;
    onOpen: (entry: Entry) => void;
    onFocus: () => void;
  } = $props();

  const lowerFilter = $derived(filter.trim().toLowerCase());

  const entries = $derived.by(() => {
    const list = sortEntries(listing?.entries ?? []);
    if (!lowerFilter) return list;
    return list.filter((entry) =>
      entry.name.toLowerCase().includes(lowerFilter),
    );
  });

  interface Crumb {
    label: string;
    value: string;
  }

  const crumbs = $derived.by((): Crumb[] => {
    const path = listing?.path ?? "";
    if (!path) return [];
    if (/^[A-Za-z]:/.test(path)) {
      const parts = path.replace(/\\/g, "/").split("/").filter(Boolean);
      let acc = "";
      return parts.map((part, index) => {
        acc = index === 0 ? `${part}\\` : `${acc.replace(/\\$/, "")}\\${part}`;
        return { label: part, value: acc };
      });
    }
    const parts = path.split("/").filter(Boolean);
    const result: Crumb[] = [{ label: "/", value: "/" }];
    let acc = "";
    for (const part of parts) {
      acc += `/${part}`;
      result.push({ label: part, value: acc });
    }
    return result;
  });

  const freeSpace = $derived(
    listing?.freeSpace != null ? formatBytes(listing.freeSpace) : "",
  );
</script>

<section
  class="pane"
  class:focused
  onpointerdown={onFocus}
>
  <div class="tabs">
    <span class="tab-icon" title="Панель">
      <PanelLeft size={15} />
    </span>
    {#each tabs as tab (tab.id)}
      <button
        class="tab"
        class:active={tab.id === activeTab}
        title={tab.hint ?? tab.label}
        onclick={() => onSelectTab(tab.id)}
      >
        {#if variant === "remote"}
          <Network size={14} />
        {:else}
          <HardDrive size={14} />
        {/if}
        <span>{tab.label}</span>
      </button>
    {/each}
    {#if canAdd}
      <button class="add" title="Добавить сервер" onclick={onAdd}>
        <Plus size={15} />
      </button>
    {/if}
  </div>

  <div class="crumbs">
    {#each crumbs as crumb, index (crumb.value)}
      {#if index > 0}<span class="slash">›</span>{/if}
      <button class="crumb" onclick={() => onPath(crumb.value)}>
        {crumb.label}
      </button>
    {/each}
  </div>

  <div class="head">
    <span class="col name">Имя <span class="sort">↑</span></span>
    <span class="col size">Размер</span>
    <span class="col perms">Права</span>
    <span class="col date">Изменён</span>
  </div>

  <div class="rows" onwheel={() => {}}>
    {#if listing?.parent}
      <button class="row" ondblclick={onUp} title="На уровень выше">
        <span class="parent-ico">↩</span>
        <span class="name parent-name">..</span>
        <span class="size"></span>
        <span class="perms"></span>
        <span class="date"></span>
      </button>
    {/if}

    {#each entries as entry (entry.path)}
      <button
        class="row"
        class:selected={selected === entry.path}
        onpointerdown={() => onSelect(entry)}
        ondblclick={() => onOpen(entry)}
      >
        <FileIcon entry={entry} />
        <span class="name" class:hidden={entry.hidden}>{entry.name}</span>
        <span class="size">{entry.kind === "dir" ? "" : formatBytes(entry.size)}</span>
        <span class="perms">{formatMode(entry.mode)}</span>
        <span class="date">{formatDate(entry.modified)}</span>
      </button>
    {:else}
      <div class="empty">{listing ? "Пусто" : "Нет данных"}</div>
    {/each}
  </div>

  <div class="foot">
    <span>{entries.length} объектов</span>
    {#if freeSpace}
      <span>свободно {freeSpace}</span>
    {/if}
  </div>
</section>

<style>
  .pane {
    display: flex;
    flex-direction: column;
    min-width: 0;
    min-height: 0;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow: hidden;
  }

  .pane.focused {
    border-color: color-mix(in srgb, var(--accent) 45%, var(--border));
  }

  .tabs {
    display: flex;
    align-items: flex-end;
    gap: 3px;
    height: 38px;
    min-height: 38px;
    padding: 0 8px;
    background: var(--panel-header);
    border-bottom: 1px solid var(--border);
  }

  .tab-icon {
    display: grid;
    place-items: center;
    width: 26px;
    height: 28px;
    margin-bottom: 4px;
    color: var(--faint);
  }

  .tab {
    display: flex;
    align-items: center;
    gap: 7px;
    height: 29px;
    margin-bottom: 3px;
    padding: 0 11px;
    border: 1px solid transparent;
    border-bottom: 0;
    border-radius: 6px 6px 0 0;
    color: var(--dim);
    font-size: 12px;
    max-width: 190px;
    overflow: hidden;
    white-space: nowrap;
  }

  .tab span {
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .tab:hover {
    color: var(--text);
    background: var(--hover);
  }

  .tab.active {
    background: var(--panel);
    border-color: color-mix(in srgb, var(--accent) 55%, var(--border));
    color: var(--text);
  }

  .tab.active svg {
    color: var(--accent);
  }

  .add {
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    margin: 0 0 7px 4px;
    border-radius: 50%;
    background: var(--success);
    color: #fff;
  }

  .add:hover {
    filter: brightness(1.1);
  }

  .crumbs {
    display: flex;
    align-items: center;
    gap: 2px;
    height: 34px;
    min-height: 34px;
    padding: 0 12px;
    border-bottom: 1px solid var(--border);
    overflow: hidden;
    white-space: nowrap;
  }

  .slash {
    color: var(--faint);
    font-size: 11px;
  }

  .crumb {
    padding: 3px 5px;
    border-radius: 4px;
    color: var(--dim);
    font-size: 12px;
    font-family: var(--mono);
  }

  .crumb:hover {
    background: var(--hover);
    color: var(--text);
  }

  .crumb:last-child {
    color: var(--text);
    text-decoration: underline;
    text-underline-offset: 3px;
    text-decoration-color: var(--faint);
  }

  .head {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 28px;
    min-height: 28px;
    padding: 0 10px;
    border-bottom: 1px solid var(--border);
    color: var(--faint);
    font-size: 11px;
  }

  .col {
    flex: 0 0 auto;
  }

  .col.name {
    flex: 1;
    min-width: 0;
  }

  .col.size {
    width: 90px;
    text-align: right;
  }

  .col.perms {
    width: 58px;
    text-align: right;
  }

  .col.date {
    width: 130px;
    text-align: right;
  }

  .sort {
    font-size: 9px;
  }

  .rows {
    flex: 1;
    min-height: 0;
    overflow: auto;
    padding: 3px 0;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    height: var(--row-height);
    padding: 0 10px;
    text-align: left;
    font-size: var(--row-font);
  }

  .row:hover {
    background: var(--hover);
  }

  .row.selected {
    background: var(--selection);
  }

  .name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .name.hidden {
    color: var(--faint);
  }

  .parent-ico {
    width: 18px;
    color: var(--archive);
    text-align: center;
  }

  .parent-name {
    color: var(--dim);
  }

  .size {
    width: 90px;
    text-align: right;
    font-size: 11px;
    color: var(--faint);
    font-family: var(--mono);
  }

  .perms {
    width: 58px;
    text-align: right;
    font-size: 10.5px;
    color: var(--faint);
    font-family: var(--mono);
  }

  .date {
    width: 130px;
    text-align: right;
    font-size: 10.5px;
    color: var(--faint);
  }

  .empty {
    padding: 24px;
    text-align: center;
    color: var(--faint);
    font-size: 12px;
  }

  .foot {
    display: flex;
    justify-content: space-between;
    height: 30px;
    min-height: 30px;
    align-items: center;
    padding: 0 12px;
    border-top: 1px solid var(--border);
    color: var(--faint);
    font-size: 10.5px;
  }
</style>
