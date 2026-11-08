<script lang="ts">
  import { onMount, onDestroy } from "svelte";
  import { Terminal } from "@xterm/xterm";
  import { FitAddon } from "@xterm/addon-fit";
  import "@xterm/xterm/css/xterm.css";
  import { ListChecks, Save, Sparkles, X } from "lucide-svelte";
  import SnippetsDialog from "./SnippetsDialog.svelte";
  import AiDialog from "./AiDialog.svelte";
  import { api, type Snippet } from "../lib/api";
  import { prefs } from "../lib/theme.svelte";

  let {
    sessionId,
    serverId = null,
    title,
    context = "",
    path = "",
    file = "",
    serverHost = "",
    user = "",
    port = 22,
    uname = "",
    onClose,
  }: {
    sessionId: string;
    serverId?: string | null;
    title: string;
    context?: string;
    path?: string;
    file?: string;
    serverHost?: string;
    user?: string;
    port?: number;
    uname?: string;
    onClose: () => void;
  } = $props();

  let host: HTMLDivElement | undefined = $state();
  let term: Terminal | null = null;
  let shellId: string | null = null;
  let timer: ReturnType<typeof setInterval> | null = null;
  let error = $state<string | null>(null);
  let snippetsOpen = $state(false);
  let aiOpen = $state(false);
  let favorites = $state<Snippet[]>([]);
  let prompt = $state<{
    label: string;
    value: string;
    resolve: (value: string | null) => void;
  } | null>(null);
  let snippetDraft = $state<{
    name: string;
    command: string;
    serverOnly: boolean;
  } | null>(null);
  let snippetError = $state<string | null>(null);

  onMount(async () => {
    if (!host) return;
    try {
      const light = document.documentElement.dataset.theme === "light";
      const t = new Terminal({
        fontFamily:
          getComputedStyle(document.documentElement).getPropertyValue("--mono") ||
          "Consolas, monospace",
        fontSize: 12.5,
        cursorBlink: true,
        convertEol: false,
        theme: {
          background: light ? "#ffffff" : "#0f1115",
          foreground: light ? "#141922" : "#e8ecf3",
          cursor: light ? "#2f6feb" : "#4c8dff",
          selectionBackground: light
            ? "rgba(47,111,235,0.2)"
            : "rgba(76,141,255,0.3)",
        },
      });
      const fit = new FitAddon();
      t.loadAddon(fit);
      t.open(host);
      fit.fit();
      term = t;

      favorites = (await api.loadSnippets().catch(() => []))
        .filter(
          (item) =>
            item.favorite &&
            (item.scope !== "server" ||
              !item.serverId ||
              item.serverId === serverId),
        )
        .sort((a, b) => a.order - b.order);
      shellId = await api.openShell(sessionId, t.cols, t.rows);
      t.onData((data) => {
        if (shellId) api.shellWrite(shellId, data).catch(() => {});
      });
      t.attachCustomKeyEventHandler((event) => {
        if (!event.ctrlKey || !event.shiftKey) return true;
        const key = event.key.toLowerCase();
        if (key === "p") {
          snippetsOpen = true;
          return false;
        }
        if (key === "a") {
          aiOpen = true;
          return false;
        }
        return true;
      });
      t.focus();

      timer = setInterval(async () => {
        if (!shellId) return;
        try {
          const chunk = await api.shellPoll(shellId);
          if (chunk) t.write(chunk);
        } catch {
          // The shell dies with its session; error is shown on close.
        }
      }, 120);
    } catch (e) {
      error = String(e);
    }
  });

  onDestroy(() => {
    if (timer) clearInterval(timer);
    if (shellId) api.shellClose(shellId).catch(() => {});
    term?.dispose();
  });

  async function expand(command: string): Promise<string | null> {
    let text = command
      .replaceAll("{path}", path)
      .replaceAll("{file}", file)
      .replaceAll("{host}", serverHost)
      .replaceAll("{user}", user)
      .replaceAll("{port}", String(port))
      .replaceAll("{server}", title);
    const pattern = /\{prompt:([^}]*)\}/;
    while (true) {
      const match = pattern.exec(text);
      if (!match) break;
      const label = match[1].trim() || "Значение";
      const answer = await new Promise<string | null>((resolve) => {
        prompt = { label, value: "", resolve };
      });
      if (answer == null) return null;
      text = text.slice(0, match.index) + answer + text.slice(match.index + match[0].length);
    }
    return text;
  }

  async function writeCommand(command: string, run: boolean) {
    if (!shellId) return;
    const text = await expand(command);
    if (text == null) return;
    api.shellWrite(shellId, run ? `${text}\r` : text).catch(() => {});
    term?.focus();
  }

  function selectionToSnippet() {
    const text = term?.getSelection().trim() ?? "";
    if (!text) {
      window.alert("Выделите текст в терминале, чтобы сохранить его как сниппет");
      return;
    }
    const first = text.split("\n")[0].trim();
    snippetDraft = {
      name: first.slice(0, 60) || "Команда из терминала",
      command: text,
      serverOnly: !!serverId,
    };
    snippetError = null;
  }

  async function saveSnippetDraft() {
    const draft = snippetDraft;
    if (!draft) return;
    const name = draft.name.trim();
    if (!name || !draft.command.trim()) {
      snippetError = "Заполните имя";
      return;
    }
    try {
      const saved = await api.saveSnippet({
        id: "",
        name,
        command: draft.command,
        description: "Сохранено из терминала",
        favorite: false,
        runImmediately: false,
        confirm: true,
        scope: draft.serverOnly ? "server" : "global",
        serverId: draft.serverOnly ? serverId : null,
        order: 0,
      });
      if (saved.favorite) favorites = [...favorites, saved];
      snippetDraft = null;
    } catch (e) {
      snippetError = String(e);
    }
  }

  async function useChip(snippet: Snippet, forceRun = false) {
    if (snippet.runImmediately || forceRun) {
      if (
        snippet.confirm &&
        !window.confirm(`Выполнить «${snippet.command}»?`)
      ) {
        return;
      }
      await writeCommand(snippet.command, true);
    } else {
      await writeCommand(snippet.command, false);
    }
  }

  function submitPrompt() {
    const current = prompt;
    if (!current) return;
    prompt = null;
    current.resolve(current.value);
  }

  function toggleTheme() {
    if (!term) return;
    const light = document.documentElement.dataset.theme === "light";
    term.options.theme = {
      background: light ? "#ffffff" : "#0f1115",
      foreground: light ? "#141922" : "#e8ecf3",
      cursor: light ? "#2f6feb" : "#4c8dff",
      selectionBackground: light
        ? "rgba(47,111,235,0.2)"
        : "rgba(76,141,255,0.3)",
    };
  }

  // Recolour when the theme flips while the panel is open.
  $effect(() => {
    prefs.mode;
    toggleTheme();
  });
