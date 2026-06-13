param(
  [string]$ReadmePath = "README.md",
  [string]$DockerignorePath = ".dockerignore",
  [string]$CiWorkflowPath = ".github/workflows/ci.yml",
  [string]$CleanCloneEvidencePath = ".tmp/open-source-alpha/clean_clone_ci_transcript.json",
  [string]$OutputPath = ".tmp/open-source-alpha/clean_clone_readiness.json"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$checks = New-Object System.Collections.Generic.List[object]
$releaseBlockers = New-Object System.Collections.Generic.List[string]

$transcriptTemplatePath = "docs/OPEN_SOURCE_ALPHA_CLEAN_CLONE_TRANSCRIPT_TEMPLATE.md"
$exactTranscriptCommands = @(
  [ordered]@{
    phase = "clean_clone_or_hosted_ci_checkout"
    command = "git clone <repo-url> fubox_API-clean-alpha && cd fubox_API-clean-alpha"
    required_for_public_tag = $true
    note = "Run this outside the current dirty workspace, or use an equivalent hosted CI checkout."
  },
  [ordered]@{
    phase = "readme_contract"
    command = "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_readme_quickstart_contract.ps1"
    required_for_public_tag = $true
    note = "Verifies the public quickstart surface and known limitations."
  },
  [ordered]@{
    phase = "first_run_compose_smoke"
    command = "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\alpha_smoke.ps1 -StartCompose -ComposeTimeoutSeconds 600"
    required_for_public_tag = $true
    note = "This is the expensive Docker build/run step; do not run from this readiness guard."
  },
  [ordered]@{
    phase = "route_level_live_http_proof"
    command = "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_route_level_live_http_proof.ps1"
    required_for_public_tag = $true
    note = "Proves operator-mediated key/voucher/Gateway routes through live HTTP without writing raw secrets to artifacts."
  },
  [ordered]@{
    phase = "open_source_alpha_matrix_gate"
    command = "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_gate.ps1 -RunMatrix"
    required_for_public_tag = $true
    note = "Runs the serial Control Plane/Gateway/SDK matrix against the same environment."
  },
  [ordered]@{
    phase = "readiness_recheck_with_transcript"
    command = "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_clean_clone_readiness.ps1 -CleanCloneEvidencePath .tmp\open-source-alpha\clean_clone_ci_transcript.json"
    required_for_public_tag = $true
    note = "Accepts only a secret-safe transcript artifact with status=pass, clean_clone=true, ci_or_clean_environment=true."
  }
)

$acceptedTranscriptContract = [ordered]@{
  artifact_path = ".tmp/open-source-alpha/clean_clone_ci_transcript.json"
  required_fields = @("status=pass", "clean_clone=true", "ci_or_clean_environment=true", "secret_safe=true")
  recommended_fields = @("repo_url_redacted", "commit_sha", "environment", "commands", "artifacts", "exit_codes", "started_at_utc", "finished_at_utc")
  template_path = $transcriptTemplatePath
  warning = "Do not include raw Authorization headers, admin session tokens, virtual-key secrets, voucher codes, database URLs, or passwords."
}

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

function Add-Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Status,
    [string]$Path = $null,
    [string]$Note = $null,
    [object]$Details = $null
  )

  [void]$checks.Add([PSCustomObject][ordered]@{
      name = $Name
      status = $Status
      path = $Path
      note = $Note
      details = $Details
    })
}

