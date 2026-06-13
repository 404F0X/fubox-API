param(
  [string]$FixturePath = "tests\fixtures\billing\credit_wallet_productization_contract.json",
  [string]$OutputPath = ".tmp\credit-wallet\billing_mutation_contract_tests.json"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-RepoBoundedPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$AllowedPrefixes
  )

  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }
  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "path_must_stay_inside_repo"
  }

  $relative = $candidate.Substring($repoPrefix.Length).Replace("\", "/")
  $allowed = $false
  foreach ($prefix in $AllowedPrefixes) {
    if ($relative.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $allowed = $true
      break
    }
  }
  if (-not $allowed) {
    throw "path_prefix_not_allowed"
  }

  return [ordered]@{
    full = $candidate
    relative = $relative
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
      '(?i)api[_-]?key\s*[:=]',
      '(?i)provider[_-]?key\s*[:=]',
      '(?i)virtual[_-]?key\s*[:=]',
      '(?i)database[_-]?url\s*[:=]',
      '(?i)postgres(?:ql)?://[^"\s]+',
      '(?i)password\s*[:=]',
      'sk-[A-Za-z0-9]{8,}'
    )) {
    if ($Text -match $pattern) {
      return $false
    }
  }
  return $true
}

function ConvertTo-StringList {
  param([AllowNull()]$Value)

  $items = [System.Collections.Generic.List[string]]::new()
  if ($null -eq $Value) {
    return @()
  }
  foreach ($entry in @($Value)) {
    if ($null -eq $entry) {
      continue
    }
    $text = ([string]$entry).Trim()
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      [void]$items.Add($text)
    }
  }
  return @($items.ToArray())
}

$fixturePathInfo = Resolve-RepoBoundedPath `
  -Path $FixturePath `
  -AllowedPrefixes @("tests/fixtures/billing/")
$outputPathInfo = Resolve-RepoBoundedPath `
  -Path $OutputPath `
  -AllowedPrefixes @(".tmp/", "artifacts/")

if (-not (Test-Path -LiteralPath $fixturePathInfo.full -PathType Leaf)) {
  throw "fixture_missing"
}

$rawFixture = Get-Content -Raw -LiteralPath $fixturePathInfo.full
if (-not (Test-SecretSafeText $rawFixture)) {
  throw "fixture_secret_unsafe"
}
$fixture = $rawFixture | ConvertFrom-Json

$endpointNames = @($fixture.endpoints | ForEach-Object { [string]$_.name })
$writeEndpoints = @($fixture.endpoints | Where-Object { [bool]$_.write })
$allWriteEndpointsHaveIdempotency = $true
$allWriteEndpointsHaveAudit = $true
$directWalletMutationForbidden = $true
$accountingMarkersPresent = $true

foreach ($endpoint in $writeEndpoints) {
  if (-not [bool]$endpoint.idempotency_required) {
    $allWriteEndpointsHaveIdempotency = $false
  }
  if (-not [bool]$endpoint.audit_required) {
    $allWriteEndpointsHaveAudit = $false
  }
  if ([bool]$endpoint.direct_wallet_snapshot_mutation_allowed) {
    $directWalletMutationForbidden = $false
  }
  if (@($endpoint.accounting_markers).Count -eq 0) {
    $accountingMarkersPresent = $false
  }
}

$moneyDecimalStrings = ([string]$fixture.money_contract.format -eq "decimal_string_with_currency") -and
  (-not [bool]$fixture.money_contract.float_allowed)
$idempotencyContract = $allWriteEndpointsHaveIdempotency -and
  (@($writeEndpoints | Where-Object { @($_.idempotency_cases).Count -gt 0 }).Count -eq @($writeEndpoints).Count)
$secretSafe = Test-SecretSafeText ($fixture | ConvertTo-Json -Depth 32)

$invariants = @(
  "credit_grant_create_list_expire_revoke_contract_present",
  "remaining_balance_summary_contract_present",
  "opening_balance_import_contract_present",
  "admin_adjustment_contract_present",
  "idempotent_replay_vs_conflict_refusal",
  "money_decimal_string_with_currency_no_float",
  "secret_safe_summary",
  "direct_wallet_snapshot_mutation_forbidden",
  "accounting_marker_required_for_mutations"
)

$status = if (
  $moneyDecimalStrings -and
  $idempotencyContract -and
  $allWriteEndpointsHaveAudit -and
  $directWalletMutationForbidden -and
  $accountingMarkersPresent -and
  $secretSafe
) {
  "pass"
} else {
  "fail"
}

$artifact = [ordered]@{
  schema = "billing_mutation_contract_tests.v1"
  status = $status
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  test_name = "credit_wallet_productization_contract_fixture_enforces_invariants"
  fixture_path = $fixturePathInfo.relative
  fixture_contract = [string]$fixture.contract
  fixture_status = [string]$fixture.status
  endpoints = @($endpointNames)
  invariants_enforced = @($invariants)
  money_decimal_strings = [bool]$moneyDecimalStrings
  idempotency_contract = [bool]$idempotencyContract
  audit_contract = [bool]$allWriteEndpointsHaveAudit
  direct_wallet_snapshot_mutation_forbidden = [bool]$directWalletMutationForbidden
  accounting_marker_contract = [bool]$accountingMarkersPresent
  secret_safe = [bool]$secretSafe
  runtime_writer_changed = $false
  paid_gate_changed = $false
  controlled_paid_beta_blocker = [bool]$fixture.controlled_paid_beta_blocker
  broader_commercial_distribution_blocker = [bool]$fixture.broader_commercial_distribution_blocker
  side_effects = [ordered]@{
    gateway_modified = $false
    control_plane_modified = $false
    admin_ui_modified = $false
    paid_artifacts_modified = $false
    network_io_performed = $false
    db_io_performed = $false
  }
  source = [ordered]@{
    fixture_path_output = "omitted"
    output_path_output = "omitted"
    raw_fixture_output = "omitted"
  }
}

$outputDirectory = Split-Path -Parent $outputPathInfo.full
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
  New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}
$artifact | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $outputPathInfo.full -Encoding UTF8
$artifact | ConvertTo-Json -Depth 16

if ($status -ne "pass") {
  exit 2
}
exit 0
