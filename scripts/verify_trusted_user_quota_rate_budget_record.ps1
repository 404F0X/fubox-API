param(
  [string]$RecordPath = "",
  [string]$OutputPath = ".tmp\launch\trusted_user_quota_rate_budget_record_verification.json",
  [string]$EvidenceManifestPath = ".tmp\launch\trusted_user_api_distribution_handoff_summary.json",
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

$requiredEvidenceEntries = [ordered]@{
  quota_template = "trusted_user_quota_rate_budget_template"
  accounting_gate = "voucher_backed_api_distribution_accounting_gate"
  guardrails = "voucher_quota_pricing_guardrails"
  remaining_balance_runtime = "user_remaining_balance_runtime"
  recharge_voucher_runtime = "recharge_voucher_runtime"
}

$requiredStringFields = @(
  "tenant_id",
  "project_id",
  "trusted_user_id_or_owner_ref",
  "wallet_id",
  "virtual_key_id_or_key_prefix",
  "operator_id",
  "support_owner",
  "credit_source",
  "voucher_id_or_redemption_id",
  "credit_grant_id",
  "ledger_entry_id",
  "model_or_canonical_model_id",
  "price_book_id_or_policy_ref",
  "price_version_id_or_model_cost_policy_ref",
  "api_key_profile_id_or_profile_binding_id",
  "revoke_or_disable_procedure",
  "rollback_contact",
  "audit_id_or_support_ticket_id"
)

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $full = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }
  $prefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "path_must_stay_inside_repo"
  }
  $relative = $full.Substring($prefix.Length).Replace("\", "/")
  if (-not ($relative.StartsWith(".tmp/", [System.StringComparison]::OrdinalIgnoreCase) -or $relative.StartsWith("artifacts/", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "path_must_be_tmp_or_artifacts"
  }
  return [pscustomobject]@{ full = $full; relative = $relative }
}

function Get-Field {
  param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $null
  }
  if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $Name) { return $null }
  return $Object.PSObject.Properties[$Name].Value
}

function Get-StringField {
  param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
  $value = Get-Field -Object $Object -Name $Name
  if ($null -eq $value) { return "" }
  return [string]$value
}

function Add-Unique {
  param([Parameter(Mandatory = $true)]$List, [Parameter(Mandatory = $true)][string]$Value)
  if (-not $List.Contains($Value)) { [void]$List.Add($Value) }
}

function Test-Placeholder {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
  return ($Value -match '^<.*>$' -or $Value -match '^REQUIRED_' -or $Value -match '^to_be_filled' -or $Value -eq "missing")
}

function Test-BoundedRef {
  param([AllowNull()][string]$Value)
  if (Test-Placeholder $Value) { return $false }
  return ($Value -match '^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$')
}

function Test-MoneyString {
  param([AllowNull()][string]$Value, [bool]$AllowZero = $false)
  if ($Value -notmatch '^[0-9]+\.[0-9]{8}$') { return $false }
  $decimal = [decimal]$Value
  if ($AllowZero) { return $decimal -ge 0 }
  return $decimal -gt 0
}

function Test-PositiveIntegerOrNotApplicable {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return $false }
  $text = [string]$Value
  if ($text -eq "not_applicable") { return $true }
  if ($text -notmatch '^[0-9]+$') { return $false }
  return ([int64]$text -gt 0)
}

function Test-PositiveInteger {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return $false }
  $text = [string]$Value
  if ($text -notmatch '^[0-9]+$') { return $false }
  return ([int64]$text -gt 0)
}

function Test-UtcTimestamp {
  param([AllowNull()][string]$Value, [bool]$RequireFuture = $false)
  if (Test-Placeholder $Value) { return $false }
  $dt = [datetime]::MinValue
  if (-not [datetime]::TryParse($Value, [ref]$dt)) { return $false }
  if ($RequireFuture -and $dt.ToUniversalTime() -le (Get-Date).ToUniversalTime()) { return $false }
  return $true
}

function Test-SecretSafeString {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
  $secretPattern = '(?i)(authorization|bearer\s+[a-z0-9_\-\.]+|cookie|sk-[a-z0-9]|x-api-key|postgres(?:ql)?://|mysql://|redis://|raw[_ -]?voucher[_ -]?code|raw[_ -]?virtual[_ -]?key|virtual[_ -]?key[_ -]?secret|provider[_ -]?key|db[_ -]?url|raw[_ -]?provider[_ -]?payload|raw[_ -]?request[_ -]?body|raw[_ -]?idempotency|dev_test_key)'
  return -not ($Value -match $secretPattern)
}

