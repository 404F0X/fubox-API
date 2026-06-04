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
- `CONTROL_PLANE_LEDGER_OPENAPI_CACHE_PROBE=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_COMMAND_MATRIX=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_CLEAN=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SELF_TEST=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_EXTERNAL_BLOCKER=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SCHEMA_MISMATCH=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_CLIENT_MISMATCH=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SENSITIVE_OUTPUT_TAIL=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SENSITIVE_COMMAND_FAILURE=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_INSPECTION_PASS=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_MISSING_REQUIRED=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_READINESS_MISSING_OUTPUT=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_READINESS_STALE_MARKER=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_READINESS_UNSAFE_TARGET=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SEMANTIC_EVIDENCE_PASS=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SEMANTIC_EVIDENCE_FAILURE=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SEMANTIC_EVIDENCE_BLOCKER=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_TOOL_PREFLIGHT_BLOCKER=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_CACHE_PROBE=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_REAL_EXECUTION_EVIDENCE_PASS=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_REAL_EXECUTION_EVIDENCE_FAILURE=1`
- `CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_REAL_EXECUTION_EVIDENCE_BLOCKER=1`

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
- Child case `default lightweight path clears stale evidence` returns exit `0`,
  removes a pre-existing stale evidence report, and does not write a new
  evidence report.
- Child case `simulated external blocker` returns exit `2`.
- Child cases `simulated schema mismatch` and `simulated client mismatch` return
  exit `1`.
- Child case `sensitive success output tail redacted` returns exit `0` after
  proving successful child output tails are redacted.
- Child case `sensitive failing command display redacted` returns exit `1` after
  proving failure output and displayed command lines are redacted.
- Child case `simulated generated-client inspection pass` returns exit `0`
  after proving a mock generated client has a current readiness marker and
  contains the required ledger execute and executor summary fields while
  omitting secret-like output fields.
- Child case `simulated generated-client missing required field` returns exit
  `1`, proving generated-client contract drift is a mismatch, not a blocker.
- Child case `simulated generated-client readiness missing output` returns exit
  `1`, proving absent generated output cannot pass readiness.
- Child case `simulated generated-client readiness stale marker` returns exit
  `1`, proving a marker bound to an old OpenAPI fixture cannot pass readiness.
- Child case `simulated generated-client readiness unsafe target` returns exit
  `1`, proving generated-client targets outside validated `TempRoot` are
  rejected before inspection.
- Child case `command matrix dry-run` returns exit `0`, prints the real opt-in
  command matrix, and does not write evidence or run npm/java tools.
- Child case `simulated cache/tool availability probe` returns exit `2` and
  writes bounded evidence covering available/missing tools, offline cache
  present/missing, download-disabled state, per-command blocker classification,
  and duration fields without running validators/generators.
- Child case `simulated package download opt-in evidence` returns exit `2` and
  writes bounded package-provenance evidence with `package_download_allowed=true`
  without downloading packages or running validators/generators.
- Child case `simulated real-tool execution evidence pass` returns exit `0` and
  writes execution-shaped evidence with real-command fields but simulated
  provenance, so it cannot close the real gap.
- Child case `simulated real-tool execution evidence failure` returns exit `1`
  and writes execution-shaped failure evidence.
- Child case `simulated real-tool execution evidence blocker` returns exit `2`
  and writes execution-shaped blocker evidence.
- Child case `simulated semantic validator evidence pass` returns exit `0` and
  writes a bounded evidence report with classification `pass`.
- Child case `simulated semantic validator evidence failure` returns exit `1`
  and writes a bounded evidence report with classification `failure`.
- Child case `simulated semantic validator evidence blocker` returns exit `2`
  and writes a bounded evidence report with classification `blocker`.
- Child case `simulated real-tool preflight blocker evidence` returns exit `2`
  and writes a bounded evidence report with a blocked tool preflight, explicit
  package/cache state, and bounded duration fields.
