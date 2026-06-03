#!/usr/bin/env python3
"""Validate the Fubox Helm chart with a static fallback when Helm is absent."""

from __future__ import annotations

import argparse
import copy
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


PUBLIC_ENV_RE = re.compile(r"^(VITE_|REACT_APP_|NEXT_PUBLIC_)")
SECRET_ENV_RE = re.compile(
    r"(^|_)(secret|token|password|credential|api_key|private_key|key)($|_)",
    re.IGNORECASE,
)


class YamlParseError(ValueError):
    pass


def strip_comment(line: str) -> str:
    in_single = False
    in_double = False
    index = 0
    while index < len(line):
        char = line[index]
        if char == "'" and not in_double:
            if in_single and index + 1 < len(line) and line[index + 1] == "'":
                index += 2
                continue
            in_single = not in_single
        elif char == '"' and not in_single:
            backslashes = 0
            probe = index - 1
            while probe >= 0 and line[probe] == "\\":
                backslashes += 1
                probe -= 1
            if backslashes % 2 == 0:
                in_double = not in_double
        elif char == "#" and not in_single and not in_double:
            if index == 0 or line[index - 1].isspace():
                return line[:index].rstrip()
        index += 1
    return line.rstrip()


def split_key_value(text: str, line_no: int) -> tuple[str, str]:
    in_single = False
    in_double = False
    for index, char in enumerate(text):
        if char == "'" and not in_double:
            if in_single and index + 1 < len(text) and text[index + 1] == "'":
                continue
            in_single = not in_single
        elif char == '"' and not in_single:
            in_double = not in_double
        elif char == ":" and not in_single and not in_double:
            key = text[:index].strip()
            value = text[index + 1 :].strip()
            if not key:
                raise YamlParseError(f"line {line_no}: empty YAML key")
            return key, value
    raise YamlParseError(f"line {line_no}: expected key: value")


def has_key_value_shape(text: str) -> bool:
    try:
        split_key_value(text, 0)
    except YamlParseError:
        return False
    return True


def parse_scalar(raw: str) -> Any:
    if raw == "{}":
        return {}
    if raw == "[]":
        return []
    if raw in ("true", "True"):
        return True
    if raw in ("false", "False"):
        return False
    if raw in ("null", "Null", "~"):
        return None
    if len(raw) >= 2 and raw[0] == "'" and raw[-1] == "'":
        return raw[1:-1].replace("''", "'")
    if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return raw[1:-1]
    if re.fullmatch(r"[-+]?\d+", raw):
        return int(raw)
    return raw


def load_yaml_subset(path: Path) -> Any:
    records: list[tuple[int, str, int]] = []
    for line_no, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if raw_line.startswith("\t"):
            raise YamlParseError(f"{path}: line {line_no}: tabs are not supported")
        line = strip_comment(raw_line)
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        records.append((indent, line.strip(), line_no))
    if not records:
        return {}
    value, next_index = parse_block(records, 0, records[0][0])
    if next_index != len(records):
        _, _, line_no = records[next_index]
        raise YamlParseError(f"{path}: line {line_no}: could not parse trailing content")
    return value


def parse_block(
    records: list[tuple[int, str, int]], start: int, indent: int
) -> tuple[Any, int]:
    if start >= len(records):
        return {}, start

    current_indent, content, _ = records[start]
    if current_indent < indent:
        return {}, start
    if current_indent != indent:
        indent = current_indent

    if content.startswith("- "):
        items: list[Any] = []
        index = start
        while index < len(records):
            current_indent, content, line_no = records[index]
            if current_indent < indent:
                break
            if current_indent != indent or not content.startswith("- "):
                break

            item_text = content[2:].strip()
            index += 1
            if not item_text:
                if index < len(records) and records[index][0] > indent:
                    item, index = parse_block(records, index, records[index][0])
                else:
                    item = {}
            elif has_key_value_shape(item_text):
                key, value = split_key_value(item_text, line_no)
                item = {}
                if value:
                    item[key] = parse_scalar(value)
                elif index < len(records) and records[index][0] > indent:
                    item[key], index = parse_block(records, index, records[index][0])
                else:
                    item[key] = {}

                while index < len(records) and records[index][0] > indent:
                    nested, index = parse_block(records, index, records[index][0])
                    if not isinstance(nested, dict):
                        raise YamlParseError(
                            f"line {line_no}: expected nested mapping for list item"
                        )
                    item.update(nested)
            else:
                item = parse_scalar(item_text)
                if index < len(records) and records[index][0] > indent:
                    raise YamlParseError(
                        f"line {line_no}: scalar list item cannot have nested content"
                    )
            items.append(item)
        return items, index

    mapping: dict[str, Any] = {}
    index = start
    while index < len(records):
        current_indent, content, line_no = records[index]
        if current_indent < indent:
            break
        if current_indent != indent or content.startswith("- "):
            break

        key, value = split_key_value(content, line_no)
        index += 1
        if value:
            mapping[key] = parse_scalar(value)
        elif index < len(records) and records[index][0] > indent:
            mapping[key], index = parse_block(records, index, records[index][0])
        else:
            mapping[key] = {}
    return mapping, index


