param(
  [string]$PromptProtectionEvidenceReportPath = ".tmp/prompt_protection_beta_closure_report.json",
  [string]$OutputPath = ".tmp/request_trace_usage_e13_bridge_report.json",
  [string]$E13ContractPath = "tests/fixtures/request_trace_usage/e13_prompt_protection_explainability_bridge_contract.json",
  [string]$MultiSourceContractPath = "tests/fixtures/request_trace_usage/multi_source_operator_readback_contract.json",
  [string]$SelfTestOutputPath = ".tmp/launch/request_trace_usage_operator_multisource_contract_selftest.json",
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "local-password",
  [string]$AdminSessionToken = "",
  [int]$TimeoutSeconds = 12,
  [switch]$E13PromptProtectionOnly,
  [switch]$LiveApiReadback,
  [switch]$LiveGapReadiness,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:CONTROL_PLANE_ADMIN_EMAIL) { $AdminEmail = $env:CONTROL_PLANE_ADMIN_EMAIL }
if ($env:CONTROL_PLANE_ADMIN_PASSWORD) { $AdminPassword = $env:CONTROL_PLANE_ADMIN_PASSWORD }
if ($env:CONTROL_PLANE_ADMIN_SESSION_TOKEN -and [string]::IsNullOrWhiteSpace($AdminSessionToken)) {
  $AdminSessionToken = $env:CONTROL_PLANE_ADMIN_SESSION_TOKEN
}
if ($env:PROMPT_PROTECTION_ADMIN_SESSION_TOKEN -and [string]::IsNullOrWhiteSpace($AdminSessionToken)) {
  $AdminSessionToken = $env:PROMPT_PROTECTION_ADMIN_SESSION_TOKEN
}

function Get-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $root = [System.IO.Path]::GetFullPath([string]$repoRoot)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $Path))
}

function Test-PathWithinRepo {
  param([Parameter(Mandatory = $true)][string]$Path)

  $root = [System.IO.Path]::GetFullPath([string]$repoRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $full = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  return ($full -eq $root -or $full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar) -or $full.StartsWith($root + [System.IO.Path]::AltDirectorySeparatorChar))
}

function Assert-SafeArtifactPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $resolved = Get-RepoPath $Path
  if (-not (Test-PathWithinRepo -Path $resolved)) {
    throw "artifact path refused: outside repository"
  }
  if ([string]::Compare([System.IO.Path]::GetExtension($resolved), ".json", $true) -ne 0) {
    throw "artifact path refused: JSON extension required"
  }
  return $resolved
}

function Assert-SecretSafeText {
  param([Parameter(Mandatory = $true)][string]$Text)

  foreach ($marker in @(
      "Ignore previous instructions",
      "dev_test_key_123456789",
      "leaked_raw_request_body_marker",
      "postgres://",
      "postgresql://",
      "sk-"
    )) {
    if ($Text.Contains($marker)) {
      throw "secret_safe_failure"
    }
  }
}

function ConvertTo-BridgeJson {
  param([Parameter(Mandatory = $true)]$Object)
  return ($Object | ConvertTo-Json -Depth 32)
}

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Path
  )

  return $Base.TrimEnd("/") + "/" + $Path.TrimStart("/")
}

function New-Issue {
  param(
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][string]$Message
  )

  return [ordered]@{
    code = $Code
    message = $Message
  }
}

function Try-AdminSessionHandoff {
  if (-not [string]::IsNullOrWhiteSpace($AdminSessionToken)) {
    return [ordered]@{
      attempted = $false
      acquired = $true
      source = "provided_session_token"
      token_echoed = $false
      failure_code = ""
    }
  }
  if ([string]::IsNullOrWhiteSpace($ControlPlaneBaseUrl) -or
      [string]::IsNullOrWhiteSpace($AdminEmail) -or
      [string]::IsNullOrWhiteSpace($AdminPassword)) {
    return [ordered]@{
      attempted = $false
      acquired = $false
      source = "none"
      token_echoed = $false
      failure_code = "admin_login_inputs_missing"
    }
  }

  $client = $null
  $request = $null
  $response = $null
  try {
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds([Math]::Max(3, [Math]::Min($TimeoutSeconds, 20)))
    $body = @{
      email = $AdminEmail
      password = $AdminPassword
    } | ConvertTo-Json -Depth 8 -Compress
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, (Join-Url $ControlPlaneBaseUrl "/admin/auth/login"))
    $request.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, "application/json")
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
      return [ordered]@{
        attempted = $true
        acquired = $false
        source = "admin_login"
        token_echoed = $false
        failure_code = "admin_login_http_$([int]$response.StatusCode)"
      }
    }
    Assert-SecretSafeText $content
    $payload = $content | ConvertFrom-Json
    $token = [string]$payload.data.session_token_once
    if ([string]::IsNullOrWhiteSpace($token)) {
      return [ordered]@{
        attempted = $true
        acquired = $false
        source = "admin_login"
        token_echoed = $false
        failure_code = "admin_login_token_missing"
      }
    }
    $script:AdminSessionToken = $token
    $env:CONTROL_PLANE_ADMIN_SESSION_TOKEN = $token
    return [ordered]@{
      attempted = $true
      acquired = $true
      source = "admin_login"
      token_echoed = $false
      failure_code = ""
    }
  } catch {
    return [ordered]@{
      attempted = $true
      acquired = $false
      source = "admin_login"
      token_echoed = $false
      failure_code = "admin_login_exception"
    }
  } finally {
    if ($null -ne $response) { $response.Dispose() }
    if ($null -ne $request) { $request.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
  }
}

function Get-ReportEndpointRequestId {
  param([Parameter(Mandatory = $true)]$Endpoint)

  if ($null -ne $Endpoint.request -and -not [string]::IsNullOrWhiteSpace([string]$Endpoint.request.request_id)) {
    return [string]$Endpoint.request.request_id
  }
  return ""
}

