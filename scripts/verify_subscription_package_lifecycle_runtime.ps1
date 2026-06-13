param(
  [string]$ContractArtifactPath = ".tmp\credit-wallet\subscription_package_lifecycle_contract.json",
  [string]$OutputPath = ".tmp\credit-wallet\subscription_package_lifecycle_runtime_deferred.json",
  [switch]$SelfTest
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
      '(?i)client[_-]?secret\s*[:=]',
      'sk-[A-Za-z0-9]{8,}'
    )) {
    if ($Text -match $pattern) {
      return $false
    }
  }
  return $true
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

function Test-ContractAccepted {
  param([AllowNull()][object]$Contract)

  return [bool](
    (Get-JsonString -Json $Contract -Name "schema") -eq "subscription_package_lifecycle_contract.v1" -and
    (Get-JsonString -Json $Contract -Name "status") -eq "pass" -and
    -not (Get-JsonBool -Json $Contract -Name "runtime_implemented" -Default $true) -and
    (Get-JsonBool -Json $Contract -Name "contract_only") -and
    (Get-JsonBool -Json $Contract -Name "secret_safe") -and
    -not (Get-JsonBool -Json $Contract -Name "paid_gate_changed" -Default $true)
  )
}

function Test-SubscriptionSchemaText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) {
    return [ordered]@{
      subscription_plans = $false
      subscription_packages = $false
      subscriptions = $false
      subscription_events_or_schedules = $false
      all_required_tables_present = $false
    }
  }

  $checks = [ordered]@{
    subscription_plans = [bool]($Text -match '(?is)create\s+table\s+(?:if\s+not\s+exists\s+)?subscription_plans\b')
    subscription_packages = [bool]($Text -match '(?is)create\s+table\s+(?:if\s+not\s+exists\s+)?subscription_packages\b')
    subscriptions = [bool]($Text -match '(?is)create\s+table\s+(?:if\s+not\s+exists\s+)?subscriptions\b')
    subscription_events_or_schedules = [bool]($Text -match '(?is)create\s+table\s+(?:if\s+not\s+exists\s+)?subscription_events_or_schedules\b')
    plan_money_decimal = [bool]($Text -match '(?is)subscription_plans[\s\S]*unit_price\s+numeric\(20,\s*8\)[\s\S]*included_credit_amount\s+numeric\(20,\s*8\)')
    plan_currency_status_interval = [bool]($Text -match '(?is)subscription_plans[\s\S]*currency\s+text\s+not\s+null[\s\S]*billing_interval\s+text\s+not\s+null[\s\S]*check\s*\(status\s+in')
    plan_unique_tenant_code = [bool]($Text -match '(?is)subscription_plans[\s\S]*unique\s*\(\s*tenant_id\s*,\s*plan_code\s*\)')
    package_entitlement_summary = [bool]($Text -match '(?is)subscription_packages[\s\S]*entitlement_summary\s+jsonb\s+not\s+null')
    package_plan_fk = [bool]($Text -match '(?is)subscription_packages[\s\S]*foreign\s+key\s*\(\s*tenant_id\s*,\s*plan_id\s*\)\s+references\s+subscription_plans')
    subscription_scope_columns = [bool]($Text -match '(?is)subscriptions[\s\S]*project_id\s+uuid\s+null[\s\S]*wallet_id\s+uuid\s+not\s+null[\s\S]*plan_id\s+uuid\s+not\s+null')
    subscription_valid_window = [bool]($Text -match '(?is)subscriptions[\s\S]*current_period_start\s+timestamptz\s+not\s+null[\s\S]*current_period_end\s+timestamptz\s+not\s+null[\s\S]*current_period_end\s*>\s*current_period_start')
    subscription_state_columns = [bool]($Text -match '(?is)subscriptions[\s\S]*trial_ends_at\s+timestamptz\s+null[\s\S]*paused_at\s+timestamptz\s+null[\s\S]*cancelled_at\s+timestamptz\s+null')
    subscription_idempotency_unique = [bool]($Text -match '(?is)subscriptions[\s\S]*idempotency_key_hash\s+text\s+not\s+null[\s\S]*unique\s*\(\s*tenant_id\s*,\s*idempotency_key_hash\s*\)')
    subscription_accounting_links = [bool]($Text -match '(?is)subscriptions[\s\S]*latest_credit_grant_id\s+uuid\s+null[\s\S]*latest_ledger_entry_id\s+uuid\s+null[\s\S]*latest_invoice_id\s+uuid\s+null[\s\S]*latest_order_id\s+uuid\s+null[\s\S]*audit_id\s+uuid\s+null')
    event_effective_idempotency = [bool]($Text -match '(?is)subscription_events_or_schedules[\s\S]*effective_at\s+timestamptz\s+not\s+null[\s\S]*idempotency_key_hash\s+text\s+not\s+null[\s\S]*unique\s*\(\s*tenant_id\s*,\s*idempotency_key_hash\s*\)')
    event_accounting_links = [bool]($Text -match '(?is)subscription_events_or_schedules[\s\S]*credit_grant_id\s+uuid\s+null[\s\S]*ledger_entry_id\s+uuid\s+null[\s\S]*invoice_id\s+uuid\s+null[\s\S]*order_id\s+uuid\s+null[\s\S]*audit_id\s+uuid\s+null')
    event_refusal_reconciliation = [bool]($Text -match '(?is)subscription_events_or_schedules[\s\S]*refusal_code\s+text\s+null[\s\S]*event_type\s+in\s*\([^\)]*dunning[^\)]*reconciliation')
    safe_json_summaries = [bool]($Text -match '(?is)request_summary\s+jsonb\s+not\s+null\s+default\s+''\{\}''::jsonb[\s\S]*metadata\s+jsonb\s+not\s+null\s+default\s+''\{\}''::jsonb')
  }
  $checks["all_required_tables_present"] = [bool]($checks.subscription_plans -and $checks.subscription_packages -and $checks.subscriptions -and $checks.subscription_events_or_schedules)
  $checks["all_required_schema_contract_present"] = [bool](
    $checks.all_required_tables_present -and
    $checks.plan_money_decimal -and
    $checks.plan_currency_status_interval -and
    $checks.plan_unique_tenant_code -and
    $checks.package_entitlement_summary -and
    $checks.package_plan_fk -and
    $checks.subscription_scope_columns -and
    $checks.subscription_valid_window -and
    $checks.subscription_state_columns -and
    $checks.subscription_idempotency_unique -and
    $checks.subscription_accounting_links -and
    $checks.event_effective_idempotency -and
    $checks.event_accounting_links -and
    $checks.event_refusal_reconciliation -and
    $checks.safe_json_summaries
  )
  return $checks
}

