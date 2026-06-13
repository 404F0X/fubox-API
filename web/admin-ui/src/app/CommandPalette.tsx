import { useEffect, useMemo, useRef, useState } from "react";

import { ArrowRight, Search, X } from "../components/icons";
import type { NavItem } from "../components/Navigation";
import type { ApiKeysFocusTarget, AppView, UsersFocusTarget } from "./types";

type CommandPaletteProps = {
  items: NavItem<AppView>[];
  open: boolean;
  onClose: () => void;
  onCreateProvider: () => void;
  onOpenBillingWallet: () => void;
  onNavigate: (view: AppView) => void;
  onOpenApiKey: (target: ApiKeysFocusTarget) => void;
  onOpenRequest: (requestId: string) => void;
  onOpenRequestLogs: () => void;
  onOpenUser: (target: UsersFocusTarget) => void;
  onOpenUserPortal: () => void;
};

type CommandAction = {
  detail: string;
  disabled: boolean;
  id: string;
  keywords: string;
  label: string;
  onSelect: () => void;
  tag: string;
};

type RecentCommand = {
  detail: string;
  id: string;
  label: string;
  tag: string;
};

type QuickActionId = "createProvider" | "requestLogs" | "billingWallet" | "userPortal";

const recentStorageKey = "fubox.admin.commandPalette.recent.v1";
const maxRecentCommands = 5;

const targetActions: Array<{
  detail: string;
  id: string;
  keywords: string;
  label: string;
  tag: string;
  view: AppView;
}> = [
  {
    detail: "供应商、通道和通道健康工作流",
    id: "providers",
    keywords: "providers channels upstream provider health 供应商 通道 上游 健康",
    label: "Providers / Channels",
    tag: "Navigate",
    view: "providers",
  },
  {
    detail: "模型目录、价格表绑定和上游映射",
    id: "models",
    keywords: "models model catalog mapping price 模型 目录 映射 价格",
    label: "Models",
    tag: "Navigate",
    view: "models",
  },
  {
    detail: "路由 dry-run、可见模型和候选通道",
    id: "routing",
    keywords: "routing route dry-run profile candidate 路由 调试 dryrun",
    label: "Routing",
    tag: "Navigate",
    view: "routing",
  },
  {
    detail: "请求日志、trace、成本和安全 payload preview",
    id: "requestLogs",
    keywords: "requests traces request logs trace usage 请求 追踪 日志 排障",
    label: "Requests / Traces",
    tag: "Navigate",
    view: "requestLogs",
  },
  {
    detail: "余额、ledger、价格、voucher 和本地支付 demo",
    id: "billing",
    keywords: "billing ledger wallet voucher price payment 计费 余额 账本 价格",
    label: "Billing",
    tag: "Navigate",
    view: "billing",
  },
  {
    detail: "迁移 dry-run、apply-plan 审阅和 rollback 信息",
    id: "importWizard",
    keywords: "import migration dry-run apply plan rollback 导入 迁移",
    label: "Import",
    tag: "Navigate",
    view: "importWizard",
  },
  {
    detail: "用户、项目、余额、key 和请求摘要",
    id: "users",
    keywords: "users user project account 用户 项目 账号",
    label: "Users",
    tag: "Navigate",
    view: "users",
  },
  {
    detail: "审计日志和安全跳转上下文",
    id: "auditLogs",
    keywords: "audit logs events 审计 日志 事件",
    label: "Audit",
    tag: "Navigate",
    view: "auditLogs",
  },
  {
    detail: "网络安全、allowlist 和 trusted proxy readback",
    id: "settings",
    keywords: "settings network security allowlist proxy 设置 网络 安全",
    label: "Settings",
    tag: "Navigate",
    view: "settings",
  },
];

