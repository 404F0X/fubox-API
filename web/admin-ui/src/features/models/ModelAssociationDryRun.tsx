import { FormEvent, useEffect, useState } from "react";
import {
  type CanonicalModel,
  dryRunModelAssociation,
  type JsonValue,
  type ModelAssociationDryRunCandidate,
  type ModelAssociationDryRunRequest,
  type ModelAssociationDryRunResponse,
  type PriceVersion,
} from "../../api/client";
import { StateChip, errorMessage, isJsonRecord, jsonSize, safeFieldValue, sanitizeSecretJson, shortId } from "../../components/adminUtils";
import { Search } from "../../components/icons";
import { safeRoutingErrorMessage } from "../../lib/safeText";
import { ModelPriceSummary, type TokenEstimateInput } from "./ModelPriceSummary";

type FormState = {
  cacheTokens: string;
  canonicalModelId: string;
  canonicalModelKey: string;
  inputTokens: string;
  outputTokens: string;
  previousChannelId: string;
  profileId: string;
  reasoningTokens: string;
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
  cacheTokens: "",
  canonicalModelId: "",
  canonicalModelKey: "",
  inputTokens: "",
  outputTokens: "",
  previousChannelId: "",
  profileId: "",
  reasoningTokens: "",
  projectId: "",
  requestedModel: "",
  seed: "",
  traceId: "",
};

const modelKeyListId = "dry-run-model-key-options";
const modelIdListId = "dry-run-model-id-options";

const fields: FieldConfig[] = [
  { label: "项目 ID", name: "projectId", required: true },
  { label: "配置 ID", name: "profileId", required: true },
  { label: "请求模型", name: "requestedModel" },
  { label: "规范模型 key", list: modelKeyListId, name: "canonicalModelKey" },
  { label: "规范模型 ID", list: modelIdListId, name: "canonicalModelId" },
  { label: "随机种子", inputMode: "numeric", name: "seed", type: "number" },
  { label: "Trace ID", name: "traceId" },
  { label: "上次成功渠道 ID", name: "previousChannelId" },
  { label: "示例 input tokens", inputMode: "numeric", name: "inputTokens", type: "number" },
  { label: "示例 output tokens", inputMode: "numeric", name: "outputTokens", type: "number" },
  { label: "示例 cache tokens", inputMode: "numeric", name: "cacheTokens", type: "number" },
  { label: "示例 reasoning tokens", inputMode: "numeric", name: "reasoningTokens", type: "number" },
];

