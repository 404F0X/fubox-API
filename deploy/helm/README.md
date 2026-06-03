# Fubox API Helm Chart

Minimal chart for deploying the gateway, control plane, admin UI, and mock provider.
PostgreSQL and Redis are expected to be managed outside this chart and injected through Kubernetes Secrets.

## Required Values

- `database.secretRef.name`: Secret exposed to gateway and control-plane with database connection environment variables, for example `DATABASE_URL`.
- `redis.secretRef.name`: Secret exposed to gateway and control-plane with Redis connection environment variables, for example `REDIS_URL`.
- `application.secretRef.name`: Secret exposed to gateway and control-plane with application secrets such as `AI_GATEWAY_MASTER_KEY` and `AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64`.
- `services.*.image.repository` and `services.*.image.tag`: image coordinates for each component.
- `services.admin-ui.env.*_UPSTREAM`: internal service origins used by the admin UI reverse proxy. Browser API calls stay same-origin under `/api/*`.
- `global.config.*`: non-secret runtime ConfigMap content mounted by backend services that set `configMapRef=true`. Keep database, Redis, and application secrets in the external Secrets above, not in the ConfigMap.

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
  --from-literal=AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64='replace-with-32-byte-base64-key'
```

Enable ingress with `ingress.enabled=true` and set `ingress.className`, `ingress.hosts`, and `ingress.tls` for the target cluster.
The default `/` ingress path can point at `admin-ui`; the admin UI image serves the static app and proxies `/api/gateway/*`, `/api/control-plane/*`, and `/api/mock-provider/*` to the in-cluster services.
