//! Seeds an isolated test profile (vault + local test servers).
//!
//! Run with: `cargo run -p nova_core --example seed_profile -- <profile dir>`

use nova_core::api;
use nova_core::model::{Auth, AuthKind, Server};

fn main() -> Result<(), String> {
    let dir = std::env::args()
        .nth(1)
        .ok_or("usage: seed_profile <profile dir>")?;
    let info = api::init_data_dir(Some(dir))?;
    println!("data dir: {}", info.data_dir);

    // Master password for the test instance; the key is then wrapped with
    // DPAPI so the app opens without a prompt.
    if info.vault == "missing" {
        api::create_vault("test1234".into())?;
        println!("vault created");
    }
    let _ = api::unlock_vault("test1234".into());

    let mut sftp = Server::new("127.0.0.1", "test");
    sftp.name = "TEST SFTP (local)".into();
    sftp.port = 2222;
    sftp.auth = Auth {
        kind: AuthKind::Password,
        ..Auth::default()
    };
    sftp.password_ref = Some("pwd_test_sftp".into());
    sftp.remote_path = Some("/downloads".into());
    sftp.notes = Some("local paramiko test server".into());
    sftp.tags = vec!["test".into()];
    let sftp = api::save_server(sftp)?;
    api::set_secret("pwd_test_sftp".into(), "test123".into())?;

    let mut ftp = Server::new("127.0.0.1", "test");
    ftp.name = "TEST FTP (local)".into();
    ftp.port = 2121;
    ftp.auth = Auth {
        kind: AuthKind::Password,
        ..Auth::default()
    };
    ftp.password_ref = Some("pwd_test_ftp".into());
    ftp.remote_path = Some("/".into());
    ftp.protocol = Some("ftp".into());
    ftp.passive = Some(true);
    ftp.tags = vec!["test".into()];
    let ftp = api::save_server(ftp)?;
    api::set_secret("pwd_test_ftp".into(), "test123".into())?;

    api::remember_master_key()?;
    println!("servers: {} / {}", sftp.name, ftp.name);
    Ok(())
}
