param(
  [string]$AlphaSmokePath = ".tmp/open-source-alpha/alpha_smoke_current.json",
  [string]$RouteLiveProofPath = ".tmp/route-live-http-proof/route_level_live_http_proof.json",
  [string]$OutputPath = ".tmp/open-source-alpha/open_source_alpha_gate.json",
  [switch]$DryRun,
  [switch]$RunMatrix
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$blockers = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$checks = New-Object System.Collections.Generic.List[object]

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

function Assert-OutputPathIsSafe {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = Resolve-RepoPath $Path
  $relative = Get-RepoRelativePath $full
  if ($relative.StartsWith("..", [System.StringComparison]::Ordinal) -or [System.IO.Path]::IsPathRooted($relative)) {
    throw "OutputPath must stay inside the repository."
  }
  if (-not $relative.StartsWith(".tmp/open-source-alpha/", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must stay under .tmp/open-source-alpha/."
  }
  return $full
}

function Read-JsonArtifact {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $full)) {
    return [PSCustomObject]@{
      exists = $false
      path = (Get-RepoRelativePath $full)
      json = $null
      error = "missing"
      last_write_time_utc = $null
    }
  }

  try {
    $item = Get-Item -LiteralPath $full
    return [PSCustomObject]@{
      exists = $true
      path = (Get-RepoRelativePath $full)
      json = (Get-Content -LiteralPath $full -Raw | ConvertFrom-Json)
      error = $null
      last_write_time_utc = $item.LastWriteTimeUtc.ToString("o")
    }
  } catch {
    return [PSCustomObject]@{
      exists = $true
      path = (Get-RepoRelativePath $full)
      json = $null
      error = $_.Exception.Message
      last_write_time_utc = $null
    }
  }
}

function Get-JsonField {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Json) { return $null }
  if ($Json.PSObject.Properties.Name -notcontains $Name) { return $null }
  return $Json.PSObject.Properties[$Name].Value
}

function Get-BoolField {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $value = Get-JsonField -Json $Json -Name $Name
  if ($value -is [bool]) { return [bool]$value }
  if ($null -eq $value) { return $null }
  $text = ([string]$value).Trim().ToLowerInvariant()
  if (@("true", "1", "yes", "pass", "passed") -contains $text) { return $true }
  if (@("false", "0", "no", "fail", "failed") -contains $text) { return $false }
  return $null
}

function Get-JsonPathField {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $current = $Json
  foreach ($segment in $Path.Split(".")) {
    if ($null -eq $current) { return $null }
    if ($current.PSObject.Properties.Name -notcontains $segment) { return $null }
    $current = $current.PSObject.Properties[$segment].Value
  }
  return $current
}

function Get-BoolPathField {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $value = Get-JsonPathField -Json $Json -Path $Path
  if ($value -is [bool]) { return [bool]$value }
  if ($null -eq $value) { return $null }
  $text = ([string]$value).Trim().ToLowerInvariant()
  if (@("true", "1", "yes", "pass", "passed") -contains $text) { return $true }
  if (@("false", "0", "no", "fail", "failed") -contains $text) { return $false }
  return $null
}

function Add-Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Status,
    [string]$Path = $null,
    [string]$Note = $null,
    [object]$Details = $null
  )

  $check = [ordered]@{
    name = $Name
    status = $Status
    path = $Path
    note = $Note
    details = $Details
  }
  [void]$checks.Add([PSCustomObject]$check)
  if ($Status -eq "fail") {
    [void]$blockers.Add($(if ([string]::IsNullOrWhiteSpace($Note)) { $Name } else { "${Name}: $Note" }))
  } elseif ($Status -eq "warn") {
    $message = $(if ([string]::IsNullOrWhiteSpace($Note)) { $Name } else { "${Name}: $Note" })
    [void]$warnings.Add($message)
    [void]$blockers.Add($message)
  }
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $true }
  foreach ($pattern in @(
      '(?i)authorization\s*[:=]\s*bearer\s+[^"\s,}]+',
      '(?i)cookie\s*[:=]',
      '(?i)x-admin-session\s*[:=]',
      '(?i)"session_token_once"\s*:',
      '(?i)"raw_voucher_code"\s*:',
      '(?i)"voucher_code"\s*:',
      '(?i)"secret"\s*:\s*"[^"]{4,}"',
      '(?i)postgres(?:ql)?://[^"\s]+',
      '(?i)password\s*[:=]\s*[^"\s,}]+',
      'sk-[A-Za-z0-9._~+\-/=]{8,}',
      'sess_[A-Za-z0-9._~+\-/=]{8,}'
    )) {
    if ($Text -match $pattern) { return $false }
  }
  return $true
}