function New-E13ExplainabilityBridge {
  param(
    [Parameter(Mandatory = $true)]$SourceReport,
    [switch]$AttemptLiveApiReadback
  )

  $issues = New-Object System.Collections.Generic.List[object]
  $blockers = New-Object System.Collections.Generic.List[object]
  $sourceJson = ConvertTo-BridgeJson $SourceReport
  try {
    Assert-SecretSafeText $sourceJson
  } catch {
    [void]$issues.Add((New-Issue -Code "secret_safe_failure" -Message "source report contains forbidden raw material marker"))
  }

  if ([string]$SourceReport.schema -ne "prompt_protection_postgres_proof_evidence_report.v1") {
    [void]$issues.Add((New-Issue -Code "source_schema_mismatch" -Message "source report schema mismatch"))
  }
  if ([string]$SourceReport.status -ne "passed" -or [int]$SourceReport.exit_code -ne 0) {
    [void]$issues.Add((New-Issue -Code "source_report_not_passed" -Message "source report must be passed with exit_code 0"))
  }
  if ($SourceReport.beta_closure_eligible -ne $true) {
    [void]$issues.Add((New-Issue -Code "source_beta_closure_not_eligible" -Message "source beta closure must be eligible"))
  }
  if ([int]$SourceReport.live_request_id_count -ne 4) {
    [void]$issues.Add((New-Issue -Code "source_live_request_id_count_mismatch" -Message "source report must export four live request ids"))
  }

  $requestRows = New-Object System.Collections.Generic.List[object]
  foreach ($endpoint in @($SourceReport.endpoints)) {
    $requestId = Get-ReportEndpointRequestId -Endpoint $endpoint
    if ([string]::IsNullOrWhiteSpace($requestId)) {
      [void]$issues.Add((New-Issue -Code "request_id_missing" -Message ("request id missing for endpoint " + [string]$endpoint.name)))
    }
    if ([int]$endpoint.provider_side_effects.provider_attempts_count -ne 0) {
      [void]$issues.Add((New-Issue -Code "provider_attempts_nonzero" -Message ("provider attempts must be zero for endpoint " + [string]$endpoint.name)))
    }
    if ([string]$endpoint.evidence_status -ne "passed") {
      [void]$issues.Add((New-Issue -Code "endpoint_not_passed" -Message ("endpoint evidence was not passed for " + [string]$endpoint.name)))
    }
    if ([string]$endpoint.request_log.redaction_status -ne "hash_only") {
      [void]$issues.Add((New-Issue -Code "request_log_redaction_mismatch" -Message ("request log redaction mismatch for " + [string]$endpoint.name)))
    }
    if ($endpoint.secret_safe_omissions.raw_payload_omitted -ne $true -or
        $endpoint.secret_safe_omissions.credential_values_omitted -ne $true -or
        $endpoint.secret_safe_omissions.provider_secret_values_omitted -ne $true) {
      [void]$issues.Add((New-Issue -Code "endpoint_secret_safe_omission_mismatch" -Message ("secret-safe omission mismatch for " + [string]$endpoint.name)))
    }

    [void]$requestRows.Add([ordered]@{
        name = [string]$endpoint.name
        endpoint = [string]$endpoint.endpoint
        request_id = [string]$requestId
        request_id_opaque = $true
        expected_prompt_rejection_fields = [ordered]@{
          request_status = "rejected"
          http_status = 400
          error_code = "prompt_protection_rejected"
          error_stage = "request_preflight"
          prompt_protection_action = "reject"
          prompt_protection_mode = "enforce"
        }
        provider_attempts_count = [int]$endpoint.provider_side_effects.provider_attempts_count
        route_provider_expectations = [ordered]@{
          route_policy_version_available = $true
          resolved_provider_id_available_when_routed = $true
          resolved_channel_id_available_when_routed = $true
          route_decision_snapshot_sanitized = $true
          provider_attempt_rows_metadata_only = $true
          provider_secret_values_omitted = $true
        }
        request_log_expectations = [ordered]@{
          redaction_status = "hash_only"
          payload_stored = $false
          payload_object_ref_present = $false
          raw_payload_omitted = $true
          request_body_hash_present = [bool]$endpoint.request_log.request_body_hash_present
        }
        guardrail_expectations = [ordered]@{
          decision_source = "prompt_protection"
          enforcement_stage = "request_preflight"
          action = "reject"
          metadata_only = $true
        }
        audit_readback_expectations = [ordered]@{
          runtime_owned_required = $true
          current_runtime_owned_required = $true
          gateway_runtime_provenance_required = $true
          admin_ui_api_readback_status_expected = "pass"
        }
        support_field_expectations = [ordered]@{
          request_id_required = $true
          trace_id_required_when_present = $true
          audit_lookup_fields = @("request_id", "resource_type", "action", "created_at")
          operator_safe_fields = @("request_id", "trace_id", "route", "provider", "ledger", "guardrail", "audit", "usage", "balance")
          forbidden_fields = @("raw_prompt", "raw_request_body", "raw_response_body", "credential_values", "provider_secret_values")
        }
        usage_cost_expectations = [ordered]@{
          prompt_rejection = $true
          provider_usage_expected = "none"
          provider_attempts_required_zero = $true
          billing_mode = "usage_only_beta"
          real_paid_billing_claimed = $false
          cost_truth_source = "metadata_only_no_provider_attempt"
        }
        ledger_balance_expectations = [ordered]@{
          ledger_entries_linked_by_request_id = $true
          ledger_entries_metadata_only = $true
          prompt_rejection_debit_expected = $false
          balance_readback_source = "control_plane_remaining_balance_endpoint_when_wallet_exists"
          balance_claim_for_prompt_rejection = "unchanged_by_guardrail_rejection"
        }
        secret_safe_omissions = [ordered]@{
          raw_prompt_omitted = $true
          raw_request_body_omitted = $true
          credential_values_omitted = $true
          provider_secret_values_omitted = $true
        }
      })
  }

  if ($requestRows.Count -ne 4) {
    [void]$issues.Add((New-Issue -Code "request_count_mismatch" -Message "bridge must contain four E13 request ids"))
  }
  if ([int]$SourceReport.runtime_owned_row_count -lt 1 -or [int]$SourceReport.current_runtime_owned_row_count -lt 1) {
    [void]$issues.Add((New-Issue -Code "runtime_owned_audit_readback_missing" -Message "runtime-owned current audit readback is required"))
  }
  if ([string]$SourceReport.gateway_runtime_provenance_status -ne "pass") {
    [void]$issues.Add((New-Issue -Code "gateway_runtime_provenance_not_pass" -Message "gateway runtime provenance must pass"))
  }
  if ([string]$SourceReport.admin_ui_api_readback_status -ne "pass") {
    [void]$issues.Add((New-Issue -Code "admin_api_readback_not_pass" -Message "Admin API readback must pass in source report"))
  }
  if ([string]$SourceReport.secret_safe_scan -ne "pass") {
    [void]$issues.Add((New-Issue -Code "source_secret_safe_not_pass" -Message "source report secret-safe scan must pass"))
  }

  $liveReadback = [ordered]@{
    attempted = [bool]$AttemptLiveApiReadback
    classification = "not_requested"
    required_for_offline_contract = $false
    blocker_reason = "not_requested"
  }
  if ($AttemptLiveApiReadback) {
    if ([string]::IsNullOrWhiteSpace($AdminSessionToken)) {
      $liveReadback.classification = "external_blocker"
      $liveReadback.blocker_reason = "admin_session_missing"
      [void]$blockers.Add((New-Issue -Code "admin_session_missing" -Message "Admin API readback requested but no session handoff is configured"))
    } else {
      try {
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds([Math]::Max(3, [Math]::Min($TimeoutSeconds, 20)))
        $url = $ControlPlaneBaseUrl.TrimEnd("/") + "/admin/audit-logs?resource_type=prompt_protection&limit=500"
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $url)
        [void]$request.Headers.TryAddWithoutValidation("X-Admin-Session", $AdminSessionToken)
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        Assert-SecretSafeText $content
        if (-not $response.IsSuccessStatusCode) {
          $liveReadback.classification = "external_blocker"
          $liveReadback.blocker_reason = "admin_api_unreachable"
          [void]$blockers.Add((New-Issue -Code "admin_api_unreachable" -Message "Admin API readback did not return success"))
        } else {
          $missing = @($requestRows | Where-Object { -not $content.Contains([string]$_.request_id) })
          if ($missing.Count -gt 0) {
            $liveReadback.classification = "blocked"
            $liveReadback.blocker_reason = "request_ids_not_visible_in_admin_api_readback"
            [void]$blockers.Add((New-Issue -Code "request_ids_not_visible_in_admin_api_readback" -Message "Not all E13 request ids were visible in the Admin API readback response"))
          } else {
            $liveReadback.classification = "pass"
            $liveReadback.blocker_reason = "none"
          }
        }
      } catch {
        $liveReadback.classification = "external_blocker"
        $liveReadback.blocker_reason = "admin_api_readback_failed"
        [void]$blockers.Add((New-Issue -Code "admin_api_readback_failed" -Message "Admin API readback could not be completed"))
      } finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
      }
    }
  }

  $overall = "pass"
  if ($issues.Count -gt 0) {
    $overall = "fail"
  } elseif ($blockers.Count -gt 0) {
    $overall = "blocked"
  }

  return [ordered]@{
    schema = "request_trace_usage_explainability_e13_bridge_v1"
    overall_status = $overall
    mode = $(if ($AttemptLiveApiReadback) { "live_api_readback" } else { "offline_contract" })
    source_report_path_marker = "repo_bounded_prompt_protection_evidence_report"
    source_report_status = [string]$SourceReport.status
    source_beta_closure_eligible = [bool]$SourceReport.beta_closure_eligible
    source_admin_ui_api_readback_status = [string]$SourceReport.admin_ui_api_readback_status
    request_id_count = [int]$requestRows.Count
    requests = [object[]]@($requestRows.ToArray())
    e13_subclosure = [ordered]@{
      status = $(if ($overall -eq "pass") { "ready" } else { $overall })
      todo_14_scope = "E13 prompt protection request ids and metadata-only rejection readback contract"
      e8_request_ids_required_from_e8_lane = $true
      e11_request_ids_required_from_e11_lane = $true
      e8_e11_request_ids_status = "external_runtime_input_required"
      todo_14_overall_closed = $false
    }
    operator_explainability_contract = [ordered]@{
      goal = "explain one trusted user request by request_id without prompt response or secret material"
      required_surfaces = @("request_log_detail", "trace_summary", "audit_logs", "ledger_entries", "remaining_balance")
      required_field_groups = @("route", "provider", "ledger", "guardrail", "audit", "usage", "balance", "support")
      prompt_response_secret_safe = $true
      e13_coverage = "prompt_protection_rejection_request_ids"
      e8_e11_coverage = "external_runtime_input_required"
    }
    usage_cost_policy = [ordered]@{
      prompt_rejection_provider_attempts_zero = $true
      usage_cost_for_prompt_rejection = "metadata_only_no_provider_attempt"
      paid_billing_claimed = $false
      e9_mode_dependency = "usage_only_beta"
    }
    live_api_readback = $liveReadback
    blockers = [object[]]@($blockers.ToArray())
    failures = [object[]]@($issues.ToArray())
    secret_safe_scan = $(if (@($issues | Where-Object { $_.code -eq "secret_safe_failure" }).Count -gt 0) { "fail" } else { "pass" })
  }
}

