use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

const SHA256_BLOCK_LEN: usize = 64;
const SHA256_OUTPUT_LEN: usize = 32;

pub const PASSWORD_HASH_ALGORITHM: &str = "pbkdf2-sha256";
pub const PASSWORD_HASH_VERSION: &str = "v1";
pub const DEFAULT_PASSWORD_HASH_ITERATIONS: u32 = 210_000;
pub const MIN_PASSWORD_HASH_ITERATIONS: u32 = 10_000;
pub const PASSWORD_SALT_LEN: usize = 32;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum PasswordHashError {
    #[error("password must not be empty")]
    EmptyPassword,
    #[error("password salt must not be empty")]
    EmptySalt,
    #[error("password hash iterations must be at least {min}, got {actual}")]
    IterationsTooLow { min: u32, actual: u32 },
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum PasswordVerificationError {
    #[error("password hash format is invalid")]
    InvalidFormat,
    #[error("password hash algorithm is unsupported")]
    UnsupportedAlgorithm,
    #[error("password hash version is unsupported")]
    UnsupportedVersion,
    #[error("password hash iterations are invalid")]
    InvalidIterations,
    #[error("password hash salt is invalid")]
    InvalidSalt,
    #[error("password hash digest is invalid")]
    InvalidDigest,
    #[error(transparent)]
    Hash(#[from] PasswordHashError),
}

pub fn hash_admin_password(password: &str) -> Result<String, PasswordHashError> {
    let salt = generate_password_salt();
    hash_admin_password_with_salt(password, &salt, DEFAULT_PASSWORD_HASH_ITERATIONS)
}

pub fn hash_admin_password_with_salt(
    password: &str,
    salt: &[u8],
    iterations: u32,
) -> Result<String, PasswordHashError> {
    let digest = derive_admin_password_digest(password, salt, iterations)?;

    Ok(format!(
        "{PASSWORD_HASH_ALGORITHM}${PASSWORD_HASH_VERSION}${iterations}${}${}",
        hex::encode(salt),
        hex::encode(digest)
    ))
}

pub fn verify_admin_password(
    password: &str,
    encoded_hash: &str,
) -> Result<bool, PasswordVerificationError> {
    let parsed = ParsedPasswordHash::parse(encoded_hash)?;
    let actual = derive_admin_password_digest(password, &parsed.salt, parsed.iterations)?;

    Ok(constant_time_eq(&actual, &parsed.digest))
}

pub fn generate_password_salt() -> [u8; PASSWORD_SALT_LEN] {
    let first = Uuid::new_v4();
    let second = Uuid::new_v4();
    let mut salt = [0_u8; PASSWORD_SALT_LEN];
    salt[..16].copy_from_slice(first.as_bytes());
    salt[16..].copy_from_slice(second.as_bytes());
    salt
}

fn derive_admin_password_digest(
    password: &str,
    salt: &[u8],
    iterations: u32,
) -> Result<[u8; SHA256_OUTPUT_LEN], PasswordHashError> {
    if password.is_empty() {
        return Err(PasswordHashError::EmptyPassword);
    }
    if salt.is_empty() {
        return Err(PasswordHashError::EmptySalt);
    }
    if iterations < MIN_PASSWORD_HASH_ITERATIONS {
        return Err(PasswordHashError::IterationsTooLow {
            min: MIN_PASSWORD_HASH_ITERATIONS,
            actual: iterations,
        });
    }

    Ok(pbkdf2_sha256(password.as_bytes(), salt, iterations))
}

fn pbkdf2_sha256(password: &[u8], salt: &[u8], iterations: u32) -> [u8; SHA256_OUTPUT_LEN] {
    let mut block = Vec::with_capacity(salt.len() + 4);
    block.extend_from_slice(salt);
    block.extend_from_slice(&1_u32.to_be_bytes());

    let mut u = hmac_sha256(password, &block);
    let mut derived = u;
    for _ in 1..iterations {
        u = hmac_sha256(password, &u);
        for (left, right) in derived.iter_mut().zip(u) {
            *left ^= right;
        }
    }

    derived
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; SHA256_OUTPUT_LEN] {
    let mut normalized_key = [0_u8; SHA256_BLOCK_LEN];
    if key.len() > SHA256_BLOCK_LEN {
        let key_hash = Sha256::digest(key);
        normalized_key[..SHA256_OUTPUT_LEN].copy_from_slice(&key_hash);
    } else {
        normalized_key[..key.len()].copy_from_slice(key);
    }

    let mut inner_pad = [0x36_u8; SHA256_BLOCK_LEN];
    let mut outer_pad = [0x5c_u8; SHA256_BLOCK_LEN];
    for index in 0..SHA256_BLOCK_LEN {
        inner_pad[index] ^= normalized_key[index];
        outer_pad[index] ^= normalized_key[index];
    }

    let mut inner = Sha256::new();
    inner.update(inner_pad);
    inner.update(data);
    let inner_hash = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(outer_pad);
    outer.update(inner_hash);
    let digest = outer.finalize();

    let mut output = [0_u8; SHA256_OUTPUT_LEN];
    output.copy_from_slice(&digest);
    output
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }

    let mut diff = 0_u8;
    for (left, right) in left.iter().zip(right) {
        diff |= left ^ right;
    }
    diff == 0
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedPasswordHash {
    iterations: u32,
    salt: Vec<u8>,
    digest: [u8; SHA256_OUTPUT_LEN],
}

impl ParsedPasswordHash {
    fn parse(encoded_hash: &str) -> Result<Self, PasswordVerificationError> {
        let mut parts = encoded_hash.split('$');
        let algorithm = parts
            .next()
            .ok_or(PasswordVerificationError::InvalidFormat)?;
        let version = parts
            .next()
            .ok_or(PasswordVerificationError::InvalidFormat)?;
        let iterations = parts
            .next()
            .ok_or(PasswordVerificationError::InvalidFormat)?;
        let salt = parts
            .next()
            .ok_or(PasswordVerificationError::InvalidFormat)?;
        let digest = parts
            .next()
            .ok_or(PasswordVerificationError::InvalidFormat)?;

        if parts.next().is_some() {
            return Err(PasswordVerificationError::InvalidFormat);
        }
        if algorithm != PASSWORD_HASH_ALGORITHM {
            return Err(PasswordVerificationError::UnsupportedAlgorithm);
        }
        if version != PASSWORD_HASH_VERSION {
            return Err(PasswordVerificationError::UnsupportedVersion);
        }

        let iterations = iterations
            .parse::<u32>()
            .map_err(|_| PasswordVerificationError::InvalidIterations)?;
        let salt = hex::decode(salt).map_err(|_| PasswordVerificationError::InvalidSalt)?;
        if salt.is_empty() {
            return Err(PasswordVerificationError::InvalidSalt);
        }

        let digest_bytes =
            hex::decode(digest).map_err(|_| PasswordVerificationError::InvalidDigest)?;
        let digest = digest_bytes
            .as_slice()
            .try_into()
            .map_err(|_| PasswordVerificationError::InvalidDigest)?;

        Ok(Self {
            iterations,
            salt,
            digest,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_salt() -> [u8; PASSWORD_SALT_LEN] {
        [7_u8; PASSWORD_SALT_LEN]
    }

    #[test]
    fn pbkdf2_sha256_matches_known_vector() {
        let digest = pbkdf2_sha256(b"password", b"salt", 1);

        assert_eq!(
            hex::encode(digest),
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
        );
    }

    #[test]
    fn hashes_and_verifies_admin_password() {
        let encoded =
            hash_admin_password_with_salt("correct horse battery staple", &test_salt(), 10_000)
                .unwrap();

        assert!(encoded.starts_with("pbkdf2-sha256$v1$10000$"));
        assert!(!encoded.contains("correct horse"));
        assert!(verify_admin_password("correct horse battery staple", &encoded).unwrap());
        assert!(!verify_admin_password("wrong password", &encoded).unwrap());
    }

    #[test]
    fn encoded_password_hash_is_stable_for_same_inputs() {
        let left = hash_admin_password_with_salt("admin-pass", &test_salt(), 10_000).unwrap();
        let right = hash_admin_password_with_salt("admin-pass", &test_salt(), 10_000).unwrap();

        assert_eq!(left, right);
    }

    #[test]
    fn rejects_invalid_password_hash_inputs() {
        assert_eq!(
            hash_admin_password_with_salt("", &test_salt(), 10_000).unwrap_err(),
            PasswordHashError::EmptyPassword
        );
        assert_eq!(
            hash_admin_password_with_salt("admin-pass", &[], 10_000).unwrap_err(),
            PasswordHashError::EmptySalt
        );
        assert_eq!(
            hash_admin_password_with_salt("admin-pass", &test_salt(), 9_999).unwrap_err(),
            PasswordHashError::IterationsTooLow {
                min: MIN_PASSWORD_HASH_ITERATIONS,
                actual: 9_999,
            }
        );
    }

    #[test]
    fn rejects_malformed_password_hashes() {
        assert_eq!(
            verify_admin_password("admin-pass", "not-enough-parts").unwrap_err(),
            PasswordVerificationError::InvalidFormat
        );
        assert_eq!(
            verify_admin_password("admin-pass", "sha256$v1$10000$aa$bb").unwrap_err(),
            PasswordVerificationError::UnsupportedAlgorithm
        );
        assert_eq!(
            verify_admin_password("admin-pass", "pbkdf2-sha256$v2$10000$aa$bb").unwrap_err(),
            PasswordVerificationError::UnsupportedVersion
        );
        assert_eq!(
            verify_admin_password("admin-pass", "pbkdf2-sha256$v1$ten$aa$bb").unwrap_err(),
            PasswordVerificationError::InvalidIterations
        );
        assert_eq!(
            verify_admin_password("admin-pass", "pbkdf2-sha256$v1$10000$zz$bb").unwrap_err(),
            PasswordVerificationError::InvalidSalt
        );
        assert_eq!(
            verify_admin_password("admin-pass", "pbkdf2-sha256$v1$10000$aa$bb").unwrap_err(),
            PasswordVerificationError::InvalidDigest
        );
    }

    #[test]
    fn generated_admin_password_hash_uses_random_salt() {
        let left = hash_admin_password("admin-pass").unwrap();
        let right = hash_admin_password("admin-pass").unwrap();

        assert_ne!(left, right);
        assert!(verify_admin_password("admin-pass", &left).unwrap());
        assert!(verify_admin_password("admin-pass", &right).unwrap());
    }
}
