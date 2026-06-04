param(
  [string]$OpenApiPath = "examples/openapi_admin_skeleton.yaml",
  [string]$TempRoot = ".tmp\ledger-adjustment-openapi-semantic",
  [string]$NpmCache = ".tool-cache\npm",
  [switch]$Semantic,
  [switch]$Redocly,
  [switch]$OpenApiGeneratorValidate,
  [switch]$ClientGeneration,
  [switch]$OpenApiTypescript,
  [switch]$TypescriptFetch,
  [switch]$AllowPackageDownload,
  [switch]$Clean,
  [switch]$SelfTest,
  [switch]$SimulateExternalBlocker,
  [switch]$SimulateSchemaMismatch,
  [switch]$SimulateClientMismatch,
  [switch]$SimulateSensitiveOutputTail,
  [switch]$SimulateSensitiveCommandFailure
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$contractGatePath = Join-Path $PSScriptRoot "verify_control_plane_ledger_adjustment_openapi_contract.ps1"

function Test-TruthyEnv {
  param([AllowNull()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  return @("1", "true", "yes", "on").Contains($Value.Trim().ToLowerInvariant())
}

if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SEMANTIC) { $Semantic = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_REDOCLY) { $Redocly = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_GENERATOR_VALIDATE) { $OpenApiGeneratorValidate = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_CLIENT_GENERATION) { $ClientGeneration = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_TYPESCRIPT) { $OpenApiTypescript = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_TYPESCRIPT_FETCH) { $TypescriptFetch = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_ALLOW_PACKAGE_DOWNLOAD) { $AllowPackageDownload = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_CLEAN) { $Clean = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SELF_TEST) { $SelfTest = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_EXTERNAL_BLOCKER) { $SimulateExternalBlocker = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SCHEMA_MISMATCH) { $SimulateSchemaMismatch = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_CLIENT_MISMATCH) { $SimulateClientMismatch = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SENSITIVE_OUTPUT_TAIL) { $SimulateSensitiveOutputTail = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SENSITIVE_COMMAND_FAILURE) { $SimulateSensitiveCommandFailure = $true }
if (-not [string]::IsNullOrWhiteSpace($env:CONTROL_PLANE_LEDGER_OPENAPI_TEMP_ROOT)) {
  $TempRoot = $env:CONTROL_PLANE_LEDGER_OPENAPI_TEMP_ROOT
}
if (-not [string]::IsNullOrWhiteSpace($env:CONTROL_PLANE_LEDGER_OPENAPI_NPM_CACHE)) {
  $NpmCache = $env:CONTROL_PLANE_LEDGER_OPENAPI_NPM_CACHE
}

if ($Semantic) {
  $Redocly = $true
  $OpenApiGeneratorValidate = $true
}
if ($ClientGeneration) {
  $OpenApiTypescript = $true
  $TypescriptFetch = $true
}

function Resolve-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

$OpenApiPath = Resolve-RepoRelativePath $OpenApiPath
$TempRoot = Resolve-RepoRelativePath $TempRoot
$NpmCache = Resolve-RepoRelativePath $NpmCache

function Test-PathUnderRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  return $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-PathUnderRepo {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  $full = [System.IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label must stay under repository root: $full"
  }
}

$tmpRoot = Join-Path $repoRoot ".tmp"
$toolCacheRoot = Join-Path $repoRoot ".tool-cache"
Assert-PathUnderRepo -Path $OpenApiPath -Label "OpenApiPath"
Assert-PathUnderRepo -Path $TempRoot -Label "TempRoot"
Assert-PathUnderRepo -Path $NpmCache -Label "NpmCache"
if (-not (Test-PathUnderRoot -Path $TempRoot -Root $tmpRoot)) {
  throw "TempRoot must stay under repository .tmp: $TempRoot"
}
if (
  -not (Test-PathUnderRoot -Path $NpmCache -Root $toolCacheRoot) -and
  -not (Test-PathUnderRoot -Path $NpmCache -Root $tmpRoot)
) {
  throw "NpmCache must stay under repository .tool-cache or .tmp: $NpmCache"
}

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Blockers = New-Object System.Collections.Generic.List[string]

function Redact-SafeText {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) {
    return ""
  }

  $redacted = [string]$Text
  $redacted = $redacted -replace '(?i)Authorization\s*[:=]\s*Bearer\s+[^\s,;)}]+', '[REDACTED_HEADER]'
  $redacted = $redacted -replace '(?i)Authorization\s*[:=]\s*[^\r\n,;)}]+', '[REDACTED_HEADER]'
  $redacted = $redacted -replace '(?i)Cookie\s*[:=]\s*[^\r\n]+', '[REDACTED_HEADER]'
  $redacted = $redacted -replace '(?i)Bearer\s+[A-Za-z0-9._~+/\-=]+', '[REDACTED_BEARER]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+/\-=]+', 'sk-[REDACTED]'
  $redacted = $redacted -replace '(?i)(https?://)([^/\s:@]+):([^/\s@]+)@', '$1[REDACTED]@'
  $redacted = $redacted -replace '(?i)(_authToken\s*=\s*)[^\s;]+', '[REDACTED_MATERIAL]'
  $redacted = $redacted -replace '(?i)((?:password|passwd|secret|token|credential|api[_-]?key|operation[_-]?key|package[_-]?token|npm[_-]?token|raw[_-]?metadata|metadata)\s*[:=]\s*)[^\s''",;}]+', '[REDACTED_MATERIAL]'
  return $redacted
}

function Write-SafeHost {
  param([AllowNull()][string]$Text)

  Write-Host (Redact-SafeText $Text)
}

function Add-Failure {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SafeText $Message
  [void]$script:Failures.Add($safe)
  Write-SafeHost $safe
}

function Add-Blocker {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SafeText $Message
  [void]$script:Blockers.Add($safe)
  Write-SafeHost $safe
}

function Exit-WithResult {
  if ($script:Failures.Count -gt 0) {
    Write-SafeHost ""
    Write-SafeHost "Control Plane ledger adjustment OpenAPI semantic validation failed:"
    foreach ($failure in $script:Failures) {
      Write-SafeHost $failure
    }
    exit 1
  }

  if ($script:Blockers.Count -gt 0) {
    Write-SafeHost ""
    Write-SafeHost "Control Plane ledger adjustment OpenAPI semantic validation is externally blocked:"
    foreach ($blocker in $script:Blockers) {
      Write-SafeHost $blocker
    }
    exit 2
  }

  Write-SafeHost "Control Plane ledger adjustment OpenAPI semantic validation passed."
  exit 0
}

function Test-ToolAvailable {
  param([Parameter(Mandatory = $true)][string]$Name)

  return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Assert-ToolAvailable {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Reason
  )

  if (-not (Test-ToolAvailable $Name)) {
    throw "$Name not found; $Reason"
  }
}

function Format-CommandLine {
  param(
    [Parameter(Mandatory = $true)][string]$FileName,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $parts = New-Object System.Collections.Generic.List[string]
  [void]$parts.Add($FileName)
  foreach ($argument in $Arguments) {
    $text = [string]$argument
    if ($text -match "\s") {
      $text = '"' + $text.Replace('"', '\"') + '"'
    }
    [void]$parts.Add($text)
  }
  return Redact-SafeText ($parts.ToArray() -join " ")
}

function Test-BlockerOutput {
  param([Parameter(Mandatory = $true)][string]$Text)

  foreach ($pattern in @(
      "ENOTCACHED",
      "EAI_AGAIN",
      "ECONNRESET",
      "ECONNREFUSED",
      "ENETUNREACH",
      "ETIMEDOUT",
      "ENOTFOUND",
      "network",
      "offline",
      "only-if-cached",
      "not in cache",
      "No cached",
      "could not determine executable",
      "unable to get local issuer certificate",
      "self signed certificate",
      "could not resolve",
      "Connection refused"
    )) {
    if ($Text -match [regex]::Escape($pattern)) {
      return $true
    }
  }

  return $false
}

function Invoke-Process {
  param(
    [Parameter(Mandatory = $true)][string]$FileName,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$Label,
    [switch]$ExternalTool
  )

  $global:LASTEXITCODE = 0
  $oldErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& $FileName @Arguments 2>&1 | ForEach-Object { [string]$_ })
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
  $commandLine = Format-CommandLine -FileName $FileName -Arguments $Arguments

  if ($exitCode -eq 0) {
    Write-SafeHost "[OK] $Label"
    foreach ($line in $output | Select-Object -Last 8) {
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        Write-SafeHost $line
      }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Command = $commandLine }
  }

  $joined = Redact-SafeText ($output -join "`n")
  if ($ExternalTool -and (Test-BlockerOutput $joined)) {
    Add-Blocker "[BLOCKED] $Label - external tool/package cache unavailable while running: $commandLine"
  } else {
    Add-Failure "[FAIL] $Label - exit $exitCode while running: $commandLine`n$joined"
  }
  return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Command = $commandLine }
}

