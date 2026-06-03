use std::fmt::Write;

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::{redact_payload_text, redact_payload_value};

pub const DEFAULT_PAYLOAD_POLICY_PREVIEW_MAX_BYTES: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PayloadPolicy {
    MetadataOnly,
    Hash,
    Redacted,
    Full,
    Sampled,
}

impl PayloadPolicy {
    pub fn parse(value: &str) -> Option<Self> {
        match normalize_policy_name(value).as_str() {
            "metadata_only" | "metadata" => Some(Self::MetadataOnly),
            "hash" | "hash_only" => Some(Self::Hash),
            "redacted" | "redact" => Some(Self::Redacted),
            "full" => Some(Self::Full),
            "sampled" | "sample" => Some(Self::Sampled),
            _ => None,
        }
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::MetadataOnly => "metadata_only",
            Self::Hash => "hash",
            Self::Redacted => "redacted",
            Self::Full => "full",
            Self::Sampled => "sampled",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PayloadStorageMode {
    MetadataOnly,
    Hash,
    Redacted,
    Full,
}

impl PayloadStorageMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::MetadataOnly => "metadata_only",
            Self::Hash => "hash",
            Self::Redacted => "redacted",
            Self::Full => "full",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PayloadPolicyOptions {
    pub sampled_in: bool,
    pub redacted_preview_max_bytes: usize,
}

impl Default for PayloadPolicyOptions {
    fn default() -> Self {
        Self {
            sampled_in: false,
            redacted_preview_max_bytes: DEFAULT_PAYLOAD_POLICY_PREVIEW_MAX_BYTES,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub enum PayloadPolicyInput<'a> {
    Bytes(&'a [u8]),
    Json(&'a Value),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PayloadPolicyDecision {
    pub requested_policy: String,
    pub effective_policy: PayloadPolicy,
    pub policy_was_recognized: bool,
    pub storage_mode: PayloadStorageMode,
    pub payload_len_bytes: usize,
    pub hash_sha256: Option<String>,
    pub redacted_preview: Option<String>,
    pub full_payload: Option<Vec<u8>>,
}

pub fn apply_payload_policy(policy: &str, payload: &[u8]) -> PayloadPolicyDecision {
    apply_payload_policy_with_options(
        policy,
        PayloadPolicyInput::Bytes(payload),
        PayloadPolicyOptions::default(),
    )
}

pub fn apply_payload_policy_to_json(policy: &str, payload: &Value) -> PayloadPolicyDecision {
    apply_payload_policy_with_options(
        policy,
        PayloadPolicyInput::Json(payload),
        PayloadPolicyOptions::default(),
    )
}

pub fn apply_payload_policy_with_options(
    policy: &str,
    payload: PayloadPolicyInput<'_>,
    options: PayloadPolicyOptions,
) -> PayloadPolicyDecision {
    let requested_policy = policy.trim().to_string();
    let (effective_policy, policy_was_recognized) = match PayloadPolicy::parse(policy) {
        Some(policy) => (policy, true),
        None => (PayloadPolicy::Hash, false),
    };
    let payload_bytes = payload_bytes(&payload);
    let hash_sha256 = payload_hash_for_policy(effective_policy, &payload_bytes);

    match effective_policy {
        PayloadPolicy::MetadataOnly => PayloadPolicyDecision {
            requested_policy,
            effective_policy,
            policy_was_recognized,
            storage_mode: PayloadStorageMode::MetadataOnly,
            payload_len_bytes: payload_bytes.len(),
            hash_sha256,
            redacted_preview: None,
            full_payload: None,
        },
        PayloadPolicy::Hash => PayloadPolicyDecision {
            requested_policy,
            effective_policy,
            policy_was_recognized,
            storage_mode: PayloadStorageMode::Hash,
            payload_len_bytes: payload_bytes.len(),
            hash_sha256,
            redacted_preview: None,
            full_payload: None,
        },
        PayloadPolicy::Redacted => PayloadPolicyDecision {
            requested_policy,
            effective_policy,
            policy_was_recognized,
            storage_mode: PayloadStorageMode::Redacted,
            payload_len_bytes: payload_bytes.len(),
            hash_sha256,
            redacted_preview: Some(redacted_payload_preview(&payload, options)),
            full_payload: None,
        },
        PayloadPolicy::Full => PayloadPolicyDecision {
            requested_policy,
            effective_policy,
            policy_was_recognized,
            storage_mode: PayloadStorageMode::Full,
            payload_len_bytes: payload_bytes.len(),
            hash_sha256,
            redacted_preview: None,
            full_payload: Some(payload_bytes),
        },
        PayloadPolicy::Sampled if options.sampled_in => PayloadPolicyDecision {
            requested_policy,
            effective_policy,
            policy_was_recognized,
            storage_mode: PayloadStorageMode::Redacted,
            payload_len_bytes: payload_bytes.len(),
            hash_sha256,
            redacted_preview: Some(redacted_payload_preview(&payload, options)),
            full_payload: None,
        },
        PayloadPolicy::Sampled => PayloadPolicyDecision {
            requested_policy,
            effective_policy,
            policy_was_recognized,
            storage_mode: PayloadStorageMode::Hash,
            payload_len_bytes: payload_bytes.len(),
            hash_sha256,
            redacted_preview: None,
            full_payload: None,
        },
    }
}

pub fn payload_sha256_hex(payload: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(payload);
    let digest = hasher.finalize();
    let mut output = String::with_capacity(digest.len() * 2);

    for byte in digest {
        let _ = write!(output, "{byte:02x}");
    }

    output
}

fn payload_hash_for_policy(policy: PayloadPolicy, payload: &[u8]) -> Option<String> {
    match policy {
        PayloadPolicy::MetadataOnly => None,
        PayloadPolicy::Hash
        | PayloadPolicy::Redacted
        | PayloadPolicy::Full
        | PayloadPolicy::Sampled => Some(payload_sha256_hex(payload)),
    }
}

fn redacted_payload_preview(
    payload: &PayloadPolicyInput<'_>,
    options: PayloadPolicyOptions,
) -> String {
    let redacted = match payload {
        PayloadPolicyInput::Bytes(bytes) => redact_payload_text(&String::from_utf8_lossy(bytes)),
        PayloadPolicyInput::Json(value) => redact_payload_value(value).to_string(),
    };

    truncate_to_byte_len(&redacted, options.redacted_preview_max_bytes)
}

fn payload_bytes(payload: &PayloadPolicyInput<'_>) -> Vec<u8> {
    match payload {
        PayloadPolicyInput::Bytes(bytes) => bytes.to_vec(),
        PayloadPolicyInput::Json(value) => value.to_string().into_bytes(),
    }
}

fn normalize_policy_name(value: &str) -> String {
    value
        .trim()
        .chars()
        .map(|character| {
            if matches!(character, '-' | ' ') {
                '_'
            } else {
                character.to_ascii_lowercase()
            }
        })
        .collect()
}

fn truncate_to_byte_len(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_string();
    }

    let mut end = max_bytes.min(value.len());
    while !value.is_char_boundary(end) {
        end -= 1;
    }

    value[..end].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn payload_policy_metadata_only_stores_no_payload_material() {
        let decision = apply_payload_policy("metadata_only", br#"{"prompt":"hello"}"#);

        assert_eq!(decision.effective_policy, PayloadPolicy::MetadataOnly);
        assert_eq!(decision.storage_mode, PayloadStorageMode::MetadataOnly);
        assert!(decision.policy_was_recognized);
        assert_eq!(decision.payload_len_bytes, br#"{"prompt":"hello"}"#.len());
        assert!(decision.hash_sha256.is_none());
        assert!(decision.redacted_preview.is_none());
        assert!(decision.full_payload.is_none());
    }

    #[test]
    fn payload_policy_hash_stores_sha256_without_payload() {
        let decision = apply_payload_policy("hash_only", b"payload");

        assert_eq!(decision.effective_policy, PayloadPolicy::Hash);
        assert_eq!(decision.storage_mode, PayloadStorageMode::Hash);
        assert_eq!(
            decision.hash_sha256.as_deref(),
            Some("239f59ed55e737c77147cf55ad0c1b030b6d7ee748a7426952f9b852d5a935e5")
        );
        assert!(decision.redacted_preview.is_none());
        assert!(decision.full_payload.is_none());
    }

    #[test]
    fn payload_policy_redacted_stores_only_redacted_preview() {
        let decision = apply_payload_policy(
            "redacted",
            br#"{"message":"email alice@example.com","api_key":"provider-token","model":"gpt"}"#,
        );
        let preview = decision.redacted_preview.as_deref().expect("preview");
        let parsed: Value = serde_json::from_str(preview).expect("redacted JSON preview");

        assert_eq!(decision.storage_mode, PayloadStorageMode::Redacted);
        assert!(decision.hash_sha256.is_some());
        assert!(decision.full_payload.is_none());
        assert_eq!(parsed["api_key"], crate::REDACTED_SECRET);
        assert_eq!(
            parsed["message"],
            format!("email {}", crate::REDACTED_SECRET)
        );
        assert_eq!(parsed["model"], "gpt");
        assert!(!preview.contains("provider-token"));
        assert!(!preview.contains("alice@example.com"));
    }

    #[test]
    fn payload_policy_full_stores_raw_payload_only_when_full_is_explicit() {
        let payload = br#"{"message":"email alice@example.com","api_key":"provider-token"}"#;
        let decision = apply_payload_policy("full", payload);

        assert_eq!(decision.effective_policy, PayloadPolicy::Full);
        assert_eq!(decision.storage_mode, PayloadStorageMode::Full);
        assert!(decision.hash_sha256.is_some());
        assert_eq!(decision.full_payload.as_deref(), Some(payload.as_slice()));
        assert!(decision.redacted_preview.is_none());
    }

    #[test]
    fn payload_policy_unknown_and_empty_fallback_to_hash_without_raw_payload() {
        for policy in ["", "raw", "unknown"] {
            let decision = apply_payload_policy(policy, b"secret=provider-token");

            assert_eq!(decision.effective_policy, PayloadPolicy::Hash);
            assert_eq!(decision.storage_mode, PayloadStorageMode::Hash);
            assert!(!decision.policy_was_recognized);
            assert!(decision.hash_sha256.is_some());
            assert!(decision.redacted_preview.is_none());
            assert!(decision.full_payload.is_none());
        }
    }

    #[test]
    fn payload_policy_json_input_reuses_secret_redaction() {
        let payload = json!({
            "messages": [
                {"content": "send to jane.doe@example.com with Bearer provider-token"}
            ],
            "metadata": {
                "password": "p4ssw0rd",
                "client_secret": "secret-value"
            }
        });
        let decision = apply_payload_policy_to_json("redacted", &payload);
        let preview = decision.redacted_preview.as_deref().expect("preview");
        let parsed: Value = serde_json::from_str(preview).expect("redacted JSON preview");

        assert_eq!(
            parsed["messages"][0]["content"],
            format!(
                "send to {} with Bearer {}",
                crate::REDACTED_SECRET,
                crate::REDACTED_SECRET
            )
        );
        assert_eq!(parsed["metadata"]["password"], crate::REDACTED_SECRET);
        assert_eq!(parsed["metadata"]["client_secret"], crate::REDACTED_SECRET);
        assert!(!preview.contains("jane.doe@example.com"));
        assert!(!preview.contains("provider-token"));
        assert!(!preview.contains("p4ssw0rd"));
    }

    #[test]
    fn payload_policy_sampled_uses_pure_sample_decision() {
        let skipped = apply_payload_policy_with_options(
            "sampled",
            PayloadPolicyInput::Bytes(b"payload"),
            PayloadPolicyOptions {
                sampled_in: false,
                ..PayloadPolicyOptions::default()
            },
        );
        let selected = apply_payload_policy_with_options(
            "sampled",
            PayloadPolicyInput::Bytes(b"email=bob@example.com"),
            PayloadPolicyOptions {
                sampled_in: true,
                ..PayloadPolicyOptions::default()
            },
        );

        assert_eq!(skipped.storage_mode, PayloadStorageMode::Hash);
        assert!(skipped.redacted_preview.is_none());
        assert!(skipped.full_payload.is_none());
        assert_eq!(selected.storage_mode, PayloadStorageMode::Redacted);
        assert_eq!(
            selected.redacted_preview.as_deref(),
            Some(format!("email={}", crate::REDACTED_SECRET).as_str())
        );
        assert!(selected.full_payload.is_none());
    }

    #[test]
    fn payload_policy_redacted_preview_respects_byte_limit() {
        let decision = apply_payload_policy_with_options(
            "redacted",
            PayloadPolicyInput::Bytes("éclair".as_bytes()),
            PayloadPolicyOptions {
                sampled_in: false,
                redacted_preview_max_bytes: 1,
            },
        );

        assert_eq!(decision.redacted_preview.as_deref(), Some(""));
    }
}
