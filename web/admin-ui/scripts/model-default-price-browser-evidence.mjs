import { chromium } from "@playwright/test";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

const adminUiBaseUrl = withoutTrailingSlash(process.env.ADMIN_UI_BASE_URL || "http://127.0.0.1:5173");
const controlPlaneProxyBaseUrl = withoutTrailingSlash(
  process.env.CONTROL_PLANE_PROXY_BASE_URL || `${adminUiBaseUrl}/api/control-plane`,
);
const adminEmail = process.env.CONTROL_PLANE_ADMIN_EMAIL || "admin@example.com";
const adminPassword = process.env.CONTROL_PLANE_ADMIN_PASSWORD || "local-password";
const outputPath = path.resolve(
  process.cwd(),
  process.env.MODEL_DEFAULT_PRICE_BROWSER_EVIDENCE_PATH ||
    ".tmp/control-plane/model_default_price_admin_ui_browser_evidence.json",
);

const startedAt = new Date();
const evidence = {
  schema: "model_default_price_admin_ui_browser_evidence.v1",
  task_id: "E4-ADMIN-UI-DEFAULT-PRICE-BROWSER-EVIDENCE",
  generated_at_utc: startedAt.toISOString(),
  admin_ui_base_url: adminUiBaseUrl,
  control_plane_proxy_base_url: controlPlaneProxyBaseUrl,
  status: "failed",
  browser_operation_chain: {
    admin_ui_reachable: false,
    login_submitted: false,
    logged_in: false,
    models_navigation: false,
    selector_visible: false,
    price_book_option_available: false,
    ui_patch_request_observed: false,
    success_banner_visible: false,
    api_readback_after_set: false,
    restored_original_default_price_book: false,
    api_readback_after_restore: false,
  },
  selected_model: null,
  selected_price_book: null,
  api_readback: null,
  request_observation: {
    patch_admin_models_count: 0,
    patch_admin_models_statuses: [],
    patch_body_fields: [],
  },
  secret_safe_policy: {
    admin_password_echoed: false,
    session_cookie_echoed: false,
    session_token_echoed: false,
    authorization_header_echoed: false,
    raw_cookie_header_echoed: false,
    raw_virtual_key_echoed: false,
    raw_provider_key_echoed: false,
  },
  blockers: [],
  warnings: [],
};

let browser;

