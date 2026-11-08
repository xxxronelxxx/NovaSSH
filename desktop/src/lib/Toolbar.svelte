<script lang="ts">
  import {
    ArchiveRestore,
    ArrowLeft,
    ArrowLeftRight,
    ArrowUp,
    Columns2,
    Copy,
    Diff,
    Download,
    FilePenLine,
    FolderPlus,
    GitCompare,
    ListChecks,
    PencilLine,
    RefreshCw,
    Repeat,
    Search,
    Settings2,
    SquareTerminal,
    Trash2,
  } from "lucide-svelte";

  let {
    canUp = false,
    canDownload = false,
    filter = "",
    onBack,
    onUp,
    onRefresh,
    onDownload,
    onFilter,
    onSettings,
  }: {
    canUp?: boolean;
    canDownload?: boolean;
    filter?: string;
    onBack: () => void;
    onUp: () => void;
    onRefresh: () => void;
    onDownload: () => void;
    onFilter: (value: string) => void;
    onSettings?: () => void;
  } = $props();

  let filterInput: HTMLInputElement | undefined = $state();
</script>

<div class="toolbar">
  <button class="tool" title="К списку серверов" onclick={onBack}>
    <ArrowLeft size={17} />
  </button>
  <button class="tool" title="Вверх (Backspace)" disabled={!canUp} onclick={onUp}>
    <ArrowUp size={17} />
  </button>
  <button class="tool" title="Обновить" onclick={onRefresh}>
    <RefreshCw size={16} />
  </button>
  <button class="tool" title="Разделить панель" disabled>
    <Columns2 size={16} />
  </button>

  <span class="sep"></span>

  <button class="tool" title="Копировать (F5)" disabled>
    <Copy size={16} />
  </button>
  <button class="tool" title="Сравнить файлы (Ctrl+F3)" disabled>
    <GitCompare size={16} />
  </button>
  <button class="tool" title="Сравнить каталоги" disabled>
    <Diff size={16} />
  </button>
  <button class="tool" title="Синхронная навигация" disabled>
    <ArrowLeftRight size={16} />
  </button>
  <button class="tool" title="Синхронизация каталогов" disabled>
    <Repeat size={16} />
  </button>
  <button class="tool" title="Распаковать в другую панель (Ctrl+F5)" disabled>
    <ArchiveRestore size={16} />
  </button>

  <span class="sep"></span>

  <button class="tool" title="Переименовать (F2)" disabled>
    <PencilLine size={16} />
  </button>
  <button class="tool" title="Массовое переименование" disabled>
    <ListChecks size={16} />
  </button>
  <button class="tool" title="Новая папка (F7)" disabled>
    <FolderPlus size={16} />
  </button>
  <button class="tool" title="Удалить (F8)" disabled>
    <Trash2 size={16} />
  </button>

  <span class="sep"></span>

  <button class="tool" title="Терминал" disabled>
    <SquareTerminal size={16} />
  </button>
  <button class="tool" title="Редактор (F4)" disabled>
    <FilePenLine size={16} />
  </button>
  <button class="tool" title="Скачать выбранное" disabled={!canDownload} onclick={onDownload}>
    <Download size={16} />
  </button>
  <button class="tool" title="Настройки" disabled={!onSettings} onclick={onSettings}>
    <Settings2 size={16} />
  </button>

  <span class="grow"></span>

  <label class="filter">
    <Search size={14} />
    <input
      bind:this={filterInput}
      value={filter}
      placeholder="Фильтр по имени"
      spellcheck="false"
      oninput={(e) => onFilter((e.target as HTMLInputElement).value)}
    />
  </label>
</div>

<style>
  .toolbar {
    display: flex;
    align-items: center;
    gap: 2px;
    height: var(--toolbar-height);
    min-height: var(--toolbar-height);
    padding: 0 18px;
  }

  .tool {
    display: grid;
    place-items: center;
    width: 34px;
    height: 30px;
    border-radius: var(--radius-sm);
    color: var(--dim);
  }

  .tool:hover:not(:disabled) {
    background: var(--hover);
    color: var(--text);
  }

  .tool:disabled {
    opacity: 0.48;
    cursor: default;
  }

  .sep {
    width: 1px;
    height: 20px;
    margin: 0 7px;
    background: var(--border);
  }

  .grow {
    flex: 1;
  }

  .filter {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 280px;
    height: 34px;
    padding: 0 11px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--panel);
    color: var(--faint);
  }

  .filter:focus-within {
    border-color: var(--accent);
    color: var(--accent);
  }

  .filter input {
    flex: 1;
    min-width: 0;
    border: 0;
    outline: 0;
    background: transparent;
    color: var(--text);
    font-size: 12.5px;
  }

  .filter input::placeholder {
    color: var(--faint);
  }
</style>
