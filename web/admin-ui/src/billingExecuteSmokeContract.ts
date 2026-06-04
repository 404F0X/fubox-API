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
    contractCheckFresh: "ledger-adjustment-contract-check-fresh",
    contractCheckNetworkCall: "ledger-adjustment-contract-check-network-call",
    executeButton: "ledger-adjustment-execute-button",
    executeContractButton: "ledger-adjustment-execute-contract-button",
    executeContractMode: "ledger-adjustment-execute-contract-mode",
    executeEndpoint: "ledger-adjustment-execute-endpoint",
    executeFlags: "ledger-adjustment-execute-flags",
    executeOutcome: "ledger-adjustment-execute-outcome",
    executeResultFresh: "ledger-adjustment-execute-result-fresh",
    executeWriteNetworkCall: "ledger-adjustment-execute-write-network-call",
    ledgerRefreshStatus: "ledger-adjustment-ledger-refresh-status",
    readiness: "ledger-adjustment-execute-readiness",
    dryRunFresh: "ledger-adjustment-dry-run-fresh",
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
  metricMarkers: {
    ledgerRefreshDurationMs: "ledger_refresh_duration_ms",
    readiness: "browser_smoke_readiness",
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

export const ledgerAdjustmentExecuteLiveSmokeHandoff = {
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
