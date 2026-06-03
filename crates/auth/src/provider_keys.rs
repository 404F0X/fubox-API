use aes_gcm::{
    Aes256Gcm, Nonce,
    aead::{Aead, AeadCore, KeyInit, OsRng, Payload},
};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::{fmt, str};
use thiserror::Error;

pub const PROVIDER_KEY_ENCRYPTION_ALGORITHM: &str = "aes-256-gcm";
pub const PROVIDER_KEY_ENCRYPTION_VERSION: u8 = 1;
pub const PROVIDER_KEY_MASTER_KEY_LEN: usize = 32;
pub const PROVIDER_KEY_NONCE_LEN: usize = 12;
pub const PROVIDER_KEY_FINGERPRINT_ALGORITHM: &str = "hmac-sha256-v1";

const ENCRYPTION_AAD_DOMAIN: &[u8] = b"ai-gateway:provider-key:seal:v1";
const CONTEXT_AAD_DOMAIN: &[u8] = b"ai-gateway:provider-key:context:v1";
const FINGERPRINT_DOMAIN: &[u8] = b"ai-gateway:provider-key:fingerprint:v1";

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ProviderKeyCryptoError {
    #[error("provider key master key must be {expected} bytes, got {actual}")]
    InvalidMasterKeyLength { expected: usize, actual: usize },
    #[error("provider key master key id must not be empty")]
    EmptyMasterKeyId,
    #[error("provider key secret must not be empty")]
    EmptySecret,
    #[error("provider key context must not be empty")]
    EmptyContext,
    #[error("provider key context field {field} must not be empty")]
    EmptyContextField { field: &'static str },
    #[error("sealed provider key version is unsupported: {0}")]
    UnsupportedVersion(u8),
    #[error("provider key encryption failed")]
    EncryptionFailed,
    #[error("provider key decryption failed")]
    DecryptionFailed,
    #[error("decrypted provider key secret is not valid UTF-8")]
    InvalidUtf8,
    #[error("provider key fingerprint key must not be empty")]
    EmptyFingerprintKey,
}

#[derive(Clone, PartialEq, Eq)]
pub struct ProviderKeySecret {
    secret: String,
}

impl ProviderKeySecret {
    pub fn new(secret: impl Into<String>) -> Result<Self, ProviderKeyCryptoError> {
        let secret = secret.into();
        if secret.is_empty() {
            return Err(ProviderKeyCryptoError::EmptySecret);
        }

        Ok(Self { secret })
    }

    pub fn expose_secret(&self) -> &str {
        &self.secret
    }

    pub fn as_bytes(&self) -> &[u8] {
        self.secret.as_bytes()
    }
}

impl fmt::Debug for ProviderKeySecret {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ProviderKeySecret([REDACTED])")
    }
}

impl fmt::Display for ProviderKeySecret {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("[REDACTED]")
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct ProviderKeyContext {
    aad: Vec<u8>,
}

impl ProviderKeyContext {
    pub fn new(
        tenant_id: impl AsRef<str>,
        provider_id: impl AsRef<str>,
        provider_key_id: impl AsRef<str>,
    ) -> Result<Self, ProviderKeyCryptoError> {
        let tenant_id = required_context_field("tenant_id", tenant_id.as_ref())?;
        let provider_id = required_context_field("provider_id", provider_id.as_ref())?;
        let provider_key_id = required_context_field("provider_key_id", provider_key_id.as_ref())?;

        let mut aad = Vec::new();
        append_field(&mut aad, "domain", CONTEXT_AAD_DOMAIN);
        append_field(&mut aad, "tenant_id", tenant_id.as_bytes());
        append_field(&mut aad, "provider_id", provider_id.as_bytes());
        append_field(&mut aad, "provider_key_id", provider_key_id.as_bytes());

        Ok(Self { aad })
    }

    pub fn from_aad(aad: impl Into<Vec<u8>>) -> Result<Self, ProviderKeyCryptoError> {
        let aad = aad.into();
        if aad.is_empty() {
            return Err(ProviderKeyCryptoError::EmptyContext);
        }

        Ok(Self { aad })
    }

    pub fn as_aad(&self) -> &[u8] {
        &self.aad
    }
}

impl fmt::Debug for ProviderKeyContext {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ProviderKeyContext")
            .field("aad_len", &self.aad.len())
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct SealedProviderKey {
    pub version: u8,
    pub master_key_id: String,
    pub nonce: [u8; PROVIDER_KEY_NONCE_LEN],
    pub ciphertext: Vec<u8>,
}

impl fmt::Debug for SealedProviderKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let nonce_hex = hex::encode(self.nonce);
        formatter
            .debug_struct("SealedProviderKey")
            .field("version", &self.version)
            .field("master_key_id", &self.master_key_id)
            .field("nonce", &nonce_hex)
            .field("ciphertext_len", &self.ciphertext.len())
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub struct ProviderKeyFingerprint {
    value: String,
}

impl ProviderKeyFingerprint {
    pub fn as_str(&self) -> &str {
        &self.value
    }

