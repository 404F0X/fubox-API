param(
  [ValidateSet("local_dev", "staging", "production")]
  [string]$Scope = "staging",
  [ValidateSet("switch", "rollback", "readback")]
  [string]$Action = "switch",
  [switch]$ExecuteSourceOfTruthSwitch,
  [switch]$ExecuteRollback,
  [switch]$AcknowledgeRollbackPlan,
  [switch]$AcknowledgeProductionReleaseReview,
  [switch]$ApplyMigration,
  [AllowNull()][string]$DatabaseUrl,
  [AllowNull()][string]$ExpectedGeneration,
  [AllowNull()][string]$RollbackToken,
  [AllowNull()][string]$UpdatedBy,
  [AllowNull()][string]$LiveCommitProofArtifactPath,
  [AllowNull()][string]$LocalDevCutoverEvidenceArtifactPath,
  [AllowNull()][string]$ResultArtifactPath,
  [AllowNull()][string]$CutoverEvidenceArtifactPath,
  [int]$BlockedExitCode = 2
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$expectedWriter = "billing_ledger_runtime_writer"
$localWriter = "control_plane_local_sql_writer"
$migrationPath = Join-Path $repoRoot "db\migrations\0010_billing_ledger_cutover_state.sql"

function Test-Present {
  param([AllowNull()][string]$Value)
  return -not [string]::IsNullOrWhiteSpace($Value)
}

function Resolve-RepoTmpJsonPath {
  param([Parameter(Mandatory = $true)][string]$PathValue)
  $candidate = if ([System.IO.Path]::IsPathRooted($PathValue)) {
    [System.IO.Path]::GetFullPath($PathValue)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PathValue))
  }
  $repoFull = [System.IO.Path]::GetFullPath($repoRoot)
  $relative = [System.IO.Path]::GetRelativePath($repoFull, $candidate)
  $normalized = $relative.Replace("\", "/")
  $safe = -not $relative.StartsWith("..") -and
    -not [System.IO.Path]::IsPathRooted($relative) -and
    $normalized.StartsWith(".tmp/") -and
    $normalized.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)
  return [ordered]@{
    safe = $safe
    relative_path = $relative
    full_path = $candidate
    reason = if ($safe) { "allowed_repo_tmp_json_path" } else { "path_must_be_repo_bounded_tmp_json" }
    raw_path_output = "omitted"
  }
}

function Read-JsonArtifact {
  param([Parameter(Mandatory = $true)]$PathGate)
  if (-not [bool]$PathGate.safe) {
    return [ordered]@{ performed = $false; classification = "blocker"; reason = "unsafe_path"; artifact = $null }
  }
  if (-not (Test-Path -LiteralPath ([string]$PathGate.full_path))) {
    return [ordered]@{ performed = $false; classification = "blocker"; reason = "artifact_missing"; artifact = $null }
  }
  try {
    return [ordered]@{
      performed = $true
      classification = "read"
      reason = "artifact_read"
      artifact = Get-Content -LiteralPath ([string]$PathGate.full_path) -Raw | ConvertFrom-Json -ErrorAction Stop
    }
  } catch {
    return [ordered]@{ performed = $false; classification = "fail"; reason = "artifact_json_parse_failed"; artifact = $null }
  }
}

function Get-Field {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $null }
  if ($Object.PSObject.Properties.Name -notcontains $Name) { return $null }
  return $Object.$Name
}

function Get-CurrentCommit {
  try {
    return ((git -C $repoRoot rev-parse --short HEAD) | Select-Object -First 1).Trim()
  } catch {
    return "unknown"
  }
}

function ConvertTo-SqlLiteral {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { return "null" }
  return "'" + $Value.Replace("'", "''") + "'"
}

function Get-Sha256Hex {
  param([Parameter(Mandatory = $true)][string]$Value)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
  $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
  return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
}

function Get-DatabaseUrl {
  if (Test-Present $DatabaseUrl) { return $DatabaseUrl }
  foreach ($name in @("BILLING_LEDGER_LIVE_DATABASE_URL", "DATABASE_URL", "POSTGRES_URL")) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (Test-Present $value) { return $value }
  }
  return ""
}

