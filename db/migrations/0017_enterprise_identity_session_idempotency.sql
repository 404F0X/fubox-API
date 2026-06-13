-- Bounded enterprise identity sessions must be replayable by a safe idempotency hash.

create unique index if not exists uq_user_sessions_enterprise_identity_idempotency_active
  on user_sessions (
    tenant_id,
    (metadata->>'enterprise_identity_session_idempotency_key_hash')
  )
  where status = 'active'
    and metadata ? 'enterprise_identity_session_idempotency_key_hash';
