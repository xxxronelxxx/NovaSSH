//! Round-trip check for the QR sync payload.
//! `cargo run -q --example sync_check -p nova_core`

use nova_core::api::{import_sync, init_data_dir, sync_export_json};

fn main() {
    let dir = std::env::temp_dir().join("nova-sync-check");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    init_data_dir(Some(dir.to_string_lossy().to_string())).expect("init");

    let payload = r#"{
      "version": 1,
      "exported_at": 1,
      "groups": [{"id":"g_a","name":"Сайты","parent":null,"color":null,"order":0,"expanded":true,"icon":null}],
      "servers": [
        {"id":"s_a","groupId":"g_a","name":"alpha","host":"10.0.0.1","port":22,"user":"root",
         "auth":{"type":"password","keyPath":null,"passphraseRef":null},
         "passwordRef":"pwd_s_a","jump":null,"encoding":null,"remotePath":null,"color":null,
         "tags":[],"terminalProfile":null,"notes":null,"lastConnected":null,
         "hostKeyFingerprint":null,"authFailed":false,"protocol":"sftp","ftpsMode":null,
         "ftpsInsecure":null,"passive":null,"s3Endpoint":null,"s3Region":null,"s3Bucket":null,
         "s3Prefix":null,"s3PathStyle":null,"s3AccessRef":null,"s3SecretRef":null,
         "reachable":null,"checkedAt":null},
        {"id":"s_b","groupId":"g_a","name":"beta","host":"10.0.0.2","port":22,"user":"root",
         "auth":{"type":"password","keyPath":null,"passphraseRef":null},
         "passwordRef":"pwd_s_b","jump":null,"encoding":null,"remotePath":null,"color":null,
         "tags":[],"terminalProfile":null,"notes":null,"lastConnected":null,
         "hostKeyFingerprint":null,"authFailed":false,"protocol":"sftp","ftpsMode":null,
         "ftpsInsecure":null,"passive":null,"s3Endpoint":null,"s3Region":null,"s3Bucket":null,
         "s3Prefix":null,"s3PathStyle":null,"s3AccessRef":null,"s3SecretRef":null,
         "reachable":null,"checkedAt":null}
      ]
    }"#;

    let first = import_sync(payload.to_string()).expect("first import");
    println!(
        "first: servers={} groups={} secrets={} settings={}",
        first.servers, first.groups, first.secrets, first.settings
    );

    let second = import_sync(payload.to_string()).expect("second import");
    println!(
        "second: servers={} groups={} secrets={} settings={}",
        second.servers, second.groups, second.secrets, second.settings
    );

    let exported = sync_export_json(false).expect("export");
    println!("exported bytes={} has_secrets={}", exported.len(), exported.contains("\"secrets\":{"));
    let book = nova_core::api::load_book().expect("book");
    println!("book: servers={} groups={}", book.servers.len(), book.groups.len());
    for server in &book.servers {
        let group = book
            .groups
            .iter()
            .find(|g| Some(&g.id) == server.group_id.as_ref())
            .map(|g| g.name.clone())
            .unwrap_or_else(|| "-".into());
        println!("  {} -> {}", server.name, group);
    }

    assert_eq!(first.servers, 2);
    assert_eq!(first.groups, 1);
    assert_eq!(second.servers, 0, "duplicates must be skipped");
    assert_eq!(book.servers.len(), 2);
}
