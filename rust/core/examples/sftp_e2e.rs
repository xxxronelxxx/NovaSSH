//! End-to-end SFTP test: starts an in-process SSH server backed by a temp dir
//! and drives the real client stack (russh + SftpFs) against it.
//!
//! Run with: `cargo run --example sftp_e2e -p nova_core`

#[path = "support/sftp_server.rs"]
mod sftp_server;

use std::sync::Arc;

use nova_core::fs::sftp::SftpFs;
use nova_core::fs::Provider;
use nova_core::model::EntryKind;
use nova_core::ssh::{connect, ConnectAuth, ConnectOptions};

// ---------------------------------------------------------------------------
// Test driver
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = std::env::temp_dir().join(format!("nova-sftp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root)?;
    std::fs::write(root.join("hello.txt"), b"hello from the server")?;
    // `canonicalize` yields a verbatim path on Windows (`\?\C:\...`), so the
    // sandbox root must be canonical too for the `starts_with` guard to work.
    let root = std::fs::canonicalize(&root)?;

    let port = 2224u16;
    let _server = sftp_server::spawn(root.clone(), port);
    tokio::time::sleep(std::time::Duration::from_millis(400)).await;

    let opts = ConnectOptions {
        host: "127.0.0.1".into(),
        port,
        user: "tester".into(),
        auth: ConnectAuth::Password("secret".into()),
        ..Default::default()
    };

    // Wrong password must be rejected.
    let mut bad = opts.clone();
    bad.auth = ConnectAuth::Password("nope".into());
    match connect(&bad).await {
        Err(e) => println!(
            "auth reject : ok ({}..)",
            e.to_string().chars().take(28).collect::<String>()
        ),
        Ok(_) => return Err("server accepted a wrong password".into()),
    }

    let session = connect(&opts).await?;
    println!(
        "connected   : fingerprint recorded = {}",
        session.fingerprint.is_some()
    );

    let fs = SftpFs::new("test", session.sftp.clone());
    let provider = Provider::sftp(Arc::new(SftpFs::new("test", session.sftp.clone())));

    let listing = fs.list("/", true).await?;
    let names: Vec<_> = listing.entries.iter().map(|e| e.name.clone()).collect();
    println!("list        : {:?}", names);
    assert!(names.contains(&"hello.txt".to_string()));

    // Upload (client -> server), the path the UI uses for "upload".
    {
        use tokio::io::AsyncWriteExt;
        let mut w = fs.open_write("/upload.txt", false).await?;
        w.write_all(b"uploaded payload").await?;
        w.flush().await?;
    }
    let stat = fs.stat("/upload.txt").await?;
    assert_eq!(stat.size, 16);
    println!("upload      : {} bytes", stat.size);

    // Download (server -> client) and compare.
    {
        use tokio::io::AsyncReadExt;
        let mut r = fs.open_read("/upload.txt", 0).await?;
        let mut buf = String::new();
        r.read_to_string(&mut buf).await?;
        assert_eq!(buf, "uploaded payload");
        println!("download    : {:?}", buf);
    }

    // Directory + rename + recursive delete through the provider abstraction.
    fs.mkdir("/sub").await?;
    fs.rename("/upload.txt", "/sub/upload.txt").await?;
    let sub = provider.list("/sub", true).await?;
    assert_eq!(sub.entries.len(), 1);
    assert!(std::path::Path::new(&root.join("sub").join("upload.txt")).exists());
    println!("mkdir+rename: ok");

    provider.remove("/sub", true).await?;
    assert!(!root.join("sub").exists());
    println!("remove tree : ok");

    // Streaming copy between providers: SFTP -> local.
    let local_root = std::env::temp_dir().join(format!("nova-sftp-local-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&local_root);
    std::fs::create_dir_all(&local_root)?;
    let local = Provider::local();
    let mut stats = nova_core::task::CopyStats::default();
    nova_core::task::copy_path(
        &provider,
        "/hello.txt",
        &local,
        &local_root.join("hello.txt").to_string_lossy(),
        nova_core::task::DEFAULT_CHUNK,
        &mut stats,
        &mut |_| {},
        None,
        0,
        None,
        1,
    )
    .await?;
    assert_eq!(stats.bytes, 21);
    assert_eq!(
        std::fs::read(local_root.join("hello.txt"))?,
        b"hello from the server"
    );
    println!("copy sftp->local: {} bytes", stats.bytes);

    // Error path: missing file.
    assert!(fs.stat("/nope.txt").await.is_err());
    println!("error path  : ok");

    session.close().await?;
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&local_root);
    println!("OK: SFTP end-to-end passed");
    let _ = EntryKind::File;
    Ok(())
}
