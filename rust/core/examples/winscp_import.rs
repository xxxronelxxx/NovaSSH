fn main() -> Result<(), Box<dyn std::error::Error>> {
    let dir = std::env::temp_dir().join("nova-winscp-test");
    let _ = std::fs::remove_dir_all(&dir);
    std::env::set_var("NOVA_DATA_DIR", &dir);
    nova_core::api::init_data_dir(None)?;
    nova_core::api::create_vault("test-pass".into())?;

    let ini = std::env::args().nth(1).unwrap_or_else(|| "WinSCP.ini".into());
    let report = nova_core::api::import_winscp_ini(ini)?;
    println!(
        "sessions={} imported={} skipped={} groups={} passwords={} errors={}",
        report.sessions, report.imported, report.skipped, report.groups, report.passwords, report.errors.len()
    );
    for e in report.errors.iter().take(3) {
        println!("  ! {e}");
    }
    let book = nova_core::api::load_book()?;
    println!("book: {} servers, {} groups", book.servers.len(), book.groups.len());
    for g in book.groups.iter().take(5) {
        println!("  group: {}", g.name);
    }
    let sample = book.servers.iter().find(|s| s.name.contains("example"));
    if let Some(s) = sample {
        let secret = nova_core::api::get_secret(s.password_ref.clone().unwrap(), None)?;
        println!("sample {} -> password ok: {}", s.name, secret.is_some());
    }
    Ok(())
}
