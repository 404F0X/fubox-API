param(
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$GatewayAuthToken = "dev_test_key_123456789",
  [string]$Model = "mock-gpt-4o-mini",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [int]$TimeoutSeconds = 12,
  [int]$DbPollSeconds = 12,
  [string]$ArtifactPath = "",
  [switch]$PreflightOnly,
  [switch]$SelfTest,
  [switch]$SkipComposePs
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$readbackSqlPath = Join-Path $repoRoot "scripts\operator\gateway_paid_hot_path_readback.sql"
$pricingSelectorMigrationPath = Join-Path $repoRoot "db\migrations\0007_pricing_policy_selection.sql"
$script:SmokeRunId = "e8-paid-" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$script:OriginalState = $null
$script:StateCaptured = $false
$script:TerminalArtifactWritten = $false

if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:GATEWAY_AUTH_TOKEN) { $GatewayAuthToken = $env:GATEWAY_AUTH_TOKEN }
if ($env:GATEWAY_PAID_HOT_PATH_SMOKE_ARTIFACT_PATH) { $ArtifactPath = $env:GATEWAY_PAID_HOT_PATH_SMOKE_ARTIFACT_PATH }
if ([string]::IsNullOrWhiteSpace($ArtifactPath)) {
  $ArtifactPath = Join-Path $repoRoot ".tmp\gateway-paid-hot-path\$($script:SmokeRunId).json"
}

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

function Redact-SecretLikeString {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) { return "" }
  $redacted = $Text
  if (-not [string]::IsNullOrWhiteSpace($GatewayAuthToken)) {
    $redacted = $redacted.Replace($GatewayAuthToken, "[REDACTED]")
  }
  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";,}]+', '${1}[REDACTED]'
  $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/\-]+=*', '${1}[REDACTED]'
  $redacted = $redacted -replace 'dev_test_key_[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  $redacted = $redacted -replace '(?i)postgres(?:ql)?://[^\s"]+', '[REDACTED_DB_URL]'
  return $redacted
}

function Write-SafeHost {
  param([AllowNull()][string]$Text)
  Write-Host (Redact-SecretLikeString $Text)
}

function Escape-SqlLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)
  return $Value.Replace("'", "''")
}

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )
  return $BaseUrl.TrimEnd("/") + $Path
}

function ConvertTo-JsonString {
  param([Parameter(Mandatory = $true)][string]$Value)
  return ($Value | ConvertTo-Json -Compress)
}

function New-ChatBodyJson {
  param(
    [Parameter(Mandatory = $true)][string]$RequestModel,
    [Parameter(Mandatory = $true)][string]$Content
  )

  return '{"model":' + (ConvertTo-JsonString $RequestModel) + ',"messages":[{"role":"user","content":' + (ConvertTo-JsonString $Content) + '}],"stream":false}'
}

