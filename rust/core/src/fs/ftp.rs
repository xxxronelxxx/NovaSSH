//! FTP transport: plain FTP and FTPS (explicit `AUTH TLS` / implicit TLS).
//!
//! `suppaftp` is a blocking client, so every call runs on a blocking thread and
//! the async signature of `Provider` is preserved. Plain and TLS sessions are
//! kept in one enum, so the rest of the app does not care which one is in use.

use std::io::Cursor;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use suppaftp::{FtpStream, ImplFtpStream, RustlsConnector, RustlsFtpStream, Status, TlsStream};

use crate::error::{NovaError, Result};
use crate::model::{DirListing, Entry, EntryKind};
use crate::util;

/// How the control connection is protected.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FtpTls {
    /// No TLS at all.
    Off,
    /// `AUTH TLS` on the plain port (usually 21).
    Explicit,
    /// TLS from the first byte (usually port 990).
    Implicit,
}

impl FtpTls {
    pub fn parse(protocol: Option<&str>, mode: Option<&str>) -> Self {
        if protocol != Some("ftps") {
            return Self::Off;
        }
        match mode {
            Some("implicit") => Self::Implicit,
            _ => Self::Explicit,
        }
    }

    pub fn is_tls(self) -> bool {
        self != Self::Off
    }
}

/// A live session, either plain or TLS-wrapped.
enum Conn {
    Plain(FtpStream),
    Secure(RustlsFtpStream),
}

/// Runs `$body` with the stream bound to `$s`, for both variants.
///
/// The body only uses `ImplFtpStream` methods, so it is type-checked twice with
/// the two different TLS backends.
macro_rules! with_conn {
    ($conn:expr, $s:ident => $body:expr) => {
        match $conn {
            Conn::Plain($s) => $body,
            Conn::Secure($s) => $body,
        }
    };
}

pub struct FtpFs {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub passive: bool,
    pub tls: FtpTls,
    /// Accepts self-signed / expired certificates (common for FTPS servers).
    pub insecure: bool,
    connection: Mutex<Option<Conn>>,
}

impl FtpFs {
    pub fn new(
        host: String,
        port: u16,
        user: String,
        password: String,
        passive: bool,
    ) -> Self {
        Self {
            host,
            port,
            user,
            password,
            passive,
            tls: FtpTls::Off,
            insecure: false,
            connection: Mutex::new(None),
        }
    }

    pub fn with_tls(mut self, tls: FtpTls, insecure: bool) -> Self {
        self.tls = tls;
        self.insecure = insecure;
        self
    }

    /// Reuses the control connection, reconnecting transparently if it dropped.
    fn with_stream<T>(&self, op: impl FnOnce(&mut Conn) -> Result<T>) -> Result<T> {
        let mut guard = self
            .connection
            .lock()
            .map_err(|_| NovaError::Sftp("ftp state poisoned".into()))?;

        if guard.is_none() {
            *guard = Some(self.open()?);
        }

        let conn = guard.as_mut().expect("connection just ensured");
        match op(conn) {
            Ok(value) => Ok(value),
            Err(e) => {
                // Drop the connection so the next call reconnects.
                *guard = None;
                Err(e)
            }
        }
    }

