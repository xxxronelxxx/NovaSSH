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
pub async fn download_to_cache(
    session_id: String,
    server_name: String,
    remote_path: String,
) -> Result<String, String> {
    blocking!(api::download_to_cache(session_id, server_name, remote_path))
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

// ---------------------------------------------------------------------------
// Archives
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn archive_needs_password(archive_path: String) -> Result<bool, String> {
    blocking!(api::archive_needs_password(archive_path))
}

#[tauri::command]
pub async fn unlock_archive(archive_path: String, password: String) -> Result<(), String> {
    blocking!(api::unlock_archive(archive_path, password))
}

#[tauri::command]
pub async fn list_archive(
    archive_path: String,
    inner: String,
    show_hidden: bool,
) -> Result<DirListing, String> {
    blocking!(api::list_archive(archive_path, inner, show_hidden))
}

#[tauri::command]
pub async fn preview_archive(
    archive_path: String,
    inner: String,
    max_bytes: u32,
    token: Option<String>,
) -> Result<String, String> {
    blocking!(api::preview_archive(archive_path, inner, max_bytes, token))
}

#[tauri::command]
pub async fn create_archive(
    sources: Vec<String>,
    target_path: String,
    format: Option<String>,
    token: Option<String>,
) -> Result<u32, String> {
    blocking!(api::create_archive(sources, target_path, format, token))
}

#[tauri::command]
pub async fn copy_to_archive(
    session_id: Option<String>,
    sources: Vec<String>,
    archive_path: String,
    inner: String,
    format: Option<String>,
    token: Option<String>,
) -> Result<u32, String> {
    blocking!(api::copy_to_archive(
        session_id,
        sources,
        archive_path,
        inner,
        format,
        token,
    ))
}

#[tauri::command]
pub async fn assemble_volumes(
    session_id: Option<String>,
    parts: Vec<String>,
    target_path: Option<String>,
) -> Result<String, String> {
    blocking!(api::assemble_volumes(session_id, parts, target_path))
}

#[tauri::command]
pub fn cancel_archive_task(token: String) -> Result<(), String> {
    api::cancel_archive_task(token)
}

#[tauri::command]
pub fn cancel_archive_job(job_id: String) -> Result<(), String> {
    api::cancel_archive_job(job_id)
}

#[tauri::command]
pub async fn copy_from_archive(
    session_id: Option<String>,
    archive_path: String,
    inner: String,
    target_dir: String,
    on_event: Channel<TransferEvent>,
) -> Result<(), String> {
    blocking!(api::copy_from_archive_with(
        session_id,
        archive_path,
        inner,
        target_dir,
        move |event| {
            let _ = on_event.send(event);
        },
    ))
}

#[tauri::command]
pub async fn pack_server_archive(
    session_id: String,
    sources: Vec<String>,
    target_path: String,
    format: Option<String>,
    on_event: Channel<TransferEvent>,
) -> Result<(), String> {
    blocking!(api::pack_server_archive_with(
        session_id,
        sources,
        target_path,
        format,
        move |event| {
            let _ = on_event.send(event);
        },
    ))
}

#[tauri::command]
pub async fn unpack_server_archive(
    session_id: String,
    archive_path: String,
    inner: String,
    target_dir: String,
    password: Option<String>,
    on_event: Channel<TransferEvent>,
) -> Result<(), String> {
    blocking!(api::unpack_server_archive_with(
        session_id,
        archive_path,
        inner,
        target_dir,
        password,
        move |event| {
            let _ = on_event.send(event);
        },
    ))
}

// ---------------------------------------------------------------------------
// AI assistant (OpenAI-compatible providers)
// ---------------------------------------------------------------------------

#[derive(serde::Serialize)]
pub struct AiModel {
    pub id: String,
    pub name: Option<String>,
}

fn ai_base(endpoint: &str) -> String {
    endpoint.trim().trim_end_matches('/').to_string()
}

fn ai_models_url(endpoint: &str) -> String {
    let base = ai_base(endpoint);
    if base.ends_with("/openai/v1") {
        format!(
            "{}/v1/models",
            &base[..base.len() - "/openai/v1".len()]
        )
    } else {
        format!("{base}/models")
    }
}

fn ai_session_id() -> String {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros())
        .unwrap_or(0);
    format!("ses_nova{stamp:x}")
}

fn ai_status_error(status: u16, body: &str) -> String {
    let hint = match status {
        400 => "запрос отклонён",
        401 => "неверный API-ключ",
        402 => "на счету провайдера нет средств",
        403 => "доступ запрещён",
        404 => "endpoint или модель не найдены",
        429 => "слишком много запросов, подождите",
        500 | 502 | 503 | 504 => "ошибка на стороне провайдера",
        _ => "ошибка",
    };
    let excerpt = body.split_whitespace().collect::<Vec<_>>().join(" ");
    let excerpt = if excerpt.len() > 220 {
        format!("{}…", &excerpt[..220])
    } else {
        excerpt
    };
    format!("{hint} (HTTP {status})\n{excerpt}")
}

