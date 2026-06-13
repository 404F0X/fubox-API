const gatewayBaseUrl = (process.env.GATEWAY_BASE_URL ?? "http://127.0.0.1:8080").replace(/\/+$/, "");
const apiKey = process.env.GATEWAY_API_KEY ?? process.env.OPENAI_API_KEY ?? process.env.GATEWAY_AUTH_TOKEN ?? "";
const model = process.env.SMOKE_MODEL ?? "mock-gpt-4o-mini";
const timeoutMs = Number(process.env.SDK_SMOKE_TIMEOUT_MS ?? 15000);
const summary = {
  schema: "fubox_gateway_user_mvp_summary.v1",
  artifact_kind: "local_mvp_sdk_smoke_summary",
  local_only: true,
  production_evidence: false,
  secret_safe: true,
  model,
  gateway_models: {
    endpoint: "/v1/models",
    status: "not_run",
    model_count: 0,
    contains_expected_model: false,
  },
  gateway_requests: {
    non_stream: {
      endpoint: "/v1/chat/completions",
      stream: false,
      status: "not_run",
      request_id: null,
      trace_id: null,
    },
    stream: {
      endpoint: "/v1/chat/completions",
      stream: true,
      status: "not_run",
      request_id: null,
      trace_id: null,
    },
  },
  readback: {
    user_request_logs: {
      status: "not_run_sdk_gateway_only",
      detail: "Run scripts/dev_login_check.ps1 for control-plane user request log readback.",
    },
    admin_request_detail: {
      status: "not_run_sdk_gateway_only",
      detail: "Run scripts/dev_login_check.ps1 for admin request detail readback.",
    },
  },
};

function redact(value) {
  return String(value)
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer [REDACTED]")
    .replace(/(api[_-]?key|authorization|token|secret)(["'\s:=]+)[^"'\s,}]+/gi, "$1$2[REDACTED]")
    .replace(/sk-[A-Za-z0-9._-]+/g, "sk-[REDACTED]");
}

function requireApiKey() {
  if (!apiKey.trim()) {
    throw new Error("missing API key; set GATEWAY_API_KEY or OPENAI_API_KEY");
  }
}

function makeTraceId(label) {
  const suffix = Math.random().toString(16).slice(2, 10);
  return `user-smoke-${label}-${Date.now()}-${suffix}`;
}

async function requestJson(path, { method = "GET", body, traceId } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`${gatewayBaseUrl}${path}`, {
      method,
      signal: controller.signal,
      headers: {
        authorization: `Bearer ${apiKey}`,
        "content-type": "application/json",
        ...(traceId ? { "x-ai-trace-id": traceId } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await response.text();
    let payload = null;
    if (text.trim()) {
      try {
        payload = JSON.parse(text);
      } catch {
        payload = { raw: text.slice(0, 500) };
      }
    }
    if (!response.ok) {
      throw new Error(`HTTP ${response.status} ${response.statusText}: ${JSON.stringify(payload)}`);
    }
    return {
      payload,
      requestId: response.headers.get("x-request-id") ?? null,
      traceId,
    };
  } finally {
    clearTimeout(timer);
  }
}

async function requestStream(path, body, traceId) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`${gatewayBaseUrl}${path}`, {
      method: "POST",
      signal: controller.signal,
      headers: {
        authorization: `Bearer ${apiKey}`,
        "content-type": "application/json",
        "x-ai-trace-id": traceId,
      },
      body: JSON.stringify(body),
    });
    const requestId = response.headers.get("x-request-id") ?? null;
    if (!response.ok) {
      throw new Error(`HTTP ${response.status} ${response.statusText}: ${await response.text()}`);
    }

    const reader = response.body?.getReader();
    if (!reader) {
      throw new Error("stream response did not include a readable body");
    }

    const decoder = new TextDecoder();
    let buffer = "";
    let chunks = 0;
    let done = false;
    while (true) {
      const { value, done: readerDone } = await reader.read();
      if (readerDone) break;
      buffer += decoder.decode(value, { stream: true });
      const frames = buffer.split(/\r?\n\r?\n/);
      buffer = frames.pop() ?? "";
      for (const frame of frames) {
        for (const line of frame.split(/\r?\n/)) {
          if (!line.startsWith("data:")) continue;
          const data = line.slice(5).trim();
          if (!data) continue;
          chunks += 1;
          if (data === "[DONE]") {
            done = true;
          }
        }
      }
    }
    return { requestId, traceId, chunks, done };
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  requireApiKey();

  const models = await requestJson("/v1/models");
  const modelIds = Array.isArray(models.payload?.data) ? models.payload.data.map((entry) => entry.id).filter(Boolean) : [];
  summary.gateway_models.status = "pass";
  summary.gateway_models.model_count = modelIds.length;
  summary.gateway_models.contains_expected_model = modelIds.includes(model);
  console.log(JSON.stringify({
    step: "models",
    model_count: modelIds.length,
    models: modelIds,
  }));

  const nonStreamTraceId = makeTraceId("non-stream");
  const nonStream = await requestJson("/v1/chat/completions", {
    method: "POST",
    traceId: nonStreamTraceId,
    body: {
      model,
      messages: [{ role: "user", content: "Return the word ok." }],
      stream: false,
    },
  });
  summary.gateway_requests.non_stream.status = "pass";
  summary.gateway_requests.non_stream.request_id = nonStream.requestId;
  summary.gateway_requests.non_stream.trace_id = nonStream.traceId;
  console.log(JSON.stringify({
    step: "chat_non_stream",
    request_id: nonStream.requestId,
    trace_id: nonStream.traceId,
    response_id: nonStream.payload?.id ?? null,
    finish_reason: nonStream.payload?.choices?.[0]?.finish_reason ?? null,
  }));

  const streamTraceId = makeTraceId("stream");
  const stream = await requestStream("/v1/chat/completions", {
    model,
    messages: [{ role: "user", content: "Stream the word ok." }],
    stream: true,
  }, streamTraceId);
  summary.gateway_requests.stream.status = "pass";
  summary.gateway_requests.stream.request_id = stream.requestId;
  summary.gateway_requests.stream.trace_id = stream.traceId;
  console.log(JSON.stringify({
    step: "chat_stream",
    request_id: stream.requestId,
    trace_id: stream.traceId,
    sse_chunks: stream.chunks,
    done: stream.done,
  }));

  console.log(JSON.stringify({
    step: "gateway_user_mvp_summary",
    summary,
  }));
}

main().catch((error) => {
  console.error("[FAIL] Gateway user smoke failed");
  console.error(redact(error?.stack ?? error));
  process.exit(1);
});
