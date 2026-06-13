param(
  [string]$ReleaseOwner = "",
  [string]$SupportContact = "",
  [string]$TenantId = "",
  [string]$ProjectId = "",
  [string]$WalletId = "",
  [string]$VoucherQuota = "",
  [string]$RateBudgetGuardrails = "",
  [string]$RollbackOwner = "",
  [string]$PacketPath = ".tmp\launch\trusted_user_distribution_review_packet.json",
  [string]$SummaryPath = ".tmp\launch\trusted_user_api_distribution_handoff_summary.json",
  [string]$ReleaseSummaryPath = "artifacts\launch_voucher_api_distribution_release_check_20260606.json",
  [switch]$AllowMissingUserFields,
  [switch]$SyntheticHandoffSelfTest,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

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

function ConvertTo-JsonObject {
  param([Parameter(Mandatory = $true)][string]$Text)
  $trimmed = $Text.Trim()
  if ([string]::IsNullOrWhiteSpace($trimmed)) { return $null }
  return $trimmed | ConvertFrom-Json
}

function Invoke-CheckedScript {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [int[]]$AllowedExitCodes = @(0)
  )
  $output = & pwsh -NoProfile -ExecutionPolicy Bypass @Arguments 2>&1 | Out-String
  $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  $status = if ($AllowedExitCodes -contains $exitCode) { "accepted" } else { "failed" }
  return [ordered]@{
    name = $Name
    command = "pwsh -NoProfile -ExecutionPolicy Bypass " + ($Arguments -join " ")
    exit_code = $exitCode
    status = $status
    output = $output.Trim()
  }
}

function Get-Field {
  param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $Name) { return $null }
  return $Object.PSObject.Properties[$Name].Value
}

function Get-StringField {
  param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
  $value = Get-Field -Object $Object -Name $Name
  if ($null -eq $value) { return "" }
  if ($value -is [datetime]) { return $value.ToUniversalTime().ToString("o") }
  return [string]$value
}

function Get-ArrayFieldCount {
  param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
  $value = Get-Field -Object $Object -Name $Name
  if ($null -eq $value) { return 0 }
  return @($value).Count
}

function Test-FilledValue {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return -not ($Value -match '^<.*>$' -or $Value -match '^to_be_filled' -or $Value -eq "missing")
}

function Test-SecretSafeOperatorText {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
  $secretPattern = '(?i)(authorization|bearer\s+[a-z0-9_\-\.]+|cookie|sk-[a-z0-9]|x-api-key|postgres(?:ql)?://|mysql://|redis://|raw[_ -]?(voucher|key|secret)|provider[_ -]?key|virtual[_ -]?key[_ -]?secret|dev_test_key)'
  return -not ($Value -match $secretPattern)
}

function Test-SecretSafeArtifactText {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
  $secretPattern = '(?i)(bearer\s+[a-z0-9_\-\.]{8,}|sk-[a-z0-9]{8,}|x-api-key\s*[:=]\s*\S+|postgres(?:ql)?://|mysql://|redis://|raw[_ -]?voucher[_ -]?code\s*[:=]\s*\S+|raw[_ -]?virtual[_ -]?key\s*[:=]\s*\S+|virtual[_ -]?key[_ -]?secret\s*[:=]\s*\S+|full[_ -]?virtual[_ -]?key\s*[:=]\s*\S+|provider[_ -]?key\s*[:=]\s*\S+|db[_ -]?url\s*[:=]\s*\S+|raw[_ -]?provider[_ -]?payload\s*[:=]\s*\S+|raw[_ -]?request[_ -]?body\s*[:=]\s*\S+|dev_test_key)'
  return -not ($Value -match $secretPattern)
}

