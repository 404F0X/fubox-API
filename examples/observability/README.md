# AI Gateway Observability Templates

This directory contains a minimal Grafana dashboard and Prometheus alert rule pack for the AI Gateway metrics currently emitted by `crates/observability/src/lib.rs`.

## Files

- `grafana/ai-gateway-overview.dashboard.json`: Grafana dashboard covering Traffic, Errors, Latency, TTFT, Fallback, Cost, and pending placeholders for Ledger Lag, Event Lag, Key Cooldown, and Provider Dimensions.
- `prometheus/ai-gateway-alerts.rules.yml`: Conservative Prometheus alerts using currently emitted gateway metric names.
- `validate_templates.py`: Lightweight local validation for dashboard JSON, alert YAML, and metric/label references.

## Grafana Import

1. Open Grafana and go to Dashboards -> New -> Import.
2. Upload `examples/observability/grafana/ai-gateway-overview.dashboard.json`.
3. Set the `DS_PROMETHEUS` datasource variable to the Prometheus datasource that scrapes the AI Gateway `/metrics` endpoint.
4. Save the dashboard after confirming the datasource mapping.

The dashboard expects the runtime request latency histogram bucket series `ai_gateway_request_latency_ms_bucket` for latency quantiles, and the request TTFT histogram series `ai_gateway_request_ttft_ms_bucket`, `ai_gateway_request_ttft_ms_sum`, and `ai_gateway_request_ttft_ms_count` for streaming time-to-first-token views.

## Prometheus Rules

Add the rules file to your Prometheus configuration, for example:

```yaml
rule_files:
  - examples/observability/prometheus/ai-gateway-alerts.rules.yml
```

Then reload Prometheus. If `promtool` is installed, validate the rules with:

```powershell
promtool check rules examples\observability\prometheus\ai-gateway-alerts.rules.yml
```

`promtool` is optional for this template. The local validator parses the dashboard JSON and rule YAML, then checks PromQL metric and label references against the current runtime contract:

```powershell
python examples\observability\validate_templates.py
```

## Current Metrics Availability

The current E10-004 runtime metrics exported by `crates/observability/src/lib.rs` are:

| Metric | Type | Labels |
| --- | --- | --- |
| `ai_gateway_service_up` | gauge | `service` |
| `ai_gateway_requests_total` | counter | `service`, `endpoint`, `method`, `status`, `status_class`, `outcome` |
| `ai_gateway_errors_total` | counter | `service`, `endpoint`, `method`, `status`, `status_class`, `owner`, `code`, `retryable` |
| `ai_gateway_request_latency_ms_bucket` / `_sum` / `_count` | histogram | `service`, `endpoint`, `method`, `status_class`, `outcome`, plus `le` on buckets |
| `ai_gateway_request_ttft_ms_bucket` / `_sum` / `_count` | histogram | `service`, `endpoint`, `method`, `status`, `status_class`, `outcome`, `error_owner`, `error_code`, plus `le` on buckets |
| `ai_gateway_fallbacks_total` | counter | `service`, `endpoint`, `method`, `reason` |
| `ai_gateway_request_cost_total` | counter | `service`, `endpoint`, `method`, `currency` |

Pending metrics and dimensions from the broader observability spec are intentionally not wired into default alert rules yet:

- Ledger/event lag metrics, such as `ai_gateway_ledger_events_total`
- Key cooldown metrics, such as `ai_gateway_key_cooldowns_total`
- Provider/channel/key/model/project/tenant dimensions on request, error, latency, fallback, cost, and TTFT metrics

The Grafana Ledger Lag, Event Lag, Key Cooldown, and Provider Dimensions panels are marked as pending placeholders and use a no-series placeholder query until those metrics or dimensions are emitted and scraped. Prometheus alert rules must remain active-only: do not reference pending metrics in `expr` fields.
