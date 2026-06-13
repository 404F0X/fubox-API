# API Contracts for UI Rebuild

Last updated: 2026-06-12

This is the first stable, frontend-focused API/DTO map for the Admin UI and User Portal rebuild. It summarizes the interfaces that are already useful to the UI, the DTO fields worth depending on, secret-safe rules, and the local mock path for end-to-end testing.

Authoritative implementation references:

- `web/admin-ui/src/api/client.ts` is the current frontend client and DTO source of truth.
- `examples/openapi_admin_skeleton.yaml` is useful for control-plane path details and security notes, but it also contains contract-only and non-UI operational material that should not drive the UI rebuild.
- `scripts/dev_login_check.ps1` is the best local smoke path for register -> voucher -> key -> gateway -> request log readback.

## Global Calling Rules

Base URLs used by the current UI client:

- Control Plane: `VITE_CONTROL_PLANE_BASE_URL`, default `http://localhost:8081`
- Gateway: `VITE_GATEWAY_BASE_URL`, default `http://localhost:8080`
- Mock Provider: `VITE_MOCK_PROVIDER_BASE_URL`, default `http://localhost:18080`

The shared `apiJson<T>()` helper:

- Sends JSON bodies with `Content-Type: application/json`.
- Uses `credentials: "include"` so session cookies work.
- Unwraps `{ data: ... }` envelopes and returns `data` to callers.
- Throws `ApiClientError` for non-2xx responses with `status`, `code`, `type`, `retryable`, `message`, and raw error `envelope`.
- Adds `x-admin-session` automatically for `/admin/*` paths when `setAdminSessionToken()` has a token, except `/admin/auth/login`.

Treat all money values as fixed-decimal strings, not numbers.

Gateway request/response headers for frontend runtime tools:

- Send user virtual key secrets only as `Authorization: Bearer <user_api_key_secret>`.
- Optional request header `x-ai-profile` selects an API key profile by reference when the current key allows it.
- Optional request header `x-ai-trace-id` groups gateway requests for trace drawer readback. Do not put secrets, prompts, or user-visible raw payload in it.
- Read response header `x-request-id` from successful gateway JSON responses and use it to deep-link into request logs. CORS exposes this header.
- Do not depend on a gateway model response header. Use the response body `model`, `/v1/models`, or request log fields such as `requested_model`, `canonical_model_id`, and `upstream_model`.

## Secret-safe Rules

The rebuild must preserve these response and UI rules:

- Never render or persist raw provider keys, `Authorization` headers, session cookies, user API key secrets after one-time display, raw voucher codes, raw idempotency keys, raw request payloads, prompt text, response bodies, DB URLs, or upstream provider payloads.
- One-time fields are allowed only at creation/login time: `session_token_once` and virtual key `secret`. Keep them in memory only, copy-on-demand, then discard.
- Lists and detail views should use redacted identifiers: `key_prefix`, `key_alias`, `code_redacted`, hashes, public ids, and status fields.
- Request payload preview is opt-in and metadata/redacted only. Default request/detail surfaces should rely on hashes, token counts, cost, route decision, provider attempts, and ledger summaries.
- Error UI should prefer safe fields: `error.code`, `error.message`, `gateway.error_owner`, `gateway.error_stage`, `gateway.retryable`, `http_status`, and local `retryable`.
- Treat `pending`, `config-needed`, `not_connected`, and `pending_scheduler` as product states, not failures. Show the server-provided `next_action` or safe operation copy.

## Importer Mapping Quality

Importer dry-run/apply-plan artifacts may include `mapping_quality_readback`, mirrored by the frontend DTO `ImporterMappingQualityReadback`.

UI should render it as a safe summary only: provider/channel/model/user/key/wallet/subscription mapping counts, conflict counts, non-migratable reason summaries, operator handoff ref presence, and `safe_next_action`. It is a readback surface, not an apply trigger.

The readback must keep `raw_provider_key_returned=false`, `raw_user_key_returned=false`, `token_returned=false`, `db_url_returned=false`, `raw_sql_returned=false`, and `authorization_returned=false`. Full SQL executor plans, when present in apply-plan artifacts, should remain behind operator review and should not be treated as mapping-quality readback content.

## Admin Table Handoff

Reusable admin tables should keep these client-side contracts stable:

```ts
type DataTableColumn = {
  id: string;
  label: string;
  locked?: boolean;
};

type SavedTableFilterState = Record<string, string>;

type TableBulkActionHandoff = {
  action: string;
  disabled?: boolean;
  reasonRequired?: boolean;
  scope: "visible_rows" | "selected_rows" | "filtered_result";
  selectedCount: number;
  status: "idle" | "ready" | "running" | "completed" | "blocked";
  totalCount?: number;
};
```

UI notes:

- Column visibility is a local UI preference. Locked columns must remain visible and should cover row selection, primary identity, and row actions.
- Sticky first column is supported for dense admin tables. Keep the first column secret-safe and useful on horizontal scroll.
- Saved filters are localStorage-backed, page-scoped, and string-only. They are for operator convenience, not a backend contract. Do not persist raw payloads, Authorization headers, provider keys, session tokens, voucher codes, or API key secrets in saved filters.
- Bulk action bars should publish the handoff state above before calling an API. Backend bulk responses should return per-row ids, safe prefixes/labels, status, action result, and audit refs where available; they must not return raw credential material or payloads.
- Current reference implementation lives in `web/admin-ui/src/design/DataTable.tsx` and `web/admin-ui/src/design/tableState.ts`. `RequestLogsPage` demonstrates saved filters; `VirtualKeysPage` demonstrates selected-row bulk action handoff and column visibility.
- MVP closure note, 2026-06-12: the current table experience is complete for local Admin MVP coverage. Remaining work is rollout to older pages, real backend bulk execution/readback, server-side pagination/sorting, and broader browser regression coverage.

## Auth

### Enterprise Identity Connections

`GET /admin/enterprise/identity-connections`

Use this as the Admin UI readback for enterprise OIDC/SAML setup cards. It is a runtime skeleton only: it does not connect to an IdP, does not accept raw tokens/assertions, and does not create sessions.

```ts
type EnterpriseIdentityConnectionsReadback = {
  schema: "enterprise_identity_connections_readback.v1" | string;
  tenant_id: string;
  status: "disabled" | "config-needed" | "validation-pending" | string;
  secret_safe: true;
  runtime_implemented: true;
  production_sso_verification_implemented: false;
  raw_tokens_or_assertions_accepted: false;
  connections: Array<{
    provider_type: "oidc" | "saml" | string;
    status: "disabled" | "config-needed" | "validation-pending" | string;
    config_needed: string[];
    metadata_url_present: boolean;
    mapped_roles: { configured: boolean; entry_count: number; values_returned: false };
    mapped_groups: { configured: boolean; entry_count: number; values_returned: false };
    next_step: string;
    raw_claims_returned: false;
    raw_tokens_or_assertions_returned: false;
    client_secret_returned: false;
    authorization_header_returned: false;
  }>;
  callback_exchange_boundary: {
    status: "rejected_until_real_validation" | string;
    raw_material_echoed: false;
    rejected_input: string[];
  };
  omitted_fields: string[];
  next_step: string;
};
```

UI rules:

- Show provider cards from `connections[]` with `provider_type`, `status`, `config_needed`, `metadata_url_present`, role/group mapping counts, and `next_step`.
- Treat `validation-pending` as "configuration shape exists but real token/assertion validation is still absent"; do not label it connected.
- Never render ID token values, access token values, SAMLResponse values, raw claims, client secrets, Authorization headers, or metadata XML bodies. The endpoint only returns presence/count/omission markers.

`GET /admin/enterprise/identity-connections/validation-plan`

Use this as the provider validation dry-run/config seam. It accepts no token/assertion body and performs no network requests. It reports presence-only readiness for OIDC issuer/client_id/JWKS metadata, SAML metadata/signature/cert config, role/group mapping readiness, and the disabled callback/ACS boundary.

```ts
type EnterpriseIdentityValidationPlan = {
  schema: "enterprise_identity_validation_plan.v1" | string;
  tenant_id: string;
  status: "disabled" | "config-needed" | "validation-pending" | string;
  secret_safe: true;
  dry_run_only: true;
  network_requests: false;
  raw_tokens_or_assertions_accepted: false;
  session_creation_implemented: false;
  providers: Array<{
    provider_type: "oidc" | "saml" | string;
    status: "disabled" | "config-needed" | "validation-pending" | string;
    enabled: boolean;
    config_needed: string[];
    validation_runtime_implemented: false;
    provider_specific: JsonValue;
    role_group_mapping: {
      status: "ready-for-validation" | "config-needed" | string;
      mapped_roles: { configured: boolean; entry_count: number; values_returned: false };
      mapped_groups: { configured: boolean; entry_count: number; values_returned: false };
      raw_claim_values_returned: false;
    };
    callback_or_acs_enabled: false;
    session_creation_implemented: false;
    raw_tokens_or_assertions_accepted: false;
    client_secret_returned: false;
    certificate_or_private_key_returned: false;
    authorization_header_returned: false;
    next_step: string;
  }>;
  callback_acs_boundary: {
    status: "disabled_until_real_validation" | string;
    raw_material_echoed: false;
    rejected_input: string[];
  };
  omitted_fields: string[];
  next_step: string;
};
```

UI rules:

- For OIDC, show presence booleans such as `issuer_present`, `client_id_present`, `jwks_uri_present`, and endpoint presence from `provider_specific`; never show client secret values.
- For SAML, show metadata, ACS, signature required/implemented, and cert presence from `provider_specific`; never show metadata XML or certificate bodies.
- Keep callback and ACS visibly disabled until real validation/exchange/session creation is implemented server-side.

`POST /admin/enterprise/identity-connections/oidc/validate-code-plan`

Use this as the bounded OIDC exchange/JWKS validation seam. It performs no network token exchange and creates no session. The request must contain only presence/hash metadata, for example `authorization_code_present`, `authorization_code_sha256`, `state_record_present`, `nonce_record_present`, `pkce_verifier_present`, `redirect_uri_present`, and optional fixture-safe `fixture_claims_summary` counts/booleans.

Do not send raw `code`, `authorization_code`, `id_token`, `access_token`, `refresh_token`, `claims`, `raw_claims`, `client_secret`, `code_verifier`, `Authorization`, private keys, cert bodies, or SAML fields; the API refuses those fields without echoing values.

```ts
type EnterpriseOidcValidateCodePlan = {
  schema: "enterprise_oidc_validate_code_plan.v1" | string;
  tenant_id: string;
  provider_type: "oidc";
  status: "ready-for-real-executor-implementation" | "plan-incomplete" | string;
  secret_safe: true;
  dry_run_only: true;
  network_requests: false;
  token_endpoint_called: false;
  jwks_fetched: false;
  session_created: false;
  raw_tokens_accepted: false;
  raw_claim_values_accepted: false;
  input_summary: {
    authorization_code_present: boolean;
    authorization_code_hash_present: boolean;
    state_record_present: boolean;
    nonce_record_present: boolean;
    pkce_verifier_present: boolean;
    redirect_uri_present: boolean;
    fixture_claims_summary_present: boolean;
    raw_values_returned: false;
  };
  authorization_code_exchange_plan: JsonValue;
  jwks_validation_plan: JsonValue;
  user_identity_binding_plan: JsonValue;
  session_binding_plan: JsonValue;
  omitted_fields: string[];
  next_step: string;
};
```

UI rules:

- Label this as a plan/dry-run surface, not connected enterprise login.
- Show `authorization_code_exchange_plan`, `jwks_validation_plan`, `user_identity_binding_plan`, and `session_binding_plan` as status/readiness panels.
- Never render raw token, raw code, raw claim, client secret, Authorization, private key, certificate body, or cookie/session material.

`POST /admin/enterprise/identity-connections/oidc/execute-validated-login`

Mockable runtime executor seam for OIDC after server-side fixture-safe JWKS validation. It accepts only `external_subject_hash`, optional local-user match `email`/`domain`, mapped role/group labels, `verified_claims_summary` presence/count booleans, structured `jwks_validation` metadata, and optional `jwt_jwks_parser_fetch` metadata containing `issuer_url`/`issuer`, `jwks_uri_ref`/`jwks_uri`, `kid`, `alg`, `audience`, `nonce`, `subject_hash`, and fixture-safe `crypto_parser` parsed metadata. `apply=true` may write/read back `user_identities` only when both the JWKS validator and crypto parser result pass; it never returns raw tokens, JWKS body, cookies, or bearer tokens.

`POST /admin/enterprise/identity-connections/oidc/jwks-validator-executor`

Bounded OIDC/JWKS validator executor readback. It uses the same fixture-safe request shape as execute-validated-login but performs validator readback only: no local binding write, no session issue, no IdP/JWKS network. Send only JWT header/claims summary metadata such as `kid`, `alg`, audience/issuer presence or safe refs, exp/iat unix timestamps, nonce presence/match or hash marker, `external_subject_hash`, `jwks_validation.jwks_key_fingerprint_present`, and `signature_verified` booleans.

The response includes `validator_result`, `blocked_reasons`, `identity_binding_handoff`, `session_issue_handoff`, legacy `binding_handoff_readiness` / `session_handoff_readiness`, and `omitted_fields`. `identity_binding_handoff` points at `POST /admin/enterprise/identity-bindings/plan` and explicitly returns `can_apply_binding`, `can_issue_session=false`, `blocked_reasons`, `safe_next_action`, and a fixture-safe summary limited to verified subject hash presence, issuer/audience presence, mapped role/group counts, and email-domain presence. `session_issue_handoff` points at `POST /admin/enterprise/identity-sessions/issue-plan`, but remains blocked until a local `user_identity` binding exists; this executor never creates a session. `[!]` Real IdP/JWKS network fetch, real token validation against provider keys, and release/live evidence remain open gaps.

`jwt_jwks_parser_fetch_adapter` is the typed OIDC/JWKS fetch/parse executor boundary. It returns `fetch_request_plan`, `parser_input_summary`, and `crypto_result_readback`; the default implementation always reports `network_enabled: false` and `network_call_performed: false`, so it is replaceable by a real fetcher later without making network calls now. `blocked_reasons` explicitly covers `missing_issuer`, `missing_jwks_uri`, `missing_kid`, `missing_alg`, `missing_audience`, `missing_nonce`, `unsupported_alg`, `nonce_mismatch`, `expired_token_metadata`, and `network_disabled`.

Do not send raw `code`, `authorization_code`, `id_token`, `access_token`, `refresh_token`, `claims`, `raw_claims`, raw `subject`/`sub`, raw email inside summaries, `client_secret`, `Authorization`, JWKS/JWK material or body, private keys, cert bodies, or SAML fields.

```ts
type EnterpriseOidcJwksValidatorExecutor = {
  schema: "enterprise_oidc_jwks_validator_executor.v1" | string;
  tenant_id: string;
  provider_type: "oidc";
  status: "validator-passed" | "validator-blocked" | string;
  secret_safe: true;
  runtime_implemented: true;
  mockable_executor: true;
  network_enabled: false;
  network_call_performed: false;
  idp_network_called: false;
  jwks_fetched: false;
  raw_token_accepted: false;
  raw_claims_accepted: false;
  jwks_or_jwk_body_accepted: false;
  client_secret_accepted: false;
  authorization_header_accepted: false;
  private_key_or_certificate_accepted: false;
  validator_result: JsonValue;
  blocked_reasons: string[];
  identity_binding_handoff: JsonValue;
  session_issue_handoff: JsonValue;
  binding_handoff_readiness: JsonValue;
  session_handoff_readiness: JsonValue;
  omitted_fields: string[];
  next_step: string;
};

type EnterpriseOidcExecuteValidatedLogin = {
  schema: "enterprise_oidc_validated_login_execution.v1" | string;
  tenant_id: string;
  provider_type: "oidc";
  status:
    | "binding-applied-session-disabled"
    | "binding-exists-session-disabled"
    | "ready-to-apply-session-disabled"
    | "local-user-not-found-session-disabled"
    | string;
  verified_claims_summary: JsonValue;
  jwks_validation_result: true;
  jwks_validator: JsonValue;
  jwt_jwks_crypto_parser_result: JsonValue;
  jwt_jwks_parser_fetch_adapter: JsonValue;
  verified_subject_hash_source: string;
  binding_result: EnterpriseIdentityBindingPlan;
  session_creation_disabled: true;
  session_created: false;
  session_blocked_reason: string;
  omitted_fields: string[];
};
```

UI rules:

- Treat this as the first runtime SSO seam, but keep login/session UX disabled.
- Show `jwks_validator.crypto_parser_result`, `jwt_jwks_crypto_parser_result`, and `jwt_jwks_parser_fetch_adapter.fetch_request_plan` / `parser_input_summary` / `crypto_result_readback` as the parser/crypto readiness panel. Failed parser result means no binding/session.
- Show `binding_result.user_identity_binding` readback and `session_blocked_reason`.
- Never render raw OIDC token/code/claim/JWKS material or cookies. `crypto_parser` input is limited to header alg/kid, claims issuer/audience/nonce presence-match, exp/iat unix timestamps, subject hash, JWKS key alg/kid, and signature status.

`POST /admin/enterprise/identity-connections/saml/validate-acs-plan`

Use this as the bounded SAML ACS/signature/assertion validation seam. It is not a login endpoint and must not create a session. The UI may send only presence booleans, SHA-256/fingerprint markers, metadata summaries, and fixture-safe assertion summaries.

```ts
type EnterpriseSamlValidateAcsPlanRequest = {
  saml_response_present?: boolean;
  saml_response_sha256?: string;
  assertion_present?: boolean;
  assertion_sha256?: string;
  idp_certificate_sha256?: string;
  metadata_summary?: Record<string, JsonValue>;
  fixture_assertion_summary?: Record<string, JsonValue>;
  issuer_present?: boolean;
  audience_present?: boolean;
  name_id_present?: boolean;
};

type EnterpriseSamlValidateAcsPlan = {
  schema: "enterprise_saml_validate_acs_plan.v1" | string;
  tenant_id: string;
  provider_type: "saml";
  status: "ready-for-real-executor-implementation" | "plan-incomplete" | string;
  secret_safe: true;
  dry_run_only: true;
  network_requests: false;
  xml_parsed: false;
  signature_verified: false;
  session_created: false;
  raw_saml_response_accepted: false;
  raw_assertion_accepted: false;
  raw_claim_values_accepted: false;
  input_summary: {
    saml_response_present: boolean;
    saml_response_hash_present: boolean;
    assertion_present: boolean;
    assertion_hash_present: boolean;
    metadata_summary_present: boolean;
    idp_certificate_fingerprint_present: boolean;
    fixture_assertion_summary_present: boolean;
    issuer_present: boolean;
    audience_present: boolean;
    name_id_present: boolean;
    attribute_summary_present: boolean;
    raw_values_returned: false;
  };
  xml_signature_validation_plan: JsonValue;
  assertion_validation_plan: JsonValue;
  attribute_mapping_plan: JsonValue;
  user_identity_binding_plan: JsonValue;
  session_binding_plan: JsonValue;
  omitted_fields: string[];
  next_step: string;
};
```

UI rules:

- Render `xml_signature_validation_plan`, `assertion_validation_plan`, `attribute_mapping_plan`, `user_identity_binding_plan`, and `session_binding_plan` as plan/status cards.
- Do not provide a raw SAMLResponse text box. Use upload/fixture tooling only to compute local hashes or presence summaries before calling this endpoint.
- Never send or display raw SAMLResponse, assertion XML, metadata XML, certificate body, private key, Authorization, client secret, tokens, raw NameID/email, or raw attribute values.

`POST /admin/enterprise/identity-connections/saml/execute-validated-acs`

Use this as the mockable SAML runtime executor after a server-side simulated validator has produced a safe assertion summary. It can read back or optionally apply the local `user_identities` binding through the same binding seam. It does not parse XML, call an IdP, accept raw SAML material, or create sessions.

```ts
type EnterpriseSamlExecuteValidatedAcsRequest = {
  signature_validation_result: true;
  assertion_validation_result?: boolean;
  issuer_validation_result?: boolean;
  audience_validation_result?: boolean;
  time_conditions_validation_result?: boolean;
  external_subject_hash: string;
  email?: string;
  domain?: string;
  mapped_groups?: string[];
  mapped_roles?: string[];
  parsed_assertion_summary?: Record<string, JsonValue>;
  metadata_trust?: {
    entity_id?: string;
    entity_id_present?: boolean;
    metadata_url?: string;
    metadata_url_present?: boolean;
    metadata_ref?: string;
    metadata_ref_present?: boolean;
    cert_fingerprint_prefix?: string;
    valid_from_present?: boolean;
    valid_to_present?: boolean;
    signature_alg?: "RS256" | "RS384" | "RS512" | "RSA-SHA256" | "RSA-SHA384" | "RSA-SHA512" | "ES256" | string;
    trust_status?: "ready" | "trusted" | "valid" | "verified" | string;
  };
  xml_signature_validation?: {
    signed_info_digest_present: boolean;
    canonicalization_alg?: "EXCLUSIVE-XML-C14N" | "EXCLUSIVE-XML-C14N11" | "XML-C14N" | "XML-C14N11" | string;
    signature_alg?: "RS256" | "RS384" | "RS512" | "RSA-SHA256" | "RSA-SHA384" | "RSA-SHA512" | "ES256" | string;
    reference_digest_valid: boolean;
    signature_value_valid: boolean;
    cert_fingerprint_matches_metadata: boolean;
  };
  verified_assertion_summary?: Record<string, JsonValue>;
  fixture_assertion_summary?: Record<string, JsonValue>;
  apply?: boolean;
};

type EnterpriseSamlExecuteValidatedAcs = {
  schema: "enterprise_saml_execute_validated_acs.v1" | string;
  tenant_id: string;
  provider_type: "saml";
  status: "binding-applied-session-disabled" | "binding-exists-session-disabled" | "ready-to-apply-session-disabled" | "local-user-not-found-session-disabled" | string;
  secret_safe: true;
  runtime_implemented: true;
  mock_executor: boolean;
  server_side_simulated_input_only: true;
  network_requests: false;
  raw_saml_response_accepted: false;
  raw_assertion_accepted: false;
  raw_claim_values_accepted: false;
  saml_validator: JsonValue;
  signature_validation: JsonValue;
  verified_assertion_summary: JsonValue;
  identity_binding_handoff: JsonValue;
  session_issue_handoff: JsonValue;
  user_identity_binding_readback: EnterpriseIdentityBindingPlan;
  session_binding: {
    session_creation_disabled: true;
    session_created: false;
    blocked_reason: string;
    cookie_returned: false;
  };
  omitted_fields: string[];
  next_step: string;
};
```

UI rules:

- Render this as an executor/readback surface, not an IdP login form.
- Allow `apply=true` only as an explicit local binding action for an existing user; show `identity_binding_handoff`, `session_issue_handoff`, and `session_binding.blocked_reason` after every call. `identity_binding_handoff` points at `POST /admin/enterprise/identity-bindings/plan`; `session_issue_handoff` points at `POST /admin/enterprise/identity-sessions/issue-plan` and only sets `can_issue_session=true` when the ACS validator passed and the local binding readback found or applied a bound identity. The ACS executor itself still creates no session and returns no cookie/token.
- Require `saml_validator.checks.metadata_cert_trust_chain.passed=true` before enabling any local binding action. This is typed metadata/cert trust readiness only: never send raw metadata XML, certificate bodies, private keys, raw SAML assertions, raw NameID/email, raw attributes, or Authorization/client secret material.
- Require `saml_validator.checks.xml_signature_validation.passed=true` before enabling any local binding action. This is typed cryptographic result metadata only: never send raw SignedInfo XML, signature bytes, raw SAMLResponse/assertion XML, certificate bodies, or private keys.
- Never send or display raw SAMLResponse, assertion XML, metadata XML, certificate body, private key, Authorization, client secret, raw NameID/email, raw attributes, tokens, or session cookies.

`POST /admin/enterprise/identity-bindings/plan`

Use this after bounded OIDC/SAML validation planning to preview or apply a local `user_identities` binding. The request accepts only fixture-safe identity summary material: `provider_type`, `external_subject_hash`, optional `email`/`domain`, `mapped_groups`, `mapped_roles`, optional `fixture_subject_summary`, and `apply`.

```ts
type EnterpriseIdentityBindingPlanRequest = {
  provider_type: "oidc" | "saml" | string;
  external_subject_hash: string;
  email?: string;
  domain?: string;
  mapped_groups?: string[];
  mapped_roles?: string[];
  fixture_subject_summary?: Record<string, JsonValue>;
  apply?: boolean;
};

type EnterpriseIdentityBindingPlan = {
  schema: "enterprise_identity_binding_plan.v1" | string;
  tenant_id: string;
  status: "binding-applied" | "binding-exists" | "matched-local-user" | "ready-to-apply" | "local-user-not-found" | string;
  secret_safe: true;
  dry_run: boolean;
  apply_requested: boolean;
  runtime_implemented: true;
  provider_type: "oidc" | "saml" | string;
  input_summary: {
    external_subject_hash_present: true;
    email_present: boolean;
    domain?: string | null;
    mapped_group_count: number;
    mapped_role_count: number;
    fixture_subject_summary_present: boolean;
    raw_subject_returned: false;
    raw_email_returned: false;
    raw_group_or_role_values_returned: false;
  };
  matched_user: {
    status: "matched" | "not-found" | string;
    user_id?: string | null;
    source: "email" | "user_identity" | "none" | string;
    email_present: boolean;
    display_name_present: boolean;
    raw_email_returned: false;
  };
  user_identity_binding: {
    status: string;
    lookup: "user_identities(provider, provider_subject, tenant_id)" | string;
    identity_id?: string | null;
    existing_binding: boolean;
    applied: boolean;
    would_create_user: false;
    create_user_disabled: true;
    idempotent: true;
    metadata_written: boolean;
    raw_subject_returned: false;
    raw_claims_returned: false;
  };
  role_group_mapping_result: JsonValue;
  session_binding: {
    session_creation_disabled: true;
    session_created: false;
    requires_completed_oidc_or_saml_validation: true;
    cookie_returned: false;
  };
  audit_id?: string | null;
  omitted_fields: string[];
  next_step: string;
};
```

UI rules:

- Default to `apply=false`; use `apply=true` only after confirming the local user match.
- `apply=true` links an existing local user found by email to `user_identities`; it never creates a user or session.
- Never send or display raw tokens, assertions, claims, raw subject, raw email inside fixture summaries, Authorization, client secrets, private keys, certificate bodies, or raw group/role values.

`POST /admin/enterprise/identity-sessions/issue-plan`

Use this after a verified OIDC/SAML executor has produced a bound `user_identity`. The request accepts only one lookup shape plus a safe executor marker:

```ts
type EnterpriseIdentitySessionIssuePlanRequest =
  | { user_identity_id: string; verified_by: "oidc_mock_executor" | "saml_mock_executor"; idempotency_key?: string; apply?: boolean }
  | { user_id: string; provider_type: "oidc" | "saml"; external_subject_hash: string; verified_by: "oidc_mock_executor" | "saml_mock_executor"; idempotency_key?: string; apply?: boolean };

type EnterpriseIdentitySessionIssuePlan = {
  schema: "enterprise_identity_session_issue_plan.v1" | string;
  tenant_id: string;
  status: "identity-binding-not-found" | "bound-user-not-active" | "session-issue-ready" | "session-issued" | "session-replayed" | string;
  secret_safe: true;
  runtime_implemented: true;
  dry_run: boolean;
  apply_requested: boolean;
  provider_type: "oidc" | "saml";
  verified_by: "oidc_mock_executor" | "saml_mock_executor";
  session_id: string | null;
  expires_at: string | null;
  input_summary: Record<string, JsonValue>;
  tenant_user_binding_summary: Record<string, JsonValue>;
  role_group_mapping_summary: JsonValue;
  session_policy: {
    status: "active" | "not-created" | string;
    session_creation_disabled: false;
    session_creation_disabled_reason: string | null;
    bounded_session_creation_available: true;
    session_created: boolean;
    session_id: string | null;
    session_status: string | null;
    session_expires_at: string | null;
    session_replayed: boolean;
    cookie_returned: false;
    authorization_returned: false;
    raw_token_or_assertion_returned: false;
    raw_session_token_returned: false;
    idempotency_key_hash_present: boolean;
    raw_idempotency_key_returned: false;
    readback_source: "user_sessions" | "plan_only" | string;
    write_behavior: "bounded_user_session_insert" | "idempotent_replay" | "dry_run_only" | string;
  };
  audit_id: string | null;
  readback: {
    readback_path: "POST /admin/enterprise/identity-sessions/issue-plan" | string;
    audit_readback_path: "GET /admin/audit-logs" | string;
    session_readback_path: "user_sessions(metadata.enterprise_identity_session_idempotency_key_hash)" | string;
    audit_action: "enterprise_identity.session_issued" | "none" | string;
    audit_marker_written: false;
    audit_written: boolean;
    session_creation_disabled: false;
    session_created: boolean;
    session_id: string | null;
    user_identity_id: string | null;
    verified_by: "oidc_mock_executor" | "saml_mock_executor" | string | null;
    idempotency_key_fingerprint: string | null;
    raw_session_token_returned: false;
    raw_idempotency_key_returned: false;
  };
  omitted_fields: string[];
  next_step: string;
};
```

UI rules:

- Default to `apply=false`. `apply=true` creates or replays a bounded local `user_sessions` row and returns only safe readback fields.
- Require `verified_by` to match the provider (`oidc_mock_executor` for OIDC, `saml_mock_executor` for SAML).
- Never send or display raw token/assertion/claims/subject, Authorization, client secret, private key, cert body, cookie, bearer token, raw idempotency key, or session secret.

### Enterprise Accounts

`GET /admin/enterprise/accounts`

Optional filters: `sales_stage`, `sso_status`, `billing_status`.

Use this as the minimal Admin UI readback contract for a multi-tenant sales backend account card/table. It does not connect to an external CRM network; it summarizes local control-plane tenant/account state, the local CRM adapter table `enterprise_sales_activities`, and the tenant-scoped external CRM adapter config source-of-truth.