function Test-ObjectSecretSafe {
  param([AllowNull()][object]$Object, [string]$Path = "record")
  $blockers = [System.Collections.Generic.List[string]]::new()
  if ($null -eq $Object) { return @() }
  if ($Object -is [string] -or $Object -is [ValueType]) {
    if (-not (Test-SecretSafeString $Object)) { [void]$blockers.Add("secret_like_value:$Path") }
    return @($blockers.ToArray())
  }
  if ($Object -is [System.Collections.IDictionary]) {
    foreach ($key in $Object.Keys) {
      foreach ($blocker in (Test-ObjectSecretSafe $Object[$key] "$Path.$key")) { [void]$blockers.Add($blocker) }
    }
    return @($blockers.ToArray())
  }
  if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
    $index = 0
    foreach ($item in $Object) {
      foreach ($blocker in (Test-ObjectSecretSafe $item "$Path[$index]")) { [void]$blockers.Add($blocker) }
      $index++
    }
    return @($blockers.ToArray())
  }
  if ($Object -isnot [pscustomobject]) {
    if (-not (Test-SecretSafeString ([string]$Object))) { [void]$blockers.Add("secret_like_value:$Path") }
    return @($blockers.ToArray())
  }
  foreach ($property in $Object.PSObject.Properties) {
    foreach ($blocker in (Test-ObjectSecretSafe $property.Value "$Path.$($property.Name)")) { [void]$blockers.Add($blocker) }
  }
  return @($blockers.ToArray())
}

function Read-Manifest {
  param([Parameter(Mandatory = $true)][string]$Path)
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $resolved.full -PathType Leaf)) {
    throw "evidence_manifest_missing"
  }
  $json = Get-Content -Raw -LiteralPath $resolved.full | ConvertFrom-Json
  $manifest = Get-Field $json "evidence_manifest"
  if ($null -eq $manifest) { $manifest = $json }
  return [pscustomobject]@{ path = $resolved.relative; manifest = $manifest }
}

function Get-ManifestEntry {
  param([Parameter(Mandatory = $true)][object]$Manifest, [Parameter(Mandatory = $true)][string]$Name)
  $entries = @(Get-Field $Manifest "entries")
  return @($entries | Where-Object { (Get-StringField $_ "name") -eq $Name } | Select-Object -First 1)[0]
}

function Read-RepoJsonByRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $resolved.full -PathType Leaf)) { return $null }
  return Get-Content -Raw -LiteralPath $resolved.full | ConvertFrom-Json
}

function Test-AnyStringEquals {
  param([AllowNull()][object]$Values, [AllowNull()][string]$Expected)
  if ([string]::IsNullOrWhiteSpace($Expected)) { return $false }
  foreach ($value in @($Values)) {
    if ([string]$value -eq $Expected) { return $true }
  }
  return $false
}

