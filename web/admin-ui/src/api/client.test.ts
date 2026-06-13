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

  it("calls the user virtual key delete route without admin key APIs", async () => {
    const { deleteUserVirtualKey } = await loadClient();
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) =>
      jsonResponse({
        id: "user-key-1",
        key_prefix: "vk_live_123",
        secret_once: false,
        secret_redacted: true,
        status: "deleted",
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await deleteUserVirtualKey("user-key-1");

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe("/api/control-plane/user/virtual-keys/user-key-1");
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ method: "DELETE" });
  });

  it("calls user productization skeleton routes without admin headers", async () => {
    const { ADMIN_SESSION_HEADER, requestUserEmailVerification, requestUserPasswordReset } = await loadClient();
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) =>
      jsonResponse({
        account_disclosure: "none",
        code: "email_config_needed",
        email_delivery: "config_needed",
        message: "pending",
        next_action: "configure mail",
        secret_safe: true,
        status: "pending",
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await requestUserPasswordReset({ email: "user@example.com" });
    await requestUserEmailVerification();

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "/api/control-plane/auth/password-reset/request",
      "/api/control-plane/auth/email-verification/request",
    ]);
    expect(fetchMock.mock.calls.map(([, init]) => new Headers(init?.headers).get(ADMIN_SESSION_HEADER))).toEqual([
      null,
      null,
    ]);
    expect(fetchMock.mock.calls[0][1]).toMatchObject({
      body: JSON.stringify({ email: "user@example.com" }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[1][1]).toMatchObject({
      body: JSON.stringify({}),
      method: "POST",
    });
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
      exportRequestLogsCsv,
      getRequestLogDetail,
      getRequestPayloadPreview,
      getRequestTraceSummary,
      listAuditLogs,
      listProviderKeys,
      listRequestLogs,
      listRequestLogsPage,
      patchProviderKey,
      requestProviderKeyRecovery,
    } = await loadClient();
    const fetchMock = vi.fn((url: RequestInfo | URL, init?: RequestInit) => {
      const requestUrl = String(url);
      const method = init?.method ?? "GET";

      if (requestUrl.includes("/admin/request-logs/request-1/payload")) {
        return jsonResponse({
          available: true,
          metadata: { redaction: "applied" },
          payload_preview_policy_readback: {
            audit_ref_presence: {
              audit_action: "request_log.payload_preview",
              audit_ref_present: false,
              reason: "metadata-only readback",
              status: "not_written_for_metadata_only_readback",
            },
            click_to_load_endpoint: "/admin/request-logs/{id}/payload",
            click_to_load_required: true,
            forbidden_raw_fields_policy: {
              authorization_header_returned: false,
              forbidden_fields: ["raw_prompt", "raw_body", "raw_provider_response", "authorization_header", "provider_key"],
              provider_key_id_returned: false,
              provider_key_returned: false,
              raw_body_returned: false,
              raw_prompt_returned: false,
              raw_provider_response_returned: false,
              raw_request_payload_returned: false,
              raw_response_payload_returned: false,
            },
            metadata_only: true,
            raw_material_returned: false,
            redaction_status: "redacted",
            safe_next_action: "Use hash metadata only.",
            schema: "payload_preview_policy_readback.v1",
            secret_safe: true,
            status: "stored_metadata_only",
            storage_status: "stored",
          },
          payload_policy_id: "payload-policy-1",
          payload_stored: true,
          redacted_request_preview: { messages_count: 2 },
          redaction_status: "redacted",
          request_body_hash: "request-body-hash-1",
          request_id: "request-1",
          response_body_hash: "response-body-hash-1",
        });
      }

      if (requestUrl.includes("/admin/request-logs/export.csv")) {
        return Promise.resolve(
          new Response("request_id,status,redaction_status\nrequest-1,succeeded,hash_only\n", {
            status: 200,
            headers: { "Content-Type": "text/csv; charset=utf-8" },
          }),
        );
      }

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

    await listRequestLogs({
      api_key_profile_id: "profile-1",
      channel_id: "channel-1",
      created_from: "2026-06-02T00:00",
      created_to: "2026-06-03T00:00",
      error_type: "rate_limit",
      limit: 10,
      model: "gpt-4o-mini",
      sort_dir: "desc",
      sort_key: "created_at",
      status: "succeeded",
      stream: true,
      virtual_key_id: "key-1",
    });
    await expect(exportRequestLogsCsv({ limit: 10, model: "gpt-4o-mini", status: "succeeded" })).resolves.toContain(
      "request-1,succeeded,hash_only",
    );
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
    await expect(getRequestPayloadPreview("request-1")).resolves.toMatchObject({
      available: true,
      payload_preview_policy_readback: {
        click_to_load_required: true,
        forbidden_raw_fields_policy: {
          authorization_header_returned: false,
          provider_key_returned: false,
          raw_body_returned: false,
          raw_prompt_returned: false,
          raw_provider_response_returned: false,
        },
        metadata_only: true,
        status: "stored_metadata_only",
        storage_status: "stored",
      },
      payload_policy_id: "payload-policy-1",
      redacted_request_preview: { messages_count: 2 },
      request_body_hash: "request-body-hash-1",
      response_body_hash: "response-body-hash-1",
    });
    await getRequestTraceSummary("trace-1", { limit: 20 });
    await expect(listRequestLogsPage({ limit: 5, sort_dir: "asc", sort_key: "latency_ms" })).resolves.toEqual([
      { id: "request-1" },
    ]);
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
      "/api/control-plane/admin/request-logs?api_key_profile_id=profile-1&channel_id=channel-1&created_from=2026-06-02T00%3A00&created_to=2026-06-03T00%3A00&error_type=rate_limit&limit=10&model=gpt-4o-mini&sort_dir=desc&sort_key=created_at&status=succeeded&stream=true&virtual_key_id=key-1",
      "/api/control-plane/admin/request-logs/export.csv?limit=10&model=gpt-4o-mini&status=succeeded",
      "/api/control-plane/admin/request-logs/request-1",
      "/api/control-plane/admin/request-logs/request-1/payload",
      "/api/control-plane/admin/traces/trace-1?limit=20",
      "/api/control-plane/admin/request-logs?limit=5&sort_dir=asc&sort_key=latency_ms",
      "/api/control-plane/admin/audit-logs?action=provider_key.update&actor_user_id=actor-1&created_from=2026-06-03T00%3A00%3A00Z&created_to=2026-06-03T23%3A59%3A59Z&limit=25&resource_type=provider_key",
      "/api/control-plane/admin/provider-keys",
      "/api/control-plane/admin/provider-keys",
      "/api/control-plane/admin/provider-keys/provider-key-1",
      "/api/control-plane/admin/provider-keys/provider-key-1/recovery",
      "/api/control-plane/admin/provider-keys/provider-key-1",
    ]);
    expect(fetchMock.mock.calls[2][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[3][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[8][1]).toMatchObject({
      body: JSON.stringify({
        channel_id: "channel-1",
        key_alias: "primary",
        metadata: { region: "us" },
        secret: "sk-create-only",
        status: "enabled",
      }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[9][1]).toMatchObject({
      body: JSON.stringify({ metadata: { region: "eu" }, status: "manual_disabled" }),
      method: "PATCH",
    });
    expect(fetchMock.mock.calls[10][1]).toMatchObject({
      body: JSON.stringify({ reason: "overview", target_status: "recovery_probe" }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[11][1]).toMatchObject({ method: "DELETE" });
  });

  it("documents admin request CSV export as a secret-safe handoff contract", async () => {
    const { adminRequestLogsExportCsvContract } = await loadClient();

    expect(adminRequestLogsExportCsvContract).toMatchObject({
      audit_action: "request_logs.export_csv",
      content_type: "text/csv",
      primary_acceptance_surface: false,
      schema_version: "admin_request_logs_export_csv.v1",
    });
    expect(adminRequestLogsExportCsvContract.export_audit_readback).toMatchObject({
      audit_action: "request_logs.export_csv",
      audit_id_ref_present: false,
      audit_readback_path: "GET /admin/audit-logs?action=request_logs.export_csv",
      filtered_row_count_field: "filtered_row_count",
      redaction_policy: "metadata_only_safe_summary_columns",
      schema: "admin_request_logs_export_audit_readback.v1",
    });
    expect(adminRequestLogsExportCsvContract.export_audit_readback.safe_next_action).toContain(
      "filtered_row_count",
    );
    expect(adminRequestLogsExportCsvContract.allowed_columns).toContain("request_id");
    expect(adminRequestLogsExportCsvContract.allowed_columns).toContain("channel_id");
    expect(adminRequestLogsExportCsvContract.forbidden_columns).toEqual(
      expect.arrayContaining([
        "prompt",
        "messages",
        "raw_payload",
        "provider_response",
        "raw_route_snapshot",
        "raw_route_decision_snapshot",
        "provider_key",
        "provider_key_id",
        "api_key_secret",
        "authorization",
        "cookie",
      ]),
    );
    for (const forbiddenColumn of adminRequestLogsExportCsvContract.forbidden_columns) {
      expect(adminRequestLogsExportCsvContract.allowed_columns).not.toContain(forbiddenColumn);
    }
  });

  it("wraps user request log request_id and trace_id filters", async () => {
    const { listUserRequestLogs } = await loadClient();
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) =>
      jsonResponse([{ id: "00000000-0000-0000-0000-000000000001", trace_id: "trace-1" }]),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      listUserRequestLogs({
        limit: 10,
        model: "gpt-4o-mini",
        request_id: "00000000-0000-0000-0000-000000000001",
        status: "succeeded",
        trace_id: "trace-1",
      }),
    ).resolves.toEqual([{ id: "00000000-0000-0000-0000-000000000001", trace_id: "trace-1" }]);

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "/api/control-plane/user/request-logs?limit=10&model=gpt-4o-mini&request_id=00000000-0000-0000-0000-000000000001&status=succeeded&trace_id=trace-1",
    ]);
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ method: "GET" });
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
    await patchProvider("provider-1", {
      metadata: { owner: "platform-2" },
      status: "disabled",
    });
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
    await patchChannel("channel-1", {
      model_mappings: { "gpt-4o-mini": "gpt-4o-mini-2024-07-18" },
      probe_policy: { path: "/ready" },
      request_overrides: [{ header: "x-ai-profile", value: "default" }],
      status: "disabled",
      tags: ["primary", "low-latency"],
      timeout_policy: { connect_ms: 2500 },
    });
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
      body: JSON.stringify({
        metadata: { owner: "platform-2" },
        status: "disabled",
      }),
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
      body: JSON.stringify({
        model_mappings: { "gpt-4o-mini": "gpt-4o-mini-2024-07-18" },
        probe_policy: { path: "/ready" },
        request_overrides: [{ header: "x-ai-profile", value: "default" }],
        status: "disabled",
        tags: ["primary", "low-latency"],
        timeout_policy: { connect_ms: 2500 },
      }),
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
    await patchCanonicalModel("model-1", { default_price_book_id: "price-book-1", status: "disabled" });
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
      body: JSON.stringify({ default_price_book_id: "price-book-1", status: "disabled" }),
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
      bulkVirtualKeyLeakAction,
      createApiKeyProfile,
      createVirtualKey,
      deleteApiKeyProfile,
      disableVirtualKey,
      expireVirtualKey,
      getApiKeyProfile,
      getVirtualKey,
      handoffVirtualKeyExternalScannerFindings,
      listApiKeyProfiles,
      listVirtualKeys,
      patchApiKeyProfile,
      restoreVirtualKey,
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
    await bulkVirtualKeyLeakAction({
      action: "revoke",
      key_ids: ["virtual-key-1", "virtual-key-2"],
      reason: "suspected public leak in support ticket",
    });
    await handoffVirtualKeyExternalScannerFindings({
      detected_at: "2026-06-12T10:30:00Z",
      finding_count: 1,
      key_hash_present: true,
      key_prefix_present: true,
      provider: "gitleaks",
      repo_ref_hash: "repoRefHashOnly123",
      severity: "high",
      signature_validated: false,
      virtual_key_id: "virtual-key-1",
    });
    await disableVirtualKey("virtual-key-1");
    await restoreVirtualKey("virtual-key-1", { reason: "manual support restore after owner confirmation" });
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
      "/api/control-plane/admin/virtual-keys/bulk-leak-action",
      "/api/control-plane/admin/virtual-keys/external-scanner/handoff",
      "/api/control-plane/admin/virtual-keys/virtual-key-1/disable",
      "/api/control-plane/admin/virtual-keys/virtual-key-1/restore",
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
    expect(fetchMock.mock.calls[8][1]).toMatchObject({
      body: JSON.stringify({
        action: "revoke",
        key_ids: ["virtual-key-1", "virtual-key-2"],
        reason: "suspected public leak in support ticket",
      }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[9][1]).toMatchObject({
      body: JSON.stringify({
        detected_at: "2026-06-12T10:30:00Z",
        finding_count: 1,
        key_hash_present: true,
        key_prefix_present: true,
        provider: "gitleaks",
        repo_ref_hash: "repoRefHashOnly123",
        severity: "high",
        signature_validated: false,
        virtual_key_id: "virtual-key-1",
      }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[9][1]).toMatchObject({ method: "POST" });
    expect(fetchMock.mock.calls[10][1]).toMatchObject({ method: "POST" });
    expect(fetchMock.mock.calls[11][1]).toMatchObject({
      body: JSON.stringify({ reason: "manual support restore after owner confirmation" }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[12][1]).toMatchObject({ method: "POST" });
  });

  it("wraps admin users management endpoints without secret-bearing payloads", async () => {
    const { bulkAdminManagedUserStatus, listAdminManagedUsers, patchAdminManagedUserStatus, planAdminManagedUserBulkOperation } = await loadClient();
    const statusResult = {
      action_result: "disabled",
      audit_log_id: "audit-1",
      id: "user-1",
      primary_project_id: "project-1",
      project_ids: ["project-1"],
      readback: {
        audit_log_readback: true,
        omitted_fields: ["password_hash", "api_key_secret", "secret_hash", "authorization", "voucher_raw_code", "raw_payload", "provider_key"],
        project_count: 1,
        project_membership_readback: true,
        project_rollup_fallback: {
          requires_user_id_for_status_write: true,
          source: "wallet_virtual_key_request_ledger_rollup",
          supported: true,
          write_allowed: false,
        },
        schema: "admin_managed_user_status_readback.v1",
        secret_safe: true,
        source: "users_table_after_write",
        status_matches_target: true,
        user_status: "disabled",
      },
      status: "disabled",
      user_id: "user-1",
    };
    const fetchMock = vi.fn((url: RequestInfo | URL, _init?: RequestInit) => {
      if (String(url).endsWith("/admin/users/bulk-operation-plan")) {
        return jsonResponse({
          action: "audit_export",
          affected_estimate: {
            active_user_count: 1,
            disabled_user_count: 0,
            estimated_user_count: 1,
            estimate_source: "users_table_tenant_scoped_readback",
            missing_selected_count: 0,
          },
          apply_policy: {
            allowed_apply_actions: ["disable", "restore"],
            apply_supported: false,
            dangerous_cross_tenant_write_allowed: false,
            message: "dry-run only",
            safe_status_apply_path: null,
          },
          audit_export_plan: {
            external_siem_connected: false,
            export_ready: true,
            forbidden_fields: ["password_hash", "api_key_secret", "authorization", "raw_payload", "raw_audit_snapshot"],
            next_step: "connect SIEM/export adapter before production audit delivery",
            raw_snapshots_returned: false,
            recommended_format: "jsonl",
            safe_fields: ["audit_log_id", "created_at", "actor_user_id", "action", "resource_id", "reason"],
            schema: "admin_users_audit_export_plan.v1",
            source: "audit_logs",
            status: "plan-only",
          },
          blocked_reasons: [],
          mode: "dry_run",
          omitted_fields: ["password_hash", "api_key_secret", "authorization", "raw_payload", "raw_audit_snapshot"],
          project_rollup_fallback: {
            requires_user_id_for_status_write: true,
            source: "wallet_virtual_key_request_ledger_rollup",
            supported: true,
            write_allowed: false,
          },
          reason_present: true,
          reason_required: true,
          risk_policy_summary: {
            automatic_enforcement: false,
            external_ml_connected: false,
            external_siem_connected: false,
            forbidden_material_returned: false,
            operator_confirmation_required: true,
            policy_source: "local_readback_rules",
            schema: "admin_users_bulk_risk_policy_summary.v1",
            signals: { estimated_user_count: 1 },
            status: "review-ready",
            summary: "plan is bounded to current tenant user ids and safe audit fields",
          },
          rows: [],
          schema: "admin_managed_users_bulk_operation_plan.v1",
          scope: {
            cross_tenant_lookup_allowed: false,
            filter_project_id: "project-1",
            filter_search_present: true,
            filter_status: "active",
            limit: 25,
            selected_user_count: 1,
            source: "selected_user_ids",
            tenant_scope: "current_admin_tenant",
          },
          secret_safe: true,
        });
      }

      if (String(url).endsWith("/admin/users/bulk-status")) {
        return jsonResponse({
          affected_count: 1,
          audit_log_ids: ["audit-1"],
          failed_count: 0,
          omitted_fields: ["password_hash", "api_key_secret", "secret_hash", "authorization", "voucher_raw_code", "raw_payload", "provider_key"],
          operation_id: "operation-1",
          project_rollup_fallback: {
            requires_user_id_for_status_write: true,
            source: "wallet_virtual_key_request_ledger_rollup",
            supported: true,
            write_allowed: false,
          },
          requested_status: "disabled",
          results: [{ ...statusResult, operation_id: "operation-1", secret_safe: true, write_allowed: true }],
          schema: "admin_managed_users_bulk_status.v1",
          secret_safe: true,
        });
      }

      return jsonResponse(statusResult);
    });
    vi.stubGlobal("fetch", fetchMock);

    await listAdminManagedUsers({
      limit: 25,
      project_id: "project-1",
      search: "support@example.com",
      status: "active",
    });
    const patchResult = await patchAdminManagedUserStatus("user-1", {
      reason: "support confirmed account compromise and disabled runtime access",
      status: "disabled",
    });
    const bulkResult = await bulkAdminManagedUserStatus({
      reason: "support confirmed bulk fraud review",
      status: "disabled",
      user_ids: ["user-1", "user-2"],
    });
    const planResult = await planAdminManagedUserBulkOperation({
      action: "audit_export",
      filters: {
        limit: 25,
        project_id: "project-1",
        search: "support@example.com",
        status: "active",
      },
      mode: "dry_run",
      reason: "operator needs production audit export plan",
      selected_user_ids: ["user-1"],
    });

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      "/api/control-plane/admin/users?limit=25&project_id=project-1&search=support%40example.com&status=active",
      "/api/control-plane/admin/users/user-1/status",
      "/api/control-plane/admin/users/bulk-status",
      "/api/control-plane/admin/users/bulk-operation-plan",
    ]);
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[1][1]).toMatchObject({
      body: JSON.stringify({
        reason: "support confirmed account compromise and disabled runtime access",
        status: "disabled",
      }),
      method: "PATCH",
    });
    expect(fetchMock.mock.calls[2][1]).toMatchObject({
      body: JSON.stringify({
        reason: "support confirmed bulk fraud review",
        status: "disabled",
        user_ids: ["user-1", "user-2"],
      }),
      method: "POST",
    });
    expect(fetchMock.mock.calls[3][1]).toMatchObject({
      body: JSON.stringify({
        action: "audit_export",
        filters: {
          limit: 25,
          project_id: "project-1",
          search: "support@example.com",
          status: "active",
        },
        mode: "dry_run",
        reason: "operator needs production audit export plan",
        selected_user_ids: ["user-1"],
      }),
      method: "POST",
    });
    expect(patchResult.readback).toMatchObject({
      audit_log_readback: true,
      project_rollup_fallback: {
        requires_user_id_for_status_write: true,
        write_allowed: false,
      },
      schema: "admin_managed_user_status_readback.v1",
      secret_safe: true,
      status_matches_target: true,
    });
    expect(bulkResult).toMatchObject({
      affected_count: 1,
      failed_count: 0,
      operation_id: "operation-1",
      project_rollup_fallback: { write_allowed: false },
      schema: "admin_managed_users_bulk_status.v1",
      secret_safe: true,
    });
    expect(planResult).toMatchObject({
      affected_estimate: { estimated_user_count: 1 },
      apply_policy: {
        apply_supported: false,
        dangerous_cross_tenant_write_allowed: false,
      },
      audit_export_plan: {
        external_siem_connected: false,
        raw_snapshots_returned: false,
      },
      schema: "admin_managed_users_bulk_operation_plan.v1",
      secret_safe: true,
    });
  });

  it("wraps health summary, production read-model, billing price version, ledger, and reconciliation endpoints", async () => {
    const {
      getAdminProductionReadModelStatus,
      getBillingReconciliationReport,
      getProviderHealthSummary,
      listLedgerEntries,
      listPriceVersions,
    } = await loadClient();
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
    await getAdminProductionReadModelStatus();
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
      "/api/control-plane/admin/production/read-model/status",
      "/api/control-plane/admin/price-versions?price_book_id=price-book-1&canonical_model_id=model-1&status=active&limit=25",
      "/api/control-plane/admin/ledger/entries?project_id=project-1&request_id=request-1&wallet_id=wallet-1&limit=50",
      "/api/control-plane/admin/billing/reconciliation?day=2026-06-02&limit=5",
    ]);
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[1][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[2][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[3][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[4][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[5][1]).toMatchObject({ method: "GET" });
    expect(fetchMock.mock.calls[5][1]?.body).toBeUndefined();
  });

  it("wraps payment provider webhook seam with bounded signature header", async () => {
    const { receivePaymentProviderWebhook } = await loadClient();
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) =>
      jsonResponse({
        action_result: "signature_missing",
        adapter_config: {
          adapter_enabled: false,
          authorization_echoed: false,
          credential_present: false,
          credential_value_echoed: false,
          db_url_echoed: false,
          merchant_account_present: false,
          merchant_connected: false,
          next_step: "configure provider adapter",
          omitted_fields: ["raw_webhook_body", "authorization", "provider_secret"],
          production_payment_evidence: false,
          provider: "stripe_like",
          provider_secret_echoed: false,
          raw_webhook_body_echoed: false,
          schema: "payment_provider_adapter_config_status.v1",
          secret_safe: true,
          signature_verifier_status: "config-needed",
          status: "config-needed",
          supported_events: ["callback", "capture", "refund", "chargeback"],
        },
        authorization_echoed: false,
        db_url_echoed: false,
        event_write: {
          attempted: false,
          readback_status: "not_written",
          written: false,
        },
        execution_plan: {
          action_result: "not_executed",
          attempted: false,
          authorization_echoed: false,
          db_url_echoed: false,
          disabled_writes: ["ledger_entries", "credit_grants"],
          mode: "verified_simulated_min_executor",
          provider_secret_echoed: false,
          raw_idempotency_key_echoed: false,
          raw_provider_payload_echoed: false,
          raw_webhook_body_echoed: false,
          reason: "signature_not_verified",
          schema: "payment_provider_bounded_execution_plan.v1",
          secret_safe: true,
          writes: {
            ledger_refs: "not_attempted",
            payment_captures: "not_attempted",
            payment_intents: "not_attempted",
            payment_reconciliations: "not_attempted",
            payment_refunds: "not_attempted",
          },
        },
        merchant_connected: false,
        mode: "real_provider_webhook_boundary",
        omitted_fields: ["raw_webhook_body", "authorization", "provider_secret"],
        production_payment_evidence: false,
        provider: "stripe_like",
        provider_secret_echoed: false,
        raw_provider_payload_echoed: false,
        raw_webhook_body_echoed: false,
        runtime_write_performed: false,
        schema: "payment_provider_webhook_event_write_readback.v1",
        secret_safe: true,
        signature_verification: "signature_missing",
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await receivePaymentProviderWebhook(
      "stripe_like",
      {
        id: "evt_123",
        type: "payment_intent.succeeded",
        data: {
          object: {
            amount_received: 1000,
            currency: "usd",
            metadata: {
              tenant_id: "00000000-0000-0000-0000-000000000001",
            },
          },
        },
      },
      { signature: "sha256=test-signature" },
    );

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe("/api/control-plane/billing/payment-provider/webhooks/stripe_like");
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ method: "POST" });
    expect(new Headers(fetchMock.mock.calls[0][1]?.headers).get("x-fubox-payment-signature")).toBe(
      "sha256=test-signature",
    );
    expect(String(fetchMock.mock.calls[0][1]?.body)).toContain("\"type\":\"payment_intent.succeeded\"");
  });

  it("wraps ledger adjustment dry-run as a plan-only same-origin post", async () => {
    const { dryRunLedgerAdjustment } = await loadClient();
    const dryRunPlan = {
      audit_log_write: false,
      future_write_contract: {
        audit_action: "ledger.refund",
        audit_insert_failure_rolls_back_ledger_write: true,
        audit_snapshot_policy: "bounded public ids and amounts only",
        business_and_success_audit_share_transaction: true,
        ledger_write: false,
        refusal_does_not_build_success_audit: true,
        success_audit_only_after_ledger_write: true,
        upstream_call: false,
      },
      ledger_write: false,
      operation: "refund",
      plan_only: true,
      planned_ledger_entry: {
        amount: "0.25000000",
        currency: "USD",
        dedupe_policy: "server_generated_on_execute",
        entry_type: "refund",
        metadata_policy: "bounded_admin_adjustment_metadata_only",
        project_id: "project-1",
        related_ledger_entry_id: "ledger-entry-1",
        request_id: "request-1",
        status: "planned",
        wallet_id: "wallet-1",
      },
      project_id: "project-1",
      related_ledger_entry: {
        amount: "-0.25000000",
        currency: "USD",
        entry_type: "settle",
        id: "ledger-entry-1",
        project_id: "project-1",
        related_ledger_entry_id: null,
        request_id: "request-1",
        status: "confirmed",
        wallet_id: "wallet-1",
      },
      refund_remaining_summary: {
        confirmed_credit_amount: "0.10000000",
        confirmed_credit_count: 1,
        confirmed_only: true,
        credit_entry_types: ["refund", "adjust"],
        currency: "USD",
        currency_bounded: true,
        remaining_refundable_amount: "0.15000000",
        requested_refund_amount: "0.15000000",
        source_debit_amount: "0.25000000",
        source_entry_bounded: true,
        tenant_bounded: true,
      },
      request_id: "request-1",
      request_log_write: false,
      tenant_id: "tenant-1",
      upstream_call: false,
      validation: {
        amount_checked: true,
        currency_checked: true,
        refund_remaining_checked: true,
        reason_provided: true,
        related_ledger_entry_checked: true,
        sensitive_material_policy: "rejected_by_schema",
      },
      wallet_id: "wallet-1",
    };
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) => jsonResponse(dryRunPlan));
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      dryRunLedgerAdjustment({
        amount: "0.25000000",
        currency: "USD",
        operation: "refund",
        reason: "customer credit",
        related_ledger_entry_id: "ledger-entry-1",
        request_id: "request-1",
      }),
    ).resolves.toEqual(dryRunPlan);

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("/api/control-plane/admin/ledger/adjustments/dry-run");
    expect(init).toMatchObject({ credentials: "include", method: "POST" });
    expect(init.body).toBe(
      JSON.stringify({
        amount: "0.25000000",
        currency: "USD",
        operation: "refund",
        reason: "customer credit",
        related_ledger_entry_id: "ledger-entry-1",
        request_id: "request-1",
      }),
    );
  });

  it("wraps ledger adjustment execute contract writer-required responses without claiming success", async () => {
    const { requestLedgerAdjustmentExecuteContract } = await loadClient();
    const validatedPlan = {
      audit_log_write: false,
      future_write_contract: {
        audit_action: "ledger.refund",
        audit_insert_failure_rolls_back_ledger_write: true,
        audit_snapshot_policy: "bounded public ids and amounts only",
        business_and_success_audit_share_transaction: true,
        ledger_write: false,
        refusal_does_not_build_success_audit: true,
        success_audit_only_after_ledger_write: true,
        upstream_call: false,
      },
      ledger_write: false,
      operation: "refund",
      plan_only: true,
      planned_ledger_entry: {
        amount: "0.25000000",
        currency: "USD",
        dedupe_policy: "server_generated_on_execute",
        entry_type: "refund",
        metadata_policy: "bounded_admin_adjustment_metadata_only",
        related_ledger_entry_id: "ledger-entry-1",
        status: "planned",
      },
      request_log_write: false,
      tenant_id: "tenant-1",
      upstream_call: false,
      validation: {
        amount_checked: true,
        currency_checked: true,
        refund_remaining_checked: true,
        reason_provided: true,
        related_ledger_entry_checked: true,
        sensitive_material_policy: "rejected_by_schema",
      },
    };
    const contractData = {
      execute_contract: {
        audit_insert_failure_rolls_back_ledger_write: true,
        audit_log_write: false,
        audit_snapshot_policy: "bounded public ids and amounts only",
        business_and_success_audit_share_transaction: true,
        contract_version: "ledger_adjustment_execute_preflight_contract.v2",
        dedupe_contract: {
          client_supplied_dedupe_material_rejected: true,
          conflicting_duplicate_refused_before_ledger_insert: true,
          dedupe_material_echoed: false,
          public_output: "digest_marker_only",
          replay_same_digest_returns_prior_result_after_writer_exists: true,
          server_generated_dedupe_material: true,
        },
        dedupe_material_echoed: false,
        dry_run_constraints_enforced_before_refusal: ["billing_adjust_permission", "refund_remaining_amount_checked"],
        future_writer_required: true,
        ledger_executor_refusal_summary_contract: {
          credential_material_echoed: false,
          dedupe_material_echoed: false,
          error_detail_output: "omitted",
          operation_key_output: "omitted",
          preflight_refusal: {
            committed: false,
            refused_statement_count: 0,
            rolled_back: false,
            row_count_mismatch: false,
          },
          raw_executor_error_detail_echoed: false,
          raw_metadata_echoed: false,
          response_field: "ledger_executor_summary",
          rollback_refusal: {
            committed: false,
            refused_statement_count: "one_or_more",
            rolled_back: true,
            row_count_mismatch: "boolean_only",
          },
          schema_version: "billing_ledger_postgres_executor_summary.v1",
          supported_outcomes: ["refused_preflight", "refused_rollback"],
        },
        ledger_writer_contract: {
          future_writer: "transactional_admin_ledger_adjustment_writer",
          insert_status_on_success: "confirmed",
          metadata_policy: "bounded_admin_adjustment_metadata_only",
          refund_over_remaining_refused_after_locked_recompute: true,
          write_performed: false,
        },
        ledger_write: false,
        refusal_does_not_build_success_audit: true,
        request_log_contract: {
          future_behavior: "reference_existing_request_id_only",
          request_log_mutation_allowed: false,
          request_material_echoed: false,
          write_performed: false,
        },
        request_log_write: false,
        safe_output_contract: {
          audit_snapshot_policy: "bounded public ids and amounts only",
          credential_material_echoed: false,
          dedupe_material_echoed: false,
          request_material_echoed: false,
        },
        server_generated_dedupe_material: true,
        success_audit_only_after_ledger_write: true,
        transaction_contract: {
          begin_before_locking: true,
          bounded_by: ["tenant_id", "currency"],
          bounded_lock_order: ["source_ledger_entry_for_update", "ledger_insert"],
          commit_only_after_ledger_and_success_audit: true,
          future_isolation: "read_committed_or_stronger",
          recompute_after_locks: ["confirmed_credit_sum"],
          rollback_on_audit_insert_failure: true,
          rollback_on_ledger_write_failure: true,
          rollback_on_refund_remaining_change: true,
          rollback_executor_summary_contract: {
            committed: false,
            credential_material_echoed: false,
            dedupe_material_echoed: false,
            error_detail_output: "omitted",
            operation_key_output: "omitted",
            outcome: "refused_rollback",
            raw_executor_error_detail_echoed: false,
            raw_metadata_echoed: false,
            refused_statement_count: "one_or_more",
            response_field: "ledger_executor_summary",
            rolled_back: true,
            row_count_mismatch: "boolean_only",
            schema_version: "billing_ledger_postgres_executor_summary.v1",
          },
          unbounded_scan_allowed: false,
        },
        upstream_call: false,
        validated_before_refusal: true,
      },
      ledger_executor_summary: {
        committed: false,
        dedupe_material_echoed: false,
        error_detail_output: "omitted",
        executed_statement_count: 0,
        executor: "control_plane_transactional_admin_ledger_adjustment_writer",
        final_statement_kind: null,
        final_statement_order: null,
        operation: "refund",
        operation_key_output: "omitted",
        outcome: "refused_preflight",
        raw_executor_error_detail_echoed: false,
        refused_statement_count: 0,
        rolled_back: false,
        row_count_mismatch: false,
        schema_version: "billing_ledger_postgres_executor_summary.v1",
        statement_count: 0,
        total_rows_affected: 0,
      },
      mode: "execute_contract",
      validated_plan: validatedPlan,
    };
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) =>
      Promise.resolve(
        new Response(
          JSON.stringify({
            data: contractData,
            error: {
              code: "future_writer_required",
              message: "ledger adjustment execute requires transactional ledger writer",
            },
          }),
          {
            status: 501,
            statusText: "Not Implemented",
            headers: { "Content-Type": "application/json" },
          },
        ),
      ),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      requestLedgerAdjustmentExecuteContract({
        amount: "0.25000000",
        currency: "USD",
        mode: "dry_run",
        operation: "refund",
        reason: "customer credit",
        related_ledger_entry_id: "ledger-entry-1",
        request_id: "request-1",
      }),
    ).resolves.toEqual({
      kind: "writer_required",
      message: "ledger adjustment execute requires transactional ledger writer",
      response: contractData,
      status: 501,
    });
    expect(contractData.execute_contract.contract_version).toBe("ledger_adjustment_execute_preflight_contract.v2");
    expect(contractData.execute_contract.transaction_contract?.unbounded_scan_allowed).toBe(false);
    expect(contractData.ledger_executor_summary?.outcome).toBe("refused_preflight");
    expect(contractData.execute_contract.transaction_contract?.rollback_executor_summary_contract?.outcome).toBe("refused_rollback");
    expect(contractData.execute_contract.dedupe_contract?.public_output).toBe("digest_marker_only");

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("/api/control-plane/admin/ledger/adjustments/dry-run");
    expect(init).toMatchObject({ credentials: "include", method: "POST" });
    expect(JSON.parse(String(init.body))).toEqual({
      amount: "0.25000000",
      currency: "USD",
      mode: "execute_contract",
      operation: "refund",
      reason: "customer credit",
      related_ledger_entry_id: "ledger-entry-1",
      request_id: "request-1",
    });
  });

  it("wraps ledger adjustment execute responses as explicit same-origin execute posts", async () => {
    const { executeLedgerAdjustment } = await loadClient();
    const executeResponse = {
      audit_log_write: true,
      audit_log_id: "audit-1",
      dedupe_material_echoed: false,
      ledger_executor_summary: {
        committed: true,
        dedupe_material_echoed: false,
        error_detail_output: "omitted",
        executed_statement_count: 1,
        executor: "control_plane_transactional_admin_ledger_adjustment_writer",
        final_statement_kind: "insert_ledger_entry",
        final_statement_order: 1,
        operation: "refund",
        operation_key_output: "omitted",
        outcome: "applied",
        refused_statement_count: 0,
        rolled_back: false,
        row_count_mismatch: false,
        schema_version: "billing_ledger_postgres_executor_summary.v1",
        statement_count: 1,
        total_rows_affected: 1,
      },
      ledger_executor_summary_contract: {
        credential_material_echoed: false,
        dedupe_material_echoed: false,
        error_detail_output: "omitted",
        operation_key_output: "omitted",
        raw_metadata_echoed: false,
        response_field: "ledger_executor_summary",
        schema_version: "billing_ledger_postgres_executor_summary.v1",
      },
      ledger_entry: {
        amount: "0.25000000",
        currency: "USD",
        entry_type: "refund",
        id: "ledger-entry-2",
        project_id: "project-1",
        related_ledger_entry_id: "ledger-entry-1",
        request_id: "request-1",
        status: "confirmed",
        wallet_id: "wallet-1",
      },
      ledger_write: true,
      mode: "execute",
      outcome: "applied",
      request_log_write: true,
      transaction_contract: {
        dedupe_material_echoed: false,
        rollback_executor_summary_contract: {
          committed: false,
          credential_material_echoed: false,
          dedupe_material_echoed: false,
          error_detail_output: "omitted",
          operation_key_output: "omitted",
          outcome: "refused_rollback",
          raw_executor_error_detail_echoed: false,
          raw_metadata_echoed: false,
          refused_statement_count: "one_or_more",
          response_field: "ledger_executor_summary",
          rolled_back: true,
          row_count_mismatch: "boolean_only",
          schema_version: "billing_ledger_postgres_executor_summary.v1",
        },
        unbounded_scan_allowed: false,
        write_performed: true,
        writer: "control_plane_transactional_admin_ledger_adjustment_writer",
      },
      upstream_call: false,
    };
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) => jsonResponse(executeResponse));
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      executeLedgerAdjustment({
        amount: "0.25000000",
        currency: "USD",
        operation: "refund",
        reason: "customer credit",
        related_ledger_entry_id: "ledger-entry-1",
      }),
    ).resolves.toEqual({
      kind: "future_execute",
      response: executeResponse,
    });

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("/api/control-plane/admin/ledger/adjustments/dry-run");
    expect(init).toMatchObject({ credentials: "include", method: "POST" });
    expect(JSON.parse(String(init.body))).toEqual({
      amount: "0.25000000",
      currency: "USD",
      mode: "execute",
      operation: "refund",
      reason: "customer credit",
      related_ledger_entry_id: "ledger-entry-1",
    });
  });

  it("accepts ledger adjustment execute responses with unknown fields and missing optional summaries", async () => {
    const { executeLedgerAdjustment } = await loadClient();
    const executeResponse = {
      audit_log_write: false,
      ledger_entry: null,
      ledger_executor_summary: {
        committed: true,
        error_detail_output: "omitted",
        executor: "control_plane_transactional_admin_ledger_adjustment_writer",
        experimental_safe_executor_status: "safe_executor_unknown_marker",
        operation: "adjust",
        operation_key: "operation-key-api-tolerance-hidden",
        operation_key_output: "omitted",
        outcome: "idempotent",
        raw_executor_error_detail: "raw executor api tolerance hidden",
        raw_metadata: "raw executor api tolerance metadata hidden",
        rolled_back: false,
        row_count_mismatch: false,
        schema_version: "billing_ledger_postgres_executor_summary.v1",
      },
      ledger_executor_summary_contract: null,
      ledger_write: false,
      mode: "execute",
      operation_key: "operation-key-api-response-hidden",
      outcome: "idempotent",
      raw_metadata: "raw api execute metadata hidden",
      request_log_write: false,
      transaction_contract: {
        experimental_safe_transaction_status: "safe_transaction_unknown_marker",
        writer: null,
      },
      unknown_safe_marker: "safe_backend_unknown_marker",
      upstream_call: false,
    };
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) => jsonResponse(executeResponse));
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      executeLedgerAdjustment({
        amount: "0.10000000",
        currency: "USD",
        operation: "adjust",
        reason: "manual balance correction",
        wallet_id: "wallet-1",
      }),
    ).resolves.toMatchObject({
      kind: "future_execute",
      response: {
        ledger_entry: null,
        ledger_executor_summary: {
          outcome: "idempotent",
          schema_version: "billing_ledger_postgres_executor_summary.v1",
        },
        outcome: "idempotent",
      },
    });

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(JSON.parse(String(init.body))).toEqual({
      amount: "0.10000000",
      currency: "USD",
      mode: "execute",
      operation: "adjust",
      reason: "manual balance correction",
      wallet_id: "wallet-1",
    });
  });

  it("keeps blocked execute error envelopes with data from becoming execute success", async () => {
    const { executeLedgerAdjustment } = await loadClient();
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) =>
      Promise.resolve(
        new Response(
          JSON.stringify({
            data: {
              ledger_executor_summary: {
                outcome: "blocked",
                raw_executor_error_detail: "raw executor blocked api envelope hidden",
              },
              mode: "execute",
              operation_key: "operation-key-blocked-api-envelope-hidden",
              outcome: "blocked",
              raw_metadata: "raw blocked api envelope metadata hidden",
              safe_unknown_error_marker: "safe_error_unknown_marker",
            },
            error: {
              code: "ledger_execute_blocked",
              message: "ledger adjustment execute blocked",
            },
          }),
          {
            status: 409,
            statusText: "Conflict",
            headers: { "Content-Type": "application/json" },
          },
        ),
      ),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      executeLedgerAdjustment({
        amount: "0.25000000",
        currency: "USD",
        operation: "refund",
        reason: "customer credit",
        related_ledger_entry_id: "ledger-entry-1",
      }),
    ).rejects.toMatchObject({
      code: "ledger_execute_blocked",
      message: "ledger adjustment execute blocked",
      status: 409,
    });
  });

  it("loads the current admin session through cookie credentials without fallback headers", async () => {
    const { ADMIN_SESSION_HEADER, getAdminMe } = await loadClient();
    const fetchMock = vi.fn((_url: RequestInfo | URL, _init?: RequestInit) =>
      jsonResponse({
        capability_summary: {
          allowed_capabilities: ["provider_health.read"],
          denied_capabilities: [],
          is_wildcard: false,
        },
        session: { expires_at: "2026-06-02T20:00:00Z", id: "session-1" },
        user: {
          display_name: "Local Admin",
          email: "admin@example.com",
          id: "user-1",
          roles: ["owner"],
          tenant_id: "tenant-1",
        },
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(getAdminMe()).resolves.toMatchObject({
      session: { id: "session-1" },
      user: { email: "admin@example.com" },
    });

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("/api/control-plane/admin/auth/me");
    expect(init).toMatchObject({ credentials: "include", method: "GET" });
    expect(new Headers(init.headers).get(ADMIN_SESSION_HEADER)).toBeNull();
    expect(init.body).toBeUndefined();
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
