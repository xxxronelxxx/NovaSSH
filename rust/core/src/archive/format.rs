//! Archive formats Nova understands.
//!
//! Detection is extension-first: a `.tar.gz` may also be a gzip-compressed
//! single file, and the extension is the only cheap way to tell them apart.
//! Files with unknown extensions fall back to magic bytes, which covers
//! archives downloaded without a suffix.

use std::io::Read;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ArchiveFormat {
    Zip,
    Tar,
    TarGz,
    TarBz2,
    TarXz,
    TarZst,
    SevenZ,
    /// Single compressed file (not a container): the archive holds one entry.
    Gz,
    Bz2,
    Xz,
    Zst,
}

impl ArchiveFormat {
    /// Longest suffix first: `.tar.gz` must win over `.gz`.
    pub fn from_path(path: &str) -> Option<Self> {
        const TABLE: [(&str, ArchiveFormat); 20] = [
            (".tar.gz", ArchiveFormat::TarGz),
            (".tar.gzip", ArchiveFormat::TarGz),
            (".tar.bz2", ArchiveFormat::TarBz2),
            (".tar.bzip2", ArchiveFormat::TarBz2),
            (".tar.xz", ArchiveFormat::TarXz),
            (".tar.lzma", ArchiveFormat::TarXz),
            (".tar.zst", ArchiveFormat::TarZst),
            (".tar.zstd", ArchiveFormat::TarZst),
            (".tgz", ArchiveFormat::TarGz),
            (".tbz2", ArchiveFormat::TarBz2),
            (".tbz", ArchiveFormat::TarBz2),
            (".txz", ArchiveFormat::TarXz),
            (".tzst", ArchiveFormat::TarZst),
            (".zip", ArchiveFormat::Zip),
            (".7z", ArchiveFormat::SevenZ),
            (".tar", ArchiveFormat::Tar),
            (".gz", ArchiveFormat::Gz),
            (".bz2", ArchiveFormat::Bz2),
            (".xz", ArchiveFormat::Xz),
            (".zst", ArchiveFormat::Zst),
        ];
        let lower = path.to_lowercase();
        TABLE
            .iter()
            .find(|(suffix, _)| lower.ends_with(suffix))
            .map(|(_, format)| *format)
    }

    pub fn is_tar(self) -> bool {
        matches!(
            self,
            Self::Tar | Self::TarGz | Self::TarBz2 | Self::TarXz | Self::TarZst
        )
    }

    pub fn is_compressed_tar(self) -> bool {
        self.is_tar() && self != Self::Tar
    }

    pub fn is_single(self) -> bool {
        matches!(self, Self::Gz | Self::Bz2 | Self::Xz | Self::Zst)
    }

    /// Human label used in dialogs and error messages.
    pub fn label(self) -> &'static str {
        match self {
            Self::Zip => "ZIP",
            Self::Tar => "TAR",
            Self::TarGz => "TAR.GZ",
            Self::TarBz2 => "TAR.BZ2",
            Self::TarXz => "TAR.XZ",
            Self::TarZst => "TAR.ZST",
            Self::SevenZ => "7Z",
            Self::Gz => "GZ",
            Self::Bz2 => "BZ2",
            Self::Xz => "XZ",
            Self::Zst => "ZST",
        }
    }

    /// Extension used when Nova creates an archive of this format.
    pub fn extension(self) -> &'static str {
        match self {
            Self::Zip => "zip",
            Self::Tar => "tar",
            Self::TarGz => "tar.gz",
            Self::TarBz2 => "tar.bz2",
            Self::TarXz => "tar.xz",
            Self::TarZst => "tar.zst",
            Self::SevenZ => "7z",
            Self::Gz => "gz",
            Self::Bz2 => "bz2",
            Self::Xz => "xz",
            Self::Zst => "zst",
        }
    }

    /// Format that can be produced from arbitrary sources. Single-file
    /// compressors are only offered when exactly one file is selected.
    pub fn writable() -> &'static [ArchiveFormat] {
        &[
            Self::Zip,
            Self::TarGz,
            Self::TarBz2,
            Self::TarXz,
            Self::TarZst,
            Self::SevenZ,
            Self::Tar,
        ]
    }

    /// Parses the value the UI sends (`"zip"`, `"tar.gz"`, `"7z"`, ...).
    pub fn parse(value: &str) -> Option<Self> {
        let lower = value.trim().trim_start_matches('.').to_lowercase();
        Some(match lower.as_str() {
            "zip" => Self::Zip,
            "tar" => Self::Tar,
            "tar.gz" | "tgz" => Self::TarGz,
            "tar.bz2" | "tbz2" | "tbz" => Self::TarBz2,
            "tar.xz" | "txz" => Self::TarXz,
            "tar.zst" | "tzst" | "tar.zstd" => Self::TarZst,
            "7z" | "sevenz" | "seven-z" => Self::SevenZ,
            "gz" => Self::Gz,
            "bz2" => Self::Bz2,
            "xz" => Self::Xz,
            "zst" => Self::Zst,
            _ => return None,
        })
    }

    /// `backup.tar.gz` -> `backup`; used as the folder name on extraction.
    pub fn stem(path: &str) -> String {
        let name = crate::util::file_name(path).to_string();
        if let Some(format) = Self::from_path(path) {
            let lower = name.to_lowercase();
            for suffix in suffixes(format) {
                if lower.ends_with(suffix) {
                    return name[..name.len() - suffix.len()].to_string();
                }
            }
        }
        name
    }

    /// Name of the virtual entry inside a single-file `.gz`/`.bz2`/...
    pub fn single_entry_name(path: &str) -> String {
        let stem = Self::stem(path);
        if stem.is_empty() {
            "file".to_string()
        } else {
            stem
        }
    }
}

