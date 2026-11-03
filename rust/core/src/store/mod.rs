//! On-disk JSON storage: paths, atomic writes, settings, session state.

use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::Serialize;

use crate::error::{NovaError, Result};
use crate::model::{ColorRules, Server, ServerBook, ServerSession, SessionState};

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct Paths {
    pub root: PathBuf,
}

impl Paths {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// Default location used on desktop. The mobile layer passes its own
    /// app-private directory to [`Paths::new`] instead.
    /// Portable by default: everything lives in `data` next to the exe.
    /// Falls back to the legacy %APPDATA% folder when that is not writable.
    pub fn default_desktop() -> Self {
        if let Ok(custom) = std::env::var("NOVA_DATA_DIR") {
            if !custom.trim().is_empty() {
                return Self::new(custom);
            }
        }
        if let Some(dir) = portable_dir() {
            return Self::new(dir);
        }
        Self::new(legacy_dir())
    }

    /// Old location, used for migration and read-only installs.
    pub fn legacy() -> Self {
        Self::new(legacy_dir())
    }

    pub fn servers(&self) -> PathBuf {
        self.root.join("servers.json")
    }

    pub fn secrets(&self) -> PathBuf {
        self.root.join("secrets.json")
    }

    pub fn keywrap(&self) -> PathBuf {
        self.root.join("keywrap.bin")
    }

    pub fn settings(&self) -> PathBuf {
        self.root.join("settings.json")
    }

    pub fn state(&self) -> PathBuf {
        self.root.join("state.json")
    }

    pub fn rules(&self) -> PathBuf {
        self.root.join("filecolors.json")
    }

    pub fn snippets(&self) -> PathBuf {
        self.root.join("snippets.json")
    }

    /// AI provider/model selection (the API key lives in `secrets.json`).
    pub fn ai_settings(&self) -> PathBuf {
        self.root.join("ai.json")
    }

    /// Logging switches (the log files themselves live in `logs/`).
    pub fn logging(&self) -> PathBuf {
        self.root.join("logging.json")
    }

    pub fn themes_dir(&self) -> PathBuf {
        self.root.join("themes")
    }

    pub fn index_cache(&self) -> PathBuf {
        self.root.join("cache").join("idx")
    }

    pub fn edit_cache(&self) -> PathBuf {
        self.root.join("cache").join("edit")
    }

    /// Temporary copies of edited files; wiped when a server tab closes.
    pub fn tmp_dir(&self) -> PathBuf {
        self.root.join("tmp")
    }

    pub fn logs_dir(&self) -> PathBuf {
        self.root.join("logs")
    }

    pub fn ensure(&self) -> Result<()> {
        for dir in [
            self.root.clone(),
            self.themes_dir(),
            self.index_cache(),
            self.edit_cache(),
            self.tmp_dir(),
            self.logs_dir(),
        ] {
            std::fs::create_dir_all(&dir)?;
        }
        Ok(())
    }
}

fn portable_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    // "profile", not "data": Flutter already uses data/ for its assets.
    let base = exe.parent()?.join("profile");
    std::fs::create_dir_all(&base).ok()?;
    let probe = base.join(".write-test");
    std::fs::write(&probe, b"ok").ok()?;
    let _ = std::fs::remove_file(&probe);
    Some(base)
}

fn legacy_dir() -> PathBuf {
    let base = dirs::config_dir().unwrap_or_else(|| PathBuf::from("."));
    base.join("NovaSSH")
}