```ts
type EnterpriseAccountsReadback = {
  schema: "admin_enterprise_accounts_readback.v1" | string;
  tenant_id: string;
  status: "customer-ready" | "trial-ready" | "attention" | "config-needed" | string;
  secret_safe: true;
  runtime_implemented: true;
  crm_connected: false;
  external_sales_system_connected: false;
  filters?: {
    sales_stage?: string | null;
    sso_status?: string | null;
    billing_status?: string | null;
    supported?: {
      sales_stage: string[];
      sso_status: string[];
      billing_status: string[];
    };
  };
  filtered_out_count?: number;
  accounts: Array<{
    tenant_id: string;
    tenant_name: string;
    tenant_slug: string;
    tenant_status: string;
    account_status?: "prospect" | "onboarding" | "trial" | "active" | "suspended" | "churn-risk" | "closed" | string;
    account_name: string;
    account_slug: string;
    account_owner?: string | null;
    account_owner_summary?: {
      present: boolean;
      sha256?: string | null;
      hash_prefix?: string | null;
      email_domain?: string | null;
      raw_returned: false;
    };
    admin_contact_summary?: {
      present: boolean;
      sha256?: string | null;
      hash_prefix?: string | null;
      email_domain?: string | null;
      raw_returned: false;
    };
    plan: {
      status: "active" | "pending" | "not-configured" | string;
      tier?: "not-configured" | "starter" | "team" | "business" | "enterprise" | "custom" | string;
      plan_id?: string | null;
      plan_code?: string | null;
      display_name?: string | null;
      billing_interval?: string | null;
      currency?: string | null;
      unit_price?: string | null;
      source: "subscriptions_and_subscription_plans" | string;
      raw_plan_metadata_returned: false;
    };
    workspace_linkage?: {
      source: "projects" | string;
      status: "linked" | "not-linked" | string;
      workspace_count: number;
      active_workspace_count: number;
      tenant_scoped: true;
      readback_path: "GET /admin/enterprise/accounts" | string;
      create_path: "POST /admin/enterprise/accounts" | string;
      project_metadata_returned: false;
      workspaces: Array<{
        workspace_id: string;
        workspace_name: string;
        workspace_status: string;
        tenant_id: string;
        tenant_scoped: true;
        project_metadata_returned: false;
      }>;
    };
    provisioning_or_invite_handoff: {
      schema: "admin_enterprise_provisioning_or_invite_handoff.v1" | string;
      status: "readback-ready" | "action-required" | "blocked" | "filtered-out" | string;
      secret_safe: true;
      account_status: "prospect" | "onboarding" | "trial" | "active" | "suspended" | "churn-risk" | "closed" | "filtered-out" | string;
      provisioning_status: "applied" | "local_records_present_audit_missing" | "not_applied" | "filtered-out" | string;
      invite_delivery_status: "delivery_planned" | "send_required" | "no_invited_users" | "no_target_users" | "filtered-out" | string;
      retry_reason?: "provisioning_audit_ref_missing" | "invite_delivery_adapter_not_connected" | string | null;
      refusal_reason?: "provisioning_not_applied" | "invite_target_user_missing" | "invite_target_not_in_invited_status" | string | null;
      next_action: string;
      audit_refs: {
        provisioning_apply_audit_ref_present: boolean;
        provisioning_apply_audit_id?: string | null;
        invite_delivery_audit_ref_present: boolean;
        invite_delivery_audit_id?: string | null;
        source: "audit_logs" | string;
        raw_metadata_returned: false;
      };
      local_record_refs: {
        tenant_id_present: boolean;
        workspace_ref_present: boolean;
        user_ref_present: boolean;
        invited_user_ref_present: boolean;
        project_member_ref_present: boolean;
        source: "tenants/projects/users/project_members" | "filtered" | string;
      };
      side_effects: {
        email_sent: false;
        crm_connected: false;
        external_email_provider_called: false;
        network_requests_executed: false;
      };
      omitted_fields: string[];
    };
    sales: {
      stage: "not-connected" | "lead" | "qualified" | "trial" | "negotiation" | "customer" | "churn-risk" | string;
      source: "env_allowlist" | "tenant_metadata_allowlist" | string;
      local_metadata_write_path?: "PATCH /admin/enterprise/accounts" | string;
      account_notes_present?: boolean;
      local_crm_adapter?: {
        adapter: "enterprise_sales_activities" | string;
        write_path: "PATCH /admin/enterprise/accounts" | string;
        tenant_scoped: true;
        external_crm_connected: false;
        raw_external_payload_returned: false;
      };
      external_crm_adapter?: {
        source: "enterprise_external_crm_adapters" | string;
        id?: string;
        provider?: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | string | null;
        status: "enabled" | "disabled" | "not-configured" | string;
        crm_connected: boolean;
        adapter_kind?: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | string | null;
        endpoint_ref_present: boolean;
        typed_client_ready?: boolean;
        blocked_reason?: string | null;
        adapter_readiness?: {
          adapter_kind: string;
          readiness: "ready-for-request-plan" | "blocked" | string;
          unsupported_reason?: string | null;
          blocked_reason?: string | null;
          network_requests_executed: false;
        };
        secret_ref_present: boolean;
        webhook_ref_present: boolean;
        sync_direction?: "read-only" | "write-only" | "bidirectional" | "webhook-only" | string | null;
        last_sync_marker_present: boolean;
        last_sync_marker?: string | null;
        disabled_at?: string | null;
        updated_at?: string;
        readback_path?: "GET /admin/enterprise/accounts" | string;
        write_path?: "PATCH /admin/enterprise/accounts" | string;
        tenant_scoped?: true;
        network_requests_executed: false;
        secret_returned: false;
        authorization_header_returned: false;
        raw_external_payload_returned: false;
      };
      activity: {
        source: "enterprise_sales_activities" | string;
        write_path?: "PATCH /admin/enterprise/accounts" | string;
        activity_count?: number;
        last_contact_at?: string | null;
        next_action?: string | null;
        next_action_due_at?: string | null;
        recent: Array<{
          id: string;
          activity_type: "call" | "email" | "meeting" | "note" | "task" | "stage-change" | "renewal-review" | string;
          status: "open" | "planned" | "completed" | "cancelled" | string;
          summary: string;
          owner?: string | null;
          next_action?: string | null;
          occurred_at: string;
          due_at?: string | null;
          created_at: string;
          raw_external_payload_returned: false;
        }>;
        recent_limit?: number;
        tenant_scoped?: true;
        external_crm_connected?: false;
        raw_external_payload_returned: false;
      };
      crm_connected: false;
      external_crm_payload_returned: false;
      next_step: string;
    };
    sso_readiness: {
      status: "disabled" | "config-needed" | "validation-pending" | string;
      identity_connections_path: "GET /admin/enterprise/identity-connections" | string;
      oidc_status: string;
      saml_status: string;
      production_sso_verification_implemented: false;
      raw_tokens_or_assertions_returned: false;
      client_secret_returned: false;
      authorization_header_returned: false;
      next_step: string;
    };
    billing_readiness: {
      status: "config-needed" | "plan-needed" | "runtime-records-pending" | "local-readback-ready" | string;
      active_wallet_count: number;
      active_subscription_count: number;
      latest_subscription_status?: string | null;
      invoice_count: number;
      receipt_count: number;
      merchant_connected: false;
      pending_scheduler: true;
      raw_invoice_metadata_returned: false;
      raw_payment_payload_returned: false;
      next_step: string;
    };
    seat_summary: {
      seat_limit?: number | null;
      seats_used: number;
      available_seats?: number | null;
      user_count: number;
      active_user_count: number;
      invited_user_count: number;
      disabled_user_count: number;
      project_member_count: number;
      source: "users_and_project_members" | string;
      raw_user_metadata_returned: false;
    };
    quota_summary: {
      status: "ready" | "attention" | "exhausted" | "config-needed" | string;
      quota_unit: "tokens_30d" | string;
      quota_limit?: number | null;
      monthly_spend_quota?: string | null;
      request_count_30d: number;
      success_count_30d: number;
      total_tokens_30d: number;
      spend_30d: string;
      currency: string;
      active_virtual_key_count: number;
      active_profile_count: number;
      project_count: number;
      active_project_count: number;
      source: "request_logs_virtual_keys_profiles_projects" | string;
      raw_request_payload_returned: false;
      authorization_header_returned: false;
    };
    next_step: string;
  }>;
  omitted_fields: string[];
  next_step: string;
};
```

`POST /admin/enterprise/accounts`

Use this to initialize the current admin tenant's enterprise account lifecycle metadata and optionally ensure a default workspace/project linkage. It is tenant-scoped; the UI must not use it as a cross-tenant account creator.

```ts
type CreateEnterpriseAccountRequest = {
  account_status?: "prospect" | "onboarding" | "trial" | "active" | "suspended" | "churn-risk" | "closed" | string;
  account_name?: string;
  account_slug?: string;
  account_owner?: string;
  admin_contact_email?: string;
  account_notes?: string;
  plan_tier?: "not-configured" | "starter" | "team" | "business" | "enterprise" | "custom" | string;
  sales_stage?: string;
  sales_activity?: PatchEnterpriseAccountRequest["sales_activity"];
  seat_limit?: number;
  monthly_token_quota?: number;
  monthly_spend_quota?: string;
  ensure_default_workspace?: boolean;
  workspace_name?: string;
};

type EnterpriseAccountLifecycleCreate = {
  schema: "admin_enterprise_account_lifecycle_create.v1" | string;
  tenant_id: string;
  status: "created-or-updated" | "unchanged" | string;
  secret_safe: true;
  runtime_implemented: true;
  tenant_scoped: true;
  updated_fields: string[];
  account: EnterpriseAccountMetadataUpdate["account"];
  workspace?: {
    workspace_id: string;
    tenant_id: string;
    workspace_name: string;
    workspace_status: string;
    source: "projects" | string;
    tenant_scoped: true;
    project_metadata_returned: false;
  } | null;
  sales_activity?: EnterpriseAccountMetadataUpdate["sales_activity"];
  audit_id: string;
  readback_path: "GET /admin/enterprise/accounts" | string;
  patch_path: "PATCH /admin/enterprise/accounts" | string;
  accepted_fields: string[];
  omitted_fields: string[];
  next_step: string;
};
```

`POST /admin/enterprise/accounts/provisioning-plan`

`POST /admin/enterprise/accounts/provisioning-apply`

Use this as the admin-only sales-backend seam for cross-tenant enterprise account provisioning. `provisioning-plan` is dry-run/read-only. `provisioning-apply` creates or reuses local `tenants`, `projects`, `users(status=invited)`, `project_members`, and an `audit_logs` idempotency marker. It never sends email and never returns raw contact or idempotency material.

```ts
type EnterpriseAccountProvisioningRequest = {
  tenant_slug: string;
  tenant_name: string;
  workspace_name: string;
  owner_contact_email?: string;
  admin_contact_email: string;
  sales_stage: "not-connected" | "lead" | "qualified" | "trial" | "negotiation" | "customer" | "churn-risk" | string;
  plan_tier: "not-configured" | "starter" | "team" | "business" | "enterprise" | "custom" | string;
  idempotency_key: string;
};

type EnterpriseAccountProvisioningPlan = {
  schema: "admin_enterprise_account_provisioning_plan.v1" | string;
  mode: "dry_run" | "apply" | "replay" | string;
  status: "planned" | "applied" | "replayed" | string;
  secret_safe: true;
  runtime_implemented: true;
  admin_only: true;
  operator_tenant_id: string;
  target_tenant_id?: string | null;
  tenant: {
    tenant_slug: string;
    tenant_name: string;
    exists: boolean;
    would_create: boolean;
    would_update: boolean;
    source: "tenants" | string;
  };
  workspace: {
    workspace_name: string;
    exists: boolean;
    would_create: boolean;
    would_update: boolean;
    source: "projects" | string;
  };
  admin_invite: {
    admin_contact_summary: EnterpriseAccountContactSummary;
    owner_contact_summary: EnterpriseAccountContactSummary;
    local_user_exists: boolean;
    would_create: boolean;
    would_update: boolean;
    email_delivery: "not_attempted" | string;
    raw_email_returned: false;
    source: "users/project_members" | string;
  };
  sales_stage: string;
  plan_tier: string;
  idempotency: {
    fingerprint: string;
    marker_exists: boolean;
    replay_safe: true;
    raw_key_returned: false;
    hash_returned: false;
    marker_source: "audit_logs.metadata.idempotency_fingerprint" | string;
  };
  db_effects: {
    would_create: Record<string, boolean>;
    would_update: Record<string, boolean>;
    apply_writes: Array<"tenants" | "projects" | "users" | "project_members" | "audit_logs" | string>;
    bounded_marker_only: boolean;
    email_sent: false;
  };
  audit_id?: string | null;
  plan_path: "POST /admin/enterprise/accounts/provisioning-plan" | string;
  apply_path: "POST /admin/enterprise/accounts/provisioning-apply" | string;
  readback_path: "GET /admin/enterprise/accounts" | string;
  omitted_fields: string[];
  next_step: string;
};
```

UI notes:

- Treat `idempotency.fingerprint` as the only displayable operation marker; never display or persist the raw `idempotency_key` after submission.
- `admin_invite.email_delivery` is always `not_attempted` in this slice. Do not show "email sent" copy.
- `provisioning-apply` replay with the same marker returns `mode="replay"` and must not be presented as a duplicate create.
- `GET /admin/enterprise/accounts` also returns `provisioning_or_invite_handoff`, a safe readback that combines account status, provisioning marker presence, invite delivery marker presence/status, retry/refusal reason, and next action. It never returns raw email/contact, Authorization, secret, CRM payload, provider payload, raw audit metadata, or raw idempotency material.

`POST /admin/enterprise/accounts/invite-delivery-plan`

`POST /admin/enterprise/accounts/invite-delivery-apply`

Use this as the local invite delivery plan/readback seam after provisioning. `invite-delivery-plan` is read-only. `invite-delivery-apply` writes only an `audit_logs` marker for local planned/queued delivery and is replay-safe. It never sends email, never calls an email provider, and never returns raw contact or idempotency material.

```ts
type EnterpriseInviteDeliveryRequest = {
  tenant_id?: string;
  tenant_slug?: string;
  workspace_id?: string;
  workspace_name?: string;
  target_user_id?: string;
  target_user_email?: string;
  delivery_request_id?: string;
  idempotency_key?: string;
};

type EnterpriseInviteDeliveryPlan = {
  schema: "admin_enterprise_invite_delivery_plan.v1" | string;
  mode: "dry_run" | "apply" | "replay" | string;
  status: "planned" | "replayed" | string;
  secret_safe: true;
  runtime_implemented: true;
  admin_only: true;
  tenant_ref: JsonValue;
  workspace_ref: JsonValue;
  target_user_refs: JsonValue[];
  invite_status: "send_required" | "delivery_planned" | "already_exists" | "blocked" | "no_target_users" | string;
  would_send: boolean;
  blocked_reasons: string[];
  idempotency_fingerprint: string;
  delivery_adapter_readiness: "local_only" | "blocked" | "no_provider" | string;
  delivery_adapter: {
    mode: "local_only" | string;
    external_provider_status: "no_provider" | string;
    provider_request_created: false;
    email_sent: false;
    raw_email_returned: false;
    raw_contact_returned: false;
  };
  idempotency: {
    fingerprint: string;
    marker_exists: boolean;
    marker_audit_id?: string | null;
    replay_safe: true;
    raw_key_returned: false;
    hash_returned: false;
  };
  db_effects: {
    plan_writes: [];
    apply_writes: ["audit_logs" | string];
    bounded_marker_only: true;
    creates_or_updates_users: false;
    creates_or_updates_project_members: false;
    email_sent: false;
  };
  plan_path: "POST /admin/enterprise/accounts/invite-delivery-plan" | string;
  apply_path: "POST /admin/enterprise/accounts/invite-delivery-apply" | string;
  readback_path: "POST /admin/enterprise/accounts/invite-delivery-plan" | string;
  audit_id?: string | null;
  omitted_fields: string[];
  next_step: string;
};
```

UI notes:

- Display `would_send=true` as "needs invite delivery" only, not as sent mail.
- Use `target_user_refs[]` and `blocked_reasons[]` for the operator readback. Do not render `target_user_email` after submission.
- `delivery_adapter_readiness="local_only"` means the backend can plan/mark local delivery only. There is no external email provider in this slice.

`PATCH /admin/enterprise/accounts`

Use this for local sales/account writes. The request updates only allowlisted `tenants.metadata` keys for the current admin tenant and can append one row to `enterprise_sales_activities` for the same tenant:

```ts
type PatchEnterpriseAccountRequest = {
  account_status?: "prospect" | "onboarding" | "trial" | "active" | "suspended" | "churn-risk" | "closed" | string;
  account_name?: string;
  account_slug?: string;
  account_owner?: string;
  admin_contact_email?: string;
  account_notes?: string;
  plan_tier?: "not-configured" | "starter" | "team" | "business" | "enterprise" | "custom" | string;
  sales_stage?: "not-connected" | "lead" | "qualified" | "trial" | "negotiation" | "customer" | "churn-risk" | string;
  sales_activity?: {
    activity_type: "call" | "email" | "meeting" | "note" | "task" | "stage-change" | "renewal-review" | string;
    status?: "open" | "planned" | "completed" | "cancelled" | string;
    summary: string;
    owner?: string;
    next_action?: string;
    occurred_at?: string;
    due_at?: string;
    external_reference_hash?: string;
  };
  external_crm_adapter?: {
    provider: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | string;
    status: "enabled" | "disabled" | string;
    endpoint_ref_present?: boolean;
    secret_ref_present?: boolean;
    webhook_ref_present?: boolean;
    sync_direction?: "read-only" | "write-only" | "bidirectional" | "webhook-only" | string;
    last_sync_marker?: string;
  };
  external_crm_sync_run?: {
    operation?: "sync-activities" | "import-activities" | "export-activities" | "webhook-readback" | string;
    direction?: "read-only" | "write-only" | "bidirectional" | "webhook-only" | string;
    external_ids_hash?: string;
    sync_marker?: string;
    updated_count?: number;
    skipped_count?: number;
    provider_response_summary?: {
      imported_count?: number;
      updated_count?: number;
      skipped_count?: number;
      failed_count?: number;
      next_cursor_hash?: string;
      next_sync_marker_hash?: string;
      rate_limit_present?: boolean;
      rate_limit_reset_present?: boolean;
      provider_error_category?: "none" | "auth" | "permission" | "rate-limit" | "validation" | "not-found" | "conflict" | "server" | "unknown" | string;
    };
    provider_response_parser?: {
      status?: "not-provided" | "success" | "partial" | "rate-limited" | "provider-error" | "auth-error" | "blocked" | string;
      retry_after_seconds?: number;
      rate_limit_present?: boolean;
      rate_limit_reset_present?: boolean;
      rate_limit_remaining_present?: boolean;
      cursor_present?: boolean;
      imported_count?: number;
      updated_count?: number;
      skipped_count?: number;
      failed_count?: number;
      external_id_count?: number;
      external_id_created_count?: number;
      external_id_updated_count?: number;
      external_id_skipped_count?: number;
      next_cursor_hash?: string;
      next_sync_marker_hash?: string;
      provider_error_category?: "none" | "auth" | "permission" | "rate-limit" | "validation" | "not-found" | "conflict" | "server" | "unknown" | string;
      safe_next_action?: string;
    };
    imported_activity_summary?: {
      activity_type: "call" | "email" | "meeting" | "note" | "task" | "stage-change" | "renewal-review" | string;
      status?: "open" | "planned" | "completed" | "cancelled" | string;
      summary: string;
      owner?: string;
      next_action?: string;
      occurred_at?: string;
      due_at?: string;
      external_reference_hash?: string;
    };
  };
  seat_limit?: number;
  monthly_token_quota?: number;
  monthly_spend_quota?: string;
};

type EnterpriseAccountMetadataUpdate = {
  schema: "admin_enterprise_account_metadata_update.v1" | string;
  tenant_id: string;
  status: "updated" | string;
  secret_safe: true;
  runtime_implemented: true;
  crm_connected: false;
  external_sales_system_connected: false;
  updated_fields: string[];
  account: {
    tenant_metadata_fields_returned: false;
    account_status?: string;
    account_name_present: boolean;
    account_slug_present: boolean;
    account_owner_present: boolean;
    account_owner_summary?: unknown;
    admin_contact_summary?: unknown;
    account_notes_present: boolean;
    plan_tier?: string;
    sales_stage: string;
    seat_limit_present: boolean;
    monthly_token_quota_present: boolean;
    monthly_spend_quota_present: boolean;
    raw_notes_returned: false;
    secret_safe: true;
  };
  sales_activity?: {
    id: string;
    tenant_id: string;
    activity_type: string;
    status: string;
    summary: string;
    owner?: string | null;
    next_action?: string | null;
    occurred_at: string;
    due_at?: string | null;
    created_at: string;
    audit_id: string;
    readback_path: "GET /admin/enterprise/accounts" | string;
    tenant_scoped: true;
    external_crm_connected: false;
    raw_external_payload_returned: false;
  } | null;
  external_crm_adapter?: {
    source: "enterprise_external_crm_adapters" | string;
    id?: string;
    tenant_id?: string;
    provider?: string | null;
    status: "enabled" | "disabled" | "not-configured" | string;
    crm_connected: boolean;
    secret_ref_present: boolean;
    webhook_ref_present: boolean;
    sync_direction?: string | null;
    last_sync_marker_present: boolean;
    last_sync_marker?: string | null;
    audit_id?: string;
    readback_path: "GET /admin/enterprise/accounts" | string;
    tenant_scoped: true;
    network_requests_executed: false;
    secret_returned: false;
    authorization_header_returned: false;
    raw_external_payload_returned: false;
  } | null;
  external_crm_sync_run?: {
    source: "enterprise_crm_sync_runs" | string;
    id: string;
    tenant_id: string;
    adapter_id?: string | null;
    adapter_kind: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
    operation: "sync-activities" | "import-activities" | "export-activities" | "webhook-readback" | string;
    provider: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
    direction: "read-only" | "write-only" | "bidirectional" | "webhook-only" | string;
    status: "running" | "completed" | "refused" | string;
    would_call: boolean;
    http_request_plan?: {
      adapter_kind: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
      operation: "sync-activities" | "import-activities" | "export-activities" | "webhook-readback" | string;
      direction: "read-only" | "write-only" | "bidirectional" | "webhook-only" | string;
      method: "GET" | "POST" | string;
      path_or_endpoint_ref: string;
      endpoint_ref_present: boolean;
      headers_required_presence: {
        authorization: boolean;
        authorization_secret_ref_present: boolean;
        content_type_json: boolean;
        provider_version_header: boolean;
        raw_header_values_returned: false;
      };
      body_shape: {
        kind: "query_or_marker_summary" | "activity_write_summary" | string;
        fields: string[];
        external_ids_hash_present: boolean;
        sync_marker_present: boolean;
        imported_activity_summary_present: boolean;
        raw_body_returned: false;
        raw_external_payload_returned: false;
      };
      idempotency_fingerprint: string;
      would_send: boolean;
      would_call?: boolean;
      blocked: boolean;
      blocked_reason?: string | null;
      network_requests_executed: false;
      raw_endpoint_url_returned: false;
      authorization_header_returned: false;
      secret_returned: false;
      raw_external_payload_returned: false;
    };
    http_executor_boundary?: {
      schema: "enterprise_crm_http_executor_boundary.v1" | string;
      implementation: "network_disabled_request_builder_readback" | string;
      request_builder: {
        method: "GET" | "POST" | string;
        path_or_endpoint_ref: string;
        endpoint_ref_present: boolean;
        headers_required_presence: object;
        body_shape: object;
        timeout: {
          connect_timeout_ms: number;
          request_timeout_ms: number;
          source: "bounded_default_readback" | string;
        };
        raw_endpoint_url_returned: false;
        authorization_header_returned: false;
        secret_returned: false;
        raw_request_body_returned: false;
        raw_external_payload_returned: false;
      };
      retry_summary: {
        retry_recommended: boolean;
        backoff_reason: string;
        max_attempts: number;
        next_retry_after_seconds?: number | null;
        reset_at_present: boolean;
        attempt_status: string;
        attempt_count: number;
      };
      network_enabled: false;
      network_call_performed: false;
      network_requests_executed: false;
      would_send_if_enabled: boolean;
      blocked: boolean;
      blocked_reason?: string | null;
      raw_response_body_returned: false;
      raw_headers_returned: false;
      raw_endpoint_url_returned: false;
      authorization_header_returned: false;
      secret_returned: false;
      raw_request_body_returned: false;
      raw_external_payload_returned: false;
    };
    blocked_reason?: string | null;
    endpoint_ref_present: boolean;
    secret_ref_present: boolean;
    external_ids_hash_present: boolean;
    external_ids_hash?: string | null;
    started_at: string;
    completed_at?: string | null;
    imported_activity_count: number;
    updated_count: number;
    skipped_count: number;
    failed_count: number;
    provider_response_parser?: {
      schema: "enterprise_crm_provider_response_parser.v1" | string;
      input_source: "external_crm_sync_run.provider_response_parser" | "external_crm_sync_run.provider_response_summary" | "fixture_safe_request_counts" | string;
      adapter_kind: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
      provider: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
      normalized_provider: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "not-configured" | string;
      status: "not-provided" | "success" | "partial" | "rate-limited" | "provider-error" | "auth-error" | "blocked" | string;
      retry_after: { present: boolean; seconds?: number | null; raw_header_returned: false };
      rate_limit: { present: boolean; reset_present: boolean; remaining_present: boolean; raw_headers_accepted: false; raw_headers_returned: false };
      cursor: { present: boolean; next_cursor_hash_present: boolean; next_cursor_hash?: string | null; next_sync_marker_hash_present: boolean; next_sync_marker_hash?: string | null; raw_cursor_accepted: false; raw_cursor_returned: false };
      external_id_counts: { total: number; created: number; updated: number; skipped: number };
      result_counts: { imported: number; updated: number; skipped: number; failed: number };
      provider_error: { present: boolean; category: "none" | "auth" | "permission" | "rate-limit" | "validation" | "not-found" | "conflict" | "server" | "unknown" | string };
      safe_next_action: string;
      network_requests_executed: false;
      raw_response_body_accepted: false;
      raw_response_body_returned: false;
      raw_headers_accepted: false;
      raw_headers_returned: false;
      raw_payload_accepted: false;
      raw_external_payload_returned: false;
      raw_cursor_accepted: false;
      raw_cursor_returned: false;
      raw_endpoint_url_returned: false;
      authorization_header_returned: false;
      secret_returned: false;
    };
    provider_response_reducer?: {
      schema: "enterprise_crm_provider_response_reducer.v1" | string;
      adapter_kind: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
      provider: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
      would_call: boolean;
      outcome: "succeeded" | "partial" | "failed" | "blocked" | string;
      blocked: boolean;
      blocked_reason?: string | null;
      imported_count: number;
      updated_count: number;
      skipped_count: number;
      failed_count: number;
      next_cursor_hash_present: boolean;
      next_cursor_hash?: string | null;
      next_sync_marker_hash_present: boolean;
      next_sync_marker_hash?: string | null;
      rate_limit: {
        present: boolean;
        reset_present: boolean;
        raw_headers_returned: false;
      };
      provider_error: {
        present: boolean;
        category?: "none" | "auth" | "permission" | "rate-limit" | "validation" | "not-found" | "conflict" | "server" | "unknown" | string | null;
      };
      input_source: "external_crm_sync_run.provider_response_parser" | "external_crm_sync_run.provider_response_summary" | "fixture_safe_request_counts" | string;
      network_requests_executed: false;
      raw_response_body_accepted: false;
      raw_response_body_returned: false;
      raw_external_payload_returned: false;
      raw_cursor_returned: false;
      authorization_header_returned: false;
      secret_returned: false;
      raw_endpoint_url_returned: false;
    };
    retry_policy_readback?: {
      schema: "enterprise_crm_retry_policy_readback.v1" | string;
      retry_recommended: boolean;
      next_retry_after_seconds?: number | null;
      reset_at_present: boolean;
      backoff_reason: string;
      max_attempts: number;
      operator_next_action: string;
      rate_limit_handoff: {
        present: boolean;
        reset_at_present: boolean;
        next_retry_after_seconds?: number | null;
        raw_headers_returned: false;
        raw_reset_at_returned: false;
      };
      network_requests_executed: false;
      raw_response_body_returned: false;
      raw_headers_returned: false;
      authorization_header_returned: false;
      secret_returned: false;
      raw_endpoint_url_returned: false;
      raw_cursor_returned: false;
    };
    retry_attempt_readback?: {
      schema: "enterprise_crm_retry_attempt_readback.v1" | string;
      attempt_count: number;
      max_attempts: number;
      next_retry_after_seconds?: number | null;
      reset_at_present: boolean;
      status: "scheduled" | "not_recommended" | "blocked" | string;
      reason: string;
      idempotency_fingerprint: string;
      provider_response_summary_present: boolean;
      provider_response_parser_present: boolean;
      network_requests_executed: false;
      raw_response_body_returned: false;
      raw_headers_returned: false;
      authorization_header_returned: false;
      secret_returned: false;
      raw_endpoint_url_returned: false;
      raw_cursor_returned: false;
    };
    rate_limit_handoff?: {
      present: boolean;
      reset_at_present: boolean;
      next_retry_after_seconds?: number | null;
      raw_headers_returned: false;
      raw_reset_at_returned: false;
    };
    retry_worker_handoff_summary?: {
      schema: "enterprise_crm_retry_worker_handoff_summary.v1" | string;
      source: "enterprise_crm_sync_runs.metadata.retry_attempt_readback" | string;
      scheduled_count: number;
      blocked_count: number;
      next_retry_after_seconds_min?: number | null;
      provider_counts: Record<string, Record<string, number>>;
      operator_next_actions: Array<{ action: string; retry_marker_count: number }>;
      status_counts: Record<string, number>;
      readback_path: "GET /admin/enterprise/accounts" | string;
      dashboard_readback_path: "GET /admin/enterprise/sales-dashboard" | string;
      worker_handoff_ready: boolean;
      read_only: true;
      network_requests_executed: false;
      authorization_header_returned: false;
      secret_returned: false;
      raw_endpoint_url_returned: false;
      raw_cursor_returned: false;
      raw_external_payload_returned: false;
    };
    refused_reason?: string | null;
    sync_marker_present: boolean;
    sync_marker?: string | null;
    imported_activity?: EnterpriseSalesActivityItem | null;
    audit_id: string;
    readback_path: "GET /admin/enterprise/accounts" | string;
    write_path: "PATCH /admin/enterprise/accounts" | string;
    tenant_scoped: true;
    runtime_implemented: true;
    network_requests_executed: false;
    secret_returned: false;
    authorization_header_returned: false;
    raw_external_payload_returned: false;
  } | null;
  audit_id: string;
  readback_path: "GET /admin/enterprise/accounts" | string;
  accepted_fields: string[];
  omitted_fields: string[];
  next_step: string;
};
```

