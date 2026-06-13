import { describe, expect, it } from "vitest";

import { safeErrorMessage, safeRoutingErrorMessage } from "./safeText";

describe("safe routing error text", () => {
  it("maps route and provider error codes to actionable safe messages", () => {
    expect(safeRoutingErrorMessage("model_not_found")).toContain("Invalid model");
    expect(safeRoutingErrorMessage("route_no_candidate")).toContain("No route");
    expect(safeRoutingErrorMessage("provider_auth_failed")).toContain("Provider authentication failed");
    expect(safeRoutingErrorMessage("provider_429")).toContain("Provider rate limit");
    expect(safeRoutingErrorMessage("billing_insufficient_balance")).toContain("Insufficient balance");
  });

  it("does not expose raw upstream details from API client errors", () => {
    const error = Object.assign(
      new Error("upstream said Authorization: Bearer sk-live-provider-secret model does not exist"),
      {
        code: "upstream_invalid_model",
        envelope: {
          error: {
            code: "upstream_invalid_model",
            message: "raw provider payload Authorization: Bearer sk-live-provider-secret",
          },
        },
      },
    );
    const message = safeErrorMessage(error);

    expect(message).toContain("Invalid upstream model mapping");
    expect(message).not.toContain("Authorization");
    expect(message).not.toContain("sk-live-provider-secret");
    expect(message).not.toContain("raw provider payload");
  });
});
