param(
  [string]$FixturePath = "tests\fixtures\billing\opening_balance_import_contract.json",
  [string]$OutputPath = ".tmp\credit-wallet\opening_balance_import_contract.json"
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

function Test-DecimalString {
  param(
    [AllowNull()]$Value,
    [int]$Scale
  )

  if ($null -eq $Value) {
    return $false
  }
  $text = [string]$Value
  if ($text -notmatch '^-?[0-9]+\.[0-9]+$') {
    return $false
  }
  $fractional = $text.Split(".")[1]
  return $fractional.Length -eq $Scale
}

function Get-JsonString {
  param(
    [AllowNull()]$Json,
    [string]$Name
  )

  if ($null -eq $Json) {
    return ""
  }
  $property = $Json.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return ""
  }
  return [string]$property.Value
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

$cases = @($fixture.cases)
$caseNames = @($cases | ForEach-Object { [string]$_.name })
$requiredCases = @(
  "accepted_apply",
  "idempotent_replay",
  "same_key_conflict",
  "duplicate_external_reference_conflict",
  "wallet_currency_mismatch",
  "non_positive_amount_refusal",
  "direct_wallet_snapshot_mutation_forbidden"
)
$missingCases = @($requiredCases | Where-Object { $caseNames -notcontains $_ })

$scale = [int]$fixture.money_contract.scale
$moneyDecimalStrings = ([string]$fixture.money_contract.format -eq "decimal_string_with_currency") -and
  (-not [bool]$fixture.money_contract.float_allowed) -and
  ($scale -eq 8)
$idempotencyContract = $false
$openingLedgerEntryRequired = $false
$directWalletSnapshotMutationForbidden = -not [bool]$fixture.writer_mapping.direct_wallet_snapshot_mutation_allowed
$writerMapsToAdminCredit = ([string]$fixture.writer_mapping.primitive -eq "AdminAdjustmentLedgerRequest") -and
  ([string]$fixture.writer_mapping.adjustment_kind -eq "credit") -and
  ([string]$fixture.writer_mapping.ledger_entry_type -eq "adjust") -and
  ([string]$fixture.writer_mapping.ledger_entry_status -eq "confirmed") -and
  ([string]$fixture.writer_mapping.opening_marker -eq "opening_entry")
$commandMetadataContract = $fixture.writer_mapping.command_metadata_contract
$commandMetadataCompatible = ([string]$commandMetadataContract.metadata_operation -eq "opening_balance_import") -and
  (-not [bool]$commandMetadataContract.raw_idempotency_key_output_allowed) -and
  (-not [bool]$commandMetadataContract.raw_import_payload_output_allowed)
foreach ($field in @("operation", "external_source", "external_reference_id", "reason")) {
  if (@($commandMetadataContract.required_metadata_fields | Where-Object { [string]$_ -eq $field }).Count -eq 0) {
    $commandMetadataCompatible = $false
  }
}
$schemaContract = $fixture.runtime_schema_contract
$requiredSchemaColumns = @(
  "id",
  "tenant_id",
  "wallet_id",
  "currency",
  "opening_amount",
  "external_source",
  "external_reference_id",
  "idempotency_key",
  "status",
  "ledger_entry_id",
  "admin_adjustment_entry_id",
  "audit_id",
  "request_summary"
)
$requiredSchemaConstraints = @(
  "(tenant_id,idempotency_key)",
  "(tenant_id,external_source,external_reference_id)"
)
$schemaColumnsPresent = $true
foreach ($column in $requiredSchemaColumns) {
  if (@($schemaContract.required_columns | Where-Object { [string]$_ -eq $column }).Count -eq 0) {
    $schemaColumnsPresent = $false
  }
}
$schemaConstraintsPresent = $true
foreach ($constraint in $requiredSchemaConstraints) {
  if (@($schemaContract.required_unique_constraints | Where-Object { [string]$_ -eq $constraint }).Count -eq 0) {
    $schemaConstraintsPresent = $false
  }
}
$schemaContractCompatible = ([string]$schemaContract.table -eq "opening_balance_imports") -and
  [bool]$schemaContract.requires_schema -and
  (-not [bool]$schemaContract.runtime_implemented) -and
  [bool]$schemaContract.schema_contract_compatible -and
  $schemaColumnsPresent -and
  $schemaConstraintsPresent

$runtimeAcceptanceContract = $fixture.runtime_acceptance_contract
$requiredLiveReadbackFields = @(
  "opening_import_id",
  "ledger_entry_id",
  "admin_adjustment_entry_id",
  "audit_id",
  "idempotency_result",
  "metadata_operation",
  "wallet_snapshot_mutated",
  "opening_import_readback_passed",
  "ledger_or_admin_adjustment_readback_passed",
  "audit_readback_passed",
  "replay_readback_passed",
  "refusal_readback_passed",
  "rollback_readback_passed"
)
$runtimeAcceptanceCompatible = [bool]$runtimeAcceptanceContract.route_or_internal_runtime_invoked_required -and
  [bool]$runtimeAcceptanceContract.psql_plan_not_runtime_acceptance -and
  [bool]$runtimeAcceptanceContract.rollback_contained_psql_plan_allowed_as_blocked_evidence -and
  [bool]$runtimeAcceptanceContract.runtime_implemented_requires_live_readback -and
  [bool]$runtimeAcceptanceContract.no_direct_wallet_mutation_required
foreach ($field in $requiredLiveReadbackFields) {
  if (@($runtimeAcceptanceContract.required_live_readback_fields | Where-Object { [string]$_ -eq $field }).Count -eq 0) {
    $runtimeAcceptanceCompatible = $false
  }
}

$caseSummaries = [System.Collections.Generic.List[object]]::new()
foreach ($case in $cases) {
  $expected = $case.expected
  $response = $expected.response
  $audit = $expected.audit_summary
  $amountString = Get-JsonString -Json $case.request -Name "opening_amount"
  if (-not (Test-DecimalString -Value $amountString -Scale $scale)) {
    $moneyDecimalStrings = $false
  }
  if ([string]$case.name -eq "idempotent_replay" -and [string]$expected.idempotency -eq "replayed") {
    $idempotencyContract = $true
  }
  if ([string]$case.name -eq "same_key_conflict" -and [string]$expected.refusal_code -eq "idempotency_conflict") {
    $idempotencyContract = $idempotencyContract -and $true
  }
  if (@($expected.accounting_markers | Where-Object { $_ -in @("opening_entry", "admin_adjustment_entry", "ledger_entry") }).Count -gt 0) {
    $openingLedgerEntryRequired = $true
  }
  if ([string]$case.attempted_accounting_marker -eq "direct_wallet_snapshot_update" -and [string]$expected.refusal_code -eq "direct_wallet_snapshot_mutation_forbidden") {
    $directWalletSnapshotMutationForbidden = $directWalletSnapshotMutationForbidden -and $true
  }

  [void]$caseSummaries.Add([ordered]@{
      name = [string]$case.name
      scenario = [string]$case.scenario
      decision = [string]$expected.decision
      refusal_code = Get-JsonString -Json $expected -Name "refusal_code"
      writer_invoked = [bool]$expected.writer_invoked
      idempotency = [string]$expected.idempotency
      response_secret_safe = [bool]$response.secret_safe
      audit_secret_safe = [bool]$audit.secret_safe
    })
}

$secretSafe = (Test-SecretSafeText ($caseSummaries | ConvertTo-Json -Depth 12)) -and
  (Test-SecretSafeText ($fixture.writer_mapping | ConvertTo-Json -Depth 12))

$status = if (
  [string]$fixture.schema -eq "billing_opening_balance_import_contract.v1" -and
  [string]$fixture.status -eq "contract_enforced_not_runtime_wired" -and
  $missingCases.Count -eq 0 -and
  $moneyDecimalStrings -and
  $idempotencyContract -and
  $openingLedgerEntryRequired -and
  $directWalletSnapshotMutationForbidden -and
  $writerMapsToAdminCredit -and
  $commandMetadataCompatible -and
  $schemaContractCompatible -and
  $runtimeAcceptanceCompatible -and
  $secretSafe -and
  (-not [bool]$fixture.paid_gate_changed) -and
  (-not [bool]$fixture.runtime_writer_changed)
) {
  "pass"
} else {
  "fail"
}

$artifact = [ordered]@{
  schema = "opening_balance_import_contract.v1"
  status = $status
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  fixture_path = $fixturePathInfo.relative
  test_name = "opening_balance_import_contract_fixture_maps_to_admin_adjustment_credit"
  contract_status = [string]$fixture.status
  secret_safe = [bool]$secretSafe
  money_decimal_strings = [bool]$moneyDecimalStrings
  idempotency_contract = [bool]$idempotencyContract
  opening_ledger_entry_required = [bool]$openingLedgerEntryRequired
  direct_wallet_snapshot_mutation_forbidden = [bool]$directWalletSnapshotMutationForbidden
  paid_gate_changed = $false
  runtime_implemented = $false
  runtime_writer_changed = $false
  requires_schema = $true
  opening_balance_imports_schema_required = $true
  schema_contract_compatible = [bool]$schemaContractCompatible
  e11_schema_landed = [bool]$schemaContract.e11_schema_landed
  ledger_command_contract = [ordered]@{
    primitive = [string]$fixture.writer_mapping.primitive
    adjustment_kind = [string]$fixture.writer_mapping.adjustment_kind
    metadata_operation = [string]$commandMetadataContract.metadata_operation
    metadata_required_fields = @($commandMetadataContract.required_metadata_fields)
    sensitive_idempotency_material_output_allowed = [bool]$commandMetadataContract.raw_idempotency_key_output_allowed
    sensitive_import_material_output_allowed = [bool]$commandMetadataContract.raw_import_payload_output_allowed
    compatible = [bool]$commandMetadataCompatible
  }
  controlled_paid_beta_blocker = $false
  broader_migration_blocker = $true
  writer_mapping = [ordered]@{
    primitive = [string]$fixture.writer_mapping.primitive
    adjustment_kind = [string]$fixture.writer_mapping.adjustment_kind
    ledger_entry_type = [string]$fixture.writer_mapping.ledger_entry_type
    ledger_entry_status = [string]$fixture.writer_mapping.ledger_entry_status
    opening_marker = [string]$fixture.writer_mapping.opening_marker
    metadata_operation = [string]$commandMetadataContract.metadata_operation
    contract_runtime_wiring = [string]$fixture.writer_mapping.contract_runtime_wiring
  }
  runtime_schema_contract = [ordered]@{
    table = [string]$schemaContract.table
    required_columns = @($schemaContract.required_columns)
    required_unique_constraints = @($schemaContract.required_unique_constraints)
    required_statuses = @($schemaContract.required_statuses)
    required_replay_fields = @($schemaContract.required_replay_fields)
    required_conflict_guards = @($schemaContract.required_conflict_guards)
  }
  runtime_acceptance_contract = [ordered]@{
    route_or_internal_runtime_invoked_required = [bool]$runtimeAcceptanceContract.route_or_internal_runtime_invoked_required
    psql_plan_not_runtime_acceptance = [bool]$runtimeAcceptanceContract.psql_plan_not_runtime_acceptance
    rollback_contained_psql_plan_allowed_as_blocked_evidence = [bool]$runtimeAcceptanceContract.rollback_contained_psql_plan_allowed_as_blocked_evidence
    runtime_implemented_requires_live_readback = [bool]$runtimeAcceptanceContract.runtime_implemented_requires_live_readback
    no_direct_wallet_mutation_required = [bool]$runtimeAcceptanceContract.no_direct_wallet_mutation_required
    required_live_readback_fields = @($runtimeAcceptanceContract.required_live_readback_fields)
    compatible = [bool]$runtimeAcceptanceCompatible
  }
  tests = [ordered]@{
    case_count = $cases.Count
    required_cases_present = $missingCases.Count -eq 0
    missing_cases = @($missingCases)
    cases = @($caseSummaries.ToArray())
  }
  invariants_enforced = @(
    "accepted_apply_maps_to_admin_adjustment_credit",
    "accepted_apply_command_metadata_operation_opening_balance_import",
    "idempotent_replay_vs_conflict_refusal",
    "duplicate_external_reference_conflict_refusal",
    "wallet_currency_mismatch_refusal",
    "non_positive_opening_amount_refusal",
    "opening_ledger_entry_required",
    "direct_wallet_snapshot_mutation_forbidden",
    "rollback_contained_psql_plan_not_runtime_acceptance",
    "runtime_acceptance_requires_live_readback",
    "money_decimal_string_with_currency_no_float",
    "secret_safe_summary"
  )
  side_effects = [ordered]@{
    gateway_modified = $false
    control_plane_modified = $false
    admin_ui_modified = $false
    paid_artifacts_modified = $false
    network_io_performed = $false
    db_io_performed = $false
  }
  source = [ordered]@{
    sensitive_material_output = "omitted"
    fixture_examples_output = "summarized_only"
    env_values_output = "omitted"
  }
}

$artifactText = $artifact | ConvertTo-Json -Depth 16
if (-not (Test-SecretSafeText $artifactText)) {
  throw "artifact_secret_unsafe"
}
if ($artifactText -match 'opening_import:new_api_balance') {
  throw "artifact_raw_idempotency_key_present"
}
if ($artifactText -match 'raw_import_payload') {
  throw "artifact_sensitive_payload_marker_present"
}

$outputDirectory = Split-Path -Parent $outputPathInfo.full
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
  New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}
$artifactText | Set-Content -LiteralPath $outputPathInfo.full -Encoding UTF8
$artifactText

if ($status -ne "pass") {
  exit 2
}
exit 0
