//! Read-only archive browsing (ZIP for now).
//!
//! An archive is presented as a virtual directory tree: `list` returns the
//! children of a virtual path, `open_read` streams one entry. The index is built
//! from the ZIP central directory, so opening a large archive is instant.

use std::collections::HashMap;
use std::io::{Cursor, Read};
use std::sync::Arc;

use crate::error::{NovaError, Result};
use crate::model::{DirListing, Entry, EntryKind};
use crate::util;

/// Cap for in-memory extraction of a single entry.
const MAX_INLINE_ENTRY: u64 = 64 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct ArchiveNode {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified_ms: Option<i64>,
}

pub struct ArchiveIndex {
    /// Virtual path ("" is the archive root) -> child names.
    children: HashMap<String, Vec<String>>,
    /// Virtual path -> node metadata.
    nodes: HashMap<String, ArchiveNode>,
    /// Virtual file path -> index in the central directory.
    entry_index: HashMap<String, usize>,
}

pub struct ArchiveFs {
    /// Path of the archive itself (local file).
    pub archive_path: String,
    pub index: Arc<ArchiveIndex>,
}

fn normalize(name: &str) -> String {
    name.replace('\\', "/").trim_matches('/').to_string()
}

fn parent_of(path: &str) -> String {
    match path.rfind('/') {
        Some(i) => path[..i].to_string(),
        None => String::new(),
    }
}

fn join_virtual(base: &str, name: &str) -> String {
    if base.is_empty() {
        name.to_string()
    } else {
        format!("{base}/{name}")
    }
}

impl ArchiveFs {
    pub fn open(path: &str) -> Result<Self> {
        let file = std::fs::File::open(path)?;
        let mut zip = zip::ZipArchive::new(file)
            .map_err(|e| NovaError::Invalid(format!("cannot read archive: {e}")))?;

        let mut nodes: HashMap<String, ArchiveNode> = HashMap::new();
        let mut entry_index: HashMap<String, usize> = HashMap::new();

        // Explicit directory entries are optional in ZIP; parents are synthesised.
        let mut ensure_dir = |nodes: &mut HashMap<String, ArchiveNode>, dir: &str| {
            if dir.is_empty() {
                return;
            }
            nodes
                .entry(dir.to_string())
                .or_insert_with(|| ArchiveNode {
                    name: dir.rsplit('/').next().unwrap_or(dir).to_string(),
                    is_dir: true,
                    size: 0,
                    modified_ms: None,
                });
        };

        for i in 0..zip.len() {
            let file = zip
                .by_index(i)
                .map_err(|e| NovaError::Invalid(format!("bad entry {i}: {e}")))?;
            let raw = file
                .name()
                .map_err(|e| NovaError::Invalid(format!("bad entry name: {e}")))?
                .to_string();
            let path = normalize(&raw);
            if path.is_empty() {
                continue;
            }
            let is_dir = file.is_dir() || raw.ends_with('/');
            let size = if is_dir { 0 } else { file.size() };
            let modified_ms = file.last_modified().and_then(datetime_to_ms);

            let mut parent = parent_of(&path);
            while !parent.is_empty() {
                ensure_dir(&mut nodes, &parent);
                parent = parent_of(&parent);
            }

            let name = path.rsplit('/').next().unwrap_or(&path).to_string();
            nodes.insert(
                path.clone(),
                ArchiveNode {
                    name,
                    is_dir,
                    size,
                    modified_ms,
                },
            );
            if !is_dir {
                entry_index.insert(path, i);
            }
        }

        let mut children: HashMap<String, Vec<String>> = HashMap::new();
        for (path, node) in &nodes {
            let parent = parent_of(path);
            let child_path = if parent.is_empty() {
                path.clone()
            } else {
                format!("{}/{}", parent, node.name)
            };
            children.entry(parent).or_default().push(child_path);
        }
        for list in children.values_mut() {
            list.sort();
        }

        Ok(Self {
            archive_path: path.to_string(),
            index: Arc::new(ArchiveIndex {
                children,
                nodes,
                entry_index,
            }),
        })
    }

