//! Reusable in-process SSH/SFTP server backed by a directory (test support).
#![allow(dead_code)]

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use russh::keys::{Algorithm, PrivateKey};
use russh::server::{Auth, ChannelOpenHandle, Msg, Server as _, Session};
use russh::{Channel, ChannelId};
use russh_sftp::protocol::{
    Attrs, Data, File, FileAttributes, Handle, Name, Status, StatusCode, Version,
};

// ---------------------------------------------------------------------------
// SSH server
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct TestServer {
    root: Arc<PathBuf>,
}

impl russh::server::Server for TestServer {
    type Handler = SshHandler;

    fn new_client(&mut self, _: Option<SocketAddr>) -> Self::Handler {
        SshHandler::new(self.root.clone())
    }
}

struct SshHandler {
    root: Arc<PathBuf>,
    channels: Arc<tokio::sync::Mutex<HashMap<ChannelId, Channel<Msg>>>>,
}

impl SshHandler {
    fn new(root: Arc<PathBuf>) -> Self {
        Self {
            root,
            channels: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
        }
    }
}

impl russh::server::Handler for SshHandler {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        Ok(if user == "tester" && password == "secret" {
            Auth::Accept
        } else {
            Auth::reject()
        })
    }

    async fn channel_open_session(
        &mut self,
        channel: Channel<Msg>,
        reply: ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.channels.lock().await.insert(channel.id(), channel);
        reply.accept().await;
        Ok(())
    }

    async fn exec_request(
        &mut self,
        channel_id: ChannelId,
        _data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        // No commands available in this sandbox: succeed with empty output.
        session.channel_success(channel_id)?;
        session.exit_status_request(channel_id, 0)?;
        session.eof(channel_id)?;
        session.close(channel_id)?;
        Ok(())
    }

    async fn subsystem_request(
        &mut self,
        channel_id: ChannelId,
        name: &str,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if name != "sftp" {
            session.channel_failure(channel_id)?;
            return Ok(());
        }
        let channel = self.channels.lock().await.remove(&channel_id);
        let Some(channel) = channel else {
            session.channel_failure(channel_id)?;
            return Ok(());
        };
        session.channel_success(channel_id)?;
        let handler = FsHandler::new(self.root.clone());
        tokio::spawn(async move {
            russh_sftp::server::run(channel.into_stream(), handler).await;
        });
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// SFTP handler backed by a real directory
// ---------------------------------------------------------------------------

struct FsHandler {
    root: Arc<PathBuf>,
    open: HashMap<String, PathBuf>,
    dirs: HashMap<String, (Vec<File>, usize)>,
    counter: u64,
}

impl FsHandler {
    fn new(root: Arc<PathBuf>) -> Self {
        Self {
            root,
            open: HashMap::new(),
            dirs: HashMap::new(),
            counter: 0,
        }
    }

    fn resolve(&self, path: &str) -> PathBuf {
        let rel = path.trim_start_matches('/');
        let candidate = self.root.join(rel);
        // Guard against traversal outside the sandbox.
        match candidate.canonicalize() {
            Ok(p) if p.starts_with(self.root.as_path()) => p,
            Ok(_) => self.root.join("__blocked__"),
            Err(_) => candidate,
        }
    }

    fn next_handle(&mut self) -> String {
        self.counter += 1;
        format!("h{}", self.counter)
    }
}

fn ok(id: u32) -> Status {
    Status {
        id,
        status_code: StatusCode::Ok,
        error_message: "Ok".to_string(),
        language_tag: "en-US".to_string(),
    }
}

fn attrs_of(path: &Path) -> Result<FileAttributes, StatusCode> {
    let meta = std::fs::metadata(path).map_err(|_| StatusCode::NoSuchFile)?;
    let is_dir = meta.is_dir();
    let mode = if is_dir { 0o040755 } else { 0o100644 };
    let mtime = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as u32);
    Ok(FileAttributes {
        size: Some(if is_dir { 0 } else { meta.len() }),
        uid: Some(1000),
        user: None,
        gid: Some(1000),
        group: None,
        permissions: Some(mode),
        atime: mtime,
        mtime,
    })
}