fn suffixes(format: ArchiveFormat) -> &'static [&'static str] {
    match format {
        ArchiveFormat::Zip => &[".zip"],
        ArchiveFormat::Tar => &[".tar"],
        ArchiveFormat::TarGz => &[".tar.gz", ".tar.gzip", ".tgz"],
        ArchiveFormat::TarBz2 => &[".tar.bz2", ".tar.bzip2", ".tbz2", ".tbz"],
        ArchiveFormat::TarXz => &[".tar.xz", ".tar.lzma", ".txz"],
        ArchiveFormat::TarZst => &[".tar.zst", ".tar.zstd", ".tzst"],
        ArchiveFormat::SevenZ => &[".7z"],
        ArchiveFormat::Gz => &[".gz"],
        ArchiveFormat::Bz2 => &[".bz2"],
        ArchiveFormat::Xz => &[".xz"],
        ArchiveFormat::Zst => &[".zst"],
    }
}

/// Extension first, then magic bytes. Returns `None` for a file that is not
/// an archive Nova can open.
pub fn detect(path: &str) -> Option<ArchiveFormat> {
    if let Some(format) = ArchiveFormat::from_path(path) {
        return Some(format);
    }
    detect_magic(path)
}

fn detect_magic(path: &str) -> Option<ArchiveFormat> {
    let mut file = std::fs::File::open(path).ok()?;
    let mut head = [0u8; 1024];
    let read = file.read(&mut head).ok()?;
    let head = &head[..read];
    if head.len() < 4 {
        return None;
    }

    if head.starts_with(b"PK\x03\x04") || head.starts_with(b"PK\x05\x06") {
        return Some(ArchiveFormat::Zip);
    }
    if head.starts_with(b"7z\xbc\xaf\x27\x1c") {
        return Some(ArchiveFormat::SevenZ);
    }
    if head.starts_with(b"\x1f\x8b") {
        return Some(if tar_magic_after_gzip(path) {
            ArchiveFormat::TarGz
        } else {
            ArchiveFormat::Gz
        });
    }
    if head.starts_with(b"BZh") {
        return Some(ArchiveFormat::Bz2);
    }
    if head.starts_with(b"\xfd7zXZ\x00") {
        return Some(ArchiveFormat::Xz);
    }
    if head.starts_with(b"\x28\xb5\x2f\xfd") {
        return Some(ArchiveFormat::Zst);
    }
    if is_tar_header(head) {
        return Some(ArchiveFormat::Tar);
    }
    None
}

fn is_tar_header(head: &[u8]) -> bool {
    head.len() >= 262 && &head[257..262] == b"ustar"
}

/// Gzip wraps either a tarball or a single file; decompressing 1024 bytes is
/// enough to see the tar header.
fn tar_magic_after_gzip(path: &str) -> bool {
    let Ok(file) = std::fs::File::open(path) else {
        return false;
    };
    let mut decoder = flate2::read::GzDecoder::new(file);
    let mut head = [0u8; 1024];
    let mut filled = 0usize;
    while filled < head.len() {
        match decoder.read(&mut head[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(_) => return false,
        }
    }
    is_tar_header(&head[..filled])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extension_detection_prefers_the_longest_suffix() {
        assert_eq!(ArchiveFormat::from_path("a.tar.gz"), Some(ArchiveFormat::TarGz));
        assert_eq!(ArchiveFormat::from_path("A.TGZ"), Some(ArchiveFormat::TarGz));
        assert_eq!(ArchiveFormat::from_path("a.gz"), Some(ArchiveFormat::Gz));
        assert_eq!(ArchiveFormat::from_path("a.tar.zst"), Some(ArchiveFormat::TarZst));
        assert_eq!(ArchiveFormat::from_path("a.txt"), None);
    }

    #[test]
    fn stems_are_used_for_extraction_folders() {
        assert_eq!(ArchiveFormat::stem("/tmp/demo.tar.gz"), "demo");
        assert_eq!(ArchiveFormat::stem("C:/x/backup.7z"), "backup");
        assert_eq!(ArchiveFormat::stem("plain"), "plain");
    }
}
