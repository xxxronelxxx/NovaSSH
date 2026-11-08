<script lang="ts">
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import { Minus, Moon, Square, Sun, X, Zap } from "lucide-svelte";
  import { prefs, toggleTheme } from "./theme.svelte";

  const win = getCurrentWindow();
  const dark = $derived(prefs.mode !== "light");
</script>

<header class="titlebar" data-tauri-drag-region>
  <div class="brand" data-tauri-drag-region>
    <span class="mark"><Zap size={12} fill="currentColor" strokeWidth={0} /></span>
    <span class="name">Nova SSH</span>
  </div>
  <div class="grow" data-tauri-drag-region></div>
  <button
    class="theme"
    title={dark ? "Светлая тема" : "Тёмная тема"}
    onclick={toggleTheme}
  >
    {#if dark}
      <Sun size={15} />
    {:else}
      <Moon size={15} />
    {/if}
  </button>
  <div class="win">
    <button title="Свернуть" onclick={() => win.minimize()}>
      <Minus size={14} />
    </button>
    <button title="Развернуть" onclick={() => win.toggleMaximize()}>
      <Square size={11} />
    </button>
    <button class="close" title="Закрыть" onclick={() => win.close()}>
      <X size={14} />
    </button>
  </div>
</header>

<style>
  .titlebar {
    display: flex;
    align-items: center;
    height: var(--title-height);
    min-height: var(--title-height);
    padding-left: 14px;
    background: var(--toolbar);
    border-bottom: 1px solid var(--border);
    -webkit-user-select: none;
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 9px;
  }

  .mark {
    display: grid;
    place-items: center;
    width: 18px;
    height: 18px;
    border-radius: 5px;
    background: var(--accent);
    color: #fff;
  }

  .name {
    font-size: 12.5px;
    font-weight: 600;
    letter-spacing: 0.1px;
  }

  .grow {
    flex: 1;
    align-self: stretch;
  }

  .theme {
    display: grid;
    place-items: center;
    width: 36px;
    height: 28px;
    margin-right: 8px;
    border-radius: var(--radius-sm);
    color: var(--dim);
  }

  .theme:hover {
    background: var(--hover);
    color: var(--text);
  }

  .win {
    display: flex;
    height: 100%;
  }

  .win button {
    display: grid;
    place-items: center;
    width: 46px;
    color: var(--dim);
  }

  .win button:hover {
    background: var(--hover);
    color: var(--text);
  }

  .win .close:hover {
    background: #c42b1c;
    color: #fff;
  }
</style>
