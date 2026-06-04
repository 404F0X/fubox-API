# E11-007 Ledger Execute OpenAPI Semantic Validation Runbook

This runbook covers the non-default acceptance item for TODO lane
`E11-007-S14`: full OpenAPI semantic validation and generated-client contract
inspection for the Control Plane ledger adjustment/refund execute API.

The default repository gate remains lightweight and offline-friendly. For this
lane, prefer the wrapper
`scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1`: without
flags it runs only the lightweight contract gate, while explicit flags opt in to
semantic validators and generated-client checks. The stronger checks may require
Node, npm, Java, Python, or a preseeded tool cache.

## Scope

In scope:

- `examples/openapi_admin_skeleton.yaml`
- `POST /admin/ledger/adjustments/dry-run`
- `mode=execute` applied/idempotent responses
- `mode=execute_contract` refusal response
- `ledger_executor_summary_contract`
- `ledger_executor_summary`
- executor refusal and rollback summary contracts
- generated client/types that consume those schemas

Out of scope:

- Live Postgres smoke.
- Control Plane runtime requests.
- Admin UI visual or E2E verification.
- Billing-ledger runtime writer migration.
- Changing scripts or source code.

## Baseline Lightweight Gate

Always run the default repository gate first. It has no external service
dependency and should pass before using any external OpenAPI tooling.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_contract.ps1
```

Expected result:

- Exit code `0`.
- Output includes `Control Plane ledger adjustment OpenAPI contract validation passed.`

If this fails, do not proceed to semantic validator or client generation until
the OpenAPI skeleton is fixed.

The wrapper default mode must not download packages or generate clients. It
returns:

- exit `0` when the lightweight gate passes.
- exit `1` when the OpenAPI contract/schema shape fails.
- exit `2` only for an external blocker such as a missing shell needed to run
  the lightweight gate.

Wrapper env opt-ins are equivalent to the flags:

- `CONTROL_PLANE_LEDGER_OPENAPI_SEMANTIC=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_REDOCLY=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_GENERATOR_VALIDATE=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_CLIENT_GENERATION=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_TYPESCRIPT=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_TYPESCRIPT_FETCH=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_ALLOW_PACKAGE_DOWNLOAD=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_CLEAN=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SELF_TEST=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_EXTERNAL_BLOCKER=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SCHEMA_MISMATCH=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_CLIENT_MISMATCH=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SENSITIVE_OUTPUT_TAIL=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SENSITIVE_COMMAND_FAILURE=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_INSPECTION_PASS=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_MISSING_REQUIRED=1`

Optional path/env overrides:

- `CONTROL_PLANE_LEDGER_OPENAPI_TEMP_ROOT`
- `CONTROL_PLANE_LEDGER_OPENAPI_NPM_CACHE`

## Wrapper Failure-Path Self-Test

The wrapper has a script-level self-test that locks the exit-code semantics
without downloading npm packages, generating clients, opening DB connections, or
calling live services.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SelfTest
```

Expected result:

- Exit `0` for the self-test command when every child case behaves as expected.
- Child case `default lightweight path` returns exit `0`.
- Child case `simulated external blocker` returns exit `2`.
- Child cases `simulated schema mismatch` and `simulated client mismatch` return
  exit `1`.
- Child case `sensitive success output tail redacted` returns exit `0` after
  proving successful child output tails are redacted.
- Child case `sensitive failing command display redacted` returns exit `1` after
  proving failure output and displayed command lines are redacted.
- Child case `simulated generated-client inspection pass` returns exit `0`
  after proving a mock generated client contains the required ledger execute and
  executor summary fields while omitting secret-like output fields.
- Child case `simulated generated-client missing required field` returns exit
  `1`, proving generated-client contract drift is a mismatch, not a blocker.
- Child cases `temp root repo escape rejected` and `npm cache repo escape
  rejected` return exit `1`, proving custom paths cannot write outside the
  allowed repository roots.
- Child case `artifact cleanup removes temp root` returns exit `0` and removes a
  marker under `.tmp\ledger-adjustment-openapi-semantic`.
