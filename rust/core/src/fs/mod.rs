//! Filesystem providers behind one dispatch enum.
//!
//! `Provider` is an enum rather than `dyn FsProvider` so that P1 can add
//! `Archive(inner)` without changing call sites or boxing async streams.

pub mod ftp;
pub mod local;
pub mod s3;
pub mod sftp;

pub use crate::archive::ArchiveFs;

use std::sync::Arc;

use tokio::io::{AsyncRead, AsyncWrite};

use crate::error::Result;
use crate::model::{DirListing, Entry, Volume};

/// A byte buffer positioned at `offset`, clamped to its length.
fn cursor_at(data: Vec<u8>, offset: u64) -> std::io::Cursor<Vec<u8>> {
    let mut cursor = std::io::Cursor::new(data);
    let len = cursor.get_ref().len() as u64;
    cursor.set_position(offset.min(len));
    cursor
}

pub enum Provider {
    Local(local::LocalFs),
    Sftp(Arc<sftp::SftpFs>),
    Ftp(Arc<ftp::FtpFs>),
    S3(Arc<s3::S3Fs>),
    /// Read-only view of an archive (ZIP for now).
    Archive(Arc<ArchiveFs>),
}

impl Clone for Provider {
    fn clone(&self) -> Self {
        match self {
            Self::Local(_) => Self::Local(local::LocalFs::new()),
            Self::Sftp(fs) => Self::Sftp(fs.clone()),
            Self::Ftp(fs) => Self::Ftp(fs.clone()),
            Self::S3(fs) => Self::S3(fs.clone()),
            Self::Archive(fs) => Self::Archive(fs.clone()),
        }
    }
}

impl Provider {
    pub fn local() -> Self {
        Self::Local(local::LocalFs::new())
    }

    pub fn sftp(fs: Arc<sftp::SftpFs>) -> Self {
        Self::Sftp(fs)
    }

    /// Used by colour rules and by the UI to pick local-only / remote-only rules.
    pub fn s3(fs: Arc<s3::S3Fs>) -> Self {
        Self::S3(fs)
    }

    pub fn ftp(fs: Arc<ftp::FtpFs>) -> Self {
        Self::Ftp(fs)
    }

    pub fn archive(fs: Arc<ArchiveFs>) -> Self {
        Self::Archive(fs)
    }