</script>

<section class="terminal">
  <header>
    <span class="title">Терминал · {title}</span>
    <span class="grow"></span>
    <button title="Сохранить выделение как сниппет" onclick={selectionToSnippet}>
      <Save size={14} />
    </button>
    <button title="Сниппеты" onclick={() => (snippetsOpen = true)}>
      <ListChecks size={14} />
    </button>
    <button title="ИИ-помощник" onclick={() => (aiOpen = true)}>
      <Sparkles size={14} />
    </button>
    <button title="Закрыть терминал" onclick={onClose}><X size={14} /></button>
  </header>
  {#if favorites.length}
    <div class="quick">
      {#each favorites as snippet (snippet.id)}
        <button
          class="chip"
          title={snippet.description || snippet.command}
          onclick={() => void useChip(snippet)}
          ondblclick={() => void useChip(snippet, true)}
        >
          {snippet.name}
        </button>
      {/each}
    </div>
  {/if}
  {#if error}
    <div class="error">{error}</div>
  {:else}
    <div class="host" bind:this={host}></div>
  {/if}
</section>

{#if snippetDraft}
  <div class="prompt-overlay" onclick={() => (snippetDraft = null)}>
    <div class="prompt" onclick={(e) => e.stopPropagation()}>
      <div class="prompt-title">Сниппет из терминала</div>
      <input
        bind:value={snippetDraft.name}
        autofocus
        placeholder="Имя сниппета"
        onkeydown={(e) => e.key === "Enter" && saveSnippetDraft()}
      />
      <pre class="snippet-command">{snippetDraft.command}</pre>
      {#if serverId}
        <label class="snippet-scope">
          <input type="checkbox" bind:checked={snippetDraft.serverOnly} />
          Только для этого сервера
        </label>
      {/if}
      {#if snippetError}<div class="snippet-error">{snippetError}</div>{/if}
      <div class="prompt-foot">
        <button class="pbtn" onclick={() => (snippetDraft = null)}>
          Отмена
        </button>
        <button class="pbtn primary" onclick={saveSnippetDraft}>
          Сохранить
        </button>
      </div>
    </div>
  </div>
{/if}

{#if prompt}
  <div class="prompt-overlay" onclick={() => (prompt = null)}>
    <div class="prompt" onclick={(e) => e.stopPropagation()}>
      <div class="prompt-title">{prompt.label}</div>
      <input
        bind:value={prompt.value}
        autofocus
        onkeydown={(e) => {
          if (e.key === "Enter") submitPrompt();
          if (e.key === "Escape") prompt = null;
        }}
      />
      <div class="prompt-foot">
        <button class="pbtn" onclick={() => (prompt = null)}>Отмена</button>
        <button class="pbtn primary" onclick={submitPrompt}>OK</button>
      </div>
    </div>
  </div>
{/if}

{#if snippetsOpen}
  <SnippetsDialog
    {serverId}
    onClose={() => (snippetsOpen = false)}
    onInsert={(command) => writeCommand(command, false)}
    onRun={(command) => writeCommand(command, true)}
  />
{/if}

{#if aiOpen}
  <AiDialog
    onClose={() => (aiOpen = false)}
    onInsert={(command) => writeCommand(command, false)}
    onRun={(command) => writeCommand(command, true)}
    {context}
  />
{/if}

<style>
  .terminal {
    display: flex;
    flex-direction: column;
    height: 280px;
    min-height: 160px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow: hidden;
  }

  header {
    display: flex;
    align-items: center;
    height: 32px;
    min-height: 32px;
    padding: 0 10px;
    border-bottom: 1px solid var(--border);
    color: var(--faint);
    font-size: 11px;
  }

  .title {
    font-weight: 600;
    color: var(--dim);
  }

  .grow {
    flex: 1;
  }

  header button {
    display: grid;
    place-items: center;
    width: 24px;
    height: 22px;
    border-radius: 4px;
    color: var(--faint);
  }

  header button:hover {
    background: var(--hover);
    color: var(--text);
  }

  .quick {
    display: flex;
    gap: 6px;
    padding: 5px 10px;
    overflow-x: auto;
    border-bottom: 1px solid var(--border);
    background: var(--panel-header);
  }

  .chip {
    flex: 0 0 auto;
    padding: 3px 9px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--raised);
    color: var(--dim);
    font-size: 11px;
  }

  .prompt-overlay {
    position: fixed;
    inset: 0;
    display: grid;
    place-items: center;
    background: rgba(0, 0, 0, 0.45);
    z-index: 130;
  }

  .prompt {
    width: 360px;
    padding: 14px 16px 12px;
    background: var(--menu);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.5);
  }

  .prompt-title {
    margin-bottom: 8px;
    font-size: 12.5px;
    font-weight: 600;
  }

  .prompt input {
    width: 100%;
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

  .snippet-command {
    max-height: 120px;
    margin: 8px 0 0;
    padding: 8px 9px;
    overflow: auto;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--text);
    font-family: var(--mono);
    font-size: 11px;
    white-space: pre-wrap;
    user-select: text;
  }

  .snippet-scope {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-top: 8px;
    color: var(--dim);
    font-size: 11.5px;
  }

  .snippet-scope input {
    accent-color: var(--accent);
  }

  .snippet-error {
    margin-top: 8px;
    color: var(--error);
    font-size: 11.5px;
  }

  .prompt input:focus {
    border-color: var(--accent);
  }

  .prompt-foot {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 10px;
  }

  .pbtn {
    padding: 6px 12px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--raised);
    color: var(--text);
    font-size: 12px;
  }

  .pbtn.primary {
    background: var(--accent);
    border-color: transparent;
    color: #fff;
    font-weight: 600;
  }

  .chip:hover {
    color: var(--text);
    border-color: var(--accent);
  }

  .host {
    flex: 1;
    min-height: 0;
    padding: 4px 6px;
    background: var(--panel);
  }

  .error {
    padding: 16px;
    color: var(--error);
    font-size: 12px;
  }

  :global(.xterm) {
    height: 100%;
    padding: 2px;
  }

  :global(.xterm-viewport) {
    background: transparent !important;
  }
</style>