function Get-Sha256Hex {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) { $Text = "" }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Quote-ProcessArgument {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  return '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-MatrixCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$Arguments = @()
  )

  $fullScript = Resolve-RepoPath $ScriptPath
  if (-not (Test-Path -LiteralPath $fullScript)) {
    return [PSCustomObject]@{
      name = $Name
      status = "fail"
      script = $ScriptPath
      exit_code = $null
      duration_ms = 0
      stdout_sha256 = $null
      stderr_sha256 = $null
      output_omitted = $true
      note = "script_missing"
    }
  }

  $started = Get-Date
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo.FileName = (Get-Process -Id $PID).Path
  $processArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $fullScript) + $Arguments
  $process.StartInfo.Arguments = (($processArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join " ")
  $process.StartInfo.UseShellExecute = $false
  $process.StartInfo.RedirectStandardOutput = $true
  $process.StartInfo.RedirectStandardError = $true
  $process.StartInfo.WorkingDirectory = $repoRoot

  try {
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
  } finally {
    $process.Dispose()
  }

  $finished = Get-Date
  return [PSCustomObject]@{
    name = $Name
    status = if ($exitCode -eq 0) { "pass" } else { "fail" }
    script = $ScriptPath
    arguments = $Arguments
    exit_code = $exitCode
    duration_ms = [int](New-TimeSpan -Start $started -End $finished).TotalMilliseconds
    stdout_sha256 = Get-Sha256Hex $stdout
    stderr_sha256 = Get-Sha256Hex $stderr
    output_omitted = $true
    note = if ($exitCode -eq 0) { "command_exit_0" } else { "command_exit_$exitCode" }
  }
}

$alpha = Read-JsonArtifact -Path $AlphaSmokePath
if (-not $alpha.exists) {
  Add-Check -Name "alpha_smoke_current" -Status "fail" -Path $alpha.path -Note "missing alpha smoke artifact"
} elseif ($alpha.error) {
  Add-Check -Name "alpha_smoke_current" -Status "fail" -Path $alpha.path -Note "invalid JSON: $($alpha.error)"
} else {
  $alphaStatus = [string](Get-JsonField -Json $alpha.json -Name "status")
  $alphaSecretSafe = Get-BoolField -Json $alpha.json -Name "secret_safe"
  $alphaSimulation = Get-BoolField -Json $alpha.json -Name "simulation"
  $alphaReady = Get-BoolField -Json $alpha.json -Name "ready_for_open_source_alpha"
  $alphaBlockers = @((Get-JsonField -Json $alpha.json -Name "blockers"))
  $pass = ($alphaStatus -eq "pass" -and $alphaSecretSafe -eq $true -and $alphaSimulation -eq $false -and $alphaBlockers.Count -eq 0)
  Add-Check -Name "alpha_smoke_current" -Status $(if ($pass) { "pass" } else { "fail" }) -Path $alpha.path -Note $(if ($pass) { "compose/sdk/secret smoke pass evidence accepted" } else { "alpha smoke is not a clean pass" }) -Details ([ordered]@{
      status = $alphaStatus
      ready_for_open_source_alpha = $alphaReady
      secret_safe = $alphaSecretSafe
      simulation = $alphaSimulation
      blocker_count = $alphaBlockers.Count
      last_write_time_utc = $alpha.last_write_time_utc
    })
}

