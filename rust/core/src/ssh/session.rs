use std::sync::{Arc, Mutex};
use std::time::Duration;

use russh::client::AuthResult;
use russh::client::{self, Handle};
use russh::keys::{HashAlg, PrivateKey, PrivateKeyWithHashAlg, PublicKeyOrCertificate};
use russh::{ChannelMsg, Disconnect};
use russh_sftp::client::SftpSession;

use crate::error::{NovaError, Result};
use crate::fs::sftp::SftpFs;

#[derive(Debug, Clone)]
pub enum ConnectAuth {
    Password(String),
    Key {
        path: String,
        passphrase: Option<String>,
    },
}

#[derive(Debug, Clone)]
pub struct ConnectOptions {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub auth: ConnectAuth,
    /// TOFU: when set, a different host key aborts the connection.
    pub expected_fingerprint: Option<String>,
    pub timeout: Duration,
    pub keepalive: Duration,
}

impl Default for ConnectOptions {
    fn default() -> Self {
        Self {
            host: String::new(),
            port: 22,
            user: String::new(),
            auth: ConnectAuth::Password(String::new()),
            expected_fingerprint: None,
            timeout: Duration::from_secs(20),
            keepalive: Duration::from_secs(30),
        }
    }
}

/// Trust-on-first-use handler. Records the fingerprint it saw so the UI can
/// persist it after a successful connection.
pub struct ClientHandler {
    expected: Option<String>,
    seen: Arc<Mutex<Option<String>>>,
}

impl ClientHandler {
    fn new(expected: Option<String>) -> Self {
        Self {
            expected,
            seen: Arc::new(Mutex::new(None)),
        }
    }
}

fn fingerprint(key: &PublicKeyOrCertificate) -> String {
    match key {
        PublicKeyOrCertificate::PublicKey { key, .. } => {
            key.fingerprint(HashAlg::Sha256).to_string()
        }
        PublicKeyOrCertificate::Certificate(cert) => {
            cert.public_key().fingerprint(HashAlg::Sha256).to_string()
        }
    }
}

impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let fp = fingerprint(server_public_key);
        if let Ok(mut guard) = self.seen.lock() {
            *guard = Some(fp.clone());
        }
        match &self.expected {
            Some(expected) => Ok(expected == &fp),
            None => Ok(true),
        }
    }
}

pub struct SshSession {
    pub handle: Handle<ClientHandler>,
    pub sftp: Arc<SftpSession>,
    pub fingerprint: Option<String>,
}

impl SshSession {
    pub fn fs(&self, session_id: impl Into<String>) -> SftpFs {
        SftpFs::new(session_id, self.sftp.clone())
    }

    pub async fn close(&self) -> Result<()> {
        self.handle
            .disconnect(Disconnect::ByApplication, "", "en")
            .await
            .map_err(|e| NovaError::Ssh(e.to_string()))
    }

    /// Run a command and return stdout, with a hard timeout.
    ///
    /// A server that accepts the exec request but never replies (or a hung
    /// command) must not block the UI, so the wait loop is bounded.
    pub async fn exec(&self, command: &str) -> Result<String> {
        self.exec_with_timeout(command, Duration::from_secs(20))
            .await
    }

    pub async fn exec_with_timeout(&self, command: &str, timeout: Duration) -> Result<String> {
        self.exec_result(command, timeout)
            .await
            .map(|(stdout, _, _)| stdout)
    }

