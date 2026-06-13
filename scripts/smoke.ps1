param(
    [switch]$StartCompose,
    [int]$ComposeTimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$alphaSmoke = Join-Path $root "scripts\alpha_smoke.ps1"

if (-not (Test-Path $alphaSmoke)) {
    throw "Missing alpha smoke script: $alphaSmoke"
}

$argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $alphaSmoke)
if ($StartCompose) {
    $argsList += "-StartCompose"
    $argsList += "-ComposeTimeoutSeconds"
    $argsList += $ComposeTimeoutSeconds
}

& pwsh @argsList
