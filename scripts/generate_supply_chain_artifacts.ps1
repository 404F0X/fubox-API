#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$OutputDirectory,
  [string]$ImageIdFile,
  [switch]$Plan,
  [string]$WriteManifestTemplate,
  [string]$CheckManifestFreshness,
  [switch]$DryRunGate
)

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}
$script:RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..")).Path
$script:ExcludedDirectoryNames = @(".git", "target", "node_modules", "dist", "dev_starter_unpacked", ".docx_unpacked")

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $script:RepoRoot "artifacts/supply-chain"
}

function Get-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $trimChars = [char[]]@("\", "/")
  $root = [System.IO.Path]::GetFullPath($script:RepoRoot).TrimEnd($trimChars)
  $target = [System.IO.Path]::GetFullPath($Path)
  if ([string]::Equals($target, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
    return "."
  }

  $rootWithSeparator = $root + [System.IO.Path]::DirectorySeparatorChar
  if ($target.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($target.Substring($rootWithSeparator.Length) -replace "\\", "/")
  }

  return ($target -replace "\\", "/")
}

function Test-ExcludedDirectoryName {
  param([Parameter(Mandatory = $true)][string]$Name)

  foreach ($excluded in $script:ExcludedDirectoryNames) {
    if ([string]::Equals($Name, $excluded, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }

  return $false
}

function Get-RepositoryFiles {
  param([Parameter(Mandatory = $true)][string[]]$Names)

  $files = New-Object System.Collections.Generic.List[string]
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($script:RepoRoot)

  while ($stack.Count -gt 0) {
    $directory = $stack.Pop()
    foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
      if ($item.PSIsContainer) {
        if (-not (Test-ExcludedDirectoryName $item.Name)) {
          $stack.Push($item.FullName)
        }
        continue
      }

      foreach ($name in $Names) {
        if ([string]::Equals($item.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
          [void]$files.Add($item.FullName)
          break
        }
      }
    }
  }

  return @($files.ToArray())
}

function Get-RepositoryFilesMatching {
  param([Parameter(Mandatory = $true)][string[]]$NamePatterns)

  $files = New-Object System.Collections.Generic.List[string]
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($script:RepoRoot)

  while ($stack.Count -gt 0) {
    $directory = $stack.Pop()
    foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
      if ($item.PSIsContainer) {
        if (-not (Test-ExcludedDirectoryName $item.Name)) {
          $stack.Push($item.FullName)
        }
        continue
      }

      foreach ($pattern in $NamePatterns) {
        if ($item.Name -like $pattern) {
          [void]$files.Add($item.FullName)
          break
        }
      }
    }
  }

  return @($files.ToArray())
}

function Write-Utf8NoBomFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content
  )

  $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-JsonArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Object
  )

  $json = $Object | ConvertTo-Json -Depth 24
  Write-Utf8NoBomFile -Path $Path -Content ($json + [Environment]::NewLine)
}

