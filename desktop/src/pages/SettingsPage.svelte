<script lang="ts">
  import { open, save } from "@tauri-apps/plugin-dialog";
  import { X } from "lucide-svelte";
  import {
    api,
    type Settings,
  } from "../lib/api";
  import { applyAppearance, setTheme } from "../lib/theme.svelte";

  let {
    settings,
    onClose,
    onSave,
    onImported,
  }: {
    settings: Settings;
    onClose: () => void;
    onSave: (settings: Settings) => Promise<void>;
    onImported?: () => Promise<void>;
  } = $props();

  let s = $state<Settings>(JSON.parse(JSON.stringify(settings)));
  let tab = $state<"appearance" | "panels" | "transfer" | "editor" | "profile">(
    "appearance",
  );
  let busy = $state(false);
  let error = $state<string | null>(null);
  let profileText = $state<string | null>(null);
  let importPrompt = $state(false);
  let pendingImport = $state<string | null>(null);

  const tabs = [
    ["appearance", "Внешний вид"],
    ["panels", "Панели"],
    ["transfer", "Передачи"],
    ["editor", "Редактор и терминал"],
    ["profile", "Профиль"],
  ] as const;

  const uiFonts = ["", "Segoe UI", "Tahoma", "Verdana", "Arial", "Inter", "Roboto"];
  const monoFonts = ["", "JetBrains Mono", "Consolas", "Cascadia Mono", "Courier New", "Roboto Mono"];
  const textColors = ["", "#E8ECF3", "#FFFFFF", "#C9D1DB", "#F0C04A", "#8BE28B", "#6CB6FF", "#C08CFF", "#F07A9B"];
  const backgrounds = ["", "#141820", "#0B0D12", "#1B2029", "#0E1622", "#151A12", "#FFFFFF", "#F4F6FA"];

  function touchAppearance() {
    applyAppearance(s.appearance);
  }

  async function commit() {
    busy = true;
    error = null;
    try {
      await onSave(s);
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  async function exportProfile() {
    const path = await save({
      defaultPath: "nova-profile.novaprof",
      filters: [{ name: "Профиль NovaSSH", extensions: ["novaprof"] }],
    });
    if (!path) return;
    await api.exportProfile(path);
  }

  async function pickImport() {
    const path = await open({
      multiple: false,
      filters: [{ name: "Профиль NovaSSH", extensions: ["novaprof"] }],
    });
    if (!path || Array.isArray(path)) return;
    pendingImport = path;
    importPrompt = true;
  }

  async function doImport(replace: boolean) {
    const path = pendingImport;
    importPrompt = false;
    pendingImport = null;
    if (!path) return;
    await api.importProfile(path, replace);
    await onImported?.();
    await onClose();
  }

  async function showCredentials() {
    profileText = await api.credentialsPreview();
  }

  async function saveCredentials() {
    if (!profileText) return;
    const path = await save({
      defaultPath: "nova-passwords.txt",
      filters: [{ name: "Текст", extensions: ["txt"] }],
    });
    if (!path) return;
    await api.exportCredentials(path);
  }
</script>

<div class="settings">
  <div class="head">
    <span>Настройки</span>
    <button class="icon" title="Закрыть" onclick={onClose}>
      <X size={16} />
    </button>
  </div>

  <div class="body">
    <nav class="nav">
      {#each tabs as [id, label] (id)}
        <button class="nav-item" class:active={tab === id} onclick={() => (tab = id)}>
          {label}
        </button>
      {/each}
    </nav>

    <div class="content">
      {#if tab === "appearance"}
        <section class="card">
          <div class="card-title">Тема</div>
          <div class="row">
            <div class="label">Оформление<small>Переключается мгновенно</small></div>
            <div class="seg">
              <button
                class:active={s.window.theme === "dark"}
                onclick={() => { s.window.theme = "dark"; setTheme("dark"); }}
              >Тёмная</button>
              <button
                class:active={s.window.theme === "light"}
                onclick={() => { s.window.theme = "light"; setTheme("light"); }}
              >Светлая</button>
              <button
                class:active={s.window.theme === "system"}
                onclick={() => { s.window.theme = "system"; setTheme("system"); }}
              >Системная</button>
            </div>
          </div>
        </section>
        <section class="card">
          <div class="card-title">Иконки</div>
          <div class="row">
            <div class="label">Файлы<small>Цветные по типу или одноцветные</small></div>
            <div class="seg">
              <button class:active={s.appearance.fileIcons === "colored"} onclick={() => { s.appearance.fileIcons = "colored"; touchAppearance(); }}>Цветные</button>
              <button class:active={s.appearance.fileIcons === "mono"} onclick={() => { s.appearance.fileIcons = "mono"; touchAppearance(); }}>Моно</button>
            </div>
          </div>
          <div class="row">
            <div class="label">Папки<small>Залитые или контурные</small></div>
            <div class="seg">
              <button class:active={s.appearance.folderIcons === "filled"} onclick={() => { s.appearance.folderIcons = "filled"; touchAppearance(); }}>Залитые</button>
              <button class:active={s.appearance.folderIcons === "outline"} onclick={() => { s.appearance.folderIcons = "outline"; touchAppearance(); }}>Контур</button>
            </div>
          </div>
        </section>

        <section class="card">
          <div class="card-title">Шрифты</div>
          <div class="row">
            <div class="label">Интерфейс<small>Системный — шрифт Windows</small></div>
            <select bind:value={s.appearance.uiFont} onchange={touchAppearance}>
              {#each uiFonts as font (font)}
                <option value={font}>{font || "Системный"}</option>
              {/each}
            </select>
          </div>
          <div class="row">
            <div class="label">Моноширинный<small>Терминал, редактор, размеры</small></div>
            <select bind:value={s.appearance.monoFont} onchange={touchAppearance}>
              {#each monoFonts as font (font)}
                <option value={font}>{font || "Системный"}</option>
              {/each}
            </select>
          </div>
          <div class="row">
            <div class="label">Размер шрифта панелей<small>{s.appearance.panelFontSize} пт</small></div>
            <input type="range" min="10" max="16" step="1" bind:value={s.appearance.panelFontSize} oninput={touchAppearance} />
          </div>
        </section>

        <section class="card">
          <div class="card-title">Цвета панелей</div>
          <div class="row">
            <div class="label">Текст<small>Пусто — цвет темы</small></div>
            <div class="swatches">
              {#each textColors as color (color)}
                <button
                  class="swatch"
                  class:selected={s.appearance.panelText === color}
                  class:theme={!color}
                  style:background={color || "var(--panel)"}
                  title={color || "По теме"}
                  onclick={() => { s.appearance.panelText = color; touchAppearance(); }}
                ></button>
              {/each}
            </div>
          </div>
          <div class="row">
            <div class="label">Фон<small>Пусто — цвет темы</small></div>
            <div class="swatches">
              {#each backgrounds as color (color)}
                <button
                  class="swatch"
                  class:selected={s.appearance.panelBackground === color}
                  class:theme={!color}
                  style:background={color || "var(--panel)"}
                  title={color || "По теме"}
                  onclick={() => { s.appearance.panelBackground = color; touchAppearance(); }}
                ></button>
              {/each}
            </div>
          </div>
        </section>
      {:else if tab === "panels"}
        <section class="card">
          <div class="card-title">Панели</div>
          <label class="check"><input type="checkbox" bind:checked={s.panels.showHidden} /> Показывать скрытые файлы</label>
          <label class="check"><input type="checkbox" bind:checked={s.panels.syncNavigation} /> Синхронная навигация</label>
          <label class="check"><input type="checkbox" bind:checked={s.panels.comparePanels} /> Подсвечивать различия панелей</label>
          <label class="check"><input type="checkbox" bind:checked={s.panels.quickFilter} /> Быстрый фильтр по имени</label>
        </section>
      {:else if tab === "transfer"}
        <section class="card">
          <div class="card-title">Передачи</div>
          <div class="row"><div class="label">Ограничение скорости<small>0 — без ограничения</small></div><input class="num" type="number" min="0" bind:value={s.transfer.bandwidthLimitKibps} /> КБ/с</div>
          <div class="row"><div class="label">Одновременных передач</div><input class="num" type="number" min="1" max="8" bind:value={s.transfer.concurrency} /></div>
          <div class="row"><div class="label">Конфликт имён</div>
            <select bind:value={s.transfer.conflictPolicy}>
              <option value="ask">Спрашивать</option>
              <option value="overwrite">Перезаписывать</option>
              <option value="skip">Пропускать</option>
            </select>
          </div>
          <div class="row"><div class="label">Проверка SHA-256</div>
            <select bind:value={s.transfer.verifyChecksum}>
              <option value="off">Выключена</option>
              <option value="sha256">После копирования</option>
            </select>
          </div>
          <label class="check"><input type="checkbox" bind:checked={s.transfer.resume} /> Докачка с места обрыва</label>
          <label class="check"><input type="checkbox" bind:checked={s.transfer.preserveTimes} /> Сохранять время файлов</label>
        </section>
      {:else if tab === "editor"}
        <section class="card">
          <div class="card-title">Редактор</div>
          <div class="row"><div class="label">Внешний редактор<small>Пусто — встроенный</small></div><input class="path" bind:value={s.editor.external} placeholder="C:\Program Files\...\editor.exe" /></div>
          <label class="check"><input type="checkbox" bind:checked={s.editor.fallbackBuiltin} /> Использовать встроенный, если внешний не задан</label>
        </section>
        <section class="card">
          <div class="card-title">Терминал</div>
          <div class="row"><div class="label">Профиль по умолчанию</div>
            <select bind:value={s.terminal.defaultProfile}>
              {#each s.terminal.profiles as profile (profile.id)}
                <option value={profile.id}>{profile.name}</option>
              {/each}
            </select>
          </div>
          <label class="check"><input type="checkbox" bind:checked={s.terminal.builtinXterm} /> Встроенный терминал</label>
        </section>
      {:else if tab === "profile"}
        <section class="card">
          <div class="card-title">Профиль</div>
          <p class="note">Экспорт содержит пароли в открытом тексте — файл не шифруется.</p>
          <div class="buttons">
            <button class="btn" onclick={exportProfile}>Экспортировать профиль…</button>
            <button class="btn" onclick={pickImport}>Импортировать профиль…</button>
            <button class="btn" onclick={showCredentials}>Пароли (IP:пароль)…</button>
          </div>
        </section>
      {/if}

      {#if error}
        <div class="error">{error}</div>
      {/if}

      <div class="footer">
        <button class="btn" onclick={onClose}>Отмена</button>
        <button class="btn primary" disabled={busy} onclick={commit}>
          {busy ? "Сохраняю…" : "Сохранить"}
        </button>
      </div>
    </div>
  </div>
</div>

{#if profileText}
  <div class="overlay" onclick={() => (profileText = null)}>
    <div class="dialog" onclick={(e) => e.stopPropagation()}>
      <div class="dialog-title">Серверы и пароли</div>
      <pre class="dump">{profileText}</pre>
      <div class="foot">
        <button class="btn" onclick={() => (profileText = null)}>Закрыть</button>
        <button class="btn primary" onclick={saveCredentials}>В файл…</button>
      </div>
    </div>
  </div>
{/if}

{#if importPrompt}
  <div class="overlay" onclick={() => (importPrompt = false)}>
    <div class="dialog" onclick={(e) => e.stopPropagation()}>
      <div class="dialog-title">Как импортировать?</div>
      <p class="note">«Добавить» сохранит текущие серверы и пропустит совпадения. «Заменить» перезапишет профиль целиком.</p>
      <div class="foot">
        <button class="btn" onclick={() => (importPrompt = false)}>Отмена</button>
        <button class="btn" onclick={() => doImport(false)}>Добавить</button>
        <button class="btn primary" onclick={() => doImport(true)}>Заменить</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .settings {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 0;
    padding: 12px 22px 18px;
  }

  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-bottom: 10px;
    font-size: 14px;
    font-weight: 600;
  }

  .icon {
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    border-radius: 5px;
    color: var(--faint);
  }

  .icon:hover {
    background: var(--hover);
    color: var(--text);
  }

  .body {
    flex: 1;
    display: flex;
    gap: 14px;
    min-height: 0;
  }

  .nav {
    display: flex;
    flex-direction: column;
    gap: 3px;
    width: 220px;
    min-width: 190px;
    padding: 8px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius);
  }

  .nav-item {
    height: 34px;
    padding: 0 11px;
    border-radius: 7px;
    color: var(--dim);
    text-align: left;
    font-size: 12.5px;
  }

  .nav-item:hover {
    background: var(--hover);
    color: var(--text);
  }

  .nav-item.active {
    background: var(--selection);
    color: var(--text);
  }

  .content {
    flex: 1;
    min-height: 0;
    overflow: auto;
    padding-right: 4px;
  }

  .card {
    margin-bottom: 12px;
    padding: 14px 16px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius);
  }

  .card-title {
    margin-bottom: 10px;
    font-size: 10.5px;
    letter-spacing: 0.8px;
    text-transform: uppercase;
    color: var(--faint);
    font-weight: 600;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 12px;
    min-height: 38px;
    padding: 3px 0;
  }

  .label {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
    font-size: 12.5px;
  }

  .label small,
  .note {
    color: var(--faint);
    font-size: 11px;
    line-height: 1.45;
  }

  .row select,
  .row input[type="text"],
  .row input[type="number"],
  .row .path,
  .row .num {
    height: 32px;
    padding: 0 9px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: color-mix(in srgb, var(--panel) 80%, black);
    color: var(--text);
    font-size: 12px;
    outline: none;
  }

  .row select {
    min-width: 170px;
  }

  .row .path {
    width: 340px;
  }

  .row .num {
    width: 80px;
    text-align: right;
  }

  .row input[type="range"] {
    width: 220px;
    accent-color: var(--accent);
  }

  .seg {
    display: flex;
    gap: 2px;
    padding: 2px;
    border: 1px solid var(--border);
    border-radius: 7px;
  }

  .seg button {
    padding: 5px 11px;
    border-radius: 5px;
    color: var(--dim);
    font-size: 11.5px;
  }

  .seg button.active {
    background: var(--accent);
    color: #fff;
  }

  .swatches {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    max-width: 260px;
  }

  .swatch {
    width: 22px;
    height: 22px;
    border-radius: 50%;
    border: 1px solid var(--border-strong);
  }

  .swatch.selected {
    border: 2px solid var(--accent);
  }

  .swatch.theme::after {
    content: "✦";
    display: grid;
    place-items: center;
    height: 100%;
    color: var(--accent);
    font-size: 10px;
  }

  .check {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 32px;
    font-size: 12.5px;
    color: var(--text);
  }

  .check input {
    accent-color: var(--accent);
  }

  .buttons {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 8px;
  }

  .btn,
  .foot .btn {
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

  .footer {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    padding-top: 8px;
  }

  .error {
    margin-bottom: 8px;
    color: var(--error);
    font-size: 11.5px;
  }

  .overlay {
    position: fixed;
    inset: 0;
    display: grid;
    place-items: center;
    background: rgba(0, 0, 0, 0.4);
    z-index: 90;
  }

  .dialog {
    width: 720px;
    max-width: 92vw;
    padding: 16px 18px 12px;
    background: var(--menu);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
  }

  .dialog-title {
    margin-bottom: 10px;
    font-size: 13px;
    font-weight: 600;
  }

  .dump {
    max-height: 360px;
    overflow: auto;
    padding: 10px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    font-family: var(--mono);
    font-size: 11px;
    white-space: pre;
    user-select: text;
  }

  .foot {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 12px;
  }
</style>