impl russh_sftp::server::Handler for FsHandler {
    type Error = StatusCode;

    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }

    async fn init(
        &mut self,
        _version: u32,
        _extensions: HashMap<String, String>,
    ) -> Result<Version, Self::Error> {
        Ok(Version::new())
    }

    async fn open(
        &mut self,
        id: u32,
        filename: String,
        _pflags: russh_sftp::protocol::OpenFlags,
        _attrs: FileAttributes,
    ) -> Result<Handle, StatusCode> {
        let path = self.resolve(&filename);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|_| StatusCode::Failure)?;
        }
        // CREATE + WRITE: ensure the file exists; content is written by `write`.
        if !path.exists() {
            std::fs::write(&path, b"").map_err(|_| StatusCode::PermissionDenied)?;
        }
        let handle = self.next_handle();
        self.open.insert(handle.clone(), path);
        Ok(Handle { id, handle })
    }

    async fn close(&mut self, id: u32, handle: String) -> Result<Status, StatusCode> {
        self.open.remove(&handle);
        self.dirs.remove(&handle);
        Ok(ok(id))
    }

    async fn read(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        len: u32,
    ) -> Result<Data, StatusCode> {
        use std::io::{Read, Seek, SeekFrom};
        let path = self.open.get(&handle).ok_or(StatusCode::Failure)?;
        let mut file = std::fs::File::open(path).map_err(|_| StatusCode::NoSuchFile)?;
        let total = file.metadata().map_err(|_| StatusCode::Failure)?.len();
        if offset >= total {
            return Err(StatusCode::Eof);
        }
        file.seek(SeekFrom::Start(offset))
            .map_err(|_| StatusCode::Failure)?;
        let mut buf = vec![0u8; len as usize];
        let read = file.read(&mut buf).map_err(|_| StatusCode::Failure)?;
        if read == 0 {
            return Err(StatusCode::Eof);
        }
        buf.truncate(read);
        Ok(Data { id, data: buf })
    }

    async fn write(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        data: Vec<u8>,
    ) -> Result<Status, StatusCode> {
        use std::io::{Seek, SeekFrom, Write};
        let path = self.open.get(&handle).ok_or(StatusCode::Failure)?;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
            .map_err(|_| StatusCode::PermissionDenied)?;
        file.seek(SeekFrom::Start(offset))
            .map_err(|_| StatusCode::Failure)?;
        file.write_all(&data).map_err(|_| StatusCode::Failure)?;
        Ok(ok(id))
    }

    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, StatusCode> {
        let attrs = attrs_of(&self.resolve(&path))?;
        Ok(Attrs { id, attrs })
    }

    async fn stat(&mut self, id: u32, path: String) -> Result<Attrs, StatusCode> {
        let attrs = attrs_of(&self.resolve(&path))?;
        Ok(Attrs { id, attrs })
    }

    async fn fstat(&mut self, id: u32, handle: String) -> Result<Attrs, StatusCode> {
        let path = self.open.get(&handle).ok_or(StatusCode::Failure)?;
        let attrs = attrs_of(path)?;
        Ok(Attrs { id, attrs })
    }

    async fn setstat(
        &mut self,
        id: u32,
        _path: String,
        _attrs: FileAttributes,
    ) -> Result<Status, StatusCode> {
        Ok(ok(id))
    }

    async fn opendir(&mut self, id: u32, path: String) -> Result<Handle, StatusCode> {
        let dir = self.resolve(&path);
        let mut files = Vec::new();
        for entry in std::fs::read_dir(&dir).map_err(|_| StatusCode::NoSuchFile)? {
            let entry = entry.map_err(|_| StatusCode::Failure)?;
            let name = entry.file_name().to_string_lossy().to_string();
            let attrs = attrs_of(&entry.path()).map_err(|_| StatusCode::Failure)?;
            files.push(File {
                filename: name,
                longname: String::new(),
                attrs,
            });
        }
        let handle = self.next_handle();
        self.dirs.insert(handle.clone(), (files, 0));
        Ok(Handle { id, handle })
    }

    async fn readdir(&mut self, id: u32, handle: String) -> Result<Name, StatusCode> {
        let (files, pos) = self.dirs.get_mut(&handle).ok_or(StatusCode::Failure)?;
        if *pos > 0 {
            return Err(StatusCode::Eof);
        }
        *pos += 1;
        Ok(Name {
            id,
            files: files.clone(),
        })
    }

    async fn remove(&mut self, id: u32, path: String) -> Result<Status, StatusCode> {
        std::fs::remove_file(self.resolve(&path)).map_err(|_| StatusCode::Failure)?;
        Ok(ok(id))
    }

    async fn mkdir(
        &mut self,
        id: u32,
        path: String,
        _attrs: FileAttributes,
    ) -> Result<Status, StatusCode> {
        std::fs::create_dir_all(self.resolve(&path)).map_err(|_| StatusCode::Failure)?;
        Ok(ok(id))
    }

    async fn rmdir(&mut self, id: u32, path: String) -> Result<Status, StatusCode> {
        std::fs::remove_dir(self.resolve(&path)).map_err(|_| StatusCode::Failure)?;
        Ok(ok(id))
    }

    async fn rename(
        &mut self,
        id: u32,
        oldpath: String,
        newpath: String,
    ) -> Result<Status, StatusCode> {
        std::fs::rename(self.resolve(&oldpath), self.resolve(&newpath))
            .map_err(|_| StatusCode::Failure)?;
        Ok(ok(id))
    }

    async fn realpath(&mut self, id: u32, path: String) -> Result<Name, StatusCode> {
        Ok(Name {
            id,
            files: vec![File::dummy(path)],
        })
    }
}

/// Starts the server in the background and returns its join handle.
pub fn spawn(root: std::path::PathBuf, port: u16) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        // `canonicalize` returns a verbatim path (\?\C:\...) on Windows,
        // so the sandbox root must be canonical for the starts_with guard.
        let root = std::fs::canonicalize(&root).unwrap_or(root);
        let root_arc = Arc::new(root);
        let mut server = TestServer { root: root_arc };
        let config = Arc::new(russh::server::Config {
            keys: vec![host_key()],
            ..Default::default()
        });
        let _ = server
            .run_on_address(config, format!("127.0.0.1:{port}"))
            .await;
    })
}

/// Stable host key across restarts, so TOFU fingerprints do not change between
/// demo runs (stored next to the demo data, not in the repo).
fn host_key() -> PrivateKey {
    let path = std::env::temp_dir().join("nova-demo-hostkey");
    if let Ok(pem) = std::fs::read(&path) {
        if let Ok(key) = PrivateKey::from_openssh(&pem) {
            return key;
        }
    }
    let key = PrivateKey::random(&mut russh::keys::key::safe_rng(), Algorithm::Ed25519)
        .expect("generate host key");
    if let Ok(pem) = key.to_openssh(russh::keys::ssh_key::LineEnding::LF) {
        let _ = std::fs::write(&path, pem.as_bytes());
    }
    key
}
