<script lang="ts">
  import { onMount } from "svelte";
  import { Copy, RefreshCw, X } from "lucide-svelte";
  import { api, formatBytes, type LogFile } from "../lib/api";

  let { onClose }: { onClose: () => void } = $props();

  let dir = $state<string | null>(null);
  let files = $state<LogFile[]>([]);
  let selected = $state<string | null>(null);
  let text = $state("");
  let onlyProblems = $state(false);
  let busy = $state(false);
  let error = $state<string | null>(null);
  let copied = $state(false);

  const visible = $derived.by(() => {
    const lines = text.split("\n");
    if (!onlyProblems) return lines;
    return lines.filter(
      (line) =>
        line.includes("ERROR") ||
        line.includes("PANIC") ||
        line.includes("FLUTTER:") ||
        line.includes("ZONE:"),
    );
  });

  async function load(path?: string | null) {
    busy = true;
    error = null;
    try {
      files = await api.listLogs();
      const target = path ?? selected ?? files[0]?.path ?? null;
      selected = target;
      text = target ? await api.readLog(target) : "";
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  onMount(async () => {
    dir = await api.logDir().catch(() => null);
    await load();
  });

  async function copy() {
    await navigator.clipboard.writeText(visible.join("\n")).catch(() => {});
    copied = true;
    setTimeout(() => (copied = false), 1200);
  }
</script>

<div class="overlay" onclick={onClose}>
  <div class="dialog" onclick={(e) => e.stopPropagation()}>
    <div class="head">
      <span>Журнал</span>
      <span class="grow"></span>
      <label class="check">
        <input type="checkbox" bind:checked={onlyProblems} /> только проблемы
      </label>
      <button class="icon" title="Обновить" onclick={() => load()}>
        <span class="icon-wrap" class:spin={busy}>
            <RefreshCw size={14} />
          </span>
      </button>
      <button class="icon" title="Копировать" onclick={copy}>
        <Copy size={14} />
      </button>
      <button class="icon" title="Закрыть" onclick={onClose}>
        <X size={15} />
      </button>
    </div>

    <div class="path">{dir ?? "папка журналов недоступна"}</div>

    <div class="body">
      <div class="files">
        {#each files as file (file.path)}
          <button
            class="file"
            class:active={selected === file.path}
            onclick={() => load(file.path)}
          >
            <span class="name">{file.name}</span>
            <span class="meta">
              {formatBytes(file.size)} · {new Date(file.modified).toLocaleString("ru-RU")}
            </span>
          </button>
        {:else}
          <div class="empty">Журналов пока нет</div>
        {/each}
      </div>
      <pre class="lines">{visible.join("\n")}</pre>
    </div>

    {#if copied}<span class="copied">Скопировано</span>{/if}
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
    z-index: 120;
  }

  .dialog {
    width: min(1100px, 94vw);
    height: min(720px, 88vh);
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
    gap: 6px;
    font-size: 13px;
    font-weight: 600;
  }

  .grow {
    flex: 1;
  }

  .check {
    display: flex;
    align-items: center;
    gap: 4px;
    margin-right: 6px;
    color: var(--dim);
    font-size: 11px;
    font-weight: 400;
  }

  .check input {
    accent-color: var(--accent);
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

  .icon-wrap {
    display: grid;
    place-items: center;
  }

  .spin {
    animation: spin 0.9s linear infinite;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .path {
    margin: 6px 0 8px;
    color: var(--faint);
    font-family: var(--mono);
    font-size: 10.5px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .body {
    flex: 1;
    min-height: 0;
    display: grid;
    grid-template-columns: 250px 1fr;
    gap: 8px;
  }

  .files {
    overflow: auto;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
  }

  .file {
    display: flex;
    flex-direction: column;
    gap: 2px;
    width: 100%;
    padding: 6px 9px;
    text-align: left;
    border-bottom: 1px solid var(--border);
  }

  .file:last-child {
    border-bottom: 0;
  }

  .file:hover {
    background: var(--hover);
  }

  .file.active {
    background: var(--selection);
  }

  .name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-family: var(--mono);
    font-size: 11px;
  }

  .meta {
    color: var(--faint);
    font-size: 10px;
  }

  .lines {
    margin: 0;
    padding: 8px 10px;
    overflow: auto;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    font-family: var(--mono);
    font-size: 11px;
    line-height: 1.5;
    white-space: pre-wrap;
    word-break: break-all;
    user-select: text;
  }

  .empty {
    padding: 24px;
    text-align: center;
    color: var(--faint);
    font-size: 11.5px;
  }

  .copied {
    align-self: flex-end;
    margin-top: 6px;
    color: var(--success);
    font-size: 11px;
  }

  .error {
    margin-top: 6px;
    color: var(--error);
    font-size: 11.5px;
  }
</style>
