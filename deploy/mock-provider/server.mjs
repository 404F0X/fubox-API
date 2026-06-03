import http from "node:http";

const port = Number(process.env.MOCK_PROVIDER_PORT ?? 18080);
const maxRequestBodyBytes = 1024 * 1024;

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
