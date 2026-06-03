param(
  [switch]$Check
)

$ErrorActionPreference = "Stop"

$cargoArgs = @("fmt", "--all")
if ($Check) {
  $cargoArgs += @("--", "--check")
}

cargo @cargoArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
