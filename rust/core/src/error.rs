use thiserror::Error;

pub type Result<T, E = NovaError> = std::result::Result<T, E>;

#[derive(Debug, Error)]
pub enum NovaError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),

    #[error("json: {0}")]
    Json(#[from] serde_json::Error),

    #[error("ssh: {0}")]
    Ssh(String),

    #[error("sftp: {0}")]
    Sftp(String),

    #[error("s3: {0}")]
    S3(String),

    #[error("crypto: {0}")]
    Crypto(String),

    #[error("master password is required")]
    Locked,

    #[error("not found: {0}")]
    NotFound(String),

    #[error("invalid input: {0}")]
    Invalid(String),

    #[error("unsupported: {0}")]
    Unsupported(String),
}

impl NovaError {
    pub fn invalid(msg: impl Into<String>) -> Self {
        Self::Invalid(msg.into())
    }
}

impl From<russh::Error> for NovaError {
    fn from(e: russh::Error) -> Self {
        Self::Ssh(e.to_string())
    }
}

impl From<russh_sftp::client::error::Error> for NovaError {
    fn from(e: russh_sftp::client::error::Error) -> Self {
        Self::Sftp(e.to_string())
    }
}

/// Convert into a flat string for the FFI boundary (and for user-facing toasts).
impl From<NovaError> for String {
    fn from(e: NovaError) -> Self {
        e.to_string()
    }
}
