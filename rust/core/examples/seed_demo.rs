//! Seeds an isolated demo profile (vault + groups + servers) for UI checks.
//!
//! `NOVA_DATA_DIR` must point at a throw-away directory; the example never
//! touches the real user profile.

use nova_core::api as nova;
use nova_core::model::{Auth, AuthKind, ColorRule, ColorRules, Group, Server, Settings};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let dir = std::env::var("NOVA_DATA_DIR").expect("set NOVA_DATA_DIR to a temp directory");
    println!("seeding {dir}");

    nova::init_data_dir(Some(dir))?;
    if nova::vault_state()? == "missing" {
        nova::create_vault("nova-demo-pass".into())?;
        nova::set_secret("pwd_s_demo1".into(), "secret".into())?;
    }
    nova::unlock_vault("nova-demo-pass".into())?;
    // Wraps the master key with DPAPI so the app can unlock silently on start.
    nova::remember_master_key()?;

    let prod = nova::save_group(Group {
        id: "g_demo_prod".into(),
        name: "Production".into(),
        parent: None,
        color: Some("#E5484D".into()),
        order: 0,
        expanded: true,
        icon: None,
    })?;
    let staging = nova::save_group(Group {
        id: "g_demo_stage".into(),
        name: "Staging".into(),
        parent: None,
        color: Some("#D29922".into()),
        order: 1,
        expanded: true,
        icon: None,
    })?;

    let make = |id: &str,
                name: &str,
                host: &str,
                user: &str,
                group: &str,
                tags: Vec<&str>,
                color: &str| Server {
        id: id.into(),
        group_id: Some(group.into()),
        name: name.into(),
        host: host.into(),
        port: 22,
        user: user.into(),
        auth: Auth {
            kind: AuthKind::Password,
            key_path: None,
            passphrase_ref: None,
        },
        password_ref: Some("pwd_s_demo1".into()),
        jump: None,
        encoding: None,
        remote_path: Some("/var/www".into()),
        color: Some(color.into()),
        tags: tags.into_iter().map(str::to_string).collect(),
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
    };

    nova::save_server(make(
        "s_demo1",
        "web-01",
        "10.0.0.5",
        "deploy",
        &prod.id,
        vec!["prod", "nginx"],
        "#4C8DFF",
    ))?;
    nova::save_server(make(
        "s_demo2",
        "db-01",
        "10.0.0.6",
        "postgres",
        &prod.id,
        vec!["prod", "db"],
        "#7FB4FF",
    ))?;
    // Live entry backed by `cargo run --example serve_demo` (tester/secret on :2224).
    nova::save_server(make(
        "s_demo_local",
        "aaa-local",
        "127.0.0.1",
        "tester",
        &prod.id,
        vec!["local"],
        "#56D4DD",
    ))?;
    let mut local = nova::load_book()?
        .servers
        .into_iter()
        .find(|s| s.id == "s_demo_local")
        .expect("local demo server");
    local.port = 2224;
    local.remote_path = Some("/var/www".into());
    nova::save_server(local)?;

    nova::save_server(make(
        "s_demo3",
        "stage",
        "stage.devspb.ru",
        "root",
        &staging.id,
        vec!["stage"],
        "#8BE28B",
    ))?;

    // A couple of colour rules to show the highlight working.
    nova::save_color_rules(ColorRules {
        version: 1,
        rules: vec![
            ColorRule {
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
            },
            ColorRule {
                id: "conf".into(),
                name: "Configs".into(),
                enabled: true,
                priority: 20,
                scope: "remote".into(),
                pattern: "*.{conf,ini,yml}".into(),
                is_regex: false,
                fg: Some("#D2A8FF".into()),
                bg: None,
                bold: false,
                italic: false,
                underline: false,
            },
        ],
    })?;

    let mut settings: Settings = nova::load_settings()?;
    settings.window.theme = "dark".into();
    nova::save_settings(settings)?;

    println!(
        "seed done: {} servers, {} groups",
        nova::load_book()?.servers.len(),
        nova::load_book()?.groups.len()
    );
    Ok(())
}