/// Copies an existing %APPDATA% profile into the portable folder once.
pub fn migrate_legacy_if_needed(target: &Paths) {
    let legacy = legacy_dir();
    if legacy == target.root || target.servers().exists() {
        return;
    }
    if !legacy.join("servers.json").exists() {
        return;
    }
    let _ = target.ensure();
    for entry in std::fs::read_dir(&legacy).into_iter().flatten().flatten() {
        let path = entry.path();
        let Some(name) = path.file_name() else { continue };
        let dest = target.root.join(name);
        if path.is_dir() {
            let _ = copy_dir(&path, &dest);
        } else {
            let _ = std::fs::copy(&path, &dest);
        }
    }
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)?.flatten() {
        let path = entry.path();
        let dest = to.join(entry.file_name());
        if path.is_dir() {
            copy_dir(&path, &dest)?;
        } else {
            std::fs::copy(&path, &dest)?;
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// JSON helpers (atomic: temp file + rename)
// ---------------------------------------------------------------------------

pub fn save_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(value)?;
    save_bytes(path, &bytes)
}

pub fn save_bytes(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("tmp");
    {
        use std::io::Write;
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        // The rename is only atomic for bytes that reached the disk.
        file.sync_all()?;
    }
    // `rename` replaces an existing file on Windows (MoveFileEx with
    // MOVEFILE_REPLACE_EXISTING) and on POSIX. Deleting the target first, as
    // this used to do, left a window where a crash erased the whole profile.
    std::fs::rename(&tmp, path)?;
    Ok(())
}

pub fn load_json<T: DeserializeOwned + Default>(path: &Path) -> Result<T> {
    match std::fs::read(path) {
        Ok(raw) if !raw.is_empty() => Ok(serde_json::from_slice(&raw)?),
        Ok(_) => Ok(T::default()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(T::default()),
        Err(e) => Err(NovaError::Io(e)),
    }
}

// ---------------------------------------------------------------------------
// Server book
// ---------------------------------------------------------------------------

impl ServerBook {
    pub fn server(&self, id: &str) -> Option<&Server> {
        self.servers.iter().find(|s| s.id == id)
    }

    pub fn upsert_server(&mut self, server: Server) {
        match self.servers.iter_mut().find(|s| s.id == server.id) {
            Some(existing) => *existing = server,
            None => self.servers.push(server),
        }
    }

    pub fn remove_server(&mut self, id: &str) -> bool {
        let before = self.servers.len();
        self.servers.retain(|s| s.id != id);
        // Drop dangling jump-host references.
        for s in &mut self.servers {
            if s.jump.as_ref().is_some_and(|j| j.server_id == id) {
                s.jump = None;
            }
        }
        self.groups.iter().all(|g| g.id != id) && before != self.servers.len()
    }

    pub fn upsert_group(&mut self, group: crate::model::Group) {
        match self.groups.iter_mut().find(|g| g.id == group.id) {
            Some(existing) => *existing = group,
            None => self.groups.push(group),
        }
    }

    /// Removes the group and re-parents its children/servers to the group's parent.
    pub fn remove_group(&mut self, id: &str) -> bool {
        let parent = self
            .groups
            .iter()
            .find(|g| g.id == id)
            .and_then(|g| g.parent.clone());
        let before = self.groups.len();
        self.groups.retain(|g| g.id != id);
        for g in &mut self.groups {
            if g.parent.as_deref() == Some(id) {
                g.parent = parent.clone();
            }
        }
        for s in &mut self.servers {
            if s.group_id.as_deref() == Some(id) {
                s.group_id = parent.clone();
            }
        }
        before != self.groups.len()
    }

    /// Validates invariants that would otherwise produce dangling references.
    ///
    /// Also heals old damage: duplicate names are merged and the virtual
    /// "Все серверы" entry (created by an earlier drag&drop bug) is removed.
    pub fn validate(&mut self) -> Result<()> {
        // 1. Drop virtual/empty groups, remembering where their servers go.
        let mut reparent: std::collections::HashMap<String, Option<String>> = Default::default();
        let mut keep: Vec<crate::model::Group> = Vec::new();
        for group in self.groups.drain(..) {
            let name = group.name.trim();
            let virtual_entry = name.is_empty() || name.eq_ignore_ascii_case("все серверы");
            if virtual_entry {
                reparent.insert(group.id.clone(), group.parent.clone());
            } else {
                keep.push(group);
            }
        }
        self.groups = keep;

        // 2. Merge groups that share a name (keep the first, re-point the rest).
        let mut seen: std::collections::HashMap<String, String> = Default::default();
        let mut unique: Vec<crate::model::Group> = Vec::new();
        for group in self.groups.drain(..) {
            let key = group.name.trim().to_lowercase();
            match seen.get(&key) {
                Some(existing) => {
                    reparent.insert(group.id.clone(), Some(existing.clone()));
                }
                None => {
                    seen.insert(key, group.id.clone());
                    unique.push(group);
                }
            }
        }
        self.groups = unique;

        for server in self.servers.iter_mut() {
            let mut target = server.group_id.clone();
            // Follow chains left by removed groups.
            for _ in 0..8 {
                match target.clone() {
                    Some(id) if reparent.contains_key(&id) => {
                        target = reparent.get(&id).cloned().flatten();
                    }
                    _ => break,
                }
            }
            server.group_id = target;
        }
        for group in self.groups.iter_mut() {
            if let Some(parent) = group.parent.clone() {
                if let Some(next) = reparent.get(&parent) {
                    group.parent = next.clone();
                }
            }
        }

        let group_ids: std::collections::HashSet<String> =
            self.groups.iter().map(|g| g.id.clone()).collect();
        for g in &mut self.groups {
            if let Some(p) = &g.parent {
                if !group_ids.contains(p) || p == &g.id {
                    g.parent = None;
                }
            }
        }
        let server_ids: std::collections::HashSet<String> =
            self.servers.iter().map(|s| s.id.clone()).collect();
        for s in &mut self.servers {
            if s.group_id.as_ref().is_some_and(|g| !group_ids.contains(g)) {
                s.group_id = None;
            }
            if s.jump
                .as_ref()
                .is_some_and(|j| !server_ids.contains(&j.server_id) || j.server_id == s.id)
            {
                s.jump = None;
            }
            if s.name.trim().is_empty() {
                s.name = format!("{}@{}", s.user, s.host);
            }
            if s.port == 0 {
                s.port = 22;
            }
            // Legacy entries: infer the transport from the well-known ports.
            if s.protocol.is_none() {
                match s.port {
                    21 => s.protocol = Some("ftp".into()),
                    990 => s.protocol = Some("ftps".into()),
                    _ => {}
                }
            }
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Session state helpers
// ---------------------------------------------------------------------------

impl SessionState {
    pub fn record(&self, server_id: &str) -> Option<&crate::model::ServerSessionRecord> {
        self.servers.iter().find(|r| r.server_id == server_id)
    }

    pub fn record_mut(&mut self, server_id: &str) -> &mut crate::model::ServerSessionRecord {
        if let Some(pos) = self.servers.iter().position(|r| r.server_id == server_id) {
            return &mut self.servers[pos];
        }
        self.servers.push(crate::model::ServerSessionRecord {
            server_id: server_id.to_string(),
            session: ServerSession::new(String::new(), String::new()),
        });
        self.servers.last_mut().expect("just pushed")
    }

    pub fn history_mut(&mut self, server_id: &str) -> &mut Vec<String> {
        if let Some(pos) = self.history.iter().position(|h| h.server_id == server_id) {
            return &mut self.history[pos].paths;
        }
        self.history.push(crate::model::HistoryEntry {
            server_id: server_id.to_string(),
            paths: Vec::new(),
        });
        &mut self.history.last_mut().expect("just pushed").paths
    }

    pub fn remember(&mut self, server_id: &str, remote: &str, local: &str) {
        self.last_server_id = Some(server_id.to_string());

        let history = self.history_mut(server_id);
        if history.last().map(|p| p != remote).unwrap_or(true) {
            history.push(remote.to_string());
            if history.len() > 40 {
                history.remove(0);
            }
        }

        self.recent_local.retain(|p| p != local);
        self.recent_local.insert(0, local.to_string());
        self.recent_local.truncate(20);

        let record = self.record_mut(server_id);
        record.session.path = remote.to_string();
        record.session.local_path = local.to_string();
    }
}

// ---------------------------------------------------------------------------
// Colour rules
// ---------------------------------------------------------------------------

/// Last matching (highest priority) rule wins; scope limits where it applies.
pub fn resolve_rule<'a>(
    rules: &'a ColorRules,
    name: &str,
    scope: &str,
) -> Option<&'a crate::model::ColorRule> {
    let mut sorted: Vec<&crate::model::ColorRule> = rules
        .rules
        .iter()
        .filter(|r| r.enabled && (r.scope == "both" || r.scope == scope))
        .collect();
    sorted.sort_by_key(|r| r.priority);
    sorted.into_iter().rev().find(|r| {
        if r.is_regex {
            regex::Regex::new(&r.pattern)
                .map(|re| re.is_match(name))
                .unwrap_or(false)
        } else {
            crate::util::glob_match(&r.pattern, name)
        }
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Auth, ColorRules, EntryKind, Group, Settings};

    fn sample_server(id: &str, host: &str) -> Server {
        Server {
            id: id.into(),
            group_id: None,
            name: host.into(),
            host: host.into(),
            port: 22,
            user: "root".into(),
            auth: Auth::default(),
            password_ref: None,
            jump: None,
            encoding: None,
            remote_path: None,
            color: None,
            tags: vec![],
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

    #[test]
    fn json_roundtrip_is_stable() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("servers.json");
        let mut book = ServerBook::default();
        book.upsert_server(sample_server("s_1", "10.0.0.1"));
        save_json(&path, &book).unwrap();
        let loaded: ServerBook = load_json(&path).unwrap();
        assert_eq!(loaded.servers.len(), 1);
        assert_eq!(loaded.servers[0].host, "10.0.0.1");
    }

    #[test]
    fn save_replaces_the_file_and_leaves_no_temp() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("servers.json");
        std::fs::write(&path, b"{\"version\":0}").unwrap();

        crate::store::save_bytes(&path, b"first").unwrap();
        crate::store::save_bytes(&path, b"second!").unwrap();

        assert_eq!(std::fs::read(&path).unwrap(), b"second!");
        assert!(!path.with_extension("tmp").exists());
    }

    #[test]
    fn missing_file_yields_default() {
        let dir = tempfile::tempdir().unwrap();
        let settings: Settings = load_json(&dir.path().join("nope.json")).unwrap();
        assert_eq!(settings.keymap_preset, "winscp");
        assert_eq!(settings.transfer.concurrency, 3);
    }

    #[test]
    fn removing_group_reparents_children() {
        let mut book = ServerBook::default();
        book.upsert_group(Group {
            id: "g1".into(),
            name: "root".into(),
            parent: None,
            color: None,
            order: 0,
            expanded: true,
            icon: None,
        });
        book.upsert_group(Group {
            id: "g2".into(),
            name: "child".into(),
            parent: Some("g1".into()),
            color: None,
            order: 0,
            expanded: true,
            icon: None,
        });
        let mut s = sample_server("s1", "h");
        s.group_id = Some("g2".into());
        book.upsert_server(s);

        // Deleting a nested group re-parents its servers to the nearest ancestor.
        book.remove_group("g2");
        assert_eq!(book.servers[0].group_id.as_deref(), Some("g1"));

        // Deleting a top-level group detaches them entirely.
        book.remove_group("g1");
        assert!(book.servers[0].group_id.is_none());
    }

    #[test]
    fn validate_drops_dangling_refs() {
        let mut book = ServerBook::default();
        let mut s = sample_server("s1", "h");
        s.group_id = Some("missing".into());
        s.name = "  ".into();
        book.upsert_server(s);
        book.validate().unwrap();
        assert!(book.servers[0].group_id.is_none());
        assert_eq!(book.servers[0].name, "root@h");
    }

    #[test]
    fn color_rules_priority_and_scope() {
        let rules = ColorRules::default();
        assert!(resolve_rule(&rules, "index.php", "local").is_some());
        assert!(resolve_rule(&rules, "index.txt", "local").is_none());

        let mut rules = ColorRules {
            version: 1,
            rules: vec![],
        };
        rules.rules.push(crate::model::ColorRule {
            id: "low".into(),
            name: "low".into(),
            enabled: true,
            priority: 1,
            scope: "both".into(),
            pattern: "*.log".into(),
            is_regex: false,
            fg: Some("#111111".into()),
            bg: None,
            bold: false,
            italic: false,
            underline: false,
        });
        rules.rules.push(crate::model::ColorRule {
            id: "high".into(),
            name: "high".into(),
            enabled: true,
            priority: 9,
            scope: "remote".into(),
            pattern: "error.log".into(),
            is_regex: false,
            fg: Some("#FF0000".into()),
            bg: None,
            bold: true,
            italic: false,
            underline: false,
        });
        assert_eq!(
            resolve_rule(&rules, "error.log", "remote").unwrap().id,
            "high"
        );
        assert_eq!(
            resolve_rule(&rules, "error.log", "local").unwrap().id,
            "low"
        );
        assert!(resolve_rule(&rules, "error.log", "local").is_some());
        let _ = EntryKind::File;
    }
}