    /// Run a command and keep stdout, stderr and the exit code.
    ///
    /// Archive tools signal failures through the exit status, so callers that
    /// must not silently succeed need the whole picture.
    pub async fn exec_result(
        &self,
        command: &str,
        timeout: Duration,
    ) -> Result<(String, String, i32)> {
        let run = async {
            let mut channel = self.handle.channel_open_session().await?;
            channel
                .exec(true, command)
                .await
                .map_err(|e| NovaError::Ssh(e.to_string()))?;
            let mut out = Vec::new();
            let mut err = Vec::new();
            let mut code = -1;
            while let Some(msg) = channel.wait().await {
                match msg {
                    ChannelMsg::Data { data } => out.extend_from_slice(&data),
                    ChannelMsg::ExtendedData { data, ext } => {
                        // ext 1 is stderr; anything else is worth keeping too.
                        let _ = ext;
                        err.extend_from_slice(&data);
                    }
                    ChannelMsg::ExitStatus { exit_status } => code = exit_status as i32,
                    ChannelMsg::Eof | ChannelMsg::Close => break,
                    _ => {}
                }
            }
            Ok::<(String, String, i32), NovaError>((
                String::from_utf8_lossy(&out).to_string(),
                String::from_utf8_lossy(&err).to_string(),
                code,
            ))
        };

        match tokio::time::timeout(timeout, run).await {
            Ok(result) => result,
            Err(_) => Err(NovaError::Ssh(format!(
                "command timed out after {}s",
                timeout.as_secs()
            ))),
        }
    }
}

fn load_private_key(path: &str, passphrase: Option<&str>) -> Result<PrivateKey> {
    let expanded = if let Some(rest) = path.strip_prefix("~/") {
        dirs::home_dir()
            .map(|h| h.join(rest).to_string_lossy().to_string())
            .unwrap_or_else(|| path.to_string())
    } else {
        path.to_string()
    };
    let raw = std::fs::read(&expanded)
        .map_err(|e| NovaError::Invalid(format!("cannot read key {expanded}: {e}")))?;
    let pass = passphrase
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(str::as_bytes);

    // PuTTY .ppk (v2/v3), OpenSSH and PEM keys are all accepted here, with a
    // passphrase for encrypted files. `to_openssh` gives russh what it expects.
    let key_file = justssh_keys::KeyFile::read(&raw, pass).map_err(|e| {
        use justssh_keys::KeyFileError;
        match e {
            KeyFileError::PassphraseNeeded => NovaError::Invalid(format!(
                "ключ {expanded} зашифрован — укажите парольную фразу в свойствах сервера"
            )),
            KeyFileError::WrongPassphrase => NovaError::Invalid(format!(
                "неверная парольная фраза для ключа {expanded}"
            )),
            KeyFileError::UnsupportedKeyType(kind) => {
                NovaError::Unsupported(format!("тип ключа {kind} не поддерживается"))
            }
            other => {
                NovaError::Invalid(format!("cannot parse key {expanded}: {other}"))
            }
        }
    })?;
    let openssh = key_file.to_openssh();
    PrivateKey::from_openssh(openssh.as_bytes())
        .map_err(|e| NovaError::Invalid(format!("cannot parse key {expanded}: {e}")))
}

