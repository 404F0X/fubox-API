import { FormEvent, useState } from "react";
import {
  type CanonicalModel,
  dryRunModelAssociation,
  type JsonValue,
  type ModelAssociationDryRunCandidate,
  type ModelAssociationDryRunRequest,
  type ModelAssociationDryRunResponse,
} from "../api/client";
import { StateChip, errorMessage, isJsonRecord, jsonSize, safeFieldValue, sanitizeSecretJson, shortId } from "./adminUtils";
import { Search } from "./icons";

type FormState = {
  canonicalModelId: string;
  canonicalModelKey: string;
  previousChannelId: string;
  profileId: string;
  projectId: string;
  requestedModel: string;
  seed: string;
  traceId: string;
};

type FieldConfig = {
  inputMode?: "numeric";
  label: string;
  list?: string;
  name: keyof FormState;
  required?: boolean;
  type?: "number" | "text";
};

const defaultForm: FormState = {
  canonicalModelId: "",
  canonicalModelKey: "",
  previousChannelId: "",
  profileId: "",
  projectId: "",
  requestedModel: "",
  seed: "",
  traceId: "",
};

const modelKeyListId = "dry-run-model-key-options";
const modelIdListId = "dry-run-model-id-options";

const fields: FieldConfig[] = [
  { label: "Project ID", name: "projectId", required: true },
  { label: "Profile ID", name: "profileId", required: true },
  { label: "Requested model", name: "requestedModel" },
  { label: "Canonical model key", list: modelKeyListId, name: "canonicalModelKey" },
  { label: "Canonical model ID", list: modelIdListId, name: "canonicalModelId" },
  { label: "Seed", inputMode: "numeric", name: "seed", type: "number" },
  { label: "Trace ID", name: "traceId" },
  { label: "Previous successful channel ID", name: "previousChannelId" },
];

export function ModelAssociationDryRun({ models = [] }: { models?: CanonicalModel[] }) {
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState<FormState>(defaultForm);
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<ModelAssociationDryRunResponse | null>(null);

  async function runDryRun(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    try {
      const request = toRequest(form);
      setError(null);
      setLoading(true);
      setResult(await dryRunModelAssociation(request));
    } catch (requestError) {
      setError(errorMessage(requestError));
      setResult(null);
    } finally {
      setLoading(false);
    }
  }

  return (
    <>
      <section className="admin-panel" aria-label="Model association dry-run">
        <h2>Model Association Dry-run</h2>
        <p>Preview route selection without upstream calls or credential material.</p>

        <form className="provider-form" onSubmit={runDryRun}>
          <div className="form-grid form-grid--three">
            {fields.map((field) => (
              <label className="field" key={field.name}>
                {field.label}
                <input
                  inputMode={field.inputMode}
                  list={field.list}
                  onChange={(event) => {
                    const value = event.currentTarget.value;
                    setForm((current) => ({ ...current, [field.name]: value }));
                  }}
                  required={field.required}
                  type={field.type ?? "text"}
                  value={form[field.name]}
                />
              </label>
            ))}
            <datalist id={modelKeyListId}>
              {models.map((model) => (
                <option key={model.id} value={model.model_key}>
                  {model.display_name}
                </option>
              ))}
            </datalist>
            <datalist id={modelIdListId}>
              {models.map((model) => (
                <option key={model.id} value={model.id}>
                  {model.model_key}
                </option>
              ))}
            </datalist>
          </div>

          <button className="primary-button primary-button--inline" type="submit" disabled={loading}>
            <Search aria-hidden="true" size={17} />
            {loading ? "Running" : "Run dry-run"}
          </button>
        </form>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
      </section>

      {result ? <DryRunResult result={result} /> : null}
    </>
  );
}

