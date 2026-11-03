//! Measures sequential vs parallel SFTP uploads against a local test server.
//!
//! `cargo run -p nova_core --release --example sftp_bench -- <port> <host> <user> <pass>`

use std::sync::Arc;
use std::time::Instant;

use nova_core::fs::sftp::SftpFs;
use nova_core::fs::Provider;
use nova_core::ssh::{connect, ConnectAuth, ConnectOptions};
use nova_core::task::{self, CopyStats, DEFAULT_CHUNK};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let port: u16 = args.next().unwrap_or_else(|| "2222".into()).parse()?;
    let host = args.next().unwrap_or_else(|| "127.0.0.1".into());
    let user = args.next().unwrap_or_else(|| "test".into());
    let pass = args.next().unwrap_or_else(|| "test123".into());

    let size_mb: usize = std::env::var("BENCH_MB")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(200);

    let local_dir = std::env::temp_dir().join(format!("nova-bench-{}", std::process::id()));
    std::fs::create_dir_all(&local_dir)?;
    let local_file = local_dir.join("bench.bin");
    if !local_file.exists() {
        println!("creating {size_mb} MiB test file…");
        let chunk = vec![0xA5u8; 1024 * 1024];
        let mut file = std::fs::File::create(&local_file)?;
        for _ in 0..size_mb {
            std::io::Write::write_all(&mut file, &chunk)?;
        }
    }

    let opts = ConnectOptions {
        host,
        port,
        user,
        auth: ConnectAuth::Password(pass),
        ..Default::default()
    };
    let session = connect(&opts).await?;
    let remote = Provider::sftp(Arc::new(SftpFs::new("bench", session.sftp.clone())));
    let local = Provider::local();
    let local_path = local_file.to_string_lossy().to_string();

    for parts in [1u32, 4, 8] {
        let remote_path = format!("/bench_{parts}.bin");
        let _ = remote.remove(&remote_path, false).await;
        let mut stats = CopyStats::default();
        let started = Instant::now();
        task::copy_path(
            &local,
            &local_path,
            &remote,
            &remote_path,
            DEFAULT_CHUNK,
            &mut stats,
            &mut |_| {},
            None,
            0,
            None,
            parts,
        )
        .await?;
        let elapsed = started.elapsed().as_secs_f64();
        let mib = size_mb as f64 / elapsed;
        println!(
            "parts={parts:>2}: {elapsed:6.2} s  {mib:7.1} MiB/s  bytes={}",
            stats.bytes
        );
        let _ = remote.remove(&remote_path, false).await;
    }

    let _ = session.close().await;
    let _ = std::fs::remove_dir_all(&local_dir);
    Ok(())
}