function Get-Sha256Digest {
  param([Parameter(Mandatory = $true)][string]$Path)

  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-CargoLockField {
  param(
    [Parameter(Mandatory = $true)][string]$Block,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $match = [regex]::Match($Block, ('(?m)^\s*{0}\s*=\s*"([^"]*)"\s*$' -f [regex]::Escape($Name)))
  if ($match.Success) {
    return [string]$match.Groups[1].Value
  }

  return ""
}

function Get-CargoComponents {
  param([Parameter(Mandatory = $true)][string]$LockPath)

  $components = New-Object System.Collections.Generic.List[object]
  $relative = Get-RepoRelativePath $LockPath
  $content = Get-Content -LiteralPath $LockPath -Raw
  $packageMatches = @([regex]::Matches($content, '(?ms)^\s*\[\[package\]\]\s*(.*?)(?=^\s*\[\[package\]\]\s*|\z)'))

  foreach ($match in $packageMatches) {
    $block = [string]$match.Groups[1].Value
    $name = Get-CargoLockField -Block $block -Name "name"
    $version = Get-CargoLockField -Block $block -Name "version"
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($version)) {
      continue
    }

    $source = Get-CargoLockField -Block $block -Name "source"
    $checksum = Get-CargoLockField -Block $block -Name "checksum"
    $hashes = @()
    if (-not [string]::IsNullOrWhiteSpace($checksum)) {
      $hashes = @([ordered]@{ alg = "SHA-256"; content = $checksum.ToLowerInvariant() })
    }

    [void]$components.Add([ordered]@{
      type = "library"
      group = "cargo"
      name = $name
      version = $version
      purl = ("pkg:cargo/{0}@{1}" -f $name, $version)
      hashes = $hashes
      properties = @(
        [ordered]@{ name = "ai-gateway:lockfile"; value = $relative },
        [ordered]@{ name = "ai-gateway:source"; value = $source }
      )
      "bom-ref" = ("pkg:cargo/{0}@{1}" -f $name, $version)
    })
  }

  return @($components.ToArray())
}

function Get-NpmPackageNameFromPath {
  param([Parameter(Mandatory = $true)][string]$PackagePath)

  $parts = @($PackagePath -split "/")
  for ($i = $parts.Count - 1; $i -ge 0; $i--) {
    if ($parts[$i] -eq "node_modules" -and ($i + 1) -lt $parts.Count) {
      $name = $parts[$i + 1]
      if ($name.StartsWith("@") -and ($i + 2) -lt $parts.Count) {
        $name = $name + "/" + $parts[$i + 2]
      }
      return $name
    }
  }

  return $PackagePath
}

function Convert-ToNpmPurlName {
  param([Parameter(Mandatory = $true)][string]$Name)

  if ($Name.StartsWith("@") -and $Name.Contains("/")) {
    $segments = @($Name.Split("/", 2, [System.StringSplitOptions]::None))
    return ("%40{0}/{1}" -f $segments[0].Substring(1), $segments[1])
  }

  return $Name
}

function Get-NpmComponents {
  param([Parameter(Mandatory = $true)][string]$LockPath)

  $components = New-Object System.Collections.Generic.List[object]
  $relative = Get-RepoRelativePath $LockPath

  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    return @()
  }

  $nodeScript = @'
const fs = require('fs');
const lockPath = process.argv[1];
const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
const components = [];

function packageNameFromPath(packagePath) {
  const parts = String(packagePath || '').split('/');
  for (let i = parts.length - 1; i >= 0; i--) {
    if (parts[i] === 'node_modules' && i + 1 < parts.length) {
      if (String(parts[i + 1]).startsWith('@') && i + 2 < parts.length) {
        return parts[i + 1] + '/' + parts[i + 2];
      }
      return parts[i + 1];
    }
  }
  return packagePath;
}

function purlName(name) {
  if (String(name).startsWith('@') && String(name).includes('/')) {
    const [scope, pkg] = String(name).split('/', 2);
    return '%40' + scope.slice(1) + '/' + pkg;
  }
  return String(name);
}

for (const [packagePath, entry] of Object.entries(lock.packages || {})) {
  if (!packagePath || !/(^|\/)node_modules\//.test(packagePath)) {
    continue;
  }
  const version = String((entry && entry.version) || '');
  if (!version) {
    continue;
  }
  const name = String((entry && entry.name) || packageNameFromPath(packagePath));
  components.push({
    packagePath,
    name,
    version,
    purlName: purlName(name),
    resolved: String((entry && entry.resolved) || ''),
    integrity: String((entry && entry.integrity) || '')
  });
}

process.stdout.write(JSON.stringify(components));
'@

  $nodeOutput = & node -e $nodeScript $LockPath 2>&1
  $exitCode = $LASTEXITCODE
  if ($null -eq $exitCode) {
    $exitCode = 0
  }
  if ($exitCode -ne 0) {
    return @()
  }

  $items = @((($nodeOutput | ForEach-Object { $_.ToString() }) -join "`n") | ConvertFrom-Json -ErrorAction Stop)
  foreach ($item in $items) {
    $packagePath = [string]$item.packagePath
    $name = [string]$item.name
    $version = [string]$item.version
    if ([string]::IsNullOrWhiteSpace($packagePath) -or [string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($version)) {
      continue
    }

    $purlName = [string]$item.purlName
    [void]$components.Add([ordered]@{
      type = "library"
      group = "npm"
      name = $name
      version = $version
      purl = ("pkg:npm/{0}@{1}" -f $purlName, $version)
      properties = @(
        [ordered]@{ name = "ai-gateway:lockfile"; value = $relative },
        [ordered]@{ name = "ai-gateway:packagePath"; value = $packagePath },
        [ordered]@{ name = "ai-gateway:resolved"; value = [string]$item.resolved },
        [ordered]@{ name = "ai-gateway:integrity"; value = [string]$item.integrity }
      )
      "bom-ref" = ("pkg:npm/{0}@{1}#{2}" -f $purlName, $version, ($packagePath -replace '[^A-Za-z0-9._~-]', '_'))
    })
  }

  return @($components.ToArray())
}

function Get-DockerfileBaseImages {
  param([Parameter(Mandatory = $true)][string]$DockerfilePath)

  $images = New-Object System.Collections.Generic.List[string]
  foreach ($line in Get-Content -LiteralPath $DockerfilePath) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
      continue
    }
    if ($trimmed -notmatch '(?i)^FROM\s+') {
      continue
    }

    $parts = @($trimmed -split '\s+')
    $imageIndex = 1
    while ($imageIndex -lt $parts.Count -and $parts[$imageIndex].StartsWith("--")) {
      $imageIndex += 1
    }
    if ($imageIndex -lt $parts.Count) {
      [void]$images.Add($parts[$imageIndex])
    }
  }

  return @($images.ToArray())
}

