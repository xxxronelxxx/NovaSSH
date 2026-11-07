//! TAR backend, plain and compressed.
//!
//! An uncompressed TAR records the byte offset of every member, so a single
//! file can be read without scanning the whole archive. Compressed TARs are
//! not seekable: their entries are addressed by ordinal and read by streaming
//! from the beginning, which is why the folder index is cached on disk.

use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};

use crate::archive::format::ArchiveFormat;
use crate::archive::index::{Locator, RawEntry};
use crate::error::{NovaError, Result};

pub fn open_reader(path: &str, format: ArchiveFormat) -> Result<Box<dyn Read>> {
    let file = BufReader::new(File::open(path)?);
    let reader: Box<dyn Read> = match format {
        ArchiveFormat::Tar => Box::new(file),
        ArchiveFormat::TarGz => Box::new(flate2::read::MultiGzDecoder::new(file)),
        ArchiveFormat::TarBz2 => Box::new(bzip2::read::BzDecoder::new(file)),
        ArchiveFormat::TarXz => Box::new(liblzma::read::XzDecoder::new_multi_decoder(file)),
        ArchiveFormat::TarZst => Box::new(
            zstd::stream::read::Decoder::new(file)
                .map_err(|e| NovaError::Invalid(format!("zstd: {e}")))?,
        ),
        other => {
            return Err(NovaError::Unsupported(format!(
                "{} is not a tar container",
                other.label()
            )))
        }
    };
    Ok(reader)
}

pub fn scan(path: &str, format: ArchiveFormat) -> Result<Vec<RawEntry>> {
    let reader = open_reader(path, format)?;
    let mut archive = tar::Archive::new(reader);
    let mut out = Vec::new();
    let mut ordinal: u32 = 0;

    let entries = archive
        .entries()
        .map_err(|e| NovaError::Invalid(format!("cannot read tar: {e}")))?;
    for item in entries {
        let entry = match item {
            Ok(entry) => entry,
            // One damaged header must not hide the rest of the archive.
            Err(_) => continue,
        };
        let header = entry.header();
        let is_dir = header.entry_type().is_dir();
        let size = header.size().unwrap_or(0);
        let modified_ms = header.mtime().ok().map(|secs| (secs as i64) * 1000);
        let mode = header.mode().ok();
        let raw_name = entry.path_bytes();
        if raw_name.is_empty() {
            continue;
        }
        let name = String::from_utf8_lossy(&raw_name).to_string();

        let locator = if format == ArchiveFormat::Tar {
            Locator::TarOffset {
                offset: entry.raw_file_position(),
                len: size,
            }
        } else if is_dir {
            // Directories are skipped by the reader, so the value is unused.
            Locator::Ordinal(u32::MAX)
        } else {
            let locator = Locator::Ordinal(ordinal);
            ordinal += 1;
            locator
        };

        out.push(RawEntry {
            path: name,
            is_dir,
            size: if is_dir { 0 } else { size },
            modified_ms,
            mode,
            locator,
        });
    }
    Ok(out)
}

pub fn with_entry<T>(
    path: &str,
    format: ArchiveFormat,
    locator: Locator,
    read: impl FnOnce(&mut dyn Read) -> Result<T>,
) -> Result<T> {
    match locator {
        Locator::TarOffset { offset, len } => {
            let mut file = File::open(path)?;
            file.seek(SeekFrom::Start(offset))?;
            let mut reader = file.take(len);
            read(&mut reader)
        }
        Locator::Ordinal(target) => {
            let reader = open_reader(path, format)?;
            let mut archive = tar::Archive::new(reader);
            let entries = archive
                .entries()
                .map_err(|e| NovaError::Invalid(format!("cannot read tar: {e}")))?;
            let mut ordinal: u32 = 0;
            for item in entries {
                let mut entry = item.map_err(|e| NovaError::Invalid(e.to_string()))?;
                if entry.header().entry_type().is_dir() {
                    continue;
                }
                if ordinal == target {
                    return read(&mut entry);
                }
                ordinal += 1;
            }
            Err(NovaError::NotFound(format!(
                "entry #{target} is missing from the archive"
            )))
        }
        _ => Err(NovaError::Invalid("not a tar entry".into())),
    }
}
