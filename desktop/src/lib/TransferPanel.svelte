<script lang="ts">
  import { ChevronDown, ChevronUp, Download, List, X } from "lucide-svelte";
  import { formatBytes, type TransferEvent } from "./api";

  let {
    transfers = [],
    collapsed = false,
    onToggle,
    onCancel,
  }: {
    transfers?: TransferEvent[];
    collapsed?: boolean;
    onToggle: () => void;
    onCancel?: (id: string) => void;
  } = $props();

  const active = $derived(
    transfers.filter((t) => t.state === "running" || t.state === "queued").length,
  );

  function percent(t: TransferEvent): number {
    if (!t.total) return 0;
    return Math.min(100, Math.round((t.done / t.total) * 100));
  }

  const stateLabel: Record<string, string> = {
    running: "Передача",
    queued: "В очереди",
    done: "Готово",
    failed: "Ошибка",
    cancelled: "Отменено",
  };
</script>

<section class="transfer" class:collapsed>
  <button class="head" onclick={onToggle} title="Свернуть/развернуть">
    <Download size={14} />
    <span class="title">Фоновая передача</span>
    <span class="count">{active}</span>
    <span class="grow"></span>
    <span class="mini" title="Список">
      <List size={14} />
    </span>
    <span class="mini">
      {#if collapsed}
        <ChevronUp size={14} />
      {:else}
        <ChevronDown size={14} />
      {/if}
    </span>
  </button>

  {#if !collapsed}
    <div class="thead">
      <span class="c op">Операция</span>
      <span class="c src">Источник</span>
      <span class="c dst">Назначение</span>
      <span class="c done">Передано</span>
      <span class="c time">Время</span>
      <span class="c speed">Скорость</span>
      <span class="c bar">Прогресс</span>
    </div>
    <div class="rows">
      {#each transfers as t (t.id)}
        <div class="row">
          <span class="c op">
            <span class="state" class:done={t.state === "done"} class:error={t.state === "failed" || t.state === "cancelled"}></span>
            {stateLabel[t.state] ?? t.state}
          </span>
          <span class="c src">{t.name}</span>
          <span class="c dst">{t.message ?? "—"}</span>
          <span class="c done">{formatBytes(t.done)}{t.total ? ` / ${formatBytes(t.total)}` : ""}</span>
          <span class="c time">—</span>
          <span class="c speed">—</span>
          <span class="c bar">
            <span class="track"><span class="fill" style:width={`${percent(t)}%`}></span></span>
            <span class="pct">{percent(t)}%</span>
          </span>
          {#if onCancel && (t.state === "running" || t.state === "queued")}
            <button class="cancel" title="Отменить" onclick={() => onCancel(t.id)}>
              <X size={12} />
            </button>
          {:else}
            <span class="cancel-space"></span>
          {/if}
        </div>
      {:else}
        <div class="empty">Нет активных передач</div>
      {/each}
    </div>
  {/if}
</section>

<style>
  .transfer {
    display: flex;
    flex-direction: column;
    height: 190px;
    min-height: 190px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow: hidden;
  }

  .transfer.collapsed {
    height: 36px;
    min-height: 36px;
  }

  .head {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 36px;
    min-height: 36px;
    padding: 0 12px;
    color: var(--dim);
    font-size: 12px;
    text-align: left;
  }

  .head:hover {
    background: var(--hover);
  }

  .title {
    font-weight: 600;
    color: var(--text);
  }

  .count {
    color: var(--faint);
    font-size: 11px;
  }

  .grow {
    flex: 1;
  }

  .mini {
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    border-radius: 4px;
    color: var(--faint);
  }

  .thead,
  .row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 0 12px;
  }

  .thead {
    height: 28px;
    min-height: 28px;
    border-top: 1px solid var(--border);
    border-bottom: 1px solid var(--border);
    color: var(--faint);
    font-size: 11px;
  }

  .rows {
    flex: 1;
    overflow: auto;
  }

  .row {
    height: 28px;
    font-size: 11.5px;
    color: var(--dim);
  }

  .row:hover {
    background: var(--hover);
  }

  .c {
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .op {
    width: 130px;
    display: flex;
    align-items: center;
    gap: 7px;
  }

  .src {
    flex: 1.2;
    min-width: 0;
    color: var(--text);
  }

  .dst {
    flex: 1;
    min-width: 0;
  }

  .done,
  .time,
  .speed {
    width: 90px;
    text-align: right;
    font-family: var(--mono);
    font-size: 10.5px;
  }

  .time,
  .speed {
    width: 70px;
  }

  .bar {
    width: 140px;
    display: flex;
    align-items: center;
    gap: 7px;
  }

  .track {
    flex: 1;
    height: 4px;
    border-radius: 2px;
    background: var(--panel-subtle);
    overflow: hidden;
  }

  .fill {
    display: block;
    height: 100%;
    background: var(--accent);
  }

  .pct {
    width: 34px;
    text-align: right;
    font-family: var(--mono);
    font-size: 10px;
  }

  .state {
    width: 7px;
    height: 7px;
    flex: 0 0 7px;
    border-radius: 50%;
    background: var(--accent);
  }

  .state.done {
    background: var(--success);
  }

  .state.error {
    background: var(--error);
  }

  .cancel {
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    border-radius: 4px;
    color: var(--faint);
  }

  .cancel:hover {
    background: var(--selection);
    color: var(--error);
  }

  .cancel-space {
    width: 20px;
  }

  .empty {
    display: grid;
    place-items: center;
    height: 100%;
    color: var(--faint);
    font-size: 12px;
  }
</style>
