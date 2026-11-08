<script lang="ts">
  import { open, save } from "@tauri-apps/plugin-dialog";
  import { Plus, Trash2, X } from "lucide-svelte";
  import { onMount } from "svelte";
  import LogsDialog from "../lib/LogsDialog.svelte";
  import SnippetsDialog from "../lib/SnippetsDialog.svelte";
  import SyncShareCard from "../lib/SyncShareCard.svelte";
  import {
    api,
    type AiModel,
    type AiSettings,
    type ColorRule,
    type ColorRules,
    type LogSettings,
    type Settings,
    type AppInfo,
    type WinscpImportReport,
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
  let tab = $state<
    | "appearance"
    | "panels"
    | "transfer"
    | "editor"
    | "colors"
    | "logs"
    | "ai"
    | "import"
    | "sync"
    | "profile"
    | "about"
  >("appearance");
  let busy = $state(false);
  let error = $state<string | null>(null);
  let profileText = $state<string | null>(null);
  let importPrompt = $state(false);
  let pendingImport = $state<string | null>(null);

  let ai = $state<AiSettings | null>(null);
  let aiKey = $state("");
  let aiModels = $state<AiModel[]>([]);
  let aiBusy = $state(false);
  let aiError = $state<string | null>(null);
  let aiSaved = $state<string | null>(null);

  let rules = $state<ColorRules | null>(null);
  let rulesSaved = $state<string | null>(null);
  let ruleDraft = $state<ColorRule | null>(null);

  let logSettings = $state<LogSettings | null>(null);
  let logsOpen = $state(false);
  let snippetsOpen = $state(false);

  let winscpPath = $state("");
  let winscpReport = $state<WinscpImportReport | null>(null);
  let winscpError = $state<string | null>(null);
  let winscpBusy = $state(false);
  let toast = $state<string | null>(null);
  let info = $state<AppInfo | null>(null);

  const providers: Record<string, { label: string; endpoint: string }> = {
    zen: { label: "OpenCode Zen", endpoint: "https://opencode.ai/zen/v1" },
    go: {
      label: "OpenCode Go",
      endpoint: "https://opencode.ai/inference/go/openai/v1",
    },
    openrouter: {
      label: "OpenRouter",
      endpoint: "https://openrouter.ai/api/v1",
    },
    custom: { label: "Свой endpoint", endpoint: "" },
  };

  onMount(async () => {
    try {
      ai = await api.loadAiSettings();
      aiKey = (await api.getSecret(`ai_key_${ai.provider}`)) ?? "";
    } catch (e) {
      aiError = String(e);
    }
    info = await api.vaultInfo().catch(() => null);
    rules = await api.loadColorRules().catch(() => null);
    logSettings = await api.loadLogSettings().catch(() => null);
  });

  async function changeProvider(provider: string) {
    if (!ai) return;
    ai.provider = provider;
    const preset = providers[provider];
    if (preset && preset.endpoint) ai.endpoint = preset.endpoint;
    aiModels = [];
    try {
      aiKey = (await api.getSecret(`ai_key_${provider}`)) ?? "";
    } catch {
      aiKey = "";
    }
  }

  async function loadAiModels() {
    if (!ai) return;
    aiBusy = true;
    aiError = null;
    try {
      aiModels = await api.aiModels(ai.endpoint, aiKey);
      if (!aiModels.some((model) => model.id === ai!.model)) {
        ai.model = aiModels[0]?.id ?? ai.model;
      }
    } catch (e) {
      aiError = String(e);
    } finally {
      aiBusy = false;
    }
  }

  async function saveAi() {
    if (!ai) return;
    aiBusy = true;
    aiError = null;
    aiSaved = null;
    try {
      await api.saveAiSettings(ai);
      if (aiKey.trim()) {
        await api.setSecret(`ai_key_${ai.provider}`, aiKey.trim());
      }
      aiSaved = "Сохранено";
    } catch (e) {
      aiError = String(e);
    } finally {
      aiBusy = false;
    }
  }

  const tabs = [
    ["appearance", "Внешний вид"],
    ["panels", "Панели"],
    ["transfer", "Передачи"],
    ["editor", "Редактор и терминал"],
    ["colors", "Цвета файлов"],
    ["logs", "Журнал"],
    ["ai", "ИИ"],
    ["import", "Импорт WinSCP"],
    ["sync", "Синхронизация"],
    ["profile", "Профиль"],
    ["about", "О программе"],
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

  async function saveRules(next: ColorRules) {
    rules = next;
    await api.saveColorRules(next);
    rulesSaved = "Правила сохранены";
    setTimeout(() => (rulesSaved = null), 1800);
  }

  function addRule() {
    ruleDraft = {
      id: `rule_${Date.now()}`,
      name: "Новое правило",
      enabled: true,
      priority: 10,
      scope: "both",
      pattern: "*.log",
      isRegex: false,
      fg: "#FF7B72",
      bg: null,
      bold: false,
      italic: false,
      underline: false,
    };
  }

  async function commitRule() {
    const draft = ruleDraft;
    if (!draft || !rules) return;
    ruleDraft = null;
    if (!draft.name.trim() || !draft.pattern.trim()) return;
    await saveRules({ ...rules, rules: [...rules.rules, draft] });
  }

  async function updateRule(index: number, patch: Partial<ColorRule>) {
    if (!rules) return;
    const next = rules.rules.map((rule, position) =>
      position === index ? { ...rule, ...patch } : rule,
    );
    await saveRules({ ...rules, rules: next });
  }

  async function removeRule(index: number) {
    if (!rules) return;
    await saveRules({
      ...rules,
      rules: rules.rules.filter((_, position) => position !== index),
    });
  }

  async function toggleEditLog(value: boolean) {
    if (!logSettings) return;
    logSettings = { ...logSettings, editLog: value };
    await api.saveLogSettings(logSettings).catch(() => {});
  }

  async function pickWinscp() {
    const path = await open({
      multiple: false,
      directory: false,
      filters: [{ name: "Конфигурация WinSCP", extensions: ["ini"] }],
    });
    if (!path || Array.isArray(path)) return;
    winscpPath = path;
  }

  async function runWinscpImport() {
    if (!winscpPath.trim()) return;
    winscpBusy = true;
    winscpError = null;
    winscpReport = null;
    try {
      winscpReport = await api.importWinscp(winscpPath.trim());
      await onImported?.();
    } catch (e) {
      winscpError = String(e);
    } finally {
      winscpBusy = false;
    }
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
          <div class="row"><div class="label">Потоков на один файл<small>Файлы больше 8 МБ режутся на части</small></div>
            <select bind:value={s.transfer.chunksPerFile}>
              {#each [1, 2, 3, 4, 6, 8] as value (value)}
                <option {value}>{value}</option>
              {/each}
            </select>
          </div>
          <div class="row"><div class="label">Конфликт имён</div>
            <select bind:value={s.transfer.conflictPolicy}>
              <option value="ask">Спрашивать</option>
              <option value="overwrite">Перезаписывать</option>
              <option value="skip">Пропускать</option>
              <option value="rename">Переименовывать</option>
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
        <section class="card">
          <div class="card-title">Сниппеты</div>
          <p class="note">Быстрые команды для терминала: избранные показываются над вводом.</p>
          <div class="buttons">
            <button class="btn" onclick={() => (snippetsOpen = true)}>
              Управление сниппетами…
            </button>
          </div>
        </section>
      {:else if tab === "colors"}
        <section class="card">
          <div class="card-title">Правила подсветки файлов</div>
          <p class="note">
            Правила применяются к именам файлов и папок. Более высокий приоритет
            перекрывает нижний; маска — это шаблон вида *.php.
          </p>
          {#if rules}
            <div class="rules">
              {#each rules.rules as rule, index (rule.id)}
                <div class="rule">
                  <span
                    class="rule-dot"
                    style:background={rule.fg ?? "var(--faint)"}
                  ></span>
                  <input
                    class="rule-name"
                    value={rule.name}
                    onchange={(e) =>
                      updateRule(index, {
                        name: (e.target as HTMLInputElement).value,
                      })}
                  />
                  <input
                    class="rule-pattern"
                    value={rule.pattern}
                    onchange={(e) =>
                      updateRule(index, {
                        pattern: (e.target as HTMLInputElement).value,
                      })}
                  />
                  <select
                    value={rule.scope}
                    onchange={(e) =>
                      updateRule(index, {
                        scope: (e.target as HTMLSelectElement).value,
                      })}
                  >
                    <option value="both">везде</option>
                    <option value="remote">сервер</option>
                    <option value="local">локально</option>
                  </select>
                  <input
                    class="rule-color"
                    type="color"
                    value={rule.fg ?? "#E8ECF3"}
                    oninput={(e) =>
                      updateRule(index, {
                        fg: (e.target as HTMLInputElement).value,
                      })}
                  />
                  <label class="check compact">
                    <input
                      type="checkbox"
                      checked={rule.enabled}
                      onchange={(e) =>
                        updateRule(index, {
                          enabled: (e.target as HTMLInputElement).checked,
                        })}
                    />
                    вкл
                  </label>
                  <button
                    class="icon"
                    title="Удалить правило"
                    onclick={() => removeRule(index)}
                  >
                    <Trash2 size={13} />
                  </button>
                </div>
              {:else}
                <div class="empty">Правил нет</div>
              {/each}
            </div>
            <div class="buttons">
              <button class="btn" onclick={addRule}>
                <Plus size={13} /> Добавить правило
              </button>
              {#if rulesSaved}<span class="ok">{rulesSaved}</span>{/if}
            </div>
          {:else}
            <div class="empty">Не удалось загрузить правила</div>
          {/if}
        </section>
        {#if ruleDraft}
          <section class="card">
            <div class="card-title">Новое правило</div>
            <div class="row">
              <div class="label">Имя</div>
              <input class="path" bind:value={ruleDraft.name} />
            </div>
            <div class="row">
              <div class="label">Маска или регулярное выражение</div>
              <input class="path" bind:value={ruleDraft.pattern} />
            </div>
            <div class="row">
              <div class="label">Область</div>
              <select bind:value={ruleDraft.scope}>
                <option value="both">везде</option>
                <option value="remote">сервер</option>
                <option value="local">локально</option>
              </select>
            </div>
            <div class="row">
              <div class="label">Цвет</div>
              <input class="rule-color" type="color" bind:value={ruleDraft.fg} />
            </div>
            <div class="checks">
              <label><input type="checkbox" bind:checked={ruleDraft.isRegex} /> Регулярное выражение</label>
              <label><input type="checkbox" bind:checked={ruleDraft.bold} /> Жирный</label>
              <label><input type="checkbox" bind:checked={ruleDraft.italic} /> Курсив</label>
              <label><input type="checkbox" bind:checked={ruleDraft.underline} /> Подчёркнутый</label>
            </div>
            <div class="buttons">
              <button class="btn" onclick={() => (ruleDraft = null)}>Отмена</button>
              <button class="btn primary" onclick={commitRule}>Добавить</button>
            </div>
          </section>
        {/if}
      {:else if tab === "logs"}
        <section class="card">
          <div class="card-title">Журнал редактирования</div>
          {#if logSettings}
            <label class="check">
              <input
                type="checkbox"
                checked={logSettings.editLog}
                onchange={(e) => toggleEditLog((e.target as HTMLInputElement).checked)}
              />
              Записывать логи в папку logs
            </label>
          {/if}
          <p class="note">
            При включении каждое открытие и сохранение файла пишется в
            logs/&lt;сервер&gt;_ДД-ММ-ГГГГ.log: дата, время, сервер и путь к файлу.
          </p>
          <div class="buttons">
            <button class="btn" onclick={() => (logsOpen = true)}>
              Открыть журнал
            </button>
          </div>
        </section>
      {:else if tab === "import"}
        <section class="card">
          <div class="card-title">Импорт из WinSCP</div>
          <p class="note">
            Пароли расшифровываются локально и сохраняются в зашифрованном
            хранилище NovaSSH. Существующие серверы не перезаписываются.
          </p>
          <div class="row">
            <div class="label">WinSCP.ini</div>
            <input
              class="path"
              bind:value={winscpPath}
              placeholder="C:\Users\...\WinSCP.ini"
            />
            <button class="btn" onclick={pickWinscp}>Обзор…</button>
          </div>
          <div class="buttons">
            <button
              class="btn primary"
              disabled={winscpBusy || !winscpPath.trim()}
              onclick={runWinscpImport}
            >
              {winscpBusy ? "Импортирую…" : "Импортировать серверы и группы"}
            </button>
          </div>
          {#if winscpReport}
            <div class="note ok-text">
              Сессий: {winscpReport.sessions} · добавлено: {winscpReport.imported}
              · пропущено: {winscpReport.skipped} · групп: {winscpReport.groups}
              · паролей: {winscpReport.passwords}
            </div>
            {#if winscpReport.errors.length}
              <div class="error">
                {#each winscpReport.errors as message (message)}
                  <div>{message}</div>
                {/each}
              </div>
            {/if}
          {/if}
          {#if winscpError}<div class="error">{winscpError}</div>{/if}
        </section>
      {:else if tab === "sync"}
        <SyncShareCard onImported={async () => await onImported?.()} onNotify={(message) => { toast = message; setTimeout(() => (toast = null), 2400); }} />
      {:else if tab === "ai"}
        {#if ai}
          <section class="card">
            <div class="card-title">ИИ-помощник</div>
            <label class="check">
              <input type="checkbox" bind:checked={ai.enabled} />
              Включить помощника в терминале и сниппетах
            </label>
            <div class="row">
              <div class="label">Провайдер</div>
              <select
                value={ai.provider}
                onchange={(e) => changeProvider((e.target as HTMLSelectElement).value)}
              >
                {#each Object.entries(providers) as [id, preset] (id)}
                  <option value={id}>{preset.label}</option>
                {/each}
              </select>
            </div>
            <div class="row">
              <div class="label">Endpoint</div>
              <input class="path" bind:value={ai.endpoint} />
            </div>
            <div class="row">
              <div class="label">API-ключ<small>Хранится в зашифрованном виде</small></div>
              <input class="path" type="password" bind:value={aiKey} placeholder="ключ" />
            </div>
            <div class="row">
              <div class="label">Модель<small>Список берётся у провайдера</small></div>
              <select bind:value={ai.model}>
                {#if ai.model && !aiModels.some((model) => model.id === ai!.model)}
                  <option value={ai.model}>{ai.model}</option>
                {/if}
                {#each aiModels as model (model.id)}
                  <option value={model.id}>{model.name || model.id}</option>
                {/each}
              </select>
              <button class="btn" disabled={aiBusy} onclick={loadAiModels}>
                {aiBusy ? "Загружаю…" : "Загрузить модели"}
              </button>
            </div>
            <label class="check">
              <input type="checkbox" bind:checked={ai.includeContext} />
              Передавать контекст сервера
            </label>
            <div class="buttons">
              <button class="btn primary" disabled={aiBusy} onclick={saveAi}>
                Сохранить ИИ
              </button>
              {#if aiSaved}<span class="ok">{aiSaved}</span>{/if}
            </div>
            {#if aiError}<div class="error">{aiError}</div>{/if}
          </section>
        {:else}
          <div class="card">Загрузка настроек ИИ…</div>
        {/if}
      {:else if tab === "about"}
        <section class="card">
          <div class="card-title">О программе</div>
          <div class="row"><div class="label">Версия</div><div>{info?.version ?? "—"}</div></div>
          <div class="row"><div class="label">Данные</div><div class="about-path">{info?.dataDir ?? "—"}</div></div>
          <div class="row"><div class="label">Платформа</div><div>{info?.platform ?? "—"}</div></div>
          <div class="buttons">
            <button
              class="btn"
              onclick={async () => {
                await navigator.clipboard.writeText(info?.dataDir ?? "");
                toast = "Путь данных скопирован";
                setTimeout(() => (toast = null), 2000);
              }}
            >
              Скопировать путь данных
            </button>
            <button class="btn" onclick={() => (logsOpen = true)}>
              Журнал событий
            </button>
          </div>
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
      {#if toast}<div class="toast">{toast}</div>{/if}

      <div class="footer">
        <button class="btn" onclick={onClose}>Отмена</button>
        <button class="btn primary" disabled={busy} onclick={commit}>
          {busy ? "Сохраняю…" : "Сохранить"}
        </button>
      </div>
    </div>
  </div>
</div>

{#if snippetsOpen}
  <SnippetsDialog
    onClose={() => (snippetsOpen = false)}
    onInsert={() => (snippetsOpen = false)}
    onRun={() => (snippetsOpen = false)}
  />
{/if}

{#if logsOpen}
  <LogsDialog onClose={() => (logsOpen = false)} />
{/if}

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

  .rules {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-bottom: 8px;
  }

  .rule {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .rule-dot {
    width: 10px;
    height: 10px;
    flex: 0 0 10px;
    border-radius: 50%;
  }

  .rule-name {
    width: 150px;
  }

  .rule-pattern {
    flex: 1;
    min-width: 60px;
    font-family: var(--mono);
  }

  .rule-name,
  .rule-pattern {
    height: 28px;
    padding: 0 8px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--text);
    font-size: 12px;
    outline: none;
  }

  .rule-name:focus,
  .rule-pattern:focus {
    border-color: var(--accent);
  }

  .rule select {
    height: 28px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--text);
    font-size: 11.5px;
  }

  .rule-color {
    width: 30px;
    height: 28px;
    padding: 2px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
  }

  .check.compact {
    margin: 0;
    font-size: 10.5px;
  }

  .checks {
    display: flex;
    flex-wrap: wrap;
    gap: 14px;
    margin-bottom: 8px;
    color: var(--dim);
    font-size: 11.5px;
  }

  .checks input {
    accent-color: var(--accent);
  }

  .about-path {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-family: var(--mono);
    font-size: 11px;
    color: var(--dim);
  }

  .toast {
    position: fixed;
    right: 26px;
    bottom: 24px;
    padding: 8px 12px;
    background: var(--panel);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius-sm);
    color: var(--text);
    font-size: 11.5px;
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.35);
    z-index: 130;
  }

  .ok-text {
    color: var(--success);
  }

  .empty {
    padding: 14px;
    text-align: center;
    color: var(--faint);
    font-size: 11.5px;
  }

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

  .ok {
    align-self: center;
    color: var(--success);
    font-size: 11.5px;
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
