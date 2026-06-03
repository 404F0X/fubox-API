$ErrorActionPreference = "Stop"

cargo check --workspace --all-targets --all-features
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

cargo clippy --workspace --all-targets --all-features -- -D warnings
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm --prefix web/admin-ui ci
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm --prefix web/admin-ui run typecheck
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
