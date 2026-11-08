mod commands;

use tauri::Manager;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            #[cfg(windows)]
            {
                use window_vibrancy::apply_mica;
                if let Some(window) = app.get_webview_window("main") {
                    let _ = apply_mica(&window, Some(true));
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::init_app,
            commands::ensure_device_vault,
            commands::load_settings,
            commands::save_settings,
            commands::volumes,
            commands::list_servers,
            commands::save_server,
            commands::delete_server,
            commands::save_group,
            commands::delete_group,
            commands::connect_server,
            commands::cancel_connect,
            commands::connect_stage,
            commands::disconnect_session,
            commands::home_local,
            commands::list_local,
            commands::list_remote,
            commands::mkdir,
            commands::rename,
            commands::remove,
            commands::copy_local,
            commands::transfer_file,
            commands::cancel_transfer,
            commands::preview,
            commands::save_text,
            commands::checksum,
            commands::find_files,
            commands::chmod,
            commands::probe_server,
            commands::check_server_access,
            commands::set_secret,
            commands::get_secret,
            commands::delete_secret,
            commands::load_color_rules,
            commands::save_color_rules,
            commands::load_snippets,
            commands::save_snippet,
            commands::delete_snippet,
            commands::save_snippet_order,
            commands::load_ai_settings,
            commands::save_ai_settings,
            commands::load_session_state,
            commands::save_open_sessions,
            commands::remember_session,
            commands::open_shell,
            commands::shell_write,
            commands::shell_poll,
            commands::shell_close,
            commands::export_profile,
            commands::import_profile,
            commands::credentials_preview,
            commands::export_credentials,
            commands::sync_export_json,
            commands::import_sync,
            commands::start_sync_share,
            commands::stop_sync_share,
            commands::sync_share_token,
        ])
        .run(tauri::generate_context!())
        .expect("error while running the NovaSSH desktop app");
}
