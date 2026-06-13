param(
  [string]$GatewayArtifactPath = ".tmp/paid-beta/e8_gateway_paid_hot_path.json",
  [string]$OutputPath = ".tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [switch]$SelfTest,
  [int]$BlockedExitCode = 2
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$contractFixturePath = Join-Path $repoRoot "tests\fixtures\billing\control_plane_paid_ledger_readback_contract.json"
$acceptedGatewayFixturePath = Join-Path $repoRoot "tests\fixtures\billing\control_plane_paid_gateway_hot_path_artifact.accepted_shape.json"
$requiredGatewayFixturePath = Join-Path $repoRoot "tests\fixtures\billing\control_plane_paid_gateway_hot_path_artifact.required_shape.json"
$readbackSqlPath = Join-Path $repoRoot "scripts\operator\control_plane_paid_ledger_reconciliation_readback.sql"
$requiredEvidence = @(
  "gateway_hot_path_reserve_settle_refund",
  "insufficient_balance_prevents_provider_call",
  "settle_idempotency",
  "refund_idempotency",
  "post_commit_readback",
  "rollback_proof",
  "reconciliation_report"
)
$controlPlaneComposerEvidence = @(
  "post_commit_readback",
  "rollback_proof",
  "reconciliation_report"
)

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "missing $Path"
  }
  Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-CurrentGitCommit {
  try {
    $commit = & git -C $repoRoot rev-parse HEAD 2>$null
    if (-not [string]::IsNullOrWhiteSpace($commit)) {
      return [string]$commit.Trim()
    }
  } catch {
  }
  return "unavailable"
}

function Resolve-RepoFilePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $repoRootString = [System.IO.Path]::GetFullPath([string]$repoRoot)
  $candidate = $Path
  if (-not [System.IO.Path]::IsPathRooted($candidate)) {
    $candidate = Join-Path $repoRootString $candidate
  }
  $fullPath = [System.IO.Path]::GetFullPath($candidate)
  $repoPrefix = $repoRootString.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "artifact path must stay inside repo"
  }
  if ([System.IO.Directory]::Exists($fullPath)) {
    throw "artifact path must be a file"
  }
  return $fullPath
}

function Resolve-OutputArtifactPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = Resolve-RepoFilePath $Path
  $repoRootString = [System.IO.Path]::GetFullPath([string]$repoRoot)
  $relative = [System.IO.Path]::GetRelativePath($repoRootString, $fullPath)
  $normalized = $relative -replace '\\', '/'
  if (-not ($normalized.StartsWith(".tmp/", [System.StringComparison]::OrdinalIgnoreCase) -or $normalized.StartsWith("artifacts/", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "output path must be repo-bounded under .tmp/ or artifacts/"
  }
  return [ordered]@{
    FullPath = $fullPath
    RelativePath = $normalized
    AllowedRoot = if ($normalized.StartsWith(".tmp/", [System.StringComparison]::OrdinalIgnoreCase)) { ".tmp" } else { "artifacts" }
  }
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) {
    return $true
  }
  foreach ($pattern in @(
      '(?i)authorization\s*[:=]',
      '(?i)bearer\s+[A-Za-z0-9._~+/\-]+=*',
      '(?i)cookie\s*[:=]',
      '(?i)provider[_-]?key\s*[:=]',
      '(?i)virtual[_-]?key\s*[:=]',
      '(?i)database[_-]?url\s*[:=]',
      '(?i)postgres(?:ql)?://',
      '(?i)password\s*[:=]',
      'sk-[A-Za-z0-9]{8,}'
    )) {
    if ($Text -match $pattern) {
      return $false
    }
  }
  return $true
}

function Get-JsonPropertyNames {
  param([AllowNull()]$Object)
  if ($null -eq $Object -or $null -eq $Object.PSObject) {
    return @()
  }
  return @($Object.PSObject.Properties.Name)
}

function Get-EvidenceItems {
  param([Parameter(Mandatory = $true)]$Artifact)
  $items = @()
  if ((Get-JsonPropertyNames $Artifact) -contains "evidence") {
    $items += @($Artifact.evidence)
  }
  if ((Get-JsonPropertyNames $Artifact) -contains "operations") {
    $items += @($Artifact.operations)
  }
  return @($items)
}

function Get-GatewayArtifactStatus {
  param([Parameter(Mandatory = $true)]$Artifact)
  foreach ($field in @("overall_status", "status")) {
    if ((Get-JsonPropertyNames $Artifact) -contains $field) {
      $value = [string]$Artifact.$field
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        return $value
      }
    }
  }
  return "unknown"
}

function Get-GatewayArtifactSchema {
  param([Parameter(Mandatory = $true)]$Artifact)
  foreach ($field in @("schema_version", "schema")) {
    if ((Get-JsonPropertyNames $Artifact) -contains $field) {
      $value = [string]$Artifact.$field
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        return $value
      }
    }
  }
  return "unknown"
}

function New-EvidenceMap {
  param([string[]]$AcceptedEvidence)
  $map = [ordered]@{}
  foreach ($name in $requiredEvidence) {
    $map[$name] = @($AcceptedEvidence) -contains $name
  }
  return $map
}

