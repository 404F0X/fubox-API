param(
  [string[]]$SchemaPaths = @("db\migrations\0001_init.sql", "db\migrations\0002_upgrade_dev_skeleton.sql", "db\migrations\0011_opening_balance_imports.sql"),
  [string]$GatewaySourcePath = "apps\gateway\src\db.rs",
  [string]$ControlPlaneAdminPath = "apps\control-plane\src\admin.rs",
  [string]$GatewaySmokeScriptPath = "scripts\verify_gateway_paid_hot_path_smoke.ps1",
  [string]$CreditWalletContractPath = "docs\todo\slices\TODO-32-CREDIT-WALLET.md",
  [string]$AdminOpenApiPath = "examples\openapi_admin_skeleton.yaml",
  [string[]]$AdminReadonlyRuntimeArtifactPaths = @(".tmp\credit-wallet\admin_readonly_wallet_credit_runtime.json", "artifacts\credit_wallet_admin_readonly_runtime.json"),
  [string[]]$BillingMutationArtifactPaths = @(".tmp\credit-wallet\billing_mutation_contract_tests.json", "artifacts\credit_wallet_billing_mutation_contract_tests.json"),
  [string[]]$OpeningBalanceImportArtifactPaths = @(".tmp\credit-wallet\opening_balance_import_runtime.json", "artifacts\credit_wallet_opening_balance_import_runtime.json", ".tmp\credit-wallet\opening_balance_import_contract.json", "artifacts\credit_wallet_opening_balance_import.json"),
  [string[]]$CreditGrantCrudArtifactPaths = @(".tmp\credit-wallet\credit_grant_crud_runtime.json", "artifacts\credit_wallet_credit_grant_crud_runtime.json", ".tmp\credit-wallet\credit_grant_crud_contract.json", "artifacts\credit_wallet_credit_grant_crud_contract.json"),
  [string[]]$UserRemainingBalanceArtifactPaths = @(".tmp\credit-wallet\user_remaining_balance_runtime.json", "artifacts\credit_wallet_user_remaining_balance_runtime.json", ".tmp\credit-wallet\user_remaining_balance_contract.json", "artifacts\credit_wallet_user_remaining_balance_contract.json", ".tmp\credit-wallet\user_remaining_balance_api.json", "artifacts\credit_wallet_user_remaining_balance_api.json"),
  [string[]]$UserRemainingBalanceFullRuntimeArtifactPaths = @(".tmp\credit-wallet\user_remaining_balance_ownership_runtime.json", "artifacts\credit_wallet_user_remaining_balance_ownership_runtime.json", ".tmp\credit-wallet\user_remaining_balance_user_runtime.json", "artifacts\credit_wallet_user_remaining_balance_user_runtime.json"),
  [string[]]$RechargeVoucherArtifactPaths = @(".tmp\credit-wallet\recharge_voucher_runtime.json", "artifacts\credit_wallet_recharge_voucher_runtime.json", ".tmp\credit-wallet\recharge_voucher_contract.json", "artifacts\credit_wallet_recharge_voucher_contract.json", ".tmp\credit-wallet\recharge_voucher.json", "artifacts\credit_wallet_recharge_voucher.json"),
  [string[]]$PaymentOrderInvoiceArtifactPaths = @(".tmp\credit-wallet\payment_order_invoice_runtime.json", "artifacts\credit_wallet_payment_order_invoice_runtime.json", ".tmp\credit-wallet\payment_order_invoice_contract.json", "artifacts\credit_wallet_payment_order_invoice_contract.json", ".tmp\credit-wallet\payment_order_invoice.json", "artifacts\credit_wallet_payment_order_invoice.json"),
  [string[]]$SubscriptionPackageLifecycleArtifactPaths = @(".tmp\credit-wallet\subscription_package_lifecycle_runtime.json", "artifacts\credit_wallet_subscription_package_lifecycle_runtime.json", ".tmp\credit-wallet\subscription_package_lifecycle_contract.json", "artifacts\credit_wallet_subscription_package_lifecycle_contract.json", ".tmp\credit-wallet\subscription_package_lifecycle.json", "artifacts\credit_wallet_subscription_package_lifecycle.json"),
  [string]$GatewayPaidHotPathArtifactPath = ".tmp\paid-beta\e8_gateway_paid_hot_path.json",
  [string]$ControlPlanePaidReadbackArtifactPath = ".tmp\paid-beta\e11_control_plane_paid_readback_reconciliation.json",
  [string]$RealPaidEvidenceBundlePath = ".tmp\paid-beta\real_paid_evidence_bundle.json",
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = [System.IO.Path]::GetFullPath($Path)
  $prefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($full.Substring($prefix.Length) -replace "\\", "/")
  }
  return ($full -replace "\\", "/")
}

function Read-RepoText {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = Resolve-RepoPath $Path
  if (-not (Test-Path $full)) {
    return [ordered]@{
      path = (Get-RepoRelativePath $full)
      exists = $false
      text = ""
    }
  }
  return [ordered]@{
    path = (Get-RepoRelativePath $full)
    exists = $true
    text = (Get-Content -Raw -Path $full)
  }
}

function Read-RepoJson {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = Resolve-RepoPath $Path
  if (-not (Test-Path $full)) {
    return [ordered]@{
      path = (Get-RepoRelativePath $full)
      exists = $false
      json = $null
    }
  }
  try {
    return [ordered]@{
      path = (Get-RepoRelativePath $full)
      exists = $true
      json = ((Get-Content -Raw -Path $full) | ConvertFrom-Json)
    }
  } catch {
    return [ordered]@{
      path = (Get-RepoRelativePath $full)
      exists = $true
      json = $null
      parse_error = "json_parse_failed"
    }
  }
}

function Test-TextPatterns {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][hashtable]$Patterns
  )

  $checks = [ordered]@{}
  foreach ($name in $Patterns.Keys) {
    $checks[$name] = [bool]([regex]::IsMatch($Text, $Patterns[$name], [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline))
  }
  return $checks
}

function Get-JsonArrayCount {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Json) { return 0 }
  if ($Json.PSObject.Properties.Name -notcontains $Name) { return 0 }
  $value = $Json.PSObject.Properties[$Name].Value
  if ($null -eq $value) { return 0 }
  return @($value).Count
}

function Get-JsonString {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Json) { return "" }
  if ($Json.PSObject.Properties.Name -notcontains $Name) { return "" }
  $value = $Json.PSObject.Properties[$Name].Value
  if ($null -eq $value) { return "" }
  return [string]$value
}

function Get-JsonBool {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name,
    [bool]$Default = $false
  )

  if ($null -eq $Json) { return $Default }
  if ($Json.PSObject.Properties.Name -notcontains $Name) { return $Default }
  $value = $Json.PSObject.Properties[$Name].Value
  if ($value -is [bool]) { return [bool]$value }
  if ($null -eq $value) { return $Default }
  $text = ([string]$value).Trim().ToLowerInvariant()
  if ($text -in @("true", "1", "yes")) { return $true }
  if ($text -in @("false", "0", "no")) { return $false }
  return $Default
}

function Get-NestedJsonBool {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string[]]$Path,
    [bool]$Default = $false
  )

  $current = $Json
  foreach ($name in $Path) {
    if ($null -eq $current) { return $Default }
    if ($current.PSObject.Properties.Name -notcontains $name) { return $Default }
    $current = $current.PSObject.Properties[$name].Value
  }
  if ($current -is [bool]) { return [bool]$current }
  if ($null -eq $current) { return $Default }
  $text = ([string]$current).Trim().ToLowerInvariant()
  if ($text -in @("true", "1", "yes")) { return $true }
  if ($text -in @("false", "0", "no")) { return $false }
  return $Default
}

function Get-JsonStringArray {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Json) { return @() }
  if ($Json.PSObject.Properties.Name -notcontains $Name) { return @() }
  $value = $Json.PSObject.Properties[$Name].Value
  if ($null -eq $value) { return @() }
  return @($value | ForEach-Object { [string]$_ })
}

function Test-DecimalString {
  param([AllowNull()][string]$Value)

  return [bool]($null -ne $Value -and $Value -match '^-?\d+(\.\d+)?$')
}

function Test-SchemaSurface {
  param([Parameter(Mandatory = $true)][string]$SchemaText)

  $patterns = @{
    wallets_table = "create\s+table\s+if\s+not\s+exists\s+wallets\b"
    credit_grants_table = "create\s+table\s+if\s+not\s+exists\s+credit_grants\b"
    ledger_entries_table = "create\s+table\s+if\s+not\s+exists\s+ledger_entries\b"
    balance_floor = "\bbalance_floor\b"
    remaining_amount = "\bremaining_amount\b"
    valid_from = "\bvalid_from\b"
    valid_until = "\bvalid_until\b"
    status = "\bstatus\b"
    source = "\bsource\b"
  }
  return Test-TextPatterns -Text $SchemaText -Patterns $patterns
}

function Test-OpeningBalanceImportSchemaSurface {
  param([Parameter(Mandatory = $true)][string]$SchemaText)

  $patterns = @{
    table_opening_balance_imports = "create\s+table\s+if\s+not\s+exists\s+opening_balance_imports\b"
    column_tenant_id = "\btenant_id\b"
    column_wallet_id = "\bwallet_id\b"
    column_currency = "\bcurrency\b"
    column_opening_amount = "\bopening_amount\b"
    column_external_source = "\bexternal_source\b"
    column_external_reference_id = "\bexternal_reference_id\b"
    column_idempotency_key = "\bidempotency_key\b"
    column_status = "\bstatus\b"
    column_ledger_entry_id = "\bledger_entry_id\b"
    column_audit_id = "\baudit_id\b"
    column_created_at = "\bcreated_at\b"
    column_updated_at = "\bupdated_at\b"
    unique_tenant_idempotency = "(unique\s*\([^\)]*tenant_id[^\)]*idempotency_key[^\)]*\)|create\s+unique\s+index[\s\S]*on\s+opening_balance_imports\s*\([^\)]*tenant_id[^\)]*idempotency_key[^\)]*\))"
    unique_tenant_external_reference = "(unique\s*\([^\)]*tenant_id[^\)]*external_source[^\)]*external_reference_id[^\)]*\)|create\s+unique\s+index[\s\S]*on\s+opening_balance_imports\s*\([^\)]*tenant_id[^\)]*external_source[^\)]*external_reference_id[^\)]*\))"
  }
  return Test-TextPatterns -Text $SchemaText -Patterns $patterns
}

function Test-CreditWalletContractSurface {
  param([Parameter(Mandatory = $true)][string]$ContractText)

  $patterns = @{
    endpoint_create_credit_grant = "##\s+POST\s+/billing/credit-grants\b"
    endpoint_list_credit_grants = "##\s+GET\s+/billing/credit-grants\b"
    endpoint_expire_credit_grant = "##\s+POST\s+/billing/credit-grants/\{credit_grant_id\}/expire\b"
    endpoint_revoke_credit_grant = "##\s+POST\s+/billing/credit-grants/\{credit_grant_id\}/revoke\b"
    endpoint_remaining_balance = "##\s+GET\s+/billing/wallets/\{wallet_id\}/remaining-balance\b"
    endpoint_opening_balance_import = "##\s+POST\s+/billing/opening-balance-imports\b"
    endpoint_admin_adjustments = "##\s+POST\s+/billing/admin-adjustments\b"
    money_decimal_strings_required = "Money values MUST be decimal strings"
    write_idempotency_required = "Every write endpoint MUST require an idempotency key"
    audit_metadata_required = "Every write endpoint MUST emit audit metadata"
    secret_safe_required = "secret-safe output|secret_safe"
    direct_wallet_snapshot_mutation_forbidden = "MUST NOT directly mutate wallet snapshot"
    remaining_balance_formula_fields = "wallet_available_balance.*active_credit_grant_total.*pending_reserve_total.*confirmed_ledger_effect.*available_to_spend"
    opening_import_ledger_entry_required = "Opening balance import MUST write an opening ledger entry or admin adjustment entry"
  }
  return Test-TextPatterns -Text $ContractText -Patterns $patterns
}

function Test-AdminReadonlyOpenApiSurface {
  param([Parameter(Mandatory = $true)][string]$OpenApiText)

  $patterns = @{
    path_list_admin_wallets = "(?m)^\s*/admin/wallets:\s*$"
    path_get_admin_wallet = "(?m)^\s*/admin/wallets/\{wallet_id\}:\s*$"
    operation_list_admin_wallets = "\boperationId:\s*listAdminWallets\b"
    operation_get_admin_wallet = "\boperationId:\s*getAdminWallet\b"
    list_envelope_schema = "\bAdminWalletCreditSurfaceListEnvelope\b"
    detail_envelope_schema = "\bAdminWalletCreditSurfaceEnvelope\b"
    surface_schema = "\bAdminWalletCreditSurface\b"
    wallet_summary_schema = "\bAdminWalletSummary\b"
    credit_grants_summary = "\bcredit_grants\b.*\bAdminWalletCreditGrantSummary\b"
    ledger_balance_window = "\bledger_balance_window\b.*\bAdminWalletLedgerBalanceWindow\b"
    pending_reserves = "\bpending_reserves\b.*\bAdminWalletPendingReserveSummary\b"
    budget_remaining = "\bbudget_remaining\b.*\bAdminWalletBudgetRemainingMarker\b"
    consistency_marker = "\bAdminWalletConsistencyMarker\b"
    secret_safe_marker = "\bAdminWalletSecretSafeMarker\b"
    read_only_marker = "\bread_only\b"
    money_decimal_strings = "fixed-decimal strings|decimal string"
    secret_omission_contract = "Authorization/Cookie|provider keys|virtual keys|DB URLs|credential material"
    contract_only_marker = "contract-only until the Control Plane implementation lands"
  }
  return Test-TextPatterns -Text $OpenApiText -Patterns $patterns
}

function Test-OpeningBalanceImportApiSurface {
  param([Parameter(Mandatory = $true)][string]$OpenApiText)

  $patterns = @{
    path_opening_balance_import = "(?m)^\s*/billing/opening-balance-imports:\s*$"
    operation_create_opening_balance_import = "\boperationId:\s*createOpeningBalanceImport\b"
    request_schema = "\bOpeningBalanceImportRequest\b"
    result_schema = "\bOpeningBalanceImportResult\b"
    envelope_schema = "\bOpeningBalanceImportEnvelope\b"
    contract_only_envelope_schema = "\bOpeningBalanceImportContractOnlyEnvelope\b"
    artifact_schema_marker = "opening_balance_import_contract\.v1"
    idempotency_required = "idempotency key|idempotency_key"
    opening_ledger_entry_required = "opening ledger entry|admin adjustment entry"
    direct_wallet_snapshot_mutation_forbidden = "must not directly mutate wallet snapshot balance"
    secret_omission_contract = "Raw import payloads|bearer/session material|DB URLs|provider keys|virtual keys|raw idempotency material"
    contract_only_runtime_marker = "contract-only|returns 501"
  }
  return Test-TextPatterns -Text $OpenApiText -Patterns $patterns
}

function Get-FirstExistingJson {
  param([Parameter(Mandatory = $true)][string[]]$Paths)

  $reads = @()
  foreach ($path in $Paths) {
    $read = Read-RepoJson -Path $path
    $reads += [ordered]@{
      path = $read.path
      exists = $read.exists
      parse_error = if ($read.Keys -contains "parse_error") { $read.parse_error } else { $null }
    }
    if ($read.exists -and $null -ne $read.json) {
      return [ordered]@{
        found = $true
        selected = $read
        searched_paths = $reads
      }
    }
  }

  return [ordered]@{
    found = $false
    selected = $null
    searched_paths = $reads
  }
}

function Test-AdminReadonlyRuntimeArtifact {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) { return $false }
  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $secretSafe = $false
  if ($Artifact.PSObject.Properties.Name -contains "secret_safe") { $secretSafe = [bool]$Artifact.secret_safe }
  $readOnly = $false
  if ($Artifact.PSObject.Properties.Name -contains "read_only") { $readOnly = [bool]$Artifact.read_only }
  $adminReadonly = $false
  if ($Artifact.PSObject.Properties.Name -contains "admin_readonly_runtime_verified") { $adminReadonly = [bool]$Artifact.admin_readonly_runtime_verified }

  return [bool](($status -in @("pass", "passed", "verified")) -and $secretSafe -and ($readOnly -or $adminReadonly))
}

function Test-BillingMutationArtifact {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) { return $false }
  $schema = Get-JsonString -Json $Artifact -Name "schema"
  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $invariants = Get-JsonStringArray -Json $Artifact -Name "invariants_enforced"
  $hasAccounting = @($invariants | Where-Object { $_ -match "accounting|ledger|admin_adjustment|opening" }).Count -gt 0
  $hasIdempotency = @($invariants | Where-Object { $_ -match "idempotent|idempotency" }).Count -gt 0
  $hasSecret = @($invariants | Where-Object { $_ -match "secret" }).Count -gt 0
  $hasDirectWalletForbid = @($invariants | Where-Object { $_ -match "direct_wallet_snapshot_mutation_forbidden|direct-wallet|wallet_snapshot" }).Count -gt 0

  return [bool](
    $schema -eq "billing_mutation_contract_tests.v1" -and
    $status -in @("pass", "passed", "verified") -and
    (Get-JsonBool -Json $Artifact -Name "money_decimal_strings") -and
    (Get-JsonBool -Json $Artifact -Name "idempotency_contract") -and
    (Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden") -and
    (Get-JsonBool -Json $Artifact -Name "secret_safe") -and
    -not (Get-JsonBool -Json $Artifact -Name "runtime_writer_changed" -Default $true) -and
    -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true) -and
    $hasAccounting -and
    $hasIdempotency -and
    $hasSecret -and
    $hasDirectWalletForbid
  )
}

function Test-OpeningBalanceImportArtifact {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) { return $false }
  $schema = Get-JsonString -Json $Artifact -Name "schema"
  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }

  return [bool](
    $schema -in @("opening_balance_import_contract.v1", "opening_balance_import_runtime.v1") -and
    $status -in @("pass", "passed", "verified") -and
    (Get-JsonBool -Json $Artifact -Name "secret_safe") -and
    (Get-JsonBool -Json $Artifact -Name "money_decimal_strings") -and
    (Get-JsonBool -Json $Artifact -Name "idempotency_contract") -and
    (Get-JsonBool -Json $Artifact -Name "opening_ledger_entry_required") -and
    (Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden") -and
    -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
  )
}

function Get-OpeningBalanceImportRuntimeChecks {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) {
    return [ordered]@{
      runtime_implemented = $false
      route_or_internal_rust_path_invoked = $false
      db_runner_implemented = $false
      contract_only_false = $false
      endpoint_present = $false
      opening_import_id_present = $false
      ledger_or_admin_adjustment_id_present = $false
      audit_id_present = $false
      live_db_readback_passed = $false
      opening_import_readback_passed = $false
      ledger_or_admin_adjustment_readback_passed = $false
      audit_readback_passed = $false
      replay_readback_passed = $false
      refusal_readback_passed = $false
      rollback_readback_passed = $false
    }
  }

  $ledgerEntryId = Get-JsonString -Json $Artifact -Name "ledger_entry_id"
  $adminAdjustmentEntryId = Get-JsonString -Json $Artifact -Name "admin_adjustment_entry_id"
  $ledgerReadbackPassed = (Get-JsonBool -Json $Artifact -Name "ledger_entry_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "admin_adjustment_entry_readback_passed")
  $routeOrRustPathInvoked = (Get-JsonBool -Json $Artifact -Name "route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "public_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "internal_rust_function_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "internal_sqlx_function_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "rust_internal_transaction_invoked")

  return [ordered]@{
    runtime_implemented = Get-JsonBool -Json $Artifact -Name "runtime_implemented"
    route_or_internal_rust_path_invoked = $routeOrRustPathInvoked
    db_runner_implemented = Get-JsonBool -Json $Artifact -Name "db_runner_implemented"
    contract_only_false = -not (Get-JsonBool -Json $Artifact -Name "contract_only" -Default $true)
    endpoint_present = (Get-JsonString -Json $Artifact -Name "endpoint") -eq "/billing/opening-balance-imports"
    opening_import_id_present = (Get-JsonString -Json $Artifact -Name "opening_import_id") -ne ""
    ledger_or_admin_adjustment_id_present = ($ledgerEntryId -ne "") -or ($adminAdjustmentEntryId -ne "")
    audit_id_present = (Get-JsonString -Json $Artifact -Name "audit_id") -ne ""
    live_db_readback_passed = Get-JsonBool -Json $Artifact -Name "live_db_readback_passed"
    opening_import_readback_passed = Get-JsonBool -Json $Artifact -Name "opening_import_readback_passed"
    ledger_or_admin_adjustment_readback_passed = $ledgerReadbackPassed
    audit_readback_passed = Get-JsonBool -Json $Artifact -Name "audit_readback_passed"
    replay_readback_passed = Get-JsonBool -Json $Artifact -Name "replay_readback_passed"
    refusal_readback_passed = Get-JsonBool -Json $Artifact -Name "refusal_readback_passed"
    rollback_readback_passed = Get-JsonBool -Json $Artifact -Name "rollback_readback_passed"
  }
}

function Test-OpeningBalanceImportRuntimeArtifact {
  param([AllowNull()][object]$Artifact)

  if (-not (Test-OpeningBalanceImportArtifact -Artifact $Artifact)) { return $false }
  $runtimeChecks = Get-OpeningBalanceImportRuntimeChecks -Artifact $Artifact
  return [bool](-not (@($runtimeChecks.GetEnumerator() | Where-Object { $_.Key -ne "db_runner_implemented" -and -not $_.Value }).Count -gt 0))
}

function Test-CreditGrantCrudArtifact {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) { return $false }
  $schema = Get-JsonString -Json $Artifact -Name "schema"
  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }

  return [bool](
    $schema -in @("credit_grant_crud_contract.v1", "credit_grant_crud_runtime.v1") -and
    $status -in @("pass", "passed", "verified") -and
    (Get-JsonBool -Json $Artifact -Name "money_decimal_strings") -and
    (Get-JsonBool -Json $Artifact -Name "idempotency_contract") -and
    (Get-JsonBool -Json $Artifact -Name "audit_required") -and
    (Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden") -and
    (Get-JsonBool -Json $Artifact -Name "secret_safe") -and
    -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
  )
}