fn ai_clean_command(raw: &str) -> String {
    let mut text = raw.trim().to_string();
    if text.starts_with("```") {
        if let Some(first_newline) = text.find('\n') {
            text = text[first_newline + 1..].to_string();
        }
        if let Some(end) = text.rfind("```") {
            text.truncate(end);
        }
    }
    let lines: Vec<String> = text
        .lines()
        .map(|line| line.trim_end().to_string())
        .filter(|line| !line.trim().is_empty())
        .collect();
    text = lines.join("\n").trim().to_string();
    if let Some(rest) = text.strip_prefix("$ ") {
        text = rest.trim().to_string();
    }
    if text.len() > 1 && text.starts_with('`') && text.ends_with('`') {
        text = text[1..text.len() - 1].trim().to_string();
    }
    text
}

#[tauri::command]
pub async fn ai_models(endpoint: String, api_key: String) -> Result<Vec<AiModel>, String> {
    if api_key.trim().is_empty() {
        return Err("Не задан API-ключ".into());
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .get(ai_models_url(&endpoint))
        .header("Authorization", format!("Bearer {}", api_key.trim()))
        .header("Accept", "application/json")
        .header("User-Agent", "NovaSSH/1.0")
        .header("x-opencode-session", ai_session_id())
        .send()
        .await
        .map_err(|e| format!("Нет связи с провайдером: {e}"))?;
    let status = response.status().as_u16();
    let body = response.text().await.map_err(|e| e.to_string())?;
    if status != 200 {
        return Err(ai_status_error(status, &body));
    }
    let value: serde_json::Value =
        serde_json::from_str(&body).map_err(|_| "Ответ /models не похож на JSON")?;
    let data = value.get("data").unwrap_or(&value);
    let list = data
        .as_array()
        .ok_or("Ответ /models непонятен: нет списка моделей")?;
    let mut models: Vec<AiModel> = list
        .iter()
        .filter_map(|item| {
            let id = item
                .as_str()
                .map(str::to_string)
                .or_else(|| {
                    item.get("id")
                        .and_then(|v| v.as_str())
                        .map(str::to_string)
                })?;
            if id.trim().is_empty() {
                return None;
            }
            let name = item
                .get("name")
                .and_then(|v| v.as_str())
                .map(str::trim)
                .filter(|v| !v.is_empty())
                .map(str::to_string);
            Some(AiModel {
                id: id.trim().to_string(),
                name,
            })
        })
        .collect();
    models.sort_by(|a, b| a.id.to_lowercase().cmp(&b.id.to_lowercase()));
    Ok(models)
}

#[tauri::command]
pub async fn ai_ask(
    endpoint: String,
    api_key: String,
    model: String,
    question: String,
    context: String,
) -> Result<String, String> {
    if api_key.trim().is_empty() {
        return Err("Не задан API-ключ".into());
    }
    if model.trim().is_empty() {
        return Err("Не выбрана модель — откройте Настройки → ИИ".into());
    }
    const SYSTEM: &str = "Ты — помощник по администрированию Linux-сервера. \
Ответ — ровно одна команда оболочки: без пояснений, без markdown, без обратных \
кавычек и без знака $ в начале. Если нужно несколько действий, соедини их через \
&& в одну строку. Если задача невыполнима одной командой, дай ближайшую подходящую.";
    let mut user = String::new();
    if !context.trim().is_empty() {
        user.push_str("Контекст сервера:\n");
        user.push_str(context.trim());
        user.push_str("\n\n");
    }
    user.push_str(question.trim());

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .post(format!("{}/chat/completions", ai_base(&endpoint)))
        .header("Authorization", format!("Bearer {}", api_key.trim()))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json")
        .header("User-Agent", "NovaSSH/1.0")
        .header("x-opencode-session", ai_session_id())
        .header("HTTP-Referer", "https://novassh.local")
        .header("X-Title", "Nova SSH")
        .json(&serde_json::json!({
            "model": model.trim(),
            "temperature": 0,
            "max_tokens": 300,
            "messages": [
                {"role": "system", "content": SYSTEM},
                {"role": "user", "content": user},
            ],
        }))
        .send()
        .await
        .map_err(|e| format!("Модель не ответила: {e}"))?;
    let status = response.status().as_u16();
    let body = response.text().await.map_err(|e| e.to_string())?;
    if status != 200 {
        return Err(ai_status_error(status, &body));
    }
    let value: serde_json::Value =
        serde_json::from_str(&body).map_err(|_| "Ответ сервера не похож на JSON")?;
    let content = value
        .get("choices")
        .and_then(|v| v.as_array())
        .and_then(|list| list.first())
        .and_then(|choice| choice.get("message"))
        .and_then(|message| message.get("content"))
        .and_then(|v| v.as_str())
        .ok_or("Модель не вернула ответ")?;
    let command = ai_clean_command(content);
    if command.is_empty() {
        return Err("Модель вернула пустой ответ".into());
    }
    Ok(command)
}

// ---------------------------------------------------------------------------
// Compare and directory sync
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn compare_files(
    left: FileRef,
    right: FileRef,
    options: CompareOptions,
) -> Result<CompareResult, String> {
    blocking!(api::compare_files(left, right, options))
}

#[tauri::command]
pub async fn sync_scan(
    session_id: String,
    local_root: String,
    remote_root: String,
    mode: String,
    max_files: u32,
) -> Result<Vec<SyncEntry>, String> {
    blocking!(api::sync_scan(
        session_id,
        local_root,
        remote_root,
        mode,
        max_files,
    ))
}

// ---------------------------------------------------------------------------
// Logs and WinSCP import
// ---------------------------------------------------------------------------

#[tauri::command]
pub fn log_dir() -> Option<String> {
    api::log_dir()
}

#[tauri::command]
pub async fn load_log_settings() -> Result<LogSettings, String> {
    blocking!(api::load_log_settings())
}

#[tauri::command]
pub async fn save_log_settings(settings: LogSettings) -> Result<(), String> {
    blocking!(api::save_log_settings(settings))
}

#[tauri::command]
pub async fn import_winscp_ini(ini_path: String) -> Result<api::WinscpImportReport, String> {
    blocking!(api::import_winscp_ini(ini_path))
}

// ---------------------------------------------------------------------------
// Log viewer (files live next to the profile; the WebView cannot read them)
// ---------------------------------------------------------------------------

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogFile {
    pub name: String,
    pub path: String,
    pub size: u64,
    pub modified: i64,
}

fn logs_root() -> Result<std::path::PathBuf, String> {
    api::log_dir()
        .map(std::path::PathBuf::from)
        .ok_or_else(|| "Папка журналов недоступна".to_string())
}

#[tauri::command]
pub async fn list_logs() -> Result<Vec<LogFile>, String> {
    let dir = logs_root()?;
    let mut files = Vec::new();
    let entries = match std::fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(_) => return Ok(files),
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path
            .extension()
            .and_then(|value| value.to_str())
            .map(|value| value.eq_ignore_ascii_case("log"))
            .unwrap_or(false)
        {
            continue;
        }
        let meta = match entry.metadata() {
            Ok(meta) => meta,
            Err(_) => continue,
        };
        let modified = meta
            .modified()
            .ok()
            .and_then(|value| value.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|value| value.as_millis() as i64)
            .unwrap_or(0);
        files.push(LogFile {
            name: entry.file_name().to_string_lossy().to_string(),
            path: path.to_string_lossy().to_string(),
            size: meta.len(),
            modified,
        });
    }
    files.sort_by(|a, b| b.modified.cmp(&a.modified));
    Ok(files)
}