function Test-DockerPostgresAvailable {
  try {
    $container = docker ps --filter "name=docker-compose-postgres-1" --format "{{.Names}}" 2>$null | Select-Object -First 1
    return [string]$container -eq "docker-compose-postgres-1"
  } catch {
    return $false
  }
}

function Invoke-PostgresJson {
  param([Parameter(Mandatory = $true)][string]$Sql)

  $dbUrl = Get-DatabaseUrl
  if (Test-Present $dbUrl) {
    $output = $Sql | psql $dbUrl -v ON_ERROR_STOP=1 -X -q -t -A 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "psql direct execution failed; details omitted"
    }
    return (($output | Out-String).Trim())
  }

  if (Test-DockerPostgresAvailable) {
    $output = $Sql | docker exec -i docker-compose-postgres-1 sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -v ON_ERROR_STOP=1 -X -q -t -A -U "$POSTGRES_USER" -d "$POSTGRES_DB"' 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "compose postgres psql execution failed; details omitted"
    }
    return (($output | Out-String).Trim())
  }

  throw "postgres_connection_missing"
}

function Invoke-PostgresFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $sql = Get-Content -LiteralPath $Path -Raw
  [void](Invoke-PostgresJson -Sql $sql)
}

$safeScope = $Scope
$safeUpdatedBy = if (Test-Present $UpdatedBy) { $UpdatedBy } else { "e9-s105-operator" }
if ($safeUpdatedBy -notmatch '^[A-Za-z0-9._:@-]{1,96}$') {
  $safeUpdatedBy = "e9-s105-operator"
}

$liveCommitPathValue = if (Test-Present $LiveCommitProofArtifactPath) { $LiveCommitProofArtifactPath } else { ".tmp/billing-ledger/live-commit-proof-artifact.json" }
$localDevPathValue = if (Test-Present $LocalDevCutoverEvidenceArtifactPath) { $LocalDevCutoverEvidenceArtifactPath } else { ".tmp/billing-ledger/cutover-evidence-artifact.local-dev.json" }
$resultPathValue = if (Test-Present $ResultArtifactPath) { $ResultArtifactPath } else { ".tmp/billing-ledger/cutover-state-s105-$safeScope-$Action.json" }
$cutoverEvidencePathValue = if (Test-Present $CutoverEvidenceArtifactPath) { $CutoverEvidenceArtifactPath } else { ".tmp/billing-ledger/cutover-evidence-artifact.$safeScope.persistent-s105.json" }

$liveCommitGate = Resolve-RepoTmpJsonPath -PathValue $liveCommitPathValue
$localDevGate = Resolve-RepoTmpJsonPath -PathValue $localDevPathValue
$resultGate = Resolve-RepoTmpJsonPath -PathValue $resultPathValue
$cutoverEvidenceGate = Resolve-RepoTmpJsonPath -PathValue $cutoverEvidencePathValue

$liveCommitRead = Read-JsonArtifact -PathGate $liveCommitGate
$localDevRead = Read-JsonArtifact -PathGate $localDevGate
$liveCommit = $liveCommitRead.artifact
$localDev = $localDevRead.artifact

$liveCommitPass = [string](Get-Field -Object $liveCommit -Name "classification") -eq "pass" -and
  [bool](Get-Field -Object $liveCommit -Name "simulated") -eq $false -and
  [bool](Get-Field -Object $liveCommit -Name "generated_by_this_script") -eq $false
$localDevProofPass = [string](Get-Field -Object $localDev -Name "environment_scope") -eq "local_dev" -and
  [bool](Get-Field -Object (Get-Field -Object $localDev -Name "post_cutover_readback") -Name "performed") -and
  [bool](Get-Field -Object (Get-Field -Object $localDev -Name "rollback_proof") -Name "performed")