function Test-EvidenceBodyConsistency {
  param([Parameter(Mandatory = $true)][object]$Record)
  $blockers = [System.Collections.Generic.List[string]]::new()
  $checks = [ordered]@{}
  $links = Get-Field $Record "evidence_links"
  if ($null -eq $links) {
    return [ordered]@{ blockers = @(); checks = $checks }
  }

  $accounting = $null
  $guardrails = $null
  $balance = $null
  $voucher = $null
  try { $accounting = Read-RepoJsonByRelativePath (Get-StringField $links "accounting_gate") } catch { Add-Unique $blockers "evidence_body_unreadable:accounting_gate" }
  try { $guardrails = Read-RepoJsonByRelativePath (Get-StringField $links "guardrails") } catch { Add-Unique $blockers "evidence_body_unreadable:guardrails" }
  try { $balance = Read-RepoJsonByRelativePath (Get-StringField $links "remaining_balance_runtime") } catch { Add-Unique $blockers "evidence_body_unreadable:remaining_balance_runtime" }
  try { $voucher = Read-RepoJsonByRelativePath (Get-StringField $links "recharge_voucher_runtime") } catch { Add-Unique $blockers "evidence_body_unreadable:recharge_voucher_runtime" }

  $checks["accounting_gate_launch_ready"] = [bool](
    $null -ne $accounting -and
    (Get-StringField $accounting "schema") -eq "voucher_backed_api_distribution_accounting_gate.v1" -and
    (Get-StringField $accounting "overall_status") -eq "launch_ready_with_productization_gaps" -and
    (Get-Field $accounting "accounting_credit_acceptable") -eq $true -and
    (Get-Field $accounting "api_distribution_launch_ready") -eq $true -and
    (Get-Field $accounting "payment_provider_required_for_this_gate") -ne $true -and
    (Get-Field $accounting "subscription_scheduler_required_for_this_gate") -ne $true
  )
  if (-not $checks["accounting_gate_launch_ready"]) { Add-Unique $blockers "accounting_gate_not_launch_ready_for_voucher_backed_scope" }

  $deferredItems = @(Get-Field $accounting "deferred_items")
  $paymentDeferred = @($deferredItems | Where-Object { (Get-StringField $_ "item") -eq "payment_order_invoice" -and (Get-StringField $_ "status") -eq "deferred_runtime_external_dependency" -and (Get-Field $_ "blocks_voucher_backed_api_distribution") -ne $true }).Count -gt 0
  $subscriptionDeferred = @($deferredItems | Where-Object { (Get-StringField $_ "item") -eq "subscription_package_lifecycle" -and (Get-StringField $_ "status") -eq "deferred_runtime_external_dependency" -and (Get-Field $_ "blocks_voucher_backed_api_distribution") -ne $true }).Count -gt 0
  $checks["todo_32j_32k_deferred_non_blocking"] = [bool]($paymentDeferred -and $subscriptionDeferred)
  if (-not $checks["todo_32j_32k_deferred_non_blocking"]) { Add-Unique $blockers "todo_32j_32k_not_deferred_non_blocking_in_accounting_gate" }

  $checks["guardrails_pass"] = [bool](
    $null -ne $guardrails -and
    (Get-StringField $guardrails "schema") -eq "voucher_quota_pricing_guardrails.v1" -and
    (Get-StringField $guardrails "overall_status") -eq "pass" -and
    (Get-Field $guardrails "launch_ready") -eq $true -and
    (Get-Field $guardrails "fixed_decimal_money") -eq $true -and
    (Get-Field $guardrails "remaining_balance_readback_verified") -eq $true -and
    (Get-Field $guardrails "voucher_credit_effect_verified") -eq $true
  )
  if (-not $checks["guardrails_pass"]) { Add-Unique $blockers "quota_pricing_guardrails_not_pass" }

  $recordCurrency = Get-StringField $Record "currency"
  $recordTenant = Get-StringField $Record "tenant_id"
  $recordProject = Get-StringField $Record "project_id"
  $recordWallet = Get-StringField $Record "wallet_id"
  $recordCreditGrant = Get-StringField $Record "credit_grant_id"
  $recordLedgerEntry = Get-StringField $Record "ledger_entry_id"
  $recordRemaining = Get-StringField $Record "remaining_balance_available_to_spend_fixed_decimal_string"
  $recordVoucherRef = Get-StringField $Record "voucher_id_or_redemption_id"

  $checks["remaining_balance_artifact_pass"] = [bool](
    $null -ne $balance -and
    (Get-StringField $balance "schema") -eq "user_remaining_balance_runtime.v1" -and
    (Get-StringField $balance "overall_status") -eq "pass" -and
    (Get-Field $balance "runtime_implemented") -eq $true -and
    (Get-Field $balance "read_only") -eq $true -and
    (Get-Field $balance "wallet_readback_passed") -eq $true -and
    (Get-Field $balance "credit_grants_readback_passed") -eq $true -and
    (Get-Field $balance "ledger_window_readback_passed") -eq $true -and
    (Get-Field $balance "secret_safe") -eq $true -and
    (Get-Field $balance "paid_gate_changed") -ne $true
  )
  if (-not $checks["remaining_balance_artifact_pass"]) { Add-Unique $blockers "remaining_balance_artifact_not_pass" }

  $checks["record_matches_remaining_balance_readback"] = [bool](
    $null -ne $balance -and
    (Get-StringField $balance "tenant_id") -eq $recordTenant -and
    (Get-StringField $balance "project_id") -eq $recordProject -and
    (Get-StringField $balance "wallet_id") -eq $recordWallet -and
    (Get-StringField $balance "currency") -eq $recordCurrency -and
    (Get-StringField $balance "available_to_spend") -eq $recordRemaining -and
    (Get-StringField $balance "credit_grant_id") -eq $recordCreditGrant -and
    (Test-AnyStringEquals (Get-Field $balance "ledger_entry_ids") $recordLedgerEntry)
  )
  if (-not $checks["record_matches_remaining_balance_readback"]) { Add-Unique $blockers "record_does_not_match_remaining_balance_readback" }

  $checks["voucher_runtime_artifact_pass"] = [bool](
    $null -ne $voucher -and
    (Get-StringField $voucher "schema") -eq "recharge_voucher_runtime.v1" -and
    (Get-StringField $voucher "overall_status") -eq "pass" -and
    (Get-Field $voucher "runtime_implemented") -eq $true -and
    (Get-Field $voucher "ledger_or_credit_readback_passed") -eq $true -and
    (Get-Field $voucher "voucher_code_redacted_output") -eq $true -and
    (Get-Field $voucher "secret_safe") -eq $true -and
    (Get-Field $voucher "paid_gate_changed") -ne $true
  )
  if (-not $checks["voucher_runtime_artifact_pass"]) { Add-Unique $blockers "voucher_runtime_artifact_not_pass" }

  $checks["record_matches_voucher_runtime_currency_and_ref"] = [bool](
    $null -ne $voucher -and
    (Get-StringField $voucher "currency") -eq $recordCurrency -and
    (
      (Get-StringField $voucher "voucher_id") -eq $recordVoucherRef -or
      (Get-StringField $voucher "redemption_id") -eq $recordVoucherRef
    )
  )
  if (-not $checks["record_matches_voucher_runtime_currency_and_ref"]) { Add-Unique $blockers "record_does_not_match_voucher_runtime_currency_or_ref" }

  return [ordered]@{ blockers = @($blockers.ToArray()); checks = $checks }
}

