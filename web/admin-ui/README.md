# AI Gateway Admin UI

Minimal operations console for the AI Gateway M0 skeleton.

## Commands

```bash
npm ci
npm run dev
npm run typecheck
npm run test
npm run build
npm run check:bundle
```

Run `npm run check:bundle` after `npm run build` to enforce the built initial JS budget. The default initial JS budget is 250 KiB; lazy route chunks are logged separately. Set `ADMIN_UI_BUNDLE_BUDGET_KIB` when an intentional initial bundle-size change needs a different threshold.

## Configuration

The API client defaults to same-origin proxy paths so the built UI can sit behind a reverse proxy without calling a user's localhost:

- Gateway: `/api/gateway`
- Control Plane: `/api/control-plane`
- Mock Provider: `/api/mock-provider`

Set these variables only when the frontend is built for explicit browser-reachable API origins:

- `VITE_GATEWAY_BASE_URL`
- `VITE_CONTROL_BASE_URL`
- `VITE_MOCK_PROVIDER_BASE_URL`

`VITE_API_BASE_URL` is kept only as a legacy fallback for the gateway URL.

The production Docker image serves the built app with nginx and proxies the same-origin paths with runtime environment variables:

- `GATEWAY_UPSTREAM`
- `CONTROL_PLANE_UPSTREAM`
- `MOCK_PROVIDER_UPSTREAM`
- `ADMIN_UI_PORT`

Requests use AbortController-backed timeouts. General JSON API requests time out after 10 seconds; health probes keep their lightweight online/offline/pending behavior and time out after 3 seconds. JSON helpers unwrap `{ "data": ... }` success envelopes and surface `{ "error": ... }` responses as typed API client errors.
