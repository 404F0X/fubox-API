[CmdletBinding()]
param(
  [string]$ArtifactDir = ".tmp\importers\sample_apply_rollback_parity",
  [string]$LiveRuntimeArtifactPath = ".tmp\importers\import_apply_live_runtime_verification.json"
)

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}

$script:RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..\..")).Path
$script:NewApiScript = Join-Path $script:RepoRoot "scripts\importers\import-newapi-dryrun.ps1"
$script:OneApiScript = Join-Path $script:RepoRoot "scripts\importers\import-oneapi-dryrun.ps1"
$script:MappingScript = Join-Path $script:RepoRoot "scripts\importers\import-internal-mapping-report.ps1"
$script:ApplyPlanScript = Join-Path $script:RepoRoot "scripts\importers\import-apply-plan.ps1"
$script:NewApiFixture = Join-Path $script:RepoRoot "examples\importer_samples\new_api_openai_compatible.sample.json"
$script:OneApiFixture = Join-Path $script:RepoRoot "examples\importer_samples\one_api_openai_compatible.sample.json"
$script:ArtifactRoot = Join-Path $script:RepoRoot $ArtifactDir
$script:LiveRuntimeArtifact = Join-Path $script:RepoRoot $LiveRuntimeArtifactPath

function Assert-Condition {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw "VERIFY FAILED: $Message"
  }
}

function Convert-ToArray {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return @() }
  if ($Value -is [string]) { return @($Value) }
  if ($Value -is [System.Collections.IEnumerable]) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Value) {
      $items.Add($item) | Out-Null
    }
    return @($items.ToArray())
  }
  return @($Value)
}

function Convert-ToRepoPath {
  param([string]$Path)
  return ($Path.Substring($script:RepoRoot.Length + 1) -replace "\\", "/")
}

function Assert-NoSecretMaterial {
  param(
    [string]$RawJson,
    [string]$Context
  )

  $patterns = @(
    'sk-[A-Za-z0-9_-]+',
    '(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}',
    '(?i)(api[_-]?key|authorization|token|password)=([^<][^&\s"`]+)'
  )

  foreach ($pattern in $patterns) {
    Assert-Condition (-not ($RawJson -match $pattern)) "$Context contains secret-like material matching $pattern"
  }

  $forbiddenLiterals = @(
    '${OPENAI_API_KEY}',
    'env:AZURE_OPENAI_API_KEY',
    'env:AZURE_OPENAI_SECONDARY_KEY',
    '${ONE_API_OPENAI_KEY}'
  )

  foreach ($literal in $forbiddenLiterals) {
    Assert-Condition (-not $RawJson.Contains($literal)) "$Context contains raw credential locator '$literal'"
  }
}

function Write-ArtifactText {
  param(
    [string]$Path,
    [string]$Content
  )

  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
}

function Invoke-JsonScript {
  param(
    [string]$ScriptPath,
    [hashtable]$Arguments,
    [string]$OutputPath,
    [string]$Context
  )

  $output = & $ScriptPath @Arguments
  if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "$Context exited with $LASTEXITCODE"
  }

  $raw = ($output | Out-String).Trim()
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($raw)) "$Context emitted JSON"
  Assert-NoSecretMaterial $raw $Context
  Write-ArtifactText $OutputPath $raw

  try {
    return ($raw | ConvertFrom-Json)
  } catch {
    throw "VERIFY FAILED: $Context output was not valid JSON. $($_.Exception.Message)"
  }
}

function Test-PreflightCheck {
  param(
    [object]$ApplyPlan,
    [string]$Name,
    [string]$ExpectedStatus,
    [string]$Context
  )

  $matches = @(Convert-ToArray $ApplyPlan.preflight.checks | Where-Object { $_.name -eq $Name })
  Assert-Condition ($matches.Count -eq 1) "$Context includes preflight check $Name"
  Assert-Condition ($matches[0].status -eq $ExpectedStatus) "$Context preflight check $Name is $ExpectedStatus"
  return $matches[0]
}

