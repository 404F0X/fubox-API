export type SavedTableFilterStore<TFilters extends Record<string, string>> = {
  clear: () => void;
  read: () => TFilters | null;
  write: (filters: TFilters) => boolean;
};

export type TableBulkActionHandoff = {
  action: string;
  disabled?: boolean;
  reasonRequired?: boolean;
  scope: "visible_rows" | "selected_rows" | "filtered_result";
  selectedCount: number;
  status: "idle" | "ready" | "running" | "completed" | "blocked";
  totalCount?: number;
};

export type TableBulkActionSummary = {
  label: string;
  tone: "muted" | "ready" | "running" | "success" | "blocked";
};

export type TableServerSortDir = "asc" | "desc";

export type TableServerPaginationRequest = {
  cursor?: string;
  limit: number;
  page?: number;
  sort_dir?: TableServerSortDir;
  sort_key?: string;
};

export type TableServerPaginationMeta = {
  cursor?: string | null;
  has_more?: boolean | null;
  limit: number;
  next_cursor?: string | null;
  page?: number | null;
  sort_dir?: TableServerSortDir;
  sort_key?: string | null;
  total?: number | null;
  unsupported?: boolean;
  unsupported_reason?: string;
};

export type TableServerPage<TItem> = {
  items: TItem[];
  pagination: TableServerPaginationMeta;
};

export const adminTableServerPaginationContract = {
  schema_version: "admin_table_server_pagination.v1",
  request_fields: ["limit", "cursor", "page", "sort_key", "sort_dir"],
  response_fields: ["items", "total", "has_more", "next_cursor"],
  unsupported_fallback: "legacy array responses keep the visible table working and mark pagination.unsupported=true",
  secret_safe: true,
  forbidden_fields: ["authorization", "provider_key", "raw_payload", "raw_request_payload", "raw_response_payload"],
} as const;

type StorageLike = Pick<Storage, "getItem" | "removeItem" | "setItem">;

export function createSavedTableFilterStore<TFilters extends Record<string, string>>({
  defaults,
  isValid,
  storageKey,
}: {
  defaults: TFilters;
  isValid?: (value: unknown) => value is Partial<TFilters>;
  storageKey: string;
}): SavedTableFilterStore<TFilters> {
  return {
    clear: () => clearSavedTableState(storageKey),
    read: () => readSavedTableState(storageKey, defaults, isValid ?? stringRecordFilterGuard(defaults)),
    write: (filters) => writeSavedTableState(storageKey, filters),
  };
}

export function reconcileVisibleTableColumns(columns: Array<{ id: string; locked?: boolean }>, visibleColumns?: string[]): string[] {
  const knownIds = new Set(columns.map((column) => column.id));
  const lockedIds = columns.filter((column) => column.locked).map((column) => column.id);
  const requested = visibleColumns?.length ? visibleColumns.filter((id) => knownIds.has(id)) : columns.map((column) => column.id);
  return Array.from(new Set([...lockedIds, ...requested]));
}

export function summarizeTableBulkAction(handoff: TableBulkActionHandoff): TableBulkActionSummary {
  if (handoff.status === "running") {
    return { label: "批量操作执行中", tone: "running" };
  }

  if (handoff.disabled) {
    return { label: "批量操作不可用", tone: "blocked" };
  }

  if (handoff.status === "completed") {
    return { label: `已处理 ${handoff.selectedCount} 项`, tone: "success" };
  }

  if (handoff.status === "blocked" || handoff.selectedCount === 0) {
    return { label: "选择行后可批量操作", tone: "muted" };
  }

  const scopeLabel = handoff.scope === "selected_rows" ? "已选择" : handoff.scope === "visible_rows" ? "当前可见" : "筛选结果";
  return {
    label: `${scopeLabel} ${handoff.selectedCount} 项可执行 ${handoff.action}`,
    tone: "ready",
  };
}

export function normalizeTableServerPage<TItem>(
  payload: TItem[] | Partial<TableServerPage<TItem>> | { data?: unknown; items?: unknown; total?: unknown; has_more?: unknown; next_cursor?: unknown },
  request: TableServerPaginationRequest,
): TableServerPage<TItem> {
  if (Array.isArray(payload)) {
    return {
      items: payload,
      pagination: {
        cursor: request.cursor ?? null,
        has_more: null,
        limit: request.limit,
        page: request.page ?? null,
        sort_dir: request.sort_dir,
        sort_key: request.sort_key ?? null,
        total: null,
        unsupported: true,
        unsupported_reason: "endpoint_returned_legacy_array",
      },
    };
  }

  const record: Record<string, unknown> = isRecord(payload) ? payload : {};
  const candidateItems = Array.isArray(record.items)
    ? record.items
    : Array.isArray(record.data)
      ? record.data
      : [];
  const pagination = isRecord(record.pagination) ? record.pagination : record;

  return {
    items: candidateItems as TItem[],
    pagination: {
      cursor: stringOrNull(pagination.cursor) ?? request.cursor ?? null,
      has_more: booleanOrNull(pagination.has_more),
      limit: numberOrDefault(pagination.limit, request.limit),
      next_cursor: stringOrNull(pagination.next_cursor),
      page: numberOrNull(pagination.page) ?? request.page ?? null,
      sort_dir: tableSortDir(pagination.sort_dir) ?? request.sort_dir,
      sort_key: stringOrNull(pagination.sort_key) ?? request.sort_key ?? null,
      total: numberOrNull(pagination.total),
      unsupported: pagination.unsupported === true ? true : undefined,
      unsupported_reason: typeof pagination.unsupported_reason === "string" ? pagination.unsupported_reason : undefined,
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value : null;
}

function booleanOrNull(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
}

function numberOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function numberOrDefault(value: unknown, fallback: number): number {
  return numberOrNull(value) ?? fallback;
}

function tableSortDir(value: unknown): TableServerSortDir | undefined {
  return value === "asc" || value === "desc" ? value : undefined;
}

function readSavedTableState<TFilters extends Record<string, string>>(
  storageKey: string,
  defaults: TFilters,
  isValid: (value: unknown) => value is Partial<TFilters>,
): TFilters | null {
  const storage = browserStorage();
  if (!storage) {
    return null;
  }

  try {
    const raw = storage.getItem(storageKey);
    if (!raw) {
      return null;
    }

    const parsed = JSON.parse(raw);
    if (!isValid(parsed)) {
      return null;
    }

    return { ...defaults, ...parsed };
  } catch {
    return null;
  }
}

function writeSavedTableState<TFilters extends Record<string, string>>(storageKey: string, filters: TFilters): boolean {
  const storage = browserStorage();
  if (!storage) {
    return false;
  }

  try {
    storage.setItem(storageKey, JSON.stringify(filters));
    return true;
  } catch {
    return false;
  }
}

function clearSavedTableState(storageKey: string) {
  const storage = browserStorage();
  if (!storage) {
    return;
  }

  try {
    storage.removeItem(storageKey);
  } catch {
    // The table can continue with in-memory defaults.
  }
}

function stringRecordFilterGuard<TFilters extends Record<string, string>>(defaults: TFilters) {
  return (value: unknown): value is Partial<TFilters> => {
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
      return false;
    }

    const candidate = value as Record<string, unknown>;
    return Object.keys(defaults).every((key) => typeof candidate[key] === "string" || candidate[key] === undefined);
  };
}

function browserStorage(): StorageLike | null {
  if (typeof window === "undefined") {
    return null;
  }

  return window.localStorage;
}