    /// Dial, secure if needed, log in and remember the transfer mode.
    fn open(&self) -> Result<Conn> {
        match self.tls {
            FtpTls::Off => {
                let stream: FtpStream = ImplFtpStream::connect((self.host.as_str(), self.port))
                    .map_err(|e| NovaError::Sftp(format!("ftp connect: {e}")))?;
                let stream = self.finish(stream)?;
                Ok(Conn::Plain(stream))
            }
            FtpTls::Explicit => {
                let connector = self.connector()?;
                let stream: RustlsFtpStream =
                    ImplFtpStream::connect((self.host.as_str(), self.port))
                        .map_err(|e| NovaError::Sftp(format!("ftp connect: {e}")))?;
                tune(&stream);
                let stream = stream
                    .into_secure(connector, &self.host)
                    .map_err(|e| NovaError::Sftp(format!("ftps AUTH TLS: {e}")))?;
                let stream = self.finish(stream)?;
                Ok(Conn::Secure(stream))
            }
            FtpTls::Implicit => {
                let connector = self.connector()?;
                let mut stream: RustlsFtpStream = RustlsFtpStream::connect_secure_implicit(
                    (self.host.as_str(), self.port),
                    connector,
                    &self.host,
                )
                .map_err(|e| NovaError::Sftp(format!("ftps implicit handshake: {e}")))?;
                // The implicit constructor does not negotiate the data channel,
                // so PBSZ/PROT have to be sent before any transfer.
                let _ = stream.custom_command("PBSZ 0", &[Status::CommandOk]);
                stream
                    .custom_command("PROT P", &[Status::CommandOk])
                    .map_err(|e| NovaError::Sftp(format!("ftps PROT P: {e}")))?;
                let stream = self.finish(stream)?;
                Ok(Conn::Secure(stream))
            }
        }
    }

    fn finish<T: TlsStream>(&self, mut stream: ImplFtpStream<T>) -> Result<ImplFtpStream<T>> {
        tune(&stream);
        stream
            .login(&self.user, &self.password)
            .map_err(|e| NovaError::Sftp(format!("ftp login: {e}")))?;
        // Binary mode is mandatory: ASCII mode rewrites CRLF (corrupting every
        // binary file) and most servers refuse SIZE in it, which made a plain
        // file look like a folder.
        stream
            .transfer_type(suppaftp::types::FileType::Binary)
            .map_err(|e| NovaError::Sftp(format!("ftp type i: {e}")))?;
        if !self.passive {
            stream = stream.active_mode(Duration::from_secs(10));
        }
        Ok(stream)
    }

    fn connector(&self) -> Result<RustlsConnector> {
        let config = tls_config(self.insecure).map_err(NovaError::Sftp)?;
        Ok(RustlsConnector::from(config))
    }

    /// `SITE CHMOD` is the only permission call plain FTP offers.
    pub async fn set_mode(&self, path: &str, mode: u32) -> Result<()> {
        let path = path.to_string();
        self.with_stream(|conn| {
            with_conn!(conn, stream => {
                stream
                    .custom_command(
                        format!("SITE CHMOD {mode:03o} {path}"),
                        &[Status::CommandOk, Status::RequestedFileActionOk],
                    )
                    .map(|_| ())
                    .map_err(|e| NovaError::Sftp(format!("ftp chmod: {e}")))
            })
        })
    }

    pub async fn list(&self, path: &str, show_hidden: bool) -> Result<DirListing> {
        let dir = if path.trim().is_empty() { "/".to_string() } else { path.to_string() };
        let entries = self.with_stream(|conn| {
            with_conn!(conn, stream => {
                let mut out = Vec::new();
                for line in stream
                    .list(Some(&dir))
                    .map_err(|e| NovaError::Sftp(format!("ftp list: {e}")))?
                {
                    let Some(parsed) = parse_list_line(&line) else {
                        continue;
                    };
                    let hidden = util::is_probably_hidden(&parsed.name);
                    if hidden && !show_hidden {
                        continue;
                    }
                    out.push(Entry {
                        path: util::join(&dir, &parsed.name),
                        name: parsed.name,
                        kind: if parsed.is_dir {
                            EntryKind::Dir
                        } else {
                            EntryKind::File
                        },
                        size: parsed.size,
                        modified: None,
                        mode: None,
                        uid: None,
                        gid: None,
                        hidden,
                        link_target: None,
                    });
                }
                Ok(out)
            })
        })?;

        Ok(DirListing {
            path: dir,
            parent: util::parent(path),
            entries,
            free_space: None,
            total_space: None,
        })
    }

