# E8-004 Production Backend Evidence Runbook

Status: operator handoff for a future real tokenizer/read-model backend.

This runbook does not enable a backend, read raw prompt/input/body/header material,
or change Gateway default behavior. It fixes the command and artifact boundary that
operators must use once a production tokenizer/read-model backend exists.

## Default Safety

Default command:

```powershell
pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -ContractOnly
```

Default behavior:

- no artifact read
- no backend connection
- no raw prompt/input/body/header read
- no network
- status is `production_ready_blocked`
- blocker is `missing_opt_in`

## Required Operator Order

1. Verify current runtime marker.

   Required evidence:

   - current runtime commit
   - Gateway runtime-current marker
   - backend kind: `tokenizer_backend` or `read_model_backend`
   - token source kind: `prompt_tokens` or `input_tokens`

2. Run the real production backend runner.

   The runner must be external to this contract and must write a bounded artifact.
   It must not include raw prompt/input/body/header, provider key, endpoint secret,
   or raw current-window material.

3. Write artifact.

   Allowed artifact paths for this handoff:

   - `.tmp/gateway_tpm_production_backend/<artifact>.json`
   - `tests/fixtures/gateway/<contract-only-fixture>.json` for contract tests only

4. Read back artifact.

   ```powershell
   pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 `
     -OptInArtifactReadback `
     -ArtifactPath .tmp/gateway_tpm_production_backend/<artifact>.json `
     -ExpectedCommit <current-runtime-commit> `
     -BackendKind read_model_backend `
     -TokenSourceKind input_tokens
   ```

5. Run Gateway live smoke with the same runtime/backend evidence.

   Command handoff shape:

   ```powershell
   $env:GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE = "1"
   $env:GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED = "1"
   pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 `
     -EmitLiveCommand `
     -ExpectedCommit <current-runtime-commit> `
     -BackendKind read_model_backend `
     -TokenSourceKind input_tokens
   ```

6. Verify DB acquire/result evidence.

   Required fields:

   - reservation capacity projection
   - DB acquire evidence
   - DB acquire result
   - token count used by TPM capacity
   - duration/latency marker

## Live Execution Pack

Execution pack schema:
`gateway_tpm_trusted_numeric_source_production_backend_live_execution_pack_v1`.

Plan-only command:

```powershell
pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 `
  -EmitExecutionPack `
  -ExpectedCommit <current-runtime-commit> `
  -BackendKind read_model_backend `
  -TokenSourceKind input_tokens
```

This command does not run the backend runner, Gateway live smoke, DB readback, or
network calls. It only prints the operator execution plan. Artifact readback still
requires `-OptInArtifactReadback`.

## Local Prototype Runner

The local prototype runner is for bounded development readback only. It does not
connect to an external tokenizer/read-model service, does not run Gateway live
smoke, does not query the DB, and does not read raw prompt/input/body/header
material. It only reads a repo-bounded fixture and writes a `.tmp` artifact
marked as non-production evidence.

Dry-run command:

```powershell
pwsh -File scripts/run_gateway_tpm_production_backend_evidence.ps1 `
  -DryRun `
  -RunLocalPrototype `
  -ArtifactPath .tmp/gateway_tpm_production_backend/e8-s115-local-prototype.json `
  -ExpectedCommit <commit> `
  -BackendKind read_model_backend `
  -TokenSourceKind input_tokens
```

Artifact write command:

```powershell
pwsh -File scripts/run_gateway_tpm_production_backend_evidence.ps1 `
  -RunLocalPrototype `
  -ArtifactPath .tmp/gateway_tpm_production_backend/e8-s115-local-prototype.json `
  -ExpectedCommit <commit> `
  -BackendKind read_model_backend `
  -TokenSourceKind input_tokens
```

Readback command:

```powershell
pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 `
  -OptInArtifactReadback `
  -ArtifactPath .tmp/gateway_tpm_production_backend/e8-s115-local-prototype.json `
  -ExpectedCommit <commit> `
  -BackendKind read_model_backend `
  -TokenSourceKind input_tokens
