//! SFTP provider built on `russh-sftp`.

use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use russh_sftp::client::SftpSession;
use russh_sftp::protocol::{FileType, OpenFlags};
use tokio::io::{AsyncRead, AsyncWrite};

use crate::error::{NovaError, Result};
use crate::model::{DirListing, Entry, EntryKind};
use crate::util;

pub struct SftpFs {
    pub session_id: String,
    sftp: Arc<SftpSession>,
    /// statvfs costs a full round trip; cache it briefly so directory
    /// navigation stays snappy on high-latency links.
    space_cache: std::sync::Mutex<Option<(Instant, Option<u64>, Option<u64>)>>,
}

impl SftpFs {
    pub fn new(session_id: impl Into<String>, sftp: Arc<SftpSession>) -> Self {
        Self {
            session_id: session_id.into(),
            sftp,
            space_cache: std::sync::Mutex::new(None),
        }
    }

    pub fn raw(&self) -> &Arc<SftpSession> {
        &self.sftp
    }

    /// Changes the permission bits of one entry (chmod).
    pub async fn set_mode(&self, path: &str, mode: u32) -> Result<()> {
        let mut attrs = russh_sftp::protocol::FileAttributes::default();
        attrs.permissions = Some(mode);
        self.sftp
            .set_metadata(path.to_string(), attrs)
            .await
            .map_err(|e| NovaError::Sftp(format!("chmod: {e}")))
    }

    /// Sets the modification time, used when unpacking archives.
    pub async fn set_times(&self, path: &str, mtime_ms: i64) -> Result<()> {
        let mut attrs = russh_sftp::protocol::FileAttributes::default();
        let seconds = mtime_ms.div_euclid(1000).clamp(0, u32::MAX as i64) as u32;
        attrs.mtime = Some(seconds);
        attrs.atime = Some(seconds);
        self.sftp
            .set_metadata(path.to_string(), attrs)
            .await
            .map_err(|e| NovaError::Sftp(format!("set times: {e}")))
    }

    pub async fn list(&self, path: &str, show_hidden: bool) -> Result<DirListing> {
        let path = if path.trim().is_empty() {
            ".".to_string()
        } else {
            path.to_string()
        };
        let dir = self.sftp.read_dir(path.clone()).await?;
        let mut entries = Vec::new();
        for item in dir {
            let name = item.file_name();
            if name == "." || name == ".." {
                continue;
            }
            let full = item.path();
            let meta = item.metadata();
            let kind = match meta.file_type() {
                FileType::Dir => EntryKind::Dir,
                FileType::File => EntryKind::File,
                FileType::Symlink => EntryKind::Symlink,
                FileType::Other => EntryKind::Other,
            };
            let hidden = util::is_probably_hidden(&name);
            if !show_hidden && hidden {
                continue;
            }
            entries.push(Entry {
                name,
                path: full,
                kind,
                size: if kind == EntryKind::Dir {
                    0
                } else {
                    meta.len()
                },
                modified: meta.modified().ok().and_then(system_time_ms),
                mode: Some(mode_bits(&meta)),
                uid: None,
                gid: None,
                hidden,
                link_target: None,
            });
        }

        let (free, total) = self.space(&path).await;

        Ok(DirListing {
            parent: util::parent(&path),
            path,
            entries,
            free_space: free,
            total_space: total,
        })
    }

    async fn space(&self, path: &str) -> (Option<u64>, Option<u64>) {
        const TTL: Duration = Duration::from_secs(10);
        if let Ok(guard) = self.space_cache.lock() {
            if let Some((at, free, total)) = *guard {
                if at.elapsed() < TTL {
                    return (free, total);
                }
            }
        }
        let result = match self.sftp.fs_info(path.to_string()).await {
            Ok(Some(st)) => (
                Some(st.blocks_avail.saturating_mul(st.fragment_size)),
                Some(st.blocks.saturating_mul(st.fragment_size)),
            ),
            _ => (None, None),
        };
        if let Ok(mut guard) = self.space_cache.lock() {
            *guard = Some((Instant::now(), result.0, result.1));
        }
        result
    }

    pub async fn stat(&self, path: &str) -> Result<Entry> {
        let meta = self.sftp.symlink_metadata(path).await?;
        let kind = match meta.file_type() {
            FileType::Dir => EntryKind::Dir,
            FileType::File => EntryKind::File,
            FileType::Symlink => EntryKind::Symlink,
            FileType::Other => EntryKind::Other,
        };
        let name = util::file_name(path).to_string();
        Ok(Entry {
            name: name.clone(),
            path: path.to_string(),
            kind,
            size: if kind == EntryKind::Dir {
                0
            } else {
                meta.len()
            },
            modified: meta.modified().ok().and_then(system_time_ms),
            mode: Some(mode_bits(&meta)),
            uid: None,
            gid: None,
            hidden: util::is_probably_hidden(&name),
            link_target: if kind == EntryKind::Symlink {
                self.sftp.read_link(path).await.ok()
            } else {
                None
            },
        })
    }