function Read-JsonArtifact {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $full)) {
    return [PSCustomObject]@{ exists = $false; json = $null; error = "missing"; path = Get-RepoRelativePath $full; last_write_time_utc = $null }
  }
  try {
    $item = Get-Item -LiteralPath $full
    return [PSCustomObject]@{
      exists = $true
      json = (Get-Content -LiteralPath $full -Raw | ConvertFrom-Json)
      error = $null
      path = Get-RepoRelativePath $full
      last_write_time_utc = $item.LastWriteTimeUtc.ToString("o")
    }
  } catch {
    return [PSCustomObject]@{ exists = $true; json = $null; error = $_.Exception.Message; path = Get-RepoRelativePath $full; last_write_time_utc = $null }
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

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $true }
  foreach ($pattern in @(
      '(?i)authorization\s*[:=]\s*bearer\s+[^"\s,}]+',
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

$readmeFull = Resolve-RepoPath $ReadmePath
$readme = if (Test-Path -LiteralPath $readmeFull) { Get-Content -LiteralPath $readmeFull -Raw } else { "" }
$requiredReadmeSnippets = @(
  "## 5. Open-source Alpha Quickstart",
  "git clone <repo-url> fubox_API",
  "alpha_smoke.ps1 -StartCompose",
  "verify_open_source_alpha_gate.ps1 -RunMatrix",
  "verify_open_source_alpha_clean_clone_readiness.ps1",
  "clean-clone/CI transcript",
  "exact transcript commands",
  "Known limitations for this Alpha:",
  "trusted-user voucher-backed Beta",
  "not a full commercial/New API replacement claim",
  "public tag readiness still needs clean-clone or CI rerun"
)
$missingReadme = @($requiredReadmeSnippets | Where-Object { -not $readme.Contains($_) })
Add-Check -Name "readme_clean_clone_release_guard" -Status $(if ($missingReadme.Count -eq 0) { "pass" } else { "fail" }) -Path (Get-RepoRelativePath $readmeFull) -Note $(if ($missingReadme.Count -eq 0) { "README documents clean-clone/CI caveat and verifier" } else { "README is missing clean-clone release guard snippets" }) -Details ([ordered]@{ missing_snippets = $missingReadme })

$dockerignoreFull = Resolve-RepoPath $DockerignorePath
$dockerignore = if (Test-Path -LiteralPath $dockerignoreFull) { Get-Content -LiteralPath $dockerignoreFull -Raw } else { "" }
$dockerignoreLines = @($dockerignore -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and -not $_.StartsWith("#") })
$requiredDockerignoreEntries = @(
  "target/",
  "target-codex*/",
  "node_modules/",
  "web/admin-ui/node_modules/",
  "web/admin-ui/dist/",
  ".tmp/",
  "artifacts/",
  ".git/",
  "*.zip",
  "*.docx"
)
$forbiddenDockerignoreEntries = @(
  "apps/",
  "crates/",
  "db/",
  "deploy/",
  "scripts/",
  "web/",
  "Cargo.toml",
  "Cargo.lock",
  "README.md"
)
$missingDockerignore = @($requiredDockerignoreEntries | Where-Object { $dockerignoreLines -notcontains $_ })
$forbiddenDockerignore = @($forbiddenDockerignoreEntries | Where-Object { $dockerignoreLines -contains $_ })
$dockerignorePass = (Test-Path -LiteralPath $dockerignoreFull) -and $missingDockerignore.Count -eq 0 -and $forbiddenDockerignore.Count -eq 0
Add-Check -Name "dockerignore_context_guard" -Status $(if ($dockerignorePass) { "pass" } else { "fail" }) -Path (Get-RepoRelativePath $dockerignoreFull) -Note $(if ($dockerignorePass) { "Docker context excludes local-heavy output without excluding source inputs" } else { ".dockerignore context guard failed" }) -Details ([ordered]@{
    missing_required_entries = $missingDockerignore
    forbidden_source_exclusions = $forbiddenDockerignore
  })

$ciFull = Resolve-RepoPath $CiWorkflowPath
$ci = if (Test-Path -LiteralPath $ciFull) { Get-Content -LiteralPath $ciFull -Raw } else { "" }
$requiredCiSnippets = @(
  "actions/checkout",
  "cargo fmt",
  "cargo check --workspace --all-targets --all-features",
  "cargo test --workspace --all-targets --all-features",
  "npm --prefix web/admin-ui ci",
  "npm --prefix web/admin-ui run build",
  "scan_secrets.ps1",
  "scan_supply_chain.ps1 -SkipNetwork",
  "make docker-build"
)
$missingCi = @($requiredCiSnippets | Where-Object { -not $ci.Contains($_) })
Add-Check -Name "ci_workflow_public_clone_guard" -Status $(if ((Test-Path -LiteralPath $ciFull) -and $missingCi.Count -eq 0) { "pass" } else { "fail" }) -Path (Get-RepoRelativePath $ciFull) -Note $(if ($missingCi.Count -eq 0) { "CI workflow contains public checkout/build/test/security surface" } else { "CI workflow is missing required public clone checks" }) -Details ([ordered]@{ missing_snippets = $missingCi })

$evidence = Read-JsonArtifact -Path $CleanCloneEvidencePath
$cleanCloneVerified = $false
$evidenceStatus = "missing"
if ($evidence.exists -and -not $evidence.error) {
  $evidenceStatus = [string](Get-JsonField -Json $evidence.json -Name "status")
  $cleanCloneVerified = (
    $evidenceStatus -eq "pass" -and
    (Get-BoolField -Json $evidence.json -Name "clean_clone") -eq $true -and
    (Get-BoolField -Json $evidence.json -Name "ci_or_clean_environment") -eq $true -and
    (Get-BoolField -Json $evidence.json -Name "secret_safe") -eq $true
  )
} elseif ($evidence.error -ne "missing") {
  $evidenceStatus = "invalid"
}

if (-not $cleanCloneVerified) {
  [void]$releaseBlockers.Add("clean_clone_ci_transcript_missing_or_unverified: run the documented clean clone or hosted CI replay before public tag/release; this does not block local code-first Alpha pass")
}

Add-Check -Name "clean_clone_ci_transcript" -Status $(if ($cleanCloneVerified) { "pass" } else { "warn" }) -Path $evidence.path -Note $(if ($cleanCloneVerified) { "clean-clone/CI transcript accepted" } else { "clean-clone/CI transcript not present or not accepted; release blocker recorded" }) -Details ([ordered]@{
    evidence_status = $evidenceStatus
    last_write_time_utc = $evidence.last_write_time_utc
    required_fields = @("status=pass", "clean_clone=true", "ci_or_clean_environment=true", "secret_safe=true")
    accepted_transcript_contract = $acceptedTranscriptContract
  })

$failedChecks = @($checks.ToArray() | Where-Object { $_.status -eq "fail" })
$status = if ($failedChecks.Count -gt 0) { "fail" } elseif ($releaseBlockers.Count -gt 0) { "warn" } else { "pass" }

$artifact = [ordered]@{
  schema = "open_source_alpha_clean_clone_readiness.v1"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  status = $status
  local_alpha_pass_unaffected = $true
  local_alpha_scope = "The current local code-first Alpha/API distribution pass is unaffected by a missing clean-clone/CI transcript."
  ready_for_public_tag_release = ($status -eq "pass")
  clean_clone_verified = $cleanCloneVerified
  clean_clone_or_ci_required_before_public_release = (-not $cleanCloneVerified)
  blocker_artifact_written = ($releaseBlockers.Count -gt 0)
  public_tag_blockers = @($releaseBlockers.ToArray())
  secret_safe = $true
  network_used = $false
  clone_performed = $false
  checks = @($checks.ToArray())
  release_blockers = @($releaseBlockers.ToArray())
  exact_transcript_commands = $exactTranscriptCommands
  accepted_transcript_contract = $acceptedTranscriptContract
  transcript_template_path = $transcriptTemplatePath
  next_commands = @(
    "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_clean_clone_readiness.ps1",
    "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\alpha_smoke.ps1 -StartCompose -ComposeTimeoutSeconds 600",
    "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_gate.ps1 -RunMatrix"
  )
}

$json = $artifact | ConvertTo-Json -Depth 12
if (-not (Test-SecretSafeText $json)) {
  throw "clean_clone_readiness artifact failed secret-safe validation"
}

$outputFull = Assert-OutputPathIsSafe -Path $OutputPath
$outputDir = Split-Path -Parent $outputFull
if (-not (Test-Path -LiteralPath $outputDir)) {
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}
Set-Content -LiteralPath $outputFull -Encoding UTF8 -Value $json

Write-Host "clean_clone_readiness_status=$status"
Write-Host "clean_clone_readiness_artifact=$(Get-RepoRelativePath $outputFull)"

if ($status -eq "fail") { exit 1 }
exit 0