function DryRunResult({ result }: { result: ModelAssociationDryRunResponse }) {
  const snapshot = summarizeRouteSnapshot(result.route_decision_snapshot);
  const overrideSummary = summarizeRequestOverrides(result);

  return (
    <section className="detail-grid" aria-label="Model association dry-run result">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>Selection</h2>
            <p>{safeFieldValue(result.requested_model)}</p>
          </div>
          <StateChip status={safeFieldValue(result.selection.status)} />
        </div>
        <Fields
          items={[
            ["Project", safeShortId(result.project_id)],
            ["Profile", safeShortId(result.profile_id)],
            ["Canonical model", canonicalModelLabel(result)],
            ["Selected", selectedSummary(result.selection.selected)],
            ["Selected channel", safeShortId(result.selection.selected_channel_id)],
            ["Candidates", result.candidates.length],
          ]}
        />
      </article>

      <SelectedCandidate candidate={result.selected_candidate} />

      <article className="admin-panel detail-panel--wide">
        <h2>Route Snapshot Summary</h2>
        <Fields
          items={[
            ["Version", result.decision_snapshot_version],
            ["Policy", result.route_policy_version],
            ["Selection status", result.selection.status],
            ["Trace affinity", traceAffinityStatus(result.trace_affinity)],
            ["Snapshot fields", jsonSize(sanitizeForSummary(result.route_decision_snapshot))],
            ["Snapshot candidates", snapshot.candidateCount],
            ["Snapshot selected", snapshot.selected],
            ["Snapshot filtered", snapshot.filteredCount],
            ["Snapshot filter reasons", snapshot.filterReasons],
          ]}
        />
      </article>

      <article className="admin-panel detail-panel--wide">
        <h2>Request Override Summary</h2>
        <Fields
          items={[
            ["Profile overrides", overrideSummary.overrideCount],
            ["Override types", overrideSummary.overrideTypes],
            ["Payload policy", overrideSummary.payloadPolicy],
            ["Profile IP allowlist", overrideSummary.profileIpAllowlist],
            ["Profile IP entries", overrideSummary.profileIpEntryCount],
          ]}
        />
        <div className="policy-grid">
          <JsonPreview label="Profile request overrides" value={overrideSummary.requestOverrides} />
          <JsonPreview label="Override policy snapshot" value={overrideSummary.policySnapshot} />
        </div>
      </article>

      <article className="admin-panel detail-panel--wide">
        <h2>Candidates</h2>
        <CandidateTable candidates={result.candidates} />
      </article>
    </section>
  );
}

function SelectedCandidate({ candidate }: { candidate: ModelAssociationDryRunCandidate | null }) {
  return (
    <article className="admin-panel">
      <h2>Selected Candidate</h2>
      {candidate ? (
        <Fields
          items={[
            ["Channel", candidate.channel_name],
            ["Provider", candidate.provider_name],
            ["Model", candidate.upstream_model ?? candidate.provider_model ?? "-"],
            ["Fallback allowed", candidate.fallback_allowed ? "Yes" : "No"],
            ["Filter reason", candidate.filter_reason],
          ]}
        />
      ) : (
        <p className="muted-copy">No candidate selected.</p>
      )}
    </article>
  );
}