function Invoke-ContractGate {
  $ps = Get-PowerShellRunner
  if ($null -eq $ps) {
    Add-Blocker "[BLOCKED] lightweight OpenAPI contract gate - powershell/pwsh not found"
    return
  }

  [void](Invoke-Process `
      -FileName $ps.Source `
      -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $contractGatePath, "-OpenApiPath", $OpenApiPath) `
      -Label "lightweight ledger execute OpenAPI contract gate")
}

function Get-PowerShellRunner {
  $ps = Get-Command powershell -ErrorAction SilentlyContinue
  if ($null -eq $ps) {
    $ps = Get-Command pwsh -ErrorAction SilentlyContinue
  }
  return $ps
}

function New-NpmExecArguments {
  param(
    [Parameter(Mandatory = $true)][string]$Package,
    [Parameter(Mandatory = $true)][string[]]$ToolArguments
  )

  $arguments = @("exec", "--yes")
  if (-not $AllowPackageDownload) {
    $arguments += "--offline"
  }
  $arguments += @("--package", $Package, "--")
  $arguments += $ToolArguments
  return $arguments
}

function Invoke-NpmTool {
  param(
    [Parameter(Mandatory = $true)][string]$Package,
    [Parameter(Mandatory = $true)][string[]]$ToolArguments,
    [Parameter(Mandatory = $true)][string]$Label,
    [switch]$RequireJava
  )

  try {
    Assert-ToolAvailable -Name "node" -Reason "Node is required for npm OpenAPI tools"
    Assert-ToolAvailable -Name "npm" -Reason "npm is required for npm OpenAPI tools"
    if ($RequireJava) {
      Assert-ToolAvailable -Name "java" -Reason "Java is required by @openapitools/openapi-generator-cli"
    }
  } catch {
    Add-Blocker "[BLOCKED] $Label - $($_.Exception.Message)"
    return
  }

  New-Item -ItemType Directory -Force $NpmCache | Out-Null
  $oldCache = $env:npm_config_cache
  try {
    $env:npm_config_cache = $NpmCache
    [void](Invoke-Process `
        -FileName "npm" `
        -Arguments (New-NpmExecArguments -Package $Package -ToolArguments $ToolArguments) `
        -Label $Label `
        -ExternalTool)
  } finally {
    $env:npm_config_cache = $oldCache
  }
}

function Assert-FileContains {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Needles,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path $Path)) {
    Add-Failure "[FAIL] $Label - missing generated file $Path"
    return
  }

  $text = Get-Content -Path $Path -Raw
  foreach ($needle in $Needles) {
    if (-not $text.Contains($needle)) {
      Add-Failure "[FAIL] $Label - generated output is missing '$needle'"
    }
  }
}

function Assert-TreeContainsAny {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Needles,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path $Path)) {
    Add-Failure "[FAIL] $Label - missing generated directory $Path"
    return
  }

  $files = @(Get-ChildItem -Path $Path -Recurse -File -Include *.ts,*.tsx,*.js,*.json,*.md 2>$null)
  $text = ($files | ForEach-Object { Get-Content -Path $_.FullName -Raw }) -join "`n"
  foreach ($needle in $Needles) {
    if (-not $text.Contains($needle)) {
      Add-Failure "[FAIL] $Label - generated tree is missing '$needle'"
    }
  }
}

