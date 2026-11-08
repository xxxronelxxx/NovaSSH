<script lang="ts">
  import { onMount } from "svelte";
  import { Eye, EyeOff, X } from "lucide-svelte";
  import { api, type Group, type Server } from "../lib/api";

  let {
    server,
    groups,
    onClose,
    onSaved,
    onDeleted,
  }: {
    server: Server | null;
    groups: Group[];
    onClose: () => void;
    onSaved: (server: Server) => void | Promise<void>;
    onDeleted: (id: string) => void | Promise<void>;
  } = $props();

  const existing = server != null;
  const id = $state(server?.id ?? `s_${Date.now()}`);
  let name = $state(server?.name ?? "");
  let host = $state(server?.host ?? "");
  let port = $state(String(server?.port ?? 22));
  let user = $state(server?.user ?? "");
  let protocol = $state(server?.protocol ?? "sftp");
  let authType = $state(server?.auth?.type === "key" ? "key" : "password");
  let password = $state("");
  let showPassword = $state(false);
  let keyPath = $state(server?.auth?.keyPath ?? "");
  let passphrase = $state("");
  let showPassphrase = $state(false);
  let groupId = $state(server?.groupId ?? "");
  let tags = $state((server?.tags ?? []).join(", "));
  let error = $state<string | null>(null);
  let busy = $state(false);

  onMount(async () => {
    if (!existing) return;
    try {
      if (server?.auth?.type === "password" && server.passwordRef) {
        password = (await api.getSecret(server.passwordRef)) ?? "";
      }
      if (server?.auth?.type === "key" && server.auth?.passphraseRef) {
        passphrase = (await api.getSecret(server.auth.passphraseRef)) ?? "";
      }
    } catch {
      // A locked vault simply leaves the fields empty.
    }
  });

  async function save() {
    error = null;
    if (!host.trim() || !user.trim()) {
      error = "Заполните хост и пользователя";
      return;
    }
    const parsedPort = Number.parseInt(port, 10);
    if (!Number.isFinite(parsedPort) || parsedPort < 1 || parsedPort > 65535) {
      error = "Неверный порт";
      return;
    }

    busy = true;
    try {
      const passwordRef = server?.passwordRef ?? `pwd_${id}`;
      const passphraseRef =
        server?.auth?.passphraseRef ??
        (authType === "key" ? `pass_${id}` : null);

      const next: Server = {
        ...(server ?? { groupId: null, tags: [] }),
        id,
        groupId: groupId || null,
        name: name.trim() || `${user.trim()}@${host.trim()}`,
        host: host.trim(),
        port: parsedPort,
        user: user.trim(),
        protocol,
        tags: tags
          .split(",")
          .map((tag) => tag.trim())
          .filter(Boolean),
        passwordRef: authType === "password" ? passwordRef : null,
        auth: {
          type: authType,
          keyPath: authType === "key" ? keyPath.trim() : null,
          passphraseRef: authType === "key" ? passphraseRef : null,
        },
      };

      const saved = await api.saveServer(next);
      if (authType === "password" && password.trim()) {
        await api.setSecret(saved.passwordRef ?? passwordRef, password);
      }
      if (authType === "key" && passphrase.trim() && passphraseRef) {
        await api.setSecret(passphraseRef, passphrase);
      }
      await onSaved(saved);
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  async function remove() {
    if (!server) return;
    busy = true;
    try {
      await api.deleteServer(server.id);
      await onDeleted(server.id);
    } catch (e) {
      error = String(e);
      busy = false;
    }
  }
</script>

<div class="overlay" onclick={onClose}>
  <div class="editor" onclick={(e) => e.stopPropagation()}>
    <div class="head">
      <span>{existing ? "Сервер" : "Новый сервер"}</span>
      <button class="icon" title="Закрыть" onclick={onClose}>
        <X size={15} />
      </button>
    </div>

    <div class="grid">
      <label class="field wide">
        <span>Название</span>
        <input bind:value={name} placeholder="Мой сервер" />
      </label>
      <label class="field">
        <span>Хост</span>
        <input bind:value={host} placeholder="example.com или 10.0.0.1" />
      </label>
      <label class="field small">
        <span>Порт</span>
        <input bind:value={port} inputmode="numeric" />
      </label>
      <label class="field">
        <span>Пользователь</span>
        <input bind:value={user} placeholder="root" />
      </label>
      <label class="field">
        <span>Протокол</span>
        <select bind:value={protocol}>
          <option value="sftp">SFTP (SSH)</option>
          <option value="ftp">FTP</option>
          <option value="ftps">FTPS</option>
        </select>
      </label>
      <label class="field">
        <span>Группа</span>
        <select bind:value={groupId}>
          <option value="">Без группы</option>
          {#each groups as group (group.id)}
            <option value={group.id}>{group.name}</option>
          {/each}
        </select>
      </label>

      {#if protocol === "sftp"}
        <label class="field">
          <span>Авторизация</span>
          <select bind:value={authType}>
            <option value="password">Пароль</option>
            <option value="key">Ключ</option>
          </select>
        </label>
      {/if}

      <label class="field wide">
        <span>{existing ? "Теги" : "Теги (через запятую)"}</span>
        <input bind:value={tags} placeholder="nginx, php" />
      </label>

      {#if authType === "password" || protocol !== "sftp"}
        <label class="field wide">
          <span>Пароль</span>
          <div class="secret">
            <input
              type={showPassword ? "text" : "password"}
              bind:value={password}
              placeholder={existing ? "оставьте пустым, чтобы не менять" : "пароль"}
            />
            <button
              class="eye"
              type="button"
              title={showPassword ? "Скрыть" : "Показать"}
              onclick={() => (showPassword = !showPassword)}
            >
              {#if showPassword}<EyeOff size={14} />{:else}<Eye size={14} />{/if}
            </button>
          </div>
        </label>
      {:else}
        <label class="field wide">
          <span>Файл ключа</span>
          <input bind:value={keyPath} placeholder="C:\Users\you\.ssh\id_ed25519" />
        </label>
        <label class="field wide">
          <span>Парольная фраза ключа</span>
          <div class="secret">
            <input
              type={showPassphrase ? "text" : "password"}
              bind:value={passphrase}
              placeholder={existing ? "оставьте пустым, чтобы не менять" : "если ключ зашифрован"}
            />
            <button
              class="eye"
              type="button"
              title={showPassphrase ? "Скрыть" : "Показать"}
              onclick={() => (showPassphrase = !showPassphrase)}
            >
              {#if showPassphrase}<EyeOff size={14} />{:else}<Eye size={14} />{/if}
            </button>
          </div>
        </label>
      {/if}
    </div>

    {#if error}
      <div class="error">{error}</div>
    {/if}

    <div class="foot">
      {#if existing}
        <button class="btn danger" disabled={busy} onclick={remove}>
          Удалить
        </button>
      {/if}
      <span class="grow"></span>
      <button class="btn" onclick={onClose}>Отмена</button>
      <button class="btn primary" disabled={busy} onclick={save}>
        {busy ? "Сохраняю…" : "Сохранить"}
      </button>
    </div>
  </div>
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    display: grid;
    place-items: center;
    background: rgba(0, 0, 0, 0.4);
    z-index: 80;
  }

  .editor {
    width: 640px;
    max-width: 92vw;
    padding: 16px 18px 12px;
    background: var(--menu);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius);
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.5);
  }

  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 14px;
    font-size: 13px;
    font-weight: 600;
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

  .grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 10px 12px;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }

  .field.wide {
    grid-column: span 2;
  }

  .field.small {
    max-width: 120px;
  }

  .field span {
    font-size: 11px;
    color: var(--faint);
  }

  .field input,
  .field select {
    height: 32px;
    padding: 0 9px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--text);
    font-size: 12.5px;
    outline: none;
  }

  .field input:focus,
  .field select:focus {
    border-color: var(--accent);
  }

  .secret {
    position: relative;
  }

  .secret input {
    width: 100%;
    padding-right: 34px;
  }

  .eye {
    position: absolute;
    top: 4px;
    right: 4px;
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    border-radius: 4px;
    color: var(--faint);
  }

  .eye:hover {
    background: var(--hover);
    color: var(--text);
  }

  .error {
    margin-top: 10px;
    color: var(--error);
    font-size: 11.5px;
  }

  .foot {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-top: 16px;
    padding-top: 12px;
    border-top: 1px solid var(--border);
  }

  .grow {
    flex: 1;
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

  .btn.danger {
    color: var(--error);
    border-color: rgba(248, 81, 73, 0.4);
  }
</style>
