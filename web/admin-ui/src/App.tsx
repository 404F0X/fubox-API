import { useState } from "react";

import { AppRouter } from "./app/AppRouter";
import { SessionRestorePanel } from "./app/SessionRestorePanel";
import { useAdminSessionRestore } from "./app/session";
import {
  replaceUserPortalRouteTarget,
  resolveUserPortalRouteTarget,
  type UserPortalRouteTarget,
} from "./app/userPortalRoute";
import { LoginPanel } from "./components/LoginPanel";
import {
  type UserPortalSession,
  UserPortalDashboard,
  UserPortalLoginPanel,
} from "./components/UserPortalPanel";

export function App() {
  const [initialUserPortalRouteTarget] = useState<UserPortalRouteTarget | null>(() => resolveUserPortalRouteTarget());
  const { authChecking, session, setSession } = useAdminSessionRestore({
    enabled: initialUserPortalRouteTarget === null,
  });
  const [userSession, setUserSession] = useState<UserPortalSession | null>(null);
  const [authMode, setAuthMode] = useState<"user" | "admin">(() =>
    initialUserPortalRouteTarget ? "user" : "admin",
  );

  function openUserPortal(target: UserPortalRouteTarget = "developer-console") {
    replaceUserPortalRouteTarget(target);
    setSession(null);
    setUserSession(null);
    setAuthMode("user");
  }

  function openAdminWorkbench() {
    replaceUserPortalRouteTarget(null);
    setAuthMode("admin");
  }

  if (authChecking) {
    return <SessionRestorePanel />;
  }

  if (!session) {
    if (userSession) {
      return <UserPortalDashboard session={userSession} onLogout={() => setUserSession(null)} />;
    }

    if (authMode === "admin") {
      return <LoginPanel onLogin={setSession} onUserMode={() => openUserPortal()} />;
    }

    return (
      <UserPortalLoginPanel
        onAdminMode={openAdminWorkbench}
        onLogin={(nextSession) => {
          setUserSession(nextSession);
          setSession(null);
        }}
      />
    );
  }

  return (
    <AppRouter
      session={session}
      onAdminSessionCleared={() => {
        setSession(null);
        setUserSession(null);
        openAdminWorkbench();
      }}
      onOpenUserPortal={() => openUserPortal()}
    />
  );
}