try {
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    baseURL: adminUiBaseUrl,
    ignoreHTTPSErrors: true,
  });
  const page = await context.newPage();

  page.on("response", async (response) => {
    const request = response.request();
    const url = response.url();
    if (request.method() === "PATCH" && /\/admin\/models\/[^/]+$/.test(url)) {
      evidence.request_observation.patch_admin_models_count += 1;
      evidence.request_observation.patch_admin_models_statuses.push(response.status());

      try {
        const body = request.postDataJSON();
        evidence.request_observation.patch_body_fields.push(...Object.keys(body || {}));
      } catch {
        evidence.warnings.push("patch_request_body_fields_unavailable");
      }
    }
  });

  const rootResponse = await page.goto("/", { waitUntil: "domcontentloaded" });
  evidence.browser_operation_chain.admin_ui_reachable = Boolean(rootResponse?.ok());

  await page.getByLabel("Email").fill(adminEmail);
  await page.getByLabel("Password").fill(adminPassword);
  await page.getByRole("button", { name: /^Sign in$/ }).click();
  evidence.browser_operation_chain.login_submitted = true;

  await page.getByRole("button", { name: /Models/ }).waitFor({ timeout: 15_000 });
  evidence.browser_operation_chain.logged_in = true;
  await page.getByRole("button", { name: /Models/ }).click();
  await page.getByRole("heading", { level: 2, name: "Model Catalog" }).waitFor({ timeout: 15_000 });
  evidence.browser_operation_chain.models_navigation = true;

  const models = await apiJson(page, "/admin/models");
  const priceVersions = await apiJson(page, "/admin/price-versions?status=active&limit=100");
  const model = firstActiveModel(models);
  const priceBookId = firstUsablePriceBookId(priceVersions, model?.default_price_book_id || null);

  if (!model) {
    evidence.blockers.push("no_active_canonical_model_available");
    throw new Error("No active canonical model available for browser evidence.");
  }
  if (!priceBookId) {
    evidence.blockers.push("no_active_price_book_option_available");
    throw new Error("No active price book option available for browser evidence.");
  }

  const originalDefaultPriceBookId = model.default_price_book_id || null;
  evidence.selected_model = {
    id_sha256: sha256(model.id),
    display_name: model.display_name,
    model_key: model.model_key,
    original_default_price_book_configured: Boolean(originalDefaultPriceBookId),
    original_default_price_book_id_sha256: originalDefaultPriceBookId ? sha256(originalDefaultPriceBookId) : null,
  };
  evidence.selected_price_book = {
    id_sha256: sha256(priceBookId),
    differs_from_original: priceBookId !== originalDefaultPriceBookId,
  };

  const effectiveSelector = page.locator(`select[aria-label=${cssString(`Default price book for ${model.display_name}`)}]`).first();
  await effectiveSelector.waitFor({ timeout: 10_000 });
  evidence.browser_operation_chain.selector_visible = true;
  await effectiveSelector.selectOption(priceBookId);
  evidence.browser_operation_chain.price_book_option_available = true;
  await page.getByRole("button", { name: `Save default price book for ${model.display_name}` }).click();
  await page.getByText(`${model.display_name} default price book saved.`).waitFor({ timeout: 10_000 });
  evidence.browser_operation_chain.success_banner_visible = true;
  evidence.browser_operation_chain.ui_patch_request_observed =
    evidence.request_observation.patch_admin_models_count >= 1 &&
    evidence.request_observation.patch_admin_models_statuses.every((status) => status >= 200 && status < 300);

  const afterSet = await apiJson(page, `/admin/models/${encodeURIComponent(model.id)}`);
  evidence.browser_operation_chain.api_readback_after_set = afterSet.default_price_book_id === priceBookId;

  await effectiveSelector.selectOption(originalDefaultPriceBookId || "");
  await page.getByRole("button", { name: `Save default price book for ${model.display_name}` }).click();
  await page.getByText(`${model.display_name} default price book saved.`).waitFor({ timeout: 10_000 });

  const afterRestore = await apiJson(page, `/admin/models/${encodeURIComponent(model.id)}`);
  evidence.browser_operation_chain.restored_original_default_price_book =
    (afterRestore.default_price_book_id || null) === originalDefaultPriceBookId;
  evidence.browser_operation_chain.api_readback_after_restore =
    (afterRestore.default_price_book_id || null) === originalDefaultPriceBookId;
  evidence.api_readback = {
    set_default_price_book_id_sha256: afterSet.default_price_book_id ? sha256(afterSet.default_price_book_id) : null,
    restore_default_price_book_id_sha256: afterRestore.default_price_book_id
      ? sha256(afterRestore.default_price_book_id)
      : null,
    restored_to_original: (afterRestore.default_price_book_id || null) === originalDefaultPriceBookId,
  };

  const failedSteps = Object.entries(evidence.browser_operation_chain)
    .filter(([, passed]) => passed !== true)
    .map(([name]) => name);
  if (failedSteps.length > 0) {
    evidence.blockers.push(...failedSteps.map((step) => `browser_step_failed:${step}`));
  }

  evidence.status = evidence.blockers.length === 0 ? "pass" : "failed";
} catch (error) {
  if (evidence.blockers.length === 0) {
    evidence.blockers.push(error instanceof Error ? error.message : String(error));
  }
  evidence.status = "failed";
  process.exitCode = 1;
} finally {
  if (browser) {
    await browser.close();
  }

  evidence.completed_at_utc = new Date().toISOString();
  evidence.duration_ms = new Date(evidence.completed_at_utc).getTime() - startedAt.getTime();
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, `${JSON.stringify(evidence, null, 2)}\n`, "utf8");
  console.log(JSON.stringify(evidence, null, 2));
}

function withoutTrailingSlash(value) {
  return value.replace(/\/+$/, "");
}

function sha256(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex");
}

async function apiJson(page, apiPath) {
  const url = `${controlPlaneProxyBaseUrl}${apiPath.startsWith("/") ? apiPath : `/${apiPath}`}`;
  const result = await page.evaluate(async (requestUrl) => {
    const response = await fetch(requestUrl, {
      credentials: "include",
      headers: { Accept: "application/json" },
    });
    const text = await response.text();
    const payload = text ? JSON.parse(text) : null;
    return {
      ok: response.ok,
      status: response.status,
      payload,
    };
  }, url);

  if (!result.ok) {
    throw new Error(`API readback failed: ${apiPath} status=${result.status}`);
  }

  return unwrapData(result.payload);
}

function unwrapData(payload) {
  if (payload && typeof payload === "object" && "data" in payload) {
    return payload.data;
  }
  return payload;
}

function firstActiveModel(models) {
  if (!Array.isArray(models)) {
    return null;
  }
  return models.find((model) => model && model.status === "active") || models[0] || null;
}

function firstUsablePriceBookId(priceVersions, originalPriceBookId) {
  if (!Array.isArray(priceVersions)) {
    return null;
  }

  const ids = [...new Set(priceVersions.map((version) => version?.price_book_id).filter(Boolean))];
  return ids.find((id) => id !== originalPriceBookId) || ids[0] || null;
}

function cssString(value) {
  return JSON.stringify(String(value));
}
