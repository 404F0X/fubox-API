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
  requiredTopLevelFields: [
    "artifact",
    "generated_at",
    "mode",
    "outcome",
    "provenance",
    "freshness",
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

export const ledgerAdjustmentExecuteBrowserRunnerReadinessContract = {
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
    pathEnv: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_PATH",
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
  durationCaptureNames: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.durationFields,
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
} as const;

export const ledgerAdjustmentExecuteBrowserDomActionRunnerContract = {
  artifactEmission: {
    artifactName: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.artifactName,
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
} as const;

export const ledgerAdjustmentExecuteBrowserPlaywrightLaunchReadinessContract = {
  artifactEmission: {
    artifactName: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.artifactName,
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
    browserLaunchDurationMs: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.durationFields.browserLaunchDurationMs,
    contextSetupDurationMs: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.durationFields.contextSetupDurationMs,
    pageReadyDurationMs: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.durationFields.pageReadyDurationMs,
    selectorSnapshotDurationMs: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.durationFields.selectorSnapshotDurationMs,
    serviceReadinessDurationMs: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.durationFields.serviceReadinessDurationMs,
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
} as const;

export const ledgerAdjustmentExecuteBrowserMutationPassArtifactClosureContract = {
  artifactName: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.artifactName,
  defaultClosesLiveGap: false,
  defaultMode: "mutation_pass_artifact_closure_gate",
  defaultSubmitsLiveMutation: false,
  durationFields: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.durationFields,
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
} as const;

export const ledgerAdjustmentExecuteBrowserLiveRunnerExecutionBridgeContract = {
  artifact: {
    defaultPath: "artifacts/billing_execute_browser_live_e2e_evidence.json",
    name: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.artifactName,
    pathEnv: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_PATH",
    readBackRequired: true,
    writeOptInFlag: "-BrowserEvidenceArtifactWriteOptIn",
  },
  command: {
    flag: "-BrowserLiveRunnerExecutionOptIn",
    script: "scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1",
  },
  defaultClicksAdminUiActions: false,
  defaultMode: "live_runner_execution_bridge",
  defaultRunsBridge: false,
  defaultSubmitsLiveMutation: false,
  durationFields: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.durationFields,
  env: {
    artifactWrite: "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_WRITE",
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
} as const;

export const ledgerAdjustmentExecuteBrowserLivePassArtifactReadbackGateContract = {
  artifactName: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.artifactName,
  defaultMode: "live_pass_artifact_readback_gate",
  defaultReadsArtifact: false,
  defaultSubmitsLiveMutation: false,
  durationFields: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.durationFields,
  expectedActionOutcomes: ledgerAdjustmentExecuteBrowserMutationPassArtifactClosureContract.expectedActionOutcomes,
  requiredArtifactFreshness: ledgerAdjustmentExecuteBrowserMutationPassArtifactClosureContract.requiredArtifactFreshness,
  requiredReadiness: ledgerAdjustmentExecuteBrowserMutationPassArtifactClosureContract.requiredReadiness,
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
} as const;

export const ledgerAdjustmentExecuteBrowserLiveEnvironmentBootstrapAttemptContract = {
  artifactName: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.artifactName,
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
  durationFields: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract.durationFields,
  playwright: {
    browser: "chromium",
    installCommand: "npm --prefix web/admin-ui exec playwright install chromium",
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
} as const;

export const ledgerAdjustmentExecuteLiveSmokeHandoff = {
  browserActionPlan: ledgerAdjustmentExecuteBrowserActionPlanContract,
  browserDomActionRunner: ledgerAdjustmentExecuteBrowserDomActionRunnerContract,
  browserEvidenceArtifact: ledgerAdjustmentExecuteBrowserEvidenceArtifactContract,
  browserLiveEnvironmentBootstrapAttempt: ledgerAdjustmentExecuteBrowserLiveEnvironmentBootstrapAttemptContract,
  browserLiveRunbook: ledgerAdjustmentExecuteBrowserLiveRunbookContract,
  browserLiveRunnerExecutionBridge: ledgerAdjustmentExecuteBrowserLiveRunnerExecutionBridgeContract,
  browserLivePassArtifactReadbackGate: ledgerAdjustmentExecuteBrowserLivePassArtifactReadbackGateContract,
  browserMutationPassArtifactClosure: ledgerAdjustmentExecuteBrowserMutationPassArtifactClosureContract,
  browserPlaywrightLaunchReadiness: ledgerAdjustmentExecuteBrowserPlaywrightLaunchReadinessContract,
  browserPreflight: ledgerAdjustmentExecuteBrowserPreflightContract,
  browserRunnerReadiness: ledgerAdjustmentExecuteBrowserRunnerReadinessContract,
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