UI rules:

- Build account list/cards from `accounts[]`; current runtime returns the session tenant as the first account, and later CRM/multi-tenant adapters can extend the same shape.
- `sales.stage` is an allowlisted operator marker from local tenant metadata or `AI_GATEWAY_ENTERPRISE_SALES_STAGE`; `sales.activity` is local CRM-adapter readback from `enterprise_sales_activities`.
- `sales.external_crm_adapter` is tenant-scoped config/readback from `enterprise_external_crm_adapters`; it stores provider/status/ref presence and sync markers only, executes no network request, and never returns secrets or raw CRM payloads.
- `external_crm_sync_run` writes a tenant-scoped row to `enterprise_crm_sync_runs`; disabled adapters, missing secret refs, missing endpoint refs, or unsupported `custom-http` adapters produce `status="refused"` with `would_call=false`, `http_request_plan.would_send=false`, `provider_response_reducer.outcome="blocked"`, `blocked_reason/refused_reason`, and fixture-safe counts. Enabled supported adapters return typed `adapter_request`/`adapter_result`, `http_request_plan`, and `provider_response_reducer` metadata with provider-specific logical endpoint refs (`hubspot`, `salesforce`, `pipedrive`, `zoho`) while still executing no real network request; fixture-safe imported activity summaries may create rows in `enterprise_sales_activities`.
- `external_crm_sync_run.provider_response_parser` is the fixture-safe provider response/header parser seam. It normalizes HubSpot/Salesforce/Pipedrive/Zoho status, retry-after seconds, rate-limit presence, cursor presence, external-id counts, provider error category, and `safe_next_action`; it rejects unknown raw header/body/payload/cursor fields and never returns raw endpoint URLs, Authorization values, secrets, raw headers, raw response bodies, raw CRM payloads, or raw cursors. `provider_response_summary` remains accepted as the legacy fixture-safe count/hash bridge.
- `http_request_plan` is a secret-safe request plan seam only. It contains method, logical path/endpoint reference, operation/direction, required header presence, body shape, and an idempotency fingerprint. It never returns Authorization values, secret material, raw endpoint URLs, raw external IDs, raw external CRM payloads, or raw request bodies.
- `http_executor_boundary` is the network-disabled HTTP executor readback. It echoes only the request builder shape (method, logical path ref, header presence, body shape, timeout) plus retry summary and fixed `network_enabled=false` / `network_call_performed=false`; it never returns raw endpoint URLs, Authorization values, secrets, raw request bodies, raw responses, raw headers, or raw CRM payloads.
- `retry_policy_readback`, `retry_attempt_readback`, and `rate_limit_handoff` are derived from `provider_response_parser`/`provider_response_reducer` and the safe HTTP request plan only. Retry attempt markers are stored in `enterprise_crm_sync_runs.metadata.retry_attempt_readback`; when a PATCH includes `provider_response_parser` or legacy `provider_response_summary` and the retry policy recommends retry, the marker returns `status="scheduled"`, bounded `attempt_count`/`max_attempts`, backoff seconds or reset-marker presence, reason, and `idempotency_fingerprint`. They do not parse live headers, execute network calls, return raw reset timestamps, response bodies, Authorization, endpoint URLs, secrets, or raw cursors. Blocked/refused adapters keep `retry_recommended=false` and `retry_attempt_readback.status="blocked"` or `"not_recommended"` until operator config is fixed.
- `retry_worker_handoff_summary` is a read-only ops/worker aggregate derived only from `enterprise_crm_sync_runs.metadata.retry_attempt_readback` and `retry_policy_readback`. It returns `scheduled_count`, `blocked_count`, `next_retry_after_seconds_min`, `provider_counts`, and `operator_next_actions`; it executes no CRM network request and returns no Authorization, secret, raw endpoint, raw cursor, raw reset header, or raw CRM payload.
- Do not send unknown fields to `PATCH`. The backend rejects unknown request fields and rejects secret-like text markers in local metadata and activity inputs.
- Use `sso_readiness.identity_connections_path` to deep-link to OIDC/SAML cards. `validation-pending` means config shape exists but real token/assertion validation is still missing.
- Treat `billing_readiness.merchant_connected=false` and `pending_scheduler=true` as product states. This endpoint is not production payment evidence.
- Never render omitted categories: client secret, tokens, raw SAML assertions, Authorization, provider payloads, raw external CRM payloads, external CRM secrets/webhook secrets, raw account owner/admin contact email, raw tenant/project/user/wallet/subscription/invoice metadata, raw request payloads, API key secrets, provider key secrets, or raw idempotency keys. For contacts, render only `present`, `email_domain`, and `hash_prefix`/`sha256` if needed for audit correlation.

## Admin: Setup Wizard Readback

`GET /admin/setup/readback`

Use this as the Admin Dashboard Setup Wizard handoff DTO. It is local/dev friendly, secret-safe, and designed to confirm the first-install seed path without requiring production provider credentials.

```ts
type AdminSetupReadback = {
  schema: "admin_setup_readback.v1" | string;
  source: "control_plane_local_seed_readback" | string;
  secret_safe: true;
  tenant_id: string;
  default_project_id: string;
  state: "ready" | "attention" | "blocked" | string;
  next_action: string;
  counts: {
    ready: number;
    blocked: number;
    total: number;
    recent_mock_chat_successes: number;
  };
  first_run_readiness?: {
    schema: "admin_setup_first_run_readiness.v1" | string;
    status: "ready" | "attention" | "blocked" | string;
    secret_safe: true;
    blocked_reasons: string[];
    safe_next_action: string;
    admin: AdminSetupFirstRunReadinessItem;
    mock_provider: AdminSetupFirstRunReadinessItem;
    mock_channel: AdminSetupFirstRunReadinessItem;
    mock_model: AdminSetupFirstRunReadinessItem;
    test_key: AdminSetupFirstRunReadinessItem;
    gateway_chat: AdminSetupFirstRunReadinessItem;
    gateway_responses: AdminSetupFirstRunReadinessItem;
    gateway_embeddings: AdminSetupFirstRunReadinessItem;
    omitted_fields: string[];
    raw_admin_password_returned: false;
    api_key_secret_returned: false;
    api_key_secret_hash_returned: false;
    provider_secret_returned: false;
    provider_secret_hash_returned: false;
    authorization_returned: false;
    raw_payload_returned: false;
  };
  local_seed: {
    admin_exists: boolean;
    mock_provider: { code: "mock-openai" | string; exists: boolean; enabled: boolean };
    mock_channel: { name: "mock-openai-default" | string; exists: boolean; enabled: boolean };
    mock_provider_key: { alias: "mock-dev-key" | string; exists: boolean; credential_configured: boolean };
    default_model: {
      model_key: "mock-gpt-4o-mini" | string;
      exists: boolean;
      active: boolean;
      association_enabled: boolean;
    };
    test_key: {
      key_prefix: "dev_test_key" | string;
      present: boolean;
      active: boolean;
      secret_returned: false;
    };
  };
  wizard_steps?: Array<{
    code:
      | "admin"
      | "mock_provider_channel_model"
      | "test_key"
      | "gateway_model_chat_readiness"
      | string;
    label: string;
    status: "ready" | "attention" | "blocked" | string;
    detail: string;
    evidence: string;
    next_action: string;
    production_credentials_required: false;
  }>;
  gateway: {
    model_readiness: {
      status: "ready" | "attention" | "blocked" | string;
      model: "mock-gpt-4o-mini" | string;
      requires_authorization_header: boolean;
      authorization_returned: false;
    };
    chat_readiness: {
      status: "ready" | "attention" | "blocked" | string;
      recent_success_count: number;
      raw_payload_returned: false;
      next_action: string;
    };
  };
  checks: Array<{
    code: string;
    label: string;
    status: "ready" | "attention" | "blocked" | string;
    detail: string;
    next_action: string;
  }>;
  blockers: string[];
  handoff: {
    admin_ui_target: string;
    user_portal_target: "/?mode=developer-console" | string;
    script_next_check: string;
    production_credentials_required: false;
    omitted_fields: string[];
  };
  raw_admin_password_returned: false;
  raw_provider_key_returned: false;
  raw_test_key_secret_returned: false;
  authorization_returned: false;
  raw_request_payload_returned: false;
};

type AdminSetupFirstRunReadinessItem = {
  status: "ready" | "attention" | "blocked" | string;
  blocked_reasons: string[];
  safe_next_action: string;
  secret_safe: true;
};
```

UI rules:

- Treat `state=ready` as the local Setup Wizard completion state. `gateway.chat_readiness.status=attention` means the seed is usable but no successful local chat request has been read back yet.
- Prefer `first_run_readiness` for first-run checklist status and operator repair copy. It covers admin, mock provider, mock channel, mock model, local test key, and Gateway chat/responses/embeddings readiness with per-item `blocked_reasons` and `safe_next_action`.
- The stable step order is `admin`, `mock_provider_channel_model`, `test_key`, `gateway_model_chat_readiness`. Prefer `wizard_steps[]` for compact cards and use `checks[]` for detailed readback rows.
- If this endpoint is unavailable, fall back to `/admin/providers/health-summary` for provider/model inference and show `scripts/setup_local_mvp.ps1` as the repair action.
- Do not ask for production credentials in this flow. Every wizard step keeps `production_credentials_required=false`; run `scripts/dev_login_check.ps1` for local Gateway model/chat smoke after setup.
- Never render omitted categories from `handoff.omitted_fields` or `first_run_readiness.omitted_fields`: raw admin password, API key secret/hash, provider secret/hash, authorization header, or raw payload.

## Admin: Production Read-model Status

`GET /admin/production/read-model/status`

Use this as a small operations/admin seam for Production ClickHouse/tokenizer/read-model smoke preparation. It is a readback/status DTO, not release evidence: the endpoint reads control-plane Postgres request-log summary and secret-safe runtime config presence, but it does not connect to ClickHouse, run load tests, or return DB URLs, credentials, Authorization, raw SQL, raw query text, or raw payloads.

```ts
type AdminProductionReadModelStatus = {
  schema: "admin_production_read_model_status.v1" | string;
  secret_safe: true;
  source: "control_plane_config_and_postgres_readback" | string;
  tenant_id: string;
  status: "ready" | "attention" | "config-needed" | "no-signal" | string;
  backend: "postgres" | "clickhouse" | "config-needed" | string;
  postgres: {
    status: "ready" | "empty" | string;
    request_count: number;
    tokenized_request_count: number;
    latest_request_created_at?: string | null;
    latest_completed_at?: string | null;
    lag_seconds?: number | null;
    staleness: "fresh" | "stale" | "very-stale" | "no-signal" | string;
    readback: "request_logs_safe_summary" | string;
    raw_payload_returned: false;
  };
  clickhouse: {
    status: "configured" | "disabled" | "config-needed" | string;
    enabled: boolean;
    endpoint_configured: boolean;
    endpoint_returned: false;
    network_requests: false;
    connectivity_check_enabled: false;
    contract: string;
    credentials?: { redaction: "presence_only" | string };
  };
  tokenizer_status: {
    status: "configured" | "provider-usage-readback" | "config-needed" | "no-signal" | string;
    configured: boolean;
    backend_configured: boolean;
    model_configured: boolean;
    config_path_configured: boolean;
    tokenized_request_count: number;
    raw_tokenizer_config_returned: false;
    next_step: string;
  };
  lag: {
    source: "postgres_request_logs" | string;
    latest_request_created_at?: string | null;
    lag_seconds?: number | null;
    staleness: "fresh" | "stale" | "very-stale" | "no-signal" | string;
  };
  contract: {
    admin_path: "GET /admin/production/read-model/status" | string;
    frontend_contract: "AdminProductionReadModelStatus" | string;
    smoke_plan_contract: "admin_production_read_model_smoke_plan.v1" | string;
    lag_explainability_contract: "admin_production_read_model_lag_explainability.v1" | string;
    network_requests: false;
    clickhouse_connected: false;
    db_url_returned: false;
    credentials_returned: false;
    authorization_returned: false;
    raw_query_returned: false;
    raw_sql_returned: false;
    raw_payload_returned: false;
  };
  smoke_plan?: {
    schema: "admin_production_read_model_smoke_plan.v1" | string;
    status: "ready-for-operator-smoke" | "readback-ready" | "blocked" | "config-needed" | string;
    backend: "postgres" | "clickhouse" | "config-needed" | string;
    secret_safe: true;
    operator_action_required: boolean;
    network_requests: false;
    clickhouse_connected: false;
    required_config_presence: {
      clickhouse_log_store_enabled: boolean;
      clickhouse_endpoint_configured: boolean;
      clickhouse_secret_presence?: { redaction: "presence_only" | string };
      tokenizer_backend_configured: boolean;
      tokenizer_model_configured: boolean;
      tokenizer_config_path_configured: boolean;
      raw_values_returned: false;
    };
    sample_query_plan: {
      source: "request_logs_safe_summary" | string;
      postgres_readback: {
        table: "request_logs" | string;
        filters: string[];
        selected_fields: string[];
        raw_payload_selected: false;
      };
      clickhouse_readback: {
        enabled_when: string;
        table?: string | null;
        database?: string | null;
        selected_fields: string[];
        query_text_returned: false;
        network_requests: false;
      };
      tokenizer_readback: {
        status: string;
        source: "configured_tokenizer_presence" | "provider_usage_token_columns" | string;
        tokenized_request_count: number;
        raw_tokenizer_config_returned: false;
      };
    };
    readback_expectations: {
      postgres_request_count: number;
      postgres_tokenized_request_count: number;
      postgres_staleness: "fresh" | "stale" | "very-stale" | "no-signal" | string;
      clickhouse_live_result_required_here: false;
      release_evidence_closure: false;
    };
    forbidden_outputs: string[];
    next_step: string;
  };
  read_model_lag_explainability?: {
    schema: "admin_production_read_model_lag_explainability.v1" | string;
    secret_safe: true;
    status: "readback-present" | "no-signal" | string;
    backend_selection: {
      selected_backend: "postgres" | "clickhouse" | "config-needed" | string;
      decision_source: "clickhouse_config_presence_and_postgres_safe_readback" | string;
      postgres_available: boolean;
      clickhouse_configured: boolean;
      clickhouse_connectivity_checked: false;
      clickhouse_live_result_present: false;
      fallback_backend: "postgres" | string;
      raw_backend_config_returned: false;
    };
    lag_staleness_source: {
      source: "postgres_request_logs_max_created_at" | string;
      readback: "request_logs_safe_summary" | string;
      lag_seconds?: number | null;
      staleness: "fresh" | "stale" | "very-stale" | "no-signal" | string;
      latest_request_created_at_present: boolean;
      latest_completed_at_present: boolean;
      clickhouse_lag_checked: false;
      raw_timestamp_query_returned: false;
      raw_payload_returned: false;
    };
    tokenizer_config_presence: {
      configured: boolean;
      backend_configured: boolean;
      model_configured: boolean;
      config_path_configured: boolean;
      tokenized_request_count: number;
      raw_tokenizer_config_returned: false;
    };
    sample_query_plan_presence: {
      present: boolean;
      postgres_plan_present: boolean;
      clickhouse_plan_present: boolean;
      tokenizer_plan_present: boolean;
      raw_sql_returned: false;
      raw_query_returned: false;
      raw_payload_selected: false;
    };
    safe_next_action: string;
    forbidden_outputs: string[];
  };
  next_step: string;
  omitted_fields: string[];
};
```

UI rules:

- Show `backend` as `postgres`, `clickhouse`, or `config-needed`; do not display ClickHouse endpoint values or database DSNs.
- Treat `tokenizer_status.status=config-needed` as an actionable seam, not a failure. The UI should show `next_step` and keep raw tokenizer config hidden.
- `lag` and `postgres` fields are safe request-log readbacks. They must not be combined with payload preview or raw route snapshots.
- Use `smoke_plan` for operator/front-end cards: show required config presence, sample readback/query plan, tokenizer source, forbidden output categories, and `next_step`. Do not render endpoint values, DB URLs, credentials, Authorization, raw query text, or raw payload.
- Use `read_model_lag_explainability` for detail drawers/cards: show backend selection, lag/staleness source, tokenizer config presence, sample query plan presence, and `safe_next_action`; never render DB URLs, credentials, Authorization, raw SQL/raw query, or raw payload.
- This endpoint must not be labeled as production readiness evidence or final smoke proof; live ClickHouse smoke remains an explicit operator action outside this DTO.

### Admin Login

`POST /admin/auth/login`

Request:

```ts
type AdminLoginRequest = {
  email: string;
  password: string;
};
```

Response:

```ts
type AdminLoginResponse = {
  session: { id: string; expires_at: string };
  session_token_once: string;
  user: {
    id: string;
    tenant_id: string;
    email: string;
    display_name: string;
    roles: string[];
  };
};
```

UI notes:

- Store `session_token_once` only in runtime state via `setAdminSessionToken()`. Do not write it into localStorage or visible diagnostics.
- Server also sets an HttpOnly admin session cookie.

### Admin Me

`GET /admin/auth/me`

Response:

```ts
type AdminMeResponse = {
  session: { id: string; expires_at: string };
  user: AdminUser;
  capability_summary: {
    capabilities: string[];
    denied_capabilities: string[];
    personas?: string[];
    roles?: string[];
    secret_safe?: boolean;
  };
};
```

Use `capability_summary` to hide or disable controls. Do not infer permissions from display labels alone.

### User Register/Login/Me

- `POST /auth/register`
- `POST /auth/login`
- `GET /auth/me`
- `POST /auth/logout`

Request:

```ts
type UserAuthRequest = {
  email: string;
  password: string;
};

type UserRegisterRequest = UserAuthRequest & {
  display_name?: string;
};
```

Response:

```ts
type UserAuthResponse = {
  session: { id: string; expires_at: string };
  session_token_once: string;
  user: {
    id: string;
    tenant_id: string;
    email: string;
    display_name: string;
    terms_version: string;
    privacy_version: string;
    accepted_at: string | null;
    pending_acceptance: boolean;
  };
  project: {
    id: string;
    role: string;
  };
};
```

Policy handoff fields are frontend-stable. `pending_acceptance=true` should be treated as a product state that needs user acknowledgement, not as an auth failure.

### User Password Reset / Email Verification Requests

- `POST /auth/password-reset/request`
- `POST /auth/email-verification/request`

Password reset request:

```ts
type UserPasswordResetRequest = {
  email: string;
};
```

Response:

```ts
type UserProductizationStatusResponse = {
  status: "pending" | "config-needed" | string;
  code: string;
  message: string;
  next_action: string;
  email_delivery: "config_needed" | "pending" | string;
  email_configured: boolean;
  delivery_mode: "config-needed" | "queued" | "local-only" | string;
  expires_in_seconds: number | null;
  request_id: string;
  audit?: JsonValue;
  account_disclosure: "none" | string;
  secret_safe: boolean;
};
```

UI notes:

- Do not infer or reveal whether the password reset email belongs to an account.
- `request_id` is a safe operation reference, not a token.
- `expires_in_seconds=null` means no reset/verification token was generated.
- Never display reset tokens, verification tokens, Authorization headers, API key secrets, raw payloads, or raw mail provider responses.
- Current MVP is a config-needed skeleton. Real email delivery, persisted policy acceptance records, and enterprise policy/SSO are later productization work.

## Admin: Providers, Channels, Provider Keys

### Providers

- `GET /admin/providers`
- `POST /admin/providers`
- `PATCH /admin/providers/{id}`
- `DELETE /admin/providers/{id}`

Core DTO:

```ts
type Provider = {
  id: string;
  tenant_id: string;
  code: string;
  name: string;
  status: "enabled" | "disabled" | "deleted" | string;
  provider_type?: string | null;
  base_url?: string | null;
  metadata: JsonValue;
};
```

Create/update fields: `code`, `name`, `status`, `provider_type`, `base_url`, `metadata`.

### Channels

- `GET /admin/channels`
- `POST /admin/channels`
- `PATCH /admin/channels/{id}`
- `DELETE /admin/channels/{id}`
- `POST /admin/channels/{id}/manual-test`

Core DTO:

```ts
type Channel = {
  id: string;
  tenant_id: string;
  provider_id: string;
  name: string;
  endpoint: string;
  protocol_mode: string;
  status: "enabled" | "disabled" | "degraded" | "cooldown" | "deleted" | string;
  priority: number;
  weight: number;
  health_score: number;
  region?: string | null;
  model_mappings: JsonValue;
  probe_policy: JsonValue;
  request_overrides: JsonValue;
  tags: JsonValue;
  timeout_policy: JsonValue;
};
```

Manual channel test request:

```ts
type ChannelManualTestRequest = {
  model: string;
  upstream_model_name?: string;
  dry_run?: boolean;
};
```

Manual test response is intentionally non-billable and secret-safe: `billing.billable=false`, `ledger_write=false`, `request_log_write=false`, `upstream_call=false`, and credential fields are omitted. The response includes `manual_test_explainability` with protocol, dry-run/mock/live/config-needed status, provider key lifecycle presence summary, endpoint capability using safe relative path templates, safe next action, and `omitted_secret_policy`. The channel `endpoint` field is returned as `omitted`; render `request_plan.path` or `manual_test_explainability.endpoint_capability.path_template` instead of any raw configured provider URL.

UI notes:

- Provider/channel CRUD is available through the endpoints above. Copying a channel should clone non-secret configuration only: `endpoint`, `protocol_mode`, priority/weight, tags, mappings, overrides, timeout, probe policy, and region.
- Channel manual test is currently a dry-run/local probe surface. It does not perform provider live smoke. If no enabled provider key exists, show `config-needed`; if live upstream probing is not connected, show the returned `live_status` and `safe_next_action`.
- Never display provider endpoint URLs, provider endpoint credentials, provider key material, Authorization headers, raw request payloads, or upstream raw response bodies in the provider workflow.

### Provider Health Summary

- `GET /admin/providers/health-summary?window_minutes=60&sample_limit=500`

Stable frontend fields:

```ts
type HealthSummaryRecentStats = {
  request_count: number;
  success_count: number;
  error_count: number;
  success_rate?: number | null;
  avg_latency_ms?: number | null;
  p95_latency_ms?: number | null;
  error_top: Array<{ code: string; count: number }>;
  last_error?: {
    code?: string | null;
    owner?: string | null;
    status: string;
    http_status?: number | null;
    observed_at: string;
  } | null;
};

type ProviderHealthSummary = {
  summary_version: 1;
  probe_status: {
    status: "scheduler_pending" | "active" | "disabled" | string;
    probe_source: "request_logs" | "scheduled_probe" | string;
    scheduler_pending: boolean;
    next_probe?: string | null;
  };
  recent_window: HealthSummaryRecentStats & {
    source: "request_logs";
    sample_count: number;
    sample_limit: number;
    window_minutes: number;
    window: { unit: "minutes"; minutes: number };
  };
  providers: Array<{ id: string; code: string; name: string; status: string; health_state: string; recent: HealthSummaryRecentStats }>;
  channels: Array<{ id: string; provider_id: string; name: string; status: string; health_state: string; recent: HealthSummaryRecentStats }>;
  provider_keys: Array<{
    id: string;
    channel_id: string;
    key_alias: string;
    status: string;
    credential_configured: boolean;
    cooldown_until?: string | null;
    configured_last_error_code?: string | null;
    recovery_probe?: ProviderKeyRecoveryProbeSummary | null;
    recovery_action_readback: ProviderKeyRecoveryActionReadback;
    recovery_apply_plan_readback: ProviderKeyRecoveryApplyPlanReadback;
    recent: HealthSummaryRecentStats;
  }>;
  models: Array<{ id: string; model_key: string; display_name: string; routing_state: string; recent: HealthSummaryRecentStats }>;
  protocol_capability_matrix: ProtocolCapabilityMatrixReadback;
};

type ProtocolCapabilityMatrixReadback = {
  schema: "provider_protocol_capability_matrix.v1" | string;
  dimensions: Array<"provider" | "channel" | "model" | "profile" | string>;
  endpoints: Array<"chat" | "responses" | "embeddings" | "anthropic_messages" | "gemini_generate_content" | string>;
  row_count: number;
  rows: ProtocolCapabilityMatrixRow[];
  secret_safe: true;
  raw_endpoint_returned: false;
  raw_payload_returned: false;
  authorization_returned: false;
  provider_key_returned: false;
};

type ProtocolCapabilityMatrixRow = {
  provider_id?: string | null;
  provider_code?: string | null;
  channel_id: string;
  model_id?: string | null;
  model_key?: string | null;
  profile_id?: string | null;
  protocol_mode: string;
  normalized_protocol: string;
  status: "supported" | "config-needed" | "blocked" | string;
  provider_key_present: boolean;
  blocked_reasons: string[];
  endpoints: Array<{
    endpoint: "chat" | "responses" | "embeddings" | "anthropic_messages" | "gemini_generate_content" | string;
    supported: boolean;
    mockable: boolean;
    config_needed: boolean;
    status: "supported" | "config-needed" | "blocked" | string;
    blocked_reason?: string | null;
    known_missing_pieces: string[];
    path_template: string;
  }>;
};

type ProviderKeyRecoveryActionReadback = {
  schema: "provider_key_recovery_action_readback.v1";
  suggested_action:
    | "request_recovery_probe"
    | "rotate_provider_key_secret"
    | "operator_review_reenable"
    | "monitor_request_logs"
    | "check_provider_quota_and_limits"
    | "create_replacement_provider_key"
    | "operator_review_provider_key_state"
    | string;
  operator_confirmation_required: boolean;
  last_probe_status: string;
  cooldown_or_refusal_reason: string;
  safe_next_action: string;
  upstream_probe_executed: false;
  secret_safe: true;
  omitted_secret_policy: {
    key_secret_returned: false;
    authorization_header_returned: false;
    raw_endpoint_returned: false;
    raw_payload_returned: false;
    sealed_secret_returned: false;
    fingerprint_returned: false;
    public_credential_indicator: "credential_configured" | string;
  };
};

type ProviderKeyRecoveryApplyPlanReadback = {
  schema: "provider_key_recovery_apply_plan_readback.v1";
  suggested_action: ProviderKeyRecoveryActionReadback["suggested_action"];
  preconditions: string[];
  would_enable: boolean;
  would_rotate: boolean;
  would_probe: boolean;
  would_refuse: boolean;
  operator_confirmation_required: boolean;
  blocked_reasons: string[];
  safe_next_action: string;
  local_execution_boundary: {
    status_write_allowed: boolean;
    secret_write_allowed: boolean;
    provider_network_call: false;
    upstream_probe_executed: false;
    live_provider_smoke: false;
    request_log_write: false;
    billing_ledger_write: false;
  };
  secret_safe: true;
  omitted_secret_policy: ProviderKeyRecoveryActionReadback["omitted_secret_policy"];
};
```

Use `models[].recent.success_rate` for per-model availability, `channels[].recent.avg_latency_ms` / `p95_latency_ms` for channel latency, `recent_window.error_top` for failure TopN, and `probe_status` for health monitor scheduler readback. Use `protocol_capability_matrix.rows[].endpoints[]` to render chat/responses/embeddings/anthropic_messages/gemini_generate_content availability instead of inferring from provider labels or channel names. Use `provider_keys[].recovery_action_readback` for recovery suggestions instead of recomputing operator actions in the UI; it confirms whether operator approval is required, the last probe status, cooldown/refusal reason, and the safe next action. Use `provider_keys[].recovery_apply_plan_readback` when rendering the executable operator plan: it is a compact local plan only, with preconditions, `would_enable` / `would_rotate` / `would_probe` / `would_refuse`, blocked reasons, and `local_execution_boundary` booleans. Current runtime scheduler status is explicit: `scheduler_pending=true`, `probe_source=request_logs`, and `next_probe=null`; show it as pending instead of implying real scheduled probes exist. These fields are best-effort over bounded request-log samples and must be shown as `no-signal` when counts are zero. They never include provider keys, Authorization headers, raw upstream payloads, endpoint secrets, raw endpoint URLs, raw payloads, sealed secrets, fingerprints, raw metadata, or raw error bodies.

### Provider Keys

- `GET /admin/provider-keys`
- `POST /admin/provider-keys`
- `PATCH /admin/provider-keys/{id}`
- `DELETE /admin/provider-keys/{id}`
- `POST /admin/provider-keys/{id}/recovery`
- `POST /admin/provider-keys/{id}/rotate`

Core DTO:

```ts
type ProviderKey = {
  id: string;
  tenant_id: string;
  channel_id: string;
  key_alias: string;
  status:
    | "enabled"
    | "manual_disabled"
    | "degraded"
    | "cooldown"
    | "recovery_probe"
    | "auth_failed"
    | "quota_exhausted"
    | "deleted"
    | string;
  health_score: number;
  lifecycle_state?:
    | "active"
    | "credential_missing"
    | "operator_disabled"
    | "degraded"
    | "cooldown"
    | "recovery_probe"
    | "credential_failed"
    | "quota_exhausted"
    | "deleted"
    | "unknown"
    | string;
  credential_generation?: {
    value: number | null;
    source: "metadata" | "rotation_metadata_without_generation" | "not_recorded" | string;
    secret_material_returned: false;
  };
  concurrency_limit?: number | null;
  rpm_limit?: number | null;
  tpm_limit?: number | null;
  cooldown_until?: string | null;
  last_error_code?: string | null;
  recovery_probe?: ProviderKeyRecoveryProbeSummary | null;
  last_probe_summary?: ProviderKeyRecoveryProbeSummary | null;
  rotation_needed?: { needed: boolean; reason: string };
  safe_next_action?: string;
  omitted_secret_policy?: {
    key_secret_returned: false;
    authorization_header_returned: false;
    raw_endpoint_returned: false;
    raw_payload_returned: false;
    sealed_secret_returned: false;
    fingerprint_returned: false;
    public_credential_indicator: "credential_configured" | string;
  };
  credential_configured?: boolean;
  secret_redacted?: true;
};
```

Create/rotate accept write-only secret inputs:

