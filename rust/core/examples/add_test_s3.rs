//! Adds (or updates) an S3 test server in an isolated test profile.
//!
//! `cargo run -p nova_core --example add_test_s3 -- <profile dir> <endpoint>`

use nova_core::api;
use nova_core::model::{Auth, AuthKind, Server};

fn main() -> Result<(), String> {
    let profile = std::env::args()
        .nth(1)
        .ok_or("usage: add_test_s3 <profile dir> [endpoint]")?;
    let endpoint = std::env::args()
        .nth(2)
        .unwrap_or_else(|| "http://127.0.0.1:9020".to_string());

    api::init_data_dir(Some(profile))?;
    api::unlock_vault("test1234".into())?;

    let mut server = Server::new(endpoint.clone(), "");
    server.name = "TEST S3 (local)".into();
    server.protocol = Some("s3".into());
    server.port = 443;
    server.auth = Auth {
        kind: AuthKind::Password,
        ..Auth::default()
    };
    server.s3_endpoint = Some(endpoint);
    server.s3_region = Some("us-east-1".into());
    server.s3_bucket = Some("nova".into());
    server.s3_path_style = Some(true);
    server.s3_access_ref = Some("s3a_test".into());
    server.s3_secret_ref = Some("s3s_test".into());
    server.tags = vec!["test".into()];
    let saved = api::save_server(server)?;

    api::set_secret("s3a_test".into(), "test".into())?;
    api::set_secret("s3s_test".into(), "test12345".into())?;
    println!("saved {}", saved.name);
    Ok(())
}