function Test-EvidenceManifest {
  param([Parameter(Mandatory = $true)][object]$Record, [Parameter(Mandatory = $true)][object]$ManifestInfo)
  $blockers = [System.Collections.Generic.List[string]]::new()
  $hashes = [ordered]@{}
  $manifest = $ManifestInfo.manifest

  if ((Get-StringField $manifest "schema") -ne "trusted_user_api_distribution_evidence_manifest.v1") {
    Add-Unique $blockers "evidence_manifest_schema_invalid"
  }
  if ((Get-StringField $manifest "hash_algorithm") -ne "SHA256") {
    Add-Unique $blockers "evidence_manifest_hash_algorithm_invalid"
  }
  if (@(Get-Field $manifest "missing_required_entries").Count -gt 0) {
    Add-Unique $blockers "evidence_manifest_missing_required_entries_not_empty"
  }

  $links = Get-Field $Record "evidence_links"
  foreach ($key in $requiredEvidenceEntries.Keys) {
    $entryName = $requiredEvidenceEntries[$key]
    $entry = Get-ManifestEntry -Manifest $manifest -Name $entryName
    if ($null -eq $entry) {
      Add-Unique $blockers "evidence_manifest_required_entry_missing:$entryName"
      continue
    }
    $entryPath = Get-StringField $entry "path"
    $entrySha = Get-StringField $entry "sha256"
    if ($entrySha -notmatch '^[a-f0-9]{64}$') {
      Add-Unique $blockers "evidence_manifest_sha_invalid:$entryName"
      continue
    }
    try {
      $resolved = Resolve-RepoPath $entryPath
      if (-not (Test-Path -LiteralPath $resolved.full -PathType Leaf)) {
        Add-Unique $blockers "evidence_manifest_entry_file_missing:$entryName"
      } else {
        $actualSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolved.full).Hash.ToLowerInvariant()
        $hashes[$entryName] = [ordered]@{ path = $entryPath; manifest_sha256 = $entrySha; actual_sha256 = $actualSha }
        if ($actualSha -ne $entrySha) {
          Add-Unique $blockers "evidence_hash_mismatch:$entryName"
        }
      }
    } catch {
      Add-Unique $blockers "repo_path_not_bounded:evidence_manifest.$entryName"
    }

    $linkValue = Get-StringField $links $key
    if (-not [string]::IsNullOrWhiteSpace($linkValue)) {
      try {
        $resolvedLink = Resolve-RepoPath $linkValue
        if ($resolvedLink.relative -ne $entryPath) {
          Add-Unique $blockers "evidence_link_manifest_path_mismatch:$key"
        }
      } catch {
        Add-Unique $blockers "repo_path_not_bounded:evidence_links.$key"
      }
    }
  }
  return [ordered]@{ blockers = @($blockers.ToArray()); evidence_hashes = $hashes }
}