    pub fn scope(&self) -> &'static str {
        match self {
            Self::Local(_) | Self::Archive(_) => "local",
            Self::Sftp(_) | Self::Ftp(_) | Self::S3(_) => "remote",
        }
    }

    pub fn is_local(&self) -> bool {
        matches!(self, Self::Local(_) | Self::Archive(_))
    }

    pub fn is_archive(&self) -> bool {
        matches!(self, Self::Archive(_))
    }

    pub async fn list(&self, path: &str, show_hidden: bool) -> Result<DirListing> {
        match self {
            Self::Local(fs) => fs.list(path, show_hidden).await,
            Self::Sftp(fs) => fs.list(path, show_hidden).await,
            Self::Ftp(fs) => fs.list(path, show_hidden).await,
            Self::S3(fs) => fs.list(path, show_hidden).await,
            Self::Archive(fs) => fs.list(path, show_hidden),
        }
    }

    pub async fn stat(&self, path: &str) -> Result<Entry> {
        match self {
            Self::Local(fs) => fs.stat(path).await,
            Self::Sftp(fs) => fs.stat(path).await,
            Self::Ftp(fs) => fs.stat(path).await,
            Self::S3(fs) => fs.stat(path).await,
            Self::Archive(fs) => fs.stat(path),
        }
    }

    pub async fn open_read(
        &self,
        path: &str,
        offset: u64,
    ) -> Result<Box<dyn AsyncRead + Send + Unpin>> {
        match self {
            Self::Local(fs) => fs.open_read(path, offset).await,
            Self::Sftp(fs) => fs.open_read(path, offset).await,
            // FTP/S3 fetch the whole object; still honour the offset so a
            // resumed download continues instead of appending a second copy.
            Self::Ftp(fs) => Ok(Box::new(cursor_at(fs.read_all(path).await?, offset))),
            Self::S3(fs) => Ok(Box::new(cursor_at(fs.read_all(path).await?, offset))),
            Self::Archive(fs) => Ok(Box::new(cursor_at(fs.read_cursor_data(path)?, offset))),
        }
    }

    /// True when this transport can write different offsets of one file in
    /// parallel (a multi-threaded upload needs that).
    pub fn supports_parallel_write(&self) -> bool {
        matches!(self, Self::Local(_) | Self::Sftp(_))
    }

    /// Opens the file for writing at `offset` without truncating it.
    ///
    /// Used by the parallel uploader: each worker owns a byte range.
    pub async fn open_write_at(
        &self,
        path: &str,
        offset: u64,
    ) -> Result<Box<dyn AsyncWrite + Send + Unpin>> {
        match self {
            Self::Local(fs) => fs.open_write_at(path, offset).await,
            Self::Sftp(fs) => fs.open_write_at(path, offset).await,
            Self::Ftp(_) | Self::S3(_) | Self::Archive(_) => Err(
                crate::error::NovaError::Unsupported(
                    "this transport cannot write at an offset".into(),
                ),
            ),
        }
    }

    pub async fn open_write(
        &self,
        path: &str,
        resume: bool,
    ) -> Result<Box<dyn AsyncWrite + Send + Unpin>> {
        match self {
            Self::Local(fs) => fs.open_write(path, resume).await,
            Self::Sftp(fs) => fs.open_write(path, resume).await,
            Self::Ftp(_) | Self::S3(_) => Err(crate::error::NovaError::Unsupported(
                "upload goes through the buffered path".into(),
            )),
            Self::Archive(_) => Err(crate::error::NovaError::Unsupported(
                "archives are read-only for now".into(),
            )),
        }
    }

    pub async fn set_mode(&self, path: &str, mode: u32) -> Result<()> {
        match self {
            Self::Local(fs) => fs.set_mode(path, mode).await,
            Self::Sftp(fs) => fs.set_mode(path, mode).await,
            Self::Ftp(fs) => fs.set_mode(path, mode).await,
            Self::S3(_) | Self::Archive(_) => Err(crate::error::NovaError::Unsupported(
                "chmod is not supported on this transport".into(),
            )),
        }
    }

    pub async fn mkdir(&self, path: &str) -> Result<()> {
        match self {
            Self::Local(fs) => fs.mkdir(path).await,
            Self::Sftp(fs) => fs.mkdir(path).await,
            Self::Ftp(fs) => fs.mkdir(path).await,
            Self::S3(fs) => fs.mkdir(path).await,
            Self::Archive(_) => Err(crate::error::NovaError::Unsupported(
                "archives are read-only for now".into(),
            )),
        }
    }

    pub async fn rename(&self, from: &str, to: &str) -> Result<()> {
        match self {
            Self::Local(fs) => fs.rename(from, to).await,
            Self::Sftp(fs) => fs.rename(from, to).await,
            Self::Ftp(fs) => fs.rename(from, to).await,
            Self::S3(fs) => fs.rename(from, to).await,
            Self::Archive(_) => Err(crate::error::NovaError::Unsupported(
                "archives are read-only for now".into(),
            )),
        }
    }

    pub async fn remove(&self, path: &str, is_dir: bool) -> Result<()> {
        match self {
            Self::Local(fs) => fs.remove(path, is_dir).await,
            Self::Sftp(fs) => fs.remove(path, is_dir).await,
            Self::Ftp(fs) => fs.remove(path, is_dir).await,
            Self::S3(fs) => fs.remove(path, is_dir).await,
            Self::Archive(_) => Err(crate::error::NovaError::Unsupported(
                "archives are read-only for now".into(),
            )),
        }
    }

    /// Expand `~`, relative names and empty paths into an absolute directory.
    pub async fn resolve_dir(&self, input: &str, fallback: &str) -> String {
        let trimmed = input.trim();
        if !trimmed.is_empty() && !trimmed.starts_with('~') {
            return trimmed.to_string();
        }
        if let Self::Sftp(fs) = self {
            let target = if trimmed.is_empty() { "." } else { trimmed };
            if let Ok(Some(p)) = fs.raw().expand_path(target).await {
                return p;
            }
            if let Ok(p) = fs.canonicalize(target).await {
                return p;
            }
        }
        fallback.to_string()
    }

    pub fn volumes(&self) -> Vec<Volume> {
        match self {
            Self::Local(fs) => fs.volumes(),
            Self::Sftp(_) | Self::Ftp(_) | Self::S3(_) | Self::Archive(_) => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::cursor_at;

    #[test]
    fn cursor_starts_at_the_requested_offset() {
        use std::io::Read;
        let mut cursor = cursor_at(vec![1, 2, 3, 4, 5], 2);
        let mut out = Vec::new();
        cursor.read_to_end(&mut out).unwrap();
        assert_eq!(out, vec![3, 4, 5]);
    }

    #[test]
    fn cursor_offset_is_clamped_to_the_buffer() {
        use std::io::Read;
        let mut cursor = cursor_at(vec![1, 2, 3], 99);
        let mut out = Vec::new();
        cursor.read_to_end(&mut out).unwrap();
        assert!(out.is_empty());
    }
}
