import type { JsonObject, JsonValue } from "../api/client";
import { safeErrorMessage, statusLabel } from "../lib/safeText";

export function StateChip({ status }: { status: string }) {
  return <span className={`state-chip state-chip--${statusTone(status)}`}>{statusLabel(status)}</span>;
}

export function parseJsonObject(value: string, label: string): JsonObject {
  const parsed = parseJson(value, label);

  if (!isJsonRecord(parsed)) {
    throw new Error(`${label} must be a JSON object.`);
  }

  return parsed;
}

export function parseJsonArray(value: string, label: string): JsonValue[] {
  const parsed = parseJson(value, label);

  if (!Array.isArray(parsed)) {
    throw new Error(`${label} must be a JSON array.`);
  }

  return parsed;
}

export function parseSafeJsonObject(value: string, label: string): JsonObject {
  const metadata = parseJsonObject(value, label);

  if (containsSensitiveMetadata(metadata)) {
    throw new Error(`${label} cannot contain credentials, tokens, keys, or fingerprints.`);
  }

  return metadata;
}

export function parseSafeMetadata(value: string): JsonObject {
  const metadata = parseJsonObject(value, "Metadata");

  if (containsSensitiveMetadata(metadata)) {
    throw new Error("Metadata cannot contain credentials, tokens, keys, or fingerprints.");
  }

  return metadata;
}

export function parseSafeJsonValue(value: string, label: string): JsonValue {
  const parsed = parseJson(value || "null", label);

  if (containsSensitiveMetadata(parsed)) {
    throw new Error(`${label} cannot contain credentials, tokens, keys, or fingerprints.`);
  }

  return parsed;
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

export function sanitizeDisplayJson(value: JsonValue): JsonValue {
  return omitUnsafeJsonFields(sanitizeSecretJson(value));
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

export function containsSensitiveMetadata(value: JsonValue): boolean {
  if (Array.isArray(value)) {
    return value.some(containsSensitiveMetadata);
  }

  if (isJsonRecord(value)) {
    return Object.entries(value).some(([key, child]) => isSensitiveKey(key) || containsSensitiveMetadata(child));
  }

  return isSensitiveValue(value);
}

export function isJsonRecord(value: JsonValue): value is Record<string, JsonValue> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function errorMessage(error: unknown): string {
  return safeErrorMessage(error);
}

export function fieldValue(value: unknown): string {
  if (value === null || value === undefined || value === "") {
    return "-";
  }

  return String(value);
}

export function safeFieldValue(value: unknown): string {
  const displayValue = fieldValue(value);

  if (displayValue === "-") {
    return displayValue;
  }

  const redacted = redactSensitiveText(displayValue);

  return isSensitiveDisplayText(redacted) ? "[redacted]" : redacted;
}

export function jsonSize(value: JsonValue): string {
  if (Array.isArray(value)) {
    return String(value.length);
  }

  if (isJsonRecord(value)) {
    return String(Object.keys(value).length);
  }

  return value === null || value === undefined ? "0" : "1";
}

export function formatStatus(status: string): string {
  return status.replace(/_/g, " ");
}

export function shortId(value: string | null | undefined): string {
  if (!value) {
    return "-";
  }

  return value.length > 12 ? `${value.slice(0, 8)}...` : value;
}

function parseJson(value: string, label: string): JsonValue {
  try {
    return JSON.parse(value || "{}") as JsonValue;
  } catch {
    throw new Error(`${label} must be valid JSON.`);
  }
}

function omitUnsafeJsonFields(value: JsonValue): JsonValue {
  if (Array.isArray(value)) {
    return value.map(omitUnsafeJsonFields);
  }

  if (isJsonRecord(value)) {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key]) => !isUnsafeJsonDisplayKey(key))
        .map(([key, child]) => [key, omitUnsafeJsonFields(child)]),
    );
  }

  if (typeof value === "string") {
    return safeFieldValue(value);
  }

  return value;
}

function isUnsafeJsonDisplayKey(key: string): boolean {
  const normalized = key.toLowerCase().replace(/[^a-z0-9]/g, "");

  return (
    normalized.includes("authorization") ||
    normalized.includes("apikey") ||
    normalized.includes("body") ||
    normalized.includes("cookie") ||
    normalized.includes("credential") ||
    normalized.includes("encryptedsecret") ||
    normalized.includes("fingerprint") ||
    normalized.includes("password") ||
    normalized.includes("payload") ||
    normalized.includes("providerkey") ||
    normalized.includes("raw") ||
    normalized.includes("secret") ||
    normalized.includes("token")
  );
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
  if (typeof value !== "string") {
    return false;
  }

  return isSensitiveDisplayText(value);
}

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

function statusTone(status: string): "danger" | "good" | "neutral" | "warn" {
  const normalized = status.toLowerCase();

  if (["active", "enabled", "success", "succeeded", "online"].includes(normalized)) {
    return "good";
  }

  if (["disabled", "manual_disabled", "auth_failed", "deleted", "expired", "failed", "offline"].includes(normalized)) {
    return "danger";
  }

  if (
    [
      "degraded",
      "cooldown",
      "recovery_probe",
      "quota_exhausted",
      "pending",
      "started",
      "rejected",
      "partial",
      "cancelled",
    ].includes(normalized)
  ) {
    return "warn";
  }

  return "neutral";
}