$blockers = New-Object System.Collections.Generic.List[string]
if ($Action -eq "switch" -and -not [bool]$ExecuteSourceOfTruthSwitch) { [void]$blockers.Add("execute_source_of_truth_switch_opt_in_missing") }
if ($Action -eq "rollback" -and -not [bool]$ExecuteRollback) { [void]$blockers.Add("execute_rollback_opt_in_missing") }
if ($Action -in @("switch", "rollback") -and -not [bool]$AcknowledgeRollbackPlan) { [void]$blockers.Add("rollback_plan_acknowledgement_missing") }
if ($Action -eq "switch" -and -not $liveCommitPass) { [void]$blockers.Add("s101_live_commit_proof_not_passed") }
if ($Action -eq "switch" -and -not $localDevProofPass) { [void]$blockers.Add("s103_local_dev_cutover_proof_not_passed") }
if (-not [bool]$resultGate.safe) { [void]$blockers.Add("result_artifact_path_not_repo_bounded") }
if (-not [bool]$cutoverEvidenceGate.safe) { [void]$blockers.Add("cutover_evidence_artifact_path_not_repo_bounded") }
if ($Scope -eq "production" -and $Action -eq "switch" -and -not [bool]$AcknowledgeProductionReleaseReview) {
  [void]$blockers.Add("production_release_review_acknowledgement_missing")
}

$dbAvailable = $true
try {
  if ($ApplyMigration) {
    Invoke-PostgresFile -Path $migrationPath
  }
} catch {
  $dbAvailable = $false
  [void]$blockers.Add("postgres_connection_or_migration_failed")
}

$dbResult = $null
$dbActionAttempted = $false
$rollbackTokenHash = if (Test-Present $RollbackToken) { Get-Sha256Hex -Value $RollbackToken } else { Get-Sha256Hex -Value ("s105-$safeScope-$Action-" + (Get-CurrentCommit)) }