    pub async fn stat(&self, path: &str) -> Result<Entry> {
        let path_owned = path.to_string();
        let (kind, size) = self.with_stream(|conn| {
            with_conn!(conn, stream => {
                match stream.size(&path_owned) {
                    Ok(size) => Ok((EntryKind::File, size as u64)),
                    // Servers without SIZE still accept LIST; anything that is
                    // not a file is treated as a folder.
                    Err(_) => Ok((EntryKind::Dir, 0)),
                }
            })
        })?;
        let name = util::file_name(path).to_string();
        Ok(Entry {
            name: name.clone(),
            path: path.to_string(),
            kind,
            size,
            modified: None,
            mode: None,
            uid: None,
            gid: None,
            hidden: util::is_probably_hidden(&name),
            link_target: None,
        })
    }

    pub async fn read_all(&self, path: &str) -> Result<Vec<u8>> {
        let path = path.to_string();
        self.with_stream(|conn| {
            with_conn!(conn, stream => {
                let cursor = stream
                    .retr_as_buffer(&path)
                    .map_err(|e| NovaError::Sftp(format!("ftp retr: {e}")))?;
                Ok(cursor.into_inner())
            })
        })
    }

    pub async fn write_all(&self, path: &str, data: &[u8]) -> Result<()> {
        let path = path.to_string();
        let data = data.to_vec();
        self.with_stream(|conn| {
            with_conn!(conn, stream => {
                let mut reader = Cursor::new(data);
                stream
                    .put_file(&path, &mut reader)
                    .map(|_| ())
                    .map_err(|e| NovaError::Sftp(format!("ftp stor: {e}")))
            })
        })
    }

    pub async fn mkdir(&self, path: &str) -> Result<()> {
        let path = path.to_string();
        self.with_stream(|conn| {
            with_conn!(conn, stream => {
                match stream.mkdir(&path) {
                    Ok(()) => Ok(()),
                    Err(suppaftp::FtpError::UnexpectedResponse(resp))
                        if resp.status.code() == 550 =>
                    {
                        Ok(())
                    }
                    Err(e) => Err(NovaError::Sftp(format!("ftp mkdir: {e}"))),
                }
            })
        })
    }

    pub async fn rename(&self, from: &str, to: &str) -> Result<()> {
        let (from, to) = (from.to_string(), to.to_string());
        self.with_stream(|conn| {
            with_conn!(conn, stream => {
                stream
                    .rename(&from, &to)
                    .map_err(|e| NovaError::Sftp(format!("ftp rename: {e}")))
            })
        })
    }

    pub async fn remove(&self, path: &str, is_dir: bool) -> Result<()> {
        if !is_dir {
            let path = path.to_string();
            return self.with_stream(|conn| {
                with_conn!(conn, stream => stream
                    .rm(&path)
                    .map_err(|e| NovaError::Sftp(format!("ftp delete: {e}"))))
            });
        }

        // RMDIR refuses a non-empty folder: empty it first, children before the
        // folder itself (a plain RMDIR made deleting any folder with files fail).
        let listing = self.list(path, true).await?;
        for entry in listing.entries {
            let child_is_dir = entry.kind == EntryKind::Dir;
            Box::pin(self.remove(&entry.path, child_is_dir)).await?;
        }
        let path = path.to_string();
        self.with_stream(|conn| {
            with_conn!(conn, stream => stream
                .rmdir(&path)
                .map_err(|e| NovaError::Sftp(format!("ftp rmdir: {e}"))))
        })
    }
}

/// One parsed row of a LIST reply.
#[derive(Debug, PartialEq, Eq)]
struct ListEntry {
    name: String,
    is_dir: bool,
    size: u64,
}

/// Parses a `LIST` line from the two formats servers actually send.
///
/// Unix: `-rw-r--r-- 1 owner group 1234 Jan 01 12:00 name with spaces`
/// DOS/IIS: `08-25-25  10:00AM  <DIR>  folder` / `08-25-25  10:00AM  1234 a.txt`
///
/// The name is taken as the rest of the line, so spaces inside it survive (the
/// old `split_whitespace().last()` truncated every such name).
fn parse_list_line(line: &str) -> Option<ListEntry> {
    let line = line.trim_end_matches(['\r', '\n']);
    let trimmed = line.trim_start();
    if trimmed.is_empty() || trimmed.starts_with("total ") {
        return None;
    }
    if trimmed.as_bytes()[0].is_ascii_digit() {
        parse_dos_line(trimmed)
    } else {
        parse_unix_line(trimmed)
    }
}

