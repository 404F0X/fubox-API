import { LogOut, type LucideIcon } from "./icons";
import type { AdminSession } from "./LoginPanel";

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

  return (
    <aside className="sidebar" aria-label="Primary navigation">
      <div className="brand">
        <span className="brand-mark">AG</span>
        <span>AI Gateway</span>
      </div>

      <nav className="nav-list">
        {items.map((item) => {
          const Icon = item.icon;
          const selected = item.id === activeView;

          return (
            <button
              aria-current={selected ? "page" : undefined}
              className={`nav-item${selected ? " nav-item--active" : ""}`}
              key={item.id}
              onClick={() => onSelect(item.id)}
              type="button"
            >
              <Icon aria-hidden="true" size={18} />
              <span className="nav-copy">
                <span>{item.label}</span>
                <span className="permission-chip">{item.permission}</span>
              </span>
            </button>
          );
        })}
      </nav>

      <div className="session-card">
        <span className="session-avatar">{initials || "AO"}</span>
        <span className="session-copy">
          <strong>{session.name}</strong>
          <span>{session.role}</span>
        </span>
        <button className="icon-button icon-button--dark" type="button" onClick={onLogout} aria-label="Sign out">
          <LogOut aria-hidden="true" size={17} />
        </button>
      </div>
    </aside>
  );
}
