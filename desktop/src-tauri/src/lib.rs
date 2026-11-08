use nova_core::api;
use nova_core::model::DirListing;
use nova_core::model::ServerBook;
use nova_core::model::TransferEvent;
use tauri::ipc::Channel;

/// One-time core initialisation. The profile lives next to the exe (`profile`).
#[tauri::command]
async fn init_app() -> Result<api::AppInfo, String> {
    tauri::async_runtime::spawn_blocking(|| api::init_data_dir(None))
        .await
        .map_err(|e| e.to_string())?
}

/// Windows has no master password: the vault key is wrapped by DPAPI.
#[tauri::command]
async fn ensure_device_vault() -> Result<bool, String> {
    tauri::async_runtime::spawn_blocking(|| {
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
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn load_settings() -> Result<nova_core::model::Settings, String> {
    tauri::async_runtime::spawn_blocking(api::load_settings)
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
fn volumes() -> Vec<nova_core::model::Volume> {
    api::volumes()
}

#[tauri::command]
async fn list_servers() -> Result<ServerBook, String> {
    tauri::async_runtime::spawn_blocking(api::load_book)
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn connect_server(
    server_id: String,
    password: Option<String>,
) -> Result<api::ConnectResult, String> {
    tauri::async_runtime::spawn_blocking(move || api::connect(server_id, password))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn cancel_connect(server_id: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || api::cancel_connect(server_id))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
fn connect_stage() -> u32 {
    api::connect_stage()
}

#[tauri::command]
async fn home_local() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(api::home_local)
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn list_local(path: String, show_hidden: bool) -> Result<DirListing, String> {
    tauri::async_runtime::spawn_blocking(move || api::list_local(path, show_hidden))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn list_remote(
    session_id: String,
    path: String,
    show_hidden: bool,
) -> Result<DirListing, String> {
    tauri::async_runtime::spawn_blocking(move || {
        api::list_remote(session_id, path, show_hidden)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn disconnect_session(session_id: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || api::disconnect(session_id))
        .await
        .map_err(|e| e.to_string())?
}

/// Streams a remote file into the local panel; progress goes to the channel.
#[tauri::command]
async fn download_file(
    session_id: String,
    source_path: String,
    target_dir: String,
    on_event: Channel<TransferEvent>,
) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        api::transfer_with(
            session_id,
            "download".to_string(),
            source_path,
            target_dir,
            0,
            0,
            false,
            None,
            move |event| {
                let _ = on_event.send(event);
            },
        )
    })
    .await
    .map_err(|e| e.to_string())?
}

pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            #[cfg(windows)]
            {
                use tauri::Manager;
                use window_vibrancy::apply_mica;
                if let Some(window) = app.get_webview_window("main") {
                    let _ = apply_mica(&window, Some(true));
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            init_app,
            ensure_device_vault,
            load_settings,
            volumes,
            list_servers,
            connect_server,
            cancel_connect,
            connect_stage,
            home_local,
            list_local,
            list_remote,
            disconnect_session,
            download_file,
        ])
        .run(tauri::generate_context!())
        .expect("error while running the NovaSSH desktop app");
}