function Assert-TreeContainsOneOf {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Needles,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path $Path)) {
    Add-Failure "[FAIL] $Label - missing generated directory $Path"
    return
  }

  $files = @(Get-ChildItem -Path $Path -Recurse -File -Include *.ts,*.tsx,*.js,*.json,*.md 2>$null)
  $text = ($files | ForEach-Object { Get-Content -Path $_.FullName -Raw }) -join "`n"
  foreach ($needle in $Needles) {
    if ($text.Contains($needle)) {
      return
    }
  }
  Add-Failure "[FAIL] $Label - generated tree is missing one of: $($Needles -join ", ")"
}

function Invoke-Redocly {
  Invoke-NpmTool `
    -Package "@redocly/cli" `
    -ToolArguments @("redocly", "lint", $OpenApiPath) `
    -Label "Redocly semantic OpenAPI validation"
}

function Invoke-OpenApiGeneratorValidate {
  Invoke-NpmTool `
    -Package "@openapitools/openapi-generator-cli" `
    -ToolArguments @("openapi-generator-cli", "validate", "-i", $OpenApiPath) `
    -Label "OpenAPI Generator semantic validation" `
    -RequireJava
}

function Invoke-OpenApiTypescript {
  $outDir = Join-Path $TempRoot "openapi-typescript"
  $outFile = Join-Path $outDir "admin-api.d.ts"
  New-Item -ItemType Directory -Force $outDir | Out-Null
  Remove-Item -Force $outFile -ErrorAction SilentlyContinue

  Invoke-NpmTool `
    -Package "openapi-typescript" `
    -ToolArguments @("openapi-typescript", $OpenApiPath, "-o", $outFile) `
    -Label "openapi-typescript client type generation"

  if ($script:Blockers.Count -eq 0) {
    Assert-FileContains -Path $outFile -Label "openapi-typescript ledger execute contract" -Needles @(
      "LedgerAdjustmentExecuteResult",
      "LedgerAdjustmentExecuteContractEnvelope",
      "LedgerAdjustmentExecuteContract",
      "LedgerAdjustmentExecutorSummaryContract",
      "LedgerAdjustmentExecutorRefusalSummaryContract",
      "LedgerAdjustmentExecutorRollbackSummaryContract",
      "LedgerAdjustmentExecutorSummary",
      "ledger_executor_summary_contract",
      "ledger_executor_summary",
      "operation_key_output",
      "error_detail_output",
      "dedupe_material_echoed",
      "raw_metadata_echoed",
      "credential_material_echoed",
      "raw_executor_error_detail_echoed",
      "row_count_mismatch"
    )
  }
}

