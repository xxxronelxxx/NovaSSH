fn main() {
    let path = std::env::args().nth(1).expect("archive path");
    match nova_core::archive::open(&path) {
        Ok(a) => {
            let root = a.list("", true).unwrap();
            println!("root entries: {:?}", root.entries.iter().map(|e| e.name.clone()).collect::<Vec<_>>());
            for e in &root.entries {
                if e.kind == nova_core::model::EntryKind::Dir {
                    let sub = a.list(&e.path, true).unwrap();
                    println!("  {}/ -> {:?}", e.name, sub.entries.iter().map(|x| x.name.clone()).collect::<Vec<_>>());
                }
            }
        }
        Err(e) => println!("ERROR: {e}"),
    }
}