```

The local prototype artifact must include:

- `local_prototype=true`
- `real_operator_evidence=false`
- `simulation_can_close_final_gap=false`
- `gateway_live_smoke_status=local_prototype_not_run`
- no DB acquire/readback counts

This path can prove the wrapper/readback contract, but it cannot move E8 to final
`[x]`. Final closure still requires real production backend runner evidence, live
Gateway smoke, DB acquire/readback, and secret-safe proof.

Required env for the live execution pack:

- `GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE=1`
- `GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED=1` or
  `GATEWAY_TPM_TRUSTED_TOKENIZER_ENABLED=1`
- `GATEWAY_TPM_PRODUCTION_ARTIFACT_PATH=.tmp/gateway_tpm_production_backend/<artifact>.json`
- `DATABASE_URL=<operator-provided-secret-in-shell-only>`

Preflight checklist:

- current runtime commit marker matches `-ExpectedCommit`
- backend kind/source are declared by the operator
- token source kind/count are numeric and match expected count
- live smoke URL/scope is bounded to Gateway operator smoke
- DB reservation table/readback target is declared
- artifact path stays under `.tmp/gateway_tpm_production_backend`
- secret-safe raw omission is asserted

Exact command shapes:

```powershell
pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -ContractOnly
```

```powershell
$env:GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE='1'
$env:GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED='1'
$env:GATEWAY_TPM_PRODUCTION_BACKEND_RUNNER_COMMAND='<external-production-runner-command>'
$env:GATEWAY_TPM_GATEWAY_LIVE_SMOKE_COMMAND='<gateway-live-smoke-command>'
$env:GATEWAY_TPM_PRODUCTION_ARTIFACT_PATH='.tmp/gateway_tpm_production_backend/<artifact>.json'
pwsh -File scripts/run_gateway_tpm_production_backend_evidence.ps1 `
  -RunBackendRunner `
  -ExpectedCommit <commit> `
  -BackendKind read_model_backend `
  -TokenSourceKind input_tokens `
  -ArtifactPath .tmp/gateway_tpm_production_backend/<artifact>.json
```

```powershell
& $env:GATEWAY_TPM_GATEWAY_LIVE_SMOKE_COMMAND `
  --scope e8-rate-limit-tpm `
  --expected-commit <commit> `
  --artifact-path .tmp/gateway_tpm_production_backend/<artifact>.json `
  --omit-raw-material
```

```powershell
psql $env:DATABASE_URL -v ON_ERROR_STOP=1 `
  -f scripts/operator/e8_rate_limit_db_acquire_readback.sql `
  --set artifact_path=.tmp/gateway_tpm_production_backend/<artifact>.json
```

```powershell
pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 `
  -OptInArtifactReadback `
  -ArtifactPath .tmp/gateway_tpm_production_backend/<artifact>.json `
  -ExpectedCommit <commit> `
  -BackendKind read_model_backend `
  -TokenSourceKind input_tokens
```

Cleanup and rollback:

- Copy the accepted artifact to the operator evidence store, then remove the
  `.tmp/gateway_tpm_production_backend/<artifact>.json` working file.
- Unset `GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE`,
  `GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED`,
  `GATEWAY_TPM_TRUSTED_TOKENIZER_ENABLED`, and
  `GATEWAY_TPM_PRODUCTION_ARTIFACT_PATH`.
- Stop the smoke process without changing Gateway defaults.

Final E8 `[x]` operator proof bundle:

- `production_backend_live_smoke_passed` readback
- live Gateway smoke evidence
- DB acquire/readback evidence
- secret-safe proof with raw material omitted

## Final Closure Audit

Closure audit schema:
`gateway_tpm_trusted_numeric_source_final_closure_evidence_audit_v1`.

Default no-IO audit:

```powershell
pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -ContractOnly
```

Default audit behavior:

- `final_x_eligible=false`
- `artifact_read=false`
- `artifact_acceptance_state=production_ready_blocked`
- blocking reasons include missing opt-in, missing production artifact, missing
  live Gateway smoke, and missing DB acquire/readback
- no external artifact read
- no backend connection
- no network
- no raw prompt/input/body/header read

The audit report includes:

- `final_x_eligible`
- `blocking_reasons`
- `required_evidence`
- `artifact_acceptance_state`
- `live_smoke_state`
- `db_acquire_readback_state`
- `backend_provenance`
- `backend_kind`
- `backend_source_present`
- `runtime_current_marker`
- `runtime_commit`
- `current_commit`
- `generated_at`
- `secret_safe_omission`
- `artifact_read`
- `simulation`
- `real_operator_evidence`
- `exact_next_commands`

Accepted simulations and repo fixtures must keep `final_x_eligible=false`.
Only real, non-simulated, non-fixture operator evidence may become
`final_x_eligible=true`, and only when the readback status is
`production_backend_live_smoke_passed`.

## Production Evidence Watcher

Watcher schema:
`gateway_tpm_trusted_numeric_source_production_evidence_watcher_v1`.

Default watcher command:

```powershell
pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 `
  -EmitWatcher `
  -ExpectedCommit <current-runtime-commit> `
  -BackendKind read_model_backend `
  -TokenSourceKind input_tokens
