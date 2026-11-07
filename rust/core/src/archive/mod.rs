//! Archive browsing: ZIP, TAR (+ gz/bz2/xz/zst), 7z and single-file
//! compressors.
//!
//! An archive is presented as a virtual directory tree: `list` returns the
//! children of a virtual path, `with_entry` streams one entry. The index is
//! built once from the archive header (ZIP central directory, TAR headers, 7z
//! header) and cached on disk, so reopening a 50 GB archive is instant.

mod create;
mod format;
mod index;
mod remote;
mod sevenz_backend;
mod single_backend;
mod tar_backend;
mod zip_backend;

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::io::Read;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use serde::{Deserialize, Serialize};

pub use create::{create_archive, CreateReport};
pub use format::ArchiveFormat;
pub use index::{ArchiveIndex, ArchiveNode, RawEntry};
pub use remote::{extract_command, pack_command, short_error};

use crate::error::{NovaError, Result};
use crate::model::{DirListing, Entry};
use crate::util;

/// Cap for in-memory reads (preview, diff). Copies stream instead.
const MAX_INLINE_ENTRY: u64 = 64 * 1024 * 1024;

/// Bump when the cached layout changes; old index files are then ignored.
const CACHE_VERSION: u32 = 1;

pub struct ArchiveFs {
    /// Path of the archive itself (local file).
    pub archive_path: String,
    pub format: ArchiveFormat,
    pub index: Arc<ArchiveIndex>,
}

impl ArchiveFs {
    /// Opens and scans an archive without touching the disk cache.
    pub fn open(path: &str) -> Result<Self> {
        let format = detect_format(path)?;
        let entries = scan(path, format)?;
        Ok(Self::from_entries(path, format, entries))
    }

    fn from_entries(path: &str, format: ArchiveFormat, entries: Vec<RawEntry>) -> Self {
        Self {
            archive_path: path.to_string(),
            format,
            index: Arc::new(ArchiveIndex::build(entries)),
        }
    }

    pub fn list(&self, inner: &str, show_hidden: bool) -> Result<DirListing> {
        let inner = index::normalize_path(inner);
        if !inner.is_empty() {
            let node = self
                .index
                .node(&inner)
                .ok_or_else(|| NovaError::NotFound(format!("{inner} in archive")))?;
            if !node.is_dir {
                return Err(NovaError::Invalid(format!("not a directory: {inner}")));
            }
        }

        let mut entries = Vec::new();
        for child in self.index.children_of(&inner) {
            if let Some(entry) = self.index.entry(&child) {
                if entry.hidden && !show_hidden {
                    continue;
                }
                entries.push(entry);
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
                let parent = index::parent_path(&inner);
                Some(if parent.is_empty() {
                    "/".to_string()
                } else {
                    format!("/{parent}")
                })
            },
            entries,
            free_space: None,
            total_space: None,
        })
    }

    pub fn stat(&self, inner: &str) -> Result<Entry> {
        let inner = index::normalize_path(inner);
        self.index
            .entry(&inner)
            .ok_or_else(|| NovaError::NotFound(inner.clone()))
    }

    /// Streams one entry through `read`. Callers that copy large files must
    /// use this instead of [`Self::read_entry`], which is capped.
    pub fn with_entry<T>(
        &self,
        inner: &str,
        read: impl FnOnce(&mut dyn Read) -> Result<T>,
    ) -> Result<T> {
        let inner = index::normalize_path(inner);
        let raw = self
            .index
            .raw(&inner)
            .ok_or_else(|| NovaError::NotFound(inner.clone()))?;
        match raw.locator {
            index::Locator::Zip(_) => {
                zip_backend::with_entry(&self.archive_path, raw.locator, read)
            }
            index::Locator::TarOffset { .. } | index::Locator::Ordinal(_) => {
                tar_backend::with_entry(&self.archive_path, self.format, raw.locator, read)
            }
            index::Locator::SevenZ => {
                sevenz_backend::with_entry(&self.archive_path, &raw.path, read)
            }
            index::Locator::Single => {
                let mut reader = single_backend::open_reader(&self.archive_path, self.format)?;
                read(&mut reader)
            }
        }
    }

    /// Reads a whole entry into memory (capped) — used for preview and diff.
    pub fn read_entry(&self, inner: &str) -> Result<Vec<u8>> {
        let inner = index::normalize_path(inner);
        let size = self.index.node(&inner).map(|n| n.size).unwrap_or(0);
        if size > MAX_INLINE_ENTRY {
            return Err(NovaError::Unsupported(format!(
                "entry is larger than {} MB",
                MAX_INLINE_ENTRY / (1024 * 1024)
            )));
        }
        self.with_entry(&inner, |reader| {
            let mut buffer = Vec::with_capacity(size.min(MAX_INLINE_ENTRY) as usize);
            reader
                .take(MAX_INLINE_ENTRY)
                .read_to_end(&mut buffer)
                .map_err(|e| NovaError::Invalid(format!("cannot read entry: {e}")))?;
            Ok(buffer)
        })
    }

    pub fn read_cursor(&self, inner: &str) -> Result<std::io::Cursor<Vec<u8>>> {
        Ok(std::io::Cursor::new(self.read_entry(inner)?))
    }

    /// Entry bytes for `Provider::open_read`, which needs the raw buffer to
    /// position it at an arbitrary offset.
    pub fn read_cursor_data(&self, inner: &str) -> Result<Vec<u8>> {
        self.read_entry(inner)
    }

    pub fn files_under(&self, inner: &str) -> Vec<String> {
        self.index.files_under(inner)
    }

    pub fn entry_size(&self, inner: &str) -> u64 {
        self.index.node(inner).map(|n| n.size).unwrap_or(0)
    }
}