function Get-RequestIds {
  param([Parameter(Mandatory = $true)]$Items)
  @($Items | ForEach-Object { [string]$_.request_id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-InsufficientRequestIds {
  param([Parameter(Mandatory = $true)]$Items)
  @($Items | Where-Object { [string]$_.evidence_key -eq "insufficient_balance_prevents_provider_call" } | ForEach-Object { [string]$_.request_id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Find-ParsedEvidenceItem {
  param(
    [Parameter(Mandatory = $true)]$Items,
    [Parameter(Mandatory = $true)][string]$EvidenceKey
  )
  foreach ($item in @($Items)) {
    if ([string]$item.evidence_key -eq $EvidenceKey) {
      return $item
    }
  }
  return $null
}

function Test-UuidText {
  param([AllowNull()][string]$Value)
  return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

function Test-GatewayPaidArtifactShape {
  param(
    [Parameter(Mandatory = $true)]$Artifact,
    [Parameter(Mandatory = $true)][string]$RawText
  )

  $refusals = New-Object System.Collections.Generic.List[string]
  if (-not (Test-SecretSafeText $RawText)) {
    [void]$refusals.Add("raw_secret_marker_present")
  }
  if ([string]::IsNullOrWhiteSpace((Get-GatewayArtifactSchema -Artifact $Artifact)) -or (Get-GatewayArtifactSchema -Artifact $Artifact) -eq "unknown") {
    [void]$refusals.Add("schema_missing")
  }
  if ([string]::IsNullOrWhiteSpace((Get-GatewayArtifactStatus -Artifact $Artifact)) -or (Get-GatewayArtifactStatus -Artifact $Artifact) -eq "unknown") {
    [void]$refusals.Add("status_missing")
  }
  if ([string]::IsNullOrWhiteSpace([string]$Artifact.smoke_run_id)) {
    [void]$refusals.Add("smoke_run_id_missing")
  }
  foreach ($flag in @("raw_secret_present", "credential_material_echoed", "database_url_echoed", "provider_key_echoed", "virtual_key_echoed")) {
    if ((Get-JsonPropertyNames $Artifact.secret_safe) -contains $flag) {
      if ([bool]$Artifact.secret_safe.$flag) {
        [void]$refusals.Add("secret_safe_flag_failed:$flag")
      }
    }
  }

  $items = @(Get-EvidenceItems -Artifact $Artifact)
  if ($items.Count -eq 0) {
    [void]$refusals.Add("gateway_paid_hot_path_artifact_empty")
  }

  $accepted = New-Object System.Collections.Generic.List[string]
  $seen = New-Object System.Collections.Generic.HashSet[string]
  foreach ($item in $items) {
    $key = ([string]$item.evidence_key).Trim()
    if (-not $seen.Add($key)) {
      [void]$refusals.Add("duplicate_evidence_key:$key")
    }
    if (@($requiredEvidence) -notcontains $key) {
      [void]$refusals.Add("unknown_evidence_key:$key")
      continue
    }
    if ([string]$item.status -ne "passed" -or -not [bool]$item.passed) {
      [void]$refusals.Add("evidence_not_passed:$key")
      continue
    }
    if (-not (Test-UuidText ([string]$item.request_id))) {
      [void]$refusals.Add("request_id_missing_or_invalid:$key")
      continue
    }
    if ([string]::IsNullOrWhiteSpace([string]$item.operation)) {
      [void]$refusals.Add("operation_missing:$key")
      continue
    }
    if (-not (Test-UuidText ([string]$item.operation_id))) {
      [void]$refusals.Add("operation_id_missing_or_invalid:$key")
      continue
    }
    if (($key -in @("gateway_hot_path_reserve_settle_refund", "settle_idempotency", "post_commit_readback", "rollback_proof", "reconciliation_report")) -and
      (Test-UuidText ([string]$item.operation_id)) -and
      [string]$item.operation_id -ne [string]$item.request_id) {
      [void]$refusals.Add("operation_id_request_id_mismatch:$key")
      continue
    }
    if ($key -eq "insufficient_balance_prevents_provider_call" -and [bool]$item.provider_call_expected) {
      [void]$refusals.Add("insufficient_balance_provider_call_expected_true")
      continue
    }
    if ($key -eq "settle_idempotency") {
      $expectedKey = "settle:$([string]$item.request_id)"
      if (-not [string]::IsNullOrWhiteSpace([string]$item.expected_idempotency_key) -and [string]$item.expected_idempotency_key -ne $expectedKey) {
        [void]$refusals.Add("settle_idempotency_key_mismatch")
        continue
      }
    }
    if ($key -eq "refund_idempotency") {
      if (-not (Test-UuidText ([string]$item.related_ledger_entry_id)) -or -not (Test-UuidText ([string]$item.refund_operation_id))) {
        [void]$refusals.Add("refund_idempotency_operation_ids_missing")
        continue
      }
      $expectedRefundKey = "refund_partial:$([string]$item.related_ledger_entry_id):$([string]$item.refund_operation_id)"
      if (-not [string]::IsNullOrWhiteSpace([string]$item.expected_idempotency_key) -and [string]$item.expected_idempotency_key -ne $expectedRefundKey) {
        [void]$refusals.Add("refund_idempotency_key_mismatch")
        continue
      }
    }
    [void]$accepted.Add($key)
  }

  $missing = @()
  foreach ($name in $requiredEvidence) {
    if (@($accepted.ToArray()) -notcontains $name) {
      $missing += $name
    }
  }
  if ($missing.Count -gt 0) {
    [void]$refusals.Add("required_evidence_missing_or_invalid")
  }

  return [pscustomobject]@{
    AcceptedEvidence = @($accepted.ToArray() | Sort-Object)
    MissingEvidence = @($missing)
    Refusals = @($refusals.ToArray() | Select-Object -Unique)
    Items = $items
    SecretSafe = (Test-SecretSafeText $RawText) -and @($refusals.ToArray() | Where-Object { $_ -like "secret_safe*" -or $_ -eq "raw_secret_marker_present" }).Count -eq 0
  }
}

function Get-GatewayShapeBlockers {
  param(
    [Parameter(Mandatory = $true)]$Shape
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  if (@($Shape.Refusals | Where-Object { $_ -eq "schema_missing" }).Count -gt 0) {
    [void]$blockers.Add("gateway_paid_hot_path_schema_missing")
  }
  if (@($Shape.Refusals | Where-Object { $_ -eq "status_missing" }).Count -gt 0) {
    [void]$blockers.Add("gateway_paid_hot_path_status_missing")
  }
  if (@($Shape.Refusals | Where-Object { $_ -eq "smoke_run_id_missing" }).Count -gt 0) {
    [void]$blockers.Add("gateway_paid_hot_path_smoke_run_id_missing")
  }
  $artifactEmpty = @($Shape.Refusals | Where-Object { $_ -eq "gateway_paid_hot_path_artifact_empty" }).Count -gt 0
  if ($artifactEmpty -or @($Shape.Refusals | Where-Object { $_ -eq "required_evidence_missing_or_invalid" }).Count -gt 0) {
    [void]$blockers.Add("gateway_paid_hot_path_evidence_mapping_missing")
  }
  if ($artifactEmpty -or @($Shape.Refusals | Where-Object { $_ -like "request_id_missing_or_invalid:*" }).Count -gt 0) {
    [void]$blockers.Add("gateway_paid_hot_path_request_ids_missing")
  }
  if ($artifactEmpty -or @($Shape.Refusals | Where-Object { $_ -like "operation_id_missing_or_invalid:*" -or $_ -like "operation_missing:*" }).Count -gt 0) {
    [void]$blockers.Add("gateway_paid_hot_path_operation_ids_missing")
  }
  return @($blockers.ToArray() | Select-Object -Unique)
}

function Get-ControlPlaneReadbackEvidencePass {
  param(
    [AllowNull()]$SqlReadback,
    [Parameter(Mandatory = $true)][string]$EvidenceKey
  )

  if ($null -eq $SqlReadback -or [string]$SqlReadback.status -ne "readback_complete") {
    return $false
  }
  if ($EvidenceKey -eq "post_commit_readback") {
    return [bool]$SqlReadback.post_commit_readback_passed
  }
  if ($EvidenceKey -eq "rollback_proof") {
    return [bool]$SqlReadback.rollback_readback_passed
  }
  if ($EvidenceKey -eq "reconciliation_report") {
    return [bool]$SqlReadback.reconciliation_report_passed
  }
  return $false
}

function New-ControlPlaneComposerEvidenceItems {
  param(
    [Parameter(Mandatory = $true)]$GatewayItems,
    [AllowNull()]$SqlReadback,
    [AllowNull()][string[]]$Blockers = @()
  )

  $items = New-Object System.Collections.Generic.List[object]
  $readbackComplete = $null -ne $SqlReadback -and [string]$SqlReadback.status -eq "readback_complete"
  $readbackStatus = if ($null -eq $SqlReadback) { "not_run" } else { [string]$SqlReadback.status }
  $readbackBlocker = if ($null -eq $SqlReadback -or [string]::IsNullOrWhiteSpace([string]$SqlReadback.blocker)) {
    if (@($Blockers).Count -gt 0) { [string]@($Blockers)[0] } else { "control_plane_paid_readback_not_complete" }
  } else {
    [string]$SqlReadback.blocker
  }

  foreach ($key in $controlPlaneComposerEvidence) {
    $sourceItem = Find-ParsedEvidenceItem -Items $GatewayItems -EvidenceKey $key
    $requestId = if ($null -eq $sourceItem) { "" } else { [string]$sourceItem.request_id }
    $operationId = if ($null -eq $sourceItem) { "" } else { [string]$sourceItem.operation_id }
    $operation = if ($null -eq $sourceItem -or [string]::IsNullOrWhiteSpace([string]$sourceItem.operation)) { $key } else { [string]$sourceItem.operation }
    $passed = Get-ControlPlaneReadbackEvidencePass -SqlReadback $SqlReadback -EvidenceKey $key
    $status = if ($passed) { "passed" } elseif ($readbackComplete) { "failed" } else { "blocked" }
    [void]$items.Add([ordered]@{
        evidence_key = $key
        status = $status
        passed = [bool]$passed
        evidence_id = "control-plane-paid-readback:$key"
        request_id = $requestId
        operation_id = $operationId
        operation = $operation
        source = "control_plane_paid_readback"
        source_gateway_artifact = "e8_gateway_paid_hot_path"
        source_control_plane_readback = "control_plane_sql_reconciliation"
        control_plane_readback_status = $readbackStatus
        blocker = if ($passed) { "none" } else { $readbackBlocker }
      })
  }
  return @($items.ToArray())
}

function Get-ControlPlaneEvidenceMappingBlockers {
  param([AllowNull()][object[]]$EvidenceItems)

  $blockers = New-Object System.Collections.Generic.List[string]
  foreach ($key in $controlPlaneComposerEvidence) {
    $item = Find-ParsedEvidenceItem -Items @($EvidenceItems) -EvidenceKey $key
    if ($null -eq $item) {
      [void]$blockers.Add("control_plane_paid_readback_evidence_mapping_missing")
      continue
    }
    if ([string]::IsNullOrWhiteSpace([string]$item.request_id) -and
      [string]::IsNullOrWhiteSpace([string]$item.operation_id) -and
      [string]::IsNullOrWhiteSpace([string]$item.evidence_id)) {
      [void]$blockers.Add("control_plane_paid_readback_request_or_operation_ids_missing")
    }
  }
  return @($blockers.ToArray() | Select-Object -Unique)
}

function ConvertTo-RelativeRepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $repoRootString = [System.IO.Path]::GetFullPath([string]$repoRoot)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  return ([System.IO.Path]::GetRelativePath($repoRootString, $fullPath) -replace '\\', '/')
}

function Redact-ReadbackText {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return ""
  }
  return (($Text -replace '(?i)(password|authorization|cookie|provider[_-]?key|virtual[_-]?key|database[_-]?url)\s*[:=]\s*\S+', '$1=[REDACTED]') `
      -replace '(?i)postgres(?:ql)?://\S+', 'postgres://[REDACTED]')
}

function Convert-PsqlJsonOutput {
  param([Parameter(Mandatory = $true)][string]$Text)
  foreach ($line in ($Text -split "`r?`n")) {
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith("{") -or $trimmed.StartsWith("[")) {
      return ($trimmed | ConvertFrom-Json)
    }
  }
  throw "psql_json_output_missing"
}

function New-ReadbackSummary {
  param(
    [string]$Status,
    [string[]]$AcceptedEvidence = @(),
    [string[]]$MissingEvidence = $requiredEvidence,
    [string[]]$Blockers = @(),
    [string[]]$Refusals = @(),
    [object]$GatewayArtifact = $null,
    [object]$SqlReadback = $null,
    [object[]]$EvidenceItems = @(),
    [object]$Diagnostics = $null
  )

  $exitCode = if ($Status -eq "passed" -or $Status -eq "selftest_passed") {
    0
  } elseif ($Status -eq "refused") {
    1
  } else {
    $BlockedExitCode
  }

  [ordered]@{
    schema_version = "control_plane_paid_ledger_readback_verification.v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    script = "scripts/verify_control_plane_paid_ledger_readback.ps1"
    current_commit = Get-CurrentGitCommit
    paid_controlled_beta_user_allowed = $true
    paid_controlled_beta_opened_by_this_check = $false
    overall_status = $Status
    actual_exit_code = $exitCode
    expected_shell_exit_code = $exitCode
    exit_code_contract = "passed/selftest=0; refused=1; blocked=2. If a PowerShell host or runner normalizes any non-zero process exit to 1, QA must use actual_exit_code from this JSON."
    e9_required_evidence = @($requiredEvidence)
    accepted_evidence = @($AcceptedEvidence)
    missing_evidence = @($MissingEvidence)
    readiness_evidence = New-EvidenceMap -AcceptedEvidence $AcceptedEvidence
    blockers = @($Blockers)
    refusal_reasons = @($Refusals)
    evidence = @($EvidenceItems)
    diagnostics = if ($Diagnostics) { $Diagnostics } elseif ($SqlReadback -and (Get-JsonPropertyNames $SqlReadback) -contains "diagnostics") { $SqlReadback.diagnostics } else { [ordered]@{ attempted = $false } }
    gateway_artifact = if ($GatewayArtifact) { $GatewayArtifact } else { [ordered]@{ path_bounded = $false; exists = $false; secret_safe = $false; request_ids_present = $false; operation_ids_present = $false } }
    control_plane_readback = if ($SqlReadback) { $SqlReadback } else { [ordered]@{ attempted = $false; status = "not_run"; ledger_entries_table_present = $false; request_logs_table_present = $false; provider_attempts_table_present = $false; audit_logs_table_present = $false } }
    secret_safe = [ordered]@{
      raw_secret_present = $false
      credential_material_echoed = $false
      database_url_echoed = $false
      provider_key_echoed = $false
      virtual_key_echoed = $false
      output_contains_raw_gateway_artifact = $false
      secret_safe = $true
    }
    side_effects = [ordered]@{
      gateway_modified = $false
      control_plane_business_logic_modified = $false
      live_mutation_executed = $false
      provider_call_executed_by_this_check = $false
    }
  }
}

function Exit-WithReadbackCode {
  param([Parameter(Mandatory = $true)][int]$Code)
  [Environment]::ExitCode = $Code
  $Host.SetShouldExit($Code)
  exit $Code
}

function Write-ReadbackSummary {
  param(
    [Parameter(Mandatory = $true)]$Summary,
    [Parameter(Mandatory = $true)][bool]$WriteOutputArtifact
  )

  if ($WriteOutputArtifact) {
    $resolvedOutput = Resolve-OutputArtifactPath $OutputPath
    $Summary.output_artifact = [ordered]@{
      path_bounded = $true
      allowed_root = [string]$resolvedOutput.AllowedRoot
      path = [string]$resolvedOutput.RelativePath
      written = $false
      raw_gateway_artifact_written = $false
      secret_material_written = $false
    }
    $json = $Summary | ConvertTo-Json -Depth 12
    if (-not (Test-SecretSafeText $json)) {
      throw "output summary failed secret-safe check"
    }
    $parent = Split-Path -Parent ([string]$resolvedOutput.FullPath)
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Set-Content -LiteralPath ([string]$resolvedOutput.FullPath) -Value $json -Encoding UTF8
    $Summary.output_artifact.written = $true
    $json = $Summary | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath ([string]$resolvedOutput.FullPath) -Value $json -Encoding UTF8
    $json
    return
  }

  $Summary | ConvertTo-Json -Depth 12
}

function Invoke-ComposePsqlText {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $docker = Get-DockerCommand
  $output = & $docker @("compose", "-f", $ComposeFile, "exec", "-T", "postgres", "psql", "-U", "ai_gateway", "-d", "ai_gateway") @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    throw "psql_readback_failed:${exitCode}:$(Redact-ReadbackText (($output | Out-String).Trim()))"
  }
  return (($output | Out-String).Trim())
}

function Invoke-ComposePsqlStdin {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptText,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  $docker = Get-DockerCommand
  $output = $ScriptText | & $docker @("compose", "-f", $ComposeFile, "exec", "-T", "postgres", "psql", "-U", "ai_gateway", "-d", "ai_gateway") @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    throw "psql_readback_failed:${exitCode}:$(Redact-ReadbackText (($output | Out-String).Trim()))"
  }
  return (($output | Out-String).Trim())
}

function New-ReadbackDiagnostics {
  param(
    [Parameter(Mandatory = $true)]$Items,
    [string]$Stage = "not_started",
    [string]$Blocker = "none",
    [AllowNull()]$Presence = $null,
    [AllowNull()]$Counts = $null,
    [AllowNull()][string]$ErrorClassification = $null,
    [AllowNull()][string]$ErrorSummary = $null
  )

  $requestIdCount = @(Get-RequestIds -Items $Items).Count
  $insufficientRequestIdCount = @(Get-InsufficientRequestIds -Items $Items).Count
  $diag = [ordered]@{
    attempted = $true
    stage = $Stage
    blocker = $Blocker
    compose_file = (ConvertTo-RelativeRepoPath $ComposeFile)
    compose_service = "postgres"
    database = "ai_gateway"
    schema = "public"
    psql_execution = "docker_compose_exec_stdin"
    host_sql_file = (ConvertTo-RelativeRepoPath $readbackSqlPath)
    host_sql_file_exists = Test-Path -LiteralPath $readbackSqlPath
    container_sql_file_required = $false
    request_id_count = $requestIdCount
    insufficient_request_id_count = $insufficientRequestIdCount
    table_presence_checked = $null -ne $Presence
    table_presence = if ($Presence) {
      [ordered]@{
        ledger_entries = [bool]$Presence.ledger_entries
        request_logs = [bool]$Presence.request_logs
        provider_attempts = [bool]$Presence.provider_attempts
        audit_logs = [bool]$Presence.audit_logs
      }
    } else {
      [ordered]@{}
    }
    counts = if ($Counts) { $Counts } else { [ordered]@{} }
    secret_safe = $true
  }
  if (-not [string]::IsNullOrWhiteSpace($ErrorClassification)) {
    $diag.error_classification = $ErrorClassification
  }
  if (-not [string]::IsNullOrWhiteSpace($ErrorSummary)) {
    $diag.error_summary = Redact-ReadbackText $ErrorSummary
  }
  return $diag
}

function New-BlockedSqlReadbackFromException {
  param(
    [Parameter(Mandatory = $true)]$ErrorRecord,
    [Parameter(Mandatory = $true)]$Items
  )

  $message = [string]$ErrorRecord.Exception.Message
  $classification = ($message -split ":", 2)[0]
  $blocker = "control_plane_paid_readback_query_failed"
  if ($message -match "docker\.exe was not found|docker.*not.*found") {
    $blocker = "control_plane_paid_readback_docker_unavailable"
  } elseif ($message -match "no container found|service .*postgres.* is not running|container .* is not running") {
    $blocker = "control_plane_paid_readback_compose_postgres_unavailable"
  } elseif ($message -match "database .* does not exist|FATAL.*database") {
    $blocker = "control_plane_paid_readback_wrong_database"
  } elseif ($message -match "relation .* does not exist|column .* does not exist") {
    $blocker = "control_plane_paid_readback_schema_mismatch"
  } elseif ($message -match "No such file or directory") {
    $blocker = "control_plane_paid_readback_sql_file_path_unavailable"
  } elseif ($classification -eq "psql_readback_failed") {
    $blocker = "control_plane_paid_readback_psql_failed"
  }

  $diag = New-ReadbackDiagnostics -Items $Items -Stage "sql_exception" -Blocker $blocker -ErrorClassification $classification -ErrorSummary $message
  return [ordered]@{
    attempted = $true
    status = "blocked"
    blocker = $blocker
    error_classification = $classification
    ledger_entries_table_present = $false
    request_logs_table_present = $false
    provider_attempts_table_present = $false
    audit_logs_table_present = $false
    diagnostics = $diag
  }
}

function Invoke-ControlPlanePaidSqlReadback {
  param([Parameter(Mandatory = $true)]$Items)

  $presenceSql = @"
select json_build_object(
  'ledger_entries', to_regclass('public.ledger_entries') is not null,
  'request_logs', to_regclass('public.request_logs') is not null,
  'provider_attempts', to_regclass('public.provider_attempts') is not null,
  'audit_logs', to_regclass('public.audit_logs') is not null
)::text;
"@
  $presenceText = Invoke-ComposePsqlText -Arguments @("-t", "-A", "-v", "ON_ERROR_STOP=1", "-c", $presenceSql)
  $presence = Convert-PsqlJsonOutput $presenceText
  $missingTables = @()
  foreach ($table in @("ledger_entries", "request_logs", "provider_attempts", "audit_logs")) {
    if (-not [bool]$presence.$table) {
      $missingTables += $table
    }
  }
  if ($missingTables.Count -gt 0) {
    $diag = New-ReadbackDiagnostics -Items $Items -Stage "table_presence" -Blocker "control_plane_paid_readback_missing_table" -Presence $presence
    return [ordered]@{
      attempted = $true
      status = "blocked"
      blocker = "control_plane_paid_readback_missing_table"
      missing_tables = @($missingTables)
      ledger_entries_table_present = [bool]$presence.ledger_entries
      request_logs_table_present = [bool]$presence.request_logs
      provider_attempts_table_present = [bool]$presence.provider_attempts
      audit_logs_table_present = [bool]$presence.audit_logs
      diagnostics = $diag
    }
  }

  $requestIds = (Get-RequestIds -Items $Items) -join ","
  $insufficientRequestIds = (Get-InsufficientRequestIds -Items $Items) -join ","
  $sqlScript = Get-Content -LiteralPath $readbackSqlPath -Raw
  $sqlText = Invoke-ComposePsqlStdin -ScriptText $sqlScript -Arguments @(
    "-v", "ON_ERROR_STOP=1",
    "-v", "request_ids=$requestIds",
    "-v", "insufficient_request_ids=$insufficientRequestIds"
  )
  $readback = Convert-PsqlJsonOutput $sqlText
  $counts = [ordered]@{
    ledger_entry_count = [int]$readback.ledger_entry_count
    request_log_count = [int]$readback.request_log_count
    provider_attempt_count = [int]$readback.provider_attempt_count
    audit_count = [int]$readback.audit_count
    reserve_count = [int]$readback.reserve_count
    settle_count = [int]$readback.settle_count
    refund_count = [int]$readback.refund_count
    reversed_count = [int]$readback.reversed_count
    insufficient_provider_attempt_count = [int]$readback.insufficient_provider_attempt_count
  }
  $diag = New-ReadbackDiagnostics -Items $Items -Stage "readback_query" -Blocker "none" -Presence $presence -Counts $counts
  return [ordered]@{
    attempted = $true
    status = "readback_complete"
    ledger_entries_table_present = $true
    request_logs_table_present = $true
    provider_attempts_table_present = $true
    audit_logs_table_present = $true
    reserve_rows_seen = [int]$readback.reserve_count -gt 0
    settle_rows_seen = [int]$readback.settle_count -gt 0
    refund_rows_seen = [int]$readback.refund_count -gt 0
    insufficient_balance_provider_attempts_zero = [bool]$readback.insufficient_balance_provider_attempts_zero
    post_commit_readback_passed = [bool]$readback.post_commit_readback_passed
    rollback_readback_passed = [bool]$readback.rollback_readback_passed
    reconciliation_report_passed = [bool]$readback.reconciliation_report_passed
    counts = $counts
    diagnostics = $diag
  }
}

function Invoke-SelfTest {
  $contract = Read-JsonFile $contractFixturePath
  if ([string]$contract.output_schema -ne "control_plane_paid_ledger_readback_verification.v1") {
    throw "selftest contract output schema mismatch"
  }
  $requiredText = Get-Content -LiteralPath $requiredGatewayFixturePath -Raw
  $requiredArtifact = $requiredText | ConvertFrom-Json
  $requiredShape = Test-GatewayPaidArtifactShape -Artifact $requiredArtifact -RawText $requiredText
  if ($requiredShape.Refusals.Count -ne 0 -or $requiredShape.MissingEvidence.Count -ne 0) {
    throw "required-shape fixture was refused: $($requiredShape.Refusals -join ',')"
  }
  if (@(Get-GatewayShapeBlockers -Shape $requiredShape).Count -ne 0) {
    throw "required-shape fixture produced shape blockers"
  }

  $missingRequestText = $requiredText -replace '"request_id"\s*:\s*"[^"]+",\s*', ''
  $missingRequestShape = Test-GatewayPaidArtifactShape -Artifact ($missingRequestText | ConvertFrom-Json) -RawText $missingRequestText
  if (@(Get-GatewayShapeBlockers -Shape $missingRequestShape) -notcontains "gateway_paid_hot_path_request_ids_missing") {
    throw "missing request ids selftest did not produce machine blocker"
  }

  $missingOperationText = $requiredText -replace '"operation_id"\s*:\s*"[^"]+",\s*', ''
  $missingOperationShape = Test-GatewayPaidArtifactShape -Artifact ($missingOperationText | ConvertFrom-Json) -RawText $missingOperationText
  if (@(Get-GatewayShapeBlockers -Shape $missingOperationShape) -notcontains "gateway_paid_hot_path_operation_ids_missing") {
    throw "missing operation ids selftest did not produce machine blocker"
  }

  $missingEvidenceArtifact = $requiredText | ConvertFrom-Json
  $missingEvidenceArtifact.PSObject.Properties.Remove("evidence")
  $missingEvidenceText = $missingEvidenceArtifact | ConvertTo-Json -Depth 16
  $missingEvidenceShape = Test-GatewayPaidArtifactShape -Artifact $missingEvidenceArtifact -RawText $missingEvidenceText
  if (@(Get-GatewayShapeBlockers -Shape $missingEvidenceShape) -notcontains "gateway_paid_hot_path_evidence_mapping_missing") {
    throw "missing evidence mapping selftest did not produce machine blocker"
  }

  $secretText = $requiredText -replace '"generated_by": "fixture_contract_only"', '"generated_by": "Authorization: Bearer secret-token"'
  $secretArtifact = $secretText | ConvertFrom-Json
  $secret = Test-GatewayPaidArtifactShape -Artifact $secretArtifact -RawText $secretText
  if (@($secret.Refusals) -notcontains "raw_secret_marker_present") {
    throw "secret marker selftest did not refuse artifact"
  }

  $operationMismatchText = $requiredText -replace '00000000-0000-0000-0000-000000040003",\s*"operation": "settle"', '00000000-0000-0000-0000-000000040999", "operation": "settle"'
  $operationMismatch = Test-GatewayPaidArtifactShape -Artifact ($operationMismatchText | ConvertFrom-Json) -RawText $operationMismatchText
  if (@($operationMismatch.Refusals | Where-Object { $_ -like "operation_id_request_id_mismatch:*" }).Count -eq 0) {
    throw "operation id mismatch selftest did not refuse artifact"
  }

  $refundMismatchText = $requiredText -replace 'refund_partial:00000000-0000-0000-0000-000000040204:00000000-0000-0000-0000-000000040104', 'refund_partial:00000000-0000-0000-0000-000000040204:00000000-0000-0000-0000-000000040999'
  $refundMismatch = Test-GatewayPaidArtifactShape -Artifact ($refundMismatchText | ConvertFrom-Json) -RawText $refundMismatchText
  if (@($refundMismatch.Refusals) -notcontains "refund_idempotency_key_mismatch") {
    throw "refund idempotency mismatch selftest did not refuse artifact"
  }

  $completeSqlReadback = [ordered]@{
    attempted = $true
    status = "readback_complete"
    post_commit_readback_passed = $true
    rollback_readback_passed = $true
    reconciliation_report_passed = $true
  }
  $selftestEvidenceItems = New-ControlPlaneComposerEvidenceItems `
    -GatewayItems $requiredShape.Items `
    -SqlReadback $completeSqlReadback `
    -Blockers @()
  if (@(Get-ControlPlaneEvidenceMappingBlockers -EvidenceItems $selftestEvidenceItems).Count -ne 0) {
    throw "composer-required E11 evidence mapping selftest produced blockers"
  }

  $missingE11MappingBlockers = @(Get-ControlPlaneEvidenceMappingBlockers -EvidenceItems @())
  if ($missingE11MappingBlockers -notcontains "control_plane_paid_readback_evidence_mapping_missing") {
    throw "missing E11 evidence mapping selftest did not produce machine blocker"
  }

  $blockedSqlEvidenceItems = New-ControlPlaneComposerEvidenceItems `
    -GatewayItems $requiredShape.Items `
    -SqlReadback ([ordered]@{
      attempted = $true
      status = "blocked"
      blocker = "control_plane_paid_readback_sql_unavailable"
    }) `
    -Blockers @("control_plane_paid_readback_sql_unavailable")
  if (@(Get-ControlPlaneEvidenceMappingBlockers -EvidenceItems $blockedSqlEvidenceItems).Count -ne 0) {
    throw "SQL-unavailable E11 evidence mapping shape selftest produced blockers"
  }
  foreach ($item in @($blockedSqlEvidenceItems)) {
    if ([string]$item.status -ne "blocked" -or [bool]$item.passed) {
      throw "SQL-unavailable E11 evidence item did not remain blocked"
    }
  }

  $missingEvidenceItems = New-ControlPlaneComposerEvidenceItems `
    -GatewayItems @() `
    -SqlReadback $null `
    -Blockers @("gateway_paid_hot_path_artifact_missing")
  $missingSummary = New-ReadbackSummary `
    -Status "blocked" `
    -Blockers @("gateway_paid_hot_path_artifact_missing") `
    -EvidenceItems $missingEvidenceItems
  if (@($missingSummary.blockers) -notcontains "gateway_paid_hot_path_artifact_missing") {
    throw "missing gateway artifact selftest did not produce blocker"
  }

  $summary = New-ReadbackSummary `
    -Status "selftest_passed" `
    -AcceptedEvidence $requiredEvidence `
    -MissingEvidence @() `
    -GatewayArtifact ([ordered]@{
      path_bounded = $true
      exists = $true
      secret_safe = $true
      request_ids_present = $true
      operation_ids_present = $true
    }) `
    -SqlReadback ([ordered]@{
      attempted = $false
      status = "selftest_fixture_only"
      accepted_shape_readback = $true
    }) `
    -EvidenceItems $selftestEvidenceItems
  $summary.selftest_cases = @(
    "required_gateway_artifact_shape_accepted_for_input_parsing",
    "missing_request_ids_refused",
    "missing_operation_ids_refused",
    "missing_evidence_mapping_refused",
    "accepted_realish_shape_includes_composer_required_e11_mapping",
    "missing_e11_mapping_returns_machine_blocker",
    "sql_unavailable_blocked_but_e11_mapping_shape_present",
    "missing_gateway_artifact_refused",
    "raw_secret_marker_refused",
    "mismatched_operation_id_refused",
    "mismatched_refund_idempotency_refused"
  )
  $summary | ConvertTo-Json -Depth 12
}

if ($SelfTest) {
  Invoke-SelfTest
  Exit-WithReadbackCode 0
}

$boundedPath = Resolve-RepoFilePath $GatewayArtifactPath
if (-not (Test-Path -LiteralPath $boundedPath)) {
  $evidenceItems = New-ControlPlaneComposerEvidenceItems `
    -GatewayItems @() `
    -SqlReadback $null `
    -Blockers @("gateway_paid_hot_path_artifact_missing")
  $summary = New-ReadbackSummary `
    -Status "blocked" `
    -Blockers @("gateway_paid_hot_path_artifact_missing") `
    -EvidenceItems $evidenceItems
  $summary.gateway_artifact = [ordered]@{
    path_bounded = $true
    exists = $false
    secret_safe = $false
    request_ids_present = $false
    operation_ids_present = $false
    output_path = "omitted"
  }
  Write-ReadbackSummary -Summary $summary -WriteOutputArtifact $true
  Exit-WithReadbackCode $BlockedExitCode
}

$raw = Get-Content -LiteralPath $boundedPath -Raw
$artifact = $raw | ConvertFrom-Json
$gatewayArtifactStatus = Get-GatewayArtifactStatus -Artifact $artifact
$gatewayArtifactSchema = Get-GatewayArtifactSchema -Artifact $artifact

if ($gatewayArtifactStatus -in @("blocked", "failed", "refused")) {
  $blockedGatewaySummary = [ordered]@{
    path_bounded = $true
    exists = $true
    schema = $gatewayArtifactSchema
    status = $gatewayArtifactStatus
    secret_safe = Test-SecretSafeText $raw
    request_ids_present = $false
    request_id_count = 0
    operation_ids_present = $false
    operation_id_count = 0
    output_path = "omitted"
    raw_artifact_output = "omitted"
  }
  $evidenceItems = New-ControlPlaneComposerEvidenceItems `
    -GatewayItems @() `
    -SqlReadback $null `
    -Blockers @("gateway_paid_hot_path_artifact_blocked")
  $summary = New-ReadbackSummary `
    -Status "blocked" `
    -Blockers @("gateway_paid_hot_path_artifact_blocked") `
    -GatewayArtifact $blockedGatewaySummary `
    -EvidenceItems $evidenceItems
  Write-ReadbackSummary -Summary $summary -WriteOutputArtifact $true
  Exit-WithReadbackCode $BlockedExitCode
}

$shape = Test-GatewayPaidArtifactShape -Artifact $artifact -RawText $raw
$requestIds = @(Get-RequestIds -Items $shape.Items)
$operationIds = @($shape.Items | ForEach-Object { [string]$_.operation_id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$gatewaySummary = [ordered]@{
  path_bounded = $true
  exists = $true
  schema = $gatewayArtifactSchema
  status = $gatewayArtifactStatus
  secret_safe = [bool]$shape.SecretSafe
  request_ids_present = $requestIds.Count -gt 0
  request_id_count = $requestIds.Count
  operation_ids_present = $operationIds.Count -gt 0
  operation_id_count = $operationIds.Count
  output_path = "omitted"
  raw_artifact_output = "omitted"
}

$shapeBlockers = @(Get-GatewayShapeBlockers -Shape $shape)
if ($shapeBlockers.Count -gt 0) {
  $evidenceItems = New-ControlPlaneComposerEvidenceItems `
    -GatewayItems $shape.Items `
    -SqlReadback $null `
    -Blockers $shapeBlockers
  $summary = New-ReadbackSummary `
    -Status "blocked" `
    -AcceptedEvidence $shape.AcceptedEvidence `
    -MissingEvidence $shape.MissingEvidence `
    -Blockers $shapeBlockers `
    -Refusals $shape.Refusals `
    -GatewayArtifact $gatewaySummary `
    -EvidenceItems $evidenceItems
  Write-ReadbackSummary -Summary $summary -WriteOutputArtifact $true
  Exit-WithReadbackCode $BlockedExitCode
}

if ($shape.Refusals.Count -gt 0 -or $shape.MissingEvidence.Count -gt 0) {
  $evidenceItems = New-ControlPlaneComposerEvidenceItems `
    -GatewayItems $shape.Items `
    -SqlReadback $null `
    -Blockers $shape.Refusals
  $summary = New-ReadbackSummary `
    -Status "refused" `
    -AcceptedEvidence $shape.AcceptedEvidence `
    -MissingEvidence $shape.MissingEvidence `
    -Refusals $shape.Refusals `
    -GatewayArtifact $gatewaySummary `
    -EvidenceItems $evidenceItems
  Write-ReadbackSummary -Summary $summary -WriteOutputArtifact $true
  Exit-WithReadbackCode 1
}

try {
  $sqlReadback = Invoke-ControlPlanePaidSqlReadback -Items $shape.Items
} catch {
  $sqlReadback = New-BlockedSqlReadbackFromException -ErrorRecord $_ -Items $shape.Items
}

$accepted = @($shape.AcceptedEvidence)
$missing = @()
$blockers = @()
if ([string]$sqlReadback.status -ne "readback_complete") {
  $blockers += if ([string]::IsNullOrWhiteSpace([string]$sqlReadback.blocker)) { "control_plane_paid_readback_blocked" } else { [string]$sqlReadback.blocker }
} else {
  if (-not [bool]$sqlReadback.reserve_rows_seen) {
    $missing += "gateway_hot_path_reserve_settle_refund"
    $blockers += "control_plane_paid_readback_reserve_rows_missing"
  }
  if (-not [bool]$sqlReadback.settle_rows_seen) {
    $missing += "gateway_hot_path_reserve_settle_refund"
    $blockers += "control_plane_paid_readback_settle_rows_missing"
  }
  if (-not [bool]$sqlReadback.refund_rows_seen) {
    $missing += "gateway_hot_path_reserve_settle_refund"
    $blockers += "control_plane_paid_readback_refund_rows_missing"
  }
  if (-not [bool]$sqlReadback.insufficient_balance_provider_attempts_zero) {
    $missing += "insufficient_balance_prevents_provider_call"
    $blockers += "control_plane_paid_readback_insufficient_balance_provider_attempts_present"
  }
  if (-not [bool]$sqlReadback.post_commit_readback_passed) {
    $missing += "post_commit_readback"
    $blockers += "control_plane_paid_readback_post_commit_missing"
  }
  if (-not [bool]$sqlReadback.rollback_readback_passed) {
    $missing += "rollback_proof"
    $blockers += "control_plane_paid_readback_rollback_missing"
  }
  if (-not [bool]$sqlReadback.reconciliation_report_passed) {
    $missing += "reconciliation_report"
    $blockers += "control_plane_paid_readback_reconciliation_missing"
  }
}

if ($missing.Count -gt 0) {
  $missing = @($missing | Select-Object -Unique)
  $accepted = @($accepted | Where-Object { @($missing) -notcontains $_ })
}

$blockers = @($blockers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
if ($sqlReadback -and $sqlReadback.diagnostics) {
  $sqlReadback.diagnostics.readback_result_blockers = @($blockers)
  if ($blockers.Count -gt 0) {
    $sqlReadback.diagnostics.blocker = [string]$blockers[0]
  }
}

$status = if ($blockers.Count -gt 0) { "blocked" } elseif ($missing.Count -gt 0) { "refused" } else { "passed" }
$evidenceItems = New-ControlPlaneComposerEvidenceItems `
  -GatewayItems $shape.Items `
  -SqlReadback $sqlReadback `
  -Blockers $blockers
$summary = New-ReadbackSummary `
  -Status $status `
  -AcceptedEvidence $accepted `
  -MissingEvidence $missing `
  -Blockers $blockers `
  -GatewayArtifact $gatewaySummary `
  -SqlReadback $sqlReadback `
  -EvidenceItems $evidenceItems `
  -Diagnostics $sqlReadback.diagnostics
Write-ReadbackSummary -Summary $summary -WriteOutputArtifact $true
if ($status -eq "passed") { Exit-WithReadbackCode 0 }
if ($status -eq "refused") { Exit-WithReadbackCode 1 }
Exit-WithReadbackCode $BlockedExitCode
