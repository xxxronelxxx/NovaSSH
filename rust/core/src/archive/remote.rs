//! Packing and unpacking archives **on the server**.
//!
//! Pulling a 5 GB tarball through SFTP just to unpack it doubles the traffic,
//! so Nova runs the server's own `tar`/`zip`/`7z` instead. The commands are
//! built here (and unit-tested without a server); the API layer executes them
//! over an SSH exec channel.

use crate::archive::format::ArchiveFormat;
use crate::error::{NovaError, Result};
use crate::util;

/// POSIX shell quoting: `it's` -> `'it'\''s'`.
pub fn quote(value: &str) -> String {
    util::shell_escape(value)
}

/// Longest common parent directory of the given absolute paths.
pub fn common_parent(paths: &[String]) -> String {
    let parts: Vec<Vec<&str>> = paths
        .iter()
        .map(|path| path.trim_matches('/').split('/').collect())
        .collect();
    let Some(first) = parts.first() else {
        return "/".to_string();
    };
    let mut shared = 0usize;
    for (index, part) in first.iter().enumerate().take(first.len().saturating_sub(1)) {
        if parts[1..].iter().all(|other| other.get(index) == Some(part)) {
            shared = index + 1;
        } else {
            break;
        }
    }
    if shared == 0 {
        "/".to_string()
    } else {
        format!("/{}", first[..shared].join("/"))
    }
}

/// Relative path of `path` below `parent`, prefixed with `./` so a name that
/// starts with `-` is never parsed as an option.
fn relative_to(parent: &str, path: &str) -> String {
    let path = path.trim_end_matches('/');
    let rest = if parent == "/" {
        path.trim_start_matches('/')
    } else {
        path.strip_prefix(parent)
            .unwrap_or(path)
            .trim_start_matches('/')
    };
    if rest.is_empty() {
        ".".to_string()
    } else {
        format!("./{rest}")
    }
}

/// Everything the server needs to create one archive.
pub struct PackPlan {
    /// Directory the tool must run in (the common parent of the sources).
    pub parent: String,
    /// Temporary file next to the target; renamed on success.
    pub partial: String,
    /// Tool invocation writing into `partial`; expects cwd = `parent`.
    pub tool: String,
}

/// Builds the tool command that writes `target` from `sources`.
pub fn pack_plan(
    format: ArchiveFormat,
    sources: &[String],
    target: &str,
) -> Result<PackPlan> {
    if sources.is_empty() {
        return Err(NovaError::Invalid("Нечего упаковывать".into()));
    }
    if format.is_single() && sources.len() != 1 {
        return Err(NovaError::Invalid(format!(
            "{} сжимает ровно один файл",
            format.label()
        )));
    }

    let parent = common_parent(sources);
    let mut names: Vec<String> = sources
        .iter()
        .map(|source| relative_to(&parent, source))
        .collect();
    names.dedup();

    // Tools write next to the target and the file is renamed at the end: a
    // failed run never leaves a truncated archive under the real name, and
    // `zip` cannot pick up the archive it is writing.
    let partial = format!("{target}.nova-part");
    let quoted_partial = quote(&partial);
    let quoted_names = names
        .iter()
        .map(|name| quote(name))
        .collect::<Vec<_>>()
        .join(" ");

    let tool = match format {
        ArchiveFormat::Zip => format!("zip -r -q {quoted_partial} {quoted_names}"),
        ArchiveFormat::SevenZ => format!("7z a -bd -y {quoted_partial} {quoted_names}"),
        ArchiveFormat::Tar
        | ArchiveFormat::TarGz
        | ArchiveFormat::TarBz2
        | ArchiveFormat::TarXz
        | ArchiveFormat::TarZst => format!(
            "tar {flags} {quoted_partial} {quoted_names}",
            flags = tar_create_flags(format),
        ),
        ArchiveFormat::Gz | ArchiveFormat::Bz2 | ArchiveFormat::Xz | ArchiveFormat::Zst => {
            let compressor = match format {
                ArchiveFormat::Gz => "gzip",
                ArchiveFormat::Bz2 => "bzip2",
                ArchiveFormat::Xz => "xz",
                _ => "zstd",
            };
            format!(
                "{compressor} -c {source} > {quoted_partial}",
                source = quote(&names[0]),
            )
        }
    };

    Ok(PackPlan {
        parent,
        partial,
        tool,
    })
}

/// One-shot command used by tests and the synchronous path.
pub fn pack_command(
    format: ArchiveFormat,
    sources: &[String],
    target: &str,
) -> Result<String> {
    let plan = pack_plan(format, sources, target)?;
    let target_parent = quote(&util::parent(target).unwrap_or_else(|| "/".into()));
    Ok(format!(
        "mkdir -p {target_parent} && cd {parent} && {tool} && mv -f {partial} {target}",
        parent = quote(&plan.parent),
        tool = plan.tool,
        partial = quote(&plan.partial),
        target = quote(target),
    ))
}

/// Command that extracts `archive` into `target_dir`. `inner` limits the
/// extraction to one member (or one folder) inside the archive.
pub fn extract_command(
    format: ArchiveFormat,
    archive: &str,
    inner: &str,
    target_dir: &str,
    password: Option<&str>,
) -> Result<String> {
    Ok(format!(
        "mkdir -p {dir} && {tool} </dev/null",
        dir = quote(target_dir),
        tool = extract_tool_command(format, archive, inner, target_dir, password)?,
    ))
}