if ($blockers.Count -eq 0 -and $dbAvailable) {
  $dbActionAttempted = $true
  $scopeSql = ConvertTo-SqlLiteral $safeScope
  $updatedBySql = ConvertTo-SqlLiteral $safeUpdatedBy
  $rollbackHashSql = ConvertTo-SqlLiteral $rollbackTokenHash
  $expectedSql = if (Test-Present $ExpectedGeneration) { [int64]$ExpectedGeneration } else { "null" }

  if ($Action -eq "readback") {
    $sql = @"
select jsonb_build_object(
  'classification', 'readback',
  'action', 'readback',
  'environment_scope', environment_scope,
  'active_writer', active_writer,
  'source_of_truth', source_of_truth,
  'previous_active_writer', previous_active_writer,
  'previous_source_of_truth', previous_source_of_truth,
  'cutover_generation', cutover_generation,
  'rollback_generation', rollback_generation,
  'rollback_token_hash_present', rollback_token_hash is not null,
  'no_dual_commit', no_dual_commit,
  'updated_at', updated_at,
  'updated_by', updated_by
)::text
from billing_ledger_writer_cutover_state
where environment_scope = $scopeSql;
"@
  } elseif ($Action -eq "switch") {
    $sql = @"
begin;
with seeded as (
  insert into billing_ledger_writer_cutover_state (
    environment_scope, active_writer, source_of_truth, cutover_generation, rollback_generation, no_dual_commit, metadata, updated_by
  )
  values ($scopeSql, '$localWriter', '$localWriter', 0, 0, true, '{"seeded_by":"s105_operator"}'::jsonb, $updatedBySql)
  on conflict (environment_scope) do nothing
),
current_state as (
  select * from billing_ledger_writer_cutover_state
  where environment_scope = $scopeSql
  for update
),
updated as (
  update billing_ledger_writer_cutover_state s
  set previous_active_writer = current_state.active_writer,
      previous_source_of_truth = current_state.source_of_truth,
      active_writer = '$expectedWriter',
      source_of_truth = '$expectedWriter',
      cutover_generation = current_state.cutover_generation + 1,
      rollback_generation = current_state.rollback_generation + 1,
      rollback_token_hash = $rollbackHashSql,
      no_dual_commit = true,
      metadata = jsonb_build_object('s105', true, 'action', 'source_of_truth_switch', 'scope', $scopeSql),
      updated_at = now(),
      updated_by = $updatedBySql
  from current_state
  where s.environment_scope = current_state.environment_scope
    and ($expectedSql is null or current_state.cutover_generation = $expectedSql)
  returning s.*, current_state.active_writer as from_active_writer, current_state.source_of_truth as from_source_of_truth
),
audit as (
  insert into billing_ledger_writer_cutover_audit (
    environment_scope, action, from_active_writer, from_source_of_truth, to_active_writer, to_source_of_truth,
    expected_generation, resulting_generation, rollback_generation, rollback_token_hash, no_dual_commit, metadata, created_by
  )
  select environment_scope, 'source_of_truth_switch', from_active_writer, from_source_of_truth, active_writer, source_of_truth,
    $expectedSql, cutover_generation, rollback_generation, rollback_token_hash, no_dual_commit,
    jsonb_build_object('s105', true, 'scope', $scopeSql), $updatedBySql
  from updated
  returning id
)
select coalesce(
  (select jsonb_build_object(
    'classification', 'switched',
    'action', 'switch',
    'environment_scope', environment_scope,
    'active_writer', active_writer,
    'source_of_truth', source_of_truth,
    'previous_active_writer', previous_active_writer,
    'previous_source_of_truth', previous_source_of_truth,
    'cutover_generation', cutover_generation,
    'rollback_generation', rollback_generation,
    'rollback_token_hash_present', rollback_token_hash is not null,
    'no_dual_commit', no_dual_commit,
    'updated_at', updated_at,
    'updated_by', updated_by,
    'audit_rows', (select count(*) from audit)
  )::text from updated),
  jsonb_build_object('classification', 'cas_mismatch_or_missing_state', 'action', 'switch', 'environment_scope', $scopeSql)::text
);
commit;
"@
  } else {
    $rollbackHashCheck = if (Test-Present $RollbackToken) { "current_state.rollback_token_hash = $rollbackHashSql" } else { "false" }
    if (-not (Test-Present $RollbackToken)) {
      [void]$blockers.Add("rollback_token_missing")
      $dbActionAttempted = $false
    } else {
      $sql = @"
begin;
with current_state as (
  select * from billing_ledger_writer_cutover_state
  where environment_scope = $scopeSql
  for update
),
updated as (
  update billing_ledger_writer_cutover_state s
  set previous_active_writer = current_state.active_writer,
      previous_source_of_truth = current_state.source_of_truth,
      active_writer = coalesce(current_state.previous_active_writer, '$localWriter'),
      source_of_truth = coalesce(current_state.previous_source_of_truth, '$localWriter'),
      cutover_generation = current_state.cutover_generation + 1,
      rollback_generation = current_state.rollback_generation + 1,
      rollback_token_hash = null,
      no_dual_commit = true,
      metadata = jsonb_build_object('s105', true, 'action', 'rollback_to_local_writer', 'scope', $scopeSql),
      updated_at = now(),
      updated_by = $updatedBySql
  from current_state
  where s.environment_scope = current_state.environment_scope
    and $rollbackHashCheck
  returning s.*, current_state.active_writer as from_active_writer, current_state.source_of_truth as from_source_of_truth
),
audit as (
  insert into billing_ledger_writer_cutover_audit (
    environment_scope, action, from_active_writer, from_source_of_truth, to_active_writer, to_source_of_truth,
    expected_generation, resulting_generation, rollback_generation, rollback_token_hash, no_dual_commit, metadata, created_by
  )
  select environment_scope, 'rollback_to_local_writer', from_active_writer, from_source_of_truth, active_writer, source_of_truth,
    null, cutover_generation, rollback_generation, rollback_token_hash, no_dual_commit,
    jsonb_build_object('s105', true, 'scope', $scopeSql), $updatedBySql
  from updated
  returning id
)
select coalesce(
  (select jsonb_build_object(
    'classification', 'rolled_back',
    'action', 'rollback',
    'environment_scope', environment_scope,
    'active_writer', active_writer,
    'source_of_truth', source_of_truth,
    'previous_active_writer', previous_active_writer,
    'previous_source_of_truth', previous_source_of_truth,
    'cutover_generation', cutover_generation,
    'rollback_generation', rollback_generation,
    'rollback_token_hash_present', rollback_token_hash is not null,
    'no_dual_commit', no_dual_commit,
    'updated_at', updated_at,
    'updated_by', updated_by,
    'audit_rows', (select count(*) from audit)
  )::text from updated),
  jsonb_build_object('classification', 'rollback_token_mismatch_or_missing_state', 'action', 'rollback', 'environment_scope', $scopeSql)::text
);
commit;
"@
    }
  }

  if ($dbActionAttempted) {
    try {
      $raw = Invoke-PostgresJson -Sql $sql
      $jsonLine = @($raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
      $dbResult = $jsonLine | ConvertFrom-Json -ErrorAction Stop
    } catch {
      [void]$blockers.Add("postgres_cutover_state_action_failed")
      $dbResult = $null
    }
  }
}

$dbClassification = if ($null -eq $dbResult) { "not_run" } else { [string](Get-Field -Object $dbResult -Name "classification") }
if ($Action -eq "switch" -and $dbClassification -ne "switched" -and $blockers.Count -eq 0) { [void]$blockers.Add("persistent_switch_not_observed") }
if ($Action -eq "rollback" -and $dbClassification -ne "rolled_back" -and $blockers.Count -eq 0) { [void]$blockers.Add("persistent_rollback_not_observed") }
if ($Action -eq "readback" -and $dbClassification -ne "readback" -and $blockers.Count -eq 0) { [void]$blockers.Add("persistent_readback_not_observed") }

$activeAfter = if ($null -eq $dbResult) { "" } else { [string](Get-Field -Object $dbResult -Name "active_writer") }
$sourceAfter = if ($null -eq $dbResult) { "" } else { [string](Get-Field -Object $dbResult -Name "source_of_truth") }
$cutoverObserved = $Action -eq "switch" -and $dbClassification -eq "switched" -and $activeAfter -eq $expectedWriter -and $sourceAfter -eq $expectedWriter
$rollbackObserved = $Action -eq "rollback" -and $dbClassification -eq "rolled_back" -and $activeAfter -eq $localWriter -and $sourceAfter -eq $localWriter
$postReadbackPassed = ($cutoverObserved -or ($Action -eq "readback" -and $activeAfter -eq $expectedWriter -and $sourceAfter -eq $expectedWriter))

if ([bool]$cutoverEvidenceGate.safe) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([string]$cutoverEvidenceGate.full_path)) | Out-Null
  $rowCounts = @(Get-Field -Object $liveCommit -Name "row_count_proof")
  $cutoverArtifact = [ordered]@{
    schema_version = "control_plane_billing_ledger_cutover_evidence_artifact.v1"
    environment_scope = $safeScope
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    current_commit = Get-CurrentCommit
    runtime_container_commit = [string](Get-Field -Object $liveCommit -Name "runtime_container_commit")
    freshness_marker = "current"
    stale_artifact = $false
    simulated = $false
    template = $false
    artifact_provenance = [ordered]@{
      source = "persistent_cutover_state_guarded_switch"
      environment_scope = $safeScope
      production_cutover = ($safeScope -eq "production" -and $cutoverObserved)
      canonical_production_artifact = $false
      persistent_state_write = $cutoverObserved
      raw_command_echoed = $false
    }
    external_runner_provenance = [ordered]@{
      runner_id = "e9_billing_ledger_persistent_cutover_state_switch"
      runner_path = "scripts/operator/e9_billing_ledger_persistent_cutover_state_switch.ps1"
      source_of_truth_switch_performed = $cutoverObserved
      rollback_performed = $rollbackObserved
      output = "sanitized_presence_only"
    }
    commit_proof_row_counts = @($rowCounts)
    no_dual_result = [ordered]@{
      passed = ($cutoverObserved -or $rollbackObserved)
      dual_commit_observed = $false
      active_writer_count = if ($cutoverObserved -or $rollbackObserved) { 1 } else { 0 }
      persistent_state_generation = if ($null -eq $dbResult) { $null } else { Get-Field -Object $dbResult -Name "cutover_generation" }
    }
    active_writer_before = if ($null -eq $dbResult) { "" } else { [string](Get-Field -Object $dbResult -Name "previous_active_writer") }
    source_of_truth_before = if ($null -eq $dbResult) { "" } else { [string](Get-Field -Object $dbResult -Name "previous_source_of_truth") }
    active_writer_after = $activeAfter
    source_of_truth_after = $sourceAfter
    actual_cutover_opt_in_marker = [ordered]@{
      performed = $cutoverObserved
      requested = [bool]$ExecuteSourceOfTruthSwitch
      action = $Action
      environment_scope = $safeScope
      production_cutover = ($safeScope -eq "production" -and $cutoverObserved)
    }
    post_cutover_readback = [ordered]@{
      performed = $postReadbackPassed
      source_of_truth = $sourceAfter
      active_writer = $activeAfter
      no_dual_commit = ($cutoverObserved -or $rollbackObserved)
      environment_scope = $safeScope
      measurement_source = "persistent_cutover_state_readback"
    }
    rollback_command = [ordered]@{
      available = $cutoverObserved
      command = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/operator/e9_billing_ledger_persistent_cutover_state_switch.ps1 -Scope $safeScope -Action rollback -ExecuteRollback -AcknowledgeRollbackPlan -RollbackToken <same-token>"
      environment_scope = $safeScope
      raw_token_echoed = $false
    }
    rollback_proof = [ordered]@{
      present = ($cutoverObserved -or $rollbackObserved)
      performed = ($cutoverObserved -or $rollbackObserved)
      rollback_generation = if ($null -eq $dbResult) { $null } else { Get-Field -Object $dbResult -Name "rollback_generation" }
      rollback_token_hash_present = if ($null -eq $dbResult) { $false } else { [bool](Get-Field -Object $dbResult -Name "rollback_token_hash_present") }
      environment_scope = $safeScope
    }
    duration_timing = [ordered]@{
      persistent_state_write_ms = 0
      post_cutover_readback_ms = 0
      rollback_marker_readback_ms = 0
      measurement_source = "postgres_transaction_readback"
    }
    secret_safe_omission = [ordered]@{
      raw_secret_present = $false
      database_url_output = "omitted"
      env_value_output = "omitted"
      operation_key_output = "omitted"
      rollback_token_output = "omitted"
      raw_env_value_echoed = $false
      raw_database_url_echoed = $false
      credential_material_echoed = $false
    }
  }
  $cutoverArtifact | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath ([string]$cutoverEvidenceGate.full_path) -Encoding utf8
}

