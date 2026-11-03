//! Runs the in-process SFTP test server on port 2224 for manual UI checks.
//!
//! Run with: `cargo run --example serve_demo -p nova_core`

#[path = "support/sftp_server.rs"]
mod sftp_server;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = std::env::temp_dir().join("nova-serve-demo");
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("var/www"))?;
    std::fs::write(root.join("var/www/index.php"), b"<?php echo 'hello';\n")?;
    std::fs::write(root.join("var/www/app.js"), b"console.log('hi');\n")?;
    std::fs::write(root.join("var/www/nginx.conf"), b"server { listen 80; }\n")?;
    std::fs::write(root.join("var/www/photo.jpg"), vec![0u8; 4096])?;
    std::fs::create_dir_all(root.join("var/www/uploads"))?;
    std::fs::write(root.join("var/www/uploads/readme.txt"), b"uploads\n")?;

    println!(
        "serving {} on 127.0.0.1:2224 (tester/secret)",
        root.display()
    );
    sftp_server::spawn(root, 2224).await?;
    Ok(())
}