function Test-SecretSafeObject {
  param([AllowNull()][object]$Object)
  if ($null -eq $Object) { return $true }
  if ($Object -is [string] -or $Object -is [ValueType]) {
    return (Test-SecretSafeArtifactText ([string]$Object))
  }
  if ($Object -is [System.Collections.IDictionary]) {
    foreach ($key in $Object.Keys) {
      if (-not (Test-SecretSafeObject $Object[$key])) { return $false }
    }
    return $true
  }
  if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
    foreach ($item in $Object) {
      if (-not (Test-SecretSafeObject $item)) { return $false }
    }
    return $true
  }
  foreach ($property in $Object.PSObject.Properties) {
    if (-not (Test-SecretSafeObject $property.Value)) { return $false }
  }
  return $true
}

function Add-SyntheticHandoffMarker {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ArtifactKind
  )
  $resolved = Resolve-RepoPath $Path
  $json = Get-Content -Raw -LiteralPath $resolved.full | ConvertFrom-Json
  $json | Add-Member -NotePropertyName "synthetic" -NotePropertyValue $true -Force
  $json | Add-Member -NotePropertyName "not_real_user" -NotePropertyValue $true -Force
  $json | Add-Member -NotePropertyName "handoff_rehearsal_only" -NotePropertyValue $true -Force
  $json | Add-Member -NotePropertyName "must_not_send_to_user" -NotePropertyValue $true -Force
  $json | Add-Member -NotePropertyName "artifact_kind" -NotePropertyValue $ArtifactKind -Force
  $json | Add-Member -NotePropertyName "secret_safe" -NotePropertyValue $true -Force
  $json | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolved.full -Encoding utf8
  return $json
}

function Get-EvidenceArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Path,
    [bool]$Required = $true
  )

  $resolved = Resolve-RepoPath $Path
  $entry = [ordered]@{
    name = $Name
    path = $resolved.relative
    required = $Required
    exists = $false
    bytes = 0
    sha256 = $null
    schema = $null
    status = $null
    overall_status = $null
    ready_to_send = $null
    blockers_count = $null
    missing_fields_count = $null
    generated_at_utc = $null
  }

  if (-not (Test-Path -LiteralPath $resolved.full -PathType Leaf)) {
    return $entry
  }

  $item = Get-Item -LiteralPath $resolved.full
  $entry.exists = $true
  $entry.bytes = [int64]$item.Length
  $entry.sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolved.full).Hash.ToLowerInvariant()

  try {
    $json = Get-Content -Raw -LiteralPath $resolved.full | ConvertFrom-Json
    $entry.schema = Get-StringField $json "schema"
    $entry.status = Get-StringField $json "status"
    $entry.overall_status = Get-StringField $json "overall_status"
    if ([string]::IsNullOrWhiteSpace($entry.overall_status)) {
      $entry.overall_status = Get-StringField $json "overallStatus"
    }
    $ready = Get-Field $json "ready_to_send"
    if ($ready -is [bool]) { $entry.ready_to_send = [bool]$ready }
    $entry.blockers_count = Get-ArrayFieldCount $json "blockers"
    $entry.missing_fields_count = Get-ArrayFieldCount $json "missing_fields"
    $entry.generated_at_utc = Get-StringField $json "generated_at_utc"
  } catch {
    $entry.status = "json_parse_failed"
  }

  return $entry
}