function Invoke-TypescriptFetch {
  $outDir = Join-Path $TempRoot "typescript-fetch"
  Remove-Item -Recurse -Force $outDir -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $outDir | Out-Null

  Invoke-NpmTool `
    -Package "@openapitools/openapi-generator-cli" `
    -ToolArguments @(
      "openapi-generator-cli",
      "generate",
      "-i",
      $OpenApiPath,
      "-g",
      "typescript-fetch",
      "-o",
      $outDir,
      "--additional-properties=typescriptThreePlus=true,enumUnknownDefaultCase=true"
    ) `
    -Label "OpenAPI Generator typescript-fetch client generation" `
    -RequireJava

  if ($script:Blockers.Count -eq 0) {
    Assert-TreeContainsAny -Path $outDir -Label "typescript-fetch ledger execute models" -Needles @(
      "LedgerAdjustmentExecuteResult",
      "LedgerAdjustmentExecuteContractEnvelope",
      "LedgerAdjustmentExecuteContract",
      "LedgerAdjustmentExecutorSummaryContract",
      "LedgerAdjustmentExecutorRefusalSummaryContract",
      "LedgerAdjustmentExecutorRollbackSummaryContract",
      "LedgerAdjustmentExecutorSummary"
    )
    foreach ($property in @(
        @("ledgerExecutorSummaryContract", "ledger_executor_summary_contract"),
        @("ledgerExecutorSummary", "ledger_executor_summary"),
        @("operationKeyOutput", "operation_key_output"),
        @("errorDetailOutput", "error_detail_output"),
        @("dedupeMaterialEchoed", "dedupe_material_echoed"),
        @("rawMetadataEchoed", "raw_metadata_echoed"),
        @("credentialMaterialEchoed", "credential_material_echoed"),
        @("rawExecutorErrorDetailEchoed", "raw_executor_error_detail_echoed"),
        @("rowCountMismatch", "row_count_mismatch")
      )) {
      Assert-TreeContainsOneOf -Path $outDir -Label "typescript-fetch generated property contract" -Needles $property
    }
  }
}