function Get-ContainerComponents {
  param([Parameter(Mandatory = $true)][string[]]$ContainerFiles)

  $components = New-Object System.Collections.Generic.List[object]
  foreach ($containerFile in $ContainerFiles) {
    $relative = Get-RepoRelativePath $containerFile
    $name = [System.IO.Path]::GetFileName($containerFile)

    if ([string]::Equals($name, "Dockerfile", [System.StringComparison]::OrdinalIgnoreCase) -or $name.EndsWith(".Dockerfile", [System.StringComparison]::OrdinalIgnoreCase)) {
      foreach ($image in @(Get-DockerfileBaseImages $containerFile)) {
        if ([string]::Equals($image, "scratch", [System.StringComparison]::OrdinalIgnoreCase)) {
          continue
        }
        [void]$components.Add([ordered]@{
          type = "container"
          name = $image
          version = ""
          properties = @(
            [ordered]@{ name = "ai-gateway:manifest"; value = $relative },
            [ordered]@{ name = "ai-gateway:usage"; value = "dockerfile-from" }
          )
          "bom-ref" = ("container:{0}#{1}" -f ($image -replace '[^A-Za-z0-9._~:-]', '_'), ($relative -replace '[^A-Za-z0-9._~-]', '_'))
        })
      }
      continue
    }

    $content = Get-Content -LiteralPath $containerFile -Raw
    foreach ($match in @([regex]::Matches($content, '(?im)^\s*image\s*:\s*[''"]?([^''"\s#]+)'))) {
      $image = [string]$match.Groups[1].Value
      [void]$components.Add([ordered]@{
        type = "container"
        name = $image
        version = ""
        properties = @(
          [ordered]@{ name = "ai-gateway:manifest"; value = $relative },
          [ordered]@{ name = "ai-gateway:usage"; value = "compose-image" }
        )
        "bom-ref" = ("container:{0}#{1}" -f ($image -replace '[^A-Za-z0-9._~:-]', '_'), ($relative -replace '[^A-Za-z0-9._~-]', '_'))
      })
    }
  }

  return @($components.ToArray())
}

function Get-Materials {
  param([Parameter(Mandatory = $true)][string[]]$Paths)

  $materials = New-Object System.Collections.Generic.List[object]
  foreach ($path in @($Paths | Sort-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      continue
    }

    [void]$materials.Add([ordered]@{
      uri = ("file:{0}" -f (Get-RepoRelativePath $path))
      digest = [ordered]@{ sha256 = Get-Sha256Digest $path }
    })
  }

  return @($materials.ToArray())
}

function Get-RelativePaths {
  param([string[]]$Paths)

  $relativePaths = New-Object System.Collections.Generic.List[string]
  foreach ($path in @($Paths)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
      continue
    }
    [void]$relativePaths.Add((Get-RepoRelativePath $path))
  }

  return @($relativePaths.ToArray() | Sort-Object -Unique)
}

