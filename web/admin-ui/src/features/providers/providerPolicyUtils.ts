import type { Channel, JsonObject, JsonValue, Provider, ProviderKey } from "../../api/client";
import {
  containsSensitiveMetadata,
  isJsonRecord,
  safeFieldValue,
  shortId,
} from "../../components/adminUtils";
import { safeUrl } from "../../lib/safeText";

export const CHANNEL_PROTOCOL_OPTIONS = [
  {
    label: "OpenAI-compatible",
    value: "openai",
  },
  {
    label: "Anthropic Messages",
    value: "anthropic_messages",
  },
  {
    label: "Gemini generateContent",
    value: "gemini_generate_content",
  },
  {
    label: "Claude-compatible mock seam",
    value: "claude_compatible",
  },
] as const;

const KNOWN_PROTOCOL_VALUES: Set<string> = new Set(CHANNEL_PROTOCOL_OPTIONS.map((option) => option.value));

export function channelProtocolValue(value: string | null | undefined): string {
  const normalized = (value ?? "").trim();

  if (normalized.length === 0) {
    return "openai";
  }

  if (normalized === "openai_compatible" || normalized === "openai-compatible") {
    return "openai";
  }

  if (normalized === "anthropic") {
    return "anthropic_messages";
  }

  if (normalized === "gemini") {
    return "gemini_generate_content";
  }

  if (normalized === "claude_mock" || normalized === "claude-compatible") {
    return "claude_compatible";
  }

  return normalized;
}

export function channelProtocolLabel(value: string | null | undefined): string {
  const normalized = channelProtocolValue(value);
  const known = CHANNEL_PROTOCOL_OPTIONS.find((option) => option.value === normalized);

  return known?.label ?? safeFieldValue(normalized);
}

export function channelProtocolStatus(channel: Pick<Channel, "protocol_mode">, hasEnabledProviderKey: boolean): {
  detail: string;
  status: "mockable" | "ready" | "config-needed" | "unknown";
} {
  const protocol = channelProtocolValue(channel.protocol_mode);

  if (!KNOWN_PROTOCOL_VALUES.has(protocol)) {
    return {
      detail: "未知协议；下一步：确认 control-plane DTO 和 adapter seam 是否支持该 protocol_mode。",
      status: "unknown",
    };
  }

  if (protocol === "openai") {
    return hasEnabledProviderKey
      ? { detail: "OpenAI-compatible 通道已有 enabled provider key，可进入真实路由或 dry-run。", status: "ready" }
      : { detail: "OpenAI-compatible 通道缺少 enabled provider key；下一步：录入一次性凭据。", status: "config-needed" };
  }

  return hasEnabledProviderKey
    ? { detail: "非 OpenAI 协议已有凭据；当前按 adapter contract-ready 状态展示。", status: "ready" }
    : { detail: "非 OpenAI 协议未配置真实 key；当前可用 mockable/contract-ready seam 演示。", status: "mockable" };
}

export type ChannelReadinessStatus = "ready" | "config-needed" | "auth-failed" | "cooldown" | "mockable";

export type ProviderKeyProbeSummary = {
  errorCode: string;
  lastCheckedAt: string;
  nextStep: string;
  result: string;
  status: ChannelReadinessStatus;
};

export type ChannelReadiness = {
  detail: string;
  keyAlias: string;
  keyId: string | null;
  nextStep: string;
  probe: ProviderKeyProbeSummary | null;
  status: ChannelReadinessStatus;
};

export function providerKeyProbeSummary(key: ProviderKey): ProviderKeyProbeSummary {
  const probe = key.last_probe_summary ?? key.recovery_probe;
  const actionReadback = key.recovery_action_readback;
  const result = safeFieldValue(actionReadback?.last_probe_status ?? probe?.result);
  const errorCode = safeFieldValue(probe?.error_code ?? key.last_error_code);
  const lastCheckedAt = safeFieldValue(probe?.last_checked_at);
  const status = providerKeyReadinessStatus(key);

  return {
    errorCode,
    lastCheckedAt,
    nextStep:
      safeFieldValue(actionReadback?.safe_next_action) !== "-"
        ? safeFieldValue(actionReadback?.safe_next_action)
        : safeFieldValue(probe?.next_step) !== "-"
          ? safeFieldValue(probe?.next_step)
          : providerKeyProbeNextStep(status, key),
    result,
    status,
  };
}

