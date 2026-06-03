$ErrorActionPreference = "Stop"

cargo build --workspace --all-targets --all-features
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm --prefix web/admin-ui ci
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm --prefix web/admin-ui run build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm --prefix web/admin-ui run check:bundle
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