function New-EvidenceManifest {
  param(
    [Parameter(Mandatory = $true)][object]$PacketResolved,
    [Parameter(Mandatory = $true)][object]$ReleaseResolved
  )

  $entries = @(
    $(Get-EvidenceArtifact -Name "trusted_user_distribution_packet" -Path ([string]$PacketResolved.relative)),
    $(Get-EvidenceArtifact -Name "launch_release_check_summary" -Path ([string]$ReleaseResolved.relative)),
    $(Get-EvidenceArtifact -Name "trusted_user_quota_rate_budget_template" -Path ".tmp/launch/trusted_user_quota_rate_budget_record_template.json"),
    $(Get-EvidenceArtifact -Name "voucher_api_distribution_readiness" -Path ".tmp/launch/voucher_api_distribution_readiness.json"),
    $(Get-EvidenceArtifact -Name "voucher_backed_api_distribution_accounting_gate" -Path ".tmp/launch/voucher_backed_api_distribution_accounting_gate.json"),
    $(Get-EvidenceArtifact -Name "e8_gateway_paid_hot_path_launch_check" -Path ".tmp/launch/e8_gateway_paid_hot_path_launch_check.json"),
    $(Get-EvidenceArtifact -Name "gateway_voucher_distribution_readiness" -Path ".tmp/launch/gateway_voucher_distribution_readiness.json"),
    $(Get-EvidenceArtifact -Name "voucher_quota_pricing_guardrails" -Path ".tmp/launch/voucher_quota_pricing_guardrails.json"),
    $(Get-EvidenceArtifact -Name "voucher_public_route_and_virtual_key_evidence" -Path ".tmp/launch/voucher_public_route_and_virtual_key_evidence.json"),
    $(Get-EvidenceArtifact -Name "api_distribution_operator_packet" -Path ".tmp/launch/api_distribution_operator_packet.json" -Required $false),
    $(Get-EvidenceArtifact -Name "voucher_operator_only_exception" -Path ".tmp/launch/voucher_operator_only_exception.json" -Required $false),
    $(Get-EvidenceArtifact -Name "user_remaining_balance_runtime" -Path ".tmp/credit-wallet/user_remaining_balance_ownership_runtime.json"),
    $(Get-EvidenceArtifact -Name "recharge_voucher_runtime" -Path ".tmp/credit-wallet/recharge_voucher_runtime.json")
  )

  $missingRequired = @($entries | Where-Object { $_.required -and -not $_.exists } | ForEach-Object { $_.name })
  return [ordered]@{
    schema = "trusted_user_api_distribution_evidence_manifest.v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    hash_algorithm = "SHA256"
    entries = $entries
    missing_required_entries = $missingRequired
    no_raw_secret_material_expected = $true
    notes = @(
      "Manifest stores repo-bounded paths, hashes, sizes, schemas, statuses, and counts only.",
      "Developer distribution packet readback is exposed as GET /user/developer-distribution-packet-readback; this packet references the endpoint and does not run release validation.",
      "Do not store raw voucher codes, full virtual keys, Authorization/Cookie headers, provider keys, DB URLs, raw request bodies, or raw provider payloads in handoff records."
    )
  }
}

function New-Summary {
  param(
    [Parameter(Mandatory = $true)][object]$QuotaStep,
    [Parameter(Mandatory = $true)][object]$PacketStep,
    [Parameter(Mandatory = $true)][object]$ReleaseStep,
    [Parameter(Mandatory = $true)][object]$SecretScanStep,
    [AllowNull()][object]$PacketResult,
    [AllowNull()][object]$ReleaseResult,
    [Parameter(Mandatory = $true)][object]$PacketResolved,
    [Parameter(Mandatory = $true)][object]$SummaryResolved,
    [Parameter(Mandatory = $true)][object]$ReleaseResolved,
    [Parameter(Mandatory = $true)][object]$EvidenceManifest
  )

  $packetExit = [int]$PacketStep.exit_code
  $secretScanPassed = ([int]$SecretScanStep.exit_code -eq 0)
  $releaseStatus = [string](Get-Field $ReleaseResult "overallStatus")
  if ([string]::IsNullOrWhiteSpace($releaseStatus)) { $releaseStatus = [string](Get-Field $ReleaseResult "overall_status") }
  $readyToSend = [bool](Get-Field $PacketResult "ready_to_send")
  $missingFields = @(Get-Field $PacketResult "missing_fields")
  $blockers = @(Get-Field $PacketResult "blockers")
  $userFieldsOnly = ($packetExit -eq 2 -and $blockers.Count -eq 0 -and $missingFields.Count -gt 0)

  $overall = if ($readyToSend -and $secretScanPassed -and ([int]$ReleaseStep.exit_code -eq 0)) {
    "ready_to_send_trusted_user_beta"
  } elseif ($userFieldsOnly -and $AllowMissingUserFields) {
    "blocked_by_missing_user_fields_only"
  } else {
    "blocked_or_failed"
  }

  [ordered]@{
    schema = "trusted_user_api_distribution_handoff_summary.v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    overall_status = $overall
    ready_to_send = $readyToSend
    packet_path = $PacketResolved.relative
    summary_path = $SummaryResolved.relative
    release_summary_path = $ReleaseResolved.relative
    missing_fields = $missingFields
    blockers = $blockers
    release_check_overall_status = $releaseStatus
    secret_scan_passed = $secretScanPassed
    no_raw_secret_material_expected = $true
    evidence_manifest = $EvidenceManifest
    external_input_policy = [ordered]@{
      missing_real_user_fields_are_deferred = $userFieldsOnly
      reason = "release_owner/support/tenant/project/wallet/quota/rate-budget/rollback values cannot be fabricated locally"
    }
    steps = @(
      [ordered]@{ name = $QuotaStep.name; exit_code = $QuotaStep.exit_code; status = $QuotaStep.status },
      [ordered]@{ name = $PacketStep.name; exit_code = $PacketStep.exit_code; status = $PacketStep.status },
      [ordered]@{ name = $ReleaseStep.name; exit_code = $ReleaseStep.exit_code; status = $ReleaseStep.status },
      [ordered]@{ name = $SecretScanStep.name; exit_code = $SecretScanStep.exit_code; status = $SecretScanStep.status }
    )
    next_action = if ($overall -eq "ready_to_send_trusted_user_beta") {
      "handoff packet is ready for selected trusted user after operator review"
    } elseif ($userFieldsOnly) {
      "fill the missing per-user fields, rerun this script without AllowMissingUserFields, then hand off"
    } else {
      "review blockers and failed steps before API distribution"
    }
  }
}

