//! Tauri commands. Thin wrappers over `nova_core::api`; everything that can
//! block is moved to the blocking pool so the async runtime stays responsive.

use nova_core::api;
use nova_core::model::*;
use tauri::ipc::Channel;

macro_rules! blocking {
    ($body:expr) => {
        tauri::async_runtime::spawn_blocking(move || $body)
            .await
            .map_err(|e| e.to_string())?
    };
}

// ---------------------------------------------------------------------------
// Core / connection
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn init_app() -> Result<api::AppInfo, String> {
    blocking!(api::init_data_dir(None))
}

#[tauri::command]
pub async fn ensure_device_vault() -> Result<bool, String> {
    blocking!({
        let info = api::info()?;
        if info.vault == "unlocked" {
            return Ok(true);
        }
        if info.has_device_key && api::unlock_vault_with_device()? {
            let _ = api::upgrade_vault_to_device_key()?;
            return Ok(true);
        }
        if info.vault == "missing" {
            api::create_vault_with_device_key()?;
            return Ok(true);
        }
        Ok(false)
    })
}

#[tauri::command]
pub async fn load_settings() -> Result<Settings, String> {
    blocking!(api::load_settings())
}

#[tauri::command]
pub fn volumes() -> Vec<Volume> {
    api::volumes()
}

#[tauri::command]
pub async fn list_servers() -> Result<ServerBook, String> {
    blocking!(api::load_book())
}

#[tauri::command]
pub async fn connect_server(
    server_id: String,
    password: Option<String>,
) -> Result<api::ConnectResult, String> {
    blocking!(api::connect(server_id, password))
}

#[tauri::command]
pub async fn cancel_connect(server_id: String) -> Result<(), String> {
    blocking!(api::cancel_connect(server_id))
}

#[tauri::command]
pub fn connect_stage() -> u32 {
    api::connect_stage()
}

#[tauri::command]
pub async fn disconnect_session(session_id: String) -> Result<(), String> {
    blocking!(api::disconnect(session_id))
}

#[tauri::command]
pub async fn home_local() -> Result<String, String> {
    blocking!(api::home_local())
}

#[tauri::command]
pub async fn list_local(path: String, show_hidden: bool) -> Result<DirListing, String> {
    blocking!(api::list_local(path, show_hidden))
}