def as_dict(value: Any, path: str, errors: list[str]) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    errors.append(f"{path} must be a map")
    return {}


def as_list(value: Any, path: str, errors: list[str]) -> list[Any]:
    if isinstance(value, list):
        return value
    errors.append(f"{path} must be a list")
    return []


def get_path(data: dict[str, Any], path: str) -> Any:
    value: Any = data
    for segment in path.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(segment)
    return value


def non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def valid_port(value: Any) -> bool:
    return isinstance(value, int) and 1 <= value <= 65535


def validate_frontend_env(env: dict[str, Any], scope: str, errors: list[str]) -> None:
    for key in env:
        name = str(key)
        if PUBLIC_ENV_RE.search(name):
            errors.append(
                f"{scope}.{name} must not use browser-bundled env prefixes; "
                "the admin UI should use same-origin /api/* or server-side upstream env"
            )
        if SECRET_ENV_RE.search(name):
            errors.append(f"{scope}.{name} looks secret-like and must not be set on admin-ui")


def validate_runtime_config(global_values: dict[str, Any], errors: list[str]) -> None:
    config = as_dict(global_values.get("config"), "global.config", errors)
    if config.get("enabled") is not True:
        return

    if not non_empty_string(config.get("name")):
        errors.append("global.config.name is required when global.config.enabled=true")
    if not non_empty_string(config.get("fileName")):
        errors.append("global.config.fileName is required when global.config.enabled=true")
    if not (
        isinstance(config.get("mountPath"), str) and config["mountPath"].startswith("/")
    ):
        errors.append("global.config.mountPath must be an absolute path")
    if not non_empty_string(config.get("content")):
        errors.append("global.config.content is required when global.config.enabled=true")


