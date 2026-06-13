# AxonHub UI Notes

Local reference clone: `references/axonhub` from `https://github.com/looplj/axonhub`.

The clone is ignored by git and should be treated as a design/reference checkout, not vendored code.

## What To Copy Conceptually

- Operational admin app, not marketing site.
- Left sidebar with grouped sections: Admin and Project.
- Dashboard first: request count, success rate, token stats, daily requests, channel success rate.
- Dense tables for models, channels, requests, users, and API keys.
- Filters directly above tables: ID/name search, status, channel, API key, date range.
- Status chips and small badges instead of long prose.
- Drill-down from lists into request detail and trace detail.
- Model/channel management emphasizes mapping, association count, enabled state, and provider identity.
- Request logs expose model, stream mode, source, channel, API key, status, latency, first token latency, created time.

## Visual Direction

- Light, quiet admin surface.
- Warm neutral background with one earthy accent color.
- Rounded sidebar and cards, but keep content dense.
- Table headers are muted bands; row text is high-contrast.
- Primary actions are in the top right of the page.
- Icons are used in nav and action buttons.
- Charts are secondary to operational readback and troubleshooting.

## What Not To Copy

- Do not vendor AxonHub source into this repo.
- Do not copy branding or logos.
- Do not add theme complexity before our own pages are understandable.
- Do not make our UI more decorative than useful.

## Immediate fubox UI Changes To Aim For

1. Rename and order navigation around real workflows: Dashboard, Distribution, Providers/Channels, Models, API Keys, Requests/Traces, Billing, Users.
2. Make Distribution a compact readiness dashboard, not a document page.
3. Move release/evidence text out of the UI unless it directly helps an operator fix routing.
4. Make request logs the main troubleshooting surface with filters and status/latency chips.
5. Treat user portal as a developer console: endpoint, balance, key, models, usage, request detail.
