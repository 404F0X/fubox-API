import type { JsonValue } from "../api/client";
import { StateChip, isJsonRecord, safeFieldValue } from "./adminUtils";

type PromptProtectionSummaryData = {
  action: string;
  auditReadiness: string;
  closureChecklist: string;
  closureGaps: string;
  closureRule: string;
  configuredActions: string;
  configuredHitCount: string;
  configuredPatternTypes: string;
  configuredRuleCount: string;
  currentCommit: string;
  defaultHitCount: string;
  detectedAction: string;
  durationAvailability: string;
  effectiveAction: string;
  freshnessReplay: string;
  generatedAt: string;
  hitCount: string;
  hitKinds: string;
  latencyClosure: string;
  liveBlockerStatus: string;
  mode: string;
  omittedMaterial: string;
  providerAttempts: string;
  proofClosure: string;
  proofCommand: string;
  proofEvidence: string;
  provenanceMode: string;
  reason: string;
  scopes: string;
  staleSimulatedMarker: string;
};

export type PromptProtectionEvidenceReadback = {
  auditReadiness: string;
  closureChecklist: string[];
  closureGaps: string[];
  closureRule: string;
  currentCommit: string;
  durationAvailability: string;
  freshnessReplay: string;
  latencyEnvelope: string;
  omittedMaterial: string;
  proofClosure: string;
  proofEvidence: string[];
  proofMode: string;
  providerAttempts: string;
  schema: "prompt_protection_evidence_readback_v1";
};

