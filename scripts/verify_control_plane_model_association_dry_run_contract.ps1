param(
  [string]$FixturePath = "tests/fixtures/control-plane/model_association_dry_run_contract.json",
  [string]$OpenApiPath = "examples/openapi_admin_skeleton.yaml",
  [string]$AdminSourcePath = "apps/control-plane/src/admin.rs",
  [string]$AdminUiSourceRoot = "web/admin-ui/src",
  [string]$OutputPath = ".tmp/control-plane/model_association_dry_run_contract_verification.json",
  [switch]$NoWrite
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Checks = New-Object System.Collections.Generic.List[object]

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
  $prefix = $repoRoot.Path.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($full.Substring($prefix.Length) -replace "\\", "/")
  }

  return ($full -replace "\\", "/")
}

function Add-Failure {
  param([Parameter(Mandatory = $true)][string]$Message)

  [void]$script:Failures.Add($Message)
  Write-Host $Message
}

function Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    & $Action
    [void]$script:Checks.Add([pscustomobject]@{ name = $Name; status = "pass" })
    Write-Host "[OK] $Name"
  } catch {
    $message = "[FAIL] $Name - $($_.Exception.Message)"
    [void]$script:Checks.Add([pscustomobject]@{ name = $Name; status = "fail"; error = $_.Exception.Message })
    Add-Failure $message
  }
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-ArrayContains {
  param(
    [AllowNull()]$Array,
    [Parameter(Mandatory = $true)][string]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $values = @($Array | ForEach-Object { [string]$_ })
  if ($values -notcontains $Expected) {
    throw "$Message; got: $($values -join ', ')"
  }
}

function Assert-TextContains {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Needle,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not $Text.Contains($Needle)) {
    throw $Message
  }
}

function Assert-TextMatches {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not ($Text -match $Pattern)) {
    throw $Message
  }
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) {
    return $true
  }

  foreach ($pattern in @(
      '(?i)"(?:encrypted_secret|secret_fingerprint|provider_secret|raw_key)"\s*:',
      '(?i)"(?:api_key|secret|token|password)"\s*:\s*"[^"]{4,}"',
      '(?i)authorization\s*[:=]\s*bearer\s+[^"\s,}]+',
      '(?i)x-admin-session\s*[:=]',
      '(?i)postgres(?:ql)?://[^"\s]+',
      'sk-[A-Za-z0-9._~+\-/=]{8,}'
    )) {
    if ($Text -match $pattern) {
      return $false
    }
  }

  return $true
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path $Path)) {
    throw "missing file: $(Get-RepoRelativePath $Path)"
  }

  try {
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
  } catch {
    throw "invalid JSON in $(Get-RepoRelativePath $Path): $($_.Exception.Message)"
  }
}

function Assert-CandidateContract {
  param(
    [Parameter(Mandatory = $true)]$Candidate,
    [Parameter(Mandatory = $true)][string]$Label
  )

  foreach ($field in @(
      "association_id",
      "association_type",
      "association_priority",
      "fallback_allowed",
      "canonical_model_id",
      "channel_id",
      "channel_name",
      "provider_id",
      "provider_code",
      "provider_name",
      "provider_model",
      "upstream_model",
      "filtered",
      "selected",
      "trace_affinity_match"
    )) {
    Assert-True ($null -ne $Candidate.PSObject.Properties[$field]) "$Label is missing $field"
  }

  Assert-True ($Candidate.fallback_allowed -is [bool]) "$Label fallback_allowed must be a boolean"
  Assert-True (Test-SecretSafeText ($Candidate | ConvertTo-Json -Depth 32 -Compress)) "$Label leaks credential-like material"
}

function Assert-RouteDecisionSnapshot {
  param([Parameter(Mandatory = $true)]$Data)

  Assert-True ($Data.decision_snapshot_version -eq 1) "decision_snapshot_version must be 1"
  Assert-True ($Data.route_policy_version -eq "gateway_db_route_v1") "route_policy_version must be gateway_db_route_v1"
  Assert-True ($null -ne $Data.route_decision_snapshot) "route_decision_snapshot is required"
  Assert-True ($Data.route_decision_snapshot.version -eq $Data.decision_snapshot_version) "snapshot version must match response version"
  Assert-True ($Data.route_decision_snapshot.requested_model -eq $Data.requested_model) "snapshot requested_model must match response"
}

$fixtureFullPath = Resolve-RepoPath $FixturePath
$openApiFullPath = Resolve-RepoPath $OpenApiPath
$adminSourceFullPath = Resolve-RepoPath $AdminSourcePath
$adminUiRootFullPath = Resolve-RepoPath $AdminUiSourceRoot
$outputFullPath = Resolve-RepoPath $OutputPath