def validate_service(
    root: dict[str, Any], name: str, service: dict[str, Any], errors: list[str]
) -> None:
    if service.get("enabled") is not True:
        return

    image = as_dict(service.get("image"), f"services.{name}.image", errors)
    if not non_empty_string(image.get("repository")):
        errors.append(f"services.{name}.image.repository is required")
    if not non_empty_string(image.get("tag")):
        errors.append(f"services.{name}.image.tag is required")

    if not valid_port(service.get("containerPort")):
        errors.append(f"services.{name}.containerPort must be 1..65535")

    service_spec = as_dict(service.get("service"), f"services.{name}.service", errors)
    if not valid_port(service_spec.get("port")):
        errors.append(f"services.{name}.service.port must be 1..65535")
    if not service_spec.get("targetPort"):
        errors.append(f"services.{name}.service.targetPort is required")

    secret_names = {
        "applicationSecretRef": get_path(root, "application.secretRef.name"),
        "databaseSecretRef": get_path(root, "database.secretRef.name"),
        "redisSecretRef": get_path(root, "redis.secretRef.name"),
    }
    for flag, secret_name in secret_names.items():
        if service.get(flag) is True and not non_empty_string(secret_name):
            owner = flag.removesuffix("SecretRef")
            errors.append(f"services.{name}.{flag} requires {owner}.secretRef.name")

    global_values = as_dict(root.get("global"), "global", errors)
    runtime_config = as_dict(global_values.get("config"), "global.config", errors)
    if service.get("configMapRef") is True:
        if runtime_config.get("enabled") is not True:
            errors.append(
                f"services.{name}.configMapRef requires global.config.enabled=true"
            )
    elif service.get("env", {}).get("AI_GATEWAY_CONFIG"):
        errors.append(
            f"services.{name}.env.AI_GATEWAY_CONFIG requires services.{name}.configMapRef=true"
        )

    config_path = service.get("env", {}).get("AI_GATEWAY_CONFIG")
    if (
        service.get("configMapRef") is True
        and isinstance(config_path, str)
        and non_empty_string(runtime_config.get("mountPath"))
        and config_path != runtime_config.get("mountPath")
    ):
        errors.append(
            f"services.{name}.env.AI_GATEWAY_CONFIG must match global.config.mountPath"
        )

    resources = as_dict(service.get("resources"), f"services.{name}.resources", errors)
    for bucket in ("requests", "limits"):
        resource_set = as_dict(
            resources.get(bucket), f"services.{name}.resources.{bucket}", errors
        )
        for field in ("cpu", "memory"):
            if not non_empty_string(resource_set.get(field)):
                errors.append(f"services.{name}.resources.{bucket}.{field} is required")

    probes = as_dict(service.get("probes"), f"services.{name}.probes", errors)
    for probe_name in ("liveness", "readiness"):
        probe = as_dict(
            probes.get(probe_name), f"services.{name}.probes.{probe_name}", errors
        )
        if probe.get("enabled") is not True:
            continue
        if not (isinstance(probe.get("path"), str) and probe["path"].startswith("/")):
            errors.append(f"services.{name}.probes.{probe_name}.path must start with /")
        numeric_limits = {
            "initialDelaySeconds": 0,
            "periodSeconds": 1,
            "timeoutSeconds": 1,
            "failureThreshold": 1,
        }
        for field, minimum in numeric_limits.items():
            value = probe.get(field)
            if value is not None and (not isinstance(value, int) or value < minimum):
                errors.append(
                    f"services.{name}.probes.{probe_name}.{field} must be >= {minimum}"
                )

    security_context = service.get("securityContext") or global_values.get("securityContext")
    security_context = as_dict(
        security_context, f"services.{name}.effectiveSecurityContext", errors
    )
    if security_context.get("allowPrivilegeEscalation") is not False:
        errors.append(
            f"services.{name}.effectiveSecurityContext.allowPrivilegeEscalation must be false"
        )
    capabilities = as_dict(
        security_context.get("capabilities"),
        f"services.{name}.effectiveSecurityContext.capabilities",
        errors,
    )
    drop = as_list(
        capabilities.get("drop"),
        f"services.{name}.effectiveSecurityContext.capabilities.drop",
        errors,
    )
    if "ALL" not in drop:
        errors.append(f"services.{name}.effectiveSecurityContext.capabilities.drop must include ALL")

    pod_security_context = service.get("podSecurityContext") or global_values.get(
        "podSecurityContext"
    )
    pod_security_context = as_dict(
        pod_security_context, f"services.{name}.effectivePodSecurityContext", errors
    )
    seccomp = as_dict(
        pod_security_context.get("seccompProfile"),
        f"services.{name}.effectivePodSecurityContext.seccompProfile",
        errors,
    )
    if seccomp.get("type") != "RuntimeDefault":
        errors.append(
            f"services.{name}.effectivePodSecurityContext.seccompProfile.type must be RuntimeDefault"
        )

    if name == "admin-ui":
        for flag in ("applicationSecretRef", "databaseSecretRef", "redisSecretRef"):
            if service.get(flag) is True:
                errors.append(f"services.admin-ui.{flag} must remain false")
        if service.get("configMapRef") is True:
            errors.append("services.admin-ui.configMapRef must remain false")
        validate_frontend_env(
            as_dict(service.get("env"), "services.admin-ui.env", errors),
            "services.admin-ui.env",
            errors,
        )
        for index, entry in enumerate(service.get("extraEnvFrom") or []):
            if isinstance(entry, dict) and "secretRef" in entry:
                errors.append(
                    f"services.admin-ui.extraEnvFrom[{index}] must not reference secretRef"
                )


