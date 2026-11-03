//! Ad-hoc probe for the S3 provider against the local moto server.
use nova_core::fs::s3::S3Fs;

fn main() -> Result<(), String> {
    let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
    let fs = S3Fs::new(
        "http://127.0.0.1:9020",
        "us-east-1",
        "nova",
        "test",
        "test12345",
        true,
        "",
    )
    .map_err(|e| e.to_string())?;

    let listing = rt.block_on(fs.list("/", true)).map_err(|e| e.to_string())?;
    for e in &listing.entries {
        println!("{} {:?} {}", e.path, e.kind, e.size);
    }
    println!("--- rename ---");
    rt.block_on(fs.rename("space name.txt", "space renamed.txt"))
        .map_err(|e| format!("rename failed: {e}"))?;
    println!("renamed ok");
    let listing = rt.block_on(fs.list("/", true)).map_err(|e| e.to_string())?;
    for e in &listing.entries {
        println!("{} {:?}", e.path, e.kind);
    }
    Ok(())
}
