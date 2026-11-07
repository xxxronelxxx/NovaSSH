//! Local filesystem provider (Windows drives, Android app storage / SAF roots).

use std::path::Path;
use std::time::SystemTime;

use tokio::fs::File;
use tokio::io::{AsyncRead, AsyncSeekExt, AsyncWrite};

use crate::error::{NovaError, Result};
use crate::model::{DirListing, Entry, EntryKind, Volume};
use crate::util;

pub struct LocalFs;

impl Default for LocalFs {
    fn default() -> Self {
        Self
    }
}

/// Normalizes user input into a real local path.
///
/// On Windows `/` and `\` mean "current drive root"; they used to be reported
/// back verbatim, which made the parent-navigation look like it jumped to root.
pub fn normalize_local(path: &str) -> String {
    #[cfg(windows)]
    {
        let mut cleaned = path.trim().replace('/', "\\");
        if cleaned.is_empty() || cleaned == "\\" {
            return drive_root();
        }
        // Strip trailing separators except for "C:\".
        while cleaned.len() > 3 && cleaned.ends_with(std::path::MAIN_SEPARATOR) {
            cleaned.pop();
        }
        cleaned
    }
    #[cfg(not(windows))]
    {
        let cleaned = path.trim();
        if cleaned.is_empty() {
            return "/".to_string();
        }
        cleaned.to_string()
    }
}

#[cfg(windows)]
fn drive_root() -> String {
    if let Ok(cwd) = std::env::current_dir() {
        let mut s = cwd.to_string_lossy().to_string();
        if s.len() >= 2 {
            s.truncate(2);
            s.push(std::path::MAIN_SEPARATOR);
            return s;
        }
    }
    "C:\\".to_string()
}

impl LocalFs {
    pub fn new() -> Self {
        Self
    }

    pub async fn list(&self, path: &str, show_hidden: bool) -> Result<DirListing> {
        let path = normalize_local(path);
        let mut reader = tokio::fs::read_dir(&path).await?;
        let mut entries = Vec::new();

        while let Some(item) = reader.next_entry().await? {
            let name = item.file_name().to_string_lossy().to_string();
            let full = util::join(&path, &name);
            match entry_from_metadata(&full, &name, &item.metadata().await) {
                Ok(entry) => {
                    if show_hidden || !entry.hidden {
                        entries.push(entry);
                    }
                }
                Err(_) => continue,
            }
        }

        let (free, total) = self.space(&path).unwrap_or((None, None));
        Ok(DirListing {
            path: path.clone(),
            parent: util::parent(&path),
            entries,
            free_space: free,
            total_space: total,
        })
    }

    pub async fn stat(&self, path: &str) -> Result<Entry> {
        let meta = tokio::fs::symlink_metadata(path).await?;
        let name = util::file_name(path).to_string();
        entry_from_metadata(path, &name, &Ok(meta))
    }

    pub async fn open_read(
        &self,
        path: &str,
        offset: u64,
    ) -> Result<Box<dyn AsyncRead + Send + Unpin>> {
        let mut file = File::open(path).await?;
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
            tokio::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .await?
        } else {
            File::create(path).await?
        };
        Ok(Box::new(file))
    }

    /// Opens an existing file for writing at `offset` (no truncation).
    pub async fn open_write_at(
        &self,
        path: &str,
        offset: u64,
    ) -> Result<Box<dyn AsyncWrite + Send + Unpin>> {
        let mut file = tokio::fs::OpenOptions::new()
            .write(true)
            .open(path)
            .await?;
        file.seek(std::io::SeekFrom::Start(offset)).await?;
        Ok(Box::new(file))
    }

    pub async fn mkdir(&self, path: &str) -> Result<()> {
        tokio::fs::create_dir_all(path).await?;
        Ok(())
    }

    pub async fn rename(&self, from: &str, to: &str) -> Result<()> {
        if Path::new(to).exists() {
            return Err(NovaError::Invalid(format!("already exists: {to}")));
        }
        tokio::fs::rename(from, to).await?;
        Ok(())
    }

    pub async fn remove(&self, path: &str, is_dir: bool) -> Result<()> {
        if is_dir {
            tokio::fs::remove_dir_all(path).await?;
        } else {
            tokio::fs::remove_file(path).await?;
        }
        Ok(())
    }

    pub async fn set_mode(&self, path: &str, mode: u32) -> Result<()> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(mode);
            tokio::fs::set_permissions(path, perms).await?;
        }
        #[cfg(windows)]
        {
            // Windows only exposes a read-only flag.
            let readonly = mode & 0o200 == 0;
            let mut perms = tokio::fs::metadata(path).await?.permissions();
            perms.set_readonly(readonly);
            tokio::fs::set_permissions(path, perms).await?;
        }
        Ok(())
    }

    /// Sets the modification time, used when unpacking archives.
    pub async fn set_times(&self, path: &str, mtime_ms: i64) -> Result<()> {
        let path = path.to_string();
        let seconds = mtime_ms.div_euclid(1000);
        let nanos = (mtime_ms.rem_euclid(1000) * 1_000_000) as u32;
        tokio::task::spawn_blocking(move || {
            filetime::set_file_mtime(
                &path,
                filetime::FileTime::from_unix_time(seconds, nanos),
            )
            .map_err(crate::error::NovaError::from)
        })
        .await
        .map_err(|e| crate::error::NovaError::Invalid(e.to_string()))?
    }

    /// Human-readable volumes for the drive selector.
    pub fn volumes(&self) -> Vec<Volume> {
        volumes_impl()
    }

    pub fn space(&self, path: &str) -> Option<(Option<u64>, Option<u64>)> {
        space_impl(path)
    }

    pub async fn home(&self) -> String {
        dirs::home_dir()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(root_default)
    }
}

