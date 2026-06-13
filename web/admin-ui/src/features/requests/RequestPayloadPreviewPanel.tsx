import { useState } from "react";
import {
  getRequestPayloadPreview,
  type JsonValue,
  type RequestLogSummary,
  type RequestPayloadPreview,
} from "../../api/client";
import { ActionButton } from "../../design/ActionButton";
import { SectionHeader } from "../../design/SectionHeader";
import {
  errorMessage,
  isJsonRecord,
  jsonSize,
  safeFieldValue,
  sanitizeDisplayJson,
} from "../../components/adminUtils";
import { Eye } from "../../components/icons";

type PayloadPreviewStatus = "idle" | "loading" | "loaded" | "forbidden" | "not_implemented" | "unavailable" | "error";

export function RequestPayloadPreviewPanel({ log }: { log: RequestLogSummary }) {
  const [message, setMessage] = useState<string | null>(null);
  const [preview, setPreview] = useState<RequestPayloadPreview | null>(null);
  const [status, setStatus] = useState<PayloadPreviewStatus>("idle");
  const canLoadPayload = Boolean(log.payload_stored);
  const previewSections = status === "loaded" && preview ? safePayloadPreviewSections(preview) : [];

  async function loadPayloadPreview() {
    if (!canLoadPayload) {
      return;
    }

    setMessage(null);
    setPreview(null);
    setStatus("loading");

    try {
      const nextPreview = await getRequestPayloadPreview(log.id);
      setPreview(nextPreview);
      setStatus(nextPreview.available === false ? "unavailable" : "loaded");
    } catch (requestError) {
      setPreview(null);

      const statusCode = apiStatusCode(requestError);
      if (statusCode === 403) {
        setStatus("forbidden");
      } else if (statusCode === 404) {
        setStatus("not_implemented");
      } else {
        setMessage(errorMessage(requestError));
        setStatus("error");
      }
    }
  }

  return (
    <article className="admin-panel" aria-label="载荷预览">
      <SectionHeader
        title="载荷预览"
        description={payloadPreviewHeadline(log, status)}
        actions={
          <ActionButton
            aria-label={`加载载荷预览 ${safeFieldValue(log.id)}`}
            disabled={!canLoadPayload || status === "loading"}
            icon={<Eye aria-hidden="true" size={16} />}
            onClick={() => void loadPayloadPreview()}
          >
            {status === "loading" ? "加载中" : preview ? "重新加载预览" : "加载预览"}
          </ActionButton>
        }
      />

      <dl className="detail-list">
        {payloadMetadataRows(log, preview).map(([label, value]) => (
          <div key={label}>
            <dt>{label}</dt>
            <dd>{value}</dd>
          </div>
        ))}
      </dl>

      {status !== "idle" && status !== "loading" ? (
        <p className={`form-status ${status === "loaded" ? "form-status--success" : "form-status--error"}`}>
          {payloadPreviewStatusMessage(status, message)}
        </p>
      ) : null}

      {status === "loaded" ? (
        previewSections.length > 0 ? (
          <div className="payload-preview-grid">
            {previewSections.map((section) => (
              <div className="payload-preview-card" key={section.title}>
                <h3>
                  {section.title}（{jsonSize(section.value)} 个字段）
                </h3>
                <pre className="json-preview">{formatJsonPreview(section.value)}</pre>
              </div>
            ))}
          </div>
        ) : (
          <p className="muted-copy">未返回脱敏预览字段。哈希元数据已显示在上方。</p>
        )
      ) : null}
    </article>
  );
}

function payloadPreviewHeadline(log: RequestLogSummary, status: PayloadPreviewStatus): string {
  if (!log.payload_stored) {
    return "此请求未存储载荷预览。";
  }

  if (status === "loading") {
    return "正在加载脱敏预览元数据。";
  }

  if (status === "loaded") {
    return "脱敏预览元数据已加载。";
  }

  return "无需加载载荷预览即可查看哈希元数据。";
}