- Output remains secret-safe; it must not print raw Authorization/Cookie values,
  bearer tokens, credentials, raw operation keys, package credentials, API keys,
  or raw metadata.

The simulated switches can also be run directly when diagnosing the wrapper:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateExternalBlocker

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateSchemaMismatch

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateClientMismatch

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateSensitiveOutputTail

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateSensitiveCommandFailure

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateGeneratedClientInspectionPass

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateGeneratedClientMissingRequired
```

The first three direct simulated commands are expected to return `2`, `1`, and
`1` respectively after the lightweight gate passes. The sensitive-output command
returns `0`; the sensitive-command failure returns `1`. They prove wrapper
failure-path classification, path/output hardening, and redaction only. They do
not run Redocly, OpenAPI Generator, `openapi-typescript`, generated-client
inspection against real generated output, or any live Postgres checks. Do not
use simulated passes to close the real semantic/client-generation gap.

## Tool Availability And Blocker Semantics

Semantic validation and client generation are acceptance checks, not default PR
checks. Missing local tools or offline package download failures are external
blockers, not passes.

Record a blocker when any of these are unavailable:

- `node` or `npm` for `npx` based tools.
- Internet access or an internal npm mirror, unless the npm cache is already
  preseeded.
- Java 17+ for `@openapitools/openapi-generator-cli`.
- Python and pip only if using the optional Python validator path.

Use this wording in acceptance notes:

```text
[BLOCKED] E11-007-S14 OpenAPI semantic/client-generation validation - <missing tool or offline package cache>
```

Do not close the OpenAPI semantic/client-generation gap from a blocker. A schema
lint failure, validation error, or generated-client contract mismatch is a test
failure, not an external blocker.

The S16 wrapper uses the same exit semantics for opt-in checks:

- exit `0`: all requested checks passed.
- exit `1`: OpenAPI semantic validation failed or generated client contract
  inspection found a mismatch.
- exit `2`: missing `node`/`npm`/`java`, offline npm package cache, or package
  download/network blocker prevented requested external tooling from running.

Recommended preflight:

```powershell
node --version
npm --version
java -version
```

Optional Python preflight:

```powershell
python --version
python -m pip --version
```

## Semantic Validator Commands

Run at least one OpenAPI semantic validator. For release acceptance, prefer both
Redocly and OpenAPI Generator validation because they catch different classes of
schema drift.

### Redocly CLI

Wrapper opt-in, using the npm cache in offline mode by default:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -Redocly
```

Equivalent env opt-in:

```powershell
$env:CONTROL_PLANE_LEDGER_OPENAPI_REDOCLY = "1"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1
```

Online or preseeded npm-cache install/run:

```powershell
$env:npm_config_cache = ".tool-cache\npm"
npx --yes @redocly/cli lint examples\openapi_admin_skeleton.yaml
```

Expected result:

- Exit code `0`.
- No unresolved `$ref`.
- No OpenAPI 3.1 schema syntax errors.
- No warning that changes the ledger execute response shape or secret-safe
  fields.

If Redocly emits non-fatal style warnings outside the ledger execute schemas,
record them separately. They do not close this slice unless the ledger execute
schemas and refs are semantically valid.

### OpenAPI Generator Validate

This check requires Java.

Wrapper opt-in:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -OpenApiGeneratorValidate
```

```powershell
$env:npm_config_cache = ".tool-cache\npm"
npx --yes @openapitools/openapi-generator-cli validate `
  -i examples\openapi_admin_skeleton.yaml
```

Expected result:

- Exit code `0`.
- No unresolved refs.
- No incompatible nullable/enum schema errors for:
  - `LedgerAdjustmentExecuteResult`
  - `LedgerAdjustmentExecuteContractEnvelope`
  - `LedgerAdjustmentExecuteContract`
  - `LedgerAdjustmentExecutorSummaryContract`
  - `LedgerAdjustmentExecutorRefusalSummaryContract`
  - `LedgerAdjustmentExecutorRollbackSummaryContract`
  - `LedgerAdjustmentExecutorSummary`

