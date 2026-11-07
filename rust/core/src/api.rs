#![allow(clippy::needless_return)]

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use flutter_rust_bridge::frb;

use crate::frb_generated::StreamSink;

use tokio::runtime::Runtime;

use crate::crypto::{self, KdfParams, SecretFile, Unlocked};
use crate::fs::local::LocalFs;
use crate::fs::sftp::SftpFs;
use crate::fs::Provider;
use crate::model::*;
use crate::ssh::{self, ConnectAuth, ConnectOptions, SshSession};
use crate::store::{self, Paths};
use crate::task::{self, CopyStats};
use crate::util;

// ---------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------

fn rt() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .thread_name("nova-net")
            .build()
            .expect("tokio runtime")
    })
}

fn now() -> i64 {
    util::now_ms()
}

/// Limits how many transfers run at once (the "параллельные передачи" setting).
///
/// Every `transfer()` used to start immediately: selecting 200 files opened 200
/// concurrent streams, which saturates the connection and, for FTP/S3, memory.
fn transfer_slots(limit: u32) -> Arc<tokio::sync::Semaphore> {
    static SLOTS: OnceLock<Mutex<(u32, Arc<tokio::sync::Semaphore>)>> = OnceLock::new();
    let limit = limit.clamp(1, 8);
    let slot = SLOTS.get_or_init(|| Mutex::new((3, Arc::new(tokio::sync::Semaphore::new(3)))));
    let mut guard = slot.lock().unwrap_or_else(|poison| poison.into_inner());
    if guard.0 != limit {
        *guard = (limit, Arc::new(tokio::sync::Semaphore::new(limit as usize)));
    }
    guard.1.clone()
}

// ---------------------------------------------------------------------------
// Application state
// ---------------------------------------------------------------------------

struct App {
    paths: Paths,
    book: Mutex<ServerBook>,
    settings: Mutex<Settings>,
    state: Mutex<SessionState>,
    rules: Mutex<ColorRules>,
    vault: Mutex<Option<Unlocked>>,
    sessions: Mutex<HashMap<String, Arc<SshSession>>>,
}

/// FTP sessions live outside the SSH map: different transport, same API.
static FTP_SESSIONS: OnceLock<Mutex<HashMap<String, Arc<crate::fs::ftp::FtpFs>>>> =
    OnceLock::new();

fn ftp_sessions() -> &'static Mutex<HashMap<String, Arc<crate::fs::ftp::FtpFs>>> {
    FTP_SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Cancellation flags for transfers that are still running, keyed by event id.
static TRANSFER_CANCELS: OnceLock<Mutex<HashMap<String, Arc<std::sync::atomic::AtomicBool>>>> =
    OnceLock::new();

fn transfer_cancels() -> &'static Mutex<HashMap<String, Arc<std::sync::atomic::AtomicBool>>> {
    TRANSFER_CANCELS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Removes the flag when the transfer ends, however it ends.
struct CancelGuard(String);

impl Drop for CancelGuard {
    fn drop(&mut self) {
        if let Ok(mut map) = transfer_cancels().lock() {
            map.remove(&self.0);
        }
    }
}

/// Asks a running transfer to stop; returns false when it already finished.
pub fn cancel_transfer(id: String) -> bool {
    let flag = transfer_cancels()
        .lock()
        .ok()
        .and_then(|map| map.get(&id).cloned());
    match flag {
        Some(flag) => {
            flag.store(true, std::sync::atomic::Ordering::Relaxed);
            true
        }
        None => false,
    }
}

static S3_SESSIONS: OnceLock<Mutex<HashMap<String, Arc<crate::fs::s3::S3Fs>>>> = OnceLock::new();

fn s3_sessions() -> &'static Mutex<HashMap<String, Arc<crate::fs::s3::S3Fs>>> {
    S3_SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

static APP: OnceLock<App> = OnceLock::new();

fn app() -> Result<&'static App, String> {
    APP.get()
        .ok_or_else(|| "core is not initialised (call initApp)".to_string())
}

fn map_book(book: &ServerBook) -> ServerBook {
    book.clone()
}

#[derive(Debug, Clone)]
pub struct AppInfo {
    pub data_dir: String,
    pub key_wrap: String,
    pub vault: String,
    /// True when `keywrap.bin` exists (the vault opens without a password).
    pub has_device_key: bool,
    pub version: String,
    pub platform: String,
}

/// Append a line to `logs/nova.log` (used by the UI error handlers).
pub fn append_log(line: String) {
    let Some(a) = APP.get() else { return };
    let dir = a.paths.logs_dir();
    let _ = std::fs::create_dir_all(&dir);
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("nova.log"))
    {
        let _ = writeln!(f, "[{}] {line}", util::now_ms());
    }
}

pub fn log_dir() -> Option<String> {
    APP.get().map(|a| a.paths.logs_dir().to_string_lossy().to_string())
}

pub fn load_log_settings() -> Result<LogSettings, String> {
    let a = app()?;
    store::load_json::<LogSettings>(&a.paths.logging()).map_err(String::from)
}

pub fn save_log_settings(settings: LogSettings) -> Result<(), String> {
    let a = app()?;
    store::save_json(&a.paths.logging(), &settings).map_err(String::from)
}

/// Appends one edit event to `logs/edits-YYYY-MM-DD.log` when the setting is
/// on. The date and time come from the UI so the file follows local time, not
/// UTC used by the diagnostic `nova.log`.
pub fn append_edit_log(
    server: String,
    server_name: String,
    path: String,
    action: String,
    date: String,
    time: String,
) -> Result<(), String> {
    let a = app()?;
    let settings: LogSettings = store::load_json(&a.paths.logging()).map_err(String::from)?;
    if !settings.edit_log {
        return Ok(());
    }
    // Never let a caller-supplied date escape the logs folder.
    let date = if date.len() == 10
        && date
            .chars()
            .all(|c| c.is_ascii_digit() || c == '-' || c == '_')
    {
        date
    } else {
        utc_date_iso()
    };
    let dir = a.paths.logs_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let clean = |text: &str| text.replace(['\r', '\n'], " ");
    let line = format!(
        "{} {} | {} | {} | {}",
        date,
        clean(&time),
        clean(&server),
        clean(&path),
        clean(&action)
    );
    // The file is named after the server, so every host gets its own daily
    // file: IKEY_NEW!_31-10-2026.log (characters Windows forbids are replaced).
    let stem = util::safe_file_stem(&server_name);
    use std::io::Write as _;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join(format!("{stem}_{date}.log")))
        .map_err(|e| e.to_string())?;
    writeln!(file, "{line}").map_err(|e| e.to_string())
}

fn utc_date_iso() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (year, month, day) = civil_from_days((secs / 86_400) as i64);
    format!("{year:04}-{month:02}-{day:02}")
}

/// Must be called once before anything else.
#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Optional explicit data directory (Android passes its app-private dir).
pub fn init_data_dir(data_dir: Option<String>) -> Result<AppInfo, String> {
    if APP.get().is_some() {
        return info();
    }
    let explicit = data_dir
        .as_deref()
        .map(|d| !d.trim().is_empty())
        .unwrap_or(false);
    let paths = match data_dir {
        Some(dir) if !dir.trim().is_empty() => Paths::new(dir),
        _ => Paths::default_desktop(),
    };
    paths.ensure().map_err(String::from)?;
    // Temporary copies of edited files never outlive a run; a crash can leave
    // them behind, so the folder starts empty.
    let _ = std::fs::remove_dir_all(paths.tmp_dir());
    let _ = std::fs::create_dir_all(paths.tmp_dir());
    // The older build kept edit copies in cache/edit; do not leave those behind.
    let _ = std::fs::remove_dir_all(paths.edit_cache());
    let _ = std::fs::create_dir_all(paths.edit_cache());
    // Archive indexes survive runs: opening a large archive then becomes a
    // header read instead of a full scan.
    crate::archive::set_cache_dir(Some(paths.index_cache()));
    // Portable mode: pull the old %APPDATA% profile in on first launch.
    if !explicit {
        store::migrate_legacy_if_needed(&paths);
    }

    let mut book: ServerBook = store::load_json(&paths.servers()).map_err(String::from)?;
    book.validate().map_err(String::from)?;
    // Write back so the inferred protocols are visible in the file as well.
    let _ = store::save_json(&paths.servers(), &book);
    let settings: Settings = store::load_json(&paths.settings()).map_err(String::from)?;
    let state: SessionState = store::load_json(&paths.state()).map_err(String::from)?;
    let rules: ColorRules = store::load_json(&paths.rules()).map_err(String::from)?;

    // Panics must never take the whole app down silently: with unwinding the
    // bridge turns them into Dart errors, and this hook records them to disk.
    {
        let hook_paths = paths.clone();
        std::panic::set_hook(Box::new(move |info| {
            let line = format!("[{}] PANIC: {info}", util::now_ms());
            eprintln!("{line}");
            let dir = hook_paths.logs_dir();
            let _ = std::fs::create_dir_all(&dir);
            use std::io::Write;
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join("panic.log"))
            {
                let _ = writeln!(f, "{line}");
            }
        }));
    }

    APP.set(App {
        paths,
        book: Mutex::new(book),
        settings: Mutex::new(settings),
        state: Mutex::new(state),
        rules: Mutex::new(rules),
        vault: Mutex::new(None),
        sessions: Mutex::new(HashMap::new()),
    })
    .map_err(|_| "already initialised".to_string())?;

    info()
}

pub fn info() -> Result<AppInfo, String> {
    let a = app()?;
    let secrets_exist = a.paths.secrets().exists();
    let unlocked = a.vault.lock().map_err(|_| "lock poisoned")?.is_some();
    Ok(AppInfo {
        data_dir: a.paths.root.to_string_lossy().to_string(),
        key_wrap: format!("{:?}", crypto::support()),
        vault: if unlocked {
            "unlocked".to_string()
        } else if secrets_exist {
            "locked".to_string()
        } else {
            "missing".to_string()
        },
        has_device_key: a.paths.keywrap().exists(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        platform: std::env::consts::OS.to_string(),
    })
}

/// True when the OS can wrap the vault key itself (DPAPI on Windows).
fn device_key_supported() -> bool {
    matches!(crypto::support(), crypto::KeyWrapSupport::Available)
}

/// Creates the vault for a passwordless platform (Windows).
///
/// The key is random and wrapped by the OS, so nothing is ever typed.
pub fn create_vault_with_device_key() -> Result<(), String> {
    let a = app()?;
    if !device_key_supported() {
        return Err("на этой платформе хранилище защищено паролем или PIN".into());
    }
    if a.paths.secrets().exists() {
        return Err("хранилище уже существует".into());
    }
    let key = crypto::random_key();
    let mut vault = crypto::SecretFile::create_with_key(&a.paths.secrets(), &key)
        .map_err(String::from)?;
    // The wrapped key is written first: a crash in between leaves an empty
    // vault with no data, never a vault whose key is lost.
    vault.remember(&a.paths.keywrap()).map_err(String::from)?;
    vault.save().map_err(String::from)?;
    *a.vault.lock().map_err(|_| "lock poisoned")? = Some(vault);
    Ok(())
}

/// Moves a password-protected vault to the device key (one-time migration).
///
/// After this the password is not needed any more; the secrets are re-encrypted
/// with a fresh random key that only this Windows account can unwrap.
pub fn rekey_vault_to_device_key(password: String) -> Result<(), String> {
    let a = app()?;
    if !device_key_supported() {
        return Err("на этой платформе хранилище защищено паролем или PIN".into());
    }
    let mut vault = crypto::SecretFile::unlock(&a.paths.secrets(), &password)
        .map_err(|_| "Неверный пароль".to_string())?;
    let key = crypto::random_key();
    vault.rekey_to_device_key(&key).map_err(String::from)?;
    // Same order as above: the new wrapped key first, the re-encrypted file
    // second. A crash in between leaves a file the old password can still open.
    vault.remember(&a.paths.keywrap()).map_err(String::from)?;
    vault.save().map_err(String::from)?;
    *a.vault.lock().map_err(|_| "lock poisoned")? = Some(vault);
    Ok(())
}

/// Converts an unlocked password vault to the device key, silently.
///
/// Called at startup when the key was already wrapped (the common case after
/// the upgrade): the password stops being required without asking for it.
pub fn upgrade_vault_to_device_key() -> Result<bool, String> {
    let a = app()?;
    if !device_key_supported() || !a.paths.keywrap().exists() {
        return Ok(false);
    }
    let mut guard = a.vault.lock().map_err(|_| "lock poisoned")?;
    let Some(vault) = guard.as_mut() else {
        return Ok(false);
    };
    if vault.is_device_key() {
        return Ok(false);
    }
    let key = crypto::random_key();
    vault.rekey_to_device_key(&key).map_err(String::from)?;
    vault.remember(&a.paths.keywrap()).map_err(String::from)?;
    vault.save().map_err(String::from)?;
    Ok(true)
}

// ---------------------------------------------------------------------------
// Vault
// ---------------------------------------------------------------------------

pub fn vault_state() -> Result<String, String> {
    info().map(|i| i.vault)
}

pub fn create_vault(password: String) -> Result<(), String> {
    let a = app()?;
    if a.paths.secrets().exists() {
        return Err("secrets file already exists".into());
    }
    let params = if cfg!(target_os = "android") {
        KdfParams::mobile()
    } else {
        KdfParams::default()
    };
    let vault = SecretFile::create(&a.paths.secrets(), &password, params).map_err(String::from)?;
    *a.vault.lock().map_err(|_| "lock poisoned")? = Some(vault);
    Ok(())
}

pub fn unlock_vault(password: String) -> Result<(), String> {
    let a = app()?;
    let vault = SecretFile::unlock(&a.paths.secrets(), &password).map_err(String::from)?;
    *a.vault.lock().map_err(|_| "lock poisoned")? = Some(vault);
    Ok(())
}

/// Try the OS-wrapped key (DPAPI). Returns false when no wrapped key exists.
pub fn unlock_vault_with_device() -> Result<bool, String> {
    let a = app()?;
    if !a.paths.keywrap().exists() {
        return Ok(false);
    }
    match crypto::unlock_with_remembered(&a.paths.secrets(), &a.paths.keywrap()) {
        Ok(Some(vault)) => {
            *a.vault.lock().map_err(|_| "lock poisoned")? = Some(vault);
            Ok(true)
        }
        Ok(None) => Ok(false),
        Err(e) => Err(e.to_string()),
    }
}

pub fn remember_master_key() -> Result<(), String> {
    let a = app()?;
    let vault = a.vault.lock().map_err(|_| "lock poisoned")?;
    let vault = vault.as_ref().ok_or("vault is locked")?;
    vault.remember(&a.paths.keywrap()).map_err(String::from)
}

pub fn forget_master_key() -> Result<(), String> {
    let a = app()?;
    Unlocked::forget(&a.paths.keywrap()).map_err(String::from)
}

/// Re-encrypts the vault with a new password/PIN. Used by the Android PIN
/// setup (and to migrate a password-protected vault to a PIN).
pub fn change_vault_password(old_password: String, new_password: String) -> Result<(), String> {
    let a = app()?;
    let trimmed = new_password.trim();
    if trimmed.len() < 4 {
        return Err("Новый пароль/PIN слишком короткий".into());
    }
    let mut vault = crate::crypto::SecretFile::unlock(&a.paths.secrets(), &old_password)
        .map_err(|_| "Текущий пароль неверен".to_string())?;
    vault.rekey(new_password.as_str()).map_err(String::from)?;
    *a.vault.lock().map_err(|_| "lock poisoned")? = Some(vault);
    Ok(())
}

/// Re-encrypts the unlocked vault with a new PIN/password (no old one needed:
/// the caller already proved access by unlocking).
pub fn set_vault_password(new_password: String) -> Result<(), String> {
    let a = app()?;
    let trimmed = new_password.trim();
    if trimmed.len() < 4 {
        return Err("Новый PIN слишком короткий".into());
    }
    let mut guard = a.vault.lock().map_err(|_| "lock poisoned")?;
    let vault = guard.as_mut().ok_or("Хранилище заблокировано")?;
    vault.rekey(new_password.as_str()).map_err(String::from)
}

pub fn lock_vault() -> Result<(), String> {
    let a = app()?;
    if let Some(mut v) = a.vault.lock().map_err(|_| "lock poisoned")?.take() {
        v.save_if_dirty().map_err(String::from)?;
    }
    Ok(())
}

fn secret(a: &App, id: &str) -> Result<Option<String>, String> {
    let vault = a.vault.lock().map_err(|_| "lock poisoned")?;
    match vault.as_ref() {
        None => Ok(None),
        Some(v) => v.get(id).map_err(String::from),
    }
}

pub fn set_secret(id: String, value: String) -> Result<(), String> {
    let a = app()?;
    let mut vault = a.vault.lock().map_err(|_| "lock poisoned")?;
    let vault = vault.as_mut().ok_or("vault is locked")?;
    vault.set(&id, &value).map_err(String::from)?;
    vault.save().map_err(String::from)
}

pub fn get_secret(id: String, master_password: Option<String>) -> Result<Option<String>, String> {
    let a = app()?;
    if let Some(p) = master_password {
        let vault = SecretFile::unlock(&a.paths.secrets(), &p).map_err(String::from)?;
        return vault.get(&id).map_err(String::from);
    }
    secret(a, &id)
}

pub fn delete_secret(id: String) -> Result<(), String> {
    let a = app()?;
    let mut vault = a.vault.lock().map_err(|_| "lock poisoned")?;
    let vault = vault.as_mut().ok_or("vault is locked")?;
    vault.remove(&id);
    vault.save().map_err(String::from)
}

// ---------------------------------------------------------------------------
// Servers and groups
// ---------------------------------------------------------------------------

pub fn load_book() -> Result<ServerBook, String> {
    let a = app()?;
    let mut book = a.book.lock().map_err(|_| "lock poisoned")?;
    book.validate().map_err(String::from)?;
    Ok(map_book(&book))
}

fn persist_book(a: &App, book: &ServerBook) -> Result<(), String> {
    store::save_json(&a.paths.servers(), book).map_err(String::from)
}

pub fn save_server(server: Server) -> Result<Server, String> {
    let a = app()?;
    let mut book = a.book.lock().map_err(|_| "lock poisoned")?;
    let mut server = server;
    if server.id.trim().is_empty() {
        server.id = util::new_id("s");
    }
    if server.name.trim().is_empty() {
        server.name = format!("{}@{}", server.user, server.host);
    }
    if server.port == 0 {
        server.port = 22;
    }
    book.upsert_server(server.clone());
    book.validate().map_err(String::from)?;
    persist_book(a, &book)?;
    Ok(server)
}

pub fn delete_server(id: String) -> Result<(), String> {
    let a = app()?;
    let mut book = a.book.lock().map_err(|_| "lock poisoned")?;
    book.remove_server(&id);
    persist_book(a, &book)
}

pub fn save_group(group: Group) -> Result<Group, String> {
    let a = app()?;
    let mut book = a.book.lock().map_err(|_| "lock poisoned")?;
    let mut group = group;
    // Guard against duplicates created by repeated drops / stale ids.
    if let Some(existing) = book
        .groups
        .iter()
        .find(|g| g.name.eq_ignore_ascii_case(group.name.trim()))
    {
        if existing.id != group.id {
            group.id = existing.id.clone();
            group.order = existing.order;
        }
    }
    if group.id.trim().is_empty() {
        group.id = util::new_id("g");
    }
    book.upsert_group(group.clone());
    book.validate().map_err(String::from)?;
    persist_book(a, &book)?;
    Ok(group)
}

pub fn delete_group(id: String) -> Result<(), String> {
    let a = app()?;
    let mut book = a.book.lock().map_err(|_| "lock poisoned")?;
    book.remove_group(&id);
    persist_book(a, &book)
}

// ---------------------------------------------------------------------------
// Settings / rules / session state
// ---------------------------------------------------------------------------

pub fn load_settings() -> Result<Settings, String> {
    let a = app()?;
    Ok(a.settings.lock().map_err(|_| "lock poisoned")?.clone())
}

pub fn save_settings(settings: Settings) -> Result<(), String> {
    let a = app()?;
    store::save_json(&a.paths.settings(), &settings).map_err(String::from)?;
    *a.settings.lock().map_err(|_| "lock poisoned")? = settings;
    Ok(())
}

// ---------------------------------------------------------------------------
// Command snippets
// ---------------------------------------------------------------------------

/// Reads `snippets.json`. Older profiles carried a bare `[]` from another app,
/// so an array is understood as the snippet list too.
fn load_snippet_book(a: &App) -> Result<SnippetBook, String> {
    let raw = match std::fs::read(a.paths.snippets()) {
        Ok(raw) => raw,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(SnippetBook::default())
        }
        Err(e) => return Err(e.to_string()),
    };
    if raw.iter().all(|b| b.is_ascii_whitespace()) {
        return Ok(SnippetBook::default());
    }
    if let Ok(list) = serde_json::from_slice::<Vec<Snippet>>(&raw) {
        return Ok(SnippetBook {
            version: 1,
            snippets: list,
        });
    }
    serde_json::from_slice::<SnippetBook>(&raw).map_err(|e| format!("snippets.json: {e}"))
}