#[tauri::command]
pub async fn read_log(path: String, max_bytes: usize) -> Result<String, String> {
    use std::io::{Read, Seek, SeekFrom};
    let dir = logs_root()?;
    let requested = std::path::PathBuf::from(&path);
    let name = requested
        .file_name()
        .ok_or_else(|| "Некорректный путь журнала".to_string())?;
    let safe = dir.join(name);
    let mut file = std::fs::File::open(&safe).map_err(|e| format!("Журнал: {e}"))?;
    let size = file.metadata().map(|meta| meta.len()).unwrap_or(0);
    let limit = max_bytes.clamp(4096, 4 * 1024 * 1024) as u64;
    if size > limit {
        file.seek(SeekFrom::Start(size - limit))
            .map_err(|e| e.to_string())?;
    }
    let mut buffer = Vec::new();
    file.read_to_end(&mut buffer).map_err(|e| e.to_string())?;
    Ok(String::from_utf8_lossy(&buffer).to_string())
}

#[tauri::command]
pub async fn import_sync_url(url: String) -> Result<SyncReport, String> {
    let trimmed = url.trim();
    if !trimmed.starts_with("http://") && !trimmed.starts_with("https://") {
        return Err("Ссылка должна начинаться с http:// или https://".into());
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .get(trimmed)
        .header("User-Agent", "NovaSSH/1.0")
        .send()
        .await
        .map_err(|e| format!("Не удалось скачать профиль: {e}"))?;
    let status = response.status().as_u16();
    let body = response.text().await.map_err(|e| e.to_string())?;
    if status != 200 {
        return Err(format!(
            "Сервер ответил HTTP {status}: {}",
            body.chars().take(180).collect::<String>()
        ));
    }
    blocking!(api::import_sync(body))
}

// ---------------------------------------------------------------------------
// Vault lock
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn lock_vault() -> Result<(), String> {
    blocking!(api::lock_vault())
}

#[tauri::command]
pub async fn unlock_vault(password: String) -> Result<(), String> {
    blocking!(api::unlock_vault(password))
}

#[tauri::command]
pub async fn vault_info() -> Result<api::AppInfo, String> {
    blocking!(api::info())
}

// ---------------------------------------------------------------------------
// Explorer / terminal shortcuts for the local pane
// ---------------------------------------------------------------------------

#[cfg(windows)]
fn launch(command: &str, args: &[&str]) -> Result<(), String> {
    std::process::Command::new(command)
        .args(args)
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn reveal_in_explorer(path: String) -> Result<(), String> {
    #[cfg(windows)]
    {
        let argument = format!("/select,{path}");
        return launch("explorer.exe", &[&argument]);
    }
    #[cfg(not(windows))]
    {
        let parent = std::path::Path::new(&path)
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or(path);
        launch("xdg-open", &[&parent])
    }
}

#[tauri::command]
pub async fn open_terminal_at(path: String) -> Result<(), String> {
    #[cfg(windows)]
    {
        let argument = format!("cd /d \"{path}\"");
        return launch("cmd.exe", &["/c", "start", "cmd", "/k", &argument]);
    }
    #[cfg(not(windows))]
    {
        launch("x-terminal-emulator", &[])
    }
}

// ---------------------------------------------------------------------------
// External programs (editor / terminal)
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn launch_process(command: String, args: Vec<String>) -> Result<(), String> {
    blocking!(api::launch_process(command, args))
}

#[tauri::command]
pub async fn launch_editor(editor: String, path: String) -> Result<(), String> {
    blocking!(api::launch_editor(editor, path))
}

#[tauri::command]
pub async fn path_exists(path: String) -> Result<bool, String> {
    Ok(api::path_exists(path))
}

#[tauri::command]
pub async fn upload_from_cache(
    session_id: String,
    local_path: String,
    remote_path: String,
) -> Result<(), String> {
    blocking!(api::upload_from_cache(session_id, local_path, remote_path))
}

#[tauri::command]
pub async fn file_mtime_ms(path: String) -> Result<i64, String> {
    blocking!(api::file_mtime_ms(path))
}

#[tauri::command]
pub async fn append_edit_log(
    server: String,
    server_name: String,
    path: String,
    action: String,
    date: String,
    time: String,
) -> Result<(), String> {
    blocking!(api::append_edit_log(
        server,
        server_name,
        path,
        action,
        date,
        time
    ))
}

#[tauri::command]
pub fn ui_log(line: String) {
    api::append_log(line);
}

#[tauri::command]
pub async fn set_solid_mode(window: tauri::WebviewWindow, solid: bool) -> Result<(), String> {
    #[cfg(windows)]
    {
        if solid {
            let _ = window_vibrancy::clear_mica(&window);
        } else {
            let _ = window_vibrancy::apply_mica(&window, Some(true));
        }
    }
    Ok(())
}

#[tauri::command]
pub async fn clear_server_tmp(server_name: String) -> Result<(), String> {
    blocking!(api::clear_server_tmp(server_name))
}

#[tauri::command]
pub async fn clear_all_tmp() -> Result<(), String> {
    blocking!(api::clear_all_tmp())
}

#[tauri::command]
pub async fn exec_remote(session_id: String, command: String) -> Result<String, String> {
    blocking!(api::exec_remote(session_id, command))
}

#[tauri::command]
pub async fn compare_text(
    left: String,
    right: String,
    options: CompareOptions,
) -> Result<CompareResult, String> {
    Ok(api::compare_text(left, right, options))
}

#[tauri::command]
pub async fn resolve_remote_dir(
    session_id: String,
    input: String,
    fallback: String,
) -> Result<String, String> {
    blocking!(api::resolve_remote_dir(session_id, input, fallback))
}

#[tauri::command]
pub async fn upgrade_vault_to_device_key() -> Result<bool, String> {
    blocking!(api::upgrade_vault_to_device_key())
}

#[tauri::command]
pub async fn rekey_vault_to_device_key(password: String) -> Result<(), String> {
    blocking!(api::rekey_vault_to_device_key(password))
}
