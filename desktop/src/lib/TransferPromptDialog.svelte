<script lang="ts">
  import { X } from "lucide-svelte";

  let {
    title,
    items,
    initialDir,
    dirLabel,
    allowRename,
    onClose,
    onConfirm,
  }: {
    title: string;
    items: string[];
    initialDir: string;
    dirLabel: string;
    allowRename: boolean;
    onClose: () => void;
    onConfirm: (result: { dir: string; name: string | null }) => void;
  } = $props();

  let dir = $state(initialDir);
  let name = $state(items.length === 1 ? items[0] : "");
  let error = $state<string | null>(null);

  function submit() {
    const target = dir.trim();
    if (!target) {
      error = "Укажите каталог назначения";
      return;
    }
    const rename = allowRename && items.length === 1 ? name.trim() : "";
    if (rename && (rename.includes("/") || rename.includes("\\"))) {
      error = "Имя не должно содержать разделитель пути";
      return;
    }
    onConfirm({ dir: target, name: rename && rename !== items[0] ? rename : null });
  }
</script>

<div class="overlay" onclick={onClose}>
  <div class="dialog" onclick={(e) => e.stopPropagation()}>
    <div class="head">
      <span>{title}</span>
      <span class="grow"></span>
      <button class="icon" title="Закрыть" onclick={onClose}><X size={15} /></button>
    </div>

    <label class="field">
      <span>{dirLabel}</span>
      <input bind:value={dir} spellcheck="false" onkeydown={(e) => e.key === "Enter" && submit()} />
    </label>

    {#if items.length === 1}
      <label class="field">
        <span>Имя {allowRename ? "(можно изменить)" : ""}</span>
        <input bind:value={name} disabled={!allowRename} spellcheck="false" onkeydown={(e) => e.key === "Enter" && submit()} />
      </label>
    {:else}
      <div class="note">Файлов: {items.length}. Имена сохранятся.</div>
    {/if}

    {#if error}<div class="error">{error}</div>{/if}

    <div class="foot">
      <button class="btn" onclick={onClose}>Отмена</button>
      <button class="btn primary" onclick={submit}>Начать</button>
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
    width: 520px;
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

  .field {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-bottom: 10px;
  }

  .field span {
    color: var(--faint);
    font-size: 10.5px;
  }

  .field input {
    height: 32px;
    padding: 0 9px;
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

  .field input:disabled {
    opacity: 0.6;
  }

  .note {
    color: var(--faint);
    font-size: 11.5px;
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

  .error {
    margin-top: 2px;
    color: var(--error);
    font-size: 11.5px;
  }
</style>