Check "fixture JSON contract" {
  $fixture = Read-JsonFile $fixtureFullPath
  $fixtureText = Get-Content -Raw -Path $fixtureFullPath

  Assert-True ($fixture.scenario -eq "control_plane_model_association_dry_run_contract") "scenario must name the model association dry-run contract"
  Assert-True ($fixture.endpoint.method -eq "POST") "endpoint method must be POST"
  Assert-True ($fixture.endpoint.path -eq "/admin/model-associations/dry-run") "endpoint path must be /admin/model-associations/dry-run"
  Assert-ArrayContains $fixture.request_contract.required_fields "project_id" "request contract must require project_id"
  Assert-ArrayContains $fixture.request_contract.required_fields "profile_id" "request contract must require profile_id"
  Assert-ArrayContains $fixture.request_contract.model_selector_any_of "requested_model" "request contract must allow requested_model selector"
  Assert-ArrayContains $fixture.request_contract.model_selector_any_of "canonical_model_id" "request contract must allow canonical_model_id selector"
  Assert-ArrayContains $fixture.request_contract.model_selector_any_of "canonical_model_key" "request contract must allow canonical_model_key selector"
  Assert-ArrayContains $fixture.response_contract.required_data_fields "route_decision_snapshot" "response contract must include route_decision_snapshot"
  Assert-ArrayContains $fixture.response_contract.required_data_fields "selected_candidate" "response contract must include selected_candidate"
  Assert-ArrayContains $fixture.response_contract.candidate_required_fields "fallback_allowed" "candidate contract must require fallback_allowed"
  Assert-True ($fixture.response_contract.credential_material_omitted -eq $true) "credential_material_omitted must be true"
  Assert-True (Test-SecretSafeText $fixtureText) "fixture contains credential-like material"
}

Check "fixture examples cover selected and no-candidate states" {
  $fixture = Read-JsonFile $fixtureFullPath
  $selected = $fixture.examples.selected.response.data
  $noCandidate = $fixture.examples.no_candidate.response.data

  Assert-True ($selected.selection.status -eq "selected") "selected example must have selected status"
  Assert-True ($null -ne $selected.selected_candidate) "selected example must expose selected_candidate"
  Assert-CandidateContract $selected.selected_candidate "selected_candidate"
  Assert-True ($selected.candidates.Count -gt 0) "selected example must include at least one candidate"
  foreach ($candidate in @($selected.candidates)) {
    Assert-CandidateContract $candidate "candidate"
  }
  Assert-RouteDecisionSnapshot $selected

  Assert-True ($noCandidate.selection.status -eq "model_not_found_or_not_allowed") "no_candidate must use model_not_found_or_not_allowed status"
  Assert-True ($null -eq $noCandidate.selected_candidate) "no_candidate selected_candidate must be null"
  Assert-True ($noCandidate.candidates.Count -eq 0) "no_candidate candidates must be empty"
  Assert-RouteDecisionSnapshot $noCandidate
}

Check "OpenAPI dry-run schema exposes fallback and selector contract" {
  if (-not (Test-Path $openApiFullPath)) {
    throw "missing file: $(Get-RepoRelativePath $openApiFullPath)"
  }

  $openApi = Get-Content -Raw -Path $openApiFullPath
  Assert-TextContains $openApi "/admin/model-associations/dry-run:" "OpenAPI must expose /admin/model-associations/dry-run"
  Assert-TextContains $openApi "`$ref: '#/components/schemas/ModelAssociationDryRunRequest'" "OpenAPI path must reference ModelAssociationDryRunRequest"
  Assert-TextContains $openApi "`$ref: '#/components/schemas/ModelAssociationDryRunEnvelope'" "OpenAPI path must reference ModelAssociationDryRunEnvelope"
  Assert-TextContains $openApi "ModelAssociationDryRunRequest:" "OpenAPI must define ModelAssociationDryRunRequest"
  Assert-TextContains $openApi "required: [project_id, profile_id]" "dry-run request must require project_id/profile_id"
  Assert-TextContains $openApi "required: [requested_model]" "dry-run request anyOf must include requested_model"
  Assert-TextContains $openApi "required: [canonical_model_id]" "dry-run request anyOf must include canonical_model_id"
  Assert-TextContains $openApi "required: [canonical_model_key]" "dry-run request anyOf must include canonical_model_key"
  Assert-TextContains $openApi "RouteDryRunCandidate:" "OpenAPI must define RouteDryRunCandidate"
  Assert-TextContains $openApi "        - fallback_allowed" "RouteDryRunCandidate required list must include fallback_allowed"
  Assert-TextMatches $openApi "(?s)RouteDryRunCandidate:.*?fallback_allowed:\s*\r?\n\s*type:\s*boolean" "RouteDryRunCandidate fallback_allowed must be boolean"
}

