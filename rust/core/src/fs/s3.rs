//! S3-compatible storage (AWS, MinIO, Selectel, Yandex, cloud.ru, any gateway).
//!
//! Uses the official `aws-sdk-s3` client: it signs requests correctly for any
//! region, honours a custom endpoint and path-style addressing, and reports the
//! real service error instead of a parser failure.

use aws_sdk_s3::error::ProvideErrorMetadata;

use crate::error::{NovaError, Result};
use crate::model::{DirListing, Entry, EntryKind};
use crate::util;

pub struct S3Fs {
    client: aws_sdk_s3::Client,
    bucket: String,
    /// Prefix shown as the root ("" for the bucket root).
    pub prefix: String,
}

impl S3Fs {
    pub fn new(
        endpoint: &str,
        region: &str,
        bucket_name: &str,
        access_key: &str,
        secret_key: &str,
        path_style: bool,
        prefix: &str,
    ) -> Result<Self> {
        use aws_sdk_s3::config::{BehaviorVersion, Credentials, Region};

        let region = if region.trim().is_empty() {
            "us-east-1".to_string()
        } else {
            region.trim().to_string()
        };

        let credentials = Credentials::new(access_key, secret_key, None, None, "novassh");
        let config = aws_sdk_s3::Config::builder()
            .behavior_version(BehaviorVersion::latest())
            .region(Region::new(region))
            .endpoint_url(endpoint.trim().trim_end_matches('/'))
            .credentials_provider(credentials)
            .force_path_style(path_style)
            .build();

        Ok(Self {
            client: aws_sdk_s3::Client::from_conf(config),
            bucket: bucket_name.trim().to_string(),
            prefix: prefix.trim_matches('/').to_string(),
        })
    }

    fn full(&self, path: &str) -> String {
        let clean = path.trim_matches('/');
        match (self.prefix.is_empty(), clean.is_empty()) {
            (true, _) => clean.to_string(),
            (false, true) => format!("{}/", self.prefix),
            (false, false) => format!("{}/{}", self.prefix, clean),
        }
    }

    fn relative(&self, key: &str) -> String {
        if self.prefix.is_empty() {
            key.to_string()
        } else {
            key.strip_prefix(&format!("{}/", self.prefix))
                .unwrap_or(key)
                .to_string()
        }
    }

    pub async fn list(&self, path: &str, show_hidden: bool) -> Result<DirListing> {
        let dir = path.trim_matches('/').to_string();
        let prefix = if dir.is_empty() {
            self.full("")
        } else {
            format!("{}/", self.full(&dir))
        };

        let mut entries: Vec<Entry> = Vec::new();
        let mut seen_dirs: std::collections::HashSet<String> = Default::default();
        // S3 returns at most 1000 keys per page: without the continuation token
        // large folders silently lose everything after the first page.
        let mut token: Option<String> = None;
        loop {
            let mut request = self
                .client
                .list_objects_v2()
                .bucket(&self.bucket)
                .prefix(&prefix)
                .delimiter("/");
            if let Some(t) = &token {
                request = request.continuation_token(t);
            }
            let response = request
                .send()
                .await
                .map_err(|e| NovaError::S3(format!("list: {}", sdk_message(&e))))?;

            for common in response.common_prefixes() {
                let Some(full_prefix) = common.prefix() else {
                    continue;
                };
                let name = full_prefix
                    .trim_end_matches('/')
                    .rsplit('/')
                    .next()
                    .unwrap_or_default()
                    .to_string();
                if name.is_empty() {
                    continue;
                }
                let path = self.relative(full_prefix.trim_end_matches('/'));
                if !seen_dirs.insert(path.clone()) {
                    continue;
                }
                entries.push(Entry {
                    path,
                    name,
                    kind: EntryKind::Dir,
                    size: 0,
                    modified: None,
                    mode: None,
                    uid: None,
                    gid: None,
                    hidden: util::is_probably_hidden(full_prefix),
                    link_target: None,
                });
            }

            for object in response.contents() {
                let Some(key) = object.key() else { continue };
                let name = key.rsplit('/').next().unwrap_or_default().to_string();
                if name.is_empty() || key.ends_with('/') {
                    continue;
                }
                let hidden = util::is_probably_hidden(&name);
                if hidden && !show_hidden {
                    continue;
                }
                entries.push(Entry {
                    path: self.relative(key),
                    name,
                    kind: EntryKind::File,
                    size: object.size().unwrap_or(0).max(0) as u64,
                    modified: object.last_modified().map(|t| t.secs() * 1000),
                    mode: None,
                    uid: None,
                    gid: None,
                    hidden,
                    link_target: None,
                });
            }

            if response.is_truncated().unwrap_or(false) {
                token = response.next_continuation_token().map(str::to_string);
                if token.is_none() {
                    break;
                }
            } else {
                break;
            }
        }

        Ok(DirListing {
            path: if dir.is_empty() {
                "/".to_string()
            } else {
                format!("/{dir}")
            },
            parent: if dir.is_empty() {
                None
            } else {
                util::parent(&format!("/{dir}"))
            },
            entries,
            free_space: None,
            total_space: None,
        })
    }

