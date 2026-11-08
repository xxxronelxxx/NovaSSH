<script lang="ts">
  import { onDestroy } from "svelte";
  import QRCode from "qrcode";
  import { api, type SyncShare } from "../lib/api";

  let {
    onImported,
    onNotify,
  }: {
    onImported: () => Promise<void> | void;
    onNotify: (message: string, warn?: boolean) => void;
  } = $props();

  let includeSecrets = $state(false);
  let share = $state<SyncShare | null>(null);
  let qr = $state<string | null>(null);
  let busy = $state(false);
  let url = $state("");
  let error = $state<string | null>(null);

  async function showQr() {
    busy = true;
    error = null;
    try {
      const started = await api.startSyncShare(includeSecrets);
      share = started;
      qr = await QRCode.toDataURL(started.url, {
        width: 260,
        margin: 1,
        color: { dark: "#000000", light: "#FFFFFF" },
      });
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  async function closeQr() {
    share = null;
    qr = null;
    await api.stopSyncShare().catch(() => {});
  }

  async function copyLink() {
    if (!share) return;
    await navigator.clipboard.writeText(share.url).catch(() => {});
    onNotify("Ссылка скопирована");
  }

  async function importUrl() {
    if (!url.trim()) return;
    busy = true;
    error = null;
    try {
      const report = await api.importSyncUrl(url.trim());
      await onImported();
      onNotify(
        `Импортировано: серверов ${report.servers}, групп ${report.groups}, паролей ${report.secrets}`,
      );
      url = "";
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }

  onDestroy(() => {
    if (share) void api.stopSyncShare().catch(() => {});
  });
</script>

<section class="card">
  <div class="card-title">Синхронизация с телефоном</div>
  <p class="note">
    Без аккаунтов: компьютер показывает QR-код, телефон скачивает профиль по
    локальной сети. Ссылка одноразовая и живёт 5 минут.
  </p>
  <label class="check">
    <input type="checkbox" bind:checked={includeSecrets} />
    Передавать сохранённые пароли и ключи S3 (по локальной сети открытым текстом)
  </label>
  <div class="buttons">
    <button class="btn primary" disabled={busy} onclick={showQr}>
      {busy ? "Готовлю…" : "Показать QR для телефона"}
    </button>
  </div>

  {#if share}
    <div class="qr-wrap">
      <div class="qr">
        {#if qr}<img src={qr} alt="QR-код синхронизации" />{/if}
      </div>
      <div class="qr-info">
        <code>{share.url}</code>
        <p>
          Откройте на телефоне «Настройки → Синхронизация» и отсканируйте код.
          Пароли: {includeSecrets ? "передаются" : "не передаются"}.
        </p>
        <p class="warn">
          Если телефон не подключается — разрешите NovaSSH в брандмауэре Windows
          для частных сетей.
        </p>
        <div class="buttons">
          <button class="btn" onclick={copyLink}>Копировать ссылку</button>
          <button class="btn" onclick={closeQr}>Остановить</button>
        </div>
      </div>
    </div>
  {/if}

  <div class="divider"></div>
  <p class="note">Или вставьте ссылку, которую показывает другой компьютер:</p>
  <div class="row">
    <input class="path" bind:value={url} placeholder="http://192.168.0.10:41234/sync?token=…" />
    <button class="btn" disabled={busy || !url.trim()} onclick={importUrl}>
      Импортировать по ссылке
    </button>
  </div>
  {#if error}<div class="error">{error}</div>{/if}
</section>

<style>
  .buttons {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 8px;
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

  .btn.primary:hover {
    background: var(--accent-hover);
  }

  .btn:disabled {
    opacity: 0.5;
  }

  .row {
    display: flex;
    gap: 8px;
    align-items: center;
  }

  .row .path {
    flex: 1;
    height: 32px;
    padding: 0 9px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--panel);
    color: var(--text);
    font-size: 12px;
    outline: none;
  }

  .row .path:focus {
    border-color: var(--accent);
  }

  .error {
    margin-top: 8px;
    color: var(--error);
    font-size: 11.5px;
    white-space: pre-wrap;
  }

  .check {
    display: flex;
    align-items: center;
    gap: 7px;
    margin-bottom: 10px;
    color: var(--dim);
    font-size: 11.5px;
  }

  .check input {
    accent-color: var(--accent);
  }

  .qr-wrap {
    display: flex;
    gap: 16px;
    align-items: flex-start;
    margin-top: 12px;
  }

  .qr {
    flex: 0 0 auto;
    padding: 10px;
    background: #fff;
    border-radius: 8px;
    line-height: 0;
  }

  .qr img {
    width: 200px;
    height: 200px;
  }

  .qr-info {
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .qr-info code {
    color: var(--dim);
    font-family: var(--mono);
    font-size: 10.5px;
    word-break: break-all;
    user-select: text;
  }

  .qr-info p {
    margin: 0;
    color: var(--faint);
    font-size: 11.5px;
    line-height: 1.4;
  }

  .qr-info p.warn {
    color: var(--warn);
    font-size: 11px;
  }

  .divider {
    height: 1px;
    margin: 14px 0 10px;
    background: var(--border);
  }
</style>
