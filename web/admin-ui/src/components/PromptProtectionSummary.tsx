import type { JsonValue } from "../api/client";
import { StateChip, isJsonRecord, safeFieldValue } from "./adminUtils";

type PromptProtectionSummaryData = {
  action: string;
  configuredActions: string;
  configuredHitCount: string;
  configuredPatternTypes: string;
  configuredRuleCount: string;
  defaultHitCount: string;
  detectedAction: string;
  effectiveAction: string;
  hitCount: string;
  hitKinds: string;
  mode: string;
  omittedMaterial: string;
  reason: string;
  scopes: string;
};

const PROMPT_PROTECTION_KEYS = new Set([
  "promptprotection",
  "promptprotectionsummary",
  "promptprotectionmetadata",
  "promptprotectionsignals",
]);

export function PromptProtectionSummary({
  sourceLabel,
  value,
}: {
  sourceLabel: string;
  value: JsonValue | null | undefined;
}) {
  const summary = summarizePromptProtection(value);

  if (!summary) {
    return null;
  }

  return (
    <article className="admin-panel" aria-label="Prompt protection summary">
      <div className="section-heading">
        <div>
          <h2>Prompt Protection</h2>
          <p>{sourceLabel}</p>
        </div>
        <StateChip status={summary.action === "reject" ? "rejected" : summary.action} />
      </div>

      <dl className="detail-list">
        <div>
          <dt>Mode</dt>
          <dd>{summary.mode}</dd>
        </div>
        <div>
          <dt>Action</dt>
          <dd>{summary.action}</dd>
        </div>
        <div>
          <dt>Reason</dt>
          <dd>{summary.reason}</dd>
        </div>
        <div>
          <dt>Hit count</dt>
          <dd>{summary.hitCount}</dd>
        </div>
        <div>
          <dt>Scopes</dt>
          <dd>{summary.scopes}</dd>
        </div>
        <div>
          <dt>Detected action</dt>
          <dd>{summary.detectedAction}</dd>
        </div>
        <div>
          <dt>Effective action</dt>
          <dd>{summary.effectiveAction}</dd>
        </div>
        <div>
          <dt>Default hits</dt>
          <dd>{summary.defaultHitCount}</dd>
        </div>
        <div>
          <dt>Configured hits</dt>
          <dd>{summary.configuredHitCount}</dd>
        </div>
        <div>
          <dt>Hit kinds</dt>
          <dd>{summary.hitKinds}</dd>
        </div>
        <div>
          <dt>Configured actions</dt>
          <dd>{summary.configuredActions}</dd>
        </div>
        <div>
          <dt>Pattern types</dt>
          <dd>{summary.configuredPatternTypes}</dd>
        </div>
        <div>
          <dt>Configured rules</dt>
          <dd>{summary.configuredRuleCount}</dd>
        </div>
        <div>
          <dt>Omitted material</dt>
          <dd>{summary.omittedMaterial}</dd>
        </div>
      </dl>
    </article>
  );
}

export function stripPromptProtectionSignals(value: JsonValue | null | undefined): JsonValue | null {
  if (value === null || value === undefined) {
    return null;
  }

  if (Array.isArray(value)) {
    return value.map(stripPromptProtectionSignals) as JsonValue;
  }

  if (!isJsonRecord(value)) {
    return value;
  }

  return Object.fromEntries(
    Object.entries(value)
      .filter(([key]) => !isPromptProtectionKey(key))
      .map(([key, child]) => [key, stripPromptProtectionSignals(child)]),
  ) as JsonValue;
}

function summarizePromptProtection(value: JsonValue | null | undefined): PromptProtectionSummaryData | null {
  const record = findPromptProtectionRecord(value);

  if (!record) {
    return null;
  }

  return {
    action: enumField(record.action),
    configuredActions: countMapField(record.configured_actions),
    configuredHitCount: numberField(record.configured_hit_count),
    configuredPatternTypes: countMapField(record.configured_pattern_types),
    configuredRuleCount: configuredRuleCount(record.configured_rules),
    defaultHitCount: numberField(record.default_hit_count),
    detectedAction: enumField(record.detected_action),
    effectiveAction: enumField(record.effective_action),
    hitCount: numberField(record.hit_count),
    hitKinds: countMapField(record.hit_kinds),
    mode: enumField(record.mode),
    omittedMaterial: omittedMaterialField(record),
    reason: enumField(record.reason),
    scopes: listField(record.scopes),
  };
}