fn entry_from_metadata(
    full: &str,
    name: &str,
    meta: &std::io::Result<std::fs::Metadata>,
) -> Result<Entry> {
    let meta = meta
        .as_ref()
        .map_err(|e| NovaError::Io(std::io::Error::new(e.kind(), e.to_string())))?;
    let ft = meta.file_type();
    let kind = if ft.is_symlink() {
        EntryKind::Symlink
    } else if ft.is_dir() {
        EntryKind::Dir
    } else if ft.is_file() {
        EntryKind::File
    } else {
        EntryKind::Other
    };

    let modified = meta.modified().ok().and_then(system_time_ms);

    Ok(Entry {
        name: name.to_string(),
        path: full.to_string(),
        kind,
        size: if kind == EntryKind::Dir {
            0
        } else {
            meta.len()
        },
        modified,
        mode: mode_of(meta),
        uid: None,
        gid: None,
        hidden: is_hidden(name, meta),
        link_target: if kind == EntryKind::Symlink {
            std::fs::read_link(full)
                .ok()
                .map(|p| p.to_string_lossy().to_string())
        } else {
            None
        },
    })
}

fn system_time_ms(t: SystemTime) -> Option<i64> {
    Some(util::unix_ms(t))
}

fn mode_of(meta: &std::fs::Metadata) -> Option<u32> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        Some(meta.permissions().mode())
    }
    #[cfg(windows)]
    {
        let readonly = meta.permissions().readonly();
        Some(if readonly { 0o444 } else { 0o644 })
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = meta;
        None
    }
}

fn is_hidden(name: &str, meta: &std::fs::Metadata) -> bool {
    if util::is_probably_hidden(name) {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
        meta.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0
    }
    #[cfg(not(windows))]
    {
        let _ = meta;
        false
    }
}

fn root_default() -> String {
    #[cfg(windows)]
    {
        "C:\\".to_string()
    }
    #[cfg(not(windows))]
    {
        "/".to_string()
    }
}

// ---------------------------------------------------------------------------
// Platform-specific volume and free-space queries
// ---------------------------------------------------------------------------

#[cfg(windows)]
fn volumes_impl() -> Vec<Volume> {
    use windows::core::PCWSTR;
    use windows::Win32::Storage::FileSystem::{GetDriveTypeW, GetLogicalDrives};

    // Stable Win32 drive type values.
    const DRIVE_NO_ROOT_DIR: u32 = 1;
    const DRIVE_REMOVABLE: u32 = 2;
    const DRIVE_FIXED: u32 = 3;
    const DRIVE_REMOTE: u32 = 4;
    const DRIVE_CDROM: u32 = 5;
    const DRIVE_RAMDISK: u32 = 6;

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    let mask = unsafe { GetLogicalDrives() };
    let mut out = Vec::new();
    for bit in 0..26u32 {
        if mask & (1 << bit) == 0 {
            continue;
        }
        let letter = (b'A' + bit as u8) as char;
        let root = format!("{letter}:\\");
        let w = wide(&root);
        let drive_type = unsafe { GetDriveTypeW(PCWSTR(w.as_ptr())) };
        if drive_type == DRIVE_NO_ROOT_DIR {
            continue;
        }
        let kind = match drive_type {
            DRIVE_FIXED => "fixed",
            DRIVE_REMOVABLE => "removable",
            DRIVE_REMOTE => "network",
            DRIVE_CDROM => "cdrom",
            DRIVE_RAMDISK => "ram",
            _ => "unknown",
        };
        let (free, total) = space_windows(&root).unwrap_or((None, None));
        out.push(Volume {
            path: root.clone(),
            name: format!("{letter}:"),
            kind: kind.to_string(),
            free_space: free,
            total_space: total,
        });
    }
    out
}