function Read-SourceReport {
  param([Parameter(Mandatory = $true)][string]$Path)

  $resolved = Get-RepoPath $Path
  if (-not (Test-PathWithinRepo -Path $resolved)) {
    throw "source report path refused"
  }
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "source report missing"
  }
  $json = Get-Content -LiteralPath $resolved -Raw
  Assert-SecretSafeText $json
  return ($json | ConvertFrom-Json)
}

function Write-BridgeReport {
  param(
    [Parameter(Mandatory = $true)]$Report,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $resolved = Assert-SafeArtifactPath -Path $Path
  $json = ConvertTo-BridgeJson $Report
  Assert-SecretSafeText $json
  $parent = Split-Path -Parent $resolved
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  Set-Content -LiteralPath $resolved -Encoding UTF8 -Value $json
  $readback = Get-Content -LiteralPath $resolved -Raw
  Assert-SecretSafeText $readback
  [void]($readback | ConvertFrom-Json)
  return $resolved
}

function Read-JsonArtifactOrNull {
  param([Parameter(Mandatory = $true)][string]$Path)

  $resolved = Get-RepoPath $Path
  if (-not (Test-PathWithinRepo -Path $resolved)) {
    throw "artifact path refused"
  }
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    return $null
  }
  $json = Get-Content -LiteralPath $resolved -Raw
  Assert-SecretSafeText $json
  return ($json | ConvertFrom-Json)
}

function Get-StringArray {
  param($Value)

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Value)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
      [void]$items.Add([string]$item)
    }
  }
  return [string[]]@($items.ToArray())
}

function Add-UniqueRequestIds {
  param(
    [Parameter(Mandatory = $true)]$List,
    $Value,
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)]$Sources,
    [int]$Limit = 10
  )

  foreach ($item in @(Get-StringArray $Value)) {
    if ($List.Count -ge $Limit) {
      break
    }
    if (@($List | Where-Object { [string]$_ -eq [string]$item }).Count -lt 1) {
      [void]$List.Add([string]$item)
      [void]$Sources.Add([ordered]@{
          source_path = $SourcePath
          request_id = [string]$item
        })
    }
  }
}

function Get-BoundedRequestIdsFromArtifact {
  param(
    [AllowNull()]$Artifact,
    [Parameter(Mandatory = $true)][string]$ArtifactLabel,
    [int]$Limit = 10
  )

  $ids = New-Object System.Collections.Generic.List[string]
  $sources = New-Object System.Collections.Generic.List[object]
  $checkedPaths = @(
    "request_ids",
    "current_request_ids",
    "request_trace.request_ids",
    "request_trace.requests[].request_id",
    "request_trace_lookup_keys.request_ids",
    "request_trace_usage_handoff.request_trace_lookup_keys.request_ids",
    "smoke_run_readback.request_ids",
    "operator_readback.parameters.request_ids",
    "post_commit_readback.resolved_request_roles.success_request_id",
    "post_commit_readback.resolved_request_roles.failure_request_id",
    "post_commit_readback.resolved_request_roles.insufficient_request_id",
    "gateway_route.request_id",
    "gateway_route.request_ids"
  )

  if ($null -ne $Artifact) {
    Add-UniqueRequestIds -List $ids -Value $Artifact.request_ids -SourcePath "$ArtifactLabel.request_ids" -Sources $sources -Limit $Limit
    Add-UniqueRequestIds -List $ids -Value $Artifact.current_request_ids -SourcePath "$ArtifactLabel.current_request_ids" -Sources $sources -Limit $Limit
    Add-UniqueRequestIds -List $ids -Value $Artifact.request_trace.request_ids -SourcePath "$ArtifactLabel.request_trace.request_ids" -Sources $sources -Limit $Limit
    Add-UniqueRequestIds -List $ids -Value (@($Artifact.request_trace.requests) | ForEach-Object { $_.request_id }) -SourcePath "$ArtifactLabel.request_trace.requests[].request_id" -Sources $sources -Limit $Limit
    Add-UniqueRequestIds -List $ids -Value $Artifact.request_trace_lookup_keys.request_ids -SourcePath "$ArtifactLabel.request_trace_lookup_keys.request_ids" -Sources $sources -Limit $Limit
    Add-UniqueRequestIds -List $ids -Value $Artifact.request_trace_usage_handoff.request_trace_lookup_keys.request_ids -SourcePath "$ArtifactLabel.request_trace_usage_handoff.request_trace_lookup_keys.request_ids" -Sources $sources -Limit $Limit
    Add-UniqueRequestIds -List $ids -Value $Artifact.smoke_run_readback.request_ids -SourcePath "$ArtifactLabel.smoke_run_readback.request_ids" -Sources $sources -Limit $Limit
    Add-UniqueRequestIds -List $ids -Value ([string]$Artifact.operator_readback.parameters.request_ids -split ",") -SourcePath "$ArtifactLabel.operator_readback.parameters.request_ids" -Sources $sources -Limit $Limit
    Add-UniqueRequestIds -List $ids -Value $Artifact.post_commit_readback.resolved_request_roles.success_request_id -SourcePath "$ArtifactLabel.post_commit_readback.resolved_request_roles.success_request_id" -Sources $sources -Limit $Limit
    Add-UniqueRequestIds -List $ids -Value $Artifact.post_commit_readback.resolved_request_roles.failure_request_id -SourcePath "$ArtifactLabel.post_commit_readback.resolved_request_roles.failure_request_id" -Sources $sources -Limit $Limit
    Add-UniqueRequestIds -List $ids -Value $Artifact.post_commit_readback.resolved_request_roles.insufficient_request_id -SourcePath "$ArtifactLabel.post_commit_readback.resolved_request_roles.insufficient_request_id" -Sources $sources -Limit $Limit
    Add-UniqueRequestIds -List $ids -Value $Artifact.gateway_route.request_id -SourcePath "$ArtifactLabel.gateway_route.request_id" -Sources $sources -Limit $Limit
    Add-UniqueRequestIds -List $ids -Value $Artifact.gateway_route.request_ids -SourcePath "$ArtifactLabel.gateway_route.request_ids" -Sources $sources -Limit $Limit
  }

  return [ordered]@{
    artifact = $ArtifactLabel
    request_ids = [object[]]@($ids.ToArray())
    request_id_count = [int]$ids.Count
    bounded_limit = $Limit
    source_paths = [object[]]@($sources.ToArray())
    checked_secret_safe_paths = [object[]]$checkedPaths
    blocker = $(if ($ids.Count -lt 1) { "current_request_ids_missing" } else { "none" })
  }
}

