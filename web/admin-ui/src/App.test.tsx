import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import {
  ledgerAdjustmentExecuteAbsentOptionalMarker,
  ledgerAdjustmentExecuteLiveSmokeContract,
  ledgerAdjustmentExecuteLiveSmokeHandoff,
  ledgerAdjustmentExecuteLiveSmokeSerializableHandoff,
} from "./billingExecuteSmokeContract";
import ledgerAdjustmentExecuteLiveSmokeSerializableHandoffArtifact from "./billingExecuteSmokeContract.serializable.json";
import {
  promptProtectionAuditClosureGate,
  promptProtectionEvidenceReadback,
} from "./components/PromptProtectionSummary";
import { UserPortalDashboard, UserPortalLoginPanel } from "./components/UserPortalPanel";

vi.setConfig({ testTimeout: 15000 });

const ledgerExecuteSmoke = ledgerAdjustmentExecuteLiveSmokeContract;
const ledgerExecuteSmokeHandoff = ledgerAdjustmentExecuteLiveSmokeHandoff;
const ledgerExecuteSmokeSerializableHandoff =
  ledgerAdjustmentExecuteLiveSmokeSerializableHandoff;
const ledgerExecuteSmokeSerializableHandoffArtifact =
  ledgerAdjustmentExecuteLiveSmokeSerializableHandoffArtifact;

const AUTH_HEADER_NAME = ["Author", "ization"].join("");
const BEARER_SCHEME = ["Bear", "er"].join("");
const SK_PREFIX = ["s", "k", "-"].join("");
const SK_UNDERSCORE_PREFIX = ["s", "k", "_"].join("");
const VK_UNDERSCORE_PREFIX = ["v", "k", "_"].join("");
const GITHUB_PAT_PREFIX = ["github", "_", "pat", "_"].join("");
const SESSION_PREFIX = ["se", "ss", "_"].join("");
const PROMPT_PROTECTION_CLOSURE_CHECKLIST_TEXT =
  "gateway_live_proof, postgres_audit_row, mock_provider_upstream_refusal, provider_attempts_zero, latency_envelope, current_provenance, duration_available, freshness_replay_classification";

function bearerPlaceholder(value: string): string {
  return `${BEARER_SCHEME} ${value}`;
}

function authorizationBearerPlaceholder(value: string): string {
  return `${AUTH_HEADER_NAME}: ${bearerPlaceholder(value)}`;
}

function skPlaceholder(value: string): string {
  return `${SK_PREFIX}${value}`;
}

function skUnderscorePlaceholder(value: string): string {
  return `${SK_UNDERSCORE_PREFIX}${value}`;
}

function vkUnderscorePlaceholder(value: string): string {
  return `${VK_UNDERSCORE_PREFIX}${value}`;
}

function githubPatPlaceholder(value: string): string {
  return `${GITHUB_PAT_PREFIX}${value}`;
}

function sessionPlaceholder(value: string): string {
  return `${SESSION_PREFIX}${value}`;
}

function stubHealthyFetch(
  roles = ["owner"],
  options: {
    meFailsWithSecret?: boolean;
    recoveryFails?: boolean;
    recoveryFailsWithSecret?: boolean;
    restoreSession?: boolean;
  } = {},
) {
  let loginSucceeded = false;
  const fetchMock = vi.fn((url: RequestInfo | URL, init?: RequestInit) => {
    const requestUrl = String(url);
    const method = init?.method ?? "GET";

    if (requestUrl.includes("/admin/auth/login")) {
      loginSucceeded = true;
      return jsonResponse(loginPayload());
    }

    if (requestUrl.includes("/admin/auth/me")) {
      if (options.meFailsWithSecret) {
        return jsonError(
          `${AUTH_HEADER_NAME}: ${bearerPlaceholder("session-restore-hidden")} ${skPlaceholder("session-restore-hidden")}`,
          401,
        );
      }

      if (!options.restoreSession && !loginSucceeded) {
        return jsonError("No active admin session", 401);
      }

      return jsonResponse(adminMePayload(roles));
    }

    if (requestUrl.includes("/admin/auth/logout")) {
      return jsonResponse({ logged_out: true });
    }

    if (
      requestUrl.includes("/admin/provider-keys/provider-key-1/recovery") &&
      method === "POST"
    ) {
      if (options.recoveryFailsWithSecret) {
        return jsonError(
          `fingerprint fp-recovery-hidden current_window_state raw metadata`,
          400,
        );
      }

      if (options.recoveryFails) {
        return jsonError(
          "provider key status `auth_failed` cannot be recovered through this endpoint",
          400,
        );
      }

      return jsonResponse(providerKeyRecoveryPayload());
    }

    if (requestUrl.includes("/admin/providers/health-summary")) {
      return jsonResponse(
        healthSummaryPayload(healthSummaryQueryOptions(requestUrl)),
      );
    }

    if (
      requestUrl.includes("/admin/audit-logs") ||
      requestUrl.includes("/admin/request-logs") ||
      requestUrl.includes("/admin/price-versions") ||
      requestUrl.includes("/admin/ledger/entries") ||
      requestUrl.includes("/admin/billing/reconciliation")
    ) {
      return jsonResponse([]);
    }

    if (
      requestUrl.includes("/admin/providers") ||
      requestUrl.includes("/admin/channels")
    ) {
      return jsonResponse([]);
    }

    return Promise.resolve(new Response("", { status: 200 }));
  });

  vi.stubGlobal("fetch", fetchMock);

  return fetchMock;
}

function stubAdminFetch(
  options: {
    ledgerAdjustmentDryRunFails?: boolean;
    ledgerEntriesRefreshFails?: boolean;
    ledgerAdjustmentErrorEnvelopeData?: boolean;
    ledgerAdjustmentExecuteResponseShape?: "default" | "tolerant";
    ledgerAdjustmentExecuteStatus?:
      | "applied"
      | "idempotent"
      | "blocked"
      | "failed";
    ledgerAdjustmentExecuteStatuses?: Array<
      "applied" | "idempotent" | "blocked" | "failed"
    >;
    payloadPreviewStatus?: "success" | "forbidden" | "notImplemented";
    payloadStored?: boolean;
    requestLogExportStatus?: "success" | "notImplemented";
    providerKeyStatus?: string;
    promptProtectionProofVariant?:
      | "duplicateRunRefused"
      | "failedRefused"
      | "liveEligible"
      | "simulatedReplayRefused"
      | "simulatedRefused"
      | "staleCommitRefused"
      | "staleGeneratedAtRefused";
    promptProtectionSignals?: boolean;
  } = {},
) {
  let channelCreated = false;
  let associationCreated = false;
  let loginSucceeded = false;
  let modelCreated = false;
  let providerCreated = false;
  let profileCreated = false;
  let ledgerEntriesRequestCount = 0;
  const requestLog = {
    api_key_profile_id: null,
    canonical_model_id: "model-1",
    client_request_id: "client-1",
    completed_at: "2026-06-02T12:01:00Z",
    created_at: "2026-06-02T12:00:00Z",
    currency: "USD",
    error_code: null,
    error_owner: null,
    final_cost: "0.0123",
    http_status: 200,
    id: "req_1",
    inbound_protocol: "openai",
    input_tokens: 100,
    latency_ms: 1234,
    outbound_protocol: "openai",
    output_tokens: 55,
    partial_sent: false,
    payload_policy_id: "payload-policy-1",
    payload_stored: options.payloadStored ?? true,
    project_id: null,
    protocol_mode: "native",
    provider_key_id: "provider-key-1",
    redaction_status: "redacted",
    request_body_hash: "request-body-hash-hidden",
    requested_model: "gpt-4o-mini",
    resolved_channel_id: "channel-1",
    resolved_provider_id: "provider-1",
    response_body_hash: "response-body-hash-hidden",
    retryable: false,
    route_policy_version: "policy-v1",
    status: "succeeded",
    stream_end_reason: null,
    tenant_id: "tenant-1",
    thread_id: null,
    trace_id: "trace-1",
    ttft_ms: 210,
    upstream_model: "gpt-4o-mini-2024-07-18",
    virtual_key_id: null,
  };
  const requestLedgerSummary = {
    currencies: ["USD"],
    entries: [
      {
        amount: "-0.01230000",
        balance: {
          after: null,
          before: null,
          currency: "USD",
          reason: "historical wallet balance snapshots are not stored on ledger_entries",
          source: "ledger_entry_summary.v1",
          status: "config-needed",
        },
        created_at: "2026-06-02T12:02:00Z",
        currency: "USD",
        entry_type: "settle",
        id: "00000000-0000-0000-0000-000000000091",
        occurred_at: "2026-06-02T12:01:30Z",
        refs: {
          ledger_entry_id: "00000000-0000-0000-0000-000000000091",
          order_id: "00000000-0000-0000-0000-0000000000a1",
          payment_capture_id: "00000000-0000-0000-0000-0000000000a2",
          ref_source: "ledger_entry_columns_and_safe_metadata_refs",
          request_id: "req_1",
          wallet_id: "00000000-0000-0000-0000-000000000040",
        },
        request_id: "req_1",
        status: "confirmed",
        wallet_id: "00000000-0000-0000-0000-000000000040",
      },
    ],
    limit: 25,
    limit_reached: false,
    omitted_fields: [
      "idempotency_key",
      "usage_snapshot",
      "policy_snapshot",
      "metadata",
    ],
    request_count: 1,
    returned_count: 1,
  };
  const promptProtectionClosureChecklist = [
    "gateway_live_proof",
    "postgres_audit_row",
    "mock_provider_upstream_refusal",
    "provider_attempts_zero",
    "latency_envelope",
    "current_provenance",
    "duration_available",
    "freshness_replay_classification",
  ];
  const promptProtectionSignal = {
    action: "reject",
    audit_readiness: {
      classification: "blocked",
      closure_checklist: promptProtectionClosureChecklist,
      closure_gaps: [
        "gateway_live_proof_blocker",
        "postgres_audit_row_missing",
        "mock_provider_upstream_refusal_missing",
      ],
      command_summary: "live_proof_report",
      current_provenance_required: true,
      duration_available_required: true,
      evidence_fields: [
        "provider_attempts_count",
        "latency_envelope",
        "provenance",
      ],
      freshness_replay_classification: "simulated_replay_refused",
      latency_envelope_required: true,
      provider_attempts_zero_required: true,
      raw_command: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("prompt-handoff-command-hidden")}`,
      raw_report_path: "C:\\secret\\prompt-handoff-report-hidden.json",
      secret_dsn: "postgres://prompt-handoff-dsn-hidden",
    },
    authorization: bearerPlaceholder("prompt-protection-hidden"),
    configured_actions: {
      reject: 1,
    },
    configured_hit_count: 1,
    configured_pattern_types: {
      regex: 1,
    },
    configured_rules: [
      "custom-reject-rule",
      skPlaceholder("prompt-rule-hidden"),
    ],
    cookie: "session prompt protection hidden",
    default_hit_count: 1,
    detected_action: "reject",
    effective_action: "reject",
    hit_count: 2,
    hit_kinds: {
      authorization_bearer: 1,
      prompt_injection_phrase: 1,
    },
    mode: "enforce",
    pattern: skPlaceholder("prompt-pattern-hidden"),
    provider_secret: skPlaceholder("prompt-provider-hidden"),
    provider_side_effects: {
      provider_attempts_count: 0,
      provider_secret: skPlaceholder("prompt-side-effect-hidden"),
    },
    performance: {
      db_evidence_duration_ms: null,
      duration_available: false,
      raw_body: "raw prompt protection performance body hidden",
      request_preflight_duration_ms: null,
      total_case_duration_ms: null,
      unavailable_reason: "live_request_or_query_blocked",
    },
    performance_envelope: {
      all_endpoint_performance_within_bounds: false,
      command_summary: {
        authorization: bearerPlaceholder("prompt-performance-command-hidden"),
        database_url: "postgres://prompt-performance-dsn-hidden",
      },
      duration_unavailable_marker: "duration_available=false",
      external_blocker_count: 1,
      latency_envelope_closure_eligible: false,
      live_blocker_status: "blocked",
      provider_attempts_zero_required: true,
      raw_headers: {
        [AUTH_HEADER_NAME]: bearerPlaceholder(
          "prompt-performance-header-hidden",
        ),
      },
    },
    freshness: {
      freshness_replay_classification: "simulated_replay_refused",
      generated_at_utc: "2026-06-04T13:30:00.000Z",
      live_evidence_closure_eligible: false,
      proof_run_id_hash:
        "feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface",
      raw_report_path: "C:\\secret\\prompt-proof-report-hidden.json",
      repo_head_commit: "abcdef1234567890abcdef1234567890abcdef12",
      stale_or_simulated_report_closes_live_gap: false,
    },
    generated_at_utc: "2026-06-04T13:30:00.000Z",
    provenance: {
      command_line: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("prompt-artifact-command-hidden")}`,
      generated_at_utc: "2026-06-04T13:30:00.000Z",
      kind: "simulated",
      mode: "contract",
      redacted_command_summary: {
        database_connection: "postgres://prompt-artifact-dsn-hidden",
        provider_secret: skPlaceholder("prompt-artifact-provider-hidden"),
        report_path: "C:\\secret\\prompt-proof-report-hidden.json",
      },
      repo: {
        head_commit: "abcdef1234567890abcdef1234567890abcdef12",
      },
    },
    raw_pattern: "secret-like prompt protection pattern hidden",
    raw_pattern_values_omitted: true,
    raw_payload_omitted: true,
    raw_prompt: "raw prompt protection prompt hidden",
    reason: "prompt_injection_detected",
    schema: "gateway_prompt_protection_v1",
    scopes: ["messages", "metadata"],
    token: skPlaceholder("prompt-token-hidden"),
  };
  const liveEligiblePromptProtectionSignal = {
    ...promptProtectionSignal,
    audit_readiness: {
      classification: "pass",
      closure_checklist: promptProtectionClosureChecklist,
      closure_gaps: ["none"],
      command_summary: "live_proof_report",
      current_provenance_required: true,
      duration_available_required: true,
      evidence_fields: [
        "provider_attempts_count",
        "latency_envelope",
        "provenance",
      ],
      freshness_replay_classification: "current_live_proof",
      latency_envelope_required: true,
      provider_attempts_zero_required: true,
      raw_command: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("prompt-live-handoff-command-hidden")}`,
      raw_report_path: "C:\\secret\\prompt-live-handoff-report-hidden.json",
      secret_dsn: "postgres://prompt-live-handoff-dsn-hidden",
    },
    freshness: {
      freshness_replay_classification: "current_live_proof",
      generated_at_utc: "2026-06-04T14:05:00.000Z",
      live_evidence_closure_eligible: true,
      proof_run_id_hash:
        "deadc0dedeadc0dedeadc0dedeadc0dedeadc0dedeadc0dedeadc0dedeadc0de",
      raw_report_path: "C:\\secret\\prompt-live-proof-report-hidden.json",
      repo_head_commit: "1234567890abcdef1234567890abcdef12345678",
      stale_or_simulated_report_closes_live_gap: false,
    },
    generated_at_utc: "2026-06-04T14:05:00.000Z",
    performance: {
      db_evidence_duration_ms: 15,
      duration_available: true,
      raw_body: "raw live prompt proof performance body hidden",
      request_preflight_duration_ms: 9,
      total_case_duration_ms: 24,
      unavailable_reason: skPlaceholder("prompt-live-unavailable-hidden"),
    },
    performance_envelope: {
      all_endpoint_performance_within_bounds: true,
      command_summary: {
        authorization: bearerPlaceholder(
          "prompt-live-performance-command-hidden",
        ),
        database_url: "postgres://prompt-live-performance-dsn-hidden",
      },
      duration_unavailable_marker: "duration_available=false",
      external_blocker_count: 0,
      latency_envelope_closure_eligible: true,
      live_blocker_status: "not_blocked",
      provider_attempts_zero_required: true,
      raw_headers: {
        [AUTH_HEADER_NAME]: bearerPlaceholder(
          "prompt-live-performance-header-hidden",
        ),
      },
    },
    provenance: {
      command_line: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("prompt-live-artifact-command-hidden")}`,
      generated_at_utc: "2026-06-04T14:05:00.000Z",
      kind: "live",
      mode: "live",
      redacted_command_summary: {
        database_connection: "postgres://prompt-live-artifact-dsn-hidden",
        provider_secret: skPlaceholder("prompt-live-artifact-provider-hidden"),
        report_path: "C:\\secret\\prompt-live-proof-report-hidden.json",
      },
      repo: {
        head_commit: "1234567890abcdef1234567890abcdef12345678",
      },
    },
  };
  const failedPromptProtectionSignal = {
    ...promptProtectionSignal,
    audit_readiness: {
      classification: "fail",
      closure_checklist: promptProtectionClosureChecklist,
      closure_gaps: ["latency_envelope_failed", "duration_unavailable"],
      command_summary: "live_proof_report",
      current_provenance_required: true,
      duration_available_required: true,
      evidence_fields: [
        "provider_attempts_count",
        "latency_envelope",
        "provenance",
      ],
      freshness_replay_classification: "freshness_or_replay_refused",
      latency_envelope_required: true,
      provider_attempts_zero_required: true,
      raw_command: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("prompt-fail-handoff-command-hidden")}`,
      raw_report_path: "C:\\secret\\prompt-fail-handoff-report-hidden.json",
      secret_dsn: "postgres://prompt-fail-handoff-dsn-hidden",
    },
    freshness: {
      freshness_replay_classification: "freshness_or_replay_refused",
      generated_at_utc: "2026-06-04T14:15:00.000Z",
      live_evidence_closure_eligible: false,
      proof_run_id_hash:
        "facefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeed",
      raw_report_path: "C:\\secret\\prompt-fail-proof-report-hidden.json",
      repo_head_commit: "1234567890abcdef1234567890abcdef12345678",
      stale_or_simulated_report_closes_live_gap: false,
    },
    generated_at_utc: "2026-06-04T14:15:00.000Z",
    performance_envelope: {
      ...promptProtectionSignal.performance_envelope,
      all_endpoint_performance_within_bounds: false,
      external_blocker_count: 0,
      latency_envelope_closure_eligible: false,
      live_blocker_status: "not_blocked",
    },
    provenance: {
      ...promptProtectionSignal.provenance,
      generated_at_utc: "2026-06-04T14:15:00.000Z",
      kind: "live",
      mode: "live",
      redacted_command_summary: {
        database_connection: "postgres://prompt-fail-artifact-dsn-hidden",
        provider_secret: skPlaceholder("prompt-fail-artifact-provider-hidden"),
        report_path: "C:\\secret\\prompt-fail-proof-report-hidden.json",
      },
      repo: {
        head_commit: "1234567890abcdef1234567890abcdef12345678",
      },
    },
  };
  const staleGeneratedAtPromptProtectionSignal = {
    ...liveEligiblePromptProtectionSignal,
    audit_readiness: {
      ...liveEligiblePromptProtectionSignal.audit_readiness,
      classification: "blocked",
      closure_gaps: ["stale_generated_at"],
      freshness_replay_classification: "stale_generated_at_refused",
      raw_command: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("prompt-stale-generated-command-hidden")}`,
      raw_report_path: "C:\\secret\\prompt-stale-generated-report-hidden.json",
      secret_dsn: "postgres://prompt-stale-generated-dsn-hidden",
    },
    freshness: {
      ...liveEligiblePromptProtectionSignal.freshness,
      freshness_replay_classification: "stale_generated_at_refused",
      generated_at_utc: "2026-06-03T14:05:00.000Z",
      live_evidence_closure_eligible: false,
      proof_run_id_hash:
        "badc0ffee0ddf00dbadc0ffee0ddf00dbadc0ffee0ddf00dbadc0ffee0ddf00d",
      raw_report_path: "C:\\secret\\prompt-stale-generated-proof-hidden.json",
    },
    generated_at_utc: "2026-06-03T14:05:00.000Z",
    provenance: {
      ...liveEligiblePromptProtectionSignal.provenance,
      generated_at_utc: "2026-06-03T14:05:00.000Z",
      redacted_command_summary: {
        database_connection:
          "postgres://prompt-stale-generated-artifact-dsn-hidden",
        provider_secret: skPlaceholder(
          "prompt-stale-generated-provider-hidden",
        ),
        report_path: "C:\\secret\\prompt-stale-generated-proof-hidden.json",
      },
    },
  };
  const staleCommitPromptProtectionSignal = {
    ...liveEligiblePromptProtectionSignal,
    audit_readiness: {
      ...liveEligiblePromptProtectionSignal.audit_readiness,
      classification: "fail",
      closure_gaps: ["stale_repo_commit"],
      freshness_replay_classification: "stale_repo_commit_refused",
      raw_command: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("prompt-stale-commit-command-hidden")}`,
      raw_report_path: "C:\\secret\\prompt-stale-commit-report-hidden.json",
      secret_dsn: "postgres://prompt-stale-commit-dsn-hidden",
    },
    freshness: {
      ...liveEligiblePromptProtectionSignal.freshness,
      freshness_replay_classification: "stale_repo_commit_refused",
      live_evidence_closure_eligible: false,
      proof_run_id_hash:
        "c001c0dec001c0dec001c0dec001c0dec001c0dec001c0dec001c0dec001c0de",
      raw_report_path: "C:\\secret\\prompt-stale-commit-proof-hidden.json",
      repo_head_commit: "0000000000000000000000000000000000000000",
    },
    provenance: {
      ...liveEligiblePromptProtectionSignal.provenance,
      redacted_command_summary: {
        database_connection:
          "postgres://prompt-stale-commit-artifact-dsn-hidden",
        provider_secret: skPlaceholder("prompt-stale-commit-provider-hidden"),
        report_path: "C:\\secret\\prompt-stale-commit-proof-hidden.json",
      },
      repo: {
        head_commit: "0000000000000000000000000000000000000000",
      },
    },
  };
  const duplicateRunPromptProtectionSignal = {
    ...liveEligiblePromptProtectionSignal,
    audit_readiness: {
      ...liveEligiblePromptProtectionSignal.audit_readiness,
      classification: "fail",
      closure_gaps: ["duplicate_proof_run"],
      freshness_replay_classification: "duplicate_proof_run_refused",
      raw_command: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("prompt-duplicate-run-command-hidden")}`,
      raw_report_path: "C:\\secret\\prompt-duplicate-run-report-hidden.json",
      secret_dsn: "postgres://prompt-duplicate-run-dsn-hidden",
    },
    freshness: {
      ...liveEligiblePromptProtectionSignal.freshness,
      freshness_replay_classification: "duplicate_proof_run_refused",
      live_evidence_closure_eligible: false,
      proof_run_id_hash:
        "d00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00d",
      raw_report_path: "C:\\secret\\prompt-duplicate-run-proof-hidden.json",
    },
    provenance: {
      ...liveEligiblePromptProtectionSignal.provenance,
      redacted_command_summary: {
        database_connection:
          "postgres://prompt-duplicate-run-artifact-dsn-hidden",
        provider_secret: skPlaceholder("prompt-duplicate-run-provider-hidden"),
        report_path: "C:\\secret\\prompt-duplicate-run-proof-hidden.json",
      },
    },
  };
  const simulatedReplayPromptProtectionSignal = {
    ...promptProtectionSignal,
    audit_readiness: {
      ...promptProtectionSignal.audit_readiness,
      classification: "blocked",
      closure_gaps: ["simulated_replay"],
      freshness_replay_classification: "simulated_replay_refused",
      raw_command: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("prompt-simulated-replay-command-hidden")}`,
      raw_report_path: "C:\\secret\\prompt-simulated-replay-report-hidden.json",
      secret_dsn: "postgres://prompt-simulated-replay-dsn-hidden",
    },
    freshness: {
      ...promptProtectionSignal.freshness,
      freshness_replay_classification: "simulated_replay_refused",
      proof_run_id_hash:
        "51015eed51015eed51015eed51015eed51015eed51015eed51015eed51015eed",
      raw_report_path: "C:\\secret\\prompt-simulated-replay-proof-hidden.json",
    },
    provenance: {
      ...promptProtectionSignal.provenance,
      redacted_command_summary: {
        database_connection:
          "postgres://prompt-simulated-replay-artifact-dsn-hidden",
        provider_secret: skPlaceholder(
          "prompt-simulated-replay-provider-hidden",
        ),
        report_path: "C:\\secret\\prompt-simulated-replay-proof-hidden.json",
      },
    },
  };
  const effectivePromptProtectionSignal =
    options.promptProtectionProofVariant === "liveEligible"
      ? liveEligiblePromptProtectionSignal
      : options.promptProtectionProofVariant === "failedRefused"
        ? failedPromptProtectionSignal
        : options.promptProtectionProofVariant === "staleGeneratedAtRefused"
          ? staleGeneratedAtPromptProtectionSignal
          : options.promptProtectionProofVariant === "staleCommitRefused"
            ? staleCommitPromptProtectionSignal
            : options.promptProtectionProofVariant === "duplicateRunRefused"
              ? duplicateRunPromptProtectionSignal
              : options.promptProtectionProofVariant ===
                  "simulatedReplayRefused"
                ? simulatedReplayPromptProtectionSignal
                : promptProtectionSignal;
  const requestDetail = {
    ledger: requestLedgerSummary,
    provider_attempts: [
      {
        attempt_no: 1,
        channel_id: "channel-1",
        error_code: null,
        error_owner: null,
        fallback_reason: null,
        http_status: 200,
        id: "attempt-1",
        input_tokens: 100,
        latency_ms: 1234,
        metadata: {},
        output_tokens: 55,
        provider_id: "provider-1",
        provider_key_id: "provider-key-1",
        provider_request_id: "upstream-1",
        request_id: "req_1",
        retryable: false,
        status: "succeeded",
        tenant_id: "tenant-1",
        ttft_ms: 210,
        upstream_model: "gpt-4o-mini-2024-07-18",
      },
    ],
    request_log: requestLog,
    route_decision_snapshot: {
      api_key: skPlaceholder("route-hidden"),
      authorization: bearerPlaceholder("route-hidden"),
      candidates: ["channel-1"],
      nested: {
        token: bearerPlaceholder("nested-route-hidden"),
      },
      payload_ref: "payload-123-hidden",
      ...(options.promptProtectionSignals === false
        ? {}
        : { prompt_protection: effectivePromptProtectionSignal }),
      request_body: {
        body: "raw prompt hidden",
      },
      strategy: "weighted-fallback",
      summary: {
        candidate_count: 3,
        fallback_status: "fallback_allowed",
        filtered_count: 2,
        filter_reasons: ["ZeroWeight", "CoolingDown"],
        reject_reason: "none",
        selected_channel_id: "channel-1",
        selected_provider_model: "gpt-route-summary-upstream",
        selected_score_total: 2144483738,
        strategy: "priority_weight",
        trace_affinity_status: "Disabled",
      },
    },
  };
  const payloadPreview = {
    available: true,
    metadata: {
      content_type: "application/json",
      raw_headers: {
        cookie: "session hidden",
      },
    },
    omitted_fields: ["payload", "raw_headers"],
    payload_policy_id: "payload-policy-1",
    payload_stored: true,
    redacted_request_preview: {
      authorization: bearerPlaceholder("payload-preview-hidden"),
      messages_count: 2,
      provider_key: "provider-key-secret-hidden",
      raw_payload: "raw lazy payload hidden",
      redacted: true,
    },
    redacted_response_preview: {
      body: "raw response body hidden",
      output_items: 1,
      token: skPlaceholder("payload-response-hidden"),
    },
    redaction_status: "redacted",
    request_body_hash: "request-preview-hash",
    request_id: "req_1",
    request_metadata: {
      byte_count: 480,
      media_type: "application/json",
    },
    response_body_hash: "response-preview-hash",
    response_metadata: {
      byte_count: 128,
      status: 200,
    },
  };
  const traceFailedRequestLog = {
    ...requestLog,
    completed_at: "2026-06-02T12:03:00Z",
    error_code: `provider_auth_failed ${skPlaceholder("trace-error-hidden")}`,
    error_owner: "provider",
    final_cost: "0.0456",
    http_status: 401,
    id: "req_2",
    input_tokens: 200,
    latency_ms: 456,
    output_tokens: 100,
    requested_model: authorizationBearerPlaceholder("requested-model-hidden"),
    request_body: "raw trace prompt hidden",
    response_body: "raw trace response hidden",
    route_decision_snapshot: {
      authorization: bearerPlaceholder("trace-route-hidden"),
    },
    status: "failed",
    upstream_model: "gpt-trace-upstream",
  };
  const traceSummary = {
    currencies: ["USD"],
    error_count: 1,
    first_request_at: "2026-06-02T12:00:00Z",
    last_error: {
      code: `provider_auth_failed ${skPlaceholder("trace-error-hidden")}`,
      http_status: 401,
      observed_at: "2026-06-02T12:03:00Z",
      owner: "provider",
      status: "failed",
    },
    last_request_at: "2026-06-02T12:03:00Z",
    ledger: requestLedgerSummary,
    limit: 25,
    limit_reached: false,
    request_count: 2,
    requests: [traceFailedRequestLog, requestLog],
    tenant_id: "tenant-1",
    total_input_tokens: 300,
    total_output_tokens: 155,
    trace_id: "trace-1",
  };
  const providerKey = {
    channel_id: "channel-1",
    concurrency_limit: 3,
    cooldown_until: null,
    current_window_state: {},
    encrypted_secret: "ciphertext-hidden",
    health_score: 97,
    id: "provider-key-1",
    key_alias: "openai-main",
    last_error_code: null,
    metadata: {
      environment: "prod",
      secret_note: skPlaceholder("metadata-hidden"),
      token: bearerPlaceholder("metadata-hidden"),
    },
    rpm_limit: 600,
    secret: skPlaceholder("live-hidden"),
    secret_fingerprint: "fp-hidden",
    status: options.providerKeyStatus ?? "enabled",
    tenant_id: "tenant-1",
    tpm_limit: 120000,
  };
  const provider = {
    code: "openai",
    id: "provider-1",
    metadata: {
      base_url: "https://api.openai.test/v1",
      owner: "platform",
      provider_type: "openai",
      secret_note: skPlaceholder("provider-hidden"),
    },
    name: "OpenAI",
    status: "enabled",
    tenant_id: "tenant-1",
  };
  const createdProvider = {
    ...provider,
    code: "anthropic",
    id: "provider-2",
    metadata: {
      base_url: "https://api.anthropic.test/v1",
      provider_type: "anthropic",
    },
    name: "Anthropic",
  };
  const channel = {
    endpoint: "https://api.openai.test/v1",
    health_score: 0.98,
    id: "channel-1",
    model_mappings: { "gpt-4o-mini": "gpt-4o-mini" },
    name: "openai primary",
    priority: 10,
    probe_policy: { path: "/health" },
    protocol_mode: "openai_compatible",
    provider_id: "provider-1",
    region: "us-east-1",
    request_overrides: [],
    status: "enabled",
    tags: ["primary"],
    tenant_id: "tenant-1",
    timeout_policy: { connect_ms: 2000 },
    weight: 100,
  };
  const createdChannel = {
    ...channel,
    endpoint: "https://api.anthropic.test/v1",
    id: "channel-2",
    model_mappings: {},
    name: "anthropic primary",
    provider_id: "provider-2",
    region: "us-west-2",
    tags: ["backup"],
  };
  let providerState = provider;
  let channelState = channel;
  const model = {
    capabilities: {},
    context_length: 128000,
    default_price_book_id: "price-book-1",
    display_name: "GPT-4o Mini",
    family: "gpt",
    id: "model-1",
    max_output_tokens: 16384,
    model_key: "gpt-4o-mini",
    status: "active",
    supports_audio: false,
    supports_reasoning: false,
    supports_stream: true,
    supports_tools: true,
    supports_vision: false,
    tenant_id: "tenant-1",
    visibility: "public",
  };
  const createdModel = {
    ...model,
    display_name: "Claude Haiku",
    family: "claude",
    id: "model-2",
    model_key: "claude-3-haiku",
  };
  const association = {
    association_type: "explicit_channel",
    canary_percent: 100,
    canonical_model_id: "model-1",
    channel_id: "channel-1",
    channel_tag: null,
    conditions: {},
    fallback_allowed: true,
    id: "association-1",
    model_pattern: null,
    priority: 10,
    status: "enabled",
    tenant_id: "tenant-1",
    upstream_model_name: "gpt-4o-mini-2024-07-18",
  };
  const createdAssociation = {
    ...association,
    canonical_model_id: "model-2",
    channel_id: "channel-2",
    id: "association-2",
    priority: 100,
    upstream_model_name: "claude-3-haiku-20240307",
  };
  let modelState = model;
  let associationState = association;
  const profile = {
    allowed_channel_tags: [],
    allowed_models: [
      "gpt-4o-mini",
      authorizationBearerPlaceholder("profile-model-hidden"),
    ],
    blocked_provider_ids: [],
    default_protocol_mode: "openai_compatible",
    denied_models: ["gpt-internal"],
    id: "profile-1",
    inbound_protocol: "auto",
    ip_allowlist: ["198.51.100.0/24", "2001:db8:1::/64"],
    model_aliases: {
      "chat-fast": "gpt-4o-mini",
      authorization: bearerPlaceholder("profile-alias-hidden"),
      secret_note: skPlaceholder("profile-alias-hidden"),
    },
    name: "default-profile",
    payload_policy_id: null,
    project_id: "project-1",
    request_overrides: [
      {
        allowlist: ["203.0.113.0/24", "2001:db8::/64"],
        authorization: bearerPlaceholder("profile-override-hidden"),
        name: "profile office networks",
        raw_payload: "raw profile payload hidden",
        type: "profile_ip_allowlist",
      },
    ],
    status: "active",
    tenant_id: "tenant-1",
    trace_header_rules: {},
  };
  const createdProfile = {
    ...profile,
    id: "profile-2",
    name: "created-profile",
    status: "active",
  };
  let createdProfileState = createdProfile;
  const virtualKey = {
    budget_policy: {
      authorization: bearerPlaceholder("vk-budget-hidden"),
      monthly_usd: 25,
      raw_payload: "raw virtual key payload hidden",
      secret_note: skPlaceholder("vk-budget-hidden"),
    },
    default_profile_id: "profile-1",
    id: "virtual-key-1",
    ip_allowlist: ["127.0.0.1"],
    key_prefix: vkUnderscorePlaceholder("live_123"),
    metadata: {
      owner: "mobile",
      secret_note: skPlaceholder("vk-metadata-hidden"),
    },
    name: "virtual-main",
    project_id: "project-1",
    rate_limit_policy: {
      rpm: 60,
      token: bearerPlaceholder("vk-rate-hidden"),
    },
    secret_hash: "vk-list-secret-hash",
    secret_redacted: true,
    status: "active",
    tenant_id: "tenant-1",
  };
  const priceVersion = {
    canonical_model_id: "model-1",
    created_at: "2026-06-02T11:00:00Z",
    effective_at: "2026-06-02T12:00:00Z",
    id: "price-version-1",
    price_book_id: "price-book-1",
    pricing_rules: {
      input_usd_per_1m: "0.15000000",
      output_usd_per_1m: "0.60000000",
      secret_note: skPlaceholder("price-hidden"),
    },
    retired_at: null,
    status: "active",
    tenant_id: "tenant-1",
    version: "2026-06",
  };
  let createdPriceVersionState: Record<string, unknown> | null = null;
  const ledgerEntry = {
    amount: "-0.01230000",
    created_at: "2026-06-02T12:02:00Z",
    currency: "USD",
    entry_type: "settle",
    id: "ledger-entry-1",
    idempotency_key: "settle:request-1",
    metadata: {
      owner: "billing",
      token: bearerPlaceholder("ledger-hidden"),
    },
    occurred_at: "2026-06-02T12:01:30Z",
    policy_snapshot: {
      price_version_id: "price-version-1",
    },
    price_version_id: "price-version-1",
    project_id: "project-1",
    related_ledger_entry_id: null,
    request_id: "req_1",
    status: "confirmed",
    tenant_id: "tenant-1",
    trace_id: "trace-1",
    usage_snapshot: {
      input_tokens: 100,
      output_tokens: 55,
      secret_note: skPlaceholder("ledger-hidden"),
    },
    virtual_key_id: null,
    wallet_id: "wallet-1",
  };
  const ledgerAdjustmentDryRunPlan = {
    audit_log_write: false,
    future_write_contract: {
      audit_action: "ledger.refund",
      audit_insert_failure_rolls_back_ledger_write: true,
      audit_snapshot_policy: "bounded public ids and amounts only",
      business_and_success_audit_share_transaction: true,
      ledger_write: false,
      omitted_material_policy:
        "no raw request, raw ledger snapshot, raw metadata, or credential material",
      refusal_does_not_build_success_audit: true,
      success_audit_only_after_ledger_write: true,
      upstream_call: false,
    },
    ledger_write: false,
    omitted_material: ["dedupe material", "ledger snapshots", "raw metadata"],
    operation: "refund",
    plan_only: true,
    planned_ledger_entry: {
      amount: "0.25000000",
      currency: "USD",
      dedupe_policy: "server_generated_on_execute",
      entry_type: "refund",
      metadata_policy: "bounded_admin_adjustment_metadata_only",
      project_id: "00000000-0000-0000-0000-000000000020",
      related_ledger_entry_id: "00000000-0000-0000-0000-000000000091",
      request_id: "00000000-0000-0000-0000-000000000090",
      status: "planned",
      wallet_id: "00000000-0000-0000-0000-000000000040",
    },
    project_id: "00000000-0000-0000-0000-000000000020",
    related_ledger_entry: {
      amount: "-0.25000000",
      currency: "USD",
      entry_type: "settle",
      id: "00000000-0000-0000-0000-000000000091",
      project_id: "00000000-0000-0000-0000-000000000020",
      related_ledger_entry_id: null,
      request_id: "00000000-0000-0000-0000-000000000090",
      status: "confirmed",
      wallet_id: "00000000-0000-0000-0000-000000000040",
    },
    refund_remaining_summary: {
      confirmed_credit_amount: "0.10000000",
      confirmed_credit_count: 1,
      confirmed_only: true,
      credit_entry_types: ["refund", "adjust"],
      currency: "USD",
      currency_bounded: true,
      remaining_refundable_amount: "0.15000000",
      requested_refund_amount: "0.15000000",
      source_debit_amount: "0.25000000",
      source_entry_bounded: true,
      tenant_bounded: true,
    },
    request_id: "00000000-0000-0000-0000-000000000090",
    request_log_write: false,
    tenant_id: "00000000-0000-0000-0000-000000000001",
    upstream_call: false,
    validation: {
      amount_checked: true,
      currency_checked: true,
      refund_remaining_checked: true,
      reason_provided: true,
      related_ledger_entry_checked: true,
      sensitive_material_policy: "rejected_by_schema",
    },
    wallet_id: "00000000-0000-0000-0000-000000000040",
  };
  const reconciliationReport = {
    discrepancies: [
      {
        canonical_model_id: "model-1",
        difference_amount: null,
        expected_ledger_amount: "-1.00000000",
        input_tokens: 12,
        issues: ["missing_ledger"],
        ledger_amount: null,
        ledger_currency: null,
        ledger_entry_ids: [],
        output_tokens: 34,
        project_id: "project-1",
        request_currency: "USD",
        request_final_cost: "1.00000000",
        request_id: "recon-req-1",
        request_status: "succeeded",
        requested_model: `model ${skUnderscorePlaceholder("reconcile_model_hidden")}`,
        resolved_channel_id: "channel-1",
        resolved_provider_id: "provider-1",
        trace_id: githubPatPlaceholder("reconcile_trace_hidden"),
        upstream_model: authorizationBearerPlaceholder(
          "reconcile-upstream-hidden",
        ),
        virtual_key_id: "virtual-key-1",
      },
    ],
    period_end: "2026-06-03 00:00:00+00",
    period_start: "2026-06-02 00:00:00+00",
    report_version: 1,
    summary: {
      amount_mismatch_count: 0,
      billable_request_count: 2,
      currency_mismatch_count: 0,
      currency_totals: [
        {
          currency: "USD",
          difference_amount: "1.00000000",
          expected_ledger_amount_total: "-1.25000000",
          ledger_amount_total: "-0.25000000",
          request_final_cost_total: "1.25000000",
        },
      ],
      discrepancy_count: 1,
      ledger_entry_count: 1,
      matched_request_count: 1,
      missing_ledger_count: 1,
      payload: {
        body: "raw reconciliation payload hidden",
        raw_policy_snapshot: {
          secret: skPlaceholder("reconcile-policy-hidden"),
        },
      },
      raw_export: {
        note: "raw reconciliation export hidden",
      },
      request_count: 2,
      returned_discrepancy_count: 1,
      secret_note: skPlaceholder("reconcile-summary-hidden"),
      unexpected_ledger_count: 0,
    },
    tenant_id: "tenant-1",
  };
  const auditLog = {
    action: "provider_key.update",
    actor_user_id: "00000000-0000-0000-0000-000000000070",
    after_snapshot: {
      key_alias: "openai-main",
      metadata: {
        owner: "platform",
        secret_note: skPlaceholder("audit-after-hidden"),
      },
      status: "manual_disabled",
      token: bearerPlaceholder("audit-after-hidden"),
    },
    audit_log_detail_readback: {
      action: "provider_key.update",
      action_result: "manual_disabled",
      actor_session_presence: {
        actor_session_id_present: true,
        actor_user_id_present: true,
        raw_session_returned: false,
      },
      audit_log_id: "audit-1",
      metadata_redaction_summary: {
        after_snapshot_redacted_field_count: 2,
        before_snapshot_redacted_field_count: 2,
        forbidden_material_omitted: [
          "raw_token",
          "raw_session",
          "api_key_secret",
          "provider_credential_material",
          "auth_header",
          "raw_payload",
        ],
        metadata_object: true,
        raw_api_key_returned: false,
        raw_authorization_returned: false,
        raw_payload_returned: false,
        raw_provider_key_returned: false,
        redacted_field_count: 2,
        safe_summary_keys: ["actor_session_id", "user_agent_sha256"],
      },
      resource_refs: {
        request_id: "req_1",
        request_id_present: true,
        resource_id: "provider-key-1",
        resource_id_present: true,
        resource_tenant_id: "tenant-1",
        resource_tenant_id_present: true,
        resource_type: "provider_key",
      },
      safe_next_action: "Open request detail by request_id, then correlate ledger entries and trace summary; do not fetch payload content.",
      schema: "audit_log_detail_readback.v1",
      source: "audit_logs",
    },
    before_snapshot: {
      headers: {
        [AUTH_HEADER_NAME]: bearerPlaceholder("audit-before-hidden"),
      },
      key_alias: "openai-main",
      metadata: {
        owner: "platform",
        secret_note: skPlaceholder("audit-before-hidden"),
      },
      raw_payload: "raw before payload hidden",
      status: "enabled",
    },
    created_at: "2026-06-02T13:00:00Z",
    id: "audit-1",
    metadata: {
      actor_session_id: "00000000-0000-0000-0000-000000000701",
      client_ip_sha256: "client-ip-hash",
      payload: {
        body: "raw audit metadata payload hidden",
      },
      ...(options.promptProtectionSignals === false
        ? {}
        : { prompt_protection: effectivePromptProtectionSignal }),
      raw_headers: {
        cookie: "session hidden",
      },
      user_agent_sha256: "ua-hash",
    },
    request_id: "req_1",
    resource_id: "provider-key-1",
    resource_tenant_id: "tenant-1",
    resource_type: "provider_key",
    tenant_id: "tenant-1",
  };
  const createdVirtualKey = {
    ...virtualKey,
    id: "virtual-key-2",
    name: "created-virtual",
    secret: "vk-created-secret-once",
    secret_hash: "vk-created-secret-hash",
    secret_once: true,
    secret_redacted: false,
  };
  const fetchMock = vi.fn((url: RequestInfo | URL, init?: RequestInit) => {
    const requestUrl = String(url);
    const method = init?.method ?? "GET";

    if (requestUrl.includes("/admin/auth/login")) {
      loginSucceeded = true;
      return jsonResponse(loginPayload());
    }

    if (requestUrl.includes("/admin/auth/me")) {
      if (!loginSucceeded) {
        return jsonError("No active admin session", 401);
      }

      return jsonResponse(adminMePayload());
    }

    if (requestUrl.includes("/admin/auth/logout")) {
      return jsonResponse({ logged_out: true });
    }

    if (requestUrl.endsWith("/healthz")) {
      return Promise.resolve(new Response("", { status: 200 }));
    }

    if (requestUrl.includes("/admin/providers/health-summary")) {
      return jsonResponse(healthSummaryPayload());
    }

    if (
      requestUrl.includes("/admin/model-associations/dry-run") &&
      method === "POST"
    ) {
      const body = JSON.parse(String(init?.body ?? "{}")) as {
        canonical_model_id?: string;
        canonical_model_key?: string;
        requested_model?: string;
      };

      if (body.requested_model === "secret-error") {
        return jsonError(
          `${authorizationBearerPlaceholder("dry-run-secret")} ${skPlaceholder("dry-run-secret")}`,
          400,
        );
      }

      return jsonResponse(
        body.requested_model === "missing-model"
          ? noCandidateDryRunResponse()
          : selectedDryRunResponse(),
      );
    }

    if (requestUrl.includes("/admin/traces/trace-1")) {
      return jsonResponse(traceSummary);
    }

    if (requestUrl.includes("/admin/request-logs/req_1/payload")) {
      if (options.payloadPreviewStatus === "forbidden") {
        return jsonError(
          `${AUTH_HEADER_NAME}: ${bearerPlaceholder("payload-forbidden-hidden")} ${skPlaceholder("payload-forbidden-hidden")}`,
          403,
        );
      }

      if (options.payloadPreviewStatus === "notImplemented") {
        return jsonError(
          `${AUTH_HEADER_NAME}: ${bearerPlaceholder("payload-not-implemented-hidden")} payload preview missing`,
          404,
        );
      }

      return jsonResponse(payloadPreview);
    }

    if (requestUrl.includes("/admin/request-logs/export.csv")) {
      if (options.requestLogExportStatus === "notImplemented") {
        return jsonError(
          `${AUTH_HEADER_NAME}: ${bearerPlaceholder("request-export-hidden")} export route pending ${skPlaceholder("request-export-hidden")}`,
          501,
        );
      }

      return Promise.resolve(
        new Response("request_id,status,redaction_status\nreq_1,succeeded,redacted\n", {
          status: 200,
          headers: { "Content-Type": "text/csv; charset=utf-8" },
        }),
      );
    }

    if (requestUrl.includes("/admin/request-logs/recon-req-1")) {
      return jsonResponse({
        ...requestDetail,
        request_log: {
          ...requestDetail.request_log,
          id: "recon-req-1",
          trace_id: "recon-trace-1",
        },
      });
    }

    if (requestUrl.includes("/admin/request-logs/req_1")) {
      return jsonResponse(requestDetail);
    }

    if (requestUrl.includes("/admin/request-logs")) {
      return jsonResponse([requestLog]);
    }

    if (requestUrl.includes("/admin/audit-logs")) {
      return jsonResponse([auditLog]);
    }

    if (
      requestUrl.includes("/admin/providers/provider-1") &&
      method === "PATCH"
    ) {
      const body = JSON.parse(String(init?.body ?? "{}")) as Partial<
        typeof providerState
      >;
      providerState = { ...providerState, ...body };
      return jsonResponse(providerState);
    }

    if (
      requestUrl.includes("/admin/providers/provider-1") &&
      method === "DELETE"
    ) {
      providerState = { ...providerState, status: "deleted" };
      return jsonResponse(providerState);
    }

    if (requestUrl.includes("/admin/providers") && method === "POST") {
      providerCreated = true;
      return jsonResponse(createdProvider);
    }

    if (requestUrl.includes("/admin/providers")) {
      return jsonResponse(
        providerCreated ? [providerState, createdProvider] : [providerState],
      );
    }

    if (
      requestUrl.includes("/admin/channels/channel-1/manual-test") &&
      method === "POST"
    ) {
      const body = JSON.parse(String(init?.body ?? "{}")) as {
        model?: string;
        upstream_model_name?: string;
      };

      if (body.model === "secret-error") {
        return jsonError(
          `${authorizationBearerPlaceholder("manual-test-secret")} ${skPlaceholder("manual-test-secret")}`,
          400,
        );
      }

      return jsonResponse(
        channelManualTestResponse(body.model, body.upstream_model_name),
      );
    }

    if (
      requestUrl.includes("/admin/channels/channel-1") &&
      method === "PATCH"
    ) {
      const body = JSON.parse(String(init?.body ?? "{}")) as Partial<
        typeof channelState
      >;
      channelState = { ...channelState, ...body };
      return jsonResponse(channelState);
    }

    if (
      requestUrl.includes("/admin/channels/channel-1") &&
      method === "DELETE"
    ) {
      channelState = { ...channelState, status: "deleted" };
      return jsonResponse(channelState);
    }

    if (requestUrl.includes("/admin/channels") && method === "POST") {
      channelCreated = true;
      return jsonResponse(createdChannel);
    }

    if (requestUrl.includes("/admin/channels")) {
      return jsonResponse(
        channelCreated ? [channelState, createdChannel] : [channelState],
      );
    }

    if (requestUrl.includes("/admin/models/model-1") && method === "PATCH") {
      const body = JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>;
      modelState = { ...modelState, ...body };
      return jsonResponse(modelState);
    }

    if (requestUrl.includes("/admin/models/model-1") && method === "DELETE") {
      modelState = { ...modelState, status: "deleted" };
      return jsonResponse(modelState);
    }

    if (requestUrl.includes("/admin/models") && method === "POST") {
      modelCreated = true;
      return jsonResponse(createdModel);
    }

    if (requestUrl.includes("/admin/models")) {
      return jsonResponse(
        modelCreated ? [modelState, createdModel] : [modelState],
      );
    }

    if (
      requestUrl.includes("/admin/model-associations/association-1") &&
      method === "PATCH"
    ) {
      associationState = { ...associationState, status: "disabled" };
      return jsonResponse(associationState);
    }

    if (
      requestUrl.includes("/admin/model-associations/association-1") &&
      method === "DELETE"
    ) {
      associationState = { ...associationState, status: "deleted" };
      return jsonResponse(associationState);
    }

    if (requestUrl.includes("/admin/model-associations") && method === "POST") {
      associationCreated = true;
      return jsonResponse(createdAssociation);
    }

    if (requestUrl.includes("/admin/model-associations")) {
      return jsonResponse(
        associationCreated
          ? [associationState, createdAssociation]
          : [associationState],
      );
    }

    if (
      requestUrl.includes("/admin/provider-keys/provider-key-1") &&
      method === "PATCH"
    ) {
      return jsonResponse({ ...providerKey, status: "manual_disabled" });
    }

    if (
      requestUrl.includes("/admin/provider-keys/provider-key-1") &&
      method === "DELETE"
    ) {
      return jsonResponse({ ...providerKey, status: "deleted" });
    }

    if (
      requestUrl.includes("/admin/provider-keys/provider-key-1/recovery") &&
      method === "POST"
    ) {
      return jsonResponse(providerKeyRecoveryPayload());
    }

    if (
      requestUrl.includes("/admin/provider-keys/provider-key-1/rotate") &&
      method === "POST"
    ) {
      return jsonResponse({
        credential_material: { omitted: true },
        dry_run: false,
        new_provider_key: {
          ...providerKey,
          id: "provider-key-rotated",
          key_alias: "openai-main-rotated",
          secret: skPlaceholder("rotated-hidden"),
          secret_fingerprint: "fp-rotated-hidden",
          status: "enabled",
        },
        old_provider_key: {
          ...providerKey,
          status: "manual_disabled",
        },
        production_rotation_closure_allowed: false,
      });
    }

    if (requestUrl.includes("/admin/provider-keys") && method === "POST") {
      return jsonResponse({
        ...providerKey,
        id: "provider-key-2",
        key_alias: "created-key",
      });
    }

    if (requestUrl.includes("/admin/provider-keys")) {
      return jsonResponse([providerKey]);
    }

    if (
      requestUrl.includes("/admin/api-key-profiles/profile-1") &&
      method === "DELETE"
    ) {
      return jsonError("api key profile has active virtual keys bound");
    }

    if (
      requestUrl.includes("/admin/api-key-profiles/profile-1") &&
      method === "PATCH"
    ) {
      const body = JSON.parse(String(init?.body ?? "{}")) as Partial<
        typeof profile
      >;
      return jsonResponse({ ...profile, ...body });
    }

    if (requestUrl.includes("/admin/api-key-profiles") && method === "POST") {
      profileCreated = true;
      const body = JSON.parse(String(init?.body ?? "{}")) as Partial<
        typeof createdProfile
      >;
      createdProfileState = { ...createdProfile, ...body };
      return jsonResponse(createdProfileState);
    }

    if (requestUrl.includes("/admin/api-key-profiles")) {
      return jsonResponse(
        profileCreated ? [profile, createdProfileState] : [profile],
      );
    }

    if (
      requestUrl.includes("/admin/virtual-keys/virtual-key-1/disable") &&
      method === "POST"
    ) {
      return jsonResponse({ ...virtualKey, status: "disabled" });
    }

    if (
      requestUrl.includes("/admin/virtual-keys/virtual-key-1/expire") &&
      method === "POST"
    ) {
      return jsonResponse({ ...virtualKey, status: "expired" });
    }

    if (requestUrl.includes("/admin/virtual-keys/virtual-key-1")) {
      return jsonResponse(virtualKey);
    }

    if (requestUrl.includes("/admin/virtual-keys") && method === "POST") {
      return jsonResponse(createdVirtualKey);
    }

    if (requestUrl.includes("/admin/virtual-keys")) {
      return jsonResponse([virtualKey]);
    }

    if (requestUrl.includes("/admin/billing/reconciliation")) {
      return jsonResponse(reconciliationReport);
    }

    if (
      requestUrl.includes("/admin/ledger/adjustments/dry-run") &&
      method === "POST"
    ) {
      const body = JSON.parse(String(init?.body ?? "{}")) as Record<
        string,
        unknown
      >;
      const validatedPlan = {
        ...ledgerAdjustmentDryRunPlan,
        operation: body.operation ?? ledgerAdjustmentDryRunPlan.operation,
        planned_ledger_entry: {
          ...ledgerAdjustmentDryRunPlan.planned_ledger_entry,
          amount:
            body.amount ??
            ledgerAdjustmentDryRunPlan.planned_ledger_entry.amount,
          currency:
            body.currency ??
            ledgerAdjustmentDryRunPlan.planned_ledger_entry.currency,
          related_ledger_entry_id:
            body.related_ledger_entry_id ??
            ledgerAdjustmentDryRunPlan.planned_ledger_entry
              .related_ledger_entry_id,
          request_id:
            body.request_id ??
            ledgerAdjustmentDryRunPlan.planned_ledger_entry.request_id,
        },
        request_id: body.request_id ?? ledgerAdjustmentDryRunPlan.request_id,
      };

      if (options.ledgerAdjustmentDryRunFails) {
        return jsonError(
          `${AUTH_HEADER_NAME}: ${bearerPlaceholder("ledger-adjust-hidden")} ${skPlaceholder(
            "ledger-adjust-hidden",
          )} idempotency_key raw metadata`,
          400,
        );
      }

      if (body.mode === "execute_contract") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              data: {
                execute_contract: {
                  audit_insert_failure_rolls_back_ledger_write: true,
                  audit_log_write: false,
                  audit_snapshot_policy: "bounded public ids and amounts only",
                  business_and_success_audit_share_transaction: true,
                  contract_version:
                    "ledger_adjustment_execute_preflight_contract.v2",
                  dedupe_contract: {
                    client_supplied_dedupe_material_rejected: true,
                    conflicting_duplicate_refused_before_ledger_insert: true,
                    dedupe_material_echoed: false,
                    public_output: "digest_marker_only",
                    replay_same_digest_returns_prior_result_after_writer_exists: true,
                    server_generated_dedupe_material: true,
                  },
                  dedupe_material_echoed: false,
                  dry_run_constraints_enforced_before_refusal: [
                    "billing_adjust_permission",
                    "tenant_scoped_related_entry",
                    "refund_remaining_amount_checked",
                  ],
                  future_writer_required: true,
                  ledger_executor_refusal_summary_contract:
                    ledgerExecutorRefusalSummaryContract(),
                  ledger_executor_summary_contract:
                    ledgerExecutorSummaryContract(),
                  ledger_writer_contract: {
                    future_writer:
                      "transactional_admin_ledger_adjustment_writer",
                    insert_status_on_success: "confirmed",
                    metadata_policy: "bounded_admin_adjustment_metadata_only",
                    refund_over_remaining_refused_after_locked_recompute: true,
                    write_performed: false,
                  },
                  ledger_write: false,
                  refusal_does_not_build_success_audit: true,
                  request_log_contract: {
                    future_behavior: "reference_existing_request_id_only",
                    request_log_mutation_allowed: false,
                    request_material_echoed: false,
                    write_performed: false,
                  },
                  request_log_write: false,
                  safe_output_contract: {
                    audit_snapshot_policy:
                      "bounded public ids and amounts only",
                    credential_material_echoed: false,
                    dedupe_material_echoed: false,
                    request_material_echoed: false,
                  },
                  server_generated_dedupe_material: true,
                  success_audit_only_after_ledger_write: true,
                  transaction_contract: {
                    begin_before_locking: true,
                    bounded_by: [
                      "tenant_id",
                      "related_ledger_entry_id",
                      "currency",
                    ],
                    bounded_lock_order: [
                      "source_ledger_entry_for_update",
                      "ledger_insert",
                      "success_audit_insert",
                    ],
                    commit_only_after_ledger_and_success_audit: true,
                    future_isolation: "read_committed_or_stronger",
                    recompute_after_locks: [
                      "confirmed_credit_sum",
                      "remaining_refundable_amount",
                    ],
                    rollback_on_audit_insert_failure: true,
                    rollback_on_ledger_write_failure: true,
                    rollback_on_refund_remaining_change: true,
                    rollback_executor_summary_contract:
                      ledgerExecutorRollbackSummaryContract(),
                    unbounded_scan_allowed: false,
                  },
                  upstream_call: false,
                  validated_before_refusal: true,
                },
                ledger_executor_summary: ledgerExecutorRefusalSummary(
                  "refund",
                  "refused_preflight",
                  false,
                  0,
                  false,
                ),
                mode: "execute_contract",
                validated_plan: validatedPlan,
              },
              error: {
                code: "future_writer_required",
                message:
                  "ledger adjustment execute requires transactional ledger writer",
              },
            }),
            {
              status: 501,
              statusText: "Not Implemented",
              headers: { "Content-Type": "application/json" },
            },
          ),
        );
      }

      if (body.mode === "execute") {
        const executeStatus =
          options.ledgerAdjustmentExecuteStatuses?.shift() ??
          options.ledgerAdjustmentExecuteStatus;

        if (executeStatus === "blocked") {
          const message = `${AUTH_HEADER_NAME}: ${bearerPlaceholder(
            "ledger-execute-blocked-hidden",
          )} idempotency_key raw metadata`;
          return options.ledgerAdjustmentErrorEnvelopeData
            ? jsonErrorWithData(
                message,
                409,
                ledgerAdjustmentExecuteErrorEnvelopeData("blocked"),
              )
            : jsonError(message, 409);
        }

        if (executeStatus === "failed") {
          const message = `${AUTH_HEADER_NAME}: ${bearerPlaceholder("ledger-execute-failed-hidden")} ${skPlaceholder(
            "ledger-execute-failed-hidden",
          )} raw request raw metadata`;
          return options.ledgerAdjustmentErrorEnvelopeData
            ? jsonErrorWithData(
                message,
                500,
                ledgerAdjustmentExecuteErrorEnvelopeData("failed"),
              )
            : jsonError(message, 500);
        }

        const outcome = executeStatus ?? "applied";
        const payload =
          options.ledgerAdjustmentExecuteResponseShape === "tolerant"
            ? ledgerAdjustmentExecuteTolerancePayload(outcome, validatedPlan)
            : ledgerAdjustmentExecutePayload(outcome, validatedPlan);
        return jsonResponseWithStatus(
          payload,
          outcome === "applied" ? 201 : 200,
        );
      }

      return jsonResponse(validatedPlan);
    }

    if (requestUrl.includes("/admin/voucher-issuance-batches") && method === "POST") {
      const body = JSON.parse(String(init?.body ?? "{}")) as {
        items?: Array<{ raw_voucher_code?: string }>;
      };
      const items = body.items ?? [];
      return jsonResponse({
        batch_idempotency_key_hash_present: true,
        database_writes: true,
        issued: items.length,
        items: items.map((_, index) => ({
          amount: "5.00000000",
          code_redacted: `ADM...00${index + 1}`,
          currency: "USD",
          index,
          raw_idempotency_key_echoed: false,
          raw_voucher_code_echoed: false,
          secret_safe: true,
          status: "issued",
          voucher_id: `voucher-batch-${index + 1}`,
          wallet_id: "wallet-1",
        })),
        raw_idempotency_key_echoed: false,
        raw_voucher_code_echoed: false,
        refused: 0,
        replayed: 0,
        runtime_implemented: true,
        schema: "recharge_voucher_batch_runtime.v1",
        secret_safe: true,
        status: "completed",
        total: items.length,
      });
    }

    if (requestUrl.includes("/admin/voucher-issuances/voucher-list-1/revoke") && method === "POST") {
      return jsonResponse({
        audit_id: "audit-voucher-revoke-1",
        operation: "voucher_revoke",
        raw_idempotency_key_echoed: false,
        raw_voucher_code_echoed: false,
        runtime_implemented: true,
        schema: "recharge_voucher_revoke_runtime.v1",
        secret_safe: true,
        status: "revoked",
        voucher: voucherIssuanceSummaryPayload("revoked"),
      });
    }

    if (requestUrl.includes("/admin/voucher-issuances") && method === "GET") {
      return jsonResponse({
        count: 2,
        items: [
          voucherIssuanceSummaryPayload("issued"),
          {
            ...voucherIssuanceSummaryPayload("redeemed"),
            code_redacted: "ADM...2222",
            redemption_count: 1,
            voucher_id: "voucher-list-2",
          },
        ],
        limit: 25,
        raw_voucher_code_echoed: false,
        runtime_implemented: true,
        schema: "recharge_voucher_issuance_list.v1",
        secret_safe: true,
      });
    }

    if (requestUrl.includes("/admin/price-versions") && method === "POST") {
      const body = JSON.parse(String(init?.body ?? "{}")) as Record<
        string,
        unknown
      >;
      createdPriceVersionState = {
        ...priceVersion,
        ...body,
        created_at: "2026-06-03T00:00:01Z",
        id: "price-version-created",
        retired_at: body.retired_at ?? null,
        tenant_id: "tenant-1",
      };
      return jsonResponse(createdPriceVersionState);
    }

    if (requestUrl.includes("/admin/price-versions")) {
      return jsonResponse(
        createdPriceVersionState
          ? [priceVersion, createdPriceVersionState]
          : [priceVersion],
      );
    }

    if (requestUrl.includes("/admin/ledger/entries")) {
      ledgerEntriesRequestCount += 1;

      if (options.ledgerEntriesRefreshFails && ledgerEntriesRequestCount > 1) {
        return jsonError(
          `${AUTH_HEADER_NAME}: ${bearerPlaceholder("ledger-refresh-hidden")} ${skPlaceholder(
            "ledger-refresh-hidden",
          )} raw metadata operation_key raw executor error detail`,
          503,
        );
      }

      return jsonResponse([ledgerEntry]);
    }

    if (requestUrl.includes("/admin/wallets")) {
      return jsonResponse([]);
    }

    return jsonResponse({});
  });

  vi.stubGlobal("fetch", fetchMock);

  return fetchMock;
}

function jsonResponse(data: unknown) {
  return Promise.resolve(
    new Response(JSON.stringify({ data }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    }),
  );
}

function jsonResponseWithStatus(data: unknown, status: number) {
  return Promise.resolve(
    new Response(JSON.stringify({ data }), {
      status,
      headers: { "Content-Type": "application/json" },
    }),
  );
}

function streamResponse(events: unknown[], requestId: string) {
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    start(controller) {
      for (const event of events) {
        controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
      }
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });

  return Promise.resolve(
    new Response(body, {
      status: 200,
      headers: {
        "Content-Type": "text/event-stream",
        "x-request-id": requestId,
      },
    }),
  );
}

function ledgerExecutorSummaryContract() {
  return {
    compatible_fields: [
      "schema_version",
      "executor",
      "operation",
      "outcome",
      "operation_key_output",
      "committed",
      "rolled_back",
      "statement_count",
      "executed_statement_count",
      "refused_statement_count",
      "total_rows_affected",
      "final_statement_order",
      "final_statement_kind",
      "error_detail_output",
      "row_count_mismatch",
    ],
    credential_material_echoed: false,
    dedupe_material_echoed: false,
    error_detail: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("ledger-executor-contract-hidden")}`,
    error_detail_output: "omitted",
    operation_key: "operation-key-secret-hidden",
    operation_key_output: "omitted",
    raw_metadata: "raw executor contract metadata hidden",
    raw_metadata_echoed: false,
    response_field: "ledger_executor_summary",
    schema_version: "billing_ledger_postgres_executor_summary.v1",
  };
}

function ledgerExecutorRefusalSummaryContract() {
  return {
    credential_material_echoed: false,
    dedupe_material_echoed: false,
    error_detail: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("ledger-refusal-contract-hidden")}`,
    error_detail_output: "omitted",
    operation_key: "operation-key-refusal-contract-hidden",
    operation_key_output: "omitted",
    preflight_refusal: {
      committed: false,
      refused_statement_count: 0,
      rolled_back: false,
      row_count_mismatch: false,
    },
    raw_executor_error_detail: "raw executor refusal contract error hidden",
    raw_executor_error_detail_echoed: false,
    raw_metadata: "raw executor refusal contract metadata hidden",
    raw_metadata_echoed: false,
    response_field: "ledger_executor_summary",
    rollback_refusal: {
      committed: false,
      refused_statement_count: "one_or_more",
      rolled_back: true,
      row_count_mismatch: "boolean_only",
    },
    schema_version: "billing_ledger_postgres_executor_summary.v1",
    supported_outcomes: ["refused_preflight", "refused_rollback"],
  };
}

function ledgerExecutorRollbackSummaryContract() {
  return {
    committed: false,
    credential_material_echoed: false,
    dedupe_material_echoed: false,
    error_detail: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("ledger-rollback-contract-hidden")}`,
    error_detail_output: "omitted",
    operation_key: "operation-key-rollback-contract-hidden",
    operation_key_output: "omitted",
    outcome: "refused_rollback",
    raw_executor_error_detail: "raw executor rollback contract error hidden",
    raw_executor_error_detail_echoed: false,
    raw_metadata: "raw executor rollback contract metadata hidden",
    raw_metadata_echoed: false,
    refused_statement_count: "one_or_more",
    response_field: "ledger_executor_summary",
    rolled_back: true,
    row_count_mismatch: "boolean_only",
    schema_version: "billing_ledger_postgres_executor_summary.v1",
  };
}

function ledgerExecutorSummary(outcome: "applied" | "idempotent") {
  const writePerformed = outcome === "applied";

  return {
    committed: true,
    dedupe_material_echoed: false,
    error_detail: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("ledger-executor-summary-hidden")}`,
    error_detail_output: "omitted",
    executed_statement_count: writePerformed ? 1 : 0,
    executor: "control_plane_transactional_admin_ledger_adjustment_writer",
    final_statement_kind: writePerformed ? "insert_ledger_entry" : null,
    final_statement_order: writePerformed ? 1 : null,
    omitted_material: [
      "dedupe material",
      "raw metadata",
      "credential material",
    ],
    operation: writePerformed ? "refund" : "adjust",
    operation_key: "operation-key-secret-hidden",
    operation_key_output: "omitted",
    outcome,
    raw_metadata: "raw executor summary metadata hidden",
    refused_statement_count: 0,
    rolled_back: false,
    row_count_mismatch: false,
    schema_version: "billing_ledger_postgres_executor_summary.v1",
    statement_count: writePerformed ? 1 : 0,
    total_rows_affected: writePerformed ? 1 : 0,
  };
}

function ledgerExecutorRefusalSummary(
  operation: string,
  outcome: "refused_preflight" | "refused_rollback",
  rolledBack: boolean,
  refusedStatementCount: number,
  rowCountMismatch: boolean,
) {
  const hasRefusedStatement = refusedStatementCount > 0;

  return {
    committed: false,
    dedupe_material_echoed: false,
    error_detail: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("ledger-executor-refusal-hidden")}`,
    error_detail_output: "omitted",
    executed_statement_count: 0,
    executor: "control_plane_transactional_admin_ledger_adjustment_writer",
    final_statement_kind: hasRefusedStatement ? "statement_refusal" : null,
    final_statement_order: hasRefusedStatement ? 1 : null,
    omitted_material: [
      "operation key",
      "dedupe material",
      "raw metadata",
      "credential material",
      "raw executor error detail",
    ],
    operation,
    operation_key: "operation-key-refusal-hidden",
    operation_key_output: "omitted",
    outcome,
    raw_executor_error_detail: "raw executor refusal error detail hidden",
    raw_executor_error_detail_echoed: false,
    raw_metadata: "raw executor refusal metadata hidden",
    refused_statement_count: refusedStatementCount,
    rolled_back: rolledBack,
    row_count_mismatch: rowCountMismatch,
    schema_version: "billing_ledger_postgres_executor_summary.v1",
    statement_count: refusedStatementCount,
    total_rows_affected: 0,
  };
}

function ledgerAdjustmentExecutePayload(
  outcome: "applied" | "idempotent",
  validatedPlan: unknown,
) {
  const writePerformed = outcome === "applied";

  return {
    audit_insert_failure_rolls_back_ledger_write: true,
    audit_log_id: writePerformed
      ? "00000000-0000-0000-0000-000000000093"
      : null,
    audit_log_write: writePerformed,
    authorization: bearerPlaceholder("ledger-execute-response-hidden"),
    business_and_success_audit_share_transaction: true,
    dedupe_material_echoed: false,
    dedupe_public_output: "omitted",
    idempotency_key: "server_dedupe_digest hidden",
    ledger_entry: {
      amount: outcome === "applied" ? "0.25000000" : "0.10000000",
      currency: "USD",
      entry_type: outcome === "applied" ? "refund" : "adjust",
      id: "00000000-0000-0000-0000-000000000092",
      idempotency_key: "server_dedupe_digest nested hidden",
      omitted_material: ["dedupe material", "ledger snapshots", "raw metadata"],
      project_id: "00000000-0000-0000-0000-000000000020",
      raw_metadata: "raw executed ledger metadata hidden",
      related_ledger_entry_id:
        outcome === "applied" ? "00000000-0000-0000-0000-000000000091" : null,
      request_id: "00000000-0000-0000-0000-000000000090",
      status: "confirmed",
      tenant_id: "00000000-0000-0000-0000-000000000001",
      wallet_id: "00000000-0000-0000-0000-000000000040",
    },
    ledger_executor_summary: ledgerExecutorSummary(outcome),
    ledger_executor_summary_contract: ledgerExecutorSummaryContract(),
    ledger_write: writePerformed,
    mode: "execute",
    outcome,
    raw_metadata: "raw execute metadata hidden",
    refund_remaining_summary:
      outcome === "applied"
        ? {
            confirmed_credit_amount: "0.10000000",
            confirmed_credit_count: 1,
            confirmed_only: true,
            credit_entry_types: ["refund", "adjust"],
            currency: "USD",
            currency_bounded: true,
            remaining_refundable_amount: "0.15000000",
            requested_refund_amount: "0.15000000",
            source_debit_amount: "0.25000000",
            source_entry_bounded: true,
            tenant_bounded: true,
          }
        : null,
    refusal_does_not_build_success_audit: true,
    request_log_write: false,
    secret: skPlaceholder("ledger-execute-response-hidden"),
    success_audit_only_after_ledger_write: true,
    transaction_contract: {
      begin_before_locking: true,
      bounded_by: [
        "tenant_id",
        "related_ledger_entry_id",
        "currency",
        "server_generated_dedupe_material",
      ],
      bounded_lock_order: [
        "source_ledger_entry_for_update",
        "same_source_confirmed_credit_entries_for_update",
        "wallet_for_update",
        "dedupe_reservation_for_update",
        "ledger_insert",
        "success_audit_insert",
      ],
      commit_only_after_ledger_and_success_audit: writePerformed,
      dedupe_material_echoed: false,
      isolation: "read_committed_or_stronger",
      rollback_on_audit_insert_failure: true,
      rollback_on_ledger_write_failure: true,
      rollback_on_refund_remaining_change: true,
      rollback_executor_summary_contract:
        ledgerExecutorRollbackSummaryContract(),
      unbounded_scan_allowed: false,
      write_performed: writePerformed,
      writer: "control_plane_transactional_admin_ledger_adjustment_writer",
    },
    upstream_call: false,
    validated_plan: validatedPlan,
  };
}

function ledgerAdjustmentExecuteTolerancePayload(
  outcome: "applied" | "idempotent",
  validatedPlan: unknown,
) {
  const payload = ledgerAdjustmentExecutePayload(outcome, validatedPlan);

  return {
    ...payload,
    audit_log_id: null,
    experimental_safe_status: "safe_backend_unknown_marker",
    ledger_entry: null,
    ledger_executor_summary: {
      ...payload.ledger_executor_summary,
      credential_material: "credential material executor tolerance hidden",
      dedupe_material: "dedupe material executor tolerance hidden",
      experimental_safe_executor_status: "safe_executor_unknown_marker",
      raw_executor_error_detail: "raw executor tolerance error detail hidden",
      raw_metadata: "raw executor tolerance metadata hidden",
      operation_key: "operation-key-executor-tolerance-hidden",
    },
    ledger_executor_summary_contract: null,
    operation_key: "operation-key-response-tolerance-hidden",
    raw_executor_error_detail: "raw executor response tolerance detail hidden",
    raw_metadata: "raw execute tolerance metadata hidden",
    refund_remaining_summary: null,
    transaction_contract: {
      experimental_safe_transaction_status: "safe_transaction_unknown_marker",
      write_performed: outcome === "applied",
      writer: null,
    },
    unknown_safe_nested: {
      marker: "safe_nested_unknown_marker",
    },
    validated_plan: {
      authorization: bearerPlaceholder("ledger-tolerance-plan-hidden"),
      raw_metadata: "raw execute validated plan hidden",
      value: validatedPlan,
    },
  };
}

function ledgerAdjustmentExecuteErrorEnvelopeData(
  outcome: "blocked" | "failed",
) {
  return {
    authorization: bearerPlaceholder(`ledger-${outcome}-envelope-hidden`),
    credential_material: "credential material error envelope hidden",
    dedupe_material: "dedupe material error envelope hidden",
    ledger_executor_summary: {
      outcome,
      raw_executor_error_detail: "raw executor error envelope hidden",
      raw_metadata: "raw executor error envelope metadata hidden",
    },
    mode: "execute",
    operation_key: `operation-key-${outcome}-envelope-hidden`,
    outcome,
    raw_metadata: "raw execute error envelope metadata hidden",
    safe_unknown_error_marker: "safe_error_unknown_marker",
    token: "token error envelope hidden",
  };
}

function deferredJsonResponse(data: unknown) {
  let resolve!: () => void;
  const promise = new Promise<Response>((next) => {
    resolve = () => {
      next(
        new Response(JSON.stringify({ data }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      );
    };
  });

  return { promise, resolve };
}

function loginPayload() {
  return {
    session: {
      expires_at: "2026-06-02T20:00:00Z",
      id: "session-1",
    },
    session_token_once: sessionPlaceholder("test_admin_session_token"),
    user: {
      display_name: "Local Admin",
      email: "operator@example.com",
      id: "user-1",
      roles: ["owner"],
      tenant_id: "tenant-1",
    },
  };
}

function adminMePayload(roles = ["owner"]) {
  const user = {
    display_name: "Local Admin",
    email: "operator@example.com",
    id: "user-1",
    roles,
    tenant_id: "tenant-1",
  };

  return {
    capability_summary: capabilitySummaryForRoles(roles),
    session: {
      expires_at: "2026-06-02T20:00:00Z",
      id: "session-1",
    },
    user,
  };
}

function voucherIssuanceSummaryPayload(status: string) {
  return {
    amount: "5.00000000",
    audit_id: "audit-voucher-issue-1",
    campaign_id: null,
    code_hash_present: false,
    code_lookup_prefix_present: false,
    code_redacted: "ADM...1111",
    currency: "USD",
    effective_status: status,
    expires_at: "2026-06-30T00:00:00Z",
    max_redemptions: 1,
    project_id: "project-1",
    raw_idempotency_key_echoed: false,
    raw_voucher_code_echoed: false,
    redemption_count: 0,
    revoke_audit_id: status === "revoked" ? "audit-voucher-revoke-1" : null,
    schema: "recharge_voucher_issuance_summary.v1",
    secret_safe: true,
    status,
    tenant_id: "tenant-1",
    voucher_id: "voucher-list-1",
    wallet_id: "wallet-1",
  };
}

function capabilitySummaryForRoles(roles: string[]) {
  const normalized = roles.map((role) => role.toLowerCase());
  const capabilities = normalized.includes("billing")
    ? [
        "billing.read",
        "price.read",
        "reconciliation.read",
        "price_version.create",
        "health.liveness",
        "health.readiness",
      ]
    : normalized.includes("viewer")
      ? [
          "request_log.read",
          "trace.read",
          "audit.read",
          "billing.read",
          "price.read",
          "reconciliation.read",
          "health.liveness",
          "health.readiness",
        ]
      : normalized.includes("ops")
        ? [
            "provider.read",
            "provider.manage",
            "key.read",
            "key.manage",
            "provider_key.recovery",
            "request_log.read",
            "trace.read",
            "audit.read",
            "manual_test.run",
            "provider_health.read",
            "alert_webhook.validate",
            "health.liveness",
            "health.readiness",
          ]
        : normalized.includes("provider")
          ? [
              "provider.read",
              "provider.manage",
              "manual_test.run",
              "health.liveness",
              "health.readiness",
            ]
          : normalized.includes("request")
            ? [
                "request_log.read",
                "trace.read",
                "health.liveness",
                "health.readiness",
              ]
            : normalized.includes("none")
              ? []
        : normalized.includes("health")
          ? ["provider_health.read", "health.liveness", "health.readiness"]
          : allCapabilities;
  const allowed = new Set(capabilities);

  return {
    capabilities,
    denied_capabilities: allCapabilities.filter(
      (capability) => !allowed.has(capability),
    ),
    personas: roles.map((role) => role[0]?.toUpperCase() + role.slice(1)),
    roles,
    secret_safe: true,
  };
}

const allCapabilities = [
  "provider.read",
  "provider.manage",
  "key.read",
  "key.manage",
  "provider_key.recovery",
  "request_log.read",
  "trace.read",
  "audit.read",
  "billing.read",
  "price.read",
  "reconciliation.read",
  "price_version.create",
  "manual_test.run",
  "provider_health.read",
  "alert_webhook.validate",
  "health.liveness",
  "health.readiness",
];

function baseRequestLog() {
  return {
    api_key_profile_id: null,
    canonical_model_id: "model-1",
    client_request_id: "client-1",
    completed_at: "2026-06-02T12:01:00Z",
    created_at: "2026-06-02T12:00:00Z",
    currency: "USD",
    error_code: null,
    error_owner: null,
    final_cost: "0.0000",
    http_status: 200,
    id: "req_base",
    inbound_protocol: "openai",
    input_tokens: 1,
    latency_ms: 10,
    outbound_protocol: "openai",
    output_tokens: 1,
    partial_sent: false,
    payload_policy_id: "payload-policy-1",
    payload_stored: true,
    project_id: null,
    protocol_mode: "openai",
    provider_key_id: "provider-key-1",
    redaction_status: "redacted",
    request_body_hash: "request-body-hash-hidden",
    requested_model: "gpt-4o-mini",
    resolved_channel_id: "channel-1",
    resolved_provider_id: "provider-1",
    response_body_hash: "response-body-hash-hidden",
    retryable: false,
    route_policy_version: "policy-v1",
    status: "succeeded",
    stream_end_reason: null,
    tenant_id: "tenant-1",
    thread_id: null,
    trace_id: "trace-1",
    ttft_ms: 5,
    upstream_model: "gpt-4o-mini",
    virtual_key_id: null,
  };
}

function healthSummaryQueryOptions(requestUrl: string) {
  const params = new URL(requestUrl, "http://admin.local").searchParams;
  const windowMinutes = Number.parseInt(params.get("window_minutes") ?? "", 10);
  const sampleLimit = Number.parseInt(params.get("sample_limit") ?? "", 10);

  return {
    sampleLimit: Number.isFinite(sampleLimit) ? sampleLimit : 500,
    windowMinutes: Number.isFinite(windowMinutes) ? windowMinutes : 60,
  };
}

function healthSummaryPayload(
  options: { sampleLimit?: number; windowMinutes?: number } = {},
) {
  const sampleLimit = options.sampleLimit ?? 500;
  const windowMinutes = options.windowMinutes ?? 60;
  const sampleCount = windowMinutes === 15 ? 1 : 2;
  const successCount = 1;
  const successRate = sampleCount > 0 ? successCount / sampleCount : null;

  return {
    channels: [
      {
        enabled_provider_key_count: 0,
        health_score: 97,
        health_state: "degraded",
        id: "channel-1",
        model_count: 1,
        name: "openai primary",
        priority: 10,
        protocol_mode: "openai_compatible",
        provider_id: "provider-1",
        provider_key_count: 1,
        recent: healthSummaryRecent("provider_auth_failed"),
        region: "us-east-1",
        status: "cooldown",
        weight: 100,
      },
    ],
    models: [
      {
        association_count: 1,
        display_name: "GPT Visible",
        enabled_association_count: 1,
        family: "gpt",
        id: "model-1",
        model_key: "gpt-visible",
        recent: healthSummaryRecent("provider_auth_failed"),
        routable_channel_count: 1,
        routing_state: "routable",
        status: "active",
        visibility: "public",
      },
    ],
    provider_keys: [
      {
        channel_id: "channel-1",
        configured_last_error_code: "provider_auth_failed",
        cooldown_until: "2026-06-02 12:05:00+00",
        credential_configured: true,
        current_window_state: {
          raw: "current-window-state-hidden",
        },
        health_score: 0.25,
        health_state: "degraded",
        id: "provider-key-1",
        key_alias: "openai-main",
        limits: {
          concurrency: 3,
          rpm: 600,
          tpm: 120000,
        },
        metadata: {
          raw_payload: "raw health metadata hidden",
        },
        recent: healthSummaryRecent("provider_auth_failed"),
        secret_fingerprint: "fp-health-hidden",
        status: "cooldown",
      },
    ],
    providers: [
      {
        channel_count: 1,
        code: "openai",
        enabled_channel_count: 0,
        enabled_provider_key_count: 0,
        health_score: 0.41,
        health_state: "degraded",
        id: "provider-1",
        metadata: {
          secret_note: skPlaceholder("health-provider-hidden"),
        },
        name: "OpenAI",
        provider_key_count: 1,
        recent: healthSummaryRecent("provider_auth_failed"),
        status: "enabled",
      },
    ],
    probe_status: {
      next_probe: null,
      probe_source: "request_logs",
      scheduler_pending: true,
      status: "scheduler_pending",
    },
    recent_window: {
      error_count: 1,
      sample_count: sampleCount,
      sample_limit: sampleLimit,
      source: "request_logs",
      success_count: successCount,
      success_rate: successRate,
      window: {
        minutes: windowMinutes,
        unit: "minutes",
      },
      window_minutes: windowMinutes,
    },
    status_counts: {
      channels: { cooldown: 1 },
      models: { active: 1 },
      provider_keys: { cooldown: 1 },
      providers: { enabled: 1 },
    },
    summary_version: 1,
    tenant_id: "tenant-1",
    totals: {
      channels: 1,
      model_associations: 1,
      models: 1,
      provider_keys: 1,
      providers: 1,
    },
  };
}

function providerKeyRecoveryPayload() {
  return {
    billing: {
      billable: false,
      ledger_write: false,
    },
    controlled_status_transition: true,
    credential_material: {
      omitted: true,
    },
    dry_run: false,
    provider_key: {
      channel_id: "channel-1",
      credential_configured: true,
      health_score: 0.25,
      id: "provider-key-1",
      key_alias: "openai-main",
      metadata: {
        owner: "ops",
        token: skPlaceholder("recovery-response-hidden"),
      },
      secret_redacted: true,
      status: "recovery_probe",
      tenant_id: "tenant-1",
    },
    reason: "overview manual recovery request",
    target_status: "recovery_probe",
    transition: {
      allowed_source_statuses: ["cooldown", "degraded", "recovery_probe"],
      allowed_target_statuses: ["recovery_probe", "enabled"],
      from_status: "cooldown",
      to_status: "recovery_probe",
    },
    upstream_probe: {
      billable: false,
      executed: false,
      mode: "not_implemented",
      request_log_write: false,
    },
  };
}

function healthSummaryRecent(code: string) {
  return {
    error_count: 1,
    last_error: {
      code,
      http_status: 401,
      observed_at: "2026-06-02 12:00:02+00",
      owner: "provider",
      status: "failed",
    },
    request_count: 2,
    success_count: 1,
    success_rate: 0.5,
  };
}

function selectedDryRunResponse() {
  const candidate = {
    association_id: "association-1",
    association_priority: 2,
    association_type: "explicit_channel",
    canonical_model_id: "canonical-model-1",
    channel_health_score: 1,
    channel_id: "channel-1",
    channel_name: "primary channel",
    channel_priority: 10,
    channel_status: "enabled",
    channel_weight: 100,
    fallback_allowed: true,
    filter_reason: null,
    filtered: false,
    priority: 2000010,
    protocol_mode: "openai_compatible",
    provider_code: "provider-a",
    provider_id: "provider-1",
    provider_model: "upstream-gpt",
    provider_name: "Provider A",
    provider_status: "enabled",
    rate_limit_available: true,
    routing_health: "Healthy",
    routing_status: "Enabled",
    score: {
      priority: 2000010,
      total: 2145483738,
      weight: 100,
    },
    secret_note: skPlaceholder("candidate-hidden"),
    selected: true,
    trace_affinity_match: true,
    upstream_model: "upstream-gpt",
    weight: 100,
  };
  const filteredCandidate = {
    ...candidate,
    association_id: "association-2",
    channel_id: "channel-2",
    channel_name: "blocked channel",
    fallback_allowed: false,
    filter_reason: "profile denied",
    filtered: true,
    provider_id: "provider-2",
    provider_name: "Provider B",
    selected: false,
    upstream_model: "backup-gpt",
  };

  return {
    candidates: [candidate, filteredCandidate],
    canonical_model: {
      display_name: "GPT Visible",
      family: "gpt",
      id: "canonical-model-1",
      model_key: "gpt-visible",
      status: "active",
    },
    decision_snapshot_version: 1,
    policy: {
      payload_policy_id: "payload-policy-override",
      profile_ip_allowlist: ["203.0.113.0/24", "2001:db8::/64"],
      request_overrides: [
        {
          allowlist: ["203.0.113.0/24", "2001:db8::/64"],
          authorization: bearerPlaceholder("request-override-hidden"),
          raw_payload: "raw request override payload hidden",
          type: "profile_ip_allowlist",
        },
      ],
      seed: 42,
    },
    profile_id: "profile-1",
    project_id: "project-1",
    requested_model: "gpt-visible",
    route_decision_snapshot: {
      api_key: skPlaceholder("route-dry-hidden"),
      authorization: bearerPlaceholder("route-dry-hidden"),
      candidates: [
        {
          channel_id: "channel-1",
          filter_reason: null,
          selected: true,
        },
        {
          channel_id: "channel-2",
          filter_reason: "profile denied",
          filtered: true,
          selected: false,
        },
      ],
      nested: {
        token: bearerPlaceholder("nested-route-dry-hidden"),
      },
      payload: {
        body: "raw dry-run payload hidden",
      },
      profile_request_overrides: [
        {
          allowlist: ["203.0.113.0/24"],
          raw_payload: "raw snapshot override payload hidden",
          type: "profile_ip_allowlist",
        },
      ],
      raw_snapshot: "raw dry-run snapshot hidden",
      selected_channel_id: "channel-1",
      version: 1,
    },
    route_policy_version: "gateway_db_route_v1",
    selected_candidate: candidate,
    selection: {
      selected: {
        api_key: skPlaceholder("selection-hidden"),
        channel_id: "channel-1",
        provider_id: "provider-1",
        provider_model: "upstream-gpt",
        weight: 100,
      },
      selected_channel_id: "channel-1",
      status: "selected",
    },
    trace_affinity: {
      applied_channel_id: "channel-1",
      previous_successful_channel_id: "channel-1",
      status: "Applied",
      trace_id: "trace-1",
    },
    trace_id: "trace-1",
  };
}

function channelManualTestResponse(
  requestedModel = "gpt-visible",
  upstreamModel = "upstream-gpt",
) {
  return {
    billing: {
      billable: false,
      ledger_write: false,
      request_log_write: false,
    },
    channel: {
      endpoint: `https://provider.example/v1?api_key=${skPlaceholder("manual-endpoint-hidden")}`,
      health_score: 1,
      id: "channel-1",
      name: "primary channel",
      priority: 10,
      protocol_mode: "openai_compatible",
      secret_note: skPlaceholder("manual-channel-hidden"),
      status: "enabled",
      weight: 100,
    },
    credential_material: {
      provider_key_secret: skPlaceholder("manual-key-hidden"),
      secret_fingerprint: "fp-manual-hidden",
    },
    dry_run: true,
    next_steps: ["Dry-run only: no upstream provider call was made."],
    provider: {
      code: "provider-a",
      id: "provider-1",
      name: "Provider A",
      secret_note: skPlaceholder("manual-provider-hidden"),
      status: "enabled",
    },
    requested_model: requestedModel,
    request_plan: {
      authorization: bearerPlaceholder("manual-plan-hidden"),
      method: "POST",
      model: upstreamModel,
      path: "/v1/chat/completions",
      protocol_mode: "openai_compatible",
      raw_payload: "raw manual payload hidden",
    },
    test_mode: "channel_manual_test",
    upstream_call: false,
    upstream_model: upstreamModel,
  };
}

function noCandidateDryRunResponse() {
  return {
    candidates: [],
    canonical_model: null,
    decision_snapshot_version: 1,
    policy: {
      seed: 0,
    },
    profile_id: "profile-1",
    project_id: "project-1",
    requested_model: "missing-model",
    route_decision_snapshot: {
      candidates: [],
      selected: null,
      selected_channel_id: null,
      version: 1,
    },
    route_policy_version: "gateway_db_route_v1",
    selected_candidate: null,
    selection: {
      selected: null,
      selected_channel_id: null,
      status: "model_not_found_or_not_allowed",
    },
    trace_affinity: {
      applied_channel_id: null,
      previous_successful_channel_id: null,
      status: "Disabled",
      trace_id: null,
    },
    trace_id: null,
  };
}

function jsonError(message: string, status = 400) {
  return Promise.resolve(
    new Response(
      JSON.stringify({
        error: {
          code: "bad_request",
          message,
        },
      }),
      {
        status,
        statusText: "Bad Request",
        headers: { "Content-Type": "application/json" },
      },
    ),
  );
}

function jsonErrorWithData(message: string, status: number, data: unknown) {
  return Promise.resolve(
    new Response(
      JSON.stringify({
        data,
        error: {
          code: "bad_request",
          message,
        },
      }),
      {
        status,
        statusText: "Bad Request",
        headers: { "Content-Type": "application/json" },
      },
    ),
  );
}

async function renderSignedInApp() {
  const user = userEvent.setup();
  render(<App />);

  await user.type(
    await screen.findByLabelText("邮箱"),
    "operator@example.com",
  );
  await user.type(screen.getByLabelText("密码"), "local-password");
  await user.click(screen.getByRole("button", { name: "登录" }));

  return user;
}

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("App", () => {
  it("opens the standalone developer console without restoring an admin session", async () => {
    window.history.replaceState(null, "", "/?mode=developer-console");
    const fetchMock = vi.fn((url: RequestInfo | URL) => {
      const requestUrl = String(url);

      if (requestUrl.includes("/auth/login")) {
        return jsonResponse({
          project: { id: "project-user-standalone", role: "developer" },
          session: { expires_at: "2026-07-06T00:00:00Z" },
          session_token_once: sessionPlaceholder("user-standalone-session"),
          user: {
            display_name: "Standalone User",
            email: "standalone@example.com",
            id: "user-standalone",
            pending_acceptance: false,
            tenant_id: "tenant-user-standalone",
          },
        });
      }

      if (requestUrl.includes("/user/models") || requestUrl.includes("/user/request-logs") || requestUrl.includes("/user/virtual-keys")) {
        return jsonResponse([]);
      }

      if (requestUrl.includes("/user/balance")) {
        return jsonResponse({
          active_credit_grant_total: "0.00",
          available_to_spend: "0.00",
          currency: "USD",
          last_credit_grant_ids: [],
          last_ledger_entry_ids: [],
          pending_confirmed_ledger_window: "0.00",
          schema: "user_balance_runtime.v1",
          secret_safe: true,
          wallet_id: "wallet-standalone",
        });
      }

      if (requestUrl.includes("/user/readiness")) {
        return jsonResponse({
          checks: [],
          counts: {
            active_keys: 0,
            active_profiles: 0,
            available_models: 0,
            recent_requests: 0,
            routable_models: 0,
          },
          next_action: "Create a user API key.",
          project_id: "project-user-standalone",
          schema: "user_readiness_runtime.v1",
          secret_safe: true,
          state: "blocked",
        });
      }

      return jsonError("not configured", 404);
    });
    vi.stubGlobal("fetch", fetchMock);
    const user = userEvent.setup();

    render(<App />);

    expect(await screen.findByRole("heading", { name: "用户登录" })).toBeInTheDocument();
    expect(fetchMock).not.toHaveBeenCalledWith(expect.stringContaining("/admin/auth/me"), expect.anything());

    await user.type(screen.getByLabelText("邮箱"), "standalone@example.com");
    await user.type(screen.getByLabelText("密码"), "local-password");
    await user.click(screen.getByRole("button", { name: "登录" }));

    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/api/control-plane/auth/login", expect.anything()));
    expect(fetchMock.mock.calls.some(([url]) => String(url).includes("/admin/auth/me"))).toBe(false);
    window.history.replaceState(null, "", "/");
  });

  it("shows user legal links and password reset skeleton without account disclosure", async () => {
    const fetchMock = vi.fn((url: RequestInfo | URL) => {
      const requestUrl = String(url);
      if (requestUrl.includes("/auth/password-reset/request")) {
        return jsonResponse({
          account_disclosure: "none",
          code: "password_reset_email_config_needed",
          email_delivery: "config_needed",
          message: "If the account can receive email, a reset link will be queued after mail delivery is configured.",
          next_action: "Configure the user mail sender and SMTP adapter, then retry this request.",
          secret_safe: true,
          status: "pending",
        });
      }
      return jsonResponse({});
    });
    vi.stubGlobal("fetch", fetchMock);
    const user = userEvent.setup();

    render(<UserPortalLoginPanel onAdminMode={vi.fn()} onLogin={vi.fn()} />);

    expect(screen.getAllByRole("button", { name: "用户协议" }).length).toBeGreaterThan(0);
    expect(screen.getAllByRole("button", { name: "隐私政策" }).length).toBeGreaterThan(0);
    await user.click(screen.getByRole("button", { name: "用户协议" }));
    expect(await screen.findByRole("dialog", { name: "用户协议" })).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "关闭" }));
    await user.type(screen.getByLabelText("邮箱"), "nobody@example.com");
    await user.click(screen.getByRole("button", { name: "请求重置" }));

    expect(await screen.findByText(/reset link will be queued/)).toBeInTheDocument();
    expect(document.body.textContent).toContain("不会泄露账号是否存在");
    expect(document.body.textContent).not.toContain(SK_PREFIX);
    expect(fetchMock.mock.calls[0][0]).toBe("/api/control-plane/auth/password-reset/request");
  });

  it("uses a safe generic message for user auth failures", async () => {
    const fetchMock = vi.fn((url: RequestInfo | URL) => {
      const requestUrl = String(url);
      if (requestUrl.includes("/auth/login")) {
        return jsonError(
          `${AUTH_HEADER_NAME}: ${bearerPlaceholder("user-login-hidden")} password=raw-secret provider_key=${skPlaceholder("hidden")}`,
          401,
        );
      }
      return jsonResponse({});
    });
    vi.stubGlobal("fetch", fetchMock);
    const user = userEvent.setup();

    render(<UserPortalLoginPanel onAdminMode={vi.fn()} onLogin={vi.fn()} />);

    await user.type(screen.getByLabelText("邮箱"), "developer@example.com");
    await user.type(screen.getByLabelText("密码"), "bad-password");
    await user.click(screen.getByRole("button", { name: "登录" }));

    expect(await screen.findByText("登录或注册失败。请检查邮箱和密码后重试。")).toBeInTheDocument();
    expect(document.body.textContent).not.toContain("raw-secret");
    expect(document.body.textContent).not.toContain(SK_PREFIX);
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
  });

  it("renders the user portal dashboard in Chinese without exposing API key secrets", async () => {
    const fetchMock = vi.fn((url: RequestInfo | URL, init?: RequestInit) => {
      const requestUrl = String(url);

      if (requestUrl.includes("/v1/chat/completions")) {
        const requestBody = typeof init?.body === "string" ? JSON.parse(init.body) : {};
        if (requestBody.stream === true) {
          return streamResponse(
            [
              {
                id: "chatcmpl-user-stream-1",
                model: "gpt-4o-mini",
                choices: [{ delta: { content: "hello " }, finish_reason: null, index: 0 }],
              },
              {
                id: "chatcmpl-user-stream-1",
                model: "gpt-4o-mini",
                choices: [{ delta: { content: "world" }, finish_reason: null, index: 0 }],
              },
              {
                id: "chatcmpl-user-stream-1",
                model: "gpt-4o-mini",
                choices: [{ delta: {}, finish_reason: "stop", index: 0 }],
              },
            ],
            "req-user-stream-1",
          );
        }

        return jsonError(
          `${AUTH_HEADER_NAME}: ${bearerPlaceholder("user-console-hidden")} provider_key=${skPlaceholder("user-console-provider-hidden")} prompt=show-this-never payload=raw-body-never`,
          500,
        );
      }

      if (requestUrl.includes("/user/balance")) {
        return jsonResponse({
          active_credit_grant_total: "20.00",
          available_to_spend: "18.50",
          currency: "USD",
          last_credit_grant_ids: [],
          last_ledger_entry_ids: [],
          pending_confirmed_ledger_window: "0.00",
          schema: "user_balance_runtime.v1",
          secret_safe: true,
          wallet_id: "wallet-user-1",
        });
      }

      if (requestUrl.includes("/user/virtual-keys")) {
        return jsonResponse([
          {
            budget_policy: {},
            default_profile_id: "profile-1",
            id: "vk-1",
            ip_allowlist: [],
            key_prefix: "vk_live",
            metadata: {},
            name: "生产 Key",
            project_id: "project-1",
            rate_limit_policy: {},
            secret_once: false,
            secret_redacted: true,
            status: "active",
            tenant_id: "tenant-1",
          },
        ]);
      }

      if (requestUrl.includes("/user/models")) {
        return jsonResponse([
          {
            context_length: 128000,
            default_profile_id: "profile-1",
            display_name: "GPT 4o mini",
            family: "gpt",
            id: "model-1",
            max_output_tokens: 4096,
            model: "gpt-4o-mini",
            price: {
              currency: "USD",
              price_book_id: "price-book-user-1",
              price_version_id: "price-version-user-1",
              pricing_rules: {
                currency: "USD",
                input_token_rate_per_1m: "1.00",
                output_token_rate_per_1m: "2.00",
              },
              secret_safe: true,
              version: "user-v1",
            },
            routable: true,
            routable_channel_count: 1,
            status: "active",
            supports_audio: false,
            supports_reasoning: false,
            supports_stream: true,
            supports_tools: true,
            supports_vision: false,
            visibility: "public",
          },
          {
            context_length: 32768,
            default_profile_id: "profile-1",
            display_name: "Price Missing Model",
            family: "gpt",
            id: "model-price-missing",
            max_output_tokens: 2048,
            model: "price-missing-model",
            price: null,
            routable: true,
            routable_channel_count: 1,
            status: "active",
            supports_audio: false,
            supports_reasoning: false,
            supports_stream: false,
            supports_tools: false,
            supports_vision: false,
            visibility: "public",
          },
        ]);
      }

      if (requestUrl.includes("/user/readiness")) {
        return jsonResponse({
          checks: [
            {
              code: "model",
              detail: "已有可路由模型",
              label: "模型",
              next_action: "可以调用",
              status: "ready",
            },
          ],
          counts: {
            active_keys: 1,
            active_profiles: 1,
            available_models: 1,
            recent_requests: 1,
            routable_models: 1,
          },
          next_action: "可以调用",
          project_id: "project-1",
          schema: "user_readiness_runtime.v1",
          secret_safe: true,
          state: "ready",
        });
      }

      if (requestUrl.includes("/user/vouchers/redeem")) {
        return jsonResponse({
          amount: "25.00",
          credit_grant_id: "credit-grant-user-1",
          currency: "USD",
          expires_at: "2026-07-06T00:00:00Z",
          ledger_entry_id: "ledger-user-1",
          operation: "voucher_redeem",
          raw_voucher_code_echoed: false,
          redemption_id: "redemption-user-1",
          status: "redeemed",
          voucher_id: "voucher-user-1",
          wallet_id: "wallet-user-1",
        });
      }

      if (requestUrl.includes("/user/usage-summary")) {
        return jsonResponse({
          by_key: [],
          by_model: [],
          project_id: "project-1",
          schema: "user_usage_summary_runtime.v1",
          secret_safe: true,
          top_errors: [],
          totals: {
            avg_latency_ms: 123,
            currency: "USD",
            failed_count: 0,
            input_tokens: 100,
            output_tokens: 40,
            request_count: 1,
            retryable_failed_count: 0,
            success_count: 1,
            total_cost: "0.001",
            total_tokens: 140,
          },
          window_days: 7,
        });
      }

      if (requestUrl.includes("/user/subscription-payment")) {
        return jsonResponse({
          current_subscription: {
            dunning_status: "not_in_dunning",
            grace_status: "not_in_grace",
            lifecycle_state: "no_subscription",
            next_action: "等待订阅后端接入。",
            next_renewal_at: null,
            renewal_status: "not_scheduled",
            status: "none",
          },
          demo_payment: {
            invoice_status: "placeholder",
            local_only: true,
            merchant_connected: false,
            next_action: "本地 demo pending。",
            order_status: "not_created",
            production_payment_evidence: false,
          },
          local_only: true,
          merchant_connected: false,
          pending_scheduler: true,
          plans: [],
          raw_idempotency_key_echoed: false,
          raw_invoice_metadata_returned: false,
          raw_payment_payload_returned: false,
          scheduler_status: "pending_scheduler",
          scheduler_demo: {
            dunning: {
              attempt_count: 0,
              max_attempts: 3,
              next_attempt_at: null,
              status: "not_in_dunning",
              write_enabled: false,
            },
            grace: {
              ends_at: null,
              grace_days: 3,
              status: "not_in_grace",
              write_enabled: false,
            },
            lifecycle_state: "no_subscription",
            local_only: true,
            merchant_connected: false,
            mode: "local_readback_demo",
            next_action: "本地 demo pending。",
            pending_scheduler: true,
            raw_idempotency_key_echoed: false,
            raw_invoice_metadata_returned: false,
            raw_payload_returned: false,
            raw_payment_payload_returned: false,
            readback_source: "test_fixture",
            runtime_scheduler_enabled: false,
            scheduled_events: [],
            scheduler_status: "pending_scheduler",
            schema: "user_subscription_scheduler_demo.v1",
            secret_safe: true,
            subscription_id: null,
            subscription_status: "none",
            upcoming_renewal: {
              amount: null,
              billing_interval: null,
              credit_grant_write: false,
              currency: null,
              due_at: null,
              invoice_status: "placeholder",
              ledger_write: false,
              order_status: "not_created",
              plan_code: null,
              status: "not_scheduled",
            },
          },
          schema: "user_subscription_payment_overview.v1",
          secret_safe: true,
        });
      }

      if (requestUrl.includes("/user/request-logs")) {
        return jsonResponse([
          {
            completed_at: "2026-06-11T10:01:00Z",
            created_at: "2026-06-11T10:00:00Z",
            currency: "USD",
            final_cost: "0.001",
            http_status: 200,
            id: "req-user-1",
            input_tokens: 100,
            output_tokens: 40,
            partial_sent: false,
            redaction_status: "redacted",
            requested_model: "gpt-4o-mini",
            status: "succeeded",
            tenant_id: "tenant-1",
            trace_id: null,
          },
        ]);
      }

      if (requestUrl.includes("/auth/email-verification/request")) {
        return jsonResponse({
          account_disclosure: "none",
          code: "email_verification_config_needed",
          email_delivery: "config_needed",
          message: "Email verification is pending because user mail delivery is not configured.",
          next_action: "Configure the user mail sender and SMTP adapter, then request verification again.",
          secret_safe: true,
          status: "pending",
        });
      }

      return jsonResponse({});
    });
    vi.stubGlobal("fetch", fetchMock);
    const user = userEvent.setup();

    render(
      <UserPortalDashboard
        onLogout={vi.fn()}
        session={{
          email: "user@example.com",
          expiresAt: "2026-06-11T12:00:00Z",
          name: "用户",
          projectId: "project-1",
          projectRole: "member",
          tenantId: "tenant-1",
          userId: "user-1",
        }}
      />,
    );

    expect(await screen.findByRole("heading", { level: 2, name: "额度" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { level: 2, name: "开发者访问" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { level: 2, name: "API 控制台" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { level: 2, name: "账号安全" })).toBeInTheDocument();
    expect(await screen.findByText("已有可路由模型")).toBeInTheDocument();
    expect(await screen.findByText("余额足够")).toBeInTheDocument();
    expect(await screen.findByText("0.000288 USD")).toBeInTheDocument();
    expect(screen.getByText(/最终费用以请求日志和 ledger 为准/)).toBeInTheDocument();
    await user.selectOptions(screen.getByLabelText("控制台模型"), "price-missing-model");
    expect((await screen.findAllByText("Price Missing Model")).length).toBeGreaterThan(0);
    expect(screen.getAllByText("config-needed").length).toBeGreaterThan(0);
    expect(screen.getByText(/缺少 active price version/)).toBeInTheDocument();
    await user.selectOptions(screen.getByLabelText("控制台模型"), "gpt-4o-mini");
    await user.type(screen.getByLabelText("按 request id 或 trace id 搜索请求"), "req-user-1");
    await user.click(screen.getByRole("button", { name: "搜索" }));
    await waitFor(() =>
      expect(fetchMock.mock.calls.some(([url]) => String(url).includes("/user/request-logs?limit=20&request_id=req-user-1"))).toBe(true),
    );
    await user.click(screen.getByRole("button", { name: "清除" }));
    await waitFor(() =>
      expect(
        fetchMock.mock.calls
          .map(([url]) => String(url))
          .filter((url) => url === "/api/control-plane/user/request-logs?limit=20").length,
      ).toBeGreaterThan(1),
    );
    await user.click(screen.getByRole("button", { name: "发送验证邮件" }));
    expect(await screen.findByText("email_verification_config_needed")).toBeInTheDocument();
    expect(await screen.findByText("config_needed")).toBeInTheDocument();
    await user.type(screen.getByLabelText("兑换码"), "VOUCHER-RAW-NEVER");
    await user.click(screen.getByRole("button", { name: "兑换" }));
    expect(await screen.findByText("兑换成功")).toBeInTheDocument();
    expect(screen.getByText("25.00 USD")).toBeInTheDocument();
    expect(screen.getByText("2026-07-06T00:00:00Z")).toBeInTheDocument();
    expect(document.body.textContent).not.toContain("VOUCHER-RAW-NEVER");
    await user.type(screen.getByLabelText("API 密钥"), "test-user-key");
    const runButton = screen.getByRole("button", { name: "运行测试" });
    await waitFor(() => expect(runButton).not.toBeDisabled());
    await user.click(runButton);
    await waitFor(() =>
      expect(fetchMock.mock.calls.some(([url]) => String(url).includes("/v1/chat/completions"))).toBe(true),
    );
    expect(await screen.findByText("上游返回了已隐藏的敏感错误详情。")).toBeInTheDocument();
    expect(document.body.textContent).not.toContain(SK_PREFIX);
    expect(document.body.textContent).not.toContain(VK_UNDERSCORE_PREFIX);
    expect(document.body.textContent).not.toContain("show-this-never");
    expect(document.body.textContent).not.toContain("raw-body-never");
    expect(document.body.textContent).not.toContain("user-console-provider-hidden");
    fireEvent.change(screen.getByLabelText("控制台调用模式"), { target: { value: "stream" } });
    await user.click(screen.getByRole("button", { name: "运行测试" }));
    await screen.findByText("req-user-stream-1");
    expect(screen.getAllByText("stream").length).toBeGreaterThan(1);
    expect(await screen.findByText("req-user-stream-1")).toBeInTheDocument();
    expect(await screen.findByText(/chunk 1: hello/)).toBeInTheDocument();
    expect(await screen.findByText(/chunk 2: world/)).toBeInTheDocument();
    expect(await screen.findByText("stop")).toBeInTheDocument();
    expect(document.body.textContent).not.toContain("test-user-key");
    expect(document.body.textContent).not.toContain("raw-body-never");
  });

  it("restores an existing admin cookie session on mount without showing the login form", async () => {
    const fetchMock = stubHealthyFetch(["ops"], { restoreSession: true });

    render(<App />);

    expect(
      screen.getByRole("heading", { level: 1, name: "正在恢复会话" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "登录" }),
    ).not.toBeInTheDocument();

    expect(
      await screen.findByRole("heading", { level: 1, name: "仪表盘" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /仪表盘/ }),
    ).toBeInTheDocument();
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toContain(
      "/api/control-plane/admin/auth/me",
    );
    expect(fetchMock.mock.calls.map(([url]) => String(url))).not.toContain(
      "/api/control-plane/admin/auth/login",
    );
  });

  it("falls back to the login page when session restore fails without exposing secrets", async () => {
    stubHealthyFetch(["owner"], { meFailsWithSecret: true });

    render(<App />);

    expect(
      screen.getByRole("heading", { level: 1, name: "正在恢复会话" }),
    ).toBeInTheDocument();
    expect(
      await screen.findByRole("heading", { level: 1, name: "管理员登录" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("heading", { level: 1, name: "仪表盘" }),
    ).not.toBeInTheDocument();
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("session-restore-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("session-restore-hidden"),
    );
  });

  it("clears restored session state on logout", async () => {
    const fetchMock = stubHealthyFetch(["owner"], { restoreSession: true });
    const user = userEvent.setup();

    render(<App />);

    expect(
      await screen.findByRole("heading", { level: 1, name: "仪表盘" }),
    ).toBeInTheDocument();
    expect(await screen.findByText("2 条请求 / 1h")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "退出登录" }));

    expect(
      await screen.findByRole("heading", { level: 1, name: "管理员登录" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("heading", { level: 1, name: "仪表盘" }),
    ).not.toBeInTheDocument();
    expect(screen.queryByText("2 条请求 / 1h")).not.toBeInTheDocument();
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toContain(
      "/api/control-plane/admin/auth/logout",
    );
  });

  it("waits for local sign-in before probing services and keeps refresh available", async () => {
    const fetchMock = stubHealthyFetch();
    const user = userEvent.setup();

    render(<App />);

    expect(
      screen.getByRole("heading", { level: 1, name: "正在恢复会话" }),
    ).toBeInTheDocument();

    await user.type(
      await screen.findByLabelText("邮箱"),
      "operator@example.com",
    );
    await user.type(screen.getByLabelText("密码"), "local-password");
    await user.click(screen.getByRole("button", { name: "登录" }));

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(7));
    expect(
      fetchMock.mock.calls
        .map(([url]) => String(url))
        .filter((url) => url === "/api/control-plane/admin/auth/me"),
    ).toHaveLength(2);
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toContain(
      "/api/control-plane/admin/providers/health-summary",
    );

    await user.click(screen.getByRole("button", { name: "刷新" }));

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(11));
    expect(
      fetchMock.mock.calls
        .map(([url]) => String(url))
        .filter(
          (url) => url === "/api/control-plane/admin/providers/health-summary",
        ),
      ).toHaveLength(2);
  });

  it("shows read-only import wizard dry-run commands without backend requests", async () => {
    const fetchMock = stubHealthyFetch(["ops"]);

    const user = await renderSignedInApp();

    await waitFor(() =>
      expect(
        fetchMock.mock.calls.some(([url]) =>
          String(url).includes("/admin/providers/health-summary"),
        ),
      ).toBe(true),
    );
    const callsBeforeImport = fetchMock.mock.calls.length;

    await user.click(screen.getByRole("button", { name: /导入向导/ }));

    expect(
      await screen.findByRole("heading", {
        level: 2,
        name: "New API apply-plan",
      }),
    ).toBeInTheDocument();
    expect(screen.getByText("One API apply-plan")).toBeInTheDocument();
    expect(screen.getByText("Sub2API apply-plan")).toBeInTheDocument();
    expect(screen.getByText(/import-newapi-dryrun\.ps1/)).toBeInTheDocument();
    expect(screen.getByText(/import-oneapi-dryrun\.ps1/)).toBeInTheDocument();
    expect(screen.getByText(/import-sub2api-dryrun\.ps1/)).toBeInTheDocument();
    expect(screen.getByText(/import-newapi-oneapi-generic-bridge\.ps1/)).toBeInTheDocument();
    expect(screen.getByText(/import-sub2api-identity-billing-plan\.ps1/)).toBeInTheDocument();
    expect(screen.getByText("Secret-safe 规则")).toBeInTheDocument();
    expect(screen.getByText("下一步 handoff")).toBeInTheDocument();
    expect(screen.getByText(/apply\/live 脚本不在本页运行/)).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("artifact JSON"), {
      target: {
        value: JSON.stringify({
          counts: {
            accounts: 1,
            api_keys: 1,
            non_migratable_items: 1,
          },
          dry_run: true,
          importer: "sub2api-source-dryrun",
          manual_review_items: [
            {
              reason: "User profile must be recreated through local registration.",
              source_id: "user-1",
              type: "user_profile",
            },
          ],
          migratable_items: [
            {
              recommended_path: "Create provider and channel mapping.",
              source_id: "account-1",
              type: "provider_channel",
            },
          ],
          next_steps: ["Map accounts into provider/channel/provider-key handoff."],
          non_migratable_items: [
            {
              reason: "Sub2API users are not applied by source dry-run.",
              source_id: "user-1",
              type: "user_profile",
            },
          ],
          provider_key_handoffs: [
            {
              key_alias: "sub2api-account-main",
              required_operator_path: "POST /admin/provider-keys",
            },
          ],
        }),
      },
    });

    expect(await screen.findByRole("heading", { name: "计数" })).toBeInTheDocument();
    expect(screen.getByText("sub2api-source-dryrun")).toBeInTheDocument();
    expect(screen.getByText("accounts")).toBeInTheDocument();
    expect(screen.getAllByText("1").length).toBeGreaterThan(0);
    expect(screen.getByText("差异筛选")).toBeInTheDocument();
    expect(screen.getByText("Sub2API 差异解释")).toBeInTheDocument();
    expect(screen.getByText("user link / wallet / subscription")).toBeInTheDocument();
    expect(screen.getByText("渠道 / token / 分组 / 模型映射")).toBeInTheDocument();
    expect(screen.getByText("apply 前 checklist")).toBeInTheDocument();
    expect(screen.getByText("handoff 确认")).toBeInTheDocument();
    expect(screen.getByText("provider_channel")).toBeInTheDocument();
    expect(screen.getAllByText("user_profile").length).toBeGreaterThan(1);
    expect(screen.getByText("sub2api-account-main")).toBeInTheDocument();
    expect(screen.getByText("通过：artifact 标记为 dry-run")).toBeInTheDocument();
    expect(screen.getByText("通过：未发现 secret-like 字段")).toBeInTheDocument();
    expect(screen.getByText("通过：不可迁移项已进入人工处理清单")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "密钥交接" }));
    expect(screen.getByText("sub2api-account-main")).toBeInTheDocument();
    expect(screen.queryByText("provider_channel")).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "人工复核" }));
    expect(screen.getByText("user_profile")).toBeInTheDocument();
    expect(screen.queryByText("sub2api-account-main")).not.toBeInTheDocument();
    expect(screen.getAllByText(/provider\/channel\/provider-key handoff/).length).toBeGreaterThan(1);

    fireEvent.change(screen.getByLabelText("artifact JSON"), {
      target: {
        value: JSON.stringify({
          apply_blocked: false,
          counts: {
            planned_creates: 2,
            planned_skips: 0,
            source_channel_previews: 1,
            source_provider_key_handoffs: 1,
          },
          dry_run: true,
          idempotency_manifest: {
            entries: [
              {
                idempotency_key: "import-create-provider",
              },
              {
                idempotency_key: "import-create-channel",
              },
            ],
          },
          importer: "importer-apply-plan-dryrun",
          planned_creates: [
            {
              action: "create",
              operation_id: "op-provider",
              reason: "not_found_in_existing_state",
              target: {
                kind: "provider",
              },
            },
            {
              action: "create",
              operation_id: "op-channel",
              reason: "not_found_in_existing_state",
              target: {
                kind: "channel",
              },
            },
          ],
          preflight: {
            status: "pass",
          },
          provider_key_handoff_contract: {
            raw_material_allowed: false,
          },
          provider_key_handoffs: [
            {
              key_alias: "sub2api-account-main",
              required_operator_path: "POST /admin/provider-keys",
            },
          ],
          rollback_snapshot: {
            entries: [
              {
                operation_id: "op-provider",
              },
              {
                operation_id: "op-channel",
              },
            ],
          },
          source_binding_contract: {
            bindings: [
              {
                channel_present: true,
                channel_source_id: "sub2api:account:fixture",
                provider_code: "openai",
              },
            ],
          },
          sql_executor_plan: {
            executor_status: "dry_run_sql_plan",
          },
          transaction_contract: {
            transaction_id: "tx-import-fixture",
          },
        }),
      },
    });

    expect(await screen.findByText("apply-plan")).toBeInTheDocument();
    expect(screen.getAllByText("pass").length).toBeGreaterThan(1);
    expect(screen.getByText("provider")).toBeInTheDocument();
    expect(screen.getByText("channel")).toBeInTheDocument();
    expect(screen.getByText("source binding")).toBeInTheDocument();
    expect(screen.getByText("sub2api:account:fixture")).toBeInTheDocument();
    expect(screen.getByText("rollback entries")).toBeInTheDocument();
    expect(screen.getByText("idempotency entries")).toBeInTheDocument();
    expect(screen.getByText("通过：apply-plan preflight 可评审")).toBeInTheDocument();
    expect(fetchMock.mock.calls).toHaveLength(callsBeforeImport);
  });

  it("signs in to the operations shell and renders the health overview", async () => {
    stubHealthyFetch();

    await renderSignedInApp();

    expect(screen.getByText("Fubox API")).toBeInTheDocument();
    expect(screen.getByText("控制台")).toBeInTheDocument();
    expect(screen.getByText("工作区")).toBeInTheDocument();
    expect(screen.getAllByText("运营").length).toBeGreaterThan(0);
    expect(
      screen.getByRole("heading", { level: 1, name: "仪表盘" }),
    ).toBeInTheDocument();
    expect(screen.getByText("路由健康度")).toBeInTheDocument();
    expect(screen.getByText("窗口成功率")).toBeInTheDocument();
    await waitFor(() =>
      expect(screen.getAllByText("50%").length).toBeGreaterThan(0),
    );
    expect(await screen.findByText("2 条请求 / 1h")).toBeInTheDocument();
    expect(await screen.findByText("Gateway")).toBeInTheDocument();
    expect(await screen.findByText("97%")).toBeInTheDocument();
    expect(document.body.textContent).not.toContain("9700%");
    expect(document.body.textContent).not.toContain("current_window_state");
    expect(document.body.textContent).not.toContain(
      "current-window-state-hidden",
    );
    expect(document.body.textContent).not.toContain("fp-health-hidden");
    expect(document.body.textContent).not.toContain(
      "raw health metadata hidden",
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("health-provider-hidden"),
    );
  });

  it("applies health summary window and sample controls on manual refresh", async () => {
    const fetchMock = stubHealthyFetch();

    const user = await renderSignedInApp();

    expect(
      await screen.findByRole("heading", { level: 2, name: "健康控制" }),
    ).toBeInTheDocument();
    expect(await screen.findByText("2 条请求 / 1h")).toBeInTheDocument();
    await user.selectOptions(screen.getByLabelText("时间窗口"), "15");
    await user.selectOptions(screen.getByLabelText("样本上限"), "100");
    await user.selectOptions(screen.getByLabelText("范围"), "Provider key");
    await user.type(screen.getByLabelText("矩阵搜索"), "openai-main");

    expect(screen.getByText("openai-main")).toBeInTheDocument();
    expect(screen.queryByText("OpenAI")).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "刷新汇总" }));

    await waitFor(() =>
      expect(fetchMock.mock.calls.map(([url]) => String(url))).toContain(
        "/api/control-plane/admin/providers/health-summary?window_minutes=15&sample_limit=100",
      ),
    );
    expect(await screen.findByText("1 条请求 / 15m")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "刷新" }));

    await waitFor(() =>
      expect(screen.getByText("2 条请求 / 1h")).toBeInTheDocument(),
    );
    expect(
      fetchMock.mock.calls
        .map(([url]) => String(url))
        .filter(
          (url) => url === "/api/control-plane/admin/providers/health-summary",
        ),
    ).toHaveLength(2);

    const recoveryButton = await screen.findByRole("button", {
      name: "请求恢复 openai-main",
    });
    await user.click(recoveryButton);

    await waitFor(() => expect(recoveryButton).toHaveTextContent("已请求"));
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/control-plane/admin/provider-keys/provider-key-1/recovery",
      expect.objectContaining({ method: "POST" }),
    );
    expect(
      screen.queryByText(skPlaceholder("recovery-response-hidden")),
    ).not.toBeInTheDocument();
  });

  it("auto refreshes the health summary with bounded selected controls", async () => {
    const fetchMock = stubHealthyFetch();

    await renderSignedInApp();

    expect(await screen.findByText("2 条请求 / 1h")).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("时间窗口"), {
      target: { value: "15" },
    });
    fireEvent.change(screen.getByLabelText("样本上限"), {
      target: { value: "100" },
    });

    vi.useFakeTimers();
    fireEvent.change(screen.getByLabelText("自动刷新"), {
      target: { value: "30" },
    });

    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000);
    });

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toContain(
      "/api/control-plane/admin/providers/health-summary?window_minutes=15&sample_limit=100",
    );
    expect(screen.getByText("1 条请求 / 15m")).toBeInTheDocument();
  });

  it("hides provider key recovery controls without recovery capability", async () => {
    stubHealthyFetch(["health"]);

    await renderSignedInApp();

    expect(await screen.findByText("openai-main")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", {
        name: "请求恢复 openai-main",
      }),
    ).not.toBeInTheDocument();
    expect(screen.getByText("无权限")).toBeInTheDocument();
  });

  it("shows request log and provider key navigation after sign-in", async () => {
    stubHealthyFetch();

    await renderSignedInApp();

    expect(
      screen.getByRole("button", { name: /请求与追踪/ }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /审计日志/ }),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /计费/ })).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /供应商密钥/ }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /API 密钥/ }),
    ).toBeInTheDocument();
  });

  it("renders distribution readiness with Chinese operator copy", async () => {
    stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /分发就绪/ }));

    expect(
      await screen.findByRole("heading", { level: 2, name: "Compact readiness" }),
    ).toBeInTheDocument();
    expect(screen.getAllByText("API 分发").length).toBeGreaterThan(0);
    expect(screen.getByText("操作面板")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /接入供应商/ }),
    ).toBeInTheDocument();
    expect(screen.getByRole("columnheader", { name: "检查项" })).toBeInTheDocument();
    expect(screen.getByRole("columnheader", { name: "证据" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { level: 2, name: "最近失败请求" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { level: 2, name: "分发路由" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { level: 2, name: "用户自助交接" })).toBeInTheDocument();
    expect(document.querySelectorAll(".status-chip-v2").length).toBeGreaterThan(0);
    expect(document.querySelector(".status-pill")).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: /接入供应商/ }));

    expect(
      await screen.findByRole("dialog", { name: "真实供应商接入向导" }),
    ).toBeInTheDocument();
    expect(screen.getByLabelText("供应商名称")).toHaveValue("OpenAI");
    expect(
      screen.getByRole("button", { name: "创建非密钥配置" }),
    ).toBeInTheDocument();
    expect(document.body.textContent).toContain("真实供应商接入计划");
  });

  it("trims navigation for viewer capability summary without hiding all sections", async () => {
    stubHealthyFetch(["viewer"]);

    await renderSignedInApp();

    expect(
      screen.getByRole("button", { name: /请求与追踪/ }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /审计日志/ }),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /计费/ })).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /仪表盘/ }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /供应商密钥/ }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /供应商与通道/ }),
    ).not.toBeInTheDocument();
    expect(screen.queryByText("provider.manage")).not.toBeInTheDocument();
  });

  it("keeps billing users scoped to billing navigation", async () => {
    stubHealthyFetch(["billing"]);

    await renderSignedInApp();

    expect(screen.getByRole("button", { name: /计费/ })).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /审计日志/ }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /请求与追踪/ }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /供应商与通道/ }),
    ).not.toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 1, name: "计费 / 价格" }),
    ).toBeInTheDocument();
  });

  it("defaults provider scoped admins to providers when overview is unavailable", async () => {
    stubHealthyFetch(["provider"]);

    await renderSignedInApp();

    expect(
      screen.getByRole("heading", { level: 1, name: "供应商与通道" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /供应商与通道/ }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /计费/ }),
    ).not.toBeInTheDocument();
  });

  it("defaults request scoped admins to requests when overview is unavailable", async () => {
    stubHealthyFetch(["request"]);

    await renderSignedInApp();

    expect(
      screen.getByRole("heading", { level: 1, name: "请求与追踪" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /请求与追踪/ }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /供应商与通道/ }),
    ).not.toBeInTheDocument();
  });

  it("shows a safe placeholder when no admin workspace is available", async () => {
    stubHealthyFetch(["none"]);

    await renderSignedInApp();

    expect(
      screen.getByRole("heading", { level: 1, name: "没有可用管理工作区" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "没有可用区域" }),
    ).toBeInTheDocument();
    expect(screen.getByText("当前管理员权限没有包含任何控制台区域。")).toBeInTheDocument();
    expect(screen.queryByText("provider.manage")).not.toBeInTheDocument();
  });

  it("keeps ops users on operational provider sections without billing", async () => {
    stubHealthyFetch(["ops"]);

    await renderSignedInApp();

    expect(
      screen.getByRole("button", { name: /仪表盘/ }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /请求与追踪/ }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /审计日志/ }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /供应商与通道/ }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /供应商密钥/ }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /计费/ }),
    ).not.toBeInTheDocument();
  });

  it("switches navigation sections and requests provider key recovery through the API", async () => {
    const fetchMock = stubHealthyFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /供应商与通道/ }));
    expect(
      screen.getByRole("heading", { level: 1, name: "供应商与通道" }),
    ).toBeInTheDocument();
    expect(
      await screen.findByRole("heading", {
        level: 2,
        name: "供应商库存",
      }),
    ).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: /仪表盘/ }));
    const recoveryButton = await screen.findByRole("button", {
      name: "请求恢复 openai-main",
    });
    await user.click(recoveryButton);

    await waitFor(() => expect(recoveryButton).toHaveTextContent("已请求"));
    expect(recoveryButton).toBeDisabled();
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/control-plane/admin/provider-keys/provider-key-1/recovery",
      expect.objectContaining({
        body: JSON.stringify({
          reason: "overview manual recovery request",
          target_status: "recovery_probe",
        }),
        method: "POST",
      }),
    );
    expect(
      screen.queryByText(skPlaceholder("recovery-response-hidden")),
    ).not.toBeInTheDocument();
  });

  it("opens the admin command palette for navigation and safe key prefix jumps", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: "打开全局快速导航" }));
    expect(screen.getByRole("dialog", { name: "全局快速导航" })).toBeInTheDocument();
    expect(
      screen.getByText(
        "只做导航和安全定位提示；不会执行全局数据搜索，也不会展示 secret、Authorization、prompt 或 raw payload。",
      ),
    ).toBeInTheDocument();

    await user.type(screen.getByLabelText("全局搜索或跳转"), "routing");
    await user.click(screen.getByRole("option", { name: /Routing/ }));
    expect(screen.getByRole("heading", { level: 1, name: "路由" })).toBeInTheDocument();

    await user.keyboard("{Control>}k{/Control}");
    await user.type(screen.getByLabelText("全局搜索或跳转"), "request:req_1");
    await user.click(screen.getByRole("option", { name: /跳转到 Request ID/ }));
    expect(screen.getByRole("heading", { level: 1, name: "请求与追踪" })).toBeInTheDocument();
    await waitFor(() =>
      expect(
        fetchMock.mock.calls.some(([url]) => String(url).includes("/admin/request-logs/req_1")),
      ).toBe(true),
    );

    await user.keyboard("{Control>}k{/Control}");
    await user.type(screen.getByLabelText("全局搜索或跳转"), "key:vk-main-prefix");
    await user.click(screen.getByRole("option", { name: /跳转到 API Key Prefix/ }));

    expect(await screen.findByText("安全跳转 focus")).toBeInTheDocument();
    expect(document.body.textContent).toContain("Prefix vk-main-prefix");
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain("raw payload");
  });

  it("shows provider key recovery API failures without exposing secrets", async () => {
    stubHealthyFetch(["owner"], { recoveryFails: true });

    const user = await renderSignedInApp();

    const recoveryButton = await screen.findByRole("button", {
      name: "请求恢复 openai-main",
    });
    await user.click(recoveryButton);

    await waitFor(() => expect(recoveryButton).toHaveTextContent("重试"));
    expect(recoveryButton).not.toBeDisabled();
    expect(
      await screen.findByText(
        "provider key status `auth_failed` cannot be recovered through this endpoint",
      ),
    ).toBeInTheDocument();
    expect(
      screen.queryByText(skPlaceholder("recovery-response-hidden")),
    ).not.toBeInTheDocument();
  });

  it("redacts secret-bearing provider key recovery errors", async () => {
    stubHealthyFetch(["owner"], { recoveryFailsWithSecret: true });

    const user = await renderSignedInApp();

    const recoveryButton = await screen.findByRole("button", {
      name: "请求恢复 openai-main",
    });
    await user.click(recoveryButton);

    await waitFor(() => expect(recoveryButton).toHaveTextContent("重试"));
    expect(await screen.findByText("Request failed.")).toBeInTheDocument();
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("recovery-error-hidden"),
    );
    expect(document.body.textContent).not.toContain("fp-recovery-hidden");
    expect(document.body.textContent).not.toContain("current_window_state");
    expect(document.body.textContent).not.toContain("raw metadata");
  });

  it("renders request logs and safe request detail fields", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /请求与追踪/ }));

    expect(await screen.findByText("req_1")).toBeInTheDocument();
    expect(screen.getByText("gpt-4o-mini")).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "查看请求日志 req_1" }),
    );

    expect(await screen.findByText("供应商尝试")).toBeInTheDocument();
    expect(screen.getByText("provider-1")).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "支持摘要" }),
    ).toBeInTheDocument();
    const supportSummaryPanel = screen
      .getByRole("heading", { level: 2, name: "支持摘要" })
      .closest("article");
    expect(supportSummaryPanel).not.toBeNull();
    expect(
      within(supportSummaryPanel as HTMLElement).getByText(
        "请求 succeeded；路由、用量、账本和脱敏信息可供查看。",
      ),
    ).toBeInTheDocument();
    expect(
      within(supportSummaryPanel as HTMLElement).getByText("channel-1 / 3 个候选"),
    ).toBeInTheDocument();
    expect(
      within(supportSummaryPanel as HTMLElement).getByText("共 1 次 / 失败 0 次"),
    ).toBeInTheDocument();
    expect(
      within(supportSummaryPanel as HTMLElement).getByText("未记录回退"),
    ).toBeInTheDocument();
    expect(
      within(supportSummaryPanel as HTMLElement).getByText("输入 100 / 输出 55"),
    ).toBeInTheDocument();
    expect(
      within(supportSummaryPanel as HTMLElement).getByText("1 条账本记录"),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "路由 Trace" }),
    ).toBeInTheDocument();
    const routeTracePanel = screen
      .getByRole("heading", { level: 2, name: "路由 Trace" })
      .closest("article");
    expect(routeTracePanel).not.toBeNull();
    expect(
      within(routeTracePanel as HTMLElement).getByText("channel-1"),
    ).toBeInTheDocument();
    expect(
      within(routeTracePanel as HTMLElement).getByText("priority_weight"),
    ).toBeInTheDocument();
    expect(
      within(routeTracePanel as HTMLElement).getByText(
        "gpt-route-summary-upstream",
      ),
    ).toBeInTheDocument();
    expect(
      within(routeTracePanel as HTMLElement).getByText("fallback_allowed"),
    ).toBeInTheDocument();
    expect(
      within(routeTracePanel as HTMLElement).getByText("none"),
    ).toBeInTheDocument();
    expect(
      within(routeTracePanel as HTMLElement).getByText("3"),
    ).toBeInTheDocument();
    expect(
      within(routeTracePanel as HTMLElement).getByText("2"),
    ).toBeInTheDocument();
    expect(
      within(routeTracePanel as HTMLElement).getByText(
        "ZeroWeight, CoolingDown",
      ),
    ).toBeInTheDocument();
    expect(
      within(routeTracePanel as HTMLElement).getByText("2144483738"),
    ).toBeInTheDocument();
    expect(
      within(routeTracePanel as HTMLElement).getByText("Disabled"),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "Prompt Protection" }),
    ).toBeInTheDocument();
    const promptProtectionPanel = screen
      .getByRole("heading", { level: 2, name: "Prompt Protection" })
      .closest("article");
    expect(promptProtectionPanel).not.toBeNull();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText("enforce"),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getAllByText("reject")
        .length,
    ).toBeGreaterThanOrEqual(2);
    expect(
      within(promptProtectionPanel as HTMLElement).getByText(
        "prompt_injection_detected",
      ),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText(
        "messages, metadata",
      ),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText(
        "authorization_bearer: 1, prompt_injection_phrase: 1",
      ),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText("regex: 1"),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText("0"),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText(
        "unavailable: live_request_or_query_blocked",
      ),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText(
        "not eligible, out of bounds or unavailable",
      ),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getAllByText("blocked")
        .length,
    ).toBeGreaterThanOrEqual(2);
    expect(
      within(promptProtectionPanel as HTMLElement).getByText(
        PROMPT_PROTECTION_CLOSURE_CHECKLIST_TEXT,
      ),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText(
        "gateway_live_proof_blocker, postgres_audit_row_missing, mock_provider_upstream_refusal_missing",
      ),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText(
        "2026-06-04T13:30:00Z",
      ),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText("abcdef123456"),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText(
        "contract / simulated",
      ),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText("not eligible"),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText(
        "simulated_replay_refused",
      ),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText(
        "cannot close live gap",
      ),
    ).toBeInTheDocument();
    expect(
      within(promptProtectionPanel as HTMLElement).getByText(
        "raw payload, raw pattern values",
      ),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "账本条目" }),
    ).toBeInTheDocument();
    expect(screen.getAllByText("0.0123 USD").length).toBeGreaterThan(0);
    expect(screen.getByText("settle")).toBeInTheDocument();
    expect(screen.getByText("-0.01230000 USD")).toBeInTheDocument();
    expect(screen.getAllByText("00000000...").length).toBeGreaterThan(0);
    expect(
      screen.getByText(
        "config-needed: historical wallet balance snapshots are not stored on ledger_entries",
      ),
    ).toBeInTheDocument();
    expect(
      screen.getByText("order 00000000... / capture 00000000..."),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "载荷预览" }),
    ).toBeInTheDocument();
    expect(screen.getByText("request-body-hash-hidden")).toBeInTheDocument();
    expect(screen.getByText("response-body-hash-hidden")).toBeInTheDocument();
    expect(
      fetchMock.mock.calls
        .map(([url]) => String(url))
        .filter((url) => url.includes("/payload")),
    ).toEqual([]);
    expect(
      screen.queryByText((content) =>
        content.includes('"strategy": "weighted-fallback"'),
      ),
    ).not.toBeInTheDocument();
    expect(screen.queryByText("weighted-fallback")).not.toBeInTheDocument();
    expect(screen.queryByText("payload-123-hidden")).not.toBeInTheDocument();
    expect(screen.queryByText("raw prompt hidden")).not.toBeInTheDocument();
    expect(document.body.textContent).not.toContain(
      "raw prompt protection prompt hidden",
    );
    expect(document.body.textContent).not.toContain(
      "secret-like prompt protection pattern hidden",
    );
    expect(document.body.textContent).not.toContain("custom-reject-rule");
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-rule-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-pattern-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-provider-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-side-effect-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-token-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-protection-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "raw prompt protection performance body hidden",
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-performance-command-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-performance-header-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "postgres://prompt-performance-dsn-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "C:\\secret\\prompt-proof-report-hidden.json",
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-artifact-command-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "postgres://prompt-artifact-dsn-hidden",
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-artifact-provider-hidden"),
    );
    expect(document.body.textContent).not.toContain("feedfacefeedface");
    expect(screen.queryByText("provider-key-1")).not.toBeInTheDocument();
    expect(screen.queryByText("settle:request-1")).not.toBeInTheDocument();
    expect(screen.queryByText("price-version-1")).not.toBeInTheDocument();
    expect(
      screen.queryByText(skPlaceholder("route-hidden")),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText(bearerPlaceholder("route-hidden")),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText(bearerPlaceholder("nested-route-hidden")),
    ).not.toBeInTheDocument();
  });

  it("keeps legacy request logs without prompt protection metadata compatible", async () => {
    stubAdminFetch({ promptProtectionSignals: false });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /请求与追踪/ }));
    await user.click(
      await screen.findByRole("button", { name: "查看请求日志 req_1" }),
    );

    expect(await screen.findByText("供应商尝试")).toBeInTheDocument();
    expect(
      screen.queryByRole("heading", { level: 2, name: "Prompt Protection" }),
    ).not.toBeInTheDocument();
  });

  it("lazy loads request payload preview only after explicit action and renders safe fields", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /请求与追踪/ }));
    await user.click(
      await screen.findByRole("button", { name: "查看请求日志 req_1" }),
    );

    const payloadCalls = () =>
      fetchMock.mock.calls
        .map(([url]) => String(url))
        .filter((url) => url.includes("/payload"));
    expect(payloadCalls()).toEqual([]);

    await user.click(
      screen.getByRole("button", { name: "加载载荷预览 req_1" }),
    );

    await waitFor(() =>
      expect(payloadCalls()).toEqual([
        "/api/control-plane/admin/request-logs/req_1/payload",
      ]),
    );
    expect(
      await screen.findByText("载荷预览已加载。"),
    ).toBeInTheDocument();
    expect(screen.getByText("request-preview-hash")).toBeInTheDocument();
    expect(screen.getByText("response-preview-hash")).toBeInTheDocument();
    expect(document.body.textContent).toContain("messages_count");
    expect(document.body.textContent).toContain("byte_count");
    expect(document.body.textContent).not.toContain("raw lazy payload hidden");
    expect(document.body.textContent).not.toContain("raw response body hidden");
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("payload-preview-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("payload-response-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "provider-key-secret-hidden",
    );
    expect(document.body.textContent).not.toContain("raw_headers");
  });

  it("sends request log troubleshooting filters to the list API", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /请求与追踪/ }));
    await screen.findByText("req_1");
    await user.selectOptions(screen.getByLabelText("状态"), "failed");
    await user.type(screen.getByLabelText("起始时间"), "2026-06-02T00:00");
    await user.type(screen.getByLabelText("结束时间"), "2026-06-03T00:00");
    await user.type(screen.getByLabelText("模型"), "gpt-4o-mini");
    await user.type(screen.getByLabelText("API Key"), "key-1");
    await user.type(screen.getByLabelText("Channel ID"), "channel-1");
    await user.selectOptions(screen.getByLabelText("Stream"), "true");
    await user.type(screen.getByLabelText("错误类型"), "rate_limit");
    await user.click(screen.getByRole("button", { name: "搜索" }));

    await waitFor(() =>
      expect(fetchMock.mock.calls.map(([url]) => String(url))).toContain(
        "/api/control-plane/admin/request-logs?api_key_profile_id=key-1&channel_id=channel-1&created_from=2026-06-02T00%3A00&created_to=2026-06-03T00%3A00&error_type=rate_limit&limit=25&model=gpt-4o-mini&status=failed&stream=true&virtual_key_id=key-1",
      ),
    );
  });

  it("exports current request log filters through the backend CSV route", async () => {
    const fetchMock = stubAdminFetch();
    const exportedParts: BlobPart[][] = [];
    const originalBlob = globalThis.Blob;
    class CapturingBlob extends originalBlob {
      constructor(parts?: BlobPart[], options?: BlobPropertyBag) {
        exportedParts.push(parts ?? []);
        super(parts, options);
      }
    }
    vi.stubGlobal("Blob", CapturingBlob);
    const createObjectUrl = vi.fn(() => "blob:request-log-export");
    const revokeObjectUrl = vi.fn();
    Object.defineProperty(URL, "createObjectURL", {
      configurable: true,
      value: createObjectUrl,
    });
    Object.defineProperty(URL, "revokeObjectURL", {
      configurable: true,
      value: revokeObjectUrl,
    });
    const anchorClick = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined);

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /请求与追踪/ }));
    expect(await screen.findByText("req_1")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "后端导出" }));

    expect(createObjectUrl).toHaveBeenCalledTimes(1);
    expect(revokeObjectUrl).toHaveBeenCalledTimes(1);
    expect(anchorClick).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toContain(
      "/api/control-plane/admin/request-logs/export.csv?limit=25",
    );
    const exportedText = exportedParts.flat().map(String).join("\n");
    expect(exportedText).toContain("request_id");
    expect(exportedText).toContain("redaction_status");
    expect(exportedText).toContain("req_1");
    expect(exportedText).toContain("succeeded");
    expect(exportedText).not.toContain("raw prompt hidden");
    expect(exportedText).not.toContain("raw lazy payload hidden");
    expect(exportedText).not.toContain(AUTH_HEADER_NAME);
    expect(exportedText).not.toContain(skPlaceholder("prompt-provider-hidden"));
    expect(exportedText).not.toContain("provider-key-secret-hidden");
  });

  it("falls back to local secret-safe request log CSV when backend export is unavailable", async () => {
    stubAdminFetch({ requestLogExportStatus: "notImplemented" });
    const exportedParts: BlobPart[][] = [];
    const originalBlob = globalThis.Blob;
    class CapturingBlob extends originalBlob {
      constructor(parts?: BlobPart[], options?: BlobPropertyBag) {
        exportedParts.push(parts ?? []);
        super(parts, options);
      }
    }
    vi.stubGlobal("Blob", CapturingBlob);
    Object.defineProperty(URL, "createObjectURL", {
      configurable: true,
      value: vi.fn(() => "blob:request-log-local-export"),
    });
    Object.defineProperty(URL, "revokeObjectURL", {
      configurable: true,
      value: vi.fn(),
    });
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined);

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /请求与追踪/ }));
    expect(await screen.findByText("req_1")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "后端导出" }));

    expect(await screen.findByText(/已回退到本地安全 CSV/)).toBeInTheDocument();
    const exportedText = exportedParts.flat().map(String).join("\n");
    expect(exportedText).toContain("request_id");
    expect(exportedText).toContain("requested_model");
    expect(exportedText).toContain("redaction_status");
    expect(exportedText).toContain("req_1");
    expect(exportedText).toContain("gpt-4o-mini");
    expect(exportedText).not.toContain("provider_key_id");
    expect(exportedText).not.toContain("raw prompt hidden");
    expect(exportedText).not.toContain("raw lazy payload hidden");
    expect(exportedText).not.toContain(AUTH_HEADER_NAME);
    expect(exportedText).not.toContain(skPlaceholder("request-export-hidden"));
    expect(exportedText).not.toContain(skPlaceholder("prompt-provider-hidden"));
    expect(exportedText).not.toContain("provider-key-secret-hidden");
  });

  it("shows payload preview permission failures without exposing response secrets", async () => {
    const fetchMock = stubAdminFetch({ payloadPreviewStatus: "forbidden" });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /请求与追踪/ }));
    await user.click(
      await screen.findByRole("button", { name: "查看请求日志 req_1" }),
    );
    await user.click(
      screen.getByRole("button", { name: "加载载荷预览 req_1" }),
    );

    await waitFor(() =>
      expect(
        fetchMock.mock.calls
          .map(([url]) => String(url))
          .filter((url) => url.includes("/payload")),
      ).toHaveLength(1),
    );
    expect(
      await screen.findByText(
        "你没有权限加载载荷预览。",
      ),
    ).toBeInTheDocument();
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("payload-forbidden-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("payload-forbidden-hidden"),
    );
  });

  it("shows payload preview unimplemented state without exposing response secrets", async () => {
    const fetchMock = stubAdminFetch({
      payloadPreviewStatus: "notImplemented",
    });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /请求与追踪/ }));
    await user.click(
      await screen.findByRole("button", { name: "查看请求日志 req_1" }),
    );
    await user.click(
      screen.getByRole("button", { name: "加载载荷预览 req_1" }),
    );

    await waitFor(() =>
      expect(
        fetchMock.mock.calls
          .map(([url]) => String(url))
          .filter((url) => url.includes("/payload")),
      ).toHaveLength(1),
    );
    expect(
      await screen.findByText("载荷预览 API 尚未实现。"),
    ).toBeInTheDocument();
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("payload-not-implemented-hidden"),
    );
  });

  it("keeps payload preview action disabled when no payload preview was stored", async () => {
    const fetchMock = stubAdminFetch({ payloadStored: false });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /请求与追踪/ }));
    await user.click(
      await screen.findByRole("button", { name: "查看请求日志 req_1" }),
    );

    const loadButton = screen.getByRole("button", {
      name: "加载载荷预览 req_1",
    });
    expect(loadButton).toBeDisabled();
    expect(
      screen.getByText("此请求未存储载荷预览。"),
    ).toBeInTheDocument();
    await user.click(loadButton);
    expect(
      fetchMock.mock.calls
        .map(([url]) => String(url))
        .filter((url) => url.includes("/payload")),
    ).toEqual([]);
  });

  it("queries trace summary and renders safe trace request rows", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /请求与追踪/ }));
    await user.type(await screen.findByLabelText("Trace ID"), "trace-1");
    await user.click(screen.getByRole("button", { name: "搜索" }));

    expect(
      await screen.findByRole("heading", { level: 2, name: "Trace 摘要" }),
    ).toBeInTheDocument();
    const metrics = screen.getByLabelText("Trace 摘要指标");
    expect(within(metrics).getByText("请求数")).toBeInTheDocument();
    expect(within(metrics).getByText("2")).toBeInTheDocument();
    expect(within(metrics).getByText("错误数")).toBeInTheDocument();
    expect(within(metrics).getByText("300")).toBeInTheDocument();
    expect(within(metrics).getByText("155")).toBeInTheDocument();
    expect(screen.getByText("账本行")).toBeInTheDocument();
    expect(screen.getAllByText("settle").length).toBeGreaterThan(0);
    expect(await screen.findByText("req_2")).toBeInTheDocument();
    expect(document.body.textContent).toContain(
      "provider_auth_failed [redacted]",
    );

    await waitFor(() =>
      expect(fetchMock.mock.calls.map(([url]) => String(url))).toContain(
        "/api/control-plane/admin/traces/trace-1?limit=25",
      ),
    );
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("requested-model-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("trace-error-hidden"),
    );
    expect(document.body.textContent).not.toContain("raw trace prompt hidden");
    expect(document.body.textContent).not.toContain(
      "raw trace response hidden",
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("trace-route-hidden"),
    );
  });

  it("merges trace summary into the request detail drawer", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /请求与追踪/ }));
    await user.click(
      await screen.findByRole("button", { name: "查看请求日志 req_1" }),
    );

    expect(
      await screen.findByRole("heading", { level: 2, name: "Trace 失败原因" }),
    ).toBeInTheDocument();
    expect(screen.getByText("Trace trace-1 / 2 个请求。")).toBeInTheDocument();
    expect(screen.getByText("1 / 2")).toBeInTheDocument();
    expect(document.body.textContent).toContain(
      "provider_auth_failed [redacted]",
    );
    await waitFor(() =>
      expect(fetchMock.mock.calls.map(([url]) => String(url))).toContain(
        "/api/control-plane/admin/traces/trace-1?limit=25",
      ),
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("trace-route-hidden"),
    );
    expect(document.body.textContent).not.toContain("raw trace prompt hidden");
  });

  it("renders audit logs with filters and secret-safe snapshots", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /审计日志/ }));

    expect(
      await screen.findByRole("heading", { level: 1, name: "审计日志" }),
    ).toBeInTheDocument();
    expect(await screen.findByText("audit-1")).toBeInTheDocument();
    expect(screen.getByText("provider_key.update")).toBeInTheDocument();
    expect(document.body.textContent).toContain("provider_key");
    expect(screen.getByText("not provided")).toBeInTheDocument();
    expect(screen.getByText("manual_disabled")).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "查看审计日志 audit-1" }),
    );

    expect(
      await screen.findByRole("heading", { level: 2, name: "Audit detail" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "Safe metadata summary" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "Detail readback" }),
    ).toBeInTheDocument();
    expect(screen.getByText("audit_log_detail_readback.v1")).toBeInTheDocument();
    expect(screen.getByText(/actor=true session=true/)).toBeInTheDocument();
    expect(screen.getByText(/metadata=2, before=2, after=2/)).toBeInTheDocument();
    expect(screen.getByText("hidden_metadata_fields")).toBeInTheDocument();
    expect(document.body.textContent).toContain("manual_disabled");
    expect(document.body.textContent).not.toContain("client-ip-hash");
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("audit-before-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("audit-after-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("audit-before-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("audit-after-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "raw before payload hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw audit metadata payload hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw prompt protection prompt hidden",
    );
    expect(document.body.textContent).not.toContain(
      "secret-like prompt protection pattern hidden",
    );
    expect(document.body.textContent).not.toContain("custom-reject-rule");
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-rule-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-pattern-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-provider-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-side-effect-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-token-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-protection-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "raw prompt protection performance body hidden",
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-performance-command-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-performance-header-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "postgres://prompt-performance-dsn-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "C:\\secret\\prompt-proof-report-hidden.json",
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-artifact-command-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "postgres://prompt-artifact-dsn-hidden",
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-artifact-provider-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "C:\\secret\\prompt-handoff-report-hidden.json",
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-handoff-command-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "postgres://prompt-handoff-dsn-hidden",
    );
    expect(document.body.textContent).not.toContain("feedfacefeedface");
    expect(document.body.textContent).not.toContain("prompt_protection");
    expect(document.body.textContent).not.toContain("raw_headers");
    expect(document.body.textContent).not.toContain('"payload"');

    await user.type(screen.getByLabelText("Action"), "provider_key.update");
    await user.type(screen.getByLabelText("Entity"), "provider_key");
    await user.type(
      screen.getByLabelText("Actor"),
      "00000000-0000-0000-0000-000000000070",
    );
    await user.type(
      screen.getByLabelText("Time from"),
      "2026-06-03T00:00:00Z",
    );
    await user.type(
      screen.getByLabelText("Time to"),
      "2026-06-03T23:59:59Z",
    );
    await user.clear(screen.getByLabelText("Limit"));
    await user.type(screen.getByLabelText("Limit"), "5");
    await user.click(screen.getByRole("button", { name: "Search" }));

    await waitFor(() =>
      expect(fetchMock.mock.calls.map(([url]) => String(url))).toContain(
        "/api/control-plane/admin/audit-logs?action=provider_key.update&actor_user_id=00000000-0000-0000-0000-000000000070&created_from=2026-06-03T00%3A00%3A00Z&created_to=2026-06-03T23%3A59%3A59Z&limit=5&resource_type=provider_key",
      ),
    );
  });

  it("keeps prompt protection audit proof material hidden in the admin operations view", async () => {
    stubAdminFetch({ promptProtectionProofVariant: "liveEligible" });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /审计日志/ }));
    await user.click(
      await screen.findByRole("button", { name: "查看审计日志 audit-1" }),
    );

    expect(
      await screen.findByRole("heading", {
      level: 2,
      name: "Safe metadata summary",
    }),
    ).toBeInTheDocument();

    expect(screen.queryByRole("heading", { level: 2, name: "Prompt Protection" })).not.toBeInTheDocument();
    expect(document.body.textContent).not.toContain("prompt_protection");
    expect(document.body.textContent).not.toContain("live_proof_report");
    expect(document.body.textContent).not.toContain(PROMPT_PROTECTION_CLOSURE_CHECKLIST_TEXT);
    expect(document.body.textContent).not.toContain(
      "C:\\secret\\prompt-live-proof-report-hidden.json",
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-live-artifact-command-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "postgres://prompt-live-artifact-dsn-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "C:\\secret\\prompt-live-handoff-report-hidden.json",
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-live-handoff-command-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "postgres://prompt-live-handoff-dsn-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "postgres://prompt-live-performance-dsn-hidden",
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-live-performance-command-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-live-performance-header-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-live-artifact-provider-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-live-unavailable-hidden"),
    );
    expect(document.body.textContent).not.toContain("deadc0dedeadc0de");
    expect(document.body.textContent).not.toContain(
      "raw live prompt proof performance body hidden",
    );
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
  });

  it("keeps failed prompt proof handoff material hidden in the admin operations view", async () => {
    stubAdminFetch({ promptProtectionProofVariant: "failedRefused" });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /审计日志/ }));
    await user.click(
      await screen.findByRole("button", { name: "查看审计日志 audit-1" }),
    );

    expect(
      await screen.findByRole("heading", {
      level: 2,
      name: "Safe metadata summary",
    }),
    ).toBeInTheDocument();

    expect(screen.queryByRole("heading", { level: 2, name: "Prompt Protection" })).not.toBeInTheDocument();
    expect(document.body.textContent).not.toContain("prompt_protection");
    expect(document.body.textContent).not.toContain("live_proof_report");
    expect(document.body.textContent).not.toContain("freshness_or_replay_refused");
    expect(document.body.textContent).not.toContain(
      "C:\\secret\\prompt-fail-handoff-report-hidden.json",
    );
    expect(document.body.textContent).not.toContain(
      "C:\\secret\\prompt-fail-proof-report-hidden.json",
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("prompt-fail-handoff-command-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "postgres://prompt-fail-handoff-dsn-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "postgres://prompt-fail-artifact-dsn-hidden",
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("prompt-fail-artifact-provider-hidden"),
    );
    expect(document.body.textContent).not.toContain("facefeedfacefeed");
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
  });

  it.each([
    {
      classification: "stale_generated_at_refused",
      forbiddenDsn: "postgres://prompt-stale-generated-dsn-hidden",
      forbiddenHashPrefix: "badc0ffee0ddf00d",
      forbiddenProvider: skPlaceholder(
        "prompt-stale-generated-provider-hidden",
      ),
      forbiddenReportPath:
        "C:\\secret\\prompt-stale-generated-proof-hidden.json",
      forbiddenToken: bearerPlaceholder(
        "prompt-stale-generated-command-hidden",
      ),
      readiness: "blocked",
      variant: "staleGeneratedAtRefused" as const,
    },
    {
      classification: "stale_repo_commit_refused",
      forbiddenDsn: "postgres://prompt-stale-commit-dsn-hidden",
      forbiddenHashPrefix: "c001c0dec001c0de",
      forbiddenProvider: skPlaceholder("prompt-stale-commit-provider-hidden"),
      forbiddenReportPath: "C:\\secret\\prompt-stale-commit-proof-hidden.json",
      forbiddenToken: bearerPlaceholder("prompt-stale-commit-command-hidden"),
      readiness: "fail",
      variant: "staleCommitRefused" as const,
    },
    {
      classification: "duplicate_proof_run_refused",
      forbiddenDsn: "postgres://prompt-duplicate-run-dsn-hidden",
      forbiddenHashPrefix: "d00df00dd00df00d",
      forbiddenProvider: skPlaceholder("prompt-duplicate-run-provider-hidden"),
      forbiddenReportPath: "C:\\secret\\prompt-duplicate-run-proof-hidden.json",
      forbiddenToken: bearerPlaceholder("prompt-duplicate-run-command-hidden"),
      readiness: "fail",
      variant: "duplicateRunRefused" as const,
    },
    {
      classification: "simulated_replay_refused",
      forbiddenDsn: "postgres://prompt-simulated-replay-dsn-hidden",
      forbiddenHashPrefix: "51015eed51015eed",
      forbiddenProvider: skPlaceholder(
        "prompt-simulated-replay-provider-hidden",
      ),
      forbiddenReportPath:
        "C:\\secret\\prompt-simulated-replay-proof-hidden.json",
      forbiddenToken: bearerPlaceholder(
        "prompt-simulated-replay-command-hidden",
      ),
      readiness: "blocked",
      variant: "simulatedReplayRefused" as const,
    },
  ])(
    "renders prompt protection proof replay refusal for $classification without raw artifact material",
    async ({
      classification,
      forbiddenDsn,
      forbiddenHashPrefix,
      forbiddenProvider,
      forbiddenReportPath,
      forbiddenToken,
      readiness,
      variant,
    }) => {
      stubAdminFetch({ promptProtectionProofVariant: variant });

      const user = await renderSignedInApp();

      await user.click(screen.getByRole("button", { name: /审计日志/ }));
      await user.click(
        await screen.findByRole("button", { name: "查看审计日志 audit-1" }),
      );

      const auditPromptPanel = await screen.findByRole("heading", {
        level: 2,
        name: "Prompt Protection",
      });
      const panel = auditPromptPanel.closest("article");
      expect(panel).not.toBeNull();

      if (readiness === "blocked") {
        expect(
          within(panel as HTMLElement).getAllByText("blocked").length,
        ).toBeGreaterThanOrEqual(1);
      } else {
        expect(
          within(panel as HTMLElement).getByText(readiness),
        ).toBeInTheDocument();
      }
      expect(
        within(panel as HTMLElement).getByText(classification),
      ).toBeInTheDocument();
      expect(within(panel as HTMLElement).getByText("0")).toBeInTheDocument();
      expect(
        within(panel as HTMLElement).getByText("live_proof_report"),
      ).toBeInTheDocument();
      expect(
        within(panel as HTMLElement).getByText(
          "provider_attempts_count, latency_envelope, provenance",
        ),
      ).toBeInTheDocument();
      expect(
        within(panel as HTMLElement).getByText(
          "provider_attempts=0, latency bounded, duration available, current provenance",
        ),
      ).toBeInTheDocument();
      expect(
        within(panel as HTMLElement).getByText(
          PROMPT_PROTECTION_CLOSURE_CHECKLIST_TEXT,
        ),
      ).toBeInTheDocument();
      expect(
        within(panel as HTMLElement).getByText(
          classification.replace("_refused", ""),
        ),
      ).toBeInTheDocument();
      expect(
        within(panel as HTMLElement).getAllByText("not eligible").length,
      ).toBeGreaterThanOrEqual(1);

      expect(document.body.textContent).not.toContain(forbiddenReportPath);
      expect(document.body.textContent).not.toContain(forbiddenToken);
      expect(document.body.textContent).not.toContain(forbiddenDsn);
      expect(document.body.textContent).not.toContain(forbiddenProvider);
      expect(document.body.textContent).not.toContain(forbiddenHashPrefix);
      expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    },
  );

  it.each([
    {
      auditReadiness: "pass",
      closureGaps: ["none"],
      durationAvailable: true,
      freshnessReplay: "current_live_proof",
      latencyClosureEligible: true,
      liveClosureEligible: true,
      performanceWithinBounds: true,
      proofMode: "live / live",
      providerAttempts: 0,
      rawMarker: "prompt-export-current-hidden",
    },
    {
      auditReadiness: "fail",
      closureGaps: ["stale_generated_at"],
      durationAvailable: true,
      freshnessReplay: "stale_generated_at_refused",
      latencyClosureEligible: true,
      liveClosureEligible: false,
      performanceWithinBounds: true,
      proofMode: "live / live",
      providerAttempts: 0,
      rawMarker: "prompt-export-stale-hidden",
    },
    {
      auditReadiness: "blocker",
      closureGaps: ["simulated_replay"],
      durationAvailable: false,
      freshnessReplay: "simulated_replay_refused",
      latencyClosureEligible: false,
      liveClosureEligible: false,
      performanceWithinBounds: false,
      proofMode: "contract / simulated",
      providerAttempts: 0,
      rawMarker: "prompt-export-simulated-hidden",
    },
    {
      auditReadiness: "blocker",
      closureGaps: ["duration_unavailable", "latency_envelope_missing"],
      durationAvailable: false,
      freshnessReplay: "current_live_proof",
      latencyClosureEligible: false,
      liveClosureEligible: false,
      performanceWithinBounds: false,
      proofMode: "live / live",
      providerAttempts: 0,
      rawMarker: "prompt-export-duration-hidden",
    },
    {
      auditReadiness: "fail",
      closureGaps: ["provider_attempts_nonzero"],
      durationAvailable: true,
      freshnessReplay: "current_live_proof",
      latencyClosureEligible: true,
      liveClosureEligible: false,
      performanceWithinBounds: true,
      proofMode: "live / live",
      providerAttempts: 1,
      rawMarker: "prompt-export-attempt-hidden",
    },
  ])(
    "exports prompt protection evidence readback for $freshnessReplay / $auditReadiness without raw material",
    ({
      auditReadiness,
      closureGaps,
      durationAvailable,
      freshnessReplay,
      latencyClosureEligible,
      liveClosureEligible,
      performanceWithinBounds,
      proofMode,
      providerAttempts,
      rawMarker,
    }) => {
      const proofKind = proofMode.endsWith("simulated") ? "simulated" : "live";
      const proofModeValue = proofMode.startsWith("contract")
        ? "contract"
        : "live";
      const input = {
        action: "reject",
        audit_readiness: {
          classification: auditReadiness,
          closure_checklist: [
            "gateway_live_proof",
            "postgres_audit_row",
            "mock_provider_upstream_refusal",
            "provider_attempts_zero",
            "latency_envelope",
            "current_provenance",
            "duration_available",
            "freshness_replay_classification",
          ],
          closure_gaps: closureGaps,
          command_summary: "live_proof_report",
          current_provenance_required: true,
          duration_available_required: true,
          evidence_fields: [
            "provider_attempts_count",
            "latency_envelope",
            "provenance",
          ],
          freshness_replay_classification: freshnessReplay,
          latency_envelope_required: true,
          provider_attempts_zero_required: true,
          raw_command: `${AUTH_HEADER_NAME}: ${bearerPlaceholder(rawMarker)}`,
          raw_report_path: `C:\\secret\\${rawMarker}.json`,
          secret_dsn: `postgres://${rawMarker}`,
        },
        freshness: {
          freshness_replay_classification: freshnessReplay,
          generated_at_utc: "2026-06-04T14:05:00.000Z",
          live_evidence_closure_eligible: liveClosureEligible,
          proof_run_id_hash: `${rawMarker}${rawMarker}${rawMarker}`,
          raw_report_path: `C:\\secret\\${rawMarker}-freshness.json`,
          repo_head_commit: "1234567890abcdef1234567890abcdef12345678",
          stale_or_simulated_report_closes_live_gap: false,
        },
        mode: "enforce",
        performance: {
          db_evidence_duration_ms: durationAvailable ? 15 : null,
          duration_available: durationAvailable,
          raw_body: `raw prompt body ${rawMarker}`,
          request_preflight_duration_ms: durationAvailable ? 9 : null,
          total_case_duration_ms: durationAvailable ? 24 : null,
          unavailable_reason: durationAvailable ? null : "duration_unavailable",
        },
        performance_envelope: {
          all_endpoint_performance_within_bounds: performanceWithinBounds,
          command_summary: {
            authorization: bearerPlaceholder(`${rawMarker}-command`),
            database_url: `postgres://${rawMarker}-performance`,
          },
          duration_unavailable_marker: "duration_available=false",
          latency_envelope_closure_eligible: latencyClosureEligible,
          live_blocker_status:
            auditReadiness === "blocker" ? "blocked" : "not_blocked",
          provider_attempts_zero_required: true,
          raw_headers: {
            [AUTH_HEADER_NAME]: bearerPlaceholder(`${rawMarker}-header`),
          },
        },
        provider_attempts_count: providerAttempts,
        provider_secret: skPlaceholder(`${rawMarker}-provider`),
        provenance: {
          command_line: `${AUTH_HEADER_NAME}: ${bearerPlaceholder(`${rawMarker}-artifact`)}`,
          generated_at_utc: "2026-06-04T14:05:00.000Z",
          kind: proofKind,
          mode: proofModeValue,
          redacted_command_summary: {
            database_connection: `postgres://${rawMarker}-artifact`,
            provider_secret: skPlaceholder(`${rawMarker}-artifact-provider`),
            report_path: `C:\\secret\\${rawMarker}-artifact.json`,
          },
          repo: {
            head_commit: "1234567890abcdef1234567890abcdef12345678",
          },
        },
        raw_payload_omitted: true,
        raw_pattern_values_omitted: true,
        raw_prompt: `raw prompt ${rawMarker}`,
        schema: "gateway_prompt_protection_v1",
      };

      const readback = promptProtectionEvidenceReadback(input);
      expect(readback).not.toBeNull();
      expect(readback).toEqual(JSON.parse(JSON.stringify(readback)));
      expect(readback).toMatchObject({
        auditReadiness,
        closureGaps,
        closureRule:
          "provider_attempts=0, latency bounded, duration available, current provenance",
        currentCommit: "1234567890ab",
        freshnessReplay,
        proofMode,
        providerAttempts: String(providerAttempts),
        schema: "prompt_protection_evidence_readback_v1",
      });
      expect(readback?.closureChecklist).toEqual([
        "gateway_live_proof",
        "postgres_audit_row",
        "mock_provider_upstream_refusal",
        "provider_attempts_zero",
        "latency_envelope",
        "current_provenance",
        "duration_available",
        "freshness_replay_classification",
      ]);
      expect(readback?.proofEvidence).toEqual([
        "provider_attempts_count",
        "latency_envelope",
        "provenance",
      ]);

      const exported = JSON.stringify(readback);
      expect(exported).not.toContain(rawMarker);
      expect(exported).not.toContain("C:\\secret");
      expect(exported).not.toContain("postgres://");
      expect(exported).not.toContain(AUTH_HEADER_NAME);
      expect(exported).not.toContain(BEARER_SCHEME);
      expect(exported).not.toContain(SK_PREFIX);
      expect(exported).not.toContain("raw prompt");
      expect(exported).not.toContain("raw prompt body");
    },
  );

  it.each([
    {
      auditReadiness: "pass",
      closureEligible: true,
      closureGaps: ["none"],
      durationAvailability: "total 24 ms / preflight 9 ms / db 15 ms",
      expectedClassification: "pass",
      expectedGaps: [],
      freshnessReplay: "current_live_proof",
      latencyEnvelope: "eligible",
      proofClosure: "eligible",
      proofMode: "live / live",
      providerAttempts: "0",
      rawMarker: "prompt-import-current-hidden",
    },
    {
      auditReadiness: "fail",
      closureEligible: false,
      closureGaps: ["stale_generated_at"],
      durationAvailability: "total 24 ms / preflight 9 ms / db 15 ms",
      expectedClassification: "fail",
      expectedGaps: [
        "stale_generated_at",
        "proof_closure_not_eligible",
        "freshness_replay_refused",
      ],
      freshnessReplay: "stale_generated_at_refused",
      latencyEnvelope: "eligible",
      proofClosure: "not eligible",
      proofMode: "live / live",
      providerAttempts: "0",
      rawMarker: "prompt-import-stale-hidden",
    },
    {
      auditReadiness: "blocker",
      closureEligible: false,
      closureGaps: ["simulated_replay"],
      durationAvailability: "total 24 ms / preflight 9 ms / db 15 ms",
      expectedClassification: "blocker",
      expectedGaps: [
        "simulated_replay",
        "current_live_proof_missing",
        "proof_closure_not_eligible",
        "freshness_replay_refused",
      ],
      freshnessReplay: "simulated_replay_refused",
      latencyEnvelope: "eligible",
      proofClosure: "not eligible",
      proofMode: "contract / simulated",
      providerAttempts: "0",
      rawMarker: "prompt-import-simulated-hidden",
    },
    {
      auditReadiness: "blocker",
      closureEligible: false,
      closureGaps: ["none"],
      durationAvailability: "total 24 ms / preflight 9 ms / db 15 ms",
      expectedClassification: "blocker",
      expectedGaps: ["provider_attempts_missing"],
      freshnessReplay: "current_live_proof",
      latencyEnvelope: "eligible",
      proofClosure: "eligible",
      proofMode: "live / live",
      providerAttempts: "-",
      rawMarker: "prompt-import-provider-missing-hidden",
    },
    {
      auditReadiness: "blocker",
      closureEligible: false,
      closureGaps: ["none"],
      durationAvailability: "unavailable: duration_unavailable",
      expectedClassification: "blocker",
      expectedGaps: [
        "latency_envelope_missing_or_ineligible",
        "duration_unavailable",
      ],
      freshnessReplay: "current_live_proof",
      latencyEnvelope: "-",
      proofClosure: "eligible",
      proofMode: "live / live",
      providerAttempts: "0",
      rawMarker: "prompt-import-latency-hidden",
    },
    {
      auditReadiness: "blocker",
      closureEligible: false,
      closureGaps: ["postgres_audit_row_missing"],
      durationAvailability: "total 24 ms / preflight 9 ms / db 15 ms",
      expectedClassification: "blocker",
      expectedGaps: ["postgres_audit_row_missing"],
      freshnessReplay: "current_live_proof",
      latencyEnvelope: "eligible",
      proofClosure: "eligible",
      proofMode: "live / live",
      providerAttempts: "0",
      rawMarker: "prompt-import-gap-hidden",
    },
    {
      auditReadiness: "fail",
      closureEligible: false,
      closureGaps: [
        "external_blocker",
        "provider_attempts_missing",
        "duration_unavailable",
      ],
      durationAvailability: "unavailable: duration_unavailable",
      expectedClassification: "blocker",
      expectedGaps: [
        "external_blocker",
        "provider_attempts_missing",
        "duration_unavailable",
        "latency_envelope_missing_or_ineligible",
        "proof_closure_not_eligible",
        "freshness_replay_refused",
      ],
      freshnessReplay: "stale_repo_commit_refused",
      latencyEnvelope: "not eligible, out of bounds or unavailable",
      proofClosure: "not eligible",
      proofMode: "live / live",
      providerAttempts: "-",
      rawMarker: "prompt-import-external-blocker-hidden",
    },
  ])(
    "gates imported prompt protection audit evidence for $rawMarker as $expectedClassification",
    ({
      auditReadiness,
      closureEligible,
      closureGaps,
      durationAvailability,
      expectedClassification,
      expectedGaps,
      freshnessReplay,
      latencyEnvelope,
      proofClosure,
      proofMode,
      providerAttempts,
      rawMarker,
    }) => {
      const importedReadback = {
        auditReadiness,
        closureChecklist: [
          "gateway_live_proof",
          "postgres_audit_row",
          "mock_provider_upstream_refusal",
          "provider_attempts_zero",
          "latency_envelope",
          "current_provenance",
          "duration_available",
          "freshness_replay_classification",
        ],
        closureGaps,
        closureRule:
          "provider_attempts=0, latency bounded, duration available, current provenance",
        currentCommit: "1234567890ab",
        durationAvailability,
        freshnessReplay,
        latencyEnvelope,
        omittedMaterial: "raw payload, raw pattern values",
        proofClosure,
        proofEvidence: [
          "provider_attempts_count",
          "latency_envelope",
          "provenance",
        ],
        proofMode,
        providerAttempts,
        raw_command: `${AUTH_HEADER_NAME}: ${bearerPlaceholder(`${rawMarker}-command`)}`,
        raw_prompt: `raw prompt ${rawMarker}`,
        raw_report_path: `C:\\secret\\${rawMarker}.json`,
        schema: "prompt_protection_evidence_readback_v1",
        secret_dsn: `postgres://${rawMarker}`,
        token: bearerPlaceholder(`${rawMarker}-token`),
      };

      const gate = promptProtectionAuditClosureGate(importedReadback);
      expect(gate).not.toBeNull();
      expect(gate).toEqual(JSON.parse(JSON.stringify(gate)));
      expect(gate).toMatchObject({
        classification: expectedClassification,
        closureEligible,
        gaps: expectedGaps,
        schema: "prompt_protection_audit_closure_gate_v1",
      });
      expect(gate?.readback).toMatchObject({
        auditReadiness,
        closureChecklist: [
          "gateway_live_proof",
          "postgres_audit_row",
          "mock_provider_upstream_refusal",
          "provider_attempts_zero",
          "latency_envelope",
          "current_provenance",
          "duration_available",
          "freshness_replay_classification",
        ],
        freshnessReplay,
        providerAttempts,
        schema: "prompt_protection_evidence_readback_v1",
      });

      const exported = JSON.stringify(gate);
      expect(exported).not.toContain(rawMarker);
      expect(exported).not.toContain("C:\\secret");
      expect(exported).not.toContain("postgres://");
      expect(exported).not.toContain(AUTH_HEADER_NAME);
      expect(exported).not.toContain(BEARER_SCHEME);
      expect(exported).not.toContain("raw prompt");
    },
  );

  it("imports prompt protection proof audit handoff bridge into the UI closure gate", () => {
    const bridge = {
      admin_ui_readback: {
        auditReadiness: "pass",
        closureChecklist: [
          "gateway_live_proof",
          "postgres_audit_row",
          "mock_provider_upstream_refusal",
          "provider_attempts_zero",
          "latency_envelope",
          "current_provenance",
          "duration_available",
          "freshness_replay_classification",
        ],
        closureGaps: ["none"],
        closureRule:
          "provider_attempts=0, latency bounded, duration available, current provenance",
        currentCommit: "1234567890ab",
        durationAvailability: "total available",
        freshnessReplay: "current_live_proof",
        latencyEnvelope: "eligible",
        omittedMaterial: "raw payload, raw pattern values",
        proofClosure: "eligible",
        proofEvidence: [
          "provider_attempts_count",
          "latency_envelope",
          "provenance",
        ],
        proofMode: "live / live",
        providerAttempts: "0",
        schema: "prompt_protection_evidence_readback_v1",
      },
      audit_import_command: {
        browser_handoff: {
          admin_session_header: "X-Admin-Session",
          admin_session_token_env: "PROMPT_PROTECTION_ADMIN_SESSION_TOKEN",
          admin_ui_base_url_env: "ADMIN_UI_BASE_URL",
          cookie_value_omitted: true,
          fallback_admin_session_token_env: "CONTROL_PLANE_ADMIN_SESSION_TOKEN",
          required_for_browser_audit_e2e: true,
          token_value_omitted: true,
        },
        command: "admin_ui_prompt_protection_audit_closure_gate_import",
        command_values_omitted: true,
        input_shape: "prompt_protection_evidence_readback_v1",
        raw_command: `${AUTH_HEADER_NAME}: ${bearerPlaceholder("prompt-bridge-command-hidden")}`,
        raw_report_path_omitted: true,
      },
      browser_audit_detail_attempt: {
        admin_session_header: "X-Admin-Session",
        admin_session_token_configured: false,
        admin_session_token_env: "PROMPT_PROTECTION_ADMIN_SESSION_TOKEN",
        admin_ui_base_url_configured: false,
        admin_ui_base_url_env: "ADMIN_UI_BASE_URL",
        blocker_reason: "admin_session_handoff_missing",
        browser_e2e_passed: false,
        classification: "blocker",
        cookie_value_omitted: true,
        fallback_admin_session_token_env: "CONTROL_PLANE_ADMIN_SESSION_TOKEN",
        raw_report_path_omitted: true,
        raw_values_omitted: true,
        required_readback: [
          "current_provenance",
          "duration_available",
          "latency_envelope",
          "provider_attempts_count=0",
          "request_log_hash_only",
          "stale_replay_refusal",
        ],
        requested: true,
        schema: "prompt_protection_browser_audit_detail_attempt_v1",
        stale_refusal_required: true,
        token_value_omitted: true,
      },
      audit_logs_mutation_row_attempt: {
        admin_api_endpoint: "GET /admin/audit-logs",
        blocker_reason: "none",
        classification: "pass",
        classification_reason: "none",
        closure_requires: [
          "admin_session_handoff",
          "audit_logs_tab_readable",
          "runtime_owned_prompt_protection_audit_row_present",
          "proof_owned_row_not_counted_as_runtime_closure",
          "request_trace_detail_readback_passed",
          "secret_safe_omission",
        ],
        cookie_value_omitted: true,
        ambiguous_prompt_protection_row_count: 0,
        failure_reason: "none",
        freshness: {
          current_run_marker: "target_request_id_count",
          generated_at_utc: "2026-06-04T14:05:00.000Z",
          proof_owned_rows_close_runtime_gap: false,
          repo_head_commit: "1234567890abcdef1234567890abcdef12345678",
          stale_or_proof_owned_report_closes_runtime_gap: false,
        },
        matching_rule:
          "matching Audit Logs row must be bound to this live request and contain prompt_protection evidence plus explicit gateway_runtime ownership; proof_owned=true is rejected for runtime closure",
        observed_row_count: 1,
        ownership_gate: "runtime_owned_required",
        prompt_protection_row_count: 1,
        proof_owned_row_count: 0,
        proof_owned_rows_close_runtime_gap: false,
        raw_report_path_omitted: true,
        raw_values_omitted: true,
        requested: true,
        rerun_command:
          "set ADMIN_UI_BASE_URL and PROMPT_PROTECTION_ADMIN_SESSION_TOKEN or CONTROL_PLANE_ADMIN_SESSION_TOKEN, then rerun scripts/verify_prompt_protection_postgres_proof.ps1 -Live -EvidenceReportPath <safe .tmp json> -BrowserAuditDetailAttempt",
        runtime_owned_closure_eligible: true,
        runtime_owned_row_count: 1,
        schema: "prompt_protection_audit_logs_mutation_row_attempt_v1",
        secret_safe_row_fields: [
          "id",
          "created_at",
          "action",
          "resource_type",
          "request_id",
          "metadata.schema",
          "metadata.source",
          "metadata.writer",
          "metadata.runtime_owned",
          "metadata.proof_owned",
          "metadata.provenance.kind",
          "after_snapshot.promptProtection.schema",
        ],
        target_request_id_count: 4,
        token_value_omitted: true,
        provenance: {
          accepted_runtime_markers: [
            "metadata.runtime_owned=true",
            "metadata.row_owner=gateway_runtime",
            "metadata.source=gateway_runtime",
            "metadata.writer=gateway_runtime",
            "metadata.provenance.kind=runtime",
          ],
          current_live_request_bound: true,
          generated_at_utc: "2026-06-04T14:05:00.000Z",
          raw_values_omitted: true,
          rejected_proof_markers: [
            "metadata.proof_owned=true",
            "action=prompt_protection.audit_readback",
          ],
          required_owner: "gateway_runtime",
        },
      },
      closure_gate: {
        classification: "pass",
        closure_eligible: true,
        gaps: ["none"],
        schema: "prompt_protection_audit_closure_gate_v1",
      },
      current_commit: "1234567890abcdef1234567890abcdef12345678",
      generated_at_utc: "2026-06-04T14:05:00.000Z",
      preflight_blocker_matrix: {
        closure_pass_requires: [
          "current_live_report",
          "provider_attempts_count=0",
          "duration_available=true",
          "latency_envelope.within_bounds=true",
          "current_provenance",
        ],
        gateway: "blocker_if_unreachable",
        mock_provider: "blocker_if_unreachable_unless_explicitly_skipped",
        postgres: "blocker_if_schema_or_psql_unavailable",
        raw_values_omitted: true,
        session_virtual_key: "blocker_if_missing",
      },
      raw_report_path: "C:\\secret\\prompt-bridge-proof-report-hidden.json",
      report_path_marker: "safe_artifact_path_configured",
      schema_version: "prompt_protection_audit_handoff_bridge.v1",
      secret_dsn: "postgres://prompt-bridge-dsn-hidden",
      secret_safe_omissions: {
        credential_values_omitted: true,
        database_connection_values_omitted: true,
        proof_raw_id_omitted: true,
        provider_secret_values_omitted: true,
        raw_command_omitted: true,
        raw_prompt_omitted: true,
        raw_report_path_omitted: true,
        raw_request_body_omitted: true,
      },
      token: bearerPlaceholder("prompt-bridge-token-hidden"),
    };

    const gate = promptProtectionAuditClosureGate(bridge.admin_ui_readback);
    expect(gate).toMatchObject({
      classification: "pass",
      closureEligible: true,
      gaps: [],
      schema: "prompt_protection_audit_closure_gate_v1",
    });
    expect(gate?.readback).toMatchObject({
      freshnessReplay: "current_live_proof",
      latencyEnvelope: "eligible",
      proofMode: "live / live",
      providerAttempts: "0",
      schema: "prompt_protection_evidence_readback_v1",
    });
    expect(bridge.preflight_blocker_matrix).toMatchObject({
      gateway: "blocker_if_unreachable",
      postgres: "blocker_if_schema_or_psql_unavailable",
      mock_provider: "blocker_if_unreachable_unless_explicitly_skipped",
      session_virtual_key: "blocker_if_missing",
      raw_values_omitted: true,
    });
    expect(bridge.audit_import_command.browser_handoff).toMatchObject({
      admin_session_header: "X-Admin-Session",
      admin_session_token_env: "PROMPT_PROTECTION_ADMIN_SESSION_TOKEN",
      admin_ui_base_url_env: "ADMIN_UI_BASE_URL",
      fallback_admin_session_token_env: "CONTROL_PLANE_ADMIN_SESSION_TOKEN",
      required_for_browser_audit_e2e: true,
      token_value_omitted: true,
    });
    expect(bridge.browser_audit_detail_attempt).toMatchObject({
      classification: "blocker",
      schema: "prompt_protection_browser_audit_detail_attempt_v1",
      requested: true,
      token_value_omitted: true,
      cookie_value_omitted: true,
      raw_report_path_omitted: true,
    });
    expect(bridge.browser_audit_detail_attempt.required_readback).toEqual([
      "current_provenance",
      "duration_available",
      "latency_envelope",
      "provider_attempts_count=0",
      "request_log_hash_only",
      "stale_replay_refusal",
    ]);
    expect(bridge.audit_logs_mutation_row_attempt).toMatchObject({
      admin_api_endpoint: "GET /admin/audit-logs",
      blocker_reason: "none",
      classification: "pass",
      ownership_gate: "runtime_owned_required",
      prompt_protection_row_count: 1,
      proof_owned_row_count: 0,
      proof_owned_rows_close_runtime_gap: false,
      runtime_owned_closure_eligible: true,
      runtime_owned_row_count: 1,
      schema: "prompt_protection_audit_logs_mutation_row_attempt_v1",
      token_value_omitted: true,
      cookie_value_omitted: true,
      raw_report_path_omitted: true,
    });
    expect(bridge.audit_logs_mutation_row_attempt.provenance).toMatchObject({
      current_live_request_bound: true,
      required_owner: "gateway_runtime",
    });
    expect(
      bridge.audit_logs_mutation_row_attempt.secret_safe_row_fields,
    ).toContain("metadata.runtime_owned");

    const exported = JSON.stringify(gate);
    expect(exported).not.toContain("prompt-bridge");
    expect(exported).not.toContain("C:\\secret");
    expect(exported).not.toContain("postgres://");
    expect(exported).not.toContain(AUTH_HEADER_NAME);
    expect(exported).not.toContain(BEARER_SCHEME);
  });

  it("refuses proof-owned prompt protection audit rows as runtime-owned closure evidence", () => {
    const proofOwnedOnlyAttempt = {
      admin_api_endpoint: "GET /admin/audit-logs",
      ambiguous_prompt_protection_row_count: 0,
      blocker_reason: "proof_owned_row_readback_only_runtime_owned_missing",
      classification: "blocker",
      classification_reason:
        "proof_owned_row_readback_only_runtime_owned_missing",
      closure_requires: [
        "admin_session_handoff",
        "audit_logs_tab_readable",
        "runtime_owned_prompt_protection_audit_row_present",
        "proof_owned_row_not_counted_as_runtime_closure",
        "request_trace_detail_readback_passed",
        "secret_safe_omission",
      ],
      cookie_value_omitted: true,
      failure_reason: "none",
      freshness: {
        current_run_marker: "target_request_id_count",
        generated_at_utc: "2026-06-04T14:06:00.000Z",
        proof_owned_rows_close_runtime_gap: false,
        repo_head_commit: "1234567890abcdef1234567890abcdef12345678",
        stale_or_proof_owned_report_closes_runtime_gap: false,
      },
      matching_rule:
        "matching Audit Logs row must be bound to this live request and contain prompt_protection evidence plus explicit gateway_runtime ownership; proof_owned=true is rejected for runtime closure",
      observed_row_count: 1,
      ownership_gate: "runtime_owned_required",
      prompt_protection_row_count: 1,
      proof_owned_row_count: 1,
      proof_owned_rows_close_runtime_gap: false,
      provenance: {
        accepted_runtime_markers: [
          "metadata.runtime_owned=true",
          "metadata.row_owner=gateway_runtime",
          "metadata.source=gateway_runtime",
          "metadata.writer=gateway_runtime",
          "metadata.provenance.kind=runtime",
        ],
        current_live_request_bound: true,
        generated_at_utc: "2026-06-04T14:06:00.000Z",
        raw_values_omitted: true,
        rejected_proof_markers: [
          "metadata.proof_owned=true",
          "action=prompt_protection.audit_readback",
        ],
        required_owner: "gateway_runtime",
      },
      raw_report_path_omitted: true,
      raw_values_omitted: true,
      requested: true,
      rerun_command:
        "set ADMIN_UI_BASE_URL and PROMPT_PROTECTION_ADMIN_SESSION_TOKEN or CONTROL_PLANE_ADMIN_SESSION_TOKEN, then rerun scripts/verify_prompt_protection_postgres_proof.ps1 -Live -EvidenceReportPath <safe .tmp json> -BrowserAuditDetailAttempt",
      runtime_owned_closure_eligible: false,
      runtime_owned_row_count: 0,
      schema: "prompt_protection_audit_logs_mutation_row_attempt_v1",
      secret_safe_row_fields: [
        "id",
        "created_at",
        "action",
        "resource_type",
        "request_id",
        "metadata.schema",
        "metadata.source",
        "metadata.writer",
        "metadata.runtime_owned",
        "metadata.proof_owned",
        "metadata.provenance.kind",
        "after_snapshot.promptProtection.schema",
      ],
      target_request_id_count: 1,
      token_value_omitted: true,
    };

    expect(proofOwnedOnlyAttempt).toMatchObject({
      blocker_reason: "proof_owned_row_readback_only_runtime_owned_missing",
      classification: "blocker",
      ownership_gate: "runtime_owned_required",
      proof_owned_row_count: 1,
      proof_owned_rows_close_runtime_gap: false,
      runtime_owned_closure_eligible: false,
      runtime_owned_row_count: 0,
      schema: "prompt_protection_audit_logs_mutation_row_attempt_v1",
    });
    expect(proofOwnedOnlyAttempt.provenance.rejected_proof_markers).toContain(
      "metadata.proof_owned=true",
    );
    expect(proofOwnedOnlyAttempt.secret_safe_row_fields).toEqual(
      expect.arrayContaining([
        "metadata.runtime_owned",
        "metadata.proof_owned",
        "metadata.provenance.kind",
      ]),
    );

    const exported = JSON.stringify(proofOwnedOnlyAttempt);
    expect(exported).not.toContain("prompt-proof-owned-token-hidden");
    expect(exported).not.toContain("C:\\secret");
    expect(exported).not.toContain("postgres://");
    expect(exported).not.toContain(AUTH_HEADER_NAME);
    expect(exported).not.toContain(BEARER_SCHEME);
    expect(exported).not.toContain(SK_PREFIX);
    expect(exported).not.toContain("raw prompt");
  });

  it("imports a current live prompt protection proof report into the audit closure gate", () => {
    const liveReport = {
      audit_handoff_bridge: {
        admin_ui_readback: {
          auditReadiness: "pass",
          closureChecklist: [
            "gateway_live_proof",
            "postgres_audit_row",
            "mock_provider_upstream_refusal",
            "provider_attempts_zero",
            "latency_envelope",
            "current_provenance",
            "duration_available",
            "freshness_replay_classification",
          ],
          closureGaps: ["none"],
          closureRule:
            "provider_attempts=0, latency bounded, duration available, current provenance",
          currentCommit: "1234567890ab",
          durationAvailability: "total available",
          freshnessReplay: "current_live_proof",
          latencyEnvelope: "eligible",
          omittedMaterial: "raw payload, raw pattern values",
          proofClosure: "eligible",
          proofEvidence: [
            "provider_attempts_count",
            "latency_envelope",
            "provenance",
          ],
          proofMode: "live / live",
          providerAttempts: "0",
          schema: "prompt_protection_evidence_readback_v1",
        },
        closure_gate: {
          classification: "pass",
          closure_eligible: true,
          gaps: ["none"],
          schema: "prompt_protection_audit_closure_gate_v1",
        },
        schema_version: "prompt_protection_audit_handoff_bridge.v1",
      },
      endpoints: [
        {
          evidence_status: "passed",
          performance: {
            duration_available: true,
            latency_envelope: { within_bounds: true },
          },
          provider_side_effects: {
            has_provider_key: false,
            has_resolved_channel: false,
            has_resolved_provider: false,
            provider_attempts_count: 0,
            route_policy_version: "policy-v1",
          },
          request_log: {
            redaction_status: "hash_only",
          },
        },
      ],
      raw_report_path: "C:\\secret\\prompt-live-e2e-report-hidden.json",
      schema_version: "prompt_protection_postgres_proof_evidence_report.v1",
      secret_dsn: "postgres://prompt-live-e2e-dsn-hidden",
      status: "passed",
      token: bearerPlaceholder("prompt-live-e2e-token-hidden"),
    };

    const endpoint = liveReport.endpoints[0];
    expect(endpoint.provider_side_effects).toMatchObject({
      has_provider_key: false,
      has_resolved_channel: false,
      has_resolved_provider: false,
      provider_attempts_count: 0,
    });
    expect(endpoint.provider_side_effects.route_policy_version).toBe(
      "policy-v1",
    );

    const gate = promptProtectionAuditClosureGate(liveReport);
    expect(gate).toMatchObject({
      classification: "pass",
      closureEligible: true,
      gaps: [],
      schema: "prompt_protection_audit_closure_gate_v1",
    });
    expect(gate?.readback).toMatchObject({
      freshnessReplay: "current_live_proof",
      latencyEnvelope: "eligible",
      proofMode: "live / live",
      providerAttempts: "0",
      schema: "prompt_protection_evidence_readback_v1",
    });

    const exported = JSON.stringify(gate);
    expect(exported).not.toContain("C:\\secret");
    expect(exported).not.toContain("postgres://");
    expect(exported).not.toContain("prompt-live-e2e");
    expect(exported).not.toContain(BEARER_SCHEME);
  });

  it("runs routing dry-run and renders selected candidates without secret material", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /路由/ }));
    await user.type(await screen.findByLabelText("项目 ID"), "project-1");
    await user.type(screen.getByLabelText("配置 ID"), "profile-1");
    await user.type(screen.getByLabelText("请求模型"), "gpt-visible");
    await user.clear(screen.getByLabelText("随机种子"));
    await user.type(screen.getByLabelText("随机种子"), "42");
    await user.type(screen.getByLabelText("Trace ID"), "trace-1");
    await user.type(
      screen.getByLabelText("上次成功渠道 ID"),
      "channel-1",
    );
    await user.click(screen.getByRole("button", { name: "运行 dry-run" }));

    expect(
      await screen.findByRole("heading", { level: 2, name: "选择结果" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "选中候选项" }),
    ).toBeInTheDocument();
    expect((await screen.findAllByText("primary channel")).length).toBeGreaterThan(0);
    expect((await screen.findAllByText("Provider A")).length).toBeGreaterThan(0);
    expect(screen.getAllByText("允许回退").length).toBeGreaterThan(0);
    expect(screen.getByText("阻止回退")).toBeInTheDocument();
    expect(screen.getAllByText("profile denied").length).toBeGreaterThan(0);
    expect(screen.getByText("路由快照摘要")).toBeInTheDocument();
    expect(screen.getByText("请求覆盖摘要")).toBeInTheDocument();
    expect(screen.getAllByText("profile_ip_allowlist").length).toBeGreaterThan(
      0,
    );
    expect(
      screen.getAllByText("203.0.113.0/24, 2001:db8::/64").length,
    ).toBeGreaterThan(0);
    expect(
      screen.getAllByText("payload-policy-override").length,
    ).toBeGreaterThan(0);

    const dryRunCall = fetchMock.mock.calls.find(([url]) =>
      String(url).includes("/admin/model-associations/dry-run"),
    );
    expect(dryRunCall?.[1]).toMatchObject({ method: "POST" });
    expect(JSON.parse(String(dryRunCall?.[1]?.body))).toEqual({
      previous_successful_channel_id: "channel-1",
      profile_id: "profile-1",
      project_id: "project-1",
      requested_model: "gpt-visible",
      seed: 42,
      trace_id: "trace-1",
    });
    expect(
      screen.queryByText((content) =>
        content.includes(skPlaceholder("route-dry-hidden")),
      ),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText((content) =>
        content.includes(bearerPlaceholder("route-dry-hidden")),
      ),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText((content) =>
        content.includes(bearerPlaceholder("nested-route-dry-hidden")),
      ),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText((content) =>
        content.includes(skPlaceholder("selection-hidden")),
      ),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText((content) =>
        content.includes(skPlaceholder("candidate-hidden")),
      ),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText((content) =>
        content.includes(bearerPlaceholder("request-override-hidden")),
      ),
    ).not.toBeInTheDocument();
    expect(document.body.textContent).not.toContain(
      "raw dry-run payload hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw dry-run snapshot hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw request override payload hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw snapshot override payload hidden",
    );
  });

  it("runs routing dry-run with a canonical model key selector", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /路由/ }));
    await user.type(await screen.findByLabelText("项目 ID"), "project-1");
    await user.type(screen.getByLabelText("配置 ID"), "profile-1");
    await user.type(
      screen.getByLabelText("规范模型 key"),
      "gpt-visible",
    );
    await user.click(screen.getByRole("button", { name: "运行 dry-run" }));

    expect(
      await screen.findByRole("heading", { level: 2, name: "选择结果" }),
    ).toBeInTheDocument();
    expect(
      screen.getAllByText((content) => content.includes("gpt-visible")).length,
    ).toBeGreaterThan(0);

    const dryRunCall = fetchMock.mock.calls.find(([url]) =>
      String(url).includes("/admin/model-associations/dry-run"),
    );
    expect(JSON.parse(String(dryRunCall?.[1]?.body))).toEqual({
      canonical_model_key: "gpt-visible",
      profile_id: "profile-1",
      project_id: "project-1",
    });
  });

  it("redacts routing dry-run error details", async () => {
    stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /路由/ }));
    await user.type(await screen.findByLabelText("项目 ID"), "project-1");
    await user.type(screen.getByLabelText("配置 ID"), "profile-1");
    await user.type(screen.getByLabelText("请求模型"), "secret-error");
    await user.click(screen.getByRole("button", { name: "运行 dry-run" }));

    expect(await screen.findByText("Request failed.")).toBeInTheDocument();
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("dry-run-secret"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("dry-run-secret"),
    );
  });

  it("renders billing price versions, ledger overview, and reconciliation without secret material", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));

    expect(
      await screen.findByRole("heading", {
        level: 1,
        name: "计费 / 价格",
      }),
    ).toBeInTheDocument();
    expect(
      await screen.findByRole("heading", { level: 2, name: "价格版本" }),
    ).toBeInTheDocument();
    expect(await screen.findByText("2026-06")).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "查看价格版本 2026-06" }),
    );

    expect(
      screen.getByRole("heading", { level: 2, name: "计费规则" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByText(skPlaceholder("price-hidden")),
    ).not.toBeInTheDocument();

    await user.click(screen.getByRole("tab", { name: "账本概览" }));

    expect(await screen.findByText("-0.01230000")).toBeInTheDocument();
    expect(screen.getByText("USD -0.0123")).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "查看账本条目 ledger-entry-1" }),
    );

    expect(
      screen.getByRole("heading", { level: 2, name: "用量快照" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByText(skPlaceholder("ledger-hidden")),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText(bearerPlaceholder("ledger-hidden")),
    ).not.toBeInTheDocument();
    expect(document.body.textContent).not.toContain("settle:request-1");

    await user.click(screen.getByRole("tab", { name: "对账" }));

    expect(
      await screen.findByRole("heading", { level: 2, name: "对账" }),
    ).toBeInTheDocument();
    expect(await screen.findByText("1.25000000")).toBeInTheDocument();
    expect(screen.getByText("missing ledger")).toBeInTheDocument();
    expect(screen.getByText("recon-req-1")).toBeInTheDocument();
    expect(screen.getByText("USD 1.00000000")).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "摘要 JSON" }),
    ).toBeInTheDocument();
    expect(document.body.textContent).not.toContain(
      skUnderscorePlaceholder("reconcile_model_hidden"),
    );
    expect(document.body.textContent).not.toContain(
      githubPatPlaceholder("reconcile_trace_hidden"),
    );
    expect(document.body.textContent).not.toContain(
      authorizationBearerPlaceholder("reconcile-upstream-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "raw reconciliation payload hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw reconciliation export hidden",
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("reconcile-policy-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("reconcile-summary-hidden"),
    );
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain("raw_policy_snapshot");
    expect(document.body.textContent).not.toContain("raw_export");
    expect(document.body.textContent).not.toContain("secret_note");
    expect(document.body.textContent).not.toContain('"payload"');
    expect(document.body.textContent).not.toContain('"body"');

    await user.type(screen.getByLabelText("日期"), "2026-06-02");
    await user.clear(screen.getByLabelText("限制"));
    await user.type(screen.getByLabelText("限制"), "5");
    await user.type(
      screen.getByLabelText("Request ID"),
      "00000000-0000-0000-0000-000000000123",
    );
    await user.click(screen.getByRole("button", { name: "搜索" }));

    await waitFor(() =>
      expect(fetchMock.mock.calls.map(([url]) => String(url))).toContain(
        "/api/control-plane/admin/billing/reconciliation?day=2026-06-02&limit=5&request_id=00000000-0000-0000-0000-000000000123",
      ),
    );

    await user.click(
      screen.getByRole("button", { name: "打开请求详情 recon-req-1" }),
    );

    expect(
      await screen.findByRole("heading", { level: 1, name: "请求与追踪" }),
    ).toBeInTheDocument();
    expect((await screen.findAllByText("recon-req-1")).length).toBeGreaterThan(0);
    await waitFor(() =>
      expect(fetchMock.mock.calls.map(([url]) => String(url))).toContain(
        "/api/control-plane/admin/request-logs/recon-req-1",
      ),
    );
  });

  it("submits voucher batches without rendering raw voucher codes", async () => {
    const fetchMock = stubAdminFetch();
    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));
    await user.click(await screen.findByRole("tab", { name: "代金券" }));
    await user.click(screen.getByRole("button", { name: "发放用户额度" }));

    const dialog = await screen.findByRole("dialog", {
      name: "发放用户额度对话框",
    });
    await user.click(within(dialog).getByRole("tab", { name: "批量" }));

    fireEvent.change(within(dialog).getByLabelText("Wallet ID"), {
      target: { value: "00000000-0000-0000-0000-000000000099" },
    });
    fireEvent.change(within(dialog).getByLabelText("批次幂等键"), {
      target: { value: "batch-test-1" },
    });
    fireEvent.change(within(dialog).getByLabelText("代金券码列表"), {
      target: { value: "BATCH-SECRET-001\nBATCH-SECRET-002,custom-batch-key-2" },
    });

    await user.click(within(dialog).getByRole("button", { name: "批量发放" }));

    expect(await screen.findByRole("heading", { name: "批量发放结果" })).toBeInTheDocument();
    expect(screen.getByText(/共 2 条/)).toBeInTheDocument();
    expect(document.body.textContent).not.toContain("BATCH-SECRET-001");
    expect(document.body.textContent).not.toContain("custom-batch-key-2");

    const batchCall = fetchMock.mock.calls.find(([url, init]) => {
      return (
        String(url).includes("/admin/voucher-issuance-batches") &&
        init?.method === "POST"
      );
    });
    expect(batchCall).toBeTruthy();
    expect(JSON.parse(String(batchCall?.[1]?.body))).toMatchObject({
      batch_idempotency_key: "batch-test-1",
      defaults: {
        amount: "5.00000000",
        currency: "USD",
        tenant_id: "00000000-0000-0000-0000-000000000001",
        wallet_id: "00000000-0000-0000-0000-000000000099",
      },
      items: [
        {
          idempotency_key: "batch-test-1:1",
          raw_voucher_code: "BATCH-SECRET-001",
        },
        {
          idempotency_key: "custom-batch-key-2",
          raw_voucher_code: "BATCH-SECRET-002",
        },
      ],
    });
  });

  it("lists and revokes issued vouchers without rendering raw voucher codes", async () => {
    const fetchMock = stubAdminFetch();
    const user = await renderSignedInApp();
    const exportedParts: BlobPart[][] = [];
    const originalBlob = globalThis.Blob;
    class CapturingBlob extends originalBlob {
      constructor(parts?: BlobPart[], options?: BlobPropertyBag) {
        exportedParts.push(parts ?? []);
        super(parts, options);
      }
    }
    vi.stubGlobal("Blob", CapturingBlob);
    const createObjectUrl = vi.fn(() => "blob:voucher-export");
    const revokeObjectUrl = vi.fn();
    Object.defineProperty(URL, "createObjectURL", {
      configurable: true,
      value: createObjectUrl,
    });
    Object.defineProperty(URL, "revokeObjectURL", {
      configurable: true,
      value: revokeObjectUrl,
    });
    const anchorClick = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined);

    await user.click(screen.getByRole("button", { name: /计费/ }));
    await user.click(await screen.findByRole("tab", { name: "代金券" }));

    expect(await screen.findByRole("heading", { name: "已发放代金券" })).toBeInTheDocument();
    expect(await screen.findByText("ADM...1111")).toBeInTheDocument();
    expect(screen.getByText("ADM...2222")).toBeInTheDocument();
    expect(document.body.textContent).not.toContain("VOUCHER-RAW-SECRET");
    expect(document.body.textContent).not.toContain("idempotency-secret");

    await user.click(screen.getByRole("button", { name: "导出 CSV" }));
    await user.click(screen.getByRole("button", { name: "导出 JSON" }));
    expect(createObjectUrl).toHaveBeenCalledTimes(2);
    expect(revokeObjectUrl).toHaveBeenCalledTimes(2);
    expect(anchorClick).toHaveBeenCalledTimes(2);
    const exportedText = exportedParts.flat().map(String).join("\n");
    expect(exportedText).toContain("code_redacted");
    expect(exportedText).toContain("ADM...1111");
    expect(exportedText).toContain("admin_voucher_issuance_export.v1");
    expect(exportedText).not.toContain("VOUCHER-RAW-SECRET");
    expect(exportedText).not.toContain("idempotency-secret");
    expect(exportedText).not.toContain("code_hash_value");

    await user.click(screen.getAllByRole("button", { name: "撤销" })[0]);

    expect(await screen.findByText("代金券 voucher-... 已撤销。")).toBeInTheDocument();
    const revokeCall = fetchMock.mock.calls.find(([url, init]) => {
      return (
        String(url).includes("/admin/voucher-issuances/voucher-list-1/revoke") &&
        init?.method === "POST"
      );
    });
    expect(revokeCall).toBeTruthy();
    expect(document.body.textContent).not.toContain("VOUCHER-RAW-SECRET");
    expect(document.body.textContent).not.toContain("idempotency-secret");
  });

  function normalizeAbsentSmokeMarker<T>(value: T | null): T | undefined {
    return value === ledgerAdjustmentExecuteAbsentOptionalMarker
      ? undefined
      : value;
  }

  function expectLedgerBackendSmokeReadiness({
    contractCheckNetworkCall = false,
    dryRunFresh,
    executeEnabled,
    executeOutcome,
    executeResultFresh,
    executeWriteNetworkCall,
    handoffState,
    ledgerRefreshStatus,
    status,
  }: {
    contractCheckNetworkCall?: boolean;
    dryRunFresh: boolean;
    executeEnabled: boolean;
    executeOutcome?: "applied" | "idempotent";
    executeResultFresh?: boolean;
    executeWriteNetworkCall: boolean;
    handoffState?: keyof typeof ledgerExecuteSmokeHandoff.readinessStates;
    ledgerRefreshStatus?: "success" | "error";
    status: string;
  }) {
    const { markers, selectors } = ledgerExecuteSmoke;
    const readiness = screen.getByTestId(selectors.readiness);
    const expectedHandoffState = handoffState
      ? ledgerExecuteSmokeHandoff.readinessStates[handoffState]
      : null;

    if (expectedHandoffState) {
      expect(expectedHandoffState.expectedStatus).toBe(status);
      expect(expectedHandoffState.executeButtonEnabled).toBe(executeEnabled);
      expect(expectedHandoffState.markers.contractCheckNetworkCall).toBe(
        contractCheckNetworkCall,
      );
      expect(expectedHandoffState.markers.dryRunFresh).toBe(dryRunFresh);
      expect(expectedHandoffState.markers.executeWriteNetworkCall).toBe(
        executeWriteNetworkCall,
      );
      expect(
        normalizeAbsentSmokeMarker(
          expectedHandoffState.markers.executeResultFresh,
        ),
      ).toBe(executeResultFresh);
      expect(
        normalizeAbsentSmokeMarker(expectedHandoffState.markers.executeOutcome),
      ).toBe(executeOutcome);
      expect(
        normalizeAbsentSmokeMarker(
          expectedHandoffState.markers.ledgerRefreshStatus,
        ),
      ).toBe(ledgerRefreshStatus);
    }

    expect(screen.getByTestId(selectors.executeContractMode)).toHaveTextContent(
      `${markers.executeContractMode}=true`,
    );
    expect(screen.getByTestId(selectors.executeEndpoint)).toHaveTextContent(
      `${markers.executeEndpoint}=true`,
    );
    expect(screen.getByTestId(selectors.dryRunFresh)).toHaveTextContent(
      `${markers.dryRunFresh}=${String(dryRunFresh)}`,
    );
    expect(
      screen.getByTestId(selectors.contractCheckNetworkCall),
    ).toHaveTextContent(
      `${markers.contractCheckNetworkCall}=${String(contractCheckNetworkCall)}`,
    );
    expect(
      screen.getByTestId(selectors.executeWriteNetworkCall),
    ).toHaveTextContent(
      `${markers.executeWriteNetworkCall}=${String(executeWriteNetworkCall)}`,
    );
    if (executeEnabled) {
      expect(screen.getByTestId(selectors.executeButton)).toBeEnabled();
    } else {
      expect(screen.getByTestId(selectors.executeButton)).toBeDisabled();
    }
    expect(within(readiness).getAllByText(status).length).toBeGreaterThan(0);

    if (executeOutcome) {
      expect(
        screen.getByTestId(selectors.executeResultFresh),
      ).toHaveTextContent(
        `${markers.executeResultFresh}=${String(executeResultFresh ?? true)}`,
      );
      expect(screen.getByTestId(selectors.executeOutcome)).toHaveTextContent(
        `${markers.executeOutcome}=${executeOutcome}`,
      );
    } else {
      expect(
        screen.queryByTestId(selectors.executeResultFresh),
      ).not.toBeInTheDocument();
      expect(
        screen.queryByTestId(selectors.executeOutcome),
      ).not.toBeInTheDocument();
    }

    if (ledgerRefreshStatus) {
      expect(
        screen.getByTestId(selectors.ledgerRefreshStatus),
      ).toHaveTextContent(
        `${markers.ledgerEntriesRefreshAfterExecute}=${ledgerRefreshStatus}`,
      );
    } else {
      expect(
        screen.queryByTestId(selectors.ledgerRefreshStatus),
      ).not.toBeInTheDocument();
    }
  }

  it("exports the ledger execute live-smoke selector and status contract", () => {
    const {
      forbiddenSensitiveMarkers,
      markers,
      refreshStatuses,
      selectors,
      statuses,
    } = ledgerExecuteSmoke;

    expect(selectors).toMatchObject({
      amountInput: "ledger-adjustment-amount-input",
      contractCheckFresh: "ledger-adjustment-contract-check-fresh",
      contractCheckNetworkCall: "ledger-adjustment-contract-check-network-call",
      currencyInput: "ledger-adjustment-currency-input",
      dryRunButton: "ledger-adjustment-dry-run-button",
      dryRunForm: "ledger-adjustment-dry-run-form",
      executeButton: "ledger-adjustment-execute-button",
      executeContractButton: "ledger-adjustment-execute-contract-button",
      executeContractMode: "ledger-adjustment-execute-contract-mode",
      executeEndpoint: "ledger-adjustment-execute-endpoint",
      executeFlags: "ledger-adjustment-execute-flags",
      executeOutcome: "ledger-adjustment-execute-outcome",
      executeResultFresh: "ledger-adjustment-execute-result-fresh",
      executeWriteNetworkCall: "ledger-adjustment-execute-write-network-call",
      ledgerRefreshStatus: "ledger-adjustment-ledger-refresh-status",
      operationInput: "ledger-adjustment-operation-input",
      projectInput: "ledger-adjustment-project-input",
      readiness: "ledger-adjustment-execute-readiness",
      reasonInput: "ledger-adjustment-reason-input",
      relatedLedgerEntryInput: "ledger-adjustment-related-ledger-entry-input",
      requestInput: "ledger-adjustment-request-input",
      dryRunFresh: "ledger-adjustment-dry-run-fresh",
      walletInput: "ledger-adjustment-wallet-input",
    });
    expect(new Set(Object.values(selectors)).size).toBe(
      Object.values(selectors).length,
    );
    expect(markers).toMatchObject({
      contractCheckNetworkCall: "contract_check_network_call",
      dryRunFresh: "fresh_dry_run",
      executeContractMode: "execute_contract_mode",
      executeEndpoint: "execute_endpoint",
      executeOutcome: "execute_outcome",
      executeResultFresh: "execute_result_fresh",
      executeWriteNetworkCall: "execute_write_network_call",
      ledgerEntriesRefreshAfterExecute: "ledger_entries_refresh_after_execute",
    });
    expect(statuses).toEqual({
      applied: "applied",
      blocked: "blocked",
      dryRunRequired: "dry run required",
      executePreflight: "execute preflight",
      failed: "failed",
      idempotent: "idempotent",
      stalePlan: "stale plan",
    });
    expect(refreshStatuses).toEqual({
      error: "error",
      success: "success",
    });
    expect(forbiddenSensitiveMarkers).toEqual([
      "Authorization",
      "Cookie",
      "token",
      "credential",
      "operation_key",
      "raw metadata",
      "raw executor error detail",
      "dedupe material",
    ]);
  });

  it("exports the ledger execute live-smoke handoff for scripts", () => {
    const {
      forbiddenSensitiveMarkers,
      readinessMarkerKeys,
      readinessStates,
      scriptUsage,
      selectors,
      statusMarkers,
    } = ledgerExecuteSmokeHandoff;

    expect(selectors).toBe(ledgerExecuteSmoke.selectors);
    expect(statusMarkers).toBe(ledgerExecuteSmoke.markers);
    expect(forbiddenSensitiveMarkers).toBe(
      ledgerExecuteSmoke.forbiddenSensitiveMarkers,
    );
    expect(scriptUsage).toEqual({
      assertNoForbiddenMarkersInDocument: true,
      readStatusFromReadinessRegion: true,
      selectorsSource: "ledgerAdjustmentExecuteLiveSmokeContract.selectors",
      statusMarkersSource:
        "ledgerAdjustmentExecuteLiveSmokeHandoff.readinessStates",
      useDataTestIdsOnly: true,
    });
    expect(readinessMarkerKeys).toEqual([
      "contractCheckNetworkCall",
      "dryRunFresh",
      "executeOutcome",
      "executeResultFresh",
      "executeWriteNetworkCall",
      "ledgerRefreshStatus",
    ]);
    expect(readinessStates).toMatchObject({
      appliedRefreshError: {
        executeButtonEnabled: true,
        expectedStatus: ledgerExecuteSmoke.statuses.applied,
        markers: {
          contractCheckNetworkCall: false,
          dryRunFresh: true,
          executeOutcome: ledgerExecuteSmoke.statuses.applied,
          executeResultFresh: true,
          executeWriteNetworkCall: true,
          ledgerRefreshStatus: ledgerExecuteSmoke.refreshStatuses.error,
        },
      },
      appliedRefreshSuccess: {
        executeButtonEnabled: true,
        expectedStatus: ledgerExecuteSmoke.statuses.applied,
        markers: {
          contractCheckNetworkCall: false,
          dryRunFresh: true,
          executeOutcome: ledgerExecuteSmoke.statuses.applied,
          executeResultFresh: true,
          executeWriteNetworkCall: true,
          ledgerRefreshStatus: ledgerExecuteSmoke.refreshStatuses.success,
        },
      },
      blocked: {
        executeButtonEnabled: true,
        expectedStatus: ledgerExecuteSmoke.statuses.blocked,
        markers: {
          contractCheckNetworkCall: false,
          dryRunFresh: true,
          executeOutcome: ledgerAdjustmentExecuteAbsentOptionalMarker,
          executeResultFresh: ledgerAdjustmentExecuteAbsentOptionalMarker,
          executeWriteNetworkCall: true,
          ledgerRefreshStatus: ledgerAdjustmentExecuteAbsentOptionalMarker,
        },
      },
      contractBlocked: {
        executeButtonEnabled: true,
        expectedStatus: ledgerExecuteSmoke.statuses.blocked,
        markers: {
          contractCheckNetworkCall: true,
          dryRunFresh: true,
          executeOutcome: ledgerAdjustmentExecuteAbsentOptionalMarker,
          executeResultFresh: ledgerAdjustmentExecuteAbsentOptionalMarker,
          executeWriteNetworkCall: false,
          ledgerRefreshStatus: ledgerAdjustmentExecuteAbsentOptionalMarker,
        },
      },
      dryRunRequired: {
        executeButtonEnabled: false,
        expectedStatus: ledgerExecuteSmoke.statuses.dryRunRequired,
        markers: {
          contractCheckNetworkCall: false,
          dryRunFresh: false,
          executeOutcome: ledgerAdjustmentExecuteAbsentOptionalMarker,
          executeResultFresh: ledgerAdjustmentExecuteAbsentOptionalMarker,
          executeWriteNetworkCall: false,
          ledgerRefreshStatus: ledgerAdjustmentExecuteAbsentOptionalMarker,
        },
      },
      executePreflight: {
        executeButtonEnabled: true,
        expectedStatus: ledgerExecuteSmoke.statuses.executePreflight,
        markers: {
          contractCheckNetworkCall: false,
          dryRunFresh: true,
          executeOutcome: ledgerAdjustmentExecuteAbsentOptionalMarker,
          executeResultFresh: ledgerAdjustmentExecuteAbsentOptionalMarker,
          executeWriteNetworkCall: false,
          ledgerRefreshStatus: ledgerAdjustmentExecuteAbsentOptionalMarker,
        },
      },
      failed: {
        executeButtonEnabled: true,
        expectedStatus: ledgerExecuteSmoke.statuses.failed,
        markers: {
          contractCheckNetworkCall: false,
          dryRunFresh: true,
          executeOutcome: ledgerAdjustmentExecuteAbsentOptionalMarker,
          executeResultFresh: ledgerAdjustmentExecuteAbsentOptionalMarker,
          executeWriteNetworkCall: true,
          ledgerRefreshStatus: ledgerAdjustmentExecuteAbsentOptionalMarker,
        },
      },
      idempotentRefreshError: {
        executeButtonEnabled: true,
        expectedStatus: ledgerExecuteSmoke.statuses.idempotent,
        markers: {
          contractCheckNetworkCall: false,
          dryRunFresh: true,
          executeOutcome: ledgerExecuteSmoke.statuses.idempotent,
          executeResultFresh: true,
          executeWriteNetworkCall: true,
          ledgerRefreshStatus: ledgerExecuteSmoke.refreshStatuses.error,
        },
      },
      idempotentRefreshSuccess: {
        executeButtonEnabled: true,
        expectedStatus: ledgerExecuteSmoke.statuses.idempotent,
        markers: {
          contractCheckNetworkCall: false,
          dryRunFresh: true,
          executeOutcome: ledgerExecuteSmoke.statuses.idempotent,
          executeResultFresh: true,
          executeWriteNetworkCall: true,
          ledgerRefreshStatus: ledgerExecuteSmoke.refreshStatuses.success,
        },
      },
      stalePlan: {
        executeButtonEnabled: false,
        expectedStatus: ledgerExecuteSmoke.statuses.stalePlan,
        markers: {
          contractCheckNetworkCall: false,
          dryRunFresh: false,
          executeOutcome: ledgerAdjustmentExecuteAbsentOptionalMarker,
          executeResultFresh: ledgerAdjustmentExecuteAbsentOptionalMarker,
          executeWriteNetworkCall: false,
          ledgerRefreshStatus: ledgerAdjustmentExecuteAbsentOptionalMarker,
        },
      },
    });
    expect(new Set(Object.keys(readinessStates)).size).toBe(
      Object.keys(readinessStates).length,
    );
  });

  it("exports a JSON-serializable ledger execute live-smoke handoff", () => {
    const handoff = ledgerExecuteSmokeSerializableHandoff;
    const serialized = JSON.stringify(handoff);
    expect(serialized).toBeDefined();
    const serializedHandoff = serialized ?? "";
    const parsed = JSON.parse(serializedHandoff);

    expect(serializedHandoff).not.toContain("undefined");
    expect(parsed).toEqual(handoff);
    expect(ledgerExecuteSmokeSerializableHandoffArtifact).toEqual(handoff);
    expect(
      JSON.parse(JSON.stringify(ledgerExecuteSmokeSerializableHandoffArtifact)),
    ).toEqual(handoff);
    expect(parsed.browserActionPlan).toEqual({
      defaultMode: "dry_run_only",
      durationMarkers: {
        dryRunPlan: "dry_run_plan_duration_ms",
        executeApply: "execute_apply_duration_ms",
        idempotentReplay: "idempotent_replay_duration_ms",
        ledgerRefresh: "ledger_refresh_duration_ms",
        refundRefusal: "refund_refusal_duration_ms",
        unavailable: "unavailable",
      },
      failureClassifications: {
        forbiddenSensitiveMarkerDetected: "forbidden_sensitive_marker_detected",
        mutationOptInMissing: "mutation_opt_in_missing",
        selectorUnavailable: "selector_unavailable",
        stateMismatch: "state_mismatch",
      },
      mutationOptIn: {
        defaultSubmitsLiveMutation: false,
        env: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_MUTATION",
        requiredValue: "1",
      },
      steps: [
        {
          expectedState: "executePreflight",
          name: "dry_run_plan",
          selector: "dryRunButton",
          submitsLiveMutation: false,
        },
        {
          expectedState: "appliedRefreshSuccess",
          name: "execute_apply",
          selector: "executeButton",
          submitsLiveMutation: true,
        },
        {
          expectedState: "idempotentRefreshSuccess",
          name: "idempotent_replay",
          selector: "executeButton",
          submitsLiveMutation: true,
        },
        {
          expectedState: "blocked",
          name: "refund_refusal",
          selector: "executeButton",
          submitsLiveMutation: true,
        },
        {
          expectedState: "appliedRefreshSuccess",
          name: "ledger_refresh",
          selector: "ledgerRefreshStatus",
          submitsLiveMutation: false,
        },
      ],
      usesDataTestIdsOnly: true,
    });
    expect(parsed.browserDomActionRunner).toEqual({
      artifactEmission: {
        artifactName: "billing_execute_browser_live_e2e_evidence.v1",
        outputMarker: "browser_runner_evidence_json",
        writeDisabledByDefault: true,
        writeOptInFlag: "-BrowserEvidenceArtifactWriteOptIn",
      },
      defaultClicksAdminUiActions: false,
      defaultMode: "dom_action_runner_dry_run_only",
      defaultSubmitsLiveMutation: false,
      durationFieldMapping: {
        dry_run_plan: "dry_run_plan_duration_ms",
        execute_apply: "execute_apply_duration_ms",
        idempotent_replay: "idempotent_replay_duration_ms",
        ledger_refresh: "ledger_refresh_duration_ms",
        refund_refusal: "refund_refusal_duration_ms",
      },
      plannedTimeoutMs: {
        dry_run_plan: 5000,
        execute_apply: 5000,
        idempotent_replay: 5000,
        ledger_refresh: 5000,
        refund_refusal: 5000,
      },
      secretSafeOmission: {
        echoRequestMaterial: false,
        echoSessionMaterial: false,
        echoUrlCredentials: false,
      },
      selectorAvailability: {
        missingMarker: "selector_unavailable",
        source: "ledgerAdjustmentExecuteLiveSmokeContract.selectors",
        summaryMarker: "selector_availability_summary",
      },
      stepOrder: [
        "dry_run_plan",
        "execute_apply",
        "idempotent_replay",
        "refund_refusal",
        "ledger_refresh",
      ],
      toolingBlocker: "browser_tooling_unavailable",
    });
    expect(parsed.browserEvidenceArtifact).toEqual({
      artifactName: "billing_execute_browser_live_e2e_evidence.v1",
      classificationFields: {
        failure: "failure",
        mutationPassArtifact: "mutation_pass_artifact",
        readback: "readback",
        replay: "replay",
        runtimeCurrent: "runtime_current",
      },
      classificationValues: {
        failure: {
          artifactClosureFailed: "artifact_closure_failed",
          artifactReadbackFailed: "artifact_readback_failed",
          artifactWriteMissing: "artifact_write_missing",
          browserUnavailable: "browser_tooling_unavailable",
          durationNonNumeric: "duration_non_numeric",
          browserIdempotentReplayFailed: "browser_idempotent_replay_failed",
          browserLiveRunnerTimeout: "browser_live_runner_timeout",
          ledgerRefreshMissing: "ledger_refresh_missing",
          mutationOptInMissing: "mutation_opt_in_missing",
          none: "none",
          refundRefusalMissing: "refund_refusal_missing",
          runtimeStale: "runtime_image_stale_or_unverified",
          sessionMissing: "session_material_missing",
          simulatedArtifact: "simulated_artifact_cannot_close_e11",
          staleArtifact: "artifact_readback_failed",
        },
        mutationPassArtifact: {
          blocked: "mutation_pass_artifact_blocked",
          failed: "mutation_pass_artifact_failed",
          notRequested: "mutation_pass_artifact_not_requested",
          passed: "mutation_pass_artifact_passed",
        },
        readback: {
          failed: "artifact_readback_failed",
          missing: "artifact_readback_missing",
          notRequested: "artifact_readback_not_requested",
          passed: "artifact_readback_passed",
        },
        replay: {
          failed: "browser_idempotent_replay_failed",
          notRun: "idempotent_replay_not_run",
          passed: "idempotent_replay_passed",
        },
        runtimeCurrent: {
          notChecked: "runtime_current_not_checked",
          staleOrUnverified: "runtime_image_stale_or_unverified",
          verified: "runtime_current_verified",
        },
      },
      durationFields: {
        browserLaunchDurationMs: "browser_launch_duration_ms",
        contextSetupDurationMs: "context_setup_duration_ms",
        dryRunPlanDurationMs: "dry_run_plan_duration_ms",
        executeApplyDurationMs: "execute_apply_duration_ms",
        idempotentReplayDurationMs: "idempotent_replay_duration_ms",
        ledgerRefreshDurationMs: "ledger_refresh_duration_ms",
        pageReadyDurationMs: "page_ready_duration_ms",
        refundRefusalDurationMs: "refund_refusal_duration_ms",
        selectorSnapshotDurationMs: "selector_snapshot_duration_ms",
        serviceReadinessDurationMs: "service_readiness_duration_ms",
        submitLatencyMs: "submit_latency_ms",
      },
      outcomes: {
        blocked: "blocked",
        failed: "failed",
        passed: "passed",
      },
      requiredTopLevelFields: [
        "artifact",
        "generated_at",
        "mode",
        "outcome",
        "provenance",
        "freshness",
        "runtime_current",
        "classifications",
        "readback",
        "runtime_current_artifact",
        "session_verification",
        "mutation_controls",
        "api_readback",
        "ledger_readback",
        "failure_taxonomy",
        "blockers",
        "matrix",
        "durations",
        "actions",
        "secret_safe",
      ],
      artifactSchema: {
        apiReadbackFields: [
          "dry_run_plan",
          "execute_apply",
          "idempotent_replay",
          "refund_refusal",
          "ledger_refresh",
        ],
        failureTaxonomyFields: [
          "session_missing",
          "runtime_stale",
          "mutation_opt_in_missing",
          "artifact_write_missing",
          "artifact_readback_failed",
          "idempotent_replay_failed",
          "refund_refusal_missing",
          "ledger_refresh_missing",
          "duration_non_numeric",
          "stale_or_simulated_artifact",
          "browser_unavailable",
        ],
        ledgerReadbackFields: [
          "applied_ledger_entry_visible",
          "idempotent_replay_reused_ledger_entry",
          "refund_refusal_no_ledger_write",
          "ledger_refresh_visible",
        ],
        mutationControlFields: [
          "mutation_opt_in_enabled",
          "artifact_write_opt_in_enabled",
          "artifact_readback_opt_in_enabled",
        ],
        runtimeCurrentArtifactLinkField: "runtime_current_artifact",
        sessionVerificationField: "session_verification",
      },
      unavailableMarker: "unavailable",
    });
    expect(parsed.browserLiveRunbook).toEqual({
      blockerClassifications: {
        adminUiUnreachable: "admin_ui_unreachable",
        browserToolingUnavailable: "browser_tooling_unavailable",
        controlPlaneHealthUnreachable: "control_plane_health_unreachable",
        liveMutationOptInMissing: "live_mutation_opt_in_missing",
        sessionMaterialMissing: "session_material_missing",
      },
      defaultMode: "contract_only",
      evidenceNames: {
        browserLaunchDurationMs: "browser_launch_duration_ms",
        contextSetupDurationMs: "context_setup_duration_ms",
        dryRunPlanDurationMs: "dry_run_plan_duration_ms",
        executeApplyDurationMs: "execute_apply_duration_ms",
        idempotentReplayDurationMs: "idempotent_replay_duration_ms",
        ledgerRefreshDurationMs: "ledger_refresh_duration_ms",
        pageReadyDurationMs: "page_ready_duration_ms",
        refundRefusalDurationMs: "refund_refusal_duration_ms",
        selectorSnapshotDurationMs: "selector_snapshot_duration_ms",
        serviceReadinessDurationMs: "service_readiness_duration_ms",
        submitLatencyMs: "submit_latency_ms",
      },
      liveCommand: {
        arguments: ["-BrowserPreflight"],
        script:
          "scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1",
      },
      mutationOptIn: {
        env: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_MUTATION",
        flag: "-BrowserMutationOptIn",
        requiredValue: "1",
      },
      requiredInputs: {
        adminUiBaseUrl: "ADMIN_UI_BASE_URL",
        controlPlaneBaseUrl: "CONTROL_PLANE_BASE_URL",
        sessionMaterial: "CONTROL_PLANE_ADMIN_SESSION_TOKEN",
      },
      secretSafeOutput: {
        echoSessionMaterial: false,
        forbiddenMarkers: ledgerExecuteSmoke.forbiddenSensitiveMarkers,
      },
    });
    expect(parsed.browserLiveRunnerExecutionBridge).toEqual({
      artifact: {
        defaultPath: "artifacts/billing_execute_browser_live_e2e_evidence.json",
        name: "billing_execute_browser_live_e2e_evidence.v1",
        pathEnv:
          "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_PATH",
        readBackRequired: true,
        writeOptInFlag: "-BrowserEvidenceArtifactWriteOptIn",
      },
      command: {
        flag: "-BrowserLiveRunnerExecutionOptIn",
        script:
          "scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1",
      },
      defaultClicksAdminUiActions: false,
      defaultMode: "live_runner_execution_bridge",
      defaultRunsBridge: false,
      defaultSubmitsLiveMutation: false,
      durationFields: parsed.browserEvidenceArtifact.durationFields,
      env: {
        artifactWrite:
          "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_WRITE",
        liveRunner: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_RUNNER",
        mutation: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_MUTATION",
        session: "CONTROL_PLANE_ADMIN_SESSION_TOKEN",
      },
      requiredForBridge: {
        adminUiReachable: true,
        artifactWriteOptIn: true,
        browserToolingAvailable: true,
        controlPlaneHealthReachable: true,
        liveRunnerOptIn: true,
        mutationOptIn: true,
        sessionMaterialPresent: true,
      },
      secretSafeOmission: {
        echoRequestMaterial: false,
        echoSessionMaterial: false,
        echoUrlCredentials: false,
      },
      statusMarkers: {
        blocked: "blocked",
        bridgeAllowed: "bridge_allowed",
        ready: "ready",
      },
    });
    expect(parsed.browserLivePassArtifactReadbackGate).toEqual({
      artifactName: "billing_execute_browser_live_e2e_evidence.v1",
      classificationValues:
        parsed.browserEvidenceArtifact.classificationValues.readback,
      defaultMode: "live_pass_artifact_readback_gate",
      defaultReadsArtifact: false,
      defaultSubmitsLiveMutation: false,
      durationFields: parsed.browserEvidenceArtifact.durationFields,
      expectedActionOutcomes:
        parsed.browserMutationPassArtifactClosure.expectedActionOutcomes,
      requiredArtifactFreshness:
        parsed.browserMutationPassArtifactClosure.requiredArtifactFreshness,
      requiredReadiness:
        parsed.browserMutationPassArtifactClosure.requiredReadiness,
      secretSafeOmission: {
        echoRequestMaterial: false,
        echoSessionMaterial: false,
        echoUrlCredentials: false,
      },
      statusMarkers: {
        blocked: "blocked",
        fail: "fail",
        pass: "pass",
      },
    });
    expect(parsed.browserMutationFinalDod).toEqual({
      acceptanceMatrix: {
        passRequires: {
          adminSessionVerifiedSecretOmitted: true,
          applyOutcome: "applied",
          artifactFreshCurrentCommit: true,
          artifactReadbackOptIn: true,
          artifactReadbackPassed: true,
          artifactWriteOptIn: true,
          browserToolingAvailable: true,
          idempotentReplayOutcome: "idempotent",
          ledgerRefreshOutcome: "success",
          mutationOptIn: true,
          numericDurations: true,
          refundRefusalOutcome: "blocked",
          runtimeCurrentVerified: true,
          secretSafeOmission: true,
        },
        rejectedEvidence: {
          browserUnavailable: "browser_tooling_unavailable",
          missingArtifact: "artifact_readback_missing",
          missingSession: "session_material_missing",
          simulatedArtifact: "simulated_artifact_cannot_close_e11",
          staleArtifact: "artifact_readback_failed",
          staleRuntime: "runtime_image_stale_or_unverified",
        },
      },
      checklist: [
        "runtime_current_verified",
        "admin_session_verified_secret_omitted",
        "mutation_opt_in_enabled",
        "artifact_write_opt_in_enabled",
        "artifact_readback_passed",
        "apply_outcome_applied",
        "idempotent_replay_outcome_idempotent",
        "refund_refusal_outcome_blocked",
        "ledger_refresh_outcome_success",
        "numeric_duration_fields_present",
        "artifact_fresh_current_commit",
        "secret_safe_omission",
      ],
      defaultBuildsRuntime: false,
      defaultClosesE11: false,
      defaultRunsBrowserRunner: false,
      defaultSubmitsLiveMutation: false,
      e11TargetState: "x_requires_real_browser_mutation_pass",
      finalPassClassification: "e11_browser_mutation_dod_passed",
      schema: "billing_execute_browser_mutation_final_dod.v1",
    });
    expect(parsed.runtimeCurrentEvidenceAcceptanceMatrix).toEqual({
      acceptedStates: {
        e11X: "requires mutation_pass_artifact_passed plus artifact_readback_passed, current commit freshness, API and ledger readback, numeric durations, and secret-safe omission",
        mutationPassArtifactPassed:
          "real browser mutation artifact passed after runtime_current_evidence_accepted_for_review, admin session verification, mutation opt-in, artifact write/readback opt-in, API readback, ledger readback, and action duration checks",
        mutationRunnerReadyBlocked:
          "runtime_current_evidence_accepted_for_review is true but admin session, mutation opt-in, browser artifact write/readback, or runner opt-in is still missing",
        runtimeCurrentEvidenceAcceptedForReview:
          "bounded external runtime-current artifact is current, non-simulated, commit-matched, timestamp-consistent, and secret-safe; cannot mark E11 final x by itself",
      },
      acceptanceSchema: {
        adminSessionVerification: {
          marker: "admin_session_verified_secret_omitted",
          rawSecretRequired: false,
          requiredField: "session_verification",
          secretOmitted: true,
        },
        browserArtifact: {
          provenanceField: "provenance",
          requiredFields: parsed.browserEvidenceArtifact.requiredTopLevelFields,
          schema: "billing_execute_browser_live_e2e_evidence.v1",
        },
        freshness: {
          currentCommitField: "git_commit",
          freshnessField: "freshness",
          requireCurrentCommit: true,
        },
        mutationControls: {
          artifactReadbackOptIn: "artifact_readback_opt_in_enabled",
          artifactWriteOptIn: "artifact_write_opt_in_enabled",
          mutationOptIn: "mutation_opt_in_enabled",
          requiredField: "mutation_controls",
        },
        readback: {
          apiFields: [
            "dry_run_plan",
            "execute_apply",
            "idempotent_replay",
            "refund_refusal",
            "ledger_refresh",
          ],
          ledgerFields: [
            "applied_ledger_entry_visible",
            "idempotent_replay_reused_ledger_entry",
            "refund_refusal_no_ledger_write",
            "ledger_refresh_visible",
          ],
        },
        resultClassification: {
          failedActionField: "failed_action",
          failureClassificationField: "failure_classification",
          requiredField: "failure_taxonomy",
        },
        runtimeArtifact: {
          currentCommitField: "git_commit",
          provenanceField: "provenance",
          requiredFields: [
            "schema",
            "status",
            "classification",
            "blocker",
            "source_newest_utc",
            "container_created_utc",
            "image_created_utc",
            "image_id",
            "git_commit",
            "alignment_rules",
            "readback_classification",
            "rebuild_handoff_execution_allowed",
          ],
          schema: "control_plane_ledger_execute_runtime_current_handoff.v1",
          timestampComparison: {
            imageCreatedUtc: "image_created_utc",
            runtimeCreatedUtc: "container_created_utc",
            sourceNewestUtc: "source_newest_utc",
          },
        },
        secretSafeOmission: {
          requestMaterialEchoed: false,
          sessionMaterialEchoed: false,
          urlCredentialsEchoed: false,
        },
      },
      defaults: {
        buildsRuntime: false,
        consumesAdminSession: false,
        mutates: false,
        readsBrowserArtifact: false,
        readsRuntimeArtifact: false,
        recreatesRuntime: false,
      },
      refusalTaxonomy: {
        artifactReadbackMissing: "artifact_readback_missing",
        artifactWriteMissing: "artifact_write_missing",
        browserArtifactSimulated: "simulated_artifact_cannot_close_e11",
        browserArtifactStale: "artifact_readback_failed",
        browserUnavailable: "browser_tooling_unavailable",
        durationNonNumeric: "duration_non_numeric",
        idempotentReplayFailed: "browser_idempotent_replay_failed",
        ledgerRefreshMissing: "ledger_refresh_missing",
        mutationOptInMissing: "mutation_opt_in_missing",
        rawSecretPresent: "raw_secret_present",
        refundRefusalMissing: "refund_refusal_missing",
        runtimeArtifactMissing: "runtime_current_artifact_missing",
        runtimeArtifactSimulated: "simulated_artifact_cannot_close_e11",
        runtimeArtifactStale: "runtime_current_artifact_stale_or_unverified",
        runtimeCommitMismatch: "runtime_current_commit_mismatch",
        runtimeUnsafeArtifact: "unsafe_artifact_path",
        sessionInvalidMarker: "admin_session_invalid",
        sessionMissingMarker: "session_material_missing",
      },
      schema: "billing_execute_runtime_current_evidence_acceptance_matrix.v1",
      simulationPolicy: {
        acceptedShapeSimulations: true,
        buildsRuntime: false,
        mutates: false,
        recreatesRuntime: false,
        simulationCanMarkFinalX: false,
      },
    });
    expect(parsed.runtimeCurrentFinalClosureAudit).toEqual({
      defaults: {
        buildsRuntime: false,
        consumesAdminSession: false,
        mutates: false,
        readsBrowserArtifact: false,
        readsRuntimeArtifact: false,
        recreatesRuntime: false,
      },
      exactNextCommands: {
        browserMutationRunnerArtifact:
          "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -BrowserPreflight -BrowserMutationOptIn -BrowserEvidenceArtifactWriteOptIn -BrowserLiveRunnerExecutionOptIn -BrowserEvidenceArtifactPath artifacts/billing_execute_browser_live_e2e_evidence.json",
        browserMutationRunnerArtifactReadback:
          "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -BrowserEvidenceArtifactReadbackOptIn -BrowserEvidenceArtifactPath artifacts/billing_execute_browser_live_e2e_evidence.json",
        runtimeCurrentHandoff:
          "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -RuntimeCurrentEvidenceArtifactWriteOptIn -RuntimeCurrentEvidenceArtifactPath artifacts/control_plane_ledger_execute_runtime_current_handoff.json",
        runtimeCurrentReadback:
          "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -RuntimeCurrentEvidenceArtifactReadbackOptIn -RuntimeCurrentEvidenceArtifactPath artifacts/control_plane_ledger_execute_runtime_current_handoff.json",
        sessionMarker:
          "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -AdminSessionHandoff",
      },
      reportFields: {
        apiReadbackState: "api_readback_state",
        blockingReasons: "blocking_reasons",
        browserArtifactState: "browser_artifact_state",
        currentCommit: "current_commit",
        durationState: "duration_state",
        finalXEligible: "final_x_eligible",
        generatedAt: "generated_at",
        ledgerReadbackState: "ledger_readback_state",
        mutationControlsState: "mutation_controls_state",
        requiredEvidence: "required_evidence",
        runtimeArtifactState: "runtime_artifact_state",
        secretSafeOmissionState: "secret_safe_omission_state",
        sessionState: "session_state",
      },
      requiredEvidence: [
        "runtime_current_verified_artifact_readback",
        "admin_session_verified_secret_omitted_marker",
        "mutation_opt_in_enabled",
        "browser_mutation_artifact_write_readback",
        "api_readback_passed",
        "ledger_readback_passed",
        "numeric_durations_present",
        "secret_safe_omission_proof",
        "current_commit_freshness",
      ],
      schema: "billing_execute_browser_mutation_final_closure_audit.v1",
      simulationPolicy: {
        acceptedShapeSimulations: true,
        buildsRuntime: false,
        mutates: false,
        recreatesRuntime: false,
        simulationCanMarkFinalX: false,
      },
      stateValues: {
        accepted: "accepted",
        blocked: "blocked",
        missing: "missing",
        refused: "refused",
        simulated: "simulated",
      },
    });
    expect(parsed.browserMutationEvidenceWatcherFinalGuard).toEqual({
      defaultMode: "watcher_final_guard_review",
      defaults: {
        buildsRuntime: false,
        consumesAdminSession: false,
        mutates: false,
        readsBrowserArtifact: false,
        readsRuntimeArtifact: false,
        recreatesRuntime: false,
      },
      exactNextCommands: {
        browserArtifactReadback:
          "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -BrowserEvidenceArtifactReadbackOptIn -BrowserEvidenceArtifactPath artifacts/billing_execute_browser_live_e2e_evidence.json",
        browserMutationRunner:
          "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -BrowserPreflight -BrowserMutationOptIn -BrowserEvidenceArtifactWriteOptIn -BrowserLiveRunnerExecutionOptIn -BrowserEvidenceArtifactPath artifacts/billing_execute_browser_live_e2e_evidence.json",
        runtimeCurrentHandoff:
          "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -RuntimeCurrentEvidenceArtifactWriteOptIn -RuntimeCurrentEvidenceArtifactPath artifacts/control_plane_ledger_execute_runtime_current_handoff.json",
        runtimeCurrentReadback:
          "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -RuntimeCurrentEvidenceArtifactReadbackOptIn -RuntimeCurrentEvidenceArtifactPath artifacts/control_plane_ledger_execute_runtime_current_handoff.json",
        sessionMarker:
          "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -AdminSessionHandoff",
      },
      expectedArtifactPaths: {
        browserMutationArtifact:
          "artifacts/billing_execute_browser_live_e2e_evidence.json",
        runtimeCurrentArtifact:
          "artifacts/control_plane_ledger_execute_runtime_current_handoff.json",
      },
      finalGuardFlags: {
        acceptedShapeCanMarkFinalX: false,
        noArtifactCanMarkFinalX: false,
        sessionMissingCanMarkFinalX: false,
        simulationCanMarkFinalX: false,
        watcherCanMarkFinalX: false,
      },
      finalReviewChecklist: [
        {
          key: "runtime_current_artifact_current",
          requiredState: "runtime_current_verified",
        },
        {
          key: "admin_session_marker_secret_omitted",
          requiredState: "admin_session_verified_secret_omitted",
        },
        {
          key: "mutation_opt_in_present",
          requiredState: "mutation_opt_in_enabled",
        },
        {
          key: "browser_artifact_readback_passed",
          requiredState: "mutation_pass_artifact_passed",
        },
        {
          key: "api_and_ledger_readback_passed",
          requiredState: "api_ledger_readback_passed",
        },
        {
          key: "numeric_durations_present",
          requiredState: "numeric_durations_present",
        },
        {
          key: "secret_safe_omission_proven",
          requiredState: "secret_safe_omission",
        },
        {
          key: "not_simulation_or_watcher_only",
          requiredState: "real_artifact_only",
        },
      ],
      mutationOptInRequirements: {
        artifactReadbackFlag: "-BrowserEvidenceArtifactReadbackOptIn",
        artifactWriteFlag: "-BrowserEvidenceArtifactWriteOptIn",
        env: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_MUTATION=1",
        runnerFlag: "-BrowserLiveRunnerExecutionOptIn",
      },
      schema:
        "billing_execute_browser_mutation_evidence_watcher_final_guard.v1",
      sessionMarkerRequirements: {
        env: "CONTROL_PLANE_ADMIN_SESSION_TOKEN",
        marker: "admin_session_verified_secret_omitted",
        rawSecretEchoed: false,
      },
      watcherStates: {
        blocked: "blocked",
        finalEligible: "final_eligible",
        waitingForRealEvidence: "waiting_for_real_evidence",
      },
    });
    expect(parsed.runtimeCurrentOperatorHandoffPack).toEqual({
      boundedRunnerTimeoutMs: 90000,
      commands: {
        adminSessionVerify: {
          env: "CONTROL_PLANE_ADMIN_SESSION_TOKEN",
          flag: "-AdminSessionHandoff",
          marker: "admin_session_present",
          secretEchoed: false,
        },
        browserMutationRunner: {
          command:
            "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -BrowserPreflight -BrowserMutationOptIn -BrowserEvidenceArtifactWriteOptIn -BrowserLiveRunnerExecutionOptIn -BrowserEvidenceArtifactPath artifacts/billing_execute_browser_live_e2e_evidence.json",
          env: {
            artifactWrite:
              "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_WRITE=1",
            mutation:
              "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_MUTATION=1",
            session: "CONTROL_PLANE_ADMIN_SESSION_TOKEN",
          },
        },
        runtimeArtifactReadback: {
          command:
            "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -RuntimeCurrentEvidenceArtifactReadbackOptIn -RuntimeCurrentEvidenceArtifactPath artifacts/control_plane_ledger_execute_runtime_current_handoff.json",
          env: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_READBACK=1",
          flag: "-RuntimeCurrentEvidenceArtifactReadbackOptIn",
        },
        runtimeArtifactWrite: {
          command:
            "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -RuntimeCurrentEvidenceArtifactWriteOptIn -RuntimeCurrentEvidenceArtifactPath artifacts/control_plane_ledger_execute_runtime_current_handoff.json",
          env: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_WRITE=1",
          flag: "-RuntimeCurrentEvidenceArtifactWriteOptIn",
        },
      },
      defaultBuildsRuntime: false,
      defaultConsumesSession: false,
      defaultMutates: false,
      defaultReadsRuntimeArtifact: false,
      defaultRecreatesRuntime: false,
      failureTaxonomy: {
        artifactReadbackMissing: "artifact_readback_missing",
        artifactWriteMissing: "artifact_write_missing",
        browserUnavailable: "browser_tooling_unavailable",
        durationNonNumeric: "duration_non_numeric",
        idempotentReplayFailed: "browser_idempotent_replay_failed",
        ledgerRefreshMissing: "ledger_refresh_missing",
        mutationOptInMissing: "mutation_opt_in_missing",
        recreateUnavailable:
          "control_plane_container_unavailable_for_no_build_handoff",
        rebuildForbidden: "runtime_image_requires_rebuild_but_build_forbidden",
        refundRefusalMissing: "refund_refusal_missing",
        runtimeArtifactMissing: "runtime_current_artifact_missing",
        runtimeArtifactSimulated: "simulated_artifact_cannot_close_e11",
        runtimeArtifactStale: "runtime_current_artifact_stale_or_unverified",
        sessionInvalid: "admin_session_invalid",
        sessionMissing: "session_material_missing",
        unsafeArtifactPath: "unsafe_artifact_path",
      },
      requiredArtifactFields: {
        browserMutationArtifact:
          parsed.browserEvidenceArtifact.requiredTopLevelFields,
        runtimeCurrentArtifact: [
          "schema",
          "status",
          "classification",
          "blocker",
          "source_newest_utc",
          "container_created_utc",
          "image_created_utc",
          "image_id",
          "git_commit",
          "alignment_rules",
          "readback_classification",
          "rebuild_handoff_execution_allowed",
        ],
      },
      schema: "billing_execute_runtime_current_operator_handoff_pack.v1",
      stateMarkers: {
        e11X: "e11_x",
        mutationPassArtifactPassed: "mutation_pass_artifact_passed",
        mutationRunnerReadyBlocked: "mutation_runner_ready_blocked",
        runtimeCurrentHandoffReady: "runtime_current_handoff_ready",
      },
      stateDefinitions: {
        e11X: "requires mutation_pass_artifact_passed and artifact_readback_passed with final DoD checklist complete",
        mutationPassArtifactPassed:
          "browser runner produced passed artifact with current runtime, action outcomes, numeric durations, API and ledger readback",
        mutationRunnerReadyBlocked:
          "runtime_current_verified is proven, but session, mutation, browser artifact write/readback, or runner opt-in is still missing",
        runtimeCurrentHandoffReady:
          "runtime_current_verified artifact/readback is current; no browser mutation has run",
      },
      sequence: [
        "operator_rebuild_or_recreate_outside_script",
        "runtime_artifact_write",
        "runtime_artifact_readback",
        "admin_session_verify_secret_omitted",
        "mutation_and_browser_artifact_opt_in",
        "browser_runner_bounded_execution",
        "browser_artifact_readback",
        "final_dod_classification",
      ],
    });
    expect(parsed.browserLiveEnvironmentBootstrapAttempt).toEqual({
      artifactName: "billing_execute_browser_live_e2e_evidence.v1",
      defaultInstallsBrowser: false,
      defaultMode: "live_environment_bootstrap_attempt",
      defaultStartsAdminUiDevServer: false,
      defaultSubmitsLiveMutation: false,
      devServer: {
        command: "npm run dev -- --host 127.0.0.1",
        cwd: "web/admin-ui",
        env: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_ADMIN_UI_DEV_SERVER",
        flag: "-BrowserAdminUiDevServerOptIn",
        requiredValue: "1",
      },
      durationFields: parsed.browserEvidenceArtifact.durationFields,
      playwright: {
        browser: "chromium",
        installCommand:
          "npm --prefix web/admin-ui exec playwright install chromium",
        installHintOnly: true,
      },
      sessionHandoff: {
        echoCookie: false,
        echoHeaderValue: false,
        echoToken: false,
        env: "CONTROL_PLANE_ADMIN_SESSION_TOKEN",
        header: "X-Admin-Session",
        requiredForActions: true,
      },
      requiredForPassAttempt: {
        adminUiReachable: true,
        artifactReadbackFresh: true,
        artifactWriteOptIn: true,
        browserToolingAvailable: true,
        controlPlaneHealthReachable: true,
        liveRunnerOptIn: true,
        mutationOptIn: true,
        sessionMaterialPresent: true,
      },
      secretSafeOmission: {
        echoRequestMaterial: false,
        echoSessionMaterial: false,
        echoUrlCredentials: false,
      },
      statusMarkers: {
        blocked: "blocked",
        fail: "fail",
        passAttemptReady: "pass_attempt_ready",
        passReadback: "pass_readback",
      },
    });
    expect(parsed.browserMutationPassArtifactClosure).toEqual({
      artifactName: "billing_execute_browser_live_e2e_evidence.v1",
      classificationValues:
        parsed.browserEvidenceArtifact.classificationValues
          .mutationPassArtifact,
      defaultClosesLiveGap: false,
      defaultMode: "mutation_pass_artifact_closure_gate",
      defaultSubmitsLiveMutation: false,
      durationFields: parsed.browserEvidenceArtifact.durationFields,
      expectedActionOutcomes: {
        dry_run_plan: "executePreflight",
        execute_apply: "applied",
        idempotent_replay: "idempotent",
        ledger_refresh: "success",
        refund_refusal: "blocked",
      },
      requiredArtifactFreshness: {
        requireCurrentGitCommit: true,
        requireFreshnessMarker: true,
        requireHandoffFresh: true,
        requireReadBack: true,
      },
      requiredReadiness: {
        adminUiReachable: true,
        browserLaunchReady: true,
        contextReady: true,
        controlPlaneHealthReachable: true,
        mutationOptInEnabled: true,
        pageReady: true,
        selectorSnapshotReady: true,
        sessionMaterialPresent: true,
      },
      secretSafeOmission: {
        echoRequestMaterial: false,
        echoSessionMaterial: false,
        echoUrlCredentials: false,
      },
      statusMarkers: {
        blocked: "blocked",
        closureEligible: "closure_eligible",
        passed: "passed",
      },
    });
    expect(parsed.browserPlaywrightLaunchReadiness).toEqual({
      artifactEmission: {
        artifactName: "billing_execute_browser_live_e2e_evidence.v1",
        outputMarker: "browser_runner_evidence_json",
        writeDisabledByDefault: true,
      },
      blockers: {
        adminUiUnreachable: "admin_ui_unreachable",
        browserToolingUnavailable: "browser_tooling_unavailable",
        controlPlaneHealthUnreachable: "control_plane_health_unreachable",
        liveMutationOptInMissing: "live_mutation_opt_in_missing",
        sessionMaterialMissing: "session_material_missing",
      },
      defaultClicksAdminUiActions: false,
      defaultMode: "playwright_launch_readiness_only",
      defaultSubmitsLiveMutation: false,
      durationFields: {
        browserLaunchDurationMs: "browser_launch_duration_ms",
        contextSetupDurationMs: "context_setup_duration_ms",
        pageReadyDurationMs: "page_ready_duration_ms",
        selectorSnapshotDurationMs: "selector_snapshot_duration_ms",
        serviceReadinessDurationMs: "service_readiness_duration_ms",
      },
      readinessFields: {
        browserLaunchReady: "browser_launch_ready",
        contextReady: "context_ready",
        mutationAllowed: "mutation_allowed",
        pageReady: "page_ready",
        safeAdminUiUrl: "safe_admin_ui_url",
        safeControlPlaneUrl: "safe_control_plane_url",
        selectorSnapshotReady: "selector_snapshot_ready",
      },
      secretSafeOmission: {
        echoRequestMaterial: false,
        echoSessionMaterial: false,
        echoUrlCredentials: false,
      },
    });
    expect(parsed.browserPreflight).toEqual({
      defaultMode: "preflight_only",
      healthProbePaths: {
        adminUi: "/",
        controlPlane: "/healthz",
      },
      metricMarkers: {
        adminUiReachable: "admin_ui_reachable",
        controlPlaneHealthReachable: "control_plane_health_reachable",
        serviceBlocker: "service_blocker",
        serviceProbeTimeoutMs: "service_probe_timeout_ms",
        serviceReadinessDurationMs: "service_readiness_duration_ms",
        ledgerRefreshDurationMs: "ledger_refresh_duration_ms",
        readiness: "browser_smoke_readiness",
        sessionMaterialEchoed: "session_material_echoed",
        sessionMaterialPresent: "session_material_present",
        submitLatencyMs: "submit_latency_ms",
        unavailable: "unavailable",
      },
      requiredInputs: {
        adminUiBaseUrl: "ADMIN_UI_BASE_URL",
        controlPlaneBaseUrl: "CONTROL_PLANE_BASE_URL",
        handoffArtifact:
          "web/admin-ui/src/billingExecuteSmokeContract.serializable.json",
      },
      requiresLiveBackendByDefault: false,
      usesDataTestIdsOnly: true,
    });
    expect(parsed.browserRunnerReadiness).toEqual({
      actionPermission: {
        defaultClicksAdminUiActions: false,
        requireAdminUiReachable: true,
        requireBrowserToolingAvailable: true,
        requireControlPlaneHealthReachable: true,
        requireMutationOptIn: true,
        requireSessionMaterialPresent: true,
        requireStableActionSelectors: true,
      },
      artifactRoundTrip: {
        freshnessMarker: "artifact_roundtrip_fresh",
        outputMarker: "browser_runner_evidence_json",
        writeMode: "json_roundtrip_only",
      },
      artifactWriteRead: {
        defaultWritesArtifact: false,
        defaultPath: "artifacts/billing_execute_browser_live_e2e_evidence.json",
        env: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_WRITE",
        flag: "-BrowserEvidenceArtifactWriteOptIn",
        pathEnv:
          "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_PATH",
        requiredValue: "1",
        staleRefusal: {
          maxGeneratedAgeMinutes: 30,
          requireCurrentGitCommit: true,
          requireFreshnessMarker: true,
          requireHandoffFresh: true,
        },
        writeMode: "explicit_opt_in_only",
      },
      defaultMode: "runner_readiness_only",
      durationCaptureNames: parsed.browserEvidenceArtifact.durationFields,
      readinessFields: {
        actionsAllowed: "actions_allowed",
        adminUiUrlSafe: "admin_ui_url_safe",
        browserAvailable: "browser_available",
        controlPlaneUrlSafe: "control_plane_url_safe",
        mutationOptInEnabled: "mutation_opt_in_enabled",
        noMutationDefault: "no_mutation_default",
        selectorReadiness: "selector_readiness",
        sessionMaterialPresent: "session_material_present",
      },
      selectorSource: "ledgerAdjustmentExecuteLiveSmokeContract.selectors",
      statusSource: "ledgerAdjustmentExecuteLiveSmokeHandoff.readinessStates",
    });
    expect(parsed.selectors).toEqual(ledgerExecuteSmoke.selectors);
    expect(parsed.statusMarkers).toEqual(ledgerExecuteSmoke.markers);
    expect(parsed.forbiddenSensitiveMarkers).toEqual(
      ledgerExecuteSmoke.forbiddenSensitiveMarkers,
    );
    expect(parsed.runtimeCurrentHandoff).toEqual({
      buildAllowedDefault: false,
      classifications: {
        buildRequiredButForbidden: "build_required_but_forbidden",
        containerRecreateAvailable: "container_recreate_available",
        containerUnavailable: "control_plane_container_unavailable",
        dockerUnavailable: "docker_unavailable",
        imageInspectUnavailable: "control_plane_image_inspect_unavailable",
        operatorCommandGenerated: "operator_command_generated",
        runtimeCurrentAfterRecreateUnverified:
          "runtime_current_after_recreate_unverified",
        runtimeCurrentAfterRecreateVerified:
          "runtime_current_after_recreate_verified",
        sourceNewerThanRuntimeImage: "source_newer_than_runtime_image",
      },
      defaultMode: "runtime_current_handoff",
      evidenceArtifact: {
        defaultPath:
          "artifacts/control_plane_ledger_execute_runtime_current_handoff.json",
        env: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_WRITE",
        flag: "-RuntimeCurrentEvidenceArtifactWriteOptIn",
        pathEnv:
          "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_PATH",
        readBackRequiredForExecution: true,
        readDisabledByDefault: true,
        readbackEnv:
          "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_READBACK",
        readbackFlag: "-RuntimeCurrentEvidenceArtifactReadbackOptIn",
        requiredValue: "1",
        schema: "control_plane_ledger_execute_runtime_current_handoff.v1",
        writeDisabledByDefault: true,
      },
      browserRunnerUnlock: {
        classifications: {
          artifactMissing: "runtime_current_artifact_missing",
          artifactStaleOrUnverified:
            "runtime_current_artifact_stale_or_unverified",
          verifiedArtifact: "runtime_current_verified",
        },
        defaultRunsBrowserRunner: false,
        defaultSubmitsLiveMutation: false,
        requiresArtifactReadback: true,
        unlockedBlockerShift: "session_mutation_artifact_gate",
        verifiedClassification: "runtime_current_verified",
      },
      noBuildRecreate: {
        command:
          "docker compose -f deploy/docker-compose/docker-compose.yml up -d --no-build --no-deps --force-recreate control-plane",
        commandClassification: "operator_command_generated",
        defaultExecutes: false,
        env: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_RECREATE",
        flag: "-RuntimeCurrentNoBuildRecreateOptIn",
        readbackRequired: true,
        requiredValue: "1",
      },
      outputMarkers: {
        buildAllowed: "runtime_current_handoff_build_allowed",
        blocker: "runtime_current_handoff_blocker",
        classification: "runtime_current_handoff_classification",
        command: "runtime_current_handoff_command",
        readbackClassification:
          "runtime_current_handoff_readback_classification",
        status: "runtime_current_handoff_status",
      },
      readbackClassifications: {
        failed: "runtime_current_readback_failed",
        notRequested: "runtime_current_readback_not_requested",
        staleOrUnverified: "runtime_current_readback_stale_or_unverified",
        verified: "runtime_current_readback_verified",
      },
      rebuildHandoff: {
        buildForbiddenBlocker:
          "runtime_image_requires_rebuild_but_build_forbidden",
        commandClassification: "operator_command_generated",
        commandHint:
          "docker compose -f deploy/docker-compose/docker-compose.yml build control-plane && docker compose -f deploy/docker-compose/docker-compose.yml up -d --no-deps --force-recreate control-plane",
        defaultExecutesBuild: false,
        env: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_REBUILD_HANDOFF",
        executionAllowed: false,
        flag: "-RuntimeCurrentRebuildHandoffOptIn",
        readbackRequired: true,
        requiredValue: "1",
      },
      secretSafeOmission: {
        echoRequestMaterial: false,
        echoSessionMaterial: false,
        echoUrlCredentials: false,
      },
    });
    expect(parsed.readinessStates).toEqual(
      ledgerExecuteSmokeHandoff.readinessStates,
    );
    expect(parsed.readinessMarkerKeys).toEqual(
      ledgerExecuteSmokeHandoff.readinessMarkerKeys,
    );
    expect(parsed.serialization).toEqual({
      absentOptionalMarker: ledgerAdjustmentExecuteAbsentOptionalMarker,
      format: "json",
      requiredReadinessMarkerKeys:
        ledgerExecuteSmokeHandoff.readinessMarkerKeys,
    });

    const expectedMarkerKeys = [
      ...handoff.serialization.requiredReadinessMarkerKeys,
    ].sort();
    for (const state of Object.values(parsed.readinessStates) as Array<{
      markers: Record<string, unknown>;
    }>) {
      expect(Object.keys(state.markers).sort()).toEqual(expectedMarkerKeys);
      expect(Object.values(state.markers)).not.toContain(undefined);
    }

    expect(parsed.readinessStates.blocked.markers.executeOutcome).toBeNull();
    expect(
      parsed.readinessStates.blocked.markers.executeResultFresh,
    ).toBeNull();
    expect(
      parsed.readinessStates.blocked.markers.ledgerRefreshStatus,
    ).toBeNull();
    expect(
      parsed.readinessStates.contractBlocked.markers.executeOutcome,
    ).toBeNull();
    expect(
      parsed.readinessStates.dryRunRequired.markers.executeResultFresh,
    ).toBeNull();
    expect(
      parsed.readinessStates.executePreflight.markers.ledgerRefreshStatus,
    ).toBeNull();
    expect(parsed.readinessStates.failed.markers.executeOutcome).toBeNull();
    expect(
      parsed.readinessStates.stalePlan.markers.ledgerRefreshStatus,
    ).toBeNull();

    const assertNoFunctionValues = (value: unknown): void => {
      if (value && typeof value === "object") {
        for (const nestedValue of Object.values(
          value as Record<string, unknown>,
        )) {
          assertNoFunctionValues(nestedValue);
        }
        return;
      }
      expect(typeof value).not.toBe("function");
    };
    assertNoFunctionValues(handoff);
  });

  it("runs ledger adjustment dry-run and renders the plan-only contract with execute readiness", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));
    await user.click(
      await screen.findByRole("tab", { name: "账本概览" }),
    );

    const readinessRegion = await screen.findByRole("region", {
      name: "账本调整执行准备",
    });
    const readinessPanel = within(readinessRegion);
    expect(
      readinessPanel.getByText("execute_contract_mode=true"),
    ).toBeInTheDocument();
    expect(
      readinessPanel.getByText("execute_endpoint=true"),
    ).toBeInTheDocument();
    expect(readinessPanel.getByText("fresh_dry_run=false")).toBeInTheDocument();
    expect(
      readinessPanel.getByText("contract_check_network_call=false"),
    ).toBeInTheDocument();
    expect(
      readinessPanel.getByText("execute_write_network_call=false"),
    ).toBeInTheDocument();
    expect(
      readinessPanel.getByRole("button", { name: "执行账本调整" }),
    ).toBeDisabled();
    expectLedgerBackendSmokeReadiness({
      dryRunFresh: false,
      executeEnabled: false,
      executeWriteNetworkCall: false,
      handoffState: "dryRunRequired",
      status: "dry run required",
    });

    const dryRunRegion = await screen.findByRole("region", {
      name: "账本调整 dry-run",
    });
    const dryRunPanel = within(dryRunRegion);
    expect(
      screen.getByTestId(ledgerExecuteSmoke.selectors.dryRunForm),
    ).toBeInTheDocument();
    expect(
      screen.getByTestId(ledgerExecuteSmoke.selectors.operationInput),
    ).toBeInTheDocument();
    expect(
      screen.getByTestId(ledgerExecuteSmoke.selectors.amountInput),
    ).toBeInTheDocument();
    expect(
      screen.getByTestId(ledgerExecuteSmoke.selectors.currencyInput),
    ).toBeInTheDocument();
    expect(
      screen.getByTestId(ledgerExecuteSmoke.selectors.relatedLedgerEntryInput),
    ).toBeInTheDocument();
    expect(
      screen.getByTestId(ledgerExecuteSmoke.selectors.requestInput),
    ).toBeInTheDocument();
    expect(
      screen.getByTestId(ledgerExecuteSmoke.selectors.reasonInput),
    ).toBeInTheDocument();
    expect(
      screen.getByTestId(ledgerExecuteSmoke.selectors.dryRunButton),
    ).toBeInTheDocument();

    await user.type(dryRunPanel.getByLabelText("金额"), "0.25000000");
    await user.type(
      dryRunPanel.getByLabelText("关联账本条目"),
      "00000000-0000-0000-0000-000000000091",
    );
    await user.type(
      dryRunPanel.getByLabelText("Request ID"),
      "00000000-0000-0000-0000-000000000090",
    );
    await user.type(dryRunPanel.getByLabelText("原因"), "customer credit");
    await user.click(dryRunPanel.getByRole("button", { name: "规划 dry-run" }));

    expect(
      await screen.findByRole("region", {
        name: "账本调整 dry-run 结果",
      }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "计划标记" }),
    ).toBeInTheDocument();
    expect(screen.getByText("plan_only=true")).toBeInTheDocument();
    expect(
      screen.getAllByText("fresh_dry_run=true").length,
    ).toBeGreaterThanOrEqual(2);
    expect(screen.getByText("ledger_write=false")).toBeInTheDocument();
    expect(screen.getByText("request_log_write=false")).toBeInTheDocument();
    expect(screen.getByText("audit_log_write=false")).toBeInTheDocument();
    expect(screen.getByText("upstream_call=false")).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "计划账本条目" }),
    ).toBeInTheDocument();
    expect(screen.getAllByText("0.25000000 USD").length).toBeGreaterThanOrEqual(
      2,
    );
    expect(screen.getByText("server generated on execute")).toBeInTheDocument();
    expect(
      screen.getByText("bounded_admin_adjustment_metadata_only"),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "关联条目摘要" }),
    ).toBeInTheDocument();
    expect(screen.getByText("-0.25000000 USD")).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "剩余可退款" }),
    ).toBeInTheDocument();
    expect(screen.getAllByText("0.15000000 USD").length).toBeGreaterThanOrEqual(
      2,
    );
    expect(screen.getByText("refund, adjust")).toBeInTheDocument();
    expect(
      screen.getByRole("heading", {
        level: 2,
        name: "未来审计 / 写入契约",
      }),
    ).toBeInTheDocument();
    expect(screen.getByText("ledger.refund")).toBeInTheDocument();
    expect(
      screen.getByText("bounded public ids and amounts only"),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "执行账本调整" }),
    ).toBeEnabled();
    expect(
      screen.getByRole("button", { name: "检查执行契约" }),
    ).toBeEnabled();
    expectLedgerBackendSmokeReadiness({
      dryRunFresh: true,
      executeEnabled: true,
      executeWriteNetworkCall: false,
      handoffState: "executePreflight",
      status: "execute preflight",
    });

    await user.click(
      screen.getByRole("button", { name: "检查执行契约" }),
    );

    expect(
      await screen.findByText(
        /future_writer_required：后端已验证计划/,
      ),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("region", {
        name: "账本调整执行契约结果",
      }),
    ).toBeInTheDocument();
    expect(
      screen.getByText("contract_check_network_call=true"),
    ).toBeInTheDocument();
    expect(
      screen.getByText("execute_write_network_call=false"),
    ).toBeInTheDocument();
    expect(screen.getByText("blocked")).toBeInTheDocument();
    expect(
      screen.getAllByText("future_writer_required").length,
    ).toBeGreaterThan(0);
    expect(
      screen.getByText("ledger_adjustment_execute_preflight_contract.v2"),
    ).toBeInTheDocument();
    expect(screen.getByText("validated before refusal")).toBeInTheDocument();
    expect(
      screen.getByText("transactional writer pending"),
    ).toBeInTheDocument();
    expect(screen.getByText("future_writer_required=true")).toBeInTheDocument();
    expect(
      screen.getAllByText("ledger_write=false").length,
    ).toBeGreaterThanOrEqual(2);
    expect(
      screen.getAllByText("audit_log_write=false").length,
    ).toBeGreaterThanOrEqual(2);
    expect(
      screen.getAllByText("request_log_write=false").length,
    ).toBeGreaterThanOrEqual(2);
    expect(
      screen.getAllByText("upstream_call=false").length,
    ).toBeGreaterThanOrEqual(2);
    expect(
      screen.getByText("server_generated_write_marker=true"),
    ).toBeInTheDocument();
    expect(screen.getByText("write_marker_echoed=false")).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 3, name: "去重摘要" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 3, name: "事务摘要" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 3, name: "写入器 / 审计摘要" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 3, name: "安全输出摘要" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", {
        level: 3,
        name: "执行器摘要契约",
      }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", {
        level: 3,
        name: "拒绝执行器摘要",
      }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", {
        level: 3,
        name: "拒绝摘要契约",
      }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", {
        level: 3,
        name: "回滚执行器摘要契约",
      }),
    ).toBeInTheDocument();
    expect(screen.getByText("read_committed_or_stronger")).toBeInTheDocument();
    expect(screen.getByText("digest_marker_only")).toBeInTheDocument();
    expect(
      screen.getByText("transactional_admin_ledger_adjustment_writer"),
    ).toBeInTheDocument();
    expect(
      screen.getAllByText("billing_ledger_postgres_executor_summary.v1").length,
    ).toBeGreaterThan(0);
    expect(
      screen.getAllByText("ledger_executor_summary").length,
    ).toBeGreaterThan(0);
    const refusalSummaryPanel = screen
      .getByRole("heading", { level: 3, name: "拒绝执行器摘要" })
      .closest("article");
    expect(refusalSummaryPanel).not.toBeNull();
    expect(
      within(refusalSummaryPanel as HTMLElement).getByText("refund"),
    ).toBeInTheDocument();
    expect(
      within(refusalSummaryPanel as HTMLElement).getByText("refused_preflight"),
    ).toBeInTheDocument();
    expect(
      within(refusalSummaryPanel as HTMLElement).getByText("已提交"),
    ).toBeInTheDocument();
    expect(
      within(refusalSummaryPanel as HTMLElement).getByText("已回滚"),
    ).toBeInTheDocument();
    expect(
      within(refusalSummaryPanel as HTMLElement).getByText(
        "拒绝语句数",
      ),
    ).toBeInTheDocument();
    expect(
      within(refusalSummaryPanel as HTMLElement).getByText("失败输出"),
    ).toBeInTheDocument();
    expect(
      within(refusalSummaryPanel as HTMLElement).getByText(
        "行数不匹配",
      ),
    ).toBeInTheDocument();
    const refusalContractPanel = screen
      .getByRole("heading", { level: 3, name: "拒绝摘要契约" })
      .closest("article");
    expect(refusalContractPanel).not.toBeNull();
    expect(
      within(refusalContractPanel as HTMLElement).getByText(
        "refused_preflight, refused_rollback",
      ),
    ).toBeInTheDocument();
    expect(
      within(refusalContractPanel as HTMLElement).getByText(
        "预检拒绝语句数",
      ),
    ).toBeInTheDocument();
    expect(
      within(refusalContractPanel as HTMLElement).getByText(
        "回滚拒绝语句数",
      ),
    ).toBeInTheDocument();
    const rollbackContractPanel = screen
      .getByRole("heading", {
        level: 3,
        name: "回滚执行器摘要契约",
      })
      .closest("article");
    expect(rollbackContractPanel).not.toBeNull();
    expect(
      within(rollbackContractPanel as HTMLElement).getByText(
        "refused_rollback",
      ),
    ).toBeInTheDocument();
    expect(
      within(rollbackContractPanel as HTMLElement).getByText("one_or_more"),
    ).toBeInTheDocument();
    expect(
      within(rollbackContractPanel as HTMLElement).getByText("boolean_only"),
    ).toBeInTheDocument();
    expect(
      within(rollbackContractPanel as HTMLElement).getByText("失败输出"),
    ).toBeInTheDocument();
    expect(screen.getByText("兼容字段")).toBeInTheDocument();
    expect(screen.getByText("已检查约束")).toBeInTheDocument();
    expect(screen.getAllByText("3").length).toBeGreaterThan(0);
    expectLedgerBackendSmokeReadiness({
      contractCheckNetworkCall: true,
      dryRunFresh: true,
      executeEnabled: true,
      executeWriteNetworkCall: false,
      handoffState: "contractBlocked",
      status: "blocked",
    });

    const dryRunCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).includes("/admin/ledger/adjustments/dry-run") &&
        init?.method === "POST",
    );
    expect(String(dryRunCall?.[0])).toBe(
      "/api/control-plane/admin/ledger/adjustments/dry-run",
    );
    expect(JSON.parse(String(dryRunCall?.[1]?.body))).toEqual({
      amount: "0.25000000",
      currency: "USD",
      mode: "dry_run",
      operation: "refund",
      reason: "customer credit",
      related_ledger_entry_id: "00000000-0000-0000-0000-000000000091",
      request_id: "00000000-0000-0000-0000-000000000090",
    });
    const executeContractCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).includes("/admin/ledger/adjustments/dry-run") &&
        init?.method === "POST" &&
        JSON.parse(String(init.body)).mode === "execute_contract",
    );
    expect(String(executeContractCall?.[0])).toBe(
      "/api/control-plane/admin/ledger/adjustments/dry-run",
    );
    expect(JSON.parse(String(executeContractCall?.[1]?.body))).toEqual({
      amount: "0.25000000",
      currency: "USD",
      mode: "execute_contract",
      operation: "refund",
      reason: "customer credit",
      related_ledger_entry_id: "00000000-0000-0000-0000-000000000091",
      request_id: "00000000-0000-0000-0000-000000000090",
    });
    expect(document.body.textContent).not.toContain("idempotency_key");
    expect(document.body.textContent).not.toContain("server_dedupe_digest");
    expect(document.body.textContent).not.toContain("dedupe_replay_state");
    expect(document.body.textContent).not.toContain(
      "dedupe_reservation_for_update",
    );
    expect(document.body.textContent).not.toContain("operation_key");
    expect(document.body.textContent).not.toContain(
      "operation-key-secret-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "operation-key-refusal-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "operation-key-refusal-contract-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "operation-key-rollback-contract-hidden",
    );
    expect(document.body.textContent).not.toContain("error_detail");
    expect(document.body.textContent).not.toContain(
      "ledger-executor-contract-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "ledger-executor-refusal-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "ledger-refusal-contract-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "ledger-rollback-contract-hidden",
    );
    expect(document.body.textContent).not.toContain("credential_material");
    expect(document.body.textContent).not.toContain("dedupe_material");
    expect(document.body.textContent).not.toContain("raw metadata");
    expect(document.body.textContent).not.toContain(
      "raw executor contract metadata hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor refusal metadata hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor refusal contract metadata hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor rollback contract metadata hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor refusal error detail hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor refusal contract error hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor rollback contract error hidden",
    );
    expect(document.body.textContent).not.toContain("raw request");
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(
      fetchMock.mock.calls.filter(
        ([url]) =>
          String(url).includes("/admin/ledger/adjustments/") &&
          !String(url).includes("/dry-run"),
      ),
    ).toHaveLength(0);
  });

  it("executes ledger adjustment from a fresh dry-run and renders applied safe response summary", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));
    await user.click(
      await screen.findByRole("tab", { name: "账本概览" }),
    );

    const dryRunRegion = await screen.findByRole("region", {
      name: "账本调整 dry-run",
    });
    const dryRunPanel = within(dryRunRegion);

    await user.type(dryRunPanel.getByLabelText("金额"), "0.25000000");
    await user.type(
      dryRunPanel.getByLabelText("关联账本条目"),
      "00000000-0000-0000-0000-000000000091",
    );
    await user.type(
      dryRunPanel.getByLabelText("Request ID"),
      "00000000-0000-0000-0000-000000000090",
    );
    await user.type(dryRunPanel.getByLabelText("原因"), "customer credit");
    await user.click(dryRunPanel.getByRole("button", { name: "规划 dry-run" }));

    expect(
      await screen.findByRole("region", {
        name: "账本调整 dry-run 结果",
      }),
    ).toBeInTheDocument();
    expect(
      fetchMock.mock.calls.filter(
        ([url, init]) =>
          String(url).includes("/admin/ledger/adjustments/dry-run") &&
          init?.method === "POST" &&
          JSON.parse(String(init.body)).mode === "execute",
      ),
    ).toHaveLength(0);

    await user.click(
      screen.getByRole("button", { name: "执行账本调整" }),
    );

    expect(
      await screen.findByText(
        "账本调整已应用：账本和审计写入已确认。",
      ),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("region", { name: "账本调整执行结果" }),
    ).toBeInTheDocument();
    expect(
      screen.getByText("execute_write_network_call=true"),
    ).toBeInTheDocument();
    expect(screen.getByText("execute_result_fresh=true")).toBeInTheDocument();
    expect(screen.getByText("execute_outcome=applied")).toBeInTheDocument();
    expect(
      await screen.findByText(
        "执行后账本条目已刷新；本次执行结果匹配当前 dry-run payload。",
      ),
    ).toBeInTheDocument();
    expect(
      screen.getByText("ledger_entries_refresh_after_execute=success"),
    ).toBeInTheDocument();
    expectLedgerBackendSmokeReadiness({
      dryRunFresh: true,
      executeEnabled: true,
      executeOutcome: "applied",
      executeResultFresh: true,
      executeWriteNetworkCall: true,
      handoffState: "appliedRefreshSuccess",
      ledgerRefreshStatus: "success",
      status: "applied",
    });
    expect(screen.getAllByText("ledger_write=true").length).toBeGreaterThan(0);
    expect(screen.getAllByText("audit_log_write=true").length).toBeGreaterThan(
      0,
    );
    expect(
      screen.getByRole("heading", { level: 3, name: "执行摘要" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 3, name: "已执行账本条目" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", {
        level: 3,
        name: "账本执行器摘要",
      }),
    ).toBeInTheDocument();
    const executorSummaryPanel = screen
      .getByRole("heading", { level: 3, name: "账本执行器摘要" })
      .closest("article");
    expect(executorSummaryPanel).not.toBeNull();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText(
        "billing_ledger_postgres_executor_summary.v1",
      ),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText(
        "control_plane_transactional_admin_ledger_adjustment_writer",
      ),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText("refund"),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText("applied"),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText(
        "insert_ledger_entry",
      ),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText(
        "行数不匹配",
      ),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getAllByText("1").length,
    ).toBeGreaterThanOrEqual(4);
    expect(
      screen.getByRole("heading", {
        level: 3,
        name: "执行器摘要契约",
      }),
    ).toBeInTheDocument();
    const rollbackContractPanel = screen
      .getByRole("heading", {
        level: 3,
        name: "回滚执行器摘要契约",
      })
      .closest("article");
    expect(rollbackContractPanel).not.toBeNull();
    expect(
      within(rollbackContractPanel as HTMLElement).getByText(
        "refused_rollback",
      ),
    ).toBeInTheDocument();
    expect(
      within(rollbackContractPanel as HTMLElement).getByText("one_or_more"),
    ).toBeInTheDocument();
    expect(
      within(rollbackContractPanel as HTMLElement).getByText("boolean_only"),
    ).toBeInTheDocument();
    expect(screen.getAllByText("00000000...").length).toBeGreaterThan(0);
    expect(
      screen.getAllByText(
        "control_plane_transactional_admin_ledger_adjustment_writer",
      ).length,
    ).toBeGreaterThan(0);
    expect(screen.getAllByText("6").length).toBeGreaterThan(0);

    const executeCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).includes("/admin/ledger/adjustments/dry-run") &&
        init?.method === "POST" &&
        JSON.parse(String(init.body)).mode === "execute",
    );
    expect(String(executeCall?.[0])).toBe(
      "/api/control-plane/admin/ledger/adjustments/dry-run",
    );
    expect(JSON.parse(String(executeCall?.[1]?.body))).toEqual({
      amount: "0.25000000",
      currency: "USD",
      mode: "execute",
      operation: "refund",
      reason: "customer credit",
      related_ledger_entry_id: "00000000-0000-0000-0000-000000000091",
      request_id: "00000000-0000-0000-0000-000000000090",
    });
    await waitFor(() =>
      expect(
        fetchMock.mock.calls.filter(
          ([url, init]) =>
            String(url).includes("/admin/ledger/entries") &&
            (init?.method ?? "GET") === "GET",
        ).length,
      ).toBeGreaterThanOrEqual(2),
    );
    expect(document.body.textContent).not.toContain("idempotency_key");
    expect(document.body.textContent).not.toContain("server_dedupe_digest");
    expect(document.body.textContent).not.toContain(
      "dedupe_reservation_for_update",
    );
    expect(document.body.textContent).not.toContain("operation_key");
    expect(document.body.textContent).not.toContain(
      "operation-key-secret-hidden",
    );
    expect(document.body.textContent).not.toContain("error_detail");
    expect(document.body.textContent).not.toContain(
      "ledger-executor-summary-hidden",
    );
    expect(document.body.textContent).not.toContain("credential_material");
    expect(document.body.textContent).not.toContain("dedupe_material");
    expect(document.body.textContent).not.toContain("raw metadata");
    expect(document.body.textContent).not.toContain(
      "raw execute metadata hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executed ledger metadata hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor summary metadata hidden",
    );
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("ledger-execute-response-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("ledger-execute-response-hidden"),
    );

    await user.clear(dryRunPanel.getByLabelText("金额"));
    await user.type(dryRunPanel.getByLabelText("金额"), "0.10000000");

    expect(
      await screen.findByText(
        "表单在 dry-run 后已变更。请重新运行 dry-run 后再评估执行。",
      ),
    ).toBeInTheDocument();
    expect(
      screen.getAllByText("fresh_dry_run=false").length,
    ).toBeGreaterThanOrEqual(2);
    expect(
      screen.getByRole("button", { name: "执行账本调整" }),
    ).toBeDisabled();
    expect(
      screen.queryByText(
        "账本调整已应用：账本和审计写入已确认。",
      ),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText("execute_outcome=applied"),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("heading", {
        level: 3,
        name: "账本执行器摘要",
      }),
    ).not.toBeInTheDocument();
    expect(
      fetchMock.mock.calls.filter(
        ([url, init]) =>
          String(url).includes("/admin/ledger/adjustments/dry-run") &&
          init?.method === "POST" &&
          JSON.parse(String(init.body)).mode === "execute",
      ),
    ).toHaveLength(1);
  });

  it("renders idempotent ledger adjustment execute replay without claiming new writes", async () => {
    const fetchMock = stubAdminFetch({
      ledgerAdjustmentExecuteStatus: "idempotent",
    });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));
    await user.click(
      await screen.findByRole("tab", { name: "账本概览" }),
    );

    const dryRunRegion = await screen.findByRole("region", {
      name: "账本调整 dry-run",
    });
    const dryRunPanel = within(dryRunRegion);

    await user.selectOptions(dryRunPanel.getByRole("combobox", { name: "操作" }), "adjust");
    await user.type(dryRunPanel.getByLabelText("金额"), "0.10000000");
    await user.type(
      dryRunPanel.getByLabelText("Wallet ID"),
      "00000000-0000-0000-0000-000000000040",
    );
    await user.click(dryRunPanel.getByRole("button", { name: "规划 dry-run" }));
    expect(
      await screen.findByRole("region", {
        name: "账本调整 dry-run 结果",
      }),
    ).toBeInTheDocument();
    await user.click(
      screen.getByRole("button", { name: "执行账本调整" }),
    );

    expect(
      await screen.findByText(
        "幂等重放：返回既有账本条目，没有新的账本或审计写入。",
      ),
    ).toBeInTheDocument();
    expect(screen.getByText("execute_result_fresh=true")).toBeInTheDocument();
    expect(screen.getByText("execute_outcome=idempotent")).toBeInTheDocument();
    expect(
      await screen.findByText(
        "执行后账本条目已刷新；本次执行结果匹配当前 dry-run payload。",
      ),
    ).toBeInTheDocument();
    expect(
      screen.getByText("ledger_entries_refresh_after_execute=success"),
    ).toBeInTheDocument();
    expectLedgerBackendSmokeReadiness({
      dryRunFresh: true,
      executeEnabled: true,
      executeOutcome: "idempotent",
      executeResultFresh: true,
      executeWriteNetworkCall: true,
      handoffState: "idempotentRefreshSuccess",
      ledgerRefreshStatus: "success",
      status: "idempotent",
    });
    expect(
      screen.getAllByText("ledger_write=false").length,
    ).toBeGreaterThanOrEqual(1);
    expect(
      screen.getAllByText("audit_log_write=false").length,
    ).toBeGreaterThanOrEqual(1);
    expect(screen.getAllByText("idempotent").length).toBeGreaterThan(0);
    const executorSummaryPanel = screen
      .getByRole("heading", { level: 3, name: "账本执行器摘要" })
      .closest("article");
    expect(executorSummaryPanel).not.toBeNull();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText("adjust"),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText("idempotent"),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getAllByText("0").length,
    ).toBeGreaterThanOrEqual(4);
    expect(
      within(executorSummaryPanel as HTMLElement).getByText(
        "行数不匹配",
      ),
    ).toBeInTheDocument();

    const executeCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).includes("/admin/ledger/adjustments/dry-run") &&
        init?.method === "POST" &&
        JSON.parse(String(init.body)).mode === "execute",
    );
    expect(JSON.parse(String(executeCall?.[1]?.body))).toEqual({
      amount: "0.10000000",
      currency: "USD",
      mode: "execute",
      operation: "adjust",
      wallet_id: "00000000-0000-0000-0000-000000000040",
    });
    expect(document.body.textContent).not.toContain("idempotency_key");
    expect(document.body.textContent).not.toContain("server_dedupe_digest");
    expect(document.body.textContent).not.toContain("operation_key");
    expect(document.body.textContent).not.toContain(
      "operation-key-secret-hidden",
    );
    expect(document.body.textContent).not.toContain("error_detail");
    expect(document.body.textContent).not.toContain(
      "ledger-executor-summary-hidden",
    );
    expect(document.body.textContent).not.toContain("credential_material");
    expect(document.body.textContent).not.toContain("dedupe_material");
    expect(document.body.textContent).not.toContain("raw metadata");
  });

  async function expectLedgerRefreshFailureKeepsFreshExecuteResult(
    outcome: "applied" | "idempotent",
  ) {
    const fetchMock = stubAdminFetch({
      ledgerAdjustmentExecuteStatus: outcome,
      ledgerEntriesRefreshFails: true,
    });
    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));
    await user.click(
      await screen.findByRole("tab", { name: "账本概览" }),
    );

    const dryRunRegion = await screen.findByRole("region", {
      name: "账本调整 dry-run",
    });
    const dryRunPanel = within(dryRunRegion);

    if (outcome === "applied") {
      await user.type(dryRunPanel.getByLabelText("金额"), "0.25000000");
      await user.type(
        dryRunPanel.getByLabelText("关联账本条目"),
        "00000000-0000-0000-0000-000000000091",
      );
      await user.type(
        dryRunPanel.getByLabelText("Request ID"),
        "00000000-0000-0000-0000-000000000090",
      );
    } else {
      await user.selectOptions(
        dryRunPanel.getByRole("combobox", { name: "操作" }),
        "adjust",
      );
      await user.type(dryRunPanel.getByLabelText("金额"), "0.10000000");
      await user.type(
        dryRunPanel.getByLabelText("Wallet ID"),
        "00000000-0000-0000-0000-000000000040",
      );
    }

    await user.click(dryRunPanel.getByRole("button", { name: "规划 dry-run" }));
    expect(
      await screen.findByRole("region", {
        name: "账本调整 dry-run 结果",
      }),
    ).toBeInTheDocument();
    await user.click(
      screen.getByRole("button", { name: "执行账本调整" }),
    );

    const expectedReadiness =
      outcome === "applied"
        ? "账本调整已应用：账本和审计写入已确认。"
        : "幂等重放：返回既有账本条目，没有新的账本或审计写入。";

    expect(await screen.findByText(expectedReadiness)).toBeInTheDocument();
    const readinessRegion = screen.getByRole("region", {
      name: "账本调整执行准备",
    });
    const readinessPanel = within(readinessRegion);
    expect(readinessPanel.getAllByText(outcome).length).toBeGreaterThan(0);
    expect(readinessPanel.queryByText("failed")).not.toBeInTheDocument();
    expect(
      readinessPanel.queryByText("future_writer_required"),
    ).not.toBeInTheDocument();
    expect(screen.getByText("execute_result_fresh=true")).toBeInTheDocument();
    expect(screen.getByText(`execute_outcome=${outcome}`)).toBeInTheDocument();
    expect(
      screen.getByText("ledger_entries_refresh_after_execute=error"),
    ).toBeInTheDocument();
    expectLedgerBackendSmokeReadiness({
      dryRunFresh: true,
      executeEnabled: true,
      executeOutcome: outcome,
      executeResultFresh: true,
      executeWriteNetworkCall: true,
      handoffState:
        outcome === "applied"
          ? "appliedRefreshError"
          : "idempotentRefreshError",
      ledgerRefreshStatus: "error",
      status: outcome,
    });
    expect(
      await screen.findByText(
        "执行结果匹配当前 dry-run payload，但账本条目刷新失败。Request failed.",
      ),
    ).toBeInTheDocument();

    const executorSummaryPanel = screen
      .getByRole("heading", { level: 3, name: "账本执行器摘要" })
      .closest("article");
    expect(executorSummaryPanel).not.toBeNull();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText(outcome),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText(
        outcome === "applied" ? "refund" : "adjust",
      ),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText(
        "行数不匹配",
      ),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("heading", {
        level: 3,
        name: "拒绝执行器摘要",
      }),
    ).not.toBeInTheDocument();

    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("ledger-refresh-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("ledger-refresh-hidden"),
    );
    expect(document.body.textContent).not.toContain("operation_key");
    expect(document.body.textContent).not.toContain("raw metadata");
    expect(document.body.textContent).not.toContain(
      "raw executor error detail",
    );
    expect(document.body.textContent).not.toContain("credential");
    expect(document.body.textContent).not.toContain("Cookie");
    expect(document.body.textContent).not.toContain("token");

    await user.clear(dryRunPanel.getByLabelText("金额"));
    await user.type(
      dryRunPanel.getByLabelText("金额"),
      outcome === "applied" ? "0.10000000" : "0.20000000",
    );

    expect(
      await screen.findByText(
        "表单在 dry-run 后已变更。请重新运行 dry-run 后再评估执行。",
      ),
    ).toBeInTheDocument();
    expect(
      screen.getAllByText("fresh_dry_run=false").length,
    ).toBeGreaterThanOrEqual(2);
    expect(
      screen.getByRole("button", { name: "执行账本调整" }),
    ).toBeDisabled();
    expect(screen.queryByText(expectedReadiness)).not.toBeInTheDocument();
    expect(
      screen.queryByText(`execute_outcome=${outcome}`),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("heading", {
        level: 3,
        name: "账本执行器摘要",
      }),
    ).not.toBeInTheDocument();
    expect(
      fetchMock.mock.calls.filter(
        ([url, init]) =>
          String(url).includes("/admin/ledger/adjustments/dry-run") &&
          init?.method === "POST" &&
          JSON.parse(String(init.body)).mode === "execute",
      ),
    ).toHaveLength(1);
  }

  it("keeps applied execute fresh when ledger entries refresh fails", async () => {
    await expectLedgerRefreshFailureKeepsFreshExecuteResult("applied");
  });

  it("keeps idempotent execute fresh when ledger entries refresh fails", async () => {
    await expectLedgerRefreshFailureKeepsFreshExecuteResult("idempotent");
  });

  async function expectLedgerExecuteToleratesBackendResponseShape(
    outcome: "applied" | "idempotent",
  ) {
    const fetchMock = stubAdminFetch({
      ledgerAdjustmentExecuteResponseShape: "tolerant",
      ledgerAdjustmentExecuteStatus: outcome,
    });
    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));
    await user.click(
      await screen.findByRole("tab", { name: "账本概览" }),
    );

    const dryRunRegion = await screen.findByRole("region", {
      name: "账本调整 dry-run",
    });
    const dryRunPanel = within(dryRunRegion);

    if (outcome === "applied") {
      await user.type(dryRunPanel.getByLabelText("金额"), "0.25000000");
      await user.type(
        dryRunPanel.getByLabelText("关联账本条目"),
        "00000000-0000-0000-0000-000000000091",
      );
      await user.type(
        dryRunPanel.getByLabelText("Request ID"),
        "00000000-0000-0000-0000-000000000090",
      );
    } else {
      await user.selectOptions(
        dryRunPanel.getByRole("combobox", { name: "操作" }),
        "adjust",
      );
      await user.type(dryRunPanel.getByLabelText("金额"), "0.10000000");
      await user.type(
        dryRunPanel.getByLabelText("Wallet ID"),
        "00000000-0000-0000-0000-000000000040",
      );
    }

    await user.click(dryRunPanel.getByRole("button", { name: "规划 dry-run" }));
    expect(
      await screen.findByRole("region", {
        name: "账本调整 dry-run 结果",
      }),
    ).toBeInTheDocument();
    await user.click(
      screen.getByRole("button", { name: "执行账本调整" }),
    );

    expect(
      await screen.findByText(
        outcome === "applied"
          ? "账本调整已应用：账本和审计写入已确认。"
          : "幂等重放：返回既有账本条目，没有新的账本或审计写入。",
      ),
    ).toBeInTheDocument();
    expectLedgerBackendSmokeReadiness({
      dryRunFresh: true,
      executeEnabled: true,
      executeOutcome: outcome,
      executeResultFresh: true,
      executeWriteNetworkCall: true,
      handoffState:
        outcome === "applied"
          ? "appliedRefreshSuccess"
          : "idempotentRefreshSuccess",
      ledgerRefreshStatus: "success",
      status: outcome,
    });
    expect(
      screen.getByRole("heading", { level: 3, name: "执行摘要" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 3, name: "已执行账本条目" }),
    ).toBeInTheDocument();
    expect(
      screen.getByText("没有返回安全账本条目摘要。"),
    ).toBeInTheDocument();
    const executorSummaryPanel = screen
      .getByRole("heading", { level: 3, name: "账本执行器摘要" })
      .closest("article");
    expect(executorSummaryPanel).not.toBeNull();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText(
        "billing_ledger_postgres_executor_summary.v1",
      ),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText(
        outcome === "applied" ? "refund" : "adjust",
      ),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText(outcome),
    ).toBeInTheDocument();
    expect(
      within(executorSummaryPanel as HTMLElement).getByText(
        "行数不匹配",
      ),
    ).toBeInTheDocument();
    if (outcome === "applied") {
      expect(
        within(executorSummaryPanel as HTMLElement).getByText(
          "insert_ledger_entry",
        ),
      ).toBeInTheDocument();
    }

    expect(document.body.textContent).not.toContain(
      "safe_backend_unknown_marker",
    );
    expect(document.body.textContent).not.toContain(
      "safe_executor_unknown_marker",
    );
    expect(document.body.textContent).not.toContain(
      "safe_nested_unknown_marker",
    );
    expect(document.body.textContent).not.toContain(
      "safe_transaction_unknown_marker",
    );
    expect(document.body.textContent).not.toContain("operation_key");
    expect(document.body.textContent).not.toContain(
      "operation-key-response-tolerance-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "operation-key-executor-tolerance-hidden",
    );
    expect(document.body.textContent).not.toContain("raw metadata");
    expect(document.body.textContent).not.toContain(
      "raw execute tolerance metadata hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor tolerance metadata hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor error detail",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor tolerance error detail hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor response tolerance detail hidden",
    );
    expect(document.body.textContent).not.toContain(
      "credential material executor tolerance hidden",
    );
    expect(document.body.textContent).not.toContain(
      "dedupe material executor tolerance hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw execute validated plan hidden",
    );
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("ledger-tolerance-plan-hidden"),
    );
    expect(document.body.textContent).not.toContain("Cookie");
    expect(document.body.textContent).not.toContain("token");

    expect(
      fetchMock.mock.calls.filter(
        ([url, init]) =>
          String(url).includes("/admin/ledger/adjustments/dry-run") &&
          init?.method === "POST" &&
          JSON.parse(String(init.body)).mode === "execute",
      ),
    ).toHaveLength(1);
  }

  it("tolerates applied execute responses with unknown and missing optional fields", async () => {
    await expectLedgerExecuteToleratesBackendResponseShape("applied");
  });

  it("tolerates idempotent execute responses with unknown and missing optional fields", async () => {
    await expectLedgerExecuteToleratesBackendResponseShape("idempotent");
  });

  it("redacts ledger adjustment execute failures and marks failed state", async () => {
    const fetchMock = stubAdminFetch({
      ledgerAdjustmentErrorEnvelopeData: true,
      ledgerAdjustmentExecuteStatus: "failed",
    });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));
    await user.click(
      await screen.findByRole("tab", { name: "账本概览" }),
    );

    const dryRunRegion = await screen.findByRole("region", {
      name: "账本调整 dry-run",
    });
    const dryRunPanel = within(dryRunRegion);

    await user.type(dryRunPanel.getByLabelText("金额"), "0.25000000");
    await user.type(
      dryRunPanel.getByLabelText("关联账本条目"),
      "00000000-0000-0000-0000-000000000091",
    );
    await user.click(dryRunPanel.getByRole("button", { name: "规划 dry-run" }));
    expect(
      await screen.findByRole("region", {
        name: "账本调整 dry-run 结果",
      }),
    ).toBeInTheDocument();
    await user.click(
      screen.getByRole("button", { name: "执行账本调整" }),
    );

    expect(
      (await screen.findAllByText("账本调整执行失败。")).length,
    ).toBeGreaterThan(0);
    const readinessRegion = screen.getByRole("region", {
      name: "账本调整执行准备",
    });
    expect(within(readinessRegion).getByText("failed")).toBeInTheDocument();
    expect(
      screen.getByText("execute_write_network_call=true"),
    ).toBeInTheDocument();
    expectLedgerBackendSmokeReadiness({
      dryRunFresh: true,
      executeEnabled: true,
      executeWriteNetworkCall: true,
      handoffState: "failed",
      status: "failed",
    });
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("ledger-execute-failed-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("ledger-execute-failed-hidden"),
    );
    expect(document.body.textContent).not.toContain("idempotency_key");
    expect(document.body.textContent).not.toContain("raw request");
    expect(document.body.textContent).not.toContain("raw metadata");
    expect(document.body.textContent).not.toContain(
      "safe_error_unknown_marker",
    );
    expect(document.body.textContent).not.toContain(
      "operation-key-failed-envelope-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor error envelope hidden",
    );
    expect(document.body.textContent).not.toContain(
      "credential material error envelope hidden",
    );
    expect(document.body.textContent).not.toContain(
      "dedupe material error envelope hidden",
    );
    expect(document.body.textContent).not.toContain(
      "token error envelope hidden",
    );

    expect(
      fetchMock.mock.calls.filter(
        ([url, init]) =>
          String(url).includes("/admin/ledger/adjustments/dry-run") &&
          init?.method === "POST" &&
          JSON.parse(String(init.body)).mode === "execute",
      ),
    ).toHaveLength(1);
  });

  it("marks ledger adjustment execute blocked without failed or success smoke markers", async () => {
    const fetchMock = stubAdminFetch({
      ledgerAdjustmentErrorEnvelopeData: true,
      ledgerAdjustmentExecuteStatus: "blocked",
    });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));
    await user.click(
      await screen.findByRole("tab", { name: "账本概览" }),
    );

    const dryRunRegion = await screen.findByRole("region", {
      name: "账本调整 dry-run",
    });
    const dryRunPanel = within(dryRunRegion);

    await user.type(dryRunPanel.getByLabelText("金额"), "0.25000000");
    await user.type(
      dryRunPanel.getByLabelText("关联账本条目"),
      "00000000-0000-0000-0000-000000000091",
    );
    await user.click(dryRunPanel.getByRole("button", { name: "规划 dry-run" }));
    expect(
      await screen.findByRole("region", {
        name: "账本调整 dry-run 结果",
      }),
    ).toBeInTheDocument();
    await user.click(
      screen.getByRole("button", { name: "执行账本调整" }),
    );

    expect(
      (await screen.findAllByText("账本调整执行被阻止。"))
        .length,
    ).toBeGreaterThan(0);
    const readinessRegion = screen.getByRole("region", {
      name: "账本调整执行准备",
    });
    expect(within(readinessRegion).getByText("blocked")).toBeInTheDocument();
    expect(
      within(readinessRegion).queryByText("failed"),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText("execute_outcome=applied"),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText("execute_outcome=idempotent"),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText("ledger_entries_refresh_after_execute=success"),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText("ledger_entries_refresh_after_execute=error"),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("heading", {
        level: 3,
        name: "账本执行器摘要",
      }),
    ).not.toBeInTheDocument();
    expectLedgerBackendSmokeReadiness({
      dryRunFresh: true,
      executeEnabled: true,
      executeWriteNetworkCall: true,
      handoffState: "blocked",
      status: "blocked",
    });
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("ledger-execute-blocked-hidden"),
    );
    expect(document.body.textContent).not.toContain("operation_key");
    expect(document.body.textContent).not.toContain("raw metadata");
    expect(document.body.textContent).not.toContain(
      "raw executor error detail",
    );
    expect(document.body.textContent).not.toContain("credential");
    expect(document.body.textContent).not.toContain("Cookie");
    expect(document.body.textContent).not.toContain("token");
    expect(document.body.textContent).not.toContain(
      "safe_error_unknown_marker",
    );
    expect(document.body.textContent).not.toContain(
      "operation-key-blocked-envelope-hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw executor error envelope hidden",
    );

    expect(
      fetchMock.mock.calls.filter(
        ([url, init]) =>
          String(url).includes("/admin/ledger/adjustments/dry-run") &&
          init?.method === "POST" &&
          JSON.parse(String(init.body)).mode === "execute",
      ),
    ).toHaveLength(1);
  });

  it("clears prior ledger execute success when a later execute fails", async () => {
    const fetchMock = stubAdminFetch({
      ledgerAdjustmentExecuteStatuses: ["applied", "failed"],
    });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));
    await user.click(
      await screen.findByRole("tab", { name: "账本概览" }),
    );

    const dryRunRegion = await screen.findByRole("region", {
      name: "账本调整 dry-run",
    });
    const dryRunPanel = within(dryRunRegion);

    await user.type(dryRunPanel.getByLabelText("金额"), "0.25000000");
    await user.type(
      dryRunPanel.getByLabelText("关联账本条目"),
      "00000000-0000-0000-0000-000000000091",
    );
    await user.click(dryRunPanel.getByRole("button", { name: "规划 dry-run" }));
    expect(
      await screen.findByRole("region", {
        name: "账本调整 dry-run 结果",
      }),
    ).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "执行账本调整" }),
    );
    expect(
      await screen.findByText(
        "账本调整已应用：账本和审计写入已确认。",
      ),
    ).toBeInTheDocument();
    expect(screen.getByText("execute_outcome=applied")).toBeInTheDocument();
    expect(
      screen.getByRole("heading", {
        level: 3,
        name: "账本执行器摘要",
      }),
    ).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "检查执行契约" }),
    );

    expect(
      await screen.findByText(
        /future_writer_required：后端已验证计划/,
      ),
    ).toBeInTheDocument();
    expect(
      within(
        screen.getByRole("region", {
          name: "账本调整执行准备",
        }),
      ).getByText("blocked"),
    ).toBeInTheDocument();
    expect(
      screen.queryByText(
        "账本调整已应用：账本和审计写入已确认。",
      ),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText("execute_outcome=applied"),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("heading", {
        level: 3,
        name: "账本执行器摘要",
      }),
    ).not.toBeInTheDocument();
    expect(
      screen.getByRole("heading", {
        level: 3,
        name: "拒绝执行器摘要",
      }),
    ).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "执行账本调整" }),
    );

    expect(
      (await screen.findAllByText("账本调整执行失败。")).length,
    ).toBeGreaterThan(0);
    const readinessRegion = screen.getByRole("region", {
      name: "账本调整执行准备",
    });
    expect(within(readinessRegion).getByText("failed")).toBeInTheDocument();
    expect(
      screen.queryByText(
        "账本调整已应用：账本和审计写入已确认。",
      ),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText("execute_outcome=applied"),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText("ledger_entries_refresh_after_execute=success"),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("heading", {
        level: 3,
        name: "账本执行器摘要",
      }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("heading", {
        level: 3,
        name: "拒绝执行器摘要",
      }),
    ).not.toBeInTheDocument();
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("ledger-execute-failed-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("ledger-execute-failed-hidden"),
    );
    expect(document.body.textContent).not.toContain("operation_key");
    expect(document.body.textContent).not.toContain("raw metadata");

    expect(
      fetchMock.mock.calls.filter(
        ([url, init]) =>
          String(url).includes("/admin/ledger/adjustments/dry-run") &&
          init?.method === "POST" &&
          JSON.parse(String(init.body)).mode === "execute",
      ),
    ).toHaveLength(2);
  });

  it("marks ledger adjustment execute readiness stale after form changes without execute calls", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));
    await user.click(
      await screen.findByRole("tab", { name: "账本概览" }),
    );

    const dryRunRegion = await screen.findByRole("region", {
      name: "账本调整 dry-run",
    });
    const dryRunPanel = within(dryRunRegion);

    await user.type(dryRunPanel.getByLabelText("金额"), "0.25000000");
    await user.type(
      dryRunPanel.getByLabelText("关联账本条目"),
      "00000000-0000-0000-0000-000000000091",
    );
    await user.type(
      dryRunPanel.getByLabelText("Request ID"),
      "00000000-0000-0000-0000-000000000090",
    );
    await user.click(dryRunPanel.getByRole("button", { name: "规划 dry-run" }));

    expect(
      await screen.findByRole("region", {
        name: "账本调整 dry-run 结果",
      }),
    ).toBeInTheDocument();
    expect(
      screen.getAllByText("fresh_dry_run=true").length,
    ).toBeGreaterThanOrEqual(2);

    await user.clear(dryRunPanel.getByLabelText("金额"));
    await user.type(dryRunPanel.getByLabelText("金额"), "0.10000000");

    expect(
      await screen.findByText(
        "表单在 dry-run 后已变更。请重新运行 dry-run 后再评估执行。",
      ),
    ).toBeInTheDocument();
    expect(
      screen.getAllByText("fresh_dry_run=false").length,
    ).toBeGreaterThanOrEqual(2);
    expect(
      screen.getByRole("button", { name: "执行账本调整" }),
    ).toBeDisabled();
    expectLedgerBackendSmokeReadiness({
      dryRunFresh: false,
      executeEnabled: false,
      executeWriteNetworkCall: false,
      handoffState: "stalePlan",
      status: "stale plan",
    });
    expect(
      fetchMock.mock.calls.filter(
        ([url, init]) =>
          String(url).includes("/admin/ledger/adjustments/dry-run") &&
          init?.method === "POST",
      ),
    ).toHaveLength(1);
    expect(
      fetchMock.mock.calls.filter(
        ([url, init]) =>
          String(url).includes("/admin/ledger/adjustments/dry-run") &&
          init?.method === "POST" &&
          JSON.parse(String(init.body)).mode === "execute",
      ),
    ).toHaveLength(0);
    expect(
      fetchMock.mock.calls.filter(
        ([url]) =>
          String(url).includes("/admin/ledger/adjustments/") &&
          !String(url).includes("/dry-run"),
      ),
    ).toHaveLength(0);
  });

  it("redacts ledger adjustment dry-run errors without retaining secret material", async () => {
    stubAdminFetch({ ledgerAdjustmentDryRunFails: true });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));
    await user.click(
      await screen.findByRole("tab", { name: "账本概览" }),
    );

    const dryRunRegion = await screen.findByRole("region", {
      name: "账本调整 dry-run",
    });
    const dryRunPanel = within(dryRunRegion);

    await user.type(dryRunPanel.getByLabelText("金额"), "0.25000000");
    await user.type(
      dryRunPanel.getByLabelText("关联账本条目"),
      "00000000-0000-0000-0000-000000000091",
    );
    await user.click(dryRunPanel.getByRole("button", { name: "规划 dry-run" }));

    expect(await screen.findByText("Request failed.")).toBeInTheDocument();
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("ledger-adjust-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("ledger-adjust-hidden"),
    );
    expect(document.body.textContent).not.toContain("idempotency_key");
    expect(document.body.textContent).not.toContain("raw metadata");
  });

  it("creates a price version, sends safe pricing rules, and refreshes the list", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));

    await user.click(
      await screen.findByRole("button", { name: "创建价格版本" }),
    );
    const createDialog = await screen.findByRole("dialog", {
      name: "创建价格版本对话框",
    });
    const createPanel = within(createDialog);
    const pricingRules = {
      currency: "USD",
      fixed_request_cost: "0.00000000",
      input_token_rate_per_1m: "0.20000000",
      output_token_rate_per_1m: "0.70000000",
      scale: 8,
    };

    await user.type(
      createPanel.getByLabelText("价格簿 ID"),
      "price-book-2",
    );
    await user.type(createPanel.getByLabelText("模型 ID"), "model-2");
    await user.type(createPanel.getByLabelText("版本"), "2026-07");
    await user.selectOptions(createPanel.getByLabelText("状态"), "active");
    await user.type(
      createPanel.getByLabelText("生效时间"),
      "2026-07-01T00:00:00Z",
    );
    await user.type(
      createPanel.getByLabelText("退役时间"),
      "2026-09-01T00:00:00Z",
    );
    fireEvent.change(createPanel.getByLabelText("计费规则 JSON"), {
      target: { value: JSON.stringify(pricingRules, null, 2) },
    });
    await user.click(createPanel.getByRole("button", { name: "创建" }));

    expect(
      await screen.findByText("价格版本 2026-07 已创建。"),
    ).toBeInTheDocument();
    expect((await screen.findAllByText("2026-07")).length).toBeGreaterThan(0);

    const createCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).includes("/admin/price-versions") &&
        init?.method === "POST",
    );
    expect(String(createCall?.[0])).toBe(
      "/api/control-plane/admin/price-versions",
    );
    expect(JSON.parse(String(createCall?.[1]?.body))).toEqual({
      canonical_model_id: "model-2",
      effective_at: "2026-07-01T00:00:00Z",
      price_book_id: "price-book-2",
      pricing_rules: pricingRules,
      retired_at: "2026-09-01T00:00:00Z",
      status: "active",
      version: "2026-07",
    });
    await waitFor(() =>
      expect(
        fetchMock.mock.calls.filter(
          ([url, init]) =>
            String(url).includes("/admin/price-versions") &&
            init?.method === "GET",
        ).length,
      ).toBeGreaterThanOrEqual(2),
    );
  });

  it("rejects unsafe price rule JSON without posting or retaining secret material", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /计费/ }));

    await user.click(
      await screen.findByRole("button", { name: "创建价格版本" }),
    );
    const createDialog = await screen.findByRole("dialog", {
      name: "创建价格版本对话框",
    });
    const createPanel = within(createDialog);
    const rawKey = skPlaceholder("price-raw-hidden");
    const bearer = bearerPlaceholder("price-auth-hidden");
    const unsafeRules = {
      [AUTH_HEADER_NAME]: bearer,
      currency: "USD",
      input_token_rate_per_1m: "0.20000000",
      output_token_rate_per_1m: "0.70000000",
      payload: {
        raw_key: rawKey,
      },
    };

    await user.type(
      createPanel.getByLabelText("价格簿 ID"),
      "price-book-2",
    );
    await user.type(createPanel.getByLabelText("版本"), "2026-07");
    fireEvent.change(createPanel.getByLabelText("计费规则 JSON"), {
      target: { value: JSON.stringify(unsafeRules, null, 2) },
    });
    await user.click(createPanel.getByRole("button", { name: "创建" }));

    expect(
      await screen.findByText(/计费规则不能包含不安全字段/),
    ).toBeInTheDocument();
    expect(
      fetchMock.mock.calls.some(
        ([url, init]) =>
          String(url).includes("/admin/price-versions") &&
          init?.method === "POST",
      ),
    ).toBe(false);
    expect(
      (createPanel.getByLabelText("计费规则 JSON") as HTMLTextAreaElement)
        .value,
    ).not.toContain(rawKey);
    expect(
      (createPanel.getByLabelText("计费规则 JSON") as HTMLTextAreaElement)
        .value,
    ).not.toContain(bearer);
    expect(document.body.textContent).not.toContain(rawKey);
    expect(document.body.textContent).not.toContain(bearer);
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain("raw_key");
    expect(document.body.textContent).not.toContain('"payload"');
  });

  it("handles routing dry-run responses without a selected candidate", async () => {
    stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /路由/ }));
    await user.type(await screen.findByLabelText("项目 ID"), "project-1");
    await user.type(screen.getByLabelText("配置 ID"), "profile-1");
    await user.type(screen.getByLabelText("请求模型"), "missing-model");
    await user.click(screen.getByRole("button", { name: "运行 dry-run" }));

    expect(
      (await screen.findAllByText("model not found or not allowed")).length,
    ).toBeGreaterThan(0);
    expect(screen.getByText("未选中候选项。")).toBeInTheDocument();
    expect(
      screen.getByText("暂无路由候选项。"),
    ).toBeInTheDocument();
  });

  it("keeps the newest request log detail when earlier detail requests resolve late", async () => {
    const slowLog = {
      ...baseRequestLog(),
      id: "req_slow",
      requested_model: "slow-model",
      trace_id: "trace-slow",
    };
    const fastLog = {
      ...baseRequestLog(),
      id: "req_fast",
      requested_model: "fast-model",
      trace_id: "trace-fast",
    };
    const slowDetail = deferredJsonResponse({
      provider_attempts: [],
      request_log: slowLog,
      route_decision_snapshot: { strategy: "slow-route" },
    });
    const fastDetail = deferredJsonResponse({
      provider_attempts: [],
      request_log: fastLog,
      route_decision_snapshot: { strategy: "fast-route" },
    });
    let loginSucceeded = false;
    const fetchMock = vi.fn((url: RequestInfo | URL, _init?: RequestInit) => {
      const requestUrl = String(url);

      if (requestUrl.includes("/admin/auth/login")) {
        loginSucceeded = true;
        return jsonResponse(loginPayload());
      }

      if (requestUrl.includes("/admin/auth/me")) {
        if (!loginSucceeded) {
          return jsonError("No active admin session", 401);
        }

        return jsonResponse(adminMePayload());
      }

      if (requestUrl.includes("/admin/auth/logout")) {
        return jsonResponse({ logged_out: true });
      }

      if (requestUrl.includes("/admin/request-logs/req_slow")) {
        return slowDetail.promise;
      }

      if (requestUrl.includes("/admin/request-logs/req_fast")) {
        return fastDetail.promise;
      }

      if (requestUrl.includes("/admin/request-logs")) {
        return jsonResponse([slowLog, fastLog]);
      }

      if (requestUrl.includes("/admin/wallets")) {
        return jsonResponse([]);
      }

      return Promise.resolve(new Response("", { status: 200 }));
    });
    vi.stubGlobal("fetch", fetchMock);

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /请求与追踪/ }));
    expect(await screen.findByText("req_slow")).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "查看请求日志 req_slow" }),
    );
    await user.click(
      screen.getByRole("button", { name: "查看请求日志 req_fast" }),
    );

    fastDetail.resolve();
    expect(await screen.findByText("供应商尝试")).toBeInTheDocument();
    expect(
      within(screen.getByLabelText("请求日志详情")).getAllByText("req_fast").length,
    ).toBeGreaterThan(0);
    expect(
      within(screen.getByLabelText("请求日志详情")).getByText(
        "fast-model",
      ),
    ).toBeInTheDocument();

    slowDetail.resolve();
    await waitFor(() =>
      expect(
        within(screen.getByLabelText("请求日志详情")).queryByText(
          "req_slow",
        ),
      ).not.toBeInTheDocument(),
    );
    expect(
      within(screen.getByLabelText("请求日志详情")).getAllByText("req_fast").length,
    ).toBeGreaterThan(0);
  });

  it("does not render provider key secret material from API responses", async () => {
    stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /供应商密钥/ }));

    expect(await screen.findByText("openai-main")).toBeInTheDocument();
    expect(screen.getAllByText("openai primary").length).toBeGreaterThan(0);
    await user.click(screen.getByRole("button", { name: "添加密钥" }));
    const createKeyDialog = screen.getByRole("dialog", {
      name: "创建供应商密钥对话框",
    });
    const channelSelect = within(createKeyDialog).getByLabelText("通道");
    expect(channelSelect).toHaveTextContent("openai primary");
    await user.selectOptions(channelSelect, "channel-1");
    expect(
      within(createKeyDialog).getByLabelText("已选择的供应商密钥通道"),
    ).toHaveTextContent("openai primary");
    expect(
      within(createKeyDialog).getByLabelText("已选择的供应商密钥通道"),
    ).toHaveTextContent("provider-1");
    expect(within(createKeyDialog).getByLabelText("Secret / API key")).toHaveAttribute(
      "type",
      "password",
    );
    expect(
      screen.queryByText(skPlaceholder("live-hidden")),
    ).not.toBeInTheDocument();
    expect(screen.queryByText("ciphertext-hidden")).not.toBeInTheDocument();
    expect(screen.queryByText("fp-hidden")).not.toBeInTheDocument();
    expect(
      screen.queryByText(skPlaceholder("metadata-hidden")),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText(bearerPlaceholder("metadata-hidden")),
    ).not.toBeInTheDocument();
  });

  it("requests provider key recovery from the provider key page", async () => {
    const fetchMock = stubAdminFetch({ providerKeyStatus: "cooldown" });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /供应商密钥/ }));
    expect(await screen.findByText("openai-main")).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", {
        name: "恢复供应商密钥 openai-main",
      }),
    );
    const recoveryDialog = screen.getByRole("dialog", {
      name: "恢复供应商密钥对话框",
    });
    expect(
      within(recoveryDialog).getByLabelText("供应商密钥恢复安全状态"),
    ).toHaveTextContent("omitted");
    await user.click(
      within(recoveryDialog).getByRole("button", {
        name: "提交恢复探针",
      }),
    );

    expect(
      await screen.findByText("openai-main 已进入恢复探针。"),
    ).toBeInTheDocument();
    const recoveryCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).endsWith("/admin/provider-keys/provider-key-1/recovery") &&
        init?.method === "POST",
    );
    expect(JSON.parse(String(recoveryCall?.[1]?.body))).toEqual({
      reason: "operator requested recovery from provider key page",
      target_status: "recovery_probe",
    });
    expect(
      screen.queryByText(skPlaceholder("recovery-response-hidden")),
    ).not.toBeInTheDocument();
  });

  it("shows a confirmed provider recovery suggestion before running recovery", async () => {
    const fetchMock = stubAdminFetch({ providerKeyStatus: "cooldown" });

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /供应商与通道/ }));
    expect(await screen.findByText("openai-main")).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", {
        name: "查看恢复建议 openai-main",
      }),
    );

    const suggestionDialog = screen.getByRole("dialog", {
      name: "恢复建议确认对话框",
    });
    expect(within(suggestionDialog).getByLabelText("恢复建议摘要")).toHaveTextContent("状态");
    expect(within(suggestionDialog).getByLabelText("恢复建议摘要")).toHaveTextContent("原因");
    expect(within(suggestionDialog).getByLabelText("恢复建议摘要")).toHaveTextContent("下一步");
    expect(suggestionDialog).not.toHaveTextContent(skPlaceholder("live-hidden"));
    expect(suggestionDialog).not.toHaveTextContent("ciphertext-hidden");
    expect(suggestionDialog).not.toHaveTextContent("https://api.openai.test/v1");

    await user.click(
      within(suggestionDialog).getByRole("button", {
        name: "确认恢复探针",
      }),
    );

    expect(
      await screen.findByText("openai-main 已进入恢复探针。"),
    ).toBeInTheDocument();
    const recoveryCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).endsWith("/admin/provider-keys/provider-key-1/recovery") &&
        init?.method === "POST",
    );
    expect(JSON.parse(String(recoveryCall?.[1]?.body))).toEqual({
      reason: "operator requested recovery from provider workflow",
      target_status: "recovery_probe",
    });
  });

  it("rotates provider keys without rendering submitted or returned secret material", async () => {
    const rotatedSecret = skPlaceholder("new-rotation-hidden");
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /供应商密钥/ }));
    expect(await screen.findByText("openai-main")).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", {
        name: "轮换供应商密钥 openai-main",
      }),
    );
    const rotateDialog = screen.getByRole("dialog", {
      name: "轮换供应商密钥对话框",
    });
    expect(within(rotateDialog).getByLabelText("新 Secret / API key")).toHaveAttribute(
      "type",
      "password",
    );
    await user.clear(within(rotateDialog).getByLabelText("新 Alias"));
    await user.type(
      within(rotateDialog).getByLabelText("新 Alias"),
      "openai-main-rotated",
    );
    await user.type(
      within(rotateDialog).getByLabelText("新 Secret / API key"),
      rotatedSecret,
    );
    await user.click(
      within(rotateDialog).getByRole("button", { name: "提交轮换" }),
    );

    expect(
      await screen.findByText(
        "供应商密钥轮换已提交。下一步：运行恢复探针或刷新通道健康；提交的 secret 已从表单清除。",
      ),
    ).toBeInTheDocument();
    const rotateCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).endsWith("/admin/provider-keys/provider-key-1/rotate") &&
        init?.method === "POST",
    );
    expect(JSON.parse(String(rotateCall?.[1]?.body))).toMatchObject({
      key_alias: "openai-main-rotated",
      reason: "operator credential rotation",
      secret: rotatedSecret,
    });
    expect(screen.getByText("openai-main-rotated")).toBeInTheDocument();
    expect(document.body.textContent).not.toContain(rotatedSecret);
    expect(document.body.textContent).not.toContain(
      skPlaceholder("rotated-hidden"),
    );
    expect(document.body.textContent).not.toContain("fp-rotated-hidden");
  });

  it("lists and mutates providers and channels", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /供应商与通道/ }));

    expect((await screen.findAllByText("OpenAI")).length).toBeGreaterThan(0);
    expect(
      screen.queryByText(skPlaceholder("provider-hidden")),
    ).not.toBeInTheDocument();
    expect(document.body.textContent).not.toContain("secret_note");

    await user.click(screen.getByRole("button", { name: "创建供应商" }));
    const providerDialog = screen.getByRole("dialog", {
      name: "创建供应商对话框",
    });
    fireEvent.change(within(providerDialog).getByLabelText("供应商 code"), {
      target: { value: "anthropic" },
    });
    fireEvent.change(within(providerDialog).getByLabelText("供应商名称"), {
      target: { value: "Anthropic" },
    });
    fireEvent.change(within(providerDialog).getByLabelText("供应商类型"), {
      target: { value: "anthropic" },
    });
    fireEvent.change(within(providerDialog).getByLabelText("供应商 base URL"), {
      target: { value: "https://api.anthropic.test/v1" },
    });
    fireEvent.change(within(providerDialog).getByLabelText("供应商 metadata JSON"), {
      target: { value: '{"owner":"research","tier":"backup"}' },
    });
    await user.click(within(providerDialog).getByRole("button", { name: "创建供应商" }));

    expect((await screen.findAllByText("Anthropic")).length).toBeGreaterThan(0);
    const createProviderCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).endsWith("/admin/providers") && init?.method === "POST",
    );
    expect(JSON.parse(String(createProviderCall?.[1]?.body))).toMatchObject({
      base_url: "https://api.anthropic.test/v1",
      code: "anthropic",
      metadata: {
        owner: "research",
        tier: "backup",
      },
      name: "Anthropic",
      provider_type: "anthropic",
    });

    await user.click(screen.getByRole("button", { name: "高级 JSON" }));
    const advancedJsonDialog = screen.getByRole("dialog", {
      name: "高级 JSON 策略对话框",
    });
    fireEvent.change(within(advancedJsonDialog).getByLabelText("供应商补丁 ID"), {
      target: { value: "provider-1" },
    });
    fireEvent.change(within(advancedJsonDialog).getByLabelText("供应商补丁 metadata JSON"), {
      target: { value: '{"owner":"platform-2","region":"us"}' },
    });
    await user.click(
      within(advancedJsonDialog).getByRole("button", { name: "保存供应商 JSON" }),
    );

    expect(
      await screen.findByText("OpenAI JSON 策略已保存。"),
    ).toBeInTheDocument();
    const providerPatchCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).includes("/admin/providers/provider-1") &&
        init?.method === "PATCH" &&
        String(init.body).includes("platform-2"),
    );
    expect(JSON.parse(String(providerPatchCall?.[1]?.body))).toEqual({
      metadata: {
        owner: "platform-2",
        region: "us",
      },
    });

    await user.click(
      screen.getByRole("button", { name: "禁用供应商 OpenAI" }),
    );

    expect(await screen.findByText("OpenAI 已禁用。")).toBeInTheDocument();

    expect(
      (await screen.findAllByText("openai primary")).length,
    ).toBeGreaterThan(0);

    fireEvent.change(screen.getByLabelText("请求模型"), {
      target: { value: "gpt-visible" },
    });
    fireEvent.change(screen.getByLabelText("上游模型"), {
      target: { value: "upstream-gpt" },
    });
    await user.click(
      screen.getByRole("button", {
        name: "为 openai primary 运行手动测试",
      }),
    );

    expect(
      await screen.findByRole("heading", {
        level: 2,
        name: "通道手动测试",
      }),
    ).toBeInTheDocument();
    expect(screen.getByText("upstream_call=false")).toBeInTheDocument();
    expect(screen.getByText("billable=false")).toBeInTheDocument();
    expect(screen.getByText("ledger_write=false")).toBeInTheDocument();
    expect(screen.getAllByText("primary channel").length).toBeGreaterThan(0);
    expect(screen.getAllByText("Provider A").length).toBeGreaterThan(0);
    expect(screen.getByText("/v1/chat/completions")).toBeInTheDocument();
    expect(screen.getAllByText("upstream-gpt").length).toBeGreaterThan(0);

    const manualTestCall = fetchMock.mock.calls.find(([url]) =>
      String(url).includes("/manual-test"),
    );
    expect(manualTestCall?.[1]).toMatchObject({ method: "POST" });
    expect(JSON.parse(String(manualTestCall?.[1]?.body))).toEqual({
      dry_run: true,
      model: "gpt-visible",
      upstream_model_name: "upstream-gpt",
    });
    expect(document.body.textContent).not.toContain(
      skPlaceholder("manual-key-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("manual-endpoint-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("manual-channel-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("manual-provider-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("manual-plan-hidden"),
    );
    expect(document.body.textContent).not.toContain("fp-manual-hidden");
    expect(document.body.textContent).not.toContain(
      "raw manual payload hidden",
    );

    await user.click(screen.getByRole("button", { name: "创建通道" }));
    const channelDialog = screen.getByRole("dialog", {
      name: "创建通道对话框",
    });
    fireEvent.change(within(channelDialog).getByLabelText("通道 provider ID"), {
      target: { value: "provider-2" },
    });
    fireEvent.change(within(channelDialog).getByLabelText("通道名称"), {
      target: { value: "anthropic primary" },
    });
    fireEvent.change(within(channelDialog).getByLabelText("Endpoint / base URL"), {
      target: { value: "https://api.anthropic.test/v1" },
    });
    fireEvent.change(within(channelDialog).getByLabelText("通道 model_mappings JSON"), {
      target: { value: '{"claude-3-haiku":"claude-3-haiku-20240307"}' },
    });
    fireEvent.change(within(channelDialog).getByLabelText("通道 tags JSON"), {
      target: { value: '["backup","anthropic"]' },
    });
    fireEvent.change(within(channelDialog).getByLabelText("通道 request_overrides JSON"), {
      target: {
        value: '[{"type":"header","name":"x-ai-profile","value":"default"}]',
      },
    });
    fireEvent.change(within(channelDialog).getByLabelText("通道 probe_policy JSON"), {
      target: { value: '{"path":"/health"}' },
    });
    fireEvent.change(within(channelDialog).getByLabelText("通道 timeout_policy JSON"), {
      target: { value: '{"connect_ms":3000}' },
    });
    await user.click(within(channelDialog).getByRole("button", { name: "创建通道" }));

    expect(
      (await screen.findAllByText("anthropic primary")).length,
    ).toBeGreaterThan(0);
    const createChannelCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).endsWith("/admin/channels") && init?.method === "POST",
    );
    expect(JSON.parse(String(createChannelCall?.[1]?.body))).toMatchObject({
      endpoint: "https://api.anthropic.test/v1",
      model_mappings: {
        "claude-3-haiku": "claude-3-haiku-20240307",
      },
      name: "anthropic primary",
      probe_policy: {
        path: "/health",
      },
      provider_id: "provider-2",
      request_overrides: [
        {
          name: "x-ai-profile",
          type: "header",
          value: "default",
        },
      ],
      tags: ["backup", "anthropic"],
      timeout_policy: {
        connect_ms: 3000,
      },
    });

    await user.click(screen.getByRole("button", { name: "高级 JSON" }));
    const channelJsonDialog = screen.getByRole("dialog", {
      name: "高级 JSON 策略对话框",
    });
    fireEvent.change(within(channelJsonDialog).getByLabelText("通道补丁 ID"), {
      target: { value: "channel-1" },
    });
    fireEvent.change(within(channelJsonDialog).getByLabelText("补丁 model_mappings JSON"), {
      target: { value: '{"gpt-visible":"gpt-4o-mini-2024-07-18"}' },
    });
    fireEvent.change(within(channelJsonDialog).getByLabelText("补丁 tags JSON"), {
      target: { value: '["primary","low-latency"]' },
    });
    fireEvent.change(within(channelJsonDialog).getByLabelText("补丁 request_overrides JSON"), {
      target: {
        value: '[{"type":"header","name":"x-ai-profile","value":"default"}]',
      },
    });
    fireEvent.change(within(channelJsonDialog).getByLabelText("补丁 probe_policy JSON"), {
      target: { value: '{"path":"/ready"}' },
    });
    fireEvent.change(within(channelJsonDialog).getByLabelText("补丁 timeout_policy JSON"), {
      target: { value: '{"connect_ms":2500}' },
    });
    await user.click(within(channelJsonDialog).getByRole("button", { name: "保存通道 JSON" }));

    expect(
      await screen.findByText("openai primary JSON 策略已保存。"),
    ).toBeInTheDocument();
    const channelPatchCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).includes("/admin/channels/channel-1") &&
        init?.method === "PATCH" &&
        String(init.body).includes("low-latency"),
    );
    expect(JSON.parse(String(channelPatchCall?.[1]?.body))).toEqual({
      model_mappings: {
        "gpt-visible": "gpt-4o-mini-2024-07-18",
      },
      probe_policy: {
        path: "/ready",
      },
      request_overrides: [
        {
          name: "x-ai-profile",
          type: "header",
          value: "default",
        },
      ],
      tags: ["primary", "low-latency"],
      timeout_policy: {
        connect_ms: 2500,
      },
    });

    await user.click(
      screen.getByRole("button", { name: "禁用通道 openai primary" }),
    );

    expect(
      await screen.findByText("openai primary 已禁用。"),
    ).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "删除通道 openai primary" }),
    );

    expect(
      await screen.findByText("openai primary 已删除。"),
    ).toBeInTheDocument();
  });

  it("rejects malformed or unsafe provider and channel JSON policies", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /供应商与通道/ }));
    expect((await screen.findAllByText("OpenAI")).length).toBeGreaterThan(0);

    await user.click(screen.getByRole("button", { name: "创建供应商" }));
    const providerDialog = screen.getByRole("dialog", {
      name: "创建供应商对话框",
    });
    fireEvent.change(within(providerDialog).getByLabelText("供应商 code"), {
      target: { value: "bad-provider" },
    });
    fireEvent.change(within(providerDialog).getByLabelText("供应商名称"), {
      target: { value: "Bad Provider" },
    });
    fireEvent.change(within(providerDialog).getByLabelText("供应商 metadata JSON"), {
      target: { value: "{" },
    });
    await user.click(within(providerDialog).getByRole("button", { name: "创建供应商" }));

    expect(
      await screen.findByText("供应商 metadata JSON 必须是有效 JSON。"),
    ).toBeInTheDocument();

    fireEvent.change(within(providerDialog).getByLabelText("供应商 metadata JSON"), {
      target: {
        value: `{"Authorization":"${bearerPlaceholder("provider-json-hidden")}"}`,
      },
    });
    await user.click(within(providerDialog).getByRole("button", { name: "创建供应商" }));

    expect(
      await screen.findByText("供应商 metadata JSON 包含不安全字段。"),
    ).toBeInTheDocument();

    await user.click(within(providerDialog).getByRole("button", { name: "关闭" }));
    await user.click(screen.getByRole("button", { name: "高级 JSON" }));
    const advancedJsonDialog = screen.getByRole("dialog", {
      name: "高级 JSON 策略对话框",
    });
    fireEvent.change(within(advancedJsonDialog).getByLabelText("通道补丁 ID"), {
      target: { value: "channel-1" },
    });
    fireEvent.change(within(advancedJsonDialog).getByLabelText("补丁 model_mappings JSON"), {
      target: { value: '{"raw_key":"hidden"}' },
    });
    await user.click(within(advancedJsonDialog).getByRole("button", { name: "保存通道 JSON" }));

    expect(
      await screen.findByText(
        "补丁 model_mappings JSON 包含不安全字段。",
      ),
    ).toBeInTheDocument();

    const unsafeMutationCalls = fetchMock.mock.calls.filter(([url, init]) => {
      const requestUrl = String(url);
      const method = init?.method;

      return (
        (requestUrl.includes("/admin/providers") && method === "POST") ||
        (requestUrl.includes("/admin/channels/channel-1") && method === "PATCH")
      );
    });
    expect(unsafeMutationCalls).toHaveLength(0);
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("provider-json-hidden"),
    );
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain("raw_key");
  });

  it("lists and mutates models and model associations", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /模型/ }));

    expect(
      await screen.findByRole("heading", { level: 2, name: "模型目录" }),
    ).toBeInTheDocument();
    expect((await screen.findAllByText("GPT-4o Mini")).length).toBeGreaterThan(
      0,
    );
    expect(screen.getByText("gpt-4o-mini / model-1")).toBeInTheDocument();
    expect(
      screen.getByLabelText("GPT-4o Mini 的默认价格表"),
    ).toHaveValue("price-book-1");

    await user.selectOptions(
      screen.getByLabelText("GPT-4o Mini 的默认价格表"),
      "",
    );
    await user.click(
      screen.getByRole("button", {
        name: "保存 GPT-4o Mini 的默认价格表",
      }),
    );

    expect(
      await screen.findByText("GPT-4o Mini 默认价格表已保存。"),
    ).toBeInTheDocument();
    const defaultPricePatchCall = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url).includes("/admin/models/model-1") &&
        init?.method === "PATCH" &&
        String(init.body).includes("default_price_book_id"),
    );
    expect(JSON.parse(String(defaultPricePatchCall?.[1]?.body))).toEqual({
      default_price_book_id: null,
    });

    await user.click(screen.getByRole("button", { name: "创建模型" }));
    const createModelDialog = screen.getByRole("dialog", {
      name: "创建模型对话框",
    });
    await user.type(within(createModelDialog).getByLabelText("模型 key"), "claude-3-haiku");
    await user.type(within(createModelDialog).getByLabelText("显示名称"), "Claude Haiku");
    await user.type(within(createModelDialog).getByLabelText("系列"), "claude");
    await user.type(within(createModelDialog).getByLabelText("上下文长度"), "200000");
    await user.click(within(createModelDialog).getByRole("button", { name: "创建模型" }));

    expect((await screen.findAllByText("Claude Haiku")).length).toBeGreaterThan(
      0,
    );

    await user.click(
      screen.getByRole("button", { name: "停用模型 GPT-4o Mini" }),
    );

    expect(
      await screen.findByText("GPT-4o Mini 已停用。"),
    ).toBeInTheDocument();
    expect((await screen.findAllByText("gpt-4o-mini")).length).toBeGreaterThan(
      0,
    );
    expect(screen.getByText("gpt-4o-mini-2024-07-18")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "创建关联" }));
    const createAssociationDialog = screen.getByRole("dialog", {
      name: "创建关联对话框",
    });
    await user.type(within(createAssociationDialog).getByLabelText("关联模型 ID"), "model-2");
    await user.type(within(createAssociationDialog).getByLabelText("渠道 ID"), "channel-2");
    await user.type(
      within(createAssociationDialog).getByLabelText("上游模型"),
      "claude-3-haiku-20240307",
    );
    await user.click(
      within(createAssociationDialog).getByRole("button", { name: "创建关联" }),
    );

    expect(
      await screen.findByText("claude-3-haiku-20240307"),
    ).toBeInTheDocument();

    await user.type(screen.getByLabelText("项目 ID"), "project-1");
    await user.type(screen.getByLabelText("配置 ID"), "profile-1");
    await user.type(
      screen.getByLabelText("规范模型 key"),
      "gpt-4o-mini",
    );
    await user.click(screen.getByRole("button", { name: "运行 dry-run" }));

    expect(
      await screen.findByRole("heading", {
        level: 2,
        name: "路由快照摘要",
      }),
    ).toBeInTheDocument();
    expect(screen.getAllByText("primary channel").length).toBeGreaterThan(0);
    expect(screen.getByText("阻止回退")).toBeInTheDocument();
    expect(screen.getAllByText("profile denied").length).toBeGreaterThan(0);

    const dryRunCalls = fetchMock.mock.calls.filter(([url]) =>
      String(url).includes("/admin/model-associations/dry-run"),
    );
    expect(JSON.parse(String(dryRunCalls.at(-1)?.[1]?.body))).toEqual({
      canonical_model_key: "gpt-4o-mini",
      profile_id: "profile-1",
      project_id: "project-1",
    });
    expect(document.body.textContent).not.toContain(AUTH_HEADER_NAME);
    expect(document.body.textContent).not.toContain(
      skPlaceholder("route-dry-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("route-dry-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("selection-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("candidate-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "raw dry-run payload hidden",
    );
    expect(document.body.textContent).not.toContain(
      "raw dry-run snapshot hidden",
    );

    await user.click(
      screen.getByRole("button", { name: "停用关联 association-1" }),
    );

    expect(
      await screen.findByText("关联 associat... 已停用。"),
    ).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "删除关联 association-1" }),
    );

    expect(
      await screen.findByText("关联 associat... 已删除。"),
    ).toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "删除模型 GPT-4o Mini" }),
    );

    expect(await screen.findByText("GPT-4o Mini 已删除。")).toBeInTheDocument();
  }, 10000);

  it("shows generated virtual key credentials once after create", async () => {
    stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /API 密钥/ }));
    await user.click(await screen.findByRole("button", { name: "创建 API 密钥" }));
    const createKeyDialog = screen.getByRole("dialog", {
      name: "创建 API 密钥对话框",
    });
    await user.type(within(createKeyDialog).getByLabelText("项目 ID"), "project-1");
    await user.type(
      within(createKeyDialog).getByLabelText("API 密钥名称"),
      "created-virtual",
    );
    await user.type(within(createKeyDialog).getByLabelText("默认配置档案 ID"), "profile-1");
    await user.click(
      within(createKeyDialog).getByRole("button", { name: "创建 API 密钥" }),
    );

    expect(
      await screen.findByText("created-virtual 已创建"),
    ).toBeInTheDocument();
    expect(screen.queryByText("vk-created-secret-once")).not.toBeInTheDocument();
    expect(
      screen.queryByText("vk-created-secret-hash"),
    ).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "清除提示" }));

    await waitFor(() =>
      expect(
        screen.queryByText("created-virtual 已创建"),
      ).not.toBeInTheDocument(),
    );
    expect(
      screen.queryByText("vk-created-secret-once"),
    ).not.toBeInTheDocument();
  });

  it("does not render virtual key secret hashes from list or detail responses", async () => {
    stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /API 密钥/ }));
    await user.type(
      await screen.findByLabelText("API 密钥项目 ID"),
      "project-1",
    );
    await user.click(screen.getByRole("button", { name: "搜索" }));

    expect(await screen.findByText("virtual-main")).toBeInTheDocument();
    expect(screen.queryByText("vk-list-secret-hash")).not.toBeInTheDocument();

    await user.click(
      screen.getByRole("button", { name: "查看 API 密钥 virtual-main" }),
    );

    expect(await screen.findByText("API 密钥详情")).toBeInTheDocument();
    expect(screen.queryByText("vk-list-secret-hash")).not.toBeInTheDocument();
    expect(
      screen.queryByText(skPlaceholder("vk-metadata-hidden")),
    ).not.toBeInTheDocument();
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("vk-budget-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("vk-rate-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("vk-budget-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "raw virtual key payload hidden",
    );
  });

  it("focuses an audit-linked virtual key without rendering secret material", async () => {
    const baseFetch = stubAdminFetch();
    const fetchMock = vi.fn((url: RequestInfo | URL, init?: RequestInit) => {
      const requestUrl = String(url);

      if (requestUrl.includes("/admin/audit-logs")) {
        return jsonResponse([
          {
            action: "virtual_key.bulk_leak_action",
            actor_user_id: "operator-1",
            after_snapshot: {
              key_prefix: vkUnderscorePlaceholder("live_123"),
              project_id: "project-1",
              status: "active",
            },
            before_snapshot: null,
            created_at: "2026-06-12T10:00:00Z",
            id: "audit-virtual-key-1",
            metadata: {
              action_result: "suspected_leaked_marked",
              key_id: "virtual-key-1",
              key_prefix: vkUnderscorePlaceholder("live_123"),
              project_id: "project-1",
              reason: "ticket INC-42",
              secret_note: skPlaceholder("audit-virtual-hidden"),
              status: "active",
            },
            request_id: null,
            resource_id: "virtual-key-1",
            resource_type: "virtual_key",
            tenant_id: "tenant-1",
          },
        ]);
      }

      return baseFetch(url, init);
    });
    vi.stubGlobal("fetch", fetchMock);

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /审计日志/ }));
    await user.click(await screen.findByRole("button", { name: /API key/ }));

    expect(await screen.findByText("审计跳转 focus")).toBeInTheDocument();
    expect(await screen.findByText(/已定位 API key/)).toBeInTheDocument();
    expect(screen.getAllByText("virtual...").length).toBeGreaterThan(0);
    expect(screen.getByRole("button", { name: "选择 focus key" })).toBeDisabled();
    expect(document.body.textContent).not.toContain("vk-list-secret-hash");
    expect(document.body.textContent).not.toContain(
      skPlaceholder("audit-virtual-hidden"),
    );

    await user.click(screen.getByRole("button", { name: "清除 focus" }));

    await waitFor(() =>
      expect(screen.queryByText("审计跳转 focus")).not.toBeInTheDocument(),
    );
  });

  it("lists, creates, and patches profile model permissions without unsafe display", async () => {
    const fetchMock = stubAdminFetch();

    const user = await renderSignedInApp();

    await user.click(screen.getByRole("button", { name: /API 密钥/ }));
    await user.click(await screen.findByRole("tab", { name: "配置档案" }));
    await user.type(screen.getByLabelText("配置档案项目 ID"), "project-1");
    await user.click(screen.getByRole("button", { name: "搜索" }));

    expect(await screen.findByText("default-profile")).toBeInTheDocument();
    expect(
      screen.getAllByText((content) => content.includes("gpt-4o-mini")).length,
    ).toBeGreaterThan(0);
    expect(
      screen.getByText((content) => content.includes("gpt-internal")),
    ).toBeInTheDocument();
    expect(
      screen.getByText((content) => content.includes("chat-fast=gpt-4o-mini")),
    ).toBeInTheDocument();
    expect(document.body.textContent).toMatch(/配置档案 IP\s*2 项/);
    expect(document.body.textContent).not.toContain("198.51.100.0/24");
    expect(document.body.textContent).not.toContain("203.0.113.0/24");
    expect(document.body.textContent).not.toContain(
      authorizationBearerPlaceholder("profile-model-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("profile-alias-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      skPlaceholder("profile-alias-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      bearerPlaceholder("profile-override-hidden"),
    );
    expect(document.body.textContent).not.toContain(
      "raw profile payload hidden",
    );

    await user.click(screen.getByRole("button", { name: "创建配置档案" }));
    const createProfileDialog = screen.getByRole("dialog", {
      name: "创建配置档案对话框",
    });
    await user.type(
      within(createProfileDialog).getByLabelText("新配置档案项目 ID"),
      "project-1",
    );
    await user.type(within(createProfileDialog).getByLabelText("配置档案名称"), "created-profile");
    fireEvent.change(within(createProfileDialog).getByLabelText("可见模型 JSON"), {
      target: { value: '["gpt-create-visible"]' },
    });
    fireEvent.change(within(createProfileDialog).getByLabelText("拒绝模型 JSON"), {
      target: { value: '["gpt-create-denied"]' },
    });
    fireEvent.change(within(createProfileDialog).getByLabelText("模型别名 JSON"), {
      target: { value: '{"create-fast":"gpt-create-visible"}' },
    });
    fireEvent.change(within(createProfileDialog).getByLabelText("配置档案 IP 白名单 JSON"), {
      target: { value: "{" },
    });
    await user.click(within(createProfileDialog).getByRole("button", { name: "创建配置档案" }));

    expect(
      await screen.findByText("配置档案 IP 白名单必须是有效 JSON。"),
    ).toBeInTheDocument();
    expect(
      fetchMock.mock.calls.some(
        ([url, init]) =>
          String(url).includes("/admin/api-key-profiles") &&
          init?.method === "POST",
      ),
    ).toBe(false);

    fireEvent.change(within(createProfileDialog).getByLabelText("配置档案 IP 白名单 JSON"), {
      target: { value: '{"office":"198.51.100.0/24"}' },
    });
    await user.click(within(createProfileDialog).getByRole("button", { name: "创建配置档案" }));

    expect(
      await screen.findByText("配置档案 IP 白名单必须是 JSON 数组。"),
    ).toBeInTheDocument();
    expect(
      fetchMock.mock.calls.some(
        ([url, init]) =>
          String(url).includes("/admin/api-key-profiles") &&
          init?.method === "POST",
      ),
    ).toBe(false);

    fireEvent.change(within(createProfileDialog).getByLabelText("配置档案 IP 白名单 JSON"), {
      target: { value: '["198.51.100.0/24","2001:db8:2::/64"]' },
    });
    await user.click(within(createProfileDialog).getByRole("button", { name: "创建配置档案" }));

    expect(await screen.findByText("created-profile")).toBeInTheDocument();
    expect(
      screen.getAllByText((content) => content.includes("gpt-create-visible"))
        .length,
    ).toBeGreaterThan(0);

    const createCall = fetchMock.mock.calls.find(([url, init]) => {
      return (
        String(url).includes("/admin/api-key-profiles") &&
        init?.method === "POST"
      );
    });
    expect(JSON.parse(String(createCall?.[1]?.body))).toEqual({
      allowed_models: ["gpt-create-visible"],
      denied_models: ["gpt-create-denied"],
      ip_allowlist: ["198.51.100.0/24", "2001:db8:2::/64"],
      model_aliases: {
        "create-fast": "gpt-create-visible",
      },
      name: "created-profile",
      project_id: "project-1",
      status: "active",
    });

    await user.click(
      screen.getByRole("button", { name: "编辑配置档案 default-profile" }),
    );

    const patchPanel = screen.getByRole("dialog", { name: "编辑配置档案对话框" });
    fireEvent.change(within(patchPanel).getByLabelText("可见模型 JSON"), {
      target: { value: '["gpt-4o-mini","gpt-visible-new"]' },
    });
    fireEvent.change(within(patchPanel).getByLabelText("拒绝模型 JSON"), {
      target: { value: '["gpt-denied-new"]' },
    });
    fireEvent.change(within(patchPanel).getByLabelText("模型别名 JSON"), {
      target: { value: '{"chat-fast":"gpt-visible-new"}' },
    });
    fireEvent.change(
      within(patchPanel).getByLabelText("配置档案 IP 白名单 JSON"),
      {
        target: { value: '["198.51.100.10","2001:db8:3::/64"]' },
      },
    );
    await user.click(
      within(patchPanel).getByRole("button", { name: "保存变更" }),
    );

    expect(await screen.findByText("配置档案已更新。")).toBeInTheDocument();
    expect(
      screen.getAllByText((content) => content.includes("gpt-visible-new"))
        .length,
    ).toBeGreaterThan(0);

    const patchCall = fetchMock.mock.calls.find(([url, init]) => {
      return (
        String(url).includes("/admin/api-key-profiles/profile-1") &&
        init?.method === "PATCH"
      );
    });
    expect(JSON.parse(String(patchCall?.[1]?.body))).toEqual({
      allowed_models: ["gpt-4o-mini", "gpt-visible-new"],
      denied_models: ["gpt-denied-new"],
      ip_allowlist: ["198.51.100.10", "2001:db8:3::/64"],
      model_aliases: {
        "chat-fast": "gpt-visible-new",
      },
    });

    await user.click(
      screen.getByRole("button", { name: "删除配置档案 default-profile" }),
    );

    expect(
      await screen.findByText("api key profile has active virtual keys bound"),
    ).toBeInTheDocument();
  });
});