    pub async fn open_read(
        &self,
        path: &str,
        offset: u64,
    ) -> Result<Box<dyn AsyncRead + Send + Unpin>> {
        use tokio::io::AsyncSeekExt;
        let mut file = self.sftp.open(path).await?;
        if offset > 0 {
            // russh-sftp tracks its own read position and sends it with every
            // request, so a seek is a real remote offset, not a local skip.
            file.seek(std::io::SeekFrom::Start(offset)).await?;
        }
        Ok(Box::new(file))
    }

    /// Opens the file for writing at `offset` without truncating it.
    ///
    /// russh-sftp sends the requested position with every write, so several
    /// handles can fill different ranges of the same file at once.
    pub async fn open_write_at(
        &self,
        path: &str,
        offset: u64,
    ) -> Result<Box<dyn AsyncWrite + Send + Unpin>> {
        use tokio::io::AsyncSeekExt;
        let mut file = self
            .sftp
            .open_with_flags(path, OpenFlags::WRITE | OpenFlags::CREATE)
            .await?;
        if offset > 0 {
            file.seek(std::io::SeekFrom::Start(offset)).await?;
        }
        Ok(Box::new(file))
    }

    pub async fn open_write(
        &self,
        path: &str,
        resume: bool,
    ) -> Result<Box<dyn AsyncWrite + Send + Unpin>> {
        let file = if resume {
            self.sftp
                .open_with_flags(
                    path,
                    OpenFlags::WRITE | OpenFlags::APPEND | OpenFlags::CREATE,
                )
                .await?
        } else {
            self.sftp
                .open_with_flags(
                    path,
                    OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE,
                )
                .await?
        };
        Ok(Box::new(file))
    }

    pub async fn mkdir(&self, path: &str) -> Result<()> {
        match self.sftp.create_dir(path).await {
            Ok(()) => Ok(()),
            Err(e) => {
                // Treat "already exists" as success.
                if self.sftp.try_exists(path).await.unwrap_or(false) {
                    Ok(())
                } else {
                    Err(e.into())
                }
            }
        }
    }

    pub async fn rename(&self, from: &str, to: &str) -> Result<()> {
        if self.sftp.try_exists(to).await.unwrap_or(false) {
            return Err(NovaError::Invalid(format!("already exists: {to}")));
        }
        self.sftp.rename(from, to).await?;
        Ok(())
    }

    pub async fn remove(&self, path: &str, is_dir: bool) -> Result<()> {
        if is_dir {
            // Recursive remove: depth-first walk.
            let listing = self.sftp.read_dir(path).await?;
            let children: Vec<(String, bool)> = listing
                .map(|item| {
                    let is_dir = matches!(item.metadata().file_type(), FileType::Dir);
                    (item.path(), is_dir)
                })
                .collect();
            for (child, child_is_dir) in children {
                Box::pin(self.remove(&child, child_is_dir)).await?;
            }
            self.sftp.remove_dir(path).await?;
        } else {
            self.sftp.remove_file(path).await?;
        }
        Ok(())
    }

    pub async fn canonicalize(&self, path: &str) -> Result<String> {
        Ok(self.sftp.canonicalize(path).await?)
    }
}

fn system_time_ms(t: SystemTime) -> Option<i64> {
    Some(util::unix_ms(t))
}

fn mode_bits(meta: &russh_sftp::client::fs::Metadata) -> u32 {
    let p = meta.permissions();
    let mut mode = 0u32;
    if p.owner_read {
        mode |= 0o400;
    }
    if p.owner_write {
        mode |= 0o200;
    }
    if p.owner_exec {
        mode |= 0o100;
    }
    if p.group_read {
        mode |= 0o040;
    }
    if p.group_write {
        mode |= 0o020;
    }
    if p.group_exec {
        mode |= 0o010;
    }
    if p.other_read {
        mode |= 0o004;
    }
    if p.other_write {
        mode |= 0o002;
    }
    if p.other_exec {
        mode |= 0o001;
    }
    match meta.file_type() {
        FileType::Dir => mode | 0o040000,
        FileType::File => mode | 0o100000,
        FileType::Symlink => mode | 0o120000,
        FileType::Other => mode,
    }
}
