import { useEffect, useState } from "react";

import { clearAdminSessionToken, getAdminMe } from "../api/client";
import { adminSessionFromMe, type AdminSession } from "../components/LoginPanel";

export function useAdminSessionRestore({ enabled = true }: { enabled?: boolean } = {}) {
  const [session, setSession] = useState<AdminSession | null>(null);
  const [authChecking, setAuthChecking] = useState(true);

  useEffect(() => {
    let cancelled = false;

    if (!enabled) {
      setSession(null);
      setAuthChecking(false);
      return () => {
        cancelled = true;
      };
    }

    async function restoreSession() {
      try {
        const me = await getAdminMe();

        if (!cancelled) {
          setSession(adminSessionFromMe(me));
        }
      } catch {
        clearAdminSessionToken();

        if (!cancelled) {
          setSession(null);
        }
      } finally {
        if (!cancelled) {
          setAuthChecking(false);
        }
      }
    }

    void restoreSession();

    return () => {
      cancelled = true;
    };
  }, [enabled]);

  return { authChecking, session, setSession };
}
