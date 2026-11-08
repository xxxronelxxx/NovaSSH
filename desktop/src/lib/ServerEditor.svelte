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
  let ftpsMode = $state(server?.ftpsMode ?? "explicit");
  let ftpsInsecure = $state(server?.ftpsInsecure ?? false);
  let passive = $state(server?.passive ?? true);
  let s3Endpoint = $state(server?.s3Endpoint ?? "");
  let s3Region = $state(server?.s3Region ?? "");
  let s3Bucket = $state(server?.s3Bucket ?? "");
  let s3Prefix = $state(server?.s3Prefix ?? "");
  let s3PathStyle = $state(server?.s3PathStyle ?? true);
  let s3Access = $state("");
  let s3Secret = $state("");
  let showS3Secret = $state(false);
  let error = $state<string | null>(null);
  let busy = $state(false);

  const s3AccessId = $state(server?.s3AccessRef ?? `s3a_${server?.id ?? id}`);
  const s3SecretId = $state(server?.s3SecretRef ?? `s3s_${server?.id ?? id}`);

  onMount(async () => {
    if (!existing) return;
    try {
      if (server?.auth?.type === "password" && server.passwordRef) {
        password = (await api.getSecret(server.passwordRef)) ?? "";
      }
      if (server?.auth?.type === "key" && server.auth?.passphraseRef) {
        passphrase = (await api.getSecret(server.auth.passphraseRef)) ?? "";
      }
      if (server?.protocol === "s3") {
        s3Access = (await api.getSecret(s3AccessId)) ?? "";
        s3Secret = (await api.getSecret(s3SecretId)) ?? "";
      }
    } catch {
      // A locked vault simply leaves the fields empty.
    }
  });

  async function save() {
    error = null;
    if (protocol !== "s3" && (!host.trim() || !user.trim())) {
      error = "Заполните хост и пользователя";
      return;
    }
    const parsedPort = Number.parseInt(port, 10);
    if (!Number.isFinite(parsedPort) || parsedPort < 1 || parsedPort > 65535) {
      error = "Неверный порт";
      return;
    }
    if (protocol === "s3" && !s3Endpoint.trim()) {
      error = "Укажите endpoint S3";
      return;
    }

    busy = true;
    try {
      const passwordRef = server?.passwordRef ?? `pwd_${id}`;
      const passphraseRef =
        server?.auth?.passphraseRef ??
        (authType === "key" ? `pass_${id}` : null);

      const isS3 = protocol === "s3";
      const hostValue = isS3 ? s3Endpoint.trim() : host.trim();
      const next: Server = {
        ...(server ?? { groupId: null, tags: [] }),
        id,
        groupId: groupId || null,
        name:
          name.trim() ||
          (isS3
            ? s3Bucket.trim() || s3Endpoint.trim()
            : `${user.trim()}@${host.trim()}`),
        host: hostValue,
        port: isS3 ? 443 : parsedPort,
        user: isS3 ? "" : user.trim(),
        protocol,
        tags: tags
          .split(",")
          .map((tag) => tag.trim())
          .filter(Boolean),
        passwordRef: !isS3 && authType === "password" ? passwordRef : null,
        auth: {
          type: authType,
          keyPath:
            !isS3 && authType === "key" ? keyPath.trim() : null,
          passphraseRef:
            !isS3 && authType === "key" ? passphraseRef : null,
        },
        ftpsMode: protocol === "ftps" ? ftpsMode : null,
        ftpsInsecure: protocol === "ftps" ? ftpsInsecure : null,
        passive: protocol === "ftp" || protocol === "ftps" ? passive : null,
        s3Endpoint: isS3 ? s3Endpoint.trim() : (server?.s3Endpoint ?? null),
        s3Region: isS3 ? s3Region.trim() : (server?.s3Region ?? null),
        s3Bucket: isS3 ? s3Bucket.trim() : (server?.s3Bucket ?? null),
        s3Prefix: isS3 ? s3Prefix.trim() : (server?.s3Prefix ?? null),
        s3PathStyle: isS3 ? s3PathStyle : (server?.s3PathStyle ?? null),
        s3AccessRef: isS3 ? s3AccessId : (server?.s3AccessRef ?? null),
        s3SecretRef: isS3 ? s3SecretId : (server?.s3SecretRef ?? null),
      };

      const saved = await api.saveServer(next);
      if (authType === "password" && password.trim()) {
        await api.setSecret(saved.passwordRef ?? passwordRef, password);
      }
      if (authType === "key" && passphrase.trim() && passphraseRef) {
        await api.setSecret(passphraseRef, passphrase);
      }
      if (protocol === "s3") {
        if (s3Access.trim()) await api.setSecret(s3AccessId, s3Access.trim());
        if (s3Secret.trim()) await api.setSecret(s3SecretId, s3Secret.trim());
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
      {#if protocol !== "s3"}
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
      {/if}
      <label class="field">
        <span>Протокол</span>
        <select bind:value={protocol}>
          <option value="sftp">SFTP (SSH)</option>
          <option value="ftp">FTP</option>
          <option value="ftps">FTPS</option>
          <option value="s3">S3 / MinIO</option>
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

      {#if protocol === "s3"}
        <label class="field wide">
          <span>Endpoint</span>
          <input
            bind:value={s3Endpoint}
            placeholder="https://s3.amazonaws.com или http://192.168.1.9:9000"
          />
        </label>
        <label class="field">
          <span>Регион</span>
          <input bind:value={s3Region} placeholder="us-east-1" />
        </label>
        <label class="field">
          <span>Bucket</span>
          <input bind:value={s3Bucket} placeholder="my-bucket" />
        </label>
        <label class="field wide">
          <span>Префикс<small>Необязательно: папка внутри bucket</small></span>
          <input bind:value={s3Prefix} placeholder="backups/site" />
        </label>
        <label class="field wide">
          <span>Access key</span>
          <input bind:value={s3Access} placeholder="AKIA..." />
        </label>
        <label class="field wide">
          <span>Secret key</span>
          <div class="secret">
            <input
              type={showS3Secret ? "text" : "password"}
              bind:value={s3Secret}
              placeholder={existing ? "оставьте пустым, чтобы не менять" : "secret"}
            />
            <button
              class="eye"
              type="button"
              title={showS3Secret ? "Скрыть" : "Показать"}
              onclick={() => (showS3Secret = !showS3Secret)}
            >
              {#if showS3Secret}<EyeOff size={14} />{:else}<Eye size={14} />{/if}
            </button>
          </div>
        </label>
        <label class="check wide">
          <input type="checkbox" bind:checked={s3PathStyle} />
          Path-style addressing (MinIO и self-hosted)
        </label>
      {:else if protocol === "ftps"}
        <label class="field">
          <span>Режим TLS</span>
          <select bind:value={ftpsMode}>
            <option value="explicit">Explicit (AUTH TLS, 21)</option>
            <option value="implicit">Implicit (990)</option>
          </select>
        </label>
        <label class="check wide">
          <input type="checkbox" bind:checked={ftpsInsecure} />
          Принимать самоподписанный сертификат
        </label>
      {/if}

      {#if protocol === "ftp" || protocol === "ftps"}
        <label class="check wide">
          <input type="checkbox" bind:checked={passive} />
          Пассивный режим
        </label>
      {/if}

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

      {#if protocol !== "s3" && (authType === "password" || protocol !== "sftp")}
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
      {:else if protocol !== "s3"}
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

  .field.wide,
  .check.wide {
    grid-column: span 2;
  }

  .check {
    display: flex;
    align-items: center;
    gap: 7px;
    color: var(--dim);
    font-size: 11.5px;
  }

  .check input {
    accent-color: var(--accent);
  }

  .field span small {
    margin-left: 6px;
    color: var(--faint);
    font-size: 10px;
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