function Assert-SelfTestOutputSecretSafe {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowEmptyString()][AllowEmptyCollection()][string[]]$Output = @()
  )

  $text = $Output -join "`n"
  foreach ($pattern in @(
      "(?i)Authorization\s*[:=]",
      "(?i)Cookie\s*[:=]",
      "(?i)Bearer\s+[A-Za-z0-9._~+/\-]+=*",
      "sk-[A-Za-z0-9._~+/\-]{8,}",
      "(?i)(password|passwd|secret|token|credential|api[_-]?key|operation[_-]?key|package[_-]?token|npm[_-]?token|raw[_-]?metadata|metadata)\s*[:=]\s*[^,\s]+",
      "(?i)https?://[^/\s:@]+:[^/\s@]+@"
    )) {
    if ($text -match $pattern) {
      Add-Failure "[FAIL] self-test output secret-safe check - $Name printed forbidden material pattern"
      return
    }
  }
}

function Invoke-SelfTestChild {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string[]]$Arguments = @(),
    [string]$ChildTempRoot = $TempRoot,
    [string]$ChildNpmCache = $NpmCache,
    [Parameter(Mandatory = $true)][int]$ExpectedExitCode
  )

  $ps = Get-PowerShellRunner
  if ($null -eq $ps) {
    Add-Blocker "[BLOCKED] self-test child runner - powershell/pwsh not found"
    return
  }

  $childArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $PSCommandPath,
    "-OpenApiPath",
    $OpenApiPath,
    "-TempRoot",
    $ChildTempRoot,
    "-NpmCache",
    $ChildNpmCache
  ) + $Arguments

  $global:LASTEXITCODE = 0
  $oldErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& $ps.Source @childArgs 2>&1 | ForEach-Object { [string]$_ })
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
  Assert-SelfTestOutputSecretSafe -Name $Name -Output $output

  if ($exitCode -ne $ExpectedExitCode) {
    Add-Failure "[FAIL] self-test $Name - expected exit $ExpectedExitCode, got exit $exitCode"
    foreach ($line in $output | Select-Object -Last 12) {
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        Write-SafeHost $line
      }
    }
    return
  }

  Write-SafeHost "[OK] self-test $Name returned exit $ExpectedExitCode"
}

function Invoke-SelfTest {
  Write-SafeHost "Control Plane ledger adjustment OpenAPI semantic wrapper self-test"
  Write-SafeHost "Self-test uses only the lightweight gate and simulated outcomes; it does not run npm tools, generate clients, or call live services."

  Invoke-SelfTestChild -Name "default lightweight path" -Arguments @() -ExpectedExitCode 0
  Invoke-SelfTestChild -Name "simulated external blocker" -Arguments @("-SimulateExternalBlocker") -ExpectedExitCode 2
  Invoke-SelfTestChild -Name "simulated schema mismatch" -Arguments @("-SimulateSchemaMismatch") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "simulated client mismatch" -Arguments @("-SimulateClientMismatch") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "sensitive success output tail redacted" -Arguments @("-SimulateSensitiveOutputTail") -ExpectedExitCode 0
  Invoke-SelfTestChild -Name "sensitive failing command display redacted" -Arguments @("-SimulateSensitiveCommandFailure") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "temp root repo escape rejected" -Arguments @() -ChildTempRoot (Join-Path $repoRoot "..\ledger-openapi-outside") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "npm cache repo escape rejected" -Arguments @() -ChildNpmCache (Join-Path $repoRoot "..\ledger-openapi-cache-outside") -ExpectedExitCode 1

  $cleanupProbe = Join-Path $TempRoot "self-test-cleanup-marker.txt"
  New-Item -ItemType Directory -Force $TempRoot | Out-Null
  Set-Content -Path $cleanupProbe -Value "cleanup marker" -Encoding ascii
  Invoke-SelfTestChild -Name "artifact cleanup removes temp root" -Arguments @("-Clean") -ExpectedExitCode 0
  if (Test-Path $cleanupProbe) {
    Add-Failure "[FAIL] self-test artifact cleanup - temp marker remained after -Clean"
  } else {
    Write-SafeHost "[OK] self-test artifact cleanup removed temp marker"
  }

  Exit-WithResult
}

