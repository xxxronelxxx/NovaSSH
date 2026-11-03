//! Small helpers shared by every subsystem.

use std::time::{SystemTime, UNIX_EPOCH};

use crate::model::{Entry, SortBy, SortSpec};

/// Live connection stage shared between the SSH layer and the UI:
/// 0 idle, 1 dialling, 2 handshake, 3 auth, 4 sftp, 5 ready.
pub static CONNECT_STAGE: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

pub fn set_connect_stage(stage: u8) {
    CONNECT_STAGE.store(stage, std::sync::atomic::Ordering::Relaxed);
}

pub fn connect_stage() -> u8 {
    CONNECT_STAGE.load(std::sync::atomic::Ordering::Relaxed)
}

pub fn new_id(prefix: &str) -> String {
    let id = uuid::Uuid::new_v4().simple().to_string();
    format!("{prefix}_{}", &id[..12])
}

pub fn unix_ms(t: SystemTime) -> i64 {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_millis() as i64,
        Err(_) => 0,
    }
}

pub fn now_ms() -> i64 {
    unix_ms(SystemTime::now())
}

/// Join a POSIX-ish logical path. Keeps the leading separator style of `base`.
pub fn join(base: &str, name: &str) -> String {
    if name.starts_with('/') || (name.len() > 1 && name.as_bytes()[1] == b':') {
        return name.to_string();
    }
    let trimmed = base.trim_end_matches(['/', '\\']);
    let sep = if base.contains('\\') && !base.contains('/') {
        '\\'
    } else {
        '/'
    };
    if trimmed.is_empty() {
        // The base was a root ("/", "\\") or empty.
        return if base.is_empty() {
            name.to_string()
        } else {
            format!("{sep}{name}")
        };
    }
    // A Windows drive root ("C:") lost its separator when trimmed.
    format!("{trimmed}{sep}{name}")
}

/// True when `name` can be used as a single path component on every platform.
///
/// Names come from remote servers and archives, so they are untrusted: a
/// component like `..`, `C:` or `a/b` would let the other side pick where the
/// file actually lands.
pub fn is_safe_component(name: &str) -> bool {
    if name.is_empty() || name == "." || name == ".." {
        return false;
    }
    // Separators and drive/stream markers are path syntax, not a name.
    if name.contains(['\0', '/', '\\', ':']) {
        return false;
    }
    !name.chars().any(|c| c.is_control())
}

/// Joins `base` with a single provider-supplied name, or `None` when that name
/// is not a plain file name (path traversal, absolute path, drive letter).
pub fn join_child(base: &str, name: &str) -> Option<String> {
    is_safe_component(name).then(|| join(base, name))
}

/// Joins a `/`-separated relative path under `base`, component by component.
///
/// Returns `None` if any component could escape: `..`, an absolute path or a
/// Windows drive. Empty components (`a//b`) are skipped.
pub fn join_relative(base: &str, relative: &str) -> Option<String> {
    let mut out = base.to_string();
    for part in relative.split('/') {
        if part.is_empty() {
            continue;
        }
        if !is_safe_component(part) {
            return None;
        }
        out = join(&out, part);
    }
    Some(out)
}

/// Parent of a logical path. `None` at a root.
pub fn parent(path: &str) -> Option<String> {
    let trimmed = path.trim_end_matches(['/', '\\']);
    if trimmed.is_empty() {
        return None;
    }

    // Windows drive roots: "C:\" / "C:/".
    if trimmed.len() == 2 && trimmed.as_bytes()[1] == b':' {
        return None;
    }
    // POSIX root.
    if trimmed == "/" {
        return None;
    }
    // UNC root "\\server\share".
    if trimmed.starts_with("\\\\") && trimmed.matches('\\').count() <= 3 {
        return None;
    }

    let sep_pos = trimmed.rfind(['/', '\\'])?;
    let parent = &trimmed[..sep_pos];
    if parent.is_empty() {
        return Some("/".to_string());
    }
    if parent.len() == 2 && parent.as_bytes()[1] == b':' {
        // "C:" -> "C:\"
        return Some(format!("{parent}\\"));
    }
    if parent.chars().all(|c| c == '\\') && trimmed.starts_with("\\\\") {
        return None;
    }
    Some(parent.to_string())
}

