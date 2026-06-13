param(
  [string]$FixturePath = "tests\fixtures\billing\credit_grant_crud_contract.json",
  [string]$OutputPath = ".tmp\credit-wallet\credit_grant_crud_contract.json"
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
$writeCases = @($fixture.cases | Where-Object { [bool]$_.write })
$appliedWriteCases = @($writeCases | Where-Object { [string]$_.decision -eq "applied" })
$refusalCases = @($writeCases | Where-Object { [string]$_.decision -eq "refused" })

$moneyDecimalStrings = ([string]$fixture.money_contract.format -eq "decimal_string_with_currency") -and
  (-not [bool]$fixture.money_contract.float_allowed) -and
  ([int]$fixture.money_contract.scale -eq 8)

$idempotencyContract = @($writeCases | Where-Object {
    $request = $_.request
    ([bool]$request.idempotency_key_present) -or ([bool]$_.same_idempotency_key)
  }).Count -eq @($writeCases).Count

$auditContract = @($appliedWriteCases | Where-Object {
    [bool]$_.audit_metadata.actor_id_present -and
    -not [string]::IsNullOrWhiteSpace([string]$_.audit_metadata.actor_type) -and
    -not [string]::IsNullOrWhiteSpace([string]$_.audit_metadata.reason) -and
    [bool]$_.audit_metadata.request_or_operation_id_present
  }).Count -eq @($appliedWriteCases).Count

$directWalletSnapshotMutationForbidden =
  (-not [bool]$fixture.accounting_contract.direct_wallet_snapshot_mutation_allowed) -and
  (@($fixture.cases | Where-Object { [string]$_.attempted_accounting_marker -eq "wallet_snapshot_balance_update" }).Count -eq 1)

$appliedWriteMarkers = @($appliedWriteCases | Where-Object {
    $markers = ConvertTo-StringArray $_.accounting_markers
    (($markers -contains "credit_grant_row") -or ($markers -contains "credit_grant_state_change_row")) -and
    (($markers -contains "ledger_entry") -or ($markers -contains "admin_adjustment_entry")) -and
    ($markers -contains "audit_log")
  }).Count -eq @($appliedWriteCases).Count

$refusalNoWrites = @($refusalCases | Where-Object {
    (-not [bool]$_.ledger_write_allowed) -and (-not [bool]$_.credit_grant_write_allowed)
  }).Count -eq @($refusalCases).Count

$secretSafe = Test-SecretSafeText ($fixture | ConvertTo-Json -Depth 64)

$runtimeImplemented = [bool]$fixture.runtime_implemented
$paidGateChanged = [bool]$fixture.paid_gate_changed

$status = if (
  @($missingCases).Count -eq 0 -and
  $moneyDecimalStrings -and
  $idempotencyContract -and
  $auditContract -and
  $directWalletSnapshotMutationForbidden -and
  $appliedWriteMarkers -and
  $refusalNoWrites -and
  $secretSafe -and
  (-not $runtimeImplemented) -and
  (-not $paidGateChanged)
) {
  "pass"
} else {
  "fail"
}

$artifact = [ordered]@{
  schema = "credit_grant_crud_contract.v1"
  status = $status
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  test_name = "credit_grant_crud_contract_fixture_enforces_accounting_invariants"
  fixture_path = $fixturePathInfo.relative
  fixture_schema = [string]$fixture.schema
  fixture_status = [string]$fixture.status
  runtime_implemented = $runtimeImplemented
  paid_gate_changed = $paidGateChanged
  controlled_paid_beta_blocker = [bool]$fixture.controlled_paid_beta_blocker
  broader_commercial_distribution_blocker = [bool]$fixture.broader_commercial_distribution_blocker
  contract_scope = @(
    "credit_grant_create",
    "credit_grant_list",
    "credit_grant_read",
    "credit_grant_expire",
    "credit_grant_revoke",
    "idempotent_replay",
    "same_key_conflict_refusal",
    "invalid_currency_amount_time_refusal",
    "direct_wallet_snapshot_mutation_forbidden",
    "audit_metadata_required",
    "fixed_decimal_money_strings",
    "secret_safe_output"
  )
  cases = @($caseNames)
  missing_cases = @($missingCases)
  invariants_enforced = @(
    "create_grant_requires_credit_grant_row_and_ledger_or_admin_adjustment_marker",
    "list_and_read_are_read_model_only",
    "expire_and_revoke_require_credit_grant_state_change_and_audit",
    "same_idempotency_key_same_body_replays",
    "same_idempotency_key_different_body_refuses_conflict",
    "invalid_currency_refused_without_writes",
    "non_positive_amount_refused_without_writes",
    "invalid_time_window_refused_without_writes",
    "direct_wallet_snapshot_mutation_forbidden",
    "audit_metadata_required_for_writes",
    "money_decimal_strings_no_float",
    "secret_safe_summary"
  )
  money_decimal_strings = [bool]$moneyDecimalStrings
  idempotency_contract = [bool]$idempotencyContract
  audit_contract = [bool]$auditContract
  audit_required = [bool]$auditContract
  direct_wallet_snapshot_mutation_forbidden = [bool]$directWalletSnapshotMutationForbidden
  accounting_marker_contract = [bool]$appliedWriteMarkers
  refusal_no_ledger_or_credit_grant_writes = [bool]$refusalNoWrites
  secret_safe = [bool]$secretSafe
  runtime_writer_changed = $false
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
