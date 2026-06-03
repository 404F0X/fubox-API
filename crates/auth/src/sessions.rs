use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

pub const SESSION_TOKEN_PREFIX: &str = "sess_";
pub const SESSION_TOKEN_RANDOM_HEX_LEN: usize = 64;
pub const SESSION_TOKEN_LEN: usize = SESSION_TOKEN_PREFIX.len() + SESSION_TOKEN_RANDOM_HEX_LEN;
pub const SESSION_TOKEN_LOOKUP_PREFIX_LEN: usize = 20;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum SessionTokenError {
    #[error("session token must not be empty")]
    Empty,
    #[error("session token prefix is invalid")]
    InvalidPrefix,
    #[error("session token length is invalid")]
    InvalidLength,
    #[error("session token contains invalid characters")]
    InvalidCharacters,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GeneratedSessionToken {
    pub token: String,
    pub prefix: String,
    pub token_hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedSessionToken {
    pub prefix: String,
    pub token_hash: String,
}

pub fn generate_session_token() -> GeneratedSessionToken {
    let token = format!(
        "{SESSION_TOKEN_PREFIX}{}{}",
        Uuid::new_v4().simple(),
        Uuid::new_v4().simple()
    );
    let parsed = parse_session_token(&token).expect("generated session token must be valid");

    GeneratedSessionToken {
        token,
        prefix: parsed.prefix,
        token_hash: parsed.token_hash,
    }
}

pub fn parse_session_token(raw: &str) -> Result<ParsedSessionToken, SessionTokenError> {
    Ok(ParsedSessionToken {
        prefix: session_token_lookup_prefix(raw)?,
        token_hash: hash_session_token(raw)?,
    })
}

pub fn hash_session_token(raw: &str) -> Result<String, SessionTokenError> {
    let token = validate_session_token(raw)?;
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    Ok(hex::encode(hasher.finalize()))
}

pub fn session_token_lookup_prefix(raw: &str) -> Result<String, SessionTokenError> {
    let token = validate_session_token(raw)?;
    Ok(token
        .chars()
        .take(SESSION_TOKEN_LOOKUP_PREFIX_LEN)
        .collect())
}

fn validate_session_token(raw: &str) -> Result<&str, SessionTokenError> {
    let token = raw.trim();
    if token.is_empty() {
        return Err(SessionTokenError::Empty);
    }
    if !token.starts_with(SESSION_TOKEN_PREFIX) {
        return Err(SessionTokenError::InvalidPrefix);
    }
    if token.len() != SESSION_TOKEN_LEN {
        return Err(SessionTokenError::InvalidLength);
    }

    let random = &token[SESSION_TOKEN_PREFIX.len()..];
    if !random.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(SessionTokenError::InvalidCharacters);
    }

    Ok(token)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixed_token() -> String {
        format!(
            "{SESSION_TOKEN_PREFIX}{}",
            "a".repeat(SESSION_TOKEN_RANDOM_HEX_LEN)
        )
    }

    #[test]
    fn generated_session_token_has_hash_and_lookup_prefix() {
        let generated = generate_session_token();
        let parsed = parse_session_token(&generated.token).unwrap();

        assert!(generated.token.starts_with(SESSION_TOKEN_PREFIX));
        assert_eq!(generated.token.len(), SESSION_TOKEN_LEN);
        assert_eq!(generated.prefix.len(), SESSION_TOKEN_LOOKUP_PREFIX_LEN);
        assert_eq!(generated.token_hash.len(), 64);
        assert_ne!(generated.token, generated.token_hash);
        assert_eq!(generated.prefix, parsed.prefix);
        assert_eq!(generated.token_hash, parsed.token_hash);
    }

    #[test]
    fn session_token_hash_is_stable_for_same_token() {
        let token = fixed_token();
        let first = hash_session_token(&token).unwrap();
        let second = hash_session_token(&token).unwrap();

        assert_eq!(first, second);
        assert_eq!(first.len(), 64);
    }

    #[test]
    fn parses_session_token_with_outer_whitespace() {
        let token = fixed_token();
        let parsed = parse_session_token(&format!("  {token}  ")).unwrap();

        assert_eq!(
            parsed.prefix,
            token
                .chars()
                .take(SESSION_TOKEN_LOOKUP_PREFIX_LEN)
                .collect::<String>()
        );
        assert_eq!(parsed.token_hash, hash_session_token(&token).unwrap());
    }

    #[test]
    fn rejects_invalid_session_tokens() {
        assert_eq!(
            parse_session_token("").unwrap_err(),
            SessionTokenError::Empty
        );
        assert_eq!(
            parse_session_token("Bearer token").unwrap_err(),
            SessionTokenError::InvalidPrefix
        );
        assert_eq!(
            parse_session_token("sess_short").unwrap_err(),
            SessionTokenError::InvalidLength
        );
        assert_eq!(
            parse_session_token(&format!(
                "{SESSION_TOKEN_PREFIX}{}z",
                "a".repeat(SESSION_TOKEN_RANDOM_HEX_LEN - 1)
            ))
            .unwrap_err(),
            SessionTokenError::InvalidCharacters
        );
    }
}
