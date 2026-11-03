//! Verifies archive extraction to a folder without the Flutter UI.
//! Run: cargo run --example extract_check -p nova_core -- demo.zip out
use std::io::Write;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let archive_path = std::env::args().nth(1).expect("archive path");
    let out_dir = std::env::args().nth(2).expect("output dir");

    let archive = nova_core::archive::open(&archive_path)?;
    let name = std::path::Path::new(&archive_path)
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "archive".into());
    let root = std::path::Path::new(&out_dir).join(&name);

    let files = archive.files_under("");
    println!("extracting {} file(s) into {}", files.len(), root.display());

    for file in &files {
        let dest = root.join(file);
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let bytes = archive.read_entry(file)?;
        let mut f = std::fs::File::create(&dest)?;
        f.write_all(&bytes)?;
        println!("  {file} -> {} bytes", bytes.len());
    }
    println!("done");
    Ok(())
}
