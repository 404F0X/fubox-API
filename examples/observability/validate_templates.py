#!/usr/bin/env python3
"""Validate observability example templates without requiring promtool."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
REPO_ROOT = ROOT.parents[1]
DASHBOARD_PATH = ROOT / "grafana" / "ai-gateway-overview.dashboard.json"
RULES_PATH = ROOT / "prometheus" / "ai-gateway-alerts.rules.yml"
OBSERVABILITY_LIB = REPO_ROOT / "crates" / "observability" / "src" / "lib.rs"

METRIC_LABELS = {
    "ai_gateway_service_up": {"service"},
    "ai_gateway_requests_total": {
        "service",
        "endpoint",
        "method",
        "status",
        "status_class",
        "outcome",
    },
    "ai_gateway_errors_total": {
        "service",
        "endpoint",
        "method",
        "status",
        "status_class",
        "owner",
        "code",
        "retryable",
    },
    "ai_gateway_request_latency_ms_bucket": {
        "service",
        "endpoint",
        "method",
        "status_class",
        "outcome",
        "le",
    },
    "ai_gateway_request_latency_ms_sum": {
        "service",
        "endpoint",
        "method",
        "status_class",
        "outcome",
    },
    "ai_gateway_request_latency_ms_count": {
        "service",
        "endpoint",
        "method",
        "status_class",
        "outcome",
    },
    "ai_gateway_request_ttft_ms_bucket": {
        "service",
        "endpoint",
        "method",
        "status",
        "status_class",
        "outcome",
        "error_owner",
        "error_code",
        "le",
    },
    "ai_gateway_request_ttft_ms_sum": {
        "service",
        "endpoint",
        "method",
        "status",
        "status_class",
        "outcome",
        "error_owner",
        "error_code",
    },
    "ai_gateway_request_ttft_ms_count": {
        "service",
        "endpoint",
        "method",
        "status",
        "status_class",
        "outcome",
        "error_owner",
        "error_code",
    },
    "ai_gateway_fallbacks_total": {"service", "endpoint", "method", "reason"},
    "ai_gateway_request_cost_total": {"service", "endpoint", "method", "currency"},
}

RUNTIME_METRIC_STRINGS = {
    "ai_gateway_service_up",
    "ai_gateway_requests_total",
    "ai_gateway_errors_total",
    "ai_gateway_request_latency_ms",
    "ai_gateway_request_ttft_ms",
    "ai_gateway_fallbacks_total",
    "ai_gateway_request_cost_total",
}

PENDING_OR_STALE_METRICS = {
    "ai_gateway_request_duration_ms",
    "ai_gateway_request_duration_ms_bucket",
    "ai_gateway_ttft_ms",
    "ai_gateway_ttft_ms_bucket",
    "ai_gateway_ttft_ms_sum",
    "ai_gateway_ttft_ms_count",
    "ai_gateway_cost_total",
    "ai_gateway_ledger_events_total",
    "ai_gateway_key_cooldowns_total",
    "ai_gateway_provider_requests_total",
    "ai_gateway_provider_request_latency_ms",
    "ai_gateway_provider_request_latency_ms_bucket",
}

PENDING_PANEL_TITLES = {
    "Ledger Lag (pending)",
    "Event Lag (pending)",
    "Key Cooldown (pending)",
    "Provider Dimensions (pending)",
}

PENDING_PLACEHOLDER_EXPR = "vector(0) unless vector(0)"

METRIC_RE = re.compile(r"\bai_gateway_[A-Za-z0-9_:]+\b")
BY_RE = re.compile(r"\b(?:by|without)\s*\(([^)]*)\)")
SELECTOR_RE = re.compile(r"\b(ai_gateway_[A-Za-z0-9_:]+)\s*\{([^{}]*)\}")
LABEL_MATCH_RE = re.compile(r"\b([A-Za-z_:][A-Za-z0-9_:]*)\s*(?:!?=|=~|!~)")
LEGEND_LABEL_RE = re.compile(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")
ANNOTATION_LABEL_RE = re.compile(r"\$labels\.([A-Za-z_][A-Za-z0-9_]*)")


def main() -> int:
    errors: list[str] = []

    dashboard = load_dashboard(errors)
    rules = load_rules(errors)
    validate_runtime_contract(errors)

    if dashboard is not None:
        validate_dashboard(dashboard, errors)

    if rules is not None:
        validate_rules(rules, errors)

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("observability templates validated")
    return 0


def load_dashboard(errors: list[str]) -> dict[str, Any] | None:
    try:
        return json.loads(DASHBOARD_PATH.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 - validation should report any parse failure.
        errors.append(f"{DASHBOARD_PATH} is not valid JSON: {exc}")
        return None


def load_rules(errors: list[str]) -> dict[str, Any] | None:
    raw = RULES_PATH.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore[import-not-found]
    except ModuleNotFoundError:
        print("warning: PyYAML is not installed; using a basic rules-file fallback")
        if not raw.lstrip().startswith("groups:"):
            errors.append(f"{RULES_PATH} does not start with a Prometheus groups document")
            return None
        return {
            "groups": [
                {
                    "name": "fallback",
                    "rules": [
                        {"alert": alert, "expr": expr}
                        for alert, expr in extract_rule_expr_blocks(raw)
                    ],
                }
            ]
        }

    try:
        loaded = yaml.safe_load(raw)
    except Exception as exc:  # noqa: BLE001 - validation should report any parse failure.
        errors.append(f"{RULES_PATH} is not valid YAML: {exc}")
        return None

    if not isinstance(loaded, dict):
        errors.append(f"{RULES_PATH} must parse to a YAML mapping")
        return None

    return loaded


def extract_rule_expr_blocks(raw: str) -> list[tuple[str, str]]:
    blocks: list[tuple[str, str]] = []
    current_alert: str | None = None
    lines = raw.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        alert_match = re.match(r"\s*-\s+alert:\s+(.+?)\s*$", line)
        if alert_match:
            current_alert = alert_match.group(1)
        if current_alert and re.match(r"\s*expr:\s*\|\s*$", line):
            index += 1
            expr_lines: list[str] = []
            while index < len(lines) and re.match(r"\s{10,}\S|\s*$", lines[index]):
                expr_lines.append(lines[index].strip())
                index += 1
            blocks.append((current_alert, "\n".join(expr_lines)))
            continue
        index += 1
    return blocks


def validate_runtime_contract(errors: list[str]) -> None:
    try:
        source = OBSERVABILITY_LIB.read_text(encoding="utf-8")
    except FileNotFoundError:
        errors.append(f"runtime metrics source not found: {OBSERVABILITY_LIB}")
        return

    for metric in sorted(RUNTIME_METRIC_STRINGS):
        if metric not in source:
            errors.append(f"{OBSERVABILITY_LIB} no longer contains expected metric {metric}")


def validate_dashboard(dashboard: dict[str, Any], errors: list[str]) -> None:
    panels = dashboard.get("panels")
    if not isinstance(panels, list) or not panels:
        errors.append(f"{DASHBOARD_PATH} has no panels")
        return

    titles = {str(panel.get("title", "")) for panel in panels if isinstance(panel, dict)}
    missing_pending = PENDING_PANEL_TITLES - titles
    if missing_pending:
        errors.append(f"dashboard is missing pending panel titles: {sorted(missing_pending)}")

    for panel in panels:
        if not isinstance(panel, dict):
            errors.append("dashboard panel is not a JSON object")
            continue
        title = str(panel.get("title", "<untitled>"))
        is_pending_panel = title in PENDING_PANEL_TITLES
        description = str(panel.get("description", ""))
        if is_pending_panel and "Pending:" not in description:
            errors.append(f"dashboard panel {title} must describe its pending metric contract")
        targets = panel.get("targets", [])
        if not isinstance(targets, list):
            errors.append(f"dashboard panel {title} targets must be a list")
            continue
        for target in targets:
            if not isinstance(target, dict):
                errors.append(f"dashboard panel {title} target is not a JSON object")
                continue
            ref_id = target.get("refId", "?")
            expr = target.get("expr")
            if isinstance(expr, str):
                context = f"dashboard panel {title} target {ref_id}"
                if is_pending_panel and expr.strip() != PENDING_PLACEHOLDER_EXPR:
                    errors.append(
                        f"{context} must use the no-series pending placeholder query"
                    )
                validate_expr(context, expr, errors)
                validate_template_labels(
                    f"{context} legendFormat",
                    str(target.get("legendFormat", "")),
                    referenced_label_union(expr),
                    errors,
                    LEGEND_LABEL_RE,
                )


def validate_rules(rules_doc: dict[str, Any], errors: list[str]) -> None:
    groups = rules_doc.get("groups")
    if not isinstance(groups, list) or not groups:
        errors.append(f"{RULES_PATH} has no rule groups")
        return

    for group in groups:
        if not isinstance(group, dict):
            errors.append("rule group is not a YAML mapping")
            continue
        rules = group.get("rules")
        group_name = group.get("name", "<unnamed>")
        if not isinstance(rules, list) or not rules:
            errors.append(f"rule group {group_name} has no rules")
            continue
        for rule in rules:
            if not isinstance(rule, dict):
                errors.append(f"rule group {group_name} contains a non-mapping rule")
                continue
            alert = str(rule.get("alert", "<unnamed>"))
            expr = rule.get("expr")
            if not isinstance(expr, str) or not expr.strip():
                errors.append(f"alert {alert} has no expression")
                continue
            context = f"alert {alert}"
            validate_expr(context, expr, errors)
            allowed_labels = referenced_label_union(expr)
            annotations = rule.get("annotations", {})
            if isinstance(annotations, dict):
                for key, value in annotations.items():
                    validate_template_labels(
                        f"{context} annotation {key}",
                        str(value),
                        allowed_labels,
                        errors,
                        ANNOTATION_LABEL_RE,
                    )


def validate_expr(context: str, expr: str, errors: list[str]) -> None:
    metrics = sorted(set(METRIC_RE.findall(expr)))
    for metric in metrics:
        if metric not in METRIC_LABELS:
            if metric in PENDING_OR_STALE_METRICS:
                errors.append(f"{context} references pending/stale metric {metric}")
            else:
                errors.append(f"{context} references unknown metric {metric}")

    allowed_labels = referenced_label_union(expr)
    for labels in BY_RE.findall(expr):
        for label in split_labels(labels):
            if label not in allowed_labels:
                errors.append(f"{context} groups by unsupported label {label}")

    for metric, labels in SELECTOR_RE.findall(expr):
        metric_allowed_labels = METRIC_LABELS.get(metric, set())
        for label in LABEL_MATCH_RE.findall(labels):
            if label not in metric_allowed_labels:
                errors.append(f"{context} filters {metric} by unsupported label {label}")


def referenced_label_union(expr: str) -> set[str]:
    allowed: set[str] = set()
    for metric in METRIC_RE.findall(expr):
        allowed.update(METRIC_LABELS.get(metric, set()))
    return allowed


def validate_template_labels(
    context: str,
    template: str,
    allowed_labels: set[str],
    errors: list[str],
    pattern: re.Pattern[str],
) -> None:
    for label in pattern.findall(template):
        if label not in allowed_labels:
            errors.append(f"{context} references unsupported label {label}")


def split_labels(raw: str) -> list[str]:
    return [label.strip() for label in raw.split(",") if label.strip()]


if __name__ == "__main__":
    raise SystemExit(main())