fn detect_format(path: &str) -> Result<ArchiveFormat> {
    format::detect(path).ok_or_else(|| {
        NovaError::Unsupported(format!(
            "archive type is not supported: {}",
            util::file_name(path)
        ))
    })
}

fn scan(path: &str, format: ArchiveFormat) -> Result<Vec<RawEntry>> {
    match format {
        ArchiveFormat::Zip => zip_backend::scan(path),
        ArchiveFormat::SevenZ => sevenz_backend::scan(path),
        f if f.is_tar() => tar_backend::scan(path, f),
        f if f.is_single() => single_backend::scan(path, f),
        other => Err(NovaError::Unsupported(format!(
            "{} is not supported",
            other.label()
        ))),
    }
}

// ---------------------------------------------------------------------------
// Opening with the index cache
// ---------------------------------------------------------------------------

/// Public entry point used by the API layer: returns a shared, cached handle.
pub fn open(path: &str) -> Result<Arc<ArchiveFs>> {
    let format = detect_format(path)?;
    let meta = std::fs::metadata(path)
        .map_err(|e| NovaError::Invalid(format!("{}: {e}", util::file_name(path))))?;
    let size = meta.len();
    let modified_ms = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let key = cache_key(path, size, modified_ms, format);

    if let Some(hit) = memory_get(&key) {
        return Ok(hit);
    }

    let entries = match disk_load(&key, path, size, modified_ms, format) {
        Some(entries) => entries,
        None => {
            let entries = scan(path, format)?;
            disk_store(
                &key,
                &CachedIndex {
                    version: CACHE_VERSION,
                    path: path.to_string(),
                    size,
                    modified_ms,
                    format,
                    entries: entries.clone(),
                },
            );
            entries
        }
    };

    let fs = Arc::new(ArchiveFs::from_entries(path, format, entries));
    memory_put(key, fs.clone());
    Ok(fs)
}

pub fn is_supported(path: &str) -> bool {
    format::detect(path).is_some()
}

fn cache_key(path: &str, size: u64, modified_ms: i64, format: ArchiveFormat) -> String {
    let mut hasher = DefaultHasher::new();
    path.hash(&mut hasher);
    size.hash(&mut hasher);
    modified_ms.hash(&mut hasher);
    (format as u8).hash(&mut hasher);
    CACHE_VERSION.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

#[derive(Serialize, Deserialize)]
struct CachedIndex {
    version: u32,
    path: String,
    size: u64,
    modified_ms: i64,
    format: ArchiveFormat,
    entries: Vec<RawEntry>,
}

fn cache_dir_slot() -> &'static Mutex<Option<PathBuf>> {
    static DIR: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();
    DIR.get_or_init(|| Mutex::new(None))
}

/// Called once from `init_data_dir`. `None` (or an unusable folder) disables
/// the disk cache; browsing still works, it just re-scans.
pub fn set_cache_dir(dir: Option<PathBuf>) {
    if let Some(dir) = dir.as_ref() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(mut slot) = cache_dir_slot().lock() {
        *slot = dir;
    }
}

