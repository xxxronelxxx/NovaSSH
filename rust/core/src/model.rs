//! Serializable model shared with the Flutter UI.
//!
//! Everything crossing the bridge is `camelCase` JSON-friendly and free of
//! handles, so the UI layer never holds raw Rust objects.

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Filesystem
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EntryKind {
    Dir,
    File,
    Symlink,
    Other,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub name: String,
    /// Path as understood by the provider that produced it.
    pub path: String,
    pub kind: EntryKind,
    pub size: u64,
    /// Unix epoch milliseconds, when the backend reports it.
    pub modified: Option<i64>,
    pub mode: Option<u32>,
    pub uid: Option<u32>,
    pub gid: Option<u32>,
    pub hidden: bool,
    pub link_target: Option<String>,
}

impl Entry {
    pub fn dir(name: impl Into<String>, path: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            path: path.into(),
            kind: EntryKind::Dir,
            size: 0,
            modified: None,
            mode: None,
            uid: None,
            gid: None,
            hidden: false,
            link_target: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DirListing {
    pub path: String,
    pub parent: Option<String>,
    pub entries: Vec<Entry>,
    pub free_space: Option<u64>,
    pub total_space: Option<u64>,
}

// ---------------------------------------------------------------------------
// File comparison (Ctrl+F3)
// ---------------------------------------------------------------------------

/// Where a file lives: local path, a file inside a local archive, or a remote
/// file reachable through an open session.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileRef {
    /// Session id when the file is on a server; `None` for local files.
    pub session_id: Option<String>,
    /// Local archive that contains the file (with `path` = path inside it).
    pub archive_path: Option<String>,
    pub path: String,
    /// Shown instead of the file name (e.g. "host:/var/www/x.php").
    pub label: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct CompareOptions {
    pub ignore_whitespace: bool,
    pub ignore_case: bool,
    /// Bytes read per file; defaults to 8 MiB.
    pub max_bytes: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffWord {
    pub text: String,
    pub changed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffLine {
    pub number: u32,
    pub text: String,
    /// Word-granular spans; empty when the whole line is plain.
    pub words: Vec<DiffWord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffRow {
    /// "equal" | "add" | "del" | "mod"
    pub kind: String,
    pub left: Option<DiffLine>,
    pub right: Option<DiffLine>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompareResult {
    pub left_label: String,
    pub right_label: String,
    pub left_size: u64,
    pub right_size: u64,
    /// Identical content (after the chosen normalisation).
    pub equal: bool,
    /// Binaries are not diffed; only the sizes and hashes are reported.
    pub binary: bool,
    /// At least one side was cut at `max_bytes`, or the row list was capped.
    pub truncated: bool,
    pub added: u32,
    pub removed: u32,
    pub changed: u32,
    /// SHA-256 (hex) for binary files, so the user can compare them manually.
    pub left_hash: Option<String>,
    pub right_hash: Option<String>,
    /// Line ending of the original file ("\n" or "\r\n"), kept so saving the
    /// edited text does not rewrite every line.
    pub left_eol: String,
    pub right_eol: String,
    pub left_bom: bool,
    pub right_bom: bool,
    /// Whether the file ended with a newline.
    pub left_final_newline: bool,
    pub right_final_newline: bool,
    /// Why this side cannot be edited/saved (archive, UTF-16, ...).
    pub left_read_only: Option<String>,
    pub right_read_only: Option<String>,
    pub rows: Vec<DiffRow>,
}

/// Where a QR sync share is listening.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncShare {
    pub url: String,
    pub ip: String,
    pub port: u32,
    pub token: String,
}

/// What an import actually added.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncReport {
    pub servers: u32,
    pub groups: u32,
    pub secrets: u32,
    pub settings: bool,
    #[serde(default)]
    pub snippets: u32,
}

/// One difference found by the directory synchronizer.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncEntry {
    /// Path relative to the compared roots.
    pub relative: String,
    /// "upload" | "download" | "skip"
    pub action: String,
    /// Why this action was chosen (shown in the list).
    pub reason: String,
    pub size: u64,
    pub local_path: String,
    pub remote_path: String,
    pub local_size: u64,
    pub remote_size: u64,
    pub local_modified: Option<i64>,
    pub remote_modified: Option<i64>,
}

/// Result of a checksum request.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileChecksum {
    pub algorithm: String,
    pub hash: String,
    pub size: u64,
    /// "server" when the remote side computed it, "local" when we hashed it.
    pub computed_by: String,
}

/// One hit of the file search (Alt+F7).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FoundFile {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub modified: Option<i64>,
    pub is_dir: bool,
    /// How many times the search text occurred (0 when not searching content).
    pub matches: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Volume {
    pub path: String,
    pub name: String,
    pub kind: String,
    pub free_space: Option<u64>,
    pub total_space: Option<u64>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SortBy {
    #[default]
    Name,
    Extension,
    Size,
    Modified,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SortSpec {
    pub by: SortBy,
    pub ascending: bool,
    pub dirs_first: bool,
}

impl Default for SortSpec {
    fn default() -> Self {
        Self {
            by: SortBy::Name,
            ascending: true,
            dirs_first: true,
        }
    }
}

// ---------------------------------------------------------------------------
// Servers and groups
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    pub id: String,
    pub name: String,
    pub parent: Option<String>,
    pub color: Option<String>,
    pub order: i32,
    pub expanded: bool,
    pub icon: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AuthKind {
    Password,
    Key,
    Agent,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Auth {
    #[serde(rename = "type")]
    pub kind: AuthKind,
    pub key_path: Option<String>,
    pub passphrase_ref: Option<String>,
}

impl Default for Auth {
    fn default() -> Self {
        Self {
            kind: AuthKind::Password,
            key_path: None,
            passphrase_ref: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JumpHost {
    pub server_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Server {
    pub id: String,
    pub group_id: Option<String>,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub user: String,
    #[serde(default)]
    pub auth: Auth,
    /// Reference into `secrets.json`; the password itself is never stored here.
    pub password_ref: Option<String>,
    pub jump: Option<JumpHost>,
    pub encoding: Option<String>,
    pub remote_path: Option<String>,
    pub color: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub terminal_profile: Option<String>,
    pub notes: Option<String>,
    pub last_connected: Option<i64>,
    pub host_key_fingerprint: Option<String>,
    /// Set when the last login was rejected (wrong password / key).
    #[serde(default)]
    pub auth_failed: bool,
    /// Transport: None/"sftp" (default), "ftp", "ftps", "s3".
    #[serde(default)]
    pub protocol: Option<String>,
    /// For FTPS: "explicit" (AUTH TLS on 21) or "implicit" (TLS on 990).
    #[serde(default)]
    pub ftps_mode: Option<String>,
    /// FTPS: accept a self-signed / untrusted certificate.
    #[serde(default)]
    pub ftps_insecure: Option<bool>,
    /// FTP passive mode; defaults to true when unset.
    #[serde(default)]
    pub passive: Option<bool>,
    /// S3 endpoint, e.g. https://s3.amazonaws.com or http://192.168.1.9:9000.
    #[serde(default)]
    pub s3_endpoint: Option<String>,
    /// Region; required for cloud providers, us-east-1 for MinIO.
    #[serde(default)]
    pub s3_region: Option<String>,
    #[serde(default)]
    pub s3_bucket: Option<String>,
    #[serde(default)]
    pub s3_prefix: Option<String>,
    /// Path-style addressing (needed by MinIO and most self-hosted gateways).
    #[serde(default)]
    pub s3_path_style: Option<bool>,
    /// Secret references for the access key pair.
    #[serde(default)]
    pub s3_access_ref: Option<String>,
    #[serde(default)]
    pub s3_secret_ref: Option<String>,
    /// Result of the last access check (persisted so it survives restarts).
    #[serde(default)]
    pub reachable: Option<bool>,
    /// When `reachable` was measured (epoch ms).
    #[serde(default)]
    pub checked_at: Option<i64>,
}

impl Server {
    pub fn new(host: impl Into<String>, user: impl Into<String>) -> Self {
        Self {
            id: crate::util::new_id("s"),
            group_id: None,
            name: String::new(),
            host: host.into(),
            port: 22,
            user: user.into(),
            auth: Auth::default(),
            password_ref: None,
            jump: None,
            encoding: None,
            remote_path: None,
            color: None,
            tags: Vec::new(),
            terminal_profile: None,
            notes: None,
            last_connected: None,
            host_key_fingerprint: None,
            auth_failed: false,
            protocol: None,
            ftps_mode: None,
            ftps_insecure: None,
            passive: None,
            s3_endpoint: None,
            s3_region: None,
            s3_bucket: None,
            s3_prefix: None,
            s3_path_style: None,
            s3_access_ref: None,
            s3_secret_ref: None,
            reachable: None,
            checked_at: None,
        }
    }

    pub fn display_name(&self) -> String {
        if self.name.trim().is_empty() {
            format!("{}@{}", self.user, self.host)
        } else {
            self.name.clone()
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerBook {
    pub version: u32,
    #[serde(default)]
    pub groups: Vec<Group>,
    #[serde(default)]
    pub servers: Vec<Server>,
}

impl Default for ServerBook {
    fn default() -> Self {
        Self {
            version: 1,
            groups: Vec::new(),
            servers: Vec::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// Appearance
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColorRule {
    pub id: String,
    pub name: String,
    pub enabled: bool,
    /// Higher wins.
    pub priority: i32,
    /// `both` | `local` | `remote`
    pub scope: String,
    pub pattern: String,
    pub is_regex: bool,
    pub fg: Option<String>,
    pub bg: Option<String>,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColorRules {
    pub version: u32,
    #[serde(default)]
    pub rules: Vec<ColorRule>,
}

impl Default for ColorRules {
    fn default() -> Self {
        Self {
            version: 1,
            rules: vec![ColorRule {
                id: "php".into(),
                name: "PHP".into(),
                enabled: true,
                priority: 10,
                scope: "both".into(),
                pattern: "*.php".into(),
                is_regex: false,
                fg: Some("#FF7B72".into()),
                bg: None,
                bold: false,
                italic: false,
                underline: false,
            }],
        }
    }
}

// ---------------------------------------------------------------------------
// Settings (persisted user preferences)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub version: u32,
    pub locale: String,
    pub keymap_preset: String,
    #[serde(default)]
    pub panels: PanelSettings,
    #[serde(default)]
    pub transfer: TransferSettings,
    #[serde(default)]
    pub editor: EditorSettings,
    #[serde(default)]
    pub terminal: TerminalSettings,
    #[serde(default)]
    pub security: SecuritySettings,
    #[serde(default)]
    pub window: WindowSettings,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            version: 1,
            locale: "ru".into(),
            keymap_preset: "winscp".into(),
            panels: PanelSettings::default(),
            transfer: TransferSettings::default(),
            editor: EditorSettings::default(),
            terminal: TerminalSettings::default(),
            security: SecuritySettings::default(),
            window: WindowSettings::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PanelSettings {
    pub layout: String,
    pub show_hidden: bool,
    pub row_density: String,
    pub sync_navigation: bool,
    pub compare_panels: bool,
    pub tabs_enabled: bool,
    pub quick_filter: bool,
    /// Ctrl+D bookmarks, kept separately for both panels.
    #[serde(default)]
    pub local_bookmarks: Vec<String>,
    #[serde(default)]
    pub remote_bookmarks: Vec<String>,
}

impl Default for PanelSettings {
    fn default() -> Self {
        Self {
            layout: "dual".into(),
            show_hidden: true,
            row_density: "comfortable".into(),
            sync_navigation: true,
            compare_panels: true,
            tabs_enabled: true,
            quick_filter: true,
            local_bookmarks: Vec::new(),
            remote_bookmarks: Vec::new(),
        }
    }
}

fn default_chunks_per_file() -> u32 {
    4
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferSettings {
    pub concurrency: u32,
    /// Byte ranges of one file written at the same time (1 = sequential).
    #[serde(default = "default_chunks_per_file")]
    pub chunks_per_file: u32,
    pub chunk_kib: u32,
    pub bandwidth_limit_kibps: u32,
    pub conflict_policy: String,
    pub verify_checksum: String,
    pub preserve_times: bool,
    pub resume: bool,
}

impl Default for TransferSettings {
    fn default() -> Self {
        Self {
            concurrency: 3,
            chunks_per_file: default_chunks_per_file(),
            chunk_kib: 256,
            bandwidth_limit_kibps: 0,
            conflict_policy: "ask".into(),
            verify_checksum: "off".into(),
            preserve_times: true,
            resume: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorSettings {
    /// Empty -> built-in editor with syntax highlighting.
    pub external: String,
    pub fallback_builtin: bool,
}

impl Default for EditorSettings {
    fn default() -> Self {
        Self {
            external: String::new(),
            fallback_builtin: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalProfile {
    pub id: String,
    pub name: String,
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    pub allow_password_arg: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalSettings {
    #[serde(default)]
    pub profiles: Vec<TerminalProfile>,
    pub default_profile: Option<String>,
    pub android_mode: String,
    pub builtin_xterm: bool,
}

impl Default for TerminalSettings {
    fn default() -> Self {
        Self {
            profiles: vec![
                TerminalProfile {
                    id: "putty".into(),
                    name: "PuTTY".into(),
                    command: "C:\\Program Files\\PuTTY\\putty.exe".into(),
                    args: vec![
                        "-ssh".into(),
                        "{user}@{host}".into(),
                        "-P".into(),
                        "{port}".into(),
                    ],
                    allow_password_arg: false,
                },
                TerminalProfile {
                    id: "wt".into(),
                    name: "Windows Terminal".into(),
                    command: "wt.exe".into(),
                    args: vec![
                        "ssh".into(),
                        "-p".into(),
                        "{port}".into(),
                        "{user}@{host}".into(),
                    ],
                    allow_password_arg: false,
                },
            ],
            default_profile: Some("putty".into()),
            android_mode: "termux".into(),
            builtin_xterm: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecuritySettings {
    pub lock_on_idle_minutes: u32,
    pub clipboard_clear_seconds: u32,
    pub remember_master_key: bool,
    pub biometric_unlock: bool,
}

impl Default for SecuritySettings {
    fn default() -> Self {
        Self {
            lock_on_idle_minutes: 15,
            clipboard_clear_seconds: 30,
            remember_master_key: true,
            biometric_unlock: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowSettings {
    pub backdrop: String,
    pub solid_mode: bool,
    pub restore_bounds: bool,
    pub theme: String,
}

impl Default for WindowSettings {
    fn default() -> Self {
        Self {
            backdrop: "mica".into(),
            solid_mode: false,
            restore_bounds: true,
            theme: "nova-graphite".into(),
        }
    }
}

// ---------------------------------------------------------------------------
// Session memory
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PanelState {
    pub remote_path: String,
    pub local_path: String,
    #[serde(default)]
    pub sort: SortSpec,
    #[serde(default)]
    pub filter: String,
    pub split_ratio: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TabState {
    pub remote: String,
    pub local: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerSession {
    pub path: String,
    pub local_path: String,
    #[serde(default)]
    pub tabs: Vec<TabState>,
    pub active_tab: usize,
    #[serde(default)]
    pub sort: SortSpec,
    #[serde(default)]
    pub filter: String,
    pub split_ratio: Option<f64>,
}

impl ServerSession {
    pub fn new(remote: impl Into<String>, local: impl Into<String>) -> Self {
        let remote = remote.into();
        let local = local.into();
        Self {
            tabs: vec![TabState {
                remote: remote.clone(),
                local: local.clone(),
            }],
            path: remote,
            local_path: local,
            active_tab: 0,
            sort: SortSpec::default(),
            filter: String::new(),
            split_ratio: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerSessionRecord {
    pub server_id: String,
    #[serde(flatten)]
    pub session: ServerSession,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub server_id: String,
    #[serde(default)]
    pub paths: Vec<String>,
}

/// One server tab that was open when the app closed.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenSession {
    pub server_id: String,
    pub name: String,
    pub local_path: String,
    pub remote_path: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionState {
    pub version: u32,
    pub last_server_id: Option<String>,
    #[serde(default)]
    pub servers: Vec<ServerSessionRecord>,
    #[serde(default)]
    pub history: Vec<HistoryEntry>,
    #[serde(default)]
    pub recent_local: Vec<String>,
    /// Tabs that were open last time, so they can be restored on demand.
    #[serde(default)]
    pub open_sessions: Vec<OpenSession>,
}

// ---------------------------------------------------------------------------
// Transfers
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TransferState {
    Queued,
    Running,
    Done,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferEvent {
    pub id: String,
    pub name: String,
    pub total: u64,
    pub done: u64,
    pub state: TransferState,
    pub message: Option<String>,
}

// ---------------------------------------------------------------------------
// Command snippets
// ---------------------------------------------------------------------------

/// One saved command for the terminal palette.
///
/// Snippets are deliberately simple: a name, the command text and a few flags.
/// `scope` is `global` (shown everywhere) or `server` (only for `server_id`).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Snippet {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub command: String,
    #[serde(default)]
    pub description: String,
    /// Shown in the quick strip above the terminal input.
    #[serde(default)]
    pub favorite: bool,
    /// Insert-only by default; this flag sends the command with Enter.
    #[serde(default)]
    pub run_immediately: bool,
    /// Ask before running (protects against an accidental tap).
    #[serde(default = "default_true")]
    pub confirm: bool,
    #[serde(default)]
    pub scope: String,
    #[serde(default)]
    pub server_id: Option<String>,
    #[serde(default)]
    pub order: i32,
    #[serde(default)]
    pub created_at: i64,
    #[serde(default)]
    pub updated_at: i64,
}

impl Snippet {
    pub(crate) fn is_server_scoped(&self) -> bool {
        self.scope.eq_ignore_ascii_case("server") && self.server_id.is_some()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnippetBook {
    #[serde(default = "default_one")]
    pub version: u32,
    #[serde(default)]
    pub snippets: Vec<Snippet>,
}

impl Default for SnippetBook {
    fn default() -> Self {
        Self {
            version: 1,
            snippets: Vec::new(),
        }
    }
}

fn default_one() -> u32 {
    1
}

fn default_true() -> bool {
    true
}

// ---------------------------------------------------------------------------
// AI assistant settings
// ---------------------------------------------------------------------------

/// Provider/model selection for the command assistant. The API key is kept in
/// the vault under `ai_key_<provider>`, never in this file.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AiSettings {
    pub enabled: bool,
    /// `zen` | `go` | `openrouter` | `custom`
    pub provider: String,
    pub endpoint: String,
    #[serde(default)]
    pub model: String,
    /// Send `uname`, the current directory and the login name with the prompt.
    #[serde(default = "default_true")]
    pub include_context: bool,
}

impl Default for AiSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            provider: "zen".into(),
            endpoint: "https://opencode.ai/zen/v1".into(),
            model: String::new(),
            include_context: true,
        }
    }
}

/// What the user wants written to `logs/` while working.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct LogSettings {
    /// One line per edited file: local date/time, server and path.
    #[serde(default)]
    pub edit_log: bool,
}
