# Fubox API Helm Chart

Minimal chart for deploying the gateway, control plane, admin UI, worker seam, and mock provider.
PostgreSQL, Redis, ClickHouse, provider adapter credentials, and payment provider credentials are expected to be managed outside this chart and injected through Kubernetes Secrets.

## Required Values

- `database.secretRef.name`: Secret exposed to gateway, control-plane, worker, and jobs with database connection environment variables, for example `DATABASE_URL`.
- `redis.secretRef.name`: Secret exposed to gateway, control-plane, worker, and jobs with Redis connection environment variables, for example `REDIS_URL`.
- `application.secretRef.name`: Secret exposed to backend workloads with application secrets such as `AI_GATEWAY_MASTER_KEY`, `AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64`, and `AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID`.
- `clickhouse.secretRef.name`: Optional staging Secret for worker/read-model observability config such as `AI_GATEWAY_CLICKHOUSE_ENDPOINT`, `AI_GATEWAY_CLICKHOUSE_DATABASE`, `AI_GATEWAY_CLICKHOUSE_TABLE`, `AI_GATEWAY_CLICKHOUSE_USERNAME`, and `AI_GATEWAY_CLICKHOUSE_PASSWORD`.
- `provider.secretRef.name`: Optional staging Secret for provider adapter credentials and non-browser upstream integration env. Do not put provider key plaintext into ConfigMaps or admin-ui env.
- `payment.secretRef.name`: Optional staging Secret for real payment adapter credentials, merchant/account identifiers, and webhook signing material.
- `services.*.image.repository` and `services.*.image.tag`: image coordinates for each component.
- `services.admin-ui.env.*_UPSTREAM`: internal service origins used by the admin UI reverse proxy. Browser API calls stay same-origin under `/api/*`.
- `global.config.*`: non-secret runtime ConfigMap content mounted by backend services that set `configMapRef=true`. It carries staging presence markers for trusted proxy, IP allowlist, CORS, rate limit, ClickHouse, provider, and payment setup. Keep database, Redis, ClickHouse credentials, provider secrets, payment secrets, and application secrets in the external Secrets above, not in the ConfigMap.
- `services.gateway.env` / `services.control-plane.env` / `services.worker.env`: required per-component env seam. The default values intentionally use `config-needed` markers for staging security knobs until an operator supplies cluster-specific proxy CIDRs, CORS origins, allowlists, and rate-limit policy.
- `jobs.recoveryProbe.enabled`: defaults to `false`. Set it only for a manual operator run of `ai-worker recovery-probe --execute`; the Job reads `AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64` from `application.secretRef.name`.

Do not set `VITE_*`, `REACT_APP_*`, or `NEXT_PUBLIC_*` values in Helm values for the admin UI. Those are build-time/browser-visible frontend variables; this chart keeps the default admin UI runtime configuration server-side through nginx upstream environment variables.

## Validate

Run the chart validation script before staging deploys:

```powershell
python deploy\helm\validate_chart.py
```

The script performs static checks for required Secret references, non-secret ConfigMap structure, image coordinates, ports, probes, resources, security contexts, service/ingress references, backend config mounts, and admin UI frontend env exposure. If `helm` is installed it also runs `helm lint` and `helm template`; if `helm` is not installed it prints a warning and keeps the static validation result.

Run the local contract self-test when changing chart validation rules:

```powershell
python deploy\helm\validate_chart.py --skip-helm --self-test
```

Generate the staging smoke/security plan seam without deploying or reading
Secret values:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\plan_staging_smoke_security.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\plan_staging_smoke_security.ps1 -WriteFile
```

The plan output uses `staging-smoke-security-plan/v1` and lists the operator
smoke order, security presence checks, target services, load/chaos plan
placeholders, required Secret/env presence, resource guards, rollback criteria,
forbidden output categories, and expected summaries. It is presence-only: it
must not print database URLs, provider credentials, payment secrets, tokens,
Authorization headers, or raw payloads.

The same plan also includes a `securityReviewChecklist` and
`securityReadbackContract` for the next operator review pass. The checklist
covers CORS origins, IP allowlist, trusted proxy boundaries, Secret refs,
Redis-backed rate limit policy, metadata-only payload policy, provider adapter
config presence, payment adapter config presence, and ClickHouse config
presence. The readback contract is intentionally status-only: it records
`not-run`, `config-needed`, `reviewed`, `follow-up-required`, or `pass` after a
real review, but it must not include secret values, tokens, DB URLs, provider or
payment secrets, Authorization headers, or raw payloads.

The plan also includes `targetServices`, `trafficModels`, `resourceGuards`,
`rollbackCriteria`, `loadReadbackContract`, `chaosExperiments`,
`chaosReadbackContract`, and `expectedSafeOutputs`. These define what a future
operator should review for bounded staging baselines and chaos drills: gateway,
control-plane, admin-ui, worker, mock-provider, Redis, Postgres, and ClickHouse
surfaces; low-volume traffic models; stop/rollback triggers; and safe readback
fields. They do not run load, inject faults, call providers, or create release
evidence.

## Install

Render locally:

```powershell
helm template fubox ./deploy/helm
```

Install or upgrade:

```powershell
helm upgrade --install fubox ./deploy/helm `
  --namespace fubox `
  --create-namespace `
  --set application.secretRef.name=fubox-app-secrets `
  --set database.secretRef.name=fubox-postgresql `
  --set redis.secretRef.name=fubox-redis
```