function Get-SchemaDiagnostics {
  $texts = [System.Collections.Generic.List[string]]::new()
  foreach ($path in @("db\migrations", "examples\sql_schema_draft.sql")) {
    $full = Join-Path $repoRoot $path
    if (-not (Test-Path -LiteralPath $full)) {
      continue
    }
    if ((Get-Item -LiteralPath $full).PSIsContainer) {
      Get-ChildItem -LiteralPath $full -Filter "*.sql" -File | ForEach-Object {
        [void]$texts.Add((Get-Content -Raw -LiteralPath $_.FullName))
      }
    } else {
      [void]$texts.Add((Get-Content -Raw -LiteralPath $full))
    }
  }
  return Test-SubscriptionSchemaText -Text ([string]::Join("`n", $texts))
}

function New-DeferredArtifact {
  param(
    [bool]$ContractFound,
    [bool]$ContractAccepted,
    [bool]$ContractSecretSafe,
    [AllowNull()][object]$SchemaDiagnostics,
    [string]$ContractPath
  )

  $schemaReady = $false
  if ($null -ne $SchemaDiagnostics -and $SchemaDiagnostics -is [System.Collections.IDictionary] -and $SchemaDiagnostics.Contains("all_required_schema_contract_present")) {
    $schemaReady = [bool]$SchemaDiagnostics["all_required_schema_contract_present"]
  } elseif ($null -ne $SchemaDiagnostics -and $SchemaDiagnostics -is [System.Collections.IDictionary] -and $SchemaDiagnostics.Contains("all_required_tables_present")) {
    $schemaReady = [bool]$SchemaDiagnostics["all_required_tables_present"]
  } elseif ($null -ne $SchemaDiagnostics -and $SchemaDiagnostics.PSObject.Properties.Name -contains "all_required_schema_contract_present") {
    $schemaReady = [bool]$SchemaDiagnostics.all_required_schema_contract_present
  } elseif ($null -ne $SchemaDiagnostics -and $SchemaDiagnostics.PSObject.Properties.Name -contains "all_required_tables_present") {
    $schemaReady = [bool]$SchemaDiagnostics.all_required_tables_present
  }

  $blockers = [System.Collections.Generic.List[string]]::new()
  [void]$blockers.Add("deferred_runtime_external_dependency")
  if (-not $ContractFound) { [void]$blockers.Add("subscription_package_lifecycle_contract_missing") }
  if ($ContractFound -and -not $ContractAccepted) { [void]$blockers.Add("subscription_package_lifecycle_contract_not_accepted") }
  if (-not $ContractSecretSafe) { [void]$blockers.Add("subscription_package_lifecycle_contract_secret_unsafe") }
  if (-not $schemaReady) { [void]$blockers.Add("subscription_package_lifecycle_schema_migration_missing") }
  [void]$blockers.Add("subscription_package_lifecycle_runtime_not_invoked")
  [void]$blockers.Add("subscription_scheduler_or_provider_callback_missing")
  [void]$blockers.Add("subscription_invoice_order_linkage_runtime_missing")
  [void]$blockers.Add("subscription_trial_proration_dunning_runtime_missing")
  [void]$blockers.Add("subscription_credit_or_ledger_effect_readback_missing")
  [void]$blockers.Add("subscription_renew_cancel_pause_resume_readback_missing")
  [void]$blockers.Add("subscription_reconciliation_runtime_missing")
  [void]$blockers.Add("subscription_package_lifecycle_runtime_pass_artifact_absent")

  return [ordered]@{
    schema = "subscription_package_lifecycle_runtime_deferred.v1"
    overall_status = "deferred_runtime_external_dependency"
    status = "deferred_runtime_external_dependency"
    actual_exit_code = 2
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    runtime_implemented = $false
    contract_only = $true
    route_invoked = $false
    internal_runtime_function_invoked = $false
    scheduler_invoked = $false
    db_integration_ran = $false
    secret_safe = [bool]($ContractSecretSafe)
    paid_gate_changed = $false
    production_distribution_ready = $false
    contract_artifact = $ContractPath
    pass_artifact_required = ".tmp/credit-wallet/subscription_package_lifecycle_runtime.json"
    current_facts = [ordered]@{
      todo_32i_recharge_voucher_runtime_verified = $true
      todo_32j_payment_order_invoice_status = "deferred_runtime_external_dependency"
      todo_32j_runtime_verified = $false
      todo_32k_contract_verified = [bool]$ContractAccepted
      todo_32k_schema_contract_present = $true
      todo_32k_schema_migration_present = [bool]$schemaReady
      todo_32k_runtime_verified = $false
    }
    schema_diagnostics = $SchemaDiagnostics
    runtime_acceptance = [ordered]@{
      runtime_artifact_schema = "subscription_package_lifecycle_runtime.v1"
      pass_requires_runtime_invocation_or_scheduler_proof = $true
      pass_requires_plan_package_crud_readback = $true
      pass_requires_subscription_lifecycle_readback = $true
      pass_requires_state_transition_readback = $true
      pass_requires_trial_proration_dunning_readback = $true
      pass_requires_credit_grant_or_ledger_effect_readback = $true
      pass_requires_invoice_order_linkage_readback = $true
      pass_requires_renew_cancel_pause_resume_readback = $true
      pass_requires_idempotency_replay_and_conflict_no_duplicate_write = $true
      pass_requires_refusal_no_write_readback = $true
      pass_requires_audit_and_reconciliation_readback = $true
      pass_requires_money_decimal_strings = $true
      pass_requires_secret_safe = $true
      pass_requires_paid_gate_changed_false = $true
    }
    resume_conditions = @(
      "subscription_plans_packages_subscriptions_events_schema_migration",
      "admin_or_product_plan_package_crud_runtime_readback",
      "subscription_create_activate_renew_cancel_pause_resume_runtime_readback",
      "trial_proration_dunning_scheduler_or_callback_runtime_readback",
      "credit_grant_or_ledger_effect_readback",
      "invoice_order_linkage_runtime_readback",
      "idempotency_replay_conflict_refusal_no_write_readback",
      "audit_and_reconciliation_readback",
      "accepted_subscription_package_lifecycle_runtime_v1_artifact",
      "main_verifier_subscription_package_lifecycle_runtime_verified_true"
    )
    blockers = @($blockers.ToArray())
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

if ($SelfTest) {
  $accepted = [pscustomobject]@{
    schema = "subscription_package_lifecycle_contract.v1"
    status = "pass"
    runtime_implemented = $false
    contract_only = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $unsafeTextRejected = -not (Test-SecretSafeText "Authorization: bearer example")
  $schemaChecks = Test-SubscriptionSchemaText @'
create table subscription_plans (
  tenant_id uuid not null,
  plan_code text not null,
  status text not null,
  currency text not null,
  billing_interval text not null,
  unit_price numeric(20, 8) not null,
  included_credit_amount numeric(20, 8) not null,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  unique (tenant_id, plan_code),
  check (status in ('draft'))
);
create table subscription_packages (
  tenant_id uuid not null,
  plan_id uuid not null,
  entitlement_summary jsonb not null,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  foreign key (tenant_id, plan_id) references subscription_plans(tenant_id, id)
);
create table subscriptions (
  tenant_id uuid not null,
  project_id uuid null,
  wallet_id uuid not null,
  plan_id uuid not null,
  current_period_start timestamptz not null,
  current_period_end timestamptz not null,
  trial_ends_at timestamptz null,
  paused_at timestamptz null,
  cancelled_at timestamptz null,
  idempotency_key_hash text not null,
  latest_credit_grant_id uuid null,
  latest_ledger_entry_id uuid null,
  latest_invoice_id uuid null,
  latest_order_id uuid null,
  audit_id uuid null,
  unique (tenant_id, idempotency_key_hash),
  check (current_period_end > current_period_start)
);
create table subscription_events_or_schedules (
  effective_at timestamptz not null,
  idempotency_key_hash text not null,
  credit_grant_id uuid null,
  ledger_entry_id uuid null,
  invoice_id uuid null,
  order_id uuid null,
  audit_id uuid null,
  refusal_code text null,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  unique (tenant_id, idempotency_key_hash),
  check (event_type in ('dunning', 'reconciliation'))
);
'@
  $artifact = New-DeferredArtifact -ContractFound $true -ContractAccepted (Test-ContractAccepted $accepted) -ContractSecretSafe $true -SchemaDiagnostics $schemaChecks -ContractPath ".tmp/credit-wallet/subscription_package_lifecycle_contract.json"
  $cases = @(
    [ordered]@{ name = "accepted_contract_is_contract_only"; status = if (Test-ContractAccepted $accepted) { "pass" } else { "fail" } },
    [ordered]@{ name = "raw_secret_marker_rejected"; status = if ($unsafeTextRejected) { "pass" } else { "fail" } },
    [ordered]@{ name = "schema_contract_fields_accepted"; status = if ([bool]$schemaChecks.all_required_schema_contract_present) { "pass" } else { "fail" } },
    [ordered]@{ name = "deferred_artifact_never_claims_runtime"; status = if (-not [bool]$artifact.runtime_implemented -and [bool]$artifact.contract_only -and [string]$artifact.overall_status -eq "deferred_runtime_external_dependency") { "pass" } else { "fail" } },
    [ordered]@{ name = "runtime_acceptance_requires_scheduler_or_runtime"; status = if ([bool]$artifact.runtime_acceptance.pass_requires_runtime_invocation_or_scheduler_proof) { "pass" } else { "fail" } }
  )
  $status = if (@($cases | Where-Object { $_.status -ne "pass" }).Count -eq 0) { "pass" } else { "fail" }
  [ordered]@{
    schema = "subscription_package_lifecycle_runtime_verifier_selftest.v1"
    status = $status
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    cases = $cases
    runtime_implemented = $false
    contract_only = $true
    secret_safe = $true
    paid_gate_changed = $false
  } | ConvertTo-Json -Depth 10
  if ($status -eq "pass") { exit 0 }
  exit 1
}

$contractPathInfo = Resolve-RepoBoundedPath -Path $ContractArtifactPath -AllowedPrefixes @(".tmp/", "artifacts/", "tests/fixtures/billing/")
$outputPathInfo = Resolve-RepoBoundedPath -Path $OutputPath -AllowedPrefixes @(".tmp/", "artifacts/")

$contractFound = Test-Path -LiteralPath $contractPathInfo.full -PathType Leaf
$contract = $null
$contractSecretSafe = $true
if ($contractFound) {
  $rawContract = Get-Content -Raw -LiteralPath $contractPathInfo.full
  $contractSecretSafe = Test-SecretSafeText $rawContract
  if ($contractSecretSafe) {
    $contract = $rawContract | ConvertFrom-Json
  }
}

$schemaDiagnostics = Get-SchemaDiagnostics
$artifact = New-DeferredArtifact `
  -ContractFound $contractFound `
  -ContractAccepted (Test-ContractAccepted $contract) `
  -ContractSecretSafe $contractSecretSafe `
  -SchemaDiagnostics $schemaDiagnostics `
  -ContractPath $contractPathInfo.relative

$outputDirectory = Split-Path -Parent $outputPathInfo.full
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
  New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}
$artifact | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $outputPathInfo.full -Encoding UTF8
$artifact | ConvertTo-Json -Depth 14

exit 2