export function ModelAssociationDryRun({
  initialForm,
  models = [],
  priceVersions = [],
}: {
  initialForm?: Partial<FormState>;
  models?: CanonicalModel[];
  priceVersions?: PriceVersion[];
}) {
  const [error, setError] = useState<string | null>(null);
  const [estimate, setEstimate] = useState<TokenEstimateInput>({});
  const [form, setForm] = useState<FormState>(defaultForm);
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<ModelAssociationDryRunResponse | null>(null);

  useEffect(() => {
    if (!initialForm) {
      return;
    }

    setForm((current) => ({
      ...current,
      ...initialForm,
    }));
  }, [initialForm]);

  async function runDryRun(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    try {
      const request = toRequest(form);
      const nextEstimate = tokenEstimateFromForm(form);
      setError(null);
      setLoading(true);
      setEstimate(nextEstimate);
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
      <section className="admin-panel" aria-label="模型关联 dry-run">
        <h2>模型关联 Dry-run</h2>
        <p>预览路由选择，不发起上游调用，也不暴露凭据材料。</p>

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
            {loading ? "运行中" : "运行 dry-run"}
          </button>
        </form>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
      </section>

      {result ? <DryRunResult estimate={estimate} models={models} priceVersions={priceVersions} result={result} /> : null}
    </>
  );
}

function DryRunResult({
  estimate,
  models,
  priceVersions,
  result,
}: {
  estimate: TokenEstimateInput;
  models: CanonicalModel[];
  priceVersions: PriceVersion[];
  result: ModelAssociationDryRunResponse;
}) {
  const snapshot = summarizeRouteSnapshot(result.route_decision_snapshot);
  const overrideSummary = summarizeRequestOverrides(result);
  const pricedModel = modelForDryRunResult(result, models);

  return (
    <section className="detail-grid" aria-label="模型关联 dry-run 结果">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>选择结果</h2>
            <p>{safeFieldValue(result.requested_model)}</p>
          </div>
          <StateChip status={safeFieldValue(result.selection.status)} />
        </div>
        <Fields
          items={[
            ["项目", safeShortId(result.project_id)],
            ["配置", safeShortId(result.profile_id)],
            ["规范模型", canonicalModelLabel(result)],
            ["选中项", selectedSummary(result.selection.selected)],
            ["选中渠道", safeShortId(result.selection.selected_channel_id)],
            ["候选数", result.candidates.length],
          ]}
        />
      </article>

      <SelectedCandidate candidate={result.selected_candidate} />

      <article className="admin-panel">
        <h2>价格估算</h2>
        <ModelPriceSummary estimate={estimate} model={pricedModel} priceVersions={priceVersions} />
        <p className="muted-copy">估算只基于当前示例 token 与价格版本摘要；实际 ledger 以网关最终记录为准。</p>
      </article>

      <article className="admin-panel detail-panel--wide">
        <h2>可见性诊断回读</h2>
        <Fields
          items={[
            ["模型决策", result.profile_visibility_readback?.requested_model_decision ?? "-"],
            ["Allowed models", modelListSummary(result.profile_visibility_readback?.allowed_models)],
            ["Denied models", modelListSummary(result.profile_visibility_readback?.denied_models)],
            ["Blocked provider/channel", result.diagnostic_readback?.blocked_provider_channel_reasons?.join(", ") || "-"],
            ["默认价格", result.price_config_presence?.default_price_book_configured ? "已配置" : "未配置"],
            ["协议 readiness", result.diagnostic_readback?.protocol_endpoint_capability_readiness_present ? "已回读" : "无候选项"],
            ["Provider key ready", result.diagnostic_readback?.provider_key_presence.enabled_configured_provider_key_count ?? 0],
            ["下一步", result.diagnostic_readback?.safe_next_action ?? result.price_config_presence?.safe_next_action ?? "-"],
          ]}
        />
      </article>

      <article className="admin-panel detail-panel--wide">
        <h2>路由快照摘要</h2>
        <Fields
          items={[
            ["版本", result.decision_snapshot_version],
            ["策略", result.route_policy_version],
            ["选择状态", routeReasonText(result.selection.status)],
            ["Trace 亲和", traceAffinityStatus(result.trace_affinity)],
            ["快照字段", jsonSize(sanitizeForSummary(result.route_decision_snapshot))],
            ["快照候选", snapshot.candidateCount],
            ["快照选中", snapshot.selected],
            ["快照已过滤", snapshot.filteredCount],
            ["快照过滤原因", snapshot.filterReasons],
          ]}
        />
      </article>

      <article className="admin-panel detail-panel--wide">
        <h2>请求覆盖摘要</h2>
        <Fields
          items={[
            ["配置覆盖", overrideSummary.overrideCount],
            ["覆盖类型", overrideSummary.overrideTypes],
            ["Payload 策略", overrideSummary.payloadPolicy],
            ["配置 IP 允许列表", overrideSummary.profileIpAllowlist],
            ["配置 IP 条目", overrideSummary.profileIpEntryCount],
          ]}
        />
        <div className="policy-grid">
          <JsonPreview label="配置请求覆盖" value={overrideSummary.requestOverrides} />
          <JsonPreview label="覆盖策略快照" value={overrideSummary.policySnapshot} />
        </div>
      </article>

      <article className="admin-panel detail-panel--wide">
        <h2>候选项</h2>
        <CandidateTable candidates={result.candidates} />
      </article>
    </section>
  );
}

function SelectedCandidate({ candidate }: { candidate: ModelAssociationDryRunCandidate | null }) {
  return (
    <article className="admin-panel">
      <h2>选中候选项</h2>
      {candidate ? (
        <Fields
          items={[
            ["渠道", candidate.channel_name],
            ["供应商", candidate.provider_name],
            ["模型", candidate.upstream_model ?? candidate.provider_model ?? "-"],
            ["允许回退", candidate.fallback_allowed ? "是" : "否"],
            ["过滤原因", routeReasonText(candidate.filter_reason)],
          ]}
        />
      ) : (
        <p className="muted-copy">未选中候选项。</p>
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
            <th>候选项</th>
            <th>供应商</th>
            <th>回退</th>
            <th>过滤原因</th>
            <th>是否选中</th>
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
                <td>{candidate.fallback_allowed ? "允许回退" : "阻止回退"}</td>
                <td>{routeReasonText(candidate.filter_reason)}</td>
                <td>{candidate.selected ? "是" : "否"}</td>
              </tr>
            ))
          ) : (
            <tr>
              <td colSpan={5}>暂无路由候选项。</td>
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
    throw new Error("请求模型、规范模型 key 或规范模型 ID 至少需要填写一项。");
  }

  if (seed) {
    const parsed = Number(seed);
    if (!Number.isInteger(parsed)) {
      throw new Error("随机种子必须是整数。");
    }
    request.seed = parsed;
  }

  return request;
}

function tokenEstimateFromForm(form: FormState): TokenEstimateInput {
  return {
    cacheTokens: optionalNonNegativeNumber(form.cacheTokens, "示例 cache tokens"),
    inputTokens: optionalNonNegativeNumber(form.inputTokens, "示例 input tokens"),
    outputTokens: optionalNonNegativeNumber(form.outputTokens, "示例 output tokens"),
    reasoningTokens: optionalNonNegativeNumber(form.reasoningTokens, "示例 reasoning tokens"),
  };
}

function optionalNonNegativeNumber(value: string, label: string): number | null {
  const trimmed = value.trim();

  if (!trimmed) {
    return null;
  }

  const parsed = Number(trimmed);

  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`${label}必须是大于等于 0 的数字。`);
  }

  return parsed;
}