function findPromptProtectionRecord(
  value: JsonValue | null | undefined,
  allowDirectSummary = true,
): Record<string, JsonValue> | null {
  if (Array.isArray(value)) {
    for (const child of value) {
      const record = findPromptProtectionRecord(child, false);

      if (record) {
        return record;
      }
    }

    return null;
  }

  if (value === undefined || !isJsonRecord(value)) {
    return null;
  }

  if (allowDirectSummary && looksLikePromptProtectionSummary(value)) {
    return value;
  }

  for (const [key, child] of Object.entries(value)) {
    if (!isPromptProtectionKey(key)) {
      continue;
    }

    const record = findPromptProtectionRecord(child, true);

    if (record) {
      return record;
    }
  }

  if (value.summary !== undefined && isJsonRecord(value.summary)) {
    return findPromptProtectionRecord(value.summary);
  }

  for (const child of Object.values(value)) {
    const record = findPromptProtectionRecord(child, false);

    if (record) {
      return record;
    }
  }

  return null;
}

function looksLikePromptProtectionSummary(value: Record<string, JsonValue>): boolean {
  const schema = typeof value.schema === "string" ? value.schema.toLowerCase() : "";

  return (
    schema.includes("prompt_protection") ||
    Boolean(value.raw_payload_omitted) ||
    Boolean(value.raw_pattern_values_omitted) ||
    (typeof value.mode === "string" &&
      typeof value.action === "string" &&
      (typeof value.hit_count === "number" || typeof value.hit_count === "string"))
  );
}

function isPromptProtectionKey(key: string): boolean {
  return PROMPT_PROTECTION_KEYS.has(key.toLowerCase().replace(/[^a-z0-9]/g, ""));
}

function enumField(value: JsonValue | undefined): string {
  if (typeof value !== "string") {
    return "-";
  }

  const safeValue = safeFieldValue(value.trim());

  if (safeValue === "-" || safeValue === "[redacted]") {
    return safeValue;
  }

  return /^[a-z0-9_.:-]{1,80}$/i.test(safeValue) ? safeValue : "[redacted]";
}

function numberField(value: JsonValue | undefined): string {
  if (typeof value === "number" && Number.isFinite(value)) {
    return safeFieldValue(value);
  }

  if (typeof value === "string" && /^\d{1,9}$/.test(value.trim())) {
    return safeFieldValue(value.trim());
  }

  return "-";
}

function listField(value: JsonValue | undefined): string {
  if (!Array.isArray(value)) {
    return "-";
  }

  const items = value
    .map((item) => enumField(item))
    .filter((item) => item !== "-")
    .slice(0, 8);

  const remaining = value.length - items.length;
  const suffix = remaining > 0 ? `, +${remaining} more` : "";

  return items.length > 0 ? `${items.join(", ")}${suffix}` : "-";
}

function countMapField(value: JsonValue | undefined): string {
  if (value === undefined || !isJsonRecord(value)) {
    return "-";
  }

  const entries = Object.entries(value)
    .map(([key, count]) => {
      const safeKey = enumField(key);
      const safeCount = numberField(count);

      return safeKey !== "-" && safeCount !== "-" ? `${safeKey}: ${safeCount}` : null;
    })
    .filter((item): item is string => Boolean(item))
    .slice(0, 6);

  const remaining = Object.keys(value).length - entries.length;
  const suffix = remaining > 0 ? `, +${remaining} more` : "";

  return entries.length > 0 ? `${entries.join(", ")}${suffix}` : "-";
}

function configuredRuleCount(value: JsonValue | undefined): string {
  if (Array.isArray(value)) {
    return safeFieldValue(value.length);
  }

  return "-";
}

function omittedMaterialField(record: Record<string, JsonValue>): string {
  const omitted = [
    record.raw_payload_omitted === true ? "raw payload" : null,
    record.raw_pattern_values_omitted === true ? "raw pattern values" : null,
  ].filter((item): item is string => Boolean(item));

  return omitted.length > 0 ? omitted.join(", ") : "-";
}
