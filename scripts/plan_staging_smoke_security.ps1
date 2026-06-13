#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$OutputPath,
  [switch]$WriteFile
)

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}
$repoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..")).Path

function Get-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $trimChars = [char[]]@("\", "/")
  $root = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd($trimChars)
  $target = [System.IO.Path]::GetFullPath($Path)
  $rootWithSeparator = $root + [System.IO.Path]::DirectorySeparatorChar
  if ($target.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($target.Substring($rootWithSeparator.Length) -replace "\\", "/")
  }

  return ($target -replace "\\", "/")
}

function Write-Utf8NoBomFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content
  )

  $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $repoRoot ".tmp/staging/staging_smoke_security_plan.json"
} elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
  $OutputPath = Join-Path $repoRoot $OutputPath
}

$chartDir = Join-Path $repoRoot "deploy/helm"
$plan = [ordered]@{
  schemaVersion = "staging-smoke-security-plan/v1"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  purpose = "Dry-run operator plan seam for staging smoke and security presence review. It does not deploy, run live smoke, run load, run chaos, or produce release evidence."
  sourceFiles = @(
    "deploy/helm/values.yaml",
    "deploy/helm/values.schema.json",
    "deploy/helm/README.md",
    "docs/11_DEPLOYMENT_OPS_RUNBOOK.md",
    "scripts/plan_staging_smoke_security.ps1"
  )
  commands = [ordered]@{
    planOnly = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/plan_staging_smoke_security.ps1"
    writePlan = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/plan_staging_smoke_security.ps1 -WriteFile"
    chartStaticValidation = "python deploy/helm/validate_chart.py --skip-helm"
    chartSelfTest = "python deploy/helm/validate_chart.py --skip-helm --self-test"
    renderWhenHelmAvailable = "helm template fubox ./deploy/helm"
  }
  requiredPresence = [ordered]@{
    helmSecretRefs = @(
      [ordered]@{ owner = "database"; valuePath = "database.secretRef.name"; requiredKeys = @("DATABASE_URL"); valuePolicy = "presence-only" },
      [ordered]@{ owner = "redis"; valuePath = "redis.secretRef.name"; requiredKeys = @("REDIS_URL"); valuePolicy = "presence-only" },
      [ordered]@{ owner = "application"; valuePath = "application.secretRef.name"; requiredKeys = @("AI_GATEWAY_MASTER_KEY", "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64", "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID"); valuePolicy = "presence-only" },
      [ordered]@{ owner = "clickhouse"; valuePath = "clickhouse.secretRef.name"; requiredKeys = @("AI_GATEWAY_CLICKHOUSE_ENDPOINT", "AI_GATEWAY_CLICKHOUSE_DATABASE", "AI_GATEWAY_CLICKHOUSE_TABLE", "AI_GATEWAY_CLICKHOUSE_USERNAME", "AI_GATEWAY_CLICKHOUSE_PASSWORD"); valuePolicy = "presence-only-or-config-needed" },
      [ordered]@{ owner = "provider"; valuePath = "provider.secretRef.name"; requiredKeys = @("provider adapter credential env selected by operator"); valuePolicy = "presence-only-or-config-needed" },
      [ordered]@{ owner = "payment"; valuePath = "payment.secretRef.name"; requiredKeys = @("payment adapter credential/signing env selected by operator"); valuePolicy = "presence-only-or-config-needed" }
    )
    runtimeConfig = @(
      [ordered]@{ path = "server.trusted_proxy_allowlist"; status = "must be reviewed before shared staging exposure" },
      [ordered]@{ path = "server.ip_allowlist.default_policy"; status = "must replace config-needed for shared staging exposure" },
      [ordered]@{ path = "security.cors"; status = "must use staging admin origins, not wildcard public origins" },
      [ordered]@{ path = "security.rate_limit"; status = "must confirm Redis-backed policy before load-like smoke" },
      [ordered]@{ path = "observability.log_payload_default"; status = "must remain false unless an approved redaction policy exists" }
    )
  }
  securityReviewChecklist = @(
    [ordered]@{
      id = "cors_origins"
      title = "CORS origins"
      source = "global.config.content security.cors and workload CORS env"
      readback = @(
        [ordered]@{ field = "gateway_allowed_origins_env_present"; expected = "presence-only" },
        [ordered]@{ field = "control_plane_allowed_origins_env_present"; expected = "presence-only" },
        [ordered]@{ field = "wildcard_public_origin_absent"; expected = "operator-reviewed" }
      )
      nextStep = "Replace .example.invalid values with staging admin origins before shared exposure."
    },
    [ordered]@{
      id = "ip_allowlist"
      title = "IP allowlist policy"
      source = "global.config.content server.ip_allowlist plus profile/key runtime config"
      readback = @(
        [ordered]@{ field = "default_policy"; expected = "config-needed-or-reviewed" },
        [ordered]@{ field = "profile_allowlist_presence"; expected = "presence-only" },
        [ordered]@{ field = "virtual_key_allowlist_presence"; expected = "presence-only" }
      )
      nextStep = "Confirm staging client/VPN policy with documented CIDRs; do not place real IP lists in this plan output."
    },
    [ordered]@{
      id = "trusted_proxy"
      title = "Trusted proxy boundary"
      source = "global.config.content server.trusted_proxy_allowlist and workload AI_GATEWAY_TRUSTED_PROXY_ALLOWLIST_STATUS"
      readback = @(
        [ordered]@{ field = "trusted_proxy_allowlist_presence"; expected = "presence-only" },
        [ordered]@{ field = "forwarded_header_trust_scope"; expected = "operator-reviewed" },
        [ordered]@{ field = "direct_client_networks_excluded"; expected = "operator-reviewed" }
      )
      nextStep = "Only add real load balancer or reverse proxy CIDRs in cluster config, not ordinary client networks."
    },
    [ordered]@{
      id = "secret_refs"
      title = "Secret references"
      source = "database/redis/application/clickhouse/provider/payment secretRef names"
      readback = @(
        [ordered]@{ field = "database_secret_ref_present"; expected = "true" },
        [ordered]@{ field = "redis_secret_ref_present"; expected = "true" },
        [ordered]@{ field = "application_secret_ref_present"; expected = "true" },
        [ordered]@{ field = "optional_adapter_secret_refs_present_or_config_needed"; expected = "presence-only" }
      )
      nextStep = "Verify Secret objects and key names in the target cluster without printing Secret data."
    },
    [ordered]@{
      id = "rate_limit"
      title = "Rate limit policy"
      source = "global.config.content security.rate_limit and Redis secretRef"
      readback = @(
        [ordered]@{ field = "rate_limit_store"; expected = "redis" },
        [ordered]@{ field = "redis_secret_ref_present"; expected = "true" },
        [ordered]@{ field = "reservation_policy_status"; expected = "config-needed-or-reviewed" }
      )
      nextStep = "Confirm Redis-backed staging policy before any load-like smoke."
    },
    [ordered]@{
      id = "payload_policy"
      title = "Payload logging policy"
      source = "global.config.content security.default_payload_policy and observability.log_payload_default"
      readback = @(
        [ordered]@{ field = "default_payload_policy"; expected = "metadata_only" },
        [ordered]@{ field = "log_payload_default"; expected = "false" },
        [ordered]@{ field = "raw_stream_sampling_reviewed"; expected = "operator-reviewed" }
      )
      nextStep = "Keep raw payload disabled unless a separate redaction policy and approval exists."
    },
    [ordered]@{
      id = "provider_config"
      title = "Provider adapter config presence"
      source = "provider.secretRef and workload provider adapter env/status"
      readback = @(
        [ordered]@{ field = "provider_secret_ref_present"; expected = "presence-only-or-config-needed" },
        [ordered]@{ field = "unsafe_provider_endpoints_disabled"; expected = "true" },
        [ordered]@{ field = "provider_adapter_status"; expected = "config-needed-or-reviewed" }
      )
      nextStep = "Use sandbox credentials through Kubernetes Secret refs only; do not print provider key values."
    },
    [ordered]@{
      id = "payment_config"
      title = "Payment adapter config presence"
      source = "payment.secretRef and workload payment provider env/status"
      readback = @(
        [ordered]@{ field = "payment_secret_ref_present"; expected = "presence-only-or-config-needed" },
        [ordered]@{ field = "webhook_signing_material_presence"; expected = "presence-only-or-config-needed" },
        [ordered]@{ field = "payment_provider_status"; expected = "config-needed-or-reviewed" }
      )
      nextStep = "Use payment sandbox credentials through Kubernetes Secret refs only; do not print webhook secrets."
    },
    [ordered]@{
      id = "clickhouse_config"
      title = "ClickHouse config presence"
      source = "clickhouse.secretRef, worker env, and read-model config_status"
      readback = @(
        [ordered]@{ field = "clickhouse_secret_ref_present"; expected = "presence-only-or-config-needed" },
        [ordered]@{ field = "endpoint_database_table_username_password_key_names_present"; expected = "presence-only-or-config-needed" },
        [ordered]@{ field = "clickhouse_log_store_status"; expected = "config-needed-or-reviewed" }
      )
      nextStep = "Keep ClickHouse values in Secret refs; do not print endpoints, passwords, or DB URLs."
    }
  )
  securityReadbackContract = [ordered]@{
    schemaVersion = "staging-security-review-readback/v1"
    status = "plan-only"
    resultPolicy = "presence-only; operator fills reviewed/config-needed/pass/follow-up after real staging review"
    requiredChecklistIds = @(
      "cors_origins",
      "ip_allowlist",
      "trusted_proxy",
      "secret_refs",
      "rate_limit",
      "payload_policy",
      "provider_config",
      "payment_config",
      "clickhouse_config"
    )
    allowedStatuses = @("not-run", "config-needed", "reviewed", "follow-up-required", "pass")
    forbiddenReadbackFields = @(
      "secret_value",
      "token",
      "database_url",
      "redis_url",
      "provider_secret",
      "payment_secret",
      "authorization_header",
      "raw_payload"
    )
  }
  smokeOrder = @(
    [ordered]@{ order = 1; id = "render_chart"; operatorAction = "Render or statically validate Helm chart with staging values."; expectedOutput = "render or validation summary only" },
    [ordered]@{ order = 2; id = "apply_migrations"; operatorAction = "Apply migrations against staging Postgres using operator-managed secret injection."; expectedOutput = "migration summary without DB URL" },
    [ordered]@{ order = 3; id = "wait_for_readiness"; operatorAction = "Wait for gateway, control-plane, admin-ui, and optional worker readiness."; expectedOutput = "pod/deployment readiness summary" },
    [ordered]@{ order = 4; id = "seed_admin_and_mock_provider"; operatorAction = "Create admin/session and mock provider/channel/model/key path for staging smoke."; expectedOutput = "safe ids/prefixes only" },
    [ordered]@{ order = 5; id = "create_virtual_key"; operatorAction = "Create a staging smoke virtual key."; expectedOutput = "key id and prefix only; secret shown once to operator tooling, never logged here" },
    [ordered]@{ order = 6; id = "gateway_models"; operatorAction = "Call /v1/models with the staging smoke key."; expectedOutput = "model ids and route readiness summary" },
    [ordered]@{ order = 7; id = "mock_chat_completion"; operatorAction = "Call a mock chat completion through gateway."; expectedOutput = "request id, status, model, token/cost summary" },
    [ordered]@{ order = 8; id = "admin_request_trace_readback"; operatorAction = "Read the request detail and trace summary from control plane."; expectedOutput = "secret-safe request, route, provider attempt, and trace summary" },
    [ordered]@{ order = 9; id = "billing_ledger_readback"; operatorAction = "Read wallet/ledger refs for the smoke request when billing is enabled."; expectedOutput = "ledger refs and balances without raw metadata" },
    [ordered]@{ order = 10; id = "recovery_probe_optional"; operatorAction = "Optionally run bounded recovery probe job after explicit operator approval."; expectedOutput = "probe status and omitted credential markers" }
  )
  targetServices = @(
    [ordered]@{
      id = "gateway"
      workload = "services.gateway"
      paths = @("/readyz", "/v1/models", "/v1/chat/completions")
      role = "OpenAI-compatible data plane, routing, provider attempt, rate-limit, billing pre-authorize path"
      guard = "Use staging virtual keys and mock/sandbox provider routes only; no production key or provider credential values in output."
    },
    [ordered]@{
      id = "control-plane"
      workload = "services.control-plane"
      paths = @("/healthz", "/admin/request-logs", "/admin/trace-requests", "/admin/settings/network-security")
      role = "Admin readback, request detail, trace, ledger refs, and security config presence"
      guard = "Use admin session/token managed by operator tooling; never print session cookies or Authorization headers."
    },
    [ordered]@{
      id = "admin-ui"
      workload = "services.admin-ui"
      paths = @("/", "/api/control-plane/*", "/api/gateway/*")
      role = "Browser-facing console and same-origin proxy surface"
      guard = "No backend Secret refs or browser-public secret env are expected."
    },
    [ordered]@{
      id = "worker"
      workload = "services.worker"
      paths = @("read-model/clickhouse-log-store", "scheduler/recovery-probe seams")
      role = "Disabled-by-default staging worker seam for async readback and optional operator jobs"
      guard = "Only enable after explicit operator command/health model selection."
    },
    [ordered]@{
      id = "mock-provider"
      workload = "services.mock-provider"
      paths = @("/healthz", "/v1/models", "/v1/chat/completions")
      role = "Bounded mock provider path for staging smoke and low-volume baseline"
      guard = "Use for plan-only and initial smoke; real provider sandbox traffic is a separate operator action."
    },
    [ordered]@{
      id = "redis"
      workload = "redis.secretRef"
      paths = @("rate-limit store", "distributed login/rate state")
      role = "Dependency target for rate-limit reservation and Redis unavailable drill planning"
      guard = "Presence-only Secret ref/key names; do not output Redis URL, keys, or raw window state."
    },
    [ordered]@{
      id = "postgres"
      workload = "database.secretRef"
      paths = @("request logs", "ledger refs", "admin readback")
      role = "Dependency target for smoke persistence and failover readiness planning"
      guard = "Presence-only Secret ref/key names; do not output DB URL, SQL payload, or credentials."
    },
    [ordered]@{
      id = "clickhouse"
      workload = "clickhouse.secretRef"
      paths = @("read-model/log-store seam")
      role = "Optional dependency target for read-model ingest baseline planning"
      guard = "May remain config-needed; do not output endpoint, username, password, or DB URL."
    }
  )
  trafficModels = @(
    [ordered]@{
      id = "gateway_latency_baseline"
      targetServices = @("gateway", "mock-provider", "control-plane")
      model = "Single staging virtual key, fixed safe model id, non-stream chat completions, low concurrency ramp chosen by operator."
      dimensions = @("p50_p95_latency_ms", "http_status_counts", "request_id_presence", "route_selected", "provider_attempt_summary")
      resourceGuard = "Do not exceed operator-approved staging request rate; stop on 5xx spike, 429 storm, CPU/memory saturation, or billing mismatch."
      expectedSafeOutput = "counts, latency buckets, request ids, route/provider attempt status, token/cost summary; no prompt/raw payload/Authorization/provider key."
    },
    [ordered]@{
      id = "streaming_idle_timeout_baseline"
      targetServices = @("gateway", "mock-provider")
      model = "Small number of streaming chat requests with bounded idle and client-cancel cases."
      dimensions = @("first_token_latency_ms", "stream_end_reason", "partial_sent", "usage_recorded", "reserve_release_reason")
      resourceGuard = "Operator-selected timeout window only; stop if stream finalizer or concurrency release readback is missing."
      expectedSafeOutput = "stream finalizer projection, request id, end reason, usage observed/recorded flags; no raw chunks."
    },
    [ordered]@{
      id = "rate_limit_reservation_baseline"
      targetServices = @("gateway", "redis", "control-plane")
      model = "Low-volume RPM/TPM/concurrency boundary probe using staging policy and safe synthetic requests."
      dimensions = @("allowed_count", "rejected_count", "retry_after_ms_presence", "reservation_release_reason")
      resourceGuard = "Redis secret ref must be present and policy reviewed; stop on fail-open or provider attempts after expected rejection."
      expectedSafeOutput = "rate-limit metadata projection and provider_attempt_rows count; no Redis URL or raw window state."
    },
    [ordered]@{
      id = "request_log_ingest_baseline"
      targetServices = @("gateway", "control-plane", "worker", "clickhouse")
      model = "Smoke request followed by admin request detail, trace summary, ledger refs, and optional read-model lag readback."
      dimensions = @("log_row_present", "trace_row_present", "ledger_refs_present", "read_model_lag_status")
      resourceGuard = "ClickHouse may remain config-needed; Postgres readback must stay bounded by operator-selected request ids."
      expectedSafeOutput = "request/trace/ledger/read-model status summary; no raw metadata, DB URL, ClickHouse endpoint, or payload."
    }
  )
  resourceGuards = @(
    [ordered]@{ id = "operator_window"; rule = "Run only in an approved staging window with a named operator and rollback owner."; status = "operator-action" },
    [ordered]@{ id = "bounded_rate"; rule = "Traffic rate, concurrency, duration, and request body size must be explicitly bounded before any live run."; status = "operator-action" },
    [ordered]@{ id = "staging_only"; rule = "Targets must be staging service origins and staging Secret refs; production endpoints are out of scope."; status = "operator-action" },
    [ordered]@{ id = "cost_cap"; rule = "Provider/payment sandbox costs must have an operator-defined cap or use mock provider only."; status = "operator-action" },
    [ordered]@{ id = "secret_safe_logs"; rule = "Outputs are limited to ids, counts, statuses, latency buckets, hashes, and omitted markers."; status = "enforced-by-plan" },
    [ordered]@{ id = "no_release_gate"; rule = "Plan/readback JSON is not release evidence and must not block feature work as a production gate."; status = "enforced-by-plan" }
  )
  rollbackCriteria = @(
    [ordered]@{ id = "readiness_degraded"; trigger = "Gateway/control-plane/admin-ui readiness fails or restarts exceed operator threshold."; action = "Stop run, scale back changed workloads, capture pod/deployment status only." },
    [ordered]@{ id = "error_rate_spike"; trigger = "5xx, route_no_candidate, provider auth, or timeout errors exceed operator threshold."; action = "Stop traffic, disable new probe/load job, keep affected request ids for safe readback." },
    [ordered]@{ id = "rate_limit_fail_open"; trigger = "Expected rate-limit rejection still reaches provider attempt or ledger mutation."; action = "Stop run, mark rate limit follow-up-required, roll back rate-limit config if changed." },
    [ordered]@{ id = "billing_mismatch"; trigger = "Ledger refs, reserve release, or balance deltas disagree with expected smoke path."; action = "Stop run, preserve safe request/ledger ids, do not continue load-like traffic." },
    [ordered]@{ id = "secret_or_payload_leak"; trigger = "Any output contains secret values, tokens, DB URLs, Authorization, provider/payment secrets, or raw payload."; action = "Stop run, rotate exposed material through operator process, redact artifact, and mark review failed." },
    [ordered]@{ id = "resource_saturation"; trigger = "CPU, memory, Redis, Postgres, or queue lag exceeds operator threshold."; action = "Stop run, scale down load job, collect resource summary without connection strings." }
  )
  securityChecks = @(
    "secret_refs_present",
    "admin_ui_has_no_secret_env",
    "browser_public_env_absent",
    "trusted_proxy_config_reviewed",
    "ip_allowlist_config_reviewed",
    "cors_origins_reviewed",
    "rate_limit_store_present",
    "payload_policy_metadata_only",
    "provider_payment_secret_values_omitted",
    "service_account_token_disabled",
    "pod_security_context_restricted"
  )
  loadPlaceholders = @(
    "gateway_latency_baseline",
    "streaming_idle_timeout_baseline",
    "rate_limit_reservation_baseline",
    "request_log_ingest_baseline"
  )
  loadReadbackContract = [ordered]@{
    schemaVersion = "staging-load-plan-readback/v1"
    status = "plan-only"
    resultPolicy = "operator fills not-run/config-needed/reviewed/follow-up-required/pass after a real bounded staging load baseline"
    requiredSections = @("targetServices", "trafficModels", "resourceGuards", "rollbackCriteria", "expectedSafeOutputs")
    allowedStatuses = @("not-run", "config-needed", "reviewed", "follow-up-required", "pass")
    allowedFields = @(
      "service_id",
      "traffic_model_id",
      "status",
      "started_at",
      "finished_at",
      "request_count",
      "error_count",
      "http_status_counts",
      "latency_bucket_ms",
      "resource_summary",
      "rollback_triggered",
      "rollback_reason",
      "safe_request_ids",
      "operator_notes"
    )
    forbiddenReadbackFields = @(
      "secret_value",
      "token",
      "database_url",
      "redis_url",
      "provider_secret",
      "payment_secret",
      "authorization_header",
      "raw_payload",
      "raw_stream_chunk",
      "raw_window_state"
    )
  }
  chaosPlaceholders = @(
    "provider_5xx_fallback_drill",
    "redis_unavailable_readiness_drill",
    "postgres_failover_readiness_drill",
    "worker_restart_recovery_drill"
  )
  chaosExperiments = @(
    [ordered]@{
      id = "provider_5xx_fallback_drill"
      targetServices = @("gateway", "mock-provider")
      fault = "Mock/sandbox provider returns bounded 5xx or timeout response for selected model/channel."
      expectedSystemBehavior = "Gateway records provider attempt, applies fallback/retry policy when configured, and returns secret-safe error if no candidate remains."
      resourceGuard = "Mock provider preferred; real provider sandbox only after explicit operator approval."
      rollbackCriteria = @("error_rate_spike", "secret_or_payload_leak")
      expectedSafeOutput = "request ids, selected route/fallback status, provider attempt error class, no upstream raw body."
    },
    [ordered]@{
      id = "redis_unavailable_readiness_drill"
      targetServices = @("gateway", "control-plane", "redis")
      fault = "Operator-approved Redis outage/dependency block in staging only."
      expectedSystemBehavior = "Rate-limit/login distributed state fails closed or degrades per reviewed policy; readiness/status surfaces config/dependency issue."
      resourceGuard = "Run only with rollback owner and Redis restore command ready."
      rollbackCriteria = @("readiness_degraded", "rate_limit_fail_open", "resource_saturation")
      expectedSafeOutput = "dependency status, rejected/allowed counts, retry-after presence; no Redis URL or raw keys."
    },
    [ordered]@{
      id = "postgres_failover_readiness_drill"
      targetServices = @("gateway", "control-plane", "worker", "postgres")
      fault = "Operator-approved Postgres failover/read-only window in staging only."
      expectedSystemBehavior = "Readiness and request logging behavior are understood; writes fail safely without leaking connection details."
      resourceGuard = "Requires DB owner approval and immediate rollback path; not run by this script."
      rollbackCriteria = @("readiness_degraded", "billing_mismatch", "resource_saturation")
      expectedSafeOutput = "readiness transitions, bounded request ids, DB dependency status; no DB URL or SQL payload."
    },
    [ordered]@{
      id = "worker_restart_recovery_drill"
      targetServices = @("worker", "control-plane", "clickhouse")
      fault = "Restart disabled/enabled worker seam or bounded operator job."
      expectedSystemBehavior = "Read-model/log-store/scheduler seams recover or report config-needed without data loss claims."
      resourceGuard = "Worker remains disabled by default; enable only for selected command and health model."
      rollbackCriteria = @("readiness_degraded", "resource_saturation", "secret_or_payload_leak")
      expectedSafeOutput = "restart count, job status, lag/status markers; no ClickHouse endpoint/password or provider/payment secrets."
    }
  )
  chaosReadbackContract = [ordered]@{
    schemaVersion = "staging-chaos-plan-readback/v1"
    status = "plan-only"
    resultPolicy = "operator fills not-run/config-needed/reviewed/follow-up-required/pass after explicitly approved staging chaos drills"
    requiredSections = @("chaosExperiments", "resourceGuards", "rollbackCriteria", "expectedSafeOutputs")
    allowedStatuses = @("not-run", "config-needed", "reviewed", "follow-up-required", "pass")
    allowedFields = @(
      "experiment_id",
      "target_service_ids",
      "status",
      "fault_started_at",
      "fault_finished_at",
      "expected_behavior_observed",
      "rollback_triggered",
      "rollback_reason",
      "safe_request_ids",
      "resource_summary",
      "operator_notes"
    )
    forbiddenReadbackFields = @(
      "secret_value",
      "token",
      "database_url",
      "redis_url",
      "provider_secret",
      "payment_secret",
      "authorization_header",
      "raw_payload",
      "raw_provider_response",
      "raw_dependency_error"
    )
  }
  forbiddenOutputs = @(
    "secret values",
    "tokens",
    "DB URLs",
    "provider secrets",
    "payment secrets",
    "Authorization headers",
    "raw webhook body",
    "raw request or response payload"
  )
  expectedOutputs = @(
    "staging_smoke_summary_json",
    "security_presence_matrix_json",
    "staging_security_review_readback_json",
    "staging_load_plan_readback_json",
    "staging_chaos_plan_readback_json",
    "operator_notes_without_secrets",
    "follow_up_actions_for_real_load_chaos_security_review"
  )
  expectedSafeOutputs = @(
    [ordered]@{ id = "staging_smoke_summary_json"; contains = @("step ids", "statuses", "safe request ids", "route/ledger/trace summaries"); excludes = @("secret values", "tokens", "DB URLs", "Authorization headers", "raw payload") },
    [ordered]@{ id = "security_presence_matrix_json"; contains = @("presence booleans", "config-needed/reviewed statuses", "omitted markers"); excludes = @("Secret data", "real CIDR lists", "provider/payment secret values") },
    [ordered]@{ id = "staging_security_review_readback_json"; contains = @("checklist ids", "allowed statuses", "follow-up notes"); excludes = @("tokens", "DB URLs", "raw headers", "raw payload") },
    [ordered]@{ id = "staging_load_plan_readback_json"; contains = @("traffic model ids", "counts", "latency buckets", "resource summaries", "rollback status"); excludes = @("prompt text", "raw stream chunks", "Redis URL", "raw rate-limit window state") },
    [ordered]@{ id = "staging_chaos_plan_readback_json"; contains = @("experiment ids", "fault window timestamps", "expected behavior status", "rollback status"); excludes = @("DB URLs", "provider raw responses", "raw dependency errors", "secrets") },
    [ordered]@{ id = "operator_notes_without_secrets"; contains = @("decisions", "follow-up owners", "safe ids/prefixes only"); excludes = @("session cookies", "API key secrets", "provider keys", "payment webhook secrets") }
  )
  nonGoals = @(
    "does not deploy to Kubernetes",
    "does not run live staging smoke",
    "does not run load tests",
    "does not run chaos drills",
    "does not run a full security review",
    "does not create release evidence"
  )
  chartDirectory = Get-RepoRelativePath $chartDir
}

$json = $plan | ConvertTo-Json -Depth 20

if ($WriteFile) {
  $parent = Split-Path -Parent $OutputPath
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  Write-Utf8NoBomFile -Path $OutputPath -Content ($json + [Environment]::NewLine)
  Write-Host "staging_smoke_security_plan_status=written"
  Write-Host ("output_path={0}" -f $OutputPath)
  Write-Host "production_gate=false"
  exit 0
}

Write-Output $json