function New-SyntheticQuotaRateBudgetRecord {
  param([Parameter(Mandatory = $true)][string]$RecordPath)
  $resolved = Resolve-RepoPath $RecordPath
  $parent = Split-Path -Parent $resolved.full
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $now = (Get-Date).ToUniversalTime()
  $balancePath = Resolve-RepoPath ".tmp/credit-wallet/user_remaining_balance_ownership_runtime.json"
  $voucherPath = Resolve-RepoPath ".tmp/credit-wallet/recharge_voucher_runtime.json"
  $balance = Get-Content -Raw -LiteralPath $balancePath.full | ConvertFrom-Json
  $voucher = Get-Content -Raw -LiteralPath $voucherPath.full | ConvertFrom-Json
  $ledgerEntryIds = @(Get-Field $balance "ledger_entry_ids")
  $ledgerEntryId = if ($ledgerEntryIds.Count -gt 0) { [string]$ledgerEntryIds[0] } else { "ledger-entry-synthetic" }
  $currency = Get-StringField $balance "currency"
  if ([string]::IsNullOrWhiteSpace($currency)) { $currency = Get-StringField $voucher "currency" }
  $voucherRef = Get-StringField $voucher "redemption_id"
  if ([string]::IsNullOrWhiteSpace($voucherRef)) { $voucherRef = Get-StringField $voucher "voucher_id" }
  $record = [ordered]@{
    schema = "trusted_user_quota_rate_budget_record.v1"
    synthetic = $true
    not_real_user = $true
    handoff_rehearsal_only = $true
    must_not_send_to_user = $true
    artifact_kind = "synthetic_trusted_user_quota_rate_budget_record"
    real_user_values_present = $true
    tenant_id = Get-StringField $balance "tenant_id"
    project_id = Get-StringField $balance "project_id"
    trusted_user_id_or_owner_ref = Get-StringField $balance "user_id"
    wallet_id = Get-StringField $balance "wallet_id"
    virtual_key_id_or_key_prefix = "vk-synthetic-prefix"
    operator_id = "operator-synthetic"
    support_owner = "support-synthetic"
    credit_amount_fixed_decimal_string = "100.00000000"
    currency = $currency
    credit_source = "voucher_redeem_or_credit_grant"
    voucher_id_or_redemption_id = $voucherRef
    credit_grant_id = Get-StringField $balance "credit_grant_id"
    ledger_entry_id = $ledgerEntryId
    remaining_balance_available_to_spend_fixed_decimal_string = Get-StringField $balance "available_to_spend"
    model_or_canonical_model_id = "model-synthetic"
    price_book_id_or_policy_ref = "price-book-synthetic"
    price_version_id_or_model_cost_policy_ref = "price-version-synthetic"
    price_policy_evidence_path = ".tmp/launch/voucher_quota_pricing_guardrails.json"
    rpm_limit_positive_integer = 60
    tpm_limit_positive_integer = 60000
    concurrency_limit_positive_integer_or_not_applicable = 4
    budget_limit_amount_fixed_decimal_string = "100.00000000"
    budget_window = [ordered]@{
      start_utc = $now.ToString("o")
      end_utc = $now.AddDays(30).ToString("o")
    }
    api_key_profile_id_or_profile_binding_id = "profile-synthetic"
    credit_valid_until_utc = $now.AddDays(30).ToString("o")
    virtual_key_expires_at_utc = $now.AddDays(30).ToString("o")
    revoke_or_disable_procedure = "disable_or_expire_virtual_key_and_revoke_or_expire_credit"
    rollback_contact = "rollback-synthetic"
    audit_id_or_support_ticket_id = "audit-synthetic"
    record_generated_at_utc = $now.ToString("o")
    evidence_links = [ordered]@{
      quota_template = ".tmp/launch/trusted_user_quota_rate_budget_record_template.json"
      accounting_gate = ".tmp/launch/voucher_backed_api_distribution_accounting_gate.json"
      guardrails = ".tmp/launch/voucher_quota_pricing_guardrails.json"
      remaining_balance_runtime = ".tmp/credit-wallet/user_remaining_balance_ownership_runtime.json"
      recharge_voucher_runtime = ".tmp/credit-wallet/recharge_voucher_runtime.json"
    }
    secret_safe = $true
    paid_gate_changed = $false
    no_raw_secret_material_expected = $true
  }
  $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolved.full -Encoding utf8
  return [pscustomobject]@{ relative = $resolved.relative; full = $resolved.full; record = [pscustomobject]$record }
}