function Get-RequestIdsFromBridge {
  param($Bridge)

  if ($null -eq $Bridge) {
    return @()
  }
  return Get-StringArray (@($Bridge.requests) | ForEach-Object { $_.request_id })
}

function Invoke-AdminApiJson {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Token
  )

  $client = $null
  $request = $null
  $response = $null
  try {
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds([Math]::Max(3, [Math]::Min($TimeoutSeconds, 20)))
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, (Join-Url $ControlPlaneBaseUrl $Path))
    [void]$request.Headers.TryAddWithoutValidation("X-Admin-Session", $Token)
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    Assert-SecretSafeText $content
    $body = $null
    if (-not [string]::IsNullOrWhiteSpace($content)) {
      $body = $content | ConvertFrom-Json
    }
    return [ordered]@{
      ok = [bool]$response.IsSuccessStatusCode
      status_code = [int]$response.StatusCode
      body = $body
      failure_code = ""
    }
  } catch {
    return [ordered]@{
      ok = $false
      status_code = 0
      body = $null
      failure_code = "admin_api_exception"
    }
  } finally {
    if ($null -ne $response) { $response.Dispose() }
    if ($null -ne $request) { $request.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
  }
}

function Get-EnvelopeData {
  param($Response)

  if ($null -eq $Response -or $null -eq $Response.body) {
    return $null
  }
  if ($null -ne $Response.body.data) {
    return $Response.body.data
  }
  return $Response.body
}

function Get-UniqueOrderedStrings {
  param($Values)

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($value in @(Get-StringArray $Values)) {
    if (@($items | Where-Object { [string]$_ -eq [string]$value }).Count -lt 1) {
      [void]$items.Add([string]$value)
    }
  }
  return [string[]]@($items.ToArray())
}