export type PromptProtectionAuditClosureGate = {
  classification: "blocker" | "fail" | "pass";
  closureEligible: boolean;
  gaps: string[];
  readback: PromptProtectionEvidenceReadback;
  schema: "prompt_protection_audit_closure_gate_v1";
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
          <dt>Audit readiness</dt>
          <dd>{summary.auditReadiness}</dd>
        </div>
        <div>
          <dt>Proof command</dt>
          <dd>{summary.proofCommand}</dd>
        </div>
        <div>
          <dt>Proof evidence</dt>
          <dd>{summary.proofEvidence}</dd>
        </div>
        <div>
          <dt>Closure rule</dt>
          <dd>{summary.closureRule}</dd>
        </div>
        <div>
          <dt>Closure checklist</dt>
          <dd>{summary.closureChecklist}</dd>
        </div>
        <div>
          <dt>Closure gaps</dt>
          <dd>{summary.closureGaps}</dd>
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
          <dt>Provider attempts</dt>
          <dd>{summary.providerAttempts}</dd>
        </div>
        <div>
          <dt>Duration</dt>
          <dd>{summary.durationAvailability}</dd>
        </div>
        <div>
          <dt>Latency envelope</dt>
          <dd>{summary.latencyClosure}</dd>
        </div>
        <div>
          <dt>Live blocker</dt>
          <dd>{summary.liveBlockerStatus}</dd>
        </div>
        <div>
          <dt>Artifact generated</dt>
          <dd>{summary.generatedAt}</dd>
        </div>
        <div>
          <dt>Current commit</dt>
          <dd>{summary.currentCommit}</dd>
        </div>
        <div>
          <dt>Proof mode</dt>
          <dd>{summary.provenanceMode}</dd>
        </div>
        <div>
          <dt>Proof closure</dt>
          <dd>{summary.proofClosure}</dd>
        </div>
        <div>
          <dt>Freshness/replay</dt>
          <dd>{summary.freshnessReplay}</dd>
        </div>
        <div>
          <dt>Stale/simulated marker</dt>
          <dd>{summary.staleSimulatedMarker}</dd>
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

export function promptProtectionEvidenceReadback(
  value: JsonValue | null | undefined,
): PromptProtectionEvidenceReadback | null {
  const record = findPromptProtectionRecord(value);

  if (!record) {
    return null;
  }

  return {
    auditReadiness: auditReadinessField(record),
    closureChecklist: closureChecklistItems(record),
    closureGaps: closureGapItems(record),
    closureRule: closureRuleField(record),
    currentCommit: currentCommitField(record),
    durationAvailability: durationAvailabilityField(record),
    freshnessReplay: freshnessReplayField(record),
    latencyEnvelope: latencyClosureField(record),
    omittedMaterial: omittedMaterialField(record),
    proofClosure: proofClosureField(record),
    proofEvidence: proofEvidenceItems(record),
    proofMode: provenanceModeField(record),
    providerAttempts: providerAttemptsField(record),
    schema: "prompt_protection_evidence_readback_v1",
  };
}

function promptProtectionEvidenceReadbackFromImport(
  value: JsonValue | PromptProtectionEvidenceReadback | null | undefined,
): PromptProtectionEvidenceReadback | null {
  if (value === null || value === undefined) {
    return null;
  }

  if (!isJsonRecord(value)) {
    return null;
  }

  const record = value as Record<string, JsonValue>;

  if (isJsonRecord(record.audit_handoff_bridge)) {
    return promptProtectionEvidenceReadbackFromImport(record.audit_handoff_bridge);
  }

  if (isJsonRecord(record.admin_ui_readback)) {
    return promptProtectionEvidenceReadbackFromImport(record.admin_ui_readback);
  }

  if (record.schema !== "prompt_protection_evidence_readback_v1") {
    return promptProtectionEvidenceReadback(record);
  }

  return {
    auditReadiness: enumField(record.auditReadiness),
    closureChecklist: listItems(record.closureChecklist),
    closureGaps: listItems(record.closureGaps),
    closureRule: safeReadbackText(record.closureRule),
    currentCommit: safeReadbackText(record.currentCommit),
    durationAvailability: safeReadbackText(record.durationAvailability),
    freshnessReplay: enumField(record.freshnessReplay),
    latencyEnvelope: safeReadbackText(record.latencyEnvelope),
    omittedMaterial: safeReadbackText(record.omittedMaterial),
    proofClosure: safeReadbackText(record.proofClosure),
    proofEvidence: listItems(record.proofEvidence),
    proofMode: safeReadbackText(record.proofMode),
    providerAttempts: safeReadbackText(record.providerAttempts),
    schema: "prompt_protection_evidence_readback_v1",
  };
}

export function promptProtectionAuditClosureGate(
  value: JsonValue | PromptProtectionEvidenceReadback | null | undefined,
): PromptProtectionAuditClosureGate | null {
  const readback = promptProtectionEvidenceReadbackFromImport(value);

  if (!readback) {
    return null;
  }

  const gaps = new Set(readback.closureGaps.filter((gap) => gap !== "none"));
  let fail = readback.auditReadiness === "fail";

  if (readback.providerAttempts === "-") {
    gaps.add("provider_attempts_missing");
  } else if (/^\d+$/.test(readback.providerAttempts) && readback.providerAttempts !== "0") {
    gaps.add("provider_attempts_nonzero");
    fail = true;
  } else if (readback.providerAttempts !== "0") {
    gaps.add("provider_attempts_missing");
  }

  if (readback.latencyEnvelope !== "eligible") {
    gaps.add("latency_envelope_missing_or_ineligible");
  }

  if (!readback.durationAvailability.startsWith("total ")) {
    gaps.add("duration_unavailable");
  }

  if (readback.proofMode !== "live / live") {
    gaps.add("current_live_proof_missing");
  }

  if (readback.proofClosure !== "eligible") {
    gaps.add("proof_closure_not_eligible");
  }

  if (readback.freshnessReplay !== "current_live_proof") {
    gaps.add("freshness_replay_refused");

    if (readback.freshnessReplay !== "simulated_replay_refused") {
      fail = true;
    }
  }

  const normalizedGaps = Array.from(gaps).slice(0, 12);
  const closureEligible = normalizedGaps.length === 0 && readback.auditReadiness === "pass";
  const hasExternalBlocker = normalizedGaps.includes("external_blocker") || readback.auditReadiness === "blocker";
  const classification = closureEligible ? "pass" : hasExternalBlocker ? "blocker" : fail ? "fail" : "blocker";

  return {
    classification,
    closureEligible,
    gaps: normalizedGaps,
    readback,
    schema: "prompt_protection_audit_closure_gate_v1",
  };
}

function summarizePromptProtection(value: JsonValue | null | undefined): PromptProtectionSummaryData | null {
  const record = findPromptProtectionRecord(value);

  if (!record) {
    return null;
  }

  return {
    action: enumField(record.action),
    auditReadiness: auditReadinessField(record),
    closureChecklist: closureChecklistField(record),
    closureGaps: closureGapsField(record),
    closureRule: closureRuleField(record),
    configuredActions: countMapField(record.configured_actions),
    configuredHitCount: numberField(record.configured_hit_count),
    configuredPatternTypes: countMapField(record.configured_pattern_types),
    configuredRuleCount: configuredRuleCount(record.configured_rules),
    currentCommit: currentCommitField(record),
    defaultHitCount: numberField(record.default_hit_count),
    detectedAction: enumField(record.detected_action),
    durationAvailability: durationAvailabilityField(record),
    effectiveAction: enumField(record.effective_action),
    freshnessReplay: freshnessReplayField(record),
    generatedAt: generatedAtField(record),
    hitCount: numberField(record.hit_count),
    hitKinds: countMapField(record.hit_kinds),
    latencyClosure: latencyClosureField(record),
    liveBlockerStatus: liveBlockerStatusField(record),
    mode: enumField(record.mode),
    omittedMaterial: omittedMaterialField(record),
    providerAttempts: providerAttemptsField(record),
    proofClosure: proofClosureField(record),
    proofCommand: proofCommandField(record),
    proofEvidence: proofEvidenceField(record),
    provenanceMode: provenanceModeField(record),
    reason: enumField(record.reason),
    scopes: listField(record.scopes),
    staleSimulatedMarker: staleSimulatedMarkerField(record),
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

function providerAttemptsField(record: Record<string, JsonValue>): string {
  const direct = numberField(record.provider_attempts_count);

  if (direct !== "-") {
    return direct;
  }

  if (isJsonRecord(record.provider_side_effects)) {
    const nested = numberField(record.provider_side_effects.provider_attempts_count);

    if (nested !== "-") {
      return nested;
    }
  }

  if (isJsonRecord(record.performance_envelope) && record.performance_envelope.provider_attempts_zero_required === true) {
    return "0 required";
  }

  return "-";
}

function durationAvailabilityField(record: Record<string, JsonValue>): string {
  const performance = isJsonRecord(record.performance) ? record.performance : null;
  const durationAvailable = performance?.duration_available;

  if (durationAvailable === true) {
    const total = numberField(performance?.total_case_duration_ms);
    const request = numberField(performance?.request_preflight_duration_ms);
    const db = numberField(performance?.db_evidence_duration_ms);

    return `total ${total} ms / preflight ${request} ms / db ${db} ms`;
  }

  if (durationAvailable === false) {
    const reason = enumField(performance?.unavailable_reason);

    return reason === "-" ? "unavailable" : `unavailable: ${reason}`;
  }

  if (isJsonRecord(record.performance_envelope)) {
    const marker =
      record.performance_envelope.duration_unavailable_marker === "duration_available=false"
        ? "duration_available=false"
        : enumField(record.performance_envelope.duration_unavailable_marker);

    if (marker !== "-") {
      return marker;
    }
  }

  return "-";
}

function latencyClosureField(record: Record<string, JsonValue>): string {
  const envelope = isJsonRecord(record.performance_envelope) ? record.performance_envelope : null;

  if (!envelope) {
    return "-";
  }

  const closure = envelope.latency_envelope_closure_eligible;
  const withinBounds = envelope.all_endpoint_performance_within_bounds;

  if (closure === true) {
    return "eligible";
  }

  if (closure === false && withinBounds === true) {
    return "not eligible";
  }

  if (closure === false && withinBounds === false) {
    return "not eligible, out of bounds or unavailable";
  }

  return "-";
}

function liveBlockerStatusField(record: Record<string, JsonValue>): string {
  if (!isJsonRecord(record.performance_envelope)) {
    return "-";
  }

  return enumField(record.performance_envelope.live_blocker_status);
}

function generatedAtField(record: Record<string, JsonValue>): string {
  const direct = isoDateField(record.generated_at_utc);

  if (direct !== "-") {
    return direct;
  }

  if (isJsonRecord(record.provenance)) {
    return isoDateField(record.provenance.generated_at_utc);
  }

  if (isJsonRecord(record.freshness)) {
    return isoDateField(record.freshness.generated_at_utc);
  }

  return "-";
}

function currentCommitField(record: Record<string, JsonValue>): string {
  if (isJsonRecord(record.freshness)) {
    const commit = commitField(record.freshness.repo_head_commit);

    if (commit !== "-") {
      return commit;
    }
  }

  if (isJsonRecord(record.provenance) && isJsonRecord(record.provenance.repo)) {
    return commitField(record.provenance.repo.head_commit);
  }

  return "-";
}

function provenanceModeField(record: Record<string, JsonValue>): string {
  if (!isJsonRecord(record.provenance)) {
    return "-";
  }

  const mode = enumField(record.provenance.mode);
  const kind = enumField(record.provenance.kind);

  if (mode === "-" && kind === "-") {
    return "-";
  }

  if (mode === "-") {
    return kind;
  }

  return kind === "-" ? mode : `${mode} / ${kind}`;
}

function proofClosureField(record: Record<string, JsonValue>): string {
  if (!isJsonRecord(record.freshness)) {
    return "-";
  }

  const eligible = record.freshness.live_evidence_closure_eligible;

  if (eligible === true) {
    return "eligible";
  }

  if (eligible === false) {
    return "not eligible";
  }

  return "-";
}

function staleSimulatedMarkerField(record: Record<string, JsonValue>): string {
  if (!isJsonRecord(record.freshness)) {
    return "-";
  }

  const marker = record.freshness.stale_or_simulated_report_closes_live_gap;

  if (marker === false) {
    if (record.freshness.live_evidence_closure_eligible === true) {
      return "current live proof";
    }

    return "cannot close live gap";
  }

  if (marker === true) {
    return "[redacted]";
  }

  return "-";
}

function freshnessReplayField(record: Record<string, JsonValue>): string {
  const handoff = auditHandoffRecord(record);

  if (handoff) {
    const handoffClassification = enumField(
      handoff.freshness_replay_classification ?? handoff.replay_classification,
    );

    if (handoffClassification !== "-") {
      return handoffClassification;
    }
  }

  if (!isJsonRecord(record.freshness)) {
    return "-";
  }

  const explicit = enumField(
    record.freshness.freshness_replay_classification ??
      record.freshness.replay_classification ??
      record.freshness.classification,
  );

  if (explicit !== "-") {
    return explicit;
  }

  if (record.freshness.live_evidence_closure_eligible === true) {
    return "current_live_proof";
  }

  if (record.freshness.stale_or_simulated_report_closes_live_gap === false) {
    const provenance = isJsonRecord(record.provenance) ? record.provenance : null;
    const kind = provenance ? enumField(provenance.kind) : "-";

    if (kind === "simulated") {
      return "simulated_replay_refused";
    }
  }

  return "-";
}

function auditReadinessField(record: Record<string, JsonValue>): string {
  const handoff = auditHandoffRecord(record);

  if (!handoff) {
    return "-";
  }

  return enumField(handoff.classification);
}

function proofCommandField(record: Record<string, JsonValue>): string {
  const handoff = auditHandoffRecord(record);

  if (!handoff) {
    return "-";
  }

  return enumField(handoff.command_summary);
}

function proofEvidenceField(record: Record<string, JsonValue>): string {
  const handoff = auditHandoffRecord(record);

  if (!handoff) {
    return "-";
  }

  return listField(handoff.evidence_fields);
}

function proofEvidenceItems(record: Record<string, JsonValue>): string[] {
  const handoff = auditHandoffRecord(record);

  if (!handoff) {
    return [];
  }

  return listItems(handoff.evidence_fields);
}

function closureRuleField(record: Record<string, JsonValue>): string {
  const handoff = auditHandoffRecord(record);

  if (!handoff) {
    return "-";
  }

  const rules = [
    handoff.provider_attempts_zero_required === true ? "provider_attempts=0" : null,
    handoff.latency_envelope_required === true ? "latency bounded" : null,
    handoff.duration_available_required === true ? "duration available" : null,
    handoff.current_provenance_required === true ? "current provenance" : null,
  ].filter((rule): rule is string => Boolean(rule));

  return rules.length > 0 ? rules.join(", ") : "-";
}

function closureChecklistField(record: Record<string, JsonValue>): string {
  const handoff = auditHandoffRecord(record);

  if (!handoff) {
    return "-";
  }

  return listField(handoff.closure_checklist);
}

function closureChecklistItems(record: Record<string, JsonValue>): string[] {
  const handoff = auditHandoffRecord(record);

  if (!handoff) {
    return [];
  }

  return listItems(handoff.closure_checklist);
}

function closureGapsField(record: Record<string, JsonValue>): string {
  const handoff = auditHandoffRecord(record);

  if (!handoff) {
    return "-";
  }

  return listField(handoff.closure_gaps);
}

function closureGapItems(record: Record<string, JsonValue>): string[] {
  const handoff = auditHandoffRecord(record);

  if (!handoff) {
    return [];
  }

  return listItems(handoff.closure_gaps);
}

function auditHandoffRecord(record: Record<string, JsonValue>): Record<string, JsonValue> | null {
  if (isJsonRecord(record.audit_readiness)) {
    return record.audit_readiness;
  }

  if (isJsonRecord(record.audit_handoff)) {
    return record.audit_handoff;
  }

  if (isJsonRecord(record.proof_handoff)) {
    return record.proof_handoff;
  }

  return null;
}

function isoDateField(value: JsonValue | undefined): string {
  if (typeof value !== "string") {
    return "-";
  }

  const trimmed = value.trim();
  const match = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/.exec(trimmed);

  return match ? safeFieldValue(`${match[1]}Z`) : "-";
}

function commitField(value: JsonValue | undefined): string {
  if (typeof value !== "string") {
    return "-";
  }

  const trimmed = value.trim().toLowerCase();

  if (trimmed === "unavailable") {
    return "unavailable";
  }

  return /^[0-9a-f]{40}$/.test(trimmed) ? trimmed.slice(0, 12) : "-";
}

function listItems(value: JsonValue | undefined): string[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .map((item) => enumField(item))
    .filter((item) => item !== "-")
    .slice(0, 8);
}

function safeReadbackText(value: JsonValue | undefined): string {
  if (typeof value !== "string") {
    return "-";
  }

  const safeValue = safeFieldValue(value.trim()).slice(0, 160);

  if (safeValue === "-" || safeValue === "[redacted]") {
    return safeValue;
  }

  return /^[a-z0-9_.,:=/ +()-]{1,160}$/i.test(safeValue) ? safeValue : "[redacted]";
}