fn store_snippet_book(a: &App, book: &SnippetBook) -> Result<(), String> {
    store::save_json(&a.paths.snippets(), book).map_err(String::from)
}

/// All snippets, in the order the user arranged them.
pub fn load_snippets() -> Result<Vec<Snippet>, String> {
    let a = app()?;
    let mut list = load_snippet_book(a)?.snippets;
    list.sort_by(|x, y| {
        x.order
            .cmp(&y.order)
            .then(x.created_at.cmp(&y.created_at))
            .then(x.name.to_lowercase().cmp(&y.name.to_lowercase()))
    });
    Ok(list)
}

/// Creates a snippet (empty `id`) or updates an existing one.
pub fn save_snippet(mut snippet: Snippet) -> Result<Snippet, String> {
    let a = app()?;
    snippet.name = snippet.name.trim().to_string();
    snippet.command = snippet.command.trim_end().to_string();
    if snippet.name.is_empty() {
        return Err("У сниппета должно быть имя".into());
    }
    if snippet.command.trim().is_empty() {
        return Err("Команда пустая".into());
    }
    if snippet.scope.trim().is_empty() {
        snippet.scope = "global".into();
    }
    if !snippet.is_server_scoped() {
        snippet.server_id = None;
        if snippet.scope.eq_ignore_ascii_case("server") {
            snippet.scope = "global".into();
        }
    }

    let mut book = load_snippet_book(a)?;
    let stamp = now();
    if snippet.id.trim().is_empty() {
        snippet.id = util::new_id("sn");
        snippet.created_at = stamp;
        snippet.updated_at = stamp;
        if snippet.order == 0 {
            snippet.order = book
                .snippets
                .iter()
                .map(|s| s.order)
                .max()
                .unwrap_or(0)
                .saturating_add(1);
        }
        book.snippets.push(snippet.clone());
    } else {
        let index = book
            .snippets
            .iter()
            .position(|s| s.id == snippet.id)
            .ok_or("Сниппет не найден — возможно, он уже удалён")?;
        snippet.created_at = book.snippets[index].created_at;
        snippet.updated_at = stamp;
        book.snippets[index] = snippet.clone();
    }
    store_snippet_book(a, &book)?;
    Ok(snippet)
}

pub fn delete_snippet(id: String) -> Result<(), String> {
    let a = app()?;
    let mut book = load_snippet_book(a)?;
    let before = book.snippets.len();
    book.snippets.retain(|s| s.id != id);
    if book.snippets.len() == before {
        return Ok(());
    }
    store_snippet_book(a, &book)
}

/// Persists a new manual order (ids top to bottom).
pub fn save_snippet_order(ids: Vec<String>) -> Result<(), String> {
    let a = app()?;
    let mut book = load_snippet_book(a)?;
    for (index, id) in ids.iter().enumerate() {
        if let Some(snippet) = book.snippets.iter_mut().find(|s| &s.id == id) {
            snippet.order = index as i32 + 1;
        }
    }
    store_snippet_book(a, &book)
}

// ---------------------------------------------------------------------------
// AI assistant settings
// ---------------------------------------------------------------------------

pub fn load_ai_settings() -> Result<AiSettings, String> {
    let a = app()?;
    store::load_json::<AiSettings>(&a.paths.ai_settings()).map_err(String::from)
}

pub fn save_ai_settings(settings: AiSettings) -> Result<(), String> {
    let a = app()?;
    let endpoint = settings.endpoint.trim();
    if !endpoint.is_empty() && !endpoint.starts_with("http://") && !endpoint.starts_with("https://")
    {
        return Err("Endpoint должен начинаться с http:// или https://".into());
    }
    store::save_json(&a.paths.ai_settings(), &settings).map_err(String::from)
}

pub fn load_color_rules() -> Result<ColorRules, String> {
    let a = app()?;
    Ok(a.rules.lock().map_err(|_| "lock poisoned")?.clone())
}

pub fn save_color_rules(rules: ColorRules) -> Result<(), String> {
    let a = app()?;
    store::save_json(&a.paths.rules(), &rules).map_err(String::from)?;
    *a.rules.lock().map_err(|_| "lock poisoned")? = rules;
    Ok(())
}

pub fn load_session_state() -> Result<SessionState, String> {
    let a = app()?;
    Ok(a.state.lock().map_err(|_| "lock poisoned")?.clone())
}

/// Stores the tabs that are open right now (restored on the next launch).
pub fn save_open_sessions(sessions: Vec<OpenSession>) -> Result<(), String> {
    let a = app()?;
    let mut state = a.state.lock().map_err(|_| "lock poisoned")?;
    state.open_sessions = sessions;
    store::save_json(&a.paths.state(), &*state).map_err(String::from)
}

pub fn remember_session(
    server_id: String,
    remote_path: String,
    local_path: String,
) -> Result<(), String> {
    let a = app()?;
    let mut state = a.state.lock().map_err(|_| "lock poisoned")?;
    state.remember(&server_id, &remote_path, &local_path);
    store::save_json(&a.paths.state(), &*state).map_err(String::from)
}

// ---------------------------------------------------------------------------
// Local filesystem
// ---------------------------------------------------------------------------

pub fn list_local(path: String, show_hidden: bool) -> Result<DirListing, String> {
    let provider = Provider::local();
    rt().block_on(provider.list(&path, show_hidden))
        .map_err(String::from)
}

pub fn volumes() -> Vec<Volume> {
    LocalFs::new().volumes()
}

pub fn home_local() -> Result<String, String> {
    Ok(rt().block_on(LocalFs::new().home()))
}

pub fn free_space_local(path: String) -> Result<u64, String> {
    Ok(LocalFs::new()
        .space(&path)
        .and_then(|(free, _)| free)
        .unwrap_or(0))
}

// ---------------------------------------------------------------------------
// Remote filesystem
// ---------------------------------------------------------------------------

fn provider_remote(a: &App, session_id: &str) -> Result<Provider, String> {
    {
        let sessions = a.sessions.lock().map_err(|_| "lock poisoned")?;
        if let Some(session) = sessions.get(session_id) {
            return Ok(Provider::sftp(Arc::new(SftpFs::new(
                session_id.to_string(),
                session.sftp.clone(),
            ))));
        }
    }
    let ftp = ftp_sessions().lock().map_err(|_| "lock poisoned")?;
    if let Some(fs) = ftp.get(session_id) {
        return Ok(Provider::ftp(fs.clone()));
    }
    drop(ftp);
    let s3 = s3_sessions().lock().map_err(|_| "lock poisoned")?;
    if let Some(fs) = s3.get(session_id) {
        return Ok(Provider::s3(fs.clone()));
    }
    Err(format!("no such session: {session_id}"))
}

/// Set by the progress window's Cancel button. The next [`connect`] clears it;
/// the SSH handshake races against it, so cancelling closes the socket instead
/// of waiting out the timeout.
static CONNECT_CANCELLED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// Server id of the attempt in flight, so Cancel cannot abort a silent
/// restore of another tab by accident.
static CONNECT_TARGET: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

const CONNECT_CANCELLED_MSG: &str = "Соединение отменено";

fn connect_cancelled() -> bool {
    CONNECT_CANCELLED.load(std::sync::atomic::Ordering::SeqCst)
}

/// Cancels the connection attempt that is currently in flight.
///
/// The call returns immediately: `connect` notices the flag, closes what it
/// already opened, and reports an error that the progress window ignores.
/// Only the attempt for `server_id` is cancelled.
pub fn cancel_connect(server_id: String) -> Result<(), String> {
    let target = CONNECT_TARGET
        .lock()
        .ok()
        .and_then(|current| current.clone());
    if target.as_deref() == Some(server_id.as_str()) {
        CONNECT_CANCELLED.store(true, std::sync::atomic::Ordering::SeqCst);
    }
    Ok(())
}