- Child cases `temp root repo escape rejected`, `source temp root rejected`,
  `git temp root rejected`, and `npm cache repo escape rejected` return exit
  `1`, proving custom paths cannot write or clean outside the allowed temp/tool
  roots.
- Child case `artifact cleanup removes wrapper-owned artifacts` returns exit
  `0`, removes stale evidence and wrapper-owned generated artifacts under
  `.tmp\ledger-adjustment-openapi-semantic`, and preserves a non-owned marker in
  the temp root.
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

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateGeneratedClientReadinessMissingOutput

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateGeneratedClientReadinessStaleMarker

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateGeneratedClientReadinessUnsafeTarget

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -CommandMatrix

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateCacheProbe

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateCacheProbe -AllowPackageDownload

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateRealExecutionEvidencePass

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateRealExecutionEvidenceFailure

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateRealExecutionEvidenceBlocker

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateSemanticEvidencePass

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateSemanticEvidenceFailure

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateSemanticEvidenceBlocker

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateToolPreflightBlocker
```

The first three direct simulated commands are expected to return `2`, `1`, and
`1` respectively after the lightweight gate passes. The sensitive-output command
returns `0`; the sensitive-command failure returns `1`. The generated-client
inspection commands return `0` and `1`. The generated-client readiness commands
return `1` for missing output, stale marker, and unsafe target. The command
matrix dry-run returns `0`. The simulated cache probe returns `2`. The semantic
evidence commands return `0`, `1`, and `2`. The simulated real execution
evidence commands return `0`, `1`, and `2`. The tool-preflight blocker command
returns `2`. They prove wrapper failure-path classification, generated-client
readiness gating, command matrix coverage, cache/tool availability evidence,
package download opt-in provenance, real-execution evidence shape, bounded
evidence lifecycle, path/output hardening, preflight/performance evidence
shape, and redaction only. They do not run Redocly, OpenAPI Generator,
`openapi-typescript`, generated-client inspection against real generated output,
download packages, or any live Postgres checks. Do not use simulated passes,
cache-probe blockers, simulated execution evidence, simulated download opt-in
evidence, or the matrix dry-run to close the real semantic/client-generation
gap.

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

## Opt-In Evidence Report

When an external semantic validator or client generator is explicitly requested,
the wrapper writes bounded evidence to:

```text
.tmp\ledger-adjustment-openapi-semantic\ledger-adjustment-openapi-semantic-evidence.json
```

The report is not written by the default lightweight path. On startup the
wrapper removes any stale report at this path before running the lightweight
gate, so a default run cannot be mistaken for fresh validator evidence. The
report is written only for real opt-in external checks and for the simulated
semantic evidence self-test paths.

The report schema is `ledger_openapi_semantic_evidence.v1` and contains only
bounded fields:

- `report_type`
- `outcome`: `pass`, `failure`, or `blocker`
- `checked_schema`: repo-relative OpenAPI skeleton path
- `repo_commit`: the current short git commit, or `unavailable`
- `repo_commit_status`: `resolved` or `unavailable`
- `provenance_mode`: `real`, `simulated`, or `mixed`
- `generated_at_utc`
- `command_summary`: redacted wrapper invocation summary
- `openapi_fixture`: path, SHA-256, size, last-write time, and status for the
  checked OpenAPI skeleton
- `evidence[]`

Each evidence record contains:

- `kind`: `semantic_validator` or `client_generation`
- `label`
- `provenance_mode`: `real` for external validators/client generators or
  `simulated` for self-test fixtures
- `tool`
- `tool_path`: bounded executable path summary, for example an outside-repo
  filename marker rather than a full user path
- `tool_version`
- `package`
- `package_list`: comma-separated required package list
- `package_version`: bounded package/tool version or cache-entry marker
- `package_provenance`: `preseeded_repo_cache`, `offline_repo_cache_missing`,
  `download_opt_in`, `simulated`, `not_applicable`, or `unknown`
- `package_cache_path`: bounded repo-relative npm cache path
- `package_cache_status`: `download_allowed`, `offline_repo_cache_present`,
  `offline_repo_cache_missing`, `simulated`, or `not_applicable`
- `package_cache_bytes`: bounded cache-size summary
- `package_download_allowed`
- `package_probe_duration_ms`: bounded cache/download availability duration
- `preflight_status`: `passed`, `blocked`, `simulated`, or `not_run`
- `execution_mode`: `real_tool_execution`, `cache_probe`, `command_matrix`,
  `simulated`, or `not_run`
- `real_command_executed`
- `readiness_marker_status`: `current`, `missing`, `stale`, `pending`, or
  `not_applicable`
- `closure_eligible`
- `checked_schema`
- `classification`: `pass`, `failure`, or `blocker`
- `exit_code`
- `duration_ms`: bounded command duration for the version probe, validator, or
  generator command represented by the record
- `command`: redacted bounded command summary
- `output_tail`: up to eight redacted bounded lines
- `failure_reason`
- `blocker_reason`

The report must not include raw Authorization/Cookie values, bearer tokens,
credentials, package tokens, API keys, raw operation keys, raw metadata, payload
or body data, or raw executor details. The self-test validates the report field
allowlist, checked schema, repo commit marker, generated-at timestamp, fixture
fingerprint, command summary, tool path, version/cache preflight status,
package list, package version/provenance marker, cache path safety, cache size
summary, package probe duration, execution mode, real-command marker,
generated-client readiness marker status, closure eligibility, duration bounds,
output-tail bounds, classification presence, provenance marker, and secret-safe
redaction.

Interpret report outcomes as follows:

- `pass`: every requested opt-in validator/client generator completed and the
  generated-client inspection contract passed where applicable.
- `failure`: a semantic validator failed, generated-client contract inspection
  failed, or schema/client output drifted. This is exit `1`.
- `blocker`: local tools, Java, npm package cache, network, or package-download
  availability prevented requested opt-in tooling from running. This is exit
  `2`.

Real-tool preflight/performance evidence:

- Real opt-in checks validate local `node` and `npm`; OpenAPI Generator paths
  also validate `java`.
- Missing local tools produce a `blocker` evidence record with
  `preflight_status=blocked`, `classification=blocker`, and exit `2`.
- Available local tools are recorded with safe bounded `tool_path` values. Paths
  outside the repository are represented by filename-only outside-repo markers.
- Package/cache state is explicit. Offline mode records whether the repository
  npm cache is present or missing; `-AllowPackageDownload` records
  `download_allowed`.
- Package provisioning/download provenance is explicit. Evidence records include
  `package_list`, `package_version`, `package_provenance`,
  `package_cache_path`, `package_cache_bytes`, `package_download_allowed`, and
  `package_probe_duration_ms`.
- Version probes and requested validator/generator commands record bounded
  `duration_ms`. The self-test locks that duration is numeric and bounded, but
  it does not run real npm tools.

Package cache provisioning/download evidence:

- The default wrapper path never downloads packages and never runs real npm
  validators/generators.
- The required package list is fixed to `@redocly/cli`,
  `@openapitools/openapi-generator-cli`, and `openapi-typescript`.
- The npm cache must stay under repository `.tool-cache` or `.tmp`; repo-external
  paths, source paths, and `.git` paths are refused before use.
- Preseeded cache evidence uses `package_provenance=preseeded_repo_cache`,
  `package_cache_status=offline_repo_cache_present`, a bounded
  `package_cache_bytes` summary, and a bounded `package_probe_duration_ms`.
- Missing offline cache evidence uses
  `package_provenance=offline_repo_cache_missing`,
  `package_cache_status=offline_repo_cache_missing`, and `classification=blocker`.
- `-AllowPackageDownload` or
  `CONTROL_PLANE_LEDGER_OPENAPI_ALLOW_PACKAGE_DOWNLOAD=1` is the only allowed
  download opt-in. Cache probes with this flag record
  `package_provenance=download_opt_in` and `package_download_allowed=true`, but
  still do not download packages or run validators/generators.
- Real package download can occur only when `-AllowPackageDownload` is combined
  with a real validator or generator flag such as `-Redocly`,
  `-OpenApiGeneratorValidate`, `-OpenApiTypescript`, or `-TypescriptFetch`.
- npm output tails are bounded and redacted. They must not include package
  tokens, registry credentials, Authorization/Cookie values, bearer tokens, API
  keys, raw operation keys, raw metadata, payload, or body data.

Real-tool execution evidence:

- `execution_mode=real_tool_execution` is required for real Redocly, OpenAPI
  Generator, `openapi-typescript`, and `typescript-fetch` opt-in executions.
- `real_command_executed=true` is required only after the requested external
  command actually ran. Tool/cache preflight blockers keep this field `false`.
- `duration_ms` records the real command runtime for the evidence record, not
  just a wrapper-level timestamp.
- `classification=pass` means the real command exited successfully and the
  wrapper-specific post-checks passed where applicable.
- `classification=failure` means the real command ran but schema validation,
  generated-client readiness, generated-client inspection, or contract checks
  failed.
- `classification=blocker` means the command could not be run because required
  tooling or package/cache availability was missing.
- Generated-client evidence must have `readiness_marker_status=current` before
  it can be used as acceptance evidence.
- `closure_eligible=true` is allowed only for `provenance_mode=real`,
  `execution_mode=real_tool_execution`, `real_command_executed=true`,
  `classification=pass`, and a current readiness marker when the evidence kind
  is `client_generation`.

Do not close the semantic validator gap from a report with outcome `blocker`.
Do not close it from a simulated or mixed-provenance report; simulated evidence
proves wrapper classification and redaction only.

Fixture freshness guidance:

- The report's `repo_commit` should match the commit under review. If it is
  `unavailable`, record why git provenance could not be resolved before using
  the report as acceptance evidence.
- The report's `openapi_fixture.path` must be
  `examples\openapi_admin_skeleton.yaml`.
- The report's `openapi_fixture.sha256`, `size_bytes`, and `last_write_utc`
  bind the validator result to the exact OpenAPI skeleton bytes checked at run
  time. If the skeleton changes after the report is written, rerun the opt-in
  validator/client-generation command and use the newer report.
- A stale report, a report produced by a default lightweight run, or a report
  with `provenance_mode=simulated` cannot close the real semantic validator
  gap.

Evidence lifecycle contract:

- The evidence report path is derived from the already validated `TempRoot`.
- `TempRoot` must be inside the repository and under `.tmp`.
- Source paths, `.git`, repo-external paths, and other non-temp locations are
  refused before any write or clean operation.
- Evidence and cleanup path output is bounded to repo-relative paths or an
  outside-repo marker.
- `-Clean` removes stale evidence and known wrapper-owned artifacts only; it
  must not remove arbitrary files another worker placed under the temp root.
- The command summary stores only bounded flags, repo-relative paths, requested
  checks, and simulated mode names. It must not include Authorization, Cookie,
  package credentials, raw operation keys, raw metadata, payload, or body data.

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

## Opt-In Command Matrix Dry-Run

Before running real validators or generators, record the command matrix. This
dry-run does not download packages, run npm tools, generate clients, or write an
evidence report.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -CommandMatrix
```