export function channelReadiness(channel: Pick<Channel, "protocol_mode">, keys: ProviderKey[]): ChannelReadiness {
  const activeKeys = keys.filter((key) => key.status !== "deleted");
  const selectedKey = selectReadinessKey(activeKeys);

  if (!selectedKey) {
    const protocolStatus = channelProtocolStatus(channel, false);
    const status = protocolStatus.status === "mockable" ? "mockable" : "config-needed";

    return {
      detail: protocolStatus.detail,
      keyAlias: "没有 provider key",
      keyId: null,
      nextStep:
        status === "mockable"
          ? "可先用 mockable contract 演示；接入真实上游前录入 provider key。"
          : "录入 provider key 后运行 recovery probe。",
      probe: null,
      status,
    };
  }

  const probe = providerKeyProbeSummary(selectedKey);
  const protocolStatus = channelProtocolStatus(channel, selectedKey.status === "enabled");

  if (probe.status === "ready") {
    return {
      detail: `${protocolStatus.detail} 最近 probe ${probe.result} / ${probe.lastCheckedAt}。`,
      keyAlias: selectedKey.key_alias,
      keyId: selectedKey.id,
      nextStep: probe.nextStep,
      probe,
      status: "ready",
    };
  }

  if (probe.status === "config-needed" && protocolStatus.status === "mockable") {
    return {
      detail: `${protocolStatus.detail} 最近 probe ${probe.result} / ${probe.lastCheckedAt}。`,
      keyAlias: selectedKey.key_alias,
      keyId: selectedKey.id,
      nextStep: "非 OpenAI seam 可 mockable 演示；真实调用前修复 provider key 配置。",
      probe,
      status: "mockable",
    };
  }

  return {
    detail: `最近 probe ${probe.result} / ${probe.errorCode} / ${probe.lastCheckedAt}。`,
    keyAlias: selectedKey.key_alias,
    keyId: selectedKey.id,
    nextStep: probe.nextStep,
    probe,
    status: probe.status,
  };
}

function selectReadinessKey(keys: ProviderKey[]): ProviderKey | undefined {
  return (
    keys.find((key) => providerKeyReadinessStatus(key) === "ready") ??
    keys.find((key) => providerKeyReadinessStatus(key) === "auth-failed") ??
    keys.find((key) => providerKeyReadinessStatus(key) === "cooldown") ??
    keys.find((key) => providerKeyReadinessStatus(key) === "config-needed") ??
    keys[0]
  );
}

function providerKeyReadinessStatus(key: ProviderKey): ChannelReadinessStatus {
  const status = key.status;
  const probe = key.last_probe_summary ?? key.recovery_probe;
  const probeResult = (probe?.result ?? "").toLowerCase();
  const probeError = (probe?.error_code ?? key.last_error_code ?? "").toLowerCase();

  if (status === "auth_failed" || probeResult.includes("auth") || isAuthErrorCode(probeError)) {
    return "auth-failed";
  }

  if (status === "cooldown" || status === "recovery_probe" || status === "degraded" || Boolean(key.cooldown_until)) {
    return "cooldown";
  }

  if (status === "manual_disabled" || status === "deleted") {
    return "config-needed";
  }

  if (status === "enabled" && !key.last_error_code) {
    return "ready";
  }

  if (status === "enabled" && (probeResult === "ok" || probeResult === "success" || probeResult === "ready")) {
    return "ready";
  }

  return "config-needed";
}

function isAuthErrorCode(errorCode: string): boolean {
  return (
    errorCode.includes("401") ||
    errorCode.includes("403") ||
    errorCode.includes("auth") ||
    errorCode.includes("credential") ||
    errorCode.includes("unauthorized") ||
    errorCode.includes("forbidden")
  );
}

function providerKeyProbeNextStep(status: ChannelReadinessStatus, key: ProviderKey): string {
  if (status === "ready") {
    return "通道可进入 routing 或手动 dry-run；继续观察最近失败和延迟。";
  }

  if (status === "auth-failed") {
    return "轮换 provider key 凭据后重新请求 recovery probe。";
  }

  if (status === "cooldown") {
    return key.cooldown_until
      ? `等待冷却结束后重新 probe；cooldown_until=${safeFieldValue(key.cooldown_until)}。`
      : "等待 recovery probe 完成，或重新确认恢复探针。";
  }

  return "录入或启用 provider key 后运行 recovery probe。";
}

export function optionalString(value: string): string | undefined {
  const trimmed = value.trim();

  return trimmed ? trimmed : undefined;
}

export function parseAdvancedJsonObject(value: string, label: string): JsonObject {
  const parsed = parseAdvancedJson(value || "{}", label);

  if (!isJsonRecord(parsed)) {
    throw new Error(`${label} 必须是 JSON object。`);
  }

  return parsed;
}

export function parseAdvancedJsonArray(value: string, label: string): JsonValue[] {
  const parsed = parseAdvancedJson(value || "[]", label);

  if (!Array.isArray(parsed)) {
    throw new Error(`${label} 必须是 JSON array。`);
  }

  return parsed;
}