function Get-CreditGrantCrudRuntimeChecks {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) {
    return [ordered]@{
      runtime_implemented = $false
      route_or_internal_rust_path_invoked = $false
      contract_only_false = $false
      endpoint_present = $false
      grant_id_present = $false
      audit_id_present = $false
      create_readback_passed = $false
      list_readback_passed = $false
      read_readback_passed = $false
      expire_or_revoke_readback_passed = $false
      status_readback_passed = $false
      replay_readback_passed = $false
      conflict_or_refusal_no_write_passed = $false
      audit_readback_passed = $false
    }
  }

  $routeOrRustPathInvoked = (Get-JsonBool -Json $Artifact -Name "route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "public_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "internal_rust_function_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "internal_sqlx_function_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "rust_internal_transaction_invoked")
  $endpoint = Get-JsonString -Json $Artifact -Name "endpoint"
  $endpointPresent = ($endpoint -eq "/billing/credit-grants") -or ($endpoint -eq "/admin/credit-grants") -or (Get-JsonBool -Json $Artifact -Name "credit_grant_crud_endpoints_present")
  $grantId = Get-JsonString -Json $Artifact -Name "credit_grant_id"
  if ($grantId -eq "") { $grantId = Get-JsonString -Json $Artifact -Name "grant_id" }

  return [ordered]@{
    runtime_implemented = Get-JsonBool -Json $Artifact -Name "runtime_implemented"
    route_or_internal_rust_path_invoked = $routeOrRustPathInvoked
    contract_only_false = -not (Get-JsonBool -Json $Artifact -Name "contract_only" -Default $true)
    endpoint_present = $endpointPresent
    grant_id_present = $grantId -ne ""
    audit_id_present = (Get-JsonString -Json $Artifact -Name "audit_id") -ne ""
    create_readback_passed = Get-JsonBool -Json $Artifact -Name "create_readback_passed"
    list_readback_passed = Get-JsonBool -Json $Artifact -Name "list_readback_passed"
    read_readback_passed = (Get-JsonBool -Json $Artifact -Name "read_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "detail_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "get_readback_passed")
    expire_or_revoke_readback_passed = (Get-JsonBool -Json $Artifact -Name "expire_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "revoke_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "lifecycle_readback_passed")
    status_readback_passed = Get-JsonBool -Json $Artifact -Name "status_readback_passed"
    replay_readback_passed = Get-JsonBool -Json $Artifact -Name "replay_readback_passed"
    conflict_or_refusal_no_write_passed = (Get-JsonBool -Json $Artifact -Name "conflict_or_refusal_no_write_passed") -or (Get-JsonBool -Json $Artifact -Name "refusal_no_write_passed") -or (Get-JsonBool -Json $Artifact -Name "refusal_readback_passed")
    audit_readback_passed = Get-JsonBool -Json $Artifact -Name "audit_readback_passed"
  }
}

function Test-CreditGrantCrudRuntimeArtifact {
  param([AllowNull()][object]$Artifact)

  if (-not (Test-CreditGrantCrudArtifact -Artifact $Artifact)) { return $false }
  $runtimeChecks = Get-CreditGrantCrudRuntimeChecks -Artifact $Artifact
  return [bool](-not (@($runtimeChecks.GetEnumerator() | Where-Object { -not $_.Value }).Count -gt 0))
}

function Test-UserRemainingBalanceArtifact {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) { return $false }
  $schema = Get-JsonString -Json $Artifact -Name "schema"
  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }

  return [bool](
    $schema -in @("user_remaining_balance_contract.v1", "user_remaining_balance_api.v1") -and
    $status -in @("pass", "passed", "verified") -and
    (Get-JsonBool -Json $Artifact -Name "money_decimal_strings") -and
    (Get-JsonBool -Json $Artifact -Name "read_only") -and
    (Get-JsonBool -Json $Artifact -Name "secret_safe") -and
    -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true) -and
    -not (Get-JsonBool -Json $Artifact -Name "runtime_implemented" -Default $true)
  )
}