    pub async fn stat(&self, path: &str) -> Result<Entry> {
        let key = self.full(path);
        let name = util::file_name(path).to_string();
        if let Ok(head) = self
            .client
            .head_object()
            .bucket(&self.bucket)
            .key(&key)
            .send()
            .await
        {
            return Ok(Entry {
                name,
                path: path.to_string(),
                kind: EntryKind::File,
                size: head.content_length().unwrap_or(0).max(0) as u64,
                modified: head.last_modified().map(|t| t.secs() * 1000),
                mode: None,
                uid: None,
                gid: None,
                hidden: util::is_probably_hidden(&util::file_name(path)),
                link_target: None,
            });
        }

        // A "folder" in S3 is only a prefix: it has no object of its own, so a
        // HEAD fails. Probe it, otherwise copying a folder out of a bucket
        // looks like a missing file.
        let response = self
            .client
            .list_objects_v2()
            .bucket(&self.bucket)
            .prefix(format!("{key}/"))
            .max_keys(1)
            .send()
            .await
            .map_err(|e| NovaError::S3(format!("stat: {}", sdk_message(&e))))?;
        if !response.contents().is_empty() || !response.common_prefixes().is_empty() {
            return Ok(Entry {
                name,
                path: path.to_string(),
                kind: EntryKind::Dir,
                size: 0,
                modified: None,
                mode: None,
                uid: None,
                gid: None,
                hidden: util::is_probably_hidden(&util::file_name(path)),
                link_target: None,
            });
        }
        Err(NovaError::NotFound(format!(
            "{path} not found in the bucket"
        )))
    }

    pub async fn read_all(&self, path: &str) -> Result<Vec<u8>> {
        let key = self.full(path);
        let object = self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(&key)
            .send()
            .await
            .map_err(|e| NovaError::S3(format!("get: {}", sdk_message(&e))))?;
        let data = object
            .body
            .collect()
            .await
            .map_err(|e| NovaError::S3(format!("read body: {e}")))?;
        Ok(data.into_bytes().to_vec())
    }

    pub async fn write_all(&self, path: &str, bytes: &[u8]) -> Result<()> {
        let key = self.full(path);
        self.client
            .put_object()
            .bucket(&self.bucket)
            .key(&key)
            .body(aws_sdk_s3::primitives::ByteStream::from(bytes.to_vec()))
            .send()
            .await
            .map_err(|e| NovaError::S3(format!("put: {}", sdk_message(&e))))?;
        Ok(())
    }

    pub async fn mkdir(&self, path: &str) -> Result<()> {
        let key = format!("{}/", self.full(path));
        self.client
            .put_object()
            .bucket(&self.bucket)
            .key(&key)
            .body(aws_sdk_s3::primitives::ByteStream::from(Vec::new()))
            .send()
            .await
            .map_err(|e| NovaError::S3(format!("mkdir: {}", sdk_message(&e))))?;
        Ok(())
    }

    pub async fn remove(&self, path: &str, is_dir: bool) -> Result<()> {
        if is_dir {
            let prefix = format!("{}/", self.full(path));
            let mut token: Option<String> = None;
            loop {
                let mut request = self
                    .client
                    .list_objects_v2()
                    .bucket(&self.bucket)
                    .prefix(&prefix);
                if let Some(t) = &token {
                    request = request.continuation_token(t);
                }
                let response = request
                    .send()
                    .await
                    .map_err(|e| NovaError::S3(format!("list: {}", sdk_message(&e))))?;

                for object in response.contents() {
                    if let Some(key) = object.key() {
                        self.client
                            .delete_object()
                            .bucket(&self.bucket)
                            .key(key)
                            .send()
                            .await
                            .map_err(|e| {
                                NovaError::S3(format!("delete: {}", sdk_message(&e)))
                            })?;
                    }
                }
                if response.is_truncated().unwrap_or(false) {
                    token = response.next_continuation_token().map(|t| t.to_string());
                } else {
                    break;
                }
            }
            Ok(())
        } else {
            self.client
                .delete_object()
                .bucket(&self.bucket)
                .key(self.full(path))
                .send()
                .await
                .map_err(|e| NovaError::S3(format!("delete: {}", sdk_message(&e))))?;
            Ok(())
        }
    }

