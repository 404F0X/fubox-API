import type { JsonValue } from "../api/client";

const EMPTY_TEXT = "-";

const STATUS_LABELS: Record<string, string> = {
  active: "启用",
  amount_mismatch: "金额不一致",
  auth_failed: "认证失败",
  blocked: "阻塞",
  cancelled: "已取消",
  cooldown: "冷却中",
  degraded: "降级",
  deleted: "已删除",
  disabled: "已禁用",
  draft: "草稿",
  dry_run: "Dry-run",
  enabled: "已启用",
  expired: "已过期",
  failed: "失败",
  issued: "已发放",
  live: "Live",
  manual_disabled: "手动禁用",
  offline: "离线",
  online: "在线",
  partial: "部分完成",
  pending: "待处理",
  planned: "已计划",
  quota_exhausted: "额度耗尽",
  recovery_probe: "恢复探针",
  redeemed: "已兑换",
  rejected: "已拒绝",
  retired: "已退役",
  revoked: "已撤销",
  started: "处理中",
  succeeded: "成功",
  success: "成功",
  unknown: "未知",
};

const SECRET_VALUE_PREFIXES = [
  "sk-",
  "sk_",
  "vk_",
  "dev_test_key_",
  "aiza",
  "xoxb-",
  "ghp_",
  "github_pat_",
];

const SAFE_ERROR_MESSAGES: Record<string, string> = {
  api_key_rate_limited: "Rate limit reached. Retry later or adjust the key/channel limit.",
  billing_insufficient_balance: "Insufficient balance. Add credit or lower the request cost.",
  model_not_found: "Invalid model or the model is not available for this key/profile.",
  provider_429: "Provider rate limit reached. Retry later or add provider capacity.",
  provider_auth_failed: "Provider authentication failed. Verify or rotate the provider key.",
  rate_limit_exceeded: "Rate limit reached. Retry later or add routing capacity.",
  route_no_candidate: "No route is available for this model. Check enabled mappings and channel health.",
  upstream_invalid_model: "Invalid upstream model mapping. Check the provider/channel model name.",
  upstream_timeout: "Provider timed out. Retry later or check channel timeout/health.",
};

const SAFE_ERROR_PATTERNS: Array<[RegExp, string]> = [
  [/\b(model_not_found|invalid[_\s-]?model|model does not exist|does not exist)\b/i, SAFE_ERROR_MESSAGES.upstream_invalid_model],
  [/\b(no route|no enabled .*route|route_no_candidate|no candidate)\b/i, SAFE_ERROR_MESSAGES.route_no_candidate],
  [/\b(provider_auth_failed|auth(?:entication)? failed|unauthorized|forbidden|401|403)\b/i, SAFE_ERROR_MESSAGES.provider_auth_failed],
  [/\b(rate[_\s-]?limit|too many requests|quota|429)\b/i, SAFE_ERROR_MESSAGES.provider_429],
  [/\b(insufficient balance|billing_insufficient_balance|budget is insufficient)\b/i, SAFE_ERROR_MESSAGES.billing_insufficient_balance],
  [/\b(timeout|timed out|upstream_timeout)\b/i, SAFE_ERROR_MESSAGES.upstream_timeout],
];

export function displayText(value: unknown): string {
  if (value === null || value === undefined || value === "") {
    return EMPTY_TEXT;
  }

  return String(value);
}

export function safeDisplayText(value: unknown): string {
  const text = displayText(value);

  if (text === EMPTY_TEXT) {
    return text;
  }

  const redacted = redactSensitiveText(text);

  return isSensitiveDisplayText(redacted) ? "[redacted]" : redacted;
}

export function statusLabel(status: string | null | undefined): string {
  const safeStatus = safeStatusValue(status);
  const normalized = normalizeStatus(safeStatus);

  return STATUS_LABELS[normalized] ?? safeStatus.replace(/_/g, " ");
}

export function safeStatusValue(status: string | null | undefined): string {
  const safeValue = safeDisplayText(status);

  return safeValue === EMPTY_TEXT ? "unknown" : safeValue;
}

export function safeShortId(value: string | null | undefined): string {
  const safeValue = safeDisplayText(value);

  if (safeValue === EMPTY_TEXT || safeValue.includes("[redacted]")) {
    return safeValue;
  }

  return safeValue.length > 12 ? `${safeValue.slice(0, 8)}...` : safeValue;
}

export function safeUrl(value: string | null | undefined): string {
  const rawValue = typeof value === "string" ? value.trim() : "";

  if (rawValue) {
    try {
      const url = new URL(rawValue);

      if (url.username || url.password || url.search || url.hash) {
        return "[redacted]";
      }
    } catch {
      // Non-URL endpoints are handled by safeDisplayText below.
    }
  }

  const safeValue = safeDisplayText(value);

  if (safeValue === EMPTY_TEXT) {
    return safeValue;
  }

  try {
    const url = new URL(safeValue);

    if (url.username || url.password || url.search || url.hash) {
      return "[redacted]";
    }
  } catch {
    return safeValue;
  }

  return safeValue;
}