    pub fn list(&self, inner: &str, show_hidden: bool) -> Result<DirListing> {
        let inner = normalize(inner);
        if !inner.is_empty() {
            let node = self
                .index
                .nodes
                .get(&inner)
                .ok_or_else(|| NovaError::NotFound(format!("{inner} in archive")))?;
            if !node.is_dir {
                return Err(NovaError::Invalid(format!("not a directory: {inner}")));
            }
        }

        let mut entries = Vec::new();
        for child in self.index.children.get(&inner).cloned().unwrap_or_default() {
            if let Some(node) = self.index.nodes.get(&child) {
                let hidden = util::is_probably_hidden(&node.name);
                if hidden && !show_hidden {
                    continue;
                }
                entries.push(Entry {
                    name: node.name.clone(),
                    path: child.clone(),
                    kind: if node.is_dir {
                        EntryKind::Dir
                    } else {
                        EntryKind::File
                    },
                    size: node.size,
                    modified: node.modified_ms,
                    mode: None,
                    uid: None,
                    gid: None,
                    hidden,
                    link_target: None,
                });
            }
        }

        Ok(DirListing {
            path: if inner.is_empty() {
                "/".to_string()
            } else {
                format!("/{inner}")
            },
            parent: if inner.is_empty() {
                None
            } else {
                Some(if parent_of(&inner).is_empty() {
                    "/".to_string()
                } else {
                    format!("/{}", parent_of(&inner))
                })
            },
            entries,
            free_space: None,
            total_space: None,
        })
    }

    pub fn stat(&self, inner: &str) -> Result<Entry> {
        let inner = normalize(inner);
        let node = self
            .index
            .nodes
            .get(&inner)
            .ok_or_else(|| NovaError::NotFound(inner.clone()))?;
        Ok(Entry {
            name: node.name.clone(),
            path: inner.clone(),
            kind: if node.is_dir {
                EntryKind::Dir
            } else {
                EntryKind::File
            },
            size: node.size,
            modified: node.modified_ms,
            mode: None,
            uid: None,
            gid: None,
            hidden: util::is_probably_hidden(&node.name),
            link_target: None,
        })
    }

    /// Reads a whole entry into memory (capped) — used for preview and copies.
    pub fn read_entry(&self, inner: &str) -> Result<Vec<u8>> {
        let inner = normalize(inner);
        let index = *self
            .index
            .entry_index
            .get(&inner)
            .ok_or_else(|| NovaError::NotFound(inner.clone()))?;

        let size = self.index.nodes.get(&inner).map(|n| n.size).unwrap_or(0);
        if size > MAX_INLINE_ENTRY {
            return Err(NovaError::Unsupported(format!(
                "entry is larger than {} MB",
                MAX_INLINE_ENTRY / (1024 * 1024)
            )));
        }

        let file = std::fs::File::open(&self.archive_path)?;
        let mut zip = zip::ZipArchive::new(file)
            .map_err(|e| NovaError::Invalid(format!("cannot read archive: {e}")))?;
        let mut entry = zip
            .by_index(index)
            .map_err(|e| NovaError::Invalid(format!("bad entry: {e}")))?;
        let mut buffer = Vec::with_capacity(size as usize);
        entry
            .read_to_end(&mut buffer)
            .map_err(|e| NovaError::Invalid(format!("cannot read entry: {e}")))?;
        Ok(buffer)
    }

    pub fn read_cursor(&self, inner: &str) -> Result<Cursor<Vec<u8>>> {
        Ok(Cursor::new(self.read_entry(inner)?))
    }

    /// Entry bytes for `Provider::open_read`, which needs the raw buffer to
    /// position it at an arbitrary offset.
    pub fn read_cursor_data(&self, inner: &str) -> Result<Vec<u8>> {
        self.read_entry(inner)
    }

    /// All file paths under `inner` (recursively), excluding directories.
    pub fn files_under(&self, inner: &str) -> Vec<String> {
        let inner = normalize(inner);
        if let Some(node) = self.index.nodes.get(&inner) {
            if !node.is_dir {
                return vec![inner];
            }
        }
        let mut out = Vec::new();
        let mut stack = vec![inner];
        while let Some(dir) = stack.pop() {
            for child in self.index.children.get(&dir).cloned().unwrap_or_default() {
                if let Some(node) = self.index.nodes.get(&child) {
                    if node.is_dir {
                        stack.push(child);
                    } else {
                        out.push(child);
                    }
                }
            }
        }
        out.sort();
        out
    }
}

