//! Line-oriented file comparison for the "Compare" window (Ctrl+F3).
//!
//! The comparison works on bytes, so it does not care where the file came from:
//! the API layer reads local files, remote files and archive entries through
//! `Provider::open_read` and hands the buffers to [`compare`].
//!
//! Text vs binary, BOMs and line endings are normalised here; the diff itself
//! comes from the `similar` crate (Patience, which reads code better than
//! Myers). Changed line pairs are additionally diffed word by word so the UI
//! can highlight what exactly changed inside the line.

use similar::{DiffOp, TextDiff};

use crate::model::{CompareResult, DiffLine, DiffRow, DiffWord};

/// Hard cap on the rows returned to the UI.
const MAX_ROWS: usize = 20_000;
/// Longer lines are not diffed word by word (minified JS would crawl).
const MAX_WORD_DIFF_LEN: usize = 2_000;

#[derive(Debug, Clone, Copy, Default)]
pub struct Options {
    pub ignore_whitespace: bool,
    pub ignore_case: bool,
}

enum Decoded {
    Text(String),
    Binary,
}

/// Compares two buffers and returns rows ready for side-by-side rendering.
pub fn compare(left: &[u8], right: &[u8], opts: &Options) -> CompareResult {
    match (decode(left), decode(right)) {
        (Decoded::Text(l), Decoded::Text(r)) => compare_text(&l, &r, opts),
        _ => CompareResult {
            // Binary files are reported with sizes and hashes only.
            equal: left == right,
            binary: true,
            ..CompareResult::default()
        },
    }
}

impl Default for CompareResult {
    fn default() -> Self {
        Self {
            left_label: String::new(),
            right_label: String::new(),
            left_size: 0,
            right_size: 0,
            equal: false,
            binary: false,
            truncated: false,
            added: 0,
            removed: 0,
            changed: 0,
            left_hash: None,
            right_hash: None,
            left_eol: "\n".into(),
            right_eol: "\n".into(),
            left_bom: false,
            right_bom: false,
            left_final_newline: true,
            right_final_newline: true,
            left_read_only: None,
            right_read_only: None,
            rows: Vec::new(),
        }
    }
}

fn decode(bytes: &[u8]) -> Decoded {
    if let Some(rest) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return Decoded::Text(String::from_utf8_lossy(rest).into_owned());
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        return Decoded::Text(utf16(rest, true));
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        return Decoded::Text(utf16(rest, false));
    }
    // NUL bytes in the head of the file mean binary data.
    if bytes.iter().take(8 * 1024).any(|b| *b == 0) {
        return Decoded::Binary;
    }
    Decoded::Text(String::from_utf8_lossy(bytes).into_owned())
}

fn utf16(bytes: &[u8], little_endian: bool) -> String {
    let units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|pair| {
            if little_endian {
                u16::from_le_bytes([pair[0], pair[1]])
            } else {
                u16::from_be_bytes([pair[0], pair[1]])
            }
        })
        .collect();
    String::from_utf16_lossy(&units)
}