/// Resolves as soon as the flag is raised. Polling keeps it free of races:
/// there is no notification window in which a cancel could be missed.
async fn wait_for_cancel() {
    while !connect_cancelled() {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
}

#[derive(Debug, Clone)]
pub struct ConnectResult {
    pub session_id: String,
    pub start_path: String,
    pub home: String,
    pub fingerprint: Option<String>,
    pub warnings: Vec<String>,
    pub tools: Vec<String>,
}

pub fn connect(server_id: String, password: Option<String>) -> Result<ConnectResult, String> {
    let a = app()?;
    // A fresh attempt starts un-cancelled, even if the previous one was.
    CONNECT_CANCELLED.store(false, std::sync::atomic::Ordering::SeqCst);
    if let Ok(mut target) = CONNECT_TARGET.lock() {
        *target = Some(server_id.clone());
    }
    let server = {
        let book = a.book.lock().map_err(|_| "lock poisoned")?;
        book.server(&server_id)
            .cloned()
            .ok_or_else(|| format!("unknown server: {server_id}"))?
    };

    if server.protocol.as_deref() == Some("s3") {
        if server
            .s3_bucket
            .as_deref()
            .map(|b| b.trim().is_empty())
            .unwrap_or(true)
        {
            return Err("Укажите имя бакета в свойствах сервера".into());
        }
        if server
            .s3_endpoint
            .as_deref()
            .map(|e| e.trim().is_empty())
            .unwrap_or(true)
        {
            return Err("Укажите Endpoint в свойствах сервера".into());
        }
        let access = secret(a, server.s3_access_ref.as_deref().unwrap_or_default())?
            .ok_or("Не задан Access Key ID для S3")?;
        let secret_key = secret(a, server.s3_secret_ref.as_deref().unwrap_or_default())?
            .ok_or("Не задан Secret Access Key для S3")?;
        let fs = Arc::new(crate::fs::s3::S3Fs::new(
            server.s3_endpoint.as_deref().unwrap_or_default(),
            server.s3_region.as_deref().unwrap_or("us-east-1"),
            server.s3_bucket.as_deref().unwrap_or_default(),
            &access,
            &secret_key,
            server.s3_path_style.unwrap_or(true),
            server.s3_prefix.as_deref().unwrap_or(""),
        )?);
        rt().block_on(fs.list("/", true))
            .map_err(|e| e.to_string())?;
        if connect_cancelled() {
            return Err(CONNECT_CANCELLED_MSG.to_string());
        }
        let session_id = util::new_id("conn");
        s3_sessions()
            .lock()
            .map_err(|_| "lock poisoned")?
            .insert(session_id.clone(), fs);
        return Ok(ConnectResult {
            session_id,
            start_path: "/".into(),
            home: "/".into(),
            fingerprint: None,
            warnings: vec![],
            tools: vec![],
        });
    }

    let auth = match server.auth.kind {
        AuthKind::Password => {
            let secret = match password {
                Some(p) => p,
                None => {
                    let secret_id = server
                        .password_ref
                        .clone()
                        .or_else(|| Some(format!("pwd_{}", server.id)))
                        .unwrap();
                    secret(a, &secret_id)?.ok_or("password is not stored for this server")?
                }
            };
            ConnectAuth::Password(secret)
        }
        AuthKind::Key => {
            let passphrase = match server.auth.passphrase_ref.as_deref() {
                Some(id) => secret(a, id)?,
                None => None,
            };
            ConnectAuth::Key {
                path: server
                    .auth
                    .key_path
                    .clone()
                    .ok_or("key path is not set for this server")?,
                passphrase,
            }
        }
        AuthKind::Agent => {
            return Err("agent authentication lands in P2".into());
        }
    };

    if server.protocol.as_deref() == Some("ftp") || server.protocol.as_deref() == Some("ftps") {
        let password = secret(a, &server.password_ref.clone().unwrap_or_default())?
            .ok_or("Для FTP-сервера не сохранён пароль")?;
        let ftp = Arc::new(
            crate::fs::ftp::FtpFs::new(
                server.host.clone(),
                server.port,
                server.user.clone(),
                password.clone(),
                server.passive.unwrap_or(true),
            )
            .with_tls(
                crate::fs::ftp::FtpTls::parse(
                    server.protocol.as_deref(),
                    server.ftps_mode.as_deref(),
                ),
                server.ftps_insecure.unwrap_or(false),
            ),
        );
        // Verify the login right away so failures surface during connect.
        let _listing = rt()
            .block_on(ftp.list("/", true))
            .map_err(|e| e.to_string())?;
        if connect_cancelled() {
            return Err(CONNECT_CANCELLED_MSG.to_string());
        }
        let session_id = util::new_id("conn");
        ftp_sessions()
            .lock()
            .map_err(|_| "lock poisoned")?
            .insert(session_id.clone(), ftp);
        return Ok(ConnectResult {
            session_id,
            start_path: "/".into(),
            home: "/".into(),
            fingerprint: None,
            warnings: vec![],
            tools: vec![],
        });
    }

    let mut warnings = Vec::new();
    let expected = server.host_key_fingerprint.clone();
    let opts = ConnectOptions {
        host: server.host.clone(),
        port: server.port,
        user: server.user.clone(),
        auth,
        expected_fingerprint: expected.clone(),
        ..Default::default()
    };

    util::set_connect_stage(1);
    let session = match rt().block_on(async {
        tokio::select! {
            result = ssh::connect(&opts) => result.map_err(|e| e.to_string()),
            _ = wait_for_cancel() => Err(CONNECT_CANCELLED_MSG.to_string()),
        }
    }) {
        Ok(session) => session,
        Err(e) => {
            util::set_connect_stage(0);
            return Err(e);
        }
    };
    if connect_cancelled() {
        util::set_connect_stage(0);
        let _ = rt().block_on(session.close());
        return Err(CONNECT_CANCELLED_MSG.to_string());
    }
    util::set_connect_stage(4);

    let fingerprint_now = session.fingerprint.clone();
    if expected.is_some() && expected != fingerprint_now {
        warnings.push("host key changed — verify the server".to_string());
    }

    let session_id = util::new_id("conn");
    let home = rt()
        .block_on(session.sftp.expand_path("."))
        .ok()
        .flatten()
        .unwrap_or_else(|| "/".to_string());

    let tools = rt()
        .block_on(session.detect_archive_tools())
        .unwrap_or_default();

    if connect_cancelled() {
        util::set_connect_stage(0);
        let _ = rt().block_on(session.close());
        return Err(CONNECT_CANCELLED_MSG.to_string());
    }

    {
        let mut sessions = a.sessions.lock().map_err(|_| "lock poisoned")?;
        sessions.insert(session_id.clone(), Arc::new(session));
    }

    // Persist learned state: fingerprint and connection time.
    {
        let mut book = a.book.lock().map_err(|_| "lock poisoned")?;
        if let Some(stored) = book.servers.iter_mut().find(|s| s.id == server_id) {
            if stored.host_key_fingerprint.is_none() {
                stored.host_key_fingerprint = fingerprint_now.clone();
            }
            stored.last_connected = Some(now());
        }
        let _ = persist_book(a, &book);
    }

    let provider = provider_remote(a, &session_id)?;
    let desired = {
        let state = a.state.lock().map_err(|_| "lock poisoned")?;
        state
            .record(&server_id)
            .map(|r| r.session.path.clone())
            .filter(|p| !p.trim().is_empty())
            .or_else(|| server.remote_path.clone())
            .unwrap_or_else(|| home.clone())
    };

    let start_path = rt().block_on(provider.resolve_dir(&desired, &home));
    let start_path = rt()
        .block_on(resolve_existing(&provider, &start_path))
        .unwrap_or_else(|_| home.clone());
    if start_path != desired {
        warnings.push(format!(
            "folder {desired} is not available — opened {start_path}"
        ));
    }

    util::set_connect_stage(5);
    Ok(ConnectResult {
        session_id,
        start_path,
        home,
        fingerprint: fingerprint_now,
        warnings,
        tools,
    })
}

/// Walk up until an existing directory is found.
async fn resolve_existing(provider: &Provider, desired: &str) -> Result<String, String> {
    let mut current = desired.to_string();
    loop {
        if provider.stat(&current).await.is_ok() {
            return Ok(current);
        }
        match util::parent(&current) {
            Some(p) => current = p,
            None => return Err("no existing ancestor".into()),
        }
    }
}

pub fn disconnect(session_id: String) -> Result<(), String> {
    let a = app()?;
    let session = {
        let mut sessions = a.sessions.lock().map_err(|_| "lock poisoned")?;
        sessions.remove(&session_id)
    };
    if let Some(session) = session {
        // Folders created by "open archive on server" live in /tmp; remove
        // them with the session instead of leaving gigabytes behind.
        let dirs = remote_tmp_dirs()
            .lock()
            .ok()
            .and_then(|mut map| map.remove(&session_id));
        if let Some(dirs) = dirs.filter(|dirs| !dirs.is_empty()) {
            let command = format!(
                "rm -rf {}",
                dirs.iter()
                    .map(|dir| util::shell_escape(dir))
                    .collect::<Vec<_>>()
                    .join(" ")
            );
            let _ = rt()
                .block_on(session.exec_result(&command, std::time::Duration::from_secs(30)));
        }
        let _ = rt().block_on(session.close());
    }
    if let Ok(mut ftp) = ftp_sessions().lock() {
        ftp.remove(&session_id);
    }
    if let Ok(mut s3) = s3_sessions().lock() {
        s3.remove(&session_id);
    }
    Ok(())
}

pub fn is_connected(session_id: String) -> bool {
    if let Ok(a) = app() {
        if let Ok(sessions) = a.sessions.lock() {
            if sessions.contains_key(&session_id) {
                return true;
            }
        }
    }
    if ftp_sessions()
        .lock()
        .map(|m| m.contains_key(&session_id))
        .unwrap_or(false)
    {
        return true;
    }
    s3_sessions()
        .lock()
        .map(|m| m.contains_key(&session_id))
        .unwrap_or(false)
}

pub fn list_remote(
    session_id: String,
    path: String,
    show_hidden: bool,
) -> Result<DirListing, String> {
    let a = app()?;
    let provider = provider_remote(a, &session_id)?;
    rt().block_on(provider.list(&path, show_hidden))
        .map_err(String::from)
}

pub fn resolve_remote_dir(
    session_id: String,
    input: String,
    fallback: String,
) -> Result<String, String> {
    let a = app()?;
    let provider = provider_remote(a, &session_id)?;
    Ok(rt().block_on(provider.resolve_dir(&input, &fallback)))
}

pub fn home_remote(session_id: String) -> Result<String, String> {
    let a = app()?;
    let sessions = a.sessions.lock().map_err(|_| "lock poisoned")?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("no such session: {session_id}"))?;
    Ok(rt()
        .block_on(session.sftp.expand_path("."))
        .ok()
        .flatten()
        .unwrap_or_else(|| "/".to_string()))
}

/// Run a command on the server (used by the terminal button and diagnostics).
pub fn exec_remote(session_id: String, command: String) -> Result<String, String> {
    let a = app()?;
    let sessions = a.sessions.lock().map_err(|_| "lock poisoned")?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("no such session: {session_id}"))?;
    rt().block_on(session.exec(&command)).map_err(String::from)
}

// ---------------------------------------------------------------------------
// Mutations (local and remote through one entry point)
// ---------------------------------------------------------------------------

fn provider_for(a: &App, session_id: Option<String>) -> Result<Provider, String> {
    match session_id {
        Some(id) => provider_remote(a, &id),
        None => Ok(Provider::local()),
    }
}

pub fn mkdir(session_id: Option<String>, path: String) -> Result<(), String> {
    let a = app()?;
    let provider = provider_for(a, session_id)?;
    rt().block_on(provider.mkdir(&path)).map_err(String::from)
}

pub fn rename(session_id: Option<String>, from: String, to: String) -> Result<(), String> {
    let a = app()?;
    let provider = provider_for(a, session_id)?;
    rt().block_on(provider.rename(&from, &to))
        .map_err(String::from)
}

pub fn remove(session_id: Option<String>, path: String, is_dir: bool) -> Result<(), String> {
    let a = app()?;
    let provider = provider_for(a, session_id)?;
    rt().block_on(provider.remove(&path, is_dir))
        .map_err(String::from)
}

// ---------------------------------------------------------------------------
// Transfers
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
pub fn transfer(
    session_id: String,
    direction: String,
    source_path: String,
    target_dir: String,
    resume_from: u64,
    limit_kibps: u32,
    verify: bool,
    // Optional new name for the copied file (rename on copy).
    target_name: Option<String>,
    sink: StreamSink<TransferEvent>,
) -> Result<(), String> {
    let a = app()?;
    let remote = provider_remote(a, &session_id)?;
    let local = Provider::local();
    let name = match target_name
        .map(|n| n.trim().to_string())
        .filter(|n| !n.is_empty())
    {
        Some(n) => n,
        None => util::file_name(&source_path).to_string(),
    };
    // The name is typed by the user or taken from the source path; either way
    // it must stay a plain file name inside `target_dir`.
    if !util::is_safe_component(&name) {
        return Err(format!("Недопустимое имя файла: {name:?}"));
    }
    let target_path = util::join(&target_dir, &name);
    let id = util::new_id("t");

    let (src, dst, src_path) = match direction.as_str() {
        "upload" => (local, remote, source_path.clone()),
        "download" => (remote, local, source_path.clone()),
        other => return Err(format!("unknown direction: {other}")),
    };

    let total = rt()
        .block_on(src.stat(&src_path))
        .map(|e| e.size)
        .unwrap_or(0);

    let _ = sink.add(TransferEvent {
        id: id.clone(),
        name: name.clone(),
        total,
        done: 0,
        state: TransferState::Queued,
        message: None,
    });

    let (concurrency, parts) = a
        .settings
        .lock()
        .map(|settings| {
            (
                settings.transfer.concurrency,
                settings.transfer.chunks_per_file,
            )
        })
        .unwrap_or((3, 4));
    let slots = transfer_slots(concurrency);
    let event_id = id.clone();
    let cancel = Arc::new(std::sync::atomic::AtomicBool::new(false));
    if let Ok(mut map) = transfer_cancels().lock() {
        map.insert(id.clone(), cancel.clone());
    }
    let ftp_target = match &dst {
        Provider::Ftp(fs) => Some(fs.clone()),
        _ => None,
    };
    let s3_target = match &dst {
        Provider::S3(fs) => Some(fs.clone()),
        _ => None,
    };

    rt().spawn(async move {
        let _guard = CancelGuard(event_id.clone());

        // The queue in the UI shows "в очереди" until this returns.
        let permit = match slots.acquire_owned().await {
            Ok(permit) => permit,
            Err(_) => {
                let _ = sink.add(TransferEvent {
                    id: event_id.clone(),
                    name: name.clone(),
                    total,
                    done: 0,
                    state: TransferState::Failed,
                    message: Some("передача отменена".into()),
                });
                return;
            }
        };
        let _ = sink.add(TransferEvent {
            id: event_id.clone(),
            name: name.clone(),
            total,
            done: 0,
            state: TransferState::Running,
            message: None,
        });
        let _permit = permit;

        if let Some(s3) = s3_target {
            use tokio::io::AsyncReadExt;
            let mut reader = match src.open_read(&src_path, 0).await {
                Ok(r) => r,
                Err(e) => {
                    let _ = sink.add(TransferEvent {
                        id,
                        name,
                        total,
                        done: 0,
                        state: TransferState::Failed,
                        message: Some(e.to_string()),
                    });
                    return;
                }
            };
            let mut data = Vec::new();
            if let Err(e) = reader.read_to_end(&mut data).await {
                let _ = sink.add(TransferEvent {
                    id,
                    name,
                    total,
                    done: 0,
                    state: TransferState::Failed,
                    message: Some(e.to_string()),
                });
                return;
            }
            let (state, message) = match s3.write_all(&target_path, &data).await {
                Ok(()) => (TransferState::Done, None),
                Err(e) => (TransferState::Failed, Some(e.to_string())),
            };
            let _ = sink.add(TransferEvent {
                id,
                name,
                total: data.len() as u64,
                done: data.len() as u64,
                state,
                message,
            });
            return;
        }
        if let Some(ftp) = ftp_target {
            use tokio::io::AsyncReadExt;
            let mut reader = match src.open_read(&src_path, 0).await {
                Ok(r) => r,
                Err(e) => {
                    let _ = sink.add(TransferEvent {
                        id,
                        name,
                        total,
                        done: 0,
                        state: TransferState::Failed,
                        message: Some(e.to_string()),
                    });
                    return;
                }
            };
            let mut data = Vec::new();
            if let Err(e) = reader.read_to_end(&mut data).await {
                let _ = sink.add(TransferEvent {
                    id,
                    name,
                    total,
                    done: 0,
                    state: TransferState::Failed,
                    message: Some(e.to_string()),
                });
                return;
            }
            let (state, message) = match ftp.write_all(&target_path, &data).await {
                Ok(()) => (TransferState::Done, None),
                Err(e) => (TransferState::Failed, Some(e.to_string())),
            };
            let _ = sink.add(TransferEvent {
                id,
                name,
                total: data.len() as u64,
                done: data.len() as u64,
                state,
                message,
            });
            return;
        }

        let mut stats = CopyStats::default();
        let mut last_emit = 0u64;
        let sink2 = sink.clone();
        let limit_bps = if limit_kibps == 0 {
            None
        } else {
            Some(limit_kibps as u64 * 1024)
        };
        let result = task::copy_path(
            &src,
            &src_path,
            &dst,
            &target_path,
            task::DEFAULT_CHUNK,
            &mut stats,
            &mut |done| {
                // Throttle to ~1 MiB to keep the UI bridge quiet.
                if done - last_emit >= 1024 * 1024 || done == total {
                    last_emit = done;
                    let _ = sink2.add(TransferEvent {
                        id: event_id.clone(),
                        name: name.clone(),
                        total,
                        done,
                        state: TransferState::Running,
                        message: None,
                    });
                }
            },
            Some(cancel.clone()),
            resume_from,
            limit_bps,
            parts,
        )
        .await;

        let (mut state, mut message) = match result {
            Ok(()) => (TransferState::Done, None),
            Err(e) => (TransferState::Failed, Some(e.to_string())),
        };

        // Cheap integrity guard: an interrupted or spliced upload shows up as a
        // size mismatch even before the optional checksum runs.
        if state == TransferState::Done {
            let expected = src.stat(&src_path).await.map(|e| e.size).unwrap_or(0);
            let actual = dst.stat(&target_path).await.map(|e| e.size).unwrap_or(0);
            if expected != actual {
                state = TransferState::Failed;
                message = Some(format!(
                    "размер не совпадает: передано {actual} из {expected}"
                ));
            }
        }

        // Optional integrity check: re-read both sides and compare SHA-256.
        if state == TransferState::Done && verify {
            match (hash_side(&src, &src_path).await, hash_side(&dst, &target_path).await) {
                (Ok(source_hash), Ok(target_hash)) if source_hash == target_hash => {
                    message = Some("SHA-256 совпадает".into());
                }
                (Ok(_), Ok(_)) => {
                    state = TransferState::Failed;
                    message = Some("SHA-256 не совпадает".into());
                }
                (Err(e), _) | (_, Err(e)) => {
                    message = Some(format!("Проверка SHA-256: {e}"));
                }
            }
        }
        if stats.skipped > 0 {
            let note = format!(
                "пропущено файлов с недопустимыми именами: {}",
                stats.skipped
            );
            message = Some(match message {
                Some(existing) => format!("{existing}; {note}"),
                None => note,
            });
        }
        let _ = sink.add(TransferEvent {
            id,
            name,
            total,
            done: stats.bytes,
            state,
            message,
        });
    });

    Ok(())
}

/// Read the first `max_bytes` of a file for the F3 viewer.
pub fn preview(session_id: Option<String>, path: String, max_bytes: u32) -> Result<String, String> {
    use tokio::io::AsyncReadExt;
    let a = app()?;
    let provider = provider_for(a, session_id)?;
    rt().block_on(async move {
        let mut reader = provider
            .open_read(&path, 0)
            .await
            .map_err(|e| e.to_string())?;
        let mut buf = vec![0u8; max_bytes as usize];
        let mut read = 0usize;
        loop {
            let n = reader
                .read(&mut buf[read..])
                .await
                .map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            read += n;
            if read >= buf.len() {
                break;
            }
        }
        buf.truncate(read);
        Ok(String::from_utf8_lossy(&buf).to_string())
    })
}

// ---------------------------------------------------------------------------
// External editor (F4)
// ---------------------------------------------------------------------------

/// Polled by the UI while the progress window is open.
pub fn connect_stage() -> u32 {
    util::connect_stage() as u32
}