The matrix must include exactly these real opt-in entries:

| Entry | Flag | Required tools | Package | Cache policy | Expected exits |
| --- | --- | --- | --- | --- | --- |
| Redocly semantic validation | `-Redocly` | `node`, `npm` | `@redocly/cli` | offline repo cache by default; `-AllowPackageDownload` only when explicit | `0` pass, `1` schema failure, `2` tool/cache blocker |
| OpenAPI Generator validate | `-OpenApiGeneratorValidate` | `node`, `npm`, `java` | `@openapitools/openapi-generator-cli` | offline repo cache by default; `-AllowPackageDownload` only when explicit | `0` pass, `1` schema failure, `2` tool/cache blocker |
| openapi-typescript generation | `-OpenApiTypescript` | `node`, `npm` | `openapi-typescript` | offline repo cache by default; `-AllowPackageDownload` only when explicit | `0` pass with readiness marker, `1` generated-client mismatch, `2` tool/cache blocker |
| typescript-fetch generation | `-TypescriptFetch` | `node`, `npm`, `java` | `@openapitools/openapi-generator-cli` | offline repo cache by default; `-AllowPackageDownload` only when explicit | `0` pass with readiness marker, `1` generated-client mismatch, `2` tool/cache blocker |

Each matrix row must document these evidence fields before a real opt-in run is
accepted:

