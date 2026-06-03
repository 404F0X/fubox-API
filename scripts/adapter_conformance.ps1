#requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Strict
)

$ErrorActionPreference = "Stop"

$Adapters = @("openai", "anthropic", "gemini", "mcp")
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$FixtureRoot = (Resolve-Path -LiteralPath (Join-Path $RepoRoot "tests\fixtures\adapters")).Path
$Failures = [System.Collections.Generic.List[string]]::new()
$SeenNames = @{}
$AdapterCounts = @{}
$TotalJson = 0
$TotalSse = 0
$FocusedCargoArgs = @("test", "-p", "ai-gateway-adapters", "adapter_fixture_conformance_harness_covers_fixture_set", "--all-targets")
$StrictCargoArgs = @("test", "-p", "ai-gateway-adapters", "--all-targets")

if ($env:ADAPTER_CONFORMANCE_DRY_RUN -eq "1") { $DryRun = $true }
if ($env:ADAPTER_CONFORMANCE_STRICT -eq "1") { $Strict = $true }

function Add-Failure {
  param([Parameter(Mandatory = $true)][string]$Message)
  [void]$script:Failures.Add($Message)
}

function Test-FailureContains {
  param([Parameter(Mandatory = $true)][string]$Needle)

  foreach ($failure in $script:Failures) {
    if ($failure.Contains($Needle)) {
      return $true
    }
  }
  return $false
}

function Format-Command {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  return "$Command $($Arguments -join ' ')"
}

function Invoke-CargoConformanceTest {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $commandLine = Format-Command -Command "cargo" -Arguments $Arguments
  if ($DryRun) {
    Write-Host "[DRY-RUN] Would run: $commandLine"
    return
  }

  $cargo = Get-Command cargo -ErrorAction SilentlyContinue
  if ($null -eq $cargo) {
    Add-Failure "${Name}: cargo was not found on PATH"
    return
  }

  Write-Host "Adapter conformance: running $Name"
  Push-Location $script:RepoRoot
  try {
    & $cargo.Source @Arguments
    $exitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }

  if ($exitCode -ne 0) {
    Add-Failure "${Name}: failed with exit code $exitCode ($commandLine)"
  }
}

