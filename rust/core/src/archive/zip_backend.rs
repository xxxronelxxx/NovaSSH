//! ZIP backend: the central directory gives random access, so entries are
//! addressed by their index and a listing never decompresses anything.

use std::fs::File;
use std::io::Read;

use crate::archive::index::{Locator, RawEntry};
use crate::error::{NovaError, Result};

pub fn scan(path: &str, password: Option<&str>) -> Result<Vec<RawEntry>> {
    let file = File::open(path)?;
    let mut zip = zip::ZipArchive::new(file)
        .map_err(|e| NovaError::Invalid(format!("cannot read archive: {e}")))?;

    let mut out = Vec::with_capacity(zip.len());
    for i in 0..zip.len() {
        // AES entries cannot even be opened without the password, so the
        // central-directory scan needs it too.
        let entry = match password {
            Some(password) => zip.by_index_decrypt(i, password.as_bytes()),
            None => zip.by_index(i),
        }
        .map_err(|e| NovaError::Invalid(format!("bad entry {i}: {e}")))?;
        // A legacy CP437 name that is not valid UTF-8 must not abort the
        // whole listing: fall back to a lossy decode of the raw bytes.
        let raw_name = match entry.name() {
            Ok(name) => name.to_string(),
            Err(_) => String::from_utf8_lossy(entry.name_raw()).to_string(),
        };
        let is_dir = entry.is_dir() || raw_name.ends_with('/');
        if raw_name.is_empty() {
            continue;
        }
        out.push(RawEntry {
            path: raw_name,
            is_dir,
            size: if is_dir { 0 } else { entry.size() },
            modified_ms: entry.last_modified().and_then(datetime_to_ms),
            mode: entry.unix_mode(),
            locator: Locator::Zip(i as u32),
        });
    }
    Ok(out)
}

pub fn with_entry<T>(
    path: &str,
    locator: Locator,
    password: Option<&str>,
    read: impl FnOnce(&mut dyn Read) -> Result<T>,
) -> Result<T> {
    let Locator::Zip(index) = locator else {
        return Err(NovaError::Invalid("not a zip entry".into()));
    };
    let file = File::open(path)?;
    let mut zip = zip::ZipArchive::new(file)
        .map_err(|e| NovaError::Invalid(format!("cannot read archive: {e}")))?;
    let mut entry = match password {
        Some(password) => zip.by_index_decrypt(index as usize, password.as_bytes()),
        None => zip.by_index(index as usize),
    }
    .map_err(|e| NovaError::Invalid(format!("bad entry {index}: {e}")))?;
    read(&mut entry)
}

fn datetime_to_ms(dt: zip::DateTime) -> Option<i64> {
    // zip exposes components without a timezone; treat it as UTC for stability.
    let year = dt.year();
    if !(1970..=3000).contains(&year) {
        return None;
    }
    let days = days_from_civil(year as i64, dt.month() as u32, dt.day() as u32);
    let secs = days * 86_400
        + dt.hour() as i64 * 3600
        + dt.minute() as i64 * 60
        + dt.second() as i64;
    Some((secs * 1000).max(0))
}

/// Howard Hinnant's days-from-civil algorithm.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}
