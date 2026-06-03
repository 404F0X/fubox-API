$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

Invoke-Docker compose -f deploy/docker-compose/docker-compose.yml up --build -d
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
