<script lang="ts">
  import { onMount } from "svelte";
  import { X } from "lucide-svelte";
  import {
    api,
    formatBytes,
    type CompareResult,
    type FileRef,
  } from "../lib/api";

  let {
    left,
    right,
    onClose,
  }: {
    left: FileRef;
    right: FileRef;
    onClose: () => void;
  } = $props();

  let result = $state<CompareResult | null>(null);
  let busy = $state(false);
  let error = $state<string | null>(null);
  let ignoreWhitespace = $state(false);
  let ignoreCase = $state(false);

  async function load() {
    busy = true;
    error = null;
    try {
      result = await api.compareFiles(left, right, {
        ignoreWhitespace,
        ignoreCase,
        maxBytes: null,
      });
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  onMount(load);
</script>

<div class="overlay" onclick={onClose}>
  <div class="dialog" onclick={(e) => e.stopPropagation()}>
    <div class="head">
      <span>Сравнение файлов</span>
      <span class="grow"></span>
      <label><input type="checkbox" bind:checked={ignoreWhitespace} onchange={load} /> пробелы</label>
      <label><input type="checkbox" bind:checked={ignoreCase} onchange={load} /> регистр</label>
      <button class="icon" title="Закрыть" onclick={onClose}><X size={15} /></button>
    </div>

    {#if result}
      <div class="labels">
        <div class="label">{result.leftLabel}<small>{formatBytes(result.leftSize)}</small></div>
        <div class="label">{result.rightLabel}<small>{formatBytes(result.rightSize)}</small></div>
      </div>
      <div class="stats">
        {#if result.equal}
          <span class="ok">Файлы совпадают</span>
        {:else if result.binary}
          <span>Бинарные файлы: построчное сравнение недоступно</span>
        {:else}
          <span class="add">+{result.added}</span>
          <span class="del">−{result.removed}</span>
          <span class="mod">~{result.changed}</span>
        {/if}
        {#if result.truncated}<span class="warn">файл усечён при чтении</span>{/if}
      </div>

      {#if result.binary}
        <div class="hashes">
          <div><b>SHA-256 слева</b><code>{result.leftHash ?? "—"}</code></div>
          <div><b>SHA-256 справа</b><code>{result.rightHash ?? "—"}</code></div>
        </div>
      {:else}
        <div class="table">
          {#each result.rows as row, index (index)}
            <div class="row {row.kind}">
              <span class="no">{row.left?.number ?? ""}</span>
              <span class="text">
                {#each row.left?.words ?? [] as word (word.text + word.changed)}
                  <span class:changed={word.changed}>{word.text}</span>
                {/each}
              </span>
              <span class="no">{row.right?.number ?? ""}</span>
              <span class="text">
                {#each row.right?.words ?? [] as word (word.text + word.changed)}
                  <span class:changed={word.changed}>{word.text}</span>
                {/each}
              </span>
            </div>
          {/each}
        </div>
      {/if}
    {:else if busy}
      <div class="empty">Сравниваю…</div>
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
    width: min(1200px, 94vw);
    height: min(760px, 88vh);
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
    gap: 12px;
    margin-bottom: 8px;
    font-size: 13px;
    font-weight: 600;
  }

  .head label {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 11px;
    font-weight: 400;
    color: var(--dim);
  }

  .head input {
    accent-color: var(--accent);
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

  .labels {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px;
    margin-bottom: 6px;
  }

  .label {
    display: flex;
    justify-content: space-between;
    padding: 5px 9px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    font-size: 11.5px;
    font-family: var(--mono);
  }

  .label small {
    color: var(--faint);
  }

  .stats {
    display: flex;
    align-items: center;
    gap: 12px;
    height: 24px;
    font-size: 11.5px;
    color: var(--dim);
  }

  .add { color: var(--success); }
  .del { color: var(--error); }
  .mod { color: var(--warn); }
  .ok { color: var(--success); }
  .warn { color: var(--warn); }

  .table {
    flex: 1;
    min-height: 0;
    overflow: auto;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    font-family: var(--mono);
    font-size: 11.5px;
  }

  .row {
    display: grid;
    grid-template-columns: 44px 1fr 44px 1fr;
    gap: 6px;
    padding: 1px 6px;
    min-height: 18px;
  }

  .row.add .text:nth-of-type(2) { background: rgba(63, 185, 80, 0.12); }
  .row.del .text:nth-of-type(1) { background: rgba(248, 81, 73, 0.12); }
  .row.mod .text { background: rgba(210, 153, 34, 0.08); }

  .no {
    text-align: right;
    color: var(--faint);
    font-size: 10px;
  }

  .text {
    white-space: pre-wrap;
    word-break: break-all;
  }

  .text .changed {
    background: rgba(210, 153, 34, 0.28);
    border-radius: 2px;
  }

  .hashes {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-top: 10px;
    padding: 12px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    font-size: 12px;
  }

  .hashes code {
    display: block;
    margin-top: 4px;
    color: var(--faint);
    font-family: var(--mono);
    word-break: break-all;
  }

  .empty {
    display: grid;
    place-items: center;
    flex: 1;
    color: var(--faint);
    font-size: 12px;
  }

  .error {
    margin-top: 8px;
    color: var(--error);
    font-size: 11.5px;
  }
</style>