```

Default watcher behavior:

- no polling
- no artifact read
- no backend connection
- no network
- no raw prompt/input/body/header read
- `current_status=production_ready_blocked`
- exact next commands are included in the report

Expected artifact paths:

- `.tmp/gateway_tpm_production_backend/<commit>-<backend-kind>-e8-live-evidence.json`
- `tests/fixtures/gateway/<contract-only-fixture>.json` for contract tests only

Required operator actions:

- run the real production tokenizer/read-model backend runner
- run Gateway live smoke with bounded E8 rate-limit TPM scope
- write the production artifact under `.tmp/gateway_tpm_production_backend`
- include DB acquire/result/readback counts
- omit raw prompt/input/body/header material
- run explicit opt-in artifact readback

If an explicitly requested artifact path does not exist, the watcher/readback
output remains blocked and returns the exact readback command to run after the
operator writes the artifact. This is not final `[x]` failure; it means the
production evidence has not arrived yet.

Final review checklist:

- closure audit `final_x_eligible` is `true`
- artifact acceptance state is `production_backend_live_smoke_passed`
- `real_operator_evidence` is `true`
- `simulation` is `false`
- live smoke state is `passed`
- DB acquire/readback state is `present`
- secret-safe omission is `true`

Do not move E8 to final `[x]` unless real production evidence satisfies this
watcher checklist and the final closure audit.

Machine-readable final guard constants:

- `simulation_can_mark_final_x=false`
- `template_can_pass=false`
- `watcher_can_mark_final_x=false`
- `accepted_for_review_can_mark_final_x=false`
- `production_shaped_temp_artifact_can_replace_real_evidence=false`

The only final `[x]` path is real production backend runner evidence plus live
Gateway smoke/readback, DB acquire/readback, and secret-safe proof.

## Artifact Schema

The production runner artifact must include:

- `schema`: `gateway_tpm_trusted_numeric_source_production_runner_artifact_v1`
- `artifact_provenance`
- `runner_provenance`
- `runner_command_provenance`
- `backend_kind`
- `backend_source`
- `runtime_current_marker`
- `runtime_commit`
- `current_commit`
- `generated_at`
- `artifact_fresh`: must not be `false`
- `token_source_kind`
- `token_count`
- `expected_token_count`
- `duration_ms`
- `latency_ms`
- `gateway_live_smoke_status`: must be `passed`
- `reservation_capacity_projection`
- `db_acquire_evidence`
- `db_acquire_result`
- `db_acquire_readback_count`
- `db_result_readback_count`
- `live_smoke_command`
- `secret_safe_raw_omission`: must be `true`
- `raw_material_present`: must be `false`
- `simulated_runner`: must be `false`
- `repo_fixture_only`: must be `false`
- `simulation_can_close_final_gap`: must be `true` only for real production artifacts

## Acceptance Matrix

The readback gate emits schema
`gateway_tpm_trusted_numeric_source_production_backend_evidence_acceptance_matrix_v1`.
It accepts an artifact for review only when all of these are true:

- artifact and runner command provenance are present
- backend kind/source match the operator-supplied flags
- runtime commit, current commit, and runtime marker agree with `-ExpectedCommit`
- artifact has `generated_at` and is not marked stale
- token source kind and token count match expected values
- duration and latency are numeric
- Gateway live smoke status is `passed`
- reservation projection is present
- DB acquire/result evidence and readback counts are present
- raw material is omitted

Repo fixtures and external-shape simulations may return
`production_evidence_accepted_for_review` only when they satisfy the matrix and
declare `simulation_can_close_final_gap=false`. That status proves the gate can
recognize the artifact shape; it cannot close E8.

Only a fresh `.tmp/gateway_tpm_production_backend/...` artifact from a
non-simulated, non-fixture production runner may return
`production_backend_live_smoke_passed`.

## Refusal Taxonomy

These states are always `production_ready_blocked`:

- `missing_opt_in`
- `unsafe_artifact_path`
- `missing_backend`
- `stale_runtime`
- `stale_artifact`
- `artifact_stale`
- `repo_fixture_only`
- `simulated_runner`
- `token_mismatch`
- `missing_live_smoke`
- `missing_db_acquire`
- `missing_db_result`
- `missing_duration`
- `duration_non_numeric`
- `raw_material_present`
- `commit_mismatch`
- `backend_kind_mismatch`

Only a fresh, non-simulated, non-fixture production artifact with matching runtime
commit, backend kind, token source kind/count, duration, reservation projection,
DB acquire/result evidence, and secret-safe readback can be
`production_backend_live_smoke_passed`.

`production_evidence_accepted_for_review` means the bounded artifact satisfies
the evidence shape but is either a repo simulation or still awaiting operator
review. `production_backend_live_smoke_passed` means the real production runner
artifact and live Gateway smoke evidence passed machine readback. Final E8 `[x]`
requires that live-smoke state plus reviewed closure evidence.

Final E8 `[x]` still requires reviewed live Gateway smoke/readback. Contract tests,
self-tests, and repo fixtures cannot substitute for real production evidence.
