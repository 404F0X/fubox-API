# Project Focus

This project is being pulled back to a readable New API style gateway MVP.

## What Matters Now

The current product must make the gateway request path obvious and reliable:

```text
Admin configures providers, models, routing, billing, import, users, settings
User registers, redeems credit, creates API key, and checks usage
Client calls Gateway OpenAI-compatible /v1/models and chat
User/Admin inspect balance, usage, request logs, request detail, trace summary, and ledger refs
```

Everything else is secondary until that path is simple to run, demo, debug, and modify.

The default local entry points are:

- `scripts/setup_local_mvp.ps1` for local/dev-only seed repair: admin, mock
  provider/channel/model, provider-key placeholder, and test key.
- `scripts/dev_up.ps1` for starting the local stack. It invokes the local MVP
  setup path.
- `scripts/dev_login_check.ps1` for the default live smoke: admin login, user
  register/login path, voucher redeem, key creation, `/v1/models`, mock chat,
  user request logs, and admin request detail readback.
- `scripts/write_network_security_config_example.ps1` for a documentation-only
  trusted proxy and IP allowlist YAML snippet that Settings can reference.

Local surfaces that say `pending`, `config-needed`, `not_connected`, or
`pending_scheduler` are acceptable current product states when they describe a
missing external provider, payment merchant, scheduler, or production credential.
Do not turn those states into release gates.

## Do Not Let These Drive The Mainline

- Paid beta evidence bundles.
- Production RC claims.
- Full commercial payment/order/invoice runtime.
- Subscription lifecycle.
- Enterprise OIDC/SAML.
- Agent task/status synchronization files.
- Contract artifacts that do not protect the active MVP path.

These can exist, but they should not dominate README, navigation, normal scripts, or feature priority.

## Current Order Of Work

1. Gateway request path first: `/v1/models`, mock chat, request log write, request detail readback.
2. Admin/User workflow second: Admin providers, models, routing, requests, billing, import, users, settings; User portal register/login, redeem, create API key, inspect models, call API console, inspect usage.
3. Evidence automation third: keep it opt-in and outside the default local MVP entry.

## Repository Hygiene Rules

- Root README stays short and runnable.
- Long status reports live in `docs/legacy/` or `docs/release/`.
- Normal development commands stay small: `setup_local_mvp.ps1`, `dev_up.ps1`, `dev_login_check.ps1`, focused smoke, test.
- Release gates are opt-in.
- `scripts/dev_login_check.ps1` is the default live smoke. Its failures should point to local environment, seed data, or an MVP feature gap.
- `scripts/write_network_security_config_example.ps1` is an example generator,
  not a production readiness check.
- New backend code should not expand `apps/gateway/src/main.rs` or `apps/control-plane/src/admin.rs`; split by feature boundary first.
- Frontend screens should prefer operational tables, filters, status chips, and drill-downs over explanatory panels.

## Refactor Priority

1. Split `apps/control-plane/src/admin.rs` into provider, model, key, billing, voucher, request-log, and distribution modules.
2. Split `apps/gateway/src/main.rs` into route handlers, provider proxy, routing runtime, billing guard, rate limit runtime, request logging, and prompt protection modules.
3. Move release/evidence scripts under a separate operational namespace.
4. Reduce Admin UI pages to AxonHub-like operator workflows: dashboard, channels/providers, models, requests/traces, API keys, users, billing.
