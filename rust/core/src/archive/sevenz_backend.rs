//! 7z backend.
//!
//! Listing comes from the archive header, so opening a big `.7z` is cheap.
//! Reading one file still decodes the solid block it lives in — that is how 7z
//! works — but the index is cached, so only browsing repeats no work.

use std::io::{Cursor, Read};

use sevenz_rust2::{Password, SevenZReader};

use crate::archive::index::{Locator, RawEntry};
use crate::error::{NovaError, Result};

fn open(path: &str, password: Option<&str>) -> Result<SevenZReader<std::fs::File>> {
    let password = match password {
        Some(password) => Password::from(password),
        None => Password::empty(),
    };
    SevenZReader::open(path, password)
        .map_err(|e| NovaError::Invalid(format!("cannot read 7z: {e}")))
}

pub fn scan(path: &str, password: Option<&str>) -> Result<Vec<RawEntry>> {
    let reader = open(path, password)?;
    let archive = reader.archive();
    let mut out = Vec::with_capacity(archive.files.len());
    for file in &archive.files {
        if file.name.is_empty() || file.is_anti_item {
            continue;
        }
        let modified_ms = if file.has_last_modified_date {
            // FileTime counts 100 ns ticks since 1601-01-01.
            let unix_ms = (file.last_modified_date.to_raw() / 10_000) as i64 - 11_644_473_600_000;
            Some(unix_ms)
        } else {
            None
        };
        out.push(RawEntry {
            path: file.name.replace('\\', "/"),
            is_dir: file.is_directory,
            size: if file.is_directory { 0 } else { file.size },
            modified_ms,
            mode: None,
            locator: Locator::SevenZ,
        });
    }
    Ok(out)
}

pub fn with_entry<T>(
    path: &str,
    name: &str,
    password: Option<&str>,
    read: impl FnOnce(&mut dyn Read) -> Result<T>,
) -> Result<T> {
    // 7z stores names with either separator depending on the packer, so match
    // on the normalised path instead of the raw header string.
    let target = crate::archive::index::normalize_path(name);
    let mut reader = open(path, password)?;
    let mut data: Option<Vec<u8>> = None;
    reader
        .for_each_entries(|entry, source| {
            if crate::archive::index::normalize_path(&entry.name) != target {
                return Ok(true);
            }
            let mut buffer = Vec::with_capacity(entry.size as usize);
            source
                .read_to_end(&mut buffer)
                .map_err(sevenz_rust2::Error::io)?;
            data = Some(buffer);
            Ok(false)
        })
        .map_err(|e| NovaError::Invalid(format!("cannot read {name}: {e}")))?;
    let bytes = data.ok_or_else(|| NovaError::NotFound(name.to_string()))?;
    read(&mut Cursor::new(bytes))
}