/// A human-readable name that is safe as a file or folder stem on Windows and
/// Android: separators, reserved characters and whitespace become `_`.
pub fn safe_file_stem(name: &str) -> String {
    let mut stem: String = name
        .trim()
        .chars()
        .map(|c| {
            if c.is_control() || c.is_whitespace() || "<>:/\\|?*\"".contains(c) {
                '_'
            } else {
                c
            }
        })
        .collect();
    stem = stem.trim_matches(['_', '.']).to_string();
    if stem.is_empty() {
        stem = "server".into();
    }
    let short: String = stem.chars().take(80).collect();
    stem = short;
    const RESERVED: [&str; 22] = [
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7",
        "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ];
    if RESERVED
        .iter()
        .any(|reserved| stem.eq_ignore_ascii_case(reserved))
    {
        stem.push('_');
    }
    stem
}

pub fn file_name(path: &str) -> &str {
    let trimmed = path.trim_end_matches(['/', '\\']);
    match trimmed.rfind(['/', '\\']) {
        Some(i) => &trimmed[i + 1..],
        None => trimmed,
    }
}

pub fn is_probably_hidden(name: &str) -> bool {
    name.starts_with('.') && name != "." && name != ".."
}

/// Escape arbitrary text for a POSIX shell single-quoted context.
///
/// `it's` -> `'it'\''s'`. Never call this on a string that is itself quoted.
pub fn shell_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

/// Simple glob matcher supporting `*`, `?` and `{a,b}` alternation.
/// Case-insensitive, because it is used for user-facing colour rules.
pub fn glob_match(pattern: &str, name: &str) -> bool {
    let pattern = pattern.to_lowercase();
    let name = name.to_lowercase();
    for expanded in expand_braces(&pattern) {
        if glob_match_simple(&expanded, &name) {
            return true;
        }
    }
    false
}

fn expand_braces(pattern: &str) -> Vec<String> {
    let (open, close) = match (pattern.find('{'), pattern.rfind('}')) {
        (Some(o), Some(c)) if o < c => (o, c),
        _ => return vec![pattern.to_string()],
    };
    let prefix = &pattern[..open];
    let suffix = &pattern[close + 1..];
    let mut out = Vec::new();
    for alternative in pattern[open + 1..close].split(',') {
        out.push(format!("{prefix}{alternative}{suffix}"));
    }
    out
}

fn glob_match_simple(pattern: &str, name: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let n: Vec<char> = name.chars().collect();
    let (mut pi, mut ni) = (0usize, 0usize);
    let mut star: Option<(usize, usize)> = None;

    while ni < n.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == n[ni]) {
            pi += 1;
            ni += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some((pi, ni));
            pi += 1;
        } else if let Some((sp, si)) = star {
            pi = sp + 1;
            ni = si + 1;
            star = Some((sp, si + 1));
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

fn extension(name: &str) -> &str {
    match name.rfind('.') {
        Some(i) if i + 1 < name.len() => &name[i + 1..],
        _ => "",
    }
}

/// Sort a directory listing the way a file manager expects.
pub fn sort_entries(entries: &mut [Entry], spec: &SortSpec) {
    entries.sort_by(|a, b| {
        use crate::model::EntryKind;
        if spec.dirs_first {
            let a_dir = a.kind == EntryKind::Dir;
            let b_dir = b.kind == EntryKind::Dir;
            if a_dir != b_dir {
                return if a_dir {
                    std::cmp::Ordering::Less
                } else {
                    std::cmp::Ordering::Greater
                };
            }
        }
        let ord = match spec.by {
            SortBy::Name => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
            SortBy::Extension => extension(&a.name)
                .to_lowercase()
                .cmp(&extension(&b.name).to_lowercase())
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())),
            SortBy::Size => a.size.cmp(&b.size),
            SortBy::Modified => a.modified.unwrap_or(0).cmp(&b.modified.unwrap_or(0)),
        };
        if spec.ascending {
            ord
        } else {
            ord.reverse()
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glob_matches_variants() {
        assert!(glob_match("*.php", "index.php"));
        assert!(glob_match("*.PHP", "Index.php"));
        assert!(!glob_match("*.php", "index.php.bak"));
        assert!(glob_match("*.{zip,tar,gz}", "backup.tar"));
        assert!(glob_match("file_?.txt", "file_1.txt"));
        assert!(!glob_match("file_?.txt", "file_10.txt"));
        assert!(glob_match("*", "anything"));
    }

    #[test]
    fn server_names_become_safe_stems() {
        assert_eq!(safe_file_stem("IKEY_NEW!"), "IKEY_NEW!");
        assert_eq!(safe_file_stem("My Server"), "My_Server");
        assert_eq!(safe_file_stem(r"a/b\c:d"), "a_b_c_d");
        assert_eq!(safe_file_stem("  ..  "), "server");
        assert_eq!(safe_file_stem("CON"), "CON_");
        assert_eq!(safe_file_stem(""), "server");
    }

    #[test]
    fn unsafe_child_names_are_refused() {
        let base = r"D:\downloads";
        assert_eq!(
            join_child(base, "photo.png").as_deref(),
            Some(r"D:\downloads\photo.png")
        );
        for bad in [
            "..",
            ".",
            "",
            "../evil",
            "a/b",
            r"a\b",
            "C:evil",
            r"\\server\share",
            "null\u{0}byte",
            "line\nbreak",
        ] {
            assert!(join_child(base, bad).is_none(), "accepted {bad:?}");
        }
    }

    #[test]
    fn relative_paths_cannot_escape() {
        let base = "/target/demo";
        assert_eq!(
            join_relative(base, "docs/readme.txt").as_deref(),
            Some("/target/demo/docs/readme.txt")
        );
        assert_eq!(
            join_relative(base, "//docs//a.txt").as_deref(),
            Some("/target/demo/docs/a.txt")
        );
        for bad in ["../x", "a/../../x", "docs/C:/x", "a/./b", "a/.."] {
            assert!(join_relative(base, bad).is_none(), "accepted {bad:?}");
        }
        // A leading separator must not turn into an absolute path: the result
        // stays below the base directory.
        assert_eq!(
            join_relative(base, "/etc/passwd").as_deref(),
            Some("/target/demo/etc/passwd")
        );
        assert_eq!(join_relative(base, "").as_deref(), Some(base));
    }

    #[test]
    fn shell_escape_handles_quotes() {
        assert_eq!(shell_escape("plain"), "'plain'");
        assert_eq!(shell_escape("it's"), "'it'\\''s'");
        assert_eq!(shell_escape("/tmp/a b;rm -rf /"), "'/tmp/a b;rm -rf /'");
    }

    #[test]
    fn paths_join_and_split() {
        assert_eq!(join("/var/www", "site"), "/var/www/site");
        assert_eq!(join("/", "etc"), "/etc");
        assert_eq!(join("D:\\work", "SSH"), "D:\\work\\SSH");
        assert_eq!(join("D:\\", "SSH"), "D:\\SSH");
        assert_eq!(parent("/root/wb2").as_deref(), Some("/root"));
        assert_eq!(parent("/").as_deref(), None);
        assert_eq!(parent("D:\\work\\SSH").as_deref(), Some("D:\\work"));
        assert_eq!(parent("D:\\").as_deref(), None);
        assert_eq!(parent("C:").as_deref(), None);
        assert_eq!(parent("/etc").as_deref(), Some("/"));
    }

    #[test]
    fn sorting_puts_dirs_first_and_respects_direction() {
        let mut e = vec![
            Entry {
                name: "b.txt".into(),
                path: "/b.txt".into(),
                kind: crate::model::EntryKind::File,
                size: 10,
                modified: None,
                mode: None,
                uid: None,
                gid: None,
                hidden: false,
                link_target: None,
            },
            Entry::dir("zdir", "/zdir"),
            Entry {
                name: "a.txt".into(),
                path: "/a.txt".into(),
                kind: crate::model::EntryKind::File,
                size: 5,
                modified: None,
                mode: None,
                uid: None,
                gid: None,
                hidden: false,
                link_target: None,
            },
        ];
        sort_entries(&mut e, &SortSpec::default());
        assert_eq!(e[0].name, "zdir");
        assert_eq!(e[1].name, "a.txt");

        sort_entries(
            &mut e,
            &SortSpec {
                by: SortBy::Size,
                ascending: false,
                dirs_first: false,
            },
        );
        assert_eq!(e[0].name, "b.txt");
    }
}
