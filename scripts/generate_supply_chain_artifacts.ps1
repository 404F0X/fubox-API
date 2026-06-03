#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$OutputDirectory,
  [string]$ImageIdFile
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
