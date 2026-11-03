//! Reversible secret storage.
//!
//! Master password -> Argon2id -> 32-byte key -> AES-256-GCM per secret.
//! The key itself may be wrapped by the OS keystore (DPAPI on Windows,
//! Android Keystore on the mobile side) so the user is not asked every launch.

mod keywrap;

pub use keywrap::{support, unwrap_key, wrap_key, KeyWrapSupport};

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::error::{NovaError, Result};

pub const KEY_LEN: usize = 32;
const NONCE_LEN: usize = 12;
const VERIFIER_PLAINTEXT: &[u8] = b"novassh-verifier-v1";

pub type MasterKey = Zeroizing<[u8; KEY_LEN]>;

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KdfParams {
    /// Memory cost in KiB.
    pub mem_kib: u32,
    pub iterations: u32,
    pub parallelism: u32,
}

impl Default for KdfParams {
    fn default() -> Self {
        Self {
            mem_kib: 64 * 1024,
            iterations: 3,
            parallelism: 4,
        }
    }
}

impl KdfParams {
    /// Lower memory footprint for low-end Android devices.
    pub fn mobile() -> Self {
        Self {
            mem_kib: 32 * 1024,
            ..Self::default()
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sealed {
    pub v: u32,
    pub alg: String,
    pub nonce: String,
    pub ct: String,
}

impl Sealed {
    fn from_parts(nonce: [u8; NONCE_LEN], ct: Vec<u8>) -> Self {
        Self {
            v: 1,
            alg: "A256GCM".into(),
            nonce: B64.encode(nonce),
            ct: B64.encode(ct),
        }
    }
}

/// Random salt for a new password-protected file (16 bytes).
pub fn random_salt() -> [u8; 16] {
    let mut salt = [0u8; 16];
    rand::rng().fill_bytes(&mut salt);
    salt
}

/// A fresh 32-byte key for the device-wrapped vault (Windows has no password).
pub fn random_key() -> MasterKey {
    let mut key = Zeroizing::new([0u8; KEY_LEN]);
    rand::rng().fill_bytes(key.as_mut());
    key
}

pub fn derive_key(password: &str, salt: &[u8], params: &KdfParams) -> Result<MasterKey> {
    if salt.len() < 8 {
        return Err(NovaError::Crypto("salt too short".into()));
    }
    if password.is_empty() {
        return Err(NovaError::Crypto("empty master password".into()));
    }
    let p = Params::new(
        params.mem_kib,
        params.iterations,
        params.parallelism,
        Some(KEY_LEN),
    )
    .map_err(|e| NovaError::Crypto(format!("kdf params: {e}")))?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, p);
    let mut key = Zeroizing::new([0u8; KEY_LEN]);
    argon
        .hash_password_into(password.as_bytes(), salt, key.as_mut())
        .map_err(|e| NovaError::Crypto(format!("kdf: {e}")))?;
    Ok(key)
}

pub fn seal(key: &[u8], aad: &[u8], plaintext: &[u8]) -> Result<Sealed> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|e| NovaError::Crypto(e.to_string()))?;
    let mut nonce = [0u8; NONCE_LEN];
    rand::rng().fill_bytes(&mut nonce);
    let ct = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| NovaError::Crypto("encrypt failed".into()))?;
    Ok(Sealed::from_parts(nonce, ct))
}

pub fn open(key: &[u8], aad: &[u8], sealed: &Sealed) -> Result<Zeroizing<Vec<u8>>> {
    if sealed.alg != "A256GCM" {
        return Err(NovaError::Crypto(format!("unknown alg {}", sealed.alg)));
    }
    let nonce = B64
        .decode(&sealed.nonce)
        .map_err(|e| NovaError::Crypto(format!("nonce: {e}")))?;
    if nonce.len() != NONCE_LEN {
        return Err(NovaError::Crypto("bad nonce length".into()));
    }
    let ct = B64
        .decode(&sealed.ct)
        .map_err(|e| NovaError::Crypto(format!("ciphertext: {e}")))?;
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|e| NovaError::Crypto(e.to_string()))?;
    let pt = cipher
        .decrypt(Nonce::from_slice(&nonce), Payload { msg: &ct, aad })
        .map_err(|_| NovaError::Crypto("decrypt failed (wrong password?)".into()))?;
    Ok(Zeroizing::new(pt))
}

