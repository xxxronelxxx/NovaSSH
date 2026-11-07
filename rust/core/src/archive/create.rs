//! Creating archives: ZIP, TAR (raw/gz/bz2/xz/zst), 7z and single-file
//! compressors.
//!
//! Sources are local paths; remote servers pack with their own CLI tools
//! (`tar`, `zip`, `7z`), which keeps a 5 GB archive on the server instead of
//! pulling it through the SFTP channel.

use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use crate::archive::format::ArchiveFormat;
use crate::error::{NovaError, Result};
use crate::util;

#[derive(Debug, Clone, Default)]
pub struct CreateReport {
    pub files: u32,
    pub bytes: u64,
    /// The user stopped an in-place append; the archive is still valid and
    /// contains everything written before the stop.
    pub cancelled: bool,
}

fn cancelled_error() -> NovaError {
    NovaError::Invalid("__cancelled__".into())
}

/// Wraps a reader so a long file can be interrupted between chunks.
struct CancelReader<'a, R> {
    inner: R,
    cancelled: &'a dyn Fn() -> bool,
}

impl<'a, R: Read> CancelReader<'a, R> {
    fn new(inner: R, cancelled: &'a dyn Fn() -> bool) -> Self {
        Self { inner, cancelled }
    }
}

impl<R: Read> Read for CancelReader<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if (self.cancelled)() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "__cancelled__",
            ));
        }
        self.inner.read(buf)
    }
}

struct Item {
    abs: PathBuf,
    name: String,
    is_dir: bool,
    size: u64,
}

/// Walks the selected paths and returns their flat, root-relative layout.
fn collect(sources: &[String], target: &str) -> Result<Vec<Item>> {
    collect_with_prefix(sources, target, "", &|| false)
}