function New-ManifestFreshnessPlan {
  param(
    [Parameter(Mandatory = $true)][string]$OutputDirectoryPath,
    [string[]]$TrackedFiles = @(),
    [string[]]$ContainerFiles = @(),
    [string[]]$CiFiles = @()
  )

  $allSourceFiles = @(Get-RelativePaths (@($TrackedFiles) + @($ContainerFiles) + @($CiFiles) + @(
    (Join-Path $script:RepoRoot "scripts/generate_supply_chain_artifacts.ps1"),
    (Join-Path $script:RepoRoot "scripts/scan_supply_chain.ps1"),
    (Join-Path $script:RepoRoot "scripts/test_supply_chain_artifacts.ps1")
  )))

  return [ordered]@{
    schemaVersion = "manifest-freshness-plan/v1"
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    purpose = "Functional planning seam for manifest/SBOM freshness. It does not execute clean-clone, full release evidence, network vulnerability scans, or a release approval gate."
    outputDirectory = Get-RepoRelativePath $OutputDirectoryPath
    requiredArtifacts = @(
      [ordered]@{ path = "sbom.cyclonedx.json"; kind = "CycloneDX SBOM"; freshnessSource = "lockfiles and container manifests" },
      [ordered]@{ path = "provenance.intoto.json"; kind = "SLSA/in-toto provenance"; freshnessSource = "source material digests and generated SBOM digest" },
      [ordered]@{ path = "manifest.json"; kind = "artifact manifest"; freshnessSource = "required artifact hashes and source coverage contract" },
      [ordered]@{ path = "SHA256SUMS"; kind = "checksums"; freshnessSource = "generated artifact file hashes" }
    )
    sourceFiles = $allSourceFiles
    sourceFileGroups = [ordered]@{
      lockfiles = @(Get-RelativePaths $TrackedFiles)
      containerManifests = @(Get-RelativePaths $ContainerFiles)
      ciWorkflows = @(Get-RelativePaths $CiFiles)
      supplyChainScripts = @(
        "scripts/generate_supply_chain_artifacts.ps1",
        "scripts/scan_supply_chain.ps1",
        "scripts/test_supply_chain_artifacts.ps1"
      )
    }
    stalenessRules = @(
      [ordered]@{ id = "required_artifacts_present"; rule = "All required artifacts must exist in the output directory before release review." },
      [ordered]@{ id = "manifest_artifact_hashes_match"; rule = "manifest.json artifact sha256 values must match current file contents." },
      [ordered]@{ id = "checksums_match"; rule = "SHA256SUMS entries must match current generated artifact file contents." },
      [ordered]@{ id = "source_materials_current"; rule = "Any change to a listed source file after artifact generation requires regenerating SBOM/provenance/manifest/checksums." },
      [ordered]@{ id = "provenance_subject_current"; rule = "provenance.intoto.json must identify sbom.cyclonedx.json with the current SBOM sha256." },
      [ordered]@{ id = "operator_evidence_not_implied"; rule = "A fresh manifest/SBOM plan is not clean-clone evidence, full SBOM approval, or release approval." }
    )
    commandsToRun = [ordered]@{
      planOnly = "pwsh -NoProfile -File scripts/generate_supply_chain_artifacts.ps1 -Plan"
      writeTemplate = "pwsh -NoProfile -File scripts/generate_supply_chain_artifacts.ps1 -Plan -WriteManifestTemplate artifacts/supply-chain/manifest.freshness.template.json"
      generateArtifacts = "pwsh -NoProfile -File scripts/generate_supply_chain_artifacts.ps1 -OutputDirectory artifacts/supply-chain"
      offlineSupplyChainScan = "pwsh -NoProfile -File scripts/scan_supply_chain.ps1 -SkipNetwork"
      selfTest = "pwsh -NoProfile -File scripts/test_supply_chain_artifacts.ps1"
      laterOperatorActions = @(
        "Run clean-clone transcript in a fresh checkout.",
        "Run full SBOM/release evidence review with the operator's selected toolchain.",
        "Run the full release gate only when the release owner intentionally resumes release readiness."
      )
    }
    nonGoals = @(
      "does not read or print environment variable values",
      "does not require provider keys, API tokens, DB URLs, or production credentials",
      "does not perform clean clone or full release evidence closure"
    )
  }
}

function Get-JsonArrayStrings {
  param($Value)

  if ($null -eq $Value) {
    return @()
  }

  return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Add-GateReason {
  param(
    [Parameter(Mandatory = $true)]$List,
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][string]$Message
  )

  [void]$List.Add([ordered]@{
    code = $Code
    message = $Message
  })
}

