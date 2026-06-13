param(
  [string]$SummaryPath = ".tmp\launch\trusted_user_api_distribution_handoff_summary.json",
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

$requiredEntryNames = @(
  "trusted_user_distribution_packet",
  "launch_release_check_summary",
  "trusted_user_quota_rate_budget_template",
  "voucher_api_distribution_readiness",
  "voucher_backed_api_distribution_accounting_gate",
  "e8_gateway_paid_hot_path_launch_check",
  "gateway_voucher_distribution_readiness",
  "voucher_quota_pricing_guardrails",
  "voucher_public_route_and_virtual_key_evidence",
  "user_remaining_balance_runtime",
  "recharge_voucher_runtime"
)

$allowedEntryFields = @(
  "name",
  "path",
  "required",
  "exists",
  "bytes",
  "sha256",
  "schema",
  "status",
  "overall_status",
  "ready_to_send",
  "blockers_count",
  "missing_fields_count",
  "generated_at_utc"
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
  if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $Name) { return $null }
  return $Object.PSObject.Properties[$Name].Value
}

function Get-StringField {
  param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
  $value = Get-Field -Object $Object -Name $Name
  if ($null -eq $value) { return "" }
  return [string]$value
}

function Test-SecretSafeString {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
  $secretPattern = '(?i)(authorization|bearer\s+[a-z0-9_\-\.]+|cookie|sk-[a-z0-9]|x-api-key|postgres(?:ql)?://|mysql://|redis://|raw[_ -]?voucher[_ -]?code|raw[_ -]?virtual[_ -]?key|virtual[_ -]?key[_ -]?secret|provider[_ -]?key|db[_ -]?url|raw[_ -]?provider[_ -]?payload|raw[_ -]?request[_ -]?body|dev_test_key)'
  return -not ($Value -match $secretPattern)
}

function Test-Entry {
  param(
    [Parameter(Mandatory = $true)][object]$Entry,
    [bool]$CheckCurrentArtifactState = $false,
    [AllowNull()][Nullable[datetime]]$SummaryGeneratedAtUtc = $null
  )

  $blockers = [System.Collections.Generic.List[string]]::new()
  $name = Get-StringField $Entry "name"
  $path = Get-StringField $Entry "path"
  $exists = Get-Field $Entry "exists"
  $sha256 = Get-StringField $Entry "sha256"
  $bytes = Get-Field $Entry "bytes"

  foreach ($property in $Entry.PSObject.Properties.Name) {
    if ($allowedEntryFields -notcontains $property) {
      [void]$blockers.Add("entry_field_not_allowed:${name}:${property}")
    }
  }

  if ([string]::IsNullOrWhiteSpace($name)) { [void]$blockers.Add("entry_name_missing") }
  if ([string]::IsNullOrWhiteSpace($path)) {
    [void]$blockers.Add("entry_path_missing:$name")
  } else {
    $resolved = $null
    try {
      $resolved = Resolve-RepoPath $path
    } catch {
      [void]$blockers.Add("entry_path_not_repo_bounded:$name")
    }

    if ($CheckCurrentArtifactState -and $null -ne $resolved) {
      $existsNow = Test-Path -LiteralPath $resolved.full -PathType Leaf
      if ($exists -is [bool] -and [bool]$exists -ne $existsNow) {
        [void]$blockers.Add("entry_exists_stale:$name")
      }

      if ($existsNow) {
        $item = Get-Item -LiteralPath $resolved.full
        $currentBytes = [int64]$item.Length
        $currentSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolved.full).Hash.ToLowerInvariant()
        if ($exists -is [bool] -and [bool]$exists) {
          if ($sha256 -notmatch '^[a-f0-9]{64}$') {
            [void]$blockers.Add("entry_sha256_invalid:$name")
          } elseif ($sha256.ToLowerInvariant() -ne $currentSha256) {
            [void]$blockers.Add("entry_sha256_stale:$name")
          }
          if ($null -eq $bytes -or [int64]$bytes -le 0) {
            [void]$blockers.Add("entry_bytes_invalid:$name")
          } elseif ([int64]$bytes -ne $currentBytes) {
            [void]$blockers.Add("entry_bytes_stale:$name")
          }
        }
        if ($null -ne $SummaryGeneratedAtUtc -and $item.LastWriteTimeUtc -gt $SummaryGeneratedAtUtc.AddSeconds(2)) {
          [void]$blockers.Add("entry_refreshed_after_summary:$name")
        }
      } elseif ($exists -is [bool] -and [bool]$exists) {
        [void]$blockers.Add("entry_file_missing_now:$name")
      }
    }
  }

  if ($exists -isnot [bool]) {
    [void]$blockers.Add("entry_exists_not_bool:$name")
  } elseif ([bool]$exists -and -not $CheckCurrentArtifactState) {
    if ($sha256 -notmatch '^[a-f0-9]{64}$') {
      [void]$blockers.Add("entry_sha256_invalid:$name")
    }
    if ($null -eq $bytes -or [int64]$bytes -le 0) {
      [void]$blockers.Add("entry_bytes_invalid:$name")
    }
  }

  foreach ($field in @("name", "path", "schema", "status", "overall_status", "generated_at_utc")) {
    if (-not (Test-SecretSafeString (Get-StringField $Entry $field))) {
      [void]$blockers.Add("entry_secret_like_value:${name}:${field}")
    }
  }

  return @($blockers.ToArray())
}