function payloadMetadataRows(
  log: RequestLogSummary,
  preview: RequestPayloadPreview | null,
): Array<[string, string]> {
  return [
    ["策略", safeFieldValue(preview?.payload_policy_id ?? log.payload_policy_id)],
    ["已存储", formatBoolean(preview?.payload_stored ?? log.payload_stored)],
    ["脱敏", safeFieldValue(preview?.redaction_status ?? log.redaction_status)],
    ["预览状态", safeFieldValue(preview?.payload_preview_policy_readback?.status)],
    ["点击加载", formatBoolean(preview?.payload_preview_policy_readback?.click_to_load_required)],
    ["原始字段", preview?.payload_preview_policy_readback ? formatRawFieldPolicy(preview) : "-"],
    ["Audit ref", formatBoolean(preview?.payload_preview_policy_readback?.audit_ref_presence.audit_ref_present)],
    ["下一步", safeFieldValue(preview?.payload_preview_policy_readback?.safe_next_action)],
    ["请求哈希", safeFieldValue(preview?.request_body_hash ?? log.request_body_hash)],
    ["响应哈希", safeFieldValue(preview?.response_body_hash ?? log.response_body_hash)],
  ];
}

function formatRawFieldPolicy(preview: RequestPayloadPreview): string {
  const policy = preview.payload_preview_policy_readback?.forbidden_raw_fields_policy;
  if (!policy) {
    return "-";
  }

  const blocked = [
    policy.raw_prompt_returned,
    policy.raw_body_returned,
    policy.raw_provider_response_returned,
    policy.authorization_header_returned,
    policy.provider_key_returned,
  ].every((returned) => returned === false);

  return blocked ? "forbidden" : "check policy";
}

function payloadPreviewStatusMessage(status: PayloadPreviewStatus, message: string | null): string {
  switch (status) {
    case "loaded":
      return "载荷预览已加载。";
    case "forbidden":
      return "你没有权限加载载荷预览。";
    case "not_implemented":
      return "载荷预览 API 尚未实现。";
    case "unavailable":
      return "此请求没有可用的载荷预览。";
    case "error":
      return message ?? "载荷预览请求失败。";
    default:
      return "";
  }
}

function safePayloadPreviewSections(preview: RequestPayloadPreview): Array<{ title: string; value: JsonValue }> {
  const sections: Array<[string, JsonValue | null | undefined]> = [
    ["请求元数据", preview.request_metadata],
    ["响应元数据", preview.response_metadata],
    ["请求脱敏预览", preview.redacted_request_preview],
    ["响应脱敏预览", preview.redacted_response_preview],
    ["元数据", preview.metadata],
  ];

  return sections.flatMap(([title, value]) => {
    if (value === null || value === undefined) {
      return [];
    }

    const safeValue = sanitizeDisplayJson(value);
    return isEmptyJsonValue(safeValue) ? [] : [{ title, value: safeValue }];
  });
}

function isEmptyJsonValue(value: JsonValue): boolean {
  if (Array.isArray(value)) {
    return value.length === 0;
  }

  if (isJsonRecord(value)) {
    return Object.keys(value).length === 0;
  }

  return value === null || value === "";
}

function formatJsonPreview(value: JsonValue): string {
  const serialized = JSON.stringify(value, null, 2);

  return serialized.length > 2000 ? `${serialized.slice(0, 2000)}\n...` : serialized;
}

function apiStatusCode(error: unknown): number | undefined {
  if (typeof error !== "object" || error === null || !("status" in error)) {
    return undefined;
  }

  const status = (error as { status?: unknown }).status;
  return typeof status === "number" ? status : undefined;
}

function formatBoolean(value: boolean | null | undefined): string {
  if (value === null || value === undefined) {
    return "-";
  }

  return value ? "是" : "否";
}