- `tool_path`
- `tool_version`
- `package_list`
- `package_version`
- `package_provenance`
- `package_cache_path`
- `package_cache_status`
- `package_cache_bytes`
- `package_download_allowed`
- `package_probe_duration_ms`
- `preflight_status`
- `duration_ms`
- `command`
- `output_tail`
- `readiness_marker` for generated-client rows

The safe command examples must use the wrapper path and scoped flags only. They
must not contain Authorization, Cookie, bearer tokens, package credentials,
operation keys, raw metadata, payload, or body data.

The command matrix closes only the blocker-audit/readiness contract. It cannot
close the real semantic/client-generation gap because it intentionally does not
run real external tools.

## Cache/Tool Availability Probe

Use the cache probe when you need to know whether the current machine or CI
runner is ready to attempt the real opt-in validators/generators. The probe is
still lightweight: it does not run Redocly, OpenAPI Generator validation,
`openapi-typescript`, `typescript-fetch`, client generation, or package
download.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -CacheProbe
```

The probe performs only these checks:

- `node --version`
- `npm --version`
- `java -version`
- offline `npm cache ls <package> --cache .tool-cache\npm --offline` for:
  - `@redocly/cli`
  - `@openapitools/openapi-generator-cli`
  - `openapi-typescript`

Expected evidence fields per command:

- `tool_path`: safe bounded path summary for `node`, `npm`, and `java` where
  required
- `tool_version`: bounded version marker
- `package_list`: fixed required npm package list
- `package_version`: bounded cache-entry or tool-version marker
- `package_provenance`: `preseeded_repo_cache`, `offline_repo_cache_missing`,
  or `download_opt_in`
- `package_cache_path`: bounded path under repository `.tool-cache` or `.tmp`
- `package_cache_status`: `offline_repo_cache_present`,
  `offline_repo_cache_missing`, or `download_allowed`
- `package_cache_bytes`: bounded cache-size summary
- `package_download_allowed`: normally `false`; `true` only when
  `-AllowPackageDownload` is explicitly supplied
- `package_probe_duration_ms`: bounded npm cache probe duration
- `preflight_status`: `passed` or `blocked`
- `classification`: `pass` or `blocker`
- `duration_ms`: bounded probe duration
- `output_tail`: bounded and redacted probe output

If any required tool or offline package cache is unavailable, the probe writes a
blocker evidence report and exits as externally blocked. That result is useful
for acceptance notes, but it does not close the real semantic/client-generation
gap.

The probe output and evidence report must remain secret-safe. It must not print
Authorization/Cookie values, bearer tokens, package credentials, API keys, raw
operation keys, raw metadata, payload, or body data.

To record explicit download opt-in policy without downloading packages or
running heavy tools:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -CacheProbe -AllowPackageDownload
```