fn compare_text(left: &str, right: &str, opts: &Options) -> CompareResult {
    let left_text = normalise_newlines(left);
    let right_text = normalise_newlines(right);
    let left_lines: Vec<&str> = left_text.lines().collect();
    let right_lines: Vec<&str> = right_text.lines().collect();

    let left_keys: Vec<String> = left_lines.iter().map(|l| key(l, opts)).collect();
    let right_keys: Vec<String> = right_lines.iter().map(|l| key(l, opts)).collect();
    let left_slice: Vec<&str> = left_keys.iter().map(String::as_str).collect();
    let right_slice: Vec<&str> = right_keys.iter().map(String::as_str).collect();

    let diff = TextDiff::configure()
        .algorithm(similar::Algorithm::Patience)
        .diff_slices(&left_slice[..], &right_slice[..]);

    let mut rows: Vec<DiffRow> = Vec::new();
    let mut added = 0u32;
    let mut removed = 0u32;
    let mut changed = 0u32;

    for op in diff.ops() {
        match *op {
            DiffOp::Equal {
                old_index,
                new_index,
                len,
            } => {
                for k in 0..len {
                    rows.push(DiffRow {
                        kind: "equal".into(),
                        left: Some(line(left_lines[old_index + k], old_index + k, &[])),
                        right: Some(line(right_lines[new_index + k], new_index + k, &[])),
                    });
                }
            }
            DiffOp::Delete {
                old_index, old_len, ..
            } => {
                for k in 0..old_len {
                    rows.push(DiffRow {
                        kind: "del".into(),
                        left: Some(line(left_lines[old_index + k], old_index + k, &[])),
                        right: None,
                    });
                    removed += 1;
                }
            }
            DiffOp::Insert {
                new_index, new_len, ..
            } => {
                for k in 0..new_len {
                    rows.push(DiffRow {
                        kind: "add".into(),
                        left: None,
                        right: Some(line(right_lines[new_index + k], new_index + k, &[])),
                    });
                    added += 1;
                }
            }
            DiffOp::Replace {
                old_index,
                old_len,
                new_index,
                new_len,
            } => {
                let paired = old_len.min(new_len);
                for k in 0..paired {
                    let (lw, rw) = word_spans(left_lines[old_index + k], right_lines[new_index + k]);
                    rows.push(DiffRow {
                        kind: "mod".into(),
                        left: Some(line(left_lines[old_index + k], old_index + k, &lw)),
                        right: Some(line(right_lines[new_index + k], new_index + k, &rw)),
                    });
                    changed += 1;
                }
                // The longer side keeps its extra lines as pure add/remove.
                for k in paired..old_len {
                    rows.push(DiffRow {
                        kind: "del".into(),
                        left: Some(line(left_lines[old_index + k], old_index + k, &[])),
                        right: None,
                    });
                    removed += 1;
                }
                for k in paired..new_len {
                    rows.push(DiffRow {
                        kind: "add".into(),
                        left: None,
                        right: Some(line(right_lines[new_index + k], new_index + k, &[])),
                    });
                    added += 1;
                }
            }
        }
    }

    let mut truncated = false;
    if rows.len() > MAX_ROWS {
        rows.truncate(MAX_ROWS);
        truncated = true;
    }

    CompareResult {
        equal: added == 0 && removed == 0 && changed == 0,
        added,
        removed,
        changed,
        truncated,
        rows,
        ..CompareResult::default()
    }
}

fn line(text: &str, index: usize, words: &[DiffWord]) -> DiffLine {
    DiffLine {
        number: index as u32 + 1,
        text: text.to_string(),
        words: words.to_vec(),
    }
}

fn normalise_newlines(text: &str) -> String {
    if text.contains('\r') {
        text.replace("\r\n", "\n").replace('\r', "\n")
    } else {
        text.to_string()
    }
}

/// Comparison key: what actually decides whether two lines are "equal".
fn key(line: &str, opts: &Options) -> String {
    let mut value = if opts.ignore_whitespace {
        line.split_whitespace().collect::<Vec<_>>().join(" ")
    } else {
        line.to_string()
    };
    if opts.ignore_case {
        value = value.to_lowercase();
    }
    value
}

/// Splits a line into runs of whitespace and non-whitespace, keeping the exact
/// original text so the highlighted spans can be concatenated back.
fn words_of(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0usize;
    let mut prev_space: Option<bool> = None;
    for (index, ch) in text.char_indices() {
        let space = ch.is_whitespace();
        match prev_space {
            None => prev_space = Some(space),
            Some(previous) if previous != space => {
                out.push(&text[start..index]);
                start = index;
                prev_space = Some(space);
            }
            _ => {}
        }
    }
    if start < text.len() {
        out.push(&text[start..]);
    }
    out
}

