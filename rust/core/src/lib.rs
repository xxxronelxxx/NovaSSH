//! NovaSSH core — filesystem providers, SFTP, storage and crypto.
//!
//! The crate is UI-agnostic: it is consumed by the Flutter bridge (`nova-api`)
//! and can be exercised directly from Rust tests.

#![allow(unexpected_cfgs)] // `frb(init)` expands to `cfg(frb_expand)`

pub mod api;
pub mod archive;
pub mod crypto;
pub mod diff;
pub mod error;
pub mod fs;
pub mod model;
pub mod ssh;
pub mod store;
pub mod sync;
pub mod task;
pub mod util;
pub mod winscp;

pub use error::{NovaError, Result};

mod frb_generated;
