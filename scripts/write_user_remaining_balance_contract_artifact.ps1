param(
  [string]$FixturePath = "tests\fixtures\billing\user_remaining_balance_contract.json",
  [string]$OutputPath = ".tmp\credit-wallet\user_remaining_balance_contract.json"
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

function ConvertTo-StringArray {
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

$caseNames = @($fixture.cases | ForEach-Object { [string]$_.name })
$requiredCases = ConvertTo-StringArray $fixture.required_cases
$missingCases = @($requiredCases | Where-Object { $caseNames -notcontains $_ })
$summaryCases = @($fixture.cases | Where-Object { [string]$_.decision -eq "summary_returned" })
$refusalCases = @($fixture.cases | Where-Object { [string]$_.decision -eq "refused" })

$moneyDecimalStrings = ([string]$fixture.money_contract.format -eq "decimal_string_with_currency") -and
  (-not [bool]$fixture.money_contract.float_allowed) -and
  ([int]$fixture.money_contract.scale -eq 8)
$ownershipScopeRequired = [bool]$fixture.ownership_scope_contract.tenant_scope_required -and
  [bool]$fixture.ownership_scope_contract.project_scope_required -and
  [bool]$fixture.ownership_scope_contract.user_scope_or_developer_token_required -and
  [bool]$fixture.ownership_scope_contract.wallet_scope_check_required -and
  [bool]$fixture.ownership_scope_contract.currency_check_required
$formulaPresent = ([string]$fixture.read_model_formula.formula -eq "active_credit_grant_total + pending_confirmed_ledger_window - wallet_balance_floor") -and
  [bool]$fixture.read_model_formula.active_grants_only -and
  (-not [bool]$fixture.read_model_formula.expired_grants_counted) -and
  (-not [bool]$fixture.read_model_formula.revoked_grants_counted) -and
  [bool]$fixture.read_model_formula.pending_ledger_window_included -and
  [bool]$fixture.read_model_formula.confirmed_ledger_window_included -and
  [bool]$fixture.read_model_formula.budget_remaining_included
$readOnlyNoMutations = @($fixture.cases | Where-Object {
    [bool]$_.read_only -and
    (-not [bool]$_.mutations.ledger_entries_written) -and
    (-not [bool]$_.mutations.credit_grants_written) -and
    (-not [bool]$_.mutations.audit_logs_written) -and
    (-not [bool]$_.mutations.wallet_snapshot_mutated)
  }).Count -eq @($fixture.cases).Count
$boundedIds = @($summaryCases | Where-Object {
    @($_.response.bounded_credit_grant_ids).Count -le [int]$fixture.bounded_output_contract.max_credit_grant_ids -and
    @($_.response.bounded_ledger_entry_ids).Count -le [int]$fixture.bounded_output_contract.max_ledger_entry_ids
  }).Count -eq @($summaryCases).Count
$consistencyMarkers = @($summaryCases | Where-Object {
    $marker = [string]$_.response.consistency
    @($fixture.allowed_consistency_markers) -contains $marker
  }).Count -eq @($summaryCases).Count
$refusalsCovered = @($refusalCases | Where-Object {
    [string]$_.refusal_code -in @("currency_mismatch", "wallet_not_found", "ownership_scope_mismatch")
  }).Count -eq 3
$secretSafe = Test-SecretSafeText ($fixture | ConvertTo-Json -Depth 64)

$runtimeImplemented = [bool]$fixture.runtime_implemented
$contractOnly = [bool]$fixture.contract_only
$paidGateChanged = [bool]$fixture.paid_gate_changed

$status = if (
  @($missingCases).Count -eq 0 -and
  $moneyDecimalStrings -and
  $ownershipScopeRequired -and
  $formulaPresent -and
  $readOnlyNoMutations -and
  $boundedIds -and
  $consistencyMarkers -and
  $refusalsCovered -and
  $secretSafe -and
  (-not $runtimeImplemented) -and
  $contractOnly -and
  (-not $paidGateChanged)
) {
  "pass"
} else {
  "fail"
}

$artifact = [ordered]@{
  schema = "user_remaining_balance_contract.v1"
  status = $status
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  test_name = "user_remaining_balance_contract_fixture_enforces_read_model_invariants"
  fixture_path = $fixturePathInfo.relative
  fixture_schema = [string]$fixture.schema
  fixture_status = [string]$fixture.status
  runtime_implemented = $runtimeImplemented
  contract_only = $contractOnly
  control_plane_endpoint_present = [bool]$fixture.control_plane_endpoint_present
  paid_gate_changed = $paidGateChanged
  read_only = [bool]$fixture.read_only
  secret_safe = [bool]$secretSafe
  contract_scope = @(
    "user_or_developer_token_ownership_scope",
    "wallet_scope_check",
    "currency_check",
    "active_credit_grants_plus_pending_confirmed_ledger_minus_wallet_balance_floor",
    "expired_revoked_grants_excluded",
    "budget_remaining_and_staleness_marker",
    "bounded_ledger_and_grant_ids",
    "read_only_no_mutations",
    "fixed_decimal_money_strings",
    "secret_safe_output"
  )
  cases = @($caseNames)
  missing_cases = @($missingCases)
  invariants_enforced = @(
    "available_to_spend_formula_explained",
    "active_grants_only_expired_revoked_excluded",
    "currency_mismatch_refused",
    "missing_wallet_refused",
    "ownership_mismatch_refused",
    "strong_stale_estimated_consistency_markers",
    "bounded_ids_only",
    "read_only_no_ledger_credit_grant_audit_mutations",
    "money_decimal_strings_no_float",
    "secret_safe_summary"
  )
  money_decimal_strings = [bool]$moneyDecimalStrings
  ownership_scope_required = [bool]$ownershipScopeRequired
  wallet_scope_check_required = [bool]$fixture.ownership_scope_contract.wallet_scope_check_required
  currency_check_required = [bool]$fixture.ownership_scope_contract.currency_check_required
  read_model_formula_present = [bool]$formulaPresent
  active_grants_only = [bool]$fixture.read_model_formula.active_grants_only
  expired_grants_counted = [bool]$fixture.read_model_formula.expired_grants_counted
  revoked_grants_counted = [bool]$fixture.read_model_formula.revoked_grants_counted
  pending_confirmed_ledger_window_included = [bool]([bool]$fixture.read_model_formula.pending_ledger_window_included -and [bool]$fixture.read_model_formula.confirmed_ledger_window_included)
  budget_remaining_included = [bool]$fixture.read_model_formula.budget_remaining_included
  bounded_ids = [bool]$boundedIds
  consistency_marker_contract = [bool]$consistencyMarkers
  refusal_contract = [bool]$refusalsCovered
  no_mutations = [bool]$readOnlyNoMutations
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