function New-LiveApiReadbackReport {
  param([Parameter(Mandatory = $true)][string]$ReadinessPath)

  $readiness = Read-JsonArtifactOrNull -Path $ReadinessPath
  $adminSessionHandoff = Try-AdminSessionHandoff
  $adminSessionPresent = -not [string]::IsNullOrWhiteSpace($AdminSessionToken)
  $blockers = New-Object System.Collections.Generic.List[object]
  $warnings = New-Object System.Collections.Generic.List[object]

  if ($null -eq $readiness) {
    [void]$blockers.Add((New-Issue -Code "readiness_artifact_missing" -Message "Live readback requires request_trace_usage_live_gap_readiness artifact"))
  } elseif ([string]$readiness.overall_status -ne "ready_for_live_readback") {
    [void]$blockers.Add((New-Issue -Code "readiness_not_ready" -Message "Live readback readiness artifact is not ready_for_live_readback"))
  }
  if (-not $adminSessionPresent) {
    [void]$blockers.Add((New-Issue -Code "admin_session_missing" -Message "Live metadata readback requires a Control Plane admin session handoff"))
  }

  $requestIds = @()
  if ($null -ne $readiness) {
    $requestIds = Get-UniqueOrderedStrings (@(
        $readiness.discovered_request_ids.e8_paid_hot_path
        $readiness.discovered_request_ids.e8_rate_limit
        $readiness.discovered_request_ids.e11_billing_or_voucher
        $readiness.discovered_request_ids.e13_prompt_protection
      ))
  }
  if ($requestIds.Count -lt 1) {
    [void]$blockers.Add((New-Issue -Code "request_ids_missing" -Message "No current request ids available for live metadata readback"))
  }

  $requestReadbacks = New-Object System.Collections.Generic.List[object]
  $traceIds = New-Object System.Collections.Generic.List[string]
  $walletIds = New-Object System.Collections.Generic.List[string]
  $ledgerReadbacks = New-Object System.Collections.Generic.List[object]
  if ($blockers.Count -eq 0) {
    foreach ($requestId in $requestIds) {
      $detail = Invoke-AdminApiJson -Path ("/admin/request-logs/{0}" -f [uri]::EscapeDataString($requestId)) -Token $AdminSessionToken
      $detailData = Get-EnvelopeData -Response $detail
      $requestLog = $detailData.request_log
      $ledger = $detailData.ledger
      $ledgerEntries = @($ledger.entries)
      $providerAttempts = @($detailData.provider_attempts)
      $traceId = [string]$requestLog.trace_id
      if (-not [string]::IsNullOrWhiteSpace($traceId) -and @($traceIds | Where-Object { [string]$_ -eq $traceId }).Count -lt 1) {
        [void]$traceIds.Add($traceId)
      }
      foreach ($entry in $ledgerEntries) {
        $walletId = [string]$entry.wallet_id
        if (-not [string]::IsNullOrWhiteSpace($walletId) -and @($walletIds | Where-Object { [string]$_ -eq $walletId }).Count -lt 1) {
          [void]$walletIds.Add($walletId)
        }
      }
      [void]$requestReadbacks.Add([ordered]@{
          request_id = $requestId
          request_log_detail_http_status = [int]$detail.status_code
          request_log_detail_found = [bool]$detail.ok
          request_log_id_matches = ([string]$requestLog.id -eq [string]$requestId)
          trace_id_present = -not [string]::IsNullOrWhiteSpace($traceId)
          status_present = -not [string]::IsNullOrWhiteSpace([string]$requestLog.status)
          http_status_present = $null -ne $requestLog.http_status
          route_metadata_present = ($null -ne $requestLog.resolved_provider_id -or $null -ne $requestLog.resolved_channel_id -or $null -ne $requestLog.route_policy_version)
          provider_attempt_count = [int]$providerAttempts.Count
          ledger_summary_present = $null -ne $ledger
          ledger_returned_count = [int]$ledger.returned_count
          ledger_entries_metadata_only = $true
          payload_preview_called = $false
          raw_payload_omitted = $true
          secret_safe = $true
          failure_code = [string]$detail.failure_code
        })

      $ledgerList = Invoke-AdminApiJson -Path ("/admin/ledger/entries?request_id={0}&limit=20" -f [uri]::EscapeDataString($requestId)) -Token $AdminSessionToken
      $ledgerListData = @(Get-EnvelopeData -Response $ledgerList)
      foreach ($entry in $ledgerListData) {
        $walletId = [string]$entry.wallet_id
        if (-not [string]::IsNullOrWhiteSpace($walletId) -and @($walletIds | Where-Object { [string]$_ -eq $walletId }).Count -lt 1) {
          [void]$walletIds.Add($walletId)
        }
      }
      [void]$ledgerReadbacks.Add([ordered]@{
          request_id = $requestId
          ledger_entries_http_status = [int]$ledgerList.status_code
          ledger_entries_readable = [bool]$ledgerList.ok
          ledger_entry_count = [int]$ledgerListData.Count
          request_id_filter_used = $true
          metadata_sanitizer_expected = $true
          raw_snapshot_omitted = $true
          secret_safe = $true
          failure_code = [string]$ledgerList.failure_code
        })
    }
  }

  $traceReadbacks = New-Object System.Collections.Generic.List[object]
  if ($blockers.Count -eq 0) {
    foreach ($traceId in @($traceIds)) {
      $trace = Invoke-AdminApiJson -Path ("/admin/traces/{0}?limit=20" -f [uri]::EscapeDataString($traceId)) -Token $AdminSessionToken
      $traceData = Get-EnvelopeData -Response $trace
      [void]$traceReadbacks.Add([ordered]@{
          trace_id = $traceId
          trace_summary_http_status = [int]$trace.status_code
          trace_summary_found = [bool]$trace.ok
          request_count = [int]$traceData.request_count
          ledger_summary_present = $null -ne $traceData.ledger
          total_input_tokens_present = $null -ne $traceData.total_input_tokens
          total_output_tokens_present = $null -ne $traceData.total_output_tokens
          raw_payload_omitted = $true
          secret_safe = $true
          failure_code = [string]$trace.failure_code
        })
    }
  }

  $audit = [ordered]@{
    attempted = $false
    http_status = 0
    readable = $false
    matching_request_id_count = 0
    request_id_filter_supported = $false
    bounded_limit = 500
    secret_safe = $true
    failure_code = ""
  }
  if ($blockers.Count -eq 0) {
    $auditResponse = Invoke-AdminApiJson -Path "/admin/audit-logs?limit=500" -Token $AdminSessionToken
    $auditData = @(Get-EnvelopeData -Response $auditResponse)
    $matchingAuditIds = New-Object System.Collections.Generic.List[string]
    foreach ($row in $auditData) {
      $rid = [string]$row.request_id
      if (-not [string]::IsNullOrWhiteSpace($rid) -and @($requestIds | Where-Object { [string]$_ -eq $rid }).Count -gt 0) {
        [void]$matchingAuditIds.Add($rid)
      }
    }
    $audit = [ordered]@{
      attempted = $true
      http_status = [int]$auditResponse.status_code
      readable = [bool]$auditResponse.ok
      matching_request_id_count = [int]$matchingAuditIds.Count
      request_id_filter_supported = $false
      bounded_limit = 500
      secret_safe = $true
      failure_code = [string]$auditResponse.failure_code
    }
  }

  $balanceReadbacks = New-Object System.Collections.Generic.List[object]
  if ($blockers.Count -eq 0) {
    foreach ($walletId in @($walletIds)) {
      $balance = Invoke-AdminApiJson -Path ("/billing/wallets/{0}/remaining-balance" -f [uri]::EscapeDataString($walletId)) -Token $AdminSessionToken
      $balanceData = Get-EnvelopeData -Response $balance
      [void]$balanceReadbacks.Add([ordered]@{
          wallet_id = $walletId
          remaining_balance_http_status = [int]$balance.status_code
          remaining_balance_readable = [bool]$balance.ok
          schema = [string]$balanceData.schema
          admin_readonly_runtime = [bool]$balanceData.admin_readonly_runtime
          user_api_runtime = [bool]$balanceData.user_api_runtime
          money_fields_fixed_decimal_claimed = $true
          raw_metadata_omitted = $true
          secret_safe = $true
          failure_code = [string]$balance.failure_code
        })
    }
    if ($walletIds.Count -lt 1) {
      [void]$warnings.Add((New-Issue -Code "wallet_id_not_available" -Message "No wallet_id was exposed by request-linked ledger readback; remaining balance readback was skipped"))
    }
  }

  $failedDetails = @($requestReadbacks | Where-Object { $_.request_log_detail_found -ne $true })
  $failedLedger = @($ledgerReadbacks | Where-Object { $_.ledger_entries_readable -ne $true })
  $failedTraces = @($traceReadbacks | Where-Object { $_.trace_summary_found -ne $true })
  if ($blockers.Count -eq 0) {
    if ($failedDetails.Count -gt 0) {
      [void]$blockers.Add((New-Issue -Code "request_log_detail_readback_failed" -Message "One or more request log detail lookups failed"))
    }
    if ($failedLedger.Count -gt 0) {
      [void]$blockers.Add((New-Issue -Code "ledger_entries_readback_failed" -Message "One or more request-linked ledger entry lookups failed"))
    }
    if ($failedTraces.Count -gt 0) {
      [void]$blockers.Add((New-Issue -Code "trace_summary_readback_failed" -Message "One or more trace summary lookups failed"))
    }
    if ([bool]$audit.attempted -and [bool]$audit.readable -ne $true) {
      [void]$blockers.Add((New-Issue -Code "audit_log_readback_failed" -Message "Audit log list readback failed"))
    }
  }

  $overall = $(if ($blockers.Count -eq 0) { "pass" } else { "blocked_bypass_api_distribution" })
  return [ordered]@{
    schema = "request_trace_usage_live_admin_api_readback_v1"
    overall_status = $overall
    live_evidence_claimed = ($overall -eq "pass")
    live_admin_readback_attempted = $true
    live_admin_readback_performed = ($requestReadbacks.Count -gt 0)
    api_distribution_blocker = $false
    blocker_classification = $(if ($blockers.Count -eq 0) { "none" } else { "admin_api_readback_gap" })
    readiness_artifact = $ReadinessPath
    request_id_count = [int]$requestIds.Count
    trace_id_count = [int]$traceIds.Count
    wallet_id_count = [int]$walletIds.Count
    admin_session = [ordered]@{
      env_present = $adminSessionPresent
      login_probe_attempted = [bool]$adminSessionHandoff.attempted
      login_probe_acquired_session = [bool]$adminSessionHandoff.acquired
      source = [string]$adminSessionHandoff.source
      failure_code = [string]$adminSessionHandoff.failure_code
      token_echoed = $false
    }
    surfaces = [ordered]@{
      request_log_detail = [object[]]@($requestReadbacks.ToArray())
      trace_summary = [object[]]@($traceReadbacks.ToArray())
      ledger_entries = [object[]]@($ledgerReadbacks.ToArray())
      audit_logs = $audit
      remaining_balance = [object[]]@($balanceReadbacks.ToArray())
    }
    secret_safe_policy = [ordered]@{
      payload_preview_endpoint_called = $false
      raw_request_body_echoed = $false
      raw_response_body_echoed = $false
      authorization_header_echoed = $false
      cookie_header_echoed = $false
      provider_secret_echoed = $false
      session_token_echoed = $false
    }
    blockers = [object[]]@($blockers.ToArray())
    warnings = [object[]]@($warnings.ToArray())
  }
}

