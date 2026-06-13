# E3 Provider Key Audit Readback Runbook

Scope: bounded operator proof for provider key readback, state mutation, restore, and audit readback without exposing credential material.

## What This Proves

- `GET /admin/provider-keys/{id}` returns operational state only.
- Provider key responses expose `credential_configured` and `secret_redacted`, not raw `secret`, `api_key`, `encrypted_secret`, `secret_fingerprint`, or `current_window_state`.
- Admin state changes through `PATCH /admin/provider-keys/{id}` write `provider_key.update` audit rows.
- `/admin/audit-logs` readback for provider key updates remains credential-safe.
- The local proof is bounded and can restore the provider key to its original status after mutation.

## Run Contract-Only Verification

This mode does not call the running Control Plane and does not mutate state.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_provider_key_audit_readback.ps1 -DryRun
```

Expected artifact:

```text
.tmp/control-plane/provider_key_audit_readback.json
```

Required fields for pass:

- `schema = provider_key_audit_readback.v1`
- `status = pass`
- `secret_safe = true`
- `checks.fixture_contract = pass`
- `checks.source_contract = pass`

## Run Live Readback Without Mutation

Use this to verify provider key readback against a running local Control Plane.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_provider_key_audit_readback.ps1
```

Optional environment overrides:

```powershell
$env:CONTROL_PLANE_BASE_URL = "http://127.0.0.1:8081"
$env:CONTROL_PLANE_ADMIN_EMAIL = "admin@example.com"
$env:CONTROL_PLANE_ADMIN_PASSWORD = "local-password"
$env:PROVIDER_KEY_AUDIT_READBACK_ID = "00000000-0000-0000-0000-000000000075"
```

## Run Bounded Mutation And Audit Readback

This mode performs one safe status patch, reads the `provider_key.update` audit log, and attempts to restore the original status. Use it only against local/dev or an explicitly approved staging target.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_provider_key_audit_readback.ps1 -ExecuteMutation
```

The verifier writes only redacted diagnostics and fails if the response, audit readback, or artifact contains credential-shaped material.

If a prior run was interrupted after mutation, use the last known safe state from the artifact:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_provider_key_audit_readback.ps1 -ExecuteMutation -RestoreStatus enabled
```

## Rotation Boundary

The Control Plane now exposes `POST /admin/provider-keys/{id}/rotate`. The runtime route creates a new sealed provider key for the same channel, moves the old key to `manual_disabled`, and writes a `provider_key.rotate` audit row in one transaction. Provider key readback, recovery response, and rotation response now include bounded lifecycle/recovery hints: `lifecycle_state`, `credential_generation`, `last_probe_summary`, `rotation_needed.reason`, `safe_next_action`, and `omitted_secret_policy`. Responses remain secret-safe: no raw provider credential, sealed payload, fingerprint, Authorization header, raw endpoint, raw payload, session token, raw metadata, or current window state is returned.

Production-grade rotation still needs external and runtime evidence:

- KMS or provider-key master-key custody and rotation policy.
- Live traffic/readback evidence on the new key before production closure.
- Old key disable/readback and rollback evidence for the selected production environment.
- Rollback policy when the new key fails provider auth or quota checks.

Until those are available, production rotation remains blocked. Operators may still use the bounded create-new-key / verify-traffic / disable-old-key substitute when a change window or policy requires manual staging.

## Production Rotation Readiness Resume Checklist

Current status: the runtime rotate endpoint is implemented, but production rotation closure is still blocked. Do not mark production provider-key rotation complete from a fixture, dry run, local-only mutation, or checklist-only artifact. Production closure still requires KMS/master-key custody evidence, live traffic/readback on the new key, old-key disable/readback, rollback evidence, and secret-safe audit readback.
Verifier marker: production closure remains blocked until those external inputs are present.

Run the readiness contract:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_provider_key_production_rotation_readiness.ps1
```

The verifier writes:

```text
.tmp/control-plane/provider_key_production_rotation_readiness.json
```

Expected classification until production evidence lands:

- `schema = provider_key_production_rotation_readiness.v1`
- `status = production_ready_blocked`
- `runtime_rotate_endpoint_implemented = true`
- `final_rotation_closure_allowed = false`
- `bounded_substitute_allowed = true`
- `secret_safe = true`

Runtime rotate endpoint flow:

1. Call `POST /admin/provider-keys/{old_id}/rotate` with a raw provider credential in `secret` or `api_key`. The server seals it and creates a new provider key for the same channel.
2. Read back the response and `GET /admin/provider-keys/{new_id}`. Confirm `credential_configured=true`, `secret_redacted=true`, status `enabled`, and no `secret`, `api_key`, `encrypted_secret`, `secret_fingerprint`, or `current_window_state`.
3. Confirm `GET /admin/provider-keys/{old_id}` shows `manual_disabled`.
4. Read back `/admin/audit-logs` for `provider_key.rotate`; confirm old/new ids, status transition metadata, request context, and secret-safe snapshots.
5. Before production closure, run traffic through the new key and read request logs/provider attempts/ledger/audit metadata. The local route alone is not enough to close production rotation.

safe substitute flow for manual staging:

1. Create a new provider key with `POST /admin/provider-keys`. The raw provider credential is allowed only in the request body handled by the Control Plane; the server must seal it. Responses must expose `credential_configured` and `secret_redacted`, never `secret`, `api_key`, `encrypted_secret`, `secret_fingerprint`, or `current_window_state`.
2. Read back `GET /admin/provider-keys/{new_id}` and confirm tenant/channel/alias/status/limits plus `credential_configured=true` and `secret_redacted=true`.
3. Verify traffic on the new key's channel/model before touching the old key. Contract preflight: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_provider_key_runtime_smoke.ps1 -DryRun`. Production/staging closure also needs live request/readback evidence showing `request_logs.provider_key_id` and `provider_attempts.provider_key_id` for the new key, with provider error output redacted.
4. Disable the old key only after new-key traffic proof passes: `PATCH /admin/provider-keys/{old_id}` with `status=manual_disabled`.
5. Read back `/admin/audit-logs` for `provider_key.update` and/or `provider_key.rotate` operations.
6. Run `pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_provider_key_audit_readback.ps1 -DryRun` and archive the readiness artifact plus the live traffic/readback artifact. All artifacts must be secret-safe.

KMS/master-key custody policy blocker:

- This is an external dependency. The repo verifier can require and record the dependency, but it cannot prove production custody until platform/security owners provide KMS or master-key evidence from outside this repository.
- Production must define where `AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64` is sourced from and how `AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID` maps to custody evidence. Acceptable sources are an approved KMS/secret manager integration or an externally reviewed master-key custody process.
- Do not reuse `dev-seed-v1` or any local dev seed master key outside local Compose.
- Custody evidence must name owner, storage location, access policy, rotation cadence, break-glass process, rollback process, and audit trail.
- The current verifier can confirm the dependency is documented; it cannot close the dependency without external KMS/master-key evidence.

Secret-safe evidence requirements:

- Admin readback, audit readback, runtime request/readback, and readiness artifacts must omit raw provider credentials, sealed payloads, fingerprints, Authorization headers, session tokens, and DB URLs.
- Allowed public indicators are operational identifiers and booleans such as provider key id, tenant id, channel id, key alias, status, `credential_configured`, and `secret_redacted`.
- Any artifact containing raw credential-shaped material invalidates the rotation attempt and requires credential revocation outside this repo.
