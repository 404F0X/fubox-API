param(
  [string]$ReadmePath = "README.md",
  [string]$OutputPath = ".tmp/open-source-alpha/readme_quickstart_contract.json"
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

$readmeFull = Resolve-RepoPath $ReadmePath
$missing = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $readmeFull)) {
  [void]$missing.Add("README.md")
  $readme = ""
} else {
  $readme = Get-Content -LiteralPath $readmeFull -Raw
}

$requiredSnippets = @(
  "## Run Locally",
  "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev_up.ps1",
  "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev_login_check.ps1",
  ".\scripts\dev_up.ps1 -DryRun",
  "admin login",
  "registration",
  "admin-issued test voucher",
  "user voucher redeem",
  "API key creation",
  "mock chat completion",
  "POSTGRES_HOST_PORT",
  "REDIS_HOST_PORT",
  "GATEWAY_HOST_PORT",
  "CONTROL_PLANE_HOST_PORT",
  "ADMIN_UI_HOST_PORT",
  "MOCK_PROVIDER_HOST_PORT",
  "http://127.0.0.1:5173",
  "http://127.0.0.1:8080",
  "http://127.0.0.1:8081",
  "Invoke-RestMethod http://127.0.0.1:8080/readyz",
  "Invoke-RestMethod http://127.0.0.1:8081/readyz",
  "Invoke-WebRequest http://127.0.0.1:5173 -UseBasicParsing",
  "dev_test_key_123456789",
  "/v1/models",
  "/v1/chat/completions",
  "## Current Product Line",
  "Deferred until the gateway/user flow is clean",
  "Payment, order, invoice runtime.",
  "Subscription lifecycle.",
  "Use the full release gates only when preparing a release."
)

foreach ($snippet in $requiredSnippets) {
  if (-not $readme.Contains($snippet)) {
    [void]$missing.Add($snippet)
  }
}

$status = if ($missing.Count -eq 0) { "pass" } else { "fail" }
$artifact = [ordered]@{
  schema = "readme_quickstart_contract.v1"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  status = $status
  readme_path = Get-RepoRelativePath $readmeFull
  clone_run_documented = $readme.Contains("dev_up.ps1") -and $readme.Contains("dev_login_check.ps1")
  api_call_documented = $readme.Contains("/v1/models") -and $readme.Contains("/v1/chat/completions")
  admin_operation_chain_documented = $readme.Contains("admin login") -and $readme.Contains("admin-issued test voucher")
  troubleshooting_documented = $readme.Contains("POSTGRES_HOST_PORT") -and $readme.Contains("GATEWAY_HOST_PORT")
  known_limitations_documented = $readme.Contains("Deferred until the gateway/user flow is clean")
  missing_snippets = @($missing.ToArray())
  secret_safe = $true
}

$outputFull = Assert-OutputPathIsSafe -Path $OutputPath
$outputDir = Split-Path -Parent $outputFull
if (-not (Test-Path -LiteralPath $outputDir)) {
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}
$artifact | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputFull -Encoding UTF8

Write-Host "readme_quickstart_contract_status=$status"
Write-Host "readme_quickstart_contract_artifact=$(Get-RepoRelativePath $outputFull)"

if ($status -ne "pass") {
  exit 1
}