function Compare-StringSets {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string[]]$Expected,
    [string[]]$Actual,
    [Parameter(Mandatory = $true)]$BlockedReasons
  )

  $expectedSet = @(Get-JsonArrayStrings $Expected)
  $actualSet = @(Get-JsonArrayStrings $Actual)
  $missing = @($expectedSet | Where-Object { $actualSet -notcontains $_ })
  $unexpected = @($actualSet | Where-Object { $expectedSet -notcontains $_ })

  if ($missing.Count -gt 0) {
    Add-GateReason -List $BlockedReasons -Code ("missing_{0}" -f $Name) -Message ("Template is missing {0}: {1}" -f $Name, ($missing -join ", "))
  }
  if ($unexpected.Count -gt 0) {
    Add-GateReason -List $BlockedReasons -Code ("unexpected_{0}" -f $Name) -Message ("Template has unexpected {0}: {1}" -f $Name, ($unexpected -join ", "))
  }

  return [ordered]@{
    expected = $expectedSet
    actual = $actualSet
    missing = $missing
    unexpected = $unexpected
    match = ($missing.Count -eq 0 -and $unexpected.Count -eq 0)
  }
}

function Get-ObjectPropertyNames {
  param($Object)

  if ($null -eq $Object) {
    return @()
  }

  if ($Object -is [System.Collections.IDictionary]) {
    return @($Object.Keys | ForEach-Object { [string]$_ } | Sort-Object -Unique)
  }

  return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
}

function Get-ObjectPropertyValue {
  param(
    $Object,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Object) {
    return @()
  }

  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) {
      return @($Object[$Name])
    }
    return @()
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return @()
  }

  return @($property.Value)
}

