<script lang="ts">
  import { X } from "lucide-svelte";

  let {
    names,
    onClose,
    onApply,
  }: {
    names: string[];
    onClose: () => void;
    onApply: (renames: { from: string; to: string }[]) => Promise<void>;
  } = $props();

  let mask = $state("[N]_[C]");
  let find = $state("");
  let replace = $state("");
  let useRegex = $state(false);
  let busy = $state(false);
  let error = $state<string | null>(null);

  function splitName(fileName: string): [string, string] {
    const dot = fileName.lastIndexOf(".");
    if (dot <= 0 || dot === fileName.length - 1) return [fileName, ""];
    return [fileName.slice(0, dot), fileName.slice(dot + 1)];
  }

  function applyMask(name: string, ext: string, index: number): string {
    const digits = Math.max(1, String(names.length).length);
    const counter = String(index + 1).padStart(digits, "0");
    const now = new Date();
    const two = (value: number) => String(value).padStart(2, "0");
    let result = mask
      .replaceAll("[N]", name)
      .replaceAll("[E]", ext)
      .replaceAll("[C]", counter)
      .replaceAll("[Y]", String(now.getFullYear()).padStart(4, "0"))
      .replaceAll("[M]", two(now.getMonth() + 1))
      .replaceAll("[D]", two(now.getDate()))
      .replaceAll("[h]", two(now.getHours()))
      .replaceAll("[m]", two(now.getMinutes()))
      .replaceAll("[s]", two(now.getSeconds()));
    if (!mask.includes("[E]") && ext) result = `${result}.${ext}`;
    return result;
  }

  const rows = $derived.by(() => {
    let pattern: RegExp | null = null;
    if (find && useRegex) {
      try {
        pattern = new RegExp(find);
      } catch {
        pattern = null;
      }
    }
    const seen = new Set<string>();
    return names.map((from, index) => {
      const [name, ext] = splitName(from);
      let to = applyMask(name, ext, index);
      if (find) {
        to = pattern
          ? to.replace(pattern, replace)
          : to.split(find).join(replace);
      }
      const [stem] = splitName(to);
      let problem: string | null = null;
      if (!to.trim() || !stem.trim()) problem = "пустое имя";
      else if (to.includes("/") || to.includes("\\")) {
        problem = "имя содержит разделитель пути";
      } else if (seen.has(to.toLowerCase())) problem = "дубликат имени";
      seen.add(to.toLowerCase());
      return { from, to, problem };
    });
  });

  const canApply = $derived(
    rows.length > 0 &&
      rows.every((row) => !row.problem) &&
      rows.some((row) => row.from !== row.to),
  );

  async function apply() {
    if (!canApply) return;
    busy = true;
    error = null;
    try {
      await onApply(rows.map(({ from, to }) => ({ from, to })));
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
      <span>Массовое переименование · {names.length}</span>
      <span class="grow"></span>
      <button class="icon" title="Закрыть" onclick={onClose}><X size={15} /></button>
    </div>

    <div class="fields">
      <label class="field">
        <span>Маска</span>
        <input bind:value={mask} placeholder="[N]_[C].[E]" />
        <small>[N] имя · [E] расширение · [C] счётчик · [Y][M][D] дата</small>
      </label>
      <label class="field">
        <span>Найти</span>
        <input bind:value={find} />
      </label>
      <label class="field">
        <span>Заменить на</span>
        <input bind:value={replace} />
      </label>
      <label class="check">
        <input type="checkbox" bind:checked={useRegex} /> regex
      </label>
    </div>

    <div class="table">
      {#each rows as row (row.from)}
        <div class="row" class:bad={!!row.problem}>
          <span class="from">{row.from}</span>
          <span class="arrow">→</span>
          <span class="to">{row.to}</span>
          {#if row.problem}<span class="problem">{row.problem}</span>{/if}
        </div>
      {/each}
    </div>

    {#if error}<div class="error">{error}</div>{/if}

    <div class="foot">
      <button class="btn" onclick={onClose}>Отмена</button>
      <button class="btn primary" disabled={busy || !canApply} onclick={apply}>
        {busy ? "Переименовываю…" : "Переименовать"}
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
    width: min(760px, 92vw);
    height: min(560px, 84vh);
    display: flex;
    flex-direction: column;
    padding: 14px 16px 12px;
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

  .fields {
    display: grid;
    grid-template-columns: 1fr 1fr 1fr auto;
    gap: 8px;
    align-items: start;
    margin-bottom: 10px;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .field span {
    color: var(--faint);
    font-size: 10.5px;
  }

  .field small {
    color: var(--faint);
    font-size: 9.5px;
  }

  .field input {
    height: 30px;
    padding: 0 8px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--text);
    font-family: var(--mono);
    font-size: 12px;
    outline: none;
  }

  .field input:focus {
    border-color: var(--accent);
  }

  .check {
    align-self: center;
    display: flex;
    align-items: center;
    gap: 5px;
    color: var(--dim);
    font-size: 11px;
  }

  .check input {
    accent-color: var(--accent);
  }

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
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 3px 9px;
    border-bottom: 1px solid var(--border);
  }

  .row:last-child {
    border-bottom: 0;
  }

  .row.bad {
    background: rgba(248, 81, 73, 0.08);
  }

  .from {
    width: 42%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--faint);
  }

  .arrow {
    color: var(--faint);
  }

  .to {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .problem {
    color: var(--error);
    font-family: var(--ui);
    font-size: 10px;
  }

  .foot {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 10px;
  }

  .btn {
    padding: 6px 12px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--raised);
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

  .btn.primary:disabled {
    opacity: 0.5;
  }

  .error {
    margin-top: 6px;
    color: var(--error);
    font-size: 11.5px;
  }
</style>
