import { FormEvent, useState } from "react";
import { getAdminMe, loginAdmin, type AdminCapabilitySummary, type AdminMeResponse, type AdminUser } from "../api/client";
import { errorMessage } from "./adminUtils";
import { LogIn, ShieldCheck } from "./icons";

export type AdminSession = {
  capabilitySummary: AdminCapabilitySummary;
  email: string;
  expiresAt: string;
  name: string;
  role: "Owner" | "Admin" | "Operator" | "Billing" | "Viewer" | "Auditor";
  roles: string[];
  sessionId: string;
  tenantId: string;
  userId: string;
};

type Props = {
  onLogin: (session: AdminSession) => void;
  onUserMode?: () => void;
};

export function LoginPanel({ onLogin, onUserMode }: Props) {
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [password, setPassword] = useState("");

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setLoading(true);

    try {
      await loginAdmin({
        email: email.trim(),
        password,
      });
      const me = await getAdminMe();

      onLogin(adminSessionFromMe(me));
      setPassword("");
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setLoading(false);
    }
  }

  return (
    <main className="auth-shell">
      <section className="auth-panel" aria-labelledby="login-title">
        <div className="auth-brand">
          <span className="brand-mark">FB</span>
          <span>Fubox API</span>
        </div>
        <p className="eyebrow">管理控制台</p>
        <h1 id="login-title">管理员登录</h1>

        <form className="login-form" onSubmit={handleSubmit}>
          <label>
            邮箱
            <input
              autoComplete="username"
              name="email"
              onChange={(event) => setEmail(event.currentTarget.value)}
              required
              type="email"
              value={email}
            />
          </label>

          <label>
            密码
            <input
              autoComplete="current-password"
              name="password"
              onChange={(event) => setPassword(event.currentTarget.value)}
              required
              type="password"
              value={password}
            />
          </label>

          <button className="primary-button" type="submit" disabled={loading}>
            <LogIn aria-hidden="true" size={18} />
            {loading ? "正在登录" : "登录"}
          </button>

          {error ? <p className="form-status form-status--error">{error}</p> : null}
        </form>

        {onUserMode ? (
          <button className="secondary-button" type="button" onClick={onUserMode}>
            用户门户
          </button>
        ) : null}
      </section>

      <section className="auth-context" aria-label="访问范围">
        <ShieldCheck aria-hidden="true" size={26} />
        <div>
          <h2>受限操作</h2>
          <dl>
            <div>
              <dt>导航</dt>
              <dd>角色标签</dd>
            </div>
            <div>
              <dt>健康</dt>
              <dd>只读探针</dd>
            </div>
            <div>
              <dt>恢复</dt>
              <dd>本地请求状态</dd>
            </div>
          </dl>
        </div>
      </section>
    </main>
  );
}

export function adminSessionFromMe(me: AdminMeResponse): AdminSession {
  return {
    capabilitySummary: me.capability_summary,
    email: me.user.email,
    expiresAt: me.session.expires_at,
    name: me.user.display_name || displayNameFromEmail(me.user.email),
    role: uiRole(me.user),
    roles: me.user.roles,
    sessionId: me.session.id,
    tenantId: me.user.tenant_id,
    userId: me.user.id,
  };
}

function displayNameFromEmail(email: string): string {
  return email.split("@")[0]?.replace(/[._-]/g, " ") || "管理员";
}

function uiRole(user: AdminUser): AdminSession["role"] {
  const roles = user.roles.map((role) => role.toLowerCase());

  if (roles.includes("owner")) {
    return "Owner";
  }
  if (roles.includes("admin") || roles.includes("developer")) {
    return "Admin";
  }
  if (roles.includes("ops")) {
    return "Operator";
  }
  if (roles.includes("billing")) {
    return "Billing";
  }
  if (roles.includes("viewer")) {
    return "Viewer";
  }

  return "Auditor";
}