```ts
type CreateProviderKeyRequest = {
  channel_id: string;
  key_alias: string;
  api_key?: string;
  secret?: string;
  status?: string;
  metadata?: JsonObject;
};

type ProviderKeyRotateRequest = {
  api_key?: string;
  secret?: string;
  key_alias?: string;
  reason?: string;
};
```

Recovery probe:

```ts
type ProviderKeyRecoveryRequest = {
  target_status?: "recovery_probe" | "enabled";
  reason?: string;
};
```

Recovery response returns `credential_material.omitted=true`, `upstream_probe.executed=false` for current local implementation, `recovery_apply_plan_readback`, and a safe `provider_key` readback.
The safe readback now includes `lifecycle_state`, `credential_generation`, `last_probe_summary`, `rotation_needed.reason`, `safe_next_action`, and `omitted_secret_policy`. Treat these as display/action hints only; do not infer live provider success from them.

Provider key readback may include:

```ts
type ProviderKeyRecoveryProbeSummary = {
  result?: string | null;
  error_code?: string | null;
  last_checked_at?: string | null;
  next_step?: string | null;
};
```

Use it for the provider -> channel -> key -> probe workflow. Recovery and rotate responses intentionally do not close production rotation; `production_rotation_closure_allowed=false` means the UI should show the new state and next action, not claim live credential cutover evidence.
Never render or persist key secret material, Authorization headers, raw provider endpoints, raw request/response payloads, sealed secret payloads, fingerprints, or raw metadata. The only public credential indicator is `credential_configured`.

## Admin: Models and Routing

### Canonical Models

- `GET /admin/models`
- `POST /admin/models`
- `PATCH /admin/models/{id}`
- `DELETE /admin/models/{id}`

Core DTO:

```ts
type CanonicalModel = {
  id: string;
  tenant_id: string;
  model_key: string;
  display_name: string;
  status: "active" | "disabled" | "deleted" | string;
  visibility: string;
  family?: string | null;
  context_length?: number | null;
  max_output_tokens?: number | null;
  default_price_book_id?: string | null;
  supports_audio: boolean;
  supports_reasoning: boolean;
  supports_stream: boolean;
  supports_tools: boolean;
  supports_vision: boolean;
  capabilities: JsonValue;
};
```

### Model Associations

- `GET /admin/model-associations`
- `POST /admin/model-associations`
- `PATCH /admin/model-associations/{id}`
- `DELETE /admin/model-associations/{id}`

Core DTO:

```ts
type ModelAssociation = {
  id: string;
  tenant_id: string;
  canonical_model_id: string;
  channel_id?: string | null;
  channel_tag?: string | null;
  association_type: string;
  upstream_model_name?: string | null;
  model_pattern?: string | null;
  priority: number;
  canary_percent: number;
  fallback_allowed: boolean;
  conditions: JsonValue;
  status: "enabled" | "disabled" | "deleted" | string;
};
```

### Routing Dry-run

`POST /admin/model-associations/dry-run`

Request:

```ts
type ModelAssociationDryRunRequest = {
  project_id: string;
  profile_id: string;
  canonical_model_id?: string;
  canonical_model_key?: string;
  requested_model?: string;
  previous_successful_channel_id?: string;
  seed?: number;
  trace_id?: string;
};
```

Response:

```ts
type ModelAssociationDryRunResponse = {
  project_id: string;
  profile_id: string;
  requested_model: string;
  canonical_model: {
    id: string;
    model_key: string;
    display_name: string;
    family?: string | null;
    status: string;
  } | null;
  candidates: Array<{
    association_id: string;
    channel_id: string;
    channel_name: string;
    provider_id: string;
    provider_code?: string | null;
    provider_name: string;
    provider_model?: string | null;
    upstream_model?: string | null;
    filtered: boolean;
    filter_reason?: string | null;
    selected: boolean;
    score?: JsonValue;
    fallback_allowed: boolean;
    routing_status?: string | null;
    routing_health?: string | null;
    rate_limit_available?: boolean | null;
  }>;
  selected_candidate: ModelAssociationDryRunCandidate | null;
  selection: { status: string; selected_channel_id?: string | null; selected: JsonValue };
  protocol_capability_matrix: ProtocolCapabilityMatrixReadback;
  route_decision_snapshot: JsonValue;
  route_policy_version: string;
  decision_snapshot_version: number;
  trace_affinity: JsonValue;
  trace_id?: string | null;
};
```

UI should expose candidate rows, selected route, filtered reasons, rejection/fallback explanations, and `protocol_capability_matrix` for profile-aware provider/channel/model capability. Prefer `protocol_capability_matrix.rows[].endpoints[]` when deciding whether to enable chat, responses, embeddings, Anthropic Messages, or Gemini generateContent controls; each endpoint reports `supported`, `mockable`, `config_needed`, `status`, and `blocked_reason`/`known_missing_pieces`. Do not render raw route policy blobs by default; put `route_decision_snapshot` behind a debug disclosure if needed.

TODO status:

- `[x]` Gateway/Admin contract readback exposes a compact provider/channel/model/profile protocol capability matrix for health summary and model association dry-run.
- `[!]` Real provider live smoke, SDK smoke, release gate evidence, raw upstream payload inspection, and provider credential verification remain outside this UI contract.

### API Key Profiles and User-visible Models

- `GET /admin/api-key-profiles?project_id=...`
- `GET /admin/api-key-profiles/{id}`
- `POST /admin/api-key-profiles`
- `PATCH /admin/api-key-profiles/{id}`
- `DELETE /admin/api-key-profiles/{id}`

Core DTO:

```ts
type ApiKeyProfile = {
  id: string;
  tenant_id: string;
  project_id: string;
  name: string;
  status: "active" | "disabled" | "deleted" | string;
  inbound_protocol: string;
  default_protocol_mode: string;
  allowed_models: JsonValue;
  denied_models: JsonValue;
  model_aliases: JsonValue;
  allowed_channel_tags: JsonValue;
  blocked_provider_ids: JsonValue;
  ip_allowlist: JsonValue;
  payload_policy_id?: string | null;
  request_overrides: JsonValue;
  trace_header_rules: JsonValue;
};
```

Frontend model availability should combine:

- Admin model/mapping screens: canonical models, model associations, profiles, and routing dry-run.
- User portal model cards: `GET /user/models`, because it includes profile-aware routability and price display.
- Runtime API console: `GET /v1/models`, because it is the actual OpenAI-compatible visibility surface for the selected user key/profile.

### User Portal: Developer Quickstart Readback

`GET /user/developer-quickstart-readback`

Use this as the user-side backend DTO seam for API quickstart cards. It aggregates endpoint URLs, profile-aware available model sample, current virtual-key status, recent request ids, mock chat/responses/embeddings readiness, billing balance summary, and safe next actions. It is readback only and must not be treated as release evidence.

```ts
type UserDeveloperQuickstartReadback = {
  schema: "user_developer_quickstart_readback.v1" | string;
  project_id: string;
  endpoint: {
    base_url: string;
    openai_base_url: string;
    models_url: string;
    chat_completions_url: string;
    source: "runtime_config" | "local_fallback" | string;
    config_needed: boolean;
  };
  available_models: {
    total_visible: number;
    routable_count: number;
    sample: Array<{
      id: string;
      model: string;
      display_name: string;
      routable: boolean;
      routable_channel_count: number;
      primary_protocol?: string | null;
      route_status: "routable" | "config-needed" | string;
    }>;
  };
  model_availability_readback: ModelAvailabilityReadback;
  current_key_status: {
    total_keys: number;
    active_keys: number;
    disabled_keys: number;
    expired_keys: number;
    deleted_keys: number;
    current_status: "active" | "attention" | "missing" | string;
    latest_key?: {
      id: string;
      name: string;
      key_prefix: string;
      status: string;
      default_profile_id?: string | null;
      last_used_at?: string | null;
      created_at: string;
    } | null;
    raw_api_key_returned: false;
    secret_hash_returned: false;
  };
  recent_request_ids: string[];
  mock_readiness: Array<{
    endpoint: "mock_chat" | "mock_responses" | "mock_embeddings" | string;
    path: "POST /v1/chat/completions" | "POST /v1/responses" | "POST /v1/embeddings" | string;
    status: "recent-success" | "ready-to-try" | "config-needed" | string;
    route_ready: boolean;
    recent_success_count: number;
    required: string[];
    next_action: string;
  }>;
  billing_balance_summary: UserBalance;
  safe_next_actions: string[];
  handoff: {
    contract: "GET /user/developer-quickstart-readback" | string;
    source: "user_session_project_scoped_readback" | string;
    fallback: string;
    omitted_fields: string[];
    raw_payload_returned: false;
    authorization_returned: false;
    provider_key_returned: false;
  };
  secret_safe: boolean;
};
```

`model_availability_readback` is the compact key/profile/project-scoped readback for developer consoles. It is also returned at `GET /user/models` as `meta.model_availability_readback`.

```ts
type ModelAvailabilityReadback = {
  schema: "model_availability_readback.v1" | string;
  scope: {
    project_id: string;
    virtual_key_id?: string | null;
    api_key_profile_id?: string | null;
    profile_status?: string | null;
    source: "user_session_project_profile_virtual_key_scope" | string;
  };
  visible_models: UserDeveloperQuickstartReadback["available_models"];
  blocked_models: {
    total_blocked: number;
    explicit_denied_count: number;
    allowed_filter_hidden_count: number;
    unroutable_visible_count: number;
    reasons: Array<{
      reason: "profile_denied_model" | "profile_allowed_models_filter" | "visible_but_no_enabled_route" | string;
      count: number;
      sample_models: string[];
    }>;
  };
  protocol_capability_summary: Array<{
    protocol_mode: string;
    visible_model_count: number;
    routable_model_count: number;
    status: "routable" | "config-needed" | string;
  }>;
  quota_rate_budget_guardrails: {
    active_virtual_key_count: number;
    active_profile_count: number;
    rate_limit_policy_present: boolean;
    rate_limit_policy_present_count: number;
    budget_policy_present: boolean;
    budget_policy_present_count: number;
    pricing_guardrail_present: boolean;
    active_price_version_count: number;
    raw_policy_payload_returned: false;
    provider_key_returned: false;
  };
  safe_next_action: string;
  handoff: {
    contract: string;
    source: "profile_filtered_model_and_guardrail_counts" | string;
    omitted_fields: string[];
    raw_api_key_returned: false;
    api_key_secret_hash_returned: false;
    authorization_returned: false;
    provider_key_returned: false;
    raw_route_policy_returned: false;
    raw_payload_returned: false;
  };
  secret_safe: true;
};
```

Do not render or infer raw API key secret/hash, Authorization, provider key or provider-key id, raw route policy, raw rate/budget policy payload, prompts/messages, embedding input, upstream payload, raw request payload, or raw response payload from this surface. Real production provider smoke, real email delivery, and release evidence remain `[!]`.

Bulk import/sync of upstream mappings is currently a secret-safe UI entry point only where no live provider sync is wired. Mark it `pending/config-needed` unless a concrete backend response says otherwise.

## Admin: Requests, Trace, Usage

### Request Logs

- `GET /admin/request-logs`
- `GET /admin/request-logs/export.csv`
- `GET /admin/request-logs/{id}`
- `GET /admin/request-logs/{id}/payload`
- `GET /admin/traces/{trace_id}`

List filters:

```ts
type RequestLogListFilters = {
  limit?: number;
  created_from?: string;
  created_to?: string;
  status?: string;
  model?: string;
  canonical_model_id?: string;
  virtual_key_id?: string;
  api_key_profile_id?: string;
  channel_id?: string;
  resolved_channel_id?: string;
  stream?: boolean | string;
  error_code?: string;
  error_type?: string;
};
```

CSV export:

```ts
type AdminRequestLogsExportCsvFilters = RequestLogListFilters;

type AdminRequestLogsExportCsvContract = {
  schema_version: "admin_request_logs_export_csv.v1";
  content_type: "text/csv";
  audit_action: "request_logs.export_csv";
  primary_acceptance_surface: false;
  export_audit_readback: {
    schema: "admin_request_logs_export_audit_readback.v1";
    audit_action: "request_logs.export_csv";
    audit_readback_path: "GET /admin/audit-logs?action=request_logs.export_csv";
    audit_id_ref_present: false;
    redaction_policy: "metadata_only_safe_summary_columns";
    filtered_row_count_field: "filtered_row_count";
    safe_next_action: string;
  };
  allowed_columns: AdminRequestLogsExportCsvColumn[];
  forbidden_columns: AdminRequestLogsExportCsvForbiddenColumn[];
};

type AdminRequestLogsExportCsvColumn =
  | "request_id"
  | "created_at"
  | "completed_at"
  | "status"
  | "http_status"
  | "requested_model"
  | "canonical_model_id"
  | "channel_id"
  | "virtual_key_id"
  | "api_key_profile_id"
  | "trace_id"
  | "client_request_id"
  | "stream"
  | "latency_ms"
  | "ttft_ms"
  | "input_tokens"
  | "output_tokens"
  | "final_cost"
  | "currency"
  | "error_owner"
  | "error_code"
  | "redaction_status";

type AdminRequestLogsExportCsvForbiddenColumn =
  | "prompt"
  | "messages"
  | "raw_request_payload"
  | "raw_response_payload"
  | "raw_provider_payload"
  | "provider_response"
  | "raw_route_decision_snapshot"
  | "raw_route_snapshot"
  | "raw_payload"
  | "provider_key"
  | "provider_key_id"
  | "provider_secret"
  | "api_key_secret"
  | "authorization"
  | "cookie";
```

Export UI notes:

- Build `/admin/request-logs/export.csv` with the same query params as the list, then download the `text/csv` response.
- The CSV is a handoff/compliance-friendly troubleshooting export, not the main acceptance path. Keep request detail drawer and trace summary as the primary readback surfaces.
- UI code should reference `adminRequestLogsExportCsvContract` from `src/api/client.ts` and use only `allowed_columns` for any local fallback export.
- Backend export should write a best-effort Audit Logs entry with `action=request_logs.export_csv`; local fallback cannot create audit evidence and must be labelled as fallback only.
- Backend audit metadata includes `export_audit_readback` with `allowed_columns`, `filtered_row_count`, audit readback path/ref presence, metadata-only redaction policy, and a safe next action. Because the endpoint returns `text/csv`, the audit id itself is read back through `/admin/audit-logs?action=request_logs.export_csv`.
- The CSV schema and export audit are secret-safe by contract. They must not contain prompt text, messages, raw request/response payloads, raw provider/upstream payloads, provider responses, raw route snapshots, provider keys or provider key ids, API key secrets, virtual key secrets, `Authorization`, cookies, or other credential headers.
- Treat `virtual_key_id` and `channel_id` as correlation identifiers only. Do not label them as credentials in UI copy.

Admin audit logs detail readback:

`GET /admin/audit-logs` rows now include `audit_log_detail_readback` for the Audit Logs detail drawer. The UI may show:

- `resource_refs`: resource type/id presence, tenant ref presence, and request id presence.
- `action_result`: derived from sanitized metadata/status fields.
- `actor_session_presence`: actor user/session marker booleans only; no session value.
- `metadata_redaction_summary`: safe summary keys, redacted counts for metadata/before/after, and omitted material categories.
- `safe_next_action`: sanitized operator follow-up.

The drawer must not render raw token/session values, API key secrets, provider credential material, credential headers, raw payload/body, raw metadata JSON, or raw snapshots.

Core row:

```ts
type RequestLogSummary = {
  id: string;
  tenant_id: string;
  project_id?: string | null;
  virtual_key_id?: string | null;
  api_key_profile_id?: string | null;
  client_request_id?: string | null;
  inbound_protocol?: string | null;
  outbound_protocol?: string | null;
  requested_model?: string | null;
  upstream_model?: string | null;
  canonical_model_id?: string | null;
  resolved_provider_id?: string | null;
  resolved_channel_id?: string | null;
  provider_key_id?: string | null;
  status: string;
  http_status?: number | null;
  error_code?: string | null;
  error_owner?: string | null;
  retryable?: boolean | null;
  input_tokens: number;
  output_tokens: number;
  final_cost: string;
  currency: string;
  latency_ms?: number | null;
  ttft_ms?: number | null;
  partial_sent: boolean;
  stream_end_reason?: string | null;
  stream_finalizer?: RequestStreamFinalizerProjection | null;
  provider_protocol_summary?: RequestProviderProtocolSummary | null;
  openai_compat?: GatewayOpenAiCompatProjection | null;
  rate_limit_metadata?: RequestRateLimitMetadata | null;
  trace_id?: string | null;
  thread_id?: string | null;
  route_policy_version?: string | null;
  protocol_mode?: string | null;
  redaction_status: string;
  payload_policy_id?: string | null;
  payload_stored: boolean;
  request_body_hash?: string | null;
  response_body_hash?: string | null;
  metadata?: JsonValue | null;
  created_at: string;
  completed_at?: string | null;
};
```

`stream_finalizer` is the stable, secret-safe stream finalizer readback. It is derived from Gateway request-log metadata and existing request columns; UI must use this projection instead of rendering raw `route_decision_snapshot.stream_finalizer`.

```ts
type RequestStreamFinalizerProjection = {
  schema: "gateway_stream_finalizer_projection_v1";
  source_schema?: "gateway_stream_finalizer_v1" | string | null;
  status: "recorded" | "config-needed" | "not_recorded";
  secret_safe: true;
  partial_sent: boolean;
  end_reason?: string | null;
  ttft_ms?: number | null;
  usage_observed?: boolean | null;
  usage_recorded?: boolean | null;
  billing_eligible?: boolean | null;
  reserve_release_reason?: string | null;
  concurrency_release?: string | null;
};
```

When the Gateway finalizer metadata is absent, streamed rows should return `status: "config-needed"` with known column values and unknown finalizer-only fields as `null`. Non-stream rows should return `status: "not_recorded"`. The projection must not contain raw stream chunks, prompts, request/response payloads, provider payloads, Authorization headers, provider keys, or API key secrets.

`provider_protocol_summary` is the stable, secret-safe top-level readback for provider/downstream protocol and streaming token usage. It is derived only from the Gateway finalizer metadata allowlist and existing stream status columns; UI must use this projection instead of reading `route_decision_snapshot.stream_finalizer`.

```ts
type RequestProviderProtocolSummary = {
  schema: "gateway_provider_protocol_summary_v1";
  source_schema?: "gateway_stream_finalizer_v1" | string | null;
  status: "recorded" | "config-needed" | "not_recorded";
  secret_safe: true;
  downstream_protocol?: string | null;
  provider_protocol?: string | null;
  prompt_tokens?: number | null;
  completion_tokens?: number | null;
  total_tokens?: number | null;
  usage_observed?: boolean | null;
  usage_recorded?: boolean | null;
  end_reason?: string | null;
  end_reason_present: boolean;
  finish_reason_present?: boolean | null;
};
```

For Gemini-backed OpenAI-compatible streaming, the expected protocol values are `downstream_protocol: "openai_chat_completions"` and `provider_protocol: "gemini_generate_content"` when the Gateway finalizer recorded them. Missing finalizer metadata returns `config-needed`/`not_recorded` with protocol and token fields as `null`.

`rate_limit_metadata` is the stable, secret-safe Gateway virtual-key rate-limit readback for both stream and non-stream request logs. Streaming chat records this projection before entering the streaming provider loop; rows without Gateway rate-limit metadata return `status: "not_recorded"` and per-dimension `not_recorded` summaries. UI must not render raw `route_decision_snapshot.virtual_key_rate_limit`.

```ts
type RequestRateLimitMetadata = {
  schema: "gateway_rate_limit_metadata_v1";
  source_schema?: string | null;
  secret_safe: true;
  scope: "virtual_key" | string;
  status: "ok" | "limited" | "not_checked" | "not_recorded" | string;
  retry_after_ms?: number | null;
  window_status: "summary_only" | "not_windowed" | "not_recorded" | string;
  concurrency: RequestRateLimitDimensionMetadata;
  rpm: RequestRateLimitDimensionMetadata;
  tpm: RequestRateLimitDimensionMetadata;
};

type RequestRateLimitDimensionMetadata = {
  scope: "virtual_key" | string;
  status: "ok" | "limited" | "not_applied" | "configured" | "not_configured" | "not_recorded" | string;
  limit?: number | null;
  used?: number | null;
  remaining?: number | null;
  required?: number | null;
  retry_after_ms?: number | null;
  window_seconds?: number | null;
  window_status: "summary_only" | "not_windowed" | "not_recorded" | "not_configured" | string;
};
```

For RPM/TPM, `window_seconds` is `60` and `window_status` is `summary_only`; the raw minute bucket and raw window state are never returned. For concurrency, `window_seconds` is `null` and `window_status` is `not_windowed`. `used` and `remaining` are safe aggregate counters after a successful acquire when available.

`usage_explainability` / `billing_usage_source` is the stable, secret-safe request detail readback for usage and billing source provenance. It is derived from request-log safe projections, provider attempt summaries, and ledger refs only. It must not contain raw prompts, raw payloads, raw provider responses, Authorization, or provider keys.

```ts
type RequestUsageTokenSource = {
  tokens?: number | null;
  source: "adapter_usage_projection" | "gateway_request_log_fallback" | "not_recorded" | string;
  recorded: boolean;
  adapter_usage?: boolean;
  safe_mismatch_reason?: string | null;
};

type RequestUsageExplainability = {
  schema: "admin_request_usage_explainability_v1" | string;
  secret_safe: true;
  source: "request_log_detail_safe_read_model" | string;
  endpoint: {
    inbound_protocol?: string | null;
    outbound_protocol?: string | null;
    protocol_mode?: string | null;
    provider_protocol?: string | null;
    downstream_protocol?: string | null;
    openai_compat_endpoint?: string | null;
    requested_model_present?: boolean;
    upstream_model_present?: boolean;
  };
  adapter_usage: {
    observed: boolean;
    recorded: boolean;
    source: "adapter_usage_projection" | "not_observed" | string;
  };
  gateway_fallback: {
    used: boolean;
    source: "request_logs_token_columns" | "not_used" | string;
  };
  tokens: {
    prompt: RequestUsageTokenSource;
    completion: RequestUsageTokenSource;
    cache: RequestUsageTokenSource;
    reasoning: RequestUsageTokenSource;
    embedding: RequestUsageTokenSource;
  };
  provider_attempts: {
    count: number;
    usage_present: boolean;
    token_sum: number;
    fallback_attempt_present: boolean;
  };
  rating: {
    status: "rated_and_ledger_ref_present" | "ledger_ref_present_rating_ref_partial" | "not_rated_or_zero_cost" | "rated_without_ledger_ref" | string;
    final_cost?: string | null;
    currency?: string | null;
    price_version_ref_present: boolean;
  };
  ledger: {
    ref_present: boolean;
    confirmed_ref_present: boolean;
    entry_count: number;
    source: "ledger_entries_by_request_id" | string;
  };
  safe_mismatch_reasons: string[];
  omitted_fields?: string[];
};
```

When cache, reasoning, or embedding token counts are not present in the safe request detail projection, render their `source: "not_recorded"` and `safe_mismatch_reason` marker instead of inspecting raw route snapshots or payloads. Real production read-model evidence remains `[!]`; this is a backend contract/readback boundary, not release evidence.

`provider_attempts_explainability` is the stable, secret-safe request detail readback for provider attempts and fallback chain inspection. It is derived only from safe provider attempt columns: attempt number, provider/channel ids, status, HTTP status, retryable flag, safe error owner/code/category, fallback reason, latency, and first-token timing presence. It must not contain raw endpoint URLs, Authorization, provider key material, provider request ids, raw request payloads, raw response payloads, raw provider responses, or provider attempt metadata.

```ts
type RequestProviderAttemptsExplainability = {
  schema: "admin_provider_attempts_explainability_v1" | string;
  secret_safe: true;
  source: "request_log_detail_provider_attempts_safe_projection" | string;
  attempt_count: number;
  selected_attempt_no?: number | null;
  fallback_attempt_count: number;
  retryable_attempt_count: number;
  latency_observed: boolean;
  first_token_observed: boolean;
  selected_fallback_sequence: Array<{
    attempt_no: number;
    role?: "selected" | "fallback" | "candidate" | string;
    provider?: { id?: string | null; present: boolean };
    channel?: { id?: string | null; present: boolean };
    status: string;
    http_status?: number | null;
    retryable?: boolean | null;
    error_category: string;
    error_owner?: string | null;
    error_code?: string | null;
    fallback_reason?: string | null;
    latency?: {
      recorded: boolean;
      latency_ms?: number | null;
      first_token_recorded: boolean;
      ttft_ms?: number | null;
    };
  }>;
  fallback_sequence: Array<{
    attempt_no: number;
    provider_id?: string | null;
    channel_id?: string | null;
    status: string;
    fallback_reason?: string | null;
    retryable?: boolean | null;
    error_category: string;
    first_token_recorded?: boolean;
  }>;
  provider_channel_status: {
    attempts_recorded: boolean;
    selected_provider_id?: string | null;
    selected_channel_id?: string | null;
    terminal_status: string;
  };
  safe_next_action: string;
  omitted_fields?: string[];
};
```

UI should render the count/selected/fallback/retryable/latency/first-token summary first, then the per-attempt table. Use `safe_next_action` as operator guidance; do not infer retry advice from raw payloads or upstream responses.

`preauthorize_and_rate_limit_explainability` is the stable, secret-safe request detail readback for preauthorize and Gateway reservation decisions. It combines request-log error/status, safe rate-limit projection, provider attempt fallback summaries, route summary fields, and ledger ref presence only. It must not contain raw keys, Authorization, raw payloads, wallet credential material, provider credential material, raw rate-limit windows, raw route snapshots, or ledger metadata.

```ts
type RequestPreauthorizeRateLimitExplainability = {
  schema: "admin_preauthorize_and_rate_limit_explainability_v1" | string;
  secret_safe: true;
  source: "request_log_detail_safe_read_model" | string;
  preauthorize: {
    status: string;
    balance: { status: string; source: string; amount_omitted: true };
    budget: { status: string; source: string; amount_omitted: true };
    reject_reason?: string | null;
    provider_attempts_blocked: boolean;
  };
  rate_limit_reservation: {
    status: string;
    scope: "virtual_key" | string;
    retry_after_ms?: number | null;
    window_status: string;
    concurrency: RequestRateLimitDimensionMetadata & { reservation_status: string };
    rpm: RequestRateLimitDimensionMetadata & { reservation_status: string };
    tpm: RequestRateLimitDimensionMetadata & { reservation_status: string };
  };
  fallback_or_reject: {
    fallback_present: boolean;
    fallback_reasons: string[];
    route_fallback_reason?: string | null;
    reject_reason?: string | null;
    route_reject_reason?: string | null;
    billing_refusal_reason?: string | null;
  };
  safe_next_action: string;
  ledger_refs: {
    reservation_ref_present: boolean;
    settle_ref_present: boolean;
    any_ledger_ref_present: boolean;
    entry_count: number;
    source: "ledger_entries_by_request_id" | string;
  };
  omitted_fields?: string[];
};
```

Detail response:

```ts
type RequestTraceTimelineReadback = {
  schema: "admin_request_trace_timeline_readback.v1" | string;
  secret_safe: true;
  source: "request_log_detail_compact_safe_readback" | string;
  raw_material_returned: false;
  stages: {
    stage:
      | "auth_key_profile"
      | "routing_decision"
      | "preauthorize_rate_limit"
      | "provider_attempts_fallback"
      | "stream_finalizer"
      | "ledger_settlement"
      | "payload_preview_policy"
      | string;
    category: "auth" | "routing" | "preauth_rate_limit" | "provider" | "streaming" | "ledger" | "payload_policy" | string;
    status: string;
    latency: {
      recorded: boolean;
      latency_ms?: number | null;
      ttft_ms?: number | null;
    };
    refs: Record<string, JsonValue>; // presence/count/status only; do not treat as raw payload metadata
    safe_next_action: string;
  }[];
  omitted_fields: string[];
};

type RequestLogDetail = {
  request_log: RequestLogSummary;
  provider_protocol_summary?: RequestProviderProtocolSummary | null;
  usage_explainability?: RequestUsageExplainability | null;
  billing_usage_source?: RequestUsageExplainability | null;
  preauthorize_and_rate_limit_explainability?: RequestPreauthorizeRateLimitExplainability | null;
  provider_attempts_explainability?: RequestProviderAttemptsExplainability | null;
  trace_timeline_readback?: RequestTraceTimelineReadback | null;
  provider_attempts: ProviderAttempt[];
  ledger: RequestLedgerSummary;
  route_decision_snapshot: JsonValue;
};
```

`trace_timeline_readback` is the compact drawer-ready readback. It includes auth/key/profile, routing decision, preauthorize/rate-limit, provider attempts/fallback, stream finalizer, ledger settlement, and payload preview policy stages. Each stage is limited to `status`, `category`, `latency`, reference presence/counts, and `safe_next_action`; it does not return raw prompt/body/payload/provider response, Authorization, API key secret, provider key, provider key id, raw metadata, provider attempt metadata, or ledger metadata.

Provider attempt fields that matter to UI: `attempt_no`, `provider_id`, `channel_id`, `status`, `http_status`, `error_code`, `error_owner`, `retryable`, `fallback_reason`, `input_tokens`, `output_tokens`, `latency_ms`, `ttft_ms`, `upstream_model`. Prefer `provider_attempts_explainability` for operator readback; do not render provider key identifiers, provider request ids, raw metadata, endpoints, Authorization, or payload/response material.

Ledger summary fields that matter to UI: `entries[]` with `id`, `wallet_id`, `request_id`, `virtual_key_id`, `related_ledger_entry_id`, `price_version_id`, `entry_type`, `amount`, `currency`, `status`, `balance`, `refs`, `occurred_at`, `created_at`; plus `currencies`, `request_count`, `returned_count`, `limit_reached`, `omitted_fields`.

`balance` is optional and secret-safe. If historical wallet balance snapshots are not available, the backend returns `status: "config-needed"` with `before`/`after` as `null`; if an entry is not wallet-linked, it returns `status: "no-ledger"`. UI should render these markers instead of an empty cell or raw JSON.

`refs` is an optional secret-safe reference summary. Expected keys include `ledger_entry_id`, `wallet_id`, `project_id`, `request_id`, `virtual_key_id`, `related_ledger_entry_id`, `price_version_id`, `credit_grant_id`, `voucher_id`, `voucher_redemption_id`, `order_id`, `payment_intent_id`, `payment_capture_id`, `invoice_id`, `refund_id`, and `ref_source`. Do not display raw metadata, idempotency keys, provider keys, Authorization, or voucher raw codes.