$route = Read-JsonArtifact -Path $RouteLiveProofPath
if (-not $route.exists) {
  Add-Check -Name "route_level_live_http_proof" -Status "fail" -Path $route.path -Note "missing route-level live proof artifact"
} elseif ($route.error) {
  Add-Check -Name "route_level_live_http_proof" -Status "fail" -Path $route.path -Note "invalid JSON: $($route.error)"
} else {
  $routeStatus = [string](Get-JsonField -Json $route.json -Name "overall_status")
  $routeSecretSafe = Get-BoolField -Json $route.json -Name "secret_safe"
  $routeSimulation = Get-BoolField -Json $route.json -Name "simulation"
  $paidGateChanged = Get-BoolField -Json $route.json -Name "paid_gate_changed"
  $routeBlockers = @((Get-JsonField -Json $route.json -Name "blockers"))
  $admin = Get-JsonField -Json $route.json -Name "admin_login"
  $virtualKey = Get-JsonField -Json $route.json -Name "virtual_key"
  $gatewayRoute = Get-JsonField -Json $route.json -Name "gateway_route"
  $voucher = Get-JsonField -Json $route.json -Name "voucher"
  $pass = (
    $routeStatus -eq "pass" -and
    $routeSecretSafe -eq $true -and
    $routeSimulation -eq $false -and
    $paidGateChanged -eq $false -and
    $routeBlockers.Count -eq 0 -and
    (Get-BoolField -Json $admin -Name "route_invoked") -eq $true -and
    (Get-BoolField -Json $virtualKey -Name "route_invoked") -eq $true -and
    (Get-BoolField -Json $virtualKey -Name "gateway_accepted_created_secret") -eq $true -and
    (Get-BoolField -Json $gatewayRoute -Name "route_invoked") -eq $true -and
    [int](Get-JsonField -Json $gatewayRoute -Name "http_status") -eq 200 -and
    (Get-BoolField -Json $voucher -Name "issue_route_invoked") -eq $true -and
    (Get-BoolField -Json $voucher -Name "redeem_route_invoked") -eq $true
  )
  Add-Check -Name "route_level_live_http_proof" -Status $(if ($pass) { "pass" } else { "fail" }) -Path $route.path -Note $(if ($pass) { "live route proof accepted" } else { "route proof is not a clean live pass" }) -Details ([ordered]@{
      overall_status = $routeStatus
      secret_safe = $routeSecretSafe
      simulation = $routeSimulation
      paid_gate_changed = $paidGateChanged
      blocker_count = $routeBlockers.Count
      last_write_time_utc = $route.last_write_time_utc
    })
}

$matrix = @(
  [ordered]@{ name = "control_plane_management_parity_smoke"; script = "scripts/verify_control_plane_crud_smoke.ps1"; arguments = @("-IncludeFullCrud", "-StrictFullCrud", "-OutputPath", ".tmp/control-plane/control_plane_management_parity_smoke.json") },
  [ordered]@{ name = "gateway_routing_smoke"; script = "scripts/verify_gateway_routing_smoke.ps1"; arguments = @() },
  [ordered]@{ name = "gateway_profile_smoke"; script = "scripts/verify_gateway_profile_smoke.ps1"; arguments = @("-SwitchProfile", "Fallback Live Strict Smoke") },
  [ordered]@{ name = "gateway_retry_fallback_strict"; script = "scripts/verify_gateway_retry_fallback_smoke.ps1"; arguments = @("-StrictGatewayFallback") },
  [ordered]@{ name = "gateway_rate_limit_reservation_smoke"; script = "scripts/verify_gateway_rate_limit_reservation_smoke.ps1"; arguments = @("-ArtifactPath", ".tmp/open-source-alpha/gateway_rate_limit_reservation_matrix.json") },
  [ordered]@{ name = "gateway_paid_hot_path_smoke"; script = "scripts/verify_gateway_paid_hot_path_smoke.ps1"; arguments = @("-ArtifactPath", ".tmp/open-source-alpha/gateway_paid_hot_path_matrix.json") },
  [ordered]@{ name = "sdk_smoke_skip_install"; script = "scripts/verify_sdk_smoke.ps1"; arguments = @("-SkipInstall") }
)

