export const ledgerAdjustmentExecuteLiveSmokeContract = {
  forbiddenSensitiveMarkers: [
    "Authorization",
    "Cookie",
    "token",
    "credential",
    "operation_key",
    "raw metadata",
    "raw executor error detail",
    "dedupe material",
  ],
  markers: {
    contractCheckNetworkCall: "contract_check_network_call",
    dryRunFresh: "fresh_dry_run",
    executeContractMode: "execute_contract_mode",
    executeEndpoint: "execute_endpoint",
    executeOutcome: "execute_outcome",
    executeResultFresh: "execute_result_fresh",
    executeWriteNetworkCall: "execute_write_network_call",
    ledgerEntriesRefreshAfterExecute: "ledger_entries_refresh_after_execute",
  },
  refreshStatuses: {
    error: "error",
    success: "success",
  },
  selectors: {
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
  },
  statuses: {
    applied: "applied",
    blocked: "blocked",
    dryRunRequired: "dry run required",
    executePreflight: "execute preflight",
    failed: "failed",
    idempotent: "idempotent",
    stalePlan: "stale plan",
  },
} as const;

export type LedgerAdjustmentExecuteLiveSmokeContract = typeof ledgerAdjustmentExecuteLiveSmokeContract;

export const ledgerAdjustmentExecuteAbsentOptionalMarker = null;

export const ledgerAdjustmentExecuteReadinessMarkerKeys = [
  "contractCheckNetworkCall",
  "dryRunFresh",
  "executeOutcome",
  "executeResultFresh",
  "executeWriteNetworkCall",
  "ledgerRefreshStatus",
] as const;

export const ledgerAdjustmentExecuteBrowserPreflightContract = {
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
    handoffArtifact: "web/admin-ui/src/billingExecuteSmokeContract.serializable.json",
  },
  requiresLiveBackendByDefault: false,
  usesDataTestIdsOnly: true,
} as const;

export const ledgerAdjustmentExecuteBrowserActionPlanContract = {
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
} as const;

export const ledgerAdjustmentExecuteBrowserLiveRunbookContract = {
  blockerClassifications: {
    adminUiUnreachable: "admin_ui_unreachable",
    browserToolingUnavailable: "browser_tooling_unavailable",
    controlPlaneHealthUnreachable: "control_plane_health_unreachable",
    liveMutationOptInMissing: "live_mutation_opt_in_missing",
    sessionMaterialMissing: "session_material_missing",
  },
  defaultMode: "contract_only",
  evidenceNames: {
    dryRunPlanDurationMs: "dry_run_plan_duration_ms",
    executeApplyDurationMs: "execute_apply_duration_ms",
    idempotentReplayDurationMs: "idempotent_replay_duration_ms",
    ledgerRefreshDurationMs: "ledger_refresh_duration_ms",
    refundRefusalDurationMs: "refund_refusal_duration_ms",
    serviceReadinessDurationMs: "service_readiness_duration_ms",
    submitLatencyMs: "submit_latency_ms",
  },
  liveCommand: {
    arguments: ["-BrowserPreflight"],
    script: "scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1",
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
    forbiddenMarkers: ledgerAdjustmentExecuteLiveSmokeContract.forbiddenSensitiveMarkers,
  },
} as const;

export const ledgerAdjustmentExecuteBrowserEvidenceArtifactContract = {
  artifactName: "billing_execute_browser_live_e2e_evidence.v1",
  durationFields: {
    dryRunPlanDurationMs: "dry_run_plan_duration_ms",
    executeApplyDurationMs: "execute_apply_duration_ms",
    idempotentReplayDurationMs: "idempotent_replay_duration_ms",
    ledgerRefreshDurationMs: "ledger_refresh_duration_ms",
    refundRefusalDurationMs: "refund_refusal_duration_ms",
    serviceReadinessDurationMs: "service_readiness_duration_ms",
    submitLatencyMs: "submit_latency_ms",
  },
  requiredTopLevelFields: [
    "artifact",
    "generated_at",
    "mode",
    "outcome",
    "provenance",
    "blockers",
    "matrix",
    "durations",
    "actions",
    "secret_safe",
  ],
  outcomes: {
    blocked: "blocked",
    failed: "failed",
    passed: "passed",
  },
  unavailableMarker: "unavailable",
} as const;