function Test-ManifestFreshness {
  param(
    [Parameter(Mandatory = $true)]$CurrentPlan,
    [string]$TemplatePath,
    [bool]$DryRunOnly
  )

  $blockedReasons = New-Object System.Collections.Generic.List[object]
  $pendingReasons = New-Object System.Collections.Generic.List[object]
  $acceptedReasons = New-Object System.Collections.Generic.List[object]
  $readback = [ordered]@{
    templatePath = if ([string]::IsNullOrWhiteSpace($TemplatePath)) { "" } else { Get-RepoRelativePath $TemplatePath }
    templateSchemaVersion = ""
    currentSchemaVersion = [string]$CurrentPlan.schemaVersion
    requiredArtifacts = $null
    sourceFiles = $null
    sourceFileGroups = [ordered]@{}
    stalenessRules = $null
  }

  if ([string]::IsNullOrWhiteSpace($TemplatePath)) {
    Add-GateReason -List $pendingReasons -Code "manifest_template_not_supplied" -Message "No freshness template path was supplied; current plan was generated for readback only."
    return [ordered]@{
      schemaVersion = "manifest-freshness-dry-run-gate/v1"
      generatedAt = (Get-Date).ToUniversalTime().ToString("o")
      classification = "pending"
      accepted = $false
      dryRunOnly = $DryRunOnly
      releaseEvidenceClosure = $false
      fullSbomApproval = $false
      cleanCloneExecuted = $false
      reasons = [ordered]@{
        accepted = @($acceptedReasons.ToArray())
        blocked = @($blockedReasons.ToArray())
        pending = @($pendingReasons.ToArray())
      }
      readback = $readback
      currentPlan = $CurrentPlan
      operatorActions = @(
        "Run clean-clone transcript in a fresh checkout.",
        "Run full SBOM/release evidence review with the release owner's selected toolchain.",
        "Treat this dry-run gate as readback only; it does not approve release evidence."
      )
    }
  }

  if (-not [System.IO.Path]::IsPathRooted($TemplatePath)) {
    $TemplatePath = Join-Path $script:RepoRoot $TemplatePath
  }

  if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
    Add-GateReason -List $pendingReasons -Code "manifest_template_missing" -Message "Freshness template is not present; write it with -Plan -WriteManifestTemplate before checking."
    $readback.templatePath = Get-RepoRelativePath $TemplatePath
    return [ordered]@{
      schemaVersion = "manifest-freshness-dry-run-gate/v1"
      generatedAt = (Get-Date).ToUniversalTime().ToString("o")
      classification = "pending"
      accepted = $false
      dryRunOnly = $DryRunOnly
      releaseEvidenceClosure = $false
      fullSbomApproval = $false
      cleanCloneExecuted = $false
      reasons = [ordered]@{
        accepted = @($acceptedReasons.ToArray())
        blocked = @($blockedReasons.ToArray())
        pending = @($pendingReasons.ToArray())
      }
      readback = $readback
      currentPlan = $CurrentPlan
      operatorActions = @(
        "Run clean-clone transcript in a fresh checkout.",
        "Run full SBOM/release evidence review with the release owner's selected toolchain.",
        "Treat this dry-run gate as readback only; it does not approve release evidence."
      )
    }
  }

  $template = (Get-Content -LiteralPath $TemplatePath -Raw) | ConvertFrom-Json -ErrorAction Stop
  $readback.templatePath = Get-RepoRelativePath $TemplatePath
  $readback.templateSchemaVersion = [string]$template.schemaVersion

  if (-not [string]::Equals([string]$template.schemaVersion, [string]$CurrentPlan.schemaVersion, [System.StringComparison]::Ordinal)) {
    Add-GateReason -List $blockedReasons -Code "schema_version_mismatch" -Message ("Template schema '{0}' does not match current plan schema '{1}'." -f [string]$template.schemaVersion, [string]$CurrentPlan.schemaVersion)
  }

  $readback.requiredArtifacts = Compare-StringSets `
    -Name "required_artifacts" `
    -Expected @($CurrentPlan.requiredArtifacts | ForEach-Object { [string]$_.path }) `
    -Actual @($template.requiredArtifacts | ForEach-Object { [string]$_.path }) `
    -BlockedReasons $blockedReasons

  $readback.sourceFiles = Compare-StringSets `
    -Name "source_files" `
    -Expected @($CurrentPlan.sourceFiles) `
    -Actual @($template.sourceFiles) `
    -BlockedReasons $blockedReasons

  $currentGroupNames = @(Get-ObjectPropertyNames $CurrentPlan.sourceFileGroups)
  $templateGroupNames = @(Get-ObjectPropertyNames $template.sourceFileGroups)
  $readback.sourceFileGroups.groupNames = Compare-StringSets `
    -Name "source_file_group_names" `
    -Expected $currentGroupNames `
    -Actual $templateGroupNames `
    -BlockedReasons $blockedReasons

  foreach ($groupName in $currentGroupNames) {
    $currentValues = @(Get-ObjectPropertyValue -Object $CurrentPlan.sourceFileGroups -Name $groupName)
    $templateValues = if ($templateGroupNames -contains $groupName) { @(Get-ObjectPropertyValue -Object $template.sourceFileGroups -Name $groupName) } else { @() }
    $readback.sourceFileGroups[$groupName] = Compare-StringSets `
      -Name ("source_file_group_{0}" -f $groupName) `
      -Expected $currentValues `
      -Actual $templateValues `
      -BlockedReasons $blockedReasons
  }

  $readback.stalenessRules = Compare-StringSets `
    -Name "staleness_rules" `
    -Expected @($CurrentPlan.stalenessRules | ForEach-Object { [string]$_.id }) `
    -Actual @($template.stalenessRules | ForEach-Object { [string]$_.id }) `
    -BlockedReasons $blockedReasons

  if ($blockedReasons.Count -eq 0) {
    Add-GateReason -List $acceptedReasons -Code "manifest_freshness_contract_matches" -Message "Template matches the current required artifacts, source files, source groups, and staleness rule ids."
  }

  $classification = if ($blockedReasons.Count -gt 0) { "blocked" } elseif ($pendingReasons.Count -gt 0) { "pending" } else { "accepted" }
  return [ordered]@{
    schemaVersion = "manifest-freshness-dry-run-gate/v1"
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    classification = $classification
    accepted = ($classification -eq "accepted")
    dryRunOnly = $DryRunOnly
    releaseEvidenceClosure = $false
    fullSbomApproval = $false
    cleanCloneExecuted = $false
    reasons = [ordered]@{
      accepted = @($acceptedReasons.ToArray())
      blocked = @($blockedReasons.ToArray())
      pending = @($pendingReasons.ToArray())
    }
    readback = $readback
    currentPlan = $CurrentPlan
    operatorActions = @(
      "Run clean-clone transcript in a fresh checkout.",
      "Run full SBOM/release evidence review with the release owner's selected toolchain.",
      "Treat this dry-run gate as readback only; it does not approve release evidence."
    )
  }
}

$resolvedOutput = $OutputDirectory
if (-not [System.IO.Path]::IsPathRooted($resolvedOutput)) {
  $resolvedOutput = Join-Path $script:RepoRoot $resolvedOutput
}
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$trackedFiles = @(Get-RepositoryFiles -Names @("Cargo.lock", "package-lock.json", "npm-shrinkwrap.json") | Sort-Object { Get-RepoRelativePath $_ })
$containerFiles = @(Get-RepositoryFilesMatching -NamePatterns @("Dockerfile", "*.Dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml") | Sort-Object { Get-RepoRelativePath $_ })
$ciFiles = @()
$githubWorkflows = Join-Path $script:RepoRoot ".github/workflows"
if (Test-Path -LiteralPath $githubWorkflows) {
  $ciFiles = @(Get-ChildItem -LiteralPath $githubWorkflows -File | Where-Object { $_.Name -match '\.ya?ml$' } | ForEach-Object { $_.FullName } | Sort-Object { Get-RepoRelativePath $_ })
}

