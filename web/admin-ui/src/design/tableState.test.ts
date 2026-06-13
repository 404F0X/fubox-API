import { afterEach, describe, expect, it, vi } from "vitest";
import {
  createSavedTableFilterStore,
  normalizeTableServerPage,
  reconcileVisibleTableColumns,
  summarizeTableBulkAction,
} from "./tableState";

afterEach(() => {
  window.localStorage.clear();
  vi.restoreAllMocks();
});

describe("tableState", () => {
  it("stores and restores string filter state with defaults", () => {
    const store = createSavedTableFilterStore({
      defaults: { limit: "25", status: "", traceId: "" },
      storageKey: "fubox.test.table.filters",
    });

    expect(store.read()).toBeNull();
    expect(store.write({ limit: "50", status: "failed", traceId: "trace-1" })).toBe(true);
    expect(store.read()).toEqual({ limit: "50", status: "failed", traceId: "trace-1" });

    window.localStorage.setItem("fubox.test.table.filters", JSON.stringify({ status: "succeeded" }));
    expect(store.read()).toEqual({ limit: "25", status: "succeeded", traceId: "" });

    store.clear();
    expect(store.read()).toBeNull();
  });

  it("rejects invalid saved filter state", () => {
    const store = createSavedTableFilterStore({
      defaults: { limit: "25", status: "" },
      storageKey: "fubox.test.table.invalid",
    });

    window.localStorage.setItem("fubox.test.table.invalid", JSON.stringify({ limit: 25, status: "failed" }));
    expect(store.read()).toBeNull();
  });

  it("keeps locked columns and drops unknown column ids", () => {
    expect(
      reconcileVisibleTableColumns(
        [
          { id: "select", locked: true },
          { id: "name", locked: true },
          { id: "status" },
          { id: "actions", locked: true },
        ],
        ["status", "unknown"],
      ),
    ).toEqual(["select", "name", "actions", "status"]);
  });

  it("summarizes bulk action handoff states", () => {
    expect(
      summarizeTableBulkAction({
        action: "停用",
        scope: "selected_rows",
        selectedCount: 2,
        status: "ready",
      }),
    ).toEqual({ label: "已选择 2 项可执行 停用", tone: "ready" });

    expect(
      summarizeTableBulkAction({
        action: "停用",
        scope: "selected_rows",
        selectedCount: 0,
        status: "idle",
      }),
    ).toEqual({ label: "选择行后可批量操作", tone: "muted" });
  });

  it("normalizes server pagination envelopes and legacy array fallbacks", () => {
    expect(
      normalizeTableServerPage([{ id: "request-1" }], {
        limit: 25,
        sort_dir: "desc",
        sort_key: "created_at",
      }),
    ).toEqual({
      items: [{ id: "request-1" }],
      pagination: {
        cursor: null,
        has_more: null,
        limit: 25,
        page: null,
        sort_dir: "desc",
        sort_key: "created_at",
        total: null,
        unsupported: true,
        unsupported_reason: "endpoint_returned_legacy_array",
      },
    });

    expect(
      normalizeTableServerPage(
        {
          items: [{ id: "request-2" }],
          pagination: {
            has_more: true,
            limit: 10,
            next_cursor: "cursor-2",
            sort_dir: "asc",
            sort_key: "latency_ms",
            total: 42,
          },
        },
        { limit: 25, sort_dir: "desc", sort_key: "created_at" },
      ),
    ).toEqual({
      items: [{ id: "request-2" }],
      pagination: {
        cursor: null,
        has_more: true,
        limit: 10,
        next_cursor: "cursor-2",
        page: null,
        sort_dir: "asc",
        sort_key: "latency_ms",
        total: 42,
        unsupported: undefined,
        unsupported_reason: undefined,
      },
    });
  });
});
