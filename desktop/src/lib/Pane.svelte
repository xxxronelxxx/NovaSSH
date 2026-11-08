<script lang="ts">
  import { formatBytes, type DirListing, type Entry } from "./api";
  import { iconColor, iconFor } from "./fileIcon";

  let {
    title,
    listing,
    selected = null,
    onSelect,
    onOpen,
    onUp,
    onPath,
    onRefresh,
  }: {
    title: string;
    listing: DirListing | null;
    selected?: string | null;
    onSelect: (entry: Entry) => void;
    onOpen: (entry: Entry) => void;
    onUp: () => void;
    onPath: (path: string) => void;
    onRefresh: () => void;
  } = $props();

  let input = $state("");

  $effect(() => {
    if (listing) input = listing.path;
  });

  const sorted = $derived(
    [...(listing?.entries ?? [])].sort((a, b) => {
      const dir = Number(b.kind === "dir") - Number(a.kind === "dir");
      return dir || a.name.localeCompare(b.name, "ru");
    }),
  );

  function submit() {
    if (input.trim()) onPath(input.trim());
  }
</script>

<section class="pane">
  <header class="pane-head">
    <span class="pane-title">{title}</span>
    <button class="tool" title="Вверх" onclick={onUp} disabled={!listing?.parent}>↑</button>
    <button class="tool" title="Обновить" onclick={onRefresh}>⟳</button>
  </header>
  <div class="path">
    <input
      value={input}
      oninput={(e) => (input = (e.target as HTMLInputElement).value)}
      onkeydown={(e) => e.key === "Enter" && submit()}
      spellcheck="false"
    />
  </div>
  <div class="rows">
    {#each sorted as entry (entry.path)}
      <button
        class="row"
        class:sel={selected === entry.path}
        onpointerdown={() => onSelect(entry)}
        ondblclick={() => onOpen(entry)}
      >
        <span class="ico" style:color={iconColor(entry)}>{iconFor(entry)}</span>
        <span class="name" class:hidden={entry.hidden}>{entry.name}</span>
        <span class="size">{entry.kind === "dir" ? "" : formatBytes(entry.size)}</span>
      </button>
    {:else}
      <div class="empty">{listing ? "Пусто" : "Нет данных"}</div>
    {/each}
  </div>
  <footer class="pane-foot">
    {#if listing}
      <span>{sorted.length} объектов</span>
      {#if listing.freeSpace != null}
        <span>свободно {formatBytes(listing.freeSpace)}</span>
      {/if}
    {:else}
      <span>—</span>
    {/if}
  </footer>
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

  .pane-head {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 6px 10px;
    background: rgba(0, 0, 0, 0.18);
    border-bottom: 1px solid var(--border);
  }

  .pane-title {
    flex: 1;
    font-size: 11px;
    letter-spacing: 0.8px;
    text-transform: uppercase;
    color: var(--faint);
  }

  .tool {
    width: 24px;
    height: 22px;
    border-radius: var(--radius-sm);
    color: var(--dim);
    font-size: 14px;
  }

  .tool:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.08);
    color: var(--text);
  }

  .tool:disabled {
    opacity: 0.35;
    cursor: default;
  }

  .path {
    padding: 6px 8px;
    border-bottom: 1px solid var(--border);
  }

  .path input {
    width: 100%;
    padding: 6px 9px;
    background: rgba(0, 0, 0, 0.28);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    font-size: 12px;
    font-family: var(--mono);
    outline: none;
  }

  .path input:focus {
    border-color: var(--accent);
  }

  .rows {
    flex: 1;
    overflow: auto;
    padding: 4px 0;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    height: 26px;
    padding: 0 10px;
    text-align: left;
    font-size: 12.5px;
  }

  .row:hover {
    background: rgba(255, 255, 255, 0.04);
  }

  .row.sel {
    background: var(--selection);
  }

  .ico {
    width: 18px;
    text-align: center;
    font-size: 13px;
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

  .size {
    width: 74px;
    text-align: right;
    font-size: 11px;
    color: var(--faint);
    font-family: var(--mono);
  }

  .empty {
    padding: 18px;
    text-align: center;
    color: var(--faint);
    font-size: 12px;
  }

  .pane-foot {
    display: flex;
    justify-content: space-between;
    padding: 5px 10px;
    border-top: 1px solid var(--border);
    font-size: 10.5px;
    color: var(--faint);
  }
</style>