function Test-RecordObject {
  param(
    [Parameter(Mandatory = $true)][object]$Record,
    [Parameter(Mandatory = $true)][string]$RecordPathForReport,
    [Parameter(Mandatory = $true)][string]$ManifestPathForReport,
    [Parameter(Mandatory = $true)][object]$ManifestInfo
  )

  $missing = [System.Collections.Generic.List[string]]::new()
  $blockers = [System.Collections.Generic.List[string]]::new()

  if ((Get-StringField $Record "schema") -ne "trusted_user_quota_rate_budget_record.v1") {
    Add-Unique $blockers "schema_invalid"
  }
  if ((Get-Field $Record "real_user_values_present") -ne $true) {
    Add-Unique $blockers "real_user_values_present_not_true"
  }
  if ((Get-Field $Record "secret_safe") -ne $true) {
    Add-Unique $blockers "secret_safe_not_true"
  }
  $paidGateChanged = Get-Field $Record "paid_gate_changed"
  if ($paidGateChanged -eq $true) {
    Add-Unique $blockers "paid_gate_changed_true"
  }

  foreach ($field in $requiredStringFields) {
    $value = Get-StringField $Record $field
    if (Test-Placeholder $value) {
      Add-Unique $missing $field
      Add-Unique $blockers "record_placeholder_values_present"
    } elseif (-not (Test-BoundedRef $value)) {
      Add-Unique $blockers "bounded_ref_invalid:$field"
    }
  }

  foreach ($moneyField in @("credit_amount_fixed_decimal_string", "budget_limit_amount_fixed_decimal_string")) {
    $value = Get-StringField $Record $moneyField
    if (-not (Test-MoneyString $value)) { Add-Unique $blockers "money_decimal_invalid:$moneyField" }
  }
  if (-not (Test-MoneyString (Get-StringField $Record "remaining_balance_available_to_spend_fixed_decimal_string") $true)) {
    Add-Unique $blockers "money_decimal_invalid:remaining_balance_available_to_spend_fixed_decimal_string"
  }

  $currency = Get-StringField $Record "currency"
  if ($currency -cnotmatch '^[A-Z]{3}$') { Add-Unique $blockers "currency_invalid" }

  foreach ($rateField in @("rpm_limit_positive_integer", "tpm_limit_positive_integer")) {
    if (-not (Test-PositiveInteger (Get-Field $Record $rateField))) { Add-Unique $blockers "rate_limit_invalid:$rateField" }
  }
  if (-not (Test-PositiveIntegerOrNotApplicable (Get-Field $Record "concurrency_limit_positive_integer_or_not_applicable"))) {
    Add-Unique $blockers "rate_limit_invalid:concurrency_limit_positive_integer_or_not_applicable"
  }

  foreach ($timeField in @("credit_valid_until_utc", "virtual_key_expires_at_utc")) {
    if (-not (Test-UtcTimestamp (Get-StringField $Record $timeField) $true)) { Add-Unique $blockers "utc_timestamp_invalid_or_not_future:$timeField" }
  }
  if (-not (Test-UtcTimestamp (Get-StringField $Record "record_generated_at_utc") $false)) {
    Add-Unique $blockers "utc_timestamp_invalid:record_generated_at_utc"
  }

  $window = Get-Field $Record "budget_window"
  if ($null -eq $window) {
    Add-Unique $missing "budget_window"
  } else {
    $start = Get-StringField $window "start_utc"
    $end = Get-StringField $window "end_utc"
    if (-not (Test-UtcTimestamp $start $false) -or -not (Test-UtcTimestamp $end $true)) {
      Add-Unique $blockers "budget_window_invalid"
    } else {
      if ([datetime]$end -le [datetime]$start) { Add-Unique $blockers "budget_window_end_not_after_start" }
    }
  }

  $links = Get-Field $Record "evidence_links"
  if ($null -eq $links) {
    Add-Unique $missing "evidence_links"
  } else {
    foreach ($key in $requiredEvidenceEntries.Keys) {
      $link = Get-StringField $links $key
      if ([string]::IsNullOrWhiteSpace($link)) {
        Add-Unique $missing "evidence_links.$key"
      } else {
        try { [void](Resolve-RepoPath $link) } catch { Add-Unique $blockers "repo_path_not_bounded:evidence_links.$key" }
      }
    }
  }

  foreach ($blocker in (Test-ObjectSecretSafe $Record)) {
    Add-Unique $blockers $blocker
  }

  $manifestResult = Test-EvidenceManifest -Record $Record -ManifestInfo $ManifestInfo
  foreach ($blocker in $manifestResult.blockers) { Add-Unique $blockers $blocker }
  $evidenceBodyResult = Test-EvidenceBodyConsistency -Record $Record
  foreach ($blocker in $evidenceBodyResult.blockers) { Add-Unique $blockers $blocker }

  $status = if ($blockers.Count -eq 0 -and $missing.Count -eq 0) { "pass" } else { "blocked" }
  return [ordered]@{
    schema = "trusted_user_quota_rate_budget_record_verification.v1"
    status = $status
    ready_for_handoff = ($status -eq "pass")
    actual_exit_code = if ($status -eq "pass") { 0 } else { 2 }
    record_path = $RecordPathForReport
    evidence_manifest_path = $ManifestPathForReport
    missing_fields = @($missing.ToArray())
    blockers = @($blockers.ToArray())
    evidence_hashes = $manifestResult.evidence_hashes
    validation_results = $evidenceBodyResult.checks
    real_user_values_present = Get-Field $Record "real_user_values_present"
    secret_safe = Get-Field $Record "secret_safe"
    paid_gate_changed = if ($null -eq $paidGateChanged) { $false } else { [bool]$paidGateChanged }
    no_raw_secret_material_expected = $true
  }
}