fn cache_path(key: &str) -> Option<PathBuf> {
    let slot = cache_dir_slot().lock().ok()?;
    slot.as_ref().map(|dir| dir.join(format!("{key}.idx")))
}

fn disk_load(
    key: &str,
    path: &str,
    size: u64,
    modified_ms: i64,
    format: ArchiveFormat,
) -> Option<Vec<RawEntry>> {
    let file = cache_path(key)?;
    disk_load_file(&file, path, size, modified_ms, format)
}

fn disk_load_file(
    file: &std::path::Path,
    path: &str,
    size: u64,
    modified_ms: i64,
    format: ArchiveFormat,
) -> Option<Vec<RawEntry>> {
    let bytes = std::fs::read(file).ok()?;
    let raw = zstd::decode_all(bytes.as_slice()).ok()?;
    let cached: CachedIndex = serde_json::from_slice(&raw).ok()?;
    if cached.version != CACHE_VERSION
        || cached.path != path
        || cached.size != size
        || cached.modified_ms != modified_ms
        || cached.format != format
    {
        let _ = std::fs::remove_file(file);
        return None;
    }
    Some(cached.entries)
}

fn disk_store(key: &str, cached: &CachedIndex) {
    let Some(file) = cache_path(key) else {
        return;
    };
    disk_store_file(&file, cached);
    prune_cache(&file);
}

fn disk_store_file(file: &std::path::Path, cached: &CachedIndex) {
    let Ok(json) = serde_json::to_vec(cached) else {
        return;
    };
    let Ok(packed) = zstd::encode_all(json.as_slice(), 3) else {
        return;
    };
    let tmp = file.with_extension("tmp");
    if std::fs::write(&tmp, packed).is_ok() {
        let _ = std::fs::remove_file(file);
        let _ = std::fs::rename(&tmp, file);
    }
}

/// Keeps the folder bounded: archives come and go, their indexes would stay.
fn prune_cache(current: &std::path::Path) {
    let Some(dir) = current.parent() else {
        return;
    };
    let Ok(read) = std::fs::read_dir(dir) else {
        return;
    };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = read
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("idx") {
                return None;
            }
            let modified = entry.metadata().ok()?.modified().ok()?;
            Some((modified, path))
        })
        .collect();
    const MAX_INDEXES: usize = 200;
    if files.len() <= MAX_INDEXES {
        return;
    }
    files.sort_by_key(|(modified, _)| *modified);
    for (_, path) in files.iter().take(files.len() - MAX_INDEXES) {
        let _ = std::fs::remove_file(path);
    }
}

fn memory_slot() -> &'static Mutex<Vec<(String, Arc<ArchiveFs>)>> {
    static MEM: OnceLock<Mutex<Vec<(String, Arc<ArchiveFs>)>>> = OnceLock::new();
    MEM.get_or_init(|| Mutex::new(Vec::new()))
}

fn memory_get(key: &str) -> Option<Arc<ArchiveFs>> {
    let mut cache = memory_slot().lock().ok()?;
    let position = cache.iter().position(|(k, _)| k == key)?;
    let hit = cache.remove(position);
    let fs = hit.1.clone();
    cache.insert(0, hit);
    Some(fs)
}