function Test-SummaryObject {
  param(
    [Parameter(Mandatory = $true)][object]$Summary,
    [string]$PathForReport = "<memory>",
    [bool]$CheckCurrentArtifactState = $false
  )

  $blockers = [System.Collections.Generic.List[string]]::new()
  if ((Get-StringField $Summary "schema") -ne "trusted_user_api_distribution_handoff_summary.v1") {
    [void]$blockers.Add("summary_schema_invalid")
  }

  $summaryGeneratedAtUtc = $null
  $summaryGeneratedAtValue = Get-Field $Summary "generated_at_utc"
  if ($summaryGeneratedAtValue -is [datetime]) {
    $summaryGeneratedAtUtc = $summaryGeneratedAtValue.ToUniversalTime()
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$summaryGeneratedAtValue)) {
    try {
      $summaryGeneratedAtUtc = ([datetimeoffset]::Parse([string]$summaryGeneratedAtValue)).UtcDateTime
    } catch {
      if ($CheckCurrentArtifactState) { [void]$blockers.Add("summary_generated_at_utc_invalid") }
    }
  } elseif ($CheckCurrentArtifactState) {
    [void]$blockers.Add("summary_generated_at_utc_missing")
  }

  $manifest = Get-Field $Summary "evidence_manifest"
  if ($null -eq $manifest) {
    [void]$blockers.Add("evidence_manifest_missing")
  } else {
    if ((Get-StringField $manifest "schema") -ne "trusted_user_api_distribution_evidence_manifest.v1") {
      [void]$blockers.Add("manifest_schema_invalid")
    }
    if ((Get-StringField $manifest "hash_algorithm") -ne "SHA256") {
      [void]$blockers.Add("manifest_hash_algorithm_invalid")
    }
    if (@(Get-Field $manifest "missing_required_entries").Count -gt 0) {
      [void]$blockers.Add("manifest_missing_required_entries_not_empty")
    }

    $entries = @(Get-Field $manifest "entries")
    if ($entries.Count -eq 0) {
      [void]$blockers.Add("manifest_entries_missing")
    }

    $names = @($entries | ForEach-Object { Get-StringField $_ "name" })
    foreach ($required in $requiredEntryNames) {
      if ($names -notcontains $required) {
        [void]$blockers.Add("required_entry_missing:$required")
      }
    }

    foreach ($entry in $entries) {
      foreach ($entryBlocker in (Test-Entry -Entry $entry -CheckCurrentArtifactState $CheckCurrentArtifactState -SummaryGeneratedAtUtc $summaryGeneratedAtUtc)) {
        [void]$blockers.Add($entryBlocker)
      }
    }
  }

  $status = if ($blockers.Count -eq 0) { "pass" } else { "fail" }
  return [ordered]@{
    schema = "trusted_user_api_distribution_evidence_manifest_verifier.v1"
    overall_status = $status
    actual_exit_code = if ($status -eq "pass") { 0 } else { 1 }
    summary_path = $PathForReport
    ready_to_send = Get-Field $Summary "ready_to_send"
    summary_overall_status = Get-StringField $Summary "overall_status"
    required_entries = $requiredEntryNames
    blockers = @($blockers.ToArray())
  }
}

function New-SelfTestSummary {
  $entries = foreach ($name in $requiredEntryNames) {
    [pscustomobject]@{
      name = $name
      path = ".tmp/launch/$name.json"
      required = $true
      exists = $true
      bytes = 128
      sha256 = "a" * 64
      schema = "$name.v1"
      status = "pass"
      overall_status = ""
      ready_to_send = $null
      blockers_count = 0
      missing_fields_count = 0
      generated_at_utc = "2026-06-06T00:00:00.0000000Z"
    }
  }
  [pscustomobject]@{
    schema = "trusted_user_api_distribution_handoff_summary.v1"
    overall_status = "blocked_by_missing_user_fields_only"
    ready_to_send = $false
    evidence_manifest = [pscustomobject]@{
      schema = "trusted_user_api_distribution_evidence_manifest.v1"
      hash_algorithm = "SHA256"
      entries = @($entries)
      missing_required_entries = @()
    }
  }
}