function Get-UserRemainingBalanceRuntimeChecks {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) {
    return [ordered]@{
      schema = $false
      status_pass = $false
      runtime_implemented = $false
      contract_only_false = $false
      route_invoked = $false
      read_only = $false
      admin_readonly_runtime = $false
      user_api_runtime = $false
      tenant_id_present = $false
      wallet_id_present = $false
      currency_present = $false
      available_to_spend_decimal = $false
      active_credit_grant_total_decimal = $false
      pending_confirmed_ledger_window_decimal = $false
      wallet_balance_floor_decimal = $false
      wallet_readback_passed = $false
      credit_grants_readback_passed = $false
      ledger_window_readback_passed = $false
      refusal_readback_passed = $false
      ownership_scope_verified = $false
      secret_safe = $false
      paid_gate_unchanged = $false
    }
  }

  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $routeInvoked = (Get-JsonBool -Json $Artifact -Name "route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "public_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "runtime_route_invoked")
  $ownershipScopeVerified = (Get-JsonBool -Json $Artifact -Name "authenticated_ownership_scope") -or
    (Get-JsonBool -Json $Artifact -Name "ownership_scope_verified") -or
    (Get-JsonBool -Json $Artifact -Name "developer_token_ownership_scope")

  return [ordered]@{
    schema = (Get-JsonString -Json $Artifact -Name "schema") -eq "user_remaining_balance_runtime.v1"
    status_pass = $status -in @("pass", "passed", "verified")
    runtime_implemented = Get-JsonBool -Json $Artifact -Name "runtime_implemented"
    contract_only_false = -not (Get-JsonBool -Json $Artifact -Name "contract_only" -Default $true)
    route_invoked = $routeInvoked
    read_only = Get-JsonBool -Json $Artifact -Name "read_only"
    admin_readonly_runtime = Get-JsonBool -Json $Artifact -Name "admin_readonly_runtime"
    user_api_runtime = Get-JsonBool -Json $Artifact -Name "user_api_runtime"
    tenant_id_present = (Get-JsonString -Json $Artifact -Name "tenant_id") -ne ""
    wallet_id_present = (Get-JsonString -Json $Artifact -Name "wallet_id") -ne ""
    currency_present = (Get-JsonString -Json $Artifact -Name "currency") -ne ""
    available_to_spend_decimal = Test-DecimalString -Value (Get-JsonString -Json $Artifact -Name "available_to_spend")
    active_credit_grant_total_decimal = Test-DecimalString -Value (Get-JsonString -Json $Artifact -Name "active_credit_grant_total")
    pending_confirmed_ledger_window_decimal = Test-DecimalString -Value (Get-JsonString -Json $Artifact -Name "pending_confirmed_ledger_window")
    wallet_balance_floor_decimal = Test-DecimalString -Value (Get-JsonString -Json $Artifact -Name "wallet_balance_floor")
    wallet_readback_passed = (Get-JsonBool -Json $Artifact -Name "wallet_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "readback_wallet")
    credit_grants_readback_passed = (Get-JsonBool -Json $Artifact -Name "credit_grants_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "readback_credit_grants")
    ledger_window_readback_passed = (Get-JsonBool -Json $Artifact -Name "ledger_window_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "readback_ledger_window")
    refusal_readback_passed = Get-JsonBool -Json $Artifact -Name "refusal_readback_passed"
    ownership_scope_verified = $ownershipScopeVerified
    secret_safe = Get-JsonBool -Json $Artifact -Name "secret_safe"
    paid_gate_unchanged = -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
  }
}

function Test-UserRemainingBalanceAdminRuntimeArtifact {
  param([AllowNull()][object]$Artifact)

  $checks = Get-UserRemainingBalanceRuntimeChecks -Artifact $Artifact
  $requiredKeys = @(
    "schema",
    "status_pass",
    "runtime_implemented",
    "contract_only_false",
    "route_invoked",
    "read_only",
    "admin_readonly_runtime",
    "tenant_id_present",
    "wallet_id_present",
    "currency_present",
    "available_to_spend_decimal",
    "active_credit_grant_total_decimal",
    "pending_confirmed_ledger_window_decimal",
    "wallet_balance_floor_decimal",
    "wallet_readback_passed",
    "credit_grants_readback_passed",
    "ledger_window_readback_passed",
    "refusal_readback_passed",
    "secret_safe",
    "paid_gate_unchanged"
  )
  return [bool](-not (@($requiredKeys | Where-Object { -not $checks[$_] }).Count -gt 0) -and -not $checks.user_api_runtime)
}

function Test-UserRemainingBalanceRuntimeArtifact {
  param([AllowNull()][object]$Artifact)

  $checks = Get-UserRemainingBalanceRuntimeChecks -Artifact $Artifact
  $requiredKeys = @(
    "schema",
    "status_pass",
    "runtime_implemented",
    "contract_only_false",
    "route_invoked",
    "read_only",
    "tenant_id_present",
    "wallet_id_present",
    "currency_present",
    "available_to_spend_decimal",
    "active_credit_grant_total_decimal",
    "pending_confirmed_ledger_window_decimal",
    "wallet_balance_floor_decimal",
    "wallet_readback_passed",
    "credit_grants_readback_passed",
    "ledger_window_readback_passed",
    "refusal_readback_passed",
    "secret_safe",
    "paid_gate_unchanged"
  )
  return [bool](
    -not (@($requiredKeys | Where-Object { -not $checks[$_] }).Count -gt 0) -and
    $checks.user_api_runtime -and
    $checks.ownership_scope_verified
  )
}

function Test-RechargeVoucherArtifact {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) { return $false }
  $schema = Get-JsonString -Json $Artifact -Name "schema"
  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $rawVoucherCode = Get-JsonString -Json $Artifact -Name "raw_voucher_code"
  $contractOnlyRequired = if ($schema -eq "recharge_voucher_contract.v1") {
    -not (Get-JsonBool -Json $Artifact -Name "runtime_implemented" -Default $true) -and
    (Get-JsonBool -Json $Artifact -Name "contract_only")
  } else {
    $true
  }
  $voucherCodeHashedOrRedacted = (Get-JsonBool -Json $Artifact -Name "voucher_code_hashed_or_redacted") -or
    ((Get-JsonBool -Json $Artifact -Name "voucher_code_hash_readback_passed") -and
      (Get-JsonBool -Json $Artifact -Name "voucher_code_redacted_output"))
  $redeemIdempotency = (Get-JsonBool -Json $Artifact -Name "redeem_idempotency_contract") -or
    (Get-JsonBool -Json $Artifact -Name "redeem_idempotency_readback_passed")
  $abuseGuard = (Get-JsonBool -Json $Artifact -Name "abuse_guard_contract") -or
    (Get-JsonBool -Json $Artifact -Name "abuse_refusal_no_write_readback_passed")
  $ledgerOrCreditEffect = (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_effect_contract") -or
    (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "credit_or_ledger_effect_readback_passed")
  $refusalNoWrites = (Get-JsonBool -Json $Artifact -Name "refusal_no_ledger_or_credit_grant_writes") -or
    (Get-JsonBool -Json $Artifact -Name "abuse_refusal_no_write_readback_passed")
  $refundCancelReversal = (Get-JsonBool -Json $Artifact -Name "refund_cancel_reversal_required") -or
    (Get-JsonBool -Json $Artifact -Name "refund_cancel_reversal_readback_passed")

  return [bool](
    $schema -in @("recharge_voucher_contract.v1", "recharge_voucher_runtime.v1", "recharge_voucher.v1") -and
    $status -in @("pass", "passed", "verified") -and
    $contractOnlyRequired -and
    (Get-JsonBool -Json $Artifact -Name "money_decimal_strings") -and
    $voucherCodeHashedOrRedacted -and
    $redeemIdempotency -and
    $abuseGuard -and
    $ledgerOrCreditEffect -and
    $refusalNoWrites -and
    $refundCancelReversal -and
    (Get-JsonBool -Json $Artifact -Name "audit_required") -and
    (Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden") -and
    (Get-JsonBool -Json $Artifact -Name "secret_safe") -and
    -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true) -and
    $rawVoucherCode -eq "" -and
    -not (Get-JsonBool -Json $Artifact -Name "raw_voucher_code_echoed" -Default $false)
  )
}

function Test-RechargeVoucherRuntimeArtifact {
  param([AllowNull()][object]$Artifact)

  if (-not (Test-RechargeVoucherArtifact -Artifact $Artifact)) { return $false }
  $schema = Get-JsonString -Json $Artifact -Name "schema"
  return [bool](
    $schema -eq "recharge_voucher_runtime.v1" -and
    (Get-JsonBool -Json $Artifact -Name "runtime_implemented") -and
    -not (Get-JsonBool -Json $Artifact -Name "contract_only" -Default $true) -and
    ((Get-JsonBool -Json $Artifact -Name "control_plane_route_invoked") -or (Get-JsonBool -Json $Artifact -Name "runtime_route_invoked") -or (Get-JsonBool -Json $Artifact -Name "internal_sqlx_function_invoked")) -and
    (Get-JsonBool -Json $Artifact -Name "voucher_storage_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "voucher_code_hash_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "voucher_code_redacted_output") -and
    (Get-JsonBool -Json $Artifact -Name "redeem_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "redeem_idempotency_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "abuse_refusal_no_write_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "refund_cancel_reversal_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "audit_readback_passed")
  )
}

function Test-PaymentOrderInvoiceArtifact {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) { return $false }
  $schema = Get-JsonString -Json $Artifact -Name "schema"
  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $contractOnlyRequired = if ($schema -eq "payment_order_invoice_contract.v1") {
    -not (Get-JsonBool -Json $Artifact -Name "runtime_implemented" -Default $true) -and
    (Get-JsonBool -Json $Artifact -Name "contract_only")
  } else {
    $true
  }

  $idempotencyContract = (Get-JsonBool -Json $Artifact -Name "idempotency_contract") -or
    (Get-JsonBool -Json $Artifact -Name "replay_idempotency_contract") -or
    (Get-JsonBool -Json $Artifact -Name "idempotency_replay_readback_passed")
  $providerHandoffContract = (Get-JsonBool -Json $Artifact -Name "provider_handoff_secret_safe") -or
    (Get-JsonBool -Json $Artifact -Name "provider_handoff_contract") -or
    ((Get-JsonBool -Json $Artifact -Name "provider_handoff_readback_passed") -and
      (Get-JsonBool -Json $Artifact -Name "provider_handoff_redacted_output"))
  $ledgerOrCreditContract = (Get-JsonBool -Json $Artifact -Name "capture_ledger_or_credit_effect_contract") -or
    (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_effect_contract") -or
    (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "credit_or_ledger_effect_readback_passed")
  $refusalNoWritesContract = (Get-JsonBool -Json $Artifact -Name "refusal_no_ledger_credit_invoice_refund_writes") -or
    (Get-JsonBool -Json $Artifact -Name "refusal_no_ledger_or_credit_grant_writes") -or
    (Get-JsonBool -Json $Artifact -Name "conflict_no_duplicate_write_readback_passed")
  $invoiceReceiptContract = (Get-JsonBool -Json $Artifact -Name "invoice_receipt_contract") -or
    (Get-JsonBool -Json $Artifact -Name "invoice_receipt_readback_passed")
  $refundCancelReversal = (Get-JsonBool -Json $Artifact -Name "refund_cancel_reversal_required") -or
    (Get-JsonBool -Json $Artifact -Name "refund_cancel_reversal_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "refund_cancel_chargeback_reversal_readback_passed")
  $reconciliation = (Get-JsonBool -Json $Artifact -Name "reconciliation_contract") -or
    (Get-JsonBool -Json $Artifact -Name "reconciliation_readback_passed")

  return [bool](
    $schema -in @("payment_order_invoice_contract.v1", "payment_order_invoice_runtime.v1", "payment_order_invoice.v1") -and
    $status -in @("pass", "passed", "verified") -and
    $contractOnlyRequired -and
    (Get-JsonBool -Json $Artifact -Name "money_decimal_strings") -and
    $idempotencyContract -and
    $providerHandoffContract -and
    $ledgerOrCreditContract -and
    $invoiceReceiptContract -and
    $refusalNoWritesContract -and
    $refundCancelReversal -and
    $reconciliation -and
    (Get-JsonBool -Json $Artifact -Name "audit_required") -and
    (Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden") -and
    (Get-JsonBool -Json $Artifact -Name "secret_safe") -and
    -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
  )
}

function Test-PaymentOrderInvoiceRuntimeArtifact {
  param([AllowNull()][object]$Artifact)

  if (-not (Test-PaymentOrderInvoiceArtifact -Artifact $Artifact)) { return $false }
  $schema = Get-JsonString -Json $Artifact -Name "schema"
  $routeOrRuntimeInvoked = (Get-JsonBool -Json $Artifact -Name "control_plane_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "runtime_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "internal_sqlx_function_invoked")
  return [bool](
    $schema -eq "payment_order_invoice_runtime.v1" -and
    (Get-JsonBool -Json $Artifact -Name "runtime_implemented") -and
    -not (Get-JsonBool -Json $Artifact -Name "contract_only" -Default $true) -and
    $routeOrRuntimeInvoked -and
    ((Get-JsonBool -Json $Artifact -Name "order_lifecycle_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "order_readback_passed")) -and
    ((Get-JsonBool -Json $Artifact -Name "provider_handoff_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "provider_handoff_runtime_verified")) -and
    (Get-JsonBool -Json $Artifact -Name "provider_handoff_redacted_output") -and
    ((Get-JsonBool -Json $Artifact -Name "payment_callback_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "provider_callback_readback_passed")) -and
    ((Get-JsonBool -Json $Artifact -Name "payment_confirm_capture_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "capture_readback_passed")) -and
    (Get-JsonBool -Json $Artifact -Name "invoice_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "invoice_receipt_readback_passed") -and
    ((Get-JsonBool -Json $Artifact -Name "ledger_or_credit_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "credit_or_ledger_effect_readback_passed")) -and
    (Get-JsonBool -Json $Artifact -Name "idempotency_replay_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "conflict_no_duplicate_write_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "audit_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "reconciliation_readback_passed") -and
    ((Get-JsonBool -Json $Artifact -Name "refund_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "refund_cancel_reversal_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "refund_cancel_chargeback_reversal_readback_passed"))
  )
}

function Test-SubscriptionPackageLifecycleArtifact {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) { return $false }
  $schema = Get-JsonString -Json $Artifact -Name "schema"
  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $contractOnlyRequired = if ($schema -eq "subscription_package_lifecycle_contract.v1") {
    -not (Get-JsonBool -Json $Artifact -Name "runtime_implemented" -Default $true) -and
    (Get-JsonBool -Json $Artifact -Name "contract_only")
  } else {
    $true
  }

  $idempotencyContract = (Get-JsonBool -Json $Artifact -Name "idempotency_contract") -or
    (Get-JsonBool -Json $Artifact -Name "replay_idempotency_contract") -or
    (Get-JsonBool -Json $Artifact -Name "idempotency_replay_readback_passed")
  $creditOrLedgerEffect = (Get-JsonBool -Json $Artifact -Name "subscription_credit_effect_contract") -or
    (Get-JsonBool -Json $Artifact -Name "credit_grant_or_ledger_effect_contract") -or
    (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_effect_contract") -or
    (Get-JsonBool -Json $Artifact -Name "credit_or_ledger_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_readback_passed")
  $refusalNoWrites = (Get-JsonBool -Json $Artifact -Name "refusal_no_subscription_ledger_credit_invoice_writes") -or
    (Get-JsonBool -Json $Artifact -Name "refusal_no_ledger_credit_invoice_refund_writes") -or
    (Get-JsonBool -Json $Artifact -Name "refusal_no_ledger_or_credit_grant_writes") -or
    (Get-JsonBool -Json $Artifact -Name "refusal_no_write_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "conflict_no_duplicate_write_readback_passed")
  $planPackageLifecycle = (Get-JsonBool -Json $Artifact -Name "plan_package_lifecycle_contract") -or
    ((Get-JsonArrayCount -Json $Artifact -Name "plan_states") -gt 0) -or
    (Get-JsonBool -Json $Artifact -Name "plan_package_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "plan_package_crud_readback_passed")
  $subscriptionStates = (Get-JsonBool -Json $Artifact -Name "subscription_states_contract") -or
    ((Get-JsonArrayCount -Json $Artifact -Name "subscription_states") -gt 0) -or
    (Get-JsonBool -Json $Artifact -Name "subscription_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "subscription_lifecycle_readback_passed")
  $invoiceOrderLinkage = (Get-JsonBool -Json $Artifact -Name "invoice_order_linkage_contract") -or
    (Get-JsonBool -Json $Artifact -Name "invoice_order_readback_passed") -or
    ((Get-JsonBool -Json $Artifact -Name "invoice_readback_passed") -and (Get-JsonBool -Json $Artifact -Name "order_readback_passed"))

  return [bool](
    $schema -in @("subscription_package_lifecycle_contract.v1", "subscription_package_lifecycle_runtime.v1", "subscription_package_lifecycle.v1") -and
    $status -in @("pass", "passed", "verified") -and
    $contractOnlyRequired -and
    (Get-JsonBool -Json $Artifact -Name "money_decimal_strings") -and
    $idempotencyContract -and
    $planPackageLifecycle -and
    $subscriptionStates -and
    $creditOrLedgerEffect -and
    $invoiceOrderLinkage -and
    $refusalNoWrites -and
    (Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden") -and
    (Get-JsonBool -Json $Artifact -Name "audit_required") -and
    (Get-JsonBool -Json $Artifact -Name "secret_safe") -and
    -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
  )
}

function Test-SubscriptionPackageLifecycleRuntimeArtifact {
  param([AllowNull()][object]$Artifact)

  if (-not (Test-SubscriptionPackageLifecycleArtifact -Artifact $Artifact)) { return $false }
  $schema = Get-JsonString -Json $Artifact -Name "schema"
  $routeOrRuntimeInvoked = (Get-JsonBool -Json $Artifact -Name "control_plane_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "runtime_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "scheduler_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "internal_sqlx_function_invoked")
  return [bool](
    $schema -eq "subscription_package_lifecycle_runtime.v1" -and
    (Get-JsonBool -Json $Artifact -Name "runtime_implemented") -and
    -not (Get-JsonBool -Json $Artifact -Name "contract_only" -Default $true) -and
    $routeOrRuntimeInvoked -and
    ((Get-JsonBool -Json $Artifact -Name "plan_package_crud_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "plan_package_readback_passed")) -and
    ((Get-JsonBool -Json $Artifact -Name "subscription_lifecycle_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "subscription_readback_passed")) -and
    (Get-JsonBool -Json $Artifact -Name "subscription_state_transitions_readback_passed") -and
    ((Get-JsonBool -Json $Artifact -Name "trial_proration_dunning_readback_passed") -or
      ((Get-JsonBool -Json $Artifact -Name "trial_readback_passed") -and (Get-JsonBool -Json $Artifact -Name "proration_readback_passed") -and (Get-JsonBool -Json $Artifact -Name "dunning_readback_passed"))) -and
    ((Get-JsonBool -Json $Artifact -Name "invoice_order_readback_passed") -or
      ((Get-JsonBool -Json $Artifact -Name "invoice_readback_passed") -and (Get-JsonBool -Json $Artifact -Name "order_readback_passed"))) -and
    ((Get-JsonBool -Json $Artifact -Name "credit_or_ledger_readback_passed") -or (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_readback_passed")) -and
    (Get-JsonBool -Json $Artifact -Name "idempotency_replay_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "conflict_no_duplicate_write_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "refusal_no_write_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "audit_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "renewal_readback_passed") -and
    (Get-JsonBool -Json $Artifact -Name "cancel_pause_resume_readback_passed")
  )
}

function Get-OpeningBalanceImportArtifactChecks {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) {
    return [ordered]@{
      schema = $false
      status_pass = $false
      secret_safe = $false
      money_decimal_strings = $false
      idempotency_contract = $false
      opening_ledger_entry_required = $false
      direct_wallet_snapshot_mutation_forbidden = $false
      paid_gate_unchanged = $false
      runtime_implemented = $false
      route_or_internal_rust_path_invoked = $false
      db_runner_implemented = $false
      contract_only_false = $false
      endpoint_present = $false
      opening_import_id_present = $false
      ledger_or_admin_adjustment_id_present = $false
      audit_id_present = $false
      live_db_readback_passed = $false
      opening_import_readback_passed = $false
      ledger_or_admin_adjustment_readback_passed = $false
      audit_readback_passed = $false
      replay_readback_passed = $false
      refusal_readback_passed = $false
      rollback_readback_passed = $false
    }
  }

  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $runtimeChecks = Get-OpeningBalanceImportRuntimeChecks -Artifact $Artifact
  return [ordered]@{
    schema = (Get-JsonString -Json $Artifact -Name "schema") -in @("opening_balance_import_contract.v1", "opening_balance_import_runtime.v1")
    status_pass = $status -in @("pass", "passed", "verified")
    secret_safe = Get-JsonBool -Json $Artifact -Name "secret_safe"
    money_decimal_strings = Get-JsonBool -Json $Artifact -Name "money_decimal_strings"
    idempotency_contract = Get-JsonBool -Json $Artifact -Name "idempotency_contract"
    opening_ledger_entry_required = Get-JsonBool -Json $Artifact -Name "opening_ledger_entry_required"
    direct_wallet_snapshot_mutation_forbidden = Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden"
    paid_gate_unchanged = -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
    runtime_implemented = Get-JsonBool -Json $Artifact -Name "runtime_implemented"
    route_or_internal_rust_path_invoked = $runtimeChecks.route_or_internal_rust_path_invoked
    db_runner_implemented = $runtimeChecks.db_runner_implemented
    contract_only_false = $runtimeChecks.contract_only_false
    endpoint_present = $runtimeChecks.endpoint_present
    opening_import_id_present = $runtimeChecks.opening_import_id_present
    ledger_or_admin_adjustment_id_present = $runtimeChecks.ledger_or_admin_adjustment_id_present
    audit_id_present = $runtimeChecks.audit_id_present
    live_db_readback_passed = $runtimeChecks.live_db_readback_passed
    opening_import_readback_passed = $runtimeChecks.opening_import_readback_passed
    ledger_or_admin_adjustment_readback_passed = $runtimeChecks.ledger_or_admin_adjustment_readback_passed
    audit_readback_passed = $runtimeChecks.audit_readback_passed
    replay_readback_passed = $runtimeChecks.replay_readback_passed
    refusal_readback_passed = $runtimeChecks.refusal_readback_passed
    rollback_readback_passed = $runtimeChecks.rollback_readback_passed
  }
}

function Get-BillingMutationArtifactChecks {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) {
    return [ordered]@{
      schema = $false
      status_pass = $false
      money_decimal_strings = $false
      idempotency_contract = $false
      direct_wallet_snapshot_mutation_forbidden = $false
      secret_safe = $false
      runtime_writer_unchanged = $false
      paid_gate_unchanged = $false
      invariant_accounting = $false
      invariant_idempotency = $false
      invariant_secret = $false
      invariant_direct_wallet_forbidden = $false
    }
  }

  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $invariants = Get-JsonStringArray -Json $Artifact -Name "invariants_enforced"
  return [ordered]@{
    schema = (Get-JsonString -Json $Artifact -Name "schema") -eq "billing_mutation_contract_tests.v1"
    status_pass = $status -in @("pass", "passed", "verified")
    money_decimal_strings = Get-JsonBool -Json $Artifact -Name "money_decimal_strings"
    idempotency_contract = Get-JsonBool -Json $Artifact -Name "idempotency_contract"
    direct_wallet_snapshot_mutation_forbidden = Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden"
    secret_safe = Get-JsonBool -Json $Artifact -Name "secret_safe"
    runtime_writer_unchanged = -not (Get-JsonBool -Json $Artifact -Name "runtime_writer_changed" -Default $true)
    paid_gate_unchanged = -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
    invariant_accounting = @($invariants | Where-Object { $_ -match "accounting|ledger|admin_adjustment|opening" }).Count -gt 0
    invariant_idempotency = @($invariants | Where-Object { $_ -match "idempotent|idempotency" }).Count -gt 0
    invariant_secret = @($invariants | Where-Object { $_ -match "secret" }).Count -gt 0
    invariant_direct_wallet_forbidden = @($invariants | Where-Object { $_ -match "direct_wallet_snapshot_mutation_forbidden|direct-wallet|wallet_snapshot" }).Count -gt 0
  }
}

function Get-CreditGrantCrudArtifactChecks {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) {
    return [ordered]@{
      schema = $false
      status_pass = $false
      money_decimal_strings = $false
      idempotency_contract = $false
      audit_required = $false
      direct_wallet_snapshot_mutation_forbidden = $false
      secret_safe = $false
      paid_gate_unchanged = $false
      runtime_implemented = $false
      route_or_internal_rust_path_invoked = $false
      contract_only_false = $false
      endpoint_present = $false
      grant_id_present = $false
      audit_id_present = $false
      create_readback_passed = $false
      list_readback_passed = $false
      read_readback_passed = $false
      expire_or_revoke_readback_passed = $false
      status_readback_passed = $false
      replay_readback_passed = $false
      conflict_or_refusal_no_write_passed = $false
      audit_readback_passed = $false
    }
  }

  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $runtimeChecks = Get-CreditGrantCrudRuntimeChecks -Artifact $Artifact
  return [ordered]@{
    schema = (Get-JsonString -Json $Artifact -Name "schema") -in @("credit_grant_crud_contract.v1", "credit_grant_crud_runtime.v1")
    status_pass = $status -in @("pass", "passed", "verified")
    money_decimal_strings = Get-JsonBool -Json $Artifact -Name "money_decimal_strings"
    idempotency_contract = Get-JsonBool -Json $Artifact -Name "idempotency_contract"
    audit_required = Get-JsonBool -Json $Artifact -Name "audit_required"
    direct_wallet_snapshot_mutation_forbidden = Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden"
    secret_safe = Get-JsonBool -Json $Artifact -Name "secret_safe"
    paid_gate_unchanged = -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
    runtime_implemented = $runtimeChecks.runtime_implemented
    route_or_internal_rust_path_invoked = $runtimeChecks.route_or_internal_rust_path_invoked
    contract_only_false = $runtimeChecks.contract_only_false
    endpoint_present = $runtimeChecks.endpoint_present
    grant_id_present = $runtimeChecks.grant_id_present
    audit_id_present = $runtimeChecks.audit_id_present
    create_readback_passed = $runtimeChecks.create_readback_passed
    list_readback_passed = $runtimeChecks.list_readback_passed
    read_readback_passed = $runtimeChecks.read_readback_passed
    expire_or_revoke_readback_passed = $runtimeChecks.expire_or_revoke_readback_passed
    status_readback_passed = $runtimeChecks.status_readback_passed
    replay_readback_passed = $runtimeChecks.replay_readback_passed
    conflict_or_refusal_no_write_passed = $runtimeChecks.conflict_or_refusal_no_write_passed
    audit_readback_passed = $runtimeChecks.audit_readback_passed
  }
}

function Get-UserRemainingBalanceArtifactChecks {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) {
    return [ordered]@{
      schema = $false
      status_pass = $false
      money_decimal_strings = $false
      read_only = $false
      secret_safe = $false
      paid_gate_unchanged = $false
      runtime_not_implemented = $false
      admin_runtime_verified = $false
      full_user_runtime_verified = $false
    }
  }

  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $runtimeChecks = Get-UserRemainingBalanceRuntimeChecks -Artifact $Artifact
  return [ordered]@{
    schema = (Get-JsonString -Json $Artifact -Name "schema") -in @("user_remaining_balance_contract.v1", "user_remaining_balance_api.v1", "user_remaining_balance_runtime.v1")
    status_pass = $status -in @("pass", "passed", "verified")
    money_decimal_strings = Get-JsonBool -Json $Artifact -Name "money_decimal_strings"
    read_only = Get-JsonBool -Json $Artifact -Name "read_only"
    secret_safe = Get-JsonBool -Json $Artifact -Name "secret_safe"
    paid_gate_unchanged = -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
    runtime_not_implemented = -not (Get-JsonBool -Json $Artifact -Name "runtime_implemented" -Default $true)
    runtime_implemented = $runtimeChecks.runtime_implemented
    contract_only_false = $runtimeChecks.contract_only_false
    route_invoked = $runtimeChecks.route_invoked
    admin_readonly_runtime = $runtimeChecks.admin_readonly_runtime
    user_api_runtime = $runtimeChecks.user_api_runtime
    tenant_id_present = $runtimeChecks.tenant_id_present
    wallet_id_present = $runtimeChecks.wallet_id_present
    currency_present = $runtimeChecks.currency_present
    available_to_spend_decimal = $runtimeChecks.available_to_spend_decimal
    active_credit_grant_total_decimal = $runtimeChecks.active_credit_grant_total_decimal
    pending_confirmed_ledger_window_decimal = $runtimeChecks.pending_confirmed_ledger_window_decimal
    wallet_balance_floor_decimal = $runtimeChecks.wallet_balance_floor_decimal
    wallet_readback_passed = $runtimeChecks.wallet_readback_passed
    credit_grants_readback_passed = $runtimeChecks.credit_grants_readback_passed
    ledger_window_readback_passed = $runtimeChecks.ledger_window_readback_passed
    refusal_readback_passed = $runtimeChecks.refusal_readback_passed
    ownership_scope_verified = $runtimeChecks.ownership_scope_verified
    admin_runtime_verified = Test-UserRemainingBalanceAdminRuntimeArtifact -Artifact $Artifact
    full_user_runtime_verified = Test-UserRemainingBalanceRuntimeArtifact -Artifact $Artifact
  }
}

function Get-RechargeVoucherArtifactChecks {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) {
    return [ordered]@{
      schema = $false
      status_pass = $false
      contract_runtime_false = $false
      contract_only_true = $false
      money_decimal_strings = $false
      voucher_code_hashed_or_redacted = $false
      redeem_idempotency_contract = $false
      abuse_guard_contract = $false
      ledger_or_credit_effect_contract = $false
      refusal_no_ledger_or_credit_grant_writes = $false
      refund_cancel_reversal_required = $false
      audit_required = $false
      direct_wallet_snapshot_mutation_forbidden = $false
      secret_safe = $false
      paid_gate_unchanged = $false
      raw_voucher_code_absent = $false
      raw_voucher_code_not_echoed = $false
      runtime_implemented = $false
      contract_only_false = $false
      route_or_internal_runtime_invoked = $false
      voucher_storage_readback_passed = $false
      voucher_code_hash_readback_passed = $false
      voucher_code_redacted_output = $false
      redeem_readback_passed = $false
      redeem_idempotency_readback_passed = $false
      abuse_refusal_no_write_readback_passed = $false
      ledger_or_credit_readback_passed = $false
      refund_cancel_reversal_readback_passed = $false
      audit_readback_passed = $false
      runtime_verified = $false
    }
  }

  $schema = Get-JsonString -Json $Artifact -Name "schema"
  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $routeOrRuntimeInvoked = (Get-JsonBool -Json $Artifact -Name "control_plane_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "runtime_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "internal_sqlx_function_invoked")
  $ledgerOrCreditReadbackPassed = (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "credit_or_ledger_effect_readback_passed")
  return [ordered]@{
    schema = $schema -in @("recharge_voucher_contract.v1", "recharge_voucher_runtime.v1", "recharge_voucher.v1")
    status_pass = $status -in @("pass", "passed", "verified")
    contract_runtime_false = if ($schema -eq "recharge_voucher_contract.v1") { -not (Get-JsonBool -Json $Artifact -Name "runtime_implemented" -Default $true) } else { $true }
    contract_only_true = if ($schema -eq "recharge_voucher_contract.v1") { Get-JsonBool -Json $Artifact -Name "contract_only" } else { $true }
    money_decimal_strings = Get-JsonBool -Json $Artifact -Name "money_decimal_strings"
    voucher_code_hashed_or_redacted = Get-JsonBool -Json $Artifact -Name "voucher_code_hashed_or_redacted"
    redeem_idempotency_contract = Get-JsonBool -Json $Artifact -Name "redeem_idempotency_contract"
    abuse_guard_contract = Get-JsonBool -Json $Artifact -Name "abuse_guard_contract"
    ledger_or_credit_effect_contract = Get-JsonBool -Json $Artifact -Name "ledger_or_credit_effect_contract"
    refusal_no_ledger_or_credit_grant_writes = Get-JsonBool -Json $Artifact -Name "refusal_no_ledger_or_credit_grant_writes"
    refund_cancel_reversal_required = Get-JsonBool -Json $Artifact -Name "refund_cancel_reversal_required"
    audit_required = Get-JsonBool -Json $Artifact -Name "audit_required"
    direct_wallet_snapshot_mutation_forbidden = Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden"
    secret_safe = Get-JsonBool -Json $Artifact -Name "secret_safe"
    paid_gate_unchanged = -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
    raw_voucher_code_absent = (Get-JsonString -Json $Artifact -Name "raw_voucher_code") -eq ""
    raw_voucher_code_not_echoed = -not (Get-JsonBool -Json $Artifact -Name "raw_voucher_code_echoed" -Default $false)
    runtime_implemented = Get-JsonBool -Json $Artifact -Name "runtime_implemented"
    contract_only_false = -not (Get-JsonBool -Json $Artifact -Name "contract_only" -Default $true)
    route_or_internal_runtime_invoked = $routeOrRuntimeInvoked
    voucher_storage_readback_passed = Get-JsonBool -Json $Artifact -Name "voucher_storage_readback_passed"
    voucher_code_hash_readback_passed = Get-JsonBool -Json $Artifact -Name "voucher_code_hash_readback_passed"
    voucher_code_redacted_output = Get-JsonBool -Json $Artifact -Name "voucher_code_redacted_output"
    redeem_readback_passed = Get-JsonBool -Json $Artifact -Name "redeem_readback_passed"
    redeem_idempotency_readback_passed = Get-JsonBool -Json $Artifact -Name "redeem_idempotency_readback_passed"
    abuse_refusal_no_write_readback_passed = Get-JsonBool -Json $Artifact -Name "abuse_refusal_no_write_readback_passed"
    ledger_or_credit_readback_passed = $ledgerOrCreditReadbackPassed
    refund_cancel_reversal_readback_passed = Get-JsonBool -Json $Artifact -Name "refund_cancel_reversal_readback_passed"
    audit_readback_passed = Get-JsonBool -Json $Artifact -Name "audit_readback_passed"
    runtime_verified = Test-RechargeVoucherRuntimeArtifact -Artifact $Artifact
  }
}

function Get-PaymentOrderInvoiceArtifactChecks {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) {
    return [ordered]@{
      schema = $false
      status_pass = $false
      contract_runtime_false = $false
      contract_only_true = $false
      money_decimal_strings = $false
      idempotency_contract = $false
      provider_handoff_contract = $false
      ledger_or_credit_effect_contract = $false
      invoice_receipt_contract = $false
      refusal_no_writes_contract = $false
      refund_cancel_reversal_required = $false
      reconciliation_contract = $false
      audit_required = $false
      direct_wallet_snapshot_mutation_forbidden = $false
      secret_safe = $false
      paid_gate_unchanged = $false
      runtime_implemented = $false
      contract_only_false = $false
      route_or_internal_runtime_invoked = $false
      order_lifecycle_readback_passed = $false
      provider_handoff_readback_passed = $false
      provider_handoff_redacted_output = $false
      provider_callback_or_capture_readback_passed = $false
      payment_confirm_capture_readback_passed = $false
      invoice_receipt_readback_passed = $false
      ledger_or_credit_readback_passed = $false
      refund_cancel_chargeback_reversal_readback_passed = $false
      idempotency_replay_readback_passed = $false
      conflict_no_duplicate_write_readback_passed = $false
      audit_readback_passed = $false
      reconciliation_readback_passed = $false
      runtime_verified = $false
    }
  }

  $schema = Get-JsonString -Json $Artifact -Name "schema"
  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $idempotencyContract = (Get-JsonBool -Json $Artifact -Name "idempotency_contract") -or
    (Get-JsonBool -Json $Artifact -Name "replay_idempotency_contract") -or
    (Get-JsonBool -Json $Artifact -Name "idempotency_replay_readback_passed")
  $providerHandoffContract = (Get-JsonBool -Json $Artifact -Name "provider_handoff_secret_safe") -or
    (Get-JsonBool -Json $Artifact -Name "provider_handoff_contract") -or
    ((Get-JsonBool -Json $Artifact -Name "provider_handoff_readback_passed") -and
      (Get-JsonBool -Json $Artifact -Name "provider_handoff_redacted_output"))
  $ledgerOrCreditContract = (Get-JsonBool -Json $Artifact -Name "capture_ledger_or_credit_effect_contract") -or
    (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_effect_contract") -or
    (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "credit_or_ledger_effect_readback_passed")
  $refusalNoWritesContract = (Get-JsonBool -Json $Artifact -Name "refusal_no_ledger_credit_invoice_refund_writes") -or
    (Get-JsonBool -Json $Artifact -Name "refusal_no_ledger_or_credit_grant_writes") -or
    (Get-JsonBool -Json $Artifact -Name "conflict_no_duplicate_write_readback_passed")
  $invoiceReceiptContract = (Get-JsonBool -Json $Artifact -Name "invoice_receipt_contract") -or
    (Get-JsonBool -Json $Artifact -Name "invoice_receipt_readback_passed")
  $refundCancelReversal = (Get-JsonBool -Json $Artifact -Name "refund_cancel_reversal_required") -or
    (Get-JsonBool -Json $Artifact -Name "refund_cancel_reversal_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "refund_cancel_chargeback_reversal_readback_passed")
  $reconciliation = (Get-JsonBool -Json $Artifact -Name "reconciliation_contract") -or
    (Get-JsonBool -Json $Artifact -Name "reconciliation_readback_passed")
  $routeOrRuntimeInvoked = (Get-JsonBool -Json $Artifact -Name "control_plane_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "runtime_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "internal_sqlx_function_invoked")
  $orderLifecycleReadbackPassed = (Get-JsonBool -Json $Artifact -Name "order_lifecycle_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "order_readback_passed")
  $providerCallbackOrCaptureReadbackPassed = (Get-JsonBool -Json $Artifact -Name "payment_callback_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "provider_callback_readback_passed")
  $paymentConfirmCaptureReadbackPassed = (Get-JsonBool -Json $Artifact -Name "payment_confirm_capture_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "capture_readback_passed")
  $ledgerOrCreditReadbackPassed = (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "credit_or_ledger_effect_readback_passed")
  $refundCancelChargebackReadbackPassed = (Get-JsonBool -Json $Artifact -Name "refund_cancel_reversal_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "refund_cancel_chargeback_reversal_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "refund_readback_passed")

  return [ordered]@{
    schema = $schema -in @("payment_order_invoice_contract.v1", "payment_order_invoice_runtime.v1", "payment_order_invoice.v1")
    status_pass = $status -in @("pass", "passed", "verified")
    contract_runtime_false = if ($schema -eq "payment_order_invoice_contract.v1") { -not (Get-JsonBool -Json $Artifact -Name "runtime_implemented" -Default $true) } else { $true }
    contract_only_true = if ($schema -eq "payment_order_invoice_contract.v1") { Get-JsonBool -Json $Artifact -Name "contract_only" } else { $true }
    money_decimal_strings = Get-JsonBool -Json $Artifact -Name "money_decimal_strings"
    idempotency_contract = $idempotencyContract
    provider_handoff_contract = $providerHandoffContract
    ledger_or_credit_effect_contract = $ledgerOrCreditContract
    invoice_receipt_contract = $invoiceReceiptContract
    refusal_no_writes_contract = $refusalNoWritesContract
    refund_cancel_reversal_required = $refundCancelReversal
    reconciliation_contract = $reconciliation
    audit_required = Get-JsonBool -Json $Artifact -Name "audit_required"
    direct_wallet_snapshot_mutation_forbidden = Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden"
    secret_safe = Get-JsonBool -Json $Artifact -Name "secret_safe"
    paid_gate_unchanged = -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
    runtime_implemented = Get-JsonBool -Json $Artifact -Name "runtime_implemented"
    contract_only_false = -not (Get-JsonBool -Json $Artifact -Name "contract_only" -Default $true)
    route_or_internal_runtime_invoked = $routeOrRuntimeInvoked
    order_lifecycle_readback_passed = $orderLifecycleReadbackPassed
    provider_handoff_readback_passed = Get-JsonBool -Json $Artifact -Name "provider_handoff_readback_passed"
    provider_handoff_redacted_output = Get-JsonBool -Json $Artifact -Name "provider_handoff_redacted_output"
    provider_callback_or_capture_readback_passed = $providerCallbackOrCaptureReadbackPassed
    payment_confirm_capture_readback_passed = $paymentConfirmCaptureReadbackPassed
    invoice_receipt_readback_passed = Get-JsonBool -Json $Artifact -Name "invoice_receipt_readback_passed"
    ledger_or_credit_readback_passed = $ledgerOrCreditReadbackPassed
    refund_cancel_chargeback_reversal_readback_passed = $refundCancelChargebackReadbackPassed
    idempotency_replay_readback_passed = Get-JsonBool -Json $Artifact -Name "idempotency_replay_readback_passed"
    conflict_no_duplicate_write_readback_passed = Get-JsonBool -Json $Artifact -Name "conflict_no_duplicate_write_readback_passed"
    audit_readback_passed = Get-JsonBool -Json $Artifact -Name "audit_readback_passed"
    reconciliation_readback_passed = Get-JsonBool -Json $Artifact -Name "reconciliation_readback_passed"
    runtime_verified = Test-PaymentOrderInvoiceRuntimeArtifact -Artifact $Artifact
  }
}

function Get-SubscriptionPackageLifecycleArtifactChecks {
  param([AllowNull()][object]$Artifact)

  if ($null -eq $Artifact) {
    return [ordered]@{
      schema = $false
      status_pass = $false
      contract_runtime_false = $false
      contract_only_true = $false
      money_decimal_strings = $false
      idempotency_contract = $false
      plan_package_lifecycle = $false
      subscription_states = $false
      credit_or_ledger_effect_contract = $false
      invoice_order_linkage_contract = $false
      refusal_no_writes_contract = $false
      direct_wallet_snapshot_mutation_forbidden = $false
      audit_required = $false
      secret_safe = $false
      paid_gate_unchanged = $false
      runtime_implemented = $false
      contract_only_false = $false
      route_or_internal_runtime_invoked = $false
      plan_package_crud_readback_passed = $false
      subscription_lifecycle_readback_passed = $false
      subscription_state_transitions_readback_passed = $false
      trial_proration_dunning_readback_passed = $false
      credit_or_ledger_readback_passed = $false
      invoice_order_readback_passed = $false
      idempotency_replay_readback_passed = $false
      conflict_no_duplicate_write_readback_passed = $false
      refusal_no_write_readback_passed = $false
      audit_readback_passed = $false
      renewal_readback_passed = $false
      cancel_pause_resume_readback_passed = $false
      runtime_verified = $false
    }
  }

  $schema = Get-JsonString -Json $Artifact -Name "schema"
  $status = Get-JsonString -Json $Artifact -Name "overall_status"
  if ($status -eq "") { $status = Get-JsonString -Json $Artifact -Name "status" }
  $routeOrRuntimeInvoked = (Get-JsonBool -Json $Artifact -Name "control_plane_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "runtime_route_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "scheduler_invoked") -or
    (Get-JsonBool -Json $Artifact -Name "internal_sqlx_function_invoked")
  $planPackageReadback = (Get-JsonBool -Json $Artifact -Name "plan_package_crud_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "plan_package_readback_passed")
  $subscriptionLifecycleReadback = (Get-JsonBool -Json $Artifact -Name "subscription_lifecycle_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "subscription_readback_passed")
  $trialProrationDunningReadback = (Get-JsonBool -Json $Artifact -Name "trial_proration_dunning_readback_passed") -or
    ((Get-JsonBool -Json $Artifact -Name "trial_readback_passed") -and
      (Get-JsonBool -Json $Artifact -Name "proration_readback_passed") -and
      (Get-JsonBool -Json $Artifact -Name "dunning_readback_passed"))
  $creditOrLedgerReadback = (Get-JsonBool -Json $Artifact -Name "credit_or_ledger_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_readback_passed")
  $invoiceOrderReadback = (Get-JsonBool -Json $Artifact -Name "invoice_order_readback_passed") -or
    ((Get-JsonBool -Json $Artifact -Name "invoice_readback_passed") -and
      (Get-JsonBool -Json $Artifact -Name "order_readback_passed"))
  $idempotencyContract = (Get-JsonBool -Json $Artifact -Name "idempotency_contract") -or
    (Get-JsonBool -Json $Artifact -Name "replay_idempotency_contract") -or
    (Get-JsonBool -Json $Artifact -Name "idempotency_replay_readback_passed")
  $planPackageLifecycle = (Get-JsonBool -Json $Artifact -Name "plan_package_lifecycle_contract") -or
    ((Get-JsonArrayCount -Json $Artifact -Name "plan_states") -gt 0) -or
    $planPackageReadback
  $subscriptionStates = (Get-JsonBool -Json $Artifact -Name "subscription_states_contract") -or
    ((Get-JsonArrayCount -Json $Artifact -Name "subscription_states") -gt 0) -or
    $subscriptionLifecycleReadback
  $creditOrLedgerEffect = (Get-JsonBool -Json $Artifact -Name "subscription_credit_effect_contract") -or
    (Get-JsonBool -Json $Artifact -Name "credit_grant_or_ledger_effect_contract") -or
    (Get-JsonBool -Json $Artifact -Name "ledger_or_credit_effect_contract") -or
    $creditOrLedgerReadback
  $invoiceOrderLinkage = (Get-JsonBool -Json $Artifact -Name "invoice_order_linkage_contract") -or
    $invoiceOrderReadback
  $refusalNoWrites = (Get-JsonBool -Json $Artifact -Name "refusal_no_subscription_ledger_credit_invoice_writes") -or
    (Get-JsonBool -Json $Artifact -Name "refusal_no_ledger_credit_invoice_refund_writes") -or
    (Get-JsonBool -Json $Artifact -Name "refusal_no_ledger_or_credit_grant_writes") -or
    (Get-JsonBool -Json $Artifact -Name "refusal_no_write_readback_passed") -or
    (Get-JsonBool -Json $Artifact -Name "conflict_no_duplicate_write_readback_passed")

  return [ordered]@{
    schema = $schema -in @("subscription_package_lifecycle_contract.v1", "subscription_package_lifecycle_runtime.v1", "subscription_package_lifecycle.v1")
    status_pass = $status -in @("pass", "passed", "verified")
    contract_runtime_false = if ($schema -eq "subscription_package_lifecycle_contract.v1") { -not (Get-JsonBool -Json $Artifact -Name "runtime_implemented" -Default $true) } else { $true }
    contract_only_true = if ($schema -eq "subscription_package_lifecycle_contract.v1") { Get-JsonBool -Json $Artifact -Name "contract_only" } else { $true }
    money_decimal_strings = Get-JsonBool -Json $Artifact -Name "money_decimal_strings"
    idempotency_contract = $idempotencyContract
    plan_package_lifecycle = $planPackageLifecycle
    subscription_states = $subscriptionStates
    credit_or_ledger_effect_contract = $creditOrLedgerEffect
    invoice_order_linkage_contract = $invoiceOrderLinkage
    refusal_no_writes_contract = $refusalNoWrites
    direct_wallet_snapshot_mutation_forbidden = Get-JsonBool -Json $Artifact -Name "direct_wallet_snapshot_mutation_forbidden"
    audit_required = Get-JsonBool -Json $Artifact -Name "audit_required"
    secret_safe = Get-JsonBool -Json $Artifact -Name "secret_safe"
    paid_gate_unchanged = -not (Get-JsonBool -Json $Artifact -Name "paid_gate_changed" -Default $true)
    runtime_implemented = Get-JsonBool -Json $Artifact -Name "runtime_implemented"
    contract_only_false = -not (Get-JsonBool -Json $Artifact -Name "contract_only" -Default $true)
    route_or_internal_runtime_invoked = $routeOrRuntimeInvoked
    plan_package_crud_readback_passed = $planPackageReadback
    subscription_lifecycle_readback_passed = $subscriptionLifecycleReadback
    subscription_state_transitions_readback_passed = Get-JsonBool -Json $Artifact -Name "subscription_state_transitions_readback_passed"
    trial_proration_dunning_readback_passed = $trialProrationDunningReadback
    credit_or_ledger_readback_passed = $creditOrLedgerReadback
    invoice_order_readback_passed = $invoiceOrderReadback
    idempotency_replay_readback_passed = Get-JsonBool -Json $Artifact -Name "idempotency_replay_readback_passed"
    conflict_no_duplicate_write_readback_passed = Get-JsonBool -Json $Artifact -Name "conflict_no_duplicate_write_readback_passed"
    refusal_no_write_readback_passed = Get-JsonBool -Json $Artifact -Name "refusal_no_write_readback_passed"
    audit_readback_passed = Get-JsonBool -Json $Artifact -Name "audit_readback_passed"
    renewal_readback_passed = Get-JsonBool -Json $Artifact -Name "renewal_readback_passed"
    cancel_pause_resume_readback_passed = Get-JsonBool -Json $Artifact -Name "cancel_pause_resume_readback_passed"
    runtime_verified = Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $Artifact
  }
}

function Invoke-SelfTest {
  $completeSchema = @"
create table if not exists wallets (
  id uuid primary key,
  balance_floor numeric(20, 8) not null default 0,
  status text not null
);
create table if not exists credit_grants (
  id uuid primary key,
  remaining_amount numeric(20, 8) not null,
  valid_from timestamptz not null,
  valid_until timestamptz null,
  status text not null,
  source text not null
);
create table if not exists ledger_entries (
  id uuid primary key,
  status text not null,
  source text null
);
"@
  $missingRemaining = $completeSchema -replace "\s*remaining_amount numeric\(20, 8\) not null,", ""
  $completeOpeningImportSchema = @"
create table if not exists opening_balance_imports (
  id uuid primary key,
  tenant_id uuid not null,
  wallet_id uuid not null,
  currency text not null,
  opening_amount numeric(20, 8) not null,
  external_source text not null,
  external_reference_id text not null,
  idempotency_key text not null,
  status text not null,
  ledger_entry_id uuid not null,
  audit_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, idempotency_key),
  unique (tenant_id, external_source, external_reference_id)
);
"@
  $missingExternalUniqueOpeningImportSchema = $completeOpeningImportSchema -replace "\s*unique \(tenant_id, external_source, external_reference_id\)", ""
  $completeContract = @"
# TODO-32 Credit / Wallet Productization Contract Draft

- Money values MUST be decimal strings with explicit currency.
- Every write endpoint MUST require an idempotency key.
- Every write endpoint MUST emit audit metadata with actor_id and actor_type.
- API responses MUST provide secret-safe output and include secret_safe.
- Wallet snapshots are read models only. They MUST NOT directly mutate wallet snapshot balance.

## POST /billing/credit-grants
## GET /billing/credit-grants
## POST /billing/credit-grants/{credit_grant_id}/expire
## POST /billing/credit-grants/{credit_grant_id}/revoke
## GET /billing/wallets/{wallet_id}/remaining-balance
wallet_available_balance active_credit_grant_total pending_reserve_total confirmed_ledger_effect available_to_spend
## POST /billing/opening-balance-imports
Opening balance import MUST write an opening ledger entry or admin adjustment entry.
## POST /billing/admin-adjustments
"@
  $missingEndpointContract = $completeContract -replace "## GET /billing/wallets/\{wallet_id\}/remaining-balance", "## GET /billing/wallets/{wallet_id}/summary"
  $completeOpenApi = @"
paths:
  /admin/wallets:
    get:
      operationId: listAdminWallets
      description: Read-only tenant-scoped wallet/credit surface. Money fields are fixed-decimal strings. It must not expose Authorization/Cookie headers, provider keys, virtual keys, DB URLs, or credential material.
      responses:
        '200':
          content:
            application/json:
              schema:
                `$ref: '#/components/schemas/AdminWalletCreditSurfaceListEnvelope'
  /admin/wallets/{wallet_id}:
    get:
      operationId: getAdminWallet
      description: This endpoint is contract-only until the Control Plane implementation lands.
      responses:
        '200':
          content:
            application/json:
              schema:
                `$ref: '#/components/schemas/AdminWalletCreditSurfaceEnvelope'
components:
  schemas:
    AdminWalletCreditSurfaceListEnvelope:
      type: object
    AdminWalletCreditSurfaceEnvelope:
      type: object
    AdminWalletCreditSurface:
      required: [wallet, credit_grants, ledger_balance_window, pending_reserves, budget_remaining, consistency, secret_safe, read_only]
      properties:
        wallet:
          `$ref: '#/components/schemas/AdminWalletSummary'
        credit_grants:
          `$ref: '#/components/schemas/AdminWalletCreditGrantSummary'
        ledger_balance_window:
          `$ref: '#/components/schemas/AdminWalletLedgerBalanceWindow'
        pending_reserves:
          `$ref: '#/components/schemas/AdminWalletPendingReserveSummary'
        budget_remaining:
          `$ref: '#/components/schemas/AdminWalletBudgetRemainingMarker'
        consistency:
          `$ref: '#/components/schemas/AdminWalletConsistencyMarker'
        secret_safe:
          `$ref: '#/components/schemas/AdminWalletSecretSafeMarker'
        read_only:
          type: boolean
    AdminWalletSummary: {}
    AdminWalletCreditGrantSummary: {}
    AdminWalletLedgerBalanceWindow: {}
    AdminWalletPendingReserveSummary: {}
    AdminWalletBudgetRemainingMarker: {}
    AdminWalletConsistencyMarker: {}
    AdminWalletSecretSafeMarker: {}
  /billing/opening-balance-imports:
    post:
      operationId: createOpeningBalanceImport
      description: Admin/RBAC protected opening balance import boundary. This write endpoint requires an idempotency key. Current Control Plane runtime is contract-only and returns 501. Future runtime must write an opening ledger entry or admin adjustment entry; it must not directly mutate wallet snapshot balance. Raw import payloads, bearer/session material, DB URLs, provider keys, virtual keys, and raw idempotency material are forbidden.
      requestBody:
        content:
          application/json:
            schema:
              `$ref: '#/components/schemas/OpeningBalanceImportRequest'
      responses:
        '200':
          content:
            application/json:
              schema:
                `$ref: '#/components/schemas/OpeningBalanceImportEnvelope'
        '501':
          content:
            application/json:
              schema:
                `$ref: '#/components/schemas/OpeningBalanceImportContractOnlyEnvelope'
    OpeningBalanceImportRequest: {}
    OpeningBalanceImportEnvelope: {}
    OpeningBalanceImportContractOnlyEnvelope: {}
    OpeningBalanceImportResult:
      properties:
        schema_version:
          enum: [opening_balance_import_contract.v1]
"@
  $missingAdminWalletsOpenApi = $completeOpenApi -replace "(?m)^\s*/admin/wallets:\s*\r?\n", ""
  $missingOpeningImportOpenApi = $completeOpenApi -replace "(?m)^\s*/billing/opening-balance-imports:\s*\r?\n", ""
  $passChecks = Test-SchemaSurface -SchemaText $completeSchema
  $missingChecks = Test-SchemaSurface -SchemaText $missingRemaining
  $openingSchemaPassChecks = Test-OpeningBalanceImportSchemaSurface -SchemaText $completeOpeningImportSchema
  $openingSchemaMissingChecks = Test-OpeningBalanceImportSchemaSurface -SchemaText $missingExternalUniqueOpeningImportSchema
  $contractPassChecks = Test-CreditWalletContractSurface -ContractText $completeContract
  $contractMissingChecks = Test-CreditWalletContractSurface -ContractText $missingEndpointContract
  $openApiPassChecks = Test-AdminReadonlyOpenApiSurface -OpenApiText $completeOpenApi
  $openApiMissingChecks = Test-AdminReadonlyOpenApiSurface -OpenApiText $missingAdminWalletsOpenApi
  $openingApiPassChecks = Test-OpeningBalanceImportApiSurface -OpenApiText $completeOpenApi
  $openingApiMissingChecks = Test-OpeningBalanceImportApiSurface -OpenApiText $missingOpeningImportOpenApi
  $billingArtifactPositive = [pscustomobject]@{
    schema = "billing_mutation_contract_tests.v1"
    status = "pass"
    money_decimal_strings = $true
    idempotency_contract = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    runtime_writer_changed = $false
    paid_gate_changed = $false
    invariants_enforced = @(
      "accounting_marker_required_for_mutations",
      "idempotent_replay_vs_conflict_refusal",
      "secret_safe_summary",
      "direct_wallet_snapshot_mutation_forbidden"
    )
  }
  $billingArtifactPending = [pscustomobject]@{
    schema = "billing_mutation_contract_tests.v1"
    status = "pending"
    money_decimal_strings = $true
    idempotency_contract = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    runtime_writer_changed = $false
    paid_gate_changed = $false
    invariants_enforced = $billingArtifactPositive.invariants_enforced
  }
  $billingArtifactSecretUnsafe = [pscustomobject]@{
    schema = "billing_mutation_contract_tests.v1"
    status = "pass"
    money_decimal_strings = $true
    idempotency_contract = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $false
    runtime_writer_changed = $false
    paid_gate_changed = $false
    invariants_enforced = $billingArtifactPositive.invariants_enforced
  }
  $billingArtifactPaidGateChanged = [pscustomobject]@{
    schema = "billing_mutation_contract_tests.v1"
    status = "pass"
    money_decimal_strings = $true
    idempotency_contract = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    runtime_writer_changed = $false
    paid_gate_changed = $true
    invariants_enforced = $billingArtifactPositive.invariants_enforced
  }
  $openingArtifactPositive = [pscustomobject]@{
    schema = "opening_balance_import_contract.v1"
    status = "pass"
    secret_safe = $true
    money_decimal_strings = $true
    idempotency_contract = $true
    opening_ledger_entry_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    paid_gate_changed = $false
    runtime_implemented = $false
  }
  $openingArtifactRuntimePositive = [pscustomobject]@{
    schema = "opening_balance_import_runtime.v1"
    status = "pass"
    secret_safe = $true
    money_decimal_strings = $true
    idempotency_contract = $true
    opening_ledger_entry_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    paid_gate_changed = $false
    runtime_implemented = $true
    internal_rust_function_invoked = $true
    contract_only = $false
    endpoint = "/billing/opening-balance-imports"
    opening_import_id = "opening-import-test"
    ledger_entry_id = "ledger-entry-test"
    admin_adjustment_entry_id = ""
    audit_id = "audit-test"
    live_db_readback_passed = $true
    opening_import_readback_passed = $true
    ledger_entry_readback_passed = $true
    audit_readback_passed = $true
    replay_readback_passed = $true
    refusal_readback_passed = $true
    rollback_readback_passed = $true
  }
  $openingArtifactRuntimePsqlPlanOnly = [pscustomobject]@{
    schema = "opening_balance_import_runtime.v1"
    overall_status = "pass"
    secret_safe = $true
    money_decimal_strings = $true
    idempotency_contract = $true
    opening_ledger_entry_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    paid_gate_changed = $false
    runtime_implemented = $true
    contract_only = $false
    endpoint = "/billing/opening-balance-imports"
    db_runner_implemented = $true
    executable_db_plan = [pscustomobject]@{
      ran = $true
      passed = $true
      route_invoked = $false
    }
    opening_import_id = "opening-import-test"
    ledger_entry_id = "ledger-entry-test"
    audit_id = "audit-test"
    live_db_readback_passed = $true
    opening_import_readback_passed = $true
    ledger_entry_readback_passed = $true
    audit_readback_passed = $true
    replay_readback_passed = $true
    refusal_readback_passed = $true
    rollback_readback_passed = $true
  }
  $openingArtifactRuntimePartialDbPlanOnly = [pscustomobject]@{
    schema = "opening_balance_import_runtime.v1"
    overall_status = "partial"
    secret_safe = $true
    paid_gate_changed = $false
    runtime_implemented = $false
    contract_only = $true
    db_integration_ran = $true
    db_runner_implemented = $true
    route_invoked = $false
    executable_db_plan = [pscustomobject]@{
      ran = $true
      passed = $true
      route_invoked = $false
      result = [pscustomobject]@{
        secret_safe = $true
        db_plan_executed = $true
        apply_readback_passed = $true
        audit_readback_passed = $true
        runtime_route_invoked = $false
        transaction_rolled_back = $true
        replay_same_key_body_passed = $true
        ledger_entry_readback_passed = $true
        idempotency_conflict_refusal_passed = $true
        external_reference_conflict_refusal_passed = $true
        wallet_currency_refusal_no_ledger_write_plan_passed = $true
      }
    }
    blockers = @(
      "opening_balance_import_public_route_not_wired",
      "opening_balance_import_internal_rust_function_not_invoked_by_verifier"
    )
  }
  $openingArtifactRuntimeMissingReadback = [pscustomobject]@{
    schema = "opening_balance_import_runtime.v1"
    status = "pass"
    secret_safe = $true
    money_decimal_strings = $true
    idempotency_contract = $true
    opening_ledger_entry_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    paid_gate_changed = $false
    runtime_implemented = $true
    contract_only = $false
    endpoint = "/billing/opening-balance-imports"
    opening_import_id = "opening-import-test"
    ledger_entry_id = "ledger-entry-test"
    audit_id = "audit-test"
    live_db_readback_passed = $false
    opening_import_readback_passed = $false
    ledger_entry_readback_passed = $true
    audit_readback_passed = $true
    replay_readback_passed = $true
    refusal_readback_passed = $true
    rollback_readback_passed = $true
  }
  $openingArtifactSecretUnsafe = [pscustomobject]@{
    schema = "opening_balance_import_contract.v1"
    status = "pass"
    secret_safe = $false
    money_decimal_strings = $true
    idempotency_contract = $true
    opening_ledger_entry_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    paid_gate_changed = $false
    runtime_implemented = $false
  }
  $openingArtifactPaidGateChanged = [pscustomobject]@{
    schema = "opening_balance_import_contract.v1"
    status = "pass"
    secret_safe = $true
    money_decimal_strings = $true
    idempotency_contract = $true
    opening_ledger_entry_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    paid_gate_changed = $true
    runtime_implemented = $false
  }
  $openingArtifactDirectWalletAllowed = [pscustomobject]@{
    schema = "opening_balance_import_contract.v1"
    status = "pass"
    secret_safe = $true
    money_decimal_strings = $true
    idempotency_contract = $true
    opening_ledger_entry_required = $true
    direct_wallet_snapshot_mutation_forbidden = $false
    paid_gate_changed = $false
    runtime_implemented = $false
  }
  $creditGrantCrudContractPositive = [pscustomobject]@{
    schema = "credit_grant_crud_contract.v1"
    status = "pass"
    money_decimal_strings = $true
    idempotency_contract = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
    runtime_implemented = $false
    contract_only = $true
  }
  $creditGrantCrudRuntimePositive = [pscustomobject]@{
    schema = "credit_grant_crud_runtime.v1"
    status = "pass"
    money_decimal_strings = $true
    idempotency_contract = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
    runtime_implemented = $true
    internal_sqlx_function_invoked = $true
    contract_only = $false
    endpoint = "/billing/credit-grants"
    credit_grant_id = "credit-grant-test"
    audit_id = "audit-test"
    create_readback_passed = $true
    list_readback_passed = $true
    read_readback_passed = $true
    expire_readback_passed = $true
    status_readback_passed = $true
    replay_readback_passed = $true
    conflict_or_refusal_no_write_passed = $true
    audit_readback_passed = $true
  }
  $creditGrantCrudSecretUnsafe = [pscustomobject]@{
    schema = "credit_grant_crud_contract.v1"
    status = "pass"
    money_decimal_strings = $true
    idempotency_contract = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $false
    paid_gate_changed = $false
  }
  $creditGrantCrudPaidGateChanged = [pscustomobject]@{
    schema = "credit_grant_crud_contract.v1"
    status = "pass"
    money_decimal_strings = $true
    idempotency_contract = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $true
  }
  $creditGrantCrudRuntimeMissingAudit = [pscustomobject]@{
    schema = "credit_grant_crud_runtime.v1"
    status = "pass"
    money_decimal_strings = $true
    idempotency_contract = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
    runtime_implemented = $true
    internal_sqlx_function_invoked = $true
    contract_only = $false
    endpoint = "/billing/credit-grants"
    credit_grant_id = "credit-grant-test"
    audit_id = ""
    create_readback_passed = $true
    list_readback_passed = $true
    read_readback_passed = $true
    expire_readback_passed = $true
    status_readback_passed = $true
    replay_readback_passed = $true
    conflict_or_refusal_no_write_passed = $true
    audit_readback_passed = $false
  }
  $userRemainingBalanceContractPositive = [pscustomobject]@{
    schema = "user_remaining_balance_contract.v1"
    status = "pass"
    money_decimal_strings = $true
    read_only = $true
    secret_safe = $true
    paid_gate_changed = $false
    runtime_implemented = $false
  }
  $userRemainingBalanceRuntimeNotAccepted = [pscustomobject]@{
    schema = "user_remaining_balance_contract.v1"
    status = "pass"
    money_decimal_strings = $true
    read_only = $true
    secret_safe = $true
    paid_gate_changed = $false
    runtime_implemented = $true
  }
  $userRemainingBalanceSecretUnsafe = [pscustomobject]@{
    schema = "user_remaining_balance_contract.v1"
    status = "pass"
    money_decimal_strings = $true
    read_only = $true
    secret_safe = $false
    paid_gate_changed = $false
    runtime_implemented = $false
  }
  $userRemainingBalanceAdminRuntimePositive = [pscustomobject]@{
    schema = "user_remaining_balance_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    route_invoked = $true
    public_route_invoked = $true
    read_only = $true
    admin_readonly_runtime = $true
    user_api_runtime = $false
    tenant_id = "tenant-test"
    wallet_id = "wallet-test"
    currency = "USD"
    available_to_spend = "125.00000000"
    active_credit_grant_total = "150.00000000"
    pending_confirmed_ledger_window = "-15.00000000"
    wallet_balance_floor = "10.00000000"
    wallet_readback_passed = $true
    credit_grants_readback_passed = $true
    ledger_window_readback_passed = $true
    refusal_readback_passed = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $userRemainingBalanceAdminRuntimeMissingReadback = [pscustomobject]@{
    schema = "user_remaining_balance_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    route_invoked = $true
    public_route_invoked = $true
    read_only = $true
    admin_readonly_runtime = $true
    user_api_runtime = $false
    tenant_id = "tenant-test"
    wallet_id = "wallet-test"
    currency = "USD"
    available_to_spend = "125.00000000"
    active_credit_grant_total = "150.00000000"
    pending_confirmed_ledger_window = "-15.00000000"
    wallet_balance_floor = "10.00000000"
    wallet_readback_passed = $true
    credit_grants_readback_passed = $false
    ledger_window_readback_passed = $true
    refusal_readback_passed = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $userRemainingBalanceAdminRuntimeSecretUnsafe = [pscustomobject]@{
    schema = "user_remaining_balance_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    route_invoked = $true
    public_route_invoked = $true
    read_only = $true
    admin_readonly_runtime = $true
    user_api_runtime = $false
    tenant_id = "tenant-test"
    wallet_id = "wallet-test"
    currency = "USD"
    available_to_spend = "125.00000000"
    active_credit_grant_total = "150.00000000"
    pending_confirmed_ledger_window = "-15.00000000"
    wallet_balance_floor = "10.00000000"
    wallet_readback_passed = $true
    credit_grants_readback_passed = $true
    ledger_window_readback_passed = $true
    refusal_readback_passed = $true
    secret_safe = $false
    paid_gate_changed = $false
  }
  $userRemainingBalanceAdminRuntimePaidGateChanged = [pscustomobject]@{
    schema = "user_remaining_balance_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    route_invoked = $true
    public_route_invoked = $true
    read_only = $true
    admin_readonly_runtime = $true
    user_api_runtime = $false
    tenant_id = "tenant-test"
    wallet_id = "wallet-test"
    currency = "USD"
    available_to_spend = "125.00000000"
    active_credit_grant_total = "150.00000000"
    pending_confirmed_ledger_window = "-15.00000000"
    wallet_balance_floor = "10.00000000"
    wallet_readback_passed = $true
    credit_grants_readback_passed = $true
    ledger_window_readback_passed = $true
    refusal_readback_passed = $true
    secret_safe = $true
    paid_gate_changed = $true
  }
  $userRemainingBalanceUserRuntimeMissingOwnershipScope = [pscustomobject]@{
    schema = "user_remaining_balance_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    route_invoked = $true
    public_route_invoked = $true
    read_only = $true
    admin_readonly_runtime = $false
    user_api_runtime = $true
    authenticated_ownership_scope = $false
    ownership_scope_verified = $false
    developer_token_ownership_scope = $false
    tenant_id = "tenant-test"
    wallet_id = "wallet-test"
    currency = "USD"
    available_to_spend = "125.00000000"
    active_credit_grant_total = "150.00000000"
    pending_confirmed_ledger_window = "-15.00000000"
    wallet_balance_floor = "10.00000000"
    wallet_readback_passed = $true
    credit_grants_readback_passed = $true
    ledger_window_readback_passed = $true
    refusal_readback_passed = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $rechargeVoucherContractPositive = [pscustomobject]@{
    schema = "recharge_voucher_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    money_decimal_strings = $true
    voucher_code_hashed_or_redacted = $true
    redeem_idempotency_contract = $true
    abuse_guard_contract = $true
    ledger_or_credit_effect_contract = $true
    refusal_no_ledger_or_credit_grant_writes = $true
    refund_cancel_reversal_required = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
    raw_voucher_code_echoed = $false
  }
  $rechargeVoucherRuntimeMarker = [pscustomobject]@{
    schema = "recharge_voucher_contract.v1"
    status = "pass"
    runtime_implemented = $true
    contract_only = $false
    money_decimal_strings = $true
    voucher_code_hashed_or_redacted = $true
    redeem_idempotency_contract = $true
    abuse_guard_contract = $true
    ledger_or_credit_effect_contract = $true
    refusal_no_ledger_or_credit_grant_writes = $true
    refund_cancel_reversal_required = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
    raw_voucher_code_echoed = $false
  }
  $rechargeVoucherRuntimePositive = [pscustomobject]@{
    schema = "recharge_voucher_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    control_plane_route_invoked = $true
    money_decimal_strings = $true
    voucher_storage_readback_passed = $true
    voucher_code_hash_readback_passed = $true
    voucher_code_redacted_output = $true
    redeem_readback_passed = $true
    redeem_idempotency_readback_passed = $true
    abuse_refusal_no_write_readback_passed = $true
    ledger_or_credit_readback_passed = $true
    refund_cancel_reversal_readback_passed = $true
    audit_required = $true
    audit_readback_passed = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
    raw_voucher_code_echoed = $false
  }
  $rechargeVoucherRuntimeMissingReadback = [pscustomobject]@{
    schema = "recharge_voucher_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    control_plane_route_invoked = $true
    money_decimal_strings = $true
    voucher_storage_readback_passed = $true
    voucher_code_hash_readback_passed = $true
    voucher_code_redacted_output = $true
    redeem_readback_passed = $true
    redeem_idempotency_readback_passed = $false
    abuse_refusal_no_write_readback_passed = $true
    ledger_or_credit_readback_passed = $true
    refund_cancel_reversal_readback_passed = $true
    audit_required = $true
    audit_readback_passed = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
    raw_voucher_code_echoed = $false
  }
  $rechargeVoucherRuntimeMissingRoute = [pscustomobject]@{
    schema = "recharge_voucher_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    control_plane_route_invoked = $false
    runtime_route_invoked = $false
    internal_sqlx_function_invoked = $false
    money_decimal_strings = $true
    voucher_storage_readback_passed = $true
    voucher_code_hash_readback_passed = $true
    voucher_code_redacted_output = $true
    redeem_readback_passed = $true
    redeem_idempotency_readback_passed = $true
    abuse_refusal_no_write_readback_passed = $true
    ledger_or_credit_readback_passed = $true
    refund_cancel_reversal_readback_passed = $true
    audit_required = $true
    audit_readback_passed = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
    raw_voucher_code_echoed = $false
  }
  $rechargeVoucherRuntimeMissingVoucherHash = [pscustomobject]@{
    schema = "recharge_voucher_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    control_plane_route_invoked = $true
    money_decimal_strings = $true
    voucher_storage_readback_passed = $true
    voucher_code_hash_readback_passed = $false
    voucher_code_redacted_output = $true
    redeem_readback_passed = $true
    redeem_idempotency_readback_passed = $true
    abuse_refusal_no_write_readback_passed = $true
    ledger_or_credit_readback_passed = $true
    refund_cancel_reversal_readback_passed = $true
    audit_required = $true
    audit_readback_passed = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
    raw_voucher_code_echoed = $false
  }
  $rechargeVoucherSecretUnsafe = [pscustomobject]@{
    schema = "recharge_voucher_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    money_decimal_strings = $true
    voucher_code_hashed_or_redacted = $true
    redeem_idempotency_contract = $true
    abuse_guard_contract = $true
    ledger_or_credit_effect_contract = $true
    refusal_no_ledger_or_credit_grant_writes = $true
    refund_cancel_reversal_required = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $false
    paid_gate_changed = $false
    raw_voucher_code_echoed = $false
  }
  $rechargeVoucherPaidGateChanged = [pscustomobject]@{
    schema = "recharge_voucher_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    money_decimal_strings = $true
    voucher_code_hashed_or_redacted = $true
    redeem_idempotency_contract = $true
    abuse_guard_contract = $true
    ledger_or_credit_effect_contract = $true
    refusal_no_ledger_or_credit_grant_writes = $true
    refund_cancel_reversal_required = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $true
    raw_voucher_code_echoed = $false
  }
  $rechargeVoucherRawCodeUnsafe = [pscustomobject]@{
    schema = "recharge_voucher_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    money_decimal_strings = $true
    voucher_code_hashed_or_redacted = $true
    redeem_idempotency_contract = $true
    abuse_guard_contract = $true
    ledger_or_credit_effect_contract = $true
    refusal_no_ledger_or_credit_grant_writes = $true
    refund_cancel_reversal_required = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
    raw_voucher_code = "unsafe-raw-code"
    raw_voucher_code_echoed = $true
  }
  $paymentOrderInvoiceContractPositive = [pscustomobject]@{
    schema = "payment_order_invoice_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    money_decimal_strings = $true
    provider_handoff_secret_safe = $true
    capture_ledger_or_credit_effect_contract = $true
    replay_idempotency_contract = $true
    invoice_receipt_contract = $true
    refusal_no_ledger_credit_invoice_refund_writes = $true
    refund_cancel_reversal_required = $true
    reconciliation_contract = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $paymentOrderInvoiceSecretUnsafe = [pscustomobject]@{
    schema = "payment_order_invoice_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    money_decimal_strings = $true
    provider_handoff_secret_safe = $true
    capture_ledger_or_credit_effect_contract = $true
    replay_idempotency_contract = $true
    invoice_receipt_contract = $true
    refusal_no_ledger_credit_invoice_refund_writes = $true
    refund_cancel_reversal_required = $true
    reconciliation_contract = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $false
    paid_gate_changed = $false
  }
  $paymentOrderInvoicePaidGateChanged = [pscustomobject]@{
    schema = "payment_order_invoice_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    money_decimal_strings = $true
    provider_handoff_secret_safe = $true
    capture_ledger_or_credit_effect_contract = $true
    replay_idempotency_contract = $true
    invoice_receipt_contract = $true
    refusal_no_ledger_credit_invoice_refund_writes = $true
    refund_cancel_reversal_required = $true
    reconciliation_contract = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $true
  }
  $paymentOrderInvoiceRuntimeMarker = [pscustomobject]@{
    schema = "payment_order_invoice_contract.v1"
    status = "pass"
    runtime_implemented = $true
    contract_only = $false
    money_decimal_strings = $true
    provider_handoff_secret_safe = $true
    capture_ledger_or_credit_effect_contract = $true
    replay_idempotency_contract = $true
    invoice_receipt_contract = $true
    refusal_no_ledger_credit_invoice_refund_writes = $true
    refund_cancel_reversal_required = $true
    reconciliation_contract = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $paymentOrderInvoiceRuntimePositive = [pscustomobject]@{
    schema = "payment_order_invoice_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    control_plane_route_invoked = $true
    money_decimal_strings = $true
    provider_handoff_readback_passed = $true
    provider_handoff_redacted_output = $true
    payment_callback_readback_passed = $true
    order_lifecycle_readback_passed = $true
    payment_confirm_capture_readback_passed = $true
    invoice_readback_passed = $true
    invoice_receipt_readback_passed = $true
    ledger_or_credit_readback_passed = $true
    idempotency_replay_readback_passed = $true
    conflict_no_duplicate_write_readback_passed = $true
    refund_cancel_chargeback_reversal_readback_passed = $true
    reconciliation_readback_passed = $true
    audit_required = $true
    audit_readback_passed = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $paymentOrderInvoiceRuntimeMissingReconciliation = [pscustomobject]@{
    schema = "payment_order_invoice_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    control_plane_route_invoked = $true
    money_decimal_strings = $true
    provider_handoff_readback_passed = $true
    provider_handoff_redacted_output = $true
    payment_callback_readback_passed = $true
    order_lifecycle_readback_passed = $true
    payment_confirm_capture_readback_passed = $true
    invoice_readback_passed = $true
    invoice_receipt_readback_passed = $true
    ledger_or_credit_readback_passed = $true
    idempotency_replay_readback_passed = $true
    conflict_no_duplicate_write_readback_passed = $true
    refund_cancel_chargeback_reversal_readback_passed = $true
    reconciliation_readback_passed = $false
    audit_required = $true
    audit_readback_passed = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $paymentOrderInvoiceMissingInvoiceReconciliation = [pscustomobject]@{
    schema = "payment_order_invoice_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    money_decimal_strings = $true
    provider_handoff_secret_safe = $true
    capture_ledger_or_credit_effect_contract = $true
    replay_idempotency_contract = $true
    invoice_receipt_contract = $false
    refusal_no_ledger_credit_invoice_refund_writes = $true
    refund_cancel_reversal_required = $true
    reconciliation_contract = $false
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $paymentOrderInvoiceRuntimePositive = [pscustomobject]@{
    schema = "payment_order_invoice_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    route_invoked = $true
    money_decimal_strings = $true
    order_lifecycle_readback_passed = $true
    provider_handoff_readback_passed = $true
    provider_handoff_redacted_output = $true
    provider_callback_readback_passed = $true
    payment_confirm_capture_readback_passed = $true
    invoice_readback_passed = $true
    invoice_receipt_readback_passed = $true
    ledger_or_credit_readback_passed = $true
    idempotency_replay_readback_passed = $true
    conflict_no_duplicate_write_readback_passed = $true
    audit_required = $true
    audit_readback_passed = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    reconciliation_readback_passed = $true
    refund_cancel_chargeback_reversal_readback_passed = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $paymentOrderInvoiceRuntimeMissingProviderCallback = [pscustomobject]@{
    schema = "payment_order_invoice_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    route_invoked = $true
    money_decimal_strings = $true
    order_lifecycle_readback_passed = $true
    provider_handoff_readback_passed = $false
    provider_handoff_redacted_output = $true
    provider_callback_readback_passed = $false
    payment_callback_readback_passed = $false
    payment_confirm_capture_readback_passed = $true
    invoice_readback_passed = $true
    invoice_receipt_readback_passed = $true
    ledger_or_credit_readback_passed = $true
    idempotency_replay_readback_passed = $true
    conflict_no_duplicate_write_readback_passed = $true
    audit_required = $true
    audit_readback_passed = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    reconciliation_readback_passed = $true
    refund_cancel_chargeback_reversal_readback_passed = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $paymentOrderInvoiceRuntimeMissingInvoiceReceipt = [pscustomobject]@{
    schema = "payment_order_invoice_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    route_invoked = $true
    money_decimal_strings = $true
    order_lifecycle_readback_passed = $true
    provider_handoff_readback_passed = $true
    provider_handoff_redacted_output = $true
    provider_callback_readback_passed = $true
    payment_confirm_capture_readback_passed = $true
    invoice_readback_passed = $false
    invoice_receipt_readback_passed = $false
    ledger_or_credit_readback_passed = $true
    idempotency_replay_readback_passed = $true
    conflict_no_duplicate_write_readback_passed = $true
    audit_required = $true
    audit_readback_passed = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    reconciliation_readback_passed = $true
    refund_cancel_chargeback_reversal_readback_passed = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $paymentOrderInvoiceRuntimeMissingReconciliation = [pscustomobject]@{
    schema = "payment_order_invoice_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    route_invoked = $true
    money_decimal_strings = $true
    order_lifecycle_readback_passed = $true
    provider_handoff_readback_passed = $true
    provider_handoff_redacted_output = $true
    provider_callback_readback_passed = $true
    payment_confirm_capture_readback_passed = $true
    invoice_readback_passed = $true
    invoice_receipt_readback_passed = $true
    ledger_or_credit_readback_passed = $true
    idempotency_replay_readback_passed = $true
    conflict_no_duplicate_write_readback_passed = $true
    audit_required = $true
    audit_readback_passed = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    reconciliation_readback_passed = $false
    refund_cancel_chargeback_reversal_readback_passed = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $paymentOrderInvoiceRuntimeMissingIdempotencyNoDuplicate = [pscustomobject]@{
    schema = "payment_order_invoice_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    route_invoked = $true
    money_decimal_strings = $true
    order_lifecycle_readback_passed = $true
    provider_handoff_readback_passed = $true
    provider_handoff_redacted_output = $true
    provider_callback_readback_passed = $true
    payment_confirm_capture_readback_passed = $true
    invoice_readback_passed = $true
    invoice_receipt_readback_passed = $true
    ledger_or_credit_readback_passed = $true
    idempotency_replay_readback_passed = $false
    conflict_no_duplicate_write_readback_passed = $false
    audit_required = $true
    audit_readback_passed = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    reconciliation_readback_passed = $true
    refund_cancel_chargeback_reversal_readback_passed = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  function New-SubscriptionPackageRuntimeSelfTestArtifact {
    param([hashtable]$Override = @{})

    $artifact = [ordered]@{
      schema = "subscription_package_lifecycle_runtime.v1"
      overall_status = "pass"
      runtime_implemented = $true
      contract_only = $false
      route_invoked = $true
      money_decimal_strings = $true
      replay_idempotency_contract = $true
      plan_package_lifecycle_contract = $true
      subscription_states_contract = $true
      subscription_credit_effect_contract = $true
      invoice_order_linkage_contract = $true
      refusal_no_subscription_ledger_credit_invoice_writes = $true
      direct_wallet_snapshot_mutation_forbidden = $true
      audit_required = $true
      secret_safe = $true
      paid_gate_changed = $false
      plan_package_crud_readback_passed = $true
      provider_handoff_readback_passed = $true
      plan_package_readback_passed = $true
      subscription_lifecycle_readback_passed = $true
      subscription_readback_passed = $true
      subscription_state_transitions_readback_passed = $true
      trial_proration_dunning_readback_passed = $true
      trial_readback_passed = $true
      proration_readback_passed = $true
      invoice_order_readback_passed = $true
      invoice_readback_passed = $true
      order_readback_passed = $true
      credit_or_ledger_readback_passed = $true
      idempotency_replay_readback_passed = $true
      conflict_no_duplicate_write_readback_passed = $true
      refusal_no_write_readback_passed = $true
      audit_readback_passed = $true
      dunning_readback_passed = $true
      renewal_readback_passed = $true
      cancel_pause_resume_readback_passed = $true
    }
    foreach ($key in $Override.Keys) {
      $artifact[$key] = $Override[$key]
    }
    return [pscustomobject]$artifact
  }

  $subscriptionPackageRuntimePositive = [pscustomobject]@{
    schema = "subscription_package_lifecycle_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    route_invoked = $true
    money_decimal_strings = $true
    replay_idempotency_contract = $true
    plan_package_lifecycle_contract = $true
    subscription_states_contract = $true
    subscription_credit_effect_contract = $true
    invoice_order_linkage_contract = $true
    refusal_no_subscription_ledger_credit_invoice_writes = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    audit_required = $true
    secret_safe = $true
    paid_gate_changed = $false
    provider_handoff_readback_passed = $true
    plan_package_crud_readback_passed = $true
    plan_package_readback_passed = $true
    subscription_lifecycle_readback_passed = $true
    subscription_readback_passed = $true
    subscription_state_transitions_readback_passed = $true
    trial_proration_dunning_readback_passed = $true
    trial_readback_passed = $true
    proration_readback_passed = $true
    dunning_readback_passed = $true
    invoice_order_readback_passed = $true
    invoice_readback_passed = $true
    order_readback_passed = $true
    credit_or_ledger_readback_passed = $true
    idempotency_replay_readback_passed = $true
    conflict_no_duplicate_write_readback_passed = $true
    refusal_no_write_readback_passed = $true
    audit_readback_passed = $true
    renewal_readback_passed = $true
    cancel_pause_resume_readback_passed = $true
  }
  $subscriptionPackageRuntimeMissingPlanPackage = New-SubscriptionPackageRuntimeSelfTestArtifact -Override @{
    plan_package_readback_passed = $false
    plan_package_crud_readback_passed = $false
  }
  $subscriptionPackageRuntimeMissingSubscriptionState = New-SubscriptionPackageRuntimeSelfTestArtifact -Override @{
    subscription_readback_passed = $false
    subscription_lifecycle_readback_passed = $false
    subscription_state_transitions_readback_passed = $false
  }
  $subscriptionPackageRuntimeMissingCreditLedgerEffect = New-SubscriptionPackageRuntimeSelfTestArtifact -Override @{
    credit_or_ledger_readback_passed = $false
  }
  $subscriptionPackageRuntimeMissingInvoiceOrder = New-SubscriptionPackageRuntimeSelfTestArtifact -Override @{
    invoice_order_readback_passed = $false
    invoice_readback_passed = $false
    order_readback_passed = $false
  }
  $subscriptionPackageRuntimeMissingRefusal = New-SubscriptionPackageRuntimeSelfTestArtifact -Override @{
    refusal_no_write_readback_passed = $false
    conflict_no_duplicate_write_readback_passed = $false
  }
  $subscriptionPackageRuntimeMissingAudit = New-SubscriptionPackageRuntimeSelfTestArtifact -Override @{
    audit_readback_passed = $false
  }
  $subscriptionPackageRuntimeMissingTrialDunning = New-SubscriptionPackageRuntimeSelfTestArtifact -Override @{
    trial_proration_dunning_readback_passed = $false
    trial_readback_passed = $false
    proration_readback_passed = $false
    dunning_readback_passed = $false
  }
  $subscriptionPackageRuntimeMissingIdempotency = New-SubscriptionPackageRuntimeSelfTestArtifact -Override @{
    idempotency_replay_readback_passed = $false
  }
  $subscriptionPackageRuntimeMissingCancelPauseResume = New-SubscriptionPackageRuntimeSelfTestArtifact -Override @{
    cancel_pause_resume_readback_passed = $false
  }
  $subscriptionPackageRuntimeSecretUnsafe = New-SubscriptionPackageRuntimeSelfTestArtifact -Override @{
    secret_safe = $false
  }

  $subscriptionPackageContractPositive = [pscustomobject]@{
    schema = "subscription_package_lifecycle_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    money_decimal_strings = $true
    replay_idempotency_contract = $true
    plan_package_lifecycle_contract = $true
    subscription_states_contract = $true
    subscription_credit_effect_contract = $true
    invoice_order_linkage_contract = $true
    refusal_no_subscription_ledger_credit_invoice_writes = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    audit_required = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $subscriptionPackageSecretUnsafe = [pscustomobject]@{
    schema = "subscription_package_lifecycle_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    money_decimal_strings = $true
    replay_idempotency_contract = $true
    plan_package_lifecycle_contract = $true
    subscription_states_contract = $true
    subscription_credit_effect_contract = $true
    invoice_order_linkage_contract = $true
    refusal_no_subscription_ledger_credit_invoice_writes = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    audit_required = $true
    secret_safe = $false
    paid_gate_changed = $false
  }
  $subscriptionPackagePaidGateChanged = [pscustomobject]@{
    schema = "subscription_package_lifecycle_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    money_decimal_strings = $true
    replay_idempotency_contract = $true
    plan_package_lifecycle_contract = $true
    subscription_states_contract = $true
    subscription_credit_effect_contract = $true
    invoice_order_linkage_contract = $true
    refusal_no_subscription_ledger_credit_invoice_writes = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    audit_required = $true
    secret_safe = $true
    paid_gate_changed = $true
  }
  $subscriptionPackageRuntimeMarker = [pscustomobject]@{
    schema = "subscription_package_lifecycle_contract.v1"
    status = "pass"
    runtime_implemented = $true
    contract_only = $false
    money_decimal_strings = $true
    replay_idempotency_contract = $true
    plan_package_lifecycle_contract = $true
    subscription_states_contract = $true
    subscription_credit_effect_contract = $true
    invoice_order_linkage_contract = $true
    refusal_no_subscription_ledger_credit_invoice_writes = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    audit_required = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $subscriptionPackageMissingCreditInvoice = [pscustomobject]@{
    schema = "subscription_package_lifecycle_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    money_decimal_strings = $true
    replay_idempotency_contract = $true
    plan_package_lifecycle_contract = $true
    subscription_states_contract = $true
    subscription_credit_effect_contract = $false
    invoice_order_linkage_contract = $false
    refusal_no_subscription_ledger_credit_invoice_writes = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    audit_required = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $passCase = -not (@($passChecks.GetEnumerator() | Where-Object { -not $_.Value }).Count -gt 0)
  $missingRejected = -not [bool]$missingChecks.remaining_amount
  $openingSchemaPassCase = -not (@($openingSchemaPassChecks.GetEnumerator() | Where-Object { -not $_.Value }).Count -gt 0)
  $openingSchemaMissingRejected = -not [bool]$openingSchemaMissingChecks.unique_tenant_external_reference
  $contractPassCase = -not (@($contractPassChecks.GetEnumerator() | Where-Object { -not $_.Value }).Count -gt 0)
  $contractMissingRejected = -not [bool]$contractMissingChecks.endpoint_remaining_balance
  $openApiPassCase = -not (@($openApiPassChecks.GetEnumerator() | Where-Object { -not $_.Value }).Count -gt 0)
  $openApiMissingRejected = -not [bool]$openApiMissingChecks.path_list_admin_wallets
  $openingApiPassCase = -not (@($openingApiPassChecks.GetEnumerator() | Where-Object { -not $_.Value }).Count -gt 0)
  $openingApiMissingRejected = -not [bool]$openingApiMissingChecks.path_opening_balance_import
  $runtimeAbsentNotVerified = -not (Test-AdminReadonlyRuntimeArtifact -Artifact $null)
  $billingArtifactPositiveAccepted = Test-BillingMutationArtifact -Artifact $billingArtifactPositive
  $billingMalformedRejected = -not (Test-BillingMutationArtifact -Artifact $null)
  $billingPendingRejected = -not (Test-BillingMutationArtifact -Artifact $billingArtifactPending)
  $billingSecretUnsafeRejected = -not (Test-BillingMutationArtifact -Artifact $billingArtifactSecretUnsafe)
  $billingPaidGateChangedRejected = -not (Test-BillingMutationArtifact -Artifact $billingArtifactPaidGateChanged)
  $openingArtifactPositiveAccepted = Test-OpeningBalanceImportArtifact -Artifact $openingArtifactPositive
  $openingMissingNotVerified = -not (Test-OpeningBalanceImportArtifact -Artifact $null)
  $openingSecretUnsafeRejected = -not (Test-OpeningBalanceImportArtifact -Artifact $openingArtifactSecretUnsafe)
  $openingPaidGateChangedRejected = -not (Test-OpeningBalanceImportArtifact -Artifact $openingArtifactPaidGateChanged)
  $openingDirectWalletAllowedRejected = -not (Test-OpeningBalanceImportArtifact -Artifact $openingArtifactDirectWalletAllowed)
  $openingRuntimeFalseWhenMarkerFalse = -not (Test-OpeningBalanceImportRuntimeArtifact -Artifact $openingArtifactPositive)
  $openingRuntimePositiveAccepted = Test-OpeningBalanceImportRuntimeArtifact -Artifact $openingArtifactRuntimePositive
  $openingRuntimePsqlPlanOnlyRejected = -not (Test-OpeningBalanceImportRuntimeArtifact -Artifact $openingArtifactRuntimePsqlPlanOnly)
  $openingRuntimePartialDbPlanOnlyRejected = -not (Test-OpeningBalanceImportRuntimeArtifact -Artifact $openingArtifactRuntimePartialDbPlanOnly)
  $openingRuntimeMissingReadbackRejected = -not (Test-OpeningBalanceImportRuntimeArtifact -Artifact $openingArtifactRuntimeMissingReadback)
  $creditGrantCrudContractPositiveAccepted = Test-CreditGrantCrudArtifact -Artifact $creditGrantCrudContractPositive
  $creditGrantCrudContractNotRuntime = -not (Test-CreditGrantCrudRuntimeArtifact -Artifact $creditGrantCrudContractPositive)
  $creditGrantCrudRuntimePositiveAccepted = Test-CreditGrantCrudRuntimeArtifact -Artifact $creditGrantCrudRuntimePositive
  $creditGrantCrudSecretUnsafeRejected = -not (Test-CreditGrantCrudArtifact -Artifact $creditGrantCrudSecretUnsafe)
  $creditGrantCrudPaidGateChangedRejected = -not (Test-CreditGrantCrudArtifact -Artifact $creditGrantCrudPaidGateChanged)
  $creditGrantCrudRuntimeMissingAuditRejected = -not (Test-CreditGrantCrudRuntimeArtifact -Artifact $creditGrantCrudRuntimeMissingAudit)
  $userRemainingBalanceContractPositiveAccepted = Test-UserRemainingBalanceArtifact -Artifact $userRemainingBalanceContractPositive
  $userRemainingBalanceRuntimeRejected = -not (Test-UserRemainingBalanceArtifact -Artifact $userRemainingBalanceRuntimeNotAccepted)
  $userRemainingBalanceSecretUnsafeRejected = -not (Test-UserRemainingBalanceArtifact -Artifact $userRemainingBalanceSecretUnsafe)
  $userRemainingBalanceAdminRuntimeAccepted = Test-UserRemainingBalanceAdminRuntimeArtifact -Artifact $userRemainingBalanceAdminRuntimePositive
  $userRemainingBalanceAdminRuntimeNotFullRuntime = -not (Test-UserRemainingBalanceRuntimeArtifact -Artifact $userRemainingBalanceAdminRuntimePositive)
  $userRemainingBalanceAdminRuntimeMissingReadbackRejected = -not (Test-UserRemainingBalanceAdminRuntimeArtifact -Artifact $userRemainingBalanceAdminRuntimeMissingReadback)
  $userRemainingBalanceAdminRuntimeSecretUnsafeRejected = -not (Test-UserRemainingBalanceAdminRuntimeArtifact -Artifact $userRemainingBalanceAdminRuntimeSecretUnsafe)
  $userRemainingBalanceAdminRuntimePaidGateChangedRejected = -not (Test-UserRemainingBalanceAdminRuntimeArtifact -Artifact $userRemainingBalanceAdminRuntimePaidGateChanged)
  $userRemainingBalanceUserRuntimeMissingOwnershipRejected = -not (Test-UserRemainingBalanceRuntimeArtifact -Artifact $userRemainingBalanceUserRuntimeMissingOwnershipScope)
  $rechargeVoucherContractPositiveAccepted = Test-RechargeVoucherArtifact -Artifact $rechargeVoucherContractPositive
  $rechargeVoucherRuntimeMarkerRejected = -not (Test-RechargeVoucherArtifact -Artifact $rechargeVoucherRuntimeMarker)
  $rechargeVoucherContractNotRuntime = -not (Test-RechargeVoucherRuntimeArtifact -Artifact $rechargeVoucherContractPositive)
  $rechargeVoucherRuntimePositiveAccepted = Test-RechargeVoucherRuntimeArtifact -Artifact $rechargeVoucherRuntimePositive
  $rechargeVoucherRuntimeMissingReadbackRejected = -not (Test-RechargeVoucherRuntimeArtifact -Artifact $rechargeVoucherRuntimeMissingReadback)
  $rechargeVoucherRuntimeMissingRouteRejected = -not (Test-RechargeVoucherRuntimeArtifact -Artifact $rechargeVoucherRuntimeMissingRoute)
  $rechargeVoucherRuntimeMissingVoucherHashRejected = -not (Test-RechargeVoucherRuntimeArtifact -Artifact $rechargeVoucherRuntimeMissingVoucherHash)
  $rechargeVoucherSecretUnsafeRejected = -not (Test-RechargeVoucherArtifact -Artifact $rechargeVoucherSecretUnsafe)
  $rechargeVoucherPaidGateChangedRejected = -not (Test-RechargeVoucherArtifact -Artifact $rechargeVoucherPaidGateChanged)
  $rechargeVoucherRawCodeUnsafeRejected = -not (Test-RechargeVoucherArtifact -Artifact $rechargeVoucherRawCodeUnsafe)
  $paymentOrderInvoiceContractPositiveAccepted = Test-PaymentOrderInvoiceArtifact -Artifact $paymentOrderInvoiceContractPositive
  $paymentOrderInvoiceSecretUnsafeRejected = -not (Test-PaymentOrderInvoiceArtifact -Artifact $paymentOrderInvoiceSecretUnsafe)
  $paymentOrderInvoicePaidGateChangedRejected = -not (Test-PaymentOrderInvoiceArtifact -Artifact $paymentOrderInvoicePaidGateChanged)
  $paymentOrderInvoiceRuntimeMarkerRejected = -not (Test-PaymentOrderInvoiceRuntimeArtifact -Artifact $paymentOrderInvoiceRuntimeMarker)
  $paymentOrderInvoiceContractNotRuntime = -not (Test-PaymentOrderInvoiceRuntimeArtifact -Artifact $paymentOrderInvoiceContractPositive)
  $paymentOrderInvoiceRuntimePositiveAccepted = Test-PaymentOrderInvoiceRuntimeArtifact -Artifact $paymentOrderInvoiceRuntimePositive
  $paymentOrderInvoiceRuntimeMissingProviderCallbackRejected = -not (Test-PaymentOrderInvoiceRuntimeArtifact -Artifact $paymentOrderInvoiceRuntimeMissingProviderCallback)
  $paymentOrderInvoiceRuntimeMissingInvoiceReceiptRejected = -not (Test-PaymentOrderInvoiceRuntimeArtifact -Artifact $paymentOrderInvoiceRuntimeMissingInvoiceReceipt)
  $paymentOrderInvoiceRuntimeMissingReconciliationRejected = -not (Test-PaymentOrderInvoiceRuntimeArtifact -Artifact $paymentOrderInvoiceRuntimeMissingReconciliation)
  $paymentOrderInvoiceRuntimeMissingIdempotencyNoDuplicateRejected = -not (Test-PaymentOrderInvoiceRuntimeArtifact -Artifact $paymentOrderInvoiceRuntimeMissingIdempotencyNoDuplicate)
  $paymentOrderInvoiceMissingInvoiceReconciliationRejected = -not (Test-PaymentOrderInvoiceArtifact -Artifact $paymentOrderInvoiceMissingInvoiceReconciliation)
  $subscriptionPackageContractPositiveAccepted = Test-SubscriptionPackageLifecycleArtifact -Artifact $subscriptionPackageContractPositive
  $subscriptionPackageSecretUnsafeRejected = -not (Test-SubscriptionPackageLifecycleArtifact -Artifact $subscriptionPackageSecretUnsafe)
  $subscriptionPackagePaidGateChangedRejected = -not (Test-SubscriptionPackageLifecycleArtifact -Artifact $subscriptionPackagePaidGateChanged)
  $subscriptionPackageRuntimeMarkerRejected = -not (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageRuntimeMarker)
  $subscriptionPackageContractNotRuntime = -not (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageContractPositive)
  $subscriptionPackageMissingCreditInvoiceRejected = -not (Test-SubscriptionPackageLifecycleArtifact -Artifact $subscriptionPackageMissingCreditInvoice)
  $subscriptionPackageRuntimePositiveAccepted = Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageRuntimePositive
  $subscriptionPackageRuntimeMissingPlanPackageRejected = -not (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageRuntimeMissingPlanPackage)
  $subscriptionPackageRuntimeMissingSubscriptionStateRejected = -not (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageRuntimeMissingSubscriptionState)
  $subscriptionPackageRuntimeMissingCreditLedgerEffectRejected = -not (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageRuntimeMissingCreditLedgerEffect)
  $subscriptionPackageRuntimeMissingInvoiceOrderRejected = -not (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageRuntimeMissingInvoiceOrder)
  $subscriptionPackageRuntimeMissingRefusalRejected = -not (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageRuntimeMissingRefusal)
  $subscriptionPackageRuntimeMissingAuditRejected = -not (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageRuntimeMissingAudit)
  $subscriptionPackageRuntimeMissingTrialDunningRejected = -not (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageRuntimeMissingTrialDunning)
  $subscriptionPackageRuntimeMissingIdempotencyRejected = -not (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageRuntimeMissingIdempotency)
  $subscriptionPackageRuntimeMissingCancelPauseResumeRejected = -not (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageRuntimeMissingCancelPauseResume)
  $subscriptionPackageRuntimeSecretUnsafeRejected = -not (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageRuntimeSecretUnsafe)
  $actualExitCode = if ($passCase -and $missingRejected -and $openingSchemaPassCase -and $openingSchemaMissingRejected -and $contractPassCase -and $contractMissingRejected -and $openApiPassCase -and $openApiMissingRejected -and $openingApiPassCase -and $openingApiMissingRejected -and $runtimeAbsentNotVerified -and $billingArtifactPositiveAccepted -and $billingMalformedRejected -and $billingPendingRejected -and $billingSecretUnsafeRejected -and $billingPaidGateChangedRejected -and $openingArtifactPositiveAccepted -and $openingMissingNotVerified -and $openingSecretUnsafeRejected -and $openingPaidGateChangedRejected -and $openingDirectWalletAllowedRejected -and $openingRuntimeFalseWhenMarkerFalse -and $openingRuntimePositiveAccepted -and $openingRuntimePsqlPlanOnlyRejected -and $openingRuntimePartialDbPlanOnlyRejected -and $openingRuntimeMissingReadbackRejected -and $creditGrantCrudContractPositiveAccepted -and $creditGrantCrudContractNotRuntime -and $creditGrantCrudRuntimePositiveAccepted -and $creditGrantCrudSecretUnsafeRejected -and $creditGrantCrudPaidGateChangedRejected -and $creditGrantCrudRuntimeMissingAuditRejected -and $userRemainingBalanceContractPositiveAccepted -and $userRemainingBalanceRuntimeRejected -and $userRemainingBalanceSecretUnsafeRejected -and $userRemainingBalanceAdminRuntimeAccepted -and $userRemainingBalanceAdminRuntimeNotFullRuntime -and $userRemainingBalanceAdminRuntimeMissingReadbackRejected -and $userRemainingBalanceAdminRuntimeSecretUnsafeRejected -and $userRemainingBalanceAdminRuntimePaidGateChangedRejected -and $userRemainingBalanceUserRuntimeMissingOwnershipRejected -and $rechargeVoucherContractPositiveAccepted -and $rechargeVoucherRuntimeMarkerRejected -and $rechargeVoucherContractNotRuntime -and $rechargeVoucherRuntimePositiveAccepted -and $rechargeVoucherRuntimeMissingReadbackRejected -and $rechargeVoucherRuntimeMissingRouteRejected -and $rechargeVoucherRuntimeMissingVoucherHashRejected -and $rechargeVoucherSecretUnsafeRejected -and $rechargeVoucherPaidGateChangedRejected -and $rechargeVoucherRawCodeUnsafeRejected -and $paymentOrderInvoiceContractPositiveAccepted -and $paymentOrderInvoiceSecretUnsafeRejected -and $paymentOrderInvoicePaidGateChangedRejected -and $paymentOrderInvoiceRuntimeMarkerRejected -and $paymentOrderInvoiceContractNotRuntime -and $paymentOrderInvoiceRuntimePositiveAccepted -and $paymentOrderInvoiceRuntimeMissingProviderCallbackRejected -and $paymentOrderInvoiceRuntimeMissingInvoiceReceiptRejected -and $paymentOrderInvoiceRuntimeMissingReconciliationRejected -and $paymentOrderInvoiceRuntimeMissingIdempotencyNoDuplicateRejected -and $paymentOrderInvoiceMissingInvoiceReconciliationRejected -and $subscriptionPackageContractPositiveAccepted -and $subscriptionPackageSecretUnsafeRejected -and $subscriptionPackagePaidGateChangedRejected -and $subscriptionPackageRuntimeMarkerRejected -and $subscriptionPackageContractNotRuntime -and $subscriptionPackageMissingCreditInvoiceRejected -and $subscriptionPackageRuntimePositiveAccepted -and $subscriptionPackageRuntimeMissingPlanPackageRejected -and $subscriptionPackageRuntimeMissingSubscriptionStateRejected -and $subscriptionPackageRuntimeMissingCreditLedgerEffectRejected -and $subscriptionPackageRuntimeMissingInvoiceOrderRejected -and $subscriptionPackageRuntimeMissingRefusalRejected -and $subscriptionPackageRuntimeMissingAuditRejected -and $subscriptionPackageRuntimeMissingTrialDunningRejected -and $subscriptionPackageRuntimeMissingIdempotencyRejected -and $subscriptionPackageRuntimeMissingCancelPauseResumeRejected -and $subscriptionPackageRuntimeSecretUnsafeRejected) { 0 } else { 1 }

  [ordered]@{
    schema = "credit_wallet_ledger_surface_selftest_v1"
    overall_status = if ($actualExitCode -eq 0) { "pass" } else { "fail" }
    actual_exit_code = $actualExitCode
    cases = @(
      [ordered]@{ name = "complete_schema"; status = if ($passCase) { "pass" } else { "fail" } },
      [ordered]@{ name = "missing_remaining_amount_rejected"; status = if ($missingRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "opening_balance_import_schema_positive_verified"; status = if ($openingSchemaPassCase) { "pass" } else { "fail" } },
      [ordered]@{ name = "opening_balance_import_schema_missing_external_unique_rejected"; status = if ($openingSchemaMissingRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "complete_credit_wallet_contract"; status = if ($contractPassCase) { "pass" } else { "fail" } },
      [ordered]@{ name = "missing_remaining_balance_endpoint_rejected"; status = if ($contractMissingRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "complete_admin_readonly_openapi_contract"; status = if ($openApiPassCase) { "pass" } else { "fail" } },
      [ordered]@{ name = "missing_admin_wallets_path_rejected"; status = if ($openApiMissingRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "complete_opening_balance_import_api_contract"; status = if ($openingApiPassCase) { "pass" } else { "fail" } },
      [ordered]@{ name = "missing_opening_balance_import_api_path_rejected"; status = if ($openingApiMissingRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "runtime_artifact_absent_not_runtime_verified"; status = if ($runtimeAbsentNotVerified) { "pass" } else { "fail" } },
      [ordered]@{ name = "billing_mutation_artifact_positive_accepted"; status = if ($billingArtifactPositiveAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "billing_mutation_artifact_malformed_rejected"; status = if ($billingMalformedRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "billing_mutation_artifact_pending_rejected"; status = if ($billingPendingRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "billing_mutation_artifact_secret_unsafe_rejected"; status = if ($billingSecretUnsafeRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "billing_mutation_artifact_paid_gate_changed_rejected"; status = if ($billingPaidGateChangedRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "opening_balance_import_artifact_positive_accepted"; status = if ($openingArtifactPositiveAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "opening_balance_import_artifact_missing_not_verified"; status = if ($openingMissingNotVerified) { "pass" } else { "fail" } },
      [ordered]@{ name = "opening_balance_import_artifact_secret_unsafe_rejected"; status = if ($openingSecretUnsafeRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "opening_balance_import_artifact_paid_gate_changed_rejected"; status = if ($openingPaidGateChangedRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "opening_balance_import_artifact_direct_wallet_mutation_allowed_rejected"; status = if ($openingDirectWalletAllowedRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "opening_balance_import_runtime_false_when_marker_false"; status = if ($openingRuntimeFalseWhenMarkerFalse) { "pass" } else { "fail" } },
      [ordered]@{ name = "opening_balance_import_runtime_positive_live_readback_accepted"; status = if ($openingRuntimePositiveAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "opening_balance_import_runtime_psql_plan_only_rejected"; status = if ($openingRuntimePsqlPlanOnlyRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "opening_balance_import_runtime_partial_db_plan_only_rejected"; status = if ($openingRuntimePartialDbPlanOnlyRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "opening_balance_import_runtime_missing_live_readback_rejected"; status = if ($openingRuntimeMissingReadbackRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "credit_grant_crud_contract_positive_accepted"; status = if ($creditGrantCrudContractPositiveAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "credit_grant_crud_contract_not_runtime_verified"; status = if ($creditGrantCrudContractNotRuntime) { "pass" } else { "fail" } },
      [ordered]@{ name = "credit_grant_crud_runtime_positive_accepted"; status = if ($creditGrantCrudRuntimePositiveAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "credit_grant_crud_secret_unsafe_rejected"; status = if ($creditGrantCrudSecretUnsafeRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "credit_grant_crud_paid_gate_changed_rejected"; status = if ($creditGrantCrudPaidGateChangedRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "credit_grant_crud_runtime_missing_audit_rejected"; status = if ($creditGrantCrudRuntimeMissingAuditRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "user_remaining_balance_contract_positive_accepted"; status = if ($userRemainingBalanceContractPositiveAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "user_remaining_balance_runtime_marker_rejected"; status = if ($userRemainingBalanceRuntimeRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "user_remaining_balance_secret_unsafe_rejected"; status = if ($userRemainingBalanceSecretUnsafeRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "user_remaining_balance_admin_runtime_partial_accepted"; status = if ($userRemainingBalanceAdminRuntimeAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "user_remaining_balance_admin_runtime_not_full_runtime"; status = if ($userRemainingBalanceAdminRuntimeNotFullRuntime) { "pass" } else { "fail" } },
      [ordered]@{ name = "user_remaining_balance_admin_runtime_missing_readback_rejected"; status = if ($userRemainingBalanceAdminRuntimeMissingReadbackRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "user_remaining_balance_admin_runtime_secret_unsafe_rejected"; status = if ($userRemainingBalanceAdminRuntimeSecretUnsafeRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "user_remaining_balance_admin_runtime_paid_gate_changed_rejected"; status = if ($userRemainingBalanceAdminRuntimePaidGateChangedRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "user_remaining_balance_user_runtime_missing_ownership_scope_rejected"; status = if ($userRemainingBalanceUserRuntimeMissingOwnershipRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "recharge_voucher_contract_positive_accepted"; status = if ($rechargeVoucherContractPositiveAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "recharge_voucher_runtime_marker_rejected"; status = if ($rechargeVoucherRuntimeMarkerRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "recharge_voucher_contract_not_runtime_verified"; status = if ($rechargeVoucherContractNotRuntime) { "pass" } else { "fail" } },
      [ordered]@{ name = "recharge_voucher_runtime_positive_accepted"; status = if ($rechargeVoucherRuntimePositiveAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "recharge_voucher_runtime_missing_readback_rejected"; status = if ($rechargeVoucherRuntimeMissingReadbackRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "recharge_voucher_runtime_missing_route_rejected"; status = if ($rechargeVoucherRuntimeMissingRouteRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "recharge_voucher_runtime_missing_voucher_hash_rejected"; status = if ($rechargeVoucherRuntimeMissingVoucherHashRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "recharge_voucher_secret_unsafe_rejected"; status = if ($rechargeVoucherSecretUnsafeRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "recharge_voucher_paid_gate_changed_rejected"; status = if ($rechargeVoucherPaidGateChangedRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "recharge_voucher_raw_code_unsafe_rejected"; status = if ($rechargeVoucherRawCodeUnsafeRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "payment_order_invoice_contract_positive_accepted"; status = if ($paymentOrderInvoiceContractPositiveAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "payment_order_invoice_secret_unsafe_rejected"; status = if ($paymentOrderInvoiceSecretUnsafeRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "payment_order_invoice_paid_gate_changed_rejected"; status = if ($paymentOrderInvoicePaidGateChangedRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "payment_order_invoice_runtime_false_not_runtime_verified"; status = if ($paymentOrderInvoiceRuntimeMarkerRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "payment_order_invoice_contract_not_runtime_verified"; status = if ($paymentOrderInvoiceContractNotRuntime) { "pass" } else { "fail" } },
      [ordered]@{ name = "payment_order_invoice_runtime_positive_accepted"; status = if ($paymentOrderInvoiceRuntimePositiveAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "payment_order_invoice_runtime_missing_provider_callback_rejected"; status = if ($paymentOrderInvoiceRuntimeMissingProviderCallbackRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "payment_order_invoice_runtime_missing_invoice_receipt_rejected"; status = if ($paymentOrderInvoiceRuntimeMissingInvoiceReceiptRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "payment_order_invoice_runtime_missing_reconciliation_rejected"; status = if ($paymentOrderInvoiceRuntimeMissingReconciliationRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "payment_order_invoice_runtime_missing_idempotency_no_duplicate_rejected"; status = if ($paymentOrderInvoiceRuntimeMissingIdempotencyNoDuplicateRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "payment_order_invoice_missing_invoice_reconciliation_rejected"; status = if ($paymentOrderInvoiceMissingInvoiceReconciliationRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_contract_positive_accepted"; status = if ($subscriptionPackageContractPositiveAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_secret_unsafe_rejected"; status = if ($subscriptionPackageSecretUnsafeRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_paid_gate_changed_rejected"; status = if ($subscriptionPackagePaidGateChangedRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_runtime_false_not_runtime_verified"; status = if ($subscriptionPackageRuntimeMarkerRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_contract_not_runtime_verified"; status = if ($subscriptionPackageContractNotRuntime) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_missing_credit_invoice_linkage_rejected"; status = if ($subscriptionPackageMissingCreditInvoiceRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_runtime_positive_accepted"; status = if ($subscriptionPackageRuntimePositiveAccepted) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_runtime_missing_plan_package_rejected"; status = if ($subscriptionPackageRuntimeMissingPlanPackageRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_runtime_missing_subscription_state_rejected"; status = if ($subscriptionPackageRuntimeMissingSubscriptionStateRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_runtime_missing_credit_ledger_effect_rejected"; status = if ($subscriptionPackageRuntimeMissingCreditLedgerEffectRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_runtime_missing_invoice_order_rejected"; status = if ($subscriptionPackageRuntimeMissingInvoiceOrderRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_runtime_missing_refusal_rejected"; status = if ($subscriptionPackageRuntimeMissingRefusalRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_runtime_missing_audit_rejected"; status = if ($subscriptionPackageRuntimeMissingAuditRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_runtime_missing_trial_dunning_rejected"; status = if ($subscriptionPackageRuntimeMissingTrialDunningRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_runtime_missing_idempotency_rejected"; status = if ($subscriptionPackageRuntimeMissingIdempotencyRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_runtime_missing_cancel_pause_resume_rejected"; status = if ($subscriptionPackageRuntimeMissingCancelPauseResumeRejected) { "pass" } else { "fail" } },
      [ordered]@{ name = "subscription_package_runtime_secret_unsafe_rejected"; status = if ($subscriptionPackageRuntimeSecretUnsafeRejected) { "pass" } else { "fail" } }
    )
  } | ConvertTo-Json -Depth 8
  exit $actualExitCode
}

if ($SelfTest) {
  Invoke-SelfTest
}

$schemaReads = @()
$schemaText = ""
foreach ($path in $SchemaPaths) {
  $read = Read-RepoText -Path $path
  $schemaReads += [ordered]@{
    path = $read.path
    exists = $read.exists
  }
  $schemaText += "`n" + $read.text
}

$schemaChecks = Test-SchemaSurface -SchemaText $schemaText
$missingSchemaChecks = @($schemaChecks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
$openingBalanceImportSchemaChecks = Test-OpeningBalanceImportSchemaSurface -SchemaText $schemaText
$missingOpeningBalanceImportSchemaChecks = @($openingBalanceImportSchemaChecks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })

$gatewaySource = Read-RepoText -Path $GatewaySourcePath
$controlPlaneAdminSource = Read-RepoText -Path $ControlPlaneAdminPath
$gatewaySmoke = Read-RepoText -Path $GatewaySmokeScriptPath
$creditWalletContract = Read-RepoText -Path $CreditWalletContractPath
$adminOpenApi = Read-RepoText -Path $AdminOpenApiPath
$runtimeChecks = [ordered]@{
  gateway_balance_reads_wallets = [bool]([regex]::IsMatch($gatewaySource.text, "from\s+wallets\s+w", "IgnoreCase"))
  gateway_balance_reads_credit_grants = [bool]([regex]::IsMatch($gatewaySource.text, "from\s+credit_grants\s+cg", "IgnoreCase"))
  gateway_balance_reads_ledger_entries = [bool]([regex]::IsMatch($gatewaySource.text, "from\s+ledger_entries\s+le", "IgnoreCase"))
  gateway_balance_window_includes_credit_grants = [bool]([regex]::IsMatch($gatewaySource.text, "credit_balance\.amount\s*\+\s*ledger_balance\.amount\s*-\s*w\.balance_floor", "IgnoreCase"))
  paid_smoke_seeds_wallet = [bool]([regex]::IsMatch($gatewaySmoke.text, "insert\s+into\s+wallets", "IgnoreCase"))
  paid_smoke_seeds_credit_grant = [bool]([regex]::IsMatch($gatewaySmoke.text, "insert\s+into\s+credit_grants", "IgnoreCase"))
  paid_smoke_sets_remaining_amount = [bool]([regex]::IsMatch($gatewaySmoke.text, "\bremaining_amount\b", "IgnoreCase"))
  paid_smoke_sets_valid_window = [bool]([regex]::IsMatch($gatewaySmoke.text, "\bvalid_from\b.*\bvalid_until\b|\bvalid_until\b.*\bvalid_from\b", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline))
}
$missingRuntimeChecks = @($runtimeChecks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })

$negativeAmountGuardChecks = [ordered]@{
  source_path = $controlPlaneAdminSource.path
  source_exists = $controlPlaneAdminSource.exists
  normalize_function_present = [bool]([regex]::IsMatch($controlPlaneAdminSource.text, "fn\s+normalize_create_admin_credit_grant_request\b"))
  rejects_amount_less_than_or_equal_zero = [bool]([regex]::IsMatch($controlPlaneAdminSource.text, "parse_billing_fixed_decimal\(&amount\)\?\.units\(\)\s*<=\s*0"))
  minus_one_fixed_decimal_test_present = [bool]([regex]::IsMatch($controlPlaneAdminSource.text, 'amount:\s*"-1\.00000000"\.to_string\(\)|amount\s*=\s*"-1\.00000000"\.to_string\(\)|amount\s*=\s*"-1\.00000000"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -and [regex]::IsMatch($controlPlaneAdminSource.text, "normalize_create_admin_credit_grant_request"))
}
$negativeAmountGuardOk = [bool]($negativeAmountGuardChecks.rejects_amount_less_than_or_equal_zero -and $negativeAmountGuardChecks.minus_one_fixed_decimal_test_present)
$negativeAmountGuardBlocker = if ($negativeAmountGuardOk) {
  $null
} elseif (-not $negativeAmountGuardChecks.rejects_amount_less_than_or_equal_zero) {
  "credit_grant_negative_amount_not_refused"
} else {
  "credit_grant_negative_amount_minus_one_test_missing"
}

$contractChecks = Test-CreditWalletContractSurface -ContractText $creditWalletContract.text
$missingContractChecks = @($contractChecks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
$adminOpenApiChecks = Test-AdminReadonlyOpenApiSurface -OpenApiText $adminOpenApi.text
$missingAdminOpenApiChecks = @($adminOpenApiChecks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
$openingBalanceImportApiChecks = Test-OpeningBalanceImportApiSurface -OpenApiText $adminOpenApi.text
$missingOpeningBalanceImportApiChecks = @($openingBalanceImportApiChecks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })

$adminRuntimeArtifact = Get-FirstExistingJson -Paths $AdminReadonlyRuntimeArtifactPaths
$billingMutationArtifact = Get-FirstExistingJson -Paths $BillingMutationArtifactPaths
$openingBalanceImportArtifact = Get-FirstExistingJson -Paths $OpeningBalanceImportArtifactPaths
$creditGrantCrudRuntimeArtifact = Get-FirstExistingJson -Paths @($CreditGrantCrudArtifactPaths | Where-Object { $_ -match "runtime" })
$creditGrantCrudContractArtifact = Get-FirstExistingJson -Paths @($CreditGrantCrudArtifactPaths | Where-Object { $_ -match "contract" })
$creditGrantCrudArtifact = if ($creditGrantCrudRuntimeArtifact.found) { $creditGrantCrudRuntimeArtifact } else { $creditGrantCrudContractArtifact }
$userRemainingBalanceAdminRuntimeArtifact = Get-FirstExistingJson -Paths @($UserRemainingBalanceArtifactPaths | Where-Object { $_ -match "runtime|api" })
$userRemainingBalanceFullRuntimeArtifact = Get-FirstExistingJson -Paths $UserRemainingBalanceFullRuntimeArtifactPaths
$userRemainingBalanceContractArtifact = Get-FirstExistingJson -Paths @($UserRemainingBalanceArtifactPaths | Where-Object { $_ -match "contract" })
$userRemainingBalanceArtifact = if ($userRemainingBalanceFullRuntimeArtifact.found) { $userRemainingBalanceFullRuntimeArtifact } elseif ($userRemainingBalanceAdminRuntimeArtifact.found) { $userRemainingBalanceAdminRuntimeArtifact } else { $userRemainingBalanceContractArtifact }
$rechargeVoucherArtifact = Get-FirstExistingJson -Paths $RechargeVoucherArtifactPaths
$paymentOrderInvoiceRuntimeArtifact = Get-FirstExistingJson -Paths @($PaymentOrderInvoiceArtifactPaths | Where-Object { $_ -match "runtime" })
$paymentOrderInvoiceContractArtifact = Get-FirstExistingJson -Paths @($PaymentOrderInvoiceArtifactPaths | Where-Object { $_ -match "contract" })
$paymentOrderInvoiceArtifact = if ($paymentOrderInvoiceRuntimeArtifact.found) { $paymentOrderInvoiceRuntimeArtifact } else { $paymentOrderInvoiceContractArtifact }
$subscriptionPackageLifecycleRuntimeArtifact = Get-FirstExistingJson -Paths @($SubscriptionPackageLifecycleArtifactPaths | Where-Object { $_ -match "runtime" })
$subscriptionPackageLifecycleContractArtifact = Get-FirstExistingJson -Paths @($SubscriptionPackageLifecycleArtifactPaths | Where-Object { $_ -match "contract" })
$subscriptionPackageLifecycleArtifact = if ($subscriptionPackageLifecycleRuntimeArtifact.found) { $subscriptionPackageLifecycleRuntimeArtifact } else { $subscriptionPackageLifecycleContractArtifact }
$adminReadonlyRuntimeVerified = [bool]($adminRuntimeArtifact.found -and (Test-AdminReadonlyRuntimeArtifact -Artifact $adminRuntimeArtifact.selected.json))
$billingMutationArtifactVerified = [bool]($billingMutationArtifact.found -and (Test-BillingMutationArtifact -Artifact $billingMutationArtifact.selected.json))
$openingBalanceImportArtifactVerified = [bool]($openingBalanceImportArtifact.found -and (Test-OpeningBalanceImportArtifact -Artifact $openingBalanceImportArtifact.selected.json))
$openingBalanceImportRuntimeVerified = [bool]($openingBalanceImportArtifact.found -and (Test-OpeningBalanceImportRuntimeArtifact -Artifact $openingBalanceImportArtifact.selected.json))
$creditGrantCrudContractVerified = [bool]($creditGrantCrudContractArtifact.found -and (Test-CreditGrantCrudArtifact -Artifact $creditGrantCrudContractArtifact.selected.json))
$creditGrantCrudRuntimeVerified = [bool]($creditGrantCrudRuntimeArtifact.found -and (Test-CreditGrantCrudRuntimeArtifact -Artifact $creditGrantCrudRuntimeArtifact.selected.json))
$creditGrantCrudArtifactVerified = [bool]($creditGrantCrudContractVerified -or $creditGrantCrudRuntimeVerified)
$userRemainingBalanceContractVerified = [bool]($userRemainingBalanceContractArtifact.found -and (Test-UserRemainingBalanceArtifact -Artifact $userRemainingBalanceContractArtifact.selected.json))
$userRemainingBalanceAdminRuntimeVerified = [bool]($userRemainingBalanceAdminRuntimeArtifact.found -and (Test-UserRemainingBalanceAdminRuntimeArtifact -Artifact $userRemainingBalanceAdminRuntimeArtifact.selected.json))
$userRemainingBalanceRuntimeVerified = [bool]($userRemainingBalanceFullRuntimeArtifact.found -and (Test-UserRemainingBalanceRuntimeArtifact -Artifact $userRemainingBalanceFullRuntimeArtifact.selected.json))
$userRemainingBalanceArtifactVerified = [bool]($userRemainingBalanceContractVerified -or $userRemainingBalanceAdminRuntimeVerified -or $userRemainingBalanceRuntimeVerified)
$rechargeVoucherContractVerified = [bool]($rechargeVoucherArtifact.found -and (Test-RechargeVoucherArtifact -Artifact $rechargeVoucherArtifact.selected.json))
$rechargeVoucherRuntimeVerified = [bool]($rechargeVoucherArtifact.found -and (Test-RechargeVoucherRuntimeArtifact -Artifact $rechargeVoucherArtifact.selected.json))
$paymentOrderInvoiceContractVerified = [bool]($paymentOrderInvoiceContractArtifact.found -and (Test-PaymentOrderInvoiceArtifact -Artifact $paymentOrderInvoiceContractArtifact.selected.json))
$paymentOrderInvoiceRuntimeVerified = [bool]($paymentOrderInvoiceRuntimeArtifact.found -and (Test-PaymentOrderInvoiceRuntimeArtifact -Artifact $paymentOrderInvoiceRuntimeArtifact.selected.json))
$subscriptionPackageLifecycleContractVerified = [bool]($subscriptionPackageLifecycleContractArtifact.found -and (Test-SubscriptionPackageLifecycleArtifact -Artifact $subscriptionPackageLifecycleContractArtifact.selected.json))
$subscriptionPackageLifecycleRuntimeVerified = [bool]($subscriptionPackageLifecycleRuntimeArtifact.found -and (Test-SubscriptionPackageLifecycleRuntimeArtifact -Artifact $subscriptionPackageLifecycleRuntimeArtifact.selected.json))

$e8 = Read-RepoJson -Path $GatewayPaidHotPathArtifactPath
$e11 = Read-RepoJson -Path $ControlPlanePaidReadbackArtifactPath
$bundle = Read-RepoJson -Path $RealPaidEvidenceBundlePath

$e8Status = Get-JsonString -Json $e8.json -Name "status"
$e11Status = Get-JsonString -Json $e11.json -Name "overall_status"
$bundleStatus = Get-JsonString -Json $bundle.json -Name "overall_status"
$bundleReady = $false
if ($null -ne $bundle.json -and $bundle.json.PSObject.Properties.Name -contains "paid_controlled_beta_production_ready") {
  $bundleReady = [bool]$bundle.json.paid_controlled_beta_production_ready
}

$artifactChecks = [ordered]@{
  gateway_paid_hot_path_artifact = [ordered]@{
    path = $e8.path
    exists = $e8.exists
    status = $e8Status
    evidence_count = Get-JsonArrayCount -Json $e8.json -Name "evidence"
    request_id_count = Get-JsonArrayCount -Json $e8.json -Name "request_ids"
    operation_id_count = Get-JsonArrayCount -Json $e8.json -Name "operation_ids"
    verifies_paid_ledger_hot_path = [bool]($e8.exists -and $e8Status -eq "passed")
  }
  control_plane_paid_readback_artifact = [ordered]@{
    path = $e11.path
    exists = $e11.exists
    overall_status = $e11Status
    accepted_evidence_count = Get-JsonArrayCount -Json $e11.json -Name "accepted_evidence"
    verifies_ledger_readback = [bool]($e11.exists -and $e11Status -eq "passed")
  }
  real_paid_evidence_bundle = [ordered]@{
    path = $bundle.path
    exists = $bundle.exists
    overall_status = $bundleStatus
    evidence_count = Get-JsonArrayCount -Json $bundle.json -Name "evidence"
    paid_controlled_beta_production_ready = $bundleReady
    verifies_bundle_acceptance = [bool]($bundle.exists -and $bundleReady)
  }
}

$schemaPresent = ($missingSchemaChecks.Count -eq 0)
$runtimePresent = ($missingRuntimeChecks.Count -eq 0)
$paidArtifactsPass = [bool]($artifactChecks.gateway_paid_hot_path_artifact.verifies_paid_ledger_hot_path -and $artifactChecks.control_plane_paid_readback_artifact.verifies_ledger_readback -and $artifactChecks.real_paid_evidence_bundle.verifies_bundle_acceptance)

$capabilityVerdict = if ($schemaPresent -and $runtimePresent -and $paidArtifactsPass) {
  "present_verified"
} elseif ($schemaPresent -and $runtimePresent) {
  "present_partially_verified"
} else {
  "not_verified"
}

$blockers = @()
if (-not $schemaPresent) { $blockers += "schema_surface_missing:" + (($missingSchemaChecks | Sort-Object) -join ",") }
if (-not $runtimePresent) { $blockers += "runtime_or_smoke_surface_missing:" + (($missingRuntimeChecks | Sort-Object) -join ",") }
if (-not $paidArtifactsPass) { $blockers += "paid_artifact_readback_not_fully_verified" }
if ($creditWalletContract.exists -and $missingContractChecks.Count -gt 0) { $blockers += "credit_wallet_contract_surface_missing:" + (($missingContractChecks | Sort-Object) -join ",") }
if ($adminOpenApi.exists -and $missingAdminOpenApiChecks.Count -gt 0) { $blockers += "admin_readonly_openapi_contract_missing:" + (($missingAdminOpenApiChecks | Sort-Object) -join ",") }
if ($adminOpenApi.exists -and $missingOpeningBalanceImportApiChecks.Count -gt 0) { $blockers += "opening_balance_import_api_contract_missing:" + (($missingOpeningBalanceImportApiChecks | Sort-Object) -join ",") }
if ($negativeAmountGuardBlocker) { $blockers += $negativeAmountGuardBlocker }

$draftContractVerified = [bool]($creditWalletContract.exists -and $missingContractChecks.Count -eq 0)
$adminReadonlyOpenApiContractVerified = [bool]($adminOpenApi.exists -and $missingAdminOpenApiChecks.Count -eq 0)
$openingBalanceImportApiContractPresent = [bool]($adminOpenApi.exists -and $missingOpeningBalanceImportApiChecks.Count -eq 0)
$openingBalanceImportSchemaVerified = [bool]($missingOpeningBalanceImportSchemaChecks.Count -eq 0)
$billingMutationContractVerified = [bool]($draftContractVerified -and $contractChecks.endpoint_create_credit_grant -and $contractChecks.endpoint_expire_credit_grant -and $contractChecks.endpoint_revoke_credit_grant -and $contractChecks.endpoint_opening_balance_import -and $contractChecks.endpoint_admin_adjustments -and $contractChecks.write_idempotency_required -and $contractChecks.audit_metadata_required -and $contractChecks.direct_wallet_snapshot_mutation_forbidden)
$openingBalanceImportContractVerified = [bool]($draftContractVerified -and $contractChecks.endpoint_opening_balance_import -and $contractChecks.opening_import_ledger_entry_required -and $contractChecks.write_idempotency_required -and $contractChecks.direct_wallet_snapshot_mutation_forbidden)

$overallStatus = if ($capabilityVerdict -eq "not_verified") { "fail" } else { "pass_with_productization_gaps" }
$actualExitCode = if ($overallStatus -eq "fail") { 1 } else { 0 }

[ordered]@{
  schema = "credit_wallet_ledger_surface_v1"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  overall_status = $overallStatus
  actual_exit_code = $actualExitCode
  schema_files = $schemaReads
  schema_checks = $schemaChecks
  opening_balance_import_schema_checks = [ordered]@{
    status = if ($openingBalanceImportSchemaVerified) { "opening_balance_import_schema_verified" } else { "opening_balance_import_schema_missing_or_incomplete" }
    verified = $openingBalanceImportSchemaVerified
    checks = $openingBalanceImportSchemaChecks
    missing_checks = $missingOpeningBalanceImportSchemaChecks
  }
  runtime_code_checks = $runtimeChecks
  negative_amount_guard = [ordered]@{
    status = if ($negativeAmountGuardOk) { "pass" } else { "needs_test_coverage" }
    checks = $negativeAmountGuardChecks
    blocker = $negativeAmountGuardBlocker
  }
  credit_wallet_contract_checks = [ordered]@{
    path = $creditWalletContract.path
    exists = $creditWalletContract.exists
    status = if (-not $creditWalletContract.exists) { "missing" } elseif ($missingContractChecks.Count -eq 0) { "draft_contract_verified" } else { "draft_contract_incomplete" }
    checks = $contractChecks
    missing_checks = $missingContractChecks
    implemented_runtime_surface = $false
  }
  admin_readonly_openapi_contract_checks = [ordered]@{
    path = $adminOpenApi.path
    exists = $adminOpenApi.exists
    status = if (-not $adminOpenApi.exists) { "missing" } elseif ($missingAdminOpenApiChecks.Count -eq 0) { "admin_readonly_openapi_contract_verified" } else { "admin_readonly_openapi_contract_incomplete" }
    checks = $adminOpenApiChecks
    missing_checks = $missingAdminOpenApiChecks
  }
  opening_balance_import_api_contract_checks = [ordered]@{
    path = $adminOpenApi.path
    exists = $adminOpenApi.exists
    status = if (-not $adminOpenApi.exists) { "missing" } elseif ($missingOpeningBalanceImportApiChecks.Count -eq 0) { "opening_balance_import_api_contract_present" } else { "opening_balance_import_api_contract_incomplete" }
    checks = $openingBalanceImportApiChecks
    missing_checks = $missingOpeningBalanceImportApiChecks
  }
  runtime_artifact_checks = [ordered]@{
    admin_readonly_runtime = [ordered]@{
      searched_paths = $adminRuntimeArtifact.searched_paths
      found = $adminRuntimeArtifact.found
      status = if ($adminReadonlyRuntimeVerified) { "admin_readonly_runtime_verified" } elseif ($adminRuntimeArtifact.found) { "runtime_artifact_present_but_not_verified" } else { "runtime_artifact_absent" }
      verified = $adminReadonlyRuntimeVerified
    }
    billing_mutation_artifact = [ordered]@{
      searched_paths = $billingMutationArtifact.searched_paths
      found = $billingMutationArtifact.found
      status = if ($billingMutationArtifactVerified) { "billing_mutation_artifact_verified" } elseif ($billingMutationArtifact.found) { "billing_mutation_artifact_present_but_not_verified" } else { "e9_credit_03_artifact_absent" }
      verified = $billingMutationArtifactVerified
      checks = Get-BillingMutationArtifactChecks -Artifact $(if ($billingMutationArtifact.found) { $billingMutationArtifact.selected.json } else { $null })
    }
    opening_balance_import = [ordered]@{
      searched_paths = $openingBalanceImportArtifact.searched_paths
      found = $openingBalanceImportArtifact.found
      status = if ($openingBalanceImportArtifactVerified) { "opening_balance_import_artifact_verified" } elseif ($openingBalanceImportArtifact.found) { "opening_balance_import_artifact_present_but_not_verified" } else { "opening_balance_import_artifact_absent" }
      verified = $openingBalanceImportArtifactVerified
      runtime_verified = $openingBalanceImportRuntimeVerified
      checks = Get-OpeningBalanceImportArtifactChecks -Artifact $(if ($openingBalanceImportArtifact.found) { $openingBalanceImportArtifact.selected.json } else { $null })
    }
    credit_grant_crud = [ordered]@{
      searched_paths = $creditGrantCrudArtifact.searched_paths
      found = $creditGrantCrudArtifact.found
      status = if ($creditGrantCrudRuntimeVerified) { "credit_grant_crud_runtime_verified" } elseif ($creditGrantCrudArtifactVerified) { "credit_grant_crud_contract_verified" } elseif ($creditGrantCrudArtifact.found) { "credit_grant_crud_artifact_present_but_not_verified" } else { "credit_grant_crud_artifact_absent" }
      verified = $creditGrantCrudArtifactVerified
      runtime_verified = $creditGrantCrudRuntimeVerified
      checks = Get-CreditGrantCrudArtifactChecks -Artifact $(if ($creditGrantCrudArtifact.found) { $creditGrantCrudArtifact.selected.json } else { $null })
    }
    user_remaining_balance = [ordered]@{
      searched_paths = $userRemainingBalanceArtifact.searched_paths
      admin_runtime_searched_paths = $userRemainingBalanceAdminRuntimeArtifact.searched_paths
      full_runtime_searched_paths = $userRemainingBalanceFullRuntimeArtifact.searched_paths
      found = $userRemainingBalanceArtifact.found
      status = if ($userRemainingBalanceRuntimeVerified) { "user_remaining_balance_user_runtime_verified" } elseif ($userRemainingBalanceAdminRuntimeVerified) { "user_remaining_balance_admin_readonly_runtime_verified" } elseif ($userRemainingBalanceContractVerified) { "user_remaining_balance_contract_verified" } elseif ($userRemainingBalanceArtifact.found) { "user_remaining_balance_artifact_present_but_not_verified" } else { "user_remaining_balance_contract_artifact_absent" }
      verified = $userRemainingBalanceArtifactVerified
      admin_runtime_verified = $userRemainingBalanceAdminRuntimeVerified
      runtime_verified = $userRemainingBalanceRuntimeVerified
      checks = Get-UserRemainingBalanceArtifactChecks -Artifact $(if ($userRemainingBalanceArtifact.found) { $userRemainingBalanceArtifact.selected.json } else { $null })
      admin_runtime_checks = Get-UserRemainingBalanceRuntimeChecks -Artifact $(if ($userRemainingBalanceAdminRuntimeArtifact.found) { $userRemainingBalanceAdminRuntimeArtifact.selected.json } else { $null })
      runtime_checks = Get-UserRemainingBalanceRuntimeChecks -Artifact $(if ($userRemainingBalanceFullRuntimeArtifact.found) { $userRemainingBalanceFullRuntimeArtifact.selected.json } elseif ($userRemainingBalanceArtifact.found) { $userRemainingBalanceArtifact.selected.json } else { $null })
    }
    recharge_voucher = [ordered]@{
      searched_paths = $rechargeVoucherArtifact.searched_paths
      found = $rechargeVoucherArtifact.found
      status = if ($rechargeVoucherRuntimeVerified) { "recharge_voucher_runtime_verified" } elseif ($rechargeVoucherContractVerified) { "recharge_voucher_contract_verified" } elseif ($rechargeVoucherArtifact.found) { "recharge_voucher_artifact_present_but_not_verified" } else { "recharge_voucher_contract_artifact_absent" }
      verified = $rechargeVoucherContractVerified
      runtime_verified = $rechargeVoucherRuntimeVerified
      checks = Get-RechargeVoucherArtifactChecks -Artifact $(if ($rechargeVoucherArtifact.found) { $rechargeVoucherArtifact.selected.json } else { $null })
    }
    payment_order_invoice = [ordered]@{
      searched_paths = $PaymentOrderInvoiceArtifactPaths
      found = [bool]($paymentOrderInvoiceContractArtifact.found -or $paymentOrderInvoiceRuntimeArtifact.found)
      contract_artifact_found = $paymentOrderInvoiceContractArtifact.found
      runtime_artifact_found = $paymentOrderInvoiceRuntimeArtifact.found
      status = if ($paymentOrderInvoiceRuntimeVerified) { "payment_order_invoice_runtime_verified" } elseif ($paymentOrderInvoiceContractVerified) { "payment_order_invoice_contract_verified" } elseif ($paymentOrderInvoiceArtifact.found) { "payment_order_invoice_artifact_present_but_not_verified" } else { "payment_order_invoice_contract_artifact_absent" }
      verified = $paymentOrderInvoiceContractVerified
      runtime_verified = $paymentOrderInvoiceRuntimeVerified
      checks = Get-PaymentOrderInvoiceArtifactChecks -Artifact $(if ($paymentOrderInvoiceContractArtifact.found) { $paymentOrderInvoiceContractArtifact.selected.json } elseif ($paymentOrderInvoiceRuntimeArtifact.found) { $paymentOrderInvoiceRuntimeArtifact.selected.json } else { $null })
      runtime_checks = Get-PaymentOrderInvoiceArtifactChecks -Artifact $(if ($paymentOrderInvoiceRuntimeArtifact.found) { $paymentOrderInvoiceRuntimeArtifact.selected.json } else { $null })
    }
    subscription_package_lifecycle = [ordered]@{
      searched_paths = $SubscriptionPackageLifecycleArtifactPaths
      found = [bool]($subscriptionPackageLifecycleContractArtifact.found -or $subscriptionPackageLifecycleRuntimeArtifact.found)
      contract_artifact_found = $subscriptionPackageLifecycleContractArtifact.found
      runtime_artifact_found = $subscriptionPackageLifecycleRuntimeArtifact.found
      status = if ($subscriptionPackageLifecycleRuntimeVerified) { "subscription_package_lifecycle_runtime_verified" } elseif ($subscriptionPackageLifecycleContractVerified) { "subscription_package_lifecycle_contract_verified" } elseif ($subscriptionPackageLifecycleArtifact.found) { "subscription_package_lifecycle_artifact_present_but_not_verified" } else { "subscription_package_lifecycle_contract_artifact_absent" }
      verified = $subscriptionPackageLifecycleContractVerified
      runtime_verified = $subscriptionPackageLifecycleRuntimeVerified
      checks = Get-SubscriptionPackageLifecycleArtifactChecks -Artifact $(if ($subscriptionPackageLifecycleContractArtifact.found) { $subscriptionPackageLifecycleContractArtifact.selected.json } elseif ($subscriptionPackageLifecycleRuntimeArtifact.found) { $subscriptionPackageLifecycleRuntimeArtifact.selected.json } else { $null })
      runtime_checks = Get-SubscriptionPackageLifecycleArtifactChecks -Artifact $(if ($subscriptionPackageLifecycleRuntimeArtifact.found) { $subscriptionPackageLifecycleRuntimeArtifact.selected.json } else { $null })
    }
  }
  layered_status = [ordered]@{
    draft_contract_verified = $draftContractVerified
    admin_readonly_openapi_contract_verified = $adminReadonlyOpenApiContractVerified
    admin_readonly_runtime_verified = $adminReadonlyRuntimeVerified
    billing_mutation_contract_verified = $billingMutationContractVerified
    billing_mutation_artifact_verified = $billingMutationArtifactVerified
    opening_balance_import_contract_verified = $openingBalanceImportContractVerified
    opening_balance_import_api_contract_present = $openingBalanceImportApiContractPresent
    opening_balance_import_schema_verified = $openingBalanceImportSchemaVerified
    opening_balance_import_runtime_verified = $openingBalanceImportRuntimeVerified
    opening_balance_import_artifact_verified = $openingBalanceImportArtifactVerified
    credit_grant_crud_contract_verified = $creditGrantCrudArtifactVerified
    credit_grant_crud_runtime_verified = $creditGrantCrudRuntimeVerified
    credit_grant_crud_artifact_verified = $creditGrantCrudArtifactVerified
    user_remaining_balance_contract_verified = $userRemainingBalanceContractVerified
    user_remaining_balance_admin_runtime_verified = $userRemainingBalanceAdminRuntimeVerified
    user_remaining_balance_admin_readonly_runtime_verified = $userRemainingBalanceAdminRuntimeVerified
    user_remaining_balance_runtime_verified = $userRemainingBalanceRuntimeVerified
    recharge_voucher_contract_verified = $rechargeVoucherContractVerified
    recharge_voucher_runtime_verified = $rechargeVoucherRuntimeVerified
    payment_order_invoice_contract_verified = $paymentOrderInvoiceContractVerified
    payment_order_invoice_runtime_verified = $paymentOrderInvoiceRuntimeVerified
    subscription_package_lifecycle_contract_verified = $subscriptionPackageLifecycleContractVerified
    subscription_package_lifecycle_runtime_verified = $subscriptionPackageLifecycleRuntimeVerified
    product_commercial_flows_not_implemented = $true
  }
  paid_artifact_checks = $artifactChecks
  verdict = [ordered]@{
    underlying_credit_balance_capability = $capabilityVerdict
    user_recharge_redeem_package_invoice = "not_productized"
    new_api_one_api_balance_import = if ($openingBalanceImportRuntimeVerified) { "runtime_verified" } else { "designed_not_implemented" }
    credit_wallet_endpoint_contract = if ($creditWalletContract.exists -and $missingContractChecks.Count -eq 0) { "draft_verified_not_implemented" } elseif ($creditWalletContract.exists) { "draft_incomplete" } else { "not_found" }
    admin_readonly_openapi_contract = if ($adminReadonlyOpenApiContractVerified) { "verified_contract_only" } elseif ($adminOpenApi.exists) { "incomplete_contract" } else { "not_found" }
    admin_readonly_runtime = if ($adminReadonlyRuntimeVerified) { "verified" } elseif ($adminRuntimeArtifact.found) { "artifact_present_not_verified" } else { "not_implemented_no_runtime_artifact" }
    billing_mutation_contract = if ($billingMutationContractVerified) { "verified_contract_only" } else { "not_verified" }
    opening_balance_import_contract = if ($openingBalanceImportContractVerified) { "verified_contract_only" } else { "not_verified" }
    opening_balance_import_api_contract = if ($openingBalanceImportApiContractPresent) { "present_contract_only" } else { "not_found" }
    opening_balance_import_schema = if ($openingBalanceImportSchemaVerified) { "verified" } else { "not_found_or_incomplete" }
    opening_balance_import_runtime = if ($openingBalanceImportRuntimeVerified) { "verified" } elseif ($openingBalanceImportArtifact.found) { "artifact_present_runtime_not_verified" } else { "not_implemented_no_runtime_artifact" }
    opening_balance_import_artifact = if ($openingBalanceImportArtifactVerified) { "verified" } elseif ($openingBalanceImportArtifact.found) { "artifact_present_not_verified" } else { "not_found" }
    credit_grant_crud_contract = if ($creditGrantCrudArtifactVerified) { "verified" } elseif ($creditGrantCrudArtifact.found) { "artifact_present_not_verified" } else { "not_found" }
    credit_grant_crud_runtime = if ($creditGrantCrudRuntimeVerified) { "verified" } elseif ($creditGrantCrudArtifact.found) { "artifact_present_runtime_not_verified" } else { "not_implemented_no_runtime_artifact" }
    user_remaining_balance_contract = if ($userRemainingBalanceContractVerified) { "verified_contract_only" } elseif ($userRemainingBalanceArtifact.found) { "artifact_present_not_verified_as_contract" } else { "not_found" }
    user_remaining_balance_runtime = if ($userRemainingBalanceRuntimeVerified) { "verified_user_runtime" } elseif ($userRemainingBalanceAdminRuntimeVerified) { "verified_admin_readonly_runtime_user_api_gap_remaining" } elseif ($userRemainingBalanceArtifact.found) { "artifact_present_runtime_not_verified" } else { "not_implemented_no_runtime_artifact" }
    recharge_voucher_contract = if ($rechargeVoucherContractVerified) { "verified_contract_only" } elseif ($rechargeVoucherArtifact.found) { "artifact_present_not_verified" } else { "not_found" }
    recharge_voucher_runtime = if ($rechargeVoucherRuntimeVerified) { "verified" } elseif ($rechargeVoucherContractVerified) { "not_verified_contract_lane_only" } elseif ($rechargeVoucherArtifact.found) { "artifact_present_runtime_not_verified" } else { "not_implemented_no_runtime_artifact" }
    payment_order_invoice_contract = if ($paymentOrderInvoiceContractVerified) { "verified_contract_only" } elseif ($paymentOrderInvoiceArtifact.found) { "artifact_present_not_verified" } else { "not_found" }
    payment_order_invoice_runtime = if ($paymentOrderInvoiceRuntimeVerified) { "verified" } elseif ($paymentOrderInvoiceContractVerified) { "not_verified_contract_lane_only" } elseif ($paymentOrderInvoiceArtifact.found) { "artifact_present_runtime_not_verified" } else { "not_implemented_no_runtime_artifact" }
    subscription_package_lifecycle_contract = if ($subscriptionPackageLifecycleContractVerified) { "verified_contract_only" } elseif ($subscriptionPackageLifecycleArtifact.found) { "artifact_present_not_verified" } else { "not_found" }
    subscription_package_lifecycle_runtime = if ($subscriptionPackageLifecycleRuntimeVerified) { "verified" } elseif ($subscriptionPackageLifecycleContractVerified) { "not_verified_contract_lane_only" } elseif ($subscriptionPackageLifecycleArtifact.found) { "artifact_present_runtime_not_verified" } else { "not_implemented_no_runtime_artifact" }
    e11_credit_02r_watcher = if ($adminRuntimeArtifact.found) { "artifact_found_checked" } else { "no_runtime_artifact_noop" }
    e9_credit_03_watcher = if ($billingMutationArtifact.found) { "artifact_found_checked" } else { "no_mutation_test_artifact_noop" }
    todo_32f_watcher = if ($openingBalanceImportArtifact.found) { "artifact_found_checked" } else { "no_opening_balance_import_artifact_noop" }
    todo_32g_watcher = if ($creditGrantCrudArtifact.found) { "artifact_found_checked" } else { "no_credit_grant_crud_artifact_noop" }
    todo_32h_watcher = if ($userRemainingBalanceArtifact.found) { "artifact_found_checked" } else { "no_user_remaining_balance_contract_artifact_noop" }
    todo_32i_watcher = if ($rechargeVoucherArtifact.found) { "artifact_found_checked" } else { "no_recharge_voucher_contract_artifact_noop" }
    todo_32j_watcher = if ($paymentOrderInvoiceArtifact.found) { "artifact_found_checked" } else { "no_payment_order_invoice_contract_artifact_noop" }
    todo_32k_watcher = if ($subscriptionPackageLifecycleArtifact.found) { "artifact_found_checked" } else { "no_subscription_package_lifecycle_contract_artifact_noop" }
    controlled_paid_beta_status_preserved = "paid_controlled_beta_allowed_true_not_reopened"
  }
  blockers = $blockers
  remaining_gaps = @($(if ($creditGrantCrudRuntimeVerified) { @() } else { @("credit_grant_crud_api_and_audit") })) + @(
    $(if ($rechargeVoucherContractVerified) { "user_recharge_voucher_redemption_flow_runtime" } else { "user_recharge_voucher_redemption_flow" }),
    $(if ($paymentOrderInvoiceContractVerified) { "payment_order_invoice_lifecycle_runtime" } else { "payment_order_invoice_lifecycle" }),
    $(if ($subscriptionPackageLifecycleContractVerified) { "subscription_plan_lifecycle_runtime" } else { "subscription_plan_lifecycle" })
  ) + $(if ($openingBalanceImportRuntimeVerified) { @() } else { @("new_api_one_api_balance_import_apply_rollback_runner") }) +
  $(if ($userRemainingBalanceRuntimeVerified) { @() } elseif ($userRemainingBalanceContractVerified) { @("user_facing_remaining_balance_api_runtime") } else { @("user_facing_remaining_balance_api") })
  secret_safe = $true
} | ConvertTo-Json -Depth 12

exit $actualExitCode