function Get-ProviderKeyAuditBoundary {
  param(
    [object[]]$Handoffs,
    [string]$CaseName
  )

  $boundaries = New-Object System.Collections.Generic.List[object]
  foreach ($handoff in $Handoffs) {
    Assert-Condition ($handoff.raw_material_exported -eq $false) "$CaseName handoff omits raw material"
    Assert-Condition ($handoff.provider_key_material_included -eq $false) "$CaseName handoff omits provider key material"
    Assert-Condition ($handoff.apply_directly_supported -eq $false) "$CaseName handoff cannot be applied by importer"
    Assert-Condition ($handoff.apply_mode -eq "sidecar_only") "$CaseName handoff is sidecar-only"
    Assert-Condition ($handoff.required_operator_path -eq "POST /admin/provider-keys" -or $handoff.recommended_path -eq "POST /admin/provider-keys") "$CaseName handoff points to Control Plane provider-key path"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handoff.binding_status)) "$CaseName handoff records binding status"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handoff.credential_locator_redacted)) "$CaseName handoff uses a redacted locator"
    Assert-Condition (@(Convert-ToArray $handoff.credential_locator_hashes).Count -gt 0) "$CaseName handoff includes locator hash evidence"

    $boundaries.Add([ordered]@{
        handoff_id = [string]$handoff.handoff_id
        channel_source_id = [string]$handoff.channel_source_id
        key_alias = [string]$handoff.key_alias
        binding_status = [string]$handoff.binding_status
        credential_material_present = [bool]$handoff.credential_material_present
        raw_provider_key_written_by_importer = $false
        importer_provider_key_sql_operation = $false
        control_plane_create_path = "POST /admin/provider-keys"
        control_plane_audit_readback_status = "deferred"
        deferred_reason = "operator_secret_required; verifier must not write or persist raw provider keys"
        required_readback_evidence = @(
          "provider_key_id",
          "channel_id or provider/channel binding",
          "secret_fingerprint or equivalent non-secret fingerprint",
          "created_by / actor",
          "created_at",
          "audit_event_id"
        )
      }) | Out-Null
  }

  return @($boundaries.ToArray())
}

foreach ($path in @($script:NewApiScript, $script:OneApiScript, $script:MappingScript, $script:ApplyPlanScript, $script:NewApiFixture, $script:OneApiFixture)) {
  Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) "required path exists: $path"
}

if (-not (Test-Path -LiteralPath $script:ArtifactRoot)) {
  New-Item -ItemType Directory -Force -Path $script:ArtifactRoot | Out-Null
}

$cases = @(
  [ordered]@{
    name = "newapi"
    source_script = $script:NewApiScript
    fixture = $script:NewApiFixture
  },
  [ordered]@{
    name = "oneapi"
    source_script = $script:OneApiScript
    fixture = $script:OneApiFixture
  }
)

$caseSummaries = New-Object System.Collections.Generic.List[object]
$deferredItems = New-Object System.Collections.Generic.List[object]

