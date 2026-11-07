//! Single-file compressors: `.gz`, `.bz2`, `.xz`, `.zst`.
//!
//! Such a file is not a container, so it is presented as an archive with one
//! entry named after the file itself. Gzip stores the uncompressed size in its
//! footer; the other formats do not, so their size stays unknown until read.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

use crate::archive::format::ArchiveFormat;
use crate::archive::index::{Locator, RawEntry};
use crate::error::{NovaError, Result};

pub fn scan(path: &str, format: ArchiveFormat) -> Result<Vec<RawEntry>> {
    let size = if format == ArchiveFormat::Gz {
        gzip_isize(path).unwrap_or(0)
    } else {
        0
    };
    // gzip stores the original file name; the other compressors do not, so
    // their entry is named after the archive itself.
    let name = if format == ArchiveFormat::Gz {
        gzip_name(path).unwrap_or_else(|| ArchiveFormat::single_entry_name(path))
    } else {
        ArchiveFormat::single_entry_name(path)
    };
    Ok(vec![RawEntry {
        path: name,
        is_dir: false,
        size,
        modified_ms: None,
        locator: Locator::Single,
    }])
}

pub fn open_reader(path: &str, format: ArchiveFormat) -> Result<Box<dyn Read>> {
    let file = File::open(path)?;
    let reader: Box<dyn Read> = match format {
        ArchiveFormat::Gz => Box::new(flate2::read::MultiGzDecoder::new(file)),
        ArchiveFormat::Bz2 => Box::new(bzip2::read::BzDecoder::new(file)),
        ArchiveFormat::Xz => Box::new(liblzma::read::XzDecoder::new_multi_decoder(file)),
        ArchiveFormat::Zst => Box::new(
            zstd::stream::read::Decoder::new(file)
                .map_err(|e| NovaError::Invalid(format!("zstd: {e}")))?,
        ),
        other => {
            return Err(NovaError::Unsupported(format!(
                "{} is not a single-file compressor",
                other.label()
            )))
        }
    };
    Ok(reader)
}

/// The last four bytes of a gzip member are the uncompressed size modulo 2^32.
fn gzip_isize(path: &str) -> Option<u64> {
    let mut file = File::open(path).ok()?;
    let len = file.seek(SeekFrom::End(0)).ok()?;
    if len < 4 {
        return None;
    }
    file.seek(SeekFrom::End(-4)).ok()?;
    let mut tail = [0u8; 4];
    file.read_exact(&mut tail).ok()?;
    Some(u32::from_le_bytes(tail) as u64)
}

/// Reads the optional original name from the gzip header (FLG bit 3). The
/// name is untrusted input, so path separators are stripped.
fn gzip_name(path: &str) -> Option<String> {
    let mut head = [0u8; 10];
    let mut file = File::open(path).ok()?;
    file.read_exact(&mut head).ok()?;
    if head[0] != 0x1f || head[1] != 0x8b || head[3] & 0x08 == 0 {
        return None;
    }
    let mut name = Vec::new();
    let mut byte = [0u8; 1];
    // A cap keeps a corrupt header from scanning the whole file.
    for _ in 0..1024 {
        if file.read(&mut byte).ok()? == 0 {
            break;
        }
        if byte[0] == 0 {
            break;
        }
        name.push(byte[0]);
    }
    let name = String::from_utf8_lossy(&name).to_string();
    let clean = name.rsplit(['/', '\\']).next().unwrap_or(&name).to_string();
    if clean.is_empty() {
        None
    } else {
        Some(clean)
    }
}
