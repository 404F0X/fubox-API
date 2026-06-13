#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$OutputPath = ".tmp/control-plane/provider_key_production_rotation_readiness.json",
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$script:Failures = @()
$script:Observed = [ordered]@{}

function Add-Failure {
  param([Parameter(Mandatory = $true)][string]$Message)
  $script:Failures += $Message
  Write-Host "[FAIL] $Message"
}

function Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    & $Action
    Write-Host "[OK] $Name"
  } catch {
    Add-Failure "$Name - $($_.Exception.Message)"
  }
}

function Assert-Contains {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Needle,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not $Content.Contains($Needle)) {
    throw "$Label missing marker '$Needle'"
  }
}

function Assert-NotContains {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Needle,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ($Content.Contains($Needle)) {
    throw "$Label unexpectedly contains marker '$Needle'"
  }
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return $true }

  foreach ($pattern in @(
      '(?i)"(?:secret|api_key|encrypted_secret|secret_fingerprint|current_window_state)"\s*:\s*"(?!\[REDACTED\])',
      '(?i)"(?:authorization|cookie|x-admin-session)"\s*:',
      '(?i)authorization\s*[:=]\s*bearer\s+[^"\s,}]+',
      '(?i)encrypted[_-]?secret\s*[:=]\s*[^"\s,}]+',
      'sk-[A-Za-z0-9._~+\-/=]{8,}',
      'sess_[A-Za-z0-9._~+/\-=]{8,}'
    )) {
    if ($Text -match $pattern) {
      return $false
    }
  }
  return $true
}

function Assert-SecretSafeText {
  param(
    [AllowNull()][string]$Text,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-SecretSafeText $Text)) {
    throw "$Label contains credential-shaped material"
  }
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  $path = Join-Path $repoRoot $RelativePath
  if (-not (Test-Path $path)) {
    throw "missing $RelativePath"
  }

  try {
    return Get-Content -Raw $path | ConvertFrom-Json
  } catch {
    throw "$RelativePath is not valid JSON: $($_.Exception.Message)"
  }
}

function Assert-RotationContractFixture {
  $fixture = Read-JsonFile "tests\fixtures\control-plane\provider_key_status_contract.json"
  if ($fixture.rotation_contract.path -ne "POST /admin/provider-keys/{id}/rotate") {
    throw "rotation contract must reserve POST /admin/provider-keys/{id}/rotate"
  }
  if ($fixture.rotation_contract.audit_action -ne "provider_key.rotate") {
    throw "rotation contract must reserve provider_key.rotate"
  }
  if ([bool]$fixture.rotation_contract.server_seals_secret -ne $true) {
    throw "rotation contract must require server-side sealing"
  }
  if ([bool]$fixture.rotation_contract.audit_secret_safe -ne $true) {
    throw "rotation contract must require secret-safe audit"
  }
  if ($fixture.rotation_contract.encrypted_at_rest_algorithm -ne "aes-256-gcm") {
    throw "rotation contract must remain aes-256-gcm"
  }
  $script:Observed.rotation_fixture_contract = "runtime_contract_present"
}

function Assert-ControlPlaneSurface {
  $adminSource = Get-Content -Raw (Join-Path $repoRoot "apps\control-plane\src\admin.rs")
  $rbacSource = Get-Content -Raw (Join-Path $repoRoot "apps\control-plane\src\rbac.rs")
  foreach ($needle in @(
      '"/admin/provider-keys"',
      'get(list_provider_keys).post(create_provider_key)',
      '"/admin/provider-keys/{id}"',
      '.patch(patch_provider_key)',
      '.delete(delete_provider_key)',
      '"/admin/provider-keys/{id}/recovery"',
      '"/admin/provider-keys/{id}/rotate"',
      'axum::routing::post(rotate_provider_key)',
      'async fn rotate_provider_key',
      'provider_key_rotation_response',
      'provider_key.rotate',
      'server_seals_secret',
      'provider_key_response',
      'provider_key_lifecycle_state',
      'provider_key_credential_generation',
      'provider_key_rotation_needed',
      'provider_key_safe_next_action',
      'provider_key_omitted_secret_policy',
      'reject_provider_key_secret_fields',
      'reject_provider_key_rotate_generated_fields',
      'credential_configured',
      'secret_redacted',
      'provider_key.recovery_request'
    )) {
    Assert-Contains -Content $adminSource -Needle $needle -Label "Control Plane provider-key source"
  }

  Assert-Contains -Content $rbacSource -Needle 'path: "/admin/provider-keys/{id}/recovery"' -Label "RBAC source"
  Assert-Contains -Content $rbacSource -Needle 'path: "/admin/provider-keys/{id}/rotate"' -Label "RBAC source"
  Assert-Contains -Content $rbacSource -Needle 'key: "provider_key.rotate"' -Label "RBAC source"
  $script:Observed.runtime_rotate_endpoint_implemented = $true
  $script:Observed.bounded_admin_surfaces_present = $true
}

