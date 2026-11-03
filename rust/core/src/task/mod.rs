//! Transfer primitives: streaming copy between any two providers.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::error::Result;
use crate::fs::Provider;
use crate::model::EntryKind;
use crate::util;

pub const DEFAULT_CHUNK: usize = 256 * 1024;

#[derive(Debug, Default, Clone, Copy)]
pub struct CopyStats {
    pub files: u64,
    pub bytes: u64,
    /// Entries dropped because the other side sent a name that is not a plain
    /// file name (`..`, `a/b`, `C:` and friends).
    pub skipped: u64,
}

/// Streams one file from `src` to `dst`. Never buffers the whole file.
#[allow(clippy::too_many_arguments)]
pub async fn copy_file(
    src: &Provider,
    src_path: &str,
    dst: &Provider,
    dst_path: &str,
    chunk: usize,
    transferred: &mut u64,
    progress: &mut (dyn FnMut(u64) + Send),
    cancel: Option<Arc<AtomicBool>>,
    resume_offset: u64,
    limit_bps: Option<u64>,
    // How many byte ranges of one file may be written at the same time.
    // 1 = the plain sequential copy.
    parts: u32,
) -> Result<()> {
    use std::time::Instant;

    let source_size = src.stat(src_path).await.map(|e| e.size).unwrap_or(0);

    // Resume ONLY from an offset the caller recorded when it paused this very
    // transfer, and only when the target still has exactly that many bytes.
    // Anything else is copied from scratch: appending to a file of unknown
    // origin produces a full-size but corrupted result.
    let mut skip = 0u64;
    if resume_offset > 0 && resume_offset <= source_size {
        let existing = dst.stat(dst_path).await.map(|e| e.size).unwrap_or(0);
        if existing == resume_offset {
            // Same size is not proof: compare the first block of both files, so
            // an unrelated file of the same length is never appended to.
            skip = if prefix_matches(src, src_path, dst, dst_path).await? {
                resume_offset
            } else {
                0
            };
        }
    }
    if source_size > 0 && skip == source_size {
        *transferred += skip;
        progress(*transferred);
        return Ok(()); // the target already holds the whole file
    }

    // Parallel upload: only for a fresh (not resumed) file on a transport that
    // can write at an offset, without a bandwidth cap (a cap is applied per
    // stream, so several streams would break it).
    let parts = parts.clamp(1, MAX_PARTS) as usize;
    let parallel = parts > 1
        && skip == 0
        && source_size >= PARALLEL_MIN_BYTES
        && limit_bps.map_or(true, |limit| limit == 0)
        && dst.supports_parallel_write();
    if parallel {
        return copy_file_parallel(
            src,
            src_path,
            dst,
            dst_path,
            source_size,
            parts,
            transferred,
            progress,
            cancel,
        )
        .await;
    }

    let mut writer = dst.open_write(dst_path, skip > 0).await?;
    let mut reader = match src.open_read(src_path, skip).await {
        Ok(reader) => reader,
        // A transport that cannot start mid-file must not kill a paused
        // transfer: restart from the beginning and truncate what is there.
        Err(_) if skip > 0 => {
            writer = dst.open_write(dst_path, false).await?;
            skip = 0;
            src.open_read(src_path, 0).await?
        }
        Err(err) => return Err(err),
    };
    if skip > 0 {
        *transferred += skip;
        progress(*transferred);
    }

    let mut buf = vec![0u8; chunk.max(16 * 1024)];
    let started = Instant::now();
    // Only the bytes moved now are paced: the resumed prefix is already on
    // disk and must not stall the limiter for minutes.
    let mut written = 0u64;

    loop {
        if cancelled(cancel.as_deref()) {
            return Err(crate::error::NovaError::Invalid("transfer cancelled".into()));
        }
        let read = reader.read(&mut buf).await?;
        if read == 0 {
            break;
        }
        writer.write_all(&buf[..read]).await?;
        *transferred += read as u64;
        written += read as u64;
        progress(*transferred);

        if let Some(limit) = limit_bps.filter(|l| *l > 0) {
            let expected = written as f64 / limit as f64;
            let actual = started.elapsed().as_secs_f64();
            if expected > actual {
                tokio::time::sleep(std::time::Duration::from_secs_f64(expected - actual)).await;
            }
        }
    }
    writer.flush().await?;
    Ok(())
}

