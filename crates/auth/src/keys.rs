use sha2::{Digest, Sha256};
use std::fmt;
use thiserror::Error;
use uuid::Uuid;

pub const VIRTUAL_KEY_SECRET_PREFIX: &str = "vk_";
pub const VIRTUAL_KEY_RANDOM_HEX_LEN: usize = 64;
pub const VIRTUAL_KEY_PREFIX_LEN: usize = 12;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum VirtualKeyError {
    #[error("virtual key must not be empty")]
    Empty,
    #[error("virtual key is too short")]
    TooShort,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum AuthorizationError {
    #[error("authorization header is missing")]
    Missing,
    #[error("authorization scheme must be Bearer")]
    InvalidScheme,
    #[error("bearer token must not be empty")]
    Empty,
    #[error("bearer token is too short")]
    TooShort,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedVirtualKey {
    pub prefix: String,
    pub secret_hash: String,
}

#[derive(Clone, PartialEq, Eq)]
pub struct GeneratedVirtualKey {
    pub secret: String,
    pub prefix: String,
    pub secret_hash: String,
}

impl fmt::Debug for GeneratedVirtualKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("GeneratedVirtualKey")
            .field("secret", &"[REDACTED]")
            .field("prefix", &self.prefix)
            .field("secret_hash", &"[REDACTED]")
            .finish()
    }
}

impl fmt::Display for GeneratedVirtualKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "GeneratedVirtualKey {{ secret: [REDACTED], prefix: {}, secret_hash: [REDACTED] }}",
            self.prefix
        )
    }
}

pub fn generate_virtual_key() -> GeneratedVirtualKey {
    let secret = format!(
        "{VIRTUAL_KEY_SECRET_PREFIX}{}{}",
        Uuid::new_v4().simple(),
        Uuid::new_v4().simple()
    );
    let parsed = parse_virtual_key(&secret).expect("generated virtual key must be valid");

    GeneratedVirtualKey {
        secret,
        prefix: parsed.prefix,
        secret_hash: parsed.secret_hash,
    }
}

pub fn parse_authorization_header(
    header: Option<&str>,
) -> Result<ParsedVirtualKey, AuthorizationError> {
    let header = header.ok_or(AuthorizationError::Missing)?.trim();
    if header.is_empty() {
        return Err(AuthorizationError::Empty);
    }

    let mut parts = header.split_whitespace();
    let scheme = parts.next().ok_or(AuthorizationError::Empty)?;
    if !scheme.eq_ignore_ascii_case("bearer") {
        return Err(AuthorizationError::InvalidScheme);
    }

    let token = parts.next().ok_or(AuthorizationError::Empty)?;
    if parts.next().is_some() {
        return Err(AuthorizationError::InvalidScheme);
    }

    parse_virtual_key(token).map_err(AuthorizationError::from)
}

pub fn parse_bearer_authorization(header: &str) -> Result<ParsedVirtualKey, AuthorizationError> {
    parse_authorization_header(Some(header))
}

pub fn parse_virtual_key(raw: &str) -> Result<ParsedVirtualKey, VirtualKeyError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(VirtualKeyError::Empty);
    }

    if trimmed.chars().count() < VIRTUAL_KEY_PREFIX_LEN {
        return Err(VirtualKeyError::TooShort);
    }

    Ok(ParsedVirtualKey {
        prefix: key_prefix_for_secret(trimmed)?,
        secret_hash: hash_virtual_key(trimmed),
    })
}

pub fn key_prefix_for_secret(raw: &str) -> Result<String, VirtualKeyError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(VirtualKeyError::Empty);
    }

    if trimmed.chars().count() < VIRTUAL_KEY_PREFIX_LEN {
        return Err(VirtualKeyError::TooShort);
    }

    Ok(trimmed.chars().take(VIRTUAL_KEY_PREFIX_LEN).collect())
}

pub fn virtual_key_prefix(raw: &str) -> Result<String, VirtualKeyError> {
    key_prefix_for_secret(raw)
}

pub fn hash_virtual_key(raw: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(raw.as_bytes());
    hex::encode(hasher.finalize())
}

pub fn hash_virtual_key_secret(raw: &str) -> String {
    hash_virtual_key(raw)
}