/// Cheap TCP reachability probe (no authentication, no banner exchange).
pub fn probe_server(host: String, port: u16, timeout_ms: u32) -> bool {
    use std::net::ToSocketAddrs;
    let host = host.trim().to_string();
    if host.is_empty() {
        return false;
    }
    let target = format!("{host}:{port}");
    let Ok(addrs) = target.to_socket_addrs() else {
        return false;
    };
    for addr in addrs.take(2) {
        if std::net::TcpStream::connect_timeout(
            &addr,
            std::time::Duration::from_millis(timeout_ms.max(200) as u64),
        )
        .is_ok()
        {
            return true;
        }
    }
    false
}

/// Starts any external program (used for PuTTY / Windows Terminal).
pub fn launch_process(command: String, args: Vec<String>) -> Result<(), String> {
    let command = command.trim().trim_matches('"').to_string();
    if command.is_empty() {
        return Err("command is empty".into());
    }
    std::process::Command::new(&command)
        .args(&args)
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("cannot start {command}: {e}"))
}

/// Starts the configured editor with the given local file.
pub fn launch_editor(editor: String, path: String) -> Result<(), String> {
    let editor = editor.trim().trim_matches('"').to_string();
    if editor.is_empty() {
        return Err("external editor is not configured".into());
    }
    // A bare name (e.g. "notepad++.exe") is resolved through PATH; only an
    // explicit path is validated up front.
    let explicit_path = editor.contains('\\') || editor.contains('/');
    if explicit_path && !std::path::Path::new(&editor).exists() {
        return Err(format!("editor not found: {editor}"));
    }
    std::process::Command::new(&editor)
        .arg(&path)
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("cannot start editor: {e}"))
}

/// True when the path exists (used by the settings screen to validate tools).
pub fn path_exists(path: String) -> bool {
    std::path::Path::new(path.trim().trim_matches('"')).exists()
}

/// Modification time in epoch milliseconds; used to detect editor saves.
pub fn file_mtime_ms(path: String) -> Result<i64, String> {
    let meta = std::fs::metadata(&path).map_err(|e| e.to_string())?;
    Ok(meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0))
}

fn edit_cache_path(a: &App, server_name: &str, remote_path: &str) -> std::path::PathBuf {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    remote_path.hash(&mut hasher);
    // tmp/<server>/<path hash>/<file>, so a whole server can be cleaned when
    // its session ends and two sessions to one host do not collide.
    let dir = a
        .paths
        .tmp_dir()
        .join(util::safe_file_stem(server_name))
        .join(format!("{:x}", hasher.finish()));
    let name = util::file_name(remote_path);
    // A hostile server must not make the cache path escape its folder ("..").
    dir.join(if util::is_safe_component(name) {
        name
    } else {
        "file"
    })
}

/// Downloads a remote file into `tmp/<server>/` and returns the local path.
pub fn download_to_cache(
    session_id: String,
    server_name: String,
    remote_path: String,
) -> Result<String, String> {
    let a = app()?;
    let remote = provider_remote(a, &session_id)?;
    let local = Provider::local();
    let target = edit_cache_path(a, &server_name, &remote_path);
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let target_str = target.to_string_lossy().to_string();
    let mut stats = CopyStats::default();
    rt().block_on(task::copy_path(
        &remote,
        &remote_path,
        &local,
        &target_str,
        task::DEFAULT_CHUNK,
        &mut stats,
        &mut |_| {},
        None,
        0,
        None,
        1,
    ))
    .map_err(|e| e.to_string())?;
    Ok(target_str)
}