$components = New-Object System.Collections.Generic.List[object]
foreach ($lock in @($trackedFiles | Where-Object { [System.IO.Path]::GetFileName($_) -eq "Cargo.lock" })) {
  foreach ($component in @(Get-CargoComponents $lock)) {
    [void]$components.Add($component)
  }
}
foreach ($lock in @($trackedFiles | Where-Object {
  $name = [System.IO.Path]::GetFileName($_)
  $name -eq "package-lock.json" -or $name -eq "npm-shrinkwrap.json"
})) {
  foreach ($component in @(Get-NpmComponents $lock)) {
    [void]$components.Add($component)
  }
}
foreach ($component in @(Get-ContainerComponents $containerFiles)) {
  [void]$components.Add($component)
}

$startedAt = (Get-Date).ToUniversalTime().ToString("o")
$materials = Get-Materials (@($trackedFiles) + @($containerFiles) + @($ciFiles) + @(Join-Path $script:RepoRoot "scripts/scan_supply_chain.ps1"))
$cargoLockContractFiles = @(Get-RelativePaths @($trackedFiles | Where-Object { [System.IO.Path]::GetFileName($_) -eq "Cargo.lock" }))
$npmLockContractFiles = @(Get-RelativePaths @($trackedFiles | Where-Object {
  $name = [System.IO.Path]::GetFileName($_)
  $name -eq "package-lock.json" -or $name -eq "npm-shrinkwrap.json"
}))
$containerContractFiles = @(Get-RelativePaths $containerFiles)
$ciContractFiles = @(Get-RelativePaths $ciFiles)
$sbomPath = Join-Path $resolvedOutput "sbom.cyclonedx.json"
$provenancePath = Join-Path $resolvedOutput "provenance.intoto.json"
$summaryPath = Join-Path $resolvedOutput "manifest.json"
$checksumsPath = Join-Path $resolvedOutput "SHA256SUMS"