def validate_ingress(root: dict[str, Any], errors: list[str]) -> None:
    ingress = as_dict(root.get("ingress"), "ingress", errors)
    services = as_dict(root.get("services"), "services", errors)
    hosts = as_list(ingress.get("hosts"), "ingress.hosts", errors)
    if ingress.get("enabled") is True and not hosts:
        errors.append("ingress.hosts must not be empty when ingress.enabled=true")

    allowed_path_types = {"ImplementationSpecific", "Exact", "Prefix"}
    for host_index, host_entry in enumerate(hosts):
        host = as_dict(host_entry, f"ingress.hosts[{host_index}]", errors)
        paths = as_list(host.get("paths"), f"ingress.hosts[{host_index}].paths", errors)
        for path_index, path_entry in enumerate(paths):
            path = as_dict(
                path_entry, f"ingress.hosts[{host_index}].paths[{path_index}]", errors
            )
            path_value = path.get("path")
            service_name = path.get("service")
            if not (isinstance(path_value, str) and path_value.startswith("/")):
                errors.append(
                    f"ingress.hosts[{host_index}].paths[{path_index}].path must start with /"
                )
            path_type = path.get("pathType", "Prefix")
            if path_type not in allowed_path_types:
                errors.append(
                    f"ingress.hosts[{host_index}].paths[{path_index}].pathType is invalid"
                )
            if not isinstance(service_name, str) or service_name not in services:
                errors.append(
                    f"ingress.hosts[{host_index}].paths[{path_index}] references unknown service"
                )
                continue
            target = as_dict(
                services.get(service_name), f"services.{service_name}", errors
            )
            if target.get("enabled") is not True:
                errors.append(
                    f"ingress path {path_value!r} references disabled service {service_name!r}"
                )
            service_spec = as_dict(
                target.get("service"), f"services.{service_name}.service", errors
            )
            if not valid_port(service_spec.get("port")):
                errors.append(
                    f"ingress path {path_value!r} references service {service_name!r} without a valid service.port"
                )


