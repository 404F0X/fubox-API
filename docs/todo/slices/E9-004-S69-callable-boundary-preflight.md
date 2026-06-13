# E9-004-S69 Callable Boundary Preflight

This is a no-build, no-DB-write operator shape guide. It does not approve a live paid commit.

## Fixture

Tracked input shape:

`tests/fixtures/billing-ledger/runtime_writer_commit_input.reserve_paid_minimal.json`

Before a separately approved live paid commit rehearsal, copy the fixture shape to:

`.tmp/billing-ledger/runtime-writer-commit-input.json`

The live input must contain real repo/operator scoped values for `tenant_id`, `project_id`, `virtual_key_id`, `user_id`, `wallet_id`, `request_id`, `source`, `amount`, `currency`, `available_balance`, `operation_scope`, `artifact_path`, and the operator-computed idempotency key.

## Required Env Markers

- `BILLING_LEDGER_LIVE_DATABASE_URL`
- `AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_WRITER_AVAILABLE=1`
- `AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_SCHEMA_AVAILABLE=1`
- `AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_TOOL_AVAILABLE=1`
- `AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_CONTAINER_COMMIT=<current runtime commit>`
- `AI_CONTROL_PLANE_BILLING_LEDGER_ACTIVE_WRITER=billing_ledger_runtime_writer`
- `AI_CONTROL_PLANE_BILLING_LEDGER_SOURCE_OF_TRUTH=billing_ledger_runtime_writer`
- `AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_READBACK=billing_ledger_runtime_writer`
- `AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_OPERATION_SCOPE=paid-beta-bounded-ledger-reserve`
- `AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_IDEMPOTENCY_KEY=<reserve_ledger_idempotency_key(request_id)>`
- `AI_CONTROL_PLANE_BILLING_LEDGER_NO_DUAL_READBACK_OPT_IN=1`
- `AI_CONTROL_PLANE_BILLING_LEDGER_COMMIT_READBACK_OPT_IN=1`
- `AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_WRITER_COMMIT_INPUT_PATH=.tmp/billing-ledger/runtime-writer-commit-input.json`
- `AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_PROOF_ARTIFACT_PATH=.tmp/billing-ledger/live-commit-proof-artifact.json`

## One-Time Command Shape

Dry-run/refusal, no DB write:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/operator/e9_billing_ledger_callable_runtime_writer_boundary.ps1 -LiveCommitOptIn -RuntimeWriterAvailable -RuntimeSchemaAvailable -RuntimeToolAvailable -NoDualReadbackOptIn -CommitReadbackOptIn -InputPath .tmp/billing-ledger/runtime-writer-commit-input.json -ArtifactPath .tmp/billing-ledger/live-commit-proof-artifact.json -OperationScope paid-beta-bounded-ledger-reserve -IdempotencyKey <reserve_ledger_idempotency_key(request_id)> -CurrentCommit <current commit> -RuntimeContainerCommit <current runtime commit> -ActiveWriterMarker billing_ledger_runtime_writer -SourceOfTruthMarker billing_ledger_runtime_writer -LiveCommitReadbackMarker billing_ledger_runtime_writer
```

Expected first blocker without separate live paid commit approval:

`execute_live_commit_opt_in_missing`

Readback command after a separately approved live run writes the artifact:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1 -ReadLiveCommitProofArtifact -LiveCommitProofArtifactPath .tmp/billing-ledger/live-commit-proof-artifact.json -SingleWriterCutoverProof -LiveCommitProof
```
