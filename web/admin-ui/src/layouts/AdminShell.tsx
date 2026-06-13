import type { ReactNode } from "react";
import { LogOut, Search } from "../components/icons";
import type { AdminSession } from "../components/LoginPanel";
import type { NavItem } from "../components/Navigation";

type AdminShellProps<TView extends string> = {
  activePermission: string;
  activeTitle: string;
  activeView: TView;
  children: ReactNode;
  commandPalette?: ReactNode;
  context?: Array<{ label: string; tone?: "default" | "muted" }>;
  items: NavItem<TView>[];
  onLogout: () => void;
  onOpenCommandPalette?: () => void;
  onSelect: (view: TView) => void;
  session: AdminSession;
};

export function AdminShell<TView extends string>({
  activePermission,
  activeTitle,
  activeView,
  children,
  commandPalette,
  context = [
    { label: "默认", tone: "default" },
    { label: "本地", tone: "muted" },
  ],
  items,
  onLogout,
  onOpenCommandPalette,
  onSelect,
  session,
}: AdminShellProps<TView>) {
  const initials = session.name
    .split(" ")
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase())
    .join("");

  let previousGroup = "";

  return (
    <main className="admin-shell-v2">
      <aside className="admin-sidebar-v2" aria-label="主导航">
        <div className="admin-brand-v2">
          <span className="admin-brand-mark-v2">FB</span>
          <span>
            <strong>Fubox API</strong>
            <small>控制台</small>
          </span>
        </div>

        <nav className="admin-nav-v2">
          {items.map((item) => {
            const Icon = item.icon;
            const selected = item.id === activeView;
            const group = groupForItem(item.id);
            const showGroup = group !== previousGroup;
            previousGroup = group;

            return (
              <div className="admin-nav-entry-v2" key={item.id}>
                {showGroup ? <span className="admin-nav-group-v2">{group}</span> : null}
                <button
                  aria-current={selected ? "page" : undefined}
                  className={`admin-nav-item-v2${selected ? " admin-nav-item-v2--active" : ""}`}
                  onClick={() => onSelect(item.id)}
                  type="button"
                >
                  <Icon aria-hidden="true" size={17} />
                  <span>{item.label}</span>
                  <small>{item.permission}</small>
                </button>
              </div>
            );
          })}
        </nav>

        <div className="admin-session-v2">
          <span className="admin-session-avatar-v2">{initials || "AD"}</span>
          <span className="admin-session-copy-v2">
            <strong>{session.name}</strong>
            <small>{session.role}</small>
          </span>
          <button className="admin-icon-button-v2" type="button" onClick={onLogout} aria-label="退出登录">
            <LogOut aria-hidden="true" size={16} />
          </button>
        </div>
      </aside>

      <section className="admin-workspace-v2">
        <header className="admin-topbar-v2">
          <div>
            <p className="eyebrow">{activePermission}工作区</p>
            <h1>{activeTitle}</h1>
          </div>
          <div className="admin-topbar-actions-v2">
            {onOpenCommandPalette ? (
              <button
                aria-label="打开全局快速导航"
                className="admin-command-trigger-v2"
                onClick={onOpenCommandPalette}
                type="button"
              >
                <Search aria-hidden="true" size={17} />
                <span>搜索 / 跳转</span>
                <kbd>Ctrl K</kbd>
              </button>
            ) : null}
            <div className="admin-context-v2" aria-label="工作区上下文">
              {context.map((item) => (
                <span
                  className={`admin-context-pill-v2${item.tone === "muted" ? " admin-context-pill-v2--muted" : ""}`}
                  key={item.label}
                >
                  {item.label}
                </span>
              ))}
            </div>
          </div>
        </header>

        <div className="admin-page-v2">{children}</div>
      </section>
      {commandPalette}
    </main>
  );
}

function groupForItem(id: string): string {
  if (id === "overview" || id === "distribution") {
    return "工作区";
  }
  if (id === "providers" || id === "providerKeys" || id === "models" || id === "routing") {
    return "运营";
  }
  if (id === "keys" || id === "requestLogs" || id === "billing") {
    return "项目";
  }
  return "治理";
}
