import { describe, expect, it } from "vitest";
import type { Channel } from "../../api/client";
import {
  channelReadiness,
  isUnsafeJsonValidationError,
  modelMappingOptions,
  parseAdvancedJsonArray,
  parseAdvancedJsonObject,
  providerKeyProbeSummary,
  safeEndpoint,
} from "./providerPolicyUtils";

describe("provider policy utils", () => {
  it("parses advanced JSON with object and array type guards", () => {
    expect(parseAdvancedJsonObject("{}", "metadata")).toEqual({});
    expect(parseAdvancedJsonArray("[]", "tags")).toEqual([]);

    expect(() => parseAdvancedJsonObject("[]", "metadata")).toThrow("metadata 必须是 JSON object。");
    expect(() => parseAdvancedJsonArray("{}", "tags")).toThrow("tags 必须是 JSON array。");
    expect(() => parseAdvancedJsonObject("{", "metadata")).toThrow("metadata 必须是有效 JSON。");
  });

  it("rejects sensitive advanced JSON keys and values", () => {
    for (const value of [
      '{"Authorization":"Bearer hidden"}',
      '{"nested":{"api-key":"hidden"}}',
      '{"encrypted_secret":"hidden"}',
      '{"key_hash":"hidden"}',
      '{"fingerprint":"hidden"}',
      '{"token":"hidden"}',
      '{"raw_headers":{"x":"hidden"}}',
      '{"payload":{"x":"hidden"}}',
      '{"body":"hidden"}',
      '{"credential":"hidden"}',
      '{"note":"Bearer sk-hidden"}',
    ]) {
      expect(() => parseAdvancedJsonObject(value, "policy")).toThrow("policy 包含不安全字段。");
    }
  });

  it("identifies unsafe JSON validation errors", () => {
    expect(isUnsafeJsonValidationError(new Error("policy 包含不安全字段。"))).toBe(true);
    expect(isUnsafeJsonValidationError(new Error("policy contains unsafe fields."))).toBe(true);
    expect(isUnsafeJsonValidationError(new Error("policy 必须是有效 JSON。"))).toBe(false);
  });

  it("redacts unsafe endpoints while preserving safe endpoints and relative paths", () => {
    expect(safeEndpoint(undefined)).toBe("-");
    expect(safeEndpoint(null)).toBe("-");
    expect(safeEndpoint("")).toBe("-");
    expect(safeEndpoint("https://user:pass@example.com/v1")).toBe("[redacted]");
    expect(safeEndpoint("https://api.example.com/v1?token=hidden")).toBe("[redacted]");
    expect(safeEndpoint("https://api.example.com/v1#hidden")).toBe("[redacted]");
    expect(safeEndpoint("https://api.example.com/v1")).toBe("https://api.example.com/v1");
    expect(safeEndpoint("/v1/chat/completions")).toBe("/v1/chat/completions");
    expect(safeEndpoint("Bearer sk-hidden")).toBe("[redacted]");
  });

  it("collects requested and upstream model mapping options", () => {
    const channel = {
      model_mappings: {
        "gpt-visible": "gpt-upstream",
        case_policy: "lowercase",
        explicit_mappings: {
          "claude-visible": "claude-upstream",
        },
        mappings: [
          { requested_model: "gemini-visible", upstream_model: "gemini-upstream" },
          { model: "llama-visible", upstream_model_name: "llama-upstream" },
          { model: "gpt-visible", upstream_model_name: "gpt-upstream" },
        ],
        trim_prefixes: ["openai/"],
      },
    } as unknown as Channel;

    expect(modelMappingOptions(channel)).toEqual({
      requested: ["claude-visible", "gemini-visible", "gpt-visible", "llama-visible"],
      upstream: ["claude-upstream", "gemini-upstream", "gpt-upstream", "llama-upstream"],
    });
  });

  it("derives channel readiness from associated provider key recovery probe state", () => {
    const channel = { protocol_mode: "openai" } as Channel;

    expect(channelReadiness(channel, [])).toMatchObject({
      keyId: null,
      status: "config-needed",
    });

    expect(
      channelReadiness(channel, [
        {
          channel_id: "channel-1",
          health_score: 50,
          id: "key-1",
          key_alias: "primary",
          last_error_code: "upstream_401",
          metadata: {},
          recovery_probe: {
            error_code: "upstream_401",
            last_checked_at: "2026-06-12T10:00:00Z",
            result: "auth_failed",
          },
          status: "enabled",
        } as never,
      ]),
    ).toMatchObject({
      keyAlias: "primary",
      keyId: "key-1",
      probe: {
        errorCode: "upstream_401",
        result: "auth_failed",
      },
      status: "auth-failed",
    });

    expect(
      channelReadiness({ protocol_mode: "anthropic_messages" } as Channel, [
        {
          channel_id: "channel-1",
          health_score: 50,
          id: "key-2",
          key_alias: "disabled",
          metadata: {},
          status: "manual_disabled",
        } as never,
      ]),
    ).toMatchObject({
      status: "mockable",
    });
  });

  it("summarizes provider key recovery probe without secret material", () => {
    expect(
      providerKeyProbeSummary({
        channel_id: "channel-1",
        cooldown_until: "2026-06-12T11:00:00Z",
        health_score: 20,
        id: "key-1",
        key_alias: "cooling",
        metadata: {},
        recovery_probe: {
          error_code: "rate_limited",
          last_checked_at: "2026-06-12T10:00:00Z",
          next_step: "wait",
          result: "cooldown",
        },
        recovery_action_readback: {
          cooldown_or_refusal_reason: "cooldown_until_present",
          last_probe_status: "cooldown",
          operator_confirmation_required: true,
          safe_next_action: "wait_for_cooldown_or_request_recovery_probe",
          schema: "provider_key_recovery_action_readback.v1",
          secret_safe: true,
          suggested_action: "request_recovery_probe",
          upstream_probe_executed: false,
        },
        status: "cooldown",
      } as never),
    ).toMatchObject({
      errorCode: "rate_limited",
      lastCheckedAt: "2026-06-12T10:00:00Z",
      nextStep: "wait_for_cooldown_or_request_recovery_probe",
      result: "cooldown",
      status: "cooldown",
    });
  });
});