/// On-disk secrets file. Server entries only hold references (`sec_xxx`).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecretFile {
    pub version: u32,
    pub kdf: KdfParams,
    pub salt: String,
    pub verifier: Sealed,
    #[serde(default)]
    pub items: BTreeMap<String, Sealed>,
}

impl SecretFile {
    pub fn create(path: &Path, password: &str, params: KdfParams) -> Result<Unlocked> {
        let mut salt = [0u8; 16];
        rand::rng().fill_bytes(&mut salt);
        let key = derive_key(password, &salt, &params)?;
        let verifier = seal(key.as_ref(), b"verifier", VERIFIER_PLAINTEXT)?;
        let file = SecretFile {
            version: 1,
            kdf: params,
            salt: B64.encode(salt),
            verifier,
            items: BTreeMap::new(),
        };
        let mut unlocked = Unlocked {
            key,
            file,
            path: path.to_path_buf(),
            dirty: true,
        };
        unlocked.save()?;
        Ok(unlocked)
    }

    /// Creates a vault protected by a device-wrapped key instead of a password.
    ///
    /// Version 2 marks such a file: the KDF fields are unused, the key comes
    /// from `keywrap.bin` (DPAPI on Windows).
    pub fn create_with_key(path: &Path, key: &MasterKey) -> Result<Unlocked> {
        let mut salt = [0u8; 16];
        rand::rng().fill_bytes(&mut salt);
        let verifier = seal(key.as_ref(), b"verifier", VERIFIER_PLAINTEXT)?;
        let file = SecretFile {
            version: 2,
            kdf: KdfParams::default(),
            salt: B64.encode(salt),
            verifier,
            items: BTreeMap::new(),
        };
        Ok(Unlocked {
            key: Zeroizing::new(<[u8; KEY_LEN]>::try_from(key.as_ref()).map_err(|_| NovaError::Crypto("bad key length".into()))?),
            file,
            path: path.to_path_buf(),
            dirty: true,
        })
    }

    pub fn unlock(path: &Path, password: &str) -> Result<Unlocked> {
        let raw = std::fs::read(path)?;
        let file: SecretFile = serde_json::from_slice(&raw)?;
        let salt = B64
            .decode(&file.salt)
            .map_err(|e| NovaError::Crypto(format!("salt: {e}")))?;
        let key = derive_key(password, &salt, &file.kdf)?;
        let ok = open(key.as_ref(), b"verifier", &file.verifier)?;
        if ok.as_slice() != VERIFIER_PLAINTEXT {
            return Err(NovaError::Crypto("verifier mismatch".into()));
        }
        Ok(Unlocked {
            key,
            file,
            path: path.to_path_buf(),
            dirty: false,
        })
    }

    /// Re-encrypt every secret with a new master password (used on export).
    pub fn reencrypt(
        &self,
        old_key: &[u8],
        new_password: &str,
        params: KdfParams,
    ) -> Result<SecretFile> {
        let mut salt = [0u8; 16];
        rand::rng().fill_bytes(&mut salt);
        let new_key = derive_key(new_password, &salt, &params)?;
        let mut items = BTreeMap::new();
        for (id, sealed) in &self.items {
            let plain = open(old_key, id.as_bytes(), sealed)?;
            items.insert(id.clone(), seal(new_key.as_ref(), id.as_bytes(), &plain)?);
        }
        Ok(SecretFile {
            version: 1,
            kdf: params,
            salt: B64.encode(salt),
            verifier: seal(new_key.as_ref(), b"verifier", VERIFIER_PLAINTEXT)?,
            items,
        })
    }
}

/// Unlocked vault: holds the master key in memory only.
pub struct Unlocked {
    key: MasterKey,
    file: SecretFile,
    path: PathBuf,
    dirty: bool,
}