Check "Control Plane source returns fallback_allowed without credential material" {
  if (-not (Test-Path $adminSourceFullPath)) {
    throw "missing file: $(Get-RepoRelativePath $adminSourceFullPath)"
  }

  $adminSource = Get-Content -Raw -Path $adminSourceFullPath
  Assert-TextContains $adminSource '"/admin/model-associations/dry-run"' "router must register dry-run endpoint"
  Assert-TextContains $adminSource "async fn dry_run_model_association" "dry-run handler must exist"
  Assert-TextContains $adminSource "requested_model, canonical_model_key, or canonical_model_id is required" "handler must validate model selector"
  Assert-TextContains $adminSource "fn route_dry_run_candidate_response" "candidate response mapper must exist"
  Assert-TextContains $adminSource '"fallback_allowed": candidate.association.fallback_allowed' "candidate response must expose association fallback_allowed"
  Assert-True (-not ($adminSource -match '"(?:encrypted_secret|secret_fingerprint|provider_secret|raw_key)"\s*:\s*candidate')) "dry-run candidate response must not serialize provider credential fields"
}

Check "Admin UI client and views surface fallback_allowed" {
  if (-not (Test-Path $adminUiRootFullPath)) {
    throw "missing directory: $(Get-RepoRelativePath $adminUiRootFullPath)"
  }

  $clientPath = Join-Path $adminUiRootFullPath "api/client.ts"
  $dryRunComponentPath = Join-Path $adminUiRootFullPath "components/ModelAssociationDryRun.tsx"
  $modelsPagePath = Join-Path $adminUiRootFullPath "components/ModelsPage.tsx"
  $routingPagePath = Join-Path $adminUiRootFullPath "components/RoutingPage.tsx"

  foreach ($path in @($clientPath, $dryRunComponentPath, $modelsPagePath, $routingPagePath)) {
    if (-not (Test-Path $path)) {
      throw "missing file: $(Get-RepoRelativePath $path)"
    }
  }

  $client = Get-Content -Raw -Path $clientPath
  $component = Get-Content -Raw -Path $dryRunComponentPath
  $modelsPage = Get-Content -Raw -Path $modelsPagePath
  $routingPage = Get-Content -Raw -Path $routingPagePath

  Assert-TextContains $client "export type ModelAssociationDryRunCandidate" "client type must declare dry-run candidate"
  Assert-TextContains $client "fallback_allowed: boolean;" "client candidate type must require fallback_allowed"
  Assert-TextContains $client '"/admin/model-associations/dry-run"' "client must call model association dry-run endpoint"
  Assert-TextContains $component "Fallback allowed" "dry-run UI must display selected fallback status"
  Assert-TextContains $component "Fallback blocked" "dry-run UI must display blocked fallback status"
  Assert-TextContains $component "dryRunModelAssociation" "dry-run UI must invoke API client"
  Assert-TextContains $modelsPage "<ModelAssociationDryRun models={models} />" "Models page must include dry-run panel with model datalist"
  Assert-TextContains $routingPage "<ModelAssociationDryRun />" "Routing page must include dry-run panel"
}

$status = if ($script:Failures.Count -eq 0) { "pass" } else { "fail" }
$result = [pscustomobject]@{
  schema_version = "control_plane_model_association_dry_run_contract_verification.v1"
  status = $status
  checked_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
  checked_paths = @{
    fixture = Get-RepoRelativePath $fixtureFullPath
    openapi = Get-RepoRelativePath $openApiFullPath
    admin_source = Get-RepoRelativePath $adminSourceFullPath
    admin_ui_source_root = Get-RepoRelativePath $adminUiRootFullPath
  }
  checks = @($script:Checks.ToArray())
  failures = @($script:Failures.ToArray())
  notes = @(
    "Verifier is contract-only and does not start Control Plane, Gateway, database, or upstream provider services.",
    "Credential-safety checks reject secret-like fields or values in the dry-run fixture and candidate response source."
  )
}

if (-not $NoWrite) {
  $outputRelative = Get-RepoRelativePath $outputFullPath
  if ($outputRelative.StartsWith("..", [System.StringComparison]::Ordinal) -or [System.IO.Path]::IsPathRooted($outputRelative)) {
    throw "OutputPath must stay inside the repository"
  }
  if (-not $outputRelative.StartsWith(".tmp/control-plane/", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must stay under .tmp/control-plane/"
  }

  $outputDirectory = Split-Path -Parent $outputFullPath
  if (-not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
  }
  $result | ConvertTo-Json -Depth 16 | Set-Content -Path $outputFullPath -Encoding UTF8
  Write-Host "Wrote $(Get-RepoRelativePath $outputFullPath)"
}

if ($script:Failures.Count -gt 0) {
  Write-Host "model association dry-run contract verification failed with $($script:Failures.Count) failure(s)."
  exit 1
}

Write-Host "model association dry-run contract verification passed."