function Write-VerificationArtifact {
  param(
    [Parameter(Mandatory = $true)][object]$Result,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $resolved = Resolve-RepoPath $Path
  $parent = Split-Path -Parent $resolved.full
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $Result["artifact_path"] = $resolved.relative
  $Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolved.full -Encoding utf8
  return $resolved.relative
}

function New-SelfTestManifestInfo {
  $dir = Resolve-RepoPath ".tmp/launch/e9_quota_record_verifier_selftest"
  if (-not (Test-Path -LiteralPath $dir.full -PathType Container)) {
    New-Item -ItemType Directory -Path $dir.full -Force | Out-Null
  }

  $sourceByName = [ordered]@{
    trusted_user_quota_rate_budget_template = ".tmp/launch/trusted_user_quota_rate_budget_record_template.json"
    voucher_backed_api_distribution_accounting_gate = ".tmp/launch/voucher_backed_api_distribution_accounting_gate.json"
    voucher_quota_pricing_guardrails = ".tmp/launch/voucher_quota_pricing_guardrails.json"
    user_remaining_balance_runtime = ".tmp/credit-wallet/user_remaining_balance_ownership_runtime.json"
    recharge_voucher_runtime = ".tmp/credit-wallet/recharge_voucher_runtime.json"
  }
  $targetByName = [ordered]@{}
  $entries = @()
  foreach ($name in $sourceByName.Keys) {
    $source = Resolve-RepoPath $sourceByName[$name]
    if (-not (Test-Path -LiteralPath $source.full -PathType Leaf)) {
      throw "selftest_source_missing:$name"
    }
    $targetRelative = ".tmp/launch/e9_quota_record_verifier_selftest/$name.json"
    $target = Resolve-RepoPath $targetRelative
    Copy-Item -LiteralPath $source.full -Destination $target.full -Force
    $targetByName[$name] = $target.relative
    $json = Get-Content -Raw -LiteralPath $target.full | ConvertFrom-Json
    $entries += [ordered]@{
      name = $name
      path = $target.relative
      required = $true
      exists = $true
      sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $target.full).Hash.ToLowerInvariant()
      schema = Get-StringField $json "schema"
      overall_status = Get-StringField $json "overall_status"
      status = Get-StringField $json "status"
    }
  }

  $manifest = [ordered]@{
    schema = "trusted_user_api_distribution_evidence_manifest.v1"
    hash_algorithm = "SHA256"
    entries = $entries
    missing_required_entries = @()
  }
  $links = [ordered]@{
    quota_template = $targetByName["trusted_user_quota_rate_budget_template"]
    accounting_gate = $targetByName["voucher_backed_api_distribution_accounting_gate"]
    guardrails = $targetByName["voucher_quota_pricing_guardrails"]
    remaining_balance_runtime = $targetByName["user_remaining_balance_runtime"]
    recharge_voucher_runtime = $targetByName["recharge_voucher_runtime"]
  }
  return [pscustomobject]@{ path = ".tmp/launch/e9_quota_record_verifier_selftest/manifest.synthetic.json"; manifest = [pscustomobject]$manifest; links = $links }
}

