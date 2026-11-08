<script lang="ts">
  import { onMount } from "svelte";
  import { Channel } from "@tauri-apps/api/core";
  import { X } from "lucide-svelte";
  import {
    api,
    formatBytes,
    type SyncEntry,
    type TransferEvent,
  } from "../lib/api";

  let {
    sessionId,
    localRoot,
    remoteRoot,
    onClose,
    onDone,
  }: {
    sessionId: string;
    localRoot: string;
    remoteRoot: string;
    onClose: () => void;
    onDone: () => void;
  } = $props();

  let mode = $state("upload");
  let entries = $state<SyncEntry[]>([]);
  let selected = $state<Set<string>>(new Set());
  let busy = $state(false);
  let error = $state<string | null>(null);
  let done = $state(0);
  let total = $state(0);
  let current = $state<string>("");

  const actionable = $derived(entries.filter((entry) => entry.action !== "skip"));

  async function scan() {
    busy = true;
    error = null;
    try {
      entries = await api.syncScan(sessionId, localRoot, remoteRoot, mode);
      selected = new Set(
        entries.filter((entry) => entry.action !== "skip").map((entry) => entry.relative),
      );
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  onMount(scan);

  function toggle(relative: string) {
    if (selected.has(relative)) selected.delete(relative);
    else selected.add(relative);
    selected = new Set(selected);
  }

  function all(on: boolean) {
    selected = new Set(
      on ? actionable.map((entry) => entry.relative) : [],
    );
  }

  async function execute() {
    const list = entries.filter(
      (entry) => entry.action !== "skip" && selected.has(entry.relative),
    );
    if (!list.length) return;
    busy = true;
    total = list.length;
    done = 0;
    error = null;
    try {
      for (const entry of list) {
        current = entry.relative;
        const channel = new Channel<TransferEvent>();
        channel.onmessage = () => {};
        await api.transferFile(
          sessionId,
          entry.action,
          entry.action === "upload" ? entry.localPath : entry.remotePath,
          entry.action === "upload" ? remoteRoot : localRoot,
          0,
          0,
          false,
          null,
          channel,
        );
        done += 1;
      }
      await onDone();
      onClose();
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }
</script>

<div class="overlay" onclick={() => !busy && onClose()}>
  <div class="dialog" onclick={(e) => e.stopPropagation()}>
    <div class="head">
      <span>Синхронизация каталогов</span>
      <span class="grow"></span>
      <button class="icon" title="Закрыть" onclick={onClose}><X size={15} /></button>
    </div>

    <div class="paths">
      <div><small>Локально</small>{localRoot}</div>
      <div><small>Сервер</small>{remoteRoot}</div>
    </div>

    <div class="controls">
      <select bind:value={mode} onchange={scan} disabled={busy}>
        <option value="upload">Сервер = локально</option>
        <option value="download">Локально = сервер</option>
        <option value="newer">Более новый файл</option>
      </select>
      <button class="btn" disabled={busy} onclick={scan}>Сканировать</button>
      <span class="grow"></span>
      <button class="btn" disabled={busy} onclick={() => all(true)}>Выбрать всё</button>
      <button class="btn" disabled={busy} onclick={() => all(false)}>Снять всё</button>
      <button class="btn primary" disabled={busy || selected.size === 0} onclick={execute}>
        {busy ? `${done}/${total}` : `Выполнить (${selected.size})`}
      </button>
    </div>

    <div class="list">
      {#each entries as entry (entry.relative)}
        <button
          class="item"
          class:skip={entry.action === "skip"}
          onclick={() => entry.action !== "skip" && toggle(entry.relative)}
        >
          <span class="check" class:checked={selected.has(entry.relative)}></span>
          <span class="action {entry.action}">
            {entry.action === "upload" ? "↑" : entry.action === "download" ? "↓" : "="}
          </span>
          <span class="rel">{entry.relative}</span>
          <span class="reason">{entry.reason}</span>
          <span class="sizes">
            {entry.localSize ? formatBytes(entry.localSize) : "—"} / {entry.remoteSize ? formatBytes(entry.remoteSize) : "—"}
          </span>
        </button>
      {:else}
        <div class="empty">{busy ? "Сканирую…" : "Различий нет"}</div>
      {/each}
    </div>

    {#if busy}
      <div class="progress"><span>{current}</span></div>
    {/if}
    {#if error}
      <div class="error">{error}</div>
    {/if}
  </div>
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    display: grid;
    place-items: center;
    background: rgba(0, 0, 0, 0.45);
    z-index: 110;
  }

  .dialog {
    width: min(900px, 92vw);
    height: min(680px, 86vh);
    display: flex;
    flex-direction: column;
    padding: 12px 14px;
    background: var(--menu);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.5);
  }

  .head {
    display: flex;
    align-items: center;
    margin-bottom: 8px;
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

  .paths {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px;
    margin-bottom: 8px;
    font-family: var(--mono);
    font-size: 10.5px;
    color: var(--dim);
  }

  .paths div {
    padding: 6px 9px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .paths small {
    display: block;
    color: var(--faint);
    font-family: var(--ui);
    font-size: 10px;
  }

  .controls {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 8px;
  }

  .controls select,
  .btn {
    height: 30px;
    padding: 0 10px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--raised);
    color: var(--text);
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

  .list {
    flex: 1;
    min-height: 0;
    overflow: auto;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
  }

  .item {
    display: flex;
    align-items: center;
    gap: 9px;
    width: 100%;
    height: 32px;
    padding: 0 10px;
    text-align: left;
    font-size: 11.5px;
  }

  .item:hover {
    background: var(--hover);
  }

  .item.skip {
    opacity: 0.5;
    cursor: default;
  }

  .check {
    width: 14px;
    height: 14px;
    flex: 0 0 14px;
    border: 1px solid var(--border-strong);
    border-radius: 3px;
  }

  .check.checked {
    background: var(--accent);
    border-color: var(--accent);
  }

  .action {
    width: 16px;
    text-align: center;
    font-weight: 700;
  }

  .action.upload { color: var(--accent); }
  .action.download { color: var(--success); }

  .rel {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-family: var(--mono);
    font-size: 11px;
  }

  .reason {
    width: 150px;
    color: var(--faint);
    font-size: 10.5px;
  }

  .sizes {
    width: 150px;
    text-align: right;
    color: var(--faint);
    font-family: var(--mono);
    font-size: 10px;
  }

  .empty {
    padding: 30px;
    text-align: center;
    color: var(--faint);
    font-size: 12px;
  }

  .progress {
    margin-top: 6px;
    color: var(--faint);
    font-family: var(--mono);
    font-size: 10.5px;
  }

  .error {
    margin-top: 6px;
    color: var(--error);
    font-size: 11.5px;
  }
</style>