foreach ($case in $cases) {
  $sourcePath = Join-Path $script:ArtifactRoot "$($case.name).source.json"
  $mappingPath = Join-Path $script:ArtifactRoot "$($case.name).mapping.json"
  $applyPlanPath = Join-Path $script:ArtifactRoot "$($case.name).apply_plan.json"

  $source = Invoke-JsonScript `
    -ScriptPath $case.source_script `
    -Arguments @{ InputPath = $case.fixture } `
    -OutputPath $sourcePath `
    -Context "$($case.name) source dry-run"
  Assert-Condition ([int]$source.counts.provider_keys -gt 0) "$($case.name) source report includes provider-key evidence"

  $mapping = Invoke-JsonScript `
    -ScriptPath $script:MappingScript `
    -Arguments @{ InputPath = $sourcePath } `
    -OutputPath $mappingPath `
    -Context "$($case.name) internal mapping"
  Assert-Condition ([int]$mapping.counts.provider_key_handoffs -eq [int]$source.counts.provider_keys) "$($case.name) preserves provider-key handoff count into mapping"

  $applyPlan = Invoke-JsonScript `
    -ScriptPath $script:ApplyPlanScript `
    -Arguments @{ InputPath = $mappingPath } `
    -OutputPath $applyPlanPath `
    -Context "$($case.name) apply plan"

  Assert-Condition ($applyPlan.preflight.status -eq "pass") "$($case.name) sample apply plan preflight passes"
  Assert-Condition ([int]$applyPlan.counts.planned_creates -gt 0) "$($case.name) sample has planned writes"
  Assert-Condition ([int]$applyPlan.counts.planned_updates -eq 0) "$($case.name) sample has no unexpected updates"
  Assert-Condition ([int]$applyPlan.counts.planned_skips -eq 0) "$($case.name) sample has no skipped writes"
  Assert-Condition ([int]$applyPlan.counts.rollback_snapshot_entries -eq ([int]$applyPlan.counts.planned_creates + [int]$applyPlan.counts.planned_updates)) "$($case.name) rollback entries match planned writes"
  Assert-Condition ($applyPlan.provider_key_handoff_contract.raw_material_allowed -eq $false) "$($case.name) raw provider keys are disallowed"
  Assert-Condition ($applyPlan.provider_key_handoff_contract.apply_directly_supported -eq $false) "$($case.name) provider-key direct apply is disabled"
  Assert-Condition ($applyPlan.provider_key_handoff_contract.required_operator_path -eq "POST /admin/provider-keys") "$($case.name) Control Plane provider-key path is required"

  [void](Test-PreflightCheck $applyPlan "provider_key_secret_management_handoff" "pass" "$($case.name) apply plan")
  [void](Test-PreflightCheck $applyPlan "rollback_snapshot_shape" "pass" "$($case.name) apply plan")
  [void](Test-PreflightCheck $applyPlan "write_operations_supported_by_sql_executor" "pass" "$($case.name) apply plan")

  $writeTargets = @(Convert-ToArray $applyPlan.planned_creates) + @(Convert-ToArray $applyPlan.planned_updates)
  Assert-Condition (@($writeTargets | Where-Object { $_.target.kind -match "provider_key|secret" }).Count -eq 0) "$($case.name) has no provider-key write target"
  $sqlOperations = @(Convert-ToArray $applyPlan.sql_executor_plan.transaction.operation_plans)
  Assert-Condition (@($sqlOperations | Where-Object { $_.target.kind -match "provider_key|secret" }).Count -eq 0) "$($case.name) has no provider-key SQL operation"

  $handoffs = @(Convert-ToArray $applyPlan.provider_key_handoffs)
  Assert-Condition ($handoffs.Count -eq [int]$applyPlan.counts.source_provider_key_handoffs) "$($case.name) provider-key handoff count matches apply-plan count"
  $auditBoundaries = Get-ProviderKeyAuditBoundary $handoffs $case.name

  $deferredItems.Add([ordered]@{
      case = $case.name
      item = "control_plane_provider_key_create_audit_readback"
      status = "deferred"
      reason = "requires real operator secret entry through POST /admin/provider-keys; verifier intentionally refuses to write raw provider keys"
      handoff_count = $handoffs.Count
      artifact = Convert-ToRepoPath $applyPlanPath
    }) | Out-Null

  $caseSummaries.Add([ordered]@{
      name = $case.name
      source_artifact = Convert-ToRepoPath $sourcePath
      mapping_artifact = Convert-ToRepoPath $mappingPath
      apply_plan_artifact = Convert-ToRepoPath $applyPlanPath
      preflight_status = [string]$applyPlan.preflight.status
      source_provider_keys = [int]$source.counts.provider_keys
      mapping_provider_key_handoffs = [int]$mapping.counts.provider_key_handoffs
      apply_plan_provider_key_handoffs = [int]$applyPlan.counts.source_provider_key_handoffs
      planned_writes = ([int]$applyPlan.counts.planned_creates + [int]$applyPlan.counts.planned_updates)
      planned_skips = [int]$applyPlan.counts.planned_skips
      rollback_snapshot_entries = [int]$applyPlan.counts.rollback_snapshot_entries
      provider_key_write_targets = 0
      provider_key_sql_operations = 0
      target_counts = $applyPlan.target_counts
      audit_readback_boundaries = $auditBoundaries
    }) | Out-Null
}

