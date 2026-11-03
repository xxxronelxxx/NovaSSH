//! Compares two local files through the same API the UI uses.
//! `cargo run -q --example compare_check -p nova_core`

use std::io::Write;

use nova_core::api::{compare_files, init_data_dir};
use nova_core::model::{CompareOptions, FileRef};

fn main() {
    let dir = std::env::temp_dir().join("nova-compare-check");
    std::fs::create_dir_all(&dir).unwrap();

    let left = dir.join("left.php");
    let right = dir.join("right.php");

    std::fs::File::create(&left)
        .unwrap()
        .write_all(
            "<h1>Заголовок</h1>\n\
             $color = 'red';\n\
             echo 'hello';\n\
             // old line\n"
                .as_bytes(),
        )
        .unwrap();
    std::fs::File::create(&right)
        .unwrap()
        .write_all(
            "<h1>Заголовок</h1>\n\
             $color = 'blue';\n\
             echo 'hello';\n"
                .as_bytes(),
        )
        .unwrap();

    let _ = init_data_dir(Some(
        dir.join("profile").to_string_lossy().to_string(),
    ));

    let result = compare_files(
        FileRef {
            session_id: None,
            archive_path: None,
            path: left.to_string_lossy().to_string(),
            label: Some("left.php".into()),
        },
        FileRef {
            session_id: None,
            archive_path: None,
            path: right.to_string_lossy().to_string(),
            label: Some("right.php".into()),
        },
        CompareOptions::default(),
    )
    .expect("compare");

    println!(
        "equal={} binary={} added={} removed={} changed={} rows={}",
        result.equal,
        result.binary,
        result.added,
        result.removed,
        result.changed,
        result.rows.len()
    );
    for row in &result.rows {
        let num = |line: &Option<nova_core::model::DiffLine>| {
            line.as_ref().map(|l| l.number.to_string()).unwrap_or_else(|| "-".into())
        };
        let text = |line: &Option<nova_core::model::DiffLine>| {
            line.as_ref().map(|l| l.text.clone()).unwrap_or_default()
        };
        println!(
            "{:<4} {:<4} {:<4} | {} || {}",
            row.kind,
            num(&row.left),
            num(&row.right),
            text(&row.left),
            text(&row.right)
        );
    }

    let left_row = result.rows.iter().find(|r| r.kind == "mod").unwrap();
    let left_words = &left_row.left.as_ref().unwrap().words;
    println!(
        "word spans: {:?}",
        left_words
            .iter()
            .map(|w| (w.text.clone(), w.changed))
            .collect::<Vec<_>>()
    );
}
