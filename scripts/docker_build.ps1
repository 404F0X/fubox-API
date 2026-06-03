$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

Invoke-Docker build -f deploy/docker-compose/Dockerfile --build-arg BIN=ai-gateway .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Invoke-Docker build -f deploy/docker-compose/Dockerfile --build-arg BIN=ai-control-plane .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Invoke-Docker build -f deploy/docker-compose/Dockerfile --build-arg BIN=ai-worker .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