function Get-RelativeFixturePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $root = $script:FixtureRoot.TrimEnd("\") + "\"
  if ($Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $Path.Substring($root.Length).Replace("\", "/")
  }
  return $Path.Replace("\", "/")
}

function Has-Field {
  param(
    [Parameter(Mandatory = $true)][object]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )

  return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-Field {
  param(
    [Parameter(Mandatory = $true)][object]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Test-JsonObject {
  param([object]$Value)
  return $null -ne $Value -and $Value -is [pscustomobject]
}

function Test-StringField {
  param(
    [Parameter(Mandatory = $true)][object]$Object,
    [Parameter(Mandatory = $true)][string]$Field
  )

  $value = Get-Field -Object $Object -Name $Field
  return $value -is [string] -and $value.Trim().Length -gt 0
}

function Test-BoolField {
  param(
    [Parameter(Mandatory = $true)][object]$Object,
    [Parameter(Mandatory = $true)][string]$Field
  )

  return (Get-Field -Object $Object -Name $Field) -is [bool]
}

function Test-U16Field {
  param(
    [Parameter(Mandatory = $true)][object]$Object,
    [Parameter(Mandatory = $true)][string]$Field
  )

  $value = Get-Field -Object $Object -Name $Field
  $isInteger = $value -is [int] -or $value -is [long]
  return $isInteger -and $value -ge 0 -and $value -le 65535
}

function Test-Base64UrlSegment {
  param([Parameter(Mandatory = $true)][string]$Value)
  return $Value -match '^[A-Za-z0-9_-]+$'
}

function Test-JwtLike {
  param([Parameter(Mandatory = $true)][string]$Token)

  $parts = $Token.Split(".")
  if ($parts.Count -ne 3) { return $false }
  foreach ($part in $parts) {
    if ($part.Length -lt 10 -or -not (Test-Base64UrlSegment -Value $part)) {
      return $false
    }
  }
  return $true
}

function Get-SecretLikeReason {
  param([Parameter(Mandatory = $true)][string]$Token)

  if ($Token.StartsWith("sk-", [System.StringComparison]::Ordinal) -and $Token.Length -ge 12) {
    return "provider key prefix"
  }
  if ($Token.StartsWith("AIza", [System.StringComparison]::Ordinal) -and $Token.Length -ge 20) {
    return "google api key prefix"
  }
  foreach ($prefix in @("ghp_", "gho_", "ghu_", "ghs_", "ghr_")) {
    if ($Token.StartsWith($prefix, [System.StringComparison]::Ordinal) -and $Token.Length -ge 20) {
      return "github token prefix"
    }
  }
  foreach ($prefix in @("xoxb-", "xoxa-", "xoxp-", "xoxr-", "xoxs-")) {
    if ($Token.StartsWith($prefix, [System.StringComparison]::Ordinal) -and $Token.Length -ge 20) {
      return "slack token prefix"
    }
  }
  if (Test-JwtLike -Token $Token) {
    return "jwt"
  }

  return $null
}

function Assert-NoSecretLikeText {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ($Text -match '-----BEGIN[\s\S]*PRIVATE KEY') {
    Add-Failure "${Label}: contains private key marker"
  }
  if ($Text -match 'Bearer\s+[A-Za-z0-9._~+/=-]{16,}') {
    Add-Failure "${Label}: contains secret-like value (bearer token)"
  }

  foreach ($token in ($Text -split '[\s"'',:;{}\[\]\(\)]+')) {
    $token = $token.Trim()
    if ($token.Length -eq 0) { continue }
    $reason = Get-SecretLikeReason -Token $token
    if ($null -ne $reason) {
      Add-Failure "${Label}: contains secret-like value ($reason)"
    }
  }
}

function Assert-NoSecretLikeJsonStrings {
  param(
    [AllowNull()][object]$Value,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ($null -eq $Value) { return }
  if ($Value -is [string]) {
    Assert-NoSecretLikeText -Text $Value -Label $Label
    return
  }
  if ($Value -is [array]) {
    foreach ($item in $Value) {
      Assert-NoSecretLikeJsonStrings -Value $item -Label $Label
    }
    return
  }
  if ($Value -is [pscustomobject]) {
    foreach ($property in $Value.PSObject.Properties) {
      Assert-NoSecretLikeJsonStrings -Value $property.Value -Label $Label
    }
  }
}

function Validate-Response {
  param(
    [Parameter(Mandatory = $true)][object]$Fixture,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $response = Get-Field -Object $Fixture -Name "response"
  if (-not (Test-JsonObject -Value $response)) {
    Add-Failure "${Label}: response must be an object"
    return
  }
  if (-not (Test-U16Field -Object $response -Field "status")) {
    Add-Failure "${Label}: response.status must be a u16 number"
  }
  if (-not (Has-Field -Object $response -Name "body")) {
    Add-Failure "${Label}: response.body is required"
  }
}

function Validate-ExpectedUpstream {
  param(
    [Parameter(Mandatory = $true)][object]$Fixture,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $upstream = Get-Field -Object $Fixture -Name "expected_upstream"
  if (-not (Test-JsonObject -Value $upstream)) {
    Add-Failure "${Label}: expected_upstream must be an object"
    return
  }
  foreach ($field in @("method", "path")) {
    if (-not (Test-StringField -Object $upstream -Field $field)) {
      Add-Failure "${Label}: expected_upstream.$field must be a string"
    }
  }
  if (-not (Test-BoolField -Object $upstream -Field "stream")) {
    Add-Failure "${Label}: expected_upstream.stream must be a boolean"
  }
  if (-not (Has-Field -Object $upstream -Name "body")) {
    Add-Failure "${Label}: expected_upstream.body is required"
  }
}

function Validate-ExpectedErrorMapping {
  param(
    [Parameter(Mandatory = $true)][object]$Fixture,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $mapping = Get-Field -Object $Fixture -Name "expected_error_mapping"
  if (-not (Test-JsonObject -Value $mapping)) {
    Add-Failure "${Label}: expected_error_mapping must be an object"
    return
  }
  if (-not (Test-U16Field -Object $mapping -Field "http_status")) {
    Add-Failure "${Label}: expected_error_mapping.http_status must be a u16 number"
  }
  foreach ($field in @("error_type", "code", "owner", "stage")) {
    if (-not (Test-StringField -Object $mapping -Field $field)) {
      Add-Failure "${Label}: expected_error_mapping.$field must be a string"
    }
  }
  if ((Has-Field -Object $mapping -Name "retryable") -and -not (Test-BoolField -Object $mapping -Field "retryable")) {
    Add-Failure "${Label}: expected_error_mapping.retryable must be a boolean"
  }
}

function Validate-JsonFixture {
  param(
    [Parameter(Mandatory = $true)][string]$Adapter,
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][object]$Fixture,
    [Parameter(Mandatory = $true)][hashtable]$Counts
  )

  if (-not (Test-JsonObject -Value $Fixture)) {
    Add-Failure "${Label}: fixture root must be a JSON object"
    return
  }

  $name = Get-Field -Object $Fixture -Name "name"
  if (-not ($name -is [string]) -or $name.Trim().Length -eq 0) {
    Add-Failure "${Label}: fixture name must be a non-empty string"
    return
  }
  $name = $name.Trim()
  if ($name -notmatch '^[a-z0-9_]+$') {
    Add-Failure "${Label}: fixture name '$name' must be a lowercase snake_case slug"
  }
  if ($script:SeenNames.ContainsKey($name)) {
    Add-Failure "${Label}: fixture name '$name' duplicates $($script:SeenNames[$name])"
  } else {
    $script:SeenNames[$name] = $Label
  }

  $hasValidContract = (Has-Field -Object $Fixture -Name "request") -and
    (Has-Field -Object $Fixture -Name "expected_upstream") -and
    (Has-Field -Object $Fixture -Name "response") -and
    (Has-Field -Object $Fixture -Name "expected_usage")
  $hasErrorMapping = Has-Field -Object $Fixture -Name "expected_error_mapping"
  $hasStreamEvent = (Has-Field -Object $Fixture -Name "event") -and
    (Has-Field -Object $Fixture -Name "expected_event")

  if ($hasValidContract) {
    $Counts["valid"]++
    if (-not (Test-JsonObject -Value (Get-Field -Object $Fixture -Name "request"))) {
      Add-Failure "${Label}: request must be an object"
    }
    Validate-ExpectedUpstream -Fixture $Fixture -Label $Label
    Validate-Response -Fixture $Fixture -Label $Label
    $expectedUsage = Get-Field -Object $Fixture -Name "expected_usage"
    if ($null -ne $expectedUsage -and -not (Test-JsonObject -Value $expectedUsage)) {
      Add-Failure "${Label}: expected_usage must be an object or null"
    }
  }

  if ($hasErrorMapping) {
    $Counts["error"]++
    if (-not ((Has-Field -Object $Fixture -Name "request") -or (Has-Field -Object $Fixture -Name "response"))) {
      Add-Failure "${Label}: error fixture must include request or response"
    }
    if (Has-Field -Object $Fixture -Name "response") {
      Validate-Response -Fixture $Fixture -Label $Label
    }
    Validate-ExpectedErrorMapping -Fixture $Fixture -Label $Label
  }

  if ($hasStreamEvent -or $name.Contains("stream")) {
    $Counts["stream"]++
  }
  if ($hasStreamEvent) {
    if ($null -eq (Get-Field -Object $Fixture -Name "event")) {
      Add-Failure "${Label}: stream fixture event must not be null"
    }
    if ($null -eq (Get-Field -Object $Fixture -Name "expected_event")) {
      Add-Failure "${Label}: stream fixture expected_event must not be null"
    }
  }

  $partialValidFields = @()
  foreach ($field in @("request", "expected_upstream", "response", "expected_usage")) {
    if (Has-Field -Object $Fixture -Name $field) {
      $partialValidFields += $field
    }
  }
  if ($partialValidFields.Count -gt 0 -and -not $hasValidContract -and -not $hasErrorMapping -and -not $hasStreamEvent) {
    Add-Failure "${Label}: incomplete valid fixture contract fields: $($partialValidFields -join ', ')"
  }

  if (-not $hasValidContract -and -not $hasErrorMapping -and -not $hasStreamEvent) {
    Add-Failure "${Label}: $Adapter fixture must declare either request/expected_upstream/response/expected_usage, expected_error_mapping, or event/expected_event"
  }
  if ($hasValidContract -and $hasErrorMapping) {
    Add-Failure "${Label}: fixture should not be both a valid response contract and an error mapping"
  }
}

function Invoke-FixtureContractSelfTest {
  $originalFailures = $script:Failures
  $originalSeenNames = $script:SeenNames
  $selfTestFailures = [System.Collections.Generic.List[string]]::new()

  try {
    $script:Failures = [System.Collections.Generic.List[string]]::new()
    $script:SeenNames = @{}

    $counts = @{ json = 0; valid = 0; error = 0; stream = 0; sse = 0 }
    $validFixture = [pscustomobject]@{
      name = "adapter_conformance_self_valid"
      request = [pscustomobject]@{}
      expected_upstream = [pscustomobject]@{
        method = "POST"
        path = "/v1/mock"
        stream = $false
        body = [pscustomobject]@{}
      }
      response = [pscustomobject]@{
        status = 200
        body = [pscustomobject]@{}
      }
      expected_usage = $null
    }
    $errorFixture = [pscustomobject]@{
      name = "adapter_conformance_self_error"
      response = [pscustomobject]@{
        status = 429
        body = [pscustomobject]@{}
      }
      expected_error_mapping = [pscustomobject]@{
        http_status = 429
        error_type = "provider_error"
        code = "provider_429"
        owner = "provider"
        stage = "provider_call"
        retryable = $true
      }
    }
    $streamFixture = [pscustomobject]@{
      name = "adapter_conformance_self_stream"
      event = [pscustomobject]@{ type = "chunk" }
      expected_event = [pscustomobject]@{ type = "chunk" }
    }

    Validate-JsonFixture -Adapter "openai" -Label "self/valid.json" -Fixture $validFixture -Counts $counts
    Validate-JsonFixture -Adapter "openai" -Label "self/error.json" -Fixture $errorFixture -Counts $counts
    Validate-JsonFixture -Adapter "openai" -Label "self/stream.json" -Fixture $streamFixture -Counts $counts

    if ($script:Failures.Count -ne 0) {
      [void]$selfTestFailures.Add("valid/error/stream fixtures unexpectedly failed: $($script:Failures -join '; ')")
    }
    if ($counts["valid"] -ne 1 -or $counts["error"] -ne 1 -or $counts["stream"] -ne 1) {
      [void]$selfTestFailures.Add("valid/error/stream counts were not classified as 1/1/1")
    }

    $script:Failures.Clear()
    $secretFixture = [pscustomobject]@{
      name = "adapter_conformance_self_secret"
      sample = "sk-abcdef1234567890"
    }
    Assert-NoSecretLikeJsonStrings -Value $secretFixture -Label "self/secret.json"
    if (-not (Test-FailureContains -Needle "provider key prefix")) {
      [void]$selfTestFailures.Add("secret-like provider key prefix was not detected")
    }

    $script:Failures.Clear()
    $incompleteFixture = [pscustomobject]@{
      name = "adapter_conformance_self_incomplete"
      request = [pscustomobject]@{}
    }
    Validate-JsonFixture -Adapter "openai" -Label "self/incomplete.json" -Fixture $incompleteFixture -Counts $counts
    if (-not (Test-FailureContains -Needle "incomplete valid fixture contract fields")) {
      [void]$selfTestFailures.Add("incomplete valid fixture contract was not detected")
    }
  } finally {
    $script:Failures = $originalFailures
    $script:SeenNames = $originalSeenNames
  }

  foreach ($failure in $selfTestFailures) {
    Add-Failure "fixture contract self-test: $failure"
  }
}

function Write-CoverageSummary {
  Write-Host "Adapter conformance coverage:"
  foreach ($adapter in $Adapters) {
    if (-not $script:AdapterCounts.ContainsKey($adapter)) {
      Write-Host " - ${adapter}: missing"
      continue
    }

    $counts = $script:AdapterCounts[$adapter]
    Write-Host (" - {0}: json={1} valid={2} error={3} stream={4} sse={5}" -f $adapter, $counts["json"], $counts["valid"], $counts["error"], $counts["stream"], $counts["sse"])
  }
}

$mode = "run"
if ($DryRun) { $mode = "dry-run" }
Write-Host "Adapter conformance: mode=$mode strict=$([bool]$Strict)"
Invoke-FixtureContractSelfTest
Write-Host "Adapter conformance: checking fixtures"

foreach ($adapter in $Adapters) {
  $adapterDir = Join-Path $FixtureRoot $adapter
  $counts = @{ json = 0; valid = 0; error = 0; stream = 0; sse = 0 }

  if (-not (Test-Path -LiteralPath $adapterDir -PathType Container)) {
    Add-Failure "${adapter}: fixture directory is missing"
    continue
  }

  foreach ($file in (Get-ChildItem -LiteralPath $adapterDir -File -Filter *.json | Sort-Object Name)) {
    $counts["json"]++
    $script:TotalJson++
    $label = Get-RelativeFixturePath -Path $file.FullName

    try {
      $text = Get-Content -LiteralPath $file.FullName -Raw
      $fixture = $text | ConvertFrom-Json
    } catch {
      Add-Failure "${label}: invalid JSON fixture: $($_.Exception.Message)"
      continue
    }

    Assert-NoSecretLikeJsonStrings -Value $fixture -Label $label
    Validate-JsonFixture -Adapter $adapter -Label $label -Fixture $fixture -Counts $counts
  }

  foreach ($file in (Get-ChildItem -LiteralPath $adapterDir -File -Recurse -Filter *.sse | Sort-Object FullName)) {
    $counts["stream"]++
    $counts["sse"]++
    $script:TotalSse++
    $label = Get-RelativeFixturePath -Path $file.FullName
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ($text.Trim().Length -eq 0) {
      Add-Failure "${label}: SSE fixture must not be empty"
    }
    Assert-NoSecretLikeText -Text $text -Label $label
  }

  if ($counts["json"] -eq 0) { Add-Failure "${adapter}: no JSON fixtures found" }
  if ($counts["valid"] -eq 0) { Add-Failure "${adapter}: missing valid fixture" }
  if ($counts["error"] -eq 0) { Add-Failure "${adapter}: missing error fixture" }
  if ($counts["stream"] -eq 0) { Add-Failure "${adapter}: missing stream fixture" }
  $script:AdapterCounts[$adapter] = $counts
}

Write-CoverageSummary

if ($Failures.Count -eq 0) {
  Invoke-CargoConformanceTest -Name "focused Rust harness" -Arguments $FocusedCargoArgs
} else {
  Write-Host "Adapter conformance: skipping focused Rust harness because fixture checks failed"
}

if ($Strict -and $Failures.Count -eq 0) {
  Invoke-CargoConformanceTest -Name "strict adapters crate tests" -Arguments $StrictCargoArgs
} elseif ($Strict) {
  Write-Host "Adapter conformance: skipping strict adapters crate tests because earlier checks failed"
}

if ($Failures.Count -gt 0) {
  Write-Host "Adapter conformance failed: failures=$($Failures.Count) adapters=$($Adapters.Count) json=$TotalJson sse=$TotalSse unique_names=$($SeenNames.Count)"
  foreach ($failure in $Failures) {
    Write-Host " - $failure"
  }
  exit 1
}

$status = "OK"
if ($DryRun) { $status = "OK (dry-run)" }
Write-Host "Adapter conformance ${status}: adapters=$($Adapters.Count) json=$TotalJson sse=$TotalSse unique_names=$($SeenNames.Count)"
exit 0