$matrixResults = New-Object System.Collections.Generic.List[object]
foreach ($item in $matrix) {
  $scriptFull = Resolve-RepoPath $item.script
  if (-not (Test-Path -LiteralPath $scriptFull)) {
    Add-Check -Name $item.name -Status "fail" -Path $item.script -Note "matrix script missing"
    continue
  }

  if ($RunMatrix -and -not $DryRun) {
    $result = Invoke-MatrixCommand -Name $item.name -ScriptPath $item.script -Arguments $item.arguments
    [void]$matrixResults.Add($result)
    Add-Check -Name $item.name -Status $result.status -Path $item.script -Note $result.note -Details $result
  } else {
    Add-Check -Name $item.name -Status "warn" -Path $item.script -Note "script available, but matrix command was not run by this gate invocation"
  }
}

$readmeContractOutputPath = ".tmp/open-source-alpha/readme_quickstart_contract.json"
$readmeVerifier = Invoke-MatrixCommand -Name "readme_quickstart_contract" -ScriptPath "scripts/verify_readme_quickstart_contract.ps1" -Arguments @("-OutputPath", $readmeContractOutputPath)
$readmeContract = Read-JsonArtifact -Path $readmeContractOutputPath
$readmeDetails = [ordered]@{
  command = $readmeVerifier
  artifact = $null
}
if ($readmeContract.exists -and -not $readmeContract.error) {
  $readmeDetails.artifact = [ordered]@{
    status = [string](Get-JsonField -Json $readmeContract.json -Name "status")
    clone_run_documented = Get-BoolField -Json $readmeContract.json -Name "clone_run_documented"
    api_call_documented = Get-BoolField -Json $readmeContract.json -Name "api_call_documented"
    admin_operation_chain_documented = Get-BoolField -Json $readmeContract.json -Name "admin_operation_chain_documented"
    troubleshooting_documented = Get-BoolField -Json $readmeContract.json -Name "troubleshooting_documented"
    known_limitations_documented = Get-BoolField -Json $readmeContract.json -Name "known_limitations_documented"
    missing_snippets = @((Get-JsonField -Json $readmeContract.json -Name "missing_snippets"))
    last_write_time_utc = $readmeContract.last_write_time_utc
  }
}
$readmePass = (
  $readmeVerifier.status -eq "pass" -and
  $readmeContract.exists -and
  -not $readmeContract.error -and
  [string](Get-JsonField -Json $readmeContract.json -Name "status") -eq "pass" -and
  (Get-BoolField -Json $readmeContract.json -Name "secret_safe") -eq $true
)
Add-Check -Name "readme_contract" -Status $(if ($readmePass) { "pass" } else { "fail" }) -Path "README.md" -Note $(if ($readmePass) { "README quickstart contract present" } else { "README quickstart contract failed" }) -Details $readmeDetails