#[tauri::command]
pub async fn list_remote(
    session_id: String,
    path: String,
    show_hidden: bool,
) -> Result<DirListing, String> {
    blocking!(api::list_remote(session_id, path, show_hidden))
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn mkdir(session_id: Option<String>, path: String) -> Result<(), String> {
    blocking!(api::mkdir(session_id, path))
}

#[tauri::command]
pub async fn rename(
    session_id: Option<String>,
    from: String,
    to: String,
) -> Result<(), String> {
    blocking!(api::rename(session_id, from, to))
}

#[tauri::command]
pub async fn remove(
    session_id: Option<String>,
    path: String,
    is_dir: bool,
) -> Result<(), String> {
    blocking!(api::remove(session_id, path, is_dir))
}

#[tauri::command]
pub async fn copy_local(sources: Vec<String>, target_dir: String) -> Result<u32, String> {
    blocking!(api::copy_local(sources, target_dir))
}

#[tauri::command]
pub async fn preview(
    session_id: Option<String>,
    path: String,
    max_bytes: u32,
) -> Result<String, String> {
    blocking!(api::preview(session_id, path, max_bytes))
}

#[tauri::command]
pub async fn save_text(file: FileRef, text: String) -> Result<(), String> {
    blocking!(api::save_text(file, text))
}

#[tauri::command]
pub async fn checksum(
    session_id: Option<String>,
    path: String,
    algorithm: String,
) -> Result<FileChecksum, String> {
    blocking!(api::checksum(session_id, path, algorithm))
}

#[tauri::command]
pub async fn find_files(
    session_id: Option<String>,
    root: String,
    mask: String,
    content: Option<String>,
    max_results: u32,
) -> Result<Vec<FoundFile>, String> {
    blocking!(api::find_files(session_id, root, mask, content, max_results))
}

#[tauri::command]
pub async fn chmod(
    session_id: Option<String>,
    path: String,
    mode: u32,
    recursive: bool,
) -> Result<u32, String> {
    blocking!(api::chmod(session_id, path, mode, recursive))
}

#[tauri::command]
pub async fn transfer_file(
    session_id: String,
    direction: String,
    source_path: String,
    target_dir: String,
    resume_from: u64,
    limit_kibps: u32,
    verify: bool,
    target_name: Option<String>,
    on_event: Channel<TransferEvent>,
) -> Result<(), String> {
    blocking!(api::transfer_with(
        session_id,
        direction,
        source_path,
        target_dir,
        resume_from,
        limit_kibps,
        verify,
        target_name,
        move |event| {
            let _ = on_event.send(event);
        },
    ))
}

#[tauri::command]
pub fn cancel_transfer(id: String) -> bool {
    api::cancel_transfer(id)
}

#[tauri::command]
pub async fn probe_server(host: String, port: u16, timeout_ms: u32) -> Result<bool, String> {
    blocking!(Ok(api::probe_server(host, port, timeout_ms)))
}

#[tauri::command]
pub async fn check_server_access(server_id: String) -> Result<String, String> {
    blocking!(api::check_server_access(server_id))
}

// ---------------------------------------------------------------------------
// Servers, groups and the vault
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn save_server(server: Server) -> Result<Server, String> {
    blocking!(api::save_server(server))
}

#[tauri::command]
pub async fn delete_server(id: String) -> Result<(), String> {
    blocking!(api::delete_server(id))
}

#[tauri::command]
pub async fn save_group(group: Group) -> Result<Group, String> {
    blocking!(api::save_group(group))
}

#[tauri::command]
pub async fn delete_group(id: String) -> Result<(), String> {
    blocking!(api::delete_group(id))
}

#[tauri::command]
pub async fn set_secret(id: String, value: String) -> Result<(), String> {
    blocking!(api::set_secret(id, value))
}

#[tauri::command]
pub async fn get_secret(
    id: String,
    master_password: Option<String>,
) -> Result<Option<String>, String> {
    blocking!(api::get_secret(id, master_password))
}

#[tauri::command]
pub async fn delete_secret(id: String) -> Result<(), String> {
    blocking!(api::delete_secret(id))
}

#[tauri::command]
pub async fn save_settings(settings: Settings) -> Result<(), String> {
    blocking!(api::save_settings(settings))
}

#[tauri::command]
pub async fn load_color_rules() -> Result<ColorRules, String> {
    blocking!(api::load_color_rules())
}

#[tauri::command]
pub async fn save_color_rules(rules: ColorRules) -> Result<(), String> {
    blocking!(api::save_color_rules(rules))
}

// ---------------------------------------------------------------------------
// Snippets and AI
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn load_snippets() -> Result<Vec<Snippet>, String> {
    blocking!(api::load_snippets())
}

#[tauri::command]
pub async fn save_snippet(snippet: Snippet) -> Result<Snippet, String> {
    blocking!(api::save_snippet(snippet))
}

#[tauri::command]
pub async fn delete_snippet(id: String) -> Result<(), String> {
    blocking!(api::delete_snippet(id))
}

#[tauri::command]
pub async fn save_snippet_order(ids: Vec<String>) -> Result<(), String> {
    blocking!(api::save_snippet_order(ids))
}

#[tauri::command]
pub async fn load_ai_settings() -> Result<AiSettings, String> {
    blocking!(api::load_ai_settings())
}

#[tauri::command]
pub async fn save_ai_settings(settings: AiSettings) -> Result<(), String> {
    blocking!(api::save_ai_settings(settings))
}

// ---------------------------------------------------------------------------
// Session memory
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn load_session_state() -> Result<SessionState, String> {
    blocking!(api::load_session_state())
}

#[tauri::command]
pub async fn save_open_sessions(sessions: Vec<OpenSession>) -> Result<(), String> {
    blocking!(api::save_open_sessions(sessions))
}

#[tauri::command]
pub async fn remember_session(
    server_id: String,
    remote_path: String,
    local_path: String,
) -> Result<(), String> {
    blocking!(api::remember_session(server_id, remote_path, local_path))
}

// ---------------------------------------------------------------------------
// Interactive shell
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn open_shell(
    session_id: String,
    cols: u32,
    rows: u32,
) -> Result<String, String> {
    blocking!(api::open_shell(session_id, cols, rows))
}

#[tauri::command]
pub async fn shell_write(shell_id: String, data: String) -> Result<(), String> {
    blocking!(api::shell_write(shell_id, data))
}

#[tauri::command]
pub async fn shell_poll(shell_id: String) -> Result<String, String> {
    blocking!(api::shell_poll(shell_id))
}

#[tauri::command]
pub fn shell_close(shell_id: String) {
    api::shell_close(shell_id);
}

// ---------------------------------------------------------------------------
// Profile and sync
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn export_profile(path: String) -> Result<(), String> {
    blocking!(api::export_profile(path))
}

#[tauri::command]
pub async fn import_profile(
    path: String,
    replace: bool,
) -> Result<api::ProfileImportReport, String> {
    blocking!(api::import_profile(path, replace))
}

#[tauri::command]
pub async fn credentials_preview() -> Result<String, String> {
    blocking!(api::credentials_preview())
}

#[tauri::command]
pub async fn export_credentials(path: String) -> Result<u32, String> {
    blocking!(api::export_credentials(path))
}

#[tauri::command]
pub async fn sync_export_json(include_secrets: bool) -> Result<String, String> {
    blocking!(api::sync_export_json(include_secrets))
}

#[tauri::command]
pub async fn import_sync(json: String) -> Result<SyncReport, String> {
    blocking!(api::import_sync(json))
}

#[tauri::command]
pub async fn start_sync_share(include_secrets: bool) -> Result<SyncShare, String> {
    blocking!(api::start_sync_share(include_secrets))
}

#[tauri::command]
pub fn stop_sync_share() {
    api::stop_sync_share();
}

#[tauri::command]
pub fn sync_share_token() -> Option<String> {
    api::sync_share_token()
}
