# fubox API

Self-hosted New API style AI gateway: admin configures upstream providers and models, users redeem credit, create API keys, call an OpenAI-compatible gateway, and inspect usage.

Treat this README as the local developer entry point. Historical status notes are preserved under `docs/legacy/`.

## Current Product Line

The active MVP is:

```text
Admin console -> providers, models, routing, requests, billing, import, users, settings
User portal   -> register/login, redeem credit, create API key, inspect usage
Gateway       -> /v1/models and /v1/chat/completions
Ops view      -> request logs, request detail, trace summary, balance and ledger readback
```

Deferred until the gateway/user flow is clean:

- Real payment, order, invoice runtime.
- Subscription scheduler/lifecycle.
- Enterprise OIDC/SAML real IdP runtime. Current SAML has a fixture-safe ACS XML signature parser executor readback only: no raw XML/SAMLResponse, no network, no session creation.
- Production rollout packs.
- Agent coordination/TODO evidence churn.

Current local product states such as `pending`, `config-needed`,
`not_connected`, and `pending_scheduler` are expected when an external
provider, merchant, scheduler, or production credential has not been connected.
They should point to the next local configuration step, not block the local MVP
loop.

## Run Locally

Prerequisites:

- Docker Desktop with Compose.
- PowerShell 7+.
- Rust and Node/npm for contributor checks.

Start the local stack:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_local_mvp.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev_up.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev_login_check.ps1
```

`setup_local_mvp.ps1` is the local/dev-only seed path. It creates or repairs the
admin account, mock provider/channel/model setup, provider-key placeholder, and
test user key needed by the demo flow. `dev_up.ps1` also calls this setup path,
so running it directly is useful when you want to refresh seed data without
restarting the full stack.

`dev_login_check.ps1` exercises the local MVP path: admin login, user
registration, user balance, admin-issued test voucher, user voucher redeem, user
API key creation, `/v1/models`, mock chat through the gateway, user request log
readback, and admin request detail readback for non-stream and stream chat. It
prints the gateway request id and injected trace id for the chat requests. A
failure means the local stack, seed data, or one of those MVP features needs
attention; it is not a release blocker.

By default, the local dev scripts keep transient tool state inside the repo:
`TEMP`/`TMP` use `.tmp`, npm uses `.tool-cache/npm`, and Cargo uses
`target-codex`. Set those environment variables before running the scripts to
override the defaults.

If a host port is already used by another local service, set the matching
environment variable before running `dev_up.ps1`: `POSTGRES_HOST_PORT`,
`REDIS_HOST_PORT`, `GATEWAY_HOST_PORT`, `CONTROL_PLANE_HOST_PORT`,
`ADMIN_UI_HOST_PORT`, or `MOCK_PROVIDER_HOST_PORT`. `dev_up.ps1` prints a
matching `dev_login_check.ps1` command with the resolved URLs after startup.

Default local endpoints:

| Service | URL |
|---|---|
| Admin UI | `http://127.0.0.1:5173` |
| Gateway | `http://127.0.0.1:8080` |
| Control Plane | `http://127.0.0.1:8081` |
| Mock Provider | `http://127.0.0.1:18080` |

Quick health checks:

```powershell
Invoke-RestMethod http://127.0.0.1:8080/readyz
Invoke-RestMethod http://127.0.0.1:8081/readyz
Invoke-WebRequest http://127.0.0.1:5173 -UseBasicParsing
```

Try the gateway:

```powershell
$headers = @{ Authorization = "Bearer dev_test_key_123456789" }
Invoke-RestMethod -Headers $headers -Uri http://127.0.0.1:8080/v1/models
Invoke-RestMethod -Method Post -Headers $headers -ContentType "application/json" `
  -Uri http://127.0.0.1:8080/v1/chat/completions `
  -Body '{"model":"mock-gpt-4o-mini","messages":[{"role":"user","content":"ping"}]}'
```

Minimal Node and Python user examples are in
`tests/integration/sdk-smoke/README.md`. They use `GATEWAY_API_KEY` from the
environment, call `/v1/models`, non-stream chat, and stream chat, then print the
Gateway request id and injected trace id for portal readback.

Network security config examples for `server.trusted_proxy_allowlist`, profile
IP allowlists, and virtual key IP allowlists can be generated with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\write_network_security_config_example.ps1
```

The default output is
`.tmp/network-security/network_security_config_example.yaml`. Add `-PrintOnly`
to print the YAML to stdout without creating or overwriting a file. The snippet
uses documentation CIDRs only and is a Settings UI/local deployment reference,
not a production gate; do not put production IPs, provider keys, Authorization
headers, API key secrets, or other secrets into the example.

Current UI paths to verify after login:

- Admin: Dashboard, Providers, Models, Routing, Requests, Billing, Import,
  Users, Settings.
- User portal: balance, voucher redeem, API keys, model list, API console,
  usage and request detail.
- Gateway: OpenAI-compatible `GET /v1/models` and
  `POST /v1/chat/completions` against the local mock provider. Chat completion
  responses expose `x-request-id`; use that id in request logs to inspect the
  secret-safe OpenAI compatibility handoff (`finish_reason`, provider usage
  presence, recorded token booleans, and response hash), not raw prompts or
  provider payloads.

## Common Commands

```powershell
.\scripts\setup_local_mvp.ps1
.\scripts\dev_up.ps1 -DryRun
.\scripts\compose_up.ps1
.\scripts\verify_compose_smoke.ps1
.\scripts\test.ps1
```

Importer and release verifiers are opt-in tools for their specific slices. They
are not the normal local MVP loop.

## Code Map

| Path | Purpose |
|---|---|
| `apps/gateway` | Data plane, OpenAI-compatible routes, provider proxying, routing, billing guard. |
| `apps/control-plane` | Admin and user APIs. |
| `apps/worker` | Async jobs and observability workers. |
| `crates/*` | Shared Rust libraries for adapters, routing, billing, config, db, auth, observability. |
| `web/admin-ui` | Admin console and user portal. |
| `db/migrations` | Postgres schema. |
| `deploy/docker-compose` | Local stack. |
| `scripts` | Development, smoke, verifier, and release helper scripts. |
| `docs/legacy` | Previous long-form status/evidence documents retained for reference. |

## Keep It Understandable

The project should optimize for the shortest path from product intent to running behavior:

1. Gateway request path first.
2. Admin/user setup workflow second.
3. Evidence and release automation third.

Before adding new gates or artifacts, check `docs/PROJECT_FOCUS.md`.