export const ledgerAdjustmentExecuteLiveSmokeHandoff = {
  browserActionPlan: ledgerAdjustmentExecuteBrowserActionPlanContract,
  browserEvidenceArtifact: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract,
  browserLiveRunbook: ledgerAdjustmentExecuteBrowserLiveRunbookContract,
  browserPreflight: ledgerAdjustmentExecuteBrowserPreflightContract,
  forbiddenSensitiveMarkers: ledgerAdjustmentExecuteLiveSmokeContract.forbiddenSensitiveMarkers,
  readinessStates: {
    appliedRefreshError: {
      executeButtonEnabled: true,
      expectedStatus: ledgerAdjustmentExecuteLiveSmokeContract.statuses.applied,
      markers: {
        contractCheckNetworkCall: false,
        dryRunFresh: true,
        executeOutcome: ledgerAdjustmentExecuteLiveSmokeContract.statuses.applied,
        executeResultFresh: true,
        executeWriteNetworkCall: true,
        ledgerRefreshStatus: ledgerAdjustmentExecuteLiveSmokeContract.refreshStatuses.error,
      },
    },
    appliedRefreshSuccess: {
      executeButtonEnabled: true,
      expectedStatus: ledgerAdjustmentExecuteLiveSmokeContract.statuses.applied,
      markers: {
        contractCheckNetworkCall: false,
        dryRunFresh: true,
        executeOutcome: ledgerAdjustmentExecuteLiveSmokeContract.statuses.applied,
        executeResultFresh: true,
        executeWriteNetworkCall: true,
        ledgerRefreshStatus: ledgerAdjustmentExecuteLiveSmokeContract.refreshStatuses.success,
      },
    },
    blocked: {
      executeButtonEnabled: true,
      expectedStatus: ledgerAdjustmentExecuteLiveSmokeContract.statuses.blocked,
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
      expectedStatus: ledgerAdjustmentExecuteLiveSmokeContract.statuses.blocked,
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
      expectedStatus: ledgerAdjustmentExecuteLiveSmokeContract.statuses.dryRunRequired,
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
      expectedStatus: ledgerAdjustmentExecuteLiveSmokeContract.statuses.executePreflight,
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
      expectedStatus: ledgerAdjustmentExecuteLiveSmokeContract.statuses.failed,
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
      expectedStatus: ledgerAdjustmentExecuteLiveSmokeContract.statuses.idempotent,
      markers: {
        contractCheckNetworkCall: false,
        dryRunFresh: true,
        executeOutcome: ledgerAdjustmentExecuteLiveSmokeContract.statuses.idempotent,
        executeResultFresh: true,
        executeWriteNetworkCall: true,
        ledgerRefreshStatus: ledgerAdjustmentExecuteLiveSmokeContract.refreshStatuses.error,
      },
    },
    idempotentRefreshSuccess: {
      executeButtonEnabled: true,
      expectedStatus: ledgerAdjustmentExecuteLiveSmokeContract.statuses.idempotent,
      markers: {
        contractCheckNetworkCall: false,
        dryRunFresh: true,
        executeOutcome: ledgerAdjustmentExecuteLiveSmokeContract.statuses.idempotent,
        executeResultFresh: true,
        executeWriteNetworkCall: true,
        ledgerRefreshStatus: ledgerAdjustmentExecuteLiveSmokeContract.refreshStatuses.success,
      },
    },
    stalePlan: {
      executeButtonEnabled: false,
      expectedStatus: ledgerAdjustmentExecuteLiveSmokeContract.statuses.stalePlan,
      markers: {
        contractCheckNetworkCall: false,
        dryRunFresh: false,
        executeOutcome: ledgerAdjustmentExecuteAbsentOptionalMarker,
        executeResultFresh: ledgerAdjustmentExecuteAbsentOptionalMarker,
        executeWriteNetworkCall: false,
        ledgerRefreshStatus: ledgerAdjustmentExecuteAbsentOptionalMarker,
      },
    },
  },
  readinessMarkerKeys: ledgerAdjustmentExecuteReadinessMarkerKeys,
  scriptUsage: {
    assertNoForbiddenMarkersInDocument: true,
    readStatusFromReadinessRegion: true,
    selectorsSource: "ledgerAdjustmentExecuteLiveSmokeContract.selectors",
    statusMarkersSource: "ledgerAdjustmentExecuteLiveSmokeHandoff.readinessStates",
    useDataTestIdsOnly: true,
  },
  selectors: ledgerAdjustmentExecuteLiveSmokeContract.selectors,
  statusMarkers: ledgerAdjustmentExecuteLiveSmokeContract.markers,
} as const;

export type LedgerAdjustmentExecuteLiveSmokeHandoff = typeof ledgerAdjustmentExecuteLiveSmokeHandoff;

export const ledgerAdjustmentExecuteLiveSmokeSerializableHandoff = {
  ...ledgerAdjustmentExecuteLiveSmokeHandoff,
  serialization: {
    absentOptionalMarker: ledgerAdjustmentExecuteAbsentOptionalMarker,
    format: "json",
    requiredReadinessMarkerKeys: ledgerAdjustmentExecuteReadinessMarkerKeys,
  },
} as const;

export type LedgerAdjustmentExecuteLiveSmokeSerializableHandoff =
  typeof ledgerAdjustmentExecuteLiveSmokeSerializableHandoff;