function Assert-AuditReadbackVerifierContract {
  $source = Get-Content -Raw (Join-Path $repoRoot "scripts\verify_provider_key_audit_readback.ps1")
  foreach ($needle in @(
      'production_rotation_requires_kms_or_master_key_policy',
      'runtime_rotate_endpoint_implemented = $true',
      'view_audit_endpoint_implemented = $false',
      'Assert-ProviderKeyPayloadSafe',
      'Assert-SecretSafeText',
      'provider_key.update'
    )) {
    Assert-Contains -Content $source -Needle $needle -Label "audit readback verifier"
  }
  $script:Observed.audit_readback_verifier_contract = "pass"
}

function Assert-OpenApiRotationContract {
  $openapi = Get-Content -Raw (Join-Path $repoRoot "examples\openapi_admin_skeleton.yaml")
  foreach ($needle in @(
      "x-provider-key-production-rotation-contract:",
      "runtime_rotate_endpoint_implemented: true",
      "path: POST /admin/provider-keys/{id}/rotate",
      "status_until_production_evidence_lands: production_ready_blocked",
      "kms_or_master_key_custody_policy_required: true",
      "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64",
      "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID",
      "audit_action: provider_key.rotate",
      "secret_safe_response_required: true",
      "lifecycle_state",
      "credential_generation",
      "last_probe_summary",
      "rotation_needed",
      "safe_next_action",
      "omitted_secret_policy"
    )) {
    Assert-Contains -Content $openapi -Needle $needle -Label "OpenAPI provider-key rotation contract"
  }
  $script:Observed.openapi_rotation_contract = "runtime_present_production_blocked"
}

function Assert-RunbookChecklist {
  $runbook = Get-Content -Raw (Join-Path $repoRoot "docs\E3_PROVIDER_KEY_AUDIT_READBACK_RUNBOOK.md")
  foreach ($needle in @(
      "Production Rotation Readiness Resume Checklist",
      "create-new-key / verify-traffic / disable-old-key",
      "safe substitute flow",
      "KMS/master-key custody policy",
      "external dependency",
      "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64",
      "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID",
      "runtime rotate endpoint is implemented",
      "production closure remains blocked",
      "provider_key.update",
      "provider_key.rotate",
      "credential_configured",
      "lifecycle_state",
      "credential_generation",
      "last_probe_summary",
      "rotation_needed.reason",
      "safe_next_action",
      "omitted_secret_policy",
      "secret_redacted",
      ".\scripts\verify_provider_key_runtime_smoke.ps1 -DryRun"
    )) {
    Assert-Contains -Content $runbook -Needle $needle -Label "provider-key runbook"
  }
  Assert-SecretSafeText -Text $runbook -Label "provider-key runbook"
  $script:Observed.runbook_resume_checklist = "pass"
}

function Resolve-OutputPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $full = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }
  $root = $repoRoot.Path.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must stay inside repository"
  }
  $relative = $full.Substring($root.Length) -replace "\\", "/"
  if (-not $relative.StartsWith(".tmp/control-plane/", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must stay under .tmp/control-plane/"
  }
  return $full
}