fn datetime_to_ms(dt: zip::DateTime) -> Option<i64> {
    // zip exposes components without a timezone; treat it as UTC for stability.
    let year = dt.year();
    let month = dt.month();
    let day = dt.day();
    let hour = dt.hour();
    let minute = dt.minute();
    let second = dt.second();
    if !(1970..=3000).contains(&year) {
        return None;
    }
    let days = days_from_civil(year as i64, month as u32, day as u32);
    let ms = ((days * 86_400 + hour as i64 * 3600 + minute as i64 * 60 + second as i64) * 1000).max(0);
    Some(ms)
}

/// Howard Hinnant's days-from-civil algorithm.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Detects archive type by extension; only ZIP is supported so far.
pub fn is_supported(path: &str) -> bool {
    let lower = path.to_lowercase();
    lower.ends_with(".zip")
}

pub fn open(path: &str) -> Result<ArchiveFs> {
    if !is_supported(path) {
        return Err(NovaError::Unsupported(format!(
            "archive type is not supported yet: {}",
            util::file_name(path)
        )));
    }
    ArchiveFs::open(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn make_zip(path: &std::path::Path) {
        let file = std::fs::File::create(path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options: zip::write::SimpleFileOptions = zip::write::SimpleFileOptions::default();

        zip.add_directory("docs/", options).unwrap();
        zip.start_file("docs/readme.txt", options).unwrap();
        zip.write_all(b"hello archive").unwrap();
        zip.start_file("index.php", options).unwrap();
        zip.write_all(b"<?php echo 1;").unwrap();
        zip.start_file("docs/nested/deep.txt", options).unwrap();
        zip.write_all(b"deep").unwrap();
        zip.finish().unwrap();
    }

    #[test]
    fn lists_root_and_nested_folders() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.zip");
        make_zip(&path);

        let archive = ArchiveFs::open(path.to_str().unwrap()).unwrap();

        let root = archive.list("", true).unwrap();
        let names: Vec<_> = root.entries.iter().map(|e| e.name.clone()).collect();
        assert!(names.contains(&"docs".to_string()), "{names:?}");
        assert!(names.contains(&"index.php".to_string()));

        let docs = archive.list("docs", true).unwrap();
        let names: Vec<_> = docs.entries.iter().map(|e| e.name.clone()).collect();
        assert!(names.contains(&"readme.txt".to_string()));
        assert!(names.contains(&"nested".to_string()));
    }

    #[test]
    fn reads_entries_and_lists_recursively() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.zip");
        make_zip(&path);
        let archive = ArchiveFs::open(path.to_str().unwrap()).unwrap();

        assert_eq!(archive.read_entry("docs/readme.txt").unwrap(), b"hello archive");
        let files = archive.files_under("docs");
        assert_eq!(files, vec!["docs/nested/deep.txt", "docs/readme.txt"]);
    }

    #[test]
    fn hostile_entry_names_never_escape_the_target() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("evil.zip");
        let file = std::fs::File::create(&path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options: zip::write::SimpleFileOptions = zip::write::SimpleFileOptions::default();
        zip.start_file("../../evil.txt", options).unwrap();
        zip.write_all(b"pwned").unwrap();
        zip.start_file("docs/ok.txt", options).unwrap();
        zip.write_all(b"ok").unwrap();
        zip.finish().unwrap();

        let archive = ArchiveFs::open(path.to_str().unwrap()).unwrap();
        let files = archive.files_under("");
        let hostile = files.iter().any(|f| f.contains(".."));
        if hostile {
            for file in &files {
                if file.contains("..") {
                    assert!(
                        crate::util::join_relative("/target/demo", file).is_none(),
                        "extraction path escaped: {file}"
                    );
                }
            }
        }
        assert!(files.iter().any(|f| f.ends_with("ok.txt")));
    }

    #[test]
    fn rejects_missing_paths() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.zip");
        make_zip(&path);
        let archive = ArchiveFs::open(path.to_str().unwrap()).unwrap();
        assert!(archive.list("nope", true).is_err());
        assert!(archive.read_entry("nope.txt").is_err());
    }
}