/// Uploads an edited file back. No backup copy is kept: the user asked for
/// "save means save".
pub fn upload_from_cache(
    session_id: String,
    local_path: String,
    remote_path: String,
) -> Result<(), String> {
    let a = app()?;
    let remote = provider_remote(a, &session_id)?;
    let local = Provider::local();

    let mut stats = CopyStats::default();
    rt().block_on(task::copy_path(
        &local,
        &local_path,
        &remote,
        &remote_path,
        task::DEFAULT_CHUNK,
        &mut stats,
        &mut |_| {},
        None,
        0,
        None,
        1,
    ))
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// Removes all temporary files of one server (called when its last tab closes).
pub fn clear_server_tmp(server_name: String) -> Result<(), String> {
    let a = app()?;
    let dir = a
        .paths
        .tmp_dir()
        .join(util::safe_file_stem(&server_name));
    if dir.exists() {
        std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Removes every temporary file, used on shutdown and after a crash recovery.
pub fn clear_all_tmp() -> Result<(), String> {
    let a = app()?;
    let dir = a.paths.tmp_dir();
    if dir.exists() {
        std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    }
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// Archives (P1)
// ---------------------------------------------------------------------------

/// Destination of one archive entry, or `None` when the entry name would
/// escape the extraction folder (`../../x`, `C:/x`, ...).
fn archive_entry_dest(
    root_dir: &str,
    target_dir: &str,
    root_is_dir: bool,
    file: &str,
    relative: &str,
) -> Option<String> {
    if root_is_dir {
        util::join_relative(root_dir, relative)
    } else {
        util::join_child(target_dir, util::file_name(file))
    }
}

/// `demo.zip` -> `demo`, so extracting an archive creates a named folder.
fn archive_folder_name(path: &str) -> String {
    crate::archive::ArchiveFormat::stem(path)
}

fn archive_error(error: crate::error::NovaError) -> String {
    if crate::archive::is_password_error(&error) {
        format!("{}{}", crate::archive::PASSWORD_MARKER, error)
    } else {
        error.to_string()
    }
}

fn open_archive(path: &str) -> Result<std::sync::Arc<crate::archive::ArchiveFs>, String> {
    crate::archive::open(path).map_err(|e| {
        if crate::archive::is_password_error(&e) {
            format!("{}{}", crate::archive::PASSWORD_MARKER, e)
        } else {
            e.to_string()
        }
    })
}

/// `true` when the archive cannot be read without a password. Reads one byte
/// of the smallest entry: names are visible in most formats, content is not.
pub fn archive_needs_password(archive_path: String) -> Result<bool, String> {
    Ok(crate::archive::needs_password(&archive_path))
}

/// Verifies and remembers a password for this run (never written to disk).
pub fn unlock_archive(archive_path: String, password: String) -> Result<(), String> {
    crate::archive::unlock(&archive_path, &password).map_err(|e| {
        if crate::archive::is_password_error(&e) {
            "Пароль не подошёл или архив повреждён".to_string()
        } else {
            e.to_string()
        }
    })
}

/// Lists a directory inside an archive. Local archives only for now.
pub fn list_archive(
    archive_path: String,
    inner: String,
    show_hidden: bool,
) -> Result<DirListing, String> {
    let archive = open_archive(&archive_path)?;
    archive.list(&inner, show_hidden).map_err(String::from)
}

/// Text preview of an entry inside an archive (F3).
pub fn preview_archive(
    archive_path: String,
    inner: String,
    max_bytes: u32,
) -> Result<String, String> {
    let archive = open_archive(&archive_path)?;
    let bytes = archive.read_entry(&inner).map_err(archive_error)?;
    let take = bytes.len().min(max_bytes as usize);
    Ok(String::from_utf8_lossy(&bytes[..take]).to_string())
}

// ---------------------------------------------------------------------------
// File comparison (Ctrl+F3)
// ---------------------------------------------------------------------------

/// Reads at most `max` bytes of `src` and reports the real file size.
fn read_ref(a: &App, src: &FileRef, max: u64) -> Result<(Vec<u8>, u64, bool), String> {
    use tokio::io::AsyncReadExt;

    let provider = match (&src.session_id, &src.archive_path) {
        (_, Some(archive)) => crate::fs::Provider::archive(open_archive(archive)?),
        (Some(id), None) => provider_remote(a, id)?,
        (None, None) => crate::fs::Provider::local(),
    };

    let entry = rt()
        .block_on(provider.stat(&src.path))
        .map_err(|e| e.to_string())?;
    if entry.kind == EntryKind::Dir {
        return Err(format!("{} — это папка", entry.name));
    }
    let size = entry.size;

    let mut reader = rt()
        .block_on(provider.open_read(&src.path, 0))
        .map_err(|e| e.to_string())?;
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = vec![0u8; 64 * 1024];
    let mut truncated = false;
    loop {
        let room = max.saturating_sub(buf.len() as u64);
        if room == 0 {
            truncated = true;
            break;
        }
        let read = rt()
            .block_on(reader.read(&mut chunk))
            .map_err(|e| e.to_string())?;
        if read == 0 {
            break;
        }
        let take = (room as usize).min(read);
        buf.extend_from_slice(&chunk[..take]);
        if take < read {
            truncated = true;
            break;
        }
    }
    if size > max {
        truncated = true;
    }

    Ok((buf, size, truncated))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = ring::digest::digest(&ring::digest::SHA256, bytes);
    digest.as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

/// Glob with `*` and `?`, case-insensitive; a mask without wildcards becomes
/// a "contains" match so typing `php` still finds something.
fn glob_match(pattern: &str, name: &str) -> bool {
    let pattern = if pattern.contains('*') || pattern.contains('?') {
        pattern.to_string()
    } else {
        format!("*{pattern}*")
    };
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    let n: Vec<char> = name.to_lowercase().chars().collect();
    let (mut pi, mut ni, mut star, mut mark) = (0usize, 0usize, None, 0usize);
    while ni < n.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == n[ni]) {
            pi += 1;
            ni += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            mark = ni;
            pi += 1;
        } else if let Some(sp) = star {
            pi = sp + 1;
            mark += 1;
            ni = mark;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

/// Copies local files or folders into a local folder (drag & drop from Explorer).
/// Returns how many top-level items were copied.
pub fn copy_local(sources: Vec<String>, target_dir: String) -> Result<u32, String> {
    let local = crate::fs::Provider::local();
    let mut copied = 0u32;
    for source in sources {
        let name = util::file_name(&source).to_string();
        let Some(target) = util::join_child(&target_dir, &name) else {
            continue;
        };
        let mut stats = CopyStats::default();
        rt().block_on(crate::task::copy_path(
            &local,
            &source,
            &local,
            &target,
            crate::task::DEFAULT_CHUNK,
            &mut stats,
            &mut |_| {},
            None,
            0,
            None,
            1,
        ))
        .map_err(|e| format!("{name}: {e}"))?;
        copied += 1;
    }
    Ok(copied)
}

// ---------------------------------------------------------------------------
// QR sync (desktop -> phone)
// ---------------------------------------------------------------------------

/// Builds the profile payload that a phone can import.
pub fn sync_export_json(include_secrets: bool) -> Result<String, String> {
    let a = app()?;
    let book: ServerBook = store::load_json(&a.paths.servers()).map_err(String::from)?;
    let settings: Settings = store::load_json(&a.paths.settings()).map_err(String::from)?;

    let mut secrets: Option<HashMap<String, String>> = None;
    if include_secrets {
        let mut map: HashMap<String, String> = HashMap::new();
        for server in &book.servers {
            let ids = [
                server.password_ref.clone(),
                server.s3_access_ref.clone(),
                server.s3_secret_ref.clone(),
                server.auth.passphrase_ref.clone(),
            ];
            for id in ids.into_iter().flatten() {
                if map.contains_key(&id) {
                    continue;
                }
                if let Ok(Some(value)) = secret(a, &id) {
                    map.insert(id, value);
                }
            }
        }
        for id in AI_KEY_IDS {
            if let Ok(Some(value)) = secret(a, id) {
                map.insert(id.to_string(), value);
            }
        }
        secrets = Some(map);
    }

    let snippets = load_snippet_book(a)?.snippets;
    let ai: AiSettings = store::load_json(&a.paths.ai_settings()).map_err(String::from)?;

    let payload = crate::sync::SyncPayload {
        version: 1,
        exported_at: util::now_ms(),
        servers: book.servers,
        groups: book.groups,
        settings: Some(settings),
        secrets,
        snippets,
        ai,
    };
    serde_json::to_string(&payload).map_err(|e| e.to_string())
}

/// Everything an exported profile contains (encrypted inside the file).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProfilePayload {
    #[serde(default)]
    servers: Vec<Server>,
    #[serde(default)]
    groups: Vec<crate::model::Group>,
    settings: Settings,
    rules: ColorRules,
    /// Secret id -> plaintext password / key.
    #[serde(default)]
    secrets: HashMap<String, String>,
    /// Saved commands travel with the profile.
    #[serde(default)]
    snippets: Vec<Snippet>,
    #[serde(default)]
    ai: AiSettings,
}

/// Exported profile file: a small header plus the whole payload in the clear.
///
/// The user asked for no password on export/import, so the file is plain JSON.
/// The UI warns that it contains the saved passwords and must be stored safely.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProfileFile {
    format: u32,
    app_version: String,
    created_at: i64,
    #[serde(flatten)]
    payload: ProfilePayload,
}

const PROFILE_FORMAT: u32 = 1;

/// Vault ids for the assistant keys; exported together with server passwords.
const AI_KEY_IDS: [&str; 4] = [
    "ai_key_zen",
    "ai_key_go",
    "ai_key_openrouter",
    "ai_key_custom",
];

pub struct ProfileImportReport {
    pub servers: u32,
    pub groups: u32,
    pub secrets: u32,
    pub snippets: u32,
    pub replaced: bool,
    pub backup_dir: Option<String>,
}

/// Writes an encrypted copy of the whole profile (servers, settings, rules and
/// the saved passwords) to `path`.
///
/// Writes the whole profile (servers, settings, rules and the saved passwords)
/// to `path` as plain JSON.
pub fn export_profile(path: String) -> Result<(), String> {
    let a = app()?;
    let book: ServerBook = store::load_json(&a.paths.servers()).map_err(String::from)?;
    let settings: Settings = store::load_json(&a.paths.settings()).map_err(String::from)?;
    let rules: ColorRules = store::load_json(&a.paths.rules()).map_err(String::from)?;

    let mut secrets: HashMap<String, String> = HashMap::new();
    {
        let vault = a.vault.lock().map_err(|_| "lock poisoned")?;
        let vault = vault
            .as_ref()
            .ok_or("Сначала разблокируйте хранилище — иначе пароли не попадут в файл")?;
        for server in &book.servers {
            let ids = [
                server.password_ref.clone(),
                server.s3_access_ref.clone(),
                server.s3_secret_ref.clone(),
                server.auth.passphrase_ref.clone(),
            ];
            for id in ids.into_iter().flatten() {
                if secrets.contains_key(&id) {
                    continue;
                }
                if let Ok(Some(value)) = vault.get(&id) {
                    secrets.insert(id, value);
                }
            }
        }
        // AI provider keys are part of the profile as well.
        for id in AI_KEY_IDS {
            if let Ok(Some(value)) = vault.get(id) {
                secrets.insert(id.to_string(), value);
            }
        }
    }

    let snippets = load_snippet_book(a)?.snippets;
    let ai: AiSettings = store::load_json(&a.paths.ai_settings()).map_err(String::from)?;

    let payload = ProfilePayload {
        servers: book.servers,
        groups: book.groups,
        settings,
        rules,
        secrets,
        snippets,
        ai,
    };
    let file = ProfileFile {
        format: PROFILE_FORMAT,
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        created_at: now(),
        payload,
    };
    let json = serde_json::to_vec_pretty(&file).map_err(|e| e.to_string())?;
    store::save_bytes(std::path::Path::new(&path), &json).map_err(String::from)
}

/// Reads an exported profile. `replace` swaps the whole profile (with a backup
/// of the current files); otherwise servers and groups are merged by
/// host+port+user and the local settings are kept.
pub fn import_profile(path: String, replace: bool) -> Result<ProfileImportReport, String> {
    let a = app()?;
    let raw = std::fs::read(&path).map_err(|e| format!("{path}: {e}"))?;

    // An intermediate build wrote an encrypted envelope; say so instead of
    // "файл повреждён".
    if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&raw) {
        if value.get("ct").is_some() || value.get("kdf").is_some() {
            return Err(
                "Файл создан промежуточной сборкой с паролем и зашифрован —                  экспортируйте профиль заново"
                    .into(),
            );
        }
    }

    let file: ProfileFile =
        serde_json::from_slice(&raw).map_err(|e| format!("Некорректный файл профиля: {e}"))?;
    if file.format != PROFILE_FORMAT {
        return Err(format!("Неизвестный формат файла: {}", file.format));
    }
    let payload = file.payload;

    let backup_dir = if replace {
        Some(backup_profile(a)?)
    } else {
        None
    };

    let mut secrets_imported = 0u32;
    {
        let mut guard = a.vault.lock().map_err(|_| "lock poisoned")?;
        let vault = guard
            .as_mut()
            .ok_or("Сначала разблокируйте хранилище, чтобы импортировать пароли")?;
        for (id, value) in &payload.secrets {
            if vault.set(id, value).is_ok() {
                secrets_imported += 1;
            }
        }
        vault.save().map_err(String::from)?;
    }

    if replace {
        let mut book = ServerBook {
            version: 1,
            groups: payload.groups,
            servers: payload.servers,
        };
        book.validate().map_err(String::from)?;
        {
            let mut current = a.book.lock().map_err(|_| "lock poisoned")?;
            *current = book.clone();
        }
        persist_book(a, &book)?;
        store::save_json(&a.paths.settings(), &payload.settings).map_err(String::from)?;
        *a.settings.lock().map_err(|_| "lock poisoned")? = payload.settings.clone();
        store::save_json(&a.paths.rules(), &payload.rules).map_err(String::from)?;
        *a.rules.lock().map_err(|_| "lock poisoned")? = payload.rules;
        let snippets = payload.snippets.len() as u32;
        store::save_json(
            &a.paths.snippets(),
            &SnippetBook {
                version: 1,
                snippets: payload.snippets,
            },
        )
        .map_err(String::from)?;
        store::save_json(&a.paths.ai_settings(), &payload.ai).map_err(String::from)?;
        return Ok(ProfileImportReport {
            servers: book.servers.len() as u32,
            groups: book.groups.len() as u32,
            secrets: secrets_imported,
            snippets,
            replaced: true,
            backup_dir,
        });
    }

    // Merge: keep what is already here, skip duplicates by host+port+user.
    let mut book_guard = a.book.lock().map_err(|_| "lock poisoned")?;
    let book = &mut *book_guard;
    let groups_before = book.groups.len();
    let servers_before = book.servers.len();

    let mut group_map: HashMap<String, String> = HashMap::new();
    for group in &payload.groups {
        if let Some(existing) = book
            .groups
            .iter()
            .find(|g| g.name.trim().eq_ignore_ascii_case(group.name.trim()))
        {
            group_map.insert(group.id.clone(), existing.id.clone());
        }
    }
    for group in payload.groups {
        if group_map.contains_key(&group.id) {
            continue;
        }
        group_map.insert(group.id.clone(), group.id.clone());
        book.upsert_group(group);
    }

    for mut server in payload.servers {
        let exists = book.servers.iter().any(|s| {
            s.host.eq_ignore_ascii_case(&server.host)
                && s.port == server.port
                && s.user == server.user
        });
        if exists {
            continue;
        }
        if book.servers.iter().any(|s| s.id == server.id) {
            server.id = util::new_id("s");
        }
        if let Some(group_id) = server.group_id.clone() {
            server.group_id = group_map.get(&group_id).cloned();
        }
        book.upsert_server(server);
    }

    book.validate().map_err(String::from)?;
    persist_book(a, book)?;

    let snippets_added = merge_snippets(a, payload.snippets)?;
    apply_ai_if_fresh(a, payload.ai)?;

    Ok(ProfileImportReport {
        servers: (book.servers.len() - servers_before) as u32,
        groups: (book.groups.len() - groups_before) as u32,
        secrets: secrets_imported,
        snippets: snippets_added,
        replaced: false,
        backup_dir,
    })
}

/// Adds incoming snippets that are not here yet (by id, or by the same
/// name+command) and keeps the local order.
fn merge_snippets(a: &App, incoming: Vec<Snippet>) -> Result<u32, String> {
    if incoming.is_empty() {
        return Ok(0);
    }
    let mut book = load_snippet_book(a)?;
    let mut added = 0u32;
    for mut snippet in incoming {
        let duplicate = book.snippets.iter().any(|s| {
            s.id == snippet.id
                || (s.command == snippet.command
                    && s.name.eq_ignore_ascii_case(snippet.name.as_str()))
        });
        if duplicate {
            continue;
        }
        if snippet.id.trim().is_empty() || book.snippets.iter().any(|s| s.id == snippet.id) {
            snippet.id = util::new_id("sn");
        }
        if snippet.created_at == 0 {
            snippet.created_at = now();
        }
        snippet.order = book
            .snippets
            .iter()
            .map(|s| s.order)
            .max()
            .unwrap_or(0)
            .saturating_add(1);
        book.snippets.push(snippet);
        added += 1;
    }
    store_snippet_book(a, &book)?;
    Ok(added)
}

/// A phone starts without `ai.json`; an import fills it in. On a machine that
/// already configured the assistant the local choice wins.
fn apply_ai_if_fresh(a: &App, ai: AiSettings) -> Result<(), String> {
    let path = a.paths.ai_settings();
    let exists = std::fs::metadata(&path)
        .map(|meta| meta.len() > 2)
        .unwrap_or(false);
    if exists {
        return Ok(());
    }
    store::save_json(&path, &ai).map_err(String::from)
}

/// Copies the profile files that an import may overwrite into a timestamped
/// folder next to them.
fn backup_profile(a: &App) -> Result<String, String> {
    let stamp = {
        let now = chrono_like_stamp();
        now
    };
    let dir = a.paths.root.join(format!("backup-{stamp}"));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    for path in [
        a.paths.servers(),
        a.paths.settings(),
        a.paths.rules(),
        a.paths.secrets(),
        a.paths.snippets(),
        a.paths.ai_settings(),
    ] {
        if !path.exists() {
            continue;
        }
        if let Some(name) = path.file_name() {
            std::fs::copy(&path, dir.join(name)).map_err(|e| e.to_string())?;
        }
    }
    Ok(dir.to_string_lossy().to_string())
}

/// `YYYYMMDD-HHMMSS` in local time, without pulling a date crate in.
fn chrono_like_stamp() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86_400;
    let time = secs % 86_400;
    let (year, month, day) = civil_from_days(days as i64);
    format!(
        "{year:04}{month:02}{day:02}-{:02}{:02}{:02}",
        time / 3600,
        (time % 3600) / 60,
        time % 60
    )
}

/// Howard Hinnant's civil-from-days.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Starts a one-shot LAN share and returns the URL for the QR code.
pub fn start_sync_share(include_secrets: bool) -> Result<SyncShare, String> {
    let json = sync_export_json(include_secrets)?;
    let started = crate::sync::start_share(json, std::time::Duration::from_secs(300))?;
    Ok(SyncShare {
        url: started.url,
        ip: started.ip,
        port: started.port as u32,
        token: started.token,
    })
}

pub fn stop_sync_share() {
    crate::sync::stop_share();
}

pub fn sync_share_token() -> Option<String> {
    crate::sync::active_token()
}

/// Imports a payload produced by [`sync_export_json`] on another device.
/// Existing servers are matched by host + port + user and kept as they are.
pub fn import_sync(json: String) -> Result<SyncReport, String> {
    let a = app()?;
    let payload: crate::sync::SyncPayload =
        serde_json::from_str(&json).map_err(|e| format!("Некорректные данные: {e}"))?;
    if payload.version != 1 {
        return Err(format!("Неизвестная версия профиля: {}", payload.version));
    }

    // The running app keeps the book in memory; import into that copy so the
    // UI sees the new servers immediately, then persist it.
    let mut book_guard = a.book.lock().map_err(|_| "lock poisoned")?;
    let book = &mut *book_guard;
    let groups_before = book.groups.len();

    // Groups are matched by name; remember which id each incoming group got so
    // servers keep pointing at the right folder after the merge.
    let mut group_map: HashMap<String, String> = HashMap::new();
    for group in &payload.groups {
        if let Some(existing) = book
            .groups
            .iter()
            .find(|g| g.name.trim().eq_ignore_ascii_case(group.name.trim()))
        {
            group_map.insert(group.id.clone(), existing.id.clone());
        }
    }
    for group in payload.groups {
        if group_map.contains_key(&group.id) {
            continue;
        }
        group_map.insert(group.id.clone(), group.id.clone());
        book.upsert_group(group);
    }

    let mut added_servers = 0u32;
    for mut server in payload.servers {
        let exists = book.servers.iter().any(|s| {
            s.host.eq_ignore_ascii_case(&server.host)
                && s.port == server.port
                && s.user == server.user
        });
        if exists {
            continue;
        }
        if book.servers.iter().any(|s| s.id == server.id) {
            server.id = util::new_id("s");
        }
        if let Some(group_id) = server.group_id.clone() {
            server.group_id = group_map.get(&group_id).cloned();
        }
        book.upsert_server(server);
        added_servers += 1;
    }

    book.validate().map_err(String::from)?;
    persist_book(a, book)?;

    let had_settings = payload.settings.is_some();
    if let Some(settings) = payload.settings {
        store::save_json(&a.paths.settings(), &settings).map_err(String::from)?;
        *a.settings.lock().map_err(|_| "lock poisoned")? = settings;
    }

    let mut imported_secrets = 0u32;
    if let Some(secrets) = payload.secrets {
        let mut vault = a.vault.lock().map_err(|_| "lock poisoned")?;
        if let Some(vault) = vault.as_mut() {
            for (id, value) in secrets {
                if vault.set(&id, &value).is_ok() {
                    imported_secrets += 1;
                }
            }
            vault.save().map_err(String::from)?;
        }
    }

    let snippets_added = merge_snippets(a, payload.snippets)?;
    apply_ai_if_fresh(a, payload.ai)?;

    Ok(SyncReport {
        servers: added_servers,
        groups: (book.groups.len() - groups_before) as u32,
        secrets: imported_secrets,
        settings: had_settings,
        snippets: snippets_added,
    })
}

/// Packs the selected files/folders into an archive.
///
/// `session_id` = Some -> the sources live on that server and the archive is
/// built there by its own `tar`/`zip`/`7z`; None -> local and written by the
/// Rust core. `format` is an extension such as `zip`, `tar.gz` or `7z`; when
/// omitted it is taken from `target_path`.
///
/// Returns the number of files written (remote: the number of sources, since
/// the server does not report a count).
pub fn create_archive(
    session_id: Option<String>,
    sources: Vec<String>,
    target_path: String,
    format: Option<String>,
) -> Result<u32, String> {
    if sources.is_empty() {
        return Err("Нечего упаковывать".into());
    }
    let format = match format.as_deref().filter(|f| !f.trim().is_empty()) {
        Some(value) => crate::archive::ArchiveFormat::parse(value)
            .ok_or_else(|| format!("неизвестный формат архива: {value}"))?,
        None => crate::archive::ArchiveFormat::from_path(&target_path)
            .ok_or_else(|| "Не удалось определить формат архива по имени файла".to_string())?,
    };

    if let Some(session_id) = session_id {
        return pack_remote(&session_id, &sources, &target_path, format);
    }

    let report = crate::archive::create_archive(Some(format), &sources, &target_path)
        .map_err(String::from)?;
    Ok(report.files)
}

/// Runs the server's archive tool over an SSH exec channel.
///
/// The command is built in `archive::remote`, where it is unit-tested; here it
/// only needs a session and a generous timeout: packing a large tree takes
/// minutes, and an interrupted tar leaves a broken file behind.
fn pack_remote(
    session_id: &str,
    sources: &[String],
    target_path: &str,
    format: crate::archive::ArchiveFormat,
) -> Result<u32, String> {
    let a = app()?;
    let session = {
        let sessions = a.sessions.lock().map_err(|_| "lock poisoned")?;
        sessions
            .get(session_id)
            .cloned()
            .ok_or_else(|| "сессия не найдена".to_string())?
    };
    let command = crate::archive::pack_command(format, sources, target_path)
        .map_err(String::from)?;
    let (stdout, stderr, code) = rt()
        .block_on(session.exec_result(&command, std::time::Duration::from_secs(3600)))
        .map_err(|e| e.to_string())?;
    if code != 0 {
        return Err(format!(
            "{}: {}",
            format.label(),
            crate::archive::short_error(&stdout, &stderr)
        ));
    }
    Ok(sources.len() as u32)
}

/// Extracts an archive **on the server** into `target_dir`.
///
/// Local archives are unpacked by [`copy_from_archive`] instead: that path
/// streams entry by entry and reports progress.
pub fn extract_archive(
    session_id: Option<String>,
    archive_path: String,
    inner: String,
    target_dir: String,
) -> Result<(), String> {
    let Some(session_id) = session_id else {
        return Err("локальные архивы распаковываются копированием".into());
    };
    let format = crate::archive::ArchiveFormat::from_path(&archive_path)
        .ok_or_else(|| format!("формат не поддерживается: {archive_path}"))?;
    let a = app()?;
    let session = {
        let sessions = a.sessions.lock().map_err(|_| "lock poisoned")?;
        sessions
            .get(&session_id)
            .cloned()
            .ok_or_else(|| "сессия не найдена".to_string())?
    };
    let command = crate::archive::extract_command(
        format,
        &archive_path,
        &inner,
        &target_dir,
        None,
    )
    .map_err(String::from)?;
    let (stdout, stderr, code) = rt()
        .block_on(session.exec_result(&command, std::time::Duration::from_secs(3600)))
        .map_err(|e| e.to_string())?;
    if code != 0 {
        return Err(crate::archive::short_error(&stdout, &stderr));
    }
    Ok(())
}

/// Copies files from a panel into a local archive ("в архив").
///
/// Archives are mostly append-hostile (compressed TAR and 7z cannot grow in
/// place), so the operation is a rewrite: the archive is unpacked into a
/// temporary folder, the new files are added there, and the archive is built
/// again. That keeps one code path for every format and never leaves a
/// half-written archive under the real name.
///
/// `session_id` = Some -> the sources are on the server and are downloaded
/// first. `inner` is the folder inside the archive that receives them; empty
/// means the root.
pub fn copy_to_archive(
    session_id: Option<String>,
    sources: Vec<String>,
    archive_path: String,
    inner: String,
    format: Option<String>,
) -> Result<u32, String> {
    if sources.is_empty() {
        return Err("Нечего копировать".into());
    }
    let a = app()?;
    let remote = session_id.is_some();
    let provider = provider_for(a, session_id)?;

    let format = match format.as_deref().filter(|f| !f.trim().is_empty()) {
        Some(value) => crate::archive::ArchiveFormat::parse(value)
            .ok_or_else(|| format!("неизвестный формат архива: {value}"))?,
        None => crate::archive::ArchiveFormat::from_path(&archive_path)
            .ok_or_else(|| "Не удалось определить формат архива по имени файла".to_string())?,
    };
    if format.is_single() {
        return Err(format!("{} не поддерживает добавление файлов", format.label()));
    }

    let stem = util::file_name(&archive_path).to_string();
    let work = a
        .paths
        .tmp_dir()
        .join(format!("add-{}", util::new_id("arc")));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work).map_err(|e| e.to_string())?;

    let result = (|| -> Result<u32, String> {
        let existing = if std::path::Path::new(&archive_path).exists() {
            // Rewriting an encrypted archive would silently drop the
            // encryption, and appending would store new entries in clear.
            if crate::archive::is_encrypted(&archive_path) {
                return Err("В зашифрованный архив добавлять нельзя".into());
            }
            Some(open_archive(&archive_path)?)
        } else {
            None
        };
        let inner = inner.trim_matches('/').to_string();

        // ZIP and plain TAR can grow in place. When a name is already taken
        // (or the format cannot append) fall back to the full rewrite below.
        let mut appendable = existing.is_some();
        if !matches!(
            format,
            crate::archive::ArchiveFormat::Zip | crate::archive::ArchiveFormat::Tar
        ) {
            appendable = false;
        }
        if let (true, Some(archive)) = (appendable, existing.as_ref()) {
            for source in &sources {
                let name = util::file_name(source);
                let rel = if inner.is_empty() {
                    name.to_string()
                } else {
                    format!("{inner}/{name}")
                };
                if archive.index.node(&rel).is_some() {
                    appendable = false;
                    break;
                }
            }
        }

        // 1. Existing content, but only when the archive has to be rebuilt.
        if !appendable {
            if let Some(archive) = existing.as_ref() {
                // Empty folders are not in `files_under`; keep them too.
                for dir in archive.index.all_dirs() {
                    if let Some(dest) = util::join_relative(&work.to_string_lossy(), &dir) {
                        let _ = std::fs::create_dir_all(dest);
                    }
                }
                for file in archive.files_under("") {
                    let Some(dest) = util::join_relative(&work.to_string_lossy(), &file) else {
                        continue;
                    };
                    if let Some(parent) = util::parent(&dest) {
                        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                    }
                    let mut out = std::fs::File::create(&dest).map_err(|e| e.to_string())?;
                    archive
                        .with_entry(&file, |reader| {
                            std::io::copy(reader, &mut out)
                                .map(|_| ())
                                .map_err(crate::error::NovaError::from)
                        })
                        .map_err(String::from)?;
                }
            }
        }

        // 2. New files, under `inner`.
        let mut copied = 0u32;
        for source in &sources {
            let name = util::file_name(source).to_string();
            let rel = if inner.is_empty() {
                name.clone()
            } else {
                format!("{inner}/{name}")
            };
            let Some(dest) = util::join_relative(&work.to_string_lossy(), &rel) else {
                return Err(format!("Недопустимое имя: {name}"));
            };
            copied += copy_into_folder(&provider, source, &dest, remote)?;
        }

        let children: Vec<String> = std::fs::read_dir(&work)
            .map_err(|e| e.to_string())?
            .flatten()
            .map(|entry| entry.path().to_string_lossy().to_string())
            .collect();
        if children.is_empty() {
            return Err("Нечего сохранять".into());
        }

        // 3a. Append in place when possible; 3b. otherwise rebuild.
        if appendable {
            crate::archive::append_archive(format, &archive_path, &children)
                .map(|_| copied)
                .map_err(String::from)
        } else {
            crate::archive::create_archive(Some(format), &children, &archive_path)
                .map(|_| copied)
                .map_err(String::from)
        }
    })();

    let _ = std::fs::remove_dir_all(&work);
    result.map_err(|e| format!("{stem}: {e}"))
}

/// Copies one file or folder into `dest`. Remote sources are downloaded
/// through the provider; local ones are copied with the filesystem API.
fn copy_into_folder(
    provider: &crate::fs::Provider,
    source: &str,
    dest: &str,
    remote: bool,
) -> Result<u32, String> {
    if !remote {
        let meta = std::fs::symlink_metadata(source).map_err(|e| format!("{source}: {e}"))?;
        if meta.is_symlink() {
            return Ok(0);
        }
        if meta.is_dir() {
            std::fs::create_dir_all(dest).map_err(|e| e.to_string())?;
            let mut copied = 0;
            for child in std::fs::read_dir(source)
                .map_err(|e| e.to_string())?
                .flatten()
            {
                let name = child.file_name().to_string_lossy().to_string();
                copied += copy_into_folder(
                    provider,
                    &child.path().to_string_lossy(),
                    &util::join(dest, &name),
                    false,
                )?;
            }
            return Ok(copied);
        }
        std::fs::copy(source, dest).map_err(|e| format!("{source}: {e}"))?;
        return Ok(1);
    }

    // Iterative walk: a deep server tree must not blow the stack.
    let mut copied = 0u32;
    let mut stack = vec![(source.to_string(), dest.to_string())];
    while let Some((path, target)) = stack.pop() {
        let entry = rt()
            .block_on(provider.stat(&path))
            .map_err(|e| format!("{path}: {e}"))?;
        if entry.kind == EntryKind::Dir {
            std::fs::create_dir_all(&target).map_err(|e| e.to_string())?;
            let listing = rt()
                .block_on(provider.list(&path, true))
                .map_err(|e| format!("{path}: {e}"))?;
            for child in listing.entries {
                if child.name == "." || child.name == ".." {
                    continue;
                }
                stack.push((child.path.clone(), util::join(&target, &child.name)));
            }
            continue;
        }
        download_file(provider, &path, &target)?;
        copied += 1;
    }
    Ok(copied)
}

fn download_file(
    provider: &crate::fs::Provider,
    remote: &str,
    local: &str,
) -> Result<(), String> {
    use std::io::Write as _;
    use tokio::io::AsyncReadExt;

    if let Some(parent) = util::parent(local) {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let mut reader = rt()
        .block_on(provider.open_read(remote, 0))
        .map_err(|e| format!("{remote}: {e}"))?;
    let mut file = std::fs::File::create(local).map_err(|e| format!("{local}: {e}"))?;
    let mut chunk = vec![0u8; 256 * 1024];
    loop {
        let read = rt()
            .block_on(reader.read(&mut chunk))
            .map_err(|e| format!("{remote}: {e}"))?;
        if read == 0 {
            break;
        }
        file.write_all(&chunk[..read]).map_err(|e| e.to_string())?;
    }
    file.flush().map_err(|e| e.to_string())?;
    Ok(())
}

/// Joins multi-volume parts (`x.7z.001`, `x.part1.rar`, `x.z01` + `x.zip`)
/// into one file next to the first part. Returns the joined path.
pub fn assemble_volumes(
    session_id: Option<String>,
    parts: Vec<String>,
    target_path: Option<String>,
) -> Result<String, String> {
    let set = crate::archive::detect_volumes(&parts)
        .ok_or_else(|| "Выбранные файлы не похожи на части одного архива".to_string())?;
    let target = match target_path.filter(|path| !path.trim().is_empty()) {
        Some(path) => path,
        None => {
            let parent = util::parent(&set.parts[0]).unwrap_or_else(|| "/".to_string());
            util::join(&parent, &set.target_name)
        }
    };

    let Some(session_id) = session_id else {
        if std::path::Path::new(&target).exists() {
            return Err(format!("{target} уже существует"));
        }
        crate::archive::assemble_local(&set.parts, &target).map_err(String::from)?;
        return Ok(target);
    };

    let a = app()?;
    let session = {
        let sessions = a.sessions.lock().map_err(|_| "lock poisoned")?;
        sessions
            .get(&session_id)
            .cloned()
            .ok_or_else(|| "сессия не найдена".to_string())?
    };
    let exists = rt()
        .block_on(session.exec_result(
            &format!("test -e {} && echo yes", util::shell_escape(&target)),
            std::time::Duration::from_secs(20),
        ))
        .map(|(stdout, _, _)| stdout.contains("yes"))
        .unwrap_or(false);
    if exists {
        return Err(format!("{target} уже существует"));
    }
    let command = crate::archive::assemble_command(&set.parts, &target);
    let (stdout, stderr, code) = rt()
        .block_on(session.exec_result(&command, std::time::Duration::from_secs(3600)))
        .map_err(|e| e.to_string())?;
    if code != 0 {
        return Err(crate::archive::short_error(&stdout, &stderr));
    }
    Ok(target)
}

// ---------------------------------------------------------------------------
// Unpacking a server archive without downloading it
// ---------------------------------------------------------------------------

struct ArchiveJob {
    cancel: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

fn archive_jobs() -> &'static std::sync::Mutex<std::collections::HashMap<String, ArchiveJob>> {
    static JOBS: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<String, ArchiveJob>>,
    > = std::sync::OnceLock::new();
    JOBS.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

/// Directories Nova created on a server for extracted archives, per session.
fn remote_tmp_dirs() -> &'static std::sync::Mutex<std::collections::HashMap<String, Vec<String>>>
{
    static DIRS: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<String, Vec<String>>>,
    > = std::sync::OnceLock::new();
    DIRS.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

async fn wait_job_cancel(flag: &std::sync::atomic::AtomicBool) {
    use std::sync::atomic::Ordering;
    while !flag.load(Ordering::SeqCst) {
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
}

/// Stops a running [`unpack_server_archive`] job.
pub fn cancel_archive_job(job_id: String) -> Result<(), String> {
    if let Ok(jobs) = archive_jobs().lock() {
        if let Some(job) = jobs.get(&job_id) {
            job.cancel.store(true, std::sync::atomic::Ordering::SeqCst);
        }
    }
    Ok(())
}

/// Extracts an archive **on the server** and returns the folder in the final
/// event's `message`. Empty `target_dir` means a fresh `/tmp/novassh_*` folder.
///
/// Emits `Running`, then exactly one of `Done` / `Failed` / `Cancelled`.
/// Cancelling kills the tool process (its PID is recorded before `exec`).
pub fn unpack_server_archive(
    session_id: String,
    archive_path: String,
    inner: String,
    target_dir: String,
    password: Option<String>,
    sink: StreamSink<TransferEvent>,
) -> Result<(), String> {
    use std::sync::atomic::AtomicBool;

    let a = app()?;
    let session = {
        let sessions = a.sessions.lock().map_err(|_| "lock poisoned")?;
        sessions
            .get(&session_id)
            .cloned()
            .ok_or_else(|| "сессия не найдена".to_string())?
    };
    let format = crate::archive::format_for(&archive_path).map_err(|e| e.to_string())?;

    let job_id = util::new_id("arc");
    let suffix = job_id.trim_start_matches("arc_");
    let target = if target_dir.trim().is_empty() {
        format!("/tmp/novassh_{suffix}")
    } else {
        target_dir.trim_end_matches('/').to_string()
    };
    let pidfile = format!("/tmp/.novassh_{suffix}.pid");
    let cancel = std::sync::Arc::new(AtomicBool::new(false));
    if let Ok(mut jobs) = archive_jobs().lock() {
        jobs.insert(
            job_id.clone(),
            ArchiveJob {
                cancel: cancel.clone(),
            },
        );
    }

    let name = util::file_name(&archive_path).to_string();
    let emit = |sink: &StreamSink<TransferEvent>, state: TransferState, message: Option<String>| {
        let _ = sink.add(TransferEvent {
            id: job_id.clone(),
            name: name.clone(),
            total: 0,
            done: 0,
            state,
            message,
        });
    };
    emit(
        &sink,
        TransferState::Running,
        Some("Распаковка на сервере…".into()),
    );

    // The shell records its PID and is then replaced by the tool, so killing
    // that PID stops the extraction itself.
    let tool = crate::archive::extract_tool_command(
        format,
        &archive_path,
        &inner,
        &target,
        password.as_deref(),
    )
    .map_err(String::from)?;
    // `</dev/null`: an encrypted archive must fail, not wait for a password
    // typed into a channel that will never send one.
    let command = format!(
        "mkdir -p {dir} && echo $$ > {pid} && exec {tool} </dev/null",
        dir = util::shell_escape(&target),
        pid = util::shell_escape(&pidfile),
    );

    let result = rt().block_on(async {
        tokio::select! {
            result = session.exec_result(&command, std::time::Duration::from_secs(6 * 3600)) => {
                result.map_err(|e| e.to_string())
            }
            _ = wait_job_cancel(&cancel) => Err("__cancelled__".to_string()),
        }
    });

    let outcome = match result {
        Ok((_stdout, _stderr, 0)) => {
            let _ = rt().block_on(session.exec_result(
                &format!("rm -f {}", util::shell_escape(&pidfile)),
                std::time::Duration::from_secs(10),
            ));
            if let Ok(mut dirs) = remote_tmp_dirs().lock() {
                dirs.entry(session_id.clone())
                    .or_default()
                    .push(target.clone());
            }
            emit(&sink, TransferState::Done, Some(target));
            Ok(())
        }
        Ok((stdout, stderr, _)) => {
            let message = crate::archive::short_error(&stdout, &stderr);
            // A failed extraction may have left half a tree behind; a retry
            // with a password uses a new folder anyway.
            let _ = rt().block_on(session.exec_result(
                &format!("rm -rf {}", util::shell_escape(&target)),
                std::time::Duration::from_secs(20),
            ));
            emit(&sink, TransferState::Failed, Some(message));
            Ok(())
        }
        Err(error) if error == "__cancelled__" => {
            let kill = format!(
                concat!(
                    "kill -TERM $(cat {pid} 2>/dev/null) 2>/dev/null; sleep 1; ",
                    "kill -9 $(cat {pid} 2>/dev/null) 2>/dev/null; ",
                    "rm -f {pid}; rm -rf {dir}"
                ),
                pid = util::shell_escape(&pidfile),
                dir = util::shell_escape(&target),
            );
            let _ = rt()
                .block_on(session.exec_result(&kill, std::time::Duration::from_secs(20)));
            emit(
                &sink,
                TransferState::Cancelled,
                Some("Распаковка отменена".into()),
            );
            Ok(())
        }
        Err(error) => {
            emit(&sink, TransferState::Failed, Some(error));
            Ok(())
        }
    };

    if let Ok(mut jobs) = archive_jobs().lock() {
        jobs.remove(&job_id);
    }
    outcome
}

/// Collects files below `root` as `relative path -> entry`.
fn walk_files(
    provider: &crate::fs::Provider,
    root: &str,
    out: &mut std::collections::HashMap<String, Entry>,
    limit: usize,
) {
    let mut stack = vec![root.to_string()];
    let mut depth_guard = 0usize;
    while let Some(dir) = stack.pop() {
        if out.len() >= limit || depth_guard > 20_000 {
            break;
        }
        let listing = match rt().block_on(provider.list(&dir, true)) {
            Ok(listing) => listing,
            Err(_) => continue,
        };
        depth_guard += listing.entries.len();
        for entry in listing.entries {
            if entry.kind == EntryKind::Dir {
                stack.push(entry.path.clone());
                continue;
            }
            let relative = if dir == root {
                entry.name.clone()
            } else {
                let prefix = dir.strip_prefix(root).unwrap_or(&dir).trim_start_matches('/');
                format!("{prefix}/{}", entry.name)
            };
            out.insert(relative, entry);
        }
    }
}

/// Compares both trees and proposes upload/download actions per file.
///
/// `mode`: "upload" mirrors local -> remote, "download" mirrors remote -> local,
/// "newer" copies whichever side is newer (two-way sync).
pub fn sync_scan(
    session_id: String,
    local_root: String,
    remote_root: String,
    mode: String,
    max_files: u32,
) -> Result<Vec<SyncEntry>, String> {
    let a = app()?;
    let local = crate::fs::Provider::local();
    let remote = provider_remote(a, &session_id)?;
    let limit = max_files.clamp(1, 20_000) as usize;

    let mut local_files = std::collections::HashMap::new();
    let mut remote_files = std::collections::HashMap::new();
    walk_files(&local, &local_root, &mut local_files, limit);
    walk_files(&remote, &remote_root, &mut remote_files, limit);

    let mut paths: Vec<String> = local_files
        .keys()
        .chain(remote_files.keys())
        .cloned()
        .collect();
    paths.sort();
    paths.dedup();

    let mut out = Vec::new();
    for relative in paths {
        let l = local_files.get(&relative);
        let r = remote_files.get(&relative);
        let join = |root: &str, rel: &str| -> String {
            if root.ends_with('/') {
                format!("{root}{rel}")
            } else {
                format!("{root}/{rel}")
            }
        };
        let local_path = join(&local_root, &relative);
        let remote_path = join(&remote_root, &relative);
        let local_size = l.map(|e| e.size).unwrap_or(0);
        let remote_size = r.map(|e| e.size).unwrap_or(0);
        let local_modified = l.and_then(|e| e.modified);
        let remote_modified = r.and_then(|e| e.modified);

        let newer_local = match (local_modified, remote_modified) {
            (Some(a), Some(b)) => a > b + 1000,
            _ => local_size != remote_size,
        };
        let close_in_time = match (local_modified, remote_modified) {
            (Some(a), Some(b)) => (a - b).abs() <= 2000,
            _ => true,
        };
        let identical =
            l.is_some() && r.is_some() && local_size == remote_size && close_in_time;

        let (action, reason) = match (l.is_some(), r.is_some()) {
            (true, false) => match mode.as_str() {
                "download" => ("skip", "только локально"),
                _ => ("upload", "только локально"),
            },
            (false, true) => match mode.as_str() {
                "upload" => ("skip", "только на сервере"),
                _ => ("download", "только на сервере"),
            },
            _ => {
                if identical {
                    ("skip", "совпадает")
                } else {
                    match mode.as_str() {
                        "upload" => ("upload", "отличается"),
                        "download" => ("download", "отличается"),
                        _ => {
                            if newer_local {
                                ("upload", "новее локально")
                            } else {
                                ("download", "новее на сервере")
                            }
                        }
                    }
                }
            }
        };

        out.push(SyncEntry {
            relative,
            action: action.into(),
            reason: reason.into(),
            size: if action == "download" { remote_size } else { local_size },
            local_path,
            remote_path,
            local_size,
            remote_size,
            local_modified,
            remote_modified,
        });
    }
    Ok(out)
}

/// SHA-256 of a file by streaming it through the digest (any transport).
async fn hash_side(provider: &crate::fs::Provider, path: &str) -> Result<String, String> {
    use tokio::io::AsyncReadExt;
    let mut reader = provider
        .open_read(path, 0)
        .await
        .map_err(|e| e.to_string())?;
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let read = reader.read(&mut buf).await.map_err(|e| e.to_string())?;
        if read == 0 {
            break;
        }
        ctx.update(&buf[..read]);
    }
    Ok(ctx
        .finish()
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

/// Asks the server for a checksum (`sha256sum` / `md5sum`) when possible.
fn remote_checksum(session_id: &str, path: &str, algorithm: &str) -> Option<String> {
    let command = match algorithm {
        "md5" => format!("md5sum -- '{}'", path.replace('\'', "'\\''")),
        _ => format!("sha256sum -- '{}'", path.replace('\'', "'\\''")),
    };
    let output = exec_remote(session_id.to_string(), command).ok()?;
    let token = output.split_whitespace().next()?.to_lowercase();
    let expected = if algorithm == "md5" { 32 } else { 64 };
    if token.len() == expected && token.chars().all(|c| c.is_ascii_hexdigit()) {
        Some(token)
    } else {
        None
    }
}

/// SHA-256 or MD5 of a file: computed by the server when it can, otherwise by
/// streaming the file through the digest locally.
pub fn checksum(
    session_id: Option<String>,
    path: String,
    algorithm: String,
) -> Result<FileChecksum, String> {
    use tokio::io::AsyncReadExt;

    let a = app()?;
    let algo = if algorithm.eq_ignore_ascii_case("md5") {
        "md5"
    } else {
        "sha256"
    };

    if let Some(id) = &session_id {
        if let Some(hash) = remote_checksum(id, &path, algo) {
            let size = provider_for(a, Some(id.clone()))
                .ok()
                .and_then(|p| rt().block_on(p.stat(&path)).ok())
                .map(|e| e.size)
                .unwrap_or(0);
            return Ok(FileChecksum {
                algorithm: algo.to_string(),
                hash,
                size,
                computed_by: "server".into(),
            });
        }
    }

    let provider = provider_for(a, session_id)?;
    let size = rt()
        .block_on(provider.stat(&path))
        .map(|e| e.size)
        .unwrap_or(0);
    let mut reader = rt()
        .block_on(provider.open_read(&path, 0))
        .map_err(|e| e.to_string())?;

    let hash = if algo == "md5" {
        use md5::Digest as _;
        let mut hasher = md5::Md5::new();
        let mut chunk = vec![0u8; 64 * 1024];
        loop {
            let read = rt()
                .block_on(reader.read(&mut chunk))
                .map_err(|e| e.to_string())?;
            if read == 0 {
                break;
            }
            hasher.update(&chunk[..read]);
        }
        hasher
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
    } else {
        let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
        let mut chunk = vec![0u8; 64 * 1024];
        loop {
            let read = rt()
                .block_on(reader.read(&mut chunk))
                .map_err(|e| e.to_string())?;
            if read == 0 {
                break;
            }
            ctx.update(&chunk[..read]);
        }
        ctx.finish()
            .as_ref()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
    };
    Ok(FileChecksum {
        algorithm: algo.to_string(),
        hash,
        size,
        computed_by: "local".into(),
    })
}

/// Recursive file search: by name mask and optionally by file contents.
pub fn find_files(
    session_id: Option<String>,
    root: String,
    mask: String,
    content: Option<String>,
    max_results: u32,
) -> Result<Vec<FoundFile>, String> {
    use tokio::io::AsyncReadExt;

    let a = app()?;
    let provider = provider_for(a, session_id)?;
    let needle = content
        .map(|c| c.trim().to_lowercase())
        .filter(|c| !c.is_empty());
    let limit = max_results.clamp(1, 5_000) as usize;

    let mut results: Vec<FoundFile> = Vec::new();
    let mut stack = vec![root];
    let mut visited = 0usize;

    while let Some(dir) = stack.pop() {
        if results.len() >= limit || visited > 50_000 {
            break;
        }
        let listing = match rt().block_on(provider.list(&dir, true)) {
            Ok(listing) => listing,
            Err(_) => continue, // unreadable folders are skipped
        };
        visited += listing.entries.len();
        for entry in listing.entries {
            if entry.kind == EntryKind::Dir {
                stack.push(entry.path.clone());
                continue;
            }
            if !glob_match(&mask, &entry.name) {
                continue;
            }
            let mut matches = 0u32;
            if let Some(needle) = &needle {
                if entry.size <= 4 * 1024 * 1024 {
                    let bytes = rt().block_on(async {
                        let mut reader = provider.open_read(&entry.path, 0).await.ok()?;
                        let mut buf = Vec::new();
                        reader.read_to_end(&mut buf).await.ok()?;
                        Some(buf)
                    });
                    if let Some(bytes) = bytes {
                        let text = String::from_utf8_lossy(&bytes).to_lowercase();
                        matches = text.matches(needle.as_str()).count() as u32;
                    }
                }
                if matches == 0 {
                    continue;
                }
            }
            results.push(FoundFile {
                path: entry.path,
                name: entry.name,
                size: entry.size,
                modified: entry.modified,
                is_dir: false,
                matches,
            });
            if results.len() >= limit {
                break;
            }
        }
    }

    results.sort_by(|a, b| a.path.to_lowercase().cmp(&b.path.to_lowercase()));
    Ok(results)
}

/// Changes permission bits (chmod), optionally for a whole folder tree.
/// Returns how many entries were updated.
pub fn chmod(
    session_id: Option<String>,
    path: String,
    mode: u32,
    recursive: bool,
) -> Result<u32, String> {
    let a = app()?;
    let provider = provider_for(a, session_id)?;
    let mode = mode & 0o7777;

    let mut queue = vec![path];
    let mut updated: u32 = 0;
    while let Some(current) = queue.pop() {
        let entry = rt()
            .block_on(provider.stat(&current))
            .map_err(|e| format!("{current}: {e}"))?;
        rt().block_on(provider.set_mode(&current, mode))
            .map_err(|e| format!("{current}: {e}"))?;
        updated += 1;
        if recursive && entry.kind == EntryKind::Dir {
            let listing = rt()
                .block_on(provider.list(&current, true))
                .map_err(|e| format!("{current}: {e}"))?;
            for child in listing.entries {
                if child.name == "." || child.name == ".." {
                    continue;
                }
                queue.push(child.path);
            }
        }
    }
    Ok(updated)
}

/// Compares two files that may live on different transports (local, SFTP, FTP,
/// S3) or inside a local archive.
pub fn compare_files(
    left: FileRef,
    right: FileRef,
    options: CompareOptions,
) -> Result<CompareResult, String> {
    let a = app()?;
    let max = options
        .max_bytes
        .map(u64::from)
        .unwrap_or(8 * 1024 * 1024)
        .clamp(64 * 1024, 64 * 1024 * 1024);

    let (left_bytes, left_size, left_truncated) = read_ref(a, &left, max)?;
    let (right_bytes, right_size, right_truncated) = read_ref(a, &right, max)?;

    let opts = crate::diff::Options {
        ignore_whitespace: options.ignore_whitespace,
        ignore_case: options.ignore_case,
    };
    let mut result = crate::diff::compare(&left_bytes, &right_bytes, &opts);

    let name = |src: &FileRef| -> String {
        src.label
            .clone()
            .filter(|l| !l.trim().is_empty())
            .unwrap_or_else(|| util::file_name(&src.path).to_string())
    };
    result.left_label = name(&left);
    result.right_label = name(&right);
    result.left_size = if left_size > 0 {
        left_size
    } else {
        left_bytes.len() as u64
    };
    result.right_size = if right_size > 0 {
        right_size
    } else {
        right_bytes.len() as u64
    };
    result.truncated |= left_truncated || right_truncated;

    let left_meta = crate::diff::text_meta(&left_bytes, left.archive_path.is_some());
    let right_meta = crate::diff::text_meta(&right_bytes, right.archive_path.is_some());
    result.left_eol = left_meta.eol;
    result.right_eol = right_meta.eol;
    result.left_bom = left_meta.bom;
    result.right_bom = right_meta.bom;
    result.left_final_newline = left_meta.final_newline;
    result.right_final_newline = right_meta.final_newline;
    result.left_read_only = left_meta.read_only;
    result.right_read_only = right_meta.read_only;

    if result.binary {
        result.left_hash = Some(sha256_hex(&left_bytes));
        result.right_hash = Some(sha256_hex(&right_bytes));
    }
    Ok(result)
}

/// Diffs two in-memory texts (used after editing inside the compare window).
pub fn compare_text(
    left: String,
    right: String,
    options: CompareOptions,
) -> CompareResult {
    let opts = crate::diff::Options {
        ignore_whitespace: options.ignore_whitespace,
        ignore_case: options.ignore_case,
    };
    let mut result = crate::diff::compare(left.as_bytes(), right.as_bytes(), &opts);
    result.left_size = left.len() as u64;
    result.right_size = right.len() as u64;
    result
}

/// Writes an edited text back to its source (local, SFTP, FTP or S3).
pub fn save_text(file: FileRef, text: String) -> Result<(), String> {
    use tokio::io::AsyncWriteExt;

    let a = app()?;
    if file.archive_path.is_some() {
        return Err("Файл внутри архива — сохранение недоступно".into());
    }
    let provider = provider_for(a, file.session_id.clone())?;
    let bytes = text.into_bytes();

    match &provider {
        crate::fs::Provider::Local(_) | crate::fs::Provider::Sftp(_) => {
            let mut writer = rt()
                .block_on(provider.open_write(&file.path, false))
                .map_err(|e| e.to_string())?;
            rt().block_on(async {
                writer.write_all(&bytes).await?;
                writer.flush().await
            })
            .map_err(|e| e.to_string())?;
        }
        crate::fs::Provider::Ftp(fs) => rt()
            .block_on(fs.write_all(&file.path, &bytes))
            .map_err(|e| e.to_string())?,
        crate::fs::Provider::S3(fs) => rt()
            .block_on(fs.write_all(&file.path, &bytes))
            .map_err(|e| e.to_string())?,
        crate::fs::Provider::Archive(_) => {
            return Err("Файл внутри архива — сохранение недоступно".into());
        }
    }
    Ok(())
}

/// Copies a file or a whole folder out of an archive into the target panel
/// (`session_id` = Some -> remote, None -> local).
pub fn copy_from_archive(
    session_id: Option<String>,
    archive_path: String,
    inner: String,
    target_dir: String,
    sink: StreamSink<TransferEvent>,
) -> Result<(), String> {
    let a = app()?;
    let target = provider_for(a, session_id)?;
    let archive = open_archive(&archive_path)?;

    let inner_norm = inner.trim_matches('/').to_string();
    // Empty inner means "the whole archive": extract it into a folder named
    // after the archive file itself.
    let whole_archive = inner_norm.is_empty();
    let root_is_dir = if whole_archive {
        true
    } else {
        archive
            .stat(&inner_norm)
            .map(|e| e.kind == EntryKind::Dir)
            .map_err(String::from)?
    };

    let files = archive.files_under(&inner_norm);
    if files.is_empty() && archive.index.all_dirs().is_empty() {
        return Err("в архиве нет файлов для копирования".into());
    }

    let base_name = {
        let raw = if whole_archive {
            archive_folder_name(&archive_path)
        } else {
            util::file_name(&inner_norm).to_string()
        };
        // A hostile archive name ("..zip") must not pick the folder outside.
        if util::is_safe_component(&raw) {
            raw
        } else {
            "archive".to_string()
        }
    };
    let total: u64 = files
        .iter()
        .filter_map(|f| archive.stat(f).ok().map(|e| e.size))
        .sum();

    let event_id = util::new_id("arc");
    let label = if root_is_dir {
        base_name.clone()
    } else {
        util::file_name(&inner_norm).to_string()
    };
    let _ = &label;

    let _ = sink.add(TransferEvent {
        id: event_id.clone(),
        name: label.clone(),
        total,
        done: 0,
        state: TransferState::Running,
        message: None,
    });

    let target_dir = target_dir.trim_end_matches('/').to_string();
    rt().spawn(async move {
        use tokio::io::AsyncWriteExt;

        let mut done = 0u64;
        let mut last_emit = 0u64;
        let mut failure: Option<String> = None;
        let mut skipped = 0u64;
        let root_dir = util::join(&target_dir, &base_name);

        // Folders exist in the index even when they hold no files, so create
        // them up front instead of only their parents. Sorted parents-first.
        if root_is_dir {
            let _ = target.mkdir(&root_dir).await;
        }
        let mut dir_meta: Vec<(String, Option<u32>, Option<i64>)> = Vec::new();
        if root_is_dir {
            for dir in archive.index.all_dirs() {
                if !inner_norm.is_empty()
                    && dir != inner_norm
                    && !dir.starts_with(&format!("{inner_norm}/"))
                {
                    continue;
                }
                let rel = dir
                    .strip_prefix(&inner_norm)
                    .unwrap_or(&dir)
                    .trim_start_matches('/');
                if rel.is_empty() {
                    continue;
                }
                let Some(dest) = util::join_relative(&root_dir, rel) else {
                    continue;
                };
                if target.mkdir(&dest).await.is_ok() {
                    let node = archive.index.node(&dir);
                    dir_meta.push((
                        dest,
                        node.and_then(|n| n.mode),
                        node.and_then(|n| n.modified_ms),
                    ));
                }
            }
        }

        for file in files {
            let rel = file
                .strip_prefix(&inner_norm)
                .unwrap_or(&file)
                .trim_start_matches('/')
                .to_string();

            // Entry names inside a ZIP are untrusted: "../../x" must never
            // resolve outside the extraction folder.
            let dest = match archive_entry_dest(&root_dir, &target_dir, root_is_dir, &file, &rel)
            {
                Some(dest) => dest,
                None => {
                    skipped += 1;
                    continue;
                }
            };

            // Create the destination directory chain first: mkdir is not
            // recursive, so `a/b/c.txt` needs `a` and `a/b` explicitly.
            let mut dirs: Vec<String> = Vec::new();
            let mut cursor = util::parent(&dest);
            while let Some(dir) = cursor {
                if dir == target_dir || dir == root_dir {
                    dirs.push(dir);
                    break;
                }
                cursor = util::parent(&dir);
                dirs.push(dir);
            }
            for dir in dirs.iter().rev() {
                let _ = target.mkdir(dir).await;
            }

            // Stream the entry through a bounded channel: the archive decoder
            // is synchronous, the provider is async, and reading a 4 GB member
            // into RAM just to write it out again is not an option.
            let mut entry_failed: Option<String> = None;
            {
                let (tx, mut rx) = tokio::sync::mpsc::channel::<Result<Vec<u8>, String>>(4);
                let source = archive.clone();
                let entry_path = file.clone();
                let producer = tokio::task::spawn_blocking(move || {
                    let sent = source.with_entry(&entry_path, |reader| {
                        let mut buf = vec![0u8; 256 * 1024];
                        loop {
                            let read = reader.read(&mut buf).map_err(|e| {
                                crate::error::NovaError::Invalid(format!(
                                    "cannot read {entry_path}: {e}"
                                ))
                            })?;
                            if read == 0 {
                                break;
                            }
                            if tx.blocking_send(Ok(buf[..read].to_vec())).is_err() {
                                break;
                            }
                        }
                        Ok(())
                    });
                    if let Err(e) = sent {
                        let _ = tx.blocking_send(Err(e.to_string()));
                    }
                });

                let write = async {
                    let mut writer = target.open_write(&dest, false).await?;
                    while let Some(chunk) = rx.recv().await {
                        let chunk = chunk.map_err(crate::error::NovaError::Invalid)?;
                        writer.write_all(&chunk).await?;
                        done += chunk.len() as u64;
                        if done - last_emit >= 512 * 1024 || done == total {
                            last_emit = done;
                            let _ = sink.add(TransferEvent {
                                id: event_id.clone(),
                                name: label.clone(),
                                total,
                                done,
                                state: TransferState::Running,
                                message: None,
                            });
                        }
                    }
                    writer.flush().await?;
                    Ok::<(), crate::error::NovaError>(())
                }
                .await;
                let _ = producer.await;

                if let Err(e) = write {
                    entry_failed = Some(format!("{}: {e}", util::file_name(&file)));
                }
            }

            if let Some(msg) = entry_failed {
                failure = Some(msg);
                break;
            }

            // ZIP and TAR store the unix mode and mtime; restore them so an
            // extracted script keeps its +x bit and dates.
            if let Some(node) = archive.index.node(&file) {
                if let Some(mode) = node.mode.filter(|mode| mode & 0o777 != 0) {
                    let _ = target.set_mode(&dest, mode).await;
                }
                if let Some(modified) = node.modified_ms {
                    let _ = target.set_times(&dest, modified).await;
                }
            }
        }

        // Directory timestamps last: writing files above changes them.
        for (dir, mode, modified) in dir_meta.iter().rev() {
            if let Some(mode) = mode {
                if *mode & 0o777 != 0 {
                    let _ = target.set_mode(dir, *mode).await;
                }
            }
            if let Some(modified) = modified {
                let _ = target.set_times(dir, *modified).await;
            }
        }

        let state = if failure.is_some() {
            TransferState::Failed
        } else {
            TransferState::Done
        };
        let message = match (failure, skipped) {
            (None, 0) => None,
            (None, n) => Some(format!("пропущено записей с недопустимыми именами: {n}")),
            (Some(msg), 0) => Some(msg),
            (Some(msg), n) => Some(format!(
                "{msg}; пропущено записей с недопустимыми именами: {n}"
            )),
        };
        let _ = sink.add(TransferEvent {
            id: event_id,
            name: label,
            total,
            done,
            state,
            message,
        });
    });

    Ok(())
}

// ---------------------------------------------------------------------------
// WinSCP import
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct WinscpImportReport {
    pub sessions: u32,
    pub imported: u32,
    pub skipped: u32,
    pub groups: u32,
    pub passwords: u32,
    pub errors: Vec<String>,
}

pub fn import_winscp(ini_path: String) -> Result<WinscpImportReport, String> {
    let a = app()?;
    // Unconditional trace: proves the import was reached and where it stopped.
    let trace = |msg: String| {
        let line = format!("[{}] {msg}
", util::now_ms());
        let dir = a.paths.root.clone();
        let _ = std::fs::create_dir_all(&dir);
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join("import-debug.txt"))
        {
            let _ = f.write_all(line.as_bytes());
        }
    };
    trace(format!("start, ini={ini_path}"));

    let raw = std::fs::read_to_string(&ini_path)
        .map_err(|e| format!("cannot read {ini_path}: {e}"))?;
    let sessions = crate::winscp::parse(&raw);
    trace(format!(
        "parsed {} sessions, folders={:?}",
        sessions.len(),
        sessions
            .iter()
            .filter_map(|s| s.group.clone())
            .collect::<std::collections::BTreeSet<_>>()
    ));
    if sessions.is_empty() {
        return Err("в файле нет сессий WinSCP".into());
    }

    let mut book = a.book.lock().map_err(|_| "lock poisoned")?;
    let mut report = WinscpImportReport {
        sessions: sessions.len() as u32,
        imported: 0,
        skipped: 0,
        groups: 0,
        passwords: 0,
        errors: Vec::new(),
    };

    let mut new_groups: std::collections::HashSet<String> = Default::default();
    append_log(format!(
        "import: {} sessions, folders={:?}",
        sessions.len(),
        sessions
            .iter()
            .filter_map(|s| s.group.clone())
            .collect::<std::collections::BTreeSet<_>>()
    ));

    // Groups are created up-front: on a re-import every session may be skipped
    // as a duplicate, but the folders from WinSCP still have to exist.
    for name in sessions.iter().filter_map(|s| s.group.clone()) {
        if name.trim().is_empty() {
            continue;
        }
        let exists = book
            .groups
            .iter()
            .any(|g| g.name.eq_ignore_ascii_case(name.trim()));
        if !exists {
            let group = Group {
                id: util::new_id("g"),
                name: name.trim().to_string(),
                parent: None,
                color: None,
                order: book.groups.len() as i32,
                expanded: true,
                icon: Some("winscp".into()),
            };
            new_groups.insert(group.id.clone());
            book.upsert_group(group);
        }
    }

    for session in sessions {
        let exists = book.servers.iter().any(|s| {
            s.host.eq_ignore_ascii_case(&session.host)
                && s.port == session.port
                && s.user == session.user
        });
        if exists {
            report.skipped += 1;
            continue;
        }

        let group_id = match &session.group {
            None => None,
            Some(name) => {
                let existing = book
                    .groups
                    .iter()
                    .find(|g| g.name.eq_ignore_ascii_case(name))
                    .map(|g| g.id.clone());
                match existing {
                    Some(id) => Some(id),
                    None => {
                        let group = Group {
                            id: util::new_id("g"),
                            name: name.clone(),
                            parent: None,
                            color: None,
                            order: book.groups.len() as i32,
                            expanded: true,
                            icon: Some("winscp".into()),
                        };
                        let id = group.id.clone();
                        book.upsert_group(group);
                        new_groups.insert(id.clone());
                        Some(id)
                    }
                }
            }
        };

        let id = util::new_id("s");
        let password_ref = if session.password.is_some() {
            Some(format!("pwd_{id}"))
        } else {
            None
        };

        let protocol = match session.protocol {
            Some(3) | Some(5) if session.port == 21 => Some("ftp".to_string()),
            Some(4) => Some("webdav".to_string()),
            _ => None,
        };
        let server = Server {
            id: id.clone(),
            protocol,
            group_id,
            name: session.name.clone(),
            host: session.host.clone(),
            port: session.port,
            user: session.user.clone(),
            auth: Auth {
                kind: if session.key_file.is_some() {
                    AuthKind::Key
                } else {
                    AuthKind::Password
                },
                key_path: session.key_file.clone(),
                passphrase_ref: None,
            },
            password_ref: password_ref.clone(),
            jump: None,
            encoding: None,
            remote_path: session.remote_dir.clone(),
            color: None,
            tags: vec!["winscp".into()],
            terminal_profile: None,
            notes: session.local_dir.clone(),
            last_connected: None,
            host_key_fingerprint: None,
            auth_failed: false,
            ftps_mode: None,
            ftps_insecure: None,
            passive: None,
            s3_endpoint: None,
            s3_region: None,
            s3_bucket: None,
            s3_prefix: None,
            s3_path_style: None,
            s3_access_ref: None,
            s3_secret_ref: None,
            reachable: None,
            checked_at: None,
        };
        book.upsert_server(server);
        report.imported += 1;

        if let (Some(reference), Some(hex)) = (password_ref, session.password.as_ref()) {
            // Decrypted natively: the key is user+host, no external tool needed.
            match crate::winscp::decrypt_password(&session.host, &session.user, hex) {
                Some(plain) if !plain.is_empty() => {
                    let mut vault = a.vault.lock().map_err(|_| "lock poisoned")?;
                    match vault.as_mut() {
                        Some(vault) => {
                            if vault.set(&reference, &plain).is_ok() {
                                report.passwords += 1;
                            }
                        }
                        None => report
                            .errors
                            .push("хранилище заблокировано, пароли не сохранены".into()),
                    }
                }
                _ => report.errors.push(format!(
                    "не удалось расшифровать пароль: {}",
                    if session.name.is_empty() { &session.host } else { &session.name }
                )),
            }
        }
    }

    report.groups = new_groups.len() as u32;
    if let Ok(mut vault) = a.vault.lock() {
        if let Some(v) = vault.as_mut() {
            let _ = v.save();
        }
    }
    book.validate().map_err(String::from)?;
    append_log(format!(
        "import: created {} groups, book now has {} groups / {} servers",
        report.groups,
        book.groups.len(),
        book.servers.len()
    ));
    persist_book(a, &book)?;
    Ok(report)
}

/// Import from a WinSCP.ini file (passwords are decrypted natively).
pub fn import_winscp_ini(ini_path: String) -> Result<WinscpImportReport, String> {
    import_winscp(ini_path)
}

// ---------------------------------------------------------------------------
// Built-in terminal (interactive shell)
// ---------------------------------------------------------------------------

pub fn open_shell(session_id: String, cols: u32, rows: u32) -> Result<String, String> {
    let a = app()?;
    let sessions = a.sessions.lock().map_err(|_| "lock poisoned")?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("no such session: {session_id}"))?;
    let id = util::new_id("sh");
    rt().block_on(session.open_shell(&id, cols, rows))
        .map_err(|e| e.to_string())?;
    Ok(id)
}

pub fn shell_write(shell_id: String, data: String) -> Result<(), String> {
    crate::ssh::session::shell_write(&shell_id, &data).map_err(|e| e.to_string())
}

pub fn shell_poll(shell_id: String) -> Result<String, String> {
    crate::ssh::session::shell_poll(&shell_id).map_err(|e| e.to_string())
}

pub fn shell_close(shell_id: String) {
    crate::ssh::session::shell_close(&shell_id);
}

/// Full access check: TCP -> SSH -> authentication (no SFTP, no tool probing).
/// Returns "ok", "unauthorized" or "unreachable" and updates the stored flag.
pub fn check_server_access(server_id: String) -> Result<String, String> {
    let a = app()?;
    let server = {
        let book = a.book.lock().map_err(|_| "lock poisoned")?;
        book.server(&server_id)
            .cloned()
            .ok_or_else(|| format!("unknown server: {server_id}"))?
    };

    let password = match server.auth.kind {
        AuthKind::Password => {
            let id = server
                .password_ref
                .clone()
                .unwrap_or_else(|| format!("pwd_{}", server.id));
            secret(a, &id)?
        }
        _ => None,
    };
    if server.auth.kind == AuthKind::Password && password.is_none() {
        return Ok("unauthorized".into());
    }

    let opts = ConnectOptions {
        host: server.host.clone(),
        port: server.port,
        user: server.user.clone(),
        auth: match server.auth.kind {
            AuthKind::Password => ConnectAuth::Password(password.unwrap_or_default()),
            _ => ConnectAuth::Key {
                path: server.auth.key_path.clone().unwrap_or_default(),
                passphrase: None,
            },
        },
        expected_fingerprint: server.host_key_fingerprint.clone(),
        timeout: std::time::Duration::from_secs(10),
        ..Default::default()
    };

    let outcome = rt().block_on(async move {
        match ssh::connect(&opts).await {
            Ok(session) => {
                let _ = session.close().await;
                "ok"
            }
            Err(e) => {
                let text = e.to_string().to_lowercase();
                if text.contains("auth")
                    || text.contains("permission denied")
                    || text.contains("publickey")
                {
                    "unauthorized"
                } else {
                    "unreachable"
                }
            }
        }
    });

    mark_auth_failed(a, &server_id, outcome == "unauthorized");
    mark_reachable(a, &server_id, outcome != "unreachable");
    Ok(outcome.to_string())
}

/// Stores the access-check result so it survives a restart.
fn mark_reachable(a: &App, server_id: &str, reachable: bool) {
    let Ok(mut book) = a.book.lock() else { return };
    let mut changed = false;
    if let Some(server) = book.servers.iter_mut().find(|s| s.id == server_id) {
        server.reachable = Some(reachable);
        server.checked_at = Some(util::now_ms());
        changed = true;
    }
    if changed {
        let _ = persist_book(a, &book);
    }
}

/// Records whether the last login for this server was rejected.
fn mark_auth_failed(a: &App, server_id: &str, failed: bool) {
    let Ok(mut book) = a.book.lock() else { return };
    let mut changed = false;
    if let Some(server) = book.servers.iter_mut().find(|s| s.id == server_id) {
        if server.auth_failed != failed {
            server.auth_failed = failed;
            changed = true;
        }
    }
    if changed {
        let _ = persist_book(a, &book);
    }
}

#[cfg(test)]
mod tests {
    use super::{archive_entry_dest, transfer_slots};

    /// The progress window's Cancel must never abort another tab's silent
    /// reconnection, so the flag is matched against the server id.
    #[test]
    fn cancel_is_scoped_to_the_server_in_flight() {
        use std::sync::atomic::Ordering;

        if let Ok(mut target) = super::CONNECT_TARGET.lock() {
            *target = Some("srv-a".to_string());
        }
        super::CONNECT_CANCELLED.store(false, Ordering::SeqCst);

        super::cancel_connect("srv-b".into()).unwrap();
        assert!(!super::connect_cancelled());

        super::cancel_connect("srv-a".into()).unwrap();
        assert!(super::connect_cancelled());

        super::CONNECT_CANCELLED.store(false, Ordering::SeqCst);
    }

    #[test]
    fn profile_export_and_import_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        crate::api::init_data_dir(Some(dir.path().to_string_lossy().to_string())).unwrap();
        crate::api::create_vault("master-pass-1".into()).unwrap();

        let mut server = crate::model::Server::new("example.test", "root");
        server.name = "Exported".into();
        server.password_ref = Some("pwd_exported".into());
        crate::api::save_server(server).unwrap();
        crate::api::set_secret("pwd_exported".into(), "s3cr3t-value".into()).unwrap();
        crate::api::save_snippet(crate::model::Snippet {
            name: "Свободное место".into(),
            command: "df -h".into(),
            favorite: true,
            ..Default::default()
        })
        .unwrap();
        crate::api::save_ai_settings(crate::model::AiSettings {
            provider: "openrouter".into(),
            endpoint: "https://openrouter.ai/api/v1".into(),
            model: "test/model".into(),
            ..Default::default()
        })
        .unwrap();

        let file = dir.path().join("profile.novaprof");
        let file_str = file.to_string_lossy().to_string();
        crate::api::export_profile(file_str.clone()).unwrap();
        assert!(file.exists());
        // No password any more: the file is readable JSON with the secrets.
        let raw = std::fs::read_to_string(&file).unwrap();
        assert!(raw.contains("s3cr3t-value"));
        assert!(raw.contains("df -h"));

        // A damaged file is reported, not silently ignored.
        let broken = dir.path().join("broken.novaprof");
        std::fs::write(&broken, b"{ not json").unwrap();
        assert!(crate::api::import_profile(broken.to_string_lossy().to_string(), false).is_err());

        // Merge into the same book: the server is a duplicate, the secret is
        // re-imported.
        let report = crate::api::import_profile(file_str.clone(), false).unwrap();
        assert_eq!(report.servers, 0, "duplicate must not be added twice");
        assert_eq!(report.snippets, 0, "the same snippet must not be added twice");
        assert!(report.secrets >= 1);
        assert!(!report.replaced);
        assert!(report.backup_dir.is_none());

        // Replace mode backs the current profile up first.
        let report = crate::api::import_profile(file_str, true).unwrap();
        assert!(report.replaced);
        assert_eq!(report.servers, 1);
        assert_eq!(report.snippets, 1);
        let ai = crate::api::load_ai_settings().unwrap();
        assert_eq!(ai.model, "test/model");
        let backup = report.backup_dir.expect("backup dir");
        assert!(std::path::Path::new(&backup).join("servers.json").exists());
        assert!(std::path::Path::new(&backup).join("snippets.json").exists());

        // The edit log is off by default and writes one dated file when on.
        crate::api::append_edit_log(
            "BOTS (root@example:22)".into(),
            "BOTS".into(),
            "/var/www/app.php".into(),
            "сохранён".into(),
            "02-11-2026".into(),
            "12:34:56".into(),
        )
        .unwrap();
        assert!(!dir.path().join("logs/BOTS_02-11-2026.log").exists());

        crate::api::save_log_settings(crate::model::LogSettings { edit_log: true }).unwrap();
        crate::api::append_edit_log(
            "BOTS (root@example:22)".into(),
            "BOTS".into(),
            "/var/www/app.php".into(),
            "сохранён".into(),
            "02-11-2026".into(),
            "12:34:56".into(),
        )
        .unwrap();
        let log =
            std::fs::read_to_string(dir.path().join("logs/BOTS_02-11-2026.log")).unwrap();
        assert!(log.contains("12:34:56"));
        assert!(log.contains("/var/www/app.php"));
        assert!(log.contains("BOTS"));

        // Session temp files live under tmp/<server> and can be wiped as a unit.
        let tmp_file = dir.path().join("tmp/IKEY_NEW!/hash/app.php");
        std::fs::create_dir_all(tmp_file.parent().unwrap()).unwrap();
        std::fs::write(&tmp_file, b"edited").unwrap();
        crate::api::clear_server_tmp("IKEY_NEW!".into()).unwrap();
        assert!(!dir.path().join("tmp/IKEY_NEW!").exists());
    }

    #[test]
    fn transfer_slots_follow_the_setting_and_are_reused() {
        let two = transfer_slots(2);
        assert_eq!(two.available_permits(), 2);
        // Same limit -> the same semaphore instance is reused.
        assert!(std::sync::Arc::ptr_eq(&two, &transfer_slots(2)));

        let one = transfer_slots(1);
        assert_eq!(one.available_permits(), 1);
        // Out-of-range values are clamped instead of creating a stuck pool.
        assert_eq!(transfer_slots(0).available_permits(), 1);
        assert_eq!(transfer_slots(99).available_permits(), 8);
    }

    #[test]
    fn archive_entries_stay_inside_the_extraction_folder() {
        let root = "/target/demo";

        // Normal nested entry.
        assert_eq!(
            archive_entry_dest(root, "/target", true, "docs/a.txt", "docs/a.txt").as_deref(),
            Some("/target/demo/docs/a.txt")
        );
        // Traversal, absolute paths and drive letters are refused.
        for rel in [
            "../escaped.txt",
            "docs/../../escaped.txt",
            "C:/Windows/Temp/x.txt",
            "a/./b",
        ] {
            assert!(
                archive_entry_dest(root, "/target", true, "x", rel).is_none(),
                "accepted {rel:?}"
            );
        }
        // A single file from the archive keeps only its name.
        assert_eq!(
            archive_entry_dest(root, "/target", false, "docs/a.txt", "docs/a.txt").as_deref(),
            Some("/target/a.txt")
        );
        // A single file is reduced to its last component, so a hostile path
        // still lands directly in the target folder.
        assert_eq!(
            archive_entry_dest(root, "/target", false, "../x", "../x").as_deref(),
            Some("/target/x")
        );
    }
}