Payload preview:

```ts
type RequestPayloadPreview = {
  available?: boolean;
  payload_stored?: boolean | null;
  payload_policy_id?: string | null;
  redaction_status?: string | null;
  request_body_hash?: string | null;
  response_body_hash?: string | null;
  redacted_request_preview?: JsonValue | null;
  redacted_response_preview?: JsonValue | null;
  request_metadata?: JsonValue | null;
  response_metadata?: JsonValue | null;
  omitted_fields?: string[] | null;
};
```

Default UI should show hashes, counts, and metadata. Only show redacted previews after explicit user action.

Trace summary:

```ts
type RequestTraceSummary = {
  trace_id: string;
  tenant_id: string;
  request_count: number;
  error_count: number;
  total_input_tokens: number;
  total_output_tokens: number;
  currencies: string[];
  first_request_at?: string | null;
  last_request_at?: string | null;
  last_error?: {
    code?: string | null;
    http_status?: number | null;
    observed_at: string;
    owner?: string | null;
    status: string;
  } | null;
  requests: RequestLogSummary[];
  ledger: RequestLedgerSummary;
  limit: number;
  limit_reached: boolean;
};
```

Request drawer UI notes:

- Filters should map directly to query params and be locally saveable without changing backend semantics.
- `error_type` is a convenience backend filter for categories such as rate limit, insufficient balance, reject, exact owner/code/status, and provider/upstream errors.
- Trace drawer should lazy-load `GET /admin/traces/{trace_id}` only when a trace id exists. Merge last error, fallback/reject reason, rate/balance signals, provider attempts, and ledger refs into one read path.
- Keep payload preview closed by default. A request log row with `payload_stored=false` or `redaction_status` indicating metadata-only should still be useful via hashes, route decision, attempts, and ledger summary.

## Admin: Virtual Keys and Network Security

### Admin Virtual Keys

- `GET /admin/virtual-keys?project_id=...&status=...`
- `GET /admin/virtual-keys/{id}`
- `POST /admin/virtual-keys`
- `POST /admin/virtual-keys/{id}/disable`
- `POST /admin/virtual-keys/{id}/restore`
- `POST /admin/virtual-keys/{id}/expire`
- `GET /admin/virtual-keys/leak-candidates?project_id=...&status=...`
- `POST /admin/virtual-keys/bulk-leak-action`

Core DTO:

```ts
type VirtualKey = {
  id: string;
  tenant_id: string;
  project_id: string;
  name: string;
  key_prefix: string;
  status: "active" | "disabled" | "expired" | "deleted" | string;
  default_profile_id?: string | null;
  budget_policy: JsonValue;
  rate_limit_policy: JsonValue;
  ip_allowlist: JsonValue;
  metadata: JsonValue;
  secret?: string;
  secret_once?: boolean;
  secret_redacted: boolean;
};
```

Create response may include `secret` once. Admin and user UIs must show it once, never store it, and then rely on `key_prefix`.

Leak candidate readback:

```ts
type VirtualKeyLeakCandidate = {
  key_id: string;
  key_prefix: string;
  status: string;
  reason: string;
  source: "operator_report" | "internal_audit_handoff" | "external_scanner_handoff" | "support_ticket_handoff" | string;
  safe_markers: ("manual_marker" | "audit_marker" | "external_scanner_config_needed" | string)[];
  rule_status: "manual_marker_active" | "audit_marker_active" | "external_scanner_config_needed" | string;
  next_step: string;
  first_seen: string | null;
  last_seen: string | null;
  confidence: number;
  action_recommendation: "operator_confirm_disable_or_revoke" | "operator_review_then_confirm" | "monitor_or_close_after_review" | string;
  operator_confirmation_required: true;
  automatic_action: false;
};

type VirtualKeyLeakCandidatesResponse = {
  leak_candidates: VirtualKeyLeakCandidate[];
  suspected_leaked: VirtualKeyLeakCandidate[]; // compatibility alias
  source_policy: {
    source_policy_version: "virtual-key-leak-detection-rules-v1" | string;
    accepted_candidate_sources: string[];
    safe_markers: {
      marker: "manual_marker" | "audit_marker" | "external_scanner_config_needed" | string;
      status: "active" | "config-needed" | string;
      next_step: string;
    }[];
    scanner_adapter: {
      status: "config-needed" | string;
      external_scanner_connected: false;
      accepts_raw_payloads: false;
      last_scan_marker?: {
        marker_present: boolean;
        external_candidate_count?: number;
        marker_counts?: Record<string, number>;
      };
      next_step: string;
    };
    candidate_only_until_confirmed: true;
    forbidden_response_material: string[];
    destructive_actions_require_operator_confirmation: ("disable" | "revoke")[];
  };
  operator_confirmation_required: true;
  automatic_disable_or_revoke: false;
  secret_safe: true;
  payload_omitted: true;
};
```

Candidate sources and safety boundary:

- Candidate sources are bounded handoffs only: operator report, internal audit handoff, external scanner handoff, or support ticket handoff. The backend must not run external secret scans from this UI path.
- `safe_markers` explains which safe seam produced the candidate: `manual_marker`, `audit_marker`, or `external_scanner_config_needed`. The external scanner adapter is currently config-needed and accepts only bounded handoff metadata, never raw leak payloads.
- `POST /admin/virtual-keys/external-scanner/handoff` accepts only bounded scanner summaries: provider, finding count, key prefix/hash presence booleans, repo/ref hash, severity, detected_at, signature_validated, and optional virtual_key_id. It must never be used to send raw findings, raw tokens/keys, raw secret/hash values, Authorization, scanner secrets, webhook bodies, request bodies, or raw payloads.
- When `virtual_key_id` is supplied and found, the handoff writes `virtual_keys.metadata.leak_detection.source = "external_scanner_handoff"` with an `external_scanner_summary_marker`; otherwise it returns `external_scanner_marker_planned`. Real scanner/vault/webhook verification and provider finding parser remain `[!]`.
- The candidate readback shape is limited to key id, non-secret prefix, current status, bounded reason/source, first/last seen timestamps, confidence, and action recommendation.
- `suspected_leaked` is a candidate marker, not an automatic runtime shutdown. Operators must explicitly confirm `disable` or `revoke` through the bulk action endpoint.
- Do not render or persist virtual key secrets, secret hashes, raw leaked-key values, raw tokens, Authorization headers, raw detection payloads, or request bodies. If a reason/source contains sensitive-looking text, treat the backend-redacted value as authoritative and do not attempt to reconstruct it client-side.

Bulk leak action:

```ts
type BulkVirtualKeyLeakActionRequest = {
  key_ids: string[];
  action: "suspected_leaked" | "disable" | "revoke";
  reason: string;
};

type BulkVirtualKeyLeakActionResult = {
  key_id: string;
  key_prefix: string | null;
  status: string | null;
  action_result: string;
  audit_log_id: string | null;
};

type BulkVirtualKeyLeakActionSummary = {
  operation_id: string;
  action: "suspected_leaked" | "disable" | "revoke";
  affected_count: number;
  failed_count: number;
  audit_log_ids: string[];
  request_id: string | null;
  secret_safe: true;
  payload_omitted: true;
};

type BulkVirtualKeyLeakActionResponse = {
  data: BulkVirtualKeyLeakActionResult[];
  result: BulkVirtualKeyLeakActionSummary;
};
```

UI rules:

- Require a human `reason` before enabling the bulk action button.
- Render only `key_id`, `key_prefix`, final `status`, `action_result`, and safe audit refs.
- After submit, store/display `result.operation_id`, `affected_count`, `failed_count`, `audit_log_ids`, and per-row `audit_log_id` as the most recent bulk operation handoff. `request_id` is reserved and currently null.
- `suspected_leaked` is a metadata candidate action; `disable` and `revoke` are destructive for runtime access and must use a confirmation step.
- Do not render or persist virtual key secrets, secret hashes, raw leaked-key values, raw detection payloads, or request bodies from this workflow; the response intentionally omits them.

Key restore:

```ts
type RestoreVirtualKeyRequest = {
  reason: string;
};

type RestoreVirtualKeyResponse = {
  id: string;
  key_id: string;
  key_prefix?: string | null;
  status: "active" | "disabled" | "expired" | "deleted" | string;
  action_result:
    | "restored"
    | "unchanged_active"
    | "restore_refused_deleted"
    | "restore_refused_expired"
    | "restore_refused_unsupported_status"
    | string;
  audit_log_id?: string | null;
  restore_supported: boolean;
  safety_reason?: string | null;
  secret_returned: false;
};
```

Restore only supports disabled-to-active. Deleted or expired keys must be reissued. UI must show `action_result`, `audit_log_id`, and `safety_reason` but never render or request the original key secret.

### Admin Users Management

- `GET /admin/users?project_id=...&status=...&search=...&limit=...`
- `GET /admin/projects/{id}/members-summary`
- `GET /admin/users/{id}/detail`
- `PATCH /admin/users/{id}/status`
- `POST /admin/users/bulk-status`
- `POST /admin/users/bulk-operation-plan`
- Supporting drilldowns use existing safe surfaces: `GET /admin/wallets`, `GET /admin/virtual-keys`, `GET /admin/request-logs`, and `GET /admin/ledger/entries`.

Compact membership readback:

```ts
type MembershipProjectAccessSummary = {
  active_key_count?: number;
  key_count?: number;
  user_active_key_count?: number;
  user_key_count?: number;
  key_access_present: boolean;
  active_profile_count: number;
  profile_access_present: boolean;
  source: string;
  secret_returned: false;
};

type MembershipRecentUsageSummary = {
  window_days: number;
  request_count: number;
  succeeded_count?: number;
  failed_count?: number;
  cost_present: boolean;
  final_cost: string;
  last_request_at?: string | null;
  source: string;
  payload_returned: false;
};

type AdminProjectMembersSummary = {
  schema: "admin_project_membership_compact_readback.v1";
  tenant_id: string;
  project_id: string;
  project_status: string;
  member_count: number;
  members: Array<{
    user_id: string;
    role: string;
    status: string;
    membership_source: "project_members";
    membership_created_at?: string | null;
    project_access: MembershipProjectAccessSummary;
    recent_usage: MembershipRecentUsageSummary;
    safe_next_action: string;
    raw_email_returned: false;
    secret_returned: false;
  }>;
  project_access: MembershipProjectAccessSummary;
  recent_usage: MembershipRecentUsageSummary;
  safe_next_action: string;
  tenant_scoped: true;
  project_scoped: true;
  raw_email_returned: false;
  secret_safe: true;
  omitted_fields: string[];
};

type AdminUserMembershipSummary = {
  schema: "admin_user_membership_compact_readback.v1";
  tenant_id: string;
  user_id: string;
  member_count: number;
  memberships: Array<{
    project_id: string;
    project_status: string;
    role: string;
    status: string;
    membership_source: "project_members";
    project_access: MembershipProjectAccessSummary;
    recent_usage: MembershipRecentUsageSummary;
    safe_next_action: string;
    secret_returned: false;
  }>;
  safe_next_action: string;
  raw_email_returned: false;
  secret_safe: true;
  omitted_fields: string[];
};
```

`GET /admin/projects/{id}/members-summary` is the preferred admin project/team card readback. `GET /admin/users/{id}/detail` also includes `membership_summary` for the selected user. The access and usage summaries are project scoped; when a key was created by a user, the user-detail membership summary may expose `user_active_key_count`, but request usage remains project scoped because request logs do not consistently encode member ownership.

This contract must not render raw email from the compact membership surfaces, API key secret/hash, Authorization/Cookie, provider key/provider secret, raw request/response/provider payload, raw tenant/project/user metadata, or raw audit snapshots.

Core DTO:

```ts
type AdminManagedUser = {
  id: string;
  tenant_id?: string | null;
  email?: string | null;
  display_name?: string | null;
  status: "active" | "disabled" | "deleted" | "invited" | string;
  last_login_at?: string | null;
  metadata?: JsonValue | null;
  created_at?: string | null;
  primary_project_id?: string | null;
  project_ids?: string[];
};

type PatchAdminManagedUserStatusRequest = {
  status: "active" | "disabled";
  reason: string;
};

type BulkAdminManagedUserStatusRequest = PatchAdminManagedUserStatusRequest & {
  user_ids: string[];
};

type AdminManagedUserStatusActionResult = {
  id: string;
  user_id: string;
  status: "active" | "disabled" | string;
  action_result: "disabled" | "restored" | "unchanged_active" | "unchanged_disabled" | string;
  audit_log_id?: string | null;
  primary_project_id?: string | null;
  project_ids?: string[];
  readback?: {
    schema: "admin_managed_user_status_readback.v1";
    source: "users_table_after_write";
    user_status: "active" | "disabled" | "deleted" | string;
    status_matches_target: boolean;
    audit_log_readback: boolean;
    project_membership_readback: boolean;
    project_count: number;
    project_rollup_fallback: {
      supported: true;
      source: "wallet_virtual_key_request_ledger_rollup";
      write_allowed: false;
      requires_user_id_for_status_write: true;
    };
    omitted_fields: string[];
    secret_safe: true;
  };
};

type AdminManagedUserBulkStatusResponse = {
  schema: "admin_managed_users_bulk_status.v1";
  operation_id: string;
  requested_status: "active" | "disabled" | string;
  affected_count: number;
  failed_count: number;
  audit_log_ids: string[];
  results: Array<AdminManagedUserStatusActionResult & {
    operation_id?: string;
    requested_status?: string;
    write_allowed?: boolean;
    secret_safe?: true;
    error?: {
      code?: string;
      message?: string;
      status?: number;
    };
  }>;
  project_rollup_fallback: {
    supported: true;
    source: "wallet_virtual_key_request_ledger_rollup";
    write_allowed: false;
    requires_user_id_for_status_write: true;
  };
  omitted_fields: string[];
  secret_safe: true;
};

type AdminManagedUserBulkOperationPlanRequest = {
  mode?: "dry_run";
  action: "disable" | "restore" | "audit_export" | "review";
  reason: string;
  selected_user_ids?: string[];
  filters?: {
    limit?: number;
    project_id?: string;
    search?: string;
    status?: AdminManagedUser["status"];
  };
};

type AdminManagedUserBulkOperationPlan = {
  schema: "admin_managed_users_bulk_operation_plan.v1";
  mode: "dry_run";
  action: string;
  reason_required: true;
  reason_present: boolean;
  scope: {
    source: "selected_user_ids" | "filters";
    selected_user_count: number;
    filter_project_id?: string | null;
    filter_status?: string | null;
    filter_search_present: boolean;
    limit: number;
    tenant_scope: "current_admin_tenant";
    cross_tenant_lookup_allowed: false;
  };
  affected_estimate: {
    estimated_user_count: number;
    active_user_count: number;
    disabled_user_count: number;
    missing_selected_count: number;
    estimate_source: "users_table_tenant_scoped_readback";
  };
  blocked_reasons: JsonValue[];
  rows: Array<{
    user_id: string;
    status: AdminManagedUser["status"];
    project_count: number;
    project_ids: string[];
    planned_action_result: string;
    blocked_reasons: string[];
    write_allowed: false;
    detail_path: string;
    secret_safe: true;
  }>;
  risk_policy_summary: {
    schema: "admin_users_bulk_risk_policy_summary.v1";
    policy_source: "local_readback_rules";
    external_ml_connected: false;
    external_siem_connected: false;
    automatic_enforcement: false;
    operator_confirmation_required: true;
    status: "review-ready" | "attention" | "blocked" | "no-op" | string;
    signals: JsonValue;
    summary: string;
    forbidden_material_returned: false;
  };
  audit_export_plan: {
    schema: "admin_users_audit_export_plan.v1";
    status: "plan-only";
    source: "audit_logs";
    external_siem_connected: false;
    export_ready: boolean;
    recommended_format: "jsonl";
    safe_fields: string[];
    forbidden_fields: string[];
    raw_snapshots_returned: false;
    next_step: string;
  };
  apply_policy: {
    apply_supported: false;
    safe_status_apply_path?: "POST /admin/users/bulk-status" | null;
    allowed_apply_actions: ["disable", "restore"];
    dangerous_cross_tenant_write_allowed: false;
    message: string;
  };
  project_rollup_fallback: {
    supported: true;
    source: "wallet_virtual_key_request_ledger_rollup";
    write_allowed: false;
    requires_user_id_for_status_write: true;
  };
  omitted_fields: string[];
  secret_safe: true;
};

type AdminManagedUserDetail = {
  schema: "admin_managed_user_detail.v1";
  user: AdminManagedUser;
  wallet_summary: {
    source: "wallets";
    project_scoped: true;
    wallet_count: number;
    active_wallet_count: number;
    currencies: JsonValue;
    first_wallet_created_at?: string | null;
    last_wallet_updated_at?: string | null;
    readback_status: "ready" | "no-project-membership" | string;
  };
  key_summary: {
    source: "virtual_keys";
    project_scoped: true;
    key_count: number;
    active_key_count: number;
    inactive_key_count: number;
    last_key_used_at?: string | null;
    recent_keys: JsonValue;
    secret_returned: false;
  };
  request_summary: {
    source: "request_logs";
    project_scoped: true;
    request_count: number;
    succeeded_count: number;
    failed_count: number;
    success_rate?: number | null;
    input_tokens: number;
    output_tokens: number;
    final_cost: string;
    currencies: JsonValue;
    last_request_at?: string | null;
    recent_error_codes: JsonValue;
    payload_returned: false;
  };
  ledger_summary: {
    source: "ledger_entries";
    project_scoped: true;
    ledger_entry_count: number;
    confirmed_entry_count: number;
    confirmed_credit_total: string;
    confirmed_debit_total: string;
    currencies: JsonValue;
    last_ledger_entry_at?: string | null;
    idempotency_key_returned: false;
  };
  recent_audit_summary: {
    schema: "admin_user_recent_audit_summary.v1";
    source: "audit_logs";
    audit_log_count: number;
    last_audit_at?: string | null;
    recent_actions: JsonValue;
    raw_snapshots_returned: false;
    metadata_sanitized: true;
  };
  risk_policy_summary: {
    schema: "admin_user_risk_policy_summary.v1";
    status: "normal" | "attention" | "config-needed" | string;
    policy_source: "local_readback_rules";
    external_ml_connected: false;
    external_siem_connected: false;
    automatic_enforcement: false;
    operator_confirmation_required: true;
    signals: {
      user_status: string;
      active_key_count: number;
      failed_request_count: number;
      project_count: number;
    };
    recommendation: string;
    forbidden_material_returned: false;
  };
  tenant_boundary: {
    schema: "admin_user_tenant_boundary.v1";
    tenant_id: string;
    requested_user_id: string;
    tenant_scope: "current_admin_tenant";
    cross_tenant_lookup_allowed: false;
    cross_tenant_result_count: 0;
    project_ids: string[];
    project_count: number;
    project_rollup_fallback_write_allowed: false;
    source_tables: string[];
    boundary_status: "tenant-scoped" | "no-project-membership" | string;
  };
  project_rollup_fallback: {
    supported: true;
    source: "wallet_virtual_key_request_ledger_rollup";
    write_allowed: false;
    requires_user_id_for_status_write: true;
  };
  production_audit_report: {
    schema: "admin_user_production_audit_report_minimal.v1";
    status: "minimal-readback";
    source: "audit_logs";
    external_siem_connected: false;
    raw_snapshots_returned: false;
    next_step: string;
  };
  omitted_fields: string[];
  secret_safe: true;
};
```

UI handoff:

- Users Management is a composed admin surface. Use `/admin/users` for identity/status, `/admin/wallets` for balance summary, `/admin/virtual-keys` for key counts/actions, `/admin/request-logs` for request drilldown, and `/admin/ledger/entries` for ledger rows.
- User detail pages should prefer `GET /admin/users/{id}/detail` for the first readback. It aggregates existing project-scoped safe surfaces and includes stable seams for `risk_policy_summary`, `tenant_boundary`, and `production_audit_report` without claiming a connected ML/SIEM backend.
- Current Users Management UI already opens detail readback from the user list and from bulk status per-row results. The panel renders wallet/key/request/ledger summaries, recent audit, `risk_policy_summary`, `tenant_boundary`, `production_audit_report`, and `omitted_fields` while keeping project rollup rows read-only.
- User detail readback includes project-scoped `funding_source_readback` with the same compact, secret-safe shape used by wallet and remaining-balance surfaces.
- Disable/restore requires a human `reason`; render the returned `action_result`, `audit_log_id`, and `readback.status_matches_target` / `readback.audit_log_readback` when present.
- Bulk status operations require real `user_ids`, return `operation_id`, `affected_count`, `failed_count`, safe `audit_log_ids`, and per-row `action_result`/`audit_log_id` or error summary. Bulk UI must not submit project rollup fallback rows.
- Bulk operation plans are dry-run only. `POST /admin/users/bulk-operation-plan` may use selected ids or current filters and returns affected estimate, blocked reasons, per-row planned result, local risk policy summary, and `audit_export_plan`. The only writable follow-up path is the existing safe status endpoint `POST /admin/users/bulk-status`; the plan endpoint itself must keep `apply_supported=false`.
- If `/admin/users` is unavailable, the UI may temporarily show a project rollup from wallet/key/request/ledger data. This fallback is read-only for user status: `project_rollup_fallback.write_allowed=false` and disable/restore must stay disabled until a real `user_id` is present.
- Do not display password hashes, session tokens, user API key secrets, Authorization headers, voucher raw codes, raw request payloads, provider keys, or raw audit snapshots. Treat `metadata` as already sanitized backend output, not as a free-form raw payload viewer.

### Network Security Settings

- `GET /admin/settings/network-security`
- `PATCH /admin/settings/network-security`

Read DTO:

```ts
type NetworkSecuritySettings = {
  schema: "admin_network_security_settings.v1" | string;
  status: "configured" | "config-needed" | "pending" | string;
  secret_safe: true;
  trusted_proxy_config_source: "runtime_config" | "config-needed" | string;
  effective_trusted_proxy_allowlist: string[];
  hot_reload_supported: false;
  recommended_env_keys: string[];
  action_result?: string;
  requested_trusted_proxy_allowlist_count?: number;
  allowlist_handoff?: {
    editable_fields: Array<{
      field: "api_key_profiles.ip_allowlist" | string;
      apply_path: "PATCH /admin/api-key-profiles/{id}" | string;
      readback_path: "GET /admin/api-key-profiles?project_id={project_id}" | string;
      effect: string;
    }>;
    read_only_fields: Array<{
      field: "virtual_keys.ip_allowlist" | string;
      readback_path: "GET /admin/virtual-keys?project_id={project_id}" | string;
      change_path: "create or rotate the virtual key" | string;
      effect: string;
    }>;
    config_file_fields: Array<{
      field: "server.trusted_proxy_allowlist" | string;
      config_path_env: "AI_GATEWAY_CONFIG" | string;
      patch_path: "PATCH /admin/settings/network-security" | string;
      patch_behavior: string;
      restart_required: boolean;
    }>;
  };
  config_keys: {
    config_path_env: "AI_GATEWAY_CONFIG" | string;
    trusted_proxy_allowlist: "server.trusted_proxy_allowlist" | string;
  };
  example_generator?: {
    script_path: "scripts/write_network_security_config_example.ps1" | string;
    default_output_path: ".tmp/network-security/network_security_config_example.yaml" | string;
    command: string;
    print_only_command: string;
    print_only_behavior: string;
    contains_real_networks_or_secrets: false;
    example_address_policy: string;
  };
  next_action: string;
};
```

Patch request:

```ts
type PatchNetworkSecuritySettingsRequest = {
  trusted_proxy_allowlist?: string[];
};
```

Current server behavior: `GET` is stable readback. `PATCH` returns `501/config_needed` with a safe `data` payload because trusted proxy allowlist is loaded from `AI_GATEWAY_CONFIG` at `server.trusted_proxy_allowlist`; UI should unwrap the safe `data` payload, mark writes as `config-needed`, show `action_result`/`next_action`, and keep `requested_trusted_proxy_allowlist_count` as a count-only submission summary. Profile `ip_allowlist` is UI editable through `PATCH /admin/api-key-profiles/{id}` and should be read back from that response. Virtual key `ip_allowlist` is readback-only in this settings surface; change it by creating or rotating the key. The `allowlist_handoff` object is the field-level source of truth for which fields are UI-editable, readback-only, or config-file/restart-required.

