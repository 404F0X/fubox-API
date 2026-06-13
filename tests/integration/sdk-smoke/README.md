# Gateway User Smoke Examples

Minimal user-facing examples for the OpenAI-compatible Gateway. They call:

- `GET /v1/models`
- `POST /v1/chat/completions` with `stream: false`
- `POST /v1/chat/completions` with `stream: true`

Both examples use an API key from the environment, inject a client trace id with
`x-ai-trace-id`, print the Gateway `x-request-id`, and redact obvious secret
material in error output.

## Environment

```powershell
$env:GATEWAY_BASE_URL = "http://127.0.0.1:8080"
$env:GATEWAY_API_KEY = "<user-api-key>"
$env:SMOKE_MODEL = "mock-gpt-4o-mini"
```

For the local seeded mock path, `GATEWAY_API_KEY` can be the dev test key
printed by the local setup flow. Do not commit real secrets.

## Node

```powershell
node .\tests\integration\sdk-smoke\gateway_user_smoke.mjs
```

## Python

```powershell
python .\tests\integration\sdk-smoke\gateway_user_smoke.py
```

Expected output is newline-delimited JSON, for example:

```json
{"step":"models","model_count":1,"models":["mock-gpt-4o-mini"]}
{"step":"chat_non_stream","request_id":"...","trace_id":"user-smoke-non-stream-...","response_id":"...","finish_reason":"stop"}
{"step":"chat_stream","request_id":"...","trace_id":"user-smoke-stream-...","sse_chunks":3,"done":true}
{"step":"gateway_user_mvp_summary","summary":{"schema":"fubox_gateway_user_mvp_summary.v1","artifact_kind":"local_mvp_sdk_smoke_summary","local_only":true,"production_evidence":false,"secret_safe":true,"model":"mock-gpt-4o-mini","gateway_models":{"endpoint":"/v1/models","status":"pass","model_count":1,"contains_expected_model":true},"gateway_requests":{"non_stream":{"endpoint":"/v1/chat/completions","stream":false,"status":"pass","request_id":"...","trace_id":"user-smoke-non-stream-..."},"stream":{"endpoint":"/v1/chat/completions","stream":true,"status":"pass","request_id":"...","trace_id":"user-smoke-stream-..."}},"readback":{"user_request_logs":{"status":"not_run_sdk_gateway_only","detail":"Run scripts/dev_login_check.ps1 for control-plane user request log readback."},"admin_request_detail":{"status":"not_run_sdk_gateway_only","detail":"Run scripts/dev_login_check.ps1 for admin request detail readback."}}}}
```

For the complete local MVP readback summary, run
`pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev_login_check.ps1`.
That script prints and writes `gateway_user_mvp_summary` with `/v1/models`,
non-stream/stream request ids, trace ids, user request log readback, and admin
request detail readback. The summary is local-only and is not production
evidence.