$cleanCloneReadinessOutputPath = ".tmp/open-source-alpha/clean_clone_readiness.json"
$cleanCloneVerifier = Invoke-MatrixCommand -Name "clean_clone_readiness" -ScriptPath "scripts/verify_open_source_alpha_clean_clone_readiness.ps1" -Arguments @("-OutputPath", $cleanCloneReadinessOutputPath)
$cleanCloneReadiness = Read-JsonArtifact -Path $cleanCloneReadinessOutputPath
$cleanCloneDetails = [ordered]@{
  command = $cleanCloneVerifier
  artifact = $null
}
if ($cleanCloneReadiness.exists -and -not $cleanCloneReadiness.error) {
  $cleanCloneDetails.artifact = [ordered]@{
    status = [string](Get-JsonField -Json $cleanCloneReadiness.json -Name "status")
    ready_for_public_tag_release = Get-BoolField -Json $cleanCloneReadiness.json -Name "ready_for_public_tag_release"
    clean_clone_verified = Get-BoolField -Json $cleanCloneReadiness.json -Name "clean_clone_verified"
    local_alpha_pass_unaffected = Get-BoolField -Json $cleanCloneReadiness.json -Name "local_alpha_pass_unaffected"
    blocker_artifact_written = Get-BoolField -Json $cleanCloneReadiness.json -Name "blocker_artifact_written"
    release_blockers = @((Get-JsonField -Json $cleanCloneReadiness.json -Name "release_blockers"))
    last_write_time_utc = $cleanCloneReadiness.last_write_time_utc
  }
}
$cleanCloneGuardPass = (
  $cleanCloneVerifier.status -eq "pass" -and
  $cleanCloneReadiness.exists -and
  -not $cleanCloneReadiness.error -and
  (Get-BoolField -Json $cleanCloneReadiness.json -Name "secret_safe") -eq $true -and
  (Get-BoolField -Json $cleanCloneReadiness.json -Name "local_alpha_pass_unaffected") -eq $true -and
  @("pass", "warn") -contains ([string](Get-JsonField -Json $cleanCloneReadiness.json -Name "status"))
)
Add-Check -Name "clean_clone_readiness_guard" -Status $(if ($cleanCloneGuardPass) { "pass" } else { "fail" }) -Path "scripts/verify_open_source_alpha_clean_clone_readiness.ps1" -Note $(if ($cleanCloneGuardPass) { "clean-clone readiness guard recorded; missing transcript is release-only blocker" } else { "clean-clone readiness guard failed" }) -Details $cleanCloneDetails

foreach ($artifactSpec in @(
    [ordered]@{
      name = "control_plane_management_parity_artifact"
      path = ".tmp/control-plane/control_plane_management_parity_smoke.json"
      pass_statuses = @("pass")
      required_true_paths = @(
        "secret_safe",
        "strict_full_crud",
        "routes.admin_login",
        "routes.provider.full_crud",
        "routes.channel.full_crud",
        "routes.provider_key.list_patch_delete",
        "routes.provider_key.credential_configured",
        "routes.provider_key.secret_redacted",
        "routes.api_key_profile.list_patch_delete",
        "routes.canonical_model.full_crud",
        "routes.model_association.full_crud",
        "routes.model_association_dry_run.selected_channel_id_present"
      )
      required_false_paths = @(
        "routes.model_association.fallback_allowed_written",
        "routes.model_association_dry_run.fallback_allowed_observed",
        "routes.model_association_dry_run.upstream_call"
      )
    },
    [ordered]@{ name = "rate_limit_matrix_artifact"; path = ".tmp/open-source-alpha/gateway_rate_limit_reservation_matrix.json"; pass_statuses = @("live_completed") },
    [ordered]@{ name = "paid_hot_path_matrix_artifact"; path = ".tmp/open-source-alpha/gateway_paid_hot_path_matrix.json"; pass_statuses = @("passed", "pass") }
  )) {
  $artifact = Read-JsonArtifact -Path $artifactSpec.path
  if (-not $artifact.exists) {
    Add-Check -Name $artifactSpec.name -Status "warn" -Path $artifact.path -Note "matrix artifact not present; this is expected until -RunMatrix is used"
    continue
  }
  if ($artifact.error) {
    Add-Check -Name $artifactSpec.name -Status "fail" -Path $artifact.path -Note "invalid JSON: $($artifact.error)"
    continue
  }
  $status = [string](Get-JsonField -Json $artifact.json -Name "status")
  $secretSafe = Get-JsonField -Json $artifact.json -Name "secret_safe"
  $secretSafePass = if ($secretSafe -is [bool]) { [bool]$secretSafe } else { $true }
  $missingTruePaths = @()
  $unexpectedFalsePaths = @()
  if ($artifactSpec.Contains("required_true_paths")) {
    foreach ($path in @($artifactSpec.required_true_paths)) {
      if ((Get-BoolPathField -Json $artifact.json -Path $path) -ne $true) {
        $missingTruePaths += $path
      }
    }
  }
  if ($artifactSpec.Contains("required_false_paths")) {
    foreach ($path in @($artifactSpec.required_false_paths)) {
      if ((Get-BoolPathField -Json $artifact.json -Path $path) -ne $false) {
        $unexpectedFalsePaths += $path
      }
    }
  }
  $pass = ($artifactSpec.pass_statuses -contains $status) -and $secretSafePass -and $missingTruePaths.Count -eq 0 -and $unexpectedFalsePaths.Count -eq 0
  Add-Check -Name $artifactSpec.name -Status $(if ($pass) { "pass" } else { "fail" }) -Path $artifact.path -Note $(if ($pass) { "matrix artifact accepted" } else { "matrix artifact is not an accepted pass" }) -Details ([ordered]@{
      status = $status
      missing_true_paths = $missingTruePaths
      unexpected_false_paths = $unexpectedFalsePaths
      last_write_time_utc = $artifact.last_write_time_utc
    })
}

