# TODO-14A E13 Request/Trace/Usage Bridge

Status: Historical E13 subclosure ready; superseded for current API distribution by TODO-14B live Admin/API metadata-only readback pass.

Generated: 2026-06-05.

## Scope

This slice connects E13 Prompt Protection request ids into the TODO-14
machine-readable readback contract. It does not modify Gateway, Control Plane
mutation logic, or Admin UI React code.

## Artifacts

- Source: `.tmp/prompt_protection_beta_closure_report.json`
- Bridge: `.tmp/request_trace_usage_e13_bridge_report.json`
- Optional live attempt: `.tmp/request_trace_usage_e13_bridge_live_readback.json`
- Launch-scoped bridge: `.tmp/launch/request_trace_usage_e13_bridge_report.json`
- Launch-scoped live gap readiness:
  `.tmp/launch/request_trace_usage_live_gap_readiness.json`
- Fixture: `tests/fixtures/request_trace_usage/e13_prompt_protection_explainability_bridge_contract.json`

## Commands

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_request_trace_usage_explainability.ps1 -SelfTest

pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_request_trace_usage_explainability.ps1 `
  -E13PromptProtectionOnly `
  -PromptProtectionEvidenceReportPath .tmp/prompt_protection_beta_closure_report.json `
  -OutputPath .tmp/request_trace_usage_e13_bridge_report.json
```

Optional live API readback:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_request_trace_usage_explainability.ps1 `
  -E13PromptProtectionOnly `
  -LiveApiReadback `
  -PromptProtectionEvidenceReportPath .tmp/prompt_protection_beta_closure_report.json `
  -OutputPath .tmp/request_trace_usage_e13_bridge_live_readback.json
```

Historical launch-scoped live gap readiness, which did not claim live readback:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_request_trace_usage_explainability.ps1 `
  -LiveGapReadiness `
  -OutputPath .tmp/launch/request_trace_usage_live_gap_readiness.json
```

## Result

The E13 bridge report passed offline contract mode:

- `schema=request_trace_usage_explainability_e13_bridge_v1`
- `overall_status=pass`
- `source_report_status=passed`
- `request_id_count=4`
- each request has endpoint/name and an opaque request id
- every request records prompt rejection expectations
- every request records `provider_attempts_count=0`
- every request records route/provider explainability expectations for
  `route_policy_version`, resolved provider/channel when routed, sanitized
  route snapshots, metadata-only provider attempts, and omitted provider secrets
- every request records guardrail expectations for prompt-protection
  `request_preflight` rejection without prompt material
- request-log expectations are hash-only/redacted
- audit/readback expectations require runtime-owned current Gateway provenance and Admin API readback
- usage/cost policy is metadata-only/no provider attempt, not paid billing
- ledger/balance expectations require request-id-linked metadata-only ledger rows
  and treat prompt-protection rejection as no debit / unchanged balance
- support fields are limited to request/trace/audit/route/provider/ledger/
  guardrail/usage/balance metadata and explicitly forbid raw prompt, raw
  request body, raw response body, credentials, and provider secrets
- `secret_safe_scan=pass`

Verifier hardening added on 2026-06-07:

- `-SelfTest` now also reads
  `tests/fixtures/request_trace_usage/e13_prompt_protection_explainability_bridge_contract.json`
  and checks the generated bridge against the fixture contract.
- The fixture readback check validates output schema, request count, required
  request fields, rejection fields, provider-attempt count, request-log
  redaction, usage/cost policy, ledger/balance policy, TODO-14 non-closure
  status, and the negative selftests.
- The self-test writes
  `.tmp/launch/request_trace_usage_operator_multisource_contract_selftest.e13_contract.json`
  with `status=pass` when the E13 fixture and bridge output remain aligned.

The optional live API readback attempt was bounded blocked without an admin
session handoff. That blocker did not invalidate the E13 offline bridge
contract and was not treated as a pass. Current API distribution status is
instead governed by `.tmp/launch/request_trace_usage_live_admin_api_readback.json`,
which passed metadata-only live Admin/API readback on 2026-06-07.

Historical live gap readiness added on 2026-06-07:

- `-LiveGapReadiness` reads existing E8/E11/E13 artifacts and writes only a
  launch-scoped readiness artifact.
- Current E8 request ids were found in
  `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` and
  `.tmp/launch/e8_gateway_rate_limit_launch_check.json`.
- Current E13 request ids were found in
  `.tmp/launch/request_trace_usage_e13_bridge_report.json`.
- E11 artifacts prove readback state, but the current artifacts inspected here
  do not expose request ids that can be joined for TODO-14 live readback.
- No admin session handoff was present in
  `CONTROL_PLANE_ADMIN_SESSION_TOKEN` or
  `PROMPT_PROTECTION_ADMIN_SESSION_TOKEN`; the script does not echo session
  material.
- Historical result:
  `overall_status=blocked_bypass_api_distribution`,
  `blocker_classification=runtime_input_required`,
  `api_distribution_blocker=false`, and `live_evidence_claimed=false`.
- Superseding result: `scripts/verify_request_trace_usage_explainability.ps1 -LiveApiReadback -OutputPath .tmp/launch/request_trace_usage_live_admin_api_readback.json`
  passed with 11 request ids, 5 traces, 1 wallet remaining-balance surface,
  `api_distribution_blocker=false`, no `/payload` call, and no token/header/raw
  body/provider-secret output.

## External Runtime Inputs

This slice only closed the E13 prompt-protection rejection bridge. It did not
invent or simulate missing trusted-user request ids for other lanes.

- E8/E11/E13 request ids have since been joined by TODO-14B live readback for
  the current API distribution troubleshooting scope.
- Remaining work is UI/browser polish and broader Production RC observability
  hardening.

## Remaining TODO-14 Work

TODO-14 is pass for the current trusted-user voucher-backed API distribution
troubleshooting requirement. Remaining owners should not reopen API
distribution on this historical bridge. Follow-up work is:

- Admin UI/browser polish for request detail and trace workflows.
- Broader audit/observability hardening for Production RC.