    pub fn into_string(self) -> String {
        self.value
    }
}

impl fmt::Debug for ProviderKeyFingerprint {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ProviderKeyFingerprint([REDACTED])")
    }
}

impl fmt::Display for ProviderKeyFingerprint {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("[REDACTED]")
    }
}

pub fn seal_provider_key(
    master_key: &[u8],
    master_key_id: impl AsRef<str>,
    context: &ProviderKeyContext,
    secret: &ProviderKeySecret,
) -> Result<SealedProviderKey, ProviderKeyCryptoError> {
    let cipher = provider_key_cipher(master_key)?;
    let master_key_id = required_master_key_id(master_key_id.as_ref())?.to_owned();
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let aad = encryption_aad(PROVIDER_KEY_ENCRYPTION_VERSION, &master_key_id, context);

    let ciphertext = cipher
        .encrypt(
            &nonce,
            Payload {
                msg: secret.as_bytes(),
                aad: &aad,
            },
        )
        .map_err(|_| ProviderKeyCryptoError::EncryptionFailed)?;

    let mut nonce_bytes = [0_u8; PROVIDER_KEY_NONCE_LEN];
    nonce_bytes.copy_from_slice(&nonce);

    Ok(SealedProviderKey {
        version: PROVIDER_KEY_ENCRYPTION_VERSION,
        master_key_id,
        nonce: nonce_bytes,
        ciphertext,
    })
}

pub fn open_provider_key(
    master_key: &[u8],
    context: &ProviderKeyContext,
    sealed: &SealedProviderKey,
) -> Result<ProviderKeySecret, ProviderKeyCryptoError> {
    if sealed.version != PROVIDER_KEY_ENCRYPTION_VERSION {
        return Err(ProviderKeyCryptoError::UnsupportedVersion(sealed.version));
    }

    let cipher = provider_key_cipher(master_key)?;
    let aad = encryption_aad(sealed.version, &sealed.master_key_id, context);
    let plaintext = cipher
        .decrypt(
            Nonce::from_slice(&sealed.nonce),
            Payload {
                msg: &sealed.ciphertext,
                aad: &aad,
            },
        )
        .map_err(|_| ProviderKeyCryptoError::DecryptionFailed)?;

    let secret = str::from_utf8(&plaintext).map_err(|_| ProviderKeyCryptoError::InvalidUtf8)?;
    ProviderKeySecret::new(secret.to_owned())
}

pub fn fingerprint_provider_key(
    fingerprint_key: &[u8],
    secret: &ProviderKeySecret,
) -> Result<ProviderKeyFingerprint, ProviderKeyCryptoError> {
    if fingerprint_key.is_empty() {
        return Err(ProviderKeyCryptoError::EmptyFingerprintKey);
    }

    let mut mac = <HmacSha256 as Mac>::new_from_slice(fingerprint_key)
        .expect("HMAC-SHA256 accepts keys of any length");
    mac.update(FINGERPRINT_DOMAIN);
    append_mac_field(&mut mac, "secret", secret.as_bytes());

    let digest = mac.finalize().into_bytes();
    Ok(ProviderKeyFingerprint {
        value: format!(
            "{PROVIDER_KEY_FINGERPRINT_ALGORITHM}:{}",
            hex::encode(digest)
        ),
    })
}

fn provider_key_cipher(master_key: &[u8]) -> Result<Aes256Gcm, ProviderKeyCryptoError> {
    if master_key.len() != PROVIDER_KEY_MASTER_KEY_LEN {
        return Err(ProviderKeyCryptoError::InvalidMasterKeyLength {
            expected: PROVIDER_KEY_MASTER_KEY_LEN,
            actual: master_key.len(),
        });
    }

    Aes256Gcm::new_from_slice(master_key).map_err(|_| {
        ProviderKeyCryptoError::InvalidMasterKeyLength {
            expected: PROVIDER_KEY_MASTER_KEY_LEN,
            actual: master_key.len(),
        }
    })
}

fn required_master_key_id(raw: &str) -> Result<&str, ProviderKeyCryptoError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ProviderKeyCryptoError::EmptyMasterKeyId);
    }

    Ok(trimmed)
}

fn required_context_field<'a>(
    field: &'static str,
    raw: &'a str,
) -> Result<&'a str, ProviderKeyCryptoError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ProviderKeyCryptoError::EmptyContextField { field });
    }

    Ok(trimmed)
}

fn encryption_aad(version: u8, master_key_id: &str, context: &ProviderKeyContext) -> Vec<u8> {
    let mut aad = Vec::new();
    append_field(&mut aad, "domain", ENCRYPTION_AAD_DOMAIN);
    append_field(
        &mut aad,
        "algorithm",
        PROVIDER_KEY_ENCRYPTION_ALGORITHM.as_bytes(),
    );
    append_field(&mut aad, "version", &[version]);
    append_field(&mut aad, "master_key_id", master_key_id.as_bytes());
    append_field(&mut aad, "context", context.as_aad());
    aad
}