Settings UI should expose the `example_generator` handoff when present. The default command is:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\write_network_security_config_example.ps1
```

It writes `.tmp/network-security/network_security_config_example.yaml` by default. The `-PrintOnly` command prints the YAML to stdout only and must not create or overwrite files. The generated YAML is documentation/local-deployment material only: it uses RFC5737 IPv4 and RFC3849 IPv6 documentation ranges and must not include real production client, office, VPN, load balancer, provider, Authorization, provider key, API key, or secret values.

## Admin: Billing, Voucher, Wallet

## Admin: Import Wizard Apply-plan

The Import Wizard is currently a browser-local review surface for importer artifacts and operator commands. It does not upload artifacts or execute apply-live from the UI.

Supported source-specific review lanes:

- NewAPI: channels/providers, groups, model mappings, quota/opening balance candidates, and user key reissue plans.
- OneAPI: channels, token aliases/fingerprints, groups, model mappings, quota/opening balance candidates, and manual conflict review.
- Sub2API: accounts to provider/channel, group to profile/subscription plan, user create/link, wallet lookup, opening balance ledger import, key reissue, and subscription mapping.

Secret-safe rules for importer UI:

- Provider keys, upstream tokens, user API keys, proxy passwords, payment secrets, Authorization headers, and raw idempotency keys must not be written into an apply-plan or rendered from an artifact.
- Raw token/key material may only be represented as alias, prefix, fingerprint, status, and operator handoff instructions.
- Provider-key operator handoff artifacts must use a sidecar shape with provider/channel alias, non-secret fingerprint, `required_manual_secret_entry=true`, and rotation/recovery next steps. The raw secret is entered exactly once through the Control Plane Provider Keys form or `POST /admin/provider-keys`; it is never copied from an import report.
- Identity and billing apply-live plans must expose user link/create intent, wallet lookup/create intent, opening balance ledger entries, key reissue requirements, subscription mapping, idempotency, rollback, and journal summaries without raw secrets.
- `config-needed`, `manual-review`, and `operator-handoff` are expected product states. The UI should explain what can migrate automatically and what must be handled by an operator.

Provider-key sidecar contract:

```ts
type ImportProviderKeyOperatorSidecar = {
  schema_version: "importer.provider-key-operator-sidecar.v1";
  handoff_id: string;
  provider_alias: string;
  channel_alias: string;
  channel_source_id: string | null;
  key_alias: string;
  fingerprint: string;
  required_manual_secret_entry: true;
  raw_secret_in_artifact: false;
  secret_material_in_artifact: false;
  required_operator_path: "POST /admin/provider-keys";
  apply_mode: "sidecar_only";
  apply_directly_supported: false;
  manual_secret_entry_contract: {
    schema_version: "importer.provider-key-manual-secret-entry.v1";
    one_time_entry_only: true;
    raw_secret_source: "operator_out_of_band";
    entry_path: "POST /admin/provider-keys";
    packet_contains_secret_material?: false;
  };
  rotation_next_step: string;
  recovery_next_step: string;
};
```

Operator packet contract:

- `scripts/importers/verify-import-provider-key-operator-handoff-packet.ps1` writes `.tmp/importers/provider_key_operator_handoff/summary.json` plus per-source `*.operator_handoff_packet.json` files.
- Packets use `schema: "importer.provider-key-operator-handoff-packet.v1"` and carry `create_handoff_metadata[]` entries with the sidecar fields above.
- Import Wizard should show the packet path, provider/channel alias, key alias, fingerprint, required manual entry state, rotation next step, and recovery next step.
- Verifiers must fail if packet/apply-plan artifacts contain raw provider keys, raw upstream tokens, bearer values, credential headers, user key secrets, or provider-key SQL write operations.

Source-specific dry-run and handoff artifacts may expose this optional field. The UI should prefer it when present, and fall back to legacy arrays (`channels`, `provider_keys`, `associations`, `manual_review_items`) when absent:

```ts
type ImportSourceSpecificApplyPlanArtifacts = {
  schema_version: "importer.source-specific-apply-plan-artifacts.v1";
  source_system: "new-api" | "one-api" | "sub2api" | string;
  secret_safe: true;
  raw_provider_key_material_included: false;
  raw_user_key_material_included: false;
  raw_email_included?: false;
  categories: {
    migratable: {
      channels: JsonValue[];
      model_mappings: JsonValue[];
    };
    manual: {
      provider_key_operator_handoffs?: JsonValue[];
      group_mappings?: JsonValue[];
      user_link_candidates?: JsonValue[];
      wallet_opening_balance_candidates?: JsonValue[];
      user_key_reissue_handoffs?: JsonValue[];
      subscription_mappings?: JsonValue[];
      price_book_multiplier_mappings?: JsonValue[];
    };
    blocked: {
      provider_key_direct_import?: JsonValue[];
      raw_user_key_import?: JsonValue[];
      user_key_reissue_handoffs?: JsonValue[];
      opening_balance_direct_apply?: JsonValue[];
      identity_billing_direct_apply?: JsonValue[];
      subscription_direct_apply_without_package_mapping?: JsonValue[];
    };
  };
  classification_counts: {
    migratable: number;
    manual: number;
    blocked: number;
  };
  automation_matrix?: {
    automatic_apply: string[];
    operator_handoff: string[];
    blocked_without_operator: string[];
  };
  executable_handoff?: {
    schema_version: "importer.source-specific-executable-handoff.v1";
    source_system: "new-api" | "one-api" | "sub2api" | string;
    generated_for: "reviewed_apply_plan" | "identity_billing_reviewed_apply_plan" | string;
    secret_safe: true;
    runner_inputs: JsonObject;
    executable_fields: JsonObject;
    apply_modes: JsonObject;
    difference_explanation: {
      automatic: string;
      manual: string;
      blocked: string;
    };
    forbidden_payload_fields: string[];
  };
};
```

Executable handoff semantics:

- NewAPI automatic fields: `channel` and `model_mapping`; operator fields: `group`, `rate`, provider-key handoff, user-key reissue, and opening balance unit review.
- OneAPI automatic fields: `channel` and `model_mapping`; operator fields: channel token/provider-key handoff, `group`, user-key reissue, and opening balance unit review.
- Sub2API automatic field: account-derived provider/channel shape; operator fields: user link/create, wallet lookup/create, opening balance ledger import, provider-key entry, user-key reissue, and subscription package mapping.
- Raw provider keys, raw channel tokens, raw user keys, proxy passwords, payment secrets, bearer tokens, and authorization headers must never appear in `runner_inputs`, apply payloads, UI previews, rollback snapshots, or generated artifacts.
- Generic `importer.apply-plan.v1` artifacts may carry source-specific contracts as `source_specific_apply_plan_artifacts[]`, where each item wraps the original `apply_plan_artifacts` under `artifacts`.

Source-specific handoff verifier:

- `scripts/importers/verify-import-source-specific-apply-plan-handoff.ps1` is the canonical field matrix check for NewAPI, OneAPI, Sub2API provider/channel handoff, and Sub2API identity/billing handoff.
- The verifier writes `.tmp/importers/source_specific_apply_plan_handoff/summary.json` with `schema_version: "importer.source-specific-apply-plan-handoff-summary.v1"`.
- NewAPI current matrix:
  - Automatic: `channels`, `model_mappings`.
  - Operator/manual: `provider_key_operator_handoffs`, `group_mappings`, `price_book_multiplier_mappings`, `wallet_opening_balance_candidates`.
  - Blocked without operator: `provider_key_direct_import`, `user_key_reissue_handoffs`, `opening_balance_direct_apply`.
  - Remaining post-apply gap: production apply-live still needs reviewed price-book/group mapping, opening-balance unit confirmation, provider-key operator entry, and user-key reissue execution.
- OneAPI current matrix:
  - Automatic: `channels`, `model_mappings`.
  - Operator/manual: `provider_key_operator_handoffs`, `group_mappings`, `price_book_multiplier_mappings`, `wallet_opening_balance_candidates`.
  - Blocked without operator: `provider_key_direct_import`, `user_key_reissue_handoffs`, `opening_balance_direct_apply`.
  - Remaining post-apply gap: production apply-live still needs operator token/provider-key entry, reviewed group mapping, opening-balance unit confirmation, and user-key reissue execution.
- Sub2API provider/channel current matrix:
  - Automatic: `channels`.
  - Operator/manual: `provider_key_operator_handoffs`, `group_mappings`, `user_link_candidates`, `wallet_opening_balance_candidates`, `subscription_mappings`.
  - Blocked without operator: `provider_key_direct_import`, `user_key_reissue_handoffs`, `identity_billing_direct_apply`.
- Sub2API identity/billing current matrix:
  - Automatic: none.
  - Operator/manual: `user_link_candidates`, `wallet_opening_balance_candidates`, `user_key_reissue_handoffs`, `subscription_mappings`.
  - Blocked without operator: `raw_user_key_import`, `opening_balance_direct_apply_without_unit_review`, `subscription_direct_apply_without_package_mapping`.
  - Remaining post-apply gap: production apply-live still needs reviewed user create/link, wallet lookup/create, opening-balance ledger import, user-key reissue, and subscription package apply runner.

### Price Versions

- `GET /admin/price-versions`
- `POST /admin/price-versions`

Core DTO:

```ts
type PriceVersion = {
  id: string;
  tenant_id: string;
  price_book_id: string;
  canonical_model_id?: string | null;
  version: string;
  status: "draft" | "active" | "retired" | string;
  pricing_rules: {
    currency: string;
    input_token_rate_per_1m?: string | number | null;
    output_token_rate_per_1m?: string | number | null;
    cache_token_rate_per_1m?: string | number | null;
    reasoning_token_rate_per_1m?: string | number | null;
    fixed_request_cost?: string | number | null;
    scale?: number | null;
  } | JsonValue;
  effective_at: string;
  retired_at?: string | null;
  created_at: string;
};
```

Use fixed-decimal display and label token rates as per 1M tokens. Do not render raw advanced JSON when it contains secret-like keys; keep JSON editing behind an advanced control.

### Wallet Credit Surfaces

- `GET /admin/wallets`
- `GET /admin/wallets/{wallet_id}?ledger_window_days=...`

List filters: `currency`, `project_id`, `status`, `limit`.

Core DTO:

```ts
type AdminWalletCreditSurface = {
  wallet: {
    id: string;
    tenant_id: string;
    project_id?: string | null;
    name: string;
    currency: string;
    status: string;
    balance_floor: string;
    created_at: string;
    updated_at: string;
  };
  credit_grants: {
    active_count: number;
    active_amount_total: string;
    active_remaining_total: string;
    expired_count: number;
    expired_amount_total: string;
    consumed_count: number;
    voided_count: number;
    total_count: number;
    grants: Array<{
      id: string;
      amount: string;
      remaining_amount: string;
      currency: string;
      source: string;
      status: string;
      valid_from: string;
      valid_until?: string | null;
      created_at: string;
    }>;
  };
  credit_grant_expiration_readback: {
    schema: "credit_grant_expiration_readback.v1" | string;
    source: "credit_grants" | string;
    wallet_id: string;
    total_count: number;
    active_count: number;
    expired_count: number;
    expiring_soon_count: number;
    expiring_soon_window_days: 30;
    available_amount_by_currency: Array<{
      currency: string;
      active_count: number;
      available_amount: string;
    }>;
    next_expiration_at?: string | null;
    bounded_grants: Array<{
      credit_grant_id: string;
      currency: string;
      remaining_amount: string;
      status: string;
      valid_until?: string | null;
    }>;
    source_refs_presence: {
      voucher_source_ref_present: boolean;
      payment_source_ref_present: boolean;
      subscription_source_ref_present: boolean;
      import_source_ref_present: boolean;
      admin_adjustment_source_ref_present: boolean;
      raw_source_ref_returned: false;
    };
    bounded_ids_only: true;
    raw_voucher_code_returned: false;
    raw_voucher_code_hash_returned: false;
    raw_ledger_metadata_returned: false;
    authorization_returned: false;
    api_key_secret_returned: false;
    provider_key_returned: false;
    raw_payload_returned: false;
    safe_next_action: string;
    read_only: true;
    secret_safe: true;
  };
  funding_source_readback: FundingSourceReadback;
  ledger_balance_window: {
    currency: string;
    confirmed_credit_total: string;
    confirmed_debit_total: string;
    confirmed_net_amount: string;
    pending_amount: string;
    reversed_amount: string;
    ledger_entry_count: number;
    window_start: string;
    window_end: string;
  };
  pending_reserves: {
    reserve_count: number;
    reserve_amount_total: string;
  };
  last_ledger_entry_ids: string[];
  bounded_links: {
    request_ids?: string[];
    trace_ids?: string[];
    ledger_entry_ids?: string[];
    audit_log_ids?: string[];
  };
  read_only: boolean;
  secret_safe: JsonValue;
};
```

`credit_grant_expiration_readback` is compact and read-only. UI may use it for expiry badges, top-up prompts, and billing page summaries. It returns only bounded ids/counts/fixed-decimal amounts/status/timestamps and source presence booleans. It must not render or expect raw voucher codes/hashes, raw ledger metadata, raw provider/payment payloads, Authorization/Cookie, API key secrets, provider keys, or raw source refs.

`funding_source_readback` is compact and read-only. UI may use it for admin wallet details, admin user billing summary, and remaining-balance readback. It summarizes voucher, manual adjustment, payment order, subscription credit, and negative proration credit sources with count, fixed-decimal amount by currency, source status, ref presence, bounded source ids/statuses, and `safe_next_action`. It must not render or expect raw voucher codes/hashes, raw ledger metadata, raw payment/provider payloads, Authorization/Cookie, API key secrets, provider keys, or raw source refs.

```ts
type FundingSourceReadback = {
  schema: "admin_wallet_funding_source_readback.v1" | string;
  source: "credit_grants_ledger_payment_orders_subscription_events" | string;
  wallet_id?: string | null;
  project_ids: string[];
  total_source_count: number;
  source_status: "ready" | "not_observed" | "refs_absent" | string;
  categories: Array<{
    category:
      | "voucher"
      | "manual_adjustment"
      | "payment_order"
      | "subscription_credit"
      | "negative_proration_credit"
      | string;
    count: number;
    amount_by_currency: Array<{ currency: string; amount: string }>;
    ref_present: boolean;
    source_status: "ready" | "not_observed" | "refs_absent" | string;
    statuses: string[];
    bounded_refs: Array<{
      source_table: "credit_grants" | "ledger_entries" | "payment_orders" | "subscription_events_or_schedules" | string;
      source_id: string;
      wallet_id?: string | null;
      amount: string;
      currency: string;
      status: string;
    }>;
    safe_next_action: string;
  }>;
  bounded_ids_only: true;
  raw_voucher_code_returned: false;
  raw_voucher_code_hash_returned: false;
  raw_ledger_metadata_returned: false;
  authorization_returned: false;
  api_key_secret_returned: false;
  provider_key_returned: false;
  raw_payload_returned: false;
  safe_next_action: string;
  read_only: true;
  secret_safe: true;
};
```

### Ledger

- `GET /admin/ledger/entries`
- `POST /admin/ledger/adjustments/dry-run`

Ledger entries support filters: `project_id`, `wallet_id`, `request_id`, `limit`.

Adjustment dry-run request:

```ts
type LedgerAdjustmentDryRunRequest = {
  operation: "adjust" | "refund";
  amount: string;
  currency: string;
  mode?: "dry_run" | "execute_contract" | "execute";
  project_id?: string;
  wallet_id?: string;
  request_id?: string;
  related_ledger_entry_id?: string;
  reason?: string;
};
```

For UI rebuild, treat `dry_run` as the stable explain-plan surface. `execute_contract` may return a writer-required contract when the backend refuses future writer execution.

### Vouchers

- `POST /admin/voucher-issuances`
- `POST /admin/voucher-issuance-batches`
- `GET /admin/voucher-issuance-batches/{batch_hash}`
- `POST /admin/voucher-issuance-batches/{batch_hash}/revoke`
- `GET /admin/voucher-issuances`
- `POST /admin/voucher-issuances/{voucher_id}/revoke`
- `POST /user/vouchers/redeem`

Admin issue request:

```ts
type AdminVoucherIssueRequest = {
  tenant_id: string;
  wallet_id: string;
  currency: string;
  amount: string;
  raw_voucher_code: string;
  idempotency_key: string;
  project_id?: string | null;
  campaign_id?: string | null;
  expires_at?: string | null;
  max_redemptions?: number | null;
};
```

Batch issue request:

```ts
type AdminVoucherIssueBatchRequest = {
  batch_idempotency_key: string;
  defaults: Omit<AdminVoucherIssueRequest, "idempotency_key" | "raw_voucher_code">;
  items: Array<{
    raw_voucher_code: string;
    idempotency_key: string;
  }>;
};
```

Batch issue response:

```ts
type AdminVoucherIssueBatchResponse = {
  schema?: string;
  status: string;
  total: number;
  issued: number;
  replayed: number;
  refused: number;
  batch_idempotency_key_hash?: string | null;
  batch_hash?: string | null;
  batch_idempotency_key_hash_present?: boolean;
  database_writes?: boolean;
  runtime_implemented?: boolean;
  secret_safe?: boolean;
  raw_voucher_code_echoed?: boolean;
  raw_idempotency_key_echoed?: boolean;
  items: Array<{
    index: number;
    status: string;
    voucher_id?: string | null;
    wallet_id?: string | null;
    amount?: string | null;
    currency?: string | null;
    code_redacted?: string | null;
    refusal_code?: string | null;
    message?: string | null;
    secret_safe?: boolean;
    raw_voucher_code_echoed?: boolean;
    raw_idempotency_key_echoed?: boolean;
  }>;
};
```

Batch query/revoke v1:

```ts
type AdminVoucherBatchQueryResponse = {
  schema?: "recharge_voucher_batch_query.v1" | string;
  status: "ok" | string;
  operation?: "voucher_batch_query" | string;
  batch_idempotency_key_hash: string;
  batch_hash?: string | null;
  batch_idempotency_key_hash_present?: boolean;
  total: number;
  issued: number;
  redeemed: number;
  revoked: number;
  expired?: number;
  revocable_count: number;
  audit_ids?: string[];
  revoke_audit_ids?: string[];
  items: AdminVoucherIssuanceSummary[];
  code_hash_present?: false;
  code_lookup_prefix_present?: false;
  secret_safe?: boolean;
  raw_voucher_code_echoed?: false;
  raw_idempotency_key_echoed?: false;
};

type AdminVoucherBatchRevokeResponse = {
  schema?: "recharge_voucher_batch_revoke.v1" | string;
  status: "completed" | string;
  operation?: "voucher_batch_revoke" | string;
  operation_id: string;
  batch_idempotency_key_hash: string;
  batch_hash?: string | null;
  batch_idempotency_key_hash_present?: boolean;
  total: number;
  total_matched_before: number;
  issued: number;
  redeemed: number;
  revoked: number;
  expired?: number;
  revocable_count: number;
  revocable_count_before: number;
  revoked_count: number;
  revoked_voucher_ids?: string[];
  audit_ids?: string[];
  code_hash_present?: false;
  code_lookup_prefix_present?: false;
  secret_safe?: boolean;
  raw_voucher_code_echoed?: false;
  raw_idempotency_key_echoed?: false;
};
```

Admin list row:

```ts
type AdminVoucherIssuanceSummary = {
  voucher_id: string;
  tenant_id: string;
  wallet_id?: string | null;
  project_id?: string | null;
  campaign_id?: string | null;
  amount: string;
  currency: string;
  code_redacted: string;
  batch_idempotency_key_hash?: string | null;
  code_hash_present?: boolean;
  code_lookup_prefix_present?: boolean;
  status: string;
  effective_status?: string | null;
  max_redemptions: number;
  redemption_count: number;
  expires_at?: string | null;
  audit_id?: string | null;
  revoke_audit_id?: string | null;
  secret_safe?: boolean;
  raw_voucher_code_echoed?: boolean;
  raw_idempotency_key_echoed?: boolean;
};
```

Admin list filters:

```ts
type AdminVoucherIssuanceListFilters = {
  wallet_id?: string;
  project_id?: string;
  campaign_id?: string;
  status?: string;
  batch_idempotency_key_hash?: string;
  limit?: number;
};
```

User redeem request:

```ts
type UserVoucherRedeemRequest = {
  voucher_code: string;
  currency?: string;
  idempotency_key?: string;
};
```

User redeem response:

```ts
type UserVoucherRedeemReceipt = {
  schema: "user_voucher_redeem_receipt.v1" | string;
  status: "redeemed" | "replayed" | string;
  amount?: string | null;
  currency?: string | null;
  credit_grant_id?: string | null;
  ledger_entry_id?: string | null;
  redemption_id?: string | null;
  voucher_id?: string | null;
  tenant_id?: string | null;
  project_id?: string | null;
  wallet_id?: string | null;
  expires_at?: string | null;
  valid_until?: string | null;
  code_locator?: string | null; // redacted locator or "omitted"; never raw code
  code_redacted?: string | null;
  voucher_code?: "omitted" | string;
  idempotency_key?: "omitted" | string;
  raw_voucher_code_echoed?: false;
  raw_idempotency_key_echoed?: false;
  secret_safe?: true;
  refs?: {
    tenant_id?: string | null;
    project_id?: string | null;
    wallet_id?: string | null;
    voucher_id?: string | null;
    voucher_redemption_id?: string | null;
    credit_grant_id?: string | null;
    ledger_entry_id?: string | null;
  };
};

type UserVoucherRedeemResponse = {
  status: string;
  operation: "voucher_redeem" | string;
  refusal_code?: string | null;
  receipt?: UserVoucherRedeemReceipt;

  // Backward-compatible top-level fields may also be present.
  amount?: string | null;
  currency?: string | null;
  credit_grant_id?: string | null;
  ledger_entry_id?: string | null;
  redemption_id?: string | null;
  voucher_id?: string | null;
  tenant_id?: string | null;
  project_id?: string | null;
  wallet_id?: string | null;
  expires_at?: string | null;
  valid_until?: string | null;
};
```

Voucher UI rules:

- Admin create form may accept a raw voucher code, but responses must display `code_redacted`, ids, status, and amount only.
- Bulk create may keep just-submitted raw codes in local component memory for one-time CSV/JSON download. Do not reload raw codes from the API; server returns only redacted codes and `batch_idempotency_key_hash`.
- User redeem UI should clear the input after submit, including refusal/network-error paths. Receipt displays `amount`, `currency`, `credit_grant_id`, `ledger_entry_id`, `expires_at`/`valid_until`, `wallet_id`, `project_id`, `tenant_id`, `voucher_id`, `redemption_id`, and `code_locator` only.
- Batch query/revoke v1 is stable for `batch_idempotency_key_hash`: query with `GET /admin/voucher-issuance-batches/{batch_hash}`, revoke remaining issued vouchers with `POST /admin/voucher-issuance-batches/{batch_hash}/revoke`, and show `operation_id`, counts, `revoked_voucher_ids`, and `audit_ids`.
- If `raw_voucher_code_echoed` or `raw_idempotency_key_echoed` is ever true, treat it as a security bug and do not render the raw value.

### Subscription Plan Skeleton

- `GET /admin/subscription-plans`
- `POST /admin/subscription-plans`
- `GET /admin/subscription-plans/{id}`
- `PATCH /admin/subscription-plans/{id}`
- `POST /admin/subscriptions/scheduler-plan`
- `POST /admin/subscriptions/run-due-scheduler-events`

Core DTO:

```ts
type SubscriptionPlan = {
  id: string;
  tenant_id: string;
  plan_code: string;
  display_name: string;
  status: "draft" | "active" | "archived" | string;
  billing_interval: "month" | "year" | "one_time" | string;
  currency: string;
  unit_price: string;
  included_credit_amount: string;
  trial_days: number;
  request_summary: JsonValue;
  entitlement_summary: JsonValue;
  expiration_policy: JsonValue;
  metadata: JsonValue;
  payment_status: "not_connected" | string;
  scheduler_status: "pending_scheduler" | string;
  raw_payment_payload_returned: false;
  secret_safe: true;
  created_at: string;
  updated_at: string;
};
```

This is a catalog/skeleton surface. Creating or editing a plan does not charge users, renew subscriptions, or grant credits until scheduler/payment integration is implemented. UI should display `payment_status=not_connected` and `scheduler_status=pending_scheduler`.

Scheduler plan/readback DTO:

```ts
type SubscriptionSchedulerPlanRequest = {
  mode?: "dry_run" | "apply";
  action?: "all" | "renewal" | "grace" | "dunning" | "proration";
  subscription_id?: string | null;
  target_plan_id?: string | null; // required for action=proration
  limit?: number;
  reason?: string | null; // required for mode=apply
};

type SubscriptionSchedulerPlan = {
  schema: "admin_subscription_scheduler_plan.v1" | string;
  mode: "dry_run" | "apply" | string;
  action: "all" | "renewal" | "grace" | "dunning" | "proration" | string;
  subscription_id?: string | null;
  target_plan_id?: string | null;
  candidate_count: number;
  candidates: Array<{
    subscription_id: string;
    project_id?: string | null;
    wallet_id: string;
    plan_id: string;
    target_plan_id?: string | null;
    plan_code?: string | null;
    status: string;
    renewal: JsonValue;   // status, effective_at, next_action
    grace: JsonValue;     // status, ends_at, next_action
    dunning: JsonValue;   // status, next_attempt_at, max_attempts, next_action
    proration: JsonValue; // status, target_plan_id, estimated_amount, next_action
    planned_event_types: string[];
    secret_safe: true;
    raw_payment_payload_returned: false;
    raw_provider_payload_returned: false;
    raw_idempotency_key_echoed: false;
  }>;
  apply_result: {
    applied: boolean;
    scheduled_event_count: number;
    events: Array<{
      id: string;
      subscription_id: string;
      event_type: string;
      event_status: string;
      effective_at: string;
      idempotency_key_fingerprint: string;
      raw_idempotency_key_echoed: false;
      secret_safe: true;
    }>;
    writes_limited_to: ["subscription_events_or_schedules"] | string[];
    subscription_rows_updated: false;
    invoice_order_ledger_credit_writes: false;
  };
  status: "planned" | "scheduled" | string;
  next_action: string;
  secret_safe: true;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  authorization_returned: false;
  raw_idempotency_key_echoed: false;
};
```

UI rules:

- Use `mode=dry_run` for readback and previews. Only show `mode=apply` behind an admin confirmation with `reason`.
- Apply mode only writes `subscription_events_or_schedules` scheduled rows. Do not label it as payment capture, renewal settlement, invoice creation, ledger settlement, or credit grant issuance.
- Never render raw payment provider payload, Authorization, provider secrets, raw idempotency material, invoice metadata, or full token-like values. The event idempotency field is a short fingerprint only.

Scheduler daemon runner boundary DTO:

```ts
type SubscriptionSchedulerRunDueRequest = {
  mode?: "dry_run" | "apply" | "refuse" | "replay";
  tenant_id?: string | null; // optional current-tenant assertion
  limit?: number;
  event_status?: "all" | "scheduled" | "replayed";
  event_type?: "all" | "renew" | "payment_failed" | "dunning" | "expire" | "prorate";
  worker_id?: string | null;
  reason?: string | null; // required for apply/refuse/replay
};

type SubscriptionSchedulerRunDueResult = {
  schema: "admin_subscription_scheduler_run_due_events.v1" | string;
  mode: "dry_run" | "apply" | "refuse" | "replay" | string;
  status: "idle" | "dry_run_planned" | "bounded_status_recorded" | string;
  processed_count: number;
  skipped_count: number;
  blocked_count: number;
  processed: Array<{
    event: JsonValue & {
      payment_capture_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
      payment_provider_executor_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
    };
    status: string;
    status_transition: JsonValue & {
      payment_capture_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
      payment_capture_executed?: false;
    };
    local_execution_readback?: JsonValue;
    payment_capture_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
    payment_provider_executor_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
  } | JsonValue>; // per-event execute-plan preview/local execution/provider handoff readback
  skipped: JsonValue[];   // concurrent status-change/idempotent no-op cases
  blocked: JsonValue[];   // unsafe/precondition failures, normally empty for bounded local execution
  supervisor: SubscriptionSchedulerSupervisorState; // durable heartbeat/counter readback for external worker loops
  next_run: JsonValue;    // at, source, runtime_daemon_running=false
  policy: JsonValue;      // retry/dunning/proration and write boundary
  omitted_fields: string[];
  secret_safe: true;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  authorization_returned: false;
  raw_invoice_metadata_returned: false;
  raw_idempotency_key_echoed: false;
};
```

UI rules:

- Default to `mode=dry_run`. For `mode=apply|refuse|replay`, require `reason`, show `limit`, and display `processed[].status_transition.writes_limited_to`.
- Show `processed`, `skipped`, and `blocked` separately. Apply mode can now record bounded local subscription mutations and renewal credit/ledger readback, but `payment_capture_executed=false` means external payment still requires provider callback/capture evidence.
- Do not present this as an in-process daemon. `runtime_daemon_running=false`; an external worker can poll this endpoint with a bounded limit and persist heartbeat/counters through `supervisor`.

Scheduler event execute/readback DTO:

```ts
type SubscriptionSchedulerEventExecuteRequest = {
  mode?: "dry_run" | "apply" | "refuse" | "replay";
  reason?: string | null; // required for apply/refuse/replay
};

type SubscriptionSchedulerEventExecutePlan = {
  schema: "admin_subscription_scheduler_event_execute_plan.v1" | string;
  mode: "dry_run" | "apply" | "refuse" | "replay" | string;
  event: {
    id: string;
    subscription_id: string;
    event_type: "renew" | "payment_failed" | "dunning" | "expire" | "prorate" | string;
    event_status: "scheduled" | "applied" | "replayed" | "refused" | "matched" | string;
    effective_at: string;
    execution_plan: JsonValue; // handoff plan for renewal/dunning/proration/expiration
    local_execution_readback?: JsonValue; // present after apply/refuse/replay
    payment_capture_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
    payment_provider_executor_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
    refund_or_credit_note_handoff?: SubscriptionSchedulerRefundOrCreditNoteHandoff;
    idempotency_key_fingerprint: string;
    secret_safe: true;
    raw_payment_payload_returned: false;
    raw_provider_payload_returned: false;
    authorization_returned: false;
    raw_invoice_metadata_returned: false;
    raw_idempotency_key_echoed: false;
  };
  status_transition: {
    mutated: boolean;
    from: string;
    to: string;
    writes_limited_to: string[];
    runtime_implemented?: boolean;
    subscription_rows_updated: number | JsonValue;
    ledger_or_credit_readback?: JsonValue;
    invoice_order_ledger_credit_writes?: false | string;
    invoice_order_readback?: JsonValue;
    dunning_retry_readback?: JsonValue;
    proration_delta_readback?: JsonValue;
    negative_proration_readback?: JsonValue;
    payment_capture_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
    refund_or_credit_note_handoff?: SubscriptionSchedulerRefundOrCreditNoteHandoff;
    payment_capture_executed: false;
  };
  executor_steps?: JsonValue;
  runtime_implemented?: boolean;
  subscription_rows_updated?: number | JsonValue;
  ledger_or_credit_readback?: JsonValue;
  invoice_order_readback?: JsonValue; // local pending order/invoice/intent refs when apply links them
  dunning_retry_readback?: JsonValue; // payment_failed/dunning retry state, next retry event, or final action
  proration_delta_readback?: JsonValue; // prorate delta amount, period ratio, and blocked reason for non-chargeable deltas
  negative_proration_readback?: JsonValue; // downgrade credit adjustment or pending refund intent; never external refund success
  payment_capture_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
  payment_provider_executor_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
  refund_or_credit_note_handoff?: SubscriptionSchedulerRefundOrCreditNoteHandoff;
  execution_boundary: {
    worker_handoff_ready: boolean;
    worker_can_pick_up_statuses: string[];
    current_runtime: "bounded_local_subscription_executor" | string;
    payment_provider_connected: false;
    invoice_creation_executed: boolean;
    order_creation_executed: boolean;
    ledger_settlement_executed: false;
    credit_grant_executed: false;
  };
  secret_safe: true;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  authorization_returned: false;
  raw_invoice_metadata_returned: false;
  raw_idempotency_key_echoed: false;
};

type SubscriptionSchedulerProviderCaptureReconciliationPlan = {
  schema: "admin_subscription_scheduler_provider_capture_reconciliation_plan.v1" | string;
  status: "blocked" | "provider_source_ready_waiting_fetch" | string;
  provider: string;
  action: "capture" | string;
  operator_api_call: JsonValue; // executor endpoint, request field presence, short idempotency fingerprint only
  provider_object_fetch_summary: JsonValue; // required source-of-truth summary shape, no raw provider payload
  executor_source_of_truth: JsonValue; // executor/fetch/client schema names; scheduler is not source of truth
  success_local_ref_updates: JsonValue; // readback/update targets after executor acceptance
  preconditions: JsonValue; // provider ref and local ref presence
  blocked_reasons?: string[];
  writes: JsonValue; // scheduler handoff is readback-only; no captures/ledger/credit writes
  network_call_enabled: false;
  network_call_performed: false;
  secret_safe: true;
  raw_provider_ref_echoed: false;
  raw_provider_payload_echoed: false;
  authorization_returned: false;
  provider_secret_returned: false;
  raw_idempotency_key_echoed: false;
};

type SubscriptionSchedulerPaymentCaptureHandoff = {
  schema: "admin_subscription_scheduler_payment_capture_handoff.v1" | string;
  status: "blocked" | "not_applicable" | "provider_source_ready_waiting_fetch" | string;
  event_id: string;
  subscription_id: string;
  event_type: string;
  event_status: string;
  due_now: boolean;
  next_provider_executor_action: "capture" | string;
  ready_for_provider_executor: false;
  blocked_reasons: string[];
  operator_api_call: {
    method: "POST" | string;
    path: "/admin/billing/payment-provider/executor" | string;
    action: "capture" | string;
    idempotency_fingerprint: string; // short fingerprint only
    raw_idempotency_key_required_from_ui: false;
  };
  local_refs: JsonValue;       // local order/invoice/payment_intent/capture presence, ids only
  provider_refs: JsonValue;    // presence/source markers only; no raw provider object
  provider_source_ref_plan: JsonValue; // derives provider object ref from payment_intents hash/redacted; metadata markers stay candidates
  credential_source: JsonValue; // readiness markers only; no secrets
  source_of_truth: {
    provider_object_fetch_required_before_capture: true;
    provider_object_fetch_summary_required: true;
    provider_object_fetch_summary_schema: "payment_provider_stripe_like_source_of_truth_summary.v1" | string;
    network_call_enabled: false;
    network_call_performed: false;
    production_payment_evidence: false;
  };
  provider_capture_reconciliation_plan: SubscriptionSchedulerProviderCaptureReconciliationPlan;
  billing_ledger_executor_contract: JsonValue;
  stripe_like_client_request_plan: JsonValue;
  idempotency: {
    source: string;
    fingerprint: string;
    raw_idempotency_key_echoed: false;
    key_hash_returned: false;
  };
  writes: JsonValue; // read_back_only/not_written map
  payment_capture_executed: false;
  network_call_enabled: false;
  network_call_performed: false;
  secret_safe: true;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  authorization_returned: false;
  provider_secret_returned: false;
  raw_idempotency_key_echoed: false;
};

