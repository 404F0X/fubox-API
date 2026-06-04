# E8-004 Gateway TPM Runtime Wiring Contract

Status: design and acceptance contract for the next Gateway wiring slice.

Routing pure contracts already cover:

- `estimate_tpm_reservation`
- `RateLimitTpmReservationEstimate::required_tokens_i64`
- `RateLimitRequiredCapacity::from_tpm_estimate`
- `plan_rate_limit_reservation`

This document fixes how Gateway runtime should map endpoint/request token signals into
`RateLimitTpmEstimateInput` before provider-key reservation acquire. It is not a
Gateway implementation change.

## Scope

In scope for the next code slice:

- Gateway endpoint request parsing helpers for TPM estimate inputs.
- Gateway request/route metadata that records only bounded numeric TPM summaries.
- Gateway fixtures/tests proving prompt-protection rejects do not reserve and
  routable provider attempts reserve before provider side effects.

Out of scope:

- Control Plane, Admin UI, billing-ledger, scripts, and routing contract changes.
- Real tokenizer implementation if none exists. Missing tokenizer data must use the
  conservative fallback contract.
- Client-supplied token counts as trusted totals.

## Endpoint Token Signals

Runtime reservation happens before the upstream provider call, so response `usage`
fields are not available for acquire. Provider response usage remains for billing,
settlement, and post-attempt reconciliation only.

| Endpoint | Prompt/input token signal before provider call | Completion/max token signal before provider call | Total token signal before provider call | Post-response usage fields, not for acquire |
|---|---|---|---|---|
| OpenAI chat `/v1/chat/completions` | Local tokenizer estimate over `messages`, optional `input`-adjacent fields, tools, and system/developer text when implemented. If no tokenizer, missing. | Request `max_completion_tokens` first, then legacy `max_tokens`. If neither is valid, missing. | None unless an internal trusted tokenizer precomputes total. Do not trust client supplied totals. | `usage.prompt_tokens`, `usage.completion_tokens`, `usage.total_tokens`. |
| OpenAI responses `/v1/responses` | Local tokenizer estimate over `input`, instructions, and tool context when implemented. If no tokenizer, missing. | Request `max_output_tokens`. If absent, missing. | None unless an internal trusted tokenizer precomputes total. | `usage.input_tokens`, `usage.output_tokens`, `usage.total_tokens` when present. |
| Anthropic messages `/v1/messages` | Local tokenizer estimate over `system`, `messages[].content`, and tool definitions when implemented. If no tokenizer, missing. | Request `max_tokens`. Anthropic requires this in normal requests, but mapper must still handle missing/invalid defensively. | None unless an internal trusted tokenizer precomputes total. | `usage.input_tokens`, `usage.output_tokens`, cache token details when present. |
| Gemini native `:generateContent` / `:streamGenerateContent` | Local tokenizer estimate over `contents`, `systemInstruction`, and tool config when implemented. If no tokenizer, missing. | Request `generationConfig.maxOutputTokens`. If absent, missing. | None unless an internal trusted tokenizer precomputes total. | `usageMetadata.promptTokenCount`, `usageMetadata.candidatesTokenCount`, `usageMetadata.totalTokenCount`. |

## Mapping To `RateLimitTpmEstimateInput`

For each candidate/provider-key acquire plan, Gateway should build one
`RateLimitTpmEstimateInput` from request-local numeric signals:

| Input field | Gateway mapping rule |
|---|---|
| `prompt_tokens` | `Some(value)` only for a trusted internal tokenizer/request parser estimate. Use `None` when tokenizer data is unavailable. Never derive this from raw payload text in logs. |
| `completion_tokens` | Usually `None` for pre-call reservation. Use only when Gateway has a trusted request-local exact completion estimate. Do not use post-response usage for acquire. |
| `max_completion_tokens` | Map endpoint max-output request fields: chat `max_completion_tokens` or `max_tokens`, responses `max_output_tokens`, Anthropic `max_tokens`, Gemini `generationConfig.maxOutputTokens`. |
| `total_tokens` | Use only for trusted internal precomputed total token estimates. Keep `None` for ordinary requests. |
| `conservative_fallback_tokens` | Use model/profile/provider-key TPM reservation fallback config when available. If missing or invalid, use the routing default `RATE_LIMIT_DEFAULT_TPM_FALLBACK_TOKENS` behavior. |

Source semantics from routing must remain intact:

- Trusted `total_tokens` wins.
- `prompt_tokens + max(completion_tokens, max_completion_tokens)` is used when both sides are available.
- Partial data uses `PartialEstimateWithConservativeFallback`, for example prompt plus fallback or fallback plus max completion.
- Fully missing data uses `ConservativeFallback`.
- Required capacity uses `RateLimitRequiredCapacity::from_tpm_estimate`, not a separate ad hoc conversion.

## Defensive Numeric Rules

The Gateway mapper must avoid unchecked casts:

