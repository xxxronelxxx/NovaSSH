<script lang="ts">
  import { onMount } from "svelte";
  import {
    CornerDownLeft,
    Pencil,
    Play,
    Plus,
    Search,
    Star,
    Trash2,
    X,
  } from "lucide-svelte";
  import { api, type Snippet } from "../lib/api";

  let {
    onClose,
    onInsert,
    onRun,
  }: {
    onClose: () => void;
    onInsert: (command: string) => void;
    onRun: (command: string) => void;
  } = $props();

  let snippets = $state<Snippet[]>([]);
  let query = $state("");
  let editing = $state<Snippet | null>(null);
  let error = $state<string | null>(null);
  let busy = $state(false);

  const filtered = $derived.by(() => {
    const text = query.trim().toLowerCase();
    const list = text
      ? snippets.filter(
          (item) =>
            item.name.toLowerCase().includes(text) ||
            item.command.toLowerCase().includes(text) ||
            item.description.toLowerCase().includes(text),
        )
      : snippets;
    return [...list].sort((a, b) => {
      if (a.favorite !== b.favorite) return a.favorite ? -1 : 1;
      return a.order - b.order || a.name.localeCompare(b.name, "ru");
    });
  });

  onMount(async () => {
    try {
      snippets = await api.loadSnippets();
    } catch (e) {
      error = String(e);
    }
  });

  function startNew() {
    editing = {
      id: "",
      name: "",
      command: "",
      description: "",
      favorite: false,
      runImmediately: false,
      confirm: true,
      scope: "global",
      serverId: null,
      order: snippets.length,
    };
  }

  function startEdit(snippet: Snippet) {
    editing = { ...snippet };
  }

  async function save() {
    const item = editing;
    if (!item) return;
    if (!item.name.trim() || !item.command.trim()) {
      error = "Заполните имя и команду";
      return;
    }
    busy = true;
    try {
      const saved = await api.saveSnippet(item);
      const index = snippets.findIndex((s) => s.id === saved.id);
      if (index >= 0) snippets[index] = saved;
      else snippets = [...snippets, saved];
      editing = null;
      error = null;
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  async function remove(snippet: Snippet) {
    if (!confirm(`Удалить сниппет «${snippet.name}»?`)) return;
    try {
      await api.deleteSnippet(snippet.id);
      snippets = snippets.filter((item) => item.id !== snippet.id);
    } catch (e) {
      error = String(e);
    }
  }

  async function toggleFavorite(snippet: Snippet) {
    try {
      const saved = await api.saveSnippet({
        ...snippet,
        favorite: !snippet.favorite,
      });
      const index = snippets.findIndex((item) => item.id === saved.id);
      if (index >= 0) snippets[index] = saved;
    } catch (e) {
      error = String(e);
    }
  }

  function use(snippet: Snippet, run: boolean) {
    if (run) {
      if (snippet.confirm && !confirm(`Выполнить «${snippet.command}»?`)) return;
      onRun(snippet.command);
    } else {
      onInsert(snippet.command);
    }
    onClose();
  }
</script>

<div class="overlay" onclick={onClose}>
  <div class="dialog" onclick={(e) => e.stopPropagation()}>
    <div class="head">
      <span>Сниппеты</span>
      <span class="grow"></span>
      <button class="icon" title="Новый сниппет" onclick={startNew}>
        <Plus size={15} />
      </button>
      <button class="icon" title="Закрыть" onclick={onClose}>
        <X size={15} />
      </button>
    </div>

    {#if editing}
      <div class="form">
        <label class="field">
          <span>Имя</span>
          <input bind:value={editing.name} placeholder="Свободное место" />
        </label>
        <label class="field">
          <span>Команда</span>
          <textarea bind:value={editing.command} spellcheck="false"></textarea>
        </label>
        <label class="field">
          <span>Описание</span>
          <input bind:value={editing.description} />
        </label>
        <div class="checks">
          <label><input type="checkbox" bind:checked={editing.favorite} /> В избранное</label>
          <label><input type="checkbox" bind:checked={editing.runImmediately} /> Выполнять сразу</label>
          <label><input type="checkbox" bind:checked={editing.confirm} /> Спрашивать перед запуском</label>
        </div>
        <div class="form-foot">
          <button class="btn" onclick={() => (editing = null)}>Отмена</button>
          <button class="btn primary" disabled={busy} onclick={save}>
            {busy ? "Сохраняю…" : "Сохранить"}
          </button>
        </div>
      </div>
    {:else}
      <label class="search">
        <Search size={14} />
        <input bind:value={query} placeholder="Поиск сниппетов" />
      </label>

      <div class="list">
        {#each filtered as snippet (snippet.id)}
          <div class="item">
            <button
              class="star"
              class:active={snippet.favorite}
              title="Избранное"
              onclick={() => toggleFavorite(snippet)}
            >
              <Star size={13} fill={snippet.favorite ? "currentColor" : "none"} />
            </button>
            <div class="info">
              <div class="name">{snippet.name}</div>
              <div class="command">{snippet.command}</div>
            </div>
            <button class="act" title="Вставить" onclick={() => use(snippet, false)}>
              <CornerDownLeft size={13} />
            </button>
            <button class="act" title="Выполнить" onclick={() => use(snippet, true)}>
              <Play size={13} />
            </button>
            <button class="act" title="Изменить" onclick={() => startEdit(snippet)}>
              <Pencil size={13} />
            </button>
            <button class="act danger" title="Удалить" onclick={() => remove(snippet)}>
              <Trash2 size={13} />
            </button>
          </div>
        {:else}
          <div class="empty">Нет сниппетов</div>
        {/each}
      </div>
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
    z-index: 100;
  }

  .dialog {
    width: 620px;
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
    gap: 6px;
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

  .search {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 32px;
    padding: 0 9px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--faint);
  }

  .search input {
    flex: 1;
    border: 0;
    outline: 0;
    background: transparent;
    font-size: 12px;
  }

  .list {
    height: 340px;
    margin-top: 10px;
    overflow: auto;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
  }

  .item {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 8px;
    border-bottom: 1px solid var(--border);
  }

  .item:last-child {
    border-bottom: 0;
  }

  .item:hover {
    background: var(--hover);
  }

  .star {
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    border-radius: 4px;
    color: var(--faint);
  }

  .star.active {
    color: var(--warn);
  }

  .info {
    flex: 1;
    min-width: 0;
  }

  .name {
    font-size: 12px;
  }

  .command {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--faint);
    font-family: var(--mono);
    font-size: 10.5px;
  }

  .act {
    display: grid;
    place-items: center;
    width: 24px;
    height: 22px;
    border-radius: 4px;
    color: var(--faint);
  }

  .act:hover {
    background: var(--selection);
    color: var(--text);
  }

  .act.danger:hover {
    color: var(--error);
  }

  .empty {
    padding: 30px;
    text-align: center;
    color: var(--faint);
    font-size: 12px;
  }

  .form {
    display: flex;
    flex-direction: column;
    gap: 9px;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .field span {
    font-size: 11px;
    color: var(--faint);
  }

  .field input,
  .field textarea {
    padding: 7px 9px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--text);
    font-size: 12.5px;
    outline: none;
  }

  .field textarea {
    height: 90px;
    resize: vertical;
    font-family: var(--mono);
  }

  .field input:focus,
  .field textarea:focus {
    border-color: var(--accent);
  }

  .checks {
    display: flex;
    flex-wrap: wrap;
    gap: 14px;
    font-size: 11.5px;
    color: var(--dim);
  }

  .checks input {
    accent-color: var(--accent);
  }

  .form-foot {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 6px;
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

  .error {
    margin-top: 8px;
    color: var(--error);
    font-size: 11.5px;
  }
</style>