function modelForDryRunResult(
  result: ModelAssociationDryRunResponse,
  models: CanonicalModel[],
): CanonicalModel | null {
  const canonical = result.canonical_model;

  if (!canonical) {
    return null;
  }

  return (
    models.find((model) => model.id === canonical.id) ??
    ({
      capabilities: {},
      context_length: null,
      default_price_book_id: null,
      display_name: canonical.display_name,
      family: canonical.family,
      id: canonical.id,
      max_output_tokens: null,
      model_key: canonical.model_key,
      status: canonical.status,
      supports_audio: false,
      supports_reasoning: false,
      supports_stream: false,
      supports_tools: false,
      supports_vision: false,
      tenant_id: "",
      visibility: "public",
    } satisfies CanonicalModel)
  );
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

function modelListSummary(value: { count: number; mode?: string; models?: string[] } | undefined): string {
  if (!value) {
    return "-";
  }

  if (value.mode === "all_visible_models") {
    return "全部可见模型";
  }

  if (!value.models || value.models.length === 0) {
    return "0";
  }

  return value.models.slice(0, 5).map(safeFieldValue).join(", ");
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
    return `${value.length} 个条目`;
  }

  return withOverflow(parts.join(", "), value.length, parts.length);
}

function selectedSummary(value: JsonValue): string {
  const selected = sanitizeForSummary(value);

  if (!isJsonRecord(selected)) {
    return safeFieldValue(selected);
  }

  const parts = [
    fieldPart("渠道", scalarValue(selected.channel_id)),
    fieldPart("供应商", scalarValue(selected.provider_id)),
    fieldPart("模型", scalarValue(selected.upstream_model ?? selected.provider_model)),
    fieldPart("权重", scalarValue(selected.weight)),
  ].filter((part) => part.length > 0);

  return parts.length > 0 ? parts.join(" / ") : `${jsonSize(selected)} 个字段`;
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
      .map(routeReasonText),
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

function routeReasonText(value: unknown): string {
  return safeRoutingErrorMessage(value) ?? safeFieldValue(value);
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