function CandidateTable({ candidates }: { candidates: ModelAssociationDryRunCandidate[] }) {
  return (
    <div className="health-table-wrap">
      <table className="health-table admin-table--attempts">
        <thead>
          <tr>
            <th>Candidate</th>
            <th>Provider</th>
            <th>Fallback</th>
            <th>Filter reason</th>
            <th>Selected</th>
          </tr>
        </thead>
        <tbody>
          {candidates.length > 0 ? (
            candidates.map((candidate) => (
              <tr key={`${candidate.association_id}:${candidate.channel_id}:${candidate.upstream_model ?? candidate.provider_model ?? ""}`}>
                <td>
                  <strong>{safeFieldValue(candidate.channel_name)}</strong>
                  <span>{safeShortId(candidate.channel_id)}</span>
                </td>
                <td>{safeFieldValue(candidate.provider_name)}</td>
                <td>{candidate.fallback_allowed ? "Fallback allowed" : "Fallback blocked"}</td>
                <td>{safeFieldValue(candidate.filter_reason)}</td>
                <td>{candidate.selected ? "Yes" : "No"}</td>
              </tr>
            ))
          ) : (
            <tr>
              <td colSpan={5}>No route candidates returned.</td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

function Fields({ items }: { items: Array<[string, unknown]> }) {
  return (
    <dl className="detail-list">
      {items.map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{safeFieldValue(value)}</dd>
        </div>
      ))}
    </dl>
  );
}

function JsonPreview({ label, value }: { label: string; value: JsonValue }) {
  return (
    <div>
      <strong>{label}</strong>
      <pre className="json-preview">{JSON.stringify(sanitizeForSummary(value), null, 2)}</pre>
    </div>
  );
}

function toRequest(form: FormState): ModelAssociationDryRunRequest {
  const seed = form.seed.trim();
  const request: ModelAssociationDryRunRequest = {
    canonical_model_id: optional(form.canonicalModelId),
    canonical_model_key: optional(form.canonicalModelKey),
    previous_successful_channel_id: optional(form.previousChannelId),
    profile_id: form.profileId.trim(),
    project_id: form.projectId.trim(),
    requested_model: optional(form.requestedModel),
    trace_id: optional(form.traceId),
  };

  if (!request.requested_model && !request.canonical_model_key && !request.canonical_model_id) {
    throw new Error("Requested model, canonical model key, or canonical model ID is required.");
  }

  if (seed) {
    const parsed = Number(seed);
    if (!Number.isInteger(parsed)) {
      throw new Error("Seed must be an integer.");
    }
    request.seed = parsed;
  }

  return request;
}

function summarizeRequestOverrides(result: ModelAssociationDryRunResponse): {
  overrideCount: string;
  overrideTypes: string;
  payloadPolicy: string;
  policySnapshot: JsonValue;
  profileIpAllowlist: string;
  profileIpEntryCount: string;
  requestOverrides: JsonValue;
} {
  const sources = [result.policy, result.route_decision_snapshot];
  const requestOverrides = firstJsonArrayByKey(sources, ["profile_request_overrides", "request_overrides"]) ?? [];
  const profileIpAllowlist = firstJsonArrayByKey(sources, ["profile_ip_allowlist", "ip_allowlist"]) ?? allowlistFromOverrides(requestOverrides);
  const overrideTypes = uniqueValues(
    requestOverrides
      .map((override) => (isJsonRecord(override) ? scalarValue(override.type ?? override.kind ?? override.policy_type) : undefined))
      .filter((type): type is string => typeof type === "string" && type.trim().length > 0)
      .map(safeFieldValue),
  );
  const payloadPolicy = firstScalarByKey(sources, ["payload_policy_id", "payload_policy", "profile_payload_policy"]);
  const policySnapshot = compactJsonObject({
    payload_policy: payloadPolicy,
    profile_ip_allowlist: profileIpAllowlist,
    request_overrides: requestOverrides,
  });

  return {
    overrideCount: String(requestOverrides.length),
    overrideTypes: overrideTypes.length > 0 ? overrideTypes.slice(0, 4).join(", ") : "-",
    payloadPolicy: payloadPolicy ?? "-",
    policySnapshot,
    profileIpAllowlist: summarizeJsonList(profileIpAllowlist),
    profileIpEntryCount: String(profileIpAllowlist.length),
    requestOverrides,
  };
}

function canonicalModelLabel(result: ModelAssociationDryRunResponse): string {
  const model = result.canonical_model;

  if (!model) {
    return "-";
  }

  return `${model.model_key} (${safeShortId(model.id)})`;
}

function firstJsonArrayByKey(values: JsonValue[], keys: string[]): JsonValue[] | undefined {
  for (const value of values) {
    const match = findJsonValueByKey(value, keys);

    if (Array.isArray(match)) {
      return sanitizeForSummary(match) as JsonValue[];
    }
  }

  return undefined;
}

function firstScalarByKey(values: JsonValue[], keys: string[]): string | undefined {
  for (const value of values) {
    const match = findJsonValueByKey(value, keys);
    const scalar = scalarValue(match);

    if (scalar !== undefined) {
      return safeFieldValue(scalar);
    }
  }

  return undefined;
}

function findJsonValueByKey(value: JsonValue, keys: string[]): JsonValue | undefined {
  if (Array.isArray(value)) {
    for (const child of value) {
      const match = findJsonValueByKey(child, keys);

      if (match !== undefined) {
        return match;
      }
    }

    return undefined;
  }

  if (!isJsonRecord(value)) {
    return undefined;
  }

  for (const [key, child] of Object.entries(value)) {
    if (keys.includes(key)) {
      return child;
    }
  }

  for (const child of Object.values(value)) {
    const match = findJsonValueByKey(child, keys);

    if (match !== undefined) {
      return match;
    }
  }

  return undefined;
}

function allowlistFromOverrides(overrides: JsonValue[]): JsonValue[] {
  for (const override of overrides) {
    if (!isJsonRecord(override)) {
      continue;
    }

    const type = scalarValue(override.type ?? override.kind ?? override.policy_type);

    if (type === "profile_ip_allowlist" && Array.isArray(override.allowlist)) {
      return sanitizeForSummary(override.allowlist) as JsonValue[];
    }
  }

  return [];
}

function compactJsonObject(value: Record<string, JsonValue | string | undefined>): JsonValue {
  return Object.fromEntries(
    Object.entries(value)
      .filter(([, child]) => child !== undefined)
      .map(([key, child]) => [key, typeof child === "string" ? child : child]),
  ) as JsonValue;
}

function summarizeJsonList(value: JsonValue[]): string {
  if (value.length === 0) {
    return "-";
  }

  const parts = value
    .slice(0, 3)
    .map(scalarValue)
    .filter((part): part is string => part !== undefined)
    .map(safeFieldValue);

  if (parts.length !== value.slice(0, 3).length) {
    return `${value.length} entries`;
  }

  return withOverflow(parts.join(", "), value.length, parts.length);
}

function selectedSummary(value: JsonValue): string {
  const selected = sanitizeForSummary(value);

  if (!isJsonRecord(selected)) {
    return safeFieldValue(selected);
  }

  const parts = [
    fieldPart("channel", scalarValue(selected.channel_id)),
    fieldPart("provider", scalarValue(selected.provider_id)),
    fieldPart("model", scalarValue(selected.upstream_model ?? selected.provider_model)),
    fieldPart("weight", scalarValue(selected.weight)),
  ].filter((part) => part.length > 0);

  return parts.length > 0 ? parts.join(" / ") : `${jsonSize(selected)} fields`;
}

function traceAffinityStatus(value: JsonValue): string {
  const traceAffinity = sanitizeForSummary(value);

  if (isJsonRecord(traceAffinity) && typeof traceAffinity.status === "string") {
    return traceAffinity.status;
  }

  return "-";
}

function summarizeRouteSnapshot(value: JsonValue): {
  candidateCount: string;
  filteredCount: string;
  filterReasons: string;
  selected: string;
} {
  const snapshot = sanitizeForSummary(value);

  if (!isJsonRecord(snapshot)) {
    return {
      candidateCount: "0",
      filteredCount: "0",
      filterReasons: "-",
      selected: "-",
    };
  }

  const candidates = Array.isArray(snapshot.candidates) ? snapshot.candidates : [];
  const filteredCount = candidates.filter((candidate) => isJsonRecord(candidate) && candidate.filtered === true).length;
  const filterReasons = uniqueValues(
    candidates
      .map((candidate) => (isJsonRecord(candidate) ? scalarValue(candidate.filter_reason) : undefined))
      .filter((reason): reason is string => typeof reason === "string" && reason.trim().length > 0)
      .map(safeFieldValue),
  );

  return {
    candidateCount: String(candidates.length),
    filteredCount: String(filteredCount),
    filterReasons: filterReasons.length > 0 ? filterReasons.slice(0, 3).join(", ") : "-",
    selected: snapshotSelected(snapshot),
  };
}

function snapshotSelected(snapshot: Record<string, JsonValue>): string {
  const direct = scalarValue(snapshot.selected_channel_id);

  if (direct !== undefined) {
    return safeFieldValue(direct);
  }

  const selected = snapshot.selected;

  if (isJsonRecord(selected)) {
    return selectedSummary(selected);
  }

  return safeFieldValue(selected);
}

function sanitizeForSummary(value: JsonValue): JsonValue {
  return omitUnsafeJsonFields(sanitizeSecretJson(value));
}

function omitUnsafeJsonFields(value: JsonValue): JsonValue {
  if (Array.isArray(value)) {
    return value.map(omitUnsafeJsonFields);
  }

  if (isJsonRecord(value)) {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key]) => !isUnsafeSummaryKey(key))
        .map(([key, child]) => [key, omitUnsafeJsonFields(child)]),
    );
  }

  return value;
}

function isUnsafeSummaryKey(key: string): boolean {
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
    normalized.includes("raw") ||
    normalized.includes("secret") ||
    normalized.includes("token")
  );
}

function fieldPart(label: string, value: string | undefined): string {
  return value === undefined ? "" : `${label} ${safeFieldValue(value)}`;
}

function scalarValue(value: JsonValue | undefined): string | undefined {
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }

  return undefined;
}

function safeShortId(value: string | null | undefined): string {
  if (!value) {
    return "-";
  }

  const safeValue = safeFieldValue(value);

  return safeValue === value ? shortId(value) : safeValue;
}

function uniqueValues(values: string[]): string[] {
  return [...new Set(values)];
}

function withOverflow(summary: string, total: number, shown: number): string {
  const extra = total - shown;

  return extra > 0 ? `${summary} +${extra}` : summary;
}

function optional(value: string): string | undefined {
  return value.trim() || undefined;
}

export default ModelAssociationDryRun;
