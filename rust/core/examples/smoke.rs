//! End-to-end smoke test of the FFI-facing API without Flutter.
//!
//! Run with: `cargo run --example smoke -p nova_core`

use nova_core::api as nova;
use nova_core::model::{Auth, AuthKind, ColorRule, ColorRules, Group, Server};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let dir = std::env::temp_dir().join(format!("nova-smoke-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::env::set_var("NOVA_DATA_DIR", &dir);

    let info = nova::init_data_dir(None)?;
    println!("data dir  : {}", info.data_dir);
    println!("vault     : {}", info.vault);
    println!("key wrap  : {}", info.key_wrap);

    nova::create_vault("smoke-master-pass".into())?;
    println!("vault now : {}", nova::vault_state()?);

    nova::set_secret("pwd_s_1".into(), "hunter2".into())?;
    assert_eq!(
        nova::get_secret("pwd_s_1".into(), None)?,
        Some("hunter2".to_string())
    );

    let group = nova::save_group(Group {
        id: String::new(),
        name: "Production".into(),
        parent: None,
        color: Some("#E5484D".into()),
        order: 0,
        expanded: true,
        icon: None,
    })?;
    println!("group id  : {}", group.id);

    let server = nova::save_server(Server {
        id: String::new(),
        group_id: Some(group.id.clone()),
        name: "web-01".into(),
        host: "127.0.0.1".into(),
        port: 22,
        user: "root".into(),
        auth: Auth {
            kind: AuthKind::Password,
            key_path: None,
            passphrase_ref: None,
        },
        password_ref: Some("pwd_s_1".into()),
        jump: None,
        encoding: None,
        remote_path: None,
        color: None,
        tags: vec!["prod".into()],
        terminal_profile: None,
        notes: None,
        last_connected: None,
        host_key_fingerprint: None,
        auth_failed: false,
        protocol: None,
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
    })?;
    println!("server id : {}", server.id);

    let book = nova::load_book()?;
    assert_eq!(book.servers.len(), 1);
    assert_eq!(book.groups.len(), 1);
    println!(
        "book      : {} server(s), {} group(s)",
        book.servers.len(),
        book.groups.len()
    );

    nova::remember_session(
        server.id.clone(),
        "/root/wb2".into(),
        "D:\\work\\wb2".into(),
    )?;
    let state = nova::load_session_state()?;
    let record = state.record(&server.id).expect("session record");
    assert_eq!(record.session.path, "/root/wb2");
    println!(
        "session   : {} | {}",
        record.session.path, record.session.local_path
    );

    nova::save_color_rules(ColorRules {
        version: 1,
        rules: vec![ColorRule {
            id: "php".into(),
            name: "PHP".into(),
            enabled: true,
            priority: 10,
            scope: "both".into(),
            pattern: "*.php".into(),
            is_regex: false,
            fg: Some("#FF7B72".into()),
            bg: None,
            bold: false,
            italic: false,
            underline: false,
        }],
    })?;
    assert_eq!(nova::load_color_rules()?.rules.len(), 1);

    // Local filesystem through the same API the UI uses.
    let listing = nova::list_local(dir.to_string_lossy().to_string(), true)?;
    println!(
        "listing   : {} entries in {}",
        listing.entries.len(),
        listing.path
    );
    assert!(listing.entries.iter().any(|e| e.name == "servers.json"));

    println!("volumes   : {}", nova::volumes().len());
    println!("home      : {}", nova::home_local()?);

    // Handler the secrets file really is encrypted on disk.
    let raw = std::fs::read_to_string(dir.join("secrets.json"))?;
    assert!(
        !raw.contains("hunter2"),
        "plaintext password leaked to disk"
    );

    // Device-wrapped key (DPAPI on Windows) must round-trip.
    nova::remember_master_key()?;
    nova::lock_vault()?;
    assert_eq!(nova::vault_state()?, "locked");
    assert!(
        nova::unlock_vault_with_device()?,
        "device key should unlock the vault"
    );
    println!("device key: works");
    nova::lock_vault()?;
    assert!(nova::unlock_vault("wrong".into()).is_err());
    nova::unlock_vault("smoke-master-pass".into())?;
    assert_eq!(
        nova::get_secret("pwd_s_1".into(), None)?,
        Some("hunter2".to_string())
    );

    let _ = std::fs::remove_dir_all(&dir);
    println!("OK: smoke test passed");
    Ok(())
}
