<script lang="ts">
  import { onMount, onDestroy } from "svelte";
  import { Terminal } from "@xterm/xterm";
  import { FitAddon } from "@xterm/addon-fit";
  import "@xterm/xterm/css/xterm.css";
  import { X } from "lucide-svelte";
  import { api } from "../lib/api";
  import { prefs } from "../lib/theme.svelte";

  let {
    sessionId,
    title,
    onClose,
  }: {
    sessionId: string;
    title: string;
    onClose: () => void;
  } = $props();

  let host: HTMLDivElement | undefined = $state();
  let term: Terminal | null = null;
  let shellId: string | null = null;
  let timer: ReturnType<typeof setInterval> | null = null;
  let error = $state<string | null>(null);

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

      shellId = await api.openShell(sessionId, t.cols, t.rows);
      t.onData((data) => {
        if (shellId) api.shellWrite(shellId, data).catch(() => {});
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
    <button title="Закрыть терминал" onclick={onClose}><X size={14} /></button>
  </header>
  {#if error}
    <div class="error">{error}</div>
  {:else}
    <div class="host" bind:this={host}></div>
  {/if}
</section>

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
