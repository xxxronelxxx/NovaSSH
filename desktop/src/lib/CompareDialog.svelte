<script lang="ts">
  import { onMount } from "svelte";
  import {
    ArrowDown,
    ArrowUp,
    Save,
    Undo2,
    X,
  } from "lucide-svelte";
  import {
    api,
    formatBytes,
    type CompareOptions,
    type CompareResult,
    type DiffLine,
    type DiffRow,
    type DiffWord,
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

  interface Meta {
    leftLabel: string;
    rightLabel: string;
    leftEol: string;
    rightEol: string;
    leftBom: boolean;
    rightBom: boolean;
    leftFinalNewline: boolean;
    rightFinalNewline: boolean;
    leftReadOnly: string | null;
    rightReadOnly: string | null;
  }

  interface Hunk {
    start: number;
    end: number;
  }

  interface Snapshot {
    left: string[];
    right: string[];
    leftDirty: boolean;
    rightDirty: boolean;
  }

  let loading = $state(true);
  let saving = $state(false);
  let error = $state<string | null>(null);
  let notice = $state<string | null>(null);
  let result = $state<CompareResult | null>(null);
  let meta = $state<Meta>({
    leftLabel: left.label ?? left.path,
    rightLabel: right.label ?? right.path,
    leftEol: "\n",
    rightEol: "\n",
    leftBom: false,
    rightBom: false,
    leftFinalNewline: true,
    rightFinalNewline: true,
    leftReadOnly: null,
    rightReadOnly: null,
  });

  let leftLines = $state<string[]>([]);
  let rightLines = $state<string[]>([]);
  let leftDirty = $state(false);
  let rightDirty = $state(false);
  let ignoreWhitespace = $state(false);
  let ignoreCase = $state(false);
  let onlyDiff = $state(false);
  let rows = $state<DiffRow[]>([]);
  let hunks = $state<Hunk[]>([]);
  let diffStarts = $state<number[]>([]);
  let rowHunk = $state<number[]>([]);
  let diffIndex = $state(0);
  let edit = $state<{
    row: number;
    side: "left" | "right";
    value: string;
  } | null>(null);
  let undoStack: Snapshot[] = [];
  let scrollEl: HTMLDivElement | undefined = $state();
  let noticeTimer: ReturnType<typeof setTimeout> | null = null;

  const dirty = $derived(leftDirty || rightDirty);
  const options = $derived<CompareOptions>({
    ignoreWhitespace,
    ignoreCase,
    maxBytes: null,
  });

  function flash(message: string) {
    notice = message;
    if (noticeTimer) clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => {
      notice = null;
      noticeTimer = null;
    }, 1800);
  }

  function adopt(source: CompareResult) {
    meta = {
      leftLabel: source.leftLabel,
      rightLabel: source.rightLabel,
      leftEol: source.leftEol || "\n",
      rightEol: source.rightEol || "\n",
      leftBom: source.leftBom,
      rightBom: source.rightBom,
      leftFinalNewline: source.leftFinalNewline,
      rightFinalNewline: source.rightFinalNewline,
      leftReadOnly: source.leftReadOnly,
      rightReadOnly: source.rightReadOnly,
    };
    leftLines = source.rows
      .map((row) => row.left)
      .filter((line): line is DiffLine => line != null)
      .map((line) => line.text);
    rightLines = source.rows
      .map((row) => row.right)
      .filter((line): line is DiffLine => line != null)
      .map((line) => line.text);
    leftDirty = false;
    rightDirty = false;
    undoStack = [];
    result = source;
    rebuild();
  }

  async function load() {
    loading = true;
    error = null;
    try {
      const compared = await api.compareFiles(left, right, options);
      adopt(compared);
    } catch (e) {
      error = String(e);
    } finally {
      loading = false;
    }
  }

  async function recompute() {
    if (!result) return;
    try {
      const compared = await api.compareText(
        leftLines.join("\n"),
        rightLines.join("\n"),
        options,
      );
      result = compared;
      rebuild();
    } catch (e) {
      error = String(e);
    }
  }

  function rebuild() {
    const all = result?.rows ?? [];
    let filtered: DiffRow[];
    if (!onlyDiff) {
      filtered = all;
    } else {
      const keep = new Array<boolean>(all.length).fill(false);
      for (let i = 0; i < all.length; i += 1) {
        if (all[i].kind === "equal") continue;
        for (
          let j = Math.max(0, i - 2);
          j <= Math.min(all.length - 1, i + 2);
          j += 1
        ) {
          keep[j] = true;
        }
      }
      filtered = all.filter((_, index) => keep[index]);
    }
    rows = filtered;
    diffStarts = [];
    for (let i = 0; i < filtered.length; i += 1) {
      if (filtered[i].kind !== "equal") diffStarts.push(i);
    }
    const next: Hunk[] = [];
    let start = -1;
    for (let i = 0; i < filtered.length; i += 1) {
      const differs = filtered[i].kind !== "equal";
      if (differs && start < 0) start = i;
      if (!differs && start >= 0) {
        next.push({ start, end: i });
        start = -1;
      }
    }
    if (start >= 0) next.push({ start, end: filtered.length });
    hunks = next;
    const map = new Array<number>(filtered.length).fill(-1);
    next.forEach((hunk, index) => {
      for (let i = hunk.start; i < hunk.end; i += 1) map[i] = index;
    });
    rowHunk = map;
    if (diffIndex >= diffStarts.length) {
      diffIndex = diffStarts.length ? diffStarts.length - 1 : 0;
    }
  }

  function hunkAt(index: number): Hunk | null {
    const h = rowHunk[index];
    return h == null || h < 0 ? null : hunks[h] ?? null;
  }

  function words(line: DiffLine | null): DiffWord[] {
    if (!line) return [];
    return line.words.length
      ? line.words
      : [{ text: line.text, changed: false }];
  }

  function pushUndo() {
    undoStack.push({
      left: [...leftLines],
      right: [...rightLines],
      leftDirty,
      rightDirty,
    });
    if (undoStack.length > 40) undoStack.shift();
  }

  function undo() {
    const snapshot = undoStack.pop();
    if (!snapshot) return;
    leftLines = [...snapshot.left];
    rightLines = [...snapshot.right];
    leftDirty = snapshot.leftDirty;
    rightDirty = snapshot.rightDirty;
    void recompute();
  }

  function beginEdit(rowIndex: number, side: "left" | "right") {
    const line = side === "left" ? rows[rowIndex]?.left : rows[rowIndex]?.right;
    if (!line) return;
    const readOnly = side === "left" ? meta.leftReadOnly : meta.rightReadOnly;
    if (readOnly) {
      flash(readOnly);
      return;
    }
    const doc = side === "left" ? leftLines : rightLines;
    const index = line.number - 1;
    if (index < 0 || index >= doc.length) return;
    edit = { row: rowIndex, side, value: doc[index] };
  }

  function commitEdit() {
    const current = edit;
    if (!current) return;
    edit = null;
    const doc = current.side === "left" ? leftLines : rightLines;
    const index = current.row >= 0
      ? (current.side === "left" ? rows[current.row]?.left : rows[current.row]?.right)
          ?.number ?? 0
      : 0;
    const position = index - 1;
    if (position < 0 || position >= doc.length) return;
    if (doc[position] === current.value) return;
    pushUndo();
    if (current.side === "left") {
      leftLines[position] = current.value;
      leftDirty = true;
    } else {
      rightLines[position] = current.value;
      rightDirty = true;
    }
    leftLines = [...leftLines];
    rightLines = [...rightLines];
    void recompute();
  }

  function cancelEdit() {
    edit = null;
  }

  function applyHunk(hunk: Hunk, intoLeft: boolean) {
    if (edit) commitEdit();
    const readOnly = intoLeft ? meta.leftReadOnly : meta.rightReadOnly;
    if (readOnly) {
      flash(readOnly);
      return;
    }
    const block = rows.slice(hunk.start, hunk.end);
    const source = block
      .map((row) => (intoLeft ? row.right : row.left)?.text)
      .filter((value): value is string => value != null);
    const targets = block
      .map((row) => (intoLeft ? row.left : row.right)?.number)
      .filter((value): value is number => value != null);
    const doc = intoLeft ? leftLines : rightLines;
    pushUndo();
    if (!targets.length) {
      let before = 0;
      for (let i = 0; i < hunk.start; i += 1) {
        const number = intoLeft ? rows[i].left?.number : rows[i].right?.number;
        if (number != null) before = number;
      }
      doc.splice(Math.max(0, Math.min(before, doc.length)), 0, ...source);
    } else {
      const start = targets[0] - 1;
      const count = targets[targets.length - 1] - targets[0] + 1;
      doc.splice(
        start,
        Math.max(0, Math.min(count, doc.length - start)),
        ...source,
      );
    }
    if (intoLeft) {
      leftLines = [...leftLines];
      leftDirty = true;
    } else {
      rightLines = [...rightLines];
      rightDirty = true;
    }
    void recompute();
  }

  function compose(
    lines: string[],
    eol: string,
    bom: boolean,
    finalNewline: boolean,
  ): string {
    const body = lines.length
      ? lines.join(eol) + (finalNewline ? eol : "")
      : "";
    return bom ? `\uFEFF${body}` : body;
  }

  async function save() {
    if (saving || !dirty) return;
    if (edit) commitEdit();
    saving = true;
    const saved: string[] = [];
    try {
      if (leftDirty) {
        await api.saveText(
          left,
          compose(
            leftLines,
            meta.leftEol,
            meta.leftBom,
            meta.leftFinalNewline,
          ),
        );
        leftDirty = false;
        saved.push(meta.leftLabel);
      }
      if (rightDirty) {
        await api.saveText(
          right,
          compose(
            rightLines,
            meta.rightEol,
            meta.rightBom,
            meta.rightFinalNewline,
          ),
        );
        rightDirty = false;
        saved.push(meta.rightLabel);
      }
      flash(`Сохранено: ${saved.join(" · ")}`);
    } catch (e) {
      error = `Не удалось сохранить: ${e}`;
    } finally {
      saving = false;
    }
  }

  function jump(delta: number) {
    if (!diffStarts.length) return;
    diffIndex =
      (diffIndex + delta + diffStarts.length) % diffStarts.length;
    const target = rows[diffStarts[diffIndex]];
    if (!target || !scrollEl) return;
    const element = scrollEl.querySelector(
      `[data-row="${diffStarts[diffIndex]}"]`,
    ) as HTMLElement | null;
    element?.scrollIntoView({ block: "center" });
  }

  function requestClose() {
    if (dirty) {
      if (!window.confirm("Закрыть сравнение без сохранения изменений?")) {
        return;
      }
    }
    onClose();
  }

  function onKey(event: KeyboardEvent) {
    if (edit) {
      if (event.key === "Escape") {
        event.preventDefault();
        cancelEdit();
      }
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      requestClose();
      return;
    }
    if (event.key === "F3") {
      event.preventDefault();
      jump(1);
      return;
    }
    if (event.key === "F2") {
      event.preventDefault();
      jump(-1);
      return;
    }
    if (!(event.ctrlKey || event.metaKey)) return;
    const key = event.key.toLowerCase();
    if (key === "s") {
      event.preventDefault();
      void save();
    } else if (key === "z") {
      event.preventDefault();
      undo();
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      jump(1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      jump(-1);
    }
  }

  function toggleWhitespace() {
    const hadEdits = dirty;
    ignoreWhitespace = !ignoreWhitespace;
    if (hadEdits) void recompute();
    else void load();
  }

  function toggleCase() {
    const hadEdits = dirty;
    ignoreCase = !ignoreCase;
    if (hadEdits) void recompute();
    else void load();
  }

  onMount(load);
</script>

<svelte:window onkeydown={onKey} />

<div class="overlay" onclick={requestClose}>
  <div class="dialog" onclick={(e) => e.stopPropagation()}>
    <div class="head">
      <span>Сравнение файлов</span>
      {#if dirty}<span class="dirty">не сохранено</span>{/if}
      <span class="grow"></span>
      {#if result && !result.binary}
        {#if result.equal}
          <span class="counter ok">Идентичны</span>
        {:else}
          <span class="counter add">+{result.added}</span>
          <span class="counter del">−{result.removed}</span>
          <span class="counter mod">~{result.changed}</span>
        {/if}
        <button class="chip" class:active={ignoreWhitespace} onclick={toggleWhitespace}>
          пробелы
        </button>
        <button class="chip" class:active={ignoreCase} onclick={toggleCase}>
          регистр
        </button>
        <button
          class="chip"
          class:active={onlyDiff}
          onclick={() => {
            onlyDiff = !onlyDiff;
            rebuild();
          }}
        >
          только отличия
        </button>
        <button class="icon" title="Предыдущее различие (Ctrl+↑)" disabled={!diffStarts.length} onclick={() => jump(-1)}>
          <ArrowUp size={14} />
        </button>
        <button class="icon" title="Следующее различие (Ctrl+↓)" disabled={!diffStarts.length} onclick={() => jump(1)}>
          <ArrowDown size={14} />
        </button>
        <button class="icon" title="Отменить (Ctrl+Z)" disabled={!undoStack.length} onclick={undo}>
          <Undo2 size={14} />
        </button>
        <button class="icon" title="Сохранить (Ctrl+S)" disabled={!dirty || saving} onclick={save}>
          <Save size={14} />
        </button>
      {/if}
      <button class="icon" title="Закрыть" onclick={requestClose}><X size={15} /></button>
    </div>

    {#if result}
      <div class="labels">
        <div class="label">
          <span>{meta.leftLabel}</span>
          <small>
            {formatBytes(result.leftSize)}
            {#if meta.leftReadOnly}<span class="ro">только чтение</span>{/if}
          </small>
        </div>
        <div class="label">
          <span>{meta.rightLabel}</span>
          <small>
            {formatBytes(result.rightSize)}
            {#if meta.rightReadOnly}<span class="ro">только чтение</span>{/if}
          </small>
        </div>
      </div>

      {#if result.binary}
        <div class="hashes">
          <div><b>SHA-256 слева</b><code>{result.leftHash ?? "—"}</code></div>
          <div><b>SHA-256 справа</b><code>{result.rightHash ?? "—"}</code></div>
        </div>
      {:else}
        <div class="table" bind:this={scrollEl}>
          {#each rows as row, index (`${index}:${row.kind}:${row.left?.number ?? ""}:${row.right?.number ?? ""}`)}
            {@const hunk = hunkAt(index)}
            <div class="crow {row.kind}" data-row={index}>
              <div class="merge">
                {#if hunk && hunk.start === index}
                  <button
                    title="Взять блок в левый файл"
                    disabled={!!meta.leftReadOnly}
                    onclick={() => applyHunk(hunk, true)}
                  >←</button>
                  <button
                    title="Взять блок в правый файл"
                    disabled={!!meta.rightReadOnly}
                    onclick={() => applyHunk(hunk, false)}
                  >→</button>
                {/if}
              </div>
              <div class="gutter">{row.left?.number ?? ""}</div>
              <div
                class="cell left"
                class:active={edit?.row === index && edit?.side === "left"}
                onclick={() => beginEdit(index, "left")}
              >
                {#if edit?.row === index && edit?.side === "left"}
                  <input
                    bind:value={edit.value}
                    autofocus
                    onfocus={(e) => e.currentTarget.select()}
                    onkeydown={(e) => {
                      if (e.key === "Enter") {
                        e.preventDefault();
                        commitEdit();
                      } else if (e.key === "Escape") {
                        e.preventDefault();
                        cancelEdit();
                      }
                    }}
                    onblur={commitEdit}
                  />
                {:else if row.left}
                  {#each words(row.left) as word (word.text + word.changed)}
                    <span class:changed={word.changed}>{word.text}</span>
                  {/each}
                {/if}
              </div>
              <div class="gutter">{row.right?.number ?? ""}</div>
              <div
                class="cell right"
                class:active={edit?.row === index && edit?.side === "right"}
                onclick={() => beginEdit(index, "right")}
              >
                {#if edit?.row === index && edit?.side === "right"}
                  <input
                    bind:value={edit.value}
                    autofocus
                    onfocus={(e) => e.currentTarget.select()}
                    onkeydown={(e) => {
                      if (e.key === "Enter") {
                        e.preventDefault();
                        commitEdit();
                      } else if (e.key === "Escape") {
                        e.preventDefault();
                        cancelEdit();
                      }
                    }}
                    onblur={commitEdit}
                  />
                {:else if row.right}
                  {#each words(row.right) as word (word.text + word.changed)}
                    <span class:changed={word.changed}>{word.text}</span>
                  {/each}
                {/if}
              </div>
            </div>
          {:else}
            <div class="empty">Пустые файлы — отличий нет</div>
          {/each}
        </div>
        {#if result.truncated}
          <div class="warn">
            Показано не всё: файл больше 8 МБ или строк больше 20 000 — сравнение ограничено.
          </div>
        {/if}
      {/if}
    {:else if loading}
      <div class="empty big">Сравниваю…</div>
    {/if}

    {#if notice}<div class="notice">{notice}</div>{/if}
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
    z-index: 110;
  }

  .dialog {
    width: min(1280px, 96vw);
    height: min(820px, 92vh);
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
    min-height: 28px;
    font-size: 13px;
    font-weight: 600;
  }

  .grow {
    flex: 1;
  }

  .dirty {
    padding: 2px 7px;
    border-radius: 4px;
    background: rgba(210, 153, 34, 0.16);
    color: var(--warn);
    font-size: 10.5px;
    font-weight: 500;
  }

  .counter {
    padding: 0 4px;
    font-family: var(--mono);
    font-size: 11px;
    font-weight: 500;
  }

  .counter.ok { color: var(--success); }
  .counter.add { color: var(--success); }
  .counter.del { color: var(--error); }
  .counter.mod { color: var(--warn); }

  .chip {
    padding: 3px 8px;
    border: 1px solid var(--border);
    border-radius: 10px;
    color: var(--dim);
    font-size: 10.5px;
  }

  .chip.active {
    border-color: var(--accent);
    color: var(--accent);
    background: color-mix(in srgb, var(--accent) 12%, transparent);
  }

  .icon {
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    border-radius: 5px;
    color: var(--faint);
  }

  .icon:hover:not(:disabled) {
    background: var(--hover);
    color: var(--text);
  }

  .icon:disabled {
    opacity: 0.4;
  }

  .labels {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px;
    margin: 8px 0 6px;
  }

  .label {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    padding: 5px 9px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    font-size: 11.5px;
    font-family: var(--mono);
  }

  .label small {
    color: var(--faint);
    white-space: nowrap;
  }

  .ro {
    margin-left: 8px;
    color: var(--warn);
    font-family: var(--ui);
  }

  .table {
    flex: 1;
    min-height: 0;
    overflow: auto;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    font-family: var(--mono);
    font-size: 11.5px;
    background: var(--panel);
  }

  .crow {
    display: grid;
    grid-template-columns: 30px 42px 1fr 42px 1fr;
    min-height: 19px;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 45%, transparent);
  }

  .crow.add .cell.right { background: rgba(63, 185, 80, 0.12); }
  .crow.del .cell.left { background: rgba(248, 81, 73, 0.12); }
  .crow.mod .cell { background: rgba(210, 153, 34, 0.08); }

  .merge {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 1px;
    border-right: 1px solid var(--border);
  }

  .merge button {
    width: 13px;
    height: 17px;
    border-radius: 2px;
    color: var(--faint);
    font-size: 10px;
    line-height: 1;
  }

  .merge button:hover:not(:disabled) {
    background: var(--selection);
    color: var(--text);
  }

  .merge button:disabled {
    opacity: 0.25;
  }

  .gutter {
    padding-top: 2px;
    padding-right: 5px;
    text-align: right;
    color: var(--faint);
    font-size: 9.5px;
    border-right: 1px solid var(--border);
    user-select: none;
  }

  .cell {
    min-width: 0;
    padding: 2px 6px;
    overflow-wrap: anywhere;
    white-space: pre-wrap;
    cursor: text;
    user-select: text;
  }

  .cell.active {
    padding: 0;
  }

  .cell input {
    width: 100%;
    height: 19px;
    padding: 0 4px;
    border: 1px solid var(--accent);
    background: var(--menu);
    color: var(--text);
    font-family: var(--mono);
    font-size: 11.5px;
    outline: none;
  }

  .changed {
    background: rgba(210, 153, 34, 0.28);
    border-radius: 2px;
  }

  .hashes {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-top: 8px;
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
    user-select: text;
  }

  .empty {
    padding: 30px;
    text-align: center;
    color: var(--faint);
    font-size: 12px;
  }

  .empty.big {
    flex: 1;
    display: grid;
    place-items: center;
  }

  .warn {
    margin-top: 6px;
    color: var(--warn);
    font-size: 10.5px;
  }

  .notice {
    margin-top: 6px;
    color: var(--success);
    font-size: 11.5px;
  }

  .error {
    margin-top: 6px;
    color: var(--error);
    font-size: 11.5px;
  }
</style>