impl Unlocked {
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn get(&self, id: &str) -> Result<Option<String>> {
        match self.file.items.get(id) {
            None => Ok(None),
            Some(sealed) => {
                let pt = open(self.key.as_ref(), id.as_bytes(), sealed)?;
                let s = String::from_utf8(pt.to_vec())
                    .map_err(|_| NovaError::Crypto("secret is not utf-8".into()))?;
                Ok(Some(s))
            }
        }
    }

    pub fn set(&mut self, id: &str, value: &str) -> Result<()> {
        let sealed = seal(self.key.as_ref(), id.as_bytes(), value.as_bytes())?;
        self.file.items.insert(id.to_string(), sealed);
        self.dirty = true;
        Ok(())
    }

    pub fn remove(&mut self, id: &str) {
        if self.file.items.remove(id).is_some() {
            self.dirty = true;
        }
    }

    /// Re-encrypts every secret with a new password (master password <-> PIN)
    /// and writes the file back. The KDF parameters stay the same.
    pub fn rekey(&mut self, new_password: &str) -> Result<()> {
        let params = self.file.kdf;
        let new_file = self.file.reencrypt(self.key.as_ref(), new_password, params)?;
        let salt = B64
            .decode(&new_file.salt)
            .map_err(|e| NovaError::Crypto(format!("salt: {e}")))?;
        self.key = derive_key(new_password, &salt, &params)?;
        self.file = new_file;
        self.dirty = true;
        self.save()
    }

    /// True for a vault that is protected by the device key (no password).
    pub fn is_device_key(&self) -> bool {
        self.file.version >= 2
    }

    /// Re-encrypts every secret with `new_key` (used when a password-protected
    /// vault is moved to the device key on Windows). The KDF fields stay as a
    /// placeholder.
    pub fn rekey_to_device_key(&mut self, new_key: &MasterKey) -> Result<()> {
        let mut items = BTreeMap::new();
        for (id, sealed) in &self.file.items {
            let plain = open(self.key.as_ref(), id.as_bytes(), sealed)?;
            items.insert(id.clone(), seal(new_key.as_ref(), id.as_bytes(), &plain)?);
        }
        let mut salt = [0u8; 16];
        rand::rng().fill_bytes(&mut salt);
        self.file = SecretFile {
            version: 2,
            kdf: KdfParams::default(),
            salt: B64.encode(salt),
            verifier: seal(new_key.as_ref(), b"verifier", VERIFIER_PLAINTEXT)?,
            items,
        };
        self.key = Zeroizing::new(<[u8; KEY_LEN]>::try_from(new_key.as_ref()).map_err(|_| NovaError::Crypto("bad key length".into()))?);
        self.dirty = true;
        Ok(())
    }

    pub fn has(&self, id: &str) -> bool {
        self.file.items.contains_key(id)
    }

    pub fn save(&mut self) -> Result<()> {
        crate::store::save_json(&self.path, &self.file)?;
        self.dirty = false;
        Ok(())
    }

    pub fn save_if_dirty(&mut self) -> Result<()> {
        if self.dirty {
            self.save()?;
        }
        Ok(())
    }

    /// Wrap the master key for the current OS keystore and persist the blob.
    pub fn remember(&self, target: &Path) -> Result<()> {
        let wrapped = wrap_key(self.key.as_ref())?;
        crate::store::save_bytes(target, &wrapped)
    }

    pub fn forget(target: &Path) -> Result<()> {
        if target.exists() {
            std::fs::remove_file(target)?;
        }
        Ok(())
    }
}