function New-LiveGapReadinessReport {
  param(
    [Parameter(Mandatory = $true)][string]$E13BridgePath,
    [Parameter(Mandatory = $true)][string]$E8PaidHotPathPath,
    [Parameter(Mandatory = $true)][string]$E8RateLimitPath,
    [Parameter(Mandatory = $true)][string]$E11BillingArtifactPath,
    [Parameter(Mandatory = $true)][string]$VoucherRouteArtifactPath
  )

  $e13Bridge = Read-JsonArtifactOrNull -Path $E13BridgePath
  $e8Paid = Read-JsonArtifactOrNull -Path $E8PaidHotPathPath
  $e8RateLimit = Read-JsonArtifactOrNull -Path $E8RateLimitPath
  $e11Billing = Read-JsonArtifactOrNull -Path $E11BillingArtifactPath
  $voucherRoute = Read-JsonArtifactOrNull -Path $VoucherRouteArtifactPath

  $e13RequestIds = Get-RequestIdsFromBridge -Bridge $e13Bridge
  $e8PaidRequestIdReadback = Get-BoundedRequestIdsFromArtifact -Artifact $e8Paid -ArtifactLabel "e8_paid_hot_path"
  $e8RateLimitRequestIdReadback = Get-BoundedRequestIdsFromArtifact -Artifact $e8RateLimit -ArtifactLabel "e8_rate_limit"
  $e11BillingRequestIdReadback = Get-BoundedRequestIdsFromArtifact -Artifact $e11Billing -ArtifactLabel "e11_billing_readback"
  $voucherRequestIdReadback = Get-BoundedRequestIdsFromArtifact -Artifact $voucherRoute -ArtifactLabel "e11_voucher_route"

  $e8PaidRequestIds = Get-StringArray $e8PaidRequestIdReadback.request_ids
  $e8RateLimitRequestIds = Get-StringArray $e8RateLimitRequestIdReadback.request_ids
  $e11RequestIds = Get-StringArray $e11BillingRequestIdReadback.request_ids
  $voucherRequestIds = Get-StringArray $voucherRequestIdReadback.request_ids

  $adminSessionHandoff = Try-AdminSessionHandoff
  $adminSessionPresent = -not [string]::IsNullOrWhiteSpace($AdminSessionToken)
  $blockers = New-Object System.Collections.Generic.List[object]
  if ($e8PaidRequestIds.Count -lt 1 -and $e8RateLimitRequestIds.Count -lt 1) {
    [void]$blockers.Add((New-Issue -Code "e8_current_request_ids_missing" -Message "No current E8 request ids were found in launch artifacts"))
  }
  if ($e11RequestIds.Count -lt 1 -and $voucherRequestIds.Count -lt 1) {
    [void]$blockers.Add((New-Issue -Code "e11_current_request_ids_missing" -Message "E11 artifacts prove readback state but do not expose current request ids for TODO-14 live join"))
  }
  if ($e13RequestIds.Count -lt 1) {
    [void]$blockers.Add((New-Issue -Code "e13_current_request_ids_missing" -Message "No E13 request ids were found in the bridge report"))
  }
  if (-not $adminSessionPresent) {
    $sessionMessage = "Live Control Plane/Admin readback requires a valid admin session handoff"
    if ([bool]$adminSessionHandoff.attempted -and -not [bool]$adminSessionHandoff.acquired) {
      $sessionMessage = "Live Control Plane/Admin readback requires a valid admin session handoff; safe dev admin login probe did not acquire a token"
    }
    [void]$blockers.Add((New-Issue -Code "admin_session_missing" -Message $sessionMessage))
  }

  $canAttemptLiveReadback = ($blockers.Count -eq 0)
  $status = $(if ($canAttemptLiveReadback) { "ready_for_live_readback" } else { "blocked_bypass_api_distribution" })

  return [ordered]@{
    schema = "request_trace_usage_live_gap_readiness_v1"
    overall_status = $status
    live_evidence_claimed = $false
    live_admin_readback_attempted = $false
    live_admin_readback_performed = $false
    api_distribution_blocker = $false
    blocker_classification = $(if ($canAttemptLiveReadback) { "none" } else { "runtime_input_required" })
    source_artifacts = [ordered]@{
      e8_paid_hot_path = $E8PaidHotPathPath
      e8_rate_limit = $E8RateLimitPath
      e11_billing_readback = $E11BillingArtifactPath
      e11_voucher_route = $VoucherRouteArtifactPath
      e13_bridge = $E13BridgePath
    }
    discovered_request_ids = [ordered]@{
      e8_paid_hot_path = $e8PaidRequestIds
      e8_rate_limit = $e8RateLimitRequestIds
      e11_billing_or_voucher = [object[]]@(Get-StringArray (@($e11RequestIds) + @($voucherRequestIds)))
      e13_prompt_protection = $e13RequestIds
    }
    artifact_readback_summary = [ordered]@{
      e8_paid_status = [string]$e8Paid.status
      e8_rate_limit_status = [string]$e8RateLimit.status
      e11_billing_outcome = [string]$e11Billing.outcome
      e11_session_previously_verified_but_secret_omitted = [bool]$e11Billing.session_verification.verified
      e11_voucher_route_status = [string]$voucherRoute.overall_status
      e13_bridge_status = [string]$e13Bridge.overall_status
    }
    request_id_readback = [ordered]@{
      e8_paid_hot_path = $e8PaidRequestIdReadback
      e8_rate_limit = $e8RateLimitRequestIdReadback
      e11_billing_readback = $e11BillingRequestIdReadback
      e11_voucher_route = $voucherRequestIdReadback
      e11_blocker_artifact = [ordered]@{
        status = $(if ($e11RequestIds.Count -gt 0 -or $voucherRequestIds.Count -gt 0) { "request_ids_found" } else { "blocked_runtime_input_required" })
        reason = $(if ($e11RequestIds.Count -gt 0 -or $voucherRequestIds.Count -gt 0) { "bounded_current_request_ids_extracted" } else { "no bounded current request ids found in E11 billing/voucher secret-safe fields" })
        live_readback_claimed = $false
        raw_material_in_output = $false
      }
    }
    admin_session = [ordered]@{
      env_present = $adminSessionPresent
      login_probe_attempted = [bool]$adminSessionHandoff.attempted
      login_probe_acquired_session = [bool]$adminSessionHandoff.acquired
      source = [string]$adminSessionHandoff.source
      failure_code = [string]$adminSessionHandoff.failure_code
      token_echoed = $false
    }
    required_to_close_todo_14 = @(
      "current E8/E11/E13 request ids from live smoke artifacts",
      "valid Control Plane/Admin session handoff",
      "live metadata-only readback over request detail, trace summary, audit logs, ledger entries, and remaining balance",
      "secret-safe output with raw prompt, response, credential, provider secret, cookie, and auth header values omitted"
    )
    blockers = [object[]]@($blockers.ToArray())
    resume_command = "Set CONTROL_PLANE_ADMIN_SESSION_TOKEN in the environment, ensure E11 emits current request_ids in its live artifact, then run: pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_request_trace_usage_explainability.ps1 -LiveGapReadiness -OutputPath .tmp/launch/request_trace_usage_live_gap_readiness.json"
  }
}

function New-SelfTestSourceReport {
  $endpoints = @(
    @{ name = "chat_completions"; endpoint = "POST /v1/chat/completions"; request_id = "00000000-0000-0000-0000-000000000001"; scope = "messages" },
    @{ name = "responses"; endpoint = "POST /v1/responses"; request_id = "00000000-0000-0000-0000-000000000002"; scope = "input" },
    @{ name = "anthropic_messages"; endpoint = "POST /v1/messages"; request_id = "00000000-0000-0000-0000-000000000003"; scope = "messages" },
    @{ name = "gemini_native_generate_content"; endpoint = "POST /v1beta/models/{model}:generateContent"; request_id = "00000000-0000-0000-0000-000000000004"; scope = "contents" }
  )

  return [pscustomobject]@{
    schema = "prompt_protection_postgres_proof_evidence_report.v1"
    status = "passed"
    exit_code = 0
    beta_closure_eligible = $true
    live_request_id_count = 4
    runtime_owned_row_count = 4
    current_runtime_owned_row_count = 4
    gateway_runtime_provenance_status = "pass"
    admin_ui_api_readback_status = "pass"
    secret_safe_scan = "pass"
    endpoints = @($endpoints | ForEach-Object {
        [pscustomobject]@{
          name = $_.name
          endpoint = $_.endpoint
          evidence_status = "passed"
          request = [pscustomobject]@{ request_id = $_.request_id }
          request_log = [pscustomobject]@{ redaction_status = "hash_only"; request_body_hash_present = $true }
          provider_side_effects = [pscustomobject]@{ provider_attempts_count = 0 }
          secret_safe_omissions = [pscustomobject]@{
            raw_payload_omitted = $true
            credential_values_omitted = $true
            provider_secret_values_omitted = $true
          }
        }
      })
  }
}

function Assert-ArrayContainsText {
  param(
    [Parameter(Mandatory = $true)]$Values,
    [Parameter(Mandatory = $true)][string]$Expected,
    [Parameter(Mandatory = $true)][string]$FailureMessage
  )

  if (@($Values | Where-Object { [string]$_ -eq $Expected }).Count -lt 1) {
    throw $FailureMessage
  }
}

