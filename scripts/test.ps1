param(
  # Targeted gates below are intentionally narrower than the default full local wrapper.
  # -FullDistributionGateOnly validates the trusted-user API distribution launch gate, not full CI.
  # Admin UI switches run local UI gates without reinstalling dependencies.
  [switch]$GatewayRateLimitReservationSmokeOnly,
  [switch]$GatewayRateLimitReservationSmokePreflight,
  [switch]$GatewayRateLimitReservationSmokeLive,
  [switch]$ControlPlaneLedgerAdjustmentExecuteSmokeOnly,
  [switch]$ControlPlaneLedgerAdjustmentExecuteSmokeLive,
  [switch]$ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly,
  [switch]$PromptProtectionPostgresProofOnly,
  [switch]$PromptProtectionPostgresProofLive,
  [switch]$GatewayProtocolContractsOnly,
  [switch]$BillingBetaModeReadinessOnly,
  [switch]$FullDistributionGateOnly,
  [switch]$AdminUiTestOnly,
  [switch]$AdminUiBundleGateOnly
)

$ErrorActionPreference = "Stop"

function Test-TruthyEnv {
  param([AllowNull()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  return @("1", "true", "yes", "on").Contains($Value.Trim().ToLowerInvariant())
}

function Invoke-CheckedScript {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [hashtable]$Parameters = @{}
  )

  $global:LASTEXITCODE = 0
  & $Path @Parameters
  $scriptSucceeded = $?
  $exitCode = $global:LASTEXITCODE
  if (-not $scriptSucceeded) {
    if ($null -ne $exitCode -and $exitCode -ne 0) { exit $exitCode }
    exit 1
  }
  if ($null -ne $exitCode -and $exitCode -ne 0) { exit $exitCode }
}

function Get-GatewayRateLimitReservationSmokeParameters {
  if ($GatewayRateLimitReservationSmokeLive) {
    return @{}
  }

  if ($GatewayRateLimitReservationSmokePreflight) {
    return @{ PreflightOnly = $true }
  }

  return @{ DryRun = $true }
}

function Invoke-GatewayRateLimitReservationSmoke {
  $mode = "dry-run"
  if ($GatewayRateLimitReservationSmokeLive) {
    $mode = "live"
  } elseif ($GatewayRateLimitReservationSmokePreflight) {
    $mode = "preflight"
  }

  Write-Host "Gateway rate-limit reservation smoke mode: $mode"
  Invoke-CheckedScript `
    -Path "$PSScriptRoot\verify_gateway_rate_limit_reservation_smoke.ps1" `
    -Parameters (Get-GatewayRateLimitReservationSmokeParameters)
}

function Get-ControlPlaneLedgerAdjustmentExecuteSmokeParameters {
  if ($ControlPlaneLedgerAdjustmentExecuteSmokeLive) {
    return @{}
  }

  return @{ ContractOnly = $true }
}

function Invoke-ControlPlaneLedgerAdjustmentExecuteSmoke {
  $mode = "contract-only"
  if ($ControlPlaneLedgerAdjustmentExecuteSmokeLive) {
    $mode = "live"
  }

  Write-Host "Control Plane ledger adjustment execute smoke mode: $mode"
  Invoke-CheckedScript `
    -Path "$PSScriptRoot\verify_control_plane_ledger_adjustment_openapi_contract.ps1"
  Invoke-CheckedScript `
    -Path "$PSScriptRoot\verify_control_plane_ledger_adjustment_execute_smoke.ps1" `
    -Parameters (Get-ControlPlaneLedgerAdjustmentExecuteSmokeParameters)
}

function Invoke-ControlPlaneLedgerAdjustmentExecuteBrowserReadback {
  Write-Host "Control Plane ledger adjustment execute browser artifact readback mode: readback-only"
  Invoke-CheckedScript `
    -Path "$PSScriptRoot\verify_control_plane_ledger_adjustment_execute_smoke.ps1" `
    -Parameters @{
      ArtifactReadbackOnly = $true
      RuntimeCurrentEvidenceArtifactPath = "artifacts/control_plane_ledger_execute_runtime_current_verified_beta.json"
      BrowserEvidenceArtifactPath = "artifacts/billing_execute_browser_live_e2e_evidence.json"
    }
}

function Get-PromptProtectionPostgresProofParameters {
  if ($PromptProtectionPostgresProofLive) {
    return @{ Live = $true }
  }

  return @{ ContractOnly = $true }
}

function Invoke-PromptProtectionPostgresProof {
  $mode = "contract-only"
  if ($PromptProtectionPostgresProofLive) {
    $mode = "live"
  }

  Write-Host "Prompt Protection Postgres proof mode: $mode"
  Invoke-CheckedScript `
    -Path "$PSScriptRoot\verify_prompt_protection_postgres_proof.ps1" `
    -Parameters (Get-PromptProtectionPostgresProofParameters)
}

function Invoke-BillingBetaModeReadiness {
  Write-Host "Billing beta mode readiness: usage-only pass + paid refusal"

  Invoke-CheckedScript `
    -Path "$PSScriptRoot\verify_billing_beta_mode_readiness.ps1" `
    -Parameters @{ BillingMode = "usage_only_beta" }

  $ps = Get-Command pwsh -ErrorAction SilentlyContinue
  if (-not $ps) {
    $ps = Get-Command powershell -ErrorAction SilentlyContinue
  }
  if (-not $ps) {
    Write-Error "PowerShell executable not found for paid_controlled_beta refusal check."
    exit 127
  }

  $psArgs = @("-NoProfile")
  if ((Split-Path -Leaf $ps.Source) -match '(?i)^powershell(\.exe)?$') {
    $psArgs += @("-ExecutionPolicy", "Bypass")
  }
  $psArgs += @("-File", "$PSScriptRoot\verify_billing_beta_mode_readiness.ps1", "-BillingMode", "paid_controlled_beta")

  $global:LASTEXITCODE = 0
  & $ps.Source @psArgs
  $paidExitCode = $global:LASTEXITCODE
  if ($null -eq $paidExitCode -or $paidExitCode -eq 0) {
    Write-Error "paid_controlled_beta readiness gate unexpectedly passed without TODO-30 evidence."
    exit 1
  }

  Write-Host "paid_controlled_beta readiness gate refused as expected; observed exit code $paidExitCode."
}

function Get-UtcNowText {
  return (Get-Date).ToUniversalTime().ToString("o")
}

function Read-JsonFileOrNull {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

function Get-JsonField {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Json -or $Json.PSObject.Properties.Name -notcontains $Name) {
    return $null
  }
  return $Json.PSObject.Properties[$Name].Value
}

function Get-JsonStringField {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $value = Get-JsonField -Json $Json -Name $Name
  if ($null -eq $value) { return "" }
  return [string]$value
}

function Resolve-FullDistributionGateRepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
  $root = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd("\", "/")
  $full = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "path_must_stay_inside_repo"
  }
  return [ordered]@{
    full = $full
    relative = $full.Substring($prefix.Length).Replace("\", "/")
  }
}

function Invoke-FullDistributionGateCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [int[]]$AllowedExitCodes = @(0)
  )

  $started = Get-Date
  $global:LASTEXITCODE = 0
  $output = @(& pwsh -NoProfile -ExecutionPolicy Bypass @Arguments 2>&1)
  $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
  $ended = Get-Date
  $tail = @($output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 12)

  return [ordered]@{
    name = $Name
    command = "pwsh -NoProfile -ExecutionPolicy Bypass " + ($Arguments -join " ")
    exit_code = $exitCode
    accepted = [bool]($AllowedExitCodes -contains $exitCode)
    started_at_utc = $started.ToUniversalTime().ToString("o")
    ended_at_utc = $ended.ToUniversalTime().ToString("o")
    duration_ms = [int][Math]::Round(($ended - $started).TotalMilliseconds)
    output_tail = $tail
  }
}

function Test-FullDistributionManifestCurrent {
  param([AllowNull()][object]$HandoffSummary)

  $blockers = [System.Collections.Generic.List[string]]::new()
  $entries = @()
  $summaryGeneratedAtUtc = $null
  $summaryGeneratedAtValue = Get-JsonField -Json $HandoffSummary -Name "generated_at_utc"
  $summaryGeneratedAtText = if ($summaryGeneratedAtValue -is [datetime]) { $summaryGeneratedAtValue.ToUniversalTime().ToString("o") } else { [string]$summaryGeneratedAtValue }
  if ($summaryGeneratedAtValue -is [datetime]) {
    $summaryGeneratedAtUtc = $summaryGeneratedAtValue.ToUniversalTime()
  } elseif (-not [string]::IsNullOrWhiteSpace($summaryGeneratedAtText)) {
    try {
      $summaryGeneratedAtUtc = ([datetimeoffset]::Parse($summaryGeneratedAtText)).UtcDateTime
    } catch {
      [void]$blockers.Add("summary_generated_at_utc_invalid")
    }
  } else {
    [void]$blockers.Add("summary_generated_at_utc_missing")
  }

  $manifest = Get-JsonField -Json $HandoffSummary -Name "evidence_manifest"
  if ($null -eq $manifest) {
    return [ordered]@{ status = "fail"; checked_entries = 0; entries = @(); blockers = @("evidence_manifest_missing") }
  }

  foreach ($entry in @(Get-JsonField -Json $manifest -Name "entries")) {
    $name = Get-JsonStringField -Json $entry -Name "name"
    $path = Get-JsonStringField -Json $entry -Name "path"
    $declaredExists = Get-JsonField -Json $entry -Name "exists"
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "unnamed_entry" }
    if ([string]::IsNullOrWhiteSpace($path)) {
      [void]$blockers.Add("manifest_entry_path_missing:$name")
      continue
    }

    try {
      $resolved = Resolve-FullDistributionGateRepoPath -Path $path
    } catch {
      [void]$blockers.Add("manifest_entry_path_not_repo_bounded:$name")
      continue
    }

    $existsNow = Test-Path -LiteralPath $resolved.full -PathType Leaf
    if ($declaredExists -is [bool] -and [bool]$declaredExists -ne $existsNow) {
      [void]$blockers.Add("manifest_entry_exists_stale:$name")
    }
    if (-not $existsNow) {
      if ($declaredExists -is [bool] -and [bool]$declaredExists) {
        [void]$blockers.Add("manifest_entry_file_missing_now:$name")
      }
      continue
    }

    $item = Get-Item -LiteralPath $resolved.full
    $currentBytes = [int64]$item.Length
    $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolved.full).Hash.ToLowerInvariant()
    $declaredBytes = Get-JsonField -Json $entry -Name "bytes"
    $declaredHash = (Get-JsonStringField -Json $entry -Name "sha256").ToLowerInvariant()
    if ($null -ne $declaredBytes -and [int64]$declaredBytes -ne $currentBytes) {
      [void]$blockers.Add("manifest_entry_size_stale:$name")
    }
    if (-not [string]::IsNullOrWhiteSpace($declaredHash) -and $declaredHash -ne $currentHash) {
      [void]$blockers.Add("manifest_entry_sha256_stale:$name")
    }
    if ($null -ne $summaryGeneratedAtUtc -and $item.LastWriteTimeUtc -gt $summaryGeneratedAtUtc.AddSeconds(2)) {
      [void]$blockers.Add("manifest_entry_refreshed_after_summary:$name")
    }
    $entries += [ordered]@{
      name = $name
      path = $resolved.relative
      sha256_current = $currentHash
      sha256_matches_manifest = [bool]($declaredHash -eq $currentHash)
      bytes_current = $currentBytes
      bytes_match_manifest = [bool]($null -ne $declaredBytes -and [int64]$declaredBytes -eq $currentBytes)
      last_write_time_utc = $item.LastWriteTimeUtc.ToString("o")
    }
  }

  return [ordered]@{
    status = if ($blockers.Count -eq 0) { "pass" } else { "fail" }
    summary_generated_at_utc = $summaryGeneratedAtText
    checked_entries = @($entries).Count
    entries = $entries
    blockers = @($blockers.ToArray())
  }
}

function Test-FullDistributionTargetHandoffSummariesCurrent {
  $resolvedDir = Resolve-FullDistributionGateRepoPath -Path ".tmp\launch"
  if (-not (Test-Path -LiteralPath $resolvedDir.full -PathType Container)) {
    return [ordered]@{ status = "pass"; checked_summaries = 0; summaries = @(); blockers = @(); note = "launch_tmp_dir_missing" }
  }

  $summaries = @()
  $blockers = [System.Collections.Generic.List[string]]::new()
  $files = @(Get-ChildItem -LiteralPath $resolvedDir.full -Filter "trusted_user_api_distribution_handoff_summary.*.json" -File | Where-Object {
      $_.Name -notmatch '\.(synthetic|selftest|filled_selftest)\.json$'
    })

  foreach ($file in $files) {
    $relative = $file.FullName.Substring($resolvedDir.full.TrimEnd("\", "/").Length + 1).Replace("\", "/")
    $relative = ".tmp/launch/$relative"
    try {
      $json = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
      $result = Test-FullDistributionManifestCurrent -HandoffSummary $json
      $summaries += [ordered]@{
        path = $relative
        status = $result.status
        summary_overall_status = Get-JsonStringField -Json $json -Name "overall_status"
        ready_to_send = Get-JsonField -Json $json -Name "ready_to_send"
        blockers = @($result.blockers)
      }
      if ([string]$result.status -ne "pass") {
        foreach ($blocker in @($result.blockers)) {
          [void]$blockers.Add("target_handoff_manifest_stale:${relative}:${blocker}")
        }
      }
    } catch {
      $summaries += [ordered]@{ path = $relative; status = "fail"; blockers = @("summary_json_parse_failed") }
      [void]$blockers.Add("target_handoff_manifest_unreadable:$relative")
    }
  }

  return [ordered]@{
    status = if ($blockers.Count -eq 0) { "pass" } else { "fail" }
    checked_summaries = $summaries.Count
    summaries = $summaries
    blockers = @($blockers.ToArray())
    next_command = "rerun scripts/prepare_trusted_user_api_distribution_packet.ps1 with the target user's real values and target-specific -PacketPath/-SummaryPath after any FullDistributionGateOnly or alpha dry-run that refreshes default artifacts"
  }
}

function Invoke-FullDistributionGate {
  Write-Host "Full distribution launch gate: release/readiness/accounting/manifest/quota/request-trace/negative-guards/secret-scan"

  $commands = [System.Collections.Generic.List[object]]::new()
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "negative_guards" -Arguments @("-File", "scripts/verify_release_negative_guards.ps1")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "request_trace_selftest" -Arguments @("-File", "scripts/verify_request_trace_usage_explainability.ps1", "-SelfTest")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "request_trace_e13_bridge" -Arguments @("-File", "scripts/verify_request_trace_usage_explainability.ps1", "-PromptProtectionEvidenceReportPath", ".tmp/prompt_protection_beta_closure_report.json", "-OutputPath", ".tmp/launch/request_trace_usage_e13_bridge_report.json")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "request_trace_live_gap_readiness" -Arguments @("-File", "scripts/verify_request_trace_usage_explainability.ps1", "-LiveGapReadiness", "-OutputPath", ".tmp/launch/request_trace_usage_live_gap_readiness.json")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "request_trace_live_admin_api_readback" -Arguments @("-File", "scripts/verify_request_trace_usage_explainability.ps1", "-LiveApiReadback", "-OutputPath", ".tmp/launch/request_trace_usage_live_admin_api_readback.json")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "accounting_selftest" -Arguments @("-File", "scripts/verify_voucher_backed_api_distribution_accounting_gate.ps1", "-SelfTest")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "accounting_gate" -Arguments @("-File", "scripts/verify_voucher_backed_api_distribution_accounting_gate.ps1")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "quota_guardrails" -Arguments @("-File", "scripts/verify_voucher_quota_pricing_guardrails.ps1")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "readiness_selftest" -Arguments @("-File", "scripts/verify_voucher_api_distribution_readiness.ps1", "-SelfTest")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "synthetic_handoff_selftest" -Arguments @("-File", "scripts/prepare_trusted_user_api_distribution_packet.ps1", "-SyntheticHandoffSelfTest")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "release_launch" -Arguments @("-File", "scripts/release_check.ps1", "-Checks", "launch", "-SummaryPath", "artifacts/launch_voucher_api_distribution_release_check_20260606.json")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "handoff_default_manifest" -Arguments @("-File", "scripts/prepare_trusted_user_api_distribution_packet.ps1", "-AllowMissingUserFields") -AllowedExitCodes @(0, 2)))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "manifest_selftest" -Arguments @("-File", "scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1", "-SelfTest")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "manifest_default" -Arguments @("-File", "scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1", "-SummaryPath", ".tmp/launch/trusted_user_api_distribution_handoff_summary.json")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "quota_record_selftest" -Arguments @("-File", "scripts/verify_trusted_user_quota_rate_budget_record.ps1", "-SelfTest", "-EvidenceManifestPath", ".tmp/launch/trusted_user_api_distribution_handoff_summary.json")))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "quota_record_default_missing_input" -Arguments @("-File", "scripts/verify_trusted_user_quota_rate_budget_record.ps1", "-EvidenceManifestPath", ".tmp/launch/trusted_user_api_distribution_handoff_summary.json", "-OutputPath", ".tmp/launch/trusted_user_quota_rate_budget_record_verification.json") -AllowedExitCodes @(2)))
  [void]$commands.Add((Invoke-FullDistributionGateCommand -Name "secret_scan" -Arguments @("-File", "scripts/scan_secrets.ps1")))

  $readiness = Read-JsonFileOrNull ".tmp\launch\voucher_api_distribution_readiness.json"
  $accounting = Read-JsonFileOrNull ".tmp\launch\voucher_backed_api_distribution_accounting_gate.json"
  $quota = Read-JsonFileOrNull ".tmp\launch\voucher_quota_pricing_guardrails.json"
  $requestTrace = Read-JsonFileOrNull ".tmp\launch\request_trace_usage_e13_bridge_report.json"
  $requestTraceLiveGap = Read-JsonFileOrNull ".tmp\launch\request_trace_usage_live_gap_readiness.json"
  $requestTraceLiveReadback = Read-JsonFileOrNull ".tmp\launch\request_trace_usage_live_admin_api_readback.json"
  $handoff = Read-JsonFileOrNull ".tmp\launch\trusted_user_api_distribution_handoff_summary.json"
  $quotaRecordDefault = Read-JsonFileOrNull ".tmp\launch\trusted_user_quota_rate_budget_record_verification.json"
  $release = Read-JsonFileOrNull "artifacts\launch_voucher_api_distribution_release_check_20260606.json"
  $manifestCurrent = Test-FullDistributionManifestCurrent -HandoffSummary $handoff
  $targetHandoffManifests = Test-FullDistributionTargetHandoffSummariesCurrent

  $globalBlockers = [System.Collections.Generic.List[string]]::new()
  foreach ($command in @($commands.ToArray())) {
    if (-not [bool]$command.accepted) {
      [void]$globalBlockers.Add("command_failed:$($command.name):exit_$($command.exit_code)")
    }
  }
  if ((Get-JsonStringField -Json $readiness -Name "overall_status") -notin @("pass", "pass_with_productization_gaps")) { [void]$globalBlockers.Add("launch_readiness_not_pass") }
  if ((Get-JsonField -Json $readiness -Name "production_distribution_ready") -ne $true) { [void]$globalBlockers.Add("production_distribution_ready_false") }
  if ((Get-JsonStringField -Json $accounting -Name "overall_status") -ne "launch_ready_with_productization_gaps") { [void]$globalBlockers.Add("accounting_gate_not_launch_ready") }
  if ((Get-JsonStringField -Json $quota -Name "overall_status") -ne "pass") { [void]$globalBlockers.Add("quota_guardrails_not_pass") }
  if ((Get-JsonStringField -Json $requestTrace -Name "overall_status") -ne "pass") { [void]$globalBlockers.Add("request_trace_e13_bridge_not_pass") }
  if ((Get-JsonStringField -Json $requestTraceLiveGap -Name "overall_status") -ne "ready_for_live_readback") { [void]$globalBlockers.Add("request_trace_live_gap_readiness_not_ready") }
  if ((Get-JsonStringField -Json $requestTraceLiveReadback -Name "overall_status") -ne "pass") { [void]$globalBlockers.Add("request_trace_live_admin_api_readback_not_pass") }
  if ((Get-JsonField -Json $requestTraceLiveReadback -Name "api_distribution_blocker") -ne $false) { [void]$globalBlockers.Add("request_trace_live_readback_marked_api_distribution_blocker") }
  if ((Get-JsonStringField -Json $release -Name "overallStatus") -notin @("pass", "warn")) { [void]$globalBlockers.Add("release_launch_summary_not_pass_or_warn") }
  if ((Get-JsonStringField -Json $quotaRecordDefault -Name "status") -ne "blocked_runtime_input_required") { [void]$globalBlockers.Add("quota_record_default_missing_input_not_classified") }
  if ((Get-JsonField -Json $quotaRecordDefault -Name "global_api_distribution_blocker") -ne $false) { [void]$globalBlockers.Add("quota_record_default_missing_input_marked_global_blocker") }
  if (@(Get-JsonField -Json $quotaRecordDefault -Name "blockers") -notcontains "real_per_user_quota_rate_budget_record_required") { [void]$globalBlockers.Add("quota_record_default_missing_expected_blocker") }
  if ([string]$manifestCurrent.status -ne "pass") {
    foreach ($blocker in @($manifestCurrent.blockers)) { [void]$globalBlockers.Add($blocker) }
  }
  $targetHandoffBlocksActualKeyHandoff = [bool]([string]$targetHandoffManifests.status -ne "pass")

  $missingFields = @(Get-JsonField -Json $handoff -Name "missing_fields")
  $summary = [ordered]@{
    schema = "final_launch_gate_summary.v1"
    task_id = "QA-FULL-DISTRIBUTION-GATE"
    generated_at_utc = Get-UtcNowText
    launch_target = "trusted_user_voucher_backed_api_distribution"
    final_status = if ($globalBlockers.Count -eq 0) { "trusted_user_voucher_backed_beta_ready_with_productization_gaps" } else { "blocked" }
    ready_to_distribute_api = [bool]($globalBlockers.Count -eq 0)
    production_distribution_ready = [bool](Get-JsonField -Json $readiness -Name "production_distribution_ready")
    production_distribution_full_ready = [bool](Get-JsonField -Json $readiness -Name "production_distribution_full_ready")
    qa_release_verdict = Get-JsonStringField -Json $readiness -Name "overall_status"
    global_blockers = @($globalBlockers.ToArray() | Select-Object -Unique)
    per_user_external_inputs = @([ordered]@{
        id = "per_user_handoff_values_missing"
        scope = "target trusted-user packet"
        fields = $missingFields
        blocks_global_voucher_backed_beta_distribution_readiness = $false
        blocks_actual_key_handoff_until_filled = [bool]($missingFields.Count -gt 0)
        reason = "Release/Ops must supply real release owner, support, tenant/project/wallet, voucher quota, rate/budget, and rollback values for the selected trusted user."
      },
      [ordered]@{
        id = "per_user_quota_rate_budget_record_missing"
        scope = "target trusted-user quota/rate/budget record"
        fields = @(Get-JsonField -Json $quotaRecordDefault -Name "missing_fields")
        blocks_global_voucher_backed_beta_distribution_readiness = $false
        blocks_actual_key_handoff_until_filled = $true
        blocker_id = "real_per_user_quota_rate_budget_record_required"
        artifact = ".tmp/launch/trusted_user_quota_rate_budget_record_verification.json"
        next_command = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_quota_rate_budget_record.ps1 -RecordPath .tmp/launch/trusted_user_quota_rate_budget_record.<trusted-user-id>.json -EvidenceManifestPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json -OutputPath .tmp/launch/trusted_user_quota_rate_budget_record_verification.<trusted-user-id>.json"
        reason = "Release/Ops must provide the real selected user's bounded quota, rate, budget, wallet, voucher, ledger, expiry, rollback, audit, and evidence-link record before actual key handoff."
      },
      [ordered]@{
        id = "target_user_handoff_manifest_stale_after_gate_refresh"
        scope = "target trusted-user handoff summary"
        fields = @($targetHandoffManifests.blockers)
        blocks_global_voucher_backed_beta_distribution_readiness = $false
        blocks_actual_key_handoff_until_refreshed = $targetHandoffBlocksActualKeyHandoff
        next_command = $targetHandoffManifests.next_command
        reason = "FullDistributionGateOnly refreshes shared launch artifacts. Any existing target-user handoff summary must be regenerated and reverified after the gate before actual key handoff."
      })
    productization_gaps = @(Get-JsonField -Json $readiness -Name "productization_gaps")
    gate_status = [ordered]@{
      release_launch = Get-JsonStringField -Json $release -Name "overallStatus"
      readiness = Get-JsonStringField -Json $readiness -Name "overall_status"
      accounting = Get-JsonStringField -Json $accounting -Name "overall_status"
      quota_guardrails = Get-JsonStringField -Json $quota -Name "overall_status"
      request_trace_e13_bridge = Get-JsonStringField -Json $requestTrace -Name "overall_status"
      request_trace_live_gap_readiness = Get-JsonStringField -Json $requestTraceLiveGap -Name "overall_status"
      request_trace_live_admin_api_readback = Get-JsonStringField -Json $requestTraceLiveReadback -Name "overall_status"
      handoff_default = Get-JsonStringField -Json $handoff -Name "overall_status"
      manifest_hash_current = $manifestCurrent.status
      target_user_handoff_manifests_current = $targetHandoffManifests.status
      synthetic_handoff_selftest = if (@($commands.ToArray() | Where-Object { $_.name -eq "synthetic_handoff_selftest" -and $_.exit_code -eq 0 }).Count -eq 1) { "pass" } else { "fail" }
      quota_record_selftest = if (@($commands.ToArray() | Where-Object { $_.name -eq "quota_record_selftest" -and $_.exit_code -eq 0 }).Count -eq 1) { "pass" } else { "fail" }
      quota_record_default_missing_input = Get-JsonStringField -Json $quotaRecordDefault -Name "status"
      secret_scan = if (@($commands.ToArray() | Where-Object { $_.name -eq "secret_scan" -and $_.exit_code -eq 0 }).Count -eq 1) { "pass" } else { "fail" }
      negative_guards = if (@($commands.ToArray() | Where-Object { $_.name -eq "negative_guards" -and $_.exit_code -eq 0 }).Count -eq 1) { "pass" } else { "fail" }
    }
    evidence_artifacts = [ordered]@{
      final_summary = ".tmp/launch/final_launch_gate_summary.json"
      release_check_summary = "artifacts/launch_voucher_api_distribution_release_check_20260606.json"
      launch_readiness = ".tmp/launch/voucher_api_distribution_readiness.json"
      accounting_gate = ".tmp/launch/voucher_backed_api_distribution_accounting_gate.json"
      quota_guardrails = ".tmp/launch/voucher_quota_pricing_guardrails.json"
      request_trace_e13_bridge = ".tmp/launch/request_trace_usage_e13_bridge_report.json"
      request_trace_live_gap_readiness = ".tmp/launch/request_trace_usage_live_gap_readiness.json"
      request_trace_live_admin_api_readback = ".tmp/launch/request_trace_usage_live_admin_api_readback.json"
      trusted_user_handoff_summary = ".tmp/launch/trusted_user_api_distribution_handoff_summary.json"
      synthetic_handoff_summary = ".tmp/launch/trusted_user_api_distribution_handoff_summary.synthetic.json"
      quota_record_default_verification = ".tmp/launch/trusted_user_quota_rate_budget_record_verification.json"
    }
    manifest_current_readback = $manifestCurrent
    target_user_handoff_manifest_readback = $targetHandoffManifests
    commands = @($commands.ToArray())
    no_secret_outputs = [ordered]@{
      raw_voucher_code = $false
      authorization = $false
      cookie = $false
      db_url = $false
      provider_key = $false
      virtual_key_secret = $false
    }
  }

  $resolvedSummary = Resolve-FullDistributionGateRepoPath -Path ".tmp\launch\final_launch_gate_summary.json"
  $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resolvedSummary.full -Encoding UTF8
  $summary | ConvertTo-Json -Depth 20
  if ($globalBlockers.Count -gt 0) { exit 1 }
}

function Invoke-GatewayProtocolContracts {
  Write-Host "Gateway protocol contracts: SDK smoke audit plus bounded Gateway fixtures"
  Invoke-CheckedScript `
    -Path "$PSScriptRoot\verify_sdk_smoke.ps1" `
    -Parameters @{ ContractOnly = $true }
  Invoke-CheckedScript `
    -Path "$PSScriptRoot\verify_gateway_streaming_smoke.ps1" `
    -Parameters @{ DryRun = $true; SkipNetwork = $true; SkipDbLog = $true; SkipComposePs = $true }
}

function Invoke-AdminUiTestGate {
  Write-Host "Admin UI test gate: npm test without dependency reinstall"
  npm --prefix web/admin-ui test
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Invoke-AdminUiBundleGate {
  Write-Host "Admin UI bundle gate: bundle budget check without dependency reinstall"
  npm --prefix web/admin-ui run check:bundle
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (Test-TruthyEnv $env:GATEWAY_RATE_LIMIT_RESERVATION_SMOKE_ONLY) {
  $GatewayRateLimitReservationSmokeOnly = $true
}
if (Test-TruthyEnv $env:GATEWAY_RATE_LIMIT_RESERVATION_SMOKE_PREFLIGHT) {
  $GatewayRateLimitReservationSmokePreflight = $true
}
if (Test-TruthyEnv $env:GATEWAY_RATE_LIMIT_RESERVATION_SMOKE_LIVE) {
  $GatewayRateLimitReservationSmokeLive = $true
}
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_ONLY) {
  $ControlPlaneLedgerAdjustmentExecuteSmokeOnly = $true
}
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_LIVE) {
  $ControlPlaneLedgerAdjustmentExecuteSmokeLive = $true
}
if (
  (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_READBACK_ONLY) -or
  (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_ARTIFACT_READBACK_ONLY)
) {
  $ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly = $true
}
if (Test-TruthyEnv $env:PROMPT_PROTECTION_POSTGRES_PROOF_ONLY) {
  $PromptProtectionPostgresProofOnly = $true
}
if (Test-TruthyEnv $env:E13_PROMPT_PROTECTION_POSTGRES_PROOF_ONLY) {
  $PromptProtectionPostgresProofOnly = $true
}
if (Test-TruthyEnv $env:PROMPT_PROTECTION_POSTGRES_PROOF_LIVE) {
  $PromptProtectionPostgresProofLive = $true
}
if (Test-TruthyEnv $env:E13_PROMPT_PROTECTION_POSTGRES_PROOF_LIVE) {
  $PromptProtectionPostgresProofLive = $true
}
if (Test-TruthyEnv $env:BILLING_BETA_MODE_READINESS_ONLY) {
  $BillingBetaModeReadinessOnly = $true
}
if (Test-TruthyEnv $env:GATEWAY_PROTOCOL_CONTRACTS_ONLY) {
  $GatewayProtocolContractsOnly = $true
}
if (Test-TruthyEnv $env:FULL_DISTRIBUTION_GATE_ONLY) {
  $FullDistributionGateOnly = $true
}
if (Test-TruthyEnv $env:ADMIN_UI_TEST_ONLY) {
  $AdminUiTestOnly = $true
}
if (Test-TruthyEnv $env:ADMIN_UI_BUNDLE_GATE_ONLY) {
  $AdminUiBundleGateOnly = $true
}

if ($GatewayRateLimitReservationSmokePreflight -and $GatewayRateLimitReservationSmokeLive) {
  throw "Use either -GatewayRateLimitReservationSmokePreflight or -GatewayRateLimitReservationSmokeLive, not both."
}
$smokeOnlyCount = @(
  $GatewayRateLimitReservationSmokeOnly,
  $ControlPlaneLedgerAdjustmentExecuteSmokeOnly,
  $ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly,
  $PromptProtectionPostgresProofOnly,
  $GatewayProtocolContractsOnly,
  $BillingBetaModeReadinessOnly,
  $FullDistributionGateOnly,
  $AdminUiTestOnly,
  $AdminUiBundleGateOnly
) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count
if ($smokeOnlyCount -gt 1) {
  throw "Use only one smoke-only switch at a time."
}

if ($GatewayRateLimitReservationSmokeOnly) {
  Invoke-GatewayRateLimitReservationSmoke
  exit 0
}
if ($ControlPlaneLedgerAdjustmentExecuteSmokeOnly) {
  Invoke-ControlPlaneLedgerAdjustmentExecuteSmoke
  exit 0
}
if ($ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly) {
  Invoke-ControlPlaneLedgerAdjustmentExecuteBrowserReadback
  exit 0
}
if ($PromptProtectionPostgresProofOnly) {
  Invoke-PromptProtectionPostgresProof
  exit 0
}
if ($GatewayProtocolContractsOnly) {
  Invoke-GatewayProtocolContracts
  exit 0
}
if ($BillingBetaModeReadinessOnly) {
  Invoke-BillingBetaModeReadiness
  exit 0
}
if ($FullDistributionGateOnly) {
  Invoke-FullDistributionGate
  exit 0
}
if ($AdminUiTestOnly) {
  Invoke-AdminUiTestGate
  exit 0
}
if ($AdminUiBundleGateOnly) {
  Invoke-AdminUiBundleGate
  exit 0
}

Invoke-CheckedScript -Path "$PSScriptRoot\test_adapter_conformance_ci_contract.ps1"
Invoke-CheckedScript -Path "$PSScriptRoot\adapter_conformance.ps1" -Parameters @{ Strict = $true }

cargo test --workspace --all-targets --all-features
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Invoke-CheckedScript -Path "$PSScriptRoot\verify_control_plane_auth_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-CheckedScript -Path "$PSScriptRoot\verify_control_plane_crud_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-CheckedScript -Path "$PSScriptRoot\verify_gateway_profile_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-GatewayProtocolContracts
Invoke-CheckedScript -Path "$PSScriptRoot\verify_gateway_streaming_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-CheckedScript -Path "$PSScriptRoot\verify_gateway_retry_fallback_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-CheckedScript -Path "$PSScriptRoot\verify_provider_key_runtime_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-GatewayRateLimitReservationSmoke
Invoke-ControlPlaneLedgerAdjustmentExecuteSmoke
Invoke-PromptProtectionPostgresProof
Invoke-BillingBetaModeReadiness
Invoke-CheckedScript -Path "$PSScriptRoot\verify_release_negative_guards.ps1"
Invoke-CheckedScript -Path "$PSScriptRoot\verify_compose_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-CheckedScript -Path "$PSScriptRoot\test_supply_chain_scan.ps1"
Invoke-CheckedScript -Path "$PSScriptRoot\test_supply_chain_artifacts.ps1"

npm --prefix web/admin-ui ci
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm --prefix web/admin-ui test
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm --prefix web/admin-ui run build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm --prefix web/admin-ui run check:bundle
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