fn memory_put(key: String, fs: Arc<ArchiveFs>) {
    let Ok(mut cache) = memory_slot().lock() else {
        return;
    };
    cache.retain(|(k, _)| k != &key);
    cache.insert(0, (key, fs));
    cache.truncate(8);
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

    fn make_tree(dir: &std::path::Path) {
        std::fs::create_dir_all(dir.join("docs/nested")).unwrap();
        std::fs::write(dir.join("docs/readme.txt"), b"hello archive").unwrap();
        std::fs::write(dir.join("docs/nested/deep.txt"), b"deep").unwrap();
        std::fs::write(dir.join("index.php"), b"<?php echo 1;").unwrap();
    }

    fn make_tar(path: &std::path::Path, dir: &std::path::Path, format: ArchiveFormat) {
        // Build the tar in memory, then wrap it: an encoder that is simply
        // dropped (zstd) would otherwise leave a truncated frame behind.
        let mut builder = tar::Builder::new(Vec::new());
        builder.append_dir_all("docs", dir.join("docs")).unwrap();
        builder
            .append_path_with_name(dir.join("index.php"), "index.php")
            .unwrap();
        let bytes = builder.into_inner().unwrap();

        let write = |path: &std::path::Path, bytes: &[u8]| {
            std::fs::write(path, bytes).unwrap();
        };
        match format {
            ArchiveFormat::Tar => write(path, &bytes),
            ArchiveFormat::TarGz => {
                let mut e = flate2::write::GzEncoder::new(
                    std::fs::File::create(path).unwrap(),
                    flate2::Compression::fast(),
                );
                e.write_all(&bytes).unwrap();
                e.finish().unwrap();
            }
            ArchiveFormat::TarBz2 => {
                let mut e = bzip2::write::BzEncoder::new(
                    std::fs::File::create(path).unwrap(),
                    bzip2::Compression::fast(),
                );
                e.write_all(&bytes).unwrap();
                e.finish().unwrap();
            }
            ArchiveFormat::TarXz => {
                let mut e = liblzma::write::XzEncoder::new(
                    std::fs::File::create(path).unwrap(),
                    1,
                );
                e.write_all(&bytes).unwrap();
                e.finish().unwrap();
            }
            ArchiveFormat::TarZst => {
                let mut e =
                    zstd::stream::write::Encoder::new(std::fs::File::create(path).unwrap(), 1)
                        .unwrap();
                e.write_all(&bytes).unwrap();
                e.finish().unwrap();
            }
            _ => unreachable!(),
        }
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

    #[test]
    fn every_tar_compression_reads_the_same_tree() {
        let src = tempfile::tempdir().unwrap();
        make_tree(src.path());

        for (format, name) in [
            (ArchiveFormat::Tar, "a.tar"),
            (ArchiveFormat::TarGz, "a.tar.gz"),
            (ArchiveFormat::TarBz2, "a.tar.bz2"),
            (ArchiveFormat::TarXz, "a.tar.xz"),
            (ArchiveFormat::TarZst, "a.tar.zst"),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join(name);
            make_tar(&path, src.path(), format);
            let archive = ArchiveFs::open(path.to_str().unwrap()).unwrap();
            assert_eq!(
                archive.read_entry("index.php").unwrap(),
                b"<?php echo 1;",
                "{name}"
            );
            assert_eq!(
                archive.read_entry("docs/nested/deep.txt").unwrap(),
                b"deep",
                "{name}"
            );
            assert!(archive.list("docs", true).is_ok(), "{name}");
        }
    }

    #[test]
    fn single_file_compressors_expose_one_entry() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("notes.txt.gz");
        let file = std::fs::File::create(&path).unwrap();
        let mut encoder = flate2::write::GzEncoder::new(file, flate2::Compression::fast());
        encoder.write_all(b"hello gzip").unwrap();
        encoder.finish().unwrap();

        let archive = ArchiveFs::open(path.to_str().unwrap()).unwrap();
        let listing = archive.list("", true).unwrap();
        assert_eq!(listing.entries.len(), 1);
        assert_eq!(listing.entries[0].name, "notes.txt");
        assert_eq!(archive.read_entry("notes.txt").unwrap(), b"hello gzip");
    }

    /// The cache is a global (the API layer has no path plumbing), so the disk
    /// round-trip is tested through the explicit helpers instead.
    #[test]
    fn index_cache_round_trips_and_invalidates() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cached.zip");
        make_zip(&path);
        let fs = ArchiveFs::open(path.to_str().unwrap()).unwrap();
        let entries = fs.files_under("");
        assert_eq!(entries, vec!["docs/nested/deep.txt", "docs/readme.txt", "index.php"]);

        let file = dir.path().join("cache.idx");
        let meta = std::fs::metadata(&path).unwrap();
        let size = meta.len();
        let modified = meta.modified().unwrap();
        let modified_ms = modified
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        let cached = CachedIndex {
            version: CACHE_VERSION,
            path: path.to_string_lossy().to_string(),
            size,
            modified_ms,
            format: ArchiveFormat::Zip,
            entries: vec![RawEntry {
                path: "index.php".into(),
                is_dir: false,
                size: 12,
                modified_ms: None,
                locator: index::Locator::Zip(0),
            }],
        };
        disk_store_file(&file, &cached);
        let loaded = disk_load_file(
            &file,
            &cached.path,
            size,
            modified_ms,
            ArchiveFormat::Zip,
        )
        .unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].path, "index.php");

        // A different size means a different archive: the entry must be dropped.
        assert!(disk_load_file(&file, &cached.path, size + 1, modified_ms, ArchiveFormat::Zip)
            .is_none());
    }
}