export function isSensitiveDisplayText(value: string): boolean {
  const trimmed = value.trim();
  const normalized = trimmed.toLowerCase();

  return (
    SECRET_VALUE_PREFIXES.some((prefix) => normalized.startsWith(prefix)) ||
    /\b(?:bearer|basic)\s+\S+/i.test(trimmed) ||
    /\b(?:api[_-]?key|apikey|authorization|cookie|password|secret|token)\s*[:=]/i.test(trimmed) ||
    /\b(?:current_window_state|encrypted_secret|secret_fingerprint|fingerprint|raw[_\s-]?(?:headers|key|metadata))\b/i.test(
      trimmed,
    ) ||
    /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i.test(trimmed)
  );
}

export function redactSensitiveText(value: string): string {
  return value
    .replace(/\b(?:bearer|basic)\s+\S+/gi, "[redacted]")
    .replace(/\b(?:sk-|sk_|vk_|dev_test_key_|xoxb-|ghp_|github_pat_)[A-Za-z0-9._-]+/gi, "[redacted]")
    .replace(/\baiza[A-Za-z0-9._-]+/gi, "[redacted]")
    .replace(/\b(?:api[_-]?key|apikey|authorization|cookie|password|secret|token)\s*[:=]\s*\S+/gi, "[redacted]")
    .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, "[redacted]");
}

export function safeErrorMessage(error: unknown): string {
  const code = errorCodeFromUnknown(error);
  const codedMessage = code ? safeRoutingErrorMessage(code) : null;

  if (codedMessage) {
    return codedMessage;
  }

  const message = error instanceof Error ? error.message : "Request failed.";
  const patternedMessage = safeRoutingErrorMessage(message);

  if (patternedMessage) {
    return patternedMessage;
  }

  const redacted = redactSensitiveText(message).trim();

  if (
    !redacted ||
    redacted.includes("[redacted]") ||
    /\bauthorization\b/i.test(message) ||
    isSensitiveDisplayText(message) ||
    isSensitiveDisplayText(redacted)
  ) {
    return "Request failed.";
  }

  return redacted;
}

export function safeRoutingErrorMessage(value: unknown): string | null {
  if (value === null || value === undefined) {
    return null;
  }

  const text = String(value).trim();
  const normalized = text.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");

  if (SAFE_ERROR_MESSAGES[normalized]) {
    return SAFE_ERROR_MESSAGES[normalized];
  }

  for (const [pattern, message] of SAFE_ERROR_PATTERNS) {
    if (pattern.test(text)) {
      return message;
    }
  }

  return null;
}

export function sanitizeSecretJson(value: JsonValue): JsonValue {
  if (Array.isArray(value)) {
    return value.map(sanitizeSecretJson);
  }

  if (isJsonRecord(value)) {
    return Object.fromEntries(
      Object.entries(value).map(([key, child]) =>
        isSensitiveKey(key) || isSensitiveValue(child)
          ? [key, "[redacted]" satisfies JsonValue]
          : [key, sanitizeSecretJson(child)],
      ),
    );
  }

  return isSensitiveValue(value) ? "[redacted]" : value;
}

export function isJsonRecord(value: JsonValue): value is Record<string, JsonValue> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function containsSensitiveJson(value: JsonValue): boolean {
  if (Array.isArray(value)) {
    return value.some(containsSensitiveJson);
  }

  if (isJsonRecord(value)) {
    return Object.entries(value).some(([key, child]) => isSensitiveKey(key) || containsSensitiveJson(child));
  }

  return isSensitiveValue(value);
}

function normalizeStatus(status: string): string {
  return status.toLowerCase().trim().replace(/\s+/g, "_");
}

function isSensitiveKey(key: string): boolean {
  const normalized = key.toLowerCase().replace(/[^a-z0-9]/g, "");

  return (
    normalized.includes("secret") ||
    normalized.includes("credential") ||
    normalized.includes("authorization") ||
    normalized.includes("password") ||
    normalized.includes("cookie") ||
    normalized.includes("token") ||
    normalized.includes("providerkey") ||
    normalized.includes("apikey") ||
    normalized.includes("keyhash") ||
    normalized.includes("encryptedsecret") ||
    normalized.includes("fingerprint")
  );
}

function isSensitiveValue(value: JsonValue): boolean {
  return typeof value === "string" && isSensitiveDisplayText(value);
}

function errorCodeFromUnknown(error: unknown): string | undefined {
  if (isRecord(error)) {
    const direct = scalarString(error.code);
    if (direct) {
      return direct;
    }

    const envelope = error.envelope;
    if (isRecord(envelope) && isRecord(envelope.error)) {
      return scalarString(envelope.error.code);
    }
  }

  return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function scalarString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value : undefined;
}