impl From<VirtualKeyError> for AuthorizationError {
    fn from(error: VirtualKeyError) -> Self {
        match error {
            VirtualKeyError::Empty => Self::Empty,
            VirtualKeyError::TooShort => Self::TooShort,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_prefix_and_stable_hash() {
        let key = parse_virtual_key("dev_test_key_123456789").unwrap();
        assert_eq!(key.prefix, "dev_test_key");
        assert_eq!(key.secret_hash.len(), 64);
        assert_eq!(key.secret_hash, hash_virtual_key("dev_test_key_123456789"));
    }

    #[test]
    fn parses_bearer_authorization_header() {
        let key = parse_authorization_header(Some("Bearer dev_test_key_123456789")).unwrap();
        assert_eq!(key.prefix, "dev_test_key");
        assert_eq!(
            key.secret_hash,
            "165c66ca7e0aff3d28b1aaca0126d4feefabc507d91a38fe4680d921540f8e83"
        );
    }

    #[test]
    fn bearer_scheme_is_case_insensitive_and_allows_extra_outer_space() {
        let key = parse_bearer_authorization("  bearer   dev_test_key_123456789  ").unwrap();
        assert_eq!(key.prefix, "dev_test_key");
    }

    #[test]
    fn rejects_missing_authorization_header() {
        assert_eq!(
            parse_authorization_header(None).unwrap_err(),
            AuthorizationError::Missing
        );
    }

    #[test]
    fn rejects_invalid_authorization_scheme() {
        assert_eq!(
            parse_bearer_authorization("Basic dev_test_key_123456789").unwrap_err(),
            AuthorizationError::InvalidScheme
        );
    }

    #[test]
    fn rejects_empty_bearer_token() {
        assert_eq!(
            parse_bearer_authorization("Bearer").unwrap_err(),
            AuthorizationError::Empty
        );
        assert_eq!(
            parse_bearer_authorization("Bearer   ").unwrap_err(),
            AuthorizationError::Empty
        );
    }

    #[test]
    fn rejects_short_bearer_token() {
        assert_eq!(
            parse_bearer_authorization("Bearer short").unwrap_err(),
            AuthorizationError::TooShort
        );
    }

    #[test]
    fn rejects_malformed_bearer_token_with_extra_segments() {
        assert_eq!(
            parse_bearer_authorization("Bearer dev_test_key_123456789 extra").unwrap_err(),
            AuthorizationError::InvalidScheme
        );
    }

    #[test]
    fn long_prefix_does_not_panic_on_boundaries() {
        let raw = "k".repeat(32);
        let key = parse_virtual_key(&raw).unwrap();
        assert_eq!(key.prefix.chars().count(), VIRTUAL_KEY_PREFIX_LEN);
        assert_eq!(key.secret_hash.len(), 64);
    }

    #[test]
    fn generated_virtual_key_parses_with_matching_prefix_and_hash() {
        let generated = generate_virtual_key();
        let parsed = parse_virtual_key(&generated.secret).unwrap();

        assert!(generated.secret.starts_with(VIRTUAL_KEY_SECRET_PREFIX));
        assert_eq!(
            generated.secret.len(),
            VIRTUAL_KEY_SECRET_PREFIX.len() + VIRTUAL_KEY_RANDOM_HEX_LEN
        );
        assert_eq!(generated.prefix, parsed.prefix);
        assert_eq!(
            generated.prefix,
            virtual_key_prefix(&generated.secret).unwrap()
        );
        assert!(generated.prefix.starts_with(VIRTUAL_KEY_SECRET_PREFIX));
        assert_eq!(generated.secret_hash, parsed.secret_hash);
        assert_eq!(
            generated.secret_hash,
            hash_virtual_key_secret(&generated.secret)
        );
    }

    #[test]
    fn generated_virtual_keys_are_unique() {
        let first = generate_virtual_key();
        let second = generate_virtual_key();

        assert_ne!(first.secret, second.secret);
        assert_ne!(first.secret_hash, second.secret_hash);
    }

    #[test]
    fn generated_virtual_key_debug_and_display_redact_secret() {
        let generated = generate_virtual_key();

        assert!(!format!("{generated:?}").contains(&generated.secret));
        assert!(!format!("{generated:?}").contains(&generated.secret_hash));
        assert!(!generated.to_string().contains(&generated.secret));
        assert!(!generated.to_string().contains(&generated.secret_hash));
        assert!(format!("{generated:?}").contains("[REDACTED]"));
        assert!(generated.to_string().contains("[REDACTED]"));
    }
}