fn append_field(output: &mut Vec<u8>, label: &str, value: &[u8]) {
    output.extend_from_slice(&(label.len() as u32).to_be_bytes());
    output.extend_from_slice(label.as_bytes());
    output.extend_from_slice(&(value.len() as u32).to_be_bytes());
    output.extend_from_slice(value);
}

fn append_mac_field(mac: &mut HmacSha256, label: &str, value: &[u8]) {
    mac.update(&(label.len() as u32).to_be_bytes());
    mac.update(label.as_bytes());
    mac.update(&(value.len() as u32).to_be_bytes());
    mac.update(value);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn master_key() -> [u8; PROVIDER_KEY_MASTER_KEY_LEN] {
        [7_u8; PROVIDER_KEY_MASTER_KEY_LEN]
    }

    fn alternate_master_key() -> [u8; PROVIDER_KEY_MASTER_KEY_LEN] {
        [9_u8; PROVIDER_KEY_MASTER_KEY_LEN]
    }

    fn context() -> ProviderKeyContext {
        ProviderKeyContext::new("tenant-a", "openai", "provider-key-1").unwrap()
    }

    fn alternate_context() -> ProviderKeyContext {
        ProviderKeyContext::new("tenant-a", "openai", "provider-key-2").unwrap()
    }

    fn secret() -> ProviderKeySecret {
        ProviderKeySecret::new("sk-provider-secret").unwrap()
    }

    #[test]
    fn provider_key_seal_open_round_trip() {
        let sealed = seal_provider_key(&master_key(), "mk-v1", &context(), &secret()).unwrap();
        let opened = open_provider_key(&master_key(), &context(), &sealed).unwrap();

        assert_eq!(sealed.version, PROVIDER_KEY_ENCRYPTION_VERSION);
        assert_eq!(sealed.master_key_id, "mk-v1");
        assert_eq!(sealed.nonce.len(), PROVIDER_KEY_NONCE_LEN);
        assert_ne!(sealed.ciphertext, secret().as_bytes());
        assert_eq!(opened.expose_secret(), secret().expose_secret());
    }

    #[test]
    fn provider_key_wrong_master_key_fails() {
        let sealed = seal_provider_key(&master_key(), "mk-v1", &context(), &secret()).unwrap();

        assert_eq!(
            open_provider_key(&alternate_master_key(), &context(), &sealed).unwrap_err(),
            ProviderKeyCryptoError::DecryptionFailed
        );
    }

    #[test]
    fn provider_key_wrong_context_fails() {
        let sealed = seal_provider_key(&master_key(), "mk-v1", &context(), &secret()).unwrap();

        assert_eq!(
            open_provider_key(&master_key(), &alternate_context(), &sealed).unwrap_err(),
            ProviderKeyCryptoError::DecryptionFailed
        );
    }

    #[test]
    fn provider_key_fingerprint_is_stable_and_keyed() {
        let first = fingerprint_provider_key(b"fingerprint-key-a", &secret()).unwrap();
        let second = fingerprint_provider_key(b"fingerprint-key-a", &secret()).unwrap();
        let different_key = fingerprint_provider_key(b"fingerprint-key-b", &secret()).unwrap();
        let different_secret = fingerprint_provider_key(
            b"fingerprint-key-a",
            &ProviderKeySecret::new("sk-provider-secret-2").unwrap(),
        )
        .unwrap();

        assert_eq!(first, second);
        assert_ne!(first, different_key);
        assert_ne!(first, different_secret);
        assert!(
            first
                .as_str()
                .starts_with(PROVIDER_KEY_FINGERPRINT_ALGORITHM)
        );
    }

    #[test]
    fn provider_key_sealing_uses_fresh_nonce() {
        let first = seal_provider_key(&master_key(), "mk-v1", &context(), &secret()).unwrap();
        let second = seal_provider_key(&master_key(), "mk-v1", &context(), &secret()).unwrap();

        assert_ne!(first.nonce, second.nonce);
        assert_ne!(first.ciphertext, second.ciphertext);
    }

    #[test]
    fn provider_key_redacts_debug_and_display() {
        let sealed = seal_provider_key(&master_key(), "mk-v1", &context(), &secret()).unwrap();
        let fingerprint = fingerprint_provider_key(b"fingerprint-key-a", &secret()).unwrap();

        assert_eq!(secret().to_string(), "[REDACTED]");
        assert!(!format!("{:?}", secret()).contains(secret().expose_secret()));
        assert!(!format!("{sealed:?}").contains(secret().expose_secret()));
        assert_eq!(fingerprint.to_string(), "[REDACTED]");
        assert!(!format!("{fingerprint:?}").contains(fingerprint.as_str()));
    }
}