def validate_values(root: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    global_values = as_dict(root.get("global"), "global", errors)
    if global_values.get("automountServiceAccountToken") is not False:
        errors.append("global.automountServiceAccountToken should default to false")
    validate_runtime_config(global_values, errors)

    services = as_dict(root.get("services"), "services", errors)
    for required_service in ("gateway", "control-plane", "admin-ui", "mock-provider"):
        if required_service not in services:
            errors.append(f"services.{required_service} is required for the default slice")

    admin_ui = services.get("admin-ui")
    if isinstance(admin_ui, dict) and admin_ui.get("enabled") is True:
        validate_frontend_env(
            as_dict(global_values.get("commonEnv"), "global.commonEnv", errors),
            "global.commonEnv",
            errors,
        )

    for name, service in services.items():
        validate_service(root, name, as_dict(service, f"services.{name}", errors), errors)

    validate_ingress(root, errors)
    return errors


def validate_template_contract(chart_dir: Path) -> list[str]:
    errors: list[str] = []
    required_fragments = {
        "templates/workloads.yaml": [
            "kind: Deployment",
            "kind: Service",
            "envFrom:",
            "secretRef:",
            "volumeMounts:",
            "configMap:",
            "automountServiceAccountToken:",
        ],
        "templates/ingress.yaml": [
            "kind: Ingress",
            "backend:",
            "service:",
            "pathType:",
        ],
        "templates/configmap.yaml": [
            "kind: ConfigMap",
            "data:",
            "global.config.content",
        ],
        "templates/_helpers.tpl": [
            'define "fubox.validateService"',
            'define "fubox.validateIngressPath"',
            'define "fubox.validateFrontendEnv"',
            'define "fubox.configMapName"',
        ],
    }

    for relative_path, fragments in required_fragments.items():
        path = chart_dir / relative_path
        if not path.exists():
            errors.append(f"missing required Helm template contract file: {relative_path}")
            continue
        text = path.read_text(encoding="utf-8")
        for fragment in fragments:
            if fragment not in text:
                errors.append(
                    f"{relative_path} is missing required template fragment: {fragment}"
                )
    return errors


def run_self_tests(chart_dir: Path) -> list[str]:
    values_path = chart_dir / "values.yaml"
    root = load_yaml_subset(values_path)
    if not isinstance(root, dict):
        return [f"{values_path} must contain a YAML mapping"]

    failures: list[str] = []
    cases: list[tuple[str, Any, str]] = [
        (
            "admin-ui browser env is rejected",
            lambda data: data["services"]["admin-ui"]["env"].__setitem__(
                "VITE_API_BASE_URL", "http://fubox-gateway:8080"
            ),
            "VITE_API_BASE_URL",
        ),
        (
            "admin-ui secret envFrom is rejected",
            lambda data: data["services"]["admin-ui"].__setitem__(
                "extraEnvFrom", [{"secretRef": {"name": "fubox-app-secrets"}}]
            ),
            "extraEnvFrom[0] must not reference secretRef",
        ),
        (
            "admin-ui ConfigMap mount is rejected",
            lambda data: data["services"]["admin-ui"].__setitem__("configMapRef", True),
            "services.admin-ui.configMapRef must remain false",
        ),
        (
            "backend AI_GATEWAY_CONFIG requires ConfigMap mount",
            lambda data: data["services"]["gateway"].__setitem__("configMapRef", False),
            "services.gateway.env.AI_GATEWAY_CONFIG requires services.gateway.configMapRef=true",
        ),
        (
            "ConfigMap mount path must match AI_GATEWAY_CONFIG",
            lambda data: data["global"]["config"].__setitem__(
                "mountPath", "/app/config/other.yaml"
            ),
            "services.gateway.env.AI_GATEWAY_CONFIG must match global.config.mountPath",
        ),
        (
            "ingress unknown service is rejected",
            lambda data: data["ingress"]["hosts"][0]["paths"][0].__setitem__(
                "service", "missing-service"
            ),
            "references unknown service",
        ),
        (
            "secretRef name is required for backend secret mounts",
            lambda data: data["application"]["secretRef"].__setitem__("name", ""),
            "services.gateway.applicationSecretRef requires application.secretRef.name",
        ),
    ]

    if validate_values(copy.deepcopy(root)):
        failures.append("default values.yaml should pass static validation")

    for name, mutate, expected in cases:
        candidate = copy.deepcopy(root)
        mutate(candidate)
        errors = validate_values(candidate)
        if not any(expected in error for error in errors):
            failures.append(
                f"{name}: expected error containing {expected!r}; got {errors!r}"
            )

    failures.extend(validate_template_contract(chart_dir))
    if not failures:
        print("Helm chart contract self-test passed")
    return failures


def run_helm(chart_dir: Path) -> list[str]:
    helm = shutil.which("helm")
    if helm is None:
        print("warning: helm not found; skipped helm lint/template")
        return []

    errors: list[str] = []
    commands = [
        [helm, "lint", str(chart_dir)],
        [helm, "template", "fubox", str(chart_dir)],
    ]
    for command in commands:
        result = subprocess.run(
            command,
            cwd=chart_dir.parent.parent,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        label = " ".join(command[1:])
        if result.stdout.strip():
            print(result.stdout.rstrip())
        if result.stderr.strip():
            print(result.stderr.rstrip())
        if result.returncode != 0:
            errors.append(f"helm {label} failed with exit code {result.returncode}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--chart-dir",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="Path to the Helm chart directory.",
    )
    parser.add_argument(
        "--values",
        type=Path,
        default=None,
        help="Values file to statically validate. Defaults to values.yaml in the chart.",
    )
    parser.add_argument(
        "--skip-helm",
        action="store_true",
        help="Only run static validation; skip helm lint/template even when Helm is installed.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run local contract self-tests for Helm chart validation rules.",
    )
    args = parser.parse_args()

    chart_dir = args.chart_dir.resolve()
    values_path = (args.values or chart_dir / "values.yaml").resolve()
    schema_path = chart_dir / "values.schema.json"
    chart_path = chart_dir / "Chart.yaml"

    errors: list[str] = []
    for required_path in (chart_path, values_path, schema_path, chart_dir / "templates"):
        if not required_path.exists():
            errors.append(f"missing required chart path: {required_path}")

    if not errors:
        errors.extend(validate_template_contract(chart_dir))

    if schema_path.exists():
        try:
            json.loads(schema_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            errors.append(f"{schema_path} is not valid JSON: {error}")

    if values_path.exists():
        try:
            values = load_yaml_subset(values_path)
        except YamlParseError as error:
            errors.append(str(error))
        else:
            if isinstance(values, dict):
                errors.extend(validate_values(values))
            else:
                errors.append(f"{values_path} must contain a YAML mapping")

    if args.self_test:
        errors.extend(run_self_tests(chart_dir))

    if not errors:
        print("static Helm chart validation passed")

    if not args.skip_helm:
        errors.extend(run_helm(chart_dir))

    if errors:
        for error in errors:
            print(f"error: {error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