export function parseAdvancedJson(value: string, label: string): JsonValue {
  let parsed: JsonValue;

  try {
    parsed = JSON.parse(value) as JsonValue;
  } catch {
    throw new Error(`${label} 必须是有效 JSON。`);
  }

  if (containsUnsafeAdvancedJson(parsed)) {
    throw new Error(`${label} 包含不安全字段。`);
  }

  return parsed;
}

export function isUnsafeJsonValidationError(error: unknown): boolean {
  return error instanceof Error && (error.message.endsWith("contains unsafe fields.") || error.message.endsWith("包含不安全字段。"));
}

export function containsUnsafeAdvancedJson(value: JsonValue): boolean {
  if (containsSensitiveMetadata(value)) {
    return true;
  }

  if (Array.isArray(value)) {
    return value.some(containsUnsafeAdvancedJson);
  }

  if (isJsonRecord(value)) {
    return Object.entries(value).some(([key, child]) => isUnsafeAdvancedJsonKey(key) || containsUnsafeAdvancedJson(child));
  }

  return false;
}

export function isUnsafeAdvancedJsonKey(key: string): boolean {
  const normalized = key.toLowerCase().replace(/[^a-z0-9]/g, "");

  return (
    normalized.includes("authorization") ||
    normalized.includes("apikey") ||
    normalized.includes("body") ||
    normalized.includes("cookie") ||
    normalized.includes("credential") ||
    normalized.includes("encryptedsecret") ||
    normalized.includes("fingerprint") ||
    normalized.includes("keyhash") ||
    normalized.includes("password") ||
    normalized.includes("payload") ||
    normalized.includes("raw") ||
    normalized.includes("secret") ||
    normalized.includes("token")
  );
}

export function jsonSummaryKeys(value: JsonValue): string {
  if (Array.isArray(value)) {
    return value.length > 0 ? `${value.length} 项` : "-";
  }

  if (!isJsonRecord(value)) {
    return value === null ? "-" : safeFieldValue(value);
  }

  const keys = Object.keys(value)
    .map(safeFieldValue)
    .filter((key) => key !== "-")
    .slice(0, 4);

  return keys.length > 0 ? keys.join(", ") : "-";
}

export function providerMetadata(provider: Provider, key: "base_url" | "provider_type"): string | undefined {
  const direct = key === "provider_type" ? provider.provider_type : provider.base_url;

  if (direct) {
    return direct;
  }

  if (typeof provider.metadata !== "object" || provider.metadata === null || Array.isArray(provider.metadata)) {
    return undefined;
  }

  const value = provider.metadata[key];

  return typeof value === "string" && value.trim() ? value : undefined;
}

export function providerName(providerId: string, providers: Provider[]): string {
  return providers.find((provider) => provider.id === providerId)?.name ?? "未知供应商";
}

export function safeEndpoint(value: string | null | undefined): string {
  return safeUrl(value);
}

export function modelMappingOptions(channel: Channel): { requested: string[]; upstream: string[] } {
  const requested = new Set<string>();
  const upstream = new Set<string>();

  collectMappingOptions(channel.model_mappings, requested, upstream);

  return {
    requested: [...requested].sort(),
    upstream: [...upstream].sort(),
  };
}

function collectMappingOptions(value: JsonValue, requested: Set<string>, upstream: Set<string>) {
  if (Array.isArray(value)) {
    for (const item of value) {
      collectMappingPair(item, requested, upstream);
    }
    return;
  }

  if (!isJsonRecord(value)) {
    return;
  }

  for (const [key, child] of Object.entries(value)) {
    if (typeof child === "string" && !isModelMappingPolicyKey(key)) {
      addOption(requested, key);
      addOption(upstream, child);
    } else if (key === "explicit_mappings" || key === "mappings") {
      collectMappingOptions(child, requested, upstream);
    }
  }
}

function collectMappingPair(value: JsonValue, requested: Set<string>, upstream: Set<string>) {
  if (!isJsonRecord(value)) {
    return;
  }

  const requestedModel = stringField(value, "requested_model") ?? stringField(value, "model");
  const upstreamModel = stringField(value, "upstream_model") ?? stringField(value, "upstream_model_name");

  addOption(requested, requestedModel);
  addOption(upstream, upstreamModel);
}

function stringField(value: Record<string, JsonValue>, key: string): string | undefined {
  const field = value[key];

  return typeof field === "string" ? field : undefined;
}

function addOption(options: Set<string>, value: string | undefined) {
  const trimmed = value?.trim();

  if (trimmed) {
    options.add(trimmed);
  }
}

function isModelMappingPolicyKey(key: string): boolean {
  return ["case_policy", "explicit_mappings", "mappings", "trim_prefixes"].includes(key);
}

export function safeShortId(value: string | null | undefined): string {
  if (!value) {
    return "-";
  }

  const safeValue = safeFieldValue(value);

  return safeValue === value ? shortId(value) : safeValue;
}