if ($SelfTest -or $SyntheticHandoffSelfTest) {
  $ReleaseOwner = "release-owner"
  $SupportContact = "support-channel"
  $TenantId = if ($SyntheticHandoffSelfTest) { "tenant-synthetic" } else { "tenant-selftest" }
  $ProjectId = if ($SyntheticHandoffSelfTest) { "project-synthetic" } else { "project-selftest" }
  $WalletId = if ($SyntheticHandoffSelfTest) { "wallet-synthetic" } else { "wallet-selftest" }
  $VoucherQuota = if ($SyntheticHandoffSelfTest) { "campaign-synthetic:100.00000000" } else { "campaign-selftest:100.00000000" }
  $RateBudgetGuardrails = if ($SyntheticHandoffSelfTest) { "rpm=60;tpm=60000;budget=100.00000000;record=.tmp/launch/trusted_user_quota_rate_budget_record.synthetic.json" } else { "rpm=60;tpm=60000;budget=100.00000000;record=.tmp/launch/trusted_user_quota_rate_budget_record_template.json" }
  $RollbackOwner = "rollback-owner"
  $PacketPath = if ($SyntheticHandoffSelfTest) { ".tmp\launch\trusted_user_distribution_review_packet.synthetic.json" } else { ".tmp\launch\trusted_user_distribution_review_packet.filled_selftest.json" }
  $SummaryPath = if ($SyntheticHandoffSelfTest) { ".tmp\launch\trusted_user_api_distribution_handoff_summary.synthetic.json" } else { ".tmp\launch\trusted_user_api_distribution_handoff_summary.selftest.json" }
}

foreach ($value in @($ReleaseOwner, $SupportContact, $TenantId, $ProjectId, $WalletId, $VoucherQuota, $RateBudgetGuardrails, $RollbackOwner)) {
  if (-not (Test-SecretSafeOperatorText $value)) {
    throw "operator_input_contains_secret_like_material"
  }
}