fn collect_with_prefix(
    sources: &[String],
    target: &str,
    prefix: &str,
    cancelled: &dyn Fn() -> bool,
) -> Result<Vec<Item>> {
    let target_path = Path::new(target);
    let mut out = Vec::new();
    let mut stack: Vec<(PathBuf, String)> = Vec::new();

    for source in sources {
        let path = PathBuf::from(source);
        let base = util::file_name(source).to_string();
        if base.is_empty() {
            return Err(NovaError::Invalid(format!("cannot take {source}")));
        }
        let name = if prefix.trim_matches('/').is_empty() {
            base
        } else {
            format!("{}/{}", prefix.trim_matches('/'), base)
        };
        stack.push((path, name));
    }

    let mut guard = 0usize;
    while let Some((abs, name)) = stack.pop() {
        if cancelled() {
            return Err(cancelled_error());
        }
        guard += 1;
        if guard > 200_000 {
            return Err(NovaError::Invalid("слишком много файлов для архива".into()));
        }
        if abs == target_path {
            continue;
        }
        // `symlink_metadata` prevents a symlink loop from expanding forever.
        let meta = std::fs::symlink_metadata(&abs)
            .map_err(|e| NovaError::Invalid(format!("{}: {e}", abs.display())))?;
        if meta.file_type().is_symlink() {
            continue;
        }
        if meta.is_dir() {
            out.push(Item {
                abs: abs.clone(),
                name: name.clone(),
                is_dir: true,
                size: 0,
            });
            let Ok(read) = std::fs::read_dir(&abs) else {
                continue;
            };
            let mut children: Vec<_> = read.flatten().collect();
            children.sort_by_key(|entry| entry.file_name());
            for child in children {
                let child_name = child.file_name().to_string_lossy().to_string();
                stack.push((child.path(), format!("{name}/{child_name}")));
            }
        } else {
            out.push(Item {
                abs,
                name,
                is_dir: false,
                size: meta.len(),
            });
        }
    }

    if out.is_empty() {
        return Err(NovaError::Invalid("нечего упаковывать".into()));
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

/// Packs `sources` into `target` using the format implied by the file name,
/// or `format` when explicitly given.
pub fn create_archive(
    format: Option<ArchiveFormat>,
    sources: &[String],
    target: &str,
) -> Result<CreateReport> {
    create_archive_cancellable(format, sources, target, &|| false)
}

/// Same as [`create_archive`], but stops when `cancelled` turns true. The
/// half-written `.nova-part` file is removed, so the target is untouched.
pub fn create_archive_cancellable(
    format: Option<ArchiveFormat>,
    sources: &[String],
    target: &str,
    cancelled: &dyn Fn() -> bool,
) -> Result<CreateReport> {
    if sources.is_empty() {
        return Err(NovaError::Invalid("Нечего упаковывать".into()));
    }
    let format = match format {
        Some(format) => format,
        None => ArchiveFormat::from_path(target).ok_or_else(|| {
            NovaError::Invalid("Не удалось определить формат архива по имени файла".into())
        })?,
    };

    let items = collect_with_prefix(sources, target, "", cancelled)?;
    if format.is_single() && (items.iter().filter(|i| !i.is_dir).count() != 1 || items.len() != 1) {
        return Err(NovaError::Invalid(format!(
            "{} сжимает ровно один файл",
            format.label()
        )));
    }

    // Write next to the target and rename at the end: a failed run must not
    // leave a half-written archive under the real name.
    let partial = format!("{target}.nova-part");
    let _ = std::fs::remove_file(&partial);
    let result = match format {
        ArchiveFormat::Zip => write_zip(&items, &partial, cancelled),
        ArchiveFormat::SevenZ => write_7z(&items, &partial, cancelled),
        f if f.is_tar() => write_tar(&items, &partial, f, cancelled),
        f if f.is_single() => write_single(&items, &partial, f, cancelled),
        other => Err(NovaError::Unsupported(format!(
            "{} is not supported",
            other.label()
        ))),
    };

    match result {
        Ok(report) => {
            let _ = std::fs::remove_file(target);
            std::fs::rename(&partial, target)?;
            Ok(report)
        }
        Err(e) => {
            let _ = std::fs::remove_file(&partial);
            Err(e)
        }
    }
}

/// Appends files/folders to an existing archive **without rewriting it**.
///
/// Only ZIP and uncompressed TAR can grow in place: ZIP by appending another
/// local file + central directory record, TAR by cutting the end-of-archive
/// marker and writing new entries. Compressed TAR and 7z return
/// `Unsupported`, and the caller falls back to a full rebuild.
pub fn append_archive(
    format: ArchiveFormat,
    archive_path: &str,
    sources: &[String],
) -> Result<CreateReport> {
    append_archive_cancellable(format, archive_path, sources, &|| false)
}

/// Appends between whole files only: a half-written member would corrupt the
/// archive, so the current file always finishes.
pub fn append_archive_cancellable(
    format: ArchiveFormat,
    archive_path: &str,
    sources: &[String],
    cancelled: &dyn Fn() -> bool,
) -> Result<CreateReport> {
    if sources.is_empty() {
        return Err(NovaError::Invalid("Нечего добавлять".into()));
    }
    // Collecting the list is instant; cancellation applies to writing, where
    // it can actually take minutes.
    let items = collect(sources, archive_path)?;
    match format {
        ArchiveFormat::Zip => append_zip(&items, archive_path, cancelled),
        ArchiveFormat::Tar => append_tar(&items, archive_path, cancelled),
        other => Err(NovaError::Unsupported(format!(
            "{} нельзя дополнить на месте",
            other.label()
        ))),
    }
}

fn append_zip(
    items: &[Item],
    target: &str,
    cancelled: &dyn Fn() -> bool,
) -> Result<CreateReport> {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(target)?;
    let mut zip = zip::ZipWriter::new_append(file)
        .map_err(|e| NovaError::Invalid(format!("cannot append to zip: {e}")))?;
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    let mut report = CreateReport::default();
    for item in items {
        if cancelled() {
            report.cancelled = true;
            break;
        }
        if item.is_dir {
            zip.add_directory(format!("{}/", item.name.trim_end_matches('/')), options)
                .map_err(|e| NovaError::Invalid(e.to_string()))?;
            continue;
        }
        zip.start_file(item.name.clone(), options)
            .map_err(|e| NovaError::Invalid(e.to_string()))?;
        let mut reader = File::open(&item.abs)?;
        copy_into(&mut reader, &mut zip, &mut report, &|| false)?;
    }
    zip.finish()
        .map_err(|e| NovaError::Invalid(format!("zip: {e}")))?;
    Ok(report)
}

fn append_tar(
    items: &[Item],
    target: &str,
    cancelled: &dyn Fn() -> bool,
) -> Result<CreateReport> {
    use std::io::{Seek, SeekFrom};

    // Find where the last member ends, drop the trailing zero blocks and
    // continue from there. `tar` would otherwise stop at the first marker.
    let end = {
        let file = File::open(target)?;
        let mut archive = tar::Archive::new(file);
        let mut end = 0u64;
        let entries = archive
            .entries()
            .map_err(|e| NovaError::Invalid(format!("cannot read tar: {e}")))?;
        for item in entries {
            let Ok(entry) = item else { continue };
            let size = entry.header().size().unwrap_or(0);
            let padded = size.div_ceil(512) * 512;
            end = end.max(entry.raw_file_position() + padded);
        }
        end
    };

    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(target)?;
    file.set_len(end)?;
    file.seek(SeekFrom::Start(end))?;

    let mut report = CreateReport::default();
    let mut builder = tar::Builder::new(file);
    for item in items {
        if cancelled() {
            report.cancelled = true;
            break;
        }
        builder
            .append_path_with_name(&item.abs, &item.name)
            .map_err(|e| NovaError::Invalid(format!("{}: {e}", item.name)))?;
        if !item.is_dir {
            report.files += 1;
            report.bytes += item.size;
        }
    }
    // Always finish: the end-of-archive marker keeps a partial append usable.
    builder.finish()?;
    Ok(report)
}

fn write_zip(
    items: &[Item],
    target: &str,
    cancelled: &dyn Fn() -> bool,
) -> Result<CreateReport> {
    let file = File::create(target)?;
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    let mut report = CreateReport::default();
    for item in items {
        if cancelled() {
            return Err(cancelled_error());
        }
        if item.is_dir {
            zip.add_directory(format!("{}/", item.name.trim_end_matches('/')), options)
                .map_err(|e| NovaError::Invalid(e.to_string()))?;
            continue;
        }
        zip.start_file(item.name.clone(), options)
            .map_err(|e| NovaError::Invalid(e.to_string()))?;
        let mut reader = File::open(&item.abs)?;
        copy_into(&mut reader, &mut zip, &mut report, cancelled)?;
    }
    zip.finish().map_err(|e| NovaError::Invalid(e.to_string()))?;
    Ok(report)
}

fn write_tar(
    items: &[Item],
    target: &str,
    format: ArchiveFormat,
    cancelled: &dyn Fn() -> bool,
) -> Result<CreateReport> {
    let file = File::create(target)?;
    let mut report = CreateReport::default();

    macro_rules! run {
        ($writer:expr, $finish:expr) => {{
            let mut builder = tar::Builder::new($writer);
            for item in items {
                if cancelled() {
                    return Err(cancelled_error());
                }
                if item.is_dir {
                    builder
                        .append_path_with_name(&item.abs, &item.name)
                        .map_err(|e| NovaError::Invalid(format!("{}: {e}", item.name)))?;
                } else {
                    let meta = std::fs::metadata(&item.abs)?;
                    let mut header = tar::Header::new_gnu();
                    header.set_metadata(&meta);
                    header.set_size(meta.len());
                    header.set_cksum();
                    let reader = CancelReader::new(File::open(&item.abs)?, cancelled);
                    builder
                        .append_data(&mut header, &item.name, reader)
                        .map_err(|e| NovaError::Invalid(format!("{}: {e}", item.name)))?;
                    report.files += 1;
                    report.bytes += item.size;
                }
            }
            builder.finish()?;
            let writer = builder.into_inner()?;
            $finish(writer)?;
        }};
    }

    match format {
        ArchiveFormat::Tar => {
            run!(file, |w: File| -> Result<()> { Ok(w.sync_all()?) });
        }
        ArchiveFormat::TarGz => {
            let encoder = flate2::write::GzEncoder::new(file, flate2::Compression::default());
            run!(encoder, |w: flate2::write::GzEncoder<File>| -> Result<()> {
                w.finish()?;
                Ok(())
            });
        }
        ArchiveFormat::TarBz2 => {
            let encoder = bzip2::write::BzEncoder::new(file, bzip2::Compression::default());
            run!(encoder, |w: bzip2::write::BzEncoder<File>| -> Result<()> {
                w.finish()?;
                Ok(())
            });
        }
        ArchiveFormat::TarXz => {
            let encoder = liblzma::write::XzEncoder::new(file, 6);
            run!(encoder, |w: liblzma::write::XzEncoder<File>| -> Result<()> {
                w.finish()?;
                Ok(())
            });
        }
        ArchiveFormat::TarZst => {
            let encoder = zstd::stream::write::Encoder::new(file, 3)
                .map_err(|e| NovaError::Invalid(format!("zstd: {e}")))?;
            run!(encoder, |w: zstd::stream::write::Encoder<File>| -> Result<()> {
                w.finish()?;
                Ok(())
            });
        }
        other => {
            return Err(NovaError::Unsupported(format!(
                "{} is not a tar format",
                other.label()
            )))
        }
    }
    Ok(report)
}

fn write_7z(
    items: &[Item],
    target: &str,
    cancelled: &dyn Fn() -> bool,
) -> Result<CreateReport> {
    use sevenz_rust2::{SevenZArchiveEntry, SevenZWriter};

    let mut writer = SevenZWriter::create(target)
        .map_err(|e| NovaError::Invalid(format!("7z: {e}")))?;
    let mut report = CreateReport::default();
    for item in items {
        if cancelled() {
            return Err(cancelled_error());
        }
        if item.is_dir {
            let entry = SevenZArchiveEntry::new_folder(item.name.trim_end_matches('/'));
            writer
                .push_archive_entry::<File>(entry, None)
                .map_err(|e| NovaError::Invalid(format!("{}: {e}", item.name)))?;
            continue;
        }
        let entry = SevenZArchiveEntry::from_path(&item.abs, item.name.clone());
        let reader = CancelReader::new(File::open(&item.abs)?, cancelled);
        writer
            .push_archive_entry(entry, Some(reader))
            .map_err(|e| NovaError::Invalid(format!("{}: {e}", item.name)))?;
        report.files += 1;
        report.bytes += item.size;
    }
    writer
        .finish()
        .map_err(|e| NovaError::Invalid(format!("7z: {e}")))?;
    Ok(report)
}

fn write_single(
    items: &[Item],
    target: &str,
    format: ArchiveFormat,
    cancelled: &dyn Fn() -> bool,
) -> Result<CreateReport> {
    let Some(item) = items.iter().find(|item| !item.is_dir) else {
        return Err(NovaError::Invalid("выберите файл".into()));
    };
    let mut reader = File::open(&item.abs)?;
    let file = File::create(target)?;
    let mut report = CreateReport::default();

    match format {
        ArchiveFormat::Gz => {
            // Gzip can carry the original name, so a `.gz` made by Nova opens
            // as `notes.txt` rather than `notes`.
            let mut encoder = flate2::GzBuilder::new()
                .filename(util::file_name(&item.abs.to_string_lossy()))
                .write(file, flate2::Compression::default());
            copy_into(&mut reader, &mut encoder, &mut report, cancelled)?;
            encoder.finish()?;
        }
        ArchiveFormat::Bz2 => {
            let mut encoder = bzip2::write::BzEncoder::new(file, bzip2::Compression::default());
            copy_into(&mut reader, &mut encoder, &mut report, cancelled)?;
            encoder.finish()?;
        }
        ArchiveFormat::Xz => {
            let mut encoder = liblzma::write::XzEncoder::new(file, 6);
            copy_into(&mut reader, &mut encoder, &mut report, cancelled)?;
            encoder.finish()?;
        }
        ArchiveFormat::Zst => {
            let mut encoder = zstd::stream::write::Encoder::new(file, 3)
                .map_err(|e| NovaError::Invalid(format!("zstd: {e}")))?;
            copy_into(&mut reader, &mut encoder, &mut report, cancelled)?;
            encoder.finish()?;
        }
        other => {
            return Err(NovaError::Unsupported(format!(
                "{} is not a single-file format",
                other.label()
            )))
        }
    }
    Ok(report)
}

fn copy_into(
    reader: &mut impl Read,
    writer: &mut impl Write,
    report: &mut CreateReport,
    cancelled: &dyn Fn() -> bool,
) -> Result<()> {
    let mut chunk = vec![0u8; 128 * 1024];
    loop {
        if cancelled() {
            return Err(cancelled_error());
        }
        let read = reader.read(&mut chunk)?;
        if read == 0 {
            break;
        }
        writer.write_all(&chunk[..read])?;
        report.bytes += read as u64;
    }
    report.files += 1;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (tempfile::TempDir, Vec<String>) {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("src/docs")).unwrap();
        std::fs::write(dir.path().join("src/docs/a.txt"), b"alpha").unwrap();
        std::fs::write(dir.path().join("src/b.txt"), b"beta").unwrap();
        let sources = vec![dir.path().join("src").to_string_lossy().to_string()];
        (dir, sources)
    }

    #[test]
    fn packs_and_reopens_every_format() {
        let (dir, sources) = fixture();
        for (format, name) in [
            (ArchiveFormat::Zip, "out.zip"),
            (ArchiveFormat::Tar, "out.tar"),
            (ArchiveFormat::TarGz, "out.tar.gz"),
            (ArchiveFormat::TarBz2, "out.tar.bz2"),
            (ArchiveFormat::SevenZ, "out.7z"),
        ] {
            let target = dir.path().join(name).to_string_lossy().to_string();
            let report = create_archive(Some(format), &sources, &target).unwrap();
            assert_eq!(report.files, 2, "{name}");

            let archive = crate::archive::ArchiveFs::open(&target).unwrap();
            assert_eq!(archive.read_entry("src/b.txt").unwrap(), b"beta", "{name}");
            assert_eq!(
                archive.read_entry("src/docs/a.txt").unwrap(),
                b"alpha",
                "{name}"
            );
        }
    }

    #[test]
    fn append_keeps_existing_entries_for_zip_and_tar() {
        let (dir, sources) = fixture();
        for (format, name) in [
            (ArchiveFormat::Zip, "append.zip"),
            (ArchiveFormat::Tar, "append.tar"),
        ] {
            let target = dir.path().join(name).to_string_lossy().to_string();
            create_archive(Some(format), &sources, &target).unwrap();

            let extra = dir.path().join("extra.txt");
            std::fs::write(&extra, b"gamma").unwrap();
            let report = append_archive(
                format,
                &target,
                &[extra.to_string_lossy().to_string()],
            )
            .unwrap();
            assert_eq!(report.files, 1, "{name}");

            let archive = crate::archive::ArchiveFs::open(&target).unwrap();
            assert_eq!(archive.read_entry("src/b.txt").unwrap(), b"beta", "{name}");
            assert_eq!(archive.read_entry("extra.txt").unwrap(), b"gamma", "{name}");
        }
    }

    #[test]
    fn compressed_tar_cannot_be_appended_in_place() {
        let (dir, sources) = fixture();
        let target = dir.path().join("append.tar.gz").to_string_lossy().to_string();
        create_archive(Some(ArchiveFormat::TarGz), &sources, &target).unwrap();
        let extra = dir.path().join("extra.txt");
        std::fs::write(&extra, b"gamma").unwrap();
        let error = append_archive(
            ArchiveFormat::TarGz,
            &target,
            &[extra.to_string_lossy().to_string()],
        )
        .unwrap_err();
        assert!(error.to_string().contains("нельзя дополнить"));
    }

    #[test]
    fn cancelled_create_leaves_no_file_behind() {
        let (dir, sources) = fixture();
        let target = dir.path().join("cancelled.zip").to_string_lossy().to_string();
        let error = create_archive_cancellable(
            Some(ArchiveFormat::Zip),
            &sources,
            &target,
            &|| true,
        )
        .unwrap_err();
        assert!(error.to_string().contains("cancelled"));
        assert!(!std::path::Path::new(&target).exists());
        assert!(!std::path::Path::new(&format!("{target}.nova-part")).exists());
    }

    #[test]
    fn cancelled_append_keeps_the_archive_valid() {
        let (dir, sources) = fixture();
        let target = dir.path().join("append-cancel.zip").to_string_lossy().to_string();
        create_archive(Some(ArchiveFormat::Zip), &sources, &target).unwrap();

        let extra = dir.path().join("extra.txt");
        std::fs::write(&extra, b"gamma").unwrap();
        let report = append_archive_cancellable(
            ArchiveFormat::Zip,
            &target,
            &[extra.to_string_lossy().to_string()],
            &|| true,
        )
        .unwrap();
        assert!(report.cancelled);
        assert_eq!(report.files, 0);

        // The original archive is still readable and unchanged.
        let archive = crate::archive::ArchiveFs::open(&target).unwrap();
        assert_eq!(archive.read_entry("src/b.txt").unwrap(), b"beta");
        assert!(archive.read_entry("extra.txt").is_err());
    }

    #[test]
    fn single_file_format_requires_one_file() {
        let (dir, sources) = fixture();
        let target = dir.path().join("out.gz").to_string_lossy().to_string();
        assert!(create_archive(Some(ArchiveFormat::Gz), &sources, &target).is_err());

        let single = vec![dir.path().join("src/b.txt").to_string_lossy().to_string()];
        create_archive(Some(ArchiveFormat::Gz), &single, &target).unwrap();
        let archive = crate::archive::ArchiveFs::open(&target).unwrap();
        // Gzip carries the original name, so the entry is `b.txt`.
        assert_eq!(archive.read_entry("b.txt").unwrap(), b"beta");
    }
}