function New-CurrentStateSelfTestSummary {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$GeneratedAtUtc
  )

  $summary = New-SelfTestSummary
  $summary | Add-Member -NotePropertyName "generated_at_utc" -NotePropertyValue $GeneratedAtUtc -Force
  $summary.evidence_manifest | Add-Member -NotePropertyName "generated_at_utc" -NotePropertyValue $GeneratedAtUtc -Force
  $prefix = [System.Guid]::NewGuid().ToString("N")
  $index = 0
  foreach ($entry in @($summary.evidence_manifest.entries)) {
    $entry.path = ".tmp/launch/manifest_verifier_current_state_absent_${prefix}_${index}.json"
    $entry.exists = $false
    $entry.bytes = 0
    $entry.sha256 = $null
    $index += 1
  }

  $resolved = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath (Split-Path -Parent $resolved.full))) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolved.full) | Out-Null
  }
  Set-Content -LiteralPath $resolved.full -Encoding UTF8 -Value "manifest verifier current-state selftest"
  $item = Get-Item -LiteralPath $resolved.full
  $summary.evidence_manifest.entries[0].path = $resolved.relative
  $summary.evidence_manifest.entries[0].exists = $true
  $summary.evidence_manifest.entries[0].bytes = [int64]$item.Length
  $summary.evidence_manifest.entries[0].sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolved.full).Hash.ToLowerInvariant()
  return $summary
}

if ($SelfTest) {
  $good = New-SelfTestSummary
  $missing = New-SelfTestSummary
  $missing.evidence_manifest.entries = @($missing.evidence_manifest.entries | Where-Object { $_.name -ne "e8_gateway_paid_hot_path_launch_check" })
  $badHash = New-SelfTestSummary
  $badHash.evidence_manifest.entries[0].sha256 = "bad"
  $badField = New-SelfTestSummary
  $badField.evidence_manifest.entries[0] | Add-Member -NotePropertyName "raw_voucher_code" -NotePropertyValue "raw_voucher_code:secret"
  $secretValue = New-SelfTestSummary
  $secretValue.evidence_manifest.entries[0].status = "Authorization Bearer abc"
  $currentGood = New-CurrentStateSelfTestSummary -Path ".tmp/launch/manifest_verifier_current_state_selftest.json" -GeneratedAtUtc (Get-Date).ToUniversalTime().AddSeconds(5).ToString("o")
  $currentStale = New-CurrentStateSelfTestSummary -Path ".tmp/launch/manifest_verifier_current_state_stale_selftest.json" -GeneratedAtUtc (Get-Date).ToUniversalTime().AddMinutes(-5).ToString("o")

  $cases = @(
    [ordered]@{ name = "good_summary_passes"; result = Test-SummaryObject $good "selftest:good"; expect = "pass" },
    [ordered]@{ name = "missing_required_rejected"; result = Test-SummaryObject $missing "selftest:missing"; expect = "fail" },
    [ordered]@{ name = "bad_sha_rejected"; result = Test-SummaryObject $badHash "selftest:bad_sha"; expect = "fail" },
    [ordered]@{ name = "unallowed_field_rejected"; result = Test-SummaryObject $badField "selftest:bad_field"; expect = "fail" },
    [ordered]@{ name = "secret_like_value_rejected"; result = Test-SummaryObject $secretValue "selftest:secret"; expect = "fail" },
    [ordered]@{ name = "current_artifact_hash_passes"; result = Test-SummaryObject -Summary $currentGood -PathForReport "selftest:current_good" -CheckCurrentArtifactState $true; expect = "pass" },
    [ordered]@{ name = "artifact_refreshed_after_summary_rejected"; result = Test-SummaryObject -Summary $currentStale -PathForReport "selftest:current_stale" -CheckCurrentArtifactState $true; expect = "fail" }
  )
  $failed = @($cases | Where-Object { $_.result.overall_status -ne $_.expect })
  $status = if ($failed.Count -eq 0) { "pass" } else { "fail" }
  [ordered]@{
    schema = "trusted_user_api_distribution_evidence_manifest_verifier_selftest.v1"
    overall_status = $status
    cases = $cases
  } | ConvertTo-Json -Depth 12
  if ($status -eq "pass") { exit 0 }
  exit 1
}

$resolved = Resolve-RepoPath $SummaryPath
if (-not (Test-Path -LiteralPath $resolved.full -PathType Leaf)) {
  [ordered]@{
    schema = "trusted_user_api_distribution_evidence_manifest_verifier.v1"
    overall_status = "fail"
    actual_exit_code = 1
    summary_path = $resolved.relative
    blockers = @("summary_missing")
  } | ConvertTo-Json -Depth 8
  exit 1
}

$summary = Get-Content -Raw -LiteralPath $resolved.full | ConvertFrom-Json
$result = Test-SummaryObject -Summary $summary -PathForReport $resolved.relative -CheckCurrentArtifactState $true
$result | ConvertTo-Json -Depth 10
exit ([int]$result.actual_exit_code)