fn word_spans(left: &str, right: &str) -> (Vec<DiffWord>, Vec<DiffWord>) {
    if left.len() > MAX_WORD_DIFF_LEN || right.len() > MAX_WORD_DIFF_LEN {
        return (Vec::new(), Vec::new());
    }
    if left.is_empty() || right.is_empty() {
        return (Vec::new(), Vec::new());
    }

    let left_words = words_of(left);
    let right_words = words_of(right);
    let diff = TextDiff::configure().diff_slices(&left_words[..], &right_words[..]);

    let mut left_spans: Vec<DiffWord> = Vec::new();
    let mut right_spans: Vec<DiffWord> = Vec::new();

    for op in diff.ops() {
        match *op {
            DiffOp::Equal {
                old_index,
                new_index,
                len,
            } => {
                for k in 0..len {
                    left_spans.push(DiffWord {
                        text: left_words[old_index + k].to_string(),
                        changed: false,
                    });
                    right_spans.push(DiffWord {
                        text: right_words[new_index + k].to_string(),
                        changed: false,
                    });
                }
            }
            DiffOp::Delete {
                old_index, old_len, ..
            } => {
                for k in 0..old_len {
                    left_spans.push(DiffWord {
                        text: left_words[old_index + k].to_string(),
                        changed: true,
                    });
                }
            }
            DiffOp::Insert {
                new_index, new_len, ..
            } => {
                for k in 0..new_len {
                    right_spans.push(DiffWord {
                        text: right_words[new_index + k].to_string(),
                        changed: true,
                    });
                }
            }
            DiffOp::Replace {
                old_index,
                old_len,
                new_index,
                new_len,
            } => {
                for k in 0..old_len {
                    left_spans.push(DiffWord {
                        text: left_words[old_index + k].to_string(),
                        changed: true,
                    });
                }
                for k in 0..new_len {
                    right_spans.push(DiffWord {
                        text: right_words[new_index + k].to_string(),
                        changed: true,
                    });
                }
            }
        }
    }

    (left_spans, right_spans)
}

/// Text metadata of one side, so the editor can save the file back unchanged.
pub struct TextMeta {
    pub eol: String,
    pub bom: bool,
    pub final_newline: bool,
    pub read_only: Option<String>,
}