type SubscriptionSchedulerRefundOrCreditNoteHandoff = {
  schema: "admin_subscription_scheduler_refund_or_credit_note_handoff.v1" | string;
  status: "blocked" | "not_applicable" | string;
  event_id: string;
  subscription_id: string;
  event_type: string;
  event_status: string;
  due_now: boolean;
  scenario: "negative_proration_refund_or_credit_note" | "not_applicable" | string;
  next_provider_executor_action: "refund_or_credit_note" | string;
  ready_for_provider_executor: false;
  blocked_reasons: string[];
  next_action: string;
  operator_api_call: {
    method: "POST" | string;
    path: "/admin/billing/payment-provider/executor" | string;
    action: "refund" | string;
    idempotency_fingerprint: string; // short fingerprint only
    raw_idempotency_key_required_from_ui: false;
  };
  local_refs: JsonValue; // credit_grant_id, ledger_entry_id, payment_refund_id, order/invoice/payment_intent ids, presence flags
  payment_refund: JsonValue; // local payment_refunds readback only; provider_refund_ref_present is a presence flag
  provider_refs: JsonValue; // provider payment/refund ref presence and fingerprints only, no raw refs
  provider_object_fetch_requirement: JsonValue; // provider payment/refund object summaries required before success
  source_of_truth_policy: JsonValue; // local credit-note is not provider refund source of truth
  negative_proration_readback?: JsonValue;
  billing_ledger_executor_contract: JsonValue;
  stripe_like_client_request_plan: JsonValue;
  idempotency: {
    source: string;
    fingerprint: string;
    raw_idempotency_key_echoed: false;
    key_hash_returned: false;
  };
  writes: JsonValue; // payment_refunds/credit_grants/ledger_entries read_back_only or not_written
  refund_executed: false;
  credit_note_recorded_locally: boolean;
  network_call_enabled: false;
  network_call_performed: false;
  secret_safe: true;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  authorization_returned: false;
  provider_secret_returned: false;
  raw_idempotency_key_echoed: false;
};
```

UI rules:

- Call `POST /admin/subscriptions/scheduler-events/{id}/execute-plan` with `mode=dry_run` from a scheduled event row to show the worker handoff plan.
- `mode=apply|refuse|replay` must require an admin confirmation and reason. Apply updates the event and, where safe, local subscription rows plus renewal `credit_grants`/`ledger_entries` readback.
- Show `invoice_order_readback` when present. Renewal/proration can now create or replay local `payment_orders`, `payment_intents(provider_handoff)`, and `invoices(issued)` from the scheduler event idempotency hash.
- Show `dunning_retry_readback` when present. `payment_failed` starts local retry state and schedules the next `dunning` event; each `dunning` attempt increments `attempt_count`, writes retry state to event metadata, and at `max_attempts` returns `final_dunning_action=expire_subscription` without marking any external payment as captured.
- Show `proration_delta_readback` when present. Positive proration uses `(target_unit_price - current_unit_price) * remaining_period_seconds / total_period_seconds`; same-currency, valid period, and positive delta are required before the scheduler creates a pending order/invoice.
- Show `negative_proration_readback` when present. Downgrades record a local wallet credit adjustment in `credit_grants`/`ledger_entries` and expose a pending refund intent readback; the UI must not display it as provider refund success.
- Show `refund_or_credit_note_handoff` when present for negative proration/refund/credit-note scenarios. It exposes local `credit_grant_id`/`ledger_entry_id`, optional local `payment_refund_id`, provider refund/payment source ref presence, a safe idempotency fingerprint, blocked reasons, next action, and `source_of_truth_policy`. It never connects to a provider, never writes `payment_refunds`/`payment_reconciliations`, never marks a refund successful, and never returns raw provider refs, raw idempotency, secrets, Authorization, or provider payloads. `[!]` Real provider refund/credit-note evidence still requires the payment provider executor/fetch or verified webhook readback.
- Show `payment_capture_handoff` / `payment_provider_executor_handoff` only as provider-executor handoff readiness/readback. It may provide `/admin/billing/payment-provider/executor`, `action=capture`, local refs, credential readiness, blocked reasons, `provider_source_ref_plan`, `stripe_like_client_request_plan`, and a short idempotency fingerprint, but `ready_for_provider_executor=false`, `network_call_performed=false`, and `payment_capture_executed=false` mean no provider capture happened.
- `provider_source_ref_plan.provider_object_ref_present=true` means the scheduler found `payment_intents.provider_reference_hash/redacted`. Metadata markers are surfaced as candidates only until normalized to a safe hash/redacted ref. The UI must still not render a raw provider payment_intent ref. If no safe hash/redacted source is present, `blocked_reasons` continues to include `provider_payment_intent_ref_missing`.
- `provider_capture_reconciliation_plan.status=provider_source_ready_waiting_fetch` means the handoff has safe local/provider-ref markers and is waiting for a real provider object fetch summary before any capture can be accepted. Its `operator_api_call` is an operator/executor plan only; the scheduler did not call provider networks and did not write `payment_captures`, `ledger_entries`, or `credit_grants`.
- Do not show this as external payment success. `payment_capture_executed=false` and `payment_provider_capture_required` mean provider callback/capture evidence is still required before paid/captured UI states.
- Never render raw provider object refs, raw idempotency keys or hashes, Authorization, provider secrets, payment payloads, request bodies, credential material, or production-payment-evidence claims from the handoff. `operator_api_call.idempotency_fingerprint` is display-safe; the UI must not ask an operator to supply a raw idempotency key for this handoff.

Scheduler worker handoff/readback DTO:

```ts
type SubscriptionSchedulerWorkerHandoff = {
  schema: "admin_subscription_scheduler_worker_handoff.v1" | string;
  status: "idle" | "due_events_available" | string;
  due_event_count: number;
  due_events: Array<{
    id: string;
    subscription_id: string;
    event_type: "renew" | "payment_failed" | "dunning" | "expire" | "prorate" | string;
    event_status: "scheduled" | "replayed" | string;
    effective_at: string;
    due_now: boolean;
    worker_handoff: JsonValue; // claimable, lease readback, execute_plan_available
    idempotency_key_fingerprint: string;
    secret_safe: true;
    raw_payment_payload_returned: false;
    raw_provider_payload_returned: false;
    authorization_returned: false;
    raw_invoice_metadata_returned: false;
    raw_idempotency_key_echoed: false;
  }>;
  next_run: JsonValue;         // at, source, runtime_daemon_running=false
  supervisor: SubscriptionSchedulerSupervisorState; // recent workers, or the requested worker_id state
  worker_handoff: JsonValue;   // lease/execute endpoints and safe write boundary
  retry_policy: JsonValue;     // readback-only defaults
  dunning_policy: JsonValue;   // grace/dunning/expire defaults
  proration_policy: JsonValue; // boundary-only policy
  secret_safe: true;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  authorization_returned: false;
  raw_invoice_metadata_returned: false;
  raw_idempotency_key_echoed: false;
};

type SubscriptionSchedulerSupervisorState = {
  schema: "admin_subscription_scheduler_supervisor_state.v1" | string;
  state_available: boolean;
  status: "not_initialized" | "idle" | "running" | "blocked" | "error" | "recent_workers_available" | string;
  worker_id?: string;
  lease_heartbeat_at?: string | null;
  last_run_at?: string | null;
  next_run_at?: string | null;
  processed_count?: number;
  skipped_count?: number;
  blocked_count?: number;
  last_mode?: string | null;
  last_event_status_filter?: string[];
  last_event_type_filter?: string[];
  last_run_summary?: JsonValue;
  latest_workers?: JsonValue[];
  durable_state_table: "subscription_scheduler_worker_supervisors" | string;
  external_worker_loop_supported: true;
  background_process_started: false;
  secret_safe?: true;
  raw_payment_payload_returned?: false;
  raw_provider_payload_returned?: false;
  authorization_returned?: false;
  raw_idempotency_key_echoed?: false;
};

type SubscriptionSchedulerEventLeaseRequest = {
  worker_id?: string | null;
  lease_seconds?: number; // 30..3600
  reason?: string | null;
};
```

UI rules:

- Call `GET /admin/subscriptions/scheduler-worker?event_status=scheduled&event_type=all&worker_id=...` to show due events, next run, retry/dunning/proration policies, and durable supervisor state.
- Call `POST /admin/subscriptions/run-due-scheduler-events` from an external worker loop to update `subscription_scheduler_worker_supervisors.lease_heartbeat_at`, `last_run_at`, `next_run_at`, `processed_count`, and `blocked_count`.
- `POST /admin/subscriptions/scheduler-events/{id}/lease` records only safe `metadata.worker_lease`; it does not change `event_status` and does not run a scheduler daemon.
- Lease and worker handoff surfaces must remain labeled as boundary/readback. They never imply external payment capture or provider callback execution.

Worker/jobs dashboard compact readback:

`GET /admin/workers/jobs-dashboard` returns a secret-safe, read-only aggregate for ops/dashboard screens. It summarizes subscription scheduler supervisor state, pending scheduled events, importer apply runner handoff, CRM retry handoff, provider health probe/recovery handoff, and payment provider executor handoff. It never starts a daemon, executes network calls, writes business tables, or returns Authorization/session tokens/provider keys/DB URLs/raw payloads/raw SQL/raw webhook bodies/raw metadata.

```ts
type AdminWorkersJobsDashboardSection = {
  schema: "admin_workers_jobs_dashboard_section.v1" | string;
  source: string;
  status: "idle" | "handoff_ready" | "blocked" | "not_initialized" | "config_needed" | string;
  count: number;
  ref?: JsonValue;
  refs?: JsonValue[];
  next_action: string;
  read_only: true;
  network_requests_executed: false;
  business_table_writes_performed: false;
  secret_safe: true;
};

type AdminWorkersJobsDashboard = {
  schema: "admin_workers_jobs_dashboard.v1" | string;
  status: "idle" | "handoff_ready" | "attention_needed" | string;
  sections: {
    subscription_scheduler_supervisor: AdminWorkersJobsDashboardSection;
    pending_scheduled_events: AdminWorkersJobsDashboardSection;
    import_apply_runner_handoff: AdminWorkersJobsDashboardSection;
    crm_retry_handoff: AdminWorkersJobsDashboardSection;
    provider_health_probe_recovery_handoff: AdminWorkersJobsDashboardSection;
    payment_provider_executor_handoff: AdminWorkersJobsDashboardSection;
  };
  readback_path: "GET /admin/workers/jobs-dashboard" | string;
  read_only: true;
  runtime_daemon_started: false;
  network_requests_executed: false;
  business_table_writes_performed: false;
  omitted_fields: string[];
  secret_safe: true;
  authorization_returned: false;
  session_token_returned: false;
  provider_key_returned: false;
  db_url_returned: false;
  raw_payload_returned: false;
  raw_sql_returned: false;
  raw_webhook_body_returned: false;
  raw_metadata_returned: false;
  next_action: string;
};
```

UI rules:

- Treat every section as a compact pointer, not executable state. Use `ref.readback_path` or the section-specific dashboard path for details.
- Do not render fields named Authorization, session token, provider key, DB URL, raw payload, raw SQL, raw webhook/body, or raw metadata. The contract exposes only presence/status/count/ref/next_action.
- `runtime_daemon_started=false`, `network_requests_executed=false`, and `business_table_writes_performed=false` are invariant for this endpoint.

### Local Payment Demo

- `POST /admin/billing/payment-demo/orders`
- `POST /admin/billing/payment-demo/orders/{order_id}/mark-paid`

Create request:

```ts
type LocalPaymentDemoCreateOrderRequest = {
  tenant_id: string;
  wallet_id: string;
  project_id?: string;
  amount: string;
  currency: string;
  idempotency_key: string;
  reason: string;
};
```

Mark paid request:

```ts
type LocalPaymentDemoMarkPaidRequest = {
  tenant_id: string;
  payment_idempotency_key: string;
  reason: string;
};
```

Response highlights:

```ts
type LocalPaymentDemoResponse = {
  schema: "billing_local_payment_demo.v1" | string;
  mode: "local_runtime_demo" | string;
  local_only: true;
  merchant_connected: false;
  production_payment_evidence: false;
  secret_safe: true;
  raw_idempotency_key_echoed: false;
  raw_metadata_echoed: false;
  raw_provider_payload_echoed: false;
  operation: string;
  outcome: string;
  order: {
    id: string;
    tenant_id: string;
    wallet_id: string;
    project_id?: string | null;
    amount: string;
    currency: string;
    status: string;
    source: string;
    created_at: string;
    updated_at: string;
  };
  refs: {
    order_id: string;
    payment_intent_id?: string | null;
    payment_capture_id?: string | null;
    credit_grant_id?: string | null;
    ledger_entry_id?: string | null;
    audit_id?: string | null;
    invoice_id?: string | null;
    receipt_id?: string | null;
    reconciliation_id?: string | null;
    capture_event_id?: string | null;
    reconciliation_event_id?: string | null;
  };
  accounting: JsonValue;
  payment_refs: {
    order_id: string;
    payment_intent_id?: string | null;
    payment_capture_id?: string | null;
    provider: "local_demo" | string;
    provider_reference?: string | null; // redacted local reference only
    provider_reference_redacted: boolean;
    provider_event_refs: Array<{
      event_id: string;
      event_type: "capture_confirm" | "reconciliation" | string;
      outcome?: string;
      created_at?: string;
      source: "local_payment_demo_event_log" | string;
    }>;
  };
  ledger_refs: {
    credit_grant_id?: string | null;
    ledger_entry_id?: string | null;
    ledger_status: "confirmed" | "not_written" | string;
    ledger_entry_type: "adjust" | string;
    ledger_operation: string;
  };
  invoice: {
    invoice_id?: string | null;
    status: "not_created" | "draft" | "issued" | "paid" | "voided" | "refunded" | string;
    amount: string;
    currency: string;
    invoice_number?: string | null;
    issued_at?: string | null;
    payment_capture_id?: string | null;
    audit_id?: string | null;
    legal_invoice: false;
    boundary: "runtime_invoice_record_not_legal_tax_invoice" | string;
    next_step: string;
  };
  receipt: {
    receipt_id?: string | null;
    status: "not_created" | "issued" | "voided" | "refunded" | string;
    amount: string;
    currency: string;
    receipt_number?: string | null;
    issued_at?: string | null;
    payment_capture_id?: string | null;
    audit_id?: string | null;
    legal_receipt: false;
    boundary: "runtime_receipt_record_not_legal_tax_receipt" | string;
    next_step: string;
  };
  reconciliation: {
    marker_id?: string | null;
    status: "pending_payment" | "matched" | "mismatch" | "refused" | string;
    matched: boolean;
    amount: string;
    currency: string;
    payment_capture_id?: string | null;
    invoice_id?: string | null;
    ledger_entry_id?: string | null;
    provider_event_refs: LocalPaymentDemoResponse["payment_refs"]["provider_event_refs"];
    matched_at?: string | null;
    boundary: "local_marker_readback_not_production_finance_reconciliation" | string;
    next_step: string;
  };
  invoice_receipt_reconciliation_readback: {
    schema: "invoice_receipt_reconciliation_readback.v1" | string;
    source: "local_payment_demo_runtime_readback" | string;
    status: "pending_payment" | "matched" | "incomplete_readback" | string;
    invoice_status: string;
    receipt_status: string;
    payment_refs_presence: {
      present: boolean;
      payment_intent_id_present: boolean;
      payment_capture_id_present: boolean;
      provider_reference_redacted: boolean;
      provider_event_refs_present: boolean;
    };
    ledger_refs_presence: {
      present: boolean;
      credit_grant_id_present: boolean;
      ledger_entry_id_present: boolean;
      ledger_status: string;
    };
    reconciliation_status: string;
    reconciliation_refs_presence: {
      present: boolean;
      marker_id_present: boolean;
      invoice_id_present: boolean;
      receipt_id_present: boolean;
      payment_capture_id_present: boolean;
      ledger_entry_id_present: boolean;
    };
    safe_next_action: string;
    local_only: true;
    merchant_connected: false;
    production_payment_evidence: false;
    legal_invoice: false;
    legal_receipt: false;
    raw_provider_payload_echoed: false;
    provider_secret_echoed: false;
    authorization_echoed: false;
    raw_idempotency_key_echoed: false;
    raw_invoice_metadata_echoed: false;
    secret_safe: true;
  };
  notes: string[];
};
```

Use `invoice_receipt_reconciliation_readback` as the compact UI surface: show invoice status, receipt status, payment refs presence, ledger refs presence, reconciliation status, and `safe_next_action`. Use this only for local runtime/demo payment flows. It is not a real merchant integration and should not be labeled as production payment evidence. The invoice and receipt objects are runtime accounting records with stable ids, numbers, statuses, issued_at timestamps, payment refs, ledger refs, and reconciliation refs; they are not legal tax invoices/receipts and must not be presented as production finance reconciliation. Do not render provider payloads, secrets, Authorization, raw invoice metadata, or raw idempotency material.

### Payment Provider Simulator

- `GET /admin/billing/payment-provider/config-status`
- `PATCH /admin/billing/payment-provider/merchant-credential`
- `POST /admin/billing/payment-provider/simulator/events`

`GET /admin/billing/payment-provider/config-status` is the stable, secret-safe adapter config readback for the next real-provider seam. It expresses provider selection, merchant/account presence, credential lifecycle/readiness, signature verifier status, supported events, and the next operator step. It may return a short credential fingerprint prefix for correlation only; it never returns provider secrets, full credential fingerprints, webhook signing secrets, Authorization, raw webhook body, provider payload, full tokens, or DB URLs. When tenant DB config exists, `credential_source.source="tenant_db"` is authoritative over legacy env fallback.

```ts
type PaymentProviderMerchantCredentialSource = {
  schema: "payment_provider_merchant_credential_source.v1" | string;
  source: "tenant_db" | "env_fallback" | string;
  source_priority: "tenant_db_over_env" | "tenant_db_missing_env_fallback" | string;
  tenant_id: string;
  provider: string;
  credential_id?: string;
  status: "enabled" | "disabled" | "missing" | string;
  enabled: boolean;
  merchant_account_ref_present: boolean;
  credential_secret_ref_present: boolean;
  credential_fingerprint_prefix?: string | null;
  webhook_secret_ref_present: boolean;
  runtime_secret_resolution: {
    webhook_signing_secret_env_present: boolean;
    webhook_secret_ref_resolved: boolean;
    credential_secret_value_loaded: boolean;
    secret_storage_policy: "operator_secret_ref_only" | "legacy_env_fallback" | string;
  };
  rotation: {
    version?: number | null;
    active_generation?: number | null;
    last_rotation_marker_hash_present?: boolean;
    last_rotation_marker_hash?: string | null;
    previous_credential_fingerprint_prefix?: string | null;
    current_credential_fingerprint_prefix?: string | null;
    last_rotated_at?: string | null;
    disabled_at?: string | null;
    updated_at?: string | null;
  };
  credential_generation?: {
    active_generation?: number | null;
    status: "active" | "disabled" | "legacy_env_active" | "unknown" | string;
    enabled: boolean;
    runtime_gate: "eligible" | "disabled" | "legacy_env_fallback" | "unknown" | string;
    fingerprint_prefix?: string | null;
    previous_fingerprint_prefix?: string | null;
  };
  secret_value_stored: false;
  secret_value_returned: false;
  credential_value_echoed: false;
  provider_secret_echoed: false;
};

type PaymentProviderAdapterConfigStatus = {
  schema: "payment_provider_adapter_config_status.v1" | string;
  adapter: "stripe_like_sandbox" | string;
  provider: string;
  status: "disabled" | "config-needed" | "ready-for-sandbox" | string;
  adapter_enabled: boolean;
  merchant_account_present: boolean;
  credential_present: boolean;
  credential_status: "enabled" | "disabled" | string;
  credential_fingerprint_present: boolean;
  credential_fingerprint_prefix?: string | null;
  credential_generation?: PaymentProviderMerchantCredentialSource["credential_generation"];
  credential_source?: PaymentProviderMerchantCredentialSource;
  credential_lifecycle: {
    status: "enabled" | "disabled" | string;
    enabled: boolean;
    credential_present: boolean;
    fingerprint_present: boolean;
    fingerprint_prefix?: string | null;
    disabled_reason?: "provider_disabled" | "credential_missing" | "merchant_account_missing" | "webhook_secret_missing" | string | null;
    refusal_reason?: "provider_disabled" | "credential_missing" | "merchant_account_missing" | "webhook_secret_missing" | string | null;
    secret_returned: false;
    credential_value_echoed: false;
  };
  signature_verifier_status: "disabled" | "config-needed" | "configured-not-validated" | string;
  signature_format_support: {
    header_names: string[];
    formats: string[];
    timestamp_tolerance_seconds?: number | null;
    raw_header_echoed: false;
    raw_signature_echoed: false;
  };
  stripe_api_source_of_truth: PaymentProviderStripeApiSourceOfTruthReadback;
  supported_events: Array<"callback" | "capture" | "refund" | "chargeback" | string>;
  next_step: string;
  merchant_connected: boolean;
  production_payment_evidence: false;
  secret_safe: true;
  credential_value_echoed: false;
  provider_secret_echoed: false;
  authorization_echoed: false;
  raw_webhook_body_echoed: false;
  db_url_echoed: false;
  omitted_fields: string[];
};

type PaymentProviderStripeApiSourceOfTruthReadback = {
  schema: "payment_provider_stripe_api_source_of_truth.v1" | string;
  adapter: "stripe_api_source_of_truth" | string;
  provider: string;
  api_read_model: "stripe_api_object_fetch_plan_v1" | string;
  source_of_truth_status:
    | "unsupported_provider"
    | "credential_source_not_ready"
    | "ready_for_network_client_but_disabled"
    | string;
  source_of_truth_blocked_reason?: string | null;
  network_call_enabled: false;
  secret_ref_required: true;
  credential_source: string;
  credential_source_ready: boolean;
  fetch_adapter: StripeApiFetchAdapterReadback;
  object_ref_requirements: {
    event_id_required: boolean;
    object_id_required: boolean;
    merchant_account_ref_required: boolean;
    credential_secret_ref_required: boolean;
    webhook_secret_ref_required_for_callback: boolean;
    local_intent_or_capture_ref_required_for_accounting: boolean;
  };
  object_ref_readback: {
    event_type?: "callback" | "capture" | "refund" | "chargeback" | string | null;
    provider_event_id_present: boolean;
    provider_object_id_present: boolean;
    local_payment_intent_ref_present: boolean;
    local_payment_capture_ref_present: boolean;
    local_refund_ref_present: boolean;
    api_object_ref_mapping: string;
  };
  capture_source_selection: string;
  refund_source_selection: string;
  chargeback_source_selection: string;
  callback_source_selection: string;
  sandbox_local_only: true;
  production_payment_evidence: false;
  secret_safe: true;
  authorization_echoed: false;
  provider_secret_echoed: false;
  raw_provider_payload_echoed: false;
  raw_webhook_body_echoed: false;
  omitted_fields: string[];
};

type StripeApiObjectType = "event" | "payment_intent" | "charge" | "refund" | "dispute" | string;

type StripeApiFetchRequest = {
  object_type: StripeApiObjectType;
  object_ref_source: string;
  object_ref_present: boolean;
  credential_secret_ref_required: boolean;
  merchant_account_ref_required: boolean;
  expand: string[];
  raw_object_ref_echoed: false;
};

type StripeApiFetchResult = {
  object_type: StripeApiObjectType;
  status: "network_disabled_ready" | "blocked" | string;
  blocked_reason?: "unsupported_provider" | "credential_source_not_ready" | "stripe_object_ref_missing" | "stripe_network_client_not_enabled" | string | null;
  network_call_performed: false;
  http_client: "network_disabled" | string;
  object_ref_present: boolean;
  object_found?: boolean | null;
  secret_safe: true;
  authorization_echoed: false;
  provider_secret_echoed: false;
  raw_object_payload_echoed: false;
  raw_object_ref_echoed: false;
};

type StripeApiFetchAdapterReadback = {
  schema: "payment_provider_stripe_api_fetch_adapter.v1" | string;
  adapter: "stripe_api_fetch" | string;
  interface: "StripeApiFetchRequest -> StripeApiFetchResult" | string;
  implementation: "network_disabled" | string;
  provider_supported: boolean;
  credential_source_ready: boolean;
  object_refs_ready: boolean;
  adapter_ready_for_network_client: boolean;
  network_call_enabled: false;
  network_call_performed: false;
  requests: StripeApiFetchRequest[];
  results: StripeApiFetchResult[];
  replace_with: string;
  omitted_fields: string[];
};
```

`stripe_api_source_of_truth.fetch_adapter` is the typed seam for the future real Stripe client. Current implementation is intentionally `network_disabled`: it returns fetch requests/results for Stripe `event`, `payment_intent`, `charge`, `refund`, and `dispute` objects, marks whether the required object refs are present, and never returns raw object refs, raw Stripe payloads, provider secrets, Authorization, webhook bodies, or DB URLs. A reqwest-backed client should replace only the adapter implementation behind `StripeApiFetchRequest -> StripeApiFetchResult`.

`PATCH /admin/billing/payment-provider/merchant-credential` writes the tenant-scoped source-of-truth for merchant credential state. It accepts operator secret references only, not raw secret values. Use it to enable/disable the provider, record merchant/account ref presence, record a short credential fingerprint prefix, and advance a rotation marker.

```ts
type PaymentProviderMerchantCredentialPatchRequest = {
  provider: string;
  enabled?: boolean;
  merchant_account_ref?: string;
  credential_secret_ref?: string;
  credential_fingerprint_prefix?: string; // 8-32 lowercase hex chars
  webhook_secret_ref?: string;
  rotate_marker?: boolean;
  rotation_idempotency_key?: string; // stored only as hash
  rotation_reason?: string;
  metadata?: Record<string, unknown>;
};

type PaymentProviderCredentialRotationReadback = {
  schema: "payment_provider_credential_rotation_readback.v1" | string;
  rotate_requested: boolean;
  rotation_applied: boolean;
  rotation_replayed: boolean;
  rotation_marker_hash_present: boolean;
  rotation_marker_hash_echoed: false;
  old_fingerprint_prefix?: string | null;
  new_fingerprint_prefix?: string | null;
  active_generation?: number | null;
  rotation_version?: number | null;
  last_rotated_at?: string | null;
  secret_value_stored: false;
  secret_value_returned: false;
  idempotency_key_hash_stored: boolean;
};

