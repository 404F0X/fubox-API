# User Portal Standalone Console Handoff v2

This handoff defines the stable route and API boundary for rebuilding the user developer console as its own app shell, separate from the Admin workbench.

## Stable Entry Targets

Primary SPA entry:

- `/?mode=developer-console`

Accepted aliases:

- `/?mode=user`
- `/?mode=portal`
- `/?app=developer-console`
- `/?console=developer-console`
- `/#/developer-console`
- `/developer-console`
- `/portal`

The current legacy UI resolves these in `web/admin-ui/src/app/userPortalRoute.ts`. When a user portal target is present, `App.tsx` starts in user auth mode and skips Admin session restore, so an existing Admin cookie does not pull the user into the Admin workbench.

Use `mode=developer-console` for new links and docs. Keep `mode=user` and `mode=portal` as compatibility aliases only.

Runtime behavior:

- Standalone user routes must not call `GET /admin/auth/me` during boot.
- User login and registration submit only to `/auth/login` and `/auth/register`.
- After login or registration succeeds, the developer console uses the returned user session and user-scoped `/user/*` endpoints.
- Failed login or registration should show a generic secret-safe message, with a specific safe rate-limit message only for `login_rate_limited`.
- Switching back to the Admin workbench clears the standalone route marker and returns to the admin auth flow.

## Product Flow Status

Current compatibility UI supports the full local MVP product flow:

1. Register or log in through the standalone user route.
2. Load the first screen from `GET /user/home-summary`, with split-call fallback when the aggregate DTO is not available.
3. Redeem voucher credit and clear the voucher input after submit.
4. Create a user API key, show the secret once, then only show safe key metadata.
5. Run the API console against `/v1/models` and `/v1/chat/completions`.
6. Read back the resulting request by request id or trace id in user request history and trace summary.

The current implementation is a handoff-compatible product flow, not the final frontend architecture. Future rebuild work should start at `/?mode=developer-console`, keep the user shell separate from Admin session restore, and move this flow into a dedicated app shell with routeable sections for overview, voucher, keys, console, usage, and account policy.

Do not expose API key secrets after the one-time creation view, voucher raw codes after submit, `Authorization` headers, provider keys, raw payloads, prompt text, or provider payloads in any handoff copy or UI state.

## Frontend File Boundary

Current legacy implementation:

- Route handoff: `web/admin-ui/src/app/userPortalRoute.ts`
- App split point: `web/admin-ui/src/App.tsx`
- Admin router: `web/admin-ui/src/app/AppRouter.tsx`
- User portal UI: `web/admin-ui/src/components/UserPortalPanel.tsx`
- Typed API client: `web/admin-ui/src/api/client.ts`

Future rebuild target:

- A standalone user app shell should import the typed user DTOs and client functions from `client.ts`.
- Admin-only navigation, capabilities, request-detail internals, provider credentials, and billing admin operations should stay out of the user shell.
- `UserPortalPanel.tsx` can be treated as the compatibility implementation. Avoid moving its large UI into the Admin router.
- The first rebuild milestone is parity with the v2 product flow above: standalone auth, home-summary, voucher, key creation, API console, and request readback.

## User Shell Data Contract

The user developer console can be built from these secret-safe endpoints:

- Register: `POST /auth/register`
- Login: `POST /auth/login`
- Current user session: `GET /auth/me`
- Logout: `POST /auth/logout`
- Home summary: `GET /user/home-summary`
- Balance: `GET /user/balance?currency=USD&ledger_window_days=...`
- Models: `GET /user/models`
- User API keys: `GET /user/virtual-keys?status=active`, `POST /user/virtual-keys`, `POST /user/virtual-keys/{id}/disable`
- Request logs: `GET /user/request-logs?limit=...&model=...&status=...&request_id=...&trace_id=...`
- Trace readback: `GET /user/traces/{trace_id}?limit=...&window_days=...`
- Voucher redeem: `POST /user/vouchers/redeem`
- Subscription payment overview: `GET /user/subscription-payment`
- Password reset request: `POST /auth/password-reset/request`
- Email verification request: `POST /auth/email-verification/request`

Auth user DTOs include policy handoff fields on `user`: `terms_version`, `privacy_version`, `accepted_at`, and `pending_acceptance`. These are stable frontend fields. `pending_acceptance=true` means the account has no current accepted policy snapshot and the standalone shell should show an acceptance/update path before sensitive account actions.

Password reset and email verification requests return a stable secret-safe status DTO:

- `status`: `pending`, `config-needed`, or a future delivery state.
- `email_configured`: boolean.
- `delivery_mode`: `config-needed`, `queued`, `local-only`, or a future safe delivery mode.
- `expires_in_seconds`: token TTL when a token is actually created, otherwise `null`.
- `request_id`: safe operation reference, never a token.
- `audit`: optional safe metadata. It must not contain reset tokens, verification tokens, Authorization headers, API key secrets, raw payloads, or account-existence signals.

Runtime validation endpoints:

- Gateway model list: `GET /v1/models` with the user's virtual key secret.
- Gateway console call: `POST /v1/chat/completions` with the user's virtual key secret.

Prefer `GET /user/home-summary` for the first screen. If it is unavailable during local development, fall back to the split calls: balance, models, usage summary, and request logs.

## Secret-Safe UI Rules

Never render or persist:

- API key secrets after one-time display.
- Provider keys.
- `Authorization` headers, cookies, or credential headers.
- Raw voucher codes after submit.
- Raw idempotency keys.
- Prompt text, messages, raw request payloads, raw response bodies, provider payloads, or route policy blobs.

Allowed user-facing request-log fields include request id, trace id, client request id, model, status, HTTP status, token counts, cost, latency, safe error code/owner, redaction status, request hash, and response hash.

Voucher redeem should clear the input after every submit path. Receipts should show amount, currency, wallet/project refs, ledger entry id, credit grant id, voucher id, redemption id, and expiry fields only.

Subscription payment overview is local/demo until a merchant integration exists. Do not label `GET /user/subscription-payment` as production payment evidence.
