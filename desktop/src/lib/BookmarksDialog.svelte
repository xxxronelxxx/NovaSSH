<script lang="ts">
  import { onMount } from "svelte";
  import { FolderOpen, Plus, Trash2, X } from "lucide-svelte";
  import { api, type Settings } from "../lib/api";

  let {
    settings,
    remote,
    current,
    onClose,
    onOpen,
  }: {
    settings: Settings;
    remote: boolean;
    current: string;
    onClose: () => void;
    onOpen: (path: string) => void;
  } = $props();

  let list = $state<string[]>([]);
  let draft = $state("");
  let error = $state<string | null>(null);

  onMount(() => {
    const saved = remote
      ? settings.panels.remoteBookmarks
      : settings.panels.localBookmarks;
    list = [...(saved ?? [])];
    draft = current;
  });

  async function persist() {
    const panels = {
      ...settings.panels,
      localBookmarks: remote ? (settings.panels.localBookmarks ?? []) : list,
      remoteBookmarks: remote ? list : (settings.panels.remoteBookmarks ?? []),
    };
    settings.panels = panels;
    try {
      await api.saveSettings(settings);
    } catch (e) {
      error = String(e);
    }
  }

  async function add() {
    const path = draft.trim();
    if (!path || list.includes(path)) return;
    list = [...list, path];
    await persist();
  }

  async function remove(path: string) {
    list = list.filter((item) => item !== path);
    await persist();
  }
</script>

<div class="overlay" onclick={onClose}>
  <div class="dialog" onclick={(e) => e.stopPropagation()}>
    <div class="head">
      <span>{remote ? "Закладки · сервер" : "Закладки · локально"}</span>
      <span class="grow"></span>
      <button class="icon" title="Закрыть" onclick={onClose}><X size={15} /></button>
    </div>

    <div class="list">
      {#each list as path (path)}
        <div class="item">
          <button class="open" title="Перейти" onclick={() => { onOpen(path); onClose(); }}>
            <FolderOpen size={13} />
            <span>{path}</span>
          </button>
          <button class="icon" title="Удалить" onclick={() => remove(path)}>
            <Trash2 size={13} />
          </button>
        </div>
      {:else}
        <div class="empty">Закладок пока нет</div>
      {/each}
    </div>

    <div class="add-row">
      <input bind:value={draft} placeholder="/var/www/site" spellcheck="false" />
      <button class="btn primary" onclick={add}><Plus size={13} /> Добавить</button>
    </div>

    {#if error}<div class="error">{error}</div>{/if}
  </div>
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    display: grid;
    place-items: center;
    background: rgba(0, 0, 0, 0.45);
    z-index: 115;
  }

  .dialog {
    width: 560px;
    max-width: 92vw;
    padding: 14px 16px;
    background: var(--menu);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.5);
  }

  .head {
    display: flex;
    align-items: center;
    margin-bottom: 10px;
    font-size: 13px;
    font-weight: 600;
  }

  .grow {
    flex: 1;
  }

  .icon {
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    border-radius: 5px;
    color: var(--faint);
  }

  .icon:hover {
    background: var(--hover);
    color: var(--text);
  }

  .list {
    max-height: 300px;
    overflow: auto;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
  }

  .item {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 2px 6px;
    border-bottom: 1px solid var(--border);
  }

  .item:last-child {
    border-bottom: 0;
  }

  .item:hover {
    background: var(--hover);
  }

  .open {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1;
    min-width: 0;
    height: 30px;
    color: var(--dim);
    font-family: var(--mono);
    font-size: 11.5px;
    text-align: left;
  }

  .open:hover {
    color: var(--text);
  }

  .open span {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .empty {
    padding: 24px;
    text-align: center;
    color: var(--faint);
    font-size: 11.5px;
  }

  .add-row {
    display: flex;
    gap: 8px;
    margin-top: 10px;
  }

  .add-row input {
    flex: 1;
    height: 32px;
    padding: 0 9px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--text);
    font-family: var(--mono);
    font-size: 12px;
    outline: none;
  }

  .add-row input:focus {
    border-color: var(--accent);
  }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 6px 12px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--raised);
    color: var(--text);
    font-size: 12px;
  }

  .btn.primary {
    background: var(--accent);
    border-color: transparent;
    color: #fff;
    font-weight: 600;
  }

  .error {
    margin-top: 8px;
    color: var(--error);
    font-size: 11.5px;
  }
</style>
