# Legacy Admin UI Handoff v1

Date: 2026-06-12

This handoff freezes the old admin shell as compatibility code only. The next frontend pass is expected to rebuild the admin workbench around `src/app`, `src/layouts`, `src/design`, and `src/features/<domain>` instead of polishing the legacy shell.

## Current Boundary

Legacy compatibility only:

- `web/admin-ui/src/components/Navigation.tsx`
  - Kept so any old route still importing `Navigation` can render.
  - Marked with `data-admin-shell="legacy-compat"` and `LEGACY_NAVIGATION_SCOPE`.
  - Do not add new navigation behavior here.
- `web/admin-ui/src/styles.css`
  - Still contains legacy `.shell`, `.sidebar`, `.nav-*`, `.workspace`, `.topbar`, card, form, and proof-era utility styles.
  - The `.shell` block is now explicitly labeled as legacy compatibility CSS.
  - Do not expand this file for new page-specific layout unless a page is still waiting to migrate.
- `web/admin-ui/src/components/PromptProtectionSummary.tsx`
  - Kept as a debug/audit renderer for existing proof-shaped records.
  - Do not make this a main-path admin page or dashboard dependency.
- `web/admin-ui/src/billingExecuteSmokeContract.ts` and `.serializable.json`
  - Kept as historical/debug contract material.
  - Do not surface their artifact/freshness/release language in the primary UI path.
- Large legacy page bodies still waiting for future decomposition, especially `BillingPage`, `UserPortalPanel`, and `ImportWizardPage`.
  - Safe fixes are allowed.
  - Visual polish and new workflow UI should move into `features/<domain>` or a new app folder.

Current rebuild path:

- `web/admin-ui/src/app/*`: routing, session restore, permissions, mode handling.
- `web/admin-ui/src/layouts/AdminShell.tsx`: current admin workbench shell.
- `web/admin-ui/src/design/*`: reusable table, chip, field, toolbar, metric, action, and empty-state primitives.
- `web/admin-ui/src/features/<domain>/*`: domain pages and local components.
- `web/admin-ui/src/lib/safeText.ts` and `format.ts`: secret-safe display and formatting helpers.

## Proof And Debug Copy

Primary UI should show:

- status
- reason
- next action
- safe ids or prefixes
- bounded details needed to operate the system

Primary UI should not show:

- release evidence narratives
- proof closure or freshness claims
- manifest freshness gates
- raw artifact JSON
- command transcripts
- raw payloads, Authorization, provider keys, voucher raw codes, idempotency keys, or secret DSNs

When proof-shaped material is still useful, move it to one of these places:

- `docs/debug/handoff/` for handoff notes and historical operator/debug context.
- A collapsed UI section labeled as debug/audit material, never the first screen or default workflow.
- Existing tests or fixtures, when the material is a contract guard rather than user-facing content.

## Migration Rules

1. New admin workbench pages must not import `components/Navigation.tsx`.
2. New shell behavior belongs in `layouts/AdminShell.tsx` or a future replacement layout.
3. New reusable controls belong in `src/design`; page-specific controls belong in `src/features/<domain>`.
4. If a legacy page needs a small safe fix, keep the patch local and do not expand the old shell CSS model.
5. If a proof/debug phrase is needed for support, document it under `docs/debug/handoff/` or hide it behind an explicit debug/audit disclosure.
6. When migrating a page, delete only the legacy selectors proven unused by that page. Do not broad-clean global CSS in a shared worker slice.

## Open Follow-up

- Split `styles.css` into shell/design/feature layers after each target page migrates.
- Remove `components/Navigation.tsx` once no route imports it.
- Replace remaining proof-era UI labels such as `证据`, `production_*_evidence`, `freshness`, and `proof` with operator-facing status/reason/next-action copy or move them to debug/audit sections.
- Continue the User Portal split through `docs/frontend/USER_PORTAL_STANDALONE_HANDOFF.md`.

These follow-ups are part of the next frontend rebuild. They do not block the current local MVP closure as long as legacy shell code remains isolated as compatibility/debug-only code and proof-shaped copy stays out of the primary UI path.