export function CommandPalette({
  items,
  open,
  onClose,
  onCreateProvider,
  onOpenBillingWallet,
  onNavigate,
  onOpenApiKey,
  onOpenRequest,
  onOpenRequestLogs,
  onOpenUser,
  onOpenUserPortal,
}: CommandPaletteProps) {
  const [query, setQuery] = useState("");
  const [recentCommands, setRecentCommands] = useState<RecentCommand[]>([]);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const availableViews = useMemo(() => new Set(items.map((item) => item.id)), [items]);

  useEffect(() => {
    setRecentCommands(readRecentCommands());
  }, []);

  useEffect(() => {
    if (!open) {
      setQuery("");
      return;
    }

    const handle = window.setTimeout(() => inputRef.current?.focus(), 0);
    return () => window.clearTimeout(handle);
  }, [open]);

  useEffect(() => {
    if (!open) {
      return;
    }

    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        event.preventDefault();
        onClose();
      }
    }

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose, open]);

  const actions = useMemo(
    () =>
      buildActions({
        availableViews,
        onClose,
        onCreateProvider,
        onOpenBillingWallet,
        onNavigate,
        onOpenApiKey,
        onOpenRequest,
        onOpenRequestLogs,
        onOpenUser,
        onOpenUserPortal,
        query,
        recentCommands,
        recordRecent: (command) => setRecentCommands(writeRecentCommand(command)),
      }),
    [
      availableViews,
      onClose,
      onCreateProvider,
      onOpenBillingWallet,
      onNavigate,
      onOpenApiKey,
      onOpenRequest,
      onOpenRequestLogs,
      onOpenUser,
      onOpenUserPortal,
      query,
      recentCommands,
    ],
  );

  if (!open) {
    return null;
  }

  return (
    <div className="command-palette-backdrop" role="presentation" onMouseDown={onClose}>
      <section
        aria-label="全局快速导航"
        aria-modal="true"
        className="command-palette"
        role="dialog"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="command-palette__search">
          <Search aria-hidden="true" size={18} />
          <input
            aria-label="全局搜索或跳转"
            ref={inputRef}
            value={query}
            onChange={(event) => setQuery(event.currentTarget.value)}
            placeholder="输入页面、request id、key prefix 或 user id"
          />
          <button aria-label="关闭全局快速导航" className="admin-icon-button-v2" type="button" onClick={onClose}>
            <X aria-hidden="true" size={16} />
          </button>
        </div>

        <div className="command-palette__notice" role="note">
          只做导航和安全定位提示；不会执行全局数据搜索，也不会展示 secret、Authorization、prompt 或 raw payload。
        </div>

        <div className="command-palette__list" role="listbox" aria-label="快速跳转结果">
          {actions.length > 0 ? (
            actions.map((action) => (
              <button
                aria-disabled={action.disabled ? "true" : undefined}
                className="command-palette__item"
                disabled={action.disabled}
                key={action.id}
                onClick={action.onSelect}
                role="option"
                type="button"
              >
                <span>
                  <strong>{action.label}</strong>
                  <small>{action.detail}</small>
                </span>
                <span className="command-palette__tag">{action.tag}</span>
                <ArrowRight aria-hidden="true" size={16} />
              </button>
            ))
          ) : (
            <div className="command-palette__empty" role="status">
              <strong>没有匹配目标</strong>
              <span>保留占位：该入口不会降级为 raw 数据搜索。请尝试 Providers、Models、Routing、Requests 或明确 ID 前缀。</span>
            </div>
          )}
        </div>
      </section>
    </div>
  );
}

