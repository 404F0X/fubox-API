import { type CanonicalModel, type JsonValue, type PriceVersion } from "../../api/client";
import { safeFieldValue, shortId } from "../../components/adminUtils";

export type TokenEstimateInput = {
  cacheTokens?: number | null;
  inputTokens?: number | null;
  outputTokens?: number | null;
  reasoningTokens?: number | null;
};

type PriceRuleSummary = {
  cacheTokenRatePer1m: string;
  currency: string;
  fixedRequestCost: string;
  inputTokenRatePer1m: string;
  outputTokenRatePer1m: string;
  reasoningTokenRatePer1m: string;
};

type PriceSelection = {
  reason: string;
  version: PriceVersion | null;
};

export function ModelPriceSummary({
  estimate,
  model,
  priceVersions,
}: {
  estimate?: TokenEstimateInput;
  model: CanonicalModel | null | undefined;
  priceVersions: PriceVersion[];
}) {
  const selection = selectPriceVersion(model, priceVersions);

  if (!model) {
    return <span>config-needed: 先选择模型</span>;
  }

  if (!selection.version) {
    return <span>config-needed: 缺少 active price version 或默认价格表</span>;
  }

  const summary = priceRuleSummary(selection.version.pricing_rules);
  const cost = estimate ? estimateCost(summary, estimate) : null;

  return (
    <div className="price-summary" aria-label={`${model.model_key} 价格摘要`}>
      <span>
        price {selection.version.version} / book {shortId(selection.version.price_book_id)} / {selection.reason}
      </span>
      <span>
        input {moneyValue(summary.inputTokenRatePer1m, summary.currency)}/1M · output{" "}
        {moneyValue(summary.outputTokenRatePer1m, summary.currency)}/1M · cache{" "}
        {moneyValue(summary.cacheTokenRatePer1m, summary.currency)}/1M · reasoning{" "}
        {moneyValue(summary.reasoningTokenRatePer1m, summary.currency)}/1M
      </span>
      {cost ? (
        <strong>
          估算 {moneyValue(cost, summary.currency)}，非最终账单
        </strong>
      ) : null}
    </div>
  );
}

export function selectedPriceVersionLabel(
  model: CanonicalModel | null | undefined,
  priceVersions: PriceVersion[],
): string {
  const selection = selectPriceVersion(model, priceVersions);

  if (!model || !selection.version) {
    return "config-needed";
  }

  return `${selection.version.version} / ${shortId(selection.version.price_book_id)}`;
}

function selectPriceVersion(
  model: CanonicalModel | null | undefined,
  priceVersions: PriceVersion[],
): PriceSelection {
  if (!model) {
    return { reason: "model_missing", version: null };
  }

  const activeVersions = priceVersions.filter((version) => version.status === "active");
  const candidates = model.default_price_book_id
    ? activeVersions.filter((version) => version.price_book_id === model.default_price_book_id)
    : activeVersions.filter((version) => version.canonical_model_id === model.id);
  const modelSpecific = candidates.find((version) => version.canonical_model_id === model.id);
  const generic = candidates.find((version) => !version.canonical_model_id);
  const version = modelSpecific ?? generic ?? candidates[0] ?? null;

  return {
    reason: modelSpecific ? "model-specific" : generic ? "book-default" : version ? "book-match" : "config-needed",
    version,
  };
}

function priceRuleSummary(rules: JsonValue): PriceRuleSummary {
  return {
    cacheTokenRatePer1m: priceRuleValue(rules, [
      "cache_token_rate_per_1m",
      "cache_token_rate_per_million",
      "cache_tokens_per_1m",
      "cached_token_rate_per_1m",
      "cached_input_token_rate_per_1m",
      "input_cache_token_rate_per_1m",
    ]),
    currency: priceRuleValue(rules, ["currency"], "USD"),
    fixedRequestCost: priceRuleValue(rules, ["fixed_request_cost"]),
    inputTokenRatePer1m: priceRuleValue(rules, [
      "input_token_rate_per_1m",
      "input_token_rate_per_million",
      "input_tokens_per_1m",
    ]),
    outputTokenRatePer1m: priceRuleValue(rules, [
      "output_token_rate_per_1m",
      "output_token_rate_per_million",
      "output_tokens_per_1m",
    ]),
    reasoningTokenRatePer1m: priceRuleValue(rules, [
      "reasoning_token_rate_per_1m",
      "reasoning_token_rate_per_million",
      "reasoning_tokens_per_1m",
    ]),
  };
}

function estimateCost(summary: PriceRuleSummary, estimate: TokenEstimateInput): string | null {
  const fixed = decimal(summary.fixedRequestCost);
  const total =
    fixed +
    tokenCost(estimate.inputTokens, summary.inputTokenRatePer1m) +
    tokenCost(estimate.outputTokens, summary.outputTokenRatePer1m) +
    tokenCost(estimate.cacheTokens, summary.cacheTokenRatePer1m) +
    tokenCost(estimate.reasoningTokens, summary.reasoningTokenRatePer1m);

  return total > 0 ? formatDecimal(total) : null;
}

function tokenCost(tokens: number | null | undefined, ratePer1m: string): number {
  if (typeof tokens !== "number" || !Number.isFinite(tokens) || tokens <= 0) {
    return 0;
  }

  return (tokens / 1_000_000) * decimal(ratePer1m);
}

function priceRuleValue(rules: JsonValue, keys: string[], fallback = "0"): string {
  if (!isJsonRecord(rules)) {
    return fallback;
  }

  for (const key of keys) {
    const value = rules[key];

    if (typeof value === "string" && value.trim()) {
      return safeFieldValue(value.trim());
    }

    if (typeof value === "number" && Number.isFinite(value)) {
      return safeFieldValue(value);
    }
  }

  return fallback;
}

function moneyValue(amount: string, currency: string): string {
  return `${safeFieldValue(amount)} ${safeFieldValue(currency)}`;
}

function decimal(value: string): number {
  const parsed = Number(value);

  return Number.isFinite(parsed) ? parsed : 0;
}

function formatDecimal(value: number): string {
  return value.toFixed(8).replace(/\.?0+$/, "");
}

function isJsonRecord(value: JsonValue): value is Record<string, JsonValue> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
