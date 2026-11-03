//! WinSCP.ini import: sessions, folders (groups) and optional password decryption.
//!
//! WinSCP stores sessions flat, with the folder path encoded in the section
//! name: `[Sessions\<folder>/<session>]`. Names are URL-encoded.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WinscpSession {
    pub name: String,
    pub group: Option<String>,
    pub host: String,
    pub user: String,
    pub port: u16,
    /// Hex blob exactly as stored by WinSCP; decryption is done separately.
    pub password: Option<String>,
    pub remote_dir: Option<String>,
    pub local_dir: Option<String>,
    pub key_file: Option<String>,
    /// Raw `FSProtocol` value (2 = SFTP, 3/5 = FTP, 4 = WebDAV).
    pub protocol: Option<u32>,
}

/// WinSCP obfuscation constants (algorithm from `anoopengineer/winscppasswd`).
const PW_MAGIC: u8 = 0xA3;
const PW_FLAG: u8 = 0xFF;

fn next_byte(data: &[u8], pos: usize) -> Option<(u8, usize)> {
    if pos + 1 >= data.len() {
        return None;
    }
    let a = data[pos];
    let b = data[pos + 1];
    Some((!(((a << 4) + b) ^ PW_MAGIC) & 0xFF, pos + 2))
}

/// Decrypts a password stored by WinSCP.
///
/// Each nibble is processed separately and the `user+host` key is folded into
/// the long form, so both are required. Returns `None` for malformed input.
pub fn decrypt_password(host: &str, user: &str, hex: &str) -> Option<String> {
    let data: Vec<u8> = hex
        .chars()
        .filter_map(|c| c.to_digit(16))
        .map(|d| d as u8)
        .collect();
    if data.len() < 4 {
        return None;
    }
    let key = format!("{user}{host}");

    let (flag, mut pos) = next_byte(&data, 0)?;
    let length: u8;
    if flag == PW_FLAG {
        let (_enc, p) = next_byte(&data, pos)?;
        let (len, p2) = next_byte(&data, p)?;
        pos = p2;
        length = len;
    } else {
        length = flag;
    }

    let (to_skip, p) = next_byte(&data, pos)?;
    pos = p + (to_skip as usize) * 2;

    let mut out: Vec<u8> = Vec::with_capacity(length as usize);
    for _ in 0..length {
        let (byte, p) = next_byte(&data, pos)?;
        pos = p;
        out.push(byte);
    }

    let mut text = String::from_utf8_lossy(&out).to_string();
    if flag == PW_FLAG {
        if text.len() < key.len() {
            return None;
        }
        text = text[key.len()..].to_string();
    }
    Some(text.trim_end_matches('\u{0}').to_string())
}

/// `%D0%9C%D0%BE%D1%8F` -> `Моя`; malformed sequences are kept as-is.
pub fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                out.push(hi * 16 + lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    let decoded = String::from_utf8_lossy(&out).to_string();
    // WinSCP sometimes stores a leading BOM inside the name.
    decoded.trim_start_matches('\u{feff}').to_string()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Parses the `[Sessions\...]` sections of a WinSCP.ini file.
pub fn parse(ini: &str) -> Vec<WinscpSession> {
    let mut sessions = Vec::new();
    let mut current: Option<(String, Vec<(String, String)>)> = None;

    let mut flush = |entry: Option<(String, Vec<(String, String)>)>, out: &mut Vec<WinscpSession>| {
        let Some((section, keys)) = entry else { return };
        let get = |name: &str| {
            keys.iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(name))
                .map(|(_, v)| v.clone())
        };

        let Some(host) = get("HostName") else { return };
        if host.trim().is_empty() {
            return;
        }

        let path = section.trim_start_matches("Sessions").trim_start_matches('\\');
        let path = percent_decode(path);
        let (group, name) = match path.rsplit_once('/') {
            Some((folder, session)) => (Some(folder.to_string()), session.to_string()),
            None => (None, path),
        };

        out.push(WinscpSession {
            name,
            group,
            host: host.trim().to_string(),
            user: get("UserName").unwrap_or_default().trim().to_string(),
            port: get("PortNumber")
                .and_then(|p| p.trim().parse::<u16>().ok())
                .filter(|p| *p > 0)
                .unwrap_or(22),
            password: get("Password").filter(|p| !p.trim().is_empty()),
            remote_dir: get("RemoteDirectory").map(|p| percent_decode(&p)),
            local_dir: get("LocalDirectory").map(|p| percent_decode(&p)),
            key_file: get("PublicKeyFile").filter(|p| !p.trim().is_empty()),
            protocol: get("FSProtocol").and_then(|p| p.trim().parse::<u32>().ok()),
        });
    };

    for raw in ini.lines() {
        let line = raw.trim_end_matches('\r');
        if line.starts_with('[') && line.ends_with(']') {
            flush(current.take(), &mut sessions);
            let name = &line[1..line.len() - 1];
            current = if name.starts_with("Sessions\\") {
                Some((name.to_string(), Vec::new()))
            } else {
                None
            };
            continue;
        }
        if let Some((_, keys)) = current.as_mut() {
            if let Some((k, v)) = line.split_once('=') {
                keys.push((k.trim().to_string(), v.trim().to_string()));
            }
        }
    }
    flush(current.take(), &mut sessions);
    sessions
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
[Configuration]
SessionList=x

[Sessions\demo@example.com]
HostName=example.com
UserName=demo
Password=A35C0000000000000000
PortNumber=50022
RemoteDirectory=/var/www/demo

[Sessions\search/demo-search]
HostName=192.0.2.10
UserName=dev
FSProtocol=2

[Sessions\%D0%9C%D0%BE%D1%8F/search]
HostName=1.2.3.4
UserName=admin
"#;

    #[test]
    fn parses_flat_and_grouped_sessions() {
        let list = parse(SAMPLE);
        assert_eq!(list.len(), 3);

        let flat = &list[0];
        assert_eq!(flat.name, "demo@example.com");
        assert!(flat.group.is_none());
        assert_eq!(flat.port, 50022);
        assert_eq!(flat.remote_dir.as_deref(), Some("/var/www/demo"));
        assert!(flat.password.is_some());

        let grouped = &list[1];
        assert_eq!(grouped.group.as_deref(), Some("search"));
        assert_eq!(grouped.name, "demo-search");
        assert_eq!(grouped.port, 22);

        let encoded = &list[2];
        assert_eq!(encoded.group.as_deref(), Some("Моя"));
        assert_eq!(encoded.name, "search");
    }

    #[test]
    fn decrypts_winscp_passwords() {
        // Synthetic pair: host example.com, user demo, password demo-password-1.
        assert_eq!(
            decrypt_password(
                "example.com",
                "demo",
                "A35D425C3839313339243D312C3039723F333138393133712C3D2F2F2B332E38716D"
            )
            .as_deref(),
            Some("demo-password-1")
        );
    }

    #[test]
    fn decodes_percent_escapes() {
        assert_eq!(percent_decode("D:%5Cwork%5Cdemo"), r"D:\work\demo");
        assert_eq!(percent_decode("%D0%9C%D0%BE%D1%8F"), "Моя");
        assert_eq!(percent_decode("100%"), "100%");
    }
}
