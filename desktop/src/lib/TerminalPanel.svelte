<script lang="ts">
  import { onMount, onDestroy } from "svelte";
  import { Terminal } from "@xterm/xterm";
  import { FitAddon } from "@xterm/addon-fit";
  import "@xterm/xterm/css/xterm.css";
  import { ListChecks, Sparkles, X } from "lucide-svelte";
  import SnippetsDialog from "./SnippetsDialog.svelte";
  import AiDialog from "./AiDialog.svelte";
  import { api, type Snippet } from "../lib/api";
  import { prefs } from "../lib/theme.svelte";

  let {
    sessionId,
    title,
    context = "",
    onClose,
  }: {
    sessionId: string;
    title: string;
    context?: string;
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
        .filter((item) => item.favorite)
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

  function writeCommand(command: string, run: boolean) {
    if (!shellId) return;
    api.shellWrite(shellId, run ? `${command}\r` : command).catch(() => {});
    term?.focus();
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
          onclick={() => writeCommand(snippet.command, false)}
          ondblclick={() =>
            writeCommand(snippet.command, snippet.runImmediately)}
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

{#if snippetsOpen}
  <SnippetsDialog
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