/// The tool invocation alone (no `mkdir`). The server-archive flow needs it
/// to start it with `exec` after recording the shell PID, so Cancel can kill
/// exactly that process.
pub fn extract_tool_command(
    format: ArchiveFormat,
    archive: &str,
    inner: &str,
    target_dir: &str,
    password: Option<&str>,
) -> Result<String> {
    let inner = inner.trim_matches('/');
    let quoted_archive = quote(archive);
    let quoted_dir = quote(target_dir);
    let member = if inner.is_empty() {
        String::new()
    } else {
        format!(" {}", quote(inner))
    };
    // `-P` / `-p` only when a password is known; encrypted tools must never
    // wait on stdin, so callers add `</dev/null`.
    let zip_password = password
        .map(|password| format!(" -P {}", quote(password)))
        .unwrap_or_default();
    let sevenz_password = password
        .map(|password| format!(" -p{}", quote(password)))
        .unwrap_or_default();

    let command = match format {
        ArchiveFormat::Zip => format!(
            "unzip -o -q{zip_password} {quoted_archive} -d {quoted_dir}{member}"
        ),
        ArchiveFormat::SevenZ => format!(
            "7z x -bd -y{sevenz_password} {quoted_archive} -o{quoted_dir}{member}"
        ),
        ArchiveFormat::Tar
        | ArchiveFormat::TarGz
        | ArchiveFormat::TarBz2
        | ArchiveFormat::TarXz
        | ArchiveFormat::TarZst => format!(
            "tar {flags} {quoted_archive} -C {quoted_dir}{member}",
            flags = tar_extract_flags(format),
        ),
        single => {
            let name = ArchiveFormat::stem(archive);
            let tool = match single {
                ArchiveFormat::Gz => "gzip",
                ArchiveFormat::Bz2 => "bzip2",
                ArchiveFormat::Xz => "xz",
                _ => "zstd",
            };
            let out = quote(&format!(
                "{}/{}",
                target_dir.trim_end_matches('/'),
                if name.is_empty() { "file" } else { &name }
            ));
            format!("{tool} -dc {quoted_archive} > {out}")
        }
    };
    Ok(command)
}

fn tar_create_flags(format: ArchiveFormat) -> &'static str {
    match format {
        ArchiveFormat::Tar => "-cf",
        ArchiveFormat::TarGz => "-czf",
        ArchiveFormat::TarBz2 => "-cjf",
        ArchiveFormat::TarXz => "-cJf",
        ArchiveFormat::TarZst => "--zstd -cf",
        _ => "-cf",
    }
}

fn tar_extract_flags(format: ArchiveFormat) -> &'static str {
    match format {
        ArchiveFormat::Tar => "-xf",
        ArchiveFormat::TarGz => "-xzf",
        ArchiveFormat::TarBz2 => "-xjf",
        ArchiveFormat::TarXz => "-xJf",
        ArchiveFormat::TarZst => "--zstd -xf",
        _ => "-xf",
    }
}

/// Trims a tool's output to something that fits in a toast.
pub fn short_error(stdout: &str, stderr: &str) -> String {
    let text = if stderr.trim().is_empty() {
        stdout.trim()
    } else {
        stderr.trim()
    };
    let text = if text.is_empty() {
        "команда завершилась с ошибкой"
    } else {
        text
    };
    let mut chars = text.chars();
    let short: String = chars.by_ref().take(400).collect();
    if chars.next().is_some() {
        format!("{short}…")
    } else {
        short
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_shell_metacharacters() {
        assert_eq!(quote("plain"), "'plain'");
        assert_eq!(quote("it's"), "'it'\\''s'");
        assert_eq!(quote("a b; rm -rf /"), "'a b; rm -rf /'");
    }

    #[test]
    fn common_parent_stops_at_the_shared_folder() {
        assert_eq!(
            common_parent(&["/var/www/a".into(), "/var/www/b".into()]),
            "/var/www"
        );
        assert_eq!(
            common_parent(&["/var/www/a".into(), "/etc/passwd".into()]),
            "/"
        );
        assert_eq!(common_parent(&["/srv/app".into()]), "/srv");
    }

    #[test]
    fn tar_pack_runs_inside_the_shared_parent() {
        let command = pack_command(
            ArchiveFormat::TarGz,
            &["/var/www/a".into(), "/var/www/b c".into()],
            "/var/www/backup.tar.gz",
        )
        .unwrap();
        assert!(command.contains("cd '/var/www'"), "{command}");
        assert!(
            command.contains("tar -czf '/var/www/backup.tar.gz.nova-part'"),
            "{command}"
        );
        assert!(
            command.contains("mv -f '/var/www/backup.tar.gz.nova-part' '/var/www/backup.tar.gz'"),
            "{command}"
        );
        assert!(command.contains("'./a'"), "{command}");
        assert!(command.contains("'./b c'"), "{command}");
    }

    #[test]
    fn extraction_creates_the_target_and_limits_members() {
        let command = extract_command(
            ArchiveFormat::Zip,
            "/srv/a.zip",
            "docs/readme.txt",
            "/srv/out",
            None,
        )
        .unwrap();
        assert!(command.contains("mkdir -p '/srv/out'"), "{command}");
        assert!(command.contains("unzip -o -q '/srv/a.zip' -d '/srv/out'"),
            "{command}");
        assert!(command.contains("'docs/readme.txt'"), "{command}");
    }

    #[test]
    fn single_file_extraction_writes_one_file() {
        let command =
            extract_command(ArchiveFormat::Gz, "/srv/notes.txt.gz", "", "/srv/out", None)
                .unwrap();
        assert!(command.contains("gzip -dc '/srv/notes.txt.gz' > '/srv/out/notes.txt'"),
            "{command}");
    }

    #[test]
    fn single_file_pack_refuses_many_sources() {
        let error = pack_command(
            ArchiveFormat::Gz,
            &["/a".into(), "/b".into()],
            "/c.gz",
        )
        .unwrap_err();
        assert!(error.to_string().contains("ровно один"));
    }
}