Create the external connection Secrets before installing:

```powershell
kubectl create secret generic fubox-postgresql `
  --from-literal=DATABASE_URL='postgres://user:password@postgres.example:5432/ai_gateway'

kubectl create secret generic fubox-redis `
  --from-literal=REDIS_URL='redis://redis.example:6379/0'

kubectl create secret generic fubox-app-secrets `
  --from-literal=AI_GATEWAY_MASTER_KEY='replace-with-random-master-key' `
  --from-literal=AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64='replace-with-32-byte-base64-key' `
  --from-literal=AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID='staging-v1'

kubectl create secret generic fubox-clickhouse `
  --from-literal=AI_GATEWAY_CLICKHOUSE_ENDPOINT='https://clickhouse.example.invalid:8123' `
  --from-literal=AI_GATEWAY_CLICKHOUSE_DATABASE='ai_gateway' `
  --from-literal=AI_GATEWAY_CLICKHOUSE_TABLE='gateway_events' `
  --from-literal=AI_GATEWAY_CLICKHOUSE_USERNAME='replace-with-user' `
  --from-literal=AI_GATEWAY_CLICKHOUSE_PASSWORD='replace-with-password'

kubectl create secret generic fubox-provider-secrets `
  --from-literal=AI_GATEWAY_PROVIDER_ADAPTER_STATUS='config-needed'

kubectl create secret generic fubox-payment-secrets `
  --from-literal=AI_GATEWAY_PAYMENT_PROVIDER_STATUS='config-needed'
```

Enable ingress with `ingress.enabled=true` and set `ingress.className`, `ingress.hosts`, and `ingress.tls` for the target cluster.
The default `/` ingress path can point at `admin-ui`; the admin UI image serves the static app and proxies `/api/gateway/*`, `/api/control-plane/*`, and `/api/mock-provider/*` to the in-cluster services.

## Staging Config Seam

This chart now renders a staging-ready configuration seam, not a release evidence loop:

- Gateway: mounts application/database/Redis/ClickHouse/provider Secrets, the runtime ConfigMap, CORS env, trusted proxy/IP allowlist/rate-limit presence markers, and provider endpoint safety env.
- Control plane: mounts application/database/Redis/ClickHouse/provider/payment Secrets, the runtime ConfigMap, CORS env, trusted proxy/IP allowlist/rate-limit presence markers, and payment provider presence markers.
- Worker: is present as a disabled-by-default deployment seam with the same backend Secret refs plus ClickHouse/provider/payment presence env. Enable `services.worker.enabled=true` only after choosing a concrete worker command/health model for the target staging cluster.
- Security knobs: `trusted_proxy_allowlist`, IP allowlist policy, CORS origins, and rate-limit store are placeholders in `global.config.content` / workload env. Replace `.example.invalid` origins and empty allowlists with cluster-specific values before any shared staging exposure.
- Staging plan: `stagingPlan` records the dry-run smoke/security order, security review checklist ids, target services, traffic model ids, resource guard ids, rollback criteria, load/chaos placeholders, chaos experiment ids, and expected safe output ids in values. `scripts/plan_staging_smoke_security.ps1` emits the operator-facing JSON plan/readback contract with the detailed load/chaos seam. The plan does not run load or chaos.

The remaining real work is to run operator staging smoke, load, chaos, and security review after real infra, CIDRs, provider sandbox credentials, payment sandbox credentials, and ClickHouse are available. Do not treat the plan JSON as release evidence.

## Manual Recovery Probe

The chart does not run provider-key recovery automatically. To trigger one bounded operator run, keep the application Secret populated with `AI_GATEWAY_MASTER_KEY` and `AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64`, then render or install with the Job enabled:

```powershell
helm template fubox ./deploy/helm `
  --set jobs.recoveryProbe.enabled=true `
  --set application.secretRef.name=fubox-app-secrets `
  --set database.secretRef.name=fubox-postgresql `
  --set redis.secretRef.name=fubox-redis
```

Optionally override `jobs.recoveryProbe.args` to add `--tenant-id` or `--limit`. Do not enable this Job in a default release pipeline unless an operator explicitly intends to run recovery.
