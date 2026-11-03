//! OS-level wrapping of the master key so the user is not prompted on every launch.
//!
//! - Windows: DPAPI (`CryptProtectData`, user scope, no UI).
//! - Android: handled on the Dart side by `flutter_secure_storage` (Keystore);
//!   Rust only reports that it is not available here.

use crate::error::{NovaError, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyWrapSupport {
    /// The OS can wrap the key by itself.
    Available,
    /// The UI layer is responsible for wrapping (Android Keystore).
    DelegatedToUi,
}

pub fn support() -> KeyWrapSupport {
    #[cfg(windows)]
    {
        KeyWrapSupport::Available
    }
    #[cfg(not(windows))]
    {
        KeyWrapSupport::DelegatedToUi
    }
}

#[cfg(windows)]
pub fn wrap_key(key: &[u8]) -> Result<Vec<u8>> {
    dpapi(key, true)
}

#[cfg(windows)]
pub fn unwrap_key(blob: &[u8]) -> Result<Vec<u8>> {
    dpapi(blob, false)
}

#[cfg(windows)]
fn dpapi(input: &[u8], protect: bool) -> Result<Vec<u8>> {
    use windows::core::PCWSTR;
    use windows::Win32::Security::Cryptography::{
        CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    let mut local = input.to_vec();
    let input_blob = CRYPT_INTEGER_BLOB {
        cbData: local.len() as u32,
        pbData: local.as_mut_ptr(),
    };
    let mut out_blob = CRYPT_INTEGER_BLOB::default();
    let flags = CRYPTPROTECT_UI_FORBIDDEN;

    unsafe {
        if protect {
            let descr: Vec<u16> = "NovaSSH master key\0".encode_utf16().collect();
            CryptProtectData(
                &input_blob,
                PCWSTR(descr.as_ptr()),
                None,
                None,
                None,
                flags,
                &mut out_blob,
            )
            .map_err(|e| NovaError::Crypto(format!("DPAPI protect: {e}")))?;
        } else {
            CryptUnprotectData(&input_blob, None, None, None, None, flags, &mut out_blob)
                .map_err(|e| NovaError::Crypto(format!("DPAPI unprotect: {e}")))?;
        }
    }

    let result =
        unsafe { std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize).to_vec() };
    unsafe {
        // The buffer is allocated by crypt32 with LocalAlloc.
        windows::Win32::Foundation::LocalFree(Some(windows::Win32::Foundation::HLOCAL(
            out_blob.pbData as *mut core::ffi::c_void,
        )));
    }
    Ok(result)
}

#[cfg(not(windows))]
pub fn wrap_key(_key: &[u8]) -> Result<Vec<u8>> {
    Err(NovaError::Unsupported(
        "device key wrapping is handled by the platform UI on this target".into(),
    ))
}

#[cfg(not(windows))]
pub fn unwrap_key(_blob: &[u8]) -> Result<Vec<u8>> {
    Err(NovaError::Unsupported(
        "device key wrapping is handled by the platform UI on this target".into(),
    ))
}