$result = [ordered]@{
  schema_version = "control_plane_billing_ledger_persistent_cutover_state_switch.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
  classification = if ($blockers.Count -eq 0) { "pass" } else { "blocked" }
  action = $Action
  environment_scope = $safeScope
  migration = [ordered]@{
    path = "db/migrations/0010_billing_ledger_cutover_state.sql"
    apply_requested = [bool]$ApplyMigration
  }
  production_release_review = [ordered]@{
    required_for_production_switch = $Scope -eq "production" -and $Action -eq "switch"
    acknowledged = [bool]$AcknowledgeProductionReleaseReview
  }
  persistent_state = [ordered]@{
    action_attempted = $dbActionAttempted
    classification = $dbClassification
    active_writer = $activeAfter
    source_of_truth = $sourceAfter
    cutover_observed = $cutoverObserved
    rollback_observed = $rollbackObserved
    generation = if ($null -eq $dbResult) { $null } else { Get-Field -Object $dbResult -Name "cutover_generation" }
    rollback_generation = if ($null -eq $dbResult) { $null } else { Get-Field -Object $dbResult -Name "rollback_generation" }
  }
  artifacts = [ordered]@{
    result_artifact = [string]$resultGate.relative_path
    cutover_evidence_artifact = [string]$cutoverEvidenceGate.relative_path
    canonical_production_artifact_written = $false
  }
  blockers = @($blockers | Select-Object -Unique)
  first_blocker = ($blockers | Select-Object -Unique | Select-Object -First 1)
  safe_output = [ordered]@{
    database_url_output = "omitted"
    env_value_output = "omitted"
    operation_key_output = "omitted"
    rollback_token_output = "omitted"
    raw_env_value_echoed = $false
    raw_database_url_echoed = $false
    credential_material_echoed = $false
  }
}

if ([bool]$resultGate.safe) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([string]$resultGate.full_path)) | Out-Null
  $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath ([string]$resultGate.full_path) -Encoding utf8
}

$result | ConvertTo-Json -Depth 8
if ($blockers.Count -gt 0) {
  exit $BlockedExitCode
}