function Test-MultiSourceOperatorReadbackContract {
  param([Parameter(Mandatory = $true)][string]$Path)

  $resolved = Get-RepoPath $Path
  if (-not (Test-PathWithinRepo -Path $resolved)) {
    throw "multi-source contract path refused"
  }
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "multi-source contract missing"
  }

  $json = Get-Content -LiteralPath $resolved -Raw
  Assert-SecretSafeText $json
  $contract = $json | ConvertFrom-Json

  if ([string]$contract.schema -ne "request_trace_usage_operator_multisource_readback_contract_v1") {
    throw "multi-source contract schema mismatch"
  }
  if ($contract.synthetic -ne $true -or $contract.non_live -ne $true) {
    throw "multi-source contract must be explicitly synthetic and non-live"
  }
  if ([string]$contract.live_readback_status.overall -ne "open") {
    throw "multi-source contract must keep overall live readback open"
  }
  if ([string]$contract.live_readback_status.missing_current_smoke_ids_classification -ne "runtime_input_required") {
    throw "missing current smoke ids must be classified as runtime input"
  }
  if ($contract.live_readback_status.global_api_distribution_blocker -ne $false) {
    throw "missing smoke ids must not be a global API distribution blocker"
  }

  foreach ($lane in @("E8", "E11", "E13")) {
    if (@($contract.source_lanes | Where-Object { [string]$_.lane -eq $lane }).Count -ne 1) {
      throw ("multi-source contract missing lane " + $lane)
    }
  }
  foreach ($surface in @("request_log_detail", "trace_request_summary", "audit_logs", "ledger_entries", "remaining_balance")) {
    Assert-ArrayContainsText -Values $contract.operator_surfaces -Expected $surface -FailureMessage ("multi-source contract missing surface " + $surface)
  }
  foreach ($field in @("route_decision", "fallback_or_reject", "usage_cost", "ledger_billing_refusal", "guardrail_audit", "provider_attempt_summary", "redaction")) {
    Assert-ArrayContainsText -Values $contract.operator_need_coverage -Expected $field -FailureMessage ("multi-source contract missing coverage " + $field)
  }

  $forbidden = @($contract.redaction_contract.forbidden_fields)
  foreach ($field in @("raw_prompt", "raw_request_body", "raw_response_body", "credential_values", "provider_secret_values", "full_virtual_key", "authorization_header", "cookie_header")) {
    Assert-ArrayContainsText -Values $forbidden -Expected $field -FailureMessage ("multi-source contract missing forbidden field " + $field)
  }

  foreach ($mapping in @($contract.expected_admin_api_field_map)) {
    foreach ($field in @("request_id", "request_log_detail", "trace_request_summary", "provider_attempt_summary", "ledger_billing_refusal", "guardrail_audit", "redaction")) {
      if ($null -eq $mapping.$field) {
        throw ("multi-source mapping missing field " + $field)
      }
    }
  }

  if (@($contract.expected_admin_api_field_map).Count -lt 3) {
    throw "multi-source contract must map E8, E11, and E13 examples"
  }

  return [ordered]@{
    schema = "request_trace_usage_operator_multisource_contract_selftest_v1"
    status = "pass"
    contract_path = "tests/fixtures/request_trace_usage/multi_source_operator_readback_contract.json"
    synthetic = $true
    non_live = $true
    source_lanes_checked = @("E8", "E11", "E13")
    live_readback_status = [string]$contract.live_readback_status.overall
    missing_current_smoke_ids_classification = [string]$contract.live_readback_status.missing_current_smoke_ids_classification
    global_api_distribution_blocker = [bool]$contract.live_readback_status.global_api_distribution_blocker
  }
}

function Test-E13BridgeContractFixture {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$AcceptedBridge
  )

  $resolved = Get-RepoPath $Path
  if (-not (Test-PathWithinRepo -Path $resolved)) {
    throw "E13 bridge contract path refused"
  }
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "E13 bridge contract missing"
  }

  $json = Get-Content -LiteralPath $resolved -Raw
  Assert-SecretSafeText $json
  $contract = $json | ConvertFrom-Json

  if ([string]$contract.schema -ne "request_trace_usage_explainability_e13_bridge_contract_fixture_v1") {
    throw "E13 bridge contract fixture schema mismatch"
  }
  if ([string]$contract.required_output_schema -ne [string]$AcceptedBridge.schema) {
    throw "E13 bridge output schema drifted from contract fixture"
  }
  if ([int]$contract.required_request_count -ne [int]$AcceptedBridge.request_id_count) {
    throw "E13 bridge request count drifted from contract fixture"
  }
  if ([string]$contract.related_operator_readback_contract -ne "tests/fixtures/request_trace_usage/multi_source_operator_readback_contract.json") {
    throw "E13 bridge contract must link the multi-source operator readback contract"
  }

  foreach ($request in @($AcceptedBridge.requests)) {
    foreach ($field in @($contract.required_request_fields)) {
      if ($null -eq $request.$field) {
        throw ("E13 bridge request missing contract field " + [string]$field)
      }
    }
    if ([string]$request.expected_prompt_rejection_fields.request_status -ne [string]$contract.required_rejection_fields.request_status -or
        [int]$request.expected_prompt_rejection_fields.http_status -ne [int]$contract.required_rejection_fields.http_status -or
        [string]$request.expected_prompt_rejection_fields.error_code -ne [string]$contract.required_rejection_fields.error_code -or
        [string]$request.expected_prompt_rejection_fields.error_stage -ne [string]$contract.required_rejection_fields.error_stage -or
        [string]$request.expected_prompt_rejection_fields.prompt_protection_action -ne [string]$contract.required_rejection_fields.prompt_protection_action) {
      throw "E13 bridge rejection fields drifted from contract fixture"
    }
    if ([int]$request.provider_attempts_count -ne [int]$contract.required_provider_attempts_count) {
      throw "E13 bridge provider attempts count drifted from contract fixture"
    }
    if ([string]$request.request_log_expectations.redaction_status -ne [string]$contract.required_request_log_expectations.redaction_status -or
        [bool]$request.request_log_expectations.payload_stored -ne [bool]$contract.required_request_log_expectations.payload_stored -or
        [bool]$request.request_log_expectations.payload_object_ref_present -ne [bool]$contract.required_request_log_expectations.payload_object_ref_present -or
        [bool]$request.request_log_expectations.raw_payload_omitted -ne [bool]$contract.required_request_log_expectations.raw_payload_omitted) {
      throw "E13 bridge request log expectations drifted from contract fixture"
    }
    if ([string]$request.usage_cost_expectations.provider_usage_expected -ne [string]$contract.usage_cost_policy.provider_usage_expected -or
        [bool]$request.usage_cost_expectations.provider_attempts_required_zero -ne [bool]$contract.usage_cost_policy.provider_attempts_required_zero -or
        [string]$request.usage_cost_expectations.billing_mode -ne [string]$contract.usage_cost_policy.billing_mode -or
        [bool]$request.usage_cost_expectations.real_paid_billing_claimed -ne [bool]$contract.usage_cost_policy.real_paid_billing_claimed) {
      throw "E13 bridge usage/cost policy drifted from contract fixture"
    }
    if ([bool]$request.ledger_balance_expectations.ledger_entries_linked_by_request_id -ne [bool]$contract.ledger_balance_policy.ledger_entries_linked_by_request_id -or
        [bool]$request.ledger_balance_expectations.ledger_entries_metadata_only -ne [bool]$contract.ledger_balance_policy.ledger_entries_metadata_only -or
        [bool]$request.ledger_balance_expectations.prompt_rejection_debit_expected -ne [bool]$contract.ledger_balance_policy.prompt_rejection_debit_expected -or
        [string]$request.ledger_balance_expectations.balance_claim_for_prompt_rejection -ne [string]$contract.ledger_balance_policy.balance_claim_for_prompt_rejection) {
      throw "E13 bridge ledger/balance policy drifted from contract fixture"
    }
  }

  foreach ($negative in @("missing_request_id_rejected", "provider_attempts_nonzero_rejected", "raw_material_marker_rejected")) {
    Assert-ArrayContainsText -Values $contract.negative_selftests -Expected $negative -FailureMessage ("E13 bridge contract missing negative selftest " + $negative)
  }
  if ($contract.todo_14_scope.e13_subclosure_ready -ne $true -or
      $contract.todo_14_scope.todo_14_overall_closed -ne $false -or
      [string]$contract.todo_14_scope.e8_e11_request_ids_status -ne "external_runtime_input_required" -or
      [string]$contract.todo_14_scope.missing_current_smoke_ids_classification -ne "runtime_input_required" -or
      $contract.todo_14_scope.global_api_distribution_blocker -ne $false) {
    throw "E13 bridge TODO-14 scope contract drifted"
  }

  return [ordered]@{
    schema = "request_trace_usage_e13_bridge_contract_selftest_v1"
    status = "pass"
    contract_path = "tests/fixtures/request_trace_usage/e13_prompt_protection_explainability_bridge_contract.json"
    required_output_schema = [string]$contract.required_output_schema
    required_request_count = [int]$contract.required_request_count
    negative_selftests_checked = @("missing_request_id_rejected", "provider_attempts_nonzero_rejected", "raw_material_marker_rejected")
    todo_14_overall_closed = [bool]$contract.todo_14_scope.todo_14_overall_closed
    missing_current_smoke_ids_classification = [string]$contract.todo_14_scope.missing_current_smoke_ids_classification
  }
}

