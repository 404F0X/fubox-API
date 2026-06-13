# Open-source Alpha Clean-clone/CI Transcript Template

Purpose: record the real clean-clone or hosted CI replay required before a public Open-source Alpha tag. This template is not proof by itself. Fill it only after the commands below ran outside the current dirty workspace or in hosted CI.

Do not include raw Authorization headers, admin session tokens, virtual-key secrets, voucher codes, database URLs, or passwords.

## Required transcript artifact

Write the secret-safe JSON transcript to:

```text
.tmp/open-source-alpha/clean_clone_ci_transcript.json
```

Minimum accepted fields:

```json
{
  "status": "pass",
  "clean_clone": true,
  "ci_or_clean_environment": true,
  "secret_safe": true,
  "repo_url_redacted": true,
  "commit_sha": "<commit-sha>",
  "environment": "<hosted-ci-or-clean-local-host>",
  "started_at_utc": "<iso-8601>",
  "finished_at_utc": "<iso-8601>",
  "commands": [],
  "artifacts": [],
  "exit_codes": []
}
```

## Exact commands

Run these from a clean clone or equivalent hosted CI checkout:

```powershell
git clone <repo-url> fubox_API-clean-alpha
cd fubox_API-clean-alpha
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_readme_quickstart_contract.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\alpha_smoke.ps1 -StartCompose -ComposeTimeoutSeconds 600
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_route_level_live_http_proof.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_gate.ps1 -RunMatrix
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_clean_clone_readiness.ps1 -CleanCloneEvidencePath .tmp\open-source-alpha\clean_clone_ci_transcript.json
```

Expected public-tag result: the final readiness artifact reports `status=pass`, `ready_for_public_tag_release=true`, and `clean_clone_verified=true`.

Current local Alpha note: until this transcript exists, `scripts/verify_open_source_alpha_clean_clone_readiness.ps1` should remain `status=warn`. That warning blocks the public tag only; it does not invalidate the local code-first Alpha/API distribution pass.