pub fn text_meta(bytes: &[u8], archive: bool) -> TextMeta {
    let mut meta = TextMeta {
        eol: "\n".to_string(),
        bom: false,
        final_newline: true,
        read_only: None,
    };
    if bytes.starts_with(&[0xFF, 0xFE]) || bytes.starts_with(&[0xFE, 0xFF]) {
        meta.read_only = Some("Файл в UTF-16 — сохранение пока не поддерживается".into());
        return meta;
    }
    if archive {
        meta.read_only = Some("Файл внутри архива — сохранение недоступно".into());
    }
    meta.bom = bytes.starts_with(&[0xEF, 0xBB, 0xBF]);
    if let Some(pos) = bytes.iter().position(|b| *b == b'\n') {
        if pos > 0 && bytes[pos - 1] == b'\r' {
            meta.eol = "\r\n".to_string();
        }
    }
    meta.final_newline = matches!(bytes.last(), Some(b'\n') | Some(b'\r'));
    meta
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmp(left: &str, right: &str) -> CompareResult {
        compare(left.as_bytes(), right.as_bytes(), &Options::default())
    }

    #[test]
    fn identical_files_have_no_differences() {
        let result = cmp("alpha\nbeta\n", "alpha\nbeta\n");
        assert!(result.equal);
        assert!(!result.binary);
        assert_eq!(result.rows.len(), 2);
        assert!(result.rows.iter().all(|r| r.kind == "equal"));
    }

    #[test]
    fn crlf_and_lf_are_the_same_text() {
        let result = cmp("alpha\r\nbeta\r\n", "alpha\nbeta\n");
        assert!(result.equal, "line endings must not count as a change");
    }

    #[test]
    fn added_and_removed_lines_are_counted() {
        let result = cmp("one\ntwo\n", "one\ntwo\nthree\n");
        assert_eq!(result.added, 1);
        assert_eq!(result.removed, 0);
        assert_eq!(result.rows.last().unwrap().kind, "add");

        let result = cmp("one\ntwo\n", "one\n");
        assert_eq!(result.removed, 1);
        assert_eq!(result.rows.last().unwrap().kind, "del");
    }

    #[test]
    fn modified_lines_are_paired_and_split_into_words() {
        let result = cmp("color: red;\n", "color: blue;\n");
        assert_eq!(result.changed, 1);
        assert_eq!(result.added, 0);
        let row = &result.rows[0];
        assert_eq!(row.kind, "mod");
        let left = row.left.as_ref().unwrap();
        let right = row.right.as_ref().unwrap();
        assert!(!left.words.is_empty());
        // The unchanged words stay unhighlighted, the changed one is marked.
        assert!(left.words.iter().any(|w| w.changed));
        assert!(left.words.iter().any(|w| !w.changed));
        assert!(right.words.iter().any(|w| w.text.contains("blue") && w.changed));
        // Spans must rebuild the original line exactly.
        assert_eq!(
            left.words.iter().map(|w| w.text.as_str()).collect::<String>(),
            "color: red;"
        );
    }

    #[test]
    fn whitespace_and_case_can_be_ignored() {
        let strict = cmp("a  =  1\n", "a = 1\n");
        assert_eq!(strict.changed, 1);

        let loose = compare(
            b"a  =  1\n",
            b"A = 1\n",
            &Options {
                ignore_whitespace: true,
                ignore_case: true,
            },
        );
        assert!(loose.equal, "normalised lines must match");
    }

    #[test]
    fn binary_files_are_not_diffed() {
        let result = compare(&[0x00, 0x01, 0x02], &[0x00, 0x01, 0x03], &Options::default());
        assert!(result.binary);
        assert!(!result.equal);
        assert!(result.rows.is_empty());
    }

    #[test]
    fn utf8_bom_is_stripped() {
        let result = compare(
            b"\xEF\xBB\xBFhello\n",
            b"hello\n",
            &Options::default(),
        );
        assert!(result.equal);
        assert_eq!(result.rows[0].left.as_ref().unwrap().text, "hello");
    }

    #[test]
    fn utf16_text_is_decoded() {
        let mut bytes = vec![0xFF, 0xFE];
        for unit in "hi\n".encode_utf16() {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }
        let result = compare(&bytes, b"hi\n", &Options::default());
        assert!(!result.binary);
        assert!(result.equal);
    }

    #[test]
    fn text_meta_detects_eol_bom_and_final_newline() {
        let meta = text_meta(b"a\r\nb\r\n", false);
        assert_eq!(meta.eol, "\r\n");
        assert!(!meta.bom);
        assert!(meta.final_newline);
        assert!(meta.read_only.is_none());

        let meta = text_meta(b"\xEF\xBB\xBFa\nb", false);
        assert!(meta.bom);
        assert!(!meta.final_newline);

        assert!(text_meta(b"a\n", true).read_only.is_some());

        let mut utf16 = vec![0xFF, 0xFE];
        utf16.extend_from_slice(&[b'a', 0, b'\n', 0]);
        assert!(text_meta(&utf16, false).read_only.is_some());
    }

    /// The compare window rebuilds both documents from the rows, so every line
    /// must appear exactly once and in order.
    #[test]
    fn rows_rebuild_both_documents() {
        let left = "one\ntwo\nthree\n";
        let right = "one\nTWO\nthree\nfour\n";
        let result = compare(left.as_bytes(), right.as_bytes(), &Options::default());

        let joined = |side: u8| -> String {
            let parts: Vec<&str> = result
                .rows
                .iter()
                .filter_map(|row| {
                    let line = if side == 0 { row.left.as_ref() } else { row.right.as_ref() };
                    line.map(|l| l.text.as_str())
                })
                .collect();
            format!("{}\n", parts.join("\n"))
        };

        assert_eq!(joined(0), left);
        assert_eq!(joined(1), right);
    }

    #[test]
    fn the_row_list_is_capped() {
        let left: String = (0..MAX_ROWS + 10).map(|i| format!("{i}\n")).collect();
        let result = cmp(&left, "");
        assert!(result.truncated);
        assert_eq!(result.rows.len(), MAX_ROWS);
    }
}
