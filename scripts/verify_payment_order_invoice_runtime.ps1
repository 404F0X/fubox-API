param(
  [string]$ContractArtifactPath = ".tmp\credit-wallet\payment_order_invoice_contract.json",
  [string]$OutputPath = ".tmp\credit-wallet\payment_order_invoice_runtime_s2_blocked.json",
  [string]$RuntimeOutputPath = ".tmp\credit-wallet\payment_order_invoice_runtime.json",
  [switch]$RunInternalRuntime,
  [switch]$SkipMigrations,
  [switch]$WriteBlockedArtifact,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$requiredTables = @(
  "payment_orders",
  "payment_intents",
  "payment_captures",
  "payment_refunds",
  "payment_events",
  "invoices",
  "invoice_receipts",
  "payment_reconciliations"
)

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
      '(?i)client_secret\s*[:=]',
      'sk-[A-Za-z0-9]{8,}'
    )) {
    if ($Text -match $pattern) {
      return $false
    }
  }
  return $true
}

function Get-JsonBool {
  param(
    [AllowNull()]$Json,
    [string]$Name,
    [bool]$Default = $false
  )
  if ($null -eq $Json) { return $Default }
  $property = $Json.PSObject.Properties[$Name]
  if ($null -eq $property) { return $Default }
  return [bool]$property.Value
}

function Get-JsonString {
  param(
    [AllowNull()]$Json,
    [string]$Name
  )
  if ($null -eq $Json) { return "" }
  $property = $Json.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return "" }
  return [string]$property.Value
}

function Get-SchemaDiagnostics {
  $schemaSearchRoots = @("db", "examples")
  $schemaText = ""
  foreach ($root in $schemaSearchRoots) {
    $fullRoot = Join-Path $repoRoot $root
    if (-not (Test-Path -LiteralPath $fullRoot)) {
      continue
    }
    $files = Get-ChildItem -LiteralPath $fullRoot -Recurse -File -Include *.sql,*.yaml,*.yml -ErrorAction SilentlyContinue
    foreach ($file in $files) {
      $schemaText += "`n"
      $schemaText += Get-Content -Raw -LiteralPath $file.FullName
    }
  }

  $present = [System.Collections.Generic.List[string]]::new()
  $missing = [System.Collections.Generic.List[string]]::new()
  foreach ($table in $requiredTables) {
    if ($schemaText -match "(?i)\b$([regex]::Escape($table))\b") {
      [void]$present.Add($table)
    } else {
      [void]$missing.Add($table)
    }
  }

  return [ordered]@{
    searched_roots = $schemaSearchRoots
    required_tables = $requiredTables
    present_tables = @($present.ToArray())
    missing_tables = @($missing.ToArray())
    all_required_tables_present = @($missing).Count -eq 0
  }
}

function Test-ContractArtifact {
  param([AllowNull()]$Contract)

  if ($null -eq $Contract) { return $false }
  $status = Get-JsonString -Json $Contract -Name "status"
  return [bool](
    (Get-JsonString -Json $Contract -Name "schema") -eq "payment_order_invoice_contract.v1" -and
    $status -in @("pass", "contract_enforced_not_runtime_wired") -and
    -not (Get-JsonBool -Json $Contract -Name "runtime_implemented" -Default $true) -and
    (Get-JsonBool -Json $Contract -Name "contract_only") -and
    (Get-JsonBool -Json $Contract -Name "secret_safe") -and
    -not (Get-JsonBool -Json $Contract -Name "paid_gate_changed" -Default $true)
  )
}

