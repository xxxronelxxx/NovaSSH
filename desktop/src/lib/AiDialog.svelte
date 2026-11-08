<script lang="ts">
  import { onMount } from "svelte";
  import { Play, CornerDownLeft, Save, Sparkles, X } from "lucide-svelte";
  import { api } from "../lib/api";

  let {
    onClose,
    onInsert,
    onRun,
    context = "",
  }: {
    onClose: () => void;
    onInsert: (command: string) => void;
    onRun: (command: string) => void;
    context?: string;
  } = $props();

  let question = $state("");
  let command = $state<string | null>(null);
  let busy = $state(false);
  let error = $state<string | null>(null);
  let ready = $state(false);
  let providerLabel = $state("");

  onMount(async () => {
    try {
      const settings = await api.loadAiSettings();
      providerLabel = settings.provider;
      const key = await api.getSecret(`ai_key_${settings.provider}`);
      ready = settings.enabled && !!key && !!settings.model;
      if (!ready) {
        error =
          "ИИ не настроен. Откройте Настройки → ИИ и укажите ключ, endpoint и модель.";
      }
    } catch (e) {
      error = String(e);
    }
  });

  async function generate() {
    if (!question.trim()) return;
    busy = true;
    error = null;
    command = null;
    try {
      const settings = await api.loadAiSettings();
      if (!settings.enabled) throw new Error("ИИ выключен в настройках");
      const key = (await api.getSecret(`ai_key_${settings.provider}`)) ?? "";
      if (!key.trim()) throw new Error("Не задан API-ключ (Настройки → ИИ)");
      if (!settings.model.trim()) {
        throw new Error("Не выбрана модель (Настройки → ИИ)");
      }
      command = await api.aiAsk(
        settings.endpoint,
        key,
        settings.model,
        question,
        settings.includeContext === false ? "" : context,
      );
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  async function saveSnippet() {
    if (!command) return;
    const name = question.trim().slice(0, 60) || "Команда от ИИ";
    await api.saveSnippet({
      id: "",
      name,
      command,
      description: "Создано ИИ-помощником",
      favorite: false,
      runImmediately: false,
      confirm: true,
      scope: "global",
      serverId: null,
      order: 0,
    });
    onClose();
  }
</script>

<div class="overlay" onclick={onClose}>
  <div class="dialog" onclick={(e) => e.stopPropagation()}>
    <div class="head">
      <Sparkles size={15} />
      <span>ИИ-помощник</span>
      <span class="grow"></span>
      <button class="icon" title="Закрыть" onclick={onClose}>
        <X size={15} />
      </button>
    </div>
    <div class="hint">
      Опишите задачу — помощник предложит одну команду и ничего не выполнит сам.
    </div>
    <textarea
      bind:value={question}
      placeholder="Например: показать 10 самых больших файлов в /var/log"
      spellcheck="false"
      onkeydown={(e) => {
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) generate();
      }}
    ></textarea>
    <div class="foot">
      <button class="btn" onclick={onClose}>Отмена</button>
      <button class="btn primary" disabled={busy || !question.trim()} onclick={generate}>
        {busy ? "Думаю…" : "Предложить команду"}
      </button>
    </div>

    {#if command}
      <div class="result">
        <pre>{command}</pre>
        <div class="actions">
          <button class="btn" onclick={() => { onInsert(command!); onClose(); }}>
            <CornerDownLeft size={13} /> Вставить
          </button>
          <button class="btn" onclick={() => { onRun(command!); onClose(); }}>
            <Play size={13} /> Выполнить
          </button>
          <button class="btn" onclick={saveSnippet}>
            <Save size={13} /> В сниппеты
          </button>
        </div>
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
    gap: 8px;
    margin-bottom: 8px;
    font-size: 13px;
    font-weight: 600;
  }

  .head svg {
    color: var(--accent);
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

  .hint {
    margin-bottom: 8px;
    color: var(--faint);
    font-size: 11px;
  }

  textarea {
    width: 100%;
    height: 90px;
    padding: 8px 10px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--text);
    font-size: 12.5px;
    resize: vertical;
    outline: none;
  }

  textarea:focus {
    border-color: var(--accent);
  }

  .foot {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 10px;
  }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
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

  .result {
    margin-top: 12px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    overflow: hidden;
  }

  .result pre {
    margin: 0;
    padding: 10px 12px;
    background: var(--panel);
    font-family: var(--mono);
    font-size: 12px;
    white-space: pre-wrap;
    user-select: text;
  }

  .actions {
    display: flex;
    gap: 8px;
    padding: 8px;
    border-top: 1px solid var(--border);
  }

  .error {
    margin-top: 10px;
    color: var(--error);
    font-size: 11.5px;
    white-space: pre-wrap;
  }
</style>