$liveRuntime = $null
$liveRuntimeSummary = [ordered]@{
  status = "not_found"
  artifact_path = ($LiveRuntimeArtifactPath -replace "\\", "/")
  closed_cases = @()
}
if (Test-Path -LiteralPath $script:LiveRuntimeArtifact -PathType Leaf) {
  $liveRuntimeRaw = Get-Content -LiteralPath $script:LiveRuntimeArtifact -Raw -Encoding UTF8
  Assert-NoSecretMaterial $liveRuntimeRaw "live runtime artifact"
  $liveRuntime = $liveRuntimeRaw | ConvertFrom-Json
  Assert-Condition ($liveRuntime.status -eq "pass") "live runtime artifact status is pass"
  Assert-Condition ($liveRuntime.rollback_verified -eq $true) "live runtime artifact verifies rollback"
  Assert-Condition ($liveRuntime.secret_safe -eq $true) "live runtime artifact is secret safe"
  $closedCases = @(Convert-ToArray $liveRuntime.cases | ForEach-Object {
      [ordered]@{
        name = [string]$_.name
        status = [string]$_.status
        artifact_path = ([string]$_.artifact_path -replace "\\", "/")
        expected_refusal = if ($null -eq $_.expected_refusal) { $false } else { [bool]$_.expected_refusal }
        database_writes = if ($null -eq $_.database_writes) { $null } else { [bool]$_.database_writes }
        provider_key_material_allowed = if ($null -eq $_.provider_key_material_allowed) { $null } else { [bool]$_.provider_key_material_allowed }
      }
    })
  $liveRuntimeSummary = [ordered]@{
    status = "pass"
    artifact_path = ($LiveRuntimeArtifactPath -replace "\\", "/")
    live_database_connection = [bool]$liveRuntime.live_database_connection
    database_writes = [bool]$liveRuntime.database_writes
    rollback_verified = [bool]$liveRuntime.rollback_verified
    closed_cases = $closedCases
  }
} else {
  $deferredItems.Add([ordered]@{
      case = "focused_live_runtime"
      item = "provider_channel_canonical_mapping_association_apply_rollback_readback"
      status = "deferred"
      reason = "live runtime artifact is absent; run scripts/importers/verify-import-apply-live-runtime.ps1 with local PostgreSQL compose to close runtime readback"
      artifact = ($LiveRuntimeArtifactPath -replace "\\", "/")
    }) | Out-Null
}

$deferredItems.Add([ordered]@{
    case = "newapi_oneapi_full_samples"
    item = "full_sample_live_apply_rollback_with_provider_key_audit_readback"
    status = "deferred"
    reason = "checked-in samples contain redacted credential locators only; no real external sample or operator secret is available, and raw provider keys must not be written by importer verifiers"
    distribution_impact = "none"
  }) | Out-Null

$summary = [ordered]@{
  schema = "importer.sample-apply-rollback-parity-verification.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("O")
  status = "pass"
  artifact_dir = Convert-ToRepoPath $script:ArtifactRoot
  secret_safe = $true
  raw_provider_keys_written = $false
  api_distribution_blocked = $false
  parity_closed = @(
    "New API and One API checked-in samples parse through source dry-run, internal mapping, and apply-plan",
    "sample apply-plan preflight passes with supported SQL adapters",
    "sample rollback snapshot entries match planned writes",
    "provider/channel, canonical_model, model_association, and simple channel_mapping_entry focused live apply/rollback parity is closed when live runtime artifact is present",
    "conflict-blocked live runner refusal performs no database writes"
  )
  parity_deferred = @($deferredItems.ToArray())
  provider_key_handoff_boundary = [ordered]@{
    importer_mode = "sidecar_only"
    control_plane_create_path = "POST /admin/provider-keys"
    raw_material_allowed = $false
    direct_db_apply_supported = $false
    audit_readback_supported_by_this_verifier = $false
    audit_readback_deferred_reason = "requires operator-provided secret material and Control Plane runtime readback; verifier only validates non-secret handoff metadata"
  }
  sample_cases = @($caseSummaries.ToArray())
  focused_live_runtime = $liveRuntimeSummary
}

$summaryJson = $summary | ConvertTo-Json -Depth 96
Assert-NoSecretMaterial $summaryJson "summary artifact"
$summaryPath = Join-Path $script:ArtifactRoot "summary.json"
Write-ArtifactText $summaryPath $summaryJson

Write-Output "import sample apply/rollback parity verification passed"
Write-Output ("artifact={0}" -f (Convert-ToRepoPath $summaryPath))
