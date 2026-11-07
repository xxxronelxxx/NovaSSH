//! Multi-volume archives: finding the parts of one set and joining them.
//!
//! Nova does not read split archives directly, but the parts are a plain byte
//! concatenation, so the user can select them all and ask for one file.

use crate::error::{NovaError, Result};
use crate::util;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VolumeSet {
    /// File name the joined archive should get (no directory).
    pub target_name: String,
    /// Parts in reading order.
    pub parts: Vec<String>,
}

/// Recognises one volume set inside `paths`. `None` when the selection is not
/// a complete, recognisable set.
pub fn detect(paths: &[String]) -> Option<VolumeSet> {
    if paths.len() < 2 {
        return None;
    }

    let mut target: Option<String> = None;
    let mut items: Vec<(u64, String)> = Vec::new();

    for path in paths {
        let name = util::file_name(path).to_lowercase();
        let (base, key) = volume_key(&name)?;
        match &target {
            None => target = Some(base),
            Some(current) if *current == base => {}
            _ => return None,
        }
        items.push((key, path.clone()));
    }

    items.sort_by_key(|(key, _)| *key);
    // Duplicate keys mean two copies of the same volume or a mixed selection.
    if items.windows(2).any(|pair| pair[0].0 == pair[1].0) {
        return None;
    }

    let parts: Vec<String> = items.into_iter().map(|(_, path)| path).collect();
    let mut target_name = target?;
    // A split ZIP includes the final `.zip` itself, so the joined copy must
    // not take its name.
    if paths
        .iter()
        .any(|path| util::file_name(path).eq_ignore_ascii_case(&target_name))
    {
        target_name = match target_name.rfind('.') {
            Some(dot) if dot > 0 => format!(
                "{}_joined{}",
                &target_name[..dot],
                &target_name[dot..]
            ),
            _ => format!("{target_name}_joined"),
        };
    }

    Some(VolumeSet {
        target_name,
        parts,
    })
}

/// `backup.7z.001` -> ("backup.7z", 1); `a.z01` -> ("a.zip", 1).
fn volume_key(name: &str) -> Option<(String, u64)> {
    if let Some((base, number)) = split_numeric(name) {
        return Some((base, number));
    }
    if let Some((base, number)) = split_suffix_number(name, ".z") {
        return Some((format!("{base}.zip"), number));
    }
    if let Some(rest) = name.strip_suffix(".zip") {
        // The trailing `.zip` of a split set comes after every `.zNN`.
        if !rest.is_empty() {
            return Some((format!("{rest}.zip"), 10_000));
        }
    }
    None
}

/// `name.ext.001` -> ("name.ext", 1). Three or more digits are required so
/// `photo.2` is not mistaken for a volume.
fn split_numeric(name: &str) -> Option<(String, u64)> {
    let dot = name.rfind('.')?;
    let digits = &name[dot + 1..];
    if digits.len() < 3 || !digits.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let number = digits.parse().ok()?;
    Some((name[..dot].to_string(), number))
}

/// `name.r00` + suffix `.r` -> ("name", 0).
fn split_suffix_number(name: &str, suffix: &str) -> Option<(String, u64)> {
    let index = name.rfind(suffix)?;
    let digits = &name[index + suffix.len()..];
    if digits.len() != 2 || !digits.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    Some((name[..index].to_string(), digits.parse().ok()?))
}

/// Joins the parts into `target` via a temporary file, so a failed run does
/// not leave a truncated archive under the real name. Returns bytes written.
pub fn assemble_local(parts: &[String], target: &str) -> Result<u64> {
    use std::io::{Read, Write};

    if parts.is_empty() {
        return Err(NovaError::Invalid("нет частей для сборки".into()));
    }
    let partial = format!("{target}.nova-part");
    let _ = std::fs::remove_file(&partial);

    let result = (|| -> Result<u64> {
        let mut out = std::fs::File::create(&partial)?;
        let mut written = 0u64;
        let mut chunk = vec![0u8; 512 * 1024];
        for part in parts {
            let mut input = std::fs::File::open(part)?;
            loop {
                let read = input.read(&mut chunk)?;
                if read == 0 {
                    break;
                }
                out.write_all(&chunk[..read])?;
                written += read as u64;
            }
        }
        out.flush()?;
        Ok(written)
    })();

    match result {
        Ok(written) => {
            let _ = std::fs::remove_file(target);
            std::fs::rename(&partial, target)?;
            Ok(written)
        }
        Err(e) => {
            let _ = std::fs::remove_file(&partial);
            Err(e)
        }
    }
}

/// Server-side equivalent of [`assemble_local`].
pub fn assemble_command(parts: &[String], target: &str) -> String {
    let partial = format!("{target}.nova-part");
    let quoted: Vec<String> = parts.iter().map(|part| util::shell_escape(part)).collect();
    format!(
        "cat {} > {partial} && mv -f {partial} {}",
        quoted.join(" "),
        util::shell_escape(target),
        partial = util::shell_escape(&partial),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|p| p.to_string()).collect()
    }

    #[test]
    fn numeric_split_is_sorted_numerically() {
        let set = detect(&names(&["/a/x.7z.010", "/a/x.7z.002", "/a/x.7z.001"])).unwrap();
        assert_eq!(set.target_name, "x.7z");
        assert_eq!(set.parts, names(&["/a/x.7z.001", "/a/x.7z.002", "/a/x.7z.010"]));
    }

    #[test]
    fn split_zip_puts_the_zip_last() {
        let set = detect(&names(&["/a/x.zip", "/a/x.z02", "/a/x.z01"])).unwrap();
        assert_eq!(set.target_name, "x_joined.zip");
        assert_eq!(set.parts, names(&["/a/x.z01", "/a/x.z02", "/a/x.zip"]));
    }

    #[test]
    fn unrelated_files_are_rejected() {
        assert!(detect(&names(&["/a/x.zip", "/a/y.7z"])).is_none());
        assert!(detect(&names(&["/a/x.7z.001"])).is_none());
        assert!(detect(&names(&["/a/photo.jpg", "/a/notes.txt"])).is_none());
    }

    #[test]
    fn assembly_concatenates_in_order() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("x.7z.001");
        let b = dir.path().join("x.7z.002");
        std::fs::write(&a, b"hello ").unwrap();
        std::fs::write(&b, b"world").unwrap();
        let target = dir.path().join("x.7z");
        let written = assemble_local(&names(&[&a.to_string_lossy(), &b.to_string_lossy()]), &target.to_string_lossy()).unwrap();
        assert_eq!(written, 11);
        assert_eq!(std::fs::read(&target).unwrap(), b"hello world");
    }
}