This command records `package_download_allowed=true`,
`package_provenance=download_opt_in`, cache path safety, package list, cache
size, and probe duration. It may still exit `2` if required local tools are
missing. It is provisioning/download policy evidence only; it does not close the
real semantic/client-generation pass gap.

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
`-TypescriptFetch`, or `-ClientGeneration` succeeds. Before inspection, the
wrapper runs a generated-client readiness gate. It inspects only the generated
ledger execute/executor summary model snippets, not unrelated auth or request
schemas elsewhere in a generated client.

Generated-client readiness requires all of the following:

- The generated output target is under the validated wrapper `TempRoot`.
- The generated output exists.
- A wrapper-owned
  `.ledger-openapi-generated-client-readiness.json` marker exists beside the
  generated output.
- The readiness marker has schema
  `ledger_openapi_generated_client_readiness.v1`.
- The marker is bound to the current `examples\openapi_admin_skeleton.yaml`
  SHA-256.
- The marker records bounded `generated_at_utc`, `target`, `tool`,
  `provenance_mode`, package/cache state, package-download flag, and
  `duration_ms`.
- The generated output preserves the required ledger execute/executor summary
  fields and omits secret-like response fields.

Readiness failure classes:

- Missing generated output is a mismatch and exits `1`.
- Missing or stale readiness marker is a mismatch and exits `1`.
- Unsafe target path outside `TempRoot` is a mismatch and exits `1`.
- Missing local tools or offline package/cache blockers before generation are
  external blockers and exit `2`.

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