fn parse_unix_line(line: &str) -> Option<ListEntry> {
    let kind = line.chars().next()?;
    if !matches!(kind, '-' | 'd' | 'l' | 'b' | 'c' | 'p' | 's') {
        return None;
    }
    // Eight fixed columns, then the name verbatim.
    let mut rest = line;
    let mut fields: Vec<&str> = Vec::with_capacity(8);
    for _ in 0..8 {
        rest = rest.trim_start_matches(' ');
        if rest.is_empty() {
            return None;
        }
        let end = rest.find(' ').unwrap_or(rest.len());
        fields.push(&rest[..end]);
        rest = &rest[end..];
    }
    let name = rest.trim_start_matches(' ');
    if name.is_empty() || name == "." || name == ".." {
        return None;
    }
    let size = fields
        .get(4)
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(0);
    // A symlink is shown as "link -> target"; the link itself is the name.
    let name = match name.find(" -> ") {
        Some(index) => &name[..index],
        None => name,
    };
    Some(ListEntry {
        name: name.to_string(),
        is_dir: kind == 'd',
        size: if kind == 'd' { 0 } else { size },
    })
}

fn parse_dos_line(line: &str) -> Option<ListEntry> {
    // 08-25-25  10:00AM  <DIR>  name   /   08-25-25  10:00AM  1234 name
    let mut rest = line;
    let date_end = rest.find(char::is_whitespace)?;
    let date = &rest[..date_end];
    if !(date.contains('-') || date.contains('.')) {
        return None;
    }
    rest = rest[date_end..].trim_start();
    let time_end = rest.find(char::is_whitespace)?;
    rest = rest[time_end..].trim_start();

    if rest.len() >= 5 && rest[..5].eq_ignore_ascii_case("<DIR>") {
        let name = rest[5..].trim_start();
        if name.is_empty() || name == "." || name == ".." {
            return None;
        }
        return Some(ListEntry {
            name: name.to_string(),
            is_dir: true,
            size: 0,
        });
    }

    let size_end = rest.find(char::is_whitespace)?;
    let size = rest[..size_end].parse::<u64>().ok()?;
    let name = rest[size_end..].trim_start();
    if name.is_empty() || name == "." || name == ".." {
        return None;
    }
    Some(ListEntry {
        name: name.to_string(),
        is_dir: false,
        size,
    })
}

fn tune<T: TlsStream>(stream: &ImplFtpStream<T>) {
    let socket = stream.get_ref();
    socket.set_read_timeout(Some(Duration::from_secs(20))).ok();
    socket.set_write_timeout(Some(Duration::from_secs(20))).ok();
}