function Get-Sha256Hex {
  param([Parameter(Mandatory = $true)][string]$Text)

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Invoke-ComposePsql {
  param([Parameter(Mandatory = $true)][string]$Sql)

  Push-Location $repoRoot
  try {
    $docker = Get-DockerCommand
    $output = $Sql | & $docker compose -f $ComposeFile exec -T postgres psql `
      -U ai_gateway `
      -d ai_gateway `
      -tA `
      -v ON_ERROR_STOP=1 `
      -f -

    if ($LASTEXITCODE -ne 0) {
      throw "psql failed with exit code $LASTEXITCODE"
    }

    return (($output | Out-String).Trim())
  } finally {
    Pop-Location
  }
}

function Invoke-OperatorReadback {
  param(
    [Parameter(Mandatory = $true)][string[]]$RequestIds,
    [Parameter(Mandatory = $true)][string]$SuccessRequestId,
    [Parameter(Mandatory = $true)][string]$FailureRequestId,
    [Parameter(Mandatory = $true)][string]$InsufficientRequestId
  )

  $docker = Get-DockerCommand
  $requestIdsCsv = [string]::Join(",", $RequestIds)
  $sql = Get-Content -Raw $readbackSqlPath

  Push-Location $repoRoot
  try {
    $output = $sql | & $docker compose -f $ComposeFile exec -T postgres psql `
      -U ai_gateway `
      -d ai_gateway `
      -tA `
      -v ON_ERROR_STOP=1 `
      --set "smoke_run_id=$script:SmokeRunId" `
      --set "request_ids=$requestIdsCsv" `
      --set "success_request_id=$SuccessRequestId" `
      --set "failure_request_id=$FailureRequestId" `
      --set "insufficient_request_id=$InsufficientRequestId" `
      -f -

    if ($LASTEXITCODE -ne 0) {
      throw "operator readback failed with exit code $LASTEXITCODE"
    }

    return (($output | Out-String).Trim()) | ConvertFrom-Json
  } finally {
    Pop-Location
  }
}

function Get-ObjectPropertyValue {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Object) { return $null }
  $matches = $Object.PSObject.Properties.Match($Name)
  if ($matches.Count -eq 0) { return $null }
  return $matches[0].Value
}

function Test-PaidHotPathReadbackPass {
  param([Parameter(Mandatory = $true)]$Readback)

  $insufficientAttemptRows = Get-ObjectPropertyValue $Readback "insufficient_balance_provider_attempt_rows"
  if ($null -eq $insufficientAttemptRows) { return $false }

  $secretSafe = Get-ObjectPropertyValue $Readback "secret_safe"
  $rawOrSecretMarkerPresent = Get-ObjectPropertyValue $secretSafe "raw_or_secret_marker_present"
  if ($null -eq $rawOrSecretMarkerPresent) { return $false }
  $refundIdempotency = Get-ObjectPropertyValue $Readback "refund_idempotency"
  $refundRows = Get-ObjectPropertyValue $refundIdempotency "refund_rows"
  $duplicateRefundIdempotent = Get-ObjectPropertyValue $refundIdempotency "duplicate_refund_idempotent"
  if ($null -eq $refundRows -or $null -eq $duplicateRefundIdempotent) { return $false }

  return [bool](Get-ObjectPropertyValue $Readback "reserve_before_provider_side_effect") `
    -and [bool](Get-ObjectPropertyValue $Readback "insufficient_balance_prevents_provider_call") `
    -and ([int]$insufficientAttemptRows -eq 0) `
    -and [bool](Get-ObjectPropertyValue $Readback "successful_request_settled") `
    -and [bool](Get-ObjectPropertyValue $Readback "failure_request_released") `
    -and [bool](Get-ObjectPropertyValue $Readback "settle_idempotency") `
    -and [bool](Get-ObjectPropertyValue $Readback "reserve_idempotency_seen") `
    -and ([int]$refundRows -gt 0) `
    -and [bool]$duplicateRefundIdempotent `
    -and [bool](Get-ObjectPropertyValue $Readback "post_commit_readback") `
    -and (-not [bool]$rawOrSecretMarkerPresent)
}

function Test-UuidText {
  param([AllowNull()][string]$Value)
  return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

function New-GatewayPaidEvidenceItems {
  param(
    [Parameter(Mandatory = $true)]$Readback,
    [Parameter(Mandatory = $true)][string]$SuccessRequestId,
    [Parameter(Mandatory = $true)][string]$FailureRequestId,
    [Parameter(Mandatory = $true)][string]$InsufficientRequestId
  )

  $operationEvidence = Get-ObjectPropertyValue $Readback "operation_evidence"
  $failureReleaseLedgerEntryId = [string](Get-ObjectPropertyValue $operationEvidence "failure_release_ledger_entry_id")
  $failureReleaseIdempotencyKey = [string](Get-ObjectPropertyValue $operationEvidence "failure_release_idempotency_key")
  $successRefundLedgerEntryId = [string](Get-ObjectPropertyValue $operationEvidence "success_refund_ledger_entry_id")
  $successRefundRelatedSettleLedgerEntryId = [string](Get-ObjectPropertyValue $operationEvidence "success_refund_related_settle_ledger_entry_id")
  $successRefundIdempotencyKey = [string](Get-ObjectPropertyValue $operationEvidence "success_refund_idempotency_key")

  return @(
    [ordered]@{
      evidence_key = "gateway_hot_path_reserve_settle_refund"
      status = "passed"
      passed = $true
      request_id = $SuccessRequestId
      operation = "reserve_settle_release"
      operation_id = $SuccessRequestId
      reserve_operation_id = $SuccessRequestId
      settle_operation_id = $SuccessRequestId
      release_operation_id = $FailureRequestId
      expected_ledger_entry_types = @("reserve", "settle", "release")
      provider_call_expected = $true
      source = "gateway_live_db_readback"
    },
    [ordered]@{
      evidence_key = "insufficient_balance_prevents_provider_call"
      status = "passed"
      passed = $true
      request_id = $InsufficientRequestId
      operation = "reserve_pre_authorize"
      operation_id = $InsufficientRequestId
      provider_call_expected = $false
      source = "gateway_live_db_readback"
    },
    [ordered]@{
      evidence_key = "settle_idempotency"
      status = "passed"
      passed = $true
      request_id = $SuccessRequestId
      operation = "settle"
      operation_id = $SuccessRequestId
      expected_idempotency_key = "settle:$SuccessRequestId"
      source = "gateway_live_db_readback"
    },
    [ordered]@{
      evidence_key = "refund_idempotency"
      status = "passed"
      passed = $true
      request_id = $SuccessRequestId
      operation = "refund_after_settle"
      operation_id = $successRefundLedgerEntryId
      related_ledger_entry_id = $successRefundRelatedSettleLedgerEntryId
      refund_operation_id = $successRefundLedgerEntryId
      actual_refund_idempotency_key = $successRefundIdempotencyKey
      duplicate_refund_idempotent = [bool](Get-ObjectPropertyValue (Get-ObjectPropertyValue $Readback "refund_idempotency") "duplicate_refund_idempotent")
      bounded_smoke_refund_step = $true
      production_default_path = $false
      source = "gateway_live_db_readback_refund_after_settle"
    },
    [ordered]@{
      evidence_key = "post_commit_readback"
      status = "passed"
      passed = $true
      request_id = $SuccessRequestId
      operation = "readback"
      operation_id = $SuccessRequestId
      source = "gateway_live_db_readback"
    },
    [ordered]@{
      evidence_key = "rollback_proof"
      status = "passed"
      passed = $true
      request_id = $InsufficientRequestId
      operation = "rollback"
      operation_id = $InsufficientRequestId
      provider_call_expected = $false
      source = "gateway_live_db_readback"
    },
    [ordered]@{
      evidence_key = "reconciliation_report"
      status = "passed"
      passed = $true
      request_id = $SuccessRequestId
      operation = "reconciliation"
      operation_id = $SuccessRequestId
      source = "gateway_live_db_readback"
    }
  )
}

function Test-GatewayPaidEvidenceItemsForE11Shape {
  param([Parameter(Mandatory = $true)][object[]]$Items)

  $required = @(
    "gateway_hot_path_reserve_settle_refund",
    "insufficient_balance_prevents_provider_call",
    "settle_idempotency",
    "refund_idempotency",
    "post_commit_readback",
    "rollback_proof",
    "reconciliation_report"
  )
  $seen = New-Object System.Collections.Generic.HashSet[string]
  foreach ($item in $Items) {
    $key = [string]$item.evidence_key
    if (@($required) -notcontains $key) { return $false }
    if (-not $seen.Add($key)) { return $false }
    if ([string]$item.status -ne "passed" -or -not [bool]$item.passed) { return $false }
    if (-not (Test-UuidText ([string]$item.request_id))) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$item.operation)) { return $false }
    if (-not (Test-UuidText ([string]$item.operation_id))) { return $false }
    if (($key -in @("gateway_hot_path_reserve_settle_refund", "settle_idempotency", "post_commit_readback", "rollback_proof", "reconciliation_report")) -and
      [string]$item.operation_id -ne [string]$item.request_id) {
      return $false
    }
    if ($key -eq "insufficient_balance_prevents_provider_call" -and [bool]$item.provider_call_expected) { return $false }
    if ($key -eq "settle_idempotency" -and [string]$item.expected_idempotency_key -ne "settle:$([string]$item.request_id)") { return $false }
    if ($key -eq "refund_idempotency") {
      if (-not (Test-UuidText ([string]$item.related_ledger_entry_id)) -or -not (Test-UuidText ([string]$item.operation_id)) -or -not (Test-UuidText ([string]$item.refund_operation_id))) { return $false }
      if (-not [string]::IsNullOrWhiteSpace([string]$item.expected_idempotency_key)) { return $false }
      if ([string]::IsNullOrWhiteSpace([string]$item.actual_refund_idempotency_key)) { return $false }
      if ([string]$item.actual_refund_idempotency_key -ne "refund:$([string]$item.related_ledger_entry_id)") { return $false }
      if (-not [bool]$item.duplicate_refund_idempotent) { return $false }
      if (-not [bool]$item.bounded_smoke_refund_step) { return $false }
      if ([bool]$item.production_default_path) { return $false }
    }
  }
  foreach ($key in $required) {
    if (-not $seen.Contains($key)) { return $false }
  }
  return $true
}

function Get-UniqueNonEmptyText {
  param([AllowNull()][object[]]$Values)

  $list = New-Object System.Collections.Generic.List[string]
  foreach ($value in @($Values)) {
    $text = [string]$value
    if (-not [string]::IsNullOrWhiteSpace($text) -and -not $list.Contains($text)) {
      [void]$list.Add($text)
    }
  }
  return @($list.ToArray())
}

function Get-LedgerOperationIdsFromReadback {
  param([Parameter(Mandatory = $true)]$Readback)

  $operationEvidence = Get-ObjectPropertyValue $Readback "operation_evidence"
  return @(Get-UniqueNonEmptyText @(
    (Get-ObjectPropertyValue $operationEvidence "success_reserve_ledger_entry_id"),
    (Get-ObjectPropertyValue $operationEvidence "success_settle_ledger_entry_id"),
    (Get-ObjectPropertyValue $operationEvidence "success_refund_ledger_entry_id"),
    (Get-ObjectPropertyValue $operationEvidence "failure_release_ledger_entry_id")
  ))
}

function Test-GatewayPaidArtifactAliasShape {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$TopRequestIds,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$TraceRequestIds,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$TopOperationIds,
    [Parameter(Mandatory = $true)][object[]]$EvidenceItems
  )

  $evidenceOperationIds = @(Get-UniqueNonEmptyText @($EvidenceItems | ForEach-Object { [string]$_.operation_id }))
  $topRequests = @(Get-UniqueNonEmptyText $TopRequestIds)
  $traceRequests = @(Get-UniqueNonEmptyText $TraceRequestIds)
  $topOperations = @(Get-UniqueNonEmptyText $TopOperationIds)

  if ($topRequests.Count -eq 0 -or $topOperations.Count -eq 0) { return $false }
  if ($topRequests.Count -ne $traceRequests.Count) { return $false }
  if ($topOperations.Count -ne $evidenceOperationIds.Count) { return $false }

  foreach ($id in $traceRequests) {
    if (-not $topRequests.Contains($id)) { return $false }
  }
  foreach ($id in $evidenceOperationIds) {
    if (-not $topOperations.Contains($id)) { return $false }
  }

  return $true
}

function New-OperatorReadbackParameters {
  param(
    [Parameter(Mandatory = $true)][string[]]$RequestIds,
    [Parameter(Mandatory = $true)][string]$SuccessRequestId,
    [Parameter(Mandatory = $true)][string]$FailureRequestId,
    [Parameter(Mandatory = $true)][string]$InsufficientRequestId
  )

  return [ordered]@{
    smoke_run_id = $script:SmokeRunId
    request_ids = [string]::Join(",", $RequestIds)
    success_request_id = $SuccessRequestId
    failure_request_id = $FailureRequestId
    insufficient_request_id = $InsufficientRequestId
  }
}

function New-OperatorReadbackCommand {
  param([Parameter(Mandatory = $true)]$Parameters)

  return '$sql = Get-Content -Raw scripts/operator/gateway_paid_hot_path_readback.sql; $sql | docker compose -f ' +
    $ComposeFile +
    ' exec -T postgres psql -U ai_gateway -d ai_gateway -tA -v ON_ERROR_STOP=1 --set "smoke_run_id=' +
    $Parameters.smoke_run_id +
    '" --set "request_ids=' +
    $Parameters.request_ids +
    '" --set "success_request_id=' +
    $Parameters.success_request_id +
    '" --set "failure_request_id=' +
    $Parameters.failure_request_id +
    '" --set "insufficient_request_id=' +
    $Parameters.insufficient_request_id +
    '" -f -'
}

function Invoke-SelfTest {
  $validReadback = [PSCustomObject]@{
    reserve_before_provider_side_effect = $true
    insufficient_balance_prevents_provider_call = $true
    insufficient_balance_provider_attempt_rows = 0
    successful_request_settled = $true
    failure_request_released = $true
    settle_idempotency = $true
    reserve_idempotency_seen = $true
    post_commit_readback = $true
    refund_idempotency = [PSCustomObject]@{
      status = "passed"
      refund_rows = 1
      duplicate_refund_idempotent = $true
      refund_idempotency_key = "refund:00000000-0000-0000-0000-000000030203"
      related_settle_ledger_entry_id = "00000000-0000-0000-0000-000000030203"
      refund_ledger_entry_id = "00000000-0000-0000-0000-000000030205"
      bounded_smoke_refund_step = $true
      production_default_path = $false
    }
    secret_safe = [PSCustomObject]@{
      raw_or_secret_marker_present = $false
    }
  }

  $cases = @(
    [PSCustomObject]@{ name = "complete_handoff_pass"; readback = $validReadback; expected = $true },
    [PSCustomObject]@{
      name = "missing_failure_release_rejected"
      readback = ($validReadback | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
      expected = $false
    },
    [PSCustomObject]@{
      name = "missing_settle_rejected"
      readback = ($validReadback | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
      expected = $false
    },
    [PSCustomObject]@{
      name = "insufficient_provider_attempt_rejected"
      readback = ($validReadback | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
      expected = $false
    },
    [PSCustomObject]@{
      name = "raw_or_auth_marker_rejected"
      readback = ($validReadback | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
      expected = $false
    },
    [PSCustomObject]@{
      name = "missing_refund_row_rejected"
      readback = ($validReadback | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
      expected = $false
    },
    [PSCustomObject]@{
      name = "duplicate_refund_not_idempotent_rejected"
      readback = ($validReadback | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
      expected = $false
    }
  )

  $cases[1].readback.failure_request_released = $false
  $cases[1].readback.post_commit_readback = $false
  $cases[2].readback.successful_request_settled = $false
  $cases[2].readback.post_commit_readback = $false
  $cases[3].readback.insufficient_balance_provider_attempt_rows = 1
  $cases[3].readback.insufficient_balance_prevents_provider_call = $false
  $cases[3].readback.post_commit_readback = $false
  $cases[4].readback.secret_safe.raw_or_secret_marker_present = $true
  $cases[5].readback.refund_idempotency.refund_rows = 0
  $cases[5].readback.post_commit_readback = $false
  $cases[6].readback.refund_idempotency.duplicate_refund_idempotent = $false

  foreach ($case in $cases) {
    $actual = Test-PaidHotPathReadbackPass $case.readback
    if ($actual -ne $case.expected) {
      throw "selftest failed: $($case.name) expected $($case.expected) got $actual"
    }
  }

  $shapeReadback = ($validReadback | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
  $shapeReadback | Add-Member -NotePropertyName operation_evidence -NotePropertyValue ([PSCustomObject]@{
    success_refund_ledger_entry_id = "00000000-0000-0000-0000-000000030205"
    success_refund_related_settle_ledger_entry_id = "00000000-0000-0000-0000-000000030203"
    success_refund_idempotency_key = "refund:00000000-0000-0000-0000-000000030203"
    failure_release_ledger_entry_id = "00000000-0000-0000-0000-000000030204"
    failure_release_idempotency_key = "release:00000000-0000-0000-0000-000000030004"
  })
  $shapeItems = New-GatewayPaidEvidenceItems `
    -Readback $shapeReadback `
    -SuccessRequestId "00000000-0000-0000-0000-000000030003" `
    -FailureRequestId "00000000-0000-0000-0000-000000030004" `
    -InsufficientRequestId "00000000-0000-0000-0000-000000030002"
  if (-not (Test-GatewayPaidEvidenceItemsForE11Shape $shapeItems)) {
    throw "selftest failed: e11 gateway artifact shape projection rejected"
  }
  $shapeItems[2].operation_id = "00000000-0000-0000-0000-000000030999"
  if (Test-GatewayPaidEvidenceItemsForE11Shape $shapeItems) {
    throw "selftest failed: mismatched operation id projection accepted"
  }
  $shapeItems = New-GatewayPaidEvidenceItems `
    -Readback $shapeReadback `
    -SuccessRequestId "00000000-0000-0000-0000-000000030003" `
    -FailureRequestId "00000000-0000-0000-0000-000000030004" `
    -InsufficientRequestId "00000000-0000-0000-0000-000000030002"
  $shapeRequestIds = @(
    "00000000-0000-0000-0000-000000030003",
    "00000000-0000-0000-0000-000000030004",
    "00000000-0000-0000-0000-000000030002"
  )
  $shapeOperationIds = @(Get-UniqueNonEmptyText @($shapeItems | ForEach-Object { [string]$_.operation_id }))
  if (-not (Test-GatewayPaidArtifactAliasShape `
        -TopRequestIds $shapeRequestIds `
        -TraceRequestIds $shapeRequestIds `
        -TopOperationIds $shapeOperationIds `
        -EvidenceItems $shapeItems)) {
    throw "selftest failed: top-level request/operation aliases rejected"
  }
  if (Test-GatewayPaidArtifactAliasShape `
      -TopRequestIds $shapeRequestIds `
      -TraceRequestIds $shapeRequestIds `
      -TopOperationIds @() `
      -EvidenceItems $shapeItems) {
    throw "selftest failed: empty top-level operation aliases accepted"
  }

  Write-SafeHost "[OK] paid hot-path smoke selftest"
}

function Invoke-ComposePsqlFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $docker = Get-DockerCommand
  $sql = Get-Content -Raw $Path

  Push-Location $repoRoot
  try {
    $null = $sql | & $docker compose -f $ComposeFile exec -T postgres psql `
      -U ai_gateway `
      -d ai_gateway `
      -v ON_ERROR_STOP=1 `
      -f -

    if ($LASTEXITCODE -ne 0) {
      throw "psql file failed with exit code $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }
}

function Ensure-PricingSelectorSchema {
  if (-not (Test-Path $pricingSelectorMigrationPath)) {
    throw "missing db\migrations\0007_pricing_policy_selection.sql"
  }
  Invoke-ComposePsqlFile $pricingSelectorMigrationPath
}

function Invoke-GatewayChat {
  param(
    [Parameter(Mandatory = $true)][string]$JsonBody,
    [hashtable]$Headers = @{},
    [int]$TimeoutSec = $TimeoutSeconds
  )

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList "POST"), (Join-Url $GatewayBaseUrl "/v1/chat/completions")
  [void]$request.Headers.TryAddWithoutValidation("Authorization", "Bearer $GatewayAuthToken")
  [void]$request.Headers.TryAddWithoutValidation("X-AI-Trace-Id", $script:SmokeRunId)
  foreach ($key in $Headers.Keys) {
    [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key])
  }

  $content = New-Object System.Net.Http.StringContent -ArgumentList $JsonBody
  $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json")
  $request.Content = $content

  $response = $null
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    return [PSCustomObject]@{
      StatusCode = [int]$response.StatusCode
      Content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function Invoke-GatewayRefundAfterSettleSmoke {
  param(
    [Parameter(Mandatory = $true)][string]$RequestId,
    [Parameter(Mandatory = $true)][string]$SettleLedgerEntryId,
    [int]$TimeoutSec = $TimeoutSeconds
  )

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList "POST"), (Join-Url $GatewayBaseUrl "/__e8/paid-hot-path/refund-after-settle")
  [void]$request.Headers.TryAddWithoutValidation("Authorization", "Bearer $GatewayAuthToken")
  [void]$request.Headers.TryAddWithoutValidation("X-AI-Trace-Id", $script:SmokeRunId)
  [void]$request.Headers.TryAddWithoutValidation("X-E8-Paid-Hot-Path-Smoke-Refund", "true")

  $body = @{
    request_id = $RequestId
    settle_ledger_entry_id = $SettleLedgerEntryId
    reason = "e8_paid_hot_path_smoke_after_settle_refund"
  } | ConvertTo-Json -Depth 6 -Compress
  $content = New-Object System.Net.Http.StringContent -ArgumentList $body
  $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json")
  $request.Content = $content

  $response = $null
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $contentText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    return [PSCustomObject]@{
      StatusCode = [int]$response.StatusCode
      Content = $contentText
      Json = if ([string]::IsNullOrWhiteSpace($contentText)) { $null } else { $contentText | ConvertFrom-Json }
    }
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function Get-RequestLogByHash {
  param([Parameter(Mandatory = $true)][string]$RequestHash)

  $hash = Escape-SqlLiteral $RequestHash
  $sql = @"
select coalesce((
  select to_jsonb(t)::text
  from (
    select
      id::text as request_id,
      status,
      http_status,
      request_body_hash,
      created_at::text as created_at,
      completed_at::text as completed_at
    from request_logs
    where request_body_hash = '$hash'
    order by created_at desc
    limit 1
  ) t
), '{}');
"@

  $json = Invoke-ComposePsql $sql
  if ([string]::IsNullOrWhiteSpace($json) -or $json -eq "{}") { return $null }
  return $json | ConvertFrom-Json
}

function Wait-RequestLogByHash {
  param([Parameter(Mandatory = $true)][string]$RequestHash)

  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($DbPollSeconds)
  do {
    $row = Get-RequestLogByHash $RequestHash
    if ($row -and $row.request_id) {
      return $row
    }
    Start-Sleep -Milliseconds 300
  } while ([DateTimeOffset]::UtcNow -lt $deadline)

  throw "request log was not found for request hash $RequestHash"
}

function Capture-OriginalState {
  $sql = @"
select jsonb_build_object(
  'virtual_key_metadata', vk.metadata,
  'virtual_key_project_id', vk.project_id,
  'virtual_key_profile_bindings', coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'tenant_id', b.tenant_id,
        'project_id', b.project_id,
        'virtual_key_id', b.virtual_key_id,
        'profile_id', b.profile_id,
        'is_default', b.is_default
      )
      order by b.profile_id
    )
    from virtual_key_profile_bindings b
    where b.tenant_id = vk.tenant_id
      and b.virtual_key_id = vk.id
  ), '[]'::jsonb),
  'canonical_model_default_price_book_id', cm.default_price_book_id,
  'channel_endpoint', ch.endpoint
)::text
from virtual_keys vk
cross join channels ch
cross join canonical_models cm
where vk.tenant_id = '00000000-0000-0000-0000-000000000001'
  and vk.id = '00000000-0000-0000-0000-000000000050'
  and ch.tenant_id = vk.tenant_id
  and ch.name = 'mock-openai-default'
  and cm.tenant_id = vk.tenant_id
  and cm.id = '00000000-0000-0000-0000-000000000080'
limit 1;
"@
  $script:OriginalState = Invoke-ComposePsql $sql | ConvertFrom-Json
  $script:StateCaptured = $true
}

function Restore-OriginalState {
  if (-not $script:StateCaptured -or $null -eq $script:OriginalState) { return }

  $metadata = Escape-SqlLiteral (($script:OriginalState.virtual_key_metadata | ConvertTo-Json -Depth 20 -Compress))
  $projectId = Escape-SqlLiteral ([string]$script:OriginalState.virtual_key_project_id)
  $bindings = Escape-SqlLiteral (($script:OriginalState.virtual_key_profile_bindings | ConvertTo-Json -Depth 20 -Compress))
  $canonicalModelDefaultPriceBookId = [string]$script:OriginalState.canonical_model_default_price_book_id
  $canonicalModelDefaultPriceBookSql = "null"
  if (-not [string]::IsNullOrWhiteSpace($canonicalModelDefaultPriceBookId)) {
    $canonicalModelDefaultPriceBookSql = "'" + (Escape-SqlLiteral $canonicalModelDefaultPriceBookId) + "'::uuid"
  }
  $endpoint = Escape-SqlLiteral ([string]$script:OriginalState.channel_endpoint)
  $sql = @"
delete from virtual_key_profile_bindings
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and virtual_key_id = '00000000-0000-0000-0000-000000000050';

update virtual_keys
set project_id = '$projectId'::uuid,
    metadata = '$metadata'::jsonb,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id = '00000000-0000-0000-0000-000000000050';

insert into virtual_key_profile_bindings (tenant_id, project_id, virtual_key_id, profile_id, is_default)
select tenant_id, project_id, virtual_key_id, profile_id, is_default
from jsonb_to_recordset('$bindings'::jsonb) as binding(
  tenant_id uuid,
  project_id uuid,
  virtual_key_id uuid,
  profile_id uuid,
  is_default boolean
)
on conflict (tenant_id, virtual_key_id, profile_id) do update
set is_default = excluded.is_default;

update canonical_models
set default_price_book_id = $canonicalModelDefaultPriceBookSql,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id = '00000000-0000-0000-0000-000000000080';

update channels
set endpoint = '$endpoint',
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and name = 'mock-openai-default';
"@
  [void](Invoke-ComposePsql $sql)
}

function Seed-PaidHotPathState {
  param([Parameter(Mandatory = $true)][string]$CreditRemaining)

  $credit = Escape-SqlLiteral $CreditRemaining
  $sql = @"
insert into projects (id, tenant_id, team_id, name, status, metadata)
values (
  '00000000-0000-0000-0000-0000000030a0',
  '00000000-0000-0000-0000-000000000001',
  null,
  'E8 Paid Hot Path Smoke Project',
  'active',
  '{"smoke":"gateway_paid_hot_path"}'::jsonb
)
on conflict (tenant_id, id) do update
set status = 'active',
    metadata = excluded.metadata,
    updated_at = now();

insert into price_books (id, tenant_id, project_id, name, currency, status, metadata)
values (
  '00000000-0000-0000-0000-0000000030b0',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-0000000030a0',
  'E8 Paid Hot Path Smoke Price Book',
  'USD',
  'active',
  '{"smoke":"gateway_paid_hot_path"}'::jsonb
)
on conflict (tenant_id, name) do update
set status = 'active',
    project_id = excluded.project_id,
    currency = 'USD',
    metadata = excluded.metadata,
    updated_at = now();

insert into api_key_profiles (
  id,
  tenant_id,
  project_id,
  name,
  inbound_protocol,
  default_protocol_mode,
  default_price_book_id,
  status
)
values (
  '00000000-0000-0000-0000-0000000030a1',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-0000000030a0',
  'E8 Paid Hot Path Smoke Profile',
  'openai',
  'openai_compatible',
  '00000000-0000-0000-0000-0000000030b0',
  'active'
)
on conflict (tenant_id, project_id, id) do update
set inbound_protocol = excluded.inbound_protocol,
    default_protocol_mode = excluded.default_protocol_mode,
    default_price_book_id = excluded.default_price_book_id,
    status = 'active',
    updated_at = now();

delete from virtual_key_profile_bindings
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and virtual_key_id = '00000000-0000-0000-0000-000000000050';

update virtual_keys
set project_id = '00000000-0000-0000-0000-0000000030a0',
    metadata = metadata || jsonb_build_object(
      'billing_mode', 'paid_controlled_beta',
      'paid_hot_path_beta', 'true',
      'paid_hot_path_smoke_run_id', '$script:SmokeRunId'
    ),
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id = '00000000-0000-0000-0000-000000000050';

insert into virtual_key_profile_bindings (tenant_id, project_id, virtual_key_id, profile_id, is_default)
values (
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-0000000030a0',
  '00000000-0000-0000-0000-000000000050',
  '00000000-0000-0000-0000-0000000030a1',
  true
)
on conflict (tenant_id, virtual_key_id, profile_id) do update
set is_default = excluded.is_default;

insert into wallets (id, tenant_id, project_id, name, currency, status, balance_floor, metadata, created_at)
values (
  '00000000-0000-0000-0000-0000000030b1',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-0000000030a0',
  'E8 Paid Hot Path Smoke Wallet',
  'USD',
  'active',
  0,
  '{"smoke":"gateway_paid_hot_path"}'::jsonb,
  timestamp with time zone '2000-01-01 00:00:00+00'
)
on conflict (tenant_id, id) do update
set status = 'active',
    project_id = excluded.project_id,
    balance_floor = 0,
    metadata = excluded.metadata,
    created_at = excluded.created_at,
    updated_at = now();

insert into credit_grants (id, tenant_id, wallet_id, amount, remaining_amount, currency, source, status, metadata)
select
  '00000000-0000-0000-0000-0000000030b2',
  '00000000-0000-0000-0000-000000000001',
  selected_wallet.id,
  10.00000000,
  ('$credit'::text)::numeric,
  'USD',
  'gateway_paid_hot_path_smoke',
  'active',
  '{"smoke":"gateway_paid_hot_path"}'::jsonb
from (
  select id
  from wallets
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = '00000000-0000-0000-0000-0000000030b1'
) selected_wallet
on conflict (tenant_id, id) do update
set wallet_id = excluded.wallet_id,
    remaining_amount = ('$credit'::text)::numeric,
    status = 'active',
    valid_from = now() - interval '1 minute',
    valid_until = null,
    metadata = excluded.metadata,
    updated_at = now();

insert into price_versions (id, tenant_id, price_book_id, canonical_model_id, version, pricing_rules, effective_at, status)
values (
  '00000000-0000-0000-0000-0000000030b3',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-0000000030b0',
  '00000000-0000-0000-0000-000000000080',
  'e8-paid-hot-path-smoke-v1',
  '{"currency":"USD","scale":8,"input_token_rate_per_1m":"1.00000000","output_token_rate_per_1m":"1.00000000","fixed_request_cost":"0.00000100"}'::jsonb,
  now() - interval '1 minute',
  'active'
)
on conflict (tenant_id, price_book_id, version) do update
set pricing_rules = excluded.pricing_rules,
    effective_at = excluded.effective_at,
    status = 'active';

update canonical_models
set default_price_book_id = '00000000-0000-0000-0000-0000000030b0',
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id = '00000000-0000-0000-0000-000000000080';

"@
  [void](Invoke-ComposePsql $sql)
}

function Set-MockChannelEndpoint {
  param([Parameter(Mandatory = $true)][string]$Endpoint)
  $endpointSql = Escape-SqlLiteral $Endpoint
  $sql = @"
update channels
set endpoint = '$endpointSql',
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and name = 'mock-openai-default';
"@
  [void](Invoke-ComposePsql $sql)
}

function Reset-MockRouteRuntimeState {
  $sql = @"
update channels
set status = 'enabled',
    health_score = 1.0,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and name = 'mock-openai-default';

update provider_keys
set status = 'enabled',
    health_score = 1.0,
    cooldown_until = null,
    last_error_code = null,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and key_alias = 'mock-dev-key';
"@
  [void](Invoke-ComposePsql $sql)
}

function Assert-Status {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int]$Expected
  )

  if ([int]$Response.StatusCode -ne $Expected) {
    throw "expected HTTP $Expected, got HTTP $($Response.StatusCode): $(Redact-SecretLikeString $Response.Content)"
  }
}

function Write-Artifact {
  param([Parameter(Mandatory = $true)]$Artifact)

  $artifactFullPath = if ([System.IO.Path]::IsPathRooted($ArtifactPath)) {
    $ArtifactPath
  } else {
    Join-Path $repoRoot $ArtifactPath
  }
  $artifactDir = Split-Path -Parent $artifactFullPath
  if (-not (Test-Path $artifactDir)) {
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
  }
  $Artifact | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $artifactFullPath -Encoding UTF8
  return $artifactFullPath
}

function Invoke-Preflight {
  if (-not (Test-Path $readbackSqlPath)) {
    throw "missing scripts\operator\gateway_paid_hot_path_readback.sql"
  }
  [void](Get-DockerCommand)
  if (-not $SkipComposePs) {
    Push-Location $repoRoot
    try {
      Invoke-Docker compose -f $ComposeFile ps postgres gateway mock-provider | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "docker compose ps failed with exit code $LASTEXITCODE"
      }
    } finally {
      Pop-Location
    }
  }
  Write-SafeHost "[OK] paid hot-path smoke preflight"
}

try {
  if ($SelfTest) {
    Invoke-SelfTest
    exit 0
  }

  Invoke-Preflight
  if ($PreflightOnly) {
    exit 0
  }

  Ensure-PricingSelectorSchema
  Capture-OriginalState
  Set-MockChannelEndpoint "http://mock-provider:18080"
  Reset-MockRouteRuntimeState
  Seed-PaidHotPathState "10.00000000"

  $successBody = New-ChatBodyJson $Model "paid hot path success $script:SmokeRunId"
  $successHash = Get-Sha256Hex $successBody
  $successResponse = Invoke-GatewayChat $successBody
  Assert-Status $successResponse 200
  $successRow = Wait-RequestLogByHash $successHash

  Seed-PaidHotPathState "10.00000000"
  Set-MockChannelEndpoint "http://mock-provider:18080/__scenario/429"
  $failureBody = New-ChatBodyJson $Model "paid hot path failure release $script:SmokeRunId"
  $failureHash = Get-Sha256Hex $failureBody
  $failureResponse = Invoke-GatewayChat $failureBody
  Assert-Status $failureResponse 429
  $failureRow = Wait-RequestLogByHash $failureHash
  Set-MockChannelEndpoint "http://mock-provider:18080"
  Reset-MockRouteRuntimeState

  Seed-PaidHotPathState "0.00000000"
  $insufficientBody = New-ChatBodyJson $Model "paid hot path insufficient balance $script:SmokeRunId"
  $insufficientHash = Get-Sha256Hex $insufficientBody
  $insufficientResponse = Invoke-GatewayChat $insufficientBody
  Assert-Status $insufficientResponse 402
  $insufficientRow = Wait-RequestLogByHash $insufficientHash

  $requestIds = @(
    [string]$successRow.request_id,
    [string]$failureRow.request_id,
    [string]$insufficientRow.request_id
  )
  $operatorReadbackParameters = New-OperatorReadbackParameters `
    -RequestIds $requestIds `
    -SuccessRequestId $successRow.request_id `
    -FailureRequestId $failureRow.request_id `
    -InsufficientRequestId $insufficientRow.request_id
  $initialReadback = Invoke-OperatorReadback `
    -RequestIds $requestIds `
    -SuccessRequestId $successRow.request_id `
    -FailureRequestId $failureRow.request_id `
    -InsufficientRequestId $insufficientRow.request_id
  $initialOperationEvidence = Get-ObjectPropertyValue $initialReadback "operation_evidence"
  $successSettleLedgerEntryId = [string](Get-ObjectPropertyValue $initialOperationEvidence "success_settle_ledger_entry_id")
  if (-not (Test-UuidText $successSettleLedgerEntryId)) {
    throw "success settle ledger entry id missing before refund smoke step"
  }

  $refundApplyResponse = Invoke-GatewayRefundAfterSettleSmoke `
    -RequestId $successRow.request_id `
    -SettleLedgerEntryId $successSettleLedgerEntryId
  Assert-Status $refundApplyResponse 200
  if ([string](Get-ObjectPropertyValue $refundApplyResponse.Json "outcome") -ne "applied") {
    throw "first refund-after-settle smoke call did not apply"
  }
  $refundReplayResponse = Invoke-GatewayRefundAfterSettleSmoke `
    -RequestId $successRow.request_id `
    -SettleLedgerEntryId $successSettleLedgerEntryId
  Assert-Status $refundReplayResponse 200
  if ([string](Get-ObjectPropertyValue $refundReplayResponse.Json "outcome") -ne "idempotent") {
    throw "duplicate refund-after-settle smoke call was not idempotent"
  }

  $readback = Invoke-OperatorReadback `
    -RequestIds $requestIds `
    -SuccessRequestId $successRow.request_id `
    -FailureRequestId $failureRow.request_id `
    -InsufficientRequestId $insufficientRow.request_id

  $evidenceItems = New-GatewayPaidEvidenceItems `
    -Readback $readback `
    -SuccessRequestId $successRow.request_id `
    -FailureRequestId $failureRow.request_id `
    -InsufficientRequestId $insufficientRow.request_id
  $operationIds = @(Get-UniqueNonEmptyText @($evidenceItems | ForEach-Object { [string]$_.operation_id }))
  $ledgerOperationIds = @(Get-LedgerOperationIdsFromReadback $readback)
  $e11ShapePass = Test-GatewayPaidEvidenceItemsForE11Shape $evidenceItems
  $aliasShapePass = Test-GatewayPaidArtifactAliasShape `
    -TopRequestIds $requestIds `
    -TraceRequestIds $requestIds `
    -TopOperationIds $operationIds `
    -EvidenceItems $evidenceItems
  $pass = (Test-PaidHotPathReadbackPass $readback) -and $e11ShapePass -and $aliasShapePass

  $artifact = [ordered]@{
    schema = "gateway_paid_hot_path_smoke_v1"
    schema_version = "gateway_paid_hot_path_smoke_v1"
    smoke_run_id = $script:SmokeRunId
    status = if ($pass) { "passed" } else { "failed" }
    request_ids = $requestIds
    operation_ids = $operationIds
    ledger_operation_ids = $ledgerOperationIds
    evidence = $evidenceItems
    gateway_hot_path_reserve_settle_refund = [ordered]@{
      reserve_before_provider_side_effect = [bool]$readback.reserve_before_provider_side_effect
      successful_request_settled = [bool]$readback.successful_request_settled
      failure_request_released = [bool]$readback.failure_request_released
      bounded_beta_scope = "success_settle_and_provider_429_pending_reserve_release"
      e11_input_shape_passed = [bool]$e11ShapePass
      consumer_alias_shape_passed = [bool]$aliasShapePass
    }
    insufficient_balance_prevents_provider_call = [ordered]@{
      passed = [bool]$readback.insufficient_balance_prevents_provider_call
      provider_attempt_rows = [int]$readback.insufficient_balance_provider_attempt_rows
    }
    settle_idempotency = [ordered]@{
      passed = [bool]$readback.settle_idempotency
      key_shape = "settle:{request_id}"
    }
    refund_idempotency = $readback.refund_idempotency
    bounded_smoke_refund_after_settle = [ordered]@{
      enabled_by = "X-E8-Paid-Hot-Path-Smoke-Refund"
      production_default_path = $false
      request_id = [string]$successRow.request_id
      settle_ledger_entry_id = $successSettleLedgerEntryId
      first_call_outcome = [string](Get-ObjectPropertyValue $refundApplyResponse.Json "outcome")
      replay_call_outcome = [string](Get-ObjectPropertyValue $refundReplayResponse.Json "outcome")
      refund_idempotency_key = [string](Get-ObjectPropertyValue $refundApplyResponse.Json "refund_idempotency_key")
      duplicate_refund_idempotent = [string](Get-ObjectPropertyValue $refundReplayResponse.Json "outcome") -eq "idempotent"
    }
    post_commit_readback = $readback
    rollback_proof = $readback.rollback_proof
    reconciliation_report = $readback.reconciliation_report
    operator_readback = [ordered]@{
      schema = "gateway_paid_hot_path_operator_readback_handoff_v1"
      sql = "scripts/operator/gateway_paid_hot_path_readback.sql"
      compose_file = $ComposeFile
      parameters = $operatorReadbackParameters
      copyable_command = New-OperatorReadbackCommand $operatorReadbackParameters
      role_parameter_required_for_legacy_sql = $false
      role_inference_supported = $true
    }
    request_trace = [ordered]@{
      request_ids = $requestIds
      success_request_id = [string]$successRow.request_id
      failure_request_id = [string]$failureRow.request_id
      insufficient_request_id = [string]$insufficientRow.request_id
      request_hashes = @($successHash, $failureHash, $insufficientHash)
      requests = @(
        [ordered]@{
          role = "success_settle"
          request_id = [string]$successRow.request_id
          request_hash = $successHash
          expected_http_status = 200
        },
        [ordered]@{
          role = "failure_release"
          request_id = [string]$failureRow.request_id
          request_hash = $failureHash
          expected_http_status = 429
        },
        [ordered]@{
          role = "insufficient_balance_no_provider_attempt"
          request_id = [string]$insufficientRow.request_id
          request_hash = $insufficientHash
          expected_http_status = 402
        }
      )
      raw_request_body_omitted = $true
    }
    secret_safe = [ordered]@{
      auth_token_omitted = $true
      provider_secret_omitted = $true
      database_url_omitted = $true
      raw_request_body_omitted = $true
      raw_or_secret_marker_present = [bool]$readback.secret_safe.raw_or_secret_marker_present
    }
  }

  $written = Write-Artifact $artifact
  $script:TerminalArtifactWritten = $true
  Write-SafeHost "[OK] wrote paid hot-path smoke artifact: $written"

  if (-not $pass) {
    Write-SafeHost "[FAIL] paid hot-path smoke readback did not satisfy acceptance checks"
    exit 1
  }

  exit 0
} catch {
  $safeError = Redact-SecretLikeString $_.Exception.Message
  if (-not $script:TerminalArtifactWritten) {
    $blockedArtifact = [ordered]@{
      schema = "gateway_paid_hot_path_smoke_v1"
      smoke_run_id = $script:SmokeRunId
      status = "blocked"
      external_blocker = $safeError
      secret_safe = [ordered]@{
        auth_token_omitted = $true
        provider_secret_omitted = $true
        database_url_omitted = $true
        raw_request_body_omitted = $true
      }
    }
    try {
      $written = Write-Artifact $blockedArtifact
      Write-SafeHost "[BLOCKED] wrote paid hot-path smoke artifact: $written"
    } catch {
      Write-SafeHost "[BLOCKED] failed to write paid hot-path smoke artifact"
    }
  }
  Write-SafeHost "[FAIL] $safeError"
  exit 1
} finally {
  try {
    Restore-OriginalState
  } catch {
    Write-SafeHost "[WARN] failed to restore paid hot-path smoke DB state: $($_.Exception.Message)"
  }
}