function New-ReadinessArtifact {
  return [ordered]@{
    schema = "provider_key_production_rotation_readiness.v1"
    status = "production_ready_blocked"
    classification = "runtime_rotate_endpoint_implemented_production_evidence_missing"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    final_rotation_closure_allowed = $false
    runtime_rotate_endpoint_implemented = $true
    runtime_rotate_endpoint = [ordered]@{
      blocker = "production_evidence_missing"
      contract = "POST /admin/provider-keys/{id}/rotate"
      current_runtime_route_present = $true
      rbac_route_present = $true
      openapi_contract_kind = "implemented_runtime_surface_production_blocked"
      server_side_sealing = $true
      audit_action = "provider_key.rotate"
      current_status = "production_ready_blocked"
    }
    bounded_substitute_allowed = $true
    bounded_substitute = [ordered]@{
      name = "create-new-key / verify-traffic / disable-old-key"
      requires_change_window = $true
      fallback_when_runtime_rotate_not_allowed = $true
      provider_key_rotate_audit_action_available = $true
      steps = @(
        "Create a new provider key through POST /admin/provider-keys with raw secret supplied only in the request body; the server seals it and responses must expose only credential_configured/secret_redacted.",
        "Read back GET /admin/provider-keys/{new_id}; confirm status, channel, alias, limits, credential_configured=true, secret_redacted=true, and no secret/encrypted_secret/secret_fingerprint/current_window_state fields.",
        "Run provider traffic proof on the new key's channel/model; use scripts\\verify_provider_key_runtime_smoke.ps1 -DryRun for contract preflight and a live smoke/readback in the approved environment before disabling the old key.",
        "Read request_logs/provider_attempts provider_key_id evidence for the new key and confirm provider error output is secret-safe.",
        "Disable the old key with PATCH /admin/provider-keys/{old_id} status=manual_disabled only after traffic proof passes.",
        "Read back provider_key.update/provider_key.rotate audit rows through /admin/audit-logs and confirm the artifact is secret-safe."
      )
    }
    external_dependencies = [ordered]@{
      kms_or_master_key_policy_required = $true
      dependency_type = "external_kms_or_master_key_custody_evidence"
      kms_integration_implemented = $false
      master_key_custody_policy_required = $true
      custody_evidence_present_in_repo = $false
      required_env = @(
        "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64",
        "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID"
      )
      production_requirements = @(
        "Master key source must be an approved KMS/secret manager or an externally documented custody process.",
        "Production must not reuse dev-seed-v1 or any dev seed provider-key master key.",
        "Custody evidence must name owner, storage location, access policy, rotation cadence, break-glass process, rollback process, and audit trail."
      )
    }
    audit_readback_secret_safe_checks = [ordered]@{
      admin_readback_verifier = "scripts\\verify_provider_key_audit_readback.ps1 -DryRun"
      runtime_contract_preflight = "scripts\\verify_provider_key_runtime_smoke.ps1 -DryRun"
      required_audit_actions = @("provider_key.update", "provider_key.rotate")
      forbidden_material = @(
        "secret",
        "api_key",
        "encrypted_secret",
        "secret_fingerprint",
        "current_window_state",
        "Authorization",
        "Bearer token"
      )
    }
    checks = $script:Observed
    blockers = @(
      "kms_or_master_key_custody_policy_missing",
      "production_live_traffic_readback_missing",
      "old_key_disable_audit_readback_missing"
    )
    next_commands = @(
      "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\verify_provider_key_production_rotation_readiness.ps1",
      "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\verify_provider_key_audit_readback.ps1 -DryRun",
      "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\verify_provider_key_runtime_smoke.ps1 -DryRun"
    )
    secret_safe = ($script:Failures.Count -eq 0)
    failures = @($script:Failures)
  }
}

function Write-Artifact {
  $full = Resolve-OutputPath $OutputPath
  $directory = Split-Path -Parent $full
  if (-not (Test-Path $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }

  $artifact = New-ReadinessArtifact
  $json = $artifact | ConvertTo-Json -Depth 32
  Assert-SecretSafeText -Text $json -Label "readiness artifact"
  Set-Content -Path $full -Value $json -Encoding UTF8
}

Check "rotation contract fixture matches runtime rotate surface" {
  Assert-RotationContractFixture
}

Check "Control Plane provider-key surface exposes rotate runtime and bounded substitute" {
  Assert-ControlPlaneSurface
}

Check "audit readback verifier exposes KMS/runtime blockers" {
  Assert-AuditReadbackVerifierContract
}

Check "OpenAPI documents rotate runtime with production blockers" {
  Assert-OpenApiRotationContract
}

Check "runbook has production rotation resume checklist" {
  Assert-RunbookChecklist
}

if ($SelfTest) {
  Check "selftest secret-safe detector rejects raw credential shapes" {
    if (Test-SecretSafeText '{"secret":"raw-test-credential-like-value"}') {
      throw "secret-safe detector did not reject raw secret field"
    }
  }
  Check "selftest output path guard rejects paths outside .tmp/control-plane" {
    $blocked = $false
    try {
      [void](Resolve-OutputPath "artifacts/provider_key_rotation.json")
    } catch {
      $blocked = $true
    }
    if (-not $blocked) {
      throw "output path guard did not reject artifacts/provider_key_rotation.json"
    }
  }
}

Write-Artifact

if ($script:Failures.Count -gt 0) {
  Write-Host ""
  Write-Host "Provider key production rotation readiness verifier failed."
  exit 1
}

Write-Host ""
Write-Host "Provider key production rotation readiness verifier passed; runtime rotate endpoint exists, but production rotation remains blocked until KMS/master-key custody and live traffic/readback evidence exist."