To run both recommended semantic validators through the wrapper:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -Semantic
```

By default the wrapper uses npm offline mode so a missing package cache exits
`2` instead of attempting a download. To explicitly permit package download in a
controlled environment:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -Semantic -AllowPackageDownload
```

### Optional Python Validator

Use this path only when Python tooling is the local standard. It still requires
package availability through the public internet or an internal mirror.

```powershell
python -m pip install --user openapi-spec-validator pyyaml
python -m openapi_spec_validator examples\openapi_admin_skeleton.yaml
```

Expected result:

- Exit code `0`.
- No OpenAPI document/schema errors.

## Client Generation Commands

Generate into a temporary directory. Do not check generated output into this
repository unless a separate client-generation lane explicitly asks for it.

### Type Contract Generation

This is the lighter generated-type check and does not require Java.

Wrapper opt-in:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -OpenApiTypescript
```

```powershell
New-Item -ItemType Directory -Force .tmp\openapi | Out-Null
$env:npm_config_cache = ".tool-cache\npm"
npx --yes openapi-typescript examples\openapi_admin_skeleton.yaml `
  -o .tmp\openapi\admin-api.d.ts
```

Expected result:

- Exit code `0`.
- `.tmp\openapi\admin-api.d.ts` is generated.

### TypeScript Fetch Client Generation

This is the fuller client-generation check and requires Java.

Wrapper opt-in:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -TypescriptFetch
```

```powershell
Remove-Item -Recurse -Force .tmp\openapi-admin-typescript-fetch -ErrorAction SilentlyContinue
$env:npm_config_cache = ".tool-cache\npm"
npx --yes @openapitools/openapi-generator-cli generate `
  -i examples\openapi_admin_skeleton.yaml `
  -g typescript-fetch `
  -o .tmp\openapi-admin-typescript-fetch `
  --additional-properties=typescriptThreePlus=true,enumUnknownDefaultCase=true
```

Expected result:

- Exit code `0`.
- Generated models include ledger execute result, execute contract, executor
  summary contract, executor summary, refusal summary contract, and rollback
  summary contract.
- Generated API surface includes `POST /admin/ledger/adjustments/dry-run`.

To run both generated-client checks through the wrapper:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -ClientGeneration
```

