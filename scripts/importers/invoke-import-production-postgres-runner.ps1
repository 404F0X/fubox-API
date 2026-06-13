[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [string]$ExistingStatePath,

  [string]$TenantId = "00000000-0000-0000-0000-000000000001",

  [string]$ArtifactPath = ".tmp\importers\import_production_postgres_runner_dryrun.json",

  [switch]$ConfirmReviewedPlan,

  [switch]$ProductionDatabaseConfigured,

  [switch]$ProductionAuthorizationConfigured
)

$ErrorActionPreference = "Stop"

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:ApplyPlanScript = Join-Path $script:RepoRoot "scripts\importers\import-apply-plan.ps1"
$script:TenantId = $TenantId

function Convert-ToArray {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [string]) { return @($Value) }
  if ($Value -is [System.Collections.IEnumerable]) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Value) { [void]$items.Add($item) }
    return @($items.ToArray())
  }
  return @($Value)
}

function ConvertTo-JsonText {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return "null" }
  return ($Value | ConvertTo-Json -Depth 96 -Compress)
}

function Get-StableHash {
  param(
    [AllowNull()][object]$Value,
    [int]$Length = 16
  )

  $text = if ($Value -is [string]) { [string]$Value } else { ConvertTo-JsonText $Value }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
  } finally {
    $sha.Dispose()
  }
  $hash = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").ToLowerInvariant()
  if ($Length -gt 0 -and $Length -lt $hash.Length) { return $hash.Substring(0, $Length) }
  return $hash
}

function Redact-SecretLikeString {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return $null }
  $text = [string]$Value
  $text = $text -replace "\$\{[A-Za-z_][A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|DATABASE_URL|DB_URL)[A-Za-z0-9_]*\}", "<redacted-env>"
  $text = $text -replace "(?i)\benv:[A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|DATABASE_URL|DB_URL)[A-Z0-9_]*\b", "env:<redacted>"
  $text = $text -replace "sk-[A-Za-z0-9_-]+", "<redacted>"
  $text = $text -replace "(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", '$1<redacted>'
  $text = $text -replace "(?i)(api[_-]?key|authorization|bearer|token|secret|password|database_url|db_url)=([^&\s""]+)", '$1=<redacted>'
  $text = $text -replace "://([^:/@\s]+):([^/@\s]+)@", "://<redacted>@"
  return $text
}

function Convert-ToSafeObject {
  param(
    [AllowNull()][object]$Value,
    [string]$FieldName = ""
  )

  if ($null -eq $Value) { return $null }
  if ($FieldName -match "(?i)(^|_)(input|output|cache_read|cache_write|reasoning|max_output)_tokens?$") {
    return $Value
  }
  if ($FieldName -match "(?i)(api[_-]?key|authorization|bearer|token|secret|password|encrypted_secret|raw_payload|payload|database_url|db_url|url)$") {
    return "<redacted>"
  }
  if ($Value -is [string]) { return Redact-SecretLikeString $Value }
  if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double]) {
    return $Value
  }
  if ($Value -is [System.Collections.IDictionary]) {
    $safe = [ordered]@{}
    foreach ($key in $Value.Keys) {
      $keyText = [string]$key
      $safe[$keyText] = Convert-ToSafeObject $Value[$key] $keyText
    }
    return $safe
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Value) { [void]$items.Add((Convert-ToSafeObject $item $FieldName)) }
    return @($items.ToArray())
  }
  $safeObject = [ordered]@{}
  foreach ($property in $Value.PSObject.Properties) {
    $safeObject[$property.Name] = Convert-ToSafeObject $property.Value $property.Name
  }
  return $safeObject
}

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
  return (Join-Path $script:RepoRoot $Path)
}

