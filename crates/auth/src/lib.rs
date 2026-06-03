pub mod keys;
pub mod login_rate_limit;
pub mod passwords;
pub mod provider_keys;
pub mod rbac;
pub mod sessions;

pub use keys::{
    AuthorizationError, GeneratedVirtualKey, ParsedVirtualKey, VIRTUAL_KEY_PREFIX_LEN,
    VIRTUAL_KEY_RANDOM_HEX_LEN, VIRTUAL_KEY_SECRET_PREFIX, generate_virtual_key, hash_virtual_key,
    hash_virtual_key_secret, key_prefix_for_secret, parse_authorization_header,
    parse_bearer_authorization, parse_virtual_key, virtual_key_prefix,
};
pub use login_rate_limit::{
    DEFAULT_LOGIN_FAILURE_LIMIT, DEFAULT_LOGIN_FAILURE_WINDOW_SECONDS,
    LoginFailureRateLimitDecision, LoginFailureRateLimitPolicy, LoginFailureRateLimitState,
    evaluate_login_failure_rate_limit, login_rate_limit_fingerprint, record_login_failure,
};
pub use passwords::{
    DEFAULT_PASSWORD_HASH_ITERATIONS, MIN_PASSWORD_HASH_ITERATIONS, PASSWORD_HASH_ALGORITHM,
    PASSWORD_HASH_VERSION, PASSWORD_SALT_LEN, PasswordHashError, PasswordVerificationError,
    generate_password_salt, hash_admin_password, hash_admin_password_with_salt,
    verify_admin_password,
};
pub use provider_keys::{
    PROVIDER_KEY_ENCRYPTION_ALGORITHM, PROVIDER_KEY_ENCRYPTION_VERSION,
    PROVIDER_KEY_FINGERPRINT_ALGORITHM, PROVIDER_KEY_MASTER_KEY_LEN, PROVIDER_KEY_NONCE_LEN,
    ProviderKeyContext, ProviderKeyCryptoError, ProviderKeyFingerprint, ProviderKeySecret,
    SealedProviderKey, fingerprint_provider_key, open_provider_key, seal_provider_key,
};
pub use rbac::{
    AccessControlError, Permission, Role, RoleParseError, any_role_allows, require_permission,
    role_allows,
};
pub use sessions::{
    GeneratedSessionToken, ParsedSessionToken, SESSION_TOKEN_LEN, SESSION_TOKEN_LOOKUP_PREFIX_LEN,
    SESSION_TOKEN_PREFIX, SESSION_TOKEN_RANDOM_HEX_LEN, SessionTokenError, generate_session_token,
    hash_session_token, parse_session_token, session_token_lookup_prefix,
};