pub async fn connect(opts: &ConnectOptions) -> Result<SshSession> {
    if opts.host.trim().is_empty() {
        return Err(NovaError::Invalid("host is empty".into()));
    }

    let config = Arc::new(client::Config {
        keepalive_interval: Some(opts.keepalive),
        nodelay: true,
        ..Default::default()
    });

    crate::util::set_connect_stage(2);
    let handler = ClientHandler::new(opts.expected_fingerprint.clone());
    let seen = handler.seen.clone();
    let connect_fut = client::connect(config, (opts.host.as_str(), opts.port), handler);

    let mut handle = match tokio::time::timeout(opts.timeout, connect_fut).await {
        Err(_) => {
            return Err(NovaError::Ssh(format!(
                "connection to {}:{} timed out",
                opts.host, opts.port
            )))
        }
        Ok(Err(e)) => {
            let actual = seen.lock().ok().and_then(|g| g.clone());
            let message = match e {
                russh::Error::UnknownKey => match (&opts.expected_fingerprint, actual) {
                    (Some(expected), Some(actual)) => format!(
                        "host key changed for {}:{}: expected {expected}, server offered {actual}.                          Update the saved fingerprint for this server if the change is legitimate.",
                        opts.host, opts.port
                    ),
                    _ => format!(
                        "host key for {}:{} was rejected",
                        opts.host, opts.port
                    ),
                },
                other => other.to_string(),
            };
            return Err(NovaError::Ssh(message));
        }
        Ok(Ok(h)) => h,
    };

    crate::util::set_connect_stage(3);
    let result = match &opts.auth {
        ConnectAuth::Password(password) => handle
            .authenticate_password(opts.user.clone(), password.clone())
            .await
            .map_err(|e| NovaError::Ssh(e.to_string()))?,
        ConnectAuth::Key { path, passphrase } => {
            let key = load_private_key(path, passphrase.as_deref())?;
            let hash = handle
                .best_supported_rsa_hash()
                .await
                .map_err(|e| NovaError::Ssh(e.to_string()))?
                .flatten();
            handle
                .authenticate_publickey(
                    opts.user.clone(),
                    PrivateKeyWithHashAlg::new(Arc::new(key), hash),
                )
                .await
                .map_err(|e| NovaError::Ssh(e.to_string()))?
        }
    };

    match result {
        AuthResult::Success => {}
        AuthResult::Failure {
            remaining_methods, ..
        } => {
            return Err(NovaError::Ssh(format!(
                "authentication failed (server allows: {remaining_methods:?})"
            )))
        }
    }

    crate::util::set_connect_stage(4);
    let channel = handle
        .channel_open_session()
        .await
        .map_err(|e| NovaError::Ssh(e.to_string()))?;
    channel
        .request_subsystem(true, "sftp")
        .await
        .map_err(|e| NovaError::Ssh(e.to_string()))?;
    let sftp = SftpSession::new(channel.into_stream())
        .await
        .map_err(|e| NovaError::Sftp(e.to_string()))?;

    // The handler lives inside the connection task, so the fingerprint is read
    // from the shared cell and handed back to the caller to persist.
    let fingerprint = seen.lock().ok().and_then(|g| g.clone());
    Ok(SshSession {
        handle,
        sftp: Arc::new(sftp),
        fingerprint,
    })
}