    pub async fn rename(&self, from: &str, to: &str) -> Result<()> {
        let from_key = self.full(from);
        let to_key = self.full(to);

        // A prefix ("folder") is moved object by object; a single key is just
        // copied. `copy_source` must be URL-encoded, otherwise keys with a
        // space or a non-ASCII byte make S3 reject the copy.
        let mut moved = 0u32;
        let mut token: Option<String> = None;
        loop {
            let mut request = self
                .client
                .list_objects_v2()
                .bucket(&self.bucket)
                .prefix(format!("{from_key}/"));
            if let Some(t) = &token {
                request = request.continuation_token(t);
            }
            let response = request
                .send()
                .await
                .map_err(|e| NovaError::S3(format!("rename list: {}", sdk_message(&e))))?;

            for object in response.contents() {
                let Some(key) = object.key() else { continue };
                let suffix = key.strip_prefix(&from_key).unwrap_or(key);
                let target = format!("{to_key}{suffix}");
                self.client
                    .copy_object()
                    .bucket(&self.bucket)
                    .key(&target)
                    .copy_source(copy_source(&self.bucket, key))
                    .send()
                    .await
                    .map_err(|e| NovaError::S3(format!("copy: {}", sdk_message(&e))))?;
                self.client
                    .delete_object()
                    .bucket(&self.bucket)
                    .key(key)
                    .send()
                    .await
                    .map_err(|e| NovaError::S3(format!("rename delete: {}", sdk_message(&e))))?;
                moved += 1;
            }

            if response.is_truncated().unwrap_or(false) {
                token = response.next_continuation_token().map(str::to_string);
                if token.is_none() {
                    break;
                }
            } else {
                break;
            }
        }

        if moved > 0 {
            return Ok(());
        }

        self.client
            .copy_object()
            .bucket(&self.bucket)
            .key(&to_key)
            .copy_source(copy_source(&self.bucket, &from_key))
            .send()
            .await
            .map_err(|e| NovaError::S3(format!("copy: {}", sdk_message(&e))))?;
        self.remove(from, false).await
    }
}

/// `bucket/key` with every path segment percent-encoded, as S3 expects it in
/// `x-amz-copy-source`. `/` stays a separator.
fn copy_source(bucket: &str, key: &str) -> String {
    fn enc(segment: &str) -> String {
        let mut out = String::with_capacity(segment.len());
        for byte in segment.bytes() {
            let keep = byte.is_ascii_alphanumeric()
                || matches!(byte, b'-' | b'_' | b'.' | b'~' | b'!');
            if keep {
                out.push(byte as char);
            } else {
                out.push_str(&format!("%{byte:02X}"));
            }
        }
        out
    }

    let mut source = enc(bucket);
    source.push('/');
    for (index, part) in key.split('/').enumerate() {
        if index > 0 {
            source.push('/');
        }
        source.push_str(&enc(part));
    }
    source
}

/// The SDK hides the service message inside the raw response; surface it.
fn sdk_message<E: std::fmt::Debug + ProvideErrorMetadata>(error: &E) -> String {
    match error.message() {
        Some(message) => format!("{}: {message}", error.code().unwrap_or("S3 error")),
        None => format!("{error:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::copy_source;

    #[test]
    fn copy_source_encodes_unsafe_bytes_but_keeps_separators() {
        assert_eq!(copy_source("bucket", "a.txt"), "bucket/a.txt");
        assert_eq!(
            copy_source("bucket", "dir/sub/file name.txt"),
            "bucket/dir/sub/file%20name.txt"
        );
        assert_eq!(copy_source("my bucket", "x"), "my%20bucket/x");
        assert_eq!(copy_source("b", "a+b#c%"), "b/a%2Bb%23c%25");
        // Non-ASCII is encoded byte by byte (UTF-8), never left raw.
        assert_eq!(copy_source("b", "фото.png"), "b/%D1%84%D0%BE%D1%82%D0%BE.png");
    }
}