Any generated-client readiness or inspection mismatch exits `1`. Missing local
tools, offline package cache, or package download blockers before generated
output is produced exit `2`.

This readiness gate is not the final production client acceptance. Passing the
simulated readiness self-test closes only the readiness-gate contract. Real
generated-client production acceptance still requires an explicit opt-in run of
`-OpenApiTypescript`, `-TypescriptFetch`, or `-ClientGeneration` in an
environment with the required tools and package/cache access.

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
inside the repository and under repository `.tmp`; source directories, `.git`,
repo-external paths, and other non-temp paths are refused. The wrapper npm cache
defaults to `.tool-cache\npm`; if overridden with `-NpmCache` or
`CONTROL_PLANE_LEDGER_OPENAPI_NPM_CACHE`, it must stay inside repository
`.tool-cache` or `.tmp`.

`-Clean` is intentionally scoped. It removes only wrapper-owned artifacts under
the validated temp root:

- `ledger-adjustment-openapi-semantic-evidence.json`
- wrapper-generated `openapi-typescript` and `typescript-fetch` directories
- generated-client readiness markers under wrapper-generated output directories
- wrapper self-test artifact directories and markers

It does not delete source files, `.git`, repo-external paths, non-temp paths, or
arbitrary files that are not on the wrapper-owned artifact allowlist. If the temp
root is empty after those removals, the wrapper may remove the empty directory.

External tool output and displayed command lines are redacted before printing.
The wrapper must not print raw Authorization/Cookie values, bearer tokens,
credentials, API keys, operation keys, package credentials, or raw metadata.

## Acceptance Record

Record all of the following when closing the semantic/client-generation gap:

- Repository commit.
- Validator commands and versions.
- Client generator command and version.
- Evidence report path, outcome, `repo_commit`, `provenance_mode`, and
  `generated_at_utc`.
- OpenAPI fixture `sha256`, `size_bytes`, and `last_write_utc`.
- Whether the npm cache was online, preseeded, or internal-mirror backed.
- Package cache provisioning/download evidence: required package list,
  package version/provenance marker, bounded cache path, `package_cache_bytes`,
  `package_download_allowed`, and `package_probe_duration_ms`.
- Tool preflight status, safe tool path summary, package/cache status, and
  bounded `duration_ms` for each opt-in evidence record.
- Real execution evidence fields for each opt-in command:
  `execution_mode`, `real_command_executed`, `duration_ms`,
  `readiness_marker_status`, `closure_eligible`, and exit classification.
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