$requiredValues = [ordered]@{
  release_owner = $ReleaseOwner
  support_contact = $SupportContact
  tenant_id = $TenantId
  project_id = $ProjectId
  wallet_id = $WalletId
  voucher_quota = $VoucherQuota
  rate_budget_guardrails = $RateBudgetGuardrails
  rollback_owner = $RollbackOwner
}
$missingInput = @($requiredValues.GetEnumerator() | Where-Object { -not (Test-FilledValue ([string]$_.Value)) } | ForEach-Object { $_.Key })
if ($missingInput.Count -gt 0 -and -not $AllowMissingUserFields) {
  $AllowMissingUserFields = $true
}

$packetResolved = Resolve-RepoPath $PacketPath
$summaryResolved = Resolve-RepoPath $SummaryPath
$releaseResolved = Resolve-RepoPath $ReleaseSummaryPath
foreach ($dir in @((Split-Path -Parent $packetResolved.full), (Split-Path -Parent $summaryResolved.full), (Split-Path -Parent $releaseResolved.full))) {
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
}

$quotaStep = Invoke-CheckedScript -Name "quota_rate_budget_template" -Arguments @("-File", "scripts/write_trusted_user_quota_rate_budget_record_template.ps1")

$packetArgs = @(
  "-File", "scripts/verify_trusted_user_distribution_review_packet.ps1",
  "-WriteDefaultPacket",
  "-PacketPath", $packetResolved.relative
)
foreach ($pair in @(
  [ordered]@{ name = "-ReleaseOwner"; value = $ReleaseOwner },
  [ordered]@{ name = "-SupportContact"; value = $SupportContact },
  [ordered]@{ name = "-TenantId"; value = $TenantId },
  [ordered]@{ name = "-ProjectId"; value = $ProjectId },
  [ordered]@{ name = "-WalletId"; value = $WalletId },
  [ordered]@{ name = "-VoucherQuota"; value = $VoucherQuota },
  [ordered]@{ name = "-RateBudgetGuardrails"; value = $RateBudgetGuardrails },
  [ordered]@{ name = "-RollbackOwner"; value = $RollbackOwner }
)) {
  if (Test-FilledValue ([string]$pair.value)) {
    $packetArgs += @($pair.name, [string]$pair.value)
  }
}
$allowedPacketExits = if ($AllowMissingUserFields) { @(0, 2) } else { @(0) }
$packetStep = Invoke-CheckedScript -Name "trusted_user_distribution_packet" -Arguments $packetArgs -AllowedExitCodes $allowedPacketExits
$packetResult = ConvertTo-JsonObject $packetStep.output
if ($SyntheticHandoffSelfTest -and [int]$packetStep.exit_code -eq 0) {
  $packetResult = Add-SyntheticHandoffMarker -Path $packetResolved.relative -ArtifactKind "synthetic_trusted_user_distribution_packet"
}

$releaseStep = Invoke-CheckedScript -Name "launch_release_check" -Arguments @("-File", "scripts/release_check.ps1", "-Checks", "launch", "-SummaryPath", $releaseResolved.relative)
$releaseResult = ConvertTo-JsonObject $releaseStep.output

$secretScanStep = Invoke-CheckedScript -Name "secret_scan" -Arguments @("-File", "scripts/scan_secrets.ps1")
$evidenceManifest = New-EvidenceManifest -PacketResolved $packetResolved -ReleaseResolved $releaseResolved

$summary = New-Summary `
  -QuotaStep $quotaStep `
  -PacketStep $packetStep `
  -ReleaseStep $releaseStep `
  -SecretScanStep $secretScanStep `
  -PacketResult $packetResult `
  -ReleaseResult $releaseResult `
  -PacketResolved $packetResolved `
  -SummaryResolved $summaryResolved `
  -ReleaseResolved $releaseResolved `
  -EvidenceManifest $evidenceManifest