if ($Clean) {
  Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue
  Write-SafeHost "[OK] cleaned temp artifacts: $TempRoot"
}

if (-not (Test-Path $OpenApiPath)) {
  Add-Failure "[FAIL] OpenAPI skeleton missing: $OpenApiPath"
  Exit-WithResult
}

if ($SelfTest) {
  Invoke-SelfTest
}

Write-SafeHost "Control Plane ledger adjustment OpenAPI semantic wrapper"
Write-SafeHost "OpenAPI: $OpenApiPath"
Write-SafeHost "TempRoot: $TempRoot"
Write-SafeHost "NpmCache: $NpmCache"
Write-SafeHost "Package download allowed: $([bool]$AllowPackageDownload)"

Invoke-ContractGate
if ($script:Failures.Count -gt 0 -or $script:Blockers.Count -gt 0) {
  Exit-WithResult
}

if ($SimulateExternalBlocker) {
  Add-Blocker "[BLOCKED] simulated external semantic-tool blocker - package cache or local tool unavailable"
  Exit-WithResult
}
if ($SimulateSchemaMismatch) {
  Add-Failure "[FAIL] simulated OpenAPI schema mismatch - ledger execute response contract drift"
  Exit-WithResult
}
if ($SimulateClientMismatch) {
  Add-Failure "[FAIL] simulated generated-client contract mismatch - ledger executor summary field drift"
  Exit-WithResult
}
if ($SimulateSensitiveOutputTail) {
  $ps = Get-PowerShellRunner
  [void](Invoke-Process `
      -FileName $ps.Source `
      -Arguments @(
        "-NoProfile",
        "-Command",
        "Write-Output 'Authorization: Bearer selftest-token-123456789'; Write-Output 'Cookie: session=selftest-cookie'; Write-Output 'api_key=selftest-api-key'; Write-Output 'operation_key=selftest-operation-key'; Write-Output 'raw_metadata={never-return}'"
      ) `
      -Label "simulated sensitive output tail")
  Exit-WithResult
}
if ($SimulateSensitiveCommandFailure) {
  $ps = Get-PowerShellRunner
  [void](Invoke-Process `
      -FileName $ps.Source `
      -Arguments @(
        "-NoProfile",
        "-Command",
        "Write-Error 'Authorization: Bearer selftest-token-123456789 package_token=selftest-package-token raw_metadata={never-return}'; exit 9"
      ) `
      -Label "simulated sensitive command failure")
  Exit-WithResult
}

if (-not ($Redocly -or $OpenApiGeneratorValidate -or $OpenApiTypescript -or $TypescriptFetch)) {
  Write-SafeHost "[OK] semantic/client generation tools were not requested; default mode performed lightweight gate only."
  Exit-WithResult
}

if ($Redocly) {
  Invoke-Redocly
}
if ($OpenApiGeneratorValidate) {
  Invoke-OpenApiGeneratorValidate
}
if ($OpenApiTypescript) {
  Invoke-OpenApiTypescript
}
if ($TypescriptFetch) {
  Invoke-TypescriptFetch
}

Exit-WithResult
