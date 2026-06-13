[CmdletBinding()]
param(
  [string]$ArtifactPath = ".tmp\importers\import_apply_live_demo_verification.json"
)

$ErrorActionPreference = "Stop"

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:Runner = Join-Path $script:RepoRoot "scripts\importers\invoke-import-apply-live-demo.ps1"
$script:CanonicalFixture = Join-Path $script:RepoRoot "tests\fixtures\importers\apply_plan_canonical_only.sample.json"
$script:DemoDbPath = ".tmp\importers\import_apply_live_demo.verify.db.json"
$script:RuntimeArtifactPath = ".tmp\importers\import_apply_live_demo.verify.runtime.json"
$script:IdempotencyDemoDbPath = ".tmp\importers\import_apply_live_demo.verify.idempotency.db.json"
$script:IdempotencyRuntimeArtifactPath = ".tmp\importers\import_apply_live_demo.verify.idempotency.runtime.json"

function Assert-Condition {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "VERIFY FAILED: $Message" }
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $full = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $script:RepoRoot $Path }
  return (Get-Content -LiteralPath $full -Raw | ConvertFrom-Json)
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  $full = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $script:RepoRoot $Path }
  $dir = Split-Path -Parent $full
  if (-not (Test-Path -LiteralPath $dir)) {
    [void](New-Item -ItemType Directory -Force -Path $dir)
  }
  $Value | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $full -Encoding UTF8
}

$blockers = New-Object System.Collections.Generic.List[string]
$runtime = $null
$idempotencyRuntime = $null
$artifactText = $null

try {
  Assert-Condition (Test-Path -LiteralPath $script:Runner -PathType Leaf) "demo runner exists"
  Assert-Condition (Test-Path -LiteralPath $script:CanonicalFixture -PathType Leaf) "canonical sample fixture exists"

  $demoDbFull = Join-Path $script:RepoRoot $script:DemoDbPath
  if (Test-Path -LiteralPath $demoDbFull) {
    Remove-Item -LiteralPath $demoDbFull -Force
  }
  $idempotencyDemoDbFull = Join-Path $script:RepoRoot $script:IdempotencyDemoDbPath
  if (Test-Path -LiteralPath $idempotencyDemoDbFull) {
    Remove-Item -LiteralPath $idempotencyDemoDbFull -Force
  }

  $raw = & $script:Runner `
    -InputPath $script:CanonicalFixture `
    -DemoDbPath $script:DemoDbPath `
    -ArtifactPath $script:RuntimeArtifactPath `
    -ConfirmReviewedPlan `
    -RollbackAfterApply `
    -Force
  if (-not $?) {
    throw "demo runner failed"
  }
  $runtime = Read-JsonFile $script:RuntimeArtifactPath
  $artifactText = Get-Content -LiteralPath (Join-Path $script:RepoRoot $script:RuntimeArtifactPath) -Raw

  Assert-Condition ($runtime.status -eq "pass") "runtime artifact status pass"
  Assert-Condition ($runtime.local_demo_db -eq $true) "runtime uses local demo DB"
  Assert-Condition ($runtime.database_writes -eq $true) "runtime records demo DB writes"
  Assert-Condition ($runtime.secret_safe -eq $true) "runtime artifact is marked secret-safe"
  Assert-Condition ($runtime.provider_key_material_allowed -eq $false) "provider key material is not allowed"
  Assert-Condition ($runtime.raw_payload_omitted -eq $true) "raw payload is omitted"
  Assert-Condition ($runtime.authorization_omitted -eq $true) "Authorization header is omitted"
  Assert-Condition ($runtime.rollback_after_apply -eq $true) "rollback was requested"
  Assert-Condition ($runtime.rollback_journal_summary.entries -ge 1) "rollback journal has entries"
  Assert-Condition ($runtime.rollback_journal_summary.rolled_back_entries -ge 1) "rollback journal has rolled back entries"
  Assert-Condition ($runtime.idempotency_summary.operation_count -ge 1) "idempotency summary has operations"
  Assert-Condition ($runtime.idempotency_summary.raw_idempotency_keys_omitted -eq $true) "raw idempotency keys are omitted"
  Assert-Condition (@($runtime.apply_readback.operations).Count -ge 1) "apply journal readback has operations"
  Assert-Condition (@($runtime.rollback_readback.operations).Count -ge 1) "rollback journal readback has operations"

  Assert-Condition (-not ($artifactText -match "sk-[A-Za-z0-9_-]+")) "artifact does not contain provider key-looking value"
  Assert-Condition (-not ($artifactText -match "(?i)authorization\s*[:=]\s*(`"Bearer|Bearer)\s+[A-Za-z0-9._~+/=-]{8,}")) "artifact does not contain Authorization bearer value"
  Assert-Condition (-not ($artifactText -match "(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}")) "artifact does not contain raw bearer token"
  Assert-Condition (-not ($artifactText -match "(?i)raw_payload\s*[:=]\s*[\{\[]")) "artifact does not contain raw payload object"

  [void](& $script:Runner `
      -InputPath $script:CanonicalFixture `
      -DemoDbPath $script:IdempotencyDemoDbPath `
      -ArtifactPath $script:IdempotencyRuntimeArtifactPath `
      -ConfirmReviewedPlan `
      -Force)
  Assert-Condition ($?) "first idempotency demo apply succeeded"
  [void](& $script:Runner `
      -InputPath $script:CanonicalFixture `
      -DemoDbPath $script:IdempotencyDemoDbPath `
      -ArtifactPath $script:IdempotencyRuntimeArtifactPath `
      -ConfirmReviewedPlan `
      -Force)
  Assert-Condition ($?) "second idempotency demo apply succeeded"
  $idempotencyRuntime = Read-JsonFile $script:IdempotencyRuntimeArtifactPath
  Assert-Condition ($idempotencyRuntime.idempotency_summary.duplicate_same_after_hash -ge 1) "second apply records duplicate same-after-hash idempotency"
} catch {
  [void]$blockers.Add($_.Exception.Message)
}

$status = if ($blockers.Count -eq 0) { "pass" } else { "fail" }
$artifact = [ordered]@{
  schema = "importer_apply_live_demo_verification.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("O")
  status = $status
  runtime_artifact_path = $script:RuntimeArtifactPath
  demo_db_path = $script:DemoDbPath
  idempotency_artifact_path = $script:IdempotencyRuntimeArtifactPath
  local_demo_db = $true
  rollback_verified = ($status -eq "pass")
  idempotency_summary_verified = ($status -eq "pass")
  secret_safe_verified = ($status -eq "pass")
  checked_fixture = "tests/fixtures/importers/apply_plan_canonical_only.sample.json"
  blockers = @($blockers.ToArray())
}

Write-JsonFile -Path $ArtifactPath -Value $artifact

if ($status -eq "pass") {
  Write-Host "import_apply_live_demo_verification=pass"
  Write-Host "artifact=$ArtifactPath"
  exit 0
}

Write-Host "import_apply_live_demo_verification=fail"
foreach ($blocker in $blockers) {
  Write-Host $blocker
}
exit 1
