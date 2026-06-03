import { afterEach, describe, expect, it, vi } from "vitest";

async function loadClient() {
  vi.resetModules();
  return import("./client");
}

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("api client", () => {
  it("defaults service URLs to same-origin proxy paths", async () => {
    vi.stubEnv("VITE_GATEWAY_BASE_URL", "");
    vi.stubEnv("VITE_API_BASE_URL", "");
    vi.stubEnv("VITE_CONTROL_BASE_URL", "");
    vi.stubEnv("VITE_MOCK_PROVIDER_BASE_URL", "");

    const { serviceBaseUrls, serviceProbes } = await loadClient();

    expect(serviceBaseUrls).toEqual({
      gateway: "/api/gateway",
      controlPlane: "/api/control-plane",
      mockProvider: "/api/mock-provider",
    });
    expect(serviceProbes.slice(0, 3).map((probe) => probe.url)).toEqual([
      "/api/gateway/healthz",
      "/api/control-plane/healthz",
      "/api/mock-provider/healthz",
    ]);
  });

  it("honors explicit service URLs and the legacy gateway fallback", async () => {
    vi.stubEnv("VITE_GATEWAY_BASE_URL", "");
    vi.stubEnv("VITE_API_BASE_URL", "http://legacy-gateway.local/");
    vi.stubEnv("VITE_CONTROL_BASE_URL", "http://control.local/");
    vi.stubEnv("VITE_MOCK_PROVIDER_BASE_URL", "http://mock.local/");

    const { serviceBaseUrls, serviceProbes } = await loadClient();

    expect(serviceBaseUrls).toEqual({
      gateway: "http://legacy-gateway.local",
      controlPlane: "http://control.local",
      mockProvider: "http://mock.local",
    });
    expect(serviceProbes.slice(0, 3).map((probe) => probe.url)).toEqual([
      "http://legacy-gateway.local/healthz",
      "http://control.local/healthz",
      "http://mock.local/healthz",
    ]);
  });

  it("keeps health probe status semantics and no-store fetches", async () => {
    const { probeServices } = await loadClient();
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({ ok: true })
      .mockResolvedValueOnce({ ok: false })
      .mockRejectedValueOnce(new Error("connection refused"));
    vi.stubGlobal("fetch", fetchMock);

    const results = await probeServices([
      { name: "Online", url: "/online", kind: "http" },
      { name: "Offline", url: "/offline", kind: "http" },
      { name: "Rejected", url: "/rejected", kind: "http" },
      { name: "Worker", url: "worker", kind: "process" },
    ]);

    expect(results).toEqual([
      { name: "Online", status: "online", detail: "/online" },
      { name: "Offline", status: "offline", detail: "/offline" },
      { name: "Rejected", status: "offline", detail: "/rejected" },
      { name: "Worker", status: "pending", detail: "worker" },
    ]);
    expect(fetchMock).toHaveBeenCalledTimes(3);
    for (const [, init] of fetchMock.mock.calls) {
      expect(init).toMatchObject({ cache: "no-store" });
      expect(init.signal).toBeInstanceOf(AbortSignal);
    }
  });

  it("aborts hanging health probes after the probe timeout", async () => {
    vi.useFakeTimers();
    const { HEALTH_PROBE_TIMEOUT_MS, probeServices } = await loadClient();
    let signal: AbortSignal | undefined;
    const fetchMock = vi.fn((_url: string, init?: RequestInit) => {
      signal = init?.signal ?? undefined;
      return new Promise<Response>((_resolve, reject) => {
        signal?.addEventListener("abort", () => reject(new Error("aborted")));
      });
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = probeServices([{ name: "Slow", url: "/slow", kind: "http" }]);

    await vi.advanceTimersByTimeAsync(HEALTH_PROBE_TIMEOUT_MS);

    await expect(result).resolves.toEqual([{ name: "Slow", status: "offline", detail: "/slow" }]);
    expect(signal?.aborted).toBe(true);
  });

  it("serializes JSON requests and unwraps data envelopes", async () => {
    const { apiJson } = await loadClient();
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) =>
      Promise.resolve(
        new Response(JSON.stringify({ data: { id: "provider-1" } }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      apiJson<{ id: string }>("/admin/providers", {
        method: "POST",
        body: { name: "mock-provider" },
      }),
    ).resolves.toEqual({ id: "provider-1" });

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("/api/control-plane/admin/providers");
    expect(init).toMatchObject({ method: "POST" });
    expect(init.body).toBe(JSON.stringify({ name: "mock-provider" }));
    expect(new Headers(init.headers).get("Content-Type")).toBe("application/json");
    expect(init.signal).toBeInstanceOf(AbortSignal);
  });

  it("throws parsed API errors from JSON envelopes", async () => {
    const { ApiClientError, apiJson } = await loadClient();
    const errorBody = {
      error: {
        code: "not_found",
        message: "provider not found",
        type: "invalid_request_error",
      },
      gateway: {
        error_owner: "gateway",
        error_stage: "route",
        retryable: true,
      },
    };
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(
          new Response(JSON.stringify(errorBody), {
            status: 404,
            statusText: "Not Found",
            headers: { "Content-Type": "application/json" },
          }),
        ),
      ),
    );

    try {
      await apiJson("/admin/providers/missing");
      throw new Error("expected apiJson to reject");
    } catch (error) {
      expect(error).toBeInstanceOf(ApiClientError);
      expect(error).toMatchObject({
        code: "not_found",
        message: "provider not found",
        retryable: true,
        status: 404,
        statusText: "Not Found",
        type: "invalid_request_error",
        url: "/api/control-plane/admin/providers/missing",
      });
      expect((error as InstanceType<typeof ApiClientError>).envelope).toEqual(errorBody);
    }
  });

  it("wraps admin request log and provider key endpoints", async () => {
    const {
      createProviderKey,
      deleteProviderKey,
      getRequestLogDetail,
      getRequestTraceSummary,
      listAuditLogs,
      listProviderKeys,
      listRequestLogs,
      patchProviderKey,
      requestProviderKeyRecovery,
    } = await loadClient();
    const fetchMock = vi.fn((url: RequestInfo | URL, init?: RequestInit) => {
      const requestUrl = String(url);
      const method = init?.method ?? "GET";

      if (requestUrl.includes("/admin/request-logs/request-1")) {
        return jsonResponse({
          ledger: {
            currencies: ["USD"],
            entries: [
              {
                amount: "-0.10000000",
                created_at: "2026-06-02T12:00:01Z",
                currency: "USD",
                entry_type: "settle",
                occurred_at: "2026-06-02T12:00:00Z",
                request_id: "request-1",
                status: "confirmed",
              },
            ],
            limit: 25,
            limit_reached: false,
            omitted_fields: ["idempotency_key", "usage_snapshot", "policy_snapshot", "metadata"],
            request_count: 1,
            returned_count: 1,
          },
          provider_attempts: [],
          request_log: { id: "request-1" },
          route_decision_snapshot: {
            summary: {
              candidate_count: 3,
              filtered_count: 2,
              filter_reasons: ["ZeroWeight", "CoolingDown"],
              selected_channel_id: "channel-1",
              selected_provider_model: "gpt-route-summary-upstream",
              selected_score_total: 2144483738,
              trace_affinity_status: "Disabled",
            },
          },
        });
      }

      if (requestUrl.includes("/admin/traces/trace-1")) {
        return jsonResponse({
          currencies: ["USD"],
          error_count: 0,
          first_request_at: "2026-06-02T12:00:00Z",
          last_error: null,
          last_request_at: "2026-06-02T12:00:00Z",
          ledger: {
            currencies: ["USD"],
            entries: [],
            limit: 500,
            limit_reached: false,
            omitted_fields: ["idempotency_key", "usage_snapshot", "policy_snapshot", "metadata"],
            request_count: 0,
            returned_count: 0,
          },
          limit: 20,
          limit_reached: false,
          request_count: 1,
          requests: [{ id: "request-1" }],
          tenant_id: "tenant-1",
          total_input_tokens: 1,
          total_output_tokens: 2,
          trace_id: "trace-1",
        });
      }

      if (requestUrl.includes("/admin/request-logs")) {
        return jsonResponse([{ id: "request-1" }]);
      }

      if (requestUrl.includes("/admin/audit-logs")) {
        return jsonResponse([{ id: "audit-1" }]);
      }

      if (requestUrl.includes("/admin/provider-keys/provider-key-1") && method === "PATCH") {
        return jsonResponse({ id: "provider-key-1", status: "manual_disabled" });
      }

      if (requestUrl.includes("/admin/provider-keys/provider-key-1") && method === "DELETE") {
        return jsonResponse({ id: "provider-key-1", status: "deleted" });
      }

      if (requestUrl.includes("/admin/provider-keys/provider-key-1/recovery") && method === "POST") {
        return jsonResponse({
          controlled_status_transition: true,
          credential_material: { omitted: true },
          dry_run: false,
          provider_key: { id: "provider-key-1", status: "recovery_probe" },
          target_status: "recovery_probe",
          transition: {
            allowed_source_statuses: ["cooldown", "degraded", "recovery_probe"],
            allowed_target_statuses: ["recovery_probe", "enabled"],
            from_status: "cooldown",
            to_status: "recovery_probe",
          },
          upstream_probe: {
            billable: false,
            executed: false,
            mode: "not_implemented",
            request_log_write: false,
          },
        });
      }

      if (requestUrl.includes("/admin/provider-keys") && method === "POST") {
        return jsonResponse({ id: "provider-key-1", status: "enabled" });
      }

      return jsonResponse([{ id: "provider-key-1" }]);
    });
    vi.stubGlobal("fetch", fetchMock);

    await listRequestLogs({ limit: 10, model: "gpt-4o-mini", status: "succeeded" });
    await expect(getRequestLogDetail("request-1")).resolves.toMatchObject({
      route_decision_snapshot: {
        summary: {
          candidate_count: 3,
          filtered_count: 2,
          filter_reasons: ["ZeroWeight", "CoolingDown"],
          selected_channel_id: "channel-1",
          selected_provider_model: "gpt-route-summary-upstream",
          selected_score_total: 2144483738,
          trace_affinity_status: "Disabled",
        },
      },
    });
    await getRequestTraceSummary("trace-1", { limit: 20 });
    await listAuditLogs({
      action: "provider_key.update",
      actor_user_id: "actor-1",
      created_from: "2026-06-03T00:00:00Z",
      created_to: "2026-06-03T23:59:59Z",
      limit: 25,
      resource_type: "provider_key",
    });
    await listProviderKeys();
    await createProviderKey({
      channel_id: "channel-1",
      key_alias: "primary",
      metadata: { region: "us" },
      secret: "sk-create-only",
      status: "enabled",
    });
    await patchProviderKey("provider-key-1", { metadata: { region: "eu" }, status: "manual_disabled" });
    await requestProviderKeyRecovery("provider-key-1", { reason: "overview", target_status: "recovery_probe" });
    await deleteProviderKey("provider-key-1");

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "/api/control-plane/admin/request-logs?limit=10&model=gpt-4o-mini&status=succeeded",
      "/api/control-plane/admin/request-logs/request-1",
      "/api/control-plane/admin/traces/trace-1?limit=20",
      "/api/control-plane/admin/audit-logs?action=provider_key.update&actor_user_id=actor-1&created_from=2026-06-03T00%3A00%3A00Z&created_to=2026-06-03T23%3A59%3A59Z&limit=25&resource_type=provider_key",
      "/api/control-plane/admin/provider-keys",
      "/api/control-plane/admin/provider-keys",
      "/api/control-plane/admin/provider-keys/provider-key-1",
      "/api/control-plane/admin/provider-keys/provider-key-1/recovery",
      "/api/control-plane/admin/provider-keys/provider-key-1",
    ]);
    expect(fetchMock.mock.calls[2][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[3][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[5][1]).toMatchObject({
      body: JSON.stringify({
        channel_id: "channel-1",
        key_alias: "primary",
        metadata: { region: "us" },
        secret: "sk-create-only",
        status: "enabled",
      }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[6][1]).toMatchObject({
      body: JSON.stringify({ metadata: { region: "eu" }, status: "manual_disabled" }),
      method: "PATCH",
    });
    expect(fetchMock.mock.calls[7][1]).toMatchObject({
      body: JSON.stringify({ reason: "overview", target_status: "recovery_probe" }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[8][1]).toMatchObject({ method: "DELETE" });
  });

  it("wraps model association dry-run endpoint", async () => {
    const { dryRunModelAssociation } = await loadClient();
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) =>
      jsonResponse({
        candidates: [],
        canonical_model: null,
        decision_snapshot_version: 1,
        policy: { seed: 7 },
        profile_id: "profile-1",
        project_id: "project-1",
        requested_model: "missing-model",
        route_decision_snapshot: {
          candidates: [],
          selected: null,
        },
        route_policy_version: "gateway_db_route_v1",
        selected_candidate: null,
        selection: {
          selected: null,
          selected_channel_id: null,
          status: "model_not_found_or_not_allowed",
        },
        trace_affinity: {
          status: "Disabled",
        },
        trace_id: null,
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      dryRunModelAssociation({
        previous_successful_channel_id: "channel-previous",
        profile_id: "profile-1",
        project_id: "project-1",
        requested_model: "missing-model",
        seed: 7,
        trace_id: "trace-1",
      }),
    ).resolves.toMatchObject({
      candidates: [],
      selected_candidate: null,
      selection: {
        status: "model_not_found_or_not_allowed",
      },
    });

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "/api/control-plane/admin/model-associations/dry-run",
    ]);
    expect(fetchMock.mock.calls[0][1]).toMatchObject({
      body: JSON.stringify({
        previous_successful_channel_id: "channel-previous",
        profile_id: "profile-1",
        project_id: "project-1",
        requested_model: "missing-model",
        seed: 7,
        trace_id: "trace-1",
      }),
      method: "POST",
    });
  });

  it("wraps channel manual test dry-run endpoint", async () => {
    const { dryRunChannelManualTest } = await loadClient();
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) =>
      jsonResponse({
        billing: {
          billable: false,
          ledger_write: false,
          request_log_write: false,
        },
        channel: {
          endpoint: "https://provider.example/v1",
          health_score: 1,
          id: "channel-1",
          name: "primary channel",
          priority: 10,
          protocol_mode: "openai_compatible",
          status: "enabled",
          weight: 100,
        },
        credential_material: {
          provider_key_secret: "omitted",
          secret_fingerprint: "omitted",
        },
        dry_run: true,
        next_steps: [],
        provider: {
          code: "provider-a",
          id: "provider-1",
          name: "Provider A",
          status: "enabled",
        },
        requested_model: "gpt-visible",
        request_plan: {
          method: "POST",
          model: "upstream-gpt",
          path: "/v1/chat/completions",
          protocol_mode: "openai_compatible",
        },
        test_mode: "channel_manual_test",
        upstream_call: false,
        upstream_model: "upstream-gpt",
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      dryRunChannelManualTest("channel-1", {
        dry_run: true,
        model: "gpt-visible",
        upstream_model_name: "upstream-gpt",
      }),
    ).resolves.toMatchObject({
      billing: {
        billable: false,
        ledger_write: false,
      },
      upstream_call: false,
    });

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "/api/control-plane/admin/channels/channel-1/manual-test",
    ]);
    expect(fetchMock.mock.calls[0][1]).toMatchObject({
      body: JSON.stringify({
        dry_run: true,
        model: "gpt-visible",
        upstream_model_name: "upstream-gpt",
      }),
      method: "POST",
    });
  });

  it("wraps provider and channel endpoints", async () => {
    const {
      createChannel,
      createProvider,
      deleteChannel,
      deleteProvider,
      listChannels,
      listProviders,
      patchChannel,
      patchProvider,
    } = await loadClient();
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) => jsonResponse({ id: "ok" }));
    vi.stubGlobal("fetch", fetchMock);

    await listProviders();
    await createProvider({
      base_url: "https://api.openai.test/v1",
      code: "openai",
      metadata: { owner: "platform" },
      name: "OpenAI",
      provider_type: "openai",
      status: "enabled",
    });
    await patchProvider("provider-1", { status: "disabled" });
    await deleteProvider("provider-1");
    await listChannels();
    await createChannel({
      endpoint: "https://api.openai.test/v1",
      health_score: 1,
      model_mappings: { "gpt-4o-mini": "gpt-4o-mini" },
      name: "primary",
      priority: 10,
      probe_policy: { path: "/health" },
      protocol_mode: "openai_compatible",
      provider_id: "provider-1",
      region: "us-east-1",
      request_overrides: [],
      status: "enabled",
      tags: ["primary"],
      timeout_policy: { connect_ms: 2000 },
      weight: 100,
    });
    await patchChannel("channel-1", { status: "disabled" });
    await deleteChannel("channel-1");

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "/api/control-plane/admin/providers",
      "/api/control-plane/admin/providers",
      "/api/control-plane/admin/providers/provider-1",
      "/api/control-plane/admin/providers/provider-1",
      "/api/control-plane/admin/channels",
      "/api/control-plane/admin/channels",
      "/api/control-plane/admin/channels/channel-1",
      "/api/control-plane/admin/channels/channel-1",
    ]);
    expect(fetchMock.mock.calls[1][1]).toMatchObject({
      body: JSON.stringify({
        base_url: "https://api.openai.test/v1",
        code: "openai",
        metadata: { owner: "platform" },
        name: "OpenAI",
        provider_type: "openai",
        status: "enabled",
      }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[2][1]).toMatchObject({
      body: JSON.stringify({ status: "disabled" }),
      method: "PATCH",
    });
    expect(fetchMock.mock.calls[3][1]).toMatchObject({ method: "DELETE" });
    expect(fetchMock.mock.calls[3][1]?.body).toBeUndefined();
    expect(fetchMock.mock.calls[5][1]).toMatchObject({
      body: JSON.stringify({
        endpoint: "https://api.openai.test/v1",
        health_score: 1,
        model_mappings: { "gpt-4o-mini": "gpt-4o-mini" },
        name: "primary",
        priority: 10,
        probe_policy: { path: "/health" },
        protocol_mode: "openai_compatible",
        provider_id: "provider-1",
        region: "us-east-1",
        request_overrides: [],
        status: "enabled",
        tags: ["primary"],
        timeout_policy: { connect_ms: 2000 },
        weight: 100,
      }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[6][1]).toMatchObject({
      body: JSON.stringify({ status: "disabled" }),
      method: "PATCH",
    });
    expect(fetchMock.mock.calls[7][1]).toMatchObject({ method: "DELETE" });
    expect(fetchMock.mock.calls[7][1]?.body).toBeUndefined();
  });

  it("wraps canonical model and association endpoints", async () => {
    const {
      createCanonicalModel,
      createModelAssociation,
      deleteCanonicalModel,
      deleteModelAssociation,
      listCanonicalModels,
      listModelAssociations,
      patchCanonicalModel,
      patchModelAssociation,
    } = await loadClient();
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) => jsonResponse({ id: "ok" }));
    vi.stubGlobal("fetch", fetchMock);

    await listCanonicalModels();
    await createCanonicalModel({
      context_length: 128000,
      display_name: "GPT-4o Mini",
      family: "gpt",
      model_key: "gpt-4o-mini",
      status: "active",
      visibility: "public",
    });
    await patchCanonicalModel("model-1", { status: "disabled" });
    await deleteCanonicalModel("model-1");
    await listModelAssociations();
    await createModelAssociation({
      association_type: "explicit_channel",
      canonical_model_id: "model-1",
      channel_id: "channel-1",
      conditions: { region: "us" },
      fallback_allowed: true,
      priority: 10,
      upstream_model_name: "gpt-4o-mini-2024-07-18",
    });
    await patchModelAssociation("association-1", { status: "disabled" });
    await deleteModelAssociation("association-1");

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "/api/control-plane/admin/models",
      "/api/control-plane/admin/models",
      "/api/control-plane/admin/models/model-1",
      "/api/control-plane/admin/models/model-1",
      "/api/control-plane/admin/model-associations",
      "/api/control-plane/admin/model-associations",
      "/api/control-plane/admin/model-associations/association-1",
      "/api/control-plane/admin/model-associations/association-1",
    ]);
    expect(fetchMock.mock.calls[1][1]).toMatchObject({
      body: JSON.stringify({
        context_length: 128000,
        display_name: "GPT-4o Mini",
        family: "gpt",
        model_key: "gpt-4o-mini",
        status: "active",
        visibility: "public",
      }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[2][1]).toMatchObject({
      body: JSON.stringify({ status: "disabled" }),
      method: "PATCH",
    });
    expect(fetchMock.mock.calls[3][1]).toMatchObject({ method: "DELETE" });
    expect(fetchMock.mock.calls[5][1]).toMatchObject({
      body: JSON.stringify({
        association_type: "explicit_channel",
        canonical_model_id: "model-1",
        channel_id: "channel-1",
        conditions: { region: "us" },
        fallback_allowed: true,
        priority: 10,
        upstream_model_name: "gpt-4o-mini-2024-07-18",
      }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[6][1]).toMatchObject({
      body: JSON.stringify({ status: "disabled" }),
      method: "PATCH",
    });
    expect(fetchMock.mock.calls[7][1]).toMatchObject({ method: "DELETE" });
  });

  it("wraps API key profile and virtual key endpoints", async () => {
    const {
      createApiKeyProfile,
      createVirtualKey,
      deleteApiKeyProfile,
      disableVirtualKey,
      expireVirtualKey,
      getApiKeyProfile,
      getVirtualKey,
      listApiKeyProfiles,
      listVirtualKeys,
      patchApiKeyProfile,
    } = await loadClient();
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) => jsonResponse({ id: "ok" }));
    vi.stubGlobal("fetch", fetchMock);

    await listApiKeyProfiles({ project_id: "project-1" });
    await getApiKeyProfile("profile-1");
    await createApiKeyProfile({
      allowed_models: ["gpt-visible"],
      denied_models: ["gpt-denied"],
      ip_allowlist: ["198.51.100.0/24"],
      model_aliases: { fast: "gpt-visible" },
      name: "default",
      project_id: "project-1",
      status: "active",
    });
    await patchApiKeyProfile("profile-1", {
      allowed_models: ["gpt-visible", "gpt-visible-2"],
      denied_models: ["gpt-denied"],
      ip_allowlist: ["198.51.100.10"],
      model_aliases: { fast: "gpt-visible-2" },
      name: "renamed",
      status: "disabled",
    });
    await deleteApiKeyProfile("profile-1");
    await listVirtualKeys({ project_id: "project-1", status: "active" });
    await createVirtualKey({
      default_profile_id: "profile-1",
      metadata: { owner: "mobile" },
      name: "mobile",
      project_id: "project-1",
      status: "active",
    });
    await getVirtualKey("virtual-key-1");
    await disableVirtualKey("virtual-key-1");
    await expireVirtualKey("virtual-key-1");

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "/api/control-plane/admin/api-key-profiles?project_id=project-1",
      "/api/control-plane/admin/api-key-profiles/profile-1",
      "/api/control-plane/admin/api-key-profiles",
      "/api/control-plane/admin/api-key-profiles/profile-1",
      "/api/control-plane/admin/api-key-profiles/profile-1",
      "/api/control-plane/admin/virtual-keys?project_id=project-1&status=active",
      "/api/control-plane/admin/virtual-keys",
      "/api/control-plane/admin/virtual-keys/virtual-key-1",
      "/api/control-plane/admin/virtual-keys/virtual-key-1/disable",
      "/api/control-plane/admin/virtual-keys/virtual-key-1/expire",
    ]);
    expect(fetchMock.mock.calls[2][1]).toMatchObject({
      body: JSON.stringify({
        allowed_models: ["gpt-visible"],
        denied_models: ["gpt-denied"],
        ip_allowlist: ["198.51.100.0/24"],
        model_aliases: { fast: "gpt-visible" },
        name: "default",
        project_id: "project-1",
        status: "active",
      }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[3][1]).toMatchObject({
      body: JSON.stringify({
        allowed_models: ["gpt-visible", "gpt-visible-2"],
        denied_models: ["gpt-denied"],
        ip_allowlist: ["198.51.100.10"],
        model_aliases: { fast: "gpt-visible-2" },
        name: "renamed",
        status: "disabled",
      }),
      method: "PATCH",
    });
    expect(fetchMock.mock.calls[4][1]).toMatchObject({ method: "DELETE" });
    expect(fetchMock.mock.calls[6][1]).toMatchObject({
      body: JSON.stringify({
        default_profile_id: "profile-1",
        metadata: { owner: "mobile" },
        name: "mobile",
        project_id: "project-1",
        status: "active",
      }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[8][1]).toMatchObject({ method: "POST" });
    expect(fetchMock.mock.calls[9][1]).toMatchObject({ method: "POST" });
  });

  it("wraps health summary, billing price version, ledger, and reconciliation endpoints", async () => {
    const { getBillingReconciliationReport, getProviderHealthSummary, listLedgerEntries, listPriceVersions } =
      await loadClient();
    const reconciliationReport = {
      discrepancies: [
        {
          difference_amount: "1.00000000",
          expected_ledger_amount: "-1.00000000",
          issues: ["missing_ledger"],
          ledger_amount: null,
          ledger_currency: null,
          ledger_entry_ids: [],
          request_currency: "USD",
          request_final_cost: "1.00000000",
          request_id: "request-1",
        },
      ],
      period_end: "2026-06-03 00:00:00+00",
      period_start: "2026-06-02 00:00:00+00",
      report_version: 1,
      summary: {
        amount_mismatch_count: 0,
        billable_request_count: 1,
        currency_mismatch_count: 0,
        currency_totals: [
          {
            currency: "USD",
            difference_amount: "1.00000000",
            expected_ledger_amount_total: "-1.00000000",
            ledger_amount_total: "0.00000000",
            request_final_cost_total: "1.00000000",
          },
        ],
        discrepancy_count: 1,
        ledger_entry_count: 0,
        matched_request_count: 0,
        missing_ledger_count: 1,
        request_count: 1,
        returned_discrepancy_count: 1,
        unexpected_ledger_count: 0,
      },
      tenant_id: "tenant-1",
    };
    const fetchMock = vi.fn((url: RequestInfo | URL, _init?: RequestInit) => {
      if (String(url).includes("/admin/billing/reconciliation")) {
        return jsonResponse(reconciliationReport);
      }

      return jsonResponse([{ id: "ok" }]);
    });
    vi.stubGlobal("fetch", fetchMock);

    await getProviderHealthSummary();
    await getProviderHealthSummary({ window_minutes: 15, sample_limit: 25 });
    await listPriceVersions({
      price_book_id: "price-book-1",
      canonical_model_id: "model-1",
      status: "active",
      limit: 25,
    });
    await listLedgerEntries({
      project_id: "project-1",
      request_id: "request-1",
      wallet_id: "wallet-1",
      limit: 50,
    });
    await expect(
      getBillingReconciliationReport({
      day: "2026-06-02",
      limit: 5,
      }),
    ).resolves.toEqual(reconciliationReport);

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "/api/control-plane/admin/providers/health-summary",
      "/api/control-plane/admin/providers/health-summary?window_minutes=15&sample_limit=25",
      "/api/control-plane/admin/price-versions?price_book_id=price-book-1&canonical_model_id=model-1&status=active&limit=25",
      "/api/control-plane/admin/ledger/entries?project_id=project-1&request_id=request-1&wallet_id=wallet-1&limit=50",
      "/api/control-plane/admin/billing/reconciliation?day=2026-06-02&limit=5",
    ]);
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[1][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[2][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[3][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[4][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[4][1]?.body).toBeUndefined();
  });

  it("keeps admin login cookie-only by default and only sends explicit fallback tokens", async () => {
    const { ADMIN_SESSION_HEADER, loginAdmin, listProviderKeys, setAdminSessionToken } = await loadClient();
    const fetchMock = vi.fn((url: RequestInfo | URL, init?: RequestInit) => {
      const requestUrl = String(url);

      if (requestUrl.includes("/admin/auth/login")) {
        return jsonResponse({
          session: { expires_at: "2026-06-02T20:00:00Z", id: "session-1" },
          session_token_once: "sess_test_admin_session_token",
          user: {
            display_name: "Local Admin",
            email: "admin@example.com",
            id: "user-1",
            roles: ["owner"],
            tenant_id: "tenant-1",
          },
        });
      }

      expect(init?.credentials).toBe("include");
      return jsonResponse([{ id: "provider-key-1" }]);
    });
    vi.stubGlobal("fetch", fetchMock);

    await loginAdmin({ email: "admin@example.com", password: "local-password" });
    await listProviderKeys();
    setAdminSessionToken("manual_admin_session_token");
    await listProviderKeys();

    expect(new Headers(fetchMock.mock.calls[0][1]?.headers).get(ADMIN_SESSION_HEADER)).toBeNull();
    expect(new Headers(fetchMock.mock.calls[1][1]?.headers).get(ADMIN_SESSION_HEADER)).toBeNull();
    expect(new Headers(fetchMock.mock.calls[2][1]?.headers).get(ADMIN_SESSION_HEADER)).toBe(
      "manual_admin_session_token",
    );
  });

  it("clears explicit fallback admin tokens when logout fails", async () => {
    const { ADMIN_SESSION_HEADER, listProviderKeys, logoutAdmin, setAdminSessionToken } = await loadClient();
    const fetchMock = vi.fn((url: RequestInfo | URL, _init?: RequestInit) => {
      const requestUrl = String(url);

      if (requestUrl.includes("/admin/auth/logout")) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              error: {
                code: "logout_failed",
                message: "logout failed",
              },
            }),
            {
              status: 500,
              statusText: "Internal Server Error",
              headers: { "Content-Type": "application/json" },
            },
          ),
        );
      }

      return jsonResponse([{ id: "provider-key-1" }]);
    });
    vi.stubGlobal("fetch", fetchMock);

    setAdminSessionToken("manual_admin_session_token");

    await expect(logoutAdmin()).rejects.toMatchObject({
      code: "logout_failed",
      message: "logout failed",
      status: 500,
    });
    await listProviderKeys();

    expect(new Headers(fetchMock.mock.calls[0][1]?.headers).get(ADMIN_SESSION_HEADER)).toBe(
      "manual_admin_session_token",
    );
    expect(new Headers(fetchMock.mock.calls[1][1]?.headers).get(ADMIN_SESSION_HEADER)).toBeNull();
  });

  it("distinguishes caller aborts from network failures", async () => {
    const { ApiClientError, apiJson } = await loadClient();
    const controller = new AbortController();
    const fetchMock = vi.fn((_url: string, init?: RequestInit) => {
      return new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(new Error("aborted")));
      });
    });
    vi.stubGlobal("fetch", fetchMock);

    const request = apiJson("/admin/providers", { signal: controller.signal });
    controller.abort();

    await expect(request).rejects.toMatchObject({
      code: "request_aborted",
      retryable: false,
      url: "/api/control-plane/admin/providers",
    });
    await expect(request).rejects.toBeInstanceOf(ApiClientError);
  });
});

function jsonResponse(data: unknown) {
  return Promise.resolve(
    new Response(JSON.stringify({ data }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    }),
  );
}