function New-SelfTestRecord {
  param([switch]$Placeholder, [switch]$BadMoney, [switch]$CurrencyMismatch, [switch]$Secret, [AllowNull()][object]$EvidenceLinks = $null)
  $now = (Get-Date).ToUniversalTime()
  if ($null -eq $EvidenceLinks) {
    $EvidenceLinks = [ordered]@{
      quota_template = ".tmp/launch/trusted_user_quota_rate_budget_record_template.json"
      accounting_gate = ".tmp/launch/voucher_backed_api_distribution_accounting_gate.json"
      guardrails = ".tmp/launch/voucher_quota_pricing_guardrails.json"
      remaining_balance_runtime = ".tmp/credit-wallet/user_remaining_balance_ownership_runtime.json"
      recharge_voucher_runtime = ".tmp/credit-wallet/recharge_voucher_runtime.json"
    }
  }
  $balance = Read-RepoJsonByRelativePath (Get-StringField $EvidenceLinks "remaining_balance_runtime")
  $voucher = Read-RepoJsonByRelativePath (Get-StringField $EvidenceLinks "recharge_voucher_runtime")
  $ledgerEntries = @(Get-Field $balance "ledger_entry_ids")
  $ledgerEntry = if ($ledgerEntries.Count -gt 0) { [string]$ledgerEntries[0] } else { "ledger-entry-selftest" }
  $voucherRef = Get-StringField $voucher "redemption_id"
  if ([string]::IsNullOrWhiteSpace($voucherRef)) { $voucherRef = Get-StringField $voucher "voucher_id" }
  $record = [ordered]@{
    schema = "trusted_user_quota_rate_budget_record.v1"
    real_user_values_present = $true
    tenant_id = Get-StringField $balance "tenant_id"
    project_id = Get-StringField $balance "project_id"
    trusted_user_id_or_owner_ref = Get-StringField $balance "user_id"
    wallet_id = Get-StringField $balance "wallet_id"
    virtual_key_id_or_key_prefix = "vk-selftest-prefix"
    operator_id = "operator-selftest"
    support_owner = "support-selftest"
    credit_amount_fixed_decimal_string = "100.00000000"
    currency = Get-StringField $balance "currency"
    credit_source = "voucher_redeem_or_credit_grant"
    voucher_id_or_redemption_id = $voucherRef
    credit_grant_id = Get-StringField $balance "credit_grant_id"
    ledger_entry_id = $ledgerEntry
    remaining_balance_available_to_spend_fixed_decimal_string = Get-StringField $balance "available_to_spend"
    model_or_canonical_model_id = "model-selftest"
    price_book_id_or_policy_ref = "price-book-selftest"
    price_version_id_or_model_cost_policy_ref = "price-version-selftest"
    price_policy_evidence_path = ".tmp/launch/voucher_quota_pricing_guardrails.json"
    rpm_limit_positive_integer = 60
    tpm_limit_positive_integer = 60000
    concurrency_limit_positive_integer_or_not_applicable = 4
    budget_limit_amount_fixed_decimal_string = "100.00000000"
    budget_window = [ordered]@{
      start_utc = $now.ToString("o")
      end_utc = $now.AddDays(30).ToString("o")
    }
    api_key_profile_id_or_profile_binding_id = "profile-selftest"
    credit_valid_until_utc = $now.AddDays(30).ToString("o")
    virtual_key_expires_at_utc = $now.AddDays(30).ToString("o")
    revoke_or_disable_procedure = "disable_or_expire_virtual_key_and_revoke_or_expire_credit"
    rollback_contact = "rollback-selftest"
    audit_id_or_support_ticket_id = "audit-selftest"
    record_generated_at_utc = $now.ToString("o")
    evidence_links = $EvidenceLinks
    secret_safe = $true
    paid_gate_changed = $false
  }
  if ($Placeholder) { $record.tenant_id = "<tenant-id>"; $record.real_user_values_present = $false }
  if ($BadMoney) { $record.credit_amount_fixed_decimal_string = "10.5" }
  if ($CurrencyMismatch) { $record.currency = "usd" }
  if ($Secret) { $record.voucher_id_or_redemption_id = "raw_voucher_code:secret" }
  return [pscustomobject]$record
}