/// Try to unlock using the device-wrapped key. Returns `None` when unavailable.
pub fn unlock_with_remembered(path: &Path, target: &Path) -> Result<Option<Unlocked>> {
    if !target.exists() {
        return Ok(None);
    }
    let wrapped = std::fs::read(target)?;
    let key = unwrap_key(&wrapped)?;
    let raw = std::fs::read(path)?;
    let file: SecretFile = serde_json::from_slice(&raw)?;
    let ok = open(&key, b"verifier", &file.verifier)?;
    if ok.as_slice() != VERIFIER_PLAINTEXT {
        return Err(NovaError::Crypto("verifier mismatch".into()));
    }
    let key: [u8; KEY_LEN] = key
        .as_slice()
        .try_into()
        .map_err(|_| NovaError::Crypto("bad key length".into()))?;
    Ok(Some(Unlocked {
        key: Zeroizing::new(key),
        file,
        path: path.to_path_buf(),
        dirty: false,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_open_roundtrip_and_wrong_key() {
        let key = [7u8; KEY_LEN];
        let sealed = seal(&key, b"aad", b"secret value").unwrap();
        let pt = open(&key, b"aad", &sealed).unwrap();
        assert_eq!(pt.as_slice(), b"secret value");

        // Different AAD must fail.
        assert!(open(&key, b"other", &sealed).is_err());
        // Different key must fail.
        assert!(open(&[9u8; KEY_LEN], b"aad", &sealed).is_err());
    }

    #[test]
    fn secrets_file_lifecycle() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("secrets.json");
        let params = KdfParams {
            mem_kib: 8 * 1024,
            iterations: 1,
            parallelism: 1,
        };

        let mut vault = SecretFile::create(&path, "master-pass", params).unwrap();
        vault.set("sec_1", "hunter2").unwrap();
        vault.set("sec_2", "keypass").unwrap();
        vault.save().unwrap();

        let unlocked = SecretFile::unlock(&path, "master-pass").unwrap();
        assert_eq!(unlocked.get("sec_1").unwrap().as_deref(), Some("hunter2"));
        assert_eq!(unlocked.get("sec_2").unwrap().as_deref(), Some("keypass"));
        assert!(unlocked.get("missing").unwrap().is_none());

        // Wrong password must not unlock.
        assert!(SecretFile::unlock(&path, "nope").is_err());

        // Ciphertext on disk must not contain plaintext.
        let raw = std::fs::read_to_string(&path).unwrap();
        assert!(!raw.contains("hunter2"));
    }

    #[test]
    fn password_vault_can_move_to_a_device_key() {
        let params = KdfParams {
            mem_kib: 8 * 1024,
            iterations: 1,
            parallelism: 1,
        };
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("secrets.json");

        let mut vault = SecretFile::create(&path, "master-pass", params).unwrap();
        vault.set("sec_1", "hunter2").unwrap();
        vault.save().unwrap();

        let mut unlocked = SecretFile::unlock(&path, "master-pass").unwrap();
        let key = random_key();
        unlocked.rekey_to_device_key(&key).unwrap();
        // The caller writes the wrapped key first, then the re-encrypted file.
        unlocked.save().unwrap();
        assert!(unlocked.is_device_key());
        assert_eq!(unlocked.get("sec_1").unwrap().as_deref(), Some("hunter2"));

        // The file now opens with the device key and no password at all.
        let raw = std::fs::read(&path).unwrap();
        let file: SecretFile = serde_json::from_slice(&raw).unwrap();
        assert_eq!(file.version, 2);
        let verifier = open(key.as_ref(), b"verifier", &file.verifier).unwrap();
        assert_eq!(verifier.as_slice(), VERIFIER_PLAINTEXT);
        let sealed = file.items.get("sec_1").unwrap();
        let plain = open(key.as_ref(), b"sec_1", sealed).unwrap();
        assert_eq!(plain.as_slice(), b"hunter2");
        assert!(!String::from_utf8_lossy(&raw).contains("hunter2"));
    }

    #[test]
    fn reencrypt_preserves_values() {
        let params = KdfParams {
            mem_kib: 8 * 1024,
            iterations: 1,
            parallelism: 1,
        };
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("secrets.json");
        let mut vault = SecretFile::create(&path, "old", params).unwrap();
        vault.set("sec_1", "value").unwrap();
        vault.save().unwrap();

        let unlocked = SecretFile::unlock(&path, "old").unwrap();
        let new_file = unlocked
            .file
            .reencrypt(unlocked.key.as_ref(), "new", params)
            .unwrap();

        crate::store::save_json(&path, &new_file).unwrap();
        let reopened = SecretFile::unlock(&path, "new").unwrap();
        assert_eq!(reopened.get("sec_1").unwrap().as_deref(), Some("value"));
        assert!(SecretFile::unlock(&path, "old").is_err());
    }
}
