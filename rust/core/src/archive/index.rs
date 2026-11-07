//! The virtual tree shared by every archive format.
//!
//! A backend only produces a flat list of [`RawEntry`] items; this module turns
//! it into the directory map the file panel browses.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::model::Entry;
use crate::util;

/// Where the bytes of one entry live inside the archive. Backends pick the
/// cheapest locator they can provide.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Locator {
    /// Index in the ZIP central directory (random access).
    Zip(u32),
    /// Absolute offset and length in an uncompressed TAR.
    TarOffset { offset: u64, len: u64 },
    /// Ordinal among files in a streamed (compressed) TAR or 7z.
    Ordinal(u32),
    /// 7z entries are addressed by name.
    SevenZ,
    /// The only entry of a `.gz`/`.bz2`/`.xz`/`.zst` file.
    Single,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawEntry {
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified_ms: Option<i64>,
    pub locator: Locator,
}

#[derive(Debug, Clone)]
pub struct ArchiveNode {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified_ms: Option<i64>,
}

pub struct ArchiveIndex {
    /// Virtual path ("" is the archive root) -> child paths.
    children: HashMap<String, Vec<String>>,
    /// Virtual path -> node metadata.
    nodes: HashMap<String, ArchiveNode>,
    /// Virtual file path -> backend locator.
    raw: HashMap<String, RawEntry>,
}

fn normalize(name: &str) -> String {
    name.replace('\\', "/")
        .split('/')
        .filter(|part| !part.is_empty() && *part != ".")
        .collect::<Vec<_>>()
        .join("/")
}

fn parent_of(path: &str) -> String {
    match path.rfind('/') {
        Some(i) => path[..i].to_string(),
        None => String::new(),
    }
}

impl ArchiveIndex {
    pub fn build(entries: Vec<RawEntry>) -> Self {
        let mut nodes: HashMap<String, ArchiveNode> = HashMap::new();
        let mut raw: HashMap<String, RawEntry> = HashMap::new();

        for entry in entries {
            let path = normalize(&entry.path);
            if path.is_empty() {
                continue;
            }

            // ZIP may omit directory records and TAR may store a file before
            // its folder; synthesise every missing parent.
            let mut parent = parent_of(&path);
            while !parent.is_empty() {
                nodes.entry(parent.clone()).or_insert_with(|| ArchiveNode {
                    name: parent.rsplit('/').next().unwrap_or(&parent).to_string(),
                    is_dir: true,
                    size: 0,
                    modified_ms: None,
                });
                parent = parent_of(&parent);
            }

            let name = path.rsplit('/').next().unwrap_or(&path).to_string();
            let is_dir = entry.is_dir;
            // A file and a folder with the same name can both exist in a
            // broken archive; the last record wins, like in most unpackers.
            if !is_dir {
                raw.insert(
                    path.clone(),
                    RawEntry {
                        path: path.clone(),
                        is_dir: false,
                        size: entry.size,
                        modified_ms: entry.modified_ms,
                        locator: entry.locator,
                    },
                );
            }
            nodes.insert(
                path,
                ArchiveNode {
                    name,
                    is_dir,
                    size: if is_dir { 0 } else { entry.size },
                    modified_ms: entry.modified_ms,
                },
            );
        }

        let mut children: HashMap<String, Vec<String>> = HashMap::new();
        for path in nodes.keys() {
            let parent = parent_of(path);
            children.entry(parent).or_default().push(path.clone());
        }
        for list in children.values_mut() {
            list.sort();
        }

        Self {
            children,
            nodes,
            raw,
        }
    }

    pub fn node(&self, path: &str) -> Option<&ArchiveNode> {
        self.nodes.get(&normalize(path))
    }

    pub fn raw(&self, path: &str) -> Option<&RawEntry> {
        self.raw.get(&normalize(path))
    }

    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    pub fn children_of(&self, path: &str) -> Vec<String> {
        self.children
            .get(&normalize(path))
            .cloned()
            .unwrap_or_default()
    }

    /// All file paths under `inner` (recursively), excluding directories.
    pub fn files_under(&self, inner: &str) -> Vec<String> {
        let inner = normalize(inner);
        if let Some(node) = self.nodes.get(&inner) {
            if !node.is_dir {
                return vec![inner];
            }
        }
        let mut out = Vec::new();
        let mut stack = vec![inner];
        while let Some(dir) = stack.pop() {
            for child in self.children_of(&dir) {
                if let Some(node) = self.nodes.get(&child) {
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

    /// Directory entries in the whole archive, root first.
    pub fn all_dirs(&self) -> Vec<String> {
        let mut dirs: Vec<String> = self
            .nodes
            .iter()
            .filter(|(_, node)| node.is_dir)
            .map(|(path, _)| path.clone())
            .collect();
        dirs.sort();
        dirs
    }

    pub fn entry(&self, path: &str) -> Option<Entry> {
        let path = normalize(path);
        let node = self.nodes.get(&path)?;
        Some(Entry {
            name: node.name.clone(),
            path: path.clone(),
            kind: if node.is_dir {
                crate::model::EntryKind::Dir
            } else {
                crate::model::EntryKind::File
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
}

pub fn normalize_path(name: &str) -> String {
    normalize(name)
}

pub fn parent_path(path: &str) -> String {
    parent_of(&normalize(path))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(path: &str, is_dir: bool) -> RawEntry {
        RawEntry {
            path: path.to_string(),
            is_dir,
            size: if is_dir { 0 } else { 3 },
            modified_ms: None,
            locator: Locator::Single,
        }
    }

    #[test]
    fn missing_parents_are_synthesised() {
        let index = ArchiveIndex::build(vec![raw("a/b/c.txt", false)]);
        assert!(index.node("a").unwrap().is_dir);
        assert!(index.node("a/b").unwrap().is_dir);
        assert_eq!(index.files_under(""), vec!["a/b/c.txt"]);
        assert_eq!(index.children_of("a"), vec!["a/b"]);
    }

    #[test]
    fn duplicate_records_keep_the_last_one() {
        let mut first = raw("same.txt", false);
        first.size = 1;
        let mut second = raw("same.txt", false);
        second.size = 9;
        let index = ArchiveIndex::build(vec![first, second]);
        assert_eq!(index.node("same.txt").unwrap().size, 9);
    }

    #[test]
    fn backslashes_and_dot_segments_are_normalised() {
        let index = ArchiveIndex::build(vec![raw("docs\\sub\\./x.txt", false)]);
        assert_eq!(index.files_under(""), vec!["docs/sub/x.txt"]);
    }
}