function Test-RuntimeArtifactPass {
  param([AllowNull()]$Artifact)

  if ($null -eq $Artifact) { return $false }
  $routeOrInternal = (Get-JsonBool -Json $Artifact -Name "route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "internal_runtime_function_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "internal_sqlx_function_invoked")
  return [bool](
    (Get-JsonString -Json $Artifact -Name "schema") -eq "payment_order_invoice_runtime.v1" -and
    (Get-JsonString -Json $Artifact -Name "overall_status") -in @("pass", "passed", "verified") -and
    (Get-JsonBool -Json $Artifact -Name "runtime_implemented") -and
    -not (Get-JsonBool -Json $Artifact -Name "contract_only" -Default $true) -and
    $routeOrInternal -and
    (Get-JsonBool -Json $Artifact -Name "db_integration_ran") -and
    (Get-JsonBool -Json $Artifact -Name "order_lifecycle_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "provider_handoff_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "provider_handoff_redacted_output") -and
    ((Get-JsonBool -Json $Artifact -Name "provider_callback_readback_passed") -or
      (Get-JsonBool -Json $Artifact -Name "payment_callback_readback_passed")) -and
    (Get-JsonBool -Json $Artifact -Name "payment_confirm_capture_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "invoice_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "invoice_receipt_readback_passed") -and
    ((Get-JsonBool -Json $Artifact -Name "ledger_or_credit_readback_passed") -or
      (Get-JsonBool -Json $Artifact -Name "credit_or_ledger_effect_readback_passed")) -and
    (Get-JsonBool -Json $Artifact -Name "idempotency_replay_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "conflict_no_duplicate_write_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "audit_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "reconciliation_readback_passed") -and
    ((Get-JsonBool -Json $Artifact -Name "refund_cancel_chargeback_reversal_readback_passed") -or
      (Get-JsonBool -Json $Artifact -Name "refund_readback_passed")) -and
    (Get-JsonBool -Json $Artifact -Name "money_decimal_strings") -and
    (Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden") -and
    (Get-JsonBool -Json $Artifact -Name "secret_safe") -and
    -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
  )
}

function Invoke-PaymentOrderInvoiceRustRuntimeTest {
  param([string]$ResolvedRuntimeOutputPath)

  $env:PAYMENT_ORDER_INVOICE_RUNTIME_ARTIFACT_PATH = $ResolvedRuntimeOutputPath
  $cargo = Get-Command cargo -ErrorAction SilentlyContinue
  if ($null -eq $cargo) {
    return [ordered]@{ exit_code = 127; output = "cargo_not_found" }
  }
  $output = & cargo test -p ai-control-plane payment_order_invoice_internal_runtime_db_integration -- --ignored --nocapture 2>&1
  return [ordered]@{
    exit_code = $LASTEXITCODE
    output = (($output | Out-String) -replace '(?i)postgres(?:ql)?://[^"\s]+', 'postgres://<redacted>')
  }
}

function Invoke-PostgresMigrationRunner {
  $runnerPath = Join-Path $PSScriptRoot "apply_migrations_postgres.ps1"
  if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
    return [ordered]@{ exit_code = 127; output = "migration_runner_missing" }
  }

  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($null -eq $pwsh) {
    $pwsh = Get-Command powershell -ErrorAction SilentlyContinue
  }
  if ($null -eq $pwsh) {
    return [ordered]@{ exit_code = 127; output = "powershell_not_found" }
  }

  $output = & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $runnerPath 2>&1
  return [ordered]@{
    exit_code = $LASTEXITCODE
    output = (($output | Out-String) -replace '(?i)postgres(?:ql)?://[^"\s]+', 'postgres://<redacted>')
  }
}

function New-BlockedArtifact {
  param(
    [AllowNull()]$Contract,
    [AllowNull()]$ContractPathInfo,
    [AllowNull()]$SchemaDiagnostics,
    [bool]$ContractFound,
    [bool]$ContractAccepted,
    [bool]$ContractSecretSafe
  )

  $blockers = [System.Collections.Generic.List[string]]::new()
  if (-not $ContractFound) {
    [void]$blockers.Add("payment_order_invoice_contract_artifact_missing")
  } elseif (-not $ContractSecretSafe) {
    [void]$blockers.Add("payment_order_invoice_contract_secret_unsafe")
  } elseif (-not $ContractAccepted) {
    [void]$blockers.Add("payment_order_invoice_contract_not_accepted")
  }
  if (-not [bool]$SchemaDiagnostics.all_required_tables_present) {
    [void]$blockers.Add("payment_order_invoice_schema_missing")
  }
  [void]$blockers.Add("payment_order_invoice_runtime_not_invoked")
  [void]$blockers.Add("payment_provider_handoff_runtime_missing")
  [void]$blockers.Add("provider_callback_or_capture_readback_missing")
  [void]$blockers.Add("invoice_receipt_runtime_missing")
  [void]$blockers.Add("refund_cancel_chargeback_reversal_runtime_missing")
  [void]$blockers.Add("payment_order_invoice_reconciliation_readback_missing")

  return [ordered]@{
    schema = "payment_order_invoice_runtime.v1"
    overall_status = "blocked"
    status = "blocked"
    actual_exit_code = 2
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    runtime_implemented = $false
    contract_only = $true
    route_invoked = $false
    internal_runtime_function_invoked = $false
    internal_sqlx_function_invoked = $false
    db_integration_ran = $false
    secret_safe = $true
    paid_gate_changed = $false
    money_decimal_strings = if ($Contract) { Get-JsonBool -Json $Contract -Name "money_decimal_strings" } else { $false }
    direct_wallet_snapshot_mutation_forbidden = if ($Contract) { Get-JsonBool -Json $Contract -Name "direct_wallet_snapshot_mutation_forbidden" } else { $true }
    blockers = @($blockers.ToArray())
    contract_readback = [ordered]@{
      path = if ($ContractPathInfo) { $ContractPathInfo.relative } else { "" }
      found = $ContractFound
      accepted = $ContractAccepted
      secret_safe = $ContractSecretSafe
      schema = if ($Contract) { Get-JsonString -Json $Contract -Name "schema" } else { "" }
      status = if ($Contract) { Get-JsonString -Json $Contract -Name "status" } else { "" }
      runtime_implemented = if ($Contract) { Get-JsonBool -Json $Contract -Name "runtime_implemented" } else { $false }
      contract_only = if ($Contract) { Get-JsonBool -Json $Contract -Name "contract_only" } else { $false }
    }
    acceptance_contract = [ordered]@{
      runtime_artifact_path = ".tmp/credit-wallet/payment_order_invoice_runtime.json"
      pass_requires_runtime_invocation = $true
      pass_requires_order_lifecycle_readback = $true
      pass_requires_provider_handoff_or_bounded_internal_simulation_policy = $true
      pass_requires_provider_callback_or_capture_readback = $true
      pass_requires_invoice_receipt_readback = $true
      pass_requires_ledger_or_credit_effect_readback = $true
      pass_requires_refund_cancel_chargeback_reversal_readback = $true
      pass_requires_idempotency_replay_and_conflict_no_duplicate_write = $true
      pass_requires_audit_and_reconciliation_readback = $true
      contract_artifact_must_not_mark_runtime_verified = $true
    }
    readback_checks = [ordered]@{
      order_lifecycle_readback_passed = $false
      provider_handoff_readback_passed = $false
      provider_handoff_redacted_output = $false
      provider_callback_readback_passed = $false
      payment_confirm_capture_readback_passed = $false
      invoice_readback_passed = $false
      invoice_receipt_readback_passed = $false
      ledger_or_credit_readback_passed = $false
      refund_cancel_chargeback_reversal_readback_passed = $false
      idempotency_replay_readback_passed = $false
      conflict_no_duplicate_write_readback_passed = $false
      audit_readback_passed = $false
      reconciliation_readback_passed = $false
    }
    diagnostics = [ordered]@{
      schema = $SchemaDiagnostics
      runtime_path_available = $false
      provider_policy = "external_provider_not_implemented; bounded_internal_simulation_policy_not_implemented"
      exact_next_runtime_steps = @(
        "add payment/order/invoice tables or confirm existing equivalents",
        "add internal Rust/sqlx transaction or public route invocation",
        "persist order intent, redacted provider handoff, capture/callback, invoice/receipt, ledger-or-credit effect, refund/cancel/chargeback reversal, audit, and reconciliation markers",
        "write .tmp/credit-wallet/payment_order_invoice_runtime.json only after all runtime readbacks pass"
      )
    }
    side_effects = [ordered]@{
      gateway_modified = $false
      admin_ui_modified = $false
      paid_gate_changed = $false
      payment_provider_called = $false
      raw_provider_payload_output = $false
      db_url_output = $false
    }
  }
}

function Invoke-SelfTest {
  $schemaDiagnostics = [ordered]@{
    searched_roots = @("selftest")
    required_tables = $requiredTables
    present_tables = @()
    missing_tables = $requiredTables
    all_required_tables_present = $false
  }
  $contract = [pscustomobject]@{
    schema = "payment_order_invoice_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    secret_safe = $true
    paid_gate_changed = $false
    money_decimal_strings = $true
    direct_wallet_snapshot_mutation_forbidden = $true
  }
  $contractPath = [ordered]@{ full = "selftest"; relative = ".tmp/credit-wallet/payment_order_invoice_contract.json" }
  $blocked = New-BlockedArtifact `
    -Contract $contract `
    -ContractPathInfo $contractPath `
    -SchemaDiagnostics $schemaDiagnostics `
    -ContractFound $true `
    -ContractAccepted (Test-ContractArtifact -Contract $contract) `
    -ContractSecretSafe $true
  $runtimeNotClaimed = -not [bool]$blocked.runtime_implemented -and [bool]$blocked.contract_only
  $hasRuntimeBlocker = @($blocked.blockers) -contains "payment_order_invoice_runtime_not_invoked"
  $hasSchemaBlocker = @($blocked.blockers) -contains "payment_order_invoice_schema_missing"
  $secretSafe = Test-SecretSafeText ($blocked | ConvertTo-Json -Depth 32)

  $unsafeContract = [pscustomobject]@{
    schema = "payment_order_invoice_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    secret_safe = $true
    paid_gate_changed = $false
    raw_marker = "Authorization: Bearer unsafe-test-token"
  }
  $unsafeRejected = -not (Test-SecretSafeText ($unsafeContract | ConvertTo-Json -Depth 8))

  $cases = @(
    [ordered]@{ name = "blocked_artifact_does_not_claim_runtime"; status = if ($runtimeNotClaimed) { "pass" } else { "fail" } },
    [ordered]@{ name = "runtime_missing_machine_blocker_present"; status = if ($hasRuntimeBlocker) { "pass" } else { "fail" } },
    [ordered]@{ name = "schema_missing_machine_blocker_present"; status = if ($hasSchemaBlocker) { "pass" } else { "fail" } },
    [ordered]@{ name = "blocked_artifact_secret_safe"; status = if ($secretSafe) { "pass" } else { "fail" } },
    [ordered]@{ name = "raw_auth_marker_rejected"; status = if ($unsafeRejected) { "pass" } else { "fail" } }
  )
  $passed = @($cases | Where-Object { $_.status -eq "pass" }).Count
  $result = [ordered]@{
    schema = "payment_order_invoice_runtime_verifier_selftest.v1"
    status = if ($passed -eq @($cases).Count) { "pass" } else { "fail" }
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    cases = $cases
    runtime_implemented = $false
    contract_only = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $result | ConvertTo-Json -Depth 12
  if ($result.status -ne "pass") { exit 1 }
  exit 0
}

if ($SelfTest) {
  Invoke-SelfTest
}

$contractPathInfo = Resolve-RepoBoundedPath `
  -Path $ContractArtifactPath `
  -AllowedPrefixes @(".tmp/", "artifacts/")
$outputPathInfo = Resolve-RepoBoundedPath `
  -Path $OutputPath `
  -AllowedPrefixes @(".tmp/", "artifacts/")

$contractFound = Test-Path -LiteralPath $contractPathInfo.full -PathType Leaf
$contract = $null
$contractSecretSafe = $false
$contractAccepted = $false
if ($contractFound) {
  $rawContract = Get-Content -Raw -LiteralPath $contractPathInfo.full
  $contractSecretSafe = Test-SecretSafeText $rawContract
  if ($contractSecretSafe) {
    $contract = $rawContract | ConvertFrom-Json
    $contractAccepted = Test-ContractArtifact -Contract $contract
  }
}

$schemaDiagnostics = Get-SchemaDiagnostics
$artifact = New-BlockedArtifact `
  -Contract $contract `
  -ContractPathInfo $contractPathInfo `
  -SchemaDiagnostics $schemaDiagnostics `
  -ContractFound $contractFound `
  -ContractAccepted $contractAccepted `
  -ContractSecretSafe $contractSecretSafe

$runtimePathInfo = Resolve-RepoBoundedPath `
  -Path $RuntimeOutputPath `
  -AllowedPrefixes @(".tmp/", "artifacts/")
$dbUrlPresent = -not [string]::IsNullOrWhiteSpace($env:CONTROL_PLANE_DATABASE_URL) -or
  -not [string]::IsNullOrWhiteSpace($env:DATABASE_URL)
if ([string]::IsNullOrWhiteSpace($env:DATABASE_URL) -and
    -not [string]::IsNullOrWhiteSpace($env:CONTROL_PLANE_DATABASE_URL)) {
  $env:DATABASE_URL = $env:CONTROL_PLANE_DATABASE_URL
}

$artifact.diagnostics.required_env = @("CONTROL_PLANE_DATABASE_URL or DATABASE_URL")
$artifact.diagnostics.runner_mode = "postgres_migrations_then_internal_runtime_test"
$artifact.diagnostics.docker_required = $false
$artifact.diagnostics.run_internal_runtime_switch_superseded = [bool]$RunInternalRuntime

if (-not $dbUrlPresent) {
  $artifact.blockers = @(@($artifact.blockers) + @("payment_order_invoice_database_url_missing"))
  $artifact.diagnostics.missing_env = @("CONTROL_PLANE_DATABASE_URL_or_DATABASE_URL")
} else {
  $env:PAYMENT_ORDER_INVOICE_DB_OPT_IN = "1"
  if (-not $SkipMigrations) {
    $migrationRun = Invoke-PostgresMigrationRunner
    $artifact.diagnostics.migration_runner_exit_code = [int]$migrationRun.exit_code
    $artifact.diagnostics.migration_runner_output_tail = ($migrationRun.output -split "`r?`n" | Select-Object -Last 80) -join "`n"
    if ([int]$migrationRun.exit_code -ne 0) {
      $artifact.blockers = @(@($artifact.blockers) + @("payment_order_invoice_migration_runner_failed"))
    }
  } else {
    $artifact.diagnostics.migrations_skipped = $true
  }

  if (-not (@($artifact.blockers) -contains "payment_order_invoice_migration_runner_failed")) {
    if (Test-Path -LiteralPath $runtimePathInfo.full -PathType Leaf) {
      Remove-Item -LiteralPath $runtimePathInfo.full -Force
    }
    $runtimeRun = Invoke-PaymentOrderInvoiceRustRuntimeTest -ResolvedRuntimeOutputPath $runtimePathInfo.full
    $artifact.diagnostics.runtime_test_exit_code = [int]$runtimeRun.exit_code
    $artifact.diagnostics.runtime_test_output_tail = ($runtimeRun.output -split "`r?`n" | Select-Object -Last 80) -join "`n"
    if ([int]$runtimeRun.exit_code -eq 0 -and (Test-Path -LiteralPath $runtimePathInfo.full -PathType Leaf)) {
      $rawRuntime = Get-Content -Raw -LiteralPath $runtimePathInfo.full
      $runtimeSecretSafe = Test-SecretSafeText $rawRuntime
      if ($runtimeSecretSafe) {
        $runtimeArtifact = $rawRuntime | ConvertFrom-Json
        if (Test-RuntimeArtifactPass -Artifact $runtimeArtifact) {
          $runtimeArtifact | ConvertTo-Json -Depth 24
          exit 0
        }
      }
      $artifact.blockers = @(@($artifact.blockers) + @("payment_order_invoice_runtime_artifact_not_accepted"))
      $artifact.diagnostics.runtime_artifact_path = $runtimePathInfo.relative
      $artifact.diagnostics.runtime_artifact_secret_safe = [bool]$runtimeSecretSafe
    } else {
      $artifact.blockers = @(@($artifact.blockers) + @("payment_order_invoice_internal_runtime_test_failed"))
      $artifact.diagnostics.runtime_artifact_path = $runtimePathInfo.relative
      $artifact.diagnostics.runtime_artifact_written = Test-Path -LiteralPath $runtimePathInfo.full -PathType Leaf
    }
  }
}

if ($WriteBlockedArtifact) {
  $outputDirectory = Split-Path -Parent $outputPathInfo.full
  if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
  }
  $artifact | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $outputPathInfo.full -Encoding UTF8
}
$artifact | ConvertTo-Json -Depth 24
exit 2