function buildActions({
  availableViews,
  onClose,
  onCreateProvider,
  onOpenBillingWallet,
  onNavigate,
  onOpenApiKey,
  onOpenRequest,
  onOpenRequestLogs,
  onOpenUser,
  onOpenUserPortal,
  query,
  recentCommands,
  recordRecent,
}: {
  availableViews: Set<AppView>;
  onClose: () => void;
  onCreateProvider: () => void;
  onOpenBillingWallet: () => void;
  onNavigate: (view: AppView) => void;
  onOpenApiKey: (target: ApiKeysFocusTarget) => void;
  onOpenRequest: (requestId: string) => void;
  onOpenRequestLogs: () => void;
  onOpenUser: (target: UsersFocusTarget) => void;
  onOpenUserPortal: () => void;
  query: string;
  recentCommands: RecentCommand[];
  recordRecent: (command: RecentCommand) => void;
}): CommandAction[] {
  const normalizedQuery = query.trim().toLowerCase();
  const quickActions = buildQuickActions({
    availableViews,
    normalizedQuery,
    onClose,
    onCreateProvider,
    onOpenBillingWallet,
    onOpenRequestLogs,
    onOpenUserPortal,
    recordRecent,
  });
  const recentActions = buildRecentActions({
    availableViews,
    normalizedQuery,
    onClose,
    onCreateProvider,
    onNavigate,
    onOpenBillingWallet,
    onOpenRequestLogs,
    onOpenUserPortal,
    recentCommands,
  });
  const actions: CommandAction[] = targetActions
    .filter((action) => !normalizedQuery || `${action.label} ${action.keywords}`.toLowerCase().includes(normalizedQuery))
    .map((action) => {
      const disabled = !availableViews.has(action.view);
      return {
        detail: disabled ? "当前管理员权限没有开放该目标，保留占位。" : action.detail,
        disabled,
        id: `view:${action.id}`,
        keywords: action.keywords,
        label: action.label,
        onSelect: () => {
          if (disabled) {
            return;
          }
          recordRecent({
            detail: action.detail,
            id: `view:${action.id}`,
            label: action.label,
            tag: "Recent",
          });
          onNavigate(action.view);
          onClose();
        },
        tag: disabled ? "Unavailable" : action.tag,
      };
    });

  const target = parseTypedTarget(query);
  if (target) {
    actions.unshift(
      typedTargetAction({
        availableViews,
        onClose,
        onOpenApiKey,
        onOpenRequest,
        onOpenUser,
        target,
      }),
    );
  }

  return [...quickActions, ...recentActions, ...actions].slice(0, 12);
}

function buildQuickActions({
  availableViews,
  normalizedQuery,
  onClose,
  onCreateProvider,
  onOpenBillingWallet,
  onOpenRequestLogs,
  onOpenUserPortal,
  recordRecent,
}: {
  availableViews: Set<AppView>;
  normalizedQuery: string;
  onClose: () => void;
  onCreateProvider: () => void;
  onOpenBillingWallet: () => void;
  onOpenRequestLogs: () => void;
  onOpenUserPortal: () => void;
  recordRecent: (command: RecentCommand) => void;
}): CommandAction[] {
  const quickActions: Array<{
    detail: string;
    disabled?: boolean;
    id: QuickActionId;
    keywords: string;
    label: string;
    onSelect: () => void;
    tag: string;
  }> = [
    {
      detail: "打开 Providers 并展开新建 provider 表单；只录入配置，不读取 secret。",
      disabled: !availableViews.has("providers"),
      id: "createProvider",
      keywords: "new create provider upstream 新建 创建 供应商",
      label: "新建 Provider",
      onSelect: onCreateProvider,
      tag: "Quick action",
    },
    {
      detail: "打开 Requests / Traces 列表；不会展示 prompt、raw payload 或 Authorization。",
      disabled: !availableViews.has("requestLogs"),
      id: "requestLogs",
      keywords: "request logs traces open requests 请求 日志 追踪",
      label: "打开 Request Logs",
      onSelect: onOpenRequestLogs,
      tag: "Shortcut",
    },
    {
      detail: "打开 Billing 的钱包余额视图；只展示 wallet/ledger 安全摘要。",
      disabled: !availableViews.has("billing"),
      id: "billingWallet",
      keywords: "billing wallet ledger balance 钱包 余额 计费 账本",
      label: "打开 Billing Wallet",
      onSelect: onOpenBillingWallet,
      tag: "Shortcut",
    },
    {
      detail: "切换到用户控制台入口；不携带管理员 secret 或 raw payload。",
      id: "userPortal",
      keywords: "user portal developer console 用户 控制台 portal",
      label: "打开 User Portal",
      onSelect: onOpenUserPortal,
      tag: "Shortcut",
    },
  ];

  return quickActions
    .filter((action) => !normalizedQuery || `${action.label} ${action.keywords}`.toLowerCase().includes(normalizedQuery))
    .map((action) => ({
      detail: action.disabled ? "当前管理员权限没有开放该目标，保留安全占位。" : action.detail,
      disabled: action.disabled ?? false,
      id: `quick:${action.id}`,
      keywords: action.keywords,
      label: action.label,
      onSelect: () => {
        if (action.disabled) {
          return;
        }
        recordRecent({
          detail: action.detail,
          id: `quick:${action.id}`,
          label: action.label,
          tag: action.tag,
        });
        action.onSelect();
        onClose();
      },
      tag: action.disabled ? "Unavailable" : action.tag,
    }));
}