function Get-SafePath {
  param([AllowNull()][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if (-not [System.IO.Path]::IsPathRooted($Path)) { return ($Path -replace "\\", "/") }
  $full = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetFullPath($script:RepoRoot).TrimEnd([char[]]@("\", "/"))
  $rootWithSeparator = $root + [System.IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($full.Substring($rootWithSeparator.Length) -replace "\\", "/")
  }
  return [System.IO.Path]::GetFileName($full)
}

function Invoke-ReviewedApplyPlan {
  $arguments = @{
    InputPath = $InputPath
    Apply = $true
    Force = $true
    TenantId = $script:TenantId
  }
  if (-not [string]::IsNullOrWhiteSpace($ExistingStatePath)) {
    $arguments["ExistingStatePath"] = $ExistingStatePath
  }

  $raw = (& $script:ApplyPlanScript @arguments | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "import-apply-plan produced no output"
  }
  return ($raw | ConvertFrom-Json)
}

function New-ExecutionGraph {
  param([Parameter(Mandatory = $true)]$Plan)

  $nodes = New-Object System.Collections.Generic.List[object]
  $edges = New-Object System.Collections.Generic.List[object]
  [void]$nodes.Add([ordered]@{ id = "preflight"; kind = "guard"; status = [string]$Plan.preflight.status })
  [void]$nodes.Add([ordered]@{ id = "begin_transaction"; kind = "phase"; database_writes = $false })
  [void]$edges.Add([ordered]@{ from = "preflight"; to = "begin_transaction"; guard = "preflight_status_pass" })

  $previous = "begin_transaction"
  foreach ($operationPlan in @(Convert-ToArray $Plan.sql_executor_plan.transaction.operation_plans)) {
    $operationId = [string]$operationPlan.operation_id
    $nodeId = "operation:$operationId"
    [void]$nodes.Add([ordered]@{
        id = $nodeId
        kind = "operation"
        operation_id = $operationId
        action = [string]$operationPlan.action
        target = Convert-ToSafeObject $operationPlan.target
        adapter = [string]$operationPlan.adapter
        supported = [bool]$operationPlan.supported
        statement_phases = @(Convert-ToArray $operationPlan.statements | ForEach-Object { [string]$_.phase })
        raw_sql_omitted = $true
      })
    [void]$edges.Add([ordered]@{ from = $previous; to = $nodeId; guard = "rollback_journal_entry_persisted_before_mutation" })
    $previous = $nodeId
  }

  [void]$nodes.Add([ordered]@{ id = "commit_or_refuse"; kind = "phase"; database_writes = $false })
  [void]$edges.Add([ordered]@{ from = $previous; to = "commit_or_refuse"; guard = "all_operation_guards_pass" })

  return [ordered]@{
    schema_version = "importer.production-postgres.execution-graph.v1"
    dry_run = $true
    live_database_connection = $false
    database_writes = $false
    nodes = @($nodes.ToArray())
    edges = @($edges.ToArray())
  }
}

function New-RollbackGuard {
  param([Parameter(Mandatory = $true)]$Plan)

  return [ordered]@{
    schema_version = "importer.production-postgres.rollback-guard.v1"
    enabled_for_real_execution = $false
    reason = "production runner dry-run guard only; no live PostgreSQL connection or rollback mutation is opened"
    rollback_snapshot_idempotency_key_fingerprint = Get-StableHash ([string]$Plan.sql_executor_plan.rollback_snapshot_idempotency_key) 16
    rollback_execution_order = [string]$Plan.sql_executor_plan.rollback_operation_plan.execution_order
    required_before_real_apply = @(
      "reviewed apply-plan confirmed",
      "production DB connection injected by deployment secret",
      "production authorization granted by operator policy",
      "rollback journal tables available",
      "before-image persisted before each mutation",
      "current target state matches after_hash before rollback replay"
    )
    journal_tables = @(Convert-ToArray $Plan.sql_executor_plan.journal_contract.sql_plan.tables)
    operation_count = @(Convert-ToArray $Plan.sql_executor_plan.rollback_operation_plan.operation_skeletons).Count
    operation_guards = @(Convert-ToArray $Plan.sql_executor_plan.rollback_operation_plan.operation_skeletons | ForEach-Object {
        [ordered]@{
          operation_id = [string]$_.operation_id
          rollback_sequence = [int]$_.rollback_sequence
          target_kind = [string]$_.target.kind
          future_adapter = [string]$_.compensating_mutation_contract.future_adapter
          database_writes = $false
          raw_sql_omitted = $true
          replay_guard = "current target state still matches after_hash or replay must refuse"
        }
      })
  }
}

function New-IdempotencyReadback {
  param([Parameter(Mandatory = $true)]$Plan)

  return [ordered]@{
    schema_version = "importer.production-postgres.idempotency-readback.v1"
    plan_key_fingerprint = Get-StableHash ([string]$Plan.sql_executor_plan.plan_idempotency_key) 16
    rollback_snapshot_key_fingerprint = Get-StableHash ([string]$Plan.sql_executor_plan.rollback_snapshot_idempotency_key) 16
    manifest_key_fingerprint = Get-StableHash ([string]$Plan.sql_executor_plan.idempotency_manifest_key) 16
    operation_count = @(Convert-ToArray $Plan.idempotency_manifest.entries).Count
    raw_idempotency_keys_omitted = $true
    operation_fingerprints = @(Convert-ToArray $Plan.idempotency_manifest.entries | ForEach-Object {
        [ordered]@{
          operation_id = [string]$_.operation_id
          target_kind = [string]$_.target.kind
          idempotency_key_fingerprint = Get-StableHash ([string]$_.idempotency_key) 16
          target_natural_key_hash = [string]$_.target.natural_key_hash
        }
      })
  }
}

function New-ForbiddenFieldsPolicy {
  return [ordered]@{
    schema_version = "importer.production-postgres.forbidden-fields-policy.v1"
    policy = "deny_raw_secret_and_mutation_material"
    forbidden_fields = @(
      "database_url",
      "db_url",
      "postgres_url",
      "authorization",
      "bearer_token",
      "access_token",
      "refresh_token",
      "provider_api_key",
      "provider_key",
      "raw_provider_key",
      "raw_user_key",
      "encrypted_secret",
      "raw_sql",
      "raw_payload",
      "raw_request_body",
      "raw_response_body"
    )
    allowed_replacements = @(
      "repo-relative input path",
      "reviewed plan SHA-256 hash",
      "short idempotency fingerprints",
      "operation ids",
      "target kind/natural key hashes",
      "statement phase names without SQL text",
      "approval and blocker enums"
    )
    artifact_write_guard = "refuse_if_secret_like_material_or_postgres_url_is_detected"
    database_write_policy = "forbidden_in_this_runner"
    live_connection_policy = "forbidden_by_default"
    raw_sql_policy = "omit; emit statement phases only"
  }
}

function New-OperatorApprovalPacket {
  param(
    [AllowNull()][object]$Plan,
    [Parameter(Mandatory = $true)][string[]]$BlockedReasons,
    [Parameter(Mandatory = $true)][object]$ForbiddenFieldsPolicy
  )

  $planHash = $null
  $planFingerprint = $null
  $rollbackSummary = $null
  $idempotencySummary = $null
  if ($null -ne $Plan) {
    $safePlanText = Redact-SecretLikeString (ConvertTo-JsonText $Plan)
    $planHash = Get-StableHash $safePlanText 64
    $planFingerprint = Get-StableHash $safePlanText 16
    $rollbackSummary = [ordered]@{
      rollback_snapshot_idempotency_key_fingerprint = Get-StableHash ([string]$Plan.sql_executor_plan.rollback_snapshot_idempotency_key) 16
      rollback_execution_order = [string]$Plan.sql_executor_plan.rollback_operation_plan.execution_order
      journal_tables = @(Convert-ToArray $Plan.sql_executor_plan.journal_contract.sql_plan.tables)
      operation_count = @(Convert-ToArray $Plan.sql_executor_plan.rollback_operation_plan.operation_skeletons).Count
      before_image_required = $true
      replay_guard = "current target state must match after_hash before rollback replay"
      live_rollback_executed = $false
    }
    $idempotencySummary = [ordered]@{
      plan_key_fingerprint = Get-StableHash ([string]$Plan.sql_executor_plan.plan_idempotency_key) 16
      rollback_snapshot_key_fingerprint = Get-StableHash ([string]$Plan.sql_executor_plan.rollback_snapshot_idempotency_key) 16
      manifest_key_fingerprint = Get-StableHash ([string]$Plan.sql_executor_plan.idempotency_manifest_key) 16
      operation_count = @(Convert-ToArray $Plan.idempotency_manifest.entries).Count
      raw_idempotency_keys_omitted = $true
    }
  }

  return [ordered]@{
    schema_version = "importer.production-postgres.operator-approval-packet.v1"
    packet_status = if ($BlockedReasons.Count -eq 0) { "ready_for_operator_review_but_no_write" } else { "blocked_waiting_external_approval_inputs" }
    purpose = "operator review packet for production PostgreSQL import; this runner never performs production writes"
    required_approvals = @(
      [ordered]@{
        approval = "reviewed_apply_plan"
        required = $true
        provided = [bool]$ConfirmReviewedPlan
        evidence = "reviewed_plan_hash_sha256"
      }
      [ordered]@{
        approval = "production_database_secret_configured"
        required = $true
        provided = [bool]$ProductionDatabaseConfigured
        evidence = "external secret/config presence only; value must not be pasted into this runner"
      }
      [ordered]@{
        approval = "operator_production_authorization"
        required = $true
        provided = [bool]$ProductionAuthorizationConfigured
        evidence = "operator/change-management authorization outside this artifact"
      }
      [ordered]@{
        approval = "approved_execution_window_or_change_ticket"
        required = $true
        provided = $false
        evidence = "external Ops ticket/window; intentionally not represented by a secret or token"
      }
      [ordered]@{
        approval = "rollback_guard_reviewed"
        required = $true
        provided = ($null -ne $rollbackSummary)
        evidence = "rollback_guard_summary"
      }
    )
    reviewed_plan_hash_sha256 = $planHash
    reviewed_plan_fingerprint = $planFingerprint
    input_path = Get-SafePath $InputPath
    existing_state_path = Get-SafePath $ExistingStatePath
    tenant_id = $script:TenantId
    rollback_guard_summary = $rollbackSummary
    idempotency_summary = $idempotencySummary
    blocked_reasons = @($BlockedReasons | Sort-Object -Unique)
    safe_command_template = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/importers/invoke-import-production-postgres-runner.ps1 -InputPath <reviewed-apply-plan-or-source-report-path> -ExistingStatePath <optional-reviewed-existing-state-path> -TenantId <tenant-uuid> -ConfirmReviewedPlan -ProductionDatabaseConfigured -ProductionAuthorizationConfigured"
    safe_command_scope = "approval packet and dry-run readback only; no DB URL, no token, no provider key, no raw SQL, no production write"
    forbidden_fields_policy = $ForbiddenFieldsPolicy
    production_write_executed = $false
    live_database_connection = $false
    database_writes = $false
    rollback_writes = $false
  }
}

function New-ApplyPlanReadback {
  param(
    [AllowNull()][object]$Plan,
    [Parameter(Mandatory = $true)][string[]]$BlockedReasons,
    [AllowNull()][object]$OperatorApprovalPacket
  )

  $safePlanText = if ($null -eq $Plan) { $null } else { Redact-SecretLikeString (ConvertTo-JsonText $Plan) }
  $planHash = if ($null -ne $OperatorApprovalPacket -and $null -ne $OperatorApprovalPacket.reviewed_plan_hash_sha256) {
    [string]$OperatorApprovalPacket.reviewed_plan_hash_sha256
  } elseif ($null -eq $safePlanText) {
    $null
  } else {
    Get-StableHash $safePlanText 64
  }
  $idempotencyFingerprint = if ($null -ne $OperatorApprovalPacket) {
    $OperatorApprovalPacket.idempotency_summary
  } elseif ($null -eq $Plan) {
    $null
  } else {
    [ordered]@{
      plan_key_fingerprint = Get-StableHash ([string]$Plan.sql_executor_plan.plan_idempotency_key) 16
      rollback_snapshot_key_fingerprint = Get-StableHash ([string]$Plan.sql_executor_plan.rollback_snapshot_idempotency_key) 16
      manifest_key_fingerprint = Get-StableHash ([string]$Plan.sql_executor_plan.idempotency_manifest_key) 16
      raw_idempotency_keys_omitted = $true
    }
  }
  $operationCount = if ($null -eq $Plan) { 0 } else { @(Convert-ToArray $Plan.sql_executor_plan.transaction.operation_plans).Count }
  $journalPresent = ($null -ne $Plan -and $null -ne $Plan.sql_executor_plan.journal_contract)
  $nextAction = if ($BlockedReasons.Count -eq 0) {
    "[!] hand off reviewed apply-plan readback to operator; real production DB connection and approved operator window remain external gaps"
  } else {
    "Resolve blocked_reasons and rerun this dry-run readback; do not paste DB URLs, raw SQL, raw user keys, provider keys, Authorization, or secrets."
  }

  return [ordered]@{
    schema_version = "control_plane.importer_apply_plan_readback.v1"
    status = if ($BlockedReasons.Count -eq 0) { "readback-ready" } else { "blocked" }
    plan_hash = $planHash
    idempotency_fingerprint = $idempotencyFingerprint
    apply_result = [ordered]@{
      applied_row_counts = [ordered]@{
        importer_apply_runs = 0
        importer_apply_operation_journal = 0
        target_rows = 0
        planned_operation_count = $operationCount
      }
      db_writes_performed = $false
      production_db_apply_performed = $false
      raw_sql_returned = $false
    }
    rollback_result = [ordered]@{
      rollback_journal_ref_present = [bool]$journalPresent
      rollback_db_writes_performed = $false
      raw_sql_returned = $false
    }
    applied_row_counts = [ordered]@{
      importer_apply_runs = 0
      importer_apply_operation_journal = 0
      target_rows = 0
      planned_operation_count = $operationCount
    }
    rollback_journal_ref_present = [bool]$journalPresent
    blocked_reasons = @($BlockedReasons | Sort-Object -Unique)
    safe_next_action = $nextAction
    db_writes_performed = $false
    readback_source = "local_demo_or_operator_handoff"
    db_url_returned = $false
    raw_sql_returned = $false
    raw_user_key_returned = $false
    provider_key_returned = $false
    authorization_returned = $false
    secret_returned = $false
    secret_safe = $true
  }
}

function Write-Artifact {
  param([Parameter(Mandatory = $true)]$Artifact)
  $full = Resolve-RepoPath $ArtifactPath
  $dir = Split-Path -Parent $full
  if (-not (Test-Path -LiteralPath $dir)) {
    [void](New-Item -ItemType Directory -Force -Path $dir)
  }

  $json = $Artifact | ConvertTo-Json -Depth 96
  $safeJson = Redact-SecretLikeString $json
  if ($safeJson -match "sk-[A-Za-z0-9_-]+" -or
      $safeJson -match "(?i)authorization\s*[:=]\s*(`"Bearer|Bearer)\s+[A-Za-z0-9._~+/=-]{8,}" -or
      $safeJson -match "(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}" -or
      $safeJson -match "(?i)(postgres|postgresql)://[^`"\s]+") {
    throw "Refusing to write production PostgreSQL runner artifact because it still contains secret-like material."
  }
  Set-Content -LiteralPath $full -Value $safeJson -Encoding UTF8
}

$status = "blocked"
$plan = $null
$blockers = New-Object System.Collections.Generic.List[string]

try {
  if (-not (Test-Path -LiteralPath $script:ApplyPlanScript -PathType Leaf)) {
    throw "apply plan script is missing"
  }

  $plan = Invoke-ReviewedApplyPlan
  if (-not $ConfirmReviewedPlan) {
    [void]$blockers.Add("reviewed_apply_plan_confirmation_missing")
  }
  if ([string]$plan.preflight.status -ne "pass") {
    [void]$blockers.Add("apply_plan_preflight_not_pass")
  }
  if ([string]$plan.sql_executor_plan.executor_status -ne "prepared_sql_plan") {
    [void]$blockers.Add("apply_plan_not_prepared_sql_plan")
  }
  foreach ($operationPlan in @(Convert-ToArray $plan.sql_executor_plan.transaction.operation_plans)) {
    if (-not [bool]$operationPlan.supported) {
      [void]$blockers.Add("unsupported_operation:$($operationPlan.operation_id)")
    }
  }
} catch {
  $status = "fail"
  [void]$blockers.Add($_.Exception.Message)
}

if (-not $ProductionDatabaseConfigured) {
  [void]$blockers.Add("production_database_connection_disabled_by_default")
}
if (-not $ProductionAuthorizationConfigured) {
  [void]$blockers.Add("production_authorization_missing")
}

$forbiddenFieldsPolicy = New-ForbiddenFieldsPolicy
$blockedReasons = @($blockers.ToArray() | Sort-Object -Unique)
$operatorApprovalPacket = New-OperatorApprovalPacket `
  -Plan $plan `
  -BlockedReasons $blockedReasons `
  -ForbiddenFieldsPolicy $forbiddenFieldsPolicy

$artifact = [ordered]@{
  importer = "import-production-postgres-runner"
  schema = "importer_production_postgres_runner_dryrun.v1"
  schema_version = "importer.production-postgres-runner-dryrun.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("O")
  status = if ($status -eq "fail") { "fail" } elseif ($blockers.Count -eq 0) { "ready_blocked_by_policy" } else { "blocked" }
  dry_run = $true
  input_path = Get-SafePath $InputPath
  existing_state_path = Get-SafePath $ExistingStatePath
  tenant_id = $script:TenantId
  entrypoint = "scripts/importers/invoke-import-production-postgres-runner.ps1"
  reviewed_plan_confirmed = [bool]$ConfirmReviewedPlan
  live_database_connection = $false
  production_database_configured = [bool]$ProductionDatabaseConfigured
  production_authorization_configured = [bool]$ProductionAuthorizationConfigured
  database_writes = $false
  rollback_writes = $false
  provider_key_material_allowed = $false
  raw_user_key_material_allowed = $false
  db_url_omitted = $true
  authorization_omitted = $true
  raw_sql_omitted = $true
  raw_payload_omitted = $true
  forbidden_fields_policy = $forbiddenFieldsPolicy
  secret_safe = $true
  plan_readback = if ($null -eq $plan) { $null } else { [ordered]@{
      schema_version = [string]$plan.schema_version
      preflight_status = [string]$plan.preflight.status
      transaction_id = [string]$plan.transaction_contract.transaction_id
      executor_status = [string]$plan.sql_executor_plan.executor_status
      operation_count = @(Convert-ToArray $plan.sql_executor_plan.transaction.operation_plans).Count
      planned_creates = [int]$plan.counts.planned_creates
      planned_updates = [int]$plan.counts.planned_updates
      planned_skips = [int]$plan.counts.planned_skips
      adapters = @(Convert-ToArray $plan.sql_executor_plan.transaction.operation_plans | ForEach-Object { [string]$_.adapter })
    } }
  execution_graph = if ($null -eq $plan) { $null } else { New-ExecutionGraph $plan }
  rollback_guard = if ($null -eq $plan) { $null } else { New-RollbackGuard $plan }
  idempotency_fingerprint = if ($null -eq $plan) { $null } else { New-IdempotencyReadback $plan }
  operator_approval_packet = $operatorApprovalPacket
  apply_plan_readback = New-ApplyPlanReadback `
    -Plan $plan `
    -BlockedReasons $blockedReasons `
    -OperatorApprovalPacket $operatorApprovalPacket
  blocked_reasons = $blockedReasons
  remaining_external_gaps = @(
    "production PostgreSQL connection secret/config",
    "operator production authorization",
    "approved execution window/change ticket",
    "live DB readback after real apply",
    "live rollback replay readback after real rollback"
  )
}

Write-Artifact $artifact
$artifact | ConvertTo-Json -Depth 96

if ($status -eq "fail") {
  exit 1
}
