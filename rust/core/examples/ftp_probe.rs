//! Ad-hoc probe for the FTP provider against the local test server.
use nova_core::fs::ftp::FtpFs;

fn main() -> Result<(), String> {
    let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
    let fs = FtpFs::new(
        "127.0.0.1".into(),
        2121,
        "test".into(),
        "test123".into(),
        true,
    );
    let listing = rt.block_on(fs.list("/", true)).map_err(|e| e.to_string())?;
    for e in &listing.entries {
        println!("list: {} {:?} {}", e.path, e.kind, e.size);
    }
    for p in ["/root.txt", "/space name.txt", "/ftpdir"] {
        match rt.block_on(fs.stat(p)) {
            Ok(entry) => println!("stat {p}: {:?} size={}", entry.kind, entry.size),
            Err(e) => println!("stat {p}: error {e}"),
        }
    }
    Ok(())
}