if ($SyntheticHandoffSelfTest) {
  $summary.synthetic = $true
  $summary.not_real_user = $true
  $summary.handoff_rehearsal_only = $true
  $summary.must_not_send_to_user = $true
  $summary.artifact_kind = "synthetic_trusted_user_api_distribution_handoff_summary"
  $summary.secret_safe = $true
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryResolved.full -Encoding utf8

if ($SyntheticHandoffSelfTest) {
  $recordInfo = New-SyntheticQuotaRateBudgetRecord -RecordPath ".tmp\launch\trusted_user_quota_rate_budget_record.synthetic.json"
  $manifestStep = Invoke-CheckedScript -Name "synthetic_manifest_verifier" -Arguments @("-File", "scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1", "-SummaryPath", $summaryResolved.relative)
  $quotaVerifyPath = ".tmp/launch/trusted_user_quota_rate_budget_record_verification.synthetic.json"
  $quotaVerifyStep = Invoke-CheckedScript -Name "synthetic_quota_record_verifier" -Arguments @("-File", "scripts/verify_trusted_user_quota_rate_budget_record.ps1", "-RecordPath", $recordInfo.relative, "-EvidenceManifestPath", $summaryResolved.relative, "-OutputPath", $quotaVerifyPath)
  $metadataOnly = (Test-SecretSafeObject $summary) -and (Test-SecretSafeObject $packetResult) -and (Test-SecretSafeObject $recordInfo.record)
  $syntheticResult = [ordered]@{
    schema = "trusted_user_api_distribution_synthetic_handoff_selftest.v1"
    overall_status = if (
      $summary.overall_status -eq "ready_to_send_trusted_user_beta" -and
      [int]$manifestStep.exit_code -eq 0 -and
      [int]$quotaVerifyStep.exit_code -eq 0 -and
      $metadataOnly
    ) { "pass" } else { "fail" }
    synthetic = $true
    not_real_user = $true
    handoff_rehearsal_only = $true
    must_not_send_to_user = $true
    secret_safe = $metadataOnly
    metadata_only = $metadataOnly
    no_raw_secret_material_expected = $true
    packet_path = $packetResolved.relative
    record_path = $recordInfo.relative
    summary_path = $summaryResolved.relative
    quota_verification_path = $quotaVerifyPath
    steps = @(
      [ordered]@{ name = $QuotaStep.name; exit_code = $QuotaStep.exit_code; status = $QuotaStep.status },
      [ordered]@{ name = $PacketStep.name; exit_code = $PacketStep.exit_code; status = $PacketStep.status },
      [ordered]@{ name = $ReleaseStep.name; exit_code = $ReleaseStep.exit_code; status = $ReleaseStep.status },
      [ordered]@{ name = $SecretScanStep.name; exit_code = $SecretScanStep.exit_code; status = $SecretScanStep.status },
      [ordered]@{ name = $manifestStep.name; exit_code = $manifestStep.exit_code; status = $manifestStep.status },
      [ordered]@{ name = $quotaVerifyStep.name; exit_code = $quotaVerifyStep.exit_code; status = $quotaVerifyStep.status }
    )
    acceptance = [ordered]@{
      target_user_packet_ready = $summary.ready_to_send
      manifest_verifier_exit_0 = ([int]$manifestStep.exit_code -eq 0)
      quota_verifier_exit_0 = ([int]$quotaVerifyStep.exit_code -eq 0)
      synthetic_outputs_marked = $true
      real_handoff_not_mixed = $true
    }
    blockers = @(
      if ($summary.overall_status -ne "ready_to_send_trusted_user_beta") { "synthetic_summary_not_ready" }
      if ([int]$manifestStep.exit_code -ne 0) { "manifest_verifier_failed" }
      if ([int]$quotaVerifyStep.exit_code -ne 0) { "quota_verifier_failed" }
      if (-not $metadataOnly) { "secret_like_or_non_metadata_output_detected" }
    )
  }
  $syntheticResult | ConvertTo-Json -Depth 12
  if ($syntheticResult.overall_status -eq "pass") { exit 0 }
  exit 1
}

$summary | ConvertTo-Json -Depth 10

if ($summary.overall_status -eq "ready_to_send_trusted_user_beta") { exit 0 }
if ($summary.overall_status -eq "blocked_by_missing_user_fields_only" -and $AllowMissingUserFields) { exit 2 }
exit 1
