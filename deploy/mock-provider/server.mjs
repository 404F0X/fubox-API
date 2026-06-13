import http from "node:http";

const port = Number(process.env.MOCK_PROVIDER_PORT ?? 18080);
const maxRequestBodyBytes = 1024 * 1024;
const requireModelsAuthorization =
  String(process.env.MOCK_PROVIDER_REQUIRE_MODELS_AUTH ?? "").toLowerCase() === "1" ||
  String(process.env.MOCK_PROVIDER_REQUIRE_MODELS_AUTH ?? "").toLowerCase() === "true";

function nowUnix() {
  return Math.floor(Date.now() / 1000);
}

function sendJson(res, status, payload, extraHeaders = {}) {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    ...extraHeaders,
  });
  res.end(JSON.stringify(payload));
}

function writeSseHeaders(res, extraHeaders = {}) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "Access-Control-Allow-Origin": "*",
    ...extraHeaders,
  });
}

function writeSseJson(res, event) {
  res.write(`data: ${JSON.stringify(event)}\n\n`);
}

function writeSseDone(res) {
  res.write("data: [DONE]\n\n");
}

function sendSse(res, events, extraHeaders = {}) {
  writeSseHeaders(res, extraHeaders);
  for (const event of events) {
    writeSseJson(res, event);
  }
  writeSseDone(res);
  res.end();
}

function sendSseWithoutDone(res, events, extraHeaders = {}) {
  writeSseHeaders(res, extraHeaders);
  for (const event of events) {
    writeSseJson(res, event);
  }
  res.end();
}

function providerError(type, message) {
  return {
    error: {
      message,
      type,
      param: null,
      code: null,
    },
  };
}

async function readJsonBody(req) {
  if (req.method === "GET" || req.method === "HEAD" || req.method === "OPTIONS") {
    return {};
  }

  let body = "";
  for await (const chunk of req) {
    body += chunk;
    if (Buffer.byteLength(body) > maxRequestBodyBytes) {
      throw new Error("request body too large");
    }
  }

  if (!body.trim()) {
    return {};
  }

  return JSON.parse(body);
}

function requestedModel(body) {
  return typeof body.model === "string" && body.model.length > 0 ? body.model : "mock-gpt-4o-mini";
}

function completionPayload(body, content = "hello") {
  const model = requestedModel(body);
  return {
    id: "chatcmpl_mock_200",
    object: "chat.completion",
    created: nowUnix(),
    model,
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content,
        },
        logprobs: null,
        finish_reason: "stop",
      },
    ],
    usage: {
      prompt_tokens: 8,
      completion_tokens: 2,
      total_tokens: 10,
    },
    system_fingerprint: "fp_mock_provider",
  };
}

function responsesPayload(body, content = "hello") {
  const model = requestedModel(body);
  const created = nowUnix();
  const responseId = "resp_mock_200";
  const messageId = "msg_mock_200";

  return {
    id: responseId,
    object: "response",
    created_at: created,
    status: "completed",
    error: null,
    incomplete_details: null,
    instructions: null,
    max_output_tokens: body.max_output_tokens ?? null,
    model,
    output: [
      {
        id: messageId,
        type: "message",
        status: "completed",
        role: "assistant",
        content: [
          {
            type: "output_text",
            text: content,
            annotations: [],
          },
        ],
      },
    ],
    output_text: content,
    parallel_tool_calls: false,
    previous_response_id: body.previous_response_id ?? null,
    temperature: body.temperature ?? null,
    tool_choice: "auto",
    tools: [],
    top_p: body.top_p ?? null,
    usage: {
      input_tokens: 8,
      input_tokens_details: {
        cached_tokens: 0,
      },
      output_tokens: 2,
      output_tokens_details: {
        reasoning_tokens: 0,
      },
      total_tokens: 10,
    },
    metadata: body.metadata ?? null,
  };
}

function embeddingItem(index) {
  return {
    object: "embedding",
    embedding: [0.01 + index / 100, -0.02 - index / 100, 0.03 + index / 100],
    index,
  };
}

function embeddingsInputCount(input) {
  if (Array.isArray(input)) {
    if (input.length === 0) {
      return 0;
    }
    if (input.every((item) => typeof item === "number")) {
      return 1;
    }
    return input.length;
  }
  return input == null ? 0 : 1;
}

function embeddingsPayload(body) {
  const count = embeddingsInputCount(body.input);
  const promptTokens = Math.max(1, count * 6);

  return {
    object: "list",
    model: requestedModel(body),
    data: Array.from({ length: count }, (_, index) => embeddingItem(index)),
    usage: {
      prompt_tokens: promptTokens,
      total_tokens: promptTokens,
    },
  };
}