if ($Plan -or $DryRunGate -or -not [string]::IsNullOrWhiteSpace($CheckManifestFreshness)) {
  $planObject = New-ManifestFreshnessPlan `
    -OutputDirectoryPath $resolvedOutput `
    -TrackedFiles $trackedFiles `
    -ContainerFiles $containerFiles `
    -CiFiles $ciFiles

  if (-not [string]::IsNullOrWhiteSpace($WriteManifestTemplate)) {
    $resolvedTemplatePath = $WriteManifestTemplate
    if (-not [System.IO.Path]::IsPathRooted($resolvedTemplatePath)) {
      $resolvedTemplatePath = Join-Path $script:RepoRoot $resolvedTemplatePath
    }
    $templateParent = Split-Path -Parent $resolvedTemplatePath
    if (-not [string]::IsNullOrWhiteSpace($templateParent)) {
      New-Item -ItemType Directory -Force -Path $templateParent | Out-Null
    }
    Write-JsonArtifact -Path $resolvedTemplatePath -Object $planObject
  }

  if ($DryRunGate -or -not [string]::IsNullOrWhiteSpace($CheckManifestFreshness)) {
    $gateObject = Test-ManifestFreshness `
      -CurrentPlan $planObject `
      -TemplatePath $CheckManifestFreshness `
      -DryRunOnly $true

    Write-Output ($gateObject | ConvertTo-Json -Depth 24)
    if ([string]$gateObject.classification -eq "blocked") {
      exit 2
    }
    exit 0
  }

  Write-Output ($planObject | ConvertTo-Json -Depth 20)
  exit 0
}

$sbom = [ordered]@{
  bomFormat = "CycloneDX"
  specVersion = "1.5"
  serialNumber = ("urn:uuid:{0}" -f ([guid]::NewGuid().ToString()))
  version = 1
  metadata = [ordered]@{
    timestamp = $startedAt
    tools = @([ordered]@{ vendor = "ai-gateway"; name = "generate_supply_chain_artifacts.ps1"; version = "0.1" })
    component = [ordered]@{
      type = "application"
      name = "ai-gateway"
      version = "0.1-dev-start"
    }
  }
  components = @($components.ToArray())
}
Write-JsonArtifact -Path $sbomPath -Object $sbom

$subject = New-Object System.Collections.Generic.List[object]
[void]$subject.Add([ordered]@{
  name = "sbom.cyclonedx.json"
  digest = [ordered]@{ sha256 = Get-Sha256Digest $sbomPath }
})

$imageIdFileParameter = ""
if (-not [string]::IsNullOrWhiteSpace($ImageIdFile)) {
  $imageIdFileParameter = $ImageIdFile
  $resolvedImageIdFile = $ImageIdFile
  if (-not [System.IO.Path]::IsPathRooted($resolvedImageIdFile)) {
    $resolvedImageIdFile = Join-Path $script:RepoRoot $resolvedImageIdFile
  }
  if (Test-Path -LiteralPath $resolvedImageIdFile -PathType Leaf) {
    $imageId = (Get-Content -LiteralPath $resolvedImageIdFile -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($imageId)) {
      [void]$subject.Add([ordered]@{
        name = "container-image-id"
        digest = [ordered]@{ sha256 = Get-Sha256Digest $resolvedImageIdFile }
      })
    }
  }
}

$finishedAt = (Get-Date).ToUniversalTime().ToString("o")
$provenance = [ordered]@{
  "_type" = "https://in-toto.io/Statement/v1"
  subject = @($subject.ToArray())
  predicateType = "https://slsa.dev/provenance/v1"
  predicate = [ordered]@{
    buildDefinition = [ordered]@{
      buildType = "https://ai-gateway.local/supply-chain-artifacts/v1"
      externalParameters = [ordered]@{
        contractVersion = "supply-chain-artifacts/v1"
        offline = $true
        outputDirectory = (Get-RepoRelativePath $resolvedOutput)
        imageIdFile = $imageIdFileParameter
      }
      internalParameters = [ordered]@{}
      resolvedDependencies = $materials
    }
    runDetails = [ordered]@{
      builder = [ordered]@{ id = "ai-gateway:scripts/generate_supply_chain_artifacts.ps1" }
      metadata = [ordered]@{
        invocationId = ([guid]::NewGuid().ToString())
        startedOn = $startedAt
        finishedOn = $finishedAt
      }
    }
  }
}
Write-JsonArtifact -Path $provenancePath -Object $provenance

$offlineContract = [ordered]@{
  kind = "supply-chain-offline-dry-run"
  version = 1
  requiredArtifacts = @("sbom.cyclonedx.json", "provenance.intoto.json", "manifest.json", "SHA256SUMS")
  coveredInputs = [ordered]@{
    cargoLockFiles = $cargoLockContractFiles
    npmLockFiles = $npmLockContractFiles
    containerFiles = $containerContractFiles
    ciWorkflowFiles = $ciContractFiles
  }
  localMissingToolPolicy = "Missing Docker, trivy, grype, cargo-audit, or npm audit is warning/skip in the offline dry-run contract."
  remainingGaps = @(
    "digest pinning is inspected but not enforced",
    "network-backed vulnerability scanning is skipped in offline dry-run mode",
    "real built image vulnerability scanning is not performed by this artifact generator"
  )
}

$summary = [ordered]@{
  schemaVersion = "supply-chain-artifacts/v1"
  generatedAt = $finishedAt
  contract = $offlineContract
  artifacts = @(
    [ordered]@{ path = "sbom.cyclonedx.json"; sha256 = Get-Sha256Digest $sbomPath },
    [ordered]@{ path = "provenance.intoto.json"; sha256 = Get-Sha256Digest $provenancePath }
  )
  counts = [ordered]@{
    components = $components.Count
    materials = $materials.Count
  }
}
Write-JsonArtifact -Path $summaryPath -Object $summary

$checksumLines = New-Object System.Collections.Generic.List[string]
foreach ($artifact in @(Get-ChildItem -LiteralPath $resolvedOutput -File | Where-Object { $_.Name -ne "SHA256SUMS" } | Sort-Object Name)) {
  [void]$checksumLines.Add(("{0}  {1}" -f (Get-Sha256Digest $artifact.FullName), $artifact.Name))
}
Write-Utf8NoBomFile -Path $checksumsPath -Content (($checksumLines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine)

Write-Host ("[OK] generated supply-chain artifacts: {0}" -f (Get-RepoRelativePath $resolvedOutput))
Write-Host ("[OK] components={0}, materials={1}" -f $components.Count, $materials.Count)