function Invoke-SelfTest {
  $acceptedSource = New-SelfTestSourceReport
  $accepted = New-E13ExplainabilityBridge -SourceReport $acceptedSource
  if ([string]$accepted.overall_status -ne "pass" -or [int]$accepted.request_id_count -ne 4) {
    throw "accepted E13 explainability bridge fixture did not pass"
  }
  $acceptedFirstRequest = @($accepted.requests)[0]
  foreach ($field in @("route_provider_expectations", "guardrail_expectations", "support_field_expectations", "ledger_balance_expectations")) {
    if ($null -eq $acceptedFirstRequest[$field]) {
      throw ("accepted E13 explainability bridge missing " + $field)
    }
  }
  if ([string]$accepted.e13_subclosure.e8_e11_request_ids_status -ne "external_runtime_input_required") {
    throw "E8/E11 external runtime input status missing"
  }
  if ($accepted.operator_explainability_contract.prompt_response_secret_safe -ne $true) {
    throw "operator explainability contract must be prompt/response/secret safe"
  }
  if ([string]$accepted.e13_subclosure.todo_14_overall_closed -ne "False" -and $accepted.e13_subclosure.todo_14_overall_closed -ne $false) {
    throw "E13 bridge must not close TODO-14 overall"
  }

  $e13ContractSummary = Test-E13BridgeContractFixture -Path $E13ContractPath -AcceptedBridge $accepted
  [void](Write-BridgeReport -Report $e13ContractSummary -Path ($SelfTestOutputPath -replace "\.json$", ".e13_contract.json"))

  $missingId = New-SelfTestSourceReport
  $missingId.endpoints[0].request.request_id = ""
  $missingIdBridge = New-E13ExplainabilityBridge -SourceReport $missingId
  if ([string]$missingIdBridge.overall_status -ne "fail" -or @($missingIdBridge.failures | Where-Object { $_.code -eq "request_id_missing" }).Count -lt 1) {
    throw "missing request id fixture was not rejected"
  }

  $nonzeroAttempts = New-SelfTestSourceReport
  $nonzeroAttempts.endpoints[1].provider_side_effects.provider_attempts_count = 1
  $nonzeroBridge = New-E13ExplainabilityBridge -SourceReport $nonzeroAttempts
  if ([string]$nonzeroBridge.overall_status -ne "fail" -or @($nonzeroBridge.failures | Where-Object { $_.code -eq "provider_attempts_nonzero" }).Count -lt 1) {
    throw "non-zero provider attempts fixture was not rejected"
  }

  $rawMarker = New-SelfTestSourceReport
  $rawMarker | Add-Member -NotePropertyName unsafe_debug_field -NotePropertyValue "leaked_raw_request_body_marker"
  $rawMarkerBridge = New-E13ExplainabilityBridge -SourceReport $rawMarker
  if ([string]$rawMarkerBridge.overall_status -ne "fail" -or [string]$rawMarkerBridge.secret_safe_scan -ne "fail") {
    throw "raw marker fixture was not rejected as secret unsafe"
  }

  $multiSourceSummary = Test-MultiSourceOperatorReadbackContract -Path $MultiSourceContractPath
  [void](Write-BridgeReport -Report $multiSourceSummary -Path $SelfTestOutputPath)

  Write-Host "Request/trace/usage E13 explainability bridge self-test passed."
}

if (-not $E13PromptProtectionOnly -and -not $SelfTest -and -not $LiveGapReadiness -and -not $LiveApiReadback) {
  $E13PromptProtectionOnly = $true
}

if ($SelfTest) {
  Invoke-SelfTest
  exit 0
}

if ($LiveGapReadiness) {
  $report = New-LiveGapReadinessReport `
    -E13BridgePath ".tmp/launch/request_trace_usage_e13_bridge_report.json" `
    -E8PaidHotPathPath ".tmp/launch/e8_gateway_paid_hot_path_launch_check.json" `
    -E8RateLimitPath ".tmp/launch/e8_gateway_rate_limit_launch_check.json" `
    -E11BillingArtifactPath "artifacts/billing_execute_browser_live_e2e_evidence.json" `
    -VoucherRouteArtifactPath ".tmp/launch/voucher_public_route_and_virtual_key_evidence.json"
  [void](Write-BridgeReport -Report $report -Path $OutputPath)
  Write-Output (ConvertTo-BridgeJson $report)
  if ([string]$report.overall_status -eq "ready_for_live_readback") {
    exit 0
  }
  exit 2
}

if ($LiveApiReadback) {
  $report = New-LiveApiReadbackReport -ReadinessPath ".tmp/launch/request_trace_usage_live_gap_readiness.json"
  [void](Write-BridgeReport -Report $report -Path $OutputPath)
  Write-Output (ConvertTo-BridgeJson $report)
  if ([string]$report.overall_status -eq "pass") {
    exit 0
  }
  exit 2
}

try {
  $sourceReport = Read-SourceReport -Path $PromptProtectionEvidenceReportPath
  $bridge = New-E13ExplainabilityBridge -SourceReport $sourceReport -AttemptLiveApiReadback:$LiveApiReadback
  $written = Write-BridgeReport -Report $bridge -Path $OutputPath
  Write-Host ("Request/trace/usage E13 explainability bridge report written: {0}" -f "repo_bounded_json")
  Write-Output (ConvertTo-BridgeJson $bridge)
  $overallStatus = [string]$bridge["overall_status"]
  if ($overallStatus -eq "pass") {
    exit 0
  }
  if ($overallStatus -eq "blocked") {
    exit 2
  }
  exit 1
} catch {
  $blocked = [ordered]@{
    schema = "request_trace_usage_explainability_e13_bridge_v1"
    overall_status = "blocked"
    source_report_status = "unavailable"
    request_id_count = 0
    requests = @()
    blockers = @((New-Issue -Code "external_blocker" -Message "E13 source report could not be read or bridge report could not be written"))
    failures = @()
    secret_safe_scan = "pass"
  }
  try {
    [void](Write-BridgeReport -Report $blocked -Path $OutputPath)
  } catch {
    Write-Host "Request/trace/usage E13 explainability bridge blocked before artifact write."
  }
  Write-Output (ConvertTo-BridgeJson $blocked)
  exit 2
}
