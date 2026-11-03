//! Live FTPS smoke check: `cargo run -q --example ftps_check -p nova_core`.
//!
//! Uses the public rebex test server (explicit FTPS on 21).

use nova_core::fs::ftp::{FtpFs, FtpTls};
use nova_core::model::EntryKind;

#[tokio::main]
async fn main() {
    for (mode, host, port) in [
        (FtpTls::Off, "test.rebex.net", 21u16),
        (FtpTls::Explicit, "test.rebex.net", 21u16),
        (FtpTls::Implicit, "test.rebex.net", 990u16),
    ] {
        let ftp = FtpFs::new(
            host.into(),
            port,
            "demo".into(),
            "password".into(),
            true,
        )
        .with_tls(mode, false);
        match ftp.list("/pub", true).await {
            Ok(listing) => {
                println!("{mode:?}: {} entries", listing.entries.len());
                for e in listing.entries.iter().take(5) {
                    println!(
                        "  {} {}",
                        if matches!(e.kind, EntryKind::Dir) { "d" } else { "-" },
                        e.name
                    );
                }
                match ftp.read_all("/pub/example/readme.txt").await {
                    Ok(data) => println!("  download: {} bytes", data.len()),
                    Err(e) => println!("  download FAILED {e}"),
                }
            }
            Err(e) => println!("{mode:?}: FAILED {e}"),
        }
    }
}