function buildRecentActions({
  availableViews,
  normalizedQuery,
  onClose,
  onCreateProvider,
  onNavigate,
  onOpenBillingWallet,
  onOpenRequestLogs,
  onOpenUserPortal,
  recentCommands,
}: {
  availableViews: Set<AppView>;
  normalizedQuery: string;
  onClose: () => void;
  onCreateProvider: () => void;
  onNavigate: (view: AppView) => void;
  onOpenBillingWallet: () => void;
  onOpenRequestLogs: () => void;
  onOpenUserPortal: () => void;
  recentCommands: RecentCommand[];
}): CommandAction[] {
  if (normalizedQuery || recentCommands.length === 0) {
    return [];
  }

  return recentCommands.map((command) => {
    const runnable = commandToRunnable({
      availableViews,
      commandId: command.id,
      onCreateProvider,
      onNavigate,
      onOpenBillingWallet,
      onOpenRequestLogs,
      onOpenUserPortal,
    });
    return {
      detail: runnable.disabled ? "该最近入口当前不可用，保留安全占位。" : command.detail,
      disabled: runnable.disabled,
      id: `recent:${command.id}`,
      keywords: command.label,
      label: command.label,
      onSelect: () => {
        if (runnable.disabled) {
          return;
        }
        runnable.run();
        onClose();
      },
      tag: "Recent",
    };
  });
}

function typedTargetAction({
  availableViews,
  onClose,
  onOpenApiKey,
  onOpenRequest,
  onOpenUser,
  target,
}: {
  availableViews: Set<AppView>;
  onClose: () => void;
  onOpenApiKey: (target: ApiKeysFocusTarget) => void;
  onOpenRequest: (requestId: string) => void;
  onOpenUser: (target: UsersFocusTarget) => void;
  target: ParsedTarget;
}): CommandAction {
  if (target.kind === "request") {
    const disabled = !availableViews.has("requestLogs");
    return {
      detail: disabled
        ? "Requests 目标不可用，保留占位。"
        : `打开 request detail drawer：${safePreview(target.value)}`,
      disabled,
      id: `typed:request:${target.value}`,
      keywords: target.value,
      label: "跳转到 Request ID",
      onSelect: () => {
        if (disabled) {
          return;
        }
        onOpenRequest(target.value);
        onClose();
      },
      tag: disabled ? "Unavailable" : "Safe jump",
    };
  }

  if (target.kind === "keyPrefix") {
    const disabled = !availableViews.has("keys");
    return {
      detail: disabled
        ? "API 密钥目标不可用，保留占位。"
        : `按 key prefix 安全定位：${safePreview(target.value)}。不会展示 secret。`,
      disabled,
      id: `typed:key:${target.value}`,
      keywords: target.value,
      label: "跳转到 API Key Prefix",
      onSelect: () => {
        if (disabled) {
          return;
        }
        onOpenApiKey({ keyPrefix: target.value });
        onClose();
      },
      tag: disabled ? "Unavailable" : "Safe hint",
    };
  }

  const disabled = !availableViews.has("users");
  return {
    detail: disabled ? "Users 目标不可用，保留占位。" : `按 user id 过滤用户工作台：${safePreview(target.value)}`,
    disabled,
    id: `typed:user:${target.value}`,
    keywords: target.value,
    label: "跳转到 User ID",
    onSelect: () => {
      if (disabled) {
        return;
      }
      onOpenUser({ userId: target.value });
      onClose();
    },
    tag: disabled ? "Unavailable" : "Safe filter",
  };
}

type ParsedTarget =
  | { kind: "keyPrefix"; value: string }
  | { kind: "request"; value: string }
  | { kind: "user"; value: string };

