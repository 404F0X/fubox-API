# Integration Smoke Verification

M0/E0 has a repeatable Docker Compose smoke check instead of relying on manual curl.

## Run

```powershell
.\scripts\compose_up.ps1
.\scripts\verify_compose_smoke.ps1
.\scripts\verify_db_schema.ps1
.\scripts\verify_sdk_smoke.ps1
```

The smoke script exits non-zero on failure and covers:

- Docker Compose service presence for postgres, redis, gateway, control-plane, worker, admin-ui, and mock-provider.
- Gateway `/healthz`, `/readyz`, and `/metrics`.
- Authenticated Gateway `/v1/models` contract probe.
- Gateway `POST /v1/chat/completions` non-stream forwarding with `Authorization: Bearer`, `stream=true` rejection, request validation, and provider 429 propagation.
- Gateway missing-Authorization probe. Strict mode explicitly hard-checks that missing auth is rejected with HTTP 401/403.
- Control-plane `/healthz` and `/readyz`.
- Admin UI root page.
- Mock provider `/healthz`, `/v1/models`, `/v1/chat/completions`, SSE streaming, and failure scenarios.

To point the script at non-default ports, pass explicit URLs:

```powershell
.\scripts\verify_compose_smoke.ps1 `
  -GatewayBaseUrl http://127.0.0.1:8080 `
  -ControlPlaneBaseUrl http://127.0.0.1:8081 `
  -MockProviderBaseUrl http://127.0.0.1:18080 `
  -AdminUiBaseUrl http://127.0.0.1:5173
```

To turn Gateway auth and `/v1/models` from compatibility probes into hard gates:

```powershell
.\scripts\verify_compose_smoke.ps1 -StrictGatewayContracts
```

Strict mode explicitly verifies:

- Authenticated `GET /v1/models` returns an OpenAI-compatible model list.
- Unauthenticated `POST /v1/chat/completions` returns HTTP 401/403.

Gateway routing has a separate smoke that verifies route resolution is persisted in `request_logs` and `provider_attempts`, and that unknown models are rejected when strict routing is enabled:

```powershell
.\scripts\verify_gateway_routing_smoke.ps1 -StrictGatewayRouting
```

## SDK Smoke

The Node OpenAI SDK smoke lives in `tests/integration/sdk-smoke` and does not reuse Admin UI dependencies.

```powershell
.\scripts\compose_up.ps1
.\scripts\verify_sdk_smoke.ps1
```

The script runs `npm ci` in the SDK smoke directory, then calls:

- `client.chat.completions.create(...)` with `stream: false`
- `baseURL = http://127.0.0.1:8080/v1`
- `apiKey = dev_test_key_123456789` by default

Environment overrides:

- `GATEWAY_BASE_URL`
- `GATEWAY_AUTH_TOKEN`
- `SMOKE_MODEL`
- `OPENAI_BASE_URL`
- `OPENAI_API_KEY`

By default it refuses non-local `OPENAI_BASE_URL` values so it cannot accidentally hit a real external provider.

User-facing Gateway examples for the API Console and README live next to the SDK smoke:

```powershell
$env:GATEWAY_BASE_URL = "http://127.0.0.1:8080"
$env:GATEWAY_API_KEY = "<user-api-key>"
$env:SMOKE_MODEL = "mock-gpt-4o-mini"
node .\tests\integration\sdk-smoke\gateway_user_smoke.mjs
python .\tests\integration\sdk-smoke\gateway_user_smoke.py
```

They call `/v1/models`, non-stream chat, and stream chat. Chat calls print the
Gateway `x-request-id` response header and the injected `x-ai-trace-id` so users
can find the matching request in the User Portal or Admin Requests view.

## Control Plane CRUD Smoke

This is a strict API contract smoke for provider/channel/model/association create+get CRUD coverage. It should pass against the local compose stack after migrations are applied.

```powershell
.\scripts\verify_control_plane_crud_smoke.ps1
```

Covered contract:

- `POST /admin/providers` then `GET /admin/providers/{id}`
- `POST /admin/channels` then `GET /admin/channels/{id}`
- `POST /admin/models` then `GET /admin/models/{id}`
- `POST /admin/model-associations` then `GET /admin/model-associations/{id}`

The baseline GET checks assert the returned JSON contains the id created by the preceding POST. Full collection/list, patch, and delete coverage is available with:

```powershell
.\scripts\verify_control_plane_crud_smoke.ps1 -IncludeFullCrud
```

Use strict full CRUD mode as the release gate for provider/channel/model/model-association CRUD:

```powershell
.\scripts\verify_control_plane_crud_smoke.ps1 -StrictFullCrud
```

## Mock Provider Contract

Use `deploy/mock-provider/server.mjs` with fixture names under `tests/fixtures/mock-provider`.

Supported OpenAI-compatible endpoints:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/chat/completions` with body field `"stream": true`

Supported scenarios:

- `200`
- `429`
- `5xx`
- `timeout`
- `eof`
- `invalid_sse`
- `large_chunk`

Scenarios can be selected through `?scenario=<name>` or request body fields `mock_scenario` / `scenario`.
The stream mode can be selected through `?stream=true` or request body field `"stream": true`.

E5 adapter and stream conformance tests should reuse these fixtures first, then add new fixture files when a new provider behavior is required.

## DB Schema Check

`scripts\verify_db_schema.ps1` does not reuse the running compose database. It starts a temporary PostgreSQL 16 container from a clean data directory, applies `db/migrations`, and verifies the key DB-level invariants needed by tenant isolation and billing ledger safety.
