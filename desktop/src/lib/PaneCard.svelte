<script lang="ts">
  import { onMount } from "svelte";
  import { HardDrive, Network, PanelLeft, Plus, X } from "lucide-svelte";
  import FileIcon from "./FileIcon.svelte";
  import {
    formatBytes,
    formatDate,
    formatMode,
    type ColorRule,
    type DirListing,
    type Entry,
    api,
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
    selected = [],
    focused = false,
    filter = "",
    canAdd = false,
    rootLabel,
    otherNames,
    otherEntries,
    compareMode = false,
    onSelectTab,
    onCloseTab,
    onReorderTab,
    onTabMenu,
    onContextMenu,
    onDrop,
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
    selected?: string[];
    focused?: boolean;
    filter?: string;
    canAdd?: boolean;
    rootLabel?: string;
    otherNames?: Set<string>;
    otherEntries?: Entry[];
    compareMode?: boolean;
    onSelectTab: (id: string) => void;
    onCloseTab?: (id: string) => void;
    onReorderTab?: (fromId: string, toId: string) => void;
    onTabMenu?: (id: string, event: MouseEvent) => void;
    onContextMenu?: (entry: Entry | null, event: MouseEvent) => void;
    onAdd: () => void;
    onUp: () => void;
    onRefresh: () => void;
    onPath: (path: string) => void;
    onSelect: (entry: Entry, mode: "single" | "toggle" | "range") => void;
    onOpen: (entry: Entry) => void;
    onFocus: () => void;
    onDrop?: (source: "local" | "remote", paths: string[]) => void;
  } = $props();

  let anchor = $state<string | null>(null);
  let rules = $state<ColorRule[]>([]);
  let sortKey = $state<"name" | "size" | "mode" | "modified">("name");
  let sortAsc = $state(true);
  let dragOver = $state(false);
  let editingPath = $state(false);
  let pathDraft = $state("");
  let root: HTMLElement | undefined = $state();
  let pointerDrag = $state<{
    x: number;
    y: number;
    paths: string[];
  } | null>(null);

  function beginPathEdit() {
    if (!listing) return;
    pathDraft = listing.path;
    editingPath = true;
  }

  function commitPath() {
    const next = pathDraft.trim();
    editingPath = false;
    if (next && next !== listing?.path) onPath(next);
  }

  const selectedSet = $derived(new Set(selected));

  const compareMap = $derived(
    new Map(
      (otherEntries ?? []).map((entry) => [
        entry.name.toLowerCase(),
        entry,
      ]),
    ),
  );

  function compareState(entry: Entry): string | null {
    if (!compareMode && !otherNames) return null;
    const other = compareMap.get(entry.name.toLowerCase());
    if (!other) return "only";
    if (other.kind !== entry.kind) return "different";
    if (entry.kind !== "dir" && other.size !== entry.size) return "different";
    return "equal";
  }

  onMount(async () => {
    try {
      const book = await api.loadColorRules();
      rules = book.rules
        .filter(
          (rule) =>
            rule.enabled &&
            (rule.scope === "both" || rule.scope === variant),
        )
        .sort((a, b) => b.priority - a.priority);
    } catch {
      rules = [];
    }
  });

  function ruleColor(style: string): string | null {
    const found = /(?:^|;)color:([^;]+)/.exec(style);
    return found ? found[1] : null;
  }

  function matches(rule: ColorRule, name: string): boolean {
    if (rule.isRegex) {
      try {
        return new RegExp(rule.pattern, "i").test(name);
      } catch {
        return false;
      }
    }
    const escaped = rule.pattern
      .replace(/[.+^${}()|[\]\\]/g, "\\$&")
      .replace(/\*/g, ".*")
      .replace(/\?/g, ".");
    try {
      return new RegExp(`^${escaped}$`, "i").test(name);
    } catch {
      return false;
    }
  }

  function ruleStyle(entry: Entry): string | null {
    for (const rule of rules) {
      if (!matches(rule, entry.name)) continue;
      const parts: string[] = [];
      if (rule.fg) parts.push(`color:${rule.fg}`);
      if (rule.bg) parts.push(`background:${rule.bg}`);
      if (rule.bold) parts.push("font-weight:700");
      if (rule.italic) parts.push("font-style:italic");
      if (rule.underline) parts.push("text-decoration:underline");
      return parts.length ? parts.join(";") : null;
    }
    return null;
  }

  function sortValue(entry: Entry): string | number {
    switch (sortKey) {
      case "size":
        return entry.size;
      case "mode":
        return entry.mode ?? 0;
      case "modified":
        return entry.modified;
      default:
        return entry.name.toLocaleLowerCase("ru");
    }
  }

  function toggleSort(key: "name" | "size" | "mode" | "modified") {
    if (sortKey === key) sortAsc = !sortAsc;
    else {
      sortKey = key;
      sortAsc = key === "name";
    }
  }

  const sortMark = $derived((key: string) =>
    sortKey === key ? (sortAsc ? " ↑" : " ↓") : "",
  );

  const lowerFilter = $derived(filter.trim().toLowerCase());

  const entries = $derived.by(() => {
    const list = [...(listing?.entries ?? [])].sort((a, b) => {
      const dir = Number(b.kind === "dir") - Number(a.kind === "dir");
      if (dir) return dir;
      const left = sortValue(a);
      const right = sortValue(b);
      const result =
        typeof left === "number" && typeof right === "number"
          ? left - right
          : String(left).localeCompare(String(right), "ru", {
              sensitivity: "base",
            });
      return sortAsc ? result : -result;
    });
    if (!lowerFilter) return list;
    return list.filter((entry) =>
      entry.name.toLowerCase().includes(lowerFilter),
    );
  });

  function handleSelect(entry: Entry, event: PointerEvent | MouseEvent) {
    if (event.shiftKey && anchor) {
      onSelect(entry, "range");
    } else if (event.ctrlKey || event.metaKey) {
      anchor = entry.path;
      onSelect(entry, "toggle");
    } else {
      anchor = entry.path;
      onSelect(entry, "single");
    }
  }

  function startPointerDrag(entry: Entry, event: PointerEvent) {
    if (event.button !== 0) return;
    pointerDrag = {
      x: event.clientX,
      y: event.clientY,
      paths: selectedSet.has(entry.path) ? [...selected] : [entry.path],
    };
  }

  function pointerMove(event: PointerEvent) {
    const start = pointerDrag;
    if (!start) return;
    if (Math.abs(event.clientX - start.x) < 6 && Math.abs(event.clientY - start.y) < 6) {
      return;
    }
    (window as any).__novaDrag = { source: variant, paths: start.paths };
  }

  function pointerUp(event: PointerEvent) {
    const start = pointerDrag;
    pointerDrag = null;
    const payload = (window as any).__novaDrag as
      | { source: "local" | "remote"; paths: string[] }
      | undefined;
    if (!payload) return;
    const element = document.elementFromPoint(event.clientX, event.clientY);
    const inside = !!root && !!element && root.contains(element);
    if (inside && payload.source !== variant) {
      onDrop?.(payload.source, payload.paths);
      delete (window as any).__novaDrag;
    } else {
      // Clear leftovers so a later click inside a pane does not re-drop.
      setTimeout(() => {
        if ((window as any).__novaDrag === payload) {
          delete (window as any).__novaDrag;
        }
      }, 0);
    }
  }

  function startDrag(entry: Entry, event: DragEvent) {
    const paths = selectedSet.has(entry.path) ? [...selected] : [entry.path];
    event.dataTransfer?.setData(
      "application/x-nova-paths",
      JSON.stringify({ source: variant, paths }),
    );
    if (event.dataTransfer) event.dataTransfer.effectAllowed = "copy";
  }

  function handleDrop(event: DragEvent) {
    dragOver = false;
    const raw = event.dataTransfer?.getData("application/x-nova-paths");
    if (!raw) return;
    event.preventDefault();
    try {
      const payload = JSON.parse(raw) as {
        source: "local" | "remote";
        paths: string[];
      };
      if (Array.isArray(payload.paths) && payload.paths.length) {
        onDrop?.(payload.source, payload.paths);
      }
    } catch {
      // ignore malformed payloads
    }
  }

  interface Crumb {
    label: string;
    value: string;
  }

  const crumbs = $derived.by((): Crumb[] => {
    const path = listing?.path ?? "";
    if (!path) return [];
    if (rootLabel) {
      const parts = path.split("/").filter(Boolean);
      const result: Crumb[] = [{ label: rootLabel, value: "" }];
      let acc = "";
      for (const part of parts) {
        acc += `/${part}`;
        result.push({ label: part, value: acc });
      }
      return result;
    }
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

<svelte:window onpointermove={pointerMove} onpointerup={pointerUp} onpointercancel={pointerUp} />

<section
  class="pane"
  class:focused
  class:drag-over={dragOver}
  data-pane={variant}
  bind:this={root}
  onpointerdown={onFocus}
>
  <div class="tabs">
    <span class="tab-icon" title="Панель">
      <PanelLeft size={15} />
    </span>
    {#each tabs as tab (tab.id)}
      <div
        class="tab"
        class:active={tab.id === activeTab}
        title={tab.hint ?? tab.label}
        oncontextmenu={(event) => {
          if (onTabMenu) {
            event.preventDefault();
            onTabMenu(tab.id, event);
          }
        }}
        draggable="true"
        ondragstart={(event) => {
          event.dataTransfer?.setData("application/x-nova-tab", tab.id);
        }}
        ondragover={(event) => {
          if (event.dataTransfer?.types.includes("application/x-nova-tab")) {
            event.preventDefault();
          }
        }}
        ondrop={(event) => {
          const from = event.dataTransfer?.getData("application/x-nova-tab");
          if (from && from !== tab.id) onReorderTab?.(from, tab.id);
        }}
      >
        <button class="tab-label" onclick={() => onSelectTab(tab.id)}>
          {#if variant === "remote"}
            <Network size={14} />
          {:else}
            <HardDrive size={14} />
          {/if}
          <span>{tab.label}</span>
        </button>
        {#if variant === "remote" && onCloseTab}
          <button
            class="tab-close"
            title="Закрыть вкладку"
            onclick={(e) => {
              e.stopPropagation();
              onCloseTab(tab.id);
            }}
          >
            <X size={11} />
          </button>
        {/if}
      </div>
    {/each}
    {#if canAdd}
      <button class="add" title="Добавить сервер" onclick={onAdd}>
        <Plus size={15} />
      </button>
    {/if}
  </div>

  <div
    class="crumbs"
    title="Двойной клик — изменить путь"
    ondblclick={beginPathEdit}
  >
    {#if editingPath}
      <input
        class="path-input"
        bind:value={pathDraft}
        autofocus
        spellcheck="false"
        onfocus={(event) => event.currentTarget.select()}
        onkeydown={(event) => {
          if (event.key === "Enter") {
            event.preventDefault();
            commitPath();
          } else if (event.key === "Escape") {
            event.preventDefault();
            editingPath = false;
          }
        }}
        onblur={commitPath}
      />
      <button
        class="path-ok"
        title="Перейти"
        onmousedown={(event) => event.preventDefault()}
        onclick={commitPath}
      >
        →
      </button>
    {:else}
      {#each crumbs as crumb, index (crumb.value)}
        {#if index > 0}<span class="slash">›</span>{/if}
        <button class="crumb" onclick={() => onPath(crumb.value)}>
          {crumb.label}
        </button>
      {/each}
    {/if}
  </div>

  <div class="head">
    <button class="col name" onclick={() => toggleSort("name")}>
      Имя <span class="sort">{sortMark("name")}</span>
    </button>
    <button class="col size" onclick={() => toggleSort("size")}>
      Размер<span class="sort">{sortMark("size")}</span>
    </button>
    <button class="col perms" onclick={() => toggleSort("mode")}>
      Права<span class="sort">{sortMark("mode")}</span>
    </button>
    <button class="col date" onclick={() => toggleSort("modified")}>
      Изменён<span class="sort">{sortMark("modified")}</span>
    </button>
  </div>

  <div
    class="rows"
    ondragover={(event) => {
      if (event.dataTransfer?.types.includes("application/x-nova-paths")) {
        event.preventDefault();
        dragOver = true;
      }
    }}
    ondragleave={() => (dragOver = false)}
    ondrop={handleDrop}
    oncontextmenu={(event) => {
      event.preventDefault();
      onContextMenu?.(null, event);
    }}
  >
    {#if listing?.parent || rootLabel}
      <button class="row" ondblclick={onUp} title="На уровень выше">
        <span class="parent-ico">↩</span>
        <span class="name parent-name">..</span>
        <span class="size"></span>
        <span class="perms"></span>
        <span class="date"></span>
      </button>
    {/if}

    {#each entries as entry (entry.path)}
      {@const style = ruleStyle(entry)}
      <button
        class="row"
        class:selected={selectedSet.has(entry.path)}
        class:only-here={(compareMode || otherNames) && compareState(entry) === "only"}
        class:different={compareState(entry) === "different"}
        draggable="false"
        onpointerdown={(event) => {
          if (event.button === 0) {
            handleSelect(entry, event);
            startPointerDrag(entry, event);
          }
        }}
        ondblclick={() => onOpen(entry)}
        oncontextmenu={(event) => {
          event.preventDefault();
          event.stopPropagation();
          if (!selectedSet.has(entry.path)) {
            handleSelect(entry, event);
          }
          onContextMenu?.(entry, event);
        }}
      >
        <FileIcon entry={entry} override={style ? ruleColor(style) : null} />
        <span class="name" class:hidden={entry.hidden} style={style ?? ""}>{entry.name}</span>
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

  .pane.drag-over {
    border-color: var(--accent);
    box-shadow: inset 0 0 0 1px var(--accent);
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
    height: 29px;
    margin-bottom: 3px;
    padding: 0 4px 0 2px;
    border: 1px solid transparent;
    border-bottom: 0;
    border-radius: 6px 6px 0 0;
    color: var(--dim);
    font-size: 12px;
    max-width: 210px;
    overflow: hidden;
    white-space: nowrap;
  }

  .tab-label {
    display: flex;
    align-items: center;
    gap: 7px;
    height: 100%;
    min-width: 0;
    padding: 0 7px;
    color: inherit;
  }

  .tab-label span {
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

  .tab-close {
    display: grid;
    place-items: center;
    width: 18px;
    height: 18px;
    border-radius: 4px;
    color: var(--faint);
    opacity: 0;
  }

  .tab:hover .tab-close,
  .tab.active .tab-close {
    opacity: 1;
  }

  .tab-close:hover {
    background: var(--selection);
    color: var(--text);
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

  .path-input {
    flex: 1;
    min-width: 0;
    height: 24px;
    padding: 0 7px;
    border: 1px solid var(--accent);
    border-radius: 4px;
    background: var(--panel);
    color: var(--text);
    font-family: var(--mono);
    font-size: 11.5px;
    outline: none;
  }

  .path-ok {
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    border-radius: 4px;
    color: var(--accent);
    font-size: 13px;
  }

  .path-ok:hover {
    background: var(--hover);
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
    padding: 0;
    border: 0;
    background: transparent;
    color: var(--faint);
    font-size: 11px;
    text-align: left;
  }

  button.col:hover {
    color: var(--text);
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

  .row.only-here .name {
    color: var(--accent);
  }

  .row.different .name {
    color: var(--warn);
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