function responsesStreamEvents(body, content = "hello") {
  const response = responsesPayload(body, content);
  return [
    {
      type: "response.created",
      sequence_number: 0,
      response: {
        ...response,
        status: "in_progress",
        output: [],
        output_text: "",
      },
    },
    {
      type: "response.output_item.added",
      sequence_number: 1,
      output_index: 0,
      item: response.output[0],
    },
    {
      type: "response.content_part.added",
      sequence_number: 2,
      output_index: 0,
      item_id: response.output[0].id,
      content_index: 0,
      part: response.output[0].content[0],
    },
    {
      type: "response.output_text.delta",
      sequence_number: 3,
      output_index: 0,
      item_id: response.output[0].id,
      content_index: 0,
      delta: content,
      logprobs: [],
    },
    {
      type: "response.output_text.done",
      sequence_number: 4,
      output_index: 0,
      item_id: response.output[0].id,
      content_index: 0,
      text: content,
      logprobs: [],
    },
    {
      type: "response.content_part.done",
      sequence_number: 5,
      output_index: 0,
      item_id: response.output[0].id,
      content_index: 0,
      part: response.output[0].content[0],
    },
    {
      type: "response.output_item.done",
      sequence_number: 6,
      output_index: 0,
      item: response.output[0],
    },
    {
      type: "response.completed",
      sequence_number: 7,
      response,
    },
  ];
}

function anthropicMessagesPayload(body, content = "hello") {
  return {
    id: "msg_mock_200",
    type: "message",
    role: "assistant",
    model: requestedModel(body),
    content: [
      {
        type: "text",
        text: content,
      },
    ],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: {
      input_tokens: 8,
      output_tokens: 2,
    },
  };
}

function anthropicToolUsePayload(body) {
  return {
    id: "msg_mock_tool_use",
    type: "message",
    role: "assistant",
    model: requestedModel(body),
    content: [
      {
        type: "tool_use",
        id: "toolu_mock_01",
        name: "fixture_lookup",
        input: {
          item_id: "fixture-item-1",
        },
      },
    ],
    stop_reason: "tool_use",
    stop_sequence: null,
    usage: {
      input_tokens: 21,
      output_tokens: 9,
    },
  };
}

function geminiGenerateContentPayload(body, content = "hello") {
  const model =
    typeof body.model === "string" && body.model.length > 0
      ? body.model
      : "models/mock-gpt-4o-mini";

  return {
    candidates: [
      {
        content: {
          role: "model",
          parts: [
            {
              text: content,
            },
          ],
        },
        finishReason: "STOP",
        index: 0,
        safetyRatings: [],
      },
    ],
    usageMetadata: {
      promptTokenCount: 8,
      candidatesTokenCount: 2,
      totalTokenCount: 10,
    },
    modelVersion: model,
  };
}

function chunkPayload(body, delta, finishReason = null) {
  const model = requestedModel(body);
  return {
    id: "chatcmpl_mock_stream",
    object: "chat.completion.chunk",
    created: nowUnix(),
    model,
    choices: [
      {
        index: 0,
        delta,
        logprobs: null,
        finish_reason: finishReason,
      },
    ],
    system_fingerprint: "fp_mock_provider",
  };
}

function defaultStreamEvents(body) {
  return [
    chunkPayload(body, { role: "assistant" }),
    chunkPayload(body, { content: "hello" }),
    chunkPayload(body, {}, "stop"),
  ];
}

function isStreamingRequest(url, body) {
  return url.searchParams.get("stream") === "true" || body.stream === true || body.stream === "true";
}

function isChatCompletionsPath(pathname) {
  return pathname.includes("/chat/completions");
}

function isResponsesPath(pathname) {
  return pathname === "/v1/responses" || pathname.endsWith("/responses");
}

function isEmbeddingsPath(pathname) {
  return pathname === "/v1/embeddings" || pathname.endsWith("/embeddings");
}

function isAnthropicMessagesPath(pathname) {
  return pathname === "/v1/messages" || pathname.endsWith("/messages");
}

function isGeminiGenerateContentPath(pathname) {
  return /^\/v1(?:beta)?\/models\/[^/]+:generateContent$/.test(pathname);
}

function scenarioIs(scenario, names) {
  return names.includes(scenario.value);
}

function headerValue(req, names) {
  for (const name of names) {
    const value = req.headers[name.toLowerCase()];
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }

  return null;
}

function endpointScenario(pathname) {
  const match = pathname.match(/^\/(?:__scenario|scenario)\/([^/]+)(\/.*)?$/);
  if (!match) {
    return { scenario: null, pathname };
  }

  return {
    scenario: decodeURIComponent(match[1]),
    pathname: match[2] ?? "/",
  };
}

function requestedScenario(req, url, body, endpointSelectedScenario) {
  const headerSelectedScenario = headerValue(req, [
    "x-mock-scenario",
    "x-mock-provider-scenario",
    "x-ai-gateway-mock-scenario",
  ]);

  return {
    value:
      url.searchParams.get("scenario") ??
      headerSelectedScenario ??
      endpointSelectedScenario ??
      body.mock_scenario ??
      body.scenario ??
      "200",
    source:
      (url.searchParams.has("scenario") && "query") ||
      (headerSelectedScenario && "header") ||
      (endpointSelectedScenario && "endpoint") ||
      ((body.mock_scenario || body.scenario) && "body") ||
      "default",
  };
}