To run all semantic and generated-client checks in one opt-in command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -Semantic -ClientGeneration
```

## Generated Client Contract Inspection

After generation, inspect the generated types/models. The exact file names vary
by generator, so use search rather than fixed paths.

```powershell
rg -n "LedgerAdjustmentExecuteResult|LedgerAdjustmentExecutorSummary|LedgerAdjustmentExecutorSummaryContract|LedgerAdjustmentExecutorRefusalSummaryContract|LedgerAdjustmentExecutorRollbackSummaryContract|ledgerExecutorSummary|ledger_executor_summary" .tmp\openapi .tmp\openapi-admin-typescript-fetch
```

The wrapper performs this inspection automatically after `-OpenApiTypescript`,
`-TypescriptFetch`, or `-ClientGeneration` succeeds. It inspects only the
generated ledger execute/executor summary model snippets, not unrelated auth or
request schemas elsewhere in a generated client.

The generated client must preserve all of these contracts:

- `LedgerAdjustmentExecuteResult` includes:
  - `mode`
  - `outcome` with `applied` and `idempotent`
  - `ledger_write`
  - `audit_log_write`
  - `ledger_executor_summary_contract`
  - `ledger_executor_summary`
  - `transaction_contract`
  - `ledger_entry`
  - `validated_plan`
- `LedgerAdjustmentExecuteContractEnvelope` includes:
  - `error`
  - `data.mode=execute_contract`
  - `data.validated_plan`
  - `data.ledger_executor_summary`
  - `data.execute_contract`
- `LedgerAdjustmentExecuteContract` includes:
  - `ledger_executor_summary_contract`
  - `ledger_executor_refusal_summary_contract`
  - `preflight_refusal_summary`
  - `transaction_contract.rollback_executor_summary_contract`
- `LedgerAdjustmentExecutorSummaryContract` includes:
  - `schema_version`
  - `response_field`
  - `operation_key_output`
  - `error_detail_output`
  - `dedupe_material_echoed`
  - `raw_metadata_echoed`
  - `credential_material_echoed`
- `LedgerAdjustmentExecutorSummary` includes:
  - `schema_version`
  - `executor`
  - `operation`
  - `outcome`
  - `committed`
  - `rolled_back`
  - `statement_count`
  - `executed_statement_count`
  - `refused_statement_count`
  - `total_rows_affected`
  - `final_statement_order`
  - `final_statement_kind`
  - `error_detail_output`
  - `row_count_mismatch`
  - `dedupe_material_echoed`
  - `omitted_material`
- `operation_key_output` and `error_detail_output` are modeled as omitted-marker
  strings, not as raw operation key or raw error fields.
- `dedupe_material_echoed`, `raw_metadata_echoed`,
  `credential_material_echoed`, and `raw_executor_error_detail_echoed` are
  modeled as false-only or boolean-safe fields where present.

The generated execute response and executor summary models must not add examples
or response fields that echo any of the following:

- raw idempotency key
- raw dedupe material
- raw metadata
- request payload/body
- Authorization or Cookie values
- credentials
- provider key material
- operation key
- raw executor error detail

Request schemas may still document rejected or accepted request inputs. This
inspection is specifically about execute responses, execute refusal responses,
and executor summary output.

Generated-client inspection mismatch examples:

- Missing `ledger_executor_summary` from `LedgerAdjustmentExecuteResult`.
- Missing `rollback_executor_summary_contract` from
  `LedgerAdjustmentExecuteContract.transaction_contract`.
- Missing statement/row-count fields from `LedgerAdjustmentExecutorSummary`.
- Adding response fields such as `idempotency_key`, `Authorization`, `Cookie`,
  `provider_key`, `operation_key`, `payload`, `body`, `raw_metadata`, `secret`,
  `credential`, `api_key`, or raw bearer/token material.

Any generated-client inspection mismatch exits `1`. Missing local tools,
offline package cache, or package download blockers exit `2`.

## Cleanup

Generated artifacts are temporary evidence. Remove them after recording the
acceptance result unless a separate lane asks to keep them.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -Clean

Remove-Item -Recurse -Force .tmp\openapi -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force .tmp\openapi-admin-typescript-fetch -ErrorAction SilentlyContinue
```

The wrapper writes generated artifacts under
`.tmp\ledger-adjustment-openapi-semantic` unless `-TempRoot` or
`CONTROL_PLANE_LEDGER_OPENAPI_TEMP_ROOT` is supplied. The temp root must stay
inside the repository and under repository `.tmp`; this keeps `-Clean` from
deleting source, `.git`, or another worker's files. The wrapper npm cache
defaults to `.tool-cache\npm`; if overridden with `-NpmCache` or
`CONTROL_PLANE_LEDGER_OPENAPI_NPM_CACHE`, it must stay inside repository
`.tool-cache` or `.tmp`.

External tool output and displayed command lines are redacted before printing.
The wrapper must not print raw Authorization/Cookie values, bearer tokens,
credentials, API keys, operation keys, package credentials, or raw metadata.

## Acceptance Record

Record all of the following when closing the semantic/client-generation gap:

- Repository commit.
- Validator commands and versions.
- Client generator command and version.
- Whether the npm cache was online, preseeded, or internal-mirror backed.
- Generated client target, for example `openapi-typescript` or
  `typescript-fetch`.
- Confirmation that ledger execute/executor summary fields listed above were
  present and secret-safe.
- Any non-ledger OpenAPI warnings that remain.

## TODO Closure Guidance

A clean semantic validator run plus successful client generation can close the
E11 OpenAPI semantic/client-generation gap for `E11-007-S14`.

It can also satisfy the remaining OpenAPI-only residual noted after `E11-007-S11`
and `E11-007-S13`, provided the generated client preserves the ledger execute
and executor summary contracts above.

It must not close these separate gaps:

- Live Postgres/concurrency smoke for `E11-007-S4`, `E11-007-S6`, or
  `E11-007-S8`.
- Success audit same-transaction evidence on a live migrated database.
- Admin UI execute flow E2E or visual verification.
- Billing-ledger runtime writer migration.
- Staging release approval or production readiness.
