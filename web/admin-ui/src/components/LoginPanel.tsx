import { FormEvent, useState } from "react";
import { getAdminMe, loginAdmin, type AdminCapabilitySummary, type AdminUser } from "../api/client";
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
};

export function LoginPanel({ onLogin }: Props) {
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

      onLogin({
        capabilitySummary: me.capability_summary,
        email: me.user.email,
        expiresAt: me.session.expires_at,
        name: me.user.display_name || displayNameFromEmail(me.user.email),
        role: uiRole(me.user),
        roles: me.user.roles,
        sessionId: me.session.id,
        tenantId: me.user.tenant_id,
        userId: me.user.id,
      });
      setPassword("");
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Sign in failed.");
    } finally {
      setLoading(false);
    }
  }

  return (
    <main className="auth-shell">
      <section className="auth-panel" aria-labelledby="login-title">
        <div className="auth-brand">
          <span className="brand-mark">AG</span>
          <span>AI Gateway</span>
        </div>
        <p className="eyebrow">Admin Console</p>
        <h1 id="login-title">Admin sign in</h1>

        <form className="login-form" onSubmit={handleSubmit}>
          <label>
            Email
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
            Password
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
            {loading ? "Signing in" : "Sign in"}
          </button>

          {error ? <p className="form-status form-status--error">{error}</p> : null}
        </form>
      </section>

      <section className="auth-context" aria-label="Access scope">
        <ShieldCheck aria-hidden="true" size={26} />
        <div>
          <h2>Scoped operations</h2>
          <dl>
            <div>
              <dt>Navigation</dt>
              <dd>Role labels</dd>
            </div>
            <div>
              <dt>Health</dt>
              <dd>Read probes</dd>
            </div>
            <div>
              <dt>Recovery</dt>
              <dd>Local request state</dd>
            </div>
          </dl>
        </div>
      </section>
    </main>
  );
}

function displayNameFromEmail(email: string): string {
  return email.split("@")[0]?.replace(/[._-]/g, " ") || "Admin Operator";
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