type PaymentProviderMerchantCredentialPatchResponse = {
  schema: "payment_provider_merchant_credential_source.v1" | string;
  provider: string;
  credential_id: string;
  credential_source: PaymentProviderMerchantCredentialSource;
  credential_generation?: PaymentProviderMerchantCredentialSource["credential_generation"];
  config_status: PaymentProviderAdapterConfigStatus;
  secret_value_stored: false;
  secret_value_returned: false;
  rotation_marker_applied: boolean;
  rotation_marker_replayed?: boolean;
  rotation_readback?: PaymentProviderCredentialRotationReadback;
  rotation_reason_present: boolean;
  omitted_fields: string[];
};
```

Manual/local simulator for provider-neutral callback, capture, refund, and chargeback handoff DTOs. It does not verify production signatures, call upstream APIs, or perform ledger/credit writes. The response includes `adapter_config`, so UI can display `disabled`, `config-needed`, or `ready-for-sandbox` without implying production payment readiness.

Request:

```ts
type PaymentProviderSimulatorEventRequest = {
  tenant_id: string;
  provider: string;
  event_type: "callback" | "capture" | "refund" | "chargeback";
  external_event_id: string;
  amount: string;
  currency: string;
  reason: string;
  idempotency_key?: string;
  order_id?: string;
  payment_intent_id?: string;
  payment_capture_id?: string;
  refund_id?: string;
  credit_grant_id?: string;
  ledger_entry_id?: string;
  reversal_ledger_entry_id?: string;
  invoice_id?: string;
};
```

Response highlights:

```ts
type PaymentProviderSimulatorEventResponse = {
  schema: "payment_provider_runtime_skeleton.v1" | string;
  mode: "manual_local_simulator" | string;
  provider: string;
  event_type: "callback" | "capture" | "refund" | "chargeback";
  external_event_id_hash: string;
  amount: string;
  currency: string;
  action_result: string;
  signature_verification: "config-needed" | string;
  merchant_connected: false;
  production_payment_evidence: false;
  secret_safe: true;
  raw_webhook_body_echoed: false;
  raw_idempotency_key_echoed: false;
  raw_provider_payload_echoed: false;
  authorization_echoed: false;
  provider_secret_echoed: false;
  db_url_echoed: false;
  runtime_write_performed: false;
  real_provider_credentials_loaded: false;
  adapter_config: PaymentProviderAdapterConfigStatus;
  idempotency_key_hash?: string | null;
  audit_id?: string | null;
  refs: {
    order_id?: string | null;
    payment_intent_id?: string | null;
    payment_capture_id?: string | null;
    refund_id?: string | null;
    credit_grant_id?: string | null;
    ledger_entry_id?: string | null;
    reversal_ledger_entry_id?: string | null;
    invoice_id?: string | null;
    audit_id?: string | null;
  };
  omitted_fields: string[];
  notes: string[];
};
```

UI must display this as a simulator/config-needed state only. Do not display raw webhook bodies, raw idempotency keys, Authorization, provider secrets, provider payloads, DB URLs, or real payment readiness claims.

Typed local executor readback is exposed by `POST /admin/billing/payment-provider/executor`. It accepts `action="capture" | "refund" | "chargeback_ack"` and local refs, first plans the secret-safe `billing-ledger` `PaymentProviderExecutor` contract plus `stripe_like_client_request_plan`, gates on the tenant merchant credential source, writes no provider network calls, and never claims external merchant settlement. `stripe_like_client_request_plan` maps `capture -> capture_payment_intent`, `refund -> create_refund`, and `chargeback_ack -> chargeback_ack`; it exposes only method, path_template, body field presence, idempotency-header presence, credential-source readiness, and blocked reasons. `stripe_like_fetch_executor` is also returned on refused, blocked, applied, and replayed paths as the current network-disabled executor boundary: it carries the same request plan, `network_call_performed=false`, blocked reasons such as `network_disabled`, reduced response header/rate-limit summary, and, when optional `provider_object_source_of_truth` is supplied, a reduced `provider_object_summary` parsed by billing-ledger. `stripe_like_response_object_reconciliation` maps the local action, amount, currency, local refs, reduced provider object summary, and reduced header summary into `matched | mismatch | blocked`, with mismatch/block reasons, retry recommendation, and safe next action. The optional `provider_object_source_of_truth` JSON readback is separately reduced into `stripe_like_provider_object_summary`; if it is absent, the summary returns `status="blocked"`, `source_of_truth_status="object_not_loaded"`, `blocked_reason="network_disabled"`, and `next_step="fetch_provider_object_source_of_truth"`. Raw provider refs and raw idempotency keys are converted to hashed safe refs before planning; contract validation errors return `action_result="refused"` with `billing_ledger_executor_contract.validation_errors` and no executor write. Credential disabled, missing API credential, webhook-only source, missing merchant account, missing webhook secret, unsupported provider, or config mismatch returns `action_result="refused"` with no executor write and `stripe_like_client_request_plan.status="blocked"`. When the gate passes, the endpoint writes a secret-safe local `payment_events` executor marker and reuses the bounded local executor against existing `payment_intents`, `payment_captures`, `payment_refunds`, `ledger_entries`, and `credit_grants`; unsafe or missing refs return `action_result="blocked"`, while successful idempotent outcomes are `applied` or `replayed`.

Request:

```ts
type PaymentProviderLocalExecutorRequest = {
  tenant_id: string;
  provider: string;
  action: "capture" | "refund" | "chargeback_ack";
  amount: string;
  currency: string;
  idempotency_key: string; // hashed only, never returned
  reason: string;
  order_id?: string;
  project_id?: string;
  wallet_id?: string;
  payment_intent_id?: string;
  payment_capture_id?: string;
  refund_id?: string;
  dispute_ref?: string; // hashed only
  provider_event_ref?: string; // hashed only
  provider_object_ref?: string; // hashed only
  provider_object_source_of_truth?: Record<string, unknown>; // reduced only, never echoed raw
  credit_grant_id?: string;
  ledger_entry_id?: string;
  reversal_ledger_entry_id?: string;
  invoice_id?: string;
  metadata?: Record<string, unknown>; // secret-free only
};
```

Response highlights:

```ts
type PaymentProviderLocalExecutorReadback = {
  schema: "payment_provider_local_executor_readback.v1" | string;
  mode: "typed_local_executor" | string;
  provider: string;
  action: "capture" | "refund" | "chargeback_ack" | string;
  event_type: "capture" | "refund" | "chargeback" | string;
  action_result: "applied" | "replayed" | "blocked" | "refused" | string;
  refusal_reason?: string;
  billing_ledger_executor_contract: {
    schema: "payment_provider_executor_contract.v1" | string;
    status: "planned" | "refused" | string;
    action_result: "capture_planned" | "refund_planned" | "chargeback_ack_planned" | "executor_refused" | string;
    required_refs: string[];
    provider_refs: Record<string, { present: boolean; hash?: string | null; fingerprint?: string | null }>;
    local_refs: PaymentProviderRefs;
    gate_readback: Record<string, unknown>;
    validation_errors: string[];
    secret_safe: true;
    raw_idempotency_key_echoed: false;
    provider_ref_raw_echoed: false;
  };
  stripe_like_client_request_plan: {
    schema: "payment_provider_stripe_like_client_plan.v1" | string;
    provider: string;
    status: "network_disabled_ready" | "blocked" | string;
    http_client: "request_plan_only" | string;
    network_call_performed: false;
    credential_source: string;
    required_refs: string[];
    validation_errors: string[];
    blocked_reasons: string[];
    request: {
      operation: "capture_payment_intent" | "create_refund" | "chargeback_ack" | string;
      method: "POST" | string;
      path_template: string;
      path_ref_source: string;
      path_ref_present: boolean;
      body_fields: Array<{ name: string; source: string; value_present: boolean; value_echoed: false }>;
      idempotency_header_required: boolean;
      idempotency_header_present: boolean;
      credential_source_ready: boolean;
      merchant_account_ref_present: boolean;
      authorization_header_value_echoed: false;
      idempotency_header_value_echoed: false;
      raw_provider_payload_echoed: false;
    };
    secret_safe: true;
    raw_secret_echoed: false;
    raw_idempotency_key_echoed: false;
    raw_provider_payload_echoed: false;
    raw_provider_ref_echoed: false;
    authorization_echoed: false;
  };
  stripe_like_fetch_executor: {
    schema: "payment_provider_stripe_like_fetch_executor.v1" | string;
    provider: string;
    status: "object_not_loaded" | "fixture_parsed" | "network_client_not_configured" | string;
    implementation: "network_disabled_fixture_parser" | string;
    request_plan: Record<string, unknown>; // same Stripe-like request plan shape
    network_call_enabled: boolean;
    network_call_performed: false;
    http_client: "not_configured" | string;
    object_found?: boolean | null;
    provider_object_summary?: Record<string, unknown> | null; // reduced summary only, no raw payload
    fixture_response_parsed: boolean;
    parser_summary_available: boolean;
    blocked_reasons: string[];
    secret_safe: true;
    raw_secret_echoed: false;
    raw_idempotency_key_echoed: false;
    raw_provider_payload_echoed: false;
    raw_provider_ref_echoed: false;
    authorization_echoed: false;
  };
  stripe_like_provider_object_summary: {
    schema: "payment_provider_stripe_like_provider_object_summary_readback.v1" | string;
    status: "loaded" | "blocked" | string;
    source_of_truth_status: "loaded_from_request" | "object_not_loaded" | string;
    blocked_reason?: "network_disabled" | string | null;
    next_step?: "fetch_provider_object_source_of_truth" | string | null;
    expected_object_type: "payment_intent" | "refund" | "dispute" | string;
    expected_statuses: string[];
    expected_local_refs: string[];
    summary?: Record<string, unknown> | null; // billing-ledger summary only
    object_ref_readback: Record<string, unknown>;
    status_readback: Record<string, unknown>;
    amount_readback: Record<string, unknown>;
    currency_readback: Record<string, unknown>;
    local_metadata_ref_readback: Record<string, unknown>;
    network_call_enabled: false;
    network_call_performed: false;
    provider_object_source_of_truth_echoed: false;
    raw_provider_payload_echoed: false;
    raw_provider_ref_echoed: false;
    raw_idempotency_key_echoed: false;
    authorization_echoed: false;
    provider_secret_echoed: false;
    secret_safe: true;
  };
  stripe_like_response_object_reconciliation: {
    schema: "payment_provider_stripe_like_response_object_reconciliation.v1" | string;
    status: "matched" | "mismatch" | "blocked" | string;
    action: "capture" | "refund" | "chargeback_ack" | string;
    matched: boolean;
    provider: string;
    provider_object_summary_present: boolean;
    response_header_summary_present: boolean;
    provider_object_type_matches?: boolean | null;
    provider_status_matches?: boolean | null;
    amount_matches?: boolean | null;
    currency_matches?: boolean | null;
    local_refs_match?: boolean | null;
    expected_provider_object_types: string[];
    expected_provider_statuses: string[];
    expected_local_refs: string[];
    mismatch_reasons: string[];
    blocked_reasons: string[];
    retry_recommended: boolean;
    retry_reason: string;
    safe_next_action: string;
    network_call_performed: false;
    secret_safe: true;
    raw_provider_payload_echoed: false;
    raw_headers_echoed: false;
    raw_provider_ref_echoed: false;
    authorization_echoed: false;
    provider_secret_echoed: false;
  };
  executor_request: Record<string, unknown>; // includes idempotency_fingerprint and hashed provider refs
  executor_result: {
    status: "applied" | "replayed" | "blocked" | "refused" | string;
    applied: boolean;
    replayed: boolean;
    blocked: boolean;
    refused: boolean;
    runtime_write_performed: boolean;
    payment_event_id?: string;
  };
  event_write?: PaymentProviderWebhookEventWrite;
  execution_plan: PaymentProviderBoundedExecutionPlan;
  credential_source: PaymentProviderMerchantCredentialSource;
  adapter_config: PaymentProviderAdapterConfigStatus;
  stripe_api_source_of_truth: PaymentProviderStripeApiSourceOfTruthReadback;
  production_payment_evidence: false;
  secret_safe: true;
  raw_provider_payload_echoed: false;
  raw_idempotency_key_echoed: false;
  authorization_echoed: false;
  provider_secret_echoed: false;
  db_url_echoed: false;
};
```

UI should render this as local executor/readback state. Show `refused` for credential/config gates, `blocked` for business precondition failures, and `applied`/`replayed` only as bounded local DB execution. Use `stripe_like_client_request_plan` as the mockable next-step HTTP executor plan, `stripe_like_fetch_executor` as the current network-disabled parser/readback boundary, and `stripe_like_response_object_reconciliation` as a safe candidate decision: matched can proceed to local apply/replay, mismatch should stop for review, and blocked should follow `safe_next_action` or retry after backoff when `retry_recommended=true`. Do not display raw provider refs, raw idempotency keys, provider payloads, raw headers, Authorization, credentials, webhook secrets, request body values, fixture bodies, Stripe response payloads, or production settlement claims.

Verified provider webhook readback is exposed by `POST /billing/payment-provider/webhooks/{provider}`. For `provider=stripe_like` or `stripe_like_sandbox`, the endpoint accepts provider-native Stripe-like sandbox payloads (`id`, `type`, `data.object.id`, `data.object.amount_*`, `currency`, and local UUID refs in `data.object.metadata`) and normalizes them before invoking the bounded capture/refund/chargeback executor. Stripe-like signatures now use `Stripe-Signature: t=<unix_timestamp>,v1=<hmac_sha256_hex>` over the `t.raw_body` signed payload basis with a 300 second replay window; `x-fubox-payment-signature` remains as the local simulated raw-body HMAC compatibility path. The response includes `adapter="stripe_like_sandbox"` plus both `adapter_normalization` and the compatibility alias `adapter_readback`, with `signature_format_support`, `signature_parse`, secret-safe `signature_verification_readback`, `provider_event_readback`, `event_mapping`, `normalized_event`, and `unsupported_reason`. It also returns `stripe_api_source_of_truth`, a bounded readback seam for the future real Stripe client: `network_call_enabled=false`, `secret_ref_required=true`, source selection for callback/capture/refund/chargeback, API object ref requirements, and current object-ref presence. `signature_verification_readback` exposes status, timestamp age/tolerance, replay-window result, payload/signed-payload hashes, and mismatch reason without raw header, raw signature, raw body, Authorization, provider secret, or raw idempotency values. `provider_event_readback` exposes event/object id presence and hashes, amount/currency/local metadata presence, local ref count, schema validity, and refusal reason without echoing provider payload. Supported Stripe-like sandbox events map as follows: `checkout.session.completed` and `payment_intent.created` -> `callback`; `payment_intent.succeeded` and `charge.succeeded` -> `capture`; `charge.refunded`, `refund.created`, and `refund.succeeded` -> `refund`; `charge.dispute.created` and `charge.dispute.closed` -> `chargeback`. Unsupported providers, stale signatures, signature mismatch, missing object id, missing amount/currency, or missing tenant metadata return bounded refusal/unsupported responses with `runtime_write_performed=false`; they do not fall back to generic event writes.

The response includes `execution_plan: PaymentProviderBoundedExecutionPlan` with optional `payment_capture`, `payment_refund`, `reconciliation`, `credit_executor`, `wallet_accounting`, and `ledger_executor` objects. UI should treat executor status fields as the operator-facing state:

- `credit_executor.status=written|read_back`: verified simulated capture matched tenant-scoped payment intent/order/capture refs and wrote or read a `credit_grants` row plus confirmed `credit_grant` ledger entry.
- `wallet_accounting.status=read_back`: capture accounting refs were read back from `credit_grants`, `ledger_entries`, and `payment_captures`; `direct_wallet_snapshot_mutation` remains false.
- `ledger_executor.status=written|read_back`: refund/chargeback wrote or read an existing tenant-scoped reversal ledger ref for a matched capture that already had `ledger_entry_id`.
- `production_reconciliation.status=matched|mismatch|refused`: secret-safe local reconciliation readback across provider event, capture/refund, source ledger, reversal ledger, voided source credit grant, and local reconciliation marker refs. `production_source_of_truth_candidate=true` only when every local ref reads back exactly once, credential/source is ready, and no raw provider payload, raw idempotency, Authorization, or provider secret is exposed.
- `production_reconciliation.source_of_truth_policy`: bounded source-selection readback for capture/refund/chargeback. `source_selection.*` is one of `local_db_verified`, `provider_api_required`, `provider_webhook_verified`, or `refused`; `source_of_truth_status=candidate_ready` means UI may show local accounting as a source-of-truth candidate, while `provider_api_readback_required=true` means the next worker/UI must wait for provider API readback before trusting production settlement.
- `blocked`, `refused`, or `not_attempted`: show `reason`/`next_step` without implying money movement.

`disabled_writes` should still be shown when present. Provider webhooks do not mutate wallet snapshots and do not prove production merchant settlement source-of-truth.

## User Portal

### Standalone Route Handoff

Use `/?mode=developer-console` as the stable User Portal standalone entry for future frontend rebuilds. Compatibility aliases are `/?mode=user`, `/?mode=portal`, `/?app=developer-console`, `/?console=developer-console`, `/#/developer-console`, `/developer-console`, and `/portal`.

The legacy Admin UI resolves this boundary in `web/admin-ui/src/app/userPortalRoute.ts`. A matched target starts the app in user auth mode and skips Admin session restore, so an existing Admin cookie does not force the standalone user console back into the Admin workbench.

The standalone user shell should consume only user-scoped DTOs and client functions from `web/admin-ui/src/api/client.ts`. Do not couple the user shell to Admin nav capabilities, provider credentials, admin request-detail internals, admin billing controls, or route policy debug blobs.

### Home Summary

`GET /user/home-summary`

Use this as the User Portal homepage handoff DTO. It aggregates endpoint config, current balance, model availability, recent usage, and bounded recent request refs. If it returns 404/501 or is temporarily unavailable, the UI should fall back to the older split calls: `/user/balance`, `/user/models`, `/user/usage-summary`, and `/user/request-logs`.

```ts
type UserHomeSummary = {
  schema: "user_home_summary.v1" | string;
  secret_safe: true;
  project_id: string;
  endpoint: {
    base_url: string;
    openai_base_url: string;
    models_url: string;
    chat_completions_url: string;
    source: "runtime_config" | "local_fallback" | string;
    config_needed: boolean;
  };
  balance: UserBalance;
  models: {
    total_visible: number;
    routable_count: number;
    sample: Array<{
      id: string;
      model: string;
      display_name: string;
      routable: boolean;
      routable_channel_count: number;
      primary_protocol?: string | null;
      route_status: "routable" | "config-needed" | string;
    }>;
  };
  recent_usage: UserUsageTotals;
  recent_requests: {
    count: number;
    request_ids: string[];
    requests: UserRequestLogSummary[];
  };
  handoff: {
    contract: "GET /user/home-summary" | string;
    fallback: string;
    omitted_fields: string[];
  };
};
```

Homepage UI rules:

- `endpoint.config_needed=true` means the server used a local fallback endpoint. Show a config-needed state, but keep the local URL usable for dev.
- `recent_requests.request_ids` are safe correlation refs. They are not API keys or request payloads.
- `handoff.omitted_fields` must include secret/payload categories that are intentionally absent. Do not try to reconstruct them in the UI.

### Team Summary

`GET /user/team-summary`

Use this for the signed-in user's current project/team compact readback. It is user-session scoped and returns only member ids, role/status, membership source, project key/profile access presence, recent project request count/cost presence, and a safe next action.

```ts
type UserTeamSummary = {
  schema: "user_team_membership_compact_readback.v1";
  tenant_id: string;
  project_id: string;
  user_id: string;
  role: string;
  status: string;
  membership_source: "user_session_project_members" | string;
  project_access: MembershipProjectAccessSummary;
  recent_usage: MembershipRecentUsageSummary;
  team_members: Array<{
    user_id: string;
    role: string;
    status: string;
    membership_source: "project_members";
    membership_created_at?: string | null;
    raw_email_returned: false;
    secret_returned: false;
  }>;
  safe_next_action: string;
  handoff: {
    contract: "GET /user/team-summary" | string;
    source: "user_session_project_scoped_membership_readback" | string;
    fallback: string;
    omitted_fields: string[];
    raw_email_returned: false;
    raw_metadata_returned: false;
    secret_returned: false;
    authorization_returned: false;
  };
  secret_safe: true;
};
```

UI must not render raw email, session token, API key secret/hash, Authorization/Cookie, provider key/provider id, raw request/response/provider payload, or raw metadata from this aggregate. `recent_usage` is project scoped, not a per-member attribution feed.

### Readiness

`GET /user/readiness`

Use this for the first screen of the developer console.

```ts
type UserReadiness = {
  schema: string;
  secret_safe: boolean;
  project_id: string;
  state: "ready" | "attention" | "blocked" | string;
  next_action: string;
  counts: {
    active_keys: number;
    active_profiles: number;
    available_models: number;
    routable_models: number;
    recent_requests: number;
  };
  checks: Array<{
    code: string;
    label: string;
    status: "ready" | "attention" | "blocked" | string;
    detail: string;
    next_action: string;
  }>;
};
```

### Balance

`GET /user/balance?currency=USD&ledger_window_days=...`

```ts
type CreditGrantExpirationReadback = {
  schema: "credit_grant_expiration_readback.v1" | string;
  source: "credit_grants" | string;
  wallet_id: string;
  total_count: number;
  active_count: number;
  expired_count: number;
  expiring_soon_count: number;
  expiring_soon_window_days: number;
  available_amount_by_currency: Array<{
    currency: string;
    active_count: number;
    available_amount: string;
  }>;
  next_expiration_at?: string | null;
  bounded_grants: Array<{
    credit_grant_id: string;
    currency: string;
    remaining_amount: string;
    status: string;
    valid_until?: string | null;
  }>;
  source_refs_presence: {
    voucher_source_ref_present: boolean;
    payment_source_ref_present: boolean;
    subscription_source_ref_present: boolean;
    import_source_ref_present: boolean;
    admin_adjustment_source_ref_present: boolean;
    raw_source_ref_returned: false;
  };
  bounded_ids_only: true;
  safe_next_action: string;
  read_only: true;
  secret_safe: true;
};

type UserBalance = {
  schema: string;
  secret_safe: boolean;
  wallet_id: string;
  currency: string;
  active_credit_grant_total: string;
  credit_grant_expiration_readback?: CreditGrantExpirationReadback | null;
  funding_source_readback?: FundingSourceReadback | null;
  pending_confirmed_ledger_window: string;
  available_to_spend: string;
  last_credit_grant_ids: string[];
  last_ledger_entry_ids: string[];
};
```

### Billing History Readback

`GET /user/billing-history-readback`

Use this as the compact backend readback for the future billing/usage history page. It is user-session and project scoped, and combines current balance, recent ledger entries, request usage/cost rollup, and voucher/order/subscription ref presence into one frontend-consumable DTO. It is readback only; it does not run billing executors or perform release validation.

```ts
type UserBillingHistoryReadback = {
  schema: "user_billing_history_readback.v1" | string;
  secret_safe: true;
  project_id: string;
  user_id: string;
  wallet_id: string;
  window_days: number;
  balance: UserBalance;
  credit_grant_expiration_readback: CreditGrantExpirationReadback;
  funding_source_readback?: FundingSourceReadback | null;
  ledger_recent_entries: {
    source: "ledger_entries_project_scope" | string;
    window_days: number;
    entry_count: number;
    confirmed_count: number;
    confirmed_net_amount: string;
    currency: string;
    last_ledger_at?: string | null;
    entries: Array<{
      ledger_entry_id: string;
      wallet_id?: string | null;
      request_id?: string | null;
      virtual_key_id?: string | null;
      entry_type: string;
      amount: string;
      currency: string;
      status: string;
      created_at: string;
      raw_metadata_returned: false;
    }>;
    raw_ledger_metadata_returned: false;
    raw_payload_returned: false;
  };
  request_usage_cost_rollup: UserUsageTotals;
  refs_presence: {
    source: "voucher_order_subscription_project_or_wallet_scope" | string;
    voucher_refs_present: boolean;
    order_refs_present: boolean;
    subscription_refs_present: boolean;
    voucher: { count: number; redemption_count: number; last_redemption_at?: string | null };
    order: { count: number; paid_count: number; last_order_at?: string | null };
    subscription: { count: number; active_count: number; last_subscription_at?: string | null };
    authorization_returned: false;
    provider_key_returned: false;
    raw_payload_returned: false;
  };
  safe_next_action: string;
  omitted_fields: string[];
  raw_api_key_returned: false;
  authorization_returned: false;
  provider_key_returned: false;
  raw_payload_returned: false;
  raw_ledger_metadata_returned: false;
  raw_invoice_metadata_returned: false;
};
```

UI rules:

- Prefer this endpoint over composing `/user/balance`, `/user/usage-summary`, and `/user/request-logs` for billing history screens.
- Render ledger rows from `ledger_recent_entries.entries[]`; do not request or infer raw ledger metadata.
- Render funding-source chips from `refs_presence.*_refs_present` and counts only. Do not render raw voucher codes, voucher code hashes, raw invoice metadata, raw payment/provider payloads, provider keys, or Authorization material.

### User API Keys

- `GET /user/virtual-keys?status=active`
- `POST /user/virtual-keys`
- `POST /user/virtual-keys/{id}/disable`

```ts
type UserVirtualKey = {
  id: string;
  tenant_id: string;
  project_id: string;
  name: string;
  key_prefix: string;
  status: "active" | "disabled" | "expired" | "deleted" | string;
  default_profile_id?: string | null;
  budget_policy: JsonValue;
  rate_limit_policy: JsonValue;
  ip_allowlist: JsonValue;
  metadata: JsonValue;
  secret?: string | null;
  secret_once: boolean;
  secret_redacted: boolean;
};
```

Creation response may include `secret` with `secret_once=true`. Show it once with copy affordance, then hide it.

### User Models

`GET /user/models`

```ts
type UserModel = {
  id: string;
  model: string;
  display_name: string;
  status: string;
  visibility: string;
  routable: boolean;
  routable_channel_count: number;
  default_profile_id?: string | null;
  family?: string | null;
  context_length?: number | null;
  max_output_tokens?: number | null;
  supports_audio: boolean;
  supports_reasoning: boolean;
  supports_stream: boolean;
  supports_tools: boolean;
  supports_vision: boolean;
  price?: {
    price_version_id: string;
    price_book_id?: string | null;
    version?: string | null;
    currency?: string | null;
    pricing_rules?: JsonValue | null;
    effective_at?: string | null;
    retired_at?: string | null;
    secret_safe: boolean;
  } | null;
};

type UserModelsMeta = {
  schema: "user_models.v1" | string;
  project_id: string;
  source: "active_user_profile" | string;
  model_availability_readback: ModelAvailabilityReadback;
  secret_safe: true;
};
```

The response envelope is `{ data: UserModel[], meta: UserModelsMeta }`. Use `meta.model_availability_readback` for developer-console model availability summaries instead of recomputing blocked reasons or guardrail presence client-side.

### Usage and Requests

- `GET /user/usage-summary?window_days=...`
- `GET /user/request-logs?limit=...&model=...&status=...&request_id=...&trace_id=...`
- `GET /user/traces/{trace_id}?limit=...&window_days=...`

Usage summary:

```ts
type UserUsageSummary = {
  schema: string;
  secret_safe: boolean;
  project_id: string;
  window_days: number;
  totals: {
    request_count: number;
    success_count: number;
    failed_count: number;
    retryable_failed_count: number;
    input_tokens: number;
    output_tokens: number;
    total_tokens: number;
    total_cost: string;
    currency: string;
    avg_latency_ms?: number | null;
  };
  by_model: UserUsageModelSummary[];
  by_key: UserUsageKeySummary[];
  top_errors: UserUsageErrorSummary[];
};
```

User request log filters:

```ts
type UserRequestLogFilters = {
  limit?: number;
  model?: string;
  status?: string;
  request_id?: string;
  trace_id?: string;
};
```

Frontend usage:

- Use `request_id` for exact lookup after the API console reads the gateway `x-request-id` response header.
- Use `trace_id` to show a user's own grouped request attempts or retries. Prefer `GET /user/traces/{trace_id}` when the UI needs the trace summary and bounded request list together.
- `request_id` and `trace_id` are project-scoped on the server. A user must only see their own request rows.
- User request rows intentionally omit admin-only route/provider internals. Show only the user's own request id, model, status, cost, tokens, latency, trace id, hashes, and safe error fields.
- Do not render or export prompt text, raw payloads, raw provider/upstream payloads, provider key material, virtual key secrets after one-time display, `Authorization`, cookies, or credential headers from any user request-log surface.

## Gateway: OpenAI-compatible API

Gateway requests use the user virtual key secret:

```http
Authorization: Bearer <user_api_key_secret>
```

Optional gateway request headers:

```http
x-ai-profile: <profile id or profile ref>
x-ai-trace-id: <safe trace id>
```

Response header:

```http
x-request-id: <request log id>
```

Use `x-request-id` to correlate API console calls with request log detail. For stream responses, request id availability depends on the response path; the request log and trace drawer remain the authoritative readback.

### List Models

`GET /v1/models`

Response:

```ts
type GatewayModelsResponse = {
  object: "list";
  data: Array<{
    id: string;
    object: "model";
    created: number;
    owned_by: string;
  }>;
  gateway: {
    model_source: "database" | string;
    authorization: "virtual_key" | string;
    profile_filtering: "api_key_profile" | "tenant_visible_models_without_profile" | string;
    profile_id?: string | null;
  };
};
```

The list is filtered by the current virtual key/profile visibility. The user portal `GET /user/models` is richer for UI display; `/v1/models` is the runtime compatibility endpoint.

### Chat Completions

`POST /v1/chat/completions`

Request accepts OpenAI-compatible fields and forwards unknown extra fields:

```ts
type ChatCompletionRequest = {
  model: string;
  messages: Array<{
    role: string;
    content?: unknown;
    [extra: string]: unknown;
  }>;
  stream?: boolean;
  [extra: string]: unknown;
};
```

Expected non-stream shape is OpenAI-compatible:

```ts
type GatewayChatCompletionResponse = {
  id: string;
  object: "chat.completion";
  created: number;
  model: string;
  choices: Array<{
    index: number;
    message?: {
      role?: string;
      content?: unknown;
      [extra: string]: unknown;
    };
    delta?: unknown;
    finish_reason: string | null;
    [extra: string]: unknown;
  }>;
  usage?: {
    prompt_tokens?: number;
    completion_tokens?: number;
    total_tokens?: number;
    [extra: string]: unknown;
  };
  [extra: string]: unknown;
};
```

The gateway fills missing `id`, `object`, `created`, `model`, choice `index`, and final `finish_reason` for non-stream chat completions. It does not fabricate `usage`; request log token fields are populated only when provider usage was present.

Request log summaries expose a secret-safe `openai_compat` handoff:

```ts
type GatewayOpenAiCompatProjection = {
  schema: "gateway_openai_compat_projection_v1";
  source_schema?: "gateway_openai_chat_completion_compat_v1" | string | null;
  status: "recorded" | "config-needed" | "not_recorded" | string;
  secret_safe: true;
  mode: "stream" | "non_stream" | string;
  endpoint?: "chat_completions" | string | null;
  x_request_id?: string | null;
  x_request_id_present?: boolean | null;
  request_id_header_present: boolean;
  response_id?: string | null;
  response_id_present: boolean;
  object?: string | null;
  type?: string | null;
  model?: string | null;
  choices_count?: number | null;
  finish_reasons?: Array<string | null> | null;
  finish_reason_present: boolean;
  response_body_hash?: string | null;
  provider_usage_present?: boolean | null;
  usage_present: boolean;
  usage_observed?: boolean | null;
  usage_recorded: boolean;
  input_tokens_recorded?: boolean | null;
  output_tokens_recorded?: boolean | null;
  done_sent?: boolean | null;
  final_chunk_seen?: boolean | null;
  final_chunk_sent?: boolean | null;
  final_chunk?: string | null;
};
```

SDK/API-console UI should read `x-request-id` from the gateway response, then use `/user/request-logs?request_id=...` or admin request detail to show `openai_compat.mode`, `request_id_header_present`/`x_request_id_present`, `response_id_present`, `object`/`type`, `finish_reason_present`, `finish_reasons`, `usage_present`/`usage_observed`, token-recorded booleans, `done_sent`, `final_chunk_seen`, `final_chunk_sent`, `final_chunk` for stream rows, and `response_body_hash`. If metadata is absent, render `status: "not_recorded"` for ordinary non-stream rows or `status: "config-needed"` for streamed rows where only request-log columns/finalizer evidence exist. Do not display raw messages, raw provider responses, raw stream chunks, `Authorization`, provider keys, or API key secrets.

Streaming uses `stream: true` and `text/event-stream` provider behavior where implemented. Stream request logs use `stream_finalizer` for finalizer readback and `openai_compat` for safe OpenAI-compatible shape status; non-stream logs use `openai_compat` for normalized response shape readback. Neither projection is a raw snapshot.

Gateway error UI should use the safe envelope:

```ts
type GatewayErrorEnvelope = {
  error?: {
    code?: string;
    message?: string;
    type?: string;
    param?: string;
  };
  gateway?: {
    error_owner?: string;
    error_stage?: string;
    retryable?: boolean;
  };
};
```

Common safe upstream normalization codes include `upstream_timeout`, `upstream_invalid_model`, upstream auth failures, upstream rate/quota failures, upstream server errors, and generic upstream request failures. Do not render raw upstream body.

## Local Mock and Smoke Path

Recommended local path for UI developers:

1. Start local stack with `scripts/dev_up.ps1`.
2. Run `scripts/dev_login_check.ps1`.
3. Use the emitted local services:
   - Admin UI: `http://localhost:5173` unless configured otherwise.
   - Control Plane: `http://localhost:8081`.
   - Gateway: `http://localhost:8080`.
   - Mock Provider: `http://localhost:18080`.

The smoke path verifies:

- `POST /admin/auth/login`
- `POST /auth/register`
- `GET /user/readiness`
- `GET /user/balance?currency=USD`
- `POST /admin/voucher-issuances`
- `POST /user/vouchers/redeem`
- `GET /user/models`
- `POST /user/virtual-keys`
- `GET /v1/models` with `Authorization: Bearer <user key>`
- `POST /v1/chat/completions` with `Authorization: Bearer <user key>`
- `GET /user/request-logs`
- `GET /admin/request-logs/{id}`

Mock provider supports:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/chat/completions` with `stream: true`
- Scenarios: `200`, `429`, `5xx`, `timeout`, `eof`, `invalid_sse`, `large_chunk`

Scenario selection works through `?scenario=<name>` or request body fields `mock_scenario` / `scenario`. Stream mode works through `?stream=true` or request body `stream: true`.

## UI Rebuild Dependency Notes

- Prefer `GET /user/models` for user model cards and pricing; use Gateway `/v1/models` only for runtime API console validation.
- Prefer `GET /user/readiness` for developer console empty/blocked states.
- Prefer Admin request detail drawer from `GET /admin/request-logs/{id}` as the main debug surface; payload preview is secondary and opt-in.
- Provider/channel/key setup should stay in one workflow: provider -> channel -> provider key -> recovery/manual test.
- Billing screens should treat wallet and voucher APIs as secret-safe readback surfaces and fixed-decimal money displays.
- Any new UI data dependency should first check whether `client.ts` already has a typed function. If not, add a typed wrapper there before using `fetch` directly in components.
