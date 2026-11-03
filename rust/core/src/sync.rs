//! Phone ↔ desktop profile transfer without accounts.
//!
//! The desktop starts a tiny HTTP server with a one-time token and shows the
//! URL as a QR code. The phone scans it, downloads the JSON payload and imports
//! servers, groups, settings and (optionally) the stored passwords.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::model::{Group, Server, Settings};

/// Everything that travels between devices.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncPayload {
    pub version: u32,
    pub exported_at: i64,
    #[serde(default)]
    pub servers: Vec<Server>,
    #[serde(default)]
    pub groups: Vec<Group>,
    #[serde(default)]
    pub settings: Option<Settings>,
    /// Secret id -> plaintext value; only present when the user allowed it.
    #[serde(default)]
    pub secrets: Option<HashMap<String, String>>,
    #[serde(default)]
    pub snippets: Vec<crate::model::Snippet>,
    #[serde(default)]
    pub ai: crate::model::AiSettings,
}

struct ShareState {
    stop: Arc<AtomicBool>,
    token: String,
}

static SHARE: OnceLock<Mutex<Option<ShareState>>> = OnceLock::new();

fn share_slot() -> &'static Mutex<Option<ShareState>> {
    SHARE.get_or_init(|| Mutex::new(None))
}

/// Best guess of the LAN address the phone can reach.
pub fn lan_ip() -> Option<String> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    socket
        .local_addr()
        .ok()
        .map(|addr| addr.ip().to_string())
        .filter(|ip| !ip.starts_with("127."))
}

fn random_token() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 16];
    rand::rng().fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub struct StartedShare {
    pub url: String,
    pub ip: String,
    pub port: u16,
    pub token: String,
}

/// Starts the one-shot HTTP share and returns the URL to put into the QR code.
pub fn start_share(payload_json: String, ttl: Duration) -> Result<StartedShare, String> {
    stop_share();

    let ip = lan_ip().ok_or_else(|| {
        "Не удалось определить адрес в локальной сети. Подключите компьютер к Wi-Fi."
            .to_string()
    })?;
    let server = tiny_http::Server::http("0.0.0.0:0")
        .map_err(|e| format!("Не удалось запустить сервер синхронизации: {e}"))?;
    let port = server
        .server_addr()
        .to_ip()
        .map(|addr| addr.port())
        .ok_or_else(|| "Не удалось получить порт".to_string())?;

    let token = random_token();
    let url = format!("http://{ip}:{port}/sync?token={token}");
    let stop = Arc::new(AtomicBool::new(false));
    let stop_flag = stop.clone();
    let expected_token = token.clone();
    let body = payload_json.into_bytes();

    std::thread::spawn(move || {
        let deadline = Instant::now() + ttl;
        while !stop_flag.load(Ordering::Relaxed) && Instant::now() < deadline {
            let request = match server.recv_timeout(Duration::from_millis(400)) {
                Ok(Some(request)) => request,
                Ok(None) => continue,
                Err(_) => break,
            };

            let url = request.url().to_string();
            let allowed = url == format!("/sync?token={expected_token}");
            let header = tiny_http::Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..])
                .expect("static header");
            let cors = tiny_http::Header::from_bytes(
                &b"Access-Control-Allow-Origin"[..],
                &b"*"[..],
            )
            .expect("static header");

            if allowed {
                let response = tiny_http::Response::from_data(body.clone())
                    .with_header(header)
                    .with_header(cors)
                    .with_status_code(200);
                let _ = request.respond(response);
                break; // one-shot: the payload is gone after the first download
            }
            let response = tiny_http::Response::from_string("forbidden").with_status_code(403);
            let _ = request.respond(response);
        }
    });

    if let Ok(mut slot) = share_slot().lock() {
        *slot = Some(ShareState {
            stop,
            token: token.clone(),
        });
    }

    Ok(StartedShare {
        url,
        ip,
        port,
        token,
    })
}

/// Stops a running share (no-op when none is active).
pub fn stop_share() {
    if let Ok(mut slot) = share_slot().lock() {
        if let Some(state) = slot.take() {
            state.stop.store(true, Ordering::Relaxed);
        }
    }
}

pub fn active_token() -> Option<String> {
    share_slot()
        .lock()
        .ok()
        .and_then(|slot| slot.as_ref().map(|state| state.token.clone()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_round_trips() {
        let payload = SyncPayload {
            version: 1,
            exported_at: 123,
            servers: Vec::new(),
            groups: Vec::new(),
            settings: None,
            secrets: None,
            snippets: Vec::new(),
            ai: Default::default(),
        };
        let json = serde_json::to_string(&payload).unwrap();
        let back: SyncPayload = serde_json::from_str(&json).unwrap();
        assert_eq!(back.version, 1);
        assert_eq!(back.exported_at, 123);
    }

    #[test]
    fn unknown_fields_are_ignored() {
        let json = r#"{"version":1,"exported_at":5,"servers":[],"groups":[]}"#;
        let back: SyncPayload = serde_json::from_str(json).unwrap();
        assert!(back.secrets.is_none());
        assert!(back.settings.is_none());
    }

    #[test]
    fn token_is_hex_and_unique() {
        let a = random_token();
        let b = random_token();
        assert_eq!(a.len(), 32);
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, b);
    }
}