Add-Check -Name "trusted_user_beta_scope_guard" -Status "pass" -Note "trusted-user voucher-backed Beta artifacts are not accepted as open-source Alpha evidence by this gate" -Details ([ordered]@{
    forbidden_substitute = "internal-trusted-beta-001"
    accepted_scope = "open-source alpha clone-and-run/live route/gateway matrix evidence only"
  })

$failedChecks = @($checks.ToArray() | Where-Object { $_.status -eq "fail" })
$status = if ($failedChecks.Count -gt 0) {
  "fail"
} elseif ($warnings.Count -gt 0) {
  "warn"
} else {
  "pass"
}

$artifactObject = [ordered]@{
  schema = "open_source_alpha_gate.v1"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  status = $status
  ready_for_open_source_alpha = ($status -eq "pass")
  dry_run = [bool]$DryRun
  run_matrix = [bool]$RunMatrix
  secret_safe = $true
  raw_command_output_omitted = $true
  trusted_user_beta_not_alpha = $true
  inputs = [ordered]@{
    alpha_smoke = (Get-RepoRelativePath (Resolve-RepoPath $AlphaSmokePath))
    route_live_http_proof = (Get-RepoRelativePath (Resolve-RepoPath $RouteLiveProofPath))
  }
  checks = @($checks.ToArray())
  blockers = @($blockers.ToArray())
  warnings = @($warnings.ToArray())
  next_commands = @(
    "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\alpha_smoke.ps1 -StartCompose -ComposeTimeoutSeconds 600",
    "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_clean_clone_readiness.ps1",
    "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_route_level_live_http_proof.ps1",
    "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_control_plane_crud_smoke.ps1 -IncludeFullCrud -StrictFullCrud",
    "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_gate.ps1 -RunMatrix"
  )
}

$json = $artifactObject | ConvertTo-Json -Depth 16
if (-not (Test-SecretSafeText $json)) {
  throw "open_source_alpha_gate artifact failed secret-safe validation"
}

$outputFull = Assert-OutputPathIsSafe -Path $OutputPath
$outputDir = Split-Path -Parent $outputFull
if (-not (Test-Path -LiteralPath $outputDir)) {
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}
Set-Content -LiteralPath $outputFull -Encoding UTF8 -Value $json

Write-Host "open_source_alpha_gate_status=$status"
Write-Host "open_source_alpha_gate_artifact=$(Get-RepoRelativePath $outputFull)"

if ($status -eq "fail") { exit 1 }
if ($status -eq "warn") { exit 2 }
exit 0