function parseTypedTarget(rawQuery: string): ParsedTarget | null {
  const query = rawQuery.trim();

  if (!query) {
    return null;
  }

  const explicit = query.match(/^(request|req|key|prefix|user)\s*[:#]\s*(.+)$/i);
  if (explicit) {
    const kind = explicit[1].toLowerCase();
    const value = cleanTargetValue(explicit[2]);
    if (!value) {
      return null;
    }
    if (kind === "request" || kind === "req") {
      return { kind: "request", value };
    }
    if (kind === "key" || kind === "prefix") {
      return { kind: "keyPrefix", value: keyPrefixOnly(value) };
    }
    return { kind: "user", value };
  }

  const value = cleanTargetValue(query);
  if (/^req[_-][A-Za-z0-9_.:-]{4,}$/.test(value)) {
    return { kind: "request", value };
  }
  if (/^(vk|key)[_-][A-Za-z0-9_.:-]{3,}$/.test(value)) {
    return { kind: "keyPrefix", value: keyPrefixOnly(value) };
  }
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    return { kind: "user", value };
  }

  return null;
}

function cleanTargetValue(value: string): string {
  return value.trim().replace(/^["']|["']$/g, "");
}

function keyPrefixOnly(value: string): string {
  const trimmed = value.trim();
  return trimmed.length > 20 ? trimmed.slice(0, 20) : trimmed;
}

function safePreview(value: string): string {
  if (value.length <= 14) {
    return value;
  }
  return `${value.slice(0, 10)}...${value.slice(-4)}`;
}

function readRecentCommands(): RecentCommand[] {
  try {
    const raw = window.localStorage.getItem(recentStorageKey);
    if (!raw) {
      return [];
    }
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }
    return parsed.filter(isRecentCommand).slice(0, maxRecentCommands);
  } catch {
    return [];
  }
}

function writeRecentCommand(command: RecentCommand): RecentCommand[] {
  const next = [command, ...readRecentCommands().filter((item) => item.id !== command.id)].slice(0, maxRecentCommands);
  try {
    window.localStorage.setItem(recentStorageKey, JSON.stringify(next));
  } catch {
    // Local UI state only; storage failure should not block navigation.
  }
  return next;
}

function isRecentCommand(value: unknown): value is RecentCommand {
  if (!value || typeof value !== "object") {
    return false;
  }
  const candidate = value as Partial<RecentCommand>;
  return (
    typeof candidate.detail === "string" &&
    typeof candidate.id === "string" &&
    typeof candidate.label === "string" &&
    typeof candidate.tag === "string"
  );
}

function commandToRunnable({
  availableViews,
  commandId,
  onCreateProvider,
  onNavigate,
  onOpenBillingWallet,
  onOpenRequestLogs,
  onOpenUserPortal,
}: {
  availableViews: Set<AppView>;
  commandId: string;
  onCreateProvider: () => void;
  onNavigate: (view: AppView) => void;
  onOpenBillingWallet: () => void;
  onOpenRequestLogs: () => void;
  onOpenUserPortal: () => void;
}): { disabled: boolean; run: () => void } {
  if (commandId.startsWith("view:")) {
    const view = commandId.slice("view:".length);
    if (!isAppView(view) || !availableViews.has(view)) {
      return { disabled: true, run: () => undefined };
    }
    return { disabled: false, run: () => onNavigate(view) };
  }

  if (commandId === "quick:createProvider") {
    return { disabled: !availableViews.has("providers"), run: onCreateProvider };
  }
  if (commandId === "quick:requestLogs") {
    return { disabled: !availableViews.has("requestLogs"), run: onOpenRequestLogs };
  }
  if (commandId === "quick:billingWallet") {
    return { disabled: !availableViews.has("billing"), run: onOpenBillingWallet };
  }
  if (commandId === "quick:userPortal") {
    return { disabled: false, run: onOpenUserPortal };
  }

  return { disabled: true, run: () => undefined };
}

function isAppView(value: string): value is AppView {
  return targetActions.some((action) => action.view === value) || value === "overview" || value === "providerKeys" || value === "keys";
}
