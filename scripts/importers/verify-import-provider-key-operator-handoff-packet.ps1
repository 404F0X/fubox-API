[CmdletBinding()]
param(
  [string]$ArtifactDir = ".tmp\importers\provider_key_operator_handoff"
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

function Get-StableHash {
  param(
    [string]$Value,
    [int]$Length = 24
  )

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = $sha.ComputeHash($bytes)
    $hex = -join ($hash | ForEach-Object { $_.ToString("x2") })
    return $hex.Substring(0, [Math]::Min($Length, $hex.Length))
  } finally {
    $sha.Dispose()
  }
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

function Assert-ProviderKeyBoundary {
  param(
    [object]$ApplyPlan,
    [string]$Context
  )

  Assert-Condition ($ApplyPlan.provider_key_handoff_contract.raw_material_allowed -eq $false) "$Context plaintext provider credential material is disallowed"
  Assert-Condition ($ApplyPlan.provider_key_handoff_contract.apply_directly_supported -eq $false) "$Context provider key direct apply is disabled"
  Assert-Condition ($ApplyPlan.provider_key_handoff_contract.required_operator_path -eq "POST /admin/provider-keys") "$Context requires Control Plane provider-key create path"

  $writeTargets = @(Convert-ToArray $ApplyPlan.planned_creates) + @(Convert-ToArray $ApplyPlan.planned_updates)
  Assert-Condition (@($writeTargets | Where-Object { $_.target.kind -match "provider_key|secret" }).Count -eq 0) "$Context has no provider-key write target"

  $operationPlans = @(Convert-ToArray $ApplyPlan.sql_executor_plan.transaction.operation_plans)
  Assert-Condition (@($operationPlans | Where-Object { $_.target.kind -match "provider_key|secret" }).Count -eq 0) "$Context has no provider-key SQL operation"
}

function New-OperatorHandoffPacket {
  param(
    [string]$CaseName,
    [object]$ApplyPlan,
    [string]$ApplyPlanArtifact
  )

  $handoffs = @(Convert-ToArray $ApplyPlan.provider_key_handoffs)
  Assert-Condition ($handoffs.Count -gt 0) "$CaseName apply plan exposes provider-key handoffs"
  Assert-Condition ($handoffs.Count -eq [int]$ApplyPlan.counts.source_provider_key_handoffs) "$CaseName handoff count matches apply-plan count"

  $metadata = New-Object System.Collections.Generic.List[object]
  foreach ($handoff in $handoffs) {
    Assert-Condition ($handoff.raw_material_exported -eq $false) "$CaseName handoff omits raw material"
    Assert-Condition ($handoff.provider_key_material_included -eq $false) "$CaseName handoff omits provider key material"
    Assert-Condition ($handoff.raw_secret_in_artifact -eq $false) "$CaseName handoff marks raw secret absent"
    Assert-Condition ($handoff.secret_material_in_artifact -eq $false) "$CaseName handoff marks secret material absent"
    Assert-Condition ($handoff.schema_version -eq "importer.provider-key-operator-sidecar.v1") "$CaseName handoff uses operator sidecar schema"
    Assert-Condition ($handoff.required_manual_secret_entry -eq $true) "$CaseName handoff requires manual secret entry"
    Assert-Condition ($handoff.apply_directly_supported -eq $false) "$CaseName handoff is not directly applicable"
    Assert-Condition ($handoff.apply_mode -eq "sidecar_only") "$CaseName handoff is sidecar-only"
    Assert-Condition ($handoff.required_operator_path -eq "POST /admin/provider-keys" -or $handoff.recommended_path -eq "POST /admin/provider-keys") "$CaseName handoff points to Control Plane provider-key path"
    Assert-Condition ([bool]$handoff.credential_material_present) "$CaseName handoff records source credential presence"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handoff.credential_locator_redacted)) "$CaseName handoff uses a redacted locator"
    Assert-Condition (@(Convert-ToArray $handoff.credential_locator_hashes).Count -gt 0) "$CaseName handoff includes locator hash evidence"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handoff.fingerprint)) "$CaseName handoff includes non-secret fingerprint"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handoff.provider_alias)) "$CaseName handoff includes provider alias"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handoff.channel_alias)) "$CaseName handoff includes channel alias"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handoff.rotation_next_step)) "$CaseName handoff includes rotation next step"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handoff.recovery_next_step)) "$CaseName handoff includes recovery next step"

    $binding = $handoff.source_channel_binding
    Assert-Condition ($null -ne $binding) "$CaseName handoff includes source channel binding metadata"
    Assert-Condition ([string]$handoff.binding_status -eq "bound") "$CaseName handoff is bound to an imported channel"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$binding.internal_channel_id)) "$CaseName handoff includes internal channel id"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$binding.internal_provider_id)) "$CaseName handoff includes internal provider id"

    $metadata.Add([ordered]@{
        schema_version = "importer.provider-key-operator-sidecar.v1"
        handoff_id = [string]$handoff.handoff_id
        channel_source_id = [string]$handoff.channel_source_id
        key_alias = [string]$handoff.key_alias
        provider_alias = [string]$handoff.provider_alias
        channel_alias = [string]$handoff.channel_alias
        fingerprint = [string]$handoff.fingerprint
        binding_status = [string]$handoff.binding_status
        provider_code = [string]$binding.provider_code
        channel_name = [string]$binding.channel_name
        protocol_mode = [string]$binding.protocol_mode
        internal_provider_id = [string]$binding.internal_provider_id
        internal_channel_id = [string]$binding.internal_channel_id
        credential_origin = [string]$handoff.credential_origin
        credential_locator_redacted = [string]$handoff.credential_locator_redacted
        credential_locator_hashes = @(Convert-ToArray $handoff.credential_locator_hashes)
        source_reports = @(Convert-ToArray $handoff.source_reports)
        plaintext_provider_credential_included = $false
        raw_secret_in_artifact = $false
        secret_material_in_artifact = $false
        importer_provider_key_sql_operation = $false
        required_manual_secret_entry = $true
        rotation_next_step = [string]$handoff.rotation_next_step
        recovery_next_step = [string]$handoff.recovery_next_step
        manual_secret_entry_contract = [ordered]@{
          schema_version = "importer.provider-key-manual-secret-entry.v1"
          required_manual_secret_entry = $true
          one_time_entry_only = $true
          entry_path = "POST /admin/provider-keys"
          raw_secret_source = "operator_out_of_band"
          packet_contains_secret_material = $false
        }
        create_request_metadata = [ordered]@{
          method = "POST"
          path = "/admin/provider-keys"
          non_secret_prefill = [ordered]@{
            provider_id = [string]$binding.internal_provider_id
            channel_id = [string]$binding.internal_channel_id
            alias = [string]$handoff.key_alias
            status = "enabled"
            imported_handoff_id = [string]$handoff.handoff_id
            source_channel_id = [string]$handoff.channel_source_id
          }
          operator_secret_entry_required = $true
          operator_secret_material_in_packet = $false
          raw_secret_placeholder_written = $false
        }
        required_audit_readback = [ordered]@{
          status = "deferred"
          deferred_reason = "operator_secret_required; importer verifier must not write or persist plaintext provider credentials"
          expected_non_secret_evidence = @(
            "provider_key_id",
            "provider_id",
            "channel_id",
            "alias",
            "status",
            "secret_fingerprint or equivalent non-secret fingerprint",
            "created_by or actor",
            "created_at",
            "audit_event_id"
          )
          forbidden_readback_evidence = @(
            "plaintext credential value",
            "plaintext secret",
            "credential header value"
          )
        }
      }) | Out-Null
  }

  $packetBasis = "$CaseName|$($ApplyPlan.idempotency_key)|$($handoffs.Count)"
  return [ordered]@{
    schema = "importer.provider-key-operator-handoff-packet.v1"
    packet_id = "provider-key-operator-handoff:v1:$(Get-StableHash $packetBasis 24)"
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString("O")
    source_case = $CaseName
    generated_from_apply_plan = Convert-ToRepoPath $ApplyPlanArtifact
    status = "ready_for_operator_secret_entry"
    secret_safe = $true
    plaintext_provider_credentials_included = $false
    raw_secrets_included = $false
    importer_writes_provider_keys = $false
    api_distribution_blocked = $false
    control_plane_create_path = "POST /admin/provider-keys"
    operator_secret_status = "deferred_required"
    operator_secret_deferred_reason = "checked-in samples only contain redacted credential locators; a real operator secret must be entered through Control Plane"
    handoff_count = $handoffs.Count
    create_handoff_metadata = @($metadata.ToArray())
  }
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
foreach ($case in $cases) {
  $sourcePath = Join-Path $script:ArtifactRoot "$($case.name).source.json"
  $mappingPath = Join-Path $script:ArtifactRoot "$($case.name).mapping.json"
  $applyPlanPath = Join-Path $script:ArtifactRoot "$($case.name).apply_plan.json"
  $packetPath = Join-Path $script:ArtifactRoot "$($case.name).operator_handoff_packet.json"

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
  Assert-ProviderKeyBoundary $applyPlan "$($case.name) apply plan"

  $packet = New-OperatorHandoffPacket $case.name $applyPlan $applyPlanPath
  $packetJson = $packet | ConvertTo-Json -Depth 96
  Assert-NoSecretMaterial $packetJson "$($case.name) operator handoff packet"
  Write-ArtifactText $packetPath $packetJson

  $caseSummaries.Add([ordered]@{
      name = $case.name
      source_artifact = Convert-ToRepoPath $sourcePath
      mapping_artifact = Convert-ToRepoPath $mappingPath
      apply_plan_artifact = Convert-ToRepoPath $applyPlanPath
      operator_handoff_packet_artifact = Convert-ToRepoPath $packetPath
      source_provider_keys = [int]$source.counts.provider_keys
      mapping_provider_key_handoffs = [int]$mapping.counts.provider_key_handoffs
      apply_plan_provider_key_handoffs = [int]$applyPlan.counts.source_provider_key_handoffs
      operator_handoff_metadata_entries = [int]$packet.handoff_count
      plaintext_provider_credentials_included = $false
      provider_key_write_targets = 0
      provider_key_sql_operations = 0
      audit_readback_status = "deferred"
      api_distribution_blocked = $false
    }) | Out-Null
}

$summary = [ordered]@{
  schema = "importer.provider-key-operator-handoff-packet-verification.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("O")
  status = "pass"
  artifact_dir = Convert-ToRepoPath $script:ArtifactRoot
  secret_safe = $true
  plaintext_provider_credentials_written = $false
  plaintext_provider_credentials_in_packets = $false
  raw_secrets_in_packets = $false
  provider_key_sql_operations = 0
  control_plane_create_path = "POST /admin/provider-keys"
  operator_secret_status = "deferred_required"
  audit_readback_status = "deferred"
  deferred_reason = "requires real operator secret entry through POST /admin/provider-keys; verifier intentionally refuses to write plaintext provider credentials"
  api_distribution_blocked = $false
  cases = @($caseSummaries.ToArray())
}

$summaryPath = Join-Path $script:ArtifactRoot "summary.json"
$summaryJson = $summary | ConvertTo-Json -Depth 96
Assert-NoSecretMaterial $summaryJson "summary artifact"
Write-ArtifactText $summaryPath $summaryJson

Write-Output "import provider key operator handoff packet verification passed"
Write-Output ("artifact={0}" -f (Convert-ToRepoPath $summaryPath))