/// Files below this size are not worth splitting: the extra round trips and
/// handles cost more than the saved latency.
pub const PARALLEL_MIN_BYTES: u64 = 8 * 1024 * 1024;

/// Upper bound for `TransferSettings::chunks_per_file`.
pub const MAX_PARTS: u32 = 8;

/// Writes one file through several ranges at once.
///
/// The data goes to `<dst>.nova-part` first and is renamed on success: a paused
/// or failed parallel copy therefore never looks like a finished file, and the
/// exact-offset resume logic (which assumes a contiguous prefix) is never
/// applied to a file with holes.
async fn copy_file_parallel(
    src: &Provider,
    src_path: &str,
    dst: &Provider,
    dst_path: &str,
    size: u64,
    parts: usize,
    transferred: &mut u64,
    progress: &mut (dyn FnMut(u64) + Send),
    cancel: Option<Arc<AtomicBool>>,
) -> Result<()> {
    use std::time::Duration;

    let tmp_path = format!("{dst_path}.nova-part");
    // Create (or truncate) the target so all workers extend a known file.
    {
        let mut writer = dst.open_write(&tmp_path, false).await?;
        tokio::io::AsyncWriteExt::flush(&mut writer).await?;
    }

    let base = *transferred;
    let done = Arc::new(AtomicU64::new(0));
    let abort = cancel.unwrap_or_else(|| Arc::new(AtomicBool::new(false)));
    let part_size = size.div_ceil(parts as u64);

    let mut set = tokio::task::JoinSet::new();
    for index in 0..parts {
        let start = index as u64 * part_size;
        if start >= size {
            break;
        }
        let end = ((index as u64 + 1) * part_size).min(size);
        let src = src.clone();
        let dst = dst.clone();
        let src_path = src_path.to_string();
        let tmp_path = tmp_path.clone();
        let counter = done.clone();
        let abort = abort.clone();
        set.spawn(async move {
            copy_range(&src, &src_path, &dst, &tmp_path, start, end, &counter, &abort).await
        });
    }

    let mut failure: Option<String> = None;
    let mut last = 0u64;
    while !set.is_empty() {
        tokio::select! {
            joined = set.join_next() => {
                match joined {
                    Some(Ok(Ok(()))) => {}
                    Some(Ok(Err(e))) => {
                        if failure.is_none() { failure = Some(e.to_string()); }
                        abort.fetch_or(true, Ordering::Relaxed);
                    }
                    Some(Err(e)) => {
                        if failure.is_none() { failure = Some(format!("поток передачи: {e}")); }
                        abort.fetch_or(true, Ordering::Relaxed);
                    }
                    None => break,
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(200)) => {
                let current = done.load(Ordering::Relaxed);
                if current != last {
                    *transferred = base + current;
                    progress(*transferred);
                    last = current;
                }
            }
        }
    }
    // Drain the remaining tasks so nothing keeps writing after we return.
    set.shutdown().await;

    if let Some(message) = failure {
        let _ = dst.remove(&tmp_path, false).await;
        return Err(crate::error::NovaError::Invalid(message));
    }
    if abort.load(Ordering::Relaxed) {
        let _ = dst.remove(&tmp_path, false).await;
        return Err(crate::error::NovaError::Invalid("transfer cancelled".into()));
    }

    // Replace the previous file (or drop a stale one first when the transport
    // refuses to rename over an existing name).
    if dst.stat(dst_path).await.is_ok() {
        let _ = dst.remove(dst_path, false).await;
    }
    dst.rename(&tmp_path, dst_path).await?;

    *transferred = base + size;
    progress(*transferred);
    Ok(())
}

/// Reads `[start, end)` from the source and writes it at the same offset.
async fn copy_range(
    src: &Provider,
    src_path: &str,
    dst: &Provider,
    dst_path: &str,
    start: u64,
    end: u64,
    done: &AtomicU64,
    abort: &AtomicBool,
) -> Result<()> {
    let mut reader = src.open_read(src_path, start).await?;
    let mut writer = dst.open_write_at(dst_path, start).await?;
    let mut buf = vec![0u8; DEFAULT_CHUNK];
    let mut position = start;
    while position < end {
        if abort.load(Ordering::Relaxed) {
            return Err(crate::error::NovaError::Invalid(
                "transfer cancelled".into(),
            ));
        }
        let want = ((end - position) as usize).min(buf.len());
        let read = tokio::io::AsyncReadExt::read(&mut reader, &mut buf[..want]).await?;
        if read == 0 {
            return Err(crate::error::NovaError::Invalid(
                "source ended before the requested range".into(),
            ));
        }
        tokio::io::AsyncWriteExt::write_all(&mut writer, &buf[..read]).await?;
        position += read as u64;
        done.fetch_add(read as u64, Ordering::Relaxed);
    }
    tokio::io::AsyncWriteExt::flush(&mut writer).await?;
    Ok(())
}

/// Compares the first 64 KiB of both files (or the whole file when shorter).
/// Used before a resumed copy: a stale file of the same size but other content
/// must never be continued.
async fn prefix_matches(
    src: &Provider,
    src_path: &str,
    dst: &Provider,
    dst_path: &str,
) -> Result<bool> {
    const PROBE: usize = 64 * 1024;
    let mut a = src.open_read(src_path, 0).await?;
    let mut b = dst.open_read(dst_path, 0).await?;
    let mut buf_a = vec![0u8; PROBE];
    let mut buf_b = vec![0u8; PROBE];
    let read_a = a.read(&mut buf_a).await?;
    let read_b = b.read(&mut buf_b).await?;
    let n = read_a.min(read_b);
    if n == 0 {
        return Ok(read_a == read_b);
    }
    Ok(buf_a[..n] == buf_b[..n])
}

/// True when the caller asked to stop the transfer.
fn cancelled(cancel: Option<&AtomicBool>) -> bool {
    cancel.map(|flag| flag.load(Ordering::Relaxed)).unwrap_or(false)
}

/// Copies a file or a whole directory tree, reporting bytes as it goes.
#[allow(clippy::too_many_arguments)]
pub async fn copy_path(
    src: &Provider,
    src_path: &str,
    dst: &Provider,
    dst_path: &str,
    chunk: usize,
    stats: &mut CopyStats,
    progress: &mut (dyn FnMut(u64) + Send),
    cancel: Option<Arc<AtomicBool>>,
    resume_offset: u64,
    limit_bps: Option<u64>,
    parts: u32,
) -> Result<()> {
    let entry = src.stat(src_path).await?;
    match entry.kind {
        EntryKind::Dir => {
            dst.mkdir(dst_path).await?;
            let listing = src.list(src_path, true).await?;
            for child in listing.entries {
                // The name comes from the other side: `..\evil` or `C:evil`
                // would let it choose where the file lands on this machine.
                let Some(child_dst) = util::join_child(dst_path, &child.name) else {
                    stats.skipped += 1;
                    continue;
                };
                Box::pin(copy_path(
                    src,
                    &child.path,
                    dst,
                    &child_dst,
                    chunk,
                    stats,
                    progress,
                    cancel.clone(),
                    resume_offset,
                    limit_bps,
                    parts,
                ))
                .await?;
            }
            Ok(())
        }
        _ => {
            copy_file(
                src,
                src_path,
                dst,
                dst_path,
                chunk,
                &mut stats.bytes,
                progress,
                cancel,
                resume_offset,
                limit_bps,
                parts,
            )
            .await?;
            stats.files += 1;
            Ok(())
        }
    }
}

pub async fn move_path(
    src: &Provider,
    src_path: &str,
    dst: &Provider,
    dst_path: &str,
    chunk: usize,
    stats: &mut CopyStats,
    progress: &mut (dyn FnMut(u64) + Send),
) -> Result<()> {
    copy_path(
        src, src_path, dst, dst_path, chunk, stats, progress, None, 0, None, 1,
    )
    .await?;
    let entry = src.stat(src_path).await?;
    src.remove(src_path, entry.kind == EntryKind::Dir).await?;
    Ok(())
}

/// Creates a uniquely named sibling: `photo.jpg` -> `photo (2).jpg`.
pub fn dedupe_name(existing: &std::collections::HashSet<String>, name: &str) -> String {
    if !existing.contains(name) {
        return name.to_string();
    }
    let (stem, ext) = match name.rfind('.') {
        Some(i) if i > 0 => (&name[..i], &name[i..]),
        _ => (name, ""),
    };
    for n in 2..10_000 {
        let candidate = format!("{stem} ({n}){ext}");
        if !existing.contains(&candidate) {
            return candidate;
        }
    }
    name.to_string()
}

/// Remote work runs through a single-provider wrapper to avoid lifetime issues
/// when a panel holds a provider behind an `Arc`.
#[derive(Clone)]
pub struct SharedProvider(pub Arc<Provider>);

impl SharedProvider {
    pub async fn list(&self, path: &str, show_hidden: bool) -> Result<crate::model::DirListing> {
        self.0.list(path, show_hidden).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fs::local::LocalFs;


    /// Copies `source` to `target` with the given resume offset.
    fn copy_with(
        src_dir: &std::path::Path,
        dst_dir: &std::path::Path,
        from: &str,
        to: &str,
        resume_offset: u64,
    ) -> Result<()> {
        copy_with_parts(src_dir, dst_dir, from, to, resume_offset, 1)
    }

    fn copy_with_parts(
        src_dir: &std::path::Path,
        dst_dir: &std::path::Path,
        from: &str,
        to: &str,
        resume_offset: u64,
        parts: u32,
    ) -> Result<()> {
        let src = Provider::Local(LocalFs::new());
        let dst = Provider::Local(LocalFs::new());
        let mut stats = CopyStats::default();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let from_path = src_dir.join(from).to_string_lossy().to_string();
        let to_path = dst_dir.join(to).to_string_lossy().to_string();
        runtime.block_on(copy_path(
            &src,
            &from_path,
            &dst,
            &to_path,
            DEFAULT_CHUNK,
            &mut stats,
            &mut |_| {},
            None,
            resume_offset,
            None,
            parts,
        ))
    }

    #[test]
    fn parallel_copy_is_byte_identical_and_leaves_no_temp() {
        let src_dir = tempfile::tempdir().unwrap();
        let dst_dir = tempfile::tempdir().unwrap();
        let size = 20 * 1024 * 1024usize;
        let payload: Vec<u8> = (0..size).map(|i| (i % 251) as u8).collect();
        std::fs::write(src_dir.path().join("big.bin"), &payload).unwrap();

        copy_with_parts(src_dir.path(), dst_dir.path(), "big.bin", "big.bin", 0, 4).unwrap();

        let out = std::fs::read(dst_dir.path().join("big.bin")).unwrap();
        assert_eq!(out.len(), payload.len());
        assert!(out == payload, "parallel copy corrupted the file");
        assert!(!dst_dir.path().join("big.bin.nova-part").exists());
    }

    #[test]
    fn parallel_copy_replaces_an_existing_file() {
        let src_dir = tempfile::tempdir().unwrap();
        let dst_dir = tempfile::tempdir().unwrap();
        let payload: Vec<u8> = (0..(9 * 1024 * 1024usize))
            .map(|i| (i % 7) as u8)
            .collect();
        std::fs::write(src_dir.path().join("big.bin"), &payload).unwrap();
        std::fs::write(dst_dir.path().join("big.bin"), b"old contents").unwrap();

        copy_with_parts(src_dir.path(), dst_dir.path(), "big.bin", "big.bin", 0, 3).unwrap();

        let out = std::fs::read(dst_dir.path().join("big.bin")).unwrap();
        assert!(out == payload);
    }

    #[test]
    fn full_copy_overwrites_a_larger_leftover() {
        let src_dir = tempfile::tempdir().unwrap();
        let dst_dir = tempfile::tempdir().unwrap();
        let payload = b"the real file";
        std::fs::write(src_dir.path().join("a.bin"), payload).unwrap();
        // A stale, bigger file with the same name must be replaced, not kept.
        std::fs::write(dst_dir.path().join("a.bin"), vec![b'x'; 100]).unwrap();

        copy_with(src_dir.path(), dst_dir.path(), "a.bin", "a.bin", 0).unwrap();
        let out = std::fs::read(dst_dir.path().join("a.bin")).unwrap();
        assert_eq!(out, payload);
    }

    #[test]
    fn resume_from_the_exact_offset_continues_the_file() {
        let src_dir = tempfile::tempdir().unwrap();
        let dst_dir = tempfile::tempdir().unwrap();
        let payload: Vec<u8> = (0..500u32).map(|i| (i % 251) as u8).collect();
        std::fs::write(src_dir.path().join("a.bin"), &payload).unwrap();
        std::fs::write(dst_dir.path().join("a.bin"), &payload[..200]).unwrap();

        copy_with(src_dir.path(), dst_dir.path(), "a.bin", "a.bin", 200).unwrap();
        let out = std::fs::read(dst_dir.path().join("a.bin")).unwrap();
        assert_eq!(out, payload);
    }

    #[test]
    fn resume_with_a_foreign_prefix_copies_from_scratch() {
        let src_dir = tempfile::tempdir().unwrap();
        let dst_dir = tempfile::tempdir().unwrap();
        let payload: Vec<u8> = (0..500u32).map(|i| (i % 251) as u8).collect();
        std::fs::write(src_dir.path().join("a.bin"), &payload).unwrap();
        // 200 bytes of something else: appending would corrupt the result.
        std::fs::write(dst_dir.path().join("a.bin"), vec![b'z'; 200]).unwrap();

        copy_with(src_dir.path(), dst_dir.path(), "a.bin", "a.bin", 200).unwrap();
        let out = std::fs::read(dst_dir.path().join("a.bin")).unwrap();
        assert_eq!(out, payload, "a mismatched prefix must trigger a full copy");
    }

    #[test]
    fn resume_offset_larger_than_the_source_is_ignored() {
        let src_dir = tempfile::tempdir().unwrap();
        let dst_dir = tempfile::tempdir().unwrap();
        let payload = b"small";
        std::fs::write(src_dir.path().join("a.bin"), payload).unwrap();
        std::fs::write(dst_dir.path().join("a.bin"), b"junk").unwrap();

        copy_with(src_dir.path(), dst_dir.path(), "a.bin", "a.bin", 999).unwrap();
        let out = std::fs::read(dst_dir.path().join("a.bin")).unwrap();
        assert_eq!(out, payload);
    }

    #[test]
    fn resume_at_the_end_keeps_the_complete_file() {
        let src_dir = tempfile::tempdir().unwrap();
        let dst_dir = tempfile::tempdir().unwrap();
        let payload = b"already there";
        std::fs::write(src_dir.path().join("a.bin"), payload).unwrap();
        std::fs::write(dst_dir.path().join("a.bin"), payload).unwrap();

        copy_with(
            src_dir.path(),
            dst_dir.path(),
            "a.bin",
            "a.bin",
            payload.len() as u64,
        )
        .unwrap();
        assert_eq!(std::fs::read(dst_dir.path().join("a.bin")).unwrap(), payload);
    }

    #[tokio::test]
    async fn copies_tree_between_local_dirs() {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();

        std::fs::create_dir_all(src.path().join("sub")).unwrap();
        std::fs::write(src.path().join("a.txt"), b"hello").unwrap();
        std::fs::write(src.path().join("sub").join("b.txt"), b"world!").unwrap();

        let provider_src = Provider::Local(LocalFs::new());
        let provider_dst = Provider::Local(LocalFs::new());

        let mut stats = CopyStats::default();
        let mut seen = 0u64;
        let target = dst.path().join("copy").to_string_lossy().to_string();
        copy_path(
            &provider_src,
            &src.path().to_string_lossy(),
            &provider_dst,
            &target,
            DEFAULT_CHUNK,
            &mut stats,
            &mut |done| seen = done,
            None,
            0,
            None,
            1,
        )
        .await
        .unwrap();

        assert_eq!(stats.files, 2);
        assert_eq!(stats.bytes, 11);
        assert_eq!(seen, 11);
        assert!(dst.path().join("copy").join("sub").join("b.txt").exists());
    }

    #[tokio::test]
    async fn dedupe_names() {
        let mut set = std::collections::HashSet::new();
        set.insert("a.txt".to_string());
        set.insert("a (2).txt".to_string());
        assert_eq!(dedupe_name(&set, "a.txt"), "a (3).txt");
        assert_eq!(dedupe_name(&set, "b.txt"), "b.txt");
    }

    #[tokio::test]
    async fn move_removes_source() {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        let file = src.path().join("m.txt");
        std::fs::write(&file, b"data").unwrap();

        let a = Provider::Local(LocalFs::new());
        let b = Provider::Local(LocalFs::new());
        let target = dst.path().join("m.txt").to_string_lossy().to_string();
        let mut stats = CopyStats::default();
        move_path(
            &a,
            &file.to_string_lossy(),
            &b,
            &target,
            DEFAULT_CHUNK,
            &mut stats,
            &mut |_| {},
        )
        .await
        .unwrap();

        assert!(!file.exists());
        assert!(std::path::Path::new(&target).exists());
    }
}
