<script lang="ts">
  import {
    ArchiveRestore,
    ArrowLeft,
    ArrowLeftRight,
    ArrowUp,
    Columns2,
    Copy,
    Diff,
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
    canCopy = false,
    canRename = false,
    canDelete = false,
    canEdit = false,
    canCompare = false,
    canSync = false,
    canExtract = false,
    terminalOpen = false,
    filter = "",
    onBack,
    onUp,
    onRefresh,
    onCopy,
    onCompare,
    onSync,
    onExtract,
    onRename,
    onDelete,
    onMkdir,
    onEdit,
    onTerminal,
    onSettings,
    onFilter,
  }: {
    canUp?: boolean;
    canCopy?: boolean;
    canRename?: boolean;
    canDelete?: boolean;
    canEdit?: boolean;
    canCompare?: boolean;
    canSync?: boolean;
    canExtract?: boolean;
    terminalOpen?: boolean;
    filter?: string;
    onBack: () => void;
    onUp: () => void;
    onRefresh: () => void;
    onCopy: () => void;
    onCompare: () => void;
    onSync: () => void;
    onExtract: () => void;
    onRename: () => void;
    onDelete: () => void;
    onMkdir: () => void;
    onEdit: () => void;
    onTerminal: () => void;
    onSettings?: () => void;
    onFilter: (value: string) => void;
  } = $props();
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

  <button class="tool" title="Копировать (F5)" disabled={!canCopy} onclick={onCopy}>
    <Copy size={16} />
  </button>
  <button class="tool" title="Сравнить файлы (Ctrl+F3)" disabled={!canCompare} onclick={onCompare}>
    <GitCompare size={16} />
  </button>
  <button class="tool" title="Сравнить каталоги" disabled>
    <Diff size={16} />
  </button>
  <button class="tool" title="Синхронная навигация" disabled>
    <ArrowLeftRight size={16} />
  </button>
  <button class="tool" title="Синхронизация каталогов" disabled={!canSync} onclick={onSync}>
    <Repeat size={16} />
  </button>
  <button class="tool" title="Распаковать в другую панель (Ctrl+F5)" disabled={!canExtract} onclick={onExtract}>
    <ArchiveRestore size={16} />
  </button>

  <span class="sep"></span>

  <button class="tool" title="Переименовать (F2)" disabled={!canRename} onclick={onRename}>
    <PencilLine size={16} />
  </button>
  <button class="tool" title="Массовое переименование" disabled>
    <ListChecks size={16} />
  </button>
  <button class="tool" title="Новая папка (F7)" onclick={onMkdir}>
    <FolderPlus size={16} />
  </button>
  <button class="tool" title="Удалить (F8)" disabled={!canDelete} onclick={onDelete}>
    <Trash2 size={16} />
  </button>

  <span class="sep"></span>

  <button class="tool" class:accent={terminalOpen} title="Терминал" onclick={onTerminal}>
    <SquareTerminal size={16} />
  </button>
  <button class="tool" title="Редактор (F4)" disabled={!canEdit} onclick={onEdit}>
    <FilePenLine size={16} />
  </button>
  <button class="tool" title="Настройки" disabled={!onSettings} onclick={onSettings}>
    <Settings2 size={16} />
  </button>

  <span class="grow"></span>

  <label class="filter">
    <Search size={14} />
    <input
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

  .tool.accent {
    background: var(--selection);
    color: var(--accent);
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