if ($SelfTest) {
  $manifestInfo = New-SelfTestManifestInfo
  $cases = @(
    [ordered]@{ name = "synthetic_bounded_record_passes"; result = Test-RecordObject (New-SelfTestRecord -EvidenceLinks $manifestInfo.links) "selftest:good" $manifestInfo.path $manifestInfo; expect = "pass" },
    [ordered]@{ name = "placeholder_record_blocks"; result = Test-RecordObject (New-SelfTestRecord -Placeholder -EvidenceLinks $manifestInfo.links) "selftest:placeholder" $manifestInfo.path $manifestInfo; expect = "blocked" },
    [ordered]@{ name = "bad_money_blocks"; result = Test-RecordObject (New-SelfTestRecord -BadMoney -EvidenceLinks $manifestInfo.links) "selftest:bad_money" $manifestInfo.path $manifestInfo; expect = "blocked" },
    [ordered]@{ name = "currency_mismatch_blocks"; result = Test-RecordObject (New-SelfTestRecord -CurrencyMismatch -EvidenceLinks $manifestInfo.links) "selftest:currency" $manifestInfo.path $manifestInfo; expect = "blocked" },
    [ordered]@{ name = "secret_like_record_blocks"; result = Test-RecordObject (New-SelfTestRecord -Secret -EvidenceLinks $manifestInfo.links) "selftest:secret" $manifestInfo.path $manifestInfo; expect = "blocked" }
  )
  $failed = @($cases | Where-Object { $_.result.status -ne $_.expect })
  $status = if ($failed.Count -eq 0) { "pass" } else { "fail" }
  [ordered]@{
    schema = "trusted_user_quota_rate_budget_record_verifier_selftest.v1"
    overall_status = $status
    cases = $cases
  } | ConvertTo-Json -Depth 12
  if ($status -eq "pass") { exit 0 }
  exit 1
}

if ([string]::IsNullOrWhiteSpace($RecordPath)) {
  $result = [ordered]@{
    schema = "trusted_user_quota_rate_budget_record_verification.v1"
    status = "blocked_runtime_input_required"
    ready_for_handoff = $false
    actual_exit_code = 2
    record_path = ""
    evidence_manifest_path = $EvidenceManifestPath
    missing_fields = @("record_path")
    blockers = @("real_per_user_quota_rate_budget_record_required")
    external_inputs_required = @("real_per_user_quota_rate_budget_record")
    missing_real_per_user_quota_record_classification = "external_input_required"
    global_api_distribution_blocker = $false
    ready_to_send_to_user = $false
    no_raw_secret_material_expected = $true
  }
  $result["artifact_path"] = Write-VerificationArtifact -Result $result -Path $OutputPath
  $result | ConvertTo-Json -Depth 8
  exit 2
}

$recordResolved = Resolve-RepoPath $RecordPath
$outputResolved = Resolve-RepoPath $OutputPath
if (-not (Test-Path -LiteralPath $recordResolved.full -PathType Leaf)) {
  $result = [ordered]@{
    schema = "trusted_user_quota_rate_budget_record_verification.v1"
    status = "blocked_runtime_input_required"
    ready_for_handoff = $false
    actual_exit_code = 2
    record_path = $recordResolved.relative
    evidence_manifest_path = $EvidenceManifestPath
    missing_fields = @("record_file")
    blockers = @("real_per_user_quota_rate_budget_record_missing")
    external_inputs_required = @("real_per_user_quota_rate_budget_record")
    missing_real_per_user_quota_record_classification = "external_input_required"
    global_api_distribution_blocker = $false
    ready_to_send_to_user = $false
    no_raw_secret_material_expected = $true
  }
  $result["artifact_path"] = Write-VerificationArtifact -Result $result -Path $OutputPath
  $result | ConvertTo-Json -Depth 8
  exit 2
}

$record = Get-Content -Raw -LiteralPath $recordResolved.full | ConvertFrom-Json
$manifestInfo = Read-Manifest $EvidenceManifestPath
$result = Test-RecordObject -Record $record -RecordPathForReport $recordResolved.relative -ManifestPathForReport $manifestInfo.path -ManifestInfo $manifestInfo

$parent = Split-Path -Parent $outputResolved.full
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
$result["artifact_path"] = $outputResolved.relative
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outputResolved.full -Encoding utf8
$result | ConvertTo-Json -Depth 12
exit ([int]$result.actual_exit_code)