#[cfg(windows)]
fn space_windows(root: &str) -> Option<(Option<u64>, Option<u64>)> {
    use windows::core::PCWSTR;
    use windows::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;

    let w: Vec<u16> = root.encode_utf16().chain(std::iter::once(0)).collect();
    let mut free_to_caller: u64 = 0;
    let mut total: u64 = 0;
    let mut total_free: u64 = 0;
    let ok = unsafe {
        GetDiskFreeSpaceExW(
            PCWSTR(w.as_ptr()),
            Some(&mut free_to_caller),
            Some(&mut total),
            Some(&mut total_free),
        )
    };
    ok.ok().map(|_| (Some(free_to_caller), Some(total)))
}

#[cfg(windows)]
fn space_impl(path: &str) -> Option<(Option<u64>, Option<u64>)> {
    // Free space is queried on the drive root, not on the directory itself.
    let root = if path.len() >= 2 && path.as_bytes()[1] == b':' {
        format!("{}\\", &path[..2])
    } else {
        "C:\\".to_string()
    };
    space_windows(&root)
}

#[cfg(not(windows))]
fn volumes_impl() -> Vec<Volume> {
    let mut out = vec![Volume {
        path: "/".into(),
        name: "/".into(),
        kind: "fixed".into(),
        free_space: None,
        total_space: None,
    }];
    if let Some(home) = dirs::home_dir() {
        out.push(Volume {
            path: home.to_string_lossy().to_string(),
            name: "home".into(),
            kind: "home".into(),
            free_space: None,
            total_space: None,
        });
    }
    out
}

#[cfg(not(windows))]
fn space_impl(_path: &str) -> Option<(Option<u64>, Option<u64>)> {
    None
}

pub async fn current_volumes_local() -> Vec<Volume> {
    LocalFs::new().volumes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn lists_temp_dir_and_finds_file() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.txt"), b"hello").unwrap();
        std::fs::create_dir_all(dir.path().join("sub")).unwrap();

        let fs = LocalFs::new();
        let path = dir.path().to_string_lossy().to_string();
        let listing = fs.list(&path, true).await.unwrap();
        let names: Vec<_> = listing.entries.iter().map(|e| e.name.clone()).collect();
        assert!(names.contains(&"a.txt".to_string()));
        assert!(names.contains(&"sub".to_string()));

        let entry = fs
            .stat(&dir.path().join("a.txt").to_string_lossy())
            .await
            .unwrap();
        assert_eq!(entry.size, 5);
        assert_eq!(entry.kind, EntryKind::File);
    }

    #[tokio::test]
    async fn writes_reads_and_removes() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("out.bin").to_string_lossy().to_string();
        let fs = LocalFs::new();

        {
            use tokio::io::AsyncWriteExt;
            let mut w = fs.open_write(&target, false).await.unwrap();
            w.write_all(b"abcdef").await.unwrap();
            w.flush().await.unwrap();
        }
        {
            use tokio::io::AsyncReadExt;
            let mut r = fs.open_read(&target, 2).await.unwrap();
            let mut buf = Vec::new();
            r.read_to_end(&mut buf).await.unwrap();
            assert_eq!(buf, b"cdef");
        }
        fs.remove(&target, false).await.unwrap();
        assert!(!std::path::Path::new(&target).exists());
    }

    #[tokio::test]
    async fn mkdir_and_rename_refuse_overwrite() {
        let dir = tempfile::tempdir().unwrap();
        let fs = LocalFs::new();
        let a = dir.path().join("a").to_string_lossy().to_string();
        let b = dir.path().join("b").to_string_lossy().to_string();
        fs.mkdir(&a).await.unwrap();
        fs.rename(&a, &b).await.unwrap();
        std::fs::write(&a, b"x").unwrap();
        assert!(fs.rename(&b, &a).await.is_err());
    }
}