impl SshSession {
    /// Ask the server which archive tools are available. Cached by the caller.
    pub async fn detect_archive_tools(&self) -> Result<Vec<String>> {
        const TOOLS: [&str; 8] = ["tar", "gzip", "bzip2", "xz", "zstd", "zip", "unzip", "7z"];
        let cmd = TOOLS
            .iter()
            .map(|t| format!("command -v {t} >/dev/null 2>&1 && echo {t}"))
            .collect::<Vec<_>>()
            .join("; ");
        // Tool detection must never stall the connect flow.
        let out = self.exec_with_timeout(&cmd, Duration::from_secs(8)).await?;
        Ok(out
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_default_is_sane() {
        let o = ConnectOptions::default();
        assert_eq!(o.port, 22);
        assert_eq!(o.timeout, Duration::from_secs(20));
    }

    #[test]
    fn missing_key_file_is_reported() {
        let err = load_private_key("C:/definitely/not/here/id_ed25519", None).unwrap_err();
        assert!(err.to_string().contains("cannot read key"));
    }
}

// ---------------------------------------------------------------------------
// Interactive shell (built-in terminal)
// ---------------------------------------------------------------------------

enum ShellCmd {
    Data(String),
    Resize(u32, u32),
}

pub struct ShellSession {
    tx: tokio::sync::mpsc::UnboundedSender<ShellCmd>,
    buffer: Arc<Mutex<String>>,
}

static SHELLS: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, ShellSession>>> =
    std::sync::OnceLock::new();

fn shells() -> &'static std::sync::Mutex<std::collections::HashMap<String, ShellSession>> {
    SHELLS.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

impl SshSession {
    /// Opens an interactive PTY shell; a task owns the channel and the UI reads
    /// the accumulated output through [`shell_poll`].
    pub async fn open_shell(&self, id: &str, cols: u32, rows: u32) -> Result<String> {
        let mut channel = self
            .handle
            .channel_open_session()
            .await
            .map_err(|e| NovaError::Ssh(e.to_string()))?;

        channel
            .request_pty(false, "xterm-256color", cols, rows, 0, 0, &[])
            .await
            .map_err(|e| NovaError::Ssh(e.to_string()))?;
        channel
            .request_shell(true)
            .await
            .map_err(|e| NovaError::Ssh(e.to_string()))?;

        let buffer = Arc::new(Mutex::new(String::new()));
        let sink = buffer.clone();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<ShellCmd>();

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    msg = channel.wait() => {
                        match msg {
                            Some(ChannelMsg::Data { data }) => {
                                if let Ok(mut guard) = sink.lock() {
                                    guard.push_str(&String::from_utf8_lossy(&data));
                                    if guard.len() > 200_000 {
                                        let keep = guard.len() - 100_000;
                                        *guard = guard[keep..].to_string();
                                    }
                                }
                            }
                            Some(ChannelMsg::Eof) | Some(ChannelMsg::Close) | None => {
                                if let Ok(mut guard) = sink.lock() {
                                    guard.push_str("[session closed]\r\n");
                                }
                                break;
                            }
                            _ => {}
                        }
                    }
                    cmd = rx.recv() => {
                        match cmd {
                            Some(ShellCmd::Data(text)) => {
                                let _ = channel.data(text.as_bytes()).await;
                            }
                            Some(ShellCmd::Resize(c, r)) => {
                                let _ = channel.window_change(c, r, 0, 0).await;
                            }
                            None => break,
                        }
                    }
                }
            }
        });

        shells()
            .lock()
            .map_err(|_| NovaError::Ssh("shell registry poisoned".into()))?
            .insert(id.to_string(), ShellSession { tx, buffer });
        Ok(id.to_string())
    }

    pub async fn shell_write(&self, id: &str, data: &str) -> Result<()> {
        let guard = shells().lock().map_err(|_| NovaError::Ssh("poisoned".into()))?;
        let shell = guard
            .get(id)
            .ok_or_else(|| NovaError::NotFound("shell".into()))?;
        shell
            .tx
            .send(ShellCmd::Data(data.to_string()))
            .map_err(|_| NovaError::Ssh("shell is closed".into()))
    }

    pub async fn shell_resize(&self, id: &str, cols: u32, rows: u32) -> Result<()> {
        let guard = shells().lock().map_err(|_| NovaError::Ssh("poisoned".into()))?;
        let shell = guard
            .get(id)
            .ok_or_else(|| NovaError::NotFound("shell".into()))?;
        shell
            .tx
            .send(ShellCmd::Resize(cols, rows))
            .map_err(|_| NovaError::Ssh("shell is closed".into()))
    }
}

/// Writes to a PTY shell by id without needing the SSH session that opened it:
/// the shell registry is global, and using "any session" used to pick a random
/// one when several tabs were open.
pub fn shell_write(id: &str, data: &str) -> Result<()> {
    let guard = shells().lock().map_err(|_| NovaError::Ssh("poisoned".into()))?;
    let shell = guard
        .get(id)
        .ok_or_else(|| NovaError::NotFound("shell".into()))?;
    shell
        .tx
        .send(ShellCmd::Data(data.to_string()))
        .map_err(|_| NovaError::Ssh("shell is closed".into()))
}

/// Drains everything the shell has printed since the last call.
pub fn shell_poll(id: &str) -> Result<String> {
    let guard = shells().lock().map_err(|_| NovaError::Ssh("poisoned".into()))?;
    let shell = guard
        .get(id)
        .ok_or_else(|| NovaError::NotFound("shell".into()))?;
    let mut out = String::new();
    if let Ok(mut buffer) = shell.buffer.lock() {
        std::mem::swap(&mut out, &mut *buffer);
    }
    Ok(out)
}

pub fn shell_close(id: &str) {
    if let Ok(mut guard) = shells().lock() {
        guard.remove(id);
    }
}