- Negative numeric fields from request JSON should normally be rejected by endpoint validation before routing.
- If a negative token signal reaches the mapper, pass it as a negative `i64` or drop it to `None`; either path must not become zero-cost. The routing contract sanitizes negative estimates and applies fallback.
- Values larger than `i64::MAX` must saturate to `i64::MAX` or be rejected by request validation. They must never wrap.
- Zero trusted totals or zero prompt/completion estimates must preserve the routing minimum 1-token clamp.
- When summed prompt/completion estimates exceed `i64::MAX`, `required_tokens_i64()` clamps the reservation capacity to `i64::MAX`.

Reference routing evidence:

- `rate_limit_tpm_estimate_contract_v1`
- `edge_behaviors`
- `capacity_bridge_behaviors`
- `tpm_estimate_to_required_capacity_bridge_clamps_i64_before_reservation`
- `tpm_estimate_bridge_serialized_outputs_are_secret_safe`

## Reservation Timing

The next Gateway implementation must preserve side-effect ordering:

1. Parse request enough to identify endpoint/model and compute safe request hash.
2. Authenticate virtual key and enforce IP/profile/model access checks.
3. Run prompt protection.
4. If prompt protection rejects, return the prompt-protection error without rate-limit reservation, provider attempt creation, provider-key open, upstream call, or billing side effect.
5. For requests that pass prompt protection and are routable/billable, resolve route candidates and candidate provider keys.
6. Immediately before provider attempt/provider-key open/upstream call, build `RateLimitTpmEstimateInput`, convert to `RateLimitRequiredCapacity`, and acquire the reservation.
7. If acquire is rejected/not applied, skip that candidate before provider side effects and continue fallback when allowed.
8. If acquire is applied and the attempt does not successfully consume the reservation, finalize/release according to the existing reservation finalization contract.

Streaming uses the same acquire point before opening the upstream stream. Pre-response stream errors/fallback release applied reservations. Late stream errors after partial output must follow the existing no-late-fallback finalizer rules.

## Secret-Safe Runtime Output

Allowed TPM reservation metadata:

- schema/version name
- endpoint family
- estimate source enum
- numeric `required_tokens`
- numeric `required_tokens_i64`
- boolean `used_conservative_fallback`
- boolean `sanitized_negative_estimate`
- boolean `clamped_to_i64_max`
- numeric `required_capacity.tokens_per_minute`
- numeric reservation dimension summary already allowed by routing contract

Forbidden in request logs, provider attempts, route decision snapshots, metrics labels, and test snapshots:

- raw request body, prompt, completion, messages, `contents`, `input`, or tool payload
- `Authorization`, virtual key secret, provider key secret, encrypted secret, bearer token
- raw headers
- raw endpoint URL with query secrets
- raw provider `current_window_state` JSON/window material
- unbounded candidate lists or unbounded metrics label values

Metrics must use bounded labels only, for example endpoint family and estimate source. Do not label with model text, trace id, request id, provider key id, or raw error text.

## Acceptance Test Plan For Next Code Slice

Focused tests should cover at least:

1. OpenAI chat maps tokenizer prompt estimate plus `max_completion_tokens` into `PromptAndMaxCompletion` and the same TPM value appears in reservation required capacity.
2. OpenAI responses maps tokenizer prompt estimate plus `max_output_tokens`.
3. Anthropic messages maps tokenizer prompt estimate plus `max_tokens`.
4. Gemini native maps tokenizer prompt estimate plus `generationConfig.maxOutputTokens`.
5. Missing tokenizer and missing max-output field uses `ConservativeFallback`.
6. Missing tokenizer but present max-output field uses partial estimate with conservative fallback.
7. Negative or too-large token fields do not wrap and do not become optimistic zero-token reservations.
8. Prompt-protection reject path proves no reservation acquire, no provider attempt, no provider-key open, and no upstream call.
9. Reservation acquire happens after prompt protection pass and before provider attempt/provider-key open/upstream call.
10. Route/request/provider snapshots include only the allowed numeric TPM summary fields.
11. Streaming pre-response failure releases an applied reservation.
12. All-candidate reservation rejection returns OpenAI-compatible `429 rate_limit_exceeded` without raw model, payload, endpoint, or secret material.

## Next Code Slice Boundary

Recommended write scope for Gateway runtime wiring:

- `apps/gateway/src/main.rs`
- `apps/gateway/src/streaming.rs` only if streaming finalization metadata must carry the same summary
- `tests/fixtures/gateway/*rate_limit*` or endpoint-specific gateway fixtures

Avoid in that slice unless there is a blocking signature mismatch:

- `crates/routing/**`
- `crates/db/**`
- `apps/control-plane/**`
- `web/admin-ui/**`
- `scripts/**`
- `crates/billing-ledger/**`

Exit conditions:

- Every implemented endpoint path calls one shared helper or clearly equivalent mapping path.
- Prompt-protection reject tests prove no reservation side effects.
- Reservation metadata is secret-safe and bounded.
- Targeted Gateway rate-limit/prompt-protection tests pass.
- Existing routing TPM contract tests remain unchanged and passing.