/// Builds the rustls client config: native trust store, or no verification at
/// all when the user allowed a self-signed certificate.
fn tls_config(insecure: bool) -> std::result::Result<Arc<suppaftp::rustls::ClientConfig>, String> {
    use suppaftp::rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
    use suppaftp::rustls::crypto::ring;
    use suppaftp::rustls::pki_types::{CertificateDer, ServerName, UnixTime};
    use suppaftp::rustls::{
        ClientConfig, DigitallySignedStruct, RootCertStore, SignatureScheme,
    };

    let provider = Arc::new(ring::default_provider());
    let builder = ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .map_err(|e| format!("ftps tls setup: {e}"))?;

    if insecure {
        #[derive(Debug)]
        struct AcceptAny(Arc<suppaftp::rustls::crypto::CryptoProvider>);

        impl ServerCertVerifier for AcceptAny {
            fn verify_server_cert(
                &self,
                _end_entity: &CertificateDer<'_>,
                _intermediates: &[CertificateDer<'_>],
                _server_name: &ServerName<'_>,
                _ocsp: &[u8],
                _now: UnixTime,
            ) -> std::result::Result<ServerCertVerified, suppaftp::rustls::Error> {
                Ok(ServerCertVerified::assertion())
            }

            fn verify_tls12_signature(
                &self,
                _message: &[u8],
                _cert: &CertificateDer<'_>,
                _dss: &DigitallySignedStruct,
            ) -> std::result::Result<HandshakeSignatureValid, suppaftp::rustls::Error> {
                Ok(HandshakeSignatureValid::assertion())
            }

            fn verify_tls13_signature(
                &self,
                _message: &[u8],
                _cert: &CertificateDer<'_>,
                _dss: &DigitallySignedStruct,
            ) -> std::result::Result<HandshakeSignatureValid, suppaftp::rustls::Error> {
                Ok(HandshakeSignatureValid::assertion())
            }

            fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
                self.0.signature_verification_algorithms.supported_schemes()
            }
        }

        let config = builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(AcceptAny(provider)))
            .with_no_client_auth();
        return Ok(Arc::new(config));
    }

    let mut roots = RootCertStore::empty();
    let native = rustls_native_certs::load_native_certs();
    for cert in native.certs {
        let _ = roots.add(cert);
    }
    if roots.is_empty() {
        return Err(
            "ftps: не удалось загрузить корневые сертификаты системы; включите «Принимать самоподписанный сертификат»"
                .into(),
        );
    }
    let config = builder.with_root_certificates(roots).with_no_client_auth();
    Ok(Arc::new(config))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_ftp_ignores_the_tls_mode() {
        assert_eq!(FtpTls::parse(Some("ftp"), Some("implicit")), FtpTls::Off);
        assert_eq!(FtpTls::parse(None, None), FtpTls::Off);
        assert!(!FtpTls::Off.is_tls());
    }

    #[test]
    fn ftps_defaults_to_explicit() {
        assert_eq!(FtpTls::parse(Some("ftps"), None), FtpTls::Explicit);
        assert_eq!(
            FtpTls::parse(Some("ftps"), Some("explicit")),
            FtpTls::Explicit
        );
        assert_eq!(
            FtpTls::parse(Some("ftps"), Some("implicit")),
            FtpTls::Implicit
        );
        assert!(FtpTls::Implicit.is_tls());
    }

    #[test]
    fn tls_config_accepts_self_signed_certificates() {
        // No network here: just make sure the connector can be built.
        assert!(tls_config(true).is_ok());
    }
}

#[cfg(test)]
mod list_parser_tests {
    use super::{parse_list_line, ListEntry};

    #[test]
    fn unix_lines_keep_spaces_in_names() {
        let line = "-rw-r--r--    1 owner group     1234 Jan 01 12:00 my report 2025.txt";
        assert_eq!(
            parse_list_line(line),
            Some(ListEntry {
                name: "my report 2025.txt".into(),
                is_dir: false,
                size: 1234,
            })
        );

        let dir = "drwxr-xr-x    2 owner group     4096 Jan 01 12:00 backup folder";
        assert_eq!(
            parse_list_line(dir),
            Some(ListEntry {
                name: "backup folder".into(),
                is_dir: true,
                size: 0,
            })
        );
    }

    #[test]
    fn dos_lines_are_understood() {
        assert_eq!(
            parse_list_line("08-25-25  10:00AM       <DIR>          my docs"),
            Some(ListEntry {
                name: "my docs".into(),
                is_dir: true,
                size: 0,
            })
        );
        assert_eq!(
            parse_list_line("08-25-25  10:00AM                 1234 report final.txt"),
            Some(ListEntry {
                name: "report final.txt".into(),
                is_dir: false,
                size: 1234,
            })
        );
    }

    #[test]
    fn junk_lines_and_links_are_handled() {
        assert_eq!(parse_list_line("total 12"), None);
        assert_eq!(parse_list_line(""), None);
        assert_eq!(
            parse_list_line("lrwxrwxrwx 1 u g 5 Jan 01 12:00 link -> /etc/passwd"),
            Some(ListEntry {
                name: "link".into(),
                is_dir: false,
                size: 5,
            })
        );
        assert_eq!(parse_list_line("drwxr-xr-x 2 u g 4096 Jan 01 12:00 .."), None);
    }
}
