import OpenAI from "openai";

const gatewayBaseUrl = (process.env.GATEWAY_BASE_URL ?? "http://127.0.0.1:8080").replace(/\/+$/, "");
const baseURL = process.env.OPENAI_BASE_URL ?? `${gatewayBaseUrl}/v1`;
const apiKey = process.env.OPENAI_API_KEY ?? process.env.GATEWAY_AUTH_TOKEN ?? "dev_test_key_123456789";
const model = process.env.SMOKE_MODEL ?? "mock-gpt-4o-mini";
const includeStreaming = parseBooleanEnv("SDK_SMOKE_INCLUDE_STREAMING");
const allowStreamingSkip = parseBooleanEnv("SDK_SMOKE_ALLOW_STREAMING_SKIP");

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function parseBooleanEnv(name) {
  const value = process.env[name];
  return value === "1" || /^(true|yes|on)$/i.test(value ?? "");
}

function assertLocalBaseUrl(url) {
  const parsed = new URL(url);
  const allowedHosts = new Set(["127.0.0.1", "localhost", "[::1]"]);
  if (process.env.ALLOW_NON_LOCAL_GATEWAY === "1") {
    return;
  }

  assert(
    allowedHosts.has(parsed.hostname),
    `refusing to run SDK smoke against non-local baseURL ${url}; set ALLOW_NON_LOCAL_GATEWAY=1 to override`,
  );
}

async function runNonStreamingSmoke(client) {
  const completion = await client.chat.completions.create({
    model,
    messages: [{ role: "user", content: "sdk smoke ping" }],
    stream: false,
  });

  assert(completion.object === "chat.completion", `expected object=chat.completion, got ${completion.object}`);
  assert(completion.model === model, `expected model=${model}, got ${completion.model}`);
  assert(Array.isArray(completion.choices), "expected choices array");
  assert(completion.choices.length > 0, "expected at least one choice");
  assert(completion.choices[0]?.message?.role === "assistant", "expected assistant message");
  assert(typeof completion.choices[0]?.message?.content === "string", "expected text content");
  assert(completion.choices[0]?.finish_reason === "stop", "expected finish_reason=stop");

  return {
    status: "ok",
    baseURL,
    model: completion.model,
    object: completion.object,
    finish_reason: completion.choices[0].finish_reason,
  };
}

async function runStreamingSmoke(client) {
  const stream = await client.chat.completions.create({
    model,
    messages: [{ role: "user", content: "sdk smoke streaming ping" }],
    stream: true,
  });

  let chunkCount = 0;
  let finalFinishReason = null;

  for await (const chunk of stream) {
    chunkCount += 1;
    assert(chunk && typeof chunk === "object", "expected streaming chunk object");
    assert(chunk.object === "chat.completion.chunk", `expected object=chat.completion.chunk, got ${chunk.object}`);

    if (Array.isArray(chunk.choices)) {
      for (const choice of chunk.choices) {
        if (choice?.finish_reason) {
          finalFinishReason = choice.finish_reason;
        }
      }
    }
  }

  assert(chunkCount > 0, "expected at least one streaming chunk");
  assert(finalFinishReason, "expected streaming iteration to end with a finish_reason chunk");

  return {
    status: "ok",
    chunks: chunkCount,
    finish_reason: finalFinishReason,
  };
}

function describeError(error) {
  const status = error?.status ? `HTTP ${error.status}` : null;
  const message = error?.message ?? String(error);
  return [status, message].filter(Boolean).join(" - ");
}

async function maybeRunStreamingSmoke(client) {
  try {
    return await runStreamingSmoke(client);
  } catch (error) {
    const message =
      "OpenAI Node SDK stream:true smoke did not complete. " +
      "Gateway runtime streaming support may still be pending. " +
      describeError(error);

    if (allowStreamingSkip) {
      console.warn(`[SKIP] ${message}`);
      return {
        status: "skipped",
        reason: message,
      };
    }

    throw new Error(
      `${message}\n` +
        "Pass -AllowStreamingSkip or set SDK_SMOKE_ALLOW_STREAMING_SKIP=1 while streaming support is pending.",
    );
  }
}

async function main() {
  assertLocalBaseUrl(baseURL);

  const client = new OpenAI({
    apiKey,
    baseURL,
    timeout: Number(process.env.SDK_SMOKE_TIMEOUT_MS ?? 8000),
    maxRetries: 0,
  });

  const result = await runNonStreamingSmoke(client);
  if (includeStreaming) {
    result.streaming = await maybeRunStreamingSmoke(client);
  }

  console.log(
    JSON.stringify(result),
  );
}

main().catch((error) => {
  console.error("[FAIL] OpenAI Node SDK smoke failed");
  console.error(error?.stack ?? error);
  process.exit(1);
});
