import { LogOut, type LucideIcon } from "./icons";
import type { AdminSession } from "./LoginPanel";

export const LEGACY_NAVIGATION_SCOPE =
  "legacy-admin-shell-compatibility-only: use layouts/AdminShell for new admin workbench routes";

export type NavItem<TView extends string = string> = {
  capabilities: string[];
  id: TView;
  icon: LucideIcon;
  label: string;
  permission: string;
};

type Props<TView extends string> = {
  activeView: TView;
  items: NavItem<TView>[];
  onLogout: () => void;
  onSelect: (view: TView) => void;
  session: AdminSession;
};

export function Navigation<TView extends string>({ activeView, items, onLogout, onSelect, session }: Props<TView>) {
  const initials = session.name
    .split(" ")
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase())
    .join("");

  function groupForItem(id: string): string {
    if (id === "overview" || id === "distribution") {
      return "工作区";
    }
    if (id === "requestLogs" || id === "keys") {
      return "项目";
    }
    return "管理";
  }

  let previousGroup = "";

  return (
    <aside className="sidebar sidebar--legacy-compat" aria-label="旧版兼容导航" data-admin-shell="legacy-compat">
      <span className="legacy-only-note">{LEGACY_NAVIGATION_SCOPE}</span>
      <div className="brand">
        <span className="brand-mark">AG</span>
        <span>AI Gateway</span>
      </div>

      <nav className="nav-list">
        {items.map((item) => {
          const Icon = item.icon;
          const selected = item.id === activeView;
          const group = groupForItem(item.id);
          const showGroup = group !== previousGroup;
          previousGroup = group;

          return (
            <div className="nav-entry" key={item.id}>
              {showGroup ? <span className="nav-group-label">{group}</span> : null}
              <button
                aria-current={selected ? "page" : undefined}
                className={`nav-item${selected ? " nav-item--active" : ""}`}
                onClick={() => onSelect(item.id)}
                type="button"
              >
                <Icon aria-hidden="true" size={18} />
                <span className="nav-copy">
                  <span>{item.label}</span>
                  <span aria-hidden="true" className="permission-chip">
                    {item.permission}
                  </span>
                </span>
              </button>
            </div>
          );
        })}
      </nav>

      <div className="session-card">
        <span className="session-avatar">{initials || "AO"}</span>
        <span className="session-copy">
          <strong>{session.name}</strong>
          <span>{session.role}</span>
        </span>
        <button className="icon-button icon-button--dark" type="button" onClick={onLogout} aria-label="退出登录">
          <LogOut aria-hidden="true" size={17} />
        </button>
      </div>
    </aside>
  );
}
