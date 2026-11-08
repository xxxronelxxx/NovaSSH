<script lang="ts">
  import { X } from "lucide-svelte";
  import { api, type Entry } from "../lib/api";

  let {
    entry,
    sessionId,
    onClose,
    onApplied,
  }: {
    entry: Entry;
    sessionId: string | null;
    onClose: () => void;
    onApplied: () => Promise<void> | void;
  } = $props();

  let mode = $state((entry.mode ?? 0o644) & 0o777);
  let recursive = $state(false);
  let busy = $state(false);
  let error = $state<string | null>(null);
  const isDir = entry.kind === "dir";

  const rows: { title: string; read: number; write: number; exec: number }[] = [
    { title: "Владелец", read: 0o400, write: 0o200, exec: 0o100 },
    { title: "Группа", read: 0o040, write: 0o020, exec: 0o010 },
    { title: "Остальные", read: 0o004, write: 0o002, exec: 0o001 },
  ];

  function toggle(bit: number, on: boolean) {
    mode = on ? mode | bit : mode & ~bit;
  }

  const octal = $derived(mode.toString(8).padStart(3, "0"));

  async function apply() {
    busy = true;
    error = null;
    try {
      await api.chmod(sessionId, entry.path, mode, isDir && recursive);
      await onApplied();
      onClose();
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }
</script>

<div class="overlay" onclick={onClose}>
  <div class="dialog" onclick={(e) => e.stopPropagation()}>
    <div class="head">
      <span>Права доступа · {entry.name}</span>
      <span class="grow"></span>
      <button class="icon" title="Закрыть" onclick={onClose}><X size={15} /></button>
    </div>

    <div class="matrix">
      <div class="row head-row">
        <span class="who"></span>
        <span>Чтение</span>
        <span>Запись</span>
        <span>Выполнение</span>
      </div>
      {#each rows as row (row.title)}
        <div class="row">
          <span class="who">{row.title}</span>
          <label class="cell"><input type="checkbox" checked={(mode & row.read) !== 0} onchange={(e) => toggle(row.read, e.currentTarget.checked)} /></label>
          <label class="cell"><input type="checkbox" checked={(mode & row.write) !== 0} onchange={(e) => toggle(row.write, e.currentTarget.checked)} /></label>
          <label class="cell"><input type="checkbox" checked={(mode & row.exec) !== 0} onchange={(e) => toggle(row.exec, e.currentTarget.checked)} /></label>
        </div>
      {/each}
    </div>

    <div class="summary">
      <span>Итог: <b>{octal}</b></span>
      {#if isDir}
        <label class="check">
          <input type="checkbox" bind:checked={recursive} />
          рекурсивно для папки
        </label>
      {/if}
    </div>

    {#if error}<div class="error">{error}</div>{/if}

    <div class="foot">
      <button class="btn" onclick={onClose}>Отмена</button>
      <button class="btn primary" disabled={busy} onclick={apply}>
        {busy ? "Применяю…" : "Применить"}
      </button>
    </div>
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
    width: 430px;
    max-width: 92vw;
    padding: 14px 16px 12px;
    background: var(--menu);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.5);
  }

  .head {
    display: flex;
    align-items: center;
    margin-bottom: 12px;
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

  .matrix {
    display: flex;
    flex-direction: column;
    gap: 3px;
    margin-bottom: 10px;
  }

  .row {
    display: grid;
    grid-template-columns: 110px 1fr 1fr 1fr;
    align-items: center;
    padding: 2px 0;
  }

  .head-row {
    color: var(--faint);
    font-size: 10.5px;
    text-align: center;
  }

  .who {
    font-size: 11.5px;
    color: var(--dim);
  }

  .cell {
    display: grid;
    place-items: center;
  }

  .cell input {
    width: 15px;
    height: 15px;
    accent-color: var(--accent);
  }

  .summary {
    display: flex;
    align-items: center;
    gap: 14px;
    margin-bottom: 4px;
    color: var(--dim);
    font-size: 11.5px;
  }

  .summary b {
    color: var(--accent);
    font-family: var(--mono);
    font-size: 13px;
  }

  .check {
    display: flex;
    align-items: center;
    gap: 6px;
    color: var(--dim);
    font-size: 11.5px;
  }

  .check input {
    accent-color: var(--accent);
  }

  .foot {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 12px;
  }

  .btn {
    padding: 6px 12px;
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

  .btn:disabled {
    opacity: 0.5;
  }

  .error {
    margin-top: 8px;
    color: var(--error);
    font-size: 11.5px;
  }
</style>
