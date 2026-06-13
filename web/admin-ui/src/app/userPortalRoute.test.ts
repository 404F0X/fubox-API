import { describe, expect, it } from "vitest";

import { resolveUserPortalRouteTarget } from "./userPortalRoute";

describe("userPortalRoute", () => {
  it("resolves the stable developer console route target", () => {
    expect(resolveUserPortalRouteTarget({ hash: "", pathname: "/", search: "?mode=developer-console" })).toBe(
      "developer-console",
    );
  });

  it("keeps user and portal aliases for standalone handoff compatibility", () => {
    expect(resolveUserPortalRouteTarget({ hash: "", pathname: "/", search: "?mode=user" })).toBe("user");
    expect(resolveUserPortalRouteTarget({ hash: "", pathname: "/", search: "?mode=portal" })).toBe("portal");
    expect(resolveUserPortalRouteTarget({ hash: "", pathname: "/", search: "?app=developer-console" })).toBe(
      "developer-console",
    );
    expect(resolveUserPortalRouteTarget({ hash: "", pathname: "/", search: "?console=developer-console" })).toBe(
      "developer-console",
    );
    expect(resolveUserPortalRouteTarget({ hash: "#/developer-console", pathname: "/", search: "" })).toBe(
      "developer-console",
    );
    expect(resolveUserPortalRouteTarget({ hash: "", pathname: "/developer-console", search: "" })).toBe(
      "developer-console",
    );
    expect(resolveUserPortalRouteTarget({ hash: "", pathname: "/portal", search: "" })).toBe("portal");
  });
});