function scenarioHeaders(scenario) {
  return {
    "X-Mock-Scenario": scenario.value,
    "X-Mock-Scenario-Source": scenario.source,
  };
}

function sendOptions(res) {
  res.writeHead(204, {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers": "authorization,content-type,x-mock-scenario,x-mock-provider-scenario,x-ai-gateway-mock-scenario,x-ai-trace-id",
  });
  res.end();
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
  const endpoint = endpointScenario(url.pathname);
  const pathname = endpoint.pathname;

  if (req.method === "OPTIONS") {
    sendOptions(res);
    return;
  }

  if (pathname === "/healthz") {
    sendJson(res, 200, { service: "mock-provider", status: "ok" });
    return;
  }

  if (pathname === "/v1/models") {
    if (requireModelsAuthorization && !String(req.headers.authorization ?? "").startsWith("Bearer ")) {
      sendJson(res, 401, providerError("authentication_error", "mock provider requires authorization"));
      return;
    }

    sendJson(res, 200, {
      object: "list",
      data: [
        {
          id: "mock-gpt-4o-mini",
          object: "model",
          created: nowUnix(),
          owned_by: "mock-provider",
        },
      ],
    });
    return;
  }

  let body;
  try {
    body = await readJsonBody(req);
  } catch (error) {
    sendJson(res, 400, providerError("invalid_request_error", error.message));
    return;
  }

  const scenario = requestedScenario(req, url, body, endpoint.scenario);
  const responseScenarioHeaders = scenarioHeaders(scenario);

  if (scenario.value === "429") {
    res.writeHead(429, {
      "Retry-After": "1",
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      ...responseScenarioHeaders,
    });
    res.end(JSON.stringify(providerError("rate_limit_error", "mock 429")));
    return;
  }

  if (scenario.value === "5xx") {
    sendJson(res, 502, providerError("server_error", "mock upstream 5xx"), responseScenarioHeaders);
    return;
  }

  if (scenario.value === "timeout") {
    setTimeout(() => sendJson(res, 200, completionPayload(body, "delayed hello"), responseScenarioHeaders), 120_000);
    return;
  }

  if (scenario.value === "eof") {
    res.destroy();
    return;
  }

  if (scenarioIs(scenario, ["invalid_sse", "invalid_json_chunk"])) {
    writeSseHeaders(res, responseScenarioHeaders);
    writeSseJson(res, chunkPayload(body, { role: "assistant" }));
    res.write("data: {not-json}\n\n");
    writeSseDone(res);
    res.end();
    return;
  }

  if (scenario.value === "large_chunk") {
    sendSse(res, [
      chunkPayload(body, { role: "assistant" }),
      chunkPayload(body, { content: "x".repeat(70 * 1024) }),
      chunkPayload(body, {}, "stop"),
    ], responseScenarioHeaders);
    return;
  }

  if (scenario.value === "missing_done") {
    sendSseWithoutDone(res, defaultStreamEvents(body), responseScenarioHeaders);
    return;
  }

  if (scenario.value === "stream_timeout") {
    writeSseHeaders(res, responseScenarioHeaders);
    writeSseJson(res, chunkPayload(body, { role: "assistant" }));
    const keepAlive = setInterval(() => {
      if (!res.destroyed) {
        res.write(": mock-provider stream still open\n\n");
      }
    }, 30_000);
    res.on("close", () => clearInterval(keepAlive));
    return;
  }

  if (scenario.value === "stream_eof") {
    writeSseHeaders(res, responseScenarioHeaders);
    writeSseJson(res, chunkPayload(body, { role: "assistant" }));
    setTimeout(() => res.destroy(), 25);
    return;
  }

  if (isResponsesPath(pathname)) {
    if (isStreamingRequest(url, body)) {
      sendSseWithoutDone(res, responsesStreamEvents(body), responseScenarioHeaders);
      return;
    }
    sendJson(res, 200, responsesPayload(body), responseScenarioHeaders);
    return;
  }

  if (isEmbeddingsPath(pathname)) {
    sendJson(res, 200, embeddingsPayload(body), responseScenarioHeaders);
    return;
  }

  if (isAnthropicMessagesPath(pathname)) {
    if (scenarioIs(scenario, ["anthropic_tool_use", "tool_use"])) {
      sendJson(res, 200, anthropicToolUsePayload(body), responseScenarioHeaders);
      return;
    }
    sendJson(res, 200, anthropicMessagesPayload(body), responseScenarioHeaders);
    return;
  }

  if (isGeminiGenerateContentPath(pathname)) {
    sendJson(res, 200, geminiGenerateContentPayload(body), responseScenarioHeaders);
    return;
  }

  if (isChatCompletionsPath(pathname)) {
    if (isStreamingRequest(url, body)) {
      sendSse(res, defaultStreamEvents(body), responseScenarioHeaders);
      return;
    }
    sendJson(res, 200, completionPayload(body), responseScenarioHeaders);
    return;
  }

  sendJson(res, 200, { service: "mock-provider", scenario: scenario.value }, responseScenarioHeaders);
});

server.listen(port, "0.0.0.0", () => {
  console.log(`mock-provider listening on ${port}`);
});
