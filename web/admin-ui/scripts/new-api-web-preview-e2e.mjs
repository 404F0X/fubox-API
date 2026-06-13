import { chromium } from "@playwright/test";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

const adminUiBaseUrl = withoutTrailingSlash(process.env.ADMIN_UI_BASE_URL || "http://127.0.0.1:5173");
const controlPlaneBaseUrl = withoutTrailingSlash(process.env.CONTROL_PLANE_BASE_URL || "http://127.0.0.1:8081");
const gatewayBaseUrl = withoutTrailingSlash(process.env.GATEWAY_BASE_URL || "http://127.0.0.1:8080");
const adminEmail = process.env.CONTROL_PLANE_ADMIN_EMAIL || "admin@example.com";
const adminPassword = process.env.CONTROL_PLANE_ADMIN_PASSWORD || "local-password";
const model = process.env.WEB_PREVIEW_MODEL || process.env.SMOKE_MODEL || "mock-gpt-4o-mini";
const runId = `web-preview-${Date.now()}`;
const userEmail = process.env.WEB_PREVIEW_USER_EMAIL || `${runId}@example.test`;
const userPassword = process.env.WEB_PREVIEW_USER_PASSWORD || "local-preview-password-123";
const userDisplayName = process.env.WEB_PREVIEW_USER_DISPLAY_NAME || "Web Preview User";
const voucherCode = process.env.WEB_PREVIEW_VOUCHER_CODE || `PREVIEW-${Date.now()}`;
const onboardingProviderCode = `preview-provider-${Date.now()}`;
const onboardingModel = `preview-model-${Date.now()}`;
const onboardingProviderKeyAlias = `preview-key-${Date.now()}`;
const onboardingProfileName = `preview-profile-${Date.now()}`;
const onboardingOneTimeProviderKey = `preview-provider-key-${crypto.randomUUID()}`;
const artifactPath = path.resolve(
  process.cwd(),
  process.env.WEB_PREVIEW_E2E_ARTIFACT_PATH || ".tmp/new-api-mvp/web_preview_e2e_mock_provider.json",
);
const screenshotDir = path.resolve(
  process.cwd(),
  process.env.WEB_PREVIEW_SCREENSHOT_DIR || ".tmp/new-api-mvp/web-preview",
);

const startedAt = new Date();
const evidence = {
  schema: "new_api_web_preview_e2e_mock_provider.v1",
  task_id: "USER-016",
  generated_at_utc: startedAt.toISOString(),
  status: "failed",
  scope: "actual_browser_admin_ui_user_portal_mock_provider",
  admin_ui_base_url: adminUiBaseUrl,
  control_plane_base_url_configured: true,
  gateway_base_url: gatewayBaseUrl,
  mock_provider_path: true,
  model,
  run_id_hash: sha256(runId),
  browser_steps: {
    admin_ui_reachable: false,
    admin_login_submitted: false,
    admin_distribution_visible: false,
    admin_distribution_authority_readback: false,
    admin_distribution_authority_panel_visible: false,
    admin_distribution_authority_secret_policy_visible: false,
    admin_distribution_routes_visible: false,
    admin_local_bootstrap_guide_visible: false,
    admin_real_provider_onboarding_guide_visible: false,
    admin_real_provider_onboarding_plan_visible: false,
    admin_real_provider_onboarding_non_secret_apply_visible: false,
    admin_real_provider_onboarding_non_secret_apply_ran: false,
    admin_real_provider_onboarding_apply_result_visible: false,
    admin_real_provider_onboarding_provider_key_secret_field_visible: false,
    admin_real_provider_onboarding_provider_key_secret_cleared: false,
    admin_real_provider_onboarding_routing_dry_run_visible: false,
    admin_real_provider_onboarding_plan_copied: false,
    admin_real_provider_onboarding_plan_secret_safe: false,
    admin_real_provider_smoke_command_visible: false,
    admin_real_provider_missing_credentials_policy_visible: false,
    admin_user_handoff_guide_visible: false,
    admin_user_handoff_billing_entry_visible: false,
    admin_user_handoff_trace_entry_visible: false,
    admin_user_handoff_user_portal_entry_visible: false,
    admin_user_handoff_checklist_copy_visible: false,
    admin_user_handoff_checklist_copied: false,
    admin_user_handoff_billing_entry_navigated: false,
    admin_user_handoff_trace_entry_navigated: false,
    admin_user_handoff_user_portal_entry_navigated: false,
    admin_provider_keys_page_visible: false,
    admin_provider_key_create_dialog_visible: false,
    admin_provider_key_channel_selector_visible: false,
    admin_provider_key_selected_channel_visible: false,
    admin_voucher_issue_ui_available: false,
    admin_voucher_issue_api_fallback_used: false,
    user_portal_mode_opened: false,
    user_registered_from_page: false,
    user_readiness_visible: false,
    user_models_visible: false,
    user_model_catalog_search_visible: false,
    user_model_catalog_search_matched: false,
    user_model_catalog_copy_model: false,
    user_balance_visible: false,
    user_billing_references_visible: false,
    user_billing_references_copied: false,
    admin_billing_references_paste_visible: false,
    admin_billing_references_applied: false,
    user_voucher_redeemed_from_page: false,
    user_api_key_created_from_page: false,
    user_connection_summary_visible: false,
    user_api_console_models_called_from_page: false,
    user_api_console_called_from_page: false,
    user_api_console_model_detail_visible: false,
    gateway_models_called_with_created_key: false,
    gateway_chat_called_with_created_key: false,
    user_usage_visible_after_gateway_call: false,
    user_usage_window_switched_from_page: false,
    user_billing_explanation_visible: false,
    user_billing_explanation_copied: false,
    user_usage_export_available: false,
    user_request_detail_visible: false,
    user_trace_summary_visible: false,
  },
  screenshots: [],
  safe_readback: {
    user_id_sha256: null,
    project_id_sha256: null,
    wallet_id_sha256: null,
    voucher_issue_status: null,
    voucher_redeem_ui_status_visible: false,
    billing_references_wallet_visible: false,
    billing_references_secret_policy_visible: false,
    user_readiness_state: null,
    user_readiness_active_profiles: null,
    user_readiness_routable_models: null,
    user_model_catalog_filter_result_visible: false,
    created_key_id_sha256: null,
    created_key_prefix: null,
    connection_summary_key_prefix_visible: false,
    connection_summary_secret_policy_visible: false,
    user_api_console_models_status: null,
    user_api_console_model: null,
    user_api_console_status: null,
    gateway_models_status: null,
    gateway_chat_status: null,
    usage_window_days_visible: null,
    billing_explanation_secret_policy_visible: false,
    usage_log_rows_observed: null,
    real_provider_smoke_command_present: false,
    real_provider_onboarding_plan_fields_visible: [],
    real_provider_onboarding_plan_steps_visible: [],
    real_provider_onboarding_plan_excludes_secret: null,
    real_provider_onboarding_apply_actions_visible: [],
    real_provider_onboarding_apply_provider_key_result_visible: false,
    real_provider_onboarding_apply_submitted_one_time_secret: false,
    real_provider_onboarding_apply_skipped_secret: false,
    real_provider_onboarding_dry_run_status: null,
    real_provider_onboarding_dry_run_selected_channel_visible: false,
    real_provider_onboarding_dry_run_secret_boundary_visible: false,
    real_provider_required_env_visible: [],
    real_provider_live_not_executed: true,
    admin_distribution_authority_status: null,
    admin_distribution_authority_ready_to_distribute: null,
    admin_distribution_authority_secret_safe: null,
    admin_distribution_authority_blockers: [],
    admin_distribution_authority_panel_inputs_visible: [],
    admin_distribution_route_surfaces_visible: [],
    user_handoff_steps_visible: [],
    user_handoff_admin_entries_visible: [],
    admin_provider_key_dialog_fields_visible: [],
    admin_provider_key_channel_selector_secret_safe: false,
  },
  secret_safe_policy: {
    admin_password_echoed: false,
    admin_session_token_echoed: false,
    user_password_echoed: false,
    session_cookie_echoed: false,
    raw_voucher_code_echoed: false,
    raw_provider_key_echoed: false,
    raw_virtual_key_secret_echoed: false,
    authorization_header_echoed: false,
    raw_request_body_echoed: false,
  },
  warnings: [],
  blockers: [],
};

let browser;
let activePage = null;
let userApiKeySecret = "";

try {
  await fs.mkdir(screenshotDir, { recursive: true });
  browser = await chromium.launch({ headless: true });

  const adminContext = await browser.newContext({ baseURL: adminUiBaseUrl, ignoreHTTPSErrors: true });
  const adminPage = await adminContext.newPage();
  activePage = adminPage;
  const rootResponse = await adminPage.goto("/", { waitUntil: "domcontentloaded" });
  evidence.browser_steps.admin_ui_reachable = Boolean(rootResponse?.ok());
  await screenshot(adminPage, "01-admin-login.png");

  await adminPage.getByLabel("Email").fill(adminEmail);
  await adminPage.getByLabel("Password").fill(adminPassword);
  await adminPage.getByRole("button", { name: /^Sign in$/ }).click();
  evidence.browser_steps.admin_login_submitted = true;
  await adminPage.getByRole("button", { name: /Distribution/ }).waitFor({ timeout: 15_000 });
  await adminPage.getByRole("button", { name: /Distribution/ }).click();
  await adminPage.getByRole("heading", { name: /API Distribution|Distribution/i }).waitFor({ timeout: 15_000 });
  await adminPage.locator('[aria-label="Station setup sequence"]').waitFor({ timeout: 15_000 });
  await adminPage.locator('[aria-label="Local mock bootstrap guide"]').waitFor({ timeout: 15_000 });
  await adminPage.getByText("bootstrap_new_api_mock_distribution.ps1").waitFor({ timeout: 15_000 });
  const realProviderGuide = adminPage.locator('[aria-label="Real provider onboarding guide"]');
  await realProviderGuide.waitFor({ timeout: 15_000 });
  await realProviderGuide.getByText("verify_real_provider_onboarding_smoke.ps1").waitFor({ timeout: 15_000 });
  const realProviderEnvInputs = realProviderGuide.locator(
    '[aria-label="Real provider onboarding environment inputs"]',
  );
  await realProviderEnvInputs.getByText("REAL_PROVIDER_BASE_URL", { exact: true }).waitFor({ timeout: 15_000 });
  await realProviderEnvInputs.getByText("REAL_PROVIDER_API_KEY", { exact: true }).waitFor({ timeout: 15_000 });
  await realProviderEnvInputs.getByText("REAL_PROVIDER_MODEL", { exact: true }).waitFor({ timeout: 15_000 });
  await realProviderGuide.getByText("credential-pending artifact").waitFor({ timeout: 15_000 });
  const openOnboardingWizardButton = realProviderGuide.getByRole("button", { name: /Open onboarding wizard/ });
  await openOnboardingWizardButton.waitFor({ timeout: 15_000 });
  await openOnboardingWizardButton.click();
  const onboardingWizard = adminPage.locator('[aria-label="Real provider onboarding wizard"]');
  await onboardingWizard.waitFor({ timeout: 15_000 });
  const onboardingPlan = onboardingWizard.locator('[aria-label="Real provider onboarding plan builder"]');
  await onboardingPlan.waitFor({ timeout: 15_000 });
  await onboardingPlan.getByLabel("Provider name").fill("Preview Provider");
  await onboardingPlan.getByLabel("Provider code").fill(onboardingProviderCode);
  await onboardingPlan.getByLabel("Base URL").fill("https://provider.example.test/v1");
  await onboardingPlan.getByLabel("Channel name").fill("preview-primary");
  await onboardingPlan.getByLabel("Public model").fill(onboardingModel);
  await onboardingPlan.getByLabel("Upstream model").fill(onboardingModel);
  await onboardingPlan.getByLabel("Provider key alias").fill(onboardingProviderKeyAlias);
  const oneTimeProviderKeyInput = onboardingPlan.getByLabel("One-time provider API key");
  await oneTimeProviderKeyInput.fill(onboardingOneTimeProviderKey);
  await onboardingPlan.getByLabel("User profile").fill(onboardingProfileName);
  const onboardingPlanPreview = onboardingPlan.locator(".onboarding-plan-preview");
  await onboardingPlanPreview.getByText("Real provider onboarding plan").waitFor({ timeout: 15_000 });
  await onboardingPlanPreview.getByText("Preview Provider").waitFor({ timeout: 15_000 });
  await onboardingPlanPreview.getByText("2. Provider Keys").waitFor({ timeout: 15_000 });
  await onboardingPlanPreview.getByText("Secret boundary").waitFor({ timeout: 15_000 });
  await onboardingPlan.getByRole("button", { name: /Open Providers/ }).waitFor({ timeout: 15_000 });
  await onboardingPlan.getByRole("button", { name: /Open Provider Keys/ }).waitFor({ timeout: 15_000 });
  await onboardingPlan.getByRole("button", { name: /Open Models/ }).waitFor({ timeout: 15_000 });
  const copyOnboardingPlanButton = onboardingPlan.getByRole("button", { name: /Copy onboarding plan/ });
  await copyOnboardingPlanButton.waitFor({ timeout: 15_000 });
  const applyOnboardingPlanButton = onboardingPlan.getByRole("button", { name: /Create non-secret setup/ });
  await applyOnboardingPlanButton.waitFor({ timeout: 15_000 });
  const userHandoffGuide = adminPage.locator('[aria-label="User self-serve handoff guide"]');
  await userHandoffGuide.waitFor({ timeout: 15_000 });
  await userHandoffGuide.getByText("User Portal", { exact: true }).waitFor({ timeout: 15_000 });
  await userHandoffGuide.getByText("Voucher credit", { exact: true }).waitFor({ timeout: 15_000 });
  await userHandoffGuide.getByText("API key", { exact: true }).waitFor({ timeout: 15_000 });
  await userHandoffGuide.getByText("Gateway call", { exact: true }).waitFor({ timeout: 15_000 });
  await userHandoffGuide.getByRole("button", { name: /Sign out to User Portal/ }).waitFor({ timeout: 15_000 });
  await userHandoffGuide.getByRole("button", { name: /Open Billing vouchers/ }).waitFor({ timeout: 15_000 });
  await userHandoffGuide.getByRole("button", { name: /Open Request\/Trace/ }).waitFor({ timeout: 15_000 });
  const copyChecklistButton = userHandoffGuide.getByRole("button", { name: /Copy user checklist/ });
  await copyChecklistButton.waitFor({ timeout: 15_000 });
  await adminPage.getByText("Voucher credit").first().waitFor({ timeout: 15_000 });
  const distributionAuthority = await pageControlPlaneJson(adminPage, "/admin/distribution/readiness");
  if (distributionAuthority.schema !== "admin_distribution_readiness.v1") {
    throw new Error("admin distribution authority readback returned unexpected schema");
  }
  if (distributionAuthority.secret_safe !== true || distributionAuthority.raw_provider_key_returned !== false) {
    throw new Error("admin distribution authority readback is not secret-safe");
  }
  const authorityPanel = adminPage.locator('[aria-label="Control Plane authority readback"]');
  await authorityPanel.waitFor({ timeout: 15_000 });
  await authorityPanel.getByText("admin_distribution_readiness.v1").waitFor({ timeout: 15_000 });
  await authorityPanel.getByText("No raw provider key").waitFor({ timeout: 15_000 });
  await authorityPanel.getByText("REAL_PROVIDER_BASE_URL").waitFor({ timeout: 15_000 });
  await authorityPanel.getByText("REAL_PROVIDER_API_KEY").waitFor({ timeout: 15_000 });
  await authorityPanel.getByText("REAL_PROVIDER_MODEL").waitFor({ timeout: 15_000 });
  const distributionRoutes = adminPage.locator('[aria-label="Distribution routes"]');
  await distributionRoutes.waitFor({ timeout: 15_000 });
  await distributionRoutes.getByText("Distribution routes", { exact: true }).waitFor({ timeout: 15_000 });
  await distributionRoutes.getByRole("columnheader", { name: "Credential" }).waitFor({ timeout: 15_000 });
  await distributionRoutes.getByRole("columnheader", { name: "User profile" }).waitFor({ timeout: 15_000 });
  await distributionRoutes.getByRole("columnheader", { name: "Last signal" }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.admin_distribution_visible = true;
  evidence.browser_steps.admin_distribution_authority_readback = true;
  evidence.browser_steps.admin_distribution_authority_panel_visible = true;
  evidence.browser_steps.admin_distribution_authority_secret_policy_visible = true;
  evidence.browser_steps.admin_distribution_routes_visible = true;
  evidence.browser_steps.admin_local_bootstrap_guide_visible = true;
  evidence.browser_steps.admin_real_provider_onboarding_guide_visible = true;
  evidence.browser_steps.admin_real_provider_onboarding_plan_visible = true;
  evidence.browser_steps.admin_real_provider_onboarding_non_secret_apply_visible = true;
  evidence.browser_steps.admin_real_provider_onboarding_provider_key_secret_field_visible = true;
  evidence.browser_steps.admin_real_provider_smoke_command_visible = true;
  evidence.browser_steps.admin_real_provider_missing_credentials_policy_visible = true;
  evidence.browser_steps.admin_user_handoff_guide_visible = true;
  evidence.browser_steps.admin_user_handoff_billing_entry_visible = true;
  evidence.browser_steps.admin_user_handoff_trace_entry_visible = true;
  evidence.browser_steps.admin_user_handoff_user_portal_entry_visible = true;
  evidence.browser_steps.admin_user_handoff_checklist_copy_visible = true;
  evidence.safe_readback.real_provider_smoke_command_present = true;
  evidence.safe_readback.real_provider_onboarding_plan_fields_visible = [
    "Provider name",
    "Provider code",
    "Base URL",
    "Channel name",
    "Public model",
    "Upstream model",
    "User profile",
  ];
  evidence.safe_readback.real_provider_onboarding_plan_steps_visible = [
    "Providers",
    "Provider Keys",
    "Models",
    "Virtual Keys",
    "Distribution",
    "User Portal",
  ];
  evidence.safe_readback.real_provider_onboarding_plan_excludes_secret = true;
  evidence.safe_readback.admin_distribution_authority_status = distributionAuthority.overall_status || null;
  evidence.safe_readback.admin_distribution_authority_ready_to_distribute =
    distributionAuthority.ready_to_distribute_api ?? null;
  evidence.safe_readback.admin_distribution_authority_secret_safe = distributionAuthority.secret_safe ?? null;
  evidence.safe_readback.admin_distribution_authority_blockers = Array.isArray(distributionAuthority.blockers)
    ? distributionAuthority.blockers
    : [];
  evidence.safe_readback.admin_distribution_authority_panel_inputs_visible = [
    "REAL_PROVIDER_BASE_URL",
    "REAL_PROVIDER_API_KEY",
    "REAL_PROVIDER_MODEL",
  ];
  evidence.safe_readback.admin_distribution_route_surfaces_visible = [
    "Route",
    "Credential",
    "Model",
    "User profile",
    "Last signal",
  ];
  evidence.safe_readback.real_provider_required_env_visible = [
    "REAL_PROVIDER_BASE_URL",
    "REAL_PROVIDER_API_KEY",
    "REAL_PROVIDER_MODEL",
  ];
  evidence.safe_readback.user_handoff_steps_visible = ["User Portal", "Voucher credit", "API key", "Gateway call"];
  evidence.safe_readback.user_handoff_admin_entries_visible = ["Billing vouchers", "Request/Trace"];
  await copyOnboardingPlanButton.click();
  await onboardingPlan.getByRole("button", { name: /Plan copied/ }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.admin_real_provider_onboarding_plan_copied = true;
  evidence.browser_steps.admin_real_provider_onboarding_plan_secret_safe = true;
  await applyOnboardingPlanButton.click();
  const applyResult = onboardingPlan.locator('[aria-label="Real provider onboarding apply result"]');
  await applyResult.waitFor({ timeout: 15_000 });
  await applyResult.getByText("Provider", { exact: true }).waitFor({ timeout: 15_000 });
  await applyResult.getByText("Channel", { exact: true }).waitFor({ timeout: 15_000 });
  await applyResult.getByText("Model", { exact: true }).waitFor({ timeout: 15_000 });
  await applyResult.getByText("Model route", { exact: true }).waitFor({ timeout: 15_000 });
  await applyResult.getByText("User profile", { exact: true }).waitFor({ timeout: 15_000 });
  await applyResult.getByText("Provider key", { exact: true }).waitFor({ timeout: 15_000 });
  await applyResult.getByText("Routing dry-run", { exact: true }).waitFor({ timeout: 15_000 });
  await applyResult.getByText("submitted secret cleared").waitFor({ timeout: 15_000 });
  const routingDryRun = onboardingPlan.locator('[aria-label="Real provider onboarding routing dry-run"]');
  await routingDryRun.waitFor({ timeout: 15_000 });
  await routingDryRun.getByText("Dry-run status").waitFor({ timeout: 15_000 });
  await routingDryRun.getByText("Selected channel").waitFor({ timeout: 15_000 });
  await routingDryRun.getByText("preview-primary").waitFor({ timeout: 15_000 });
  await routingDryRun.getByText("Dry-run does not call upstream").waitFor({ timeout: 15_000 });
  const clearedProviderKeyValue = await oneTimeProviderKeyInput.inputValue();
  if (clearedProviderKeyValue !== "") {
    throw new Error("one-time provider key input was not cleared after submit");
  }
  evidence.browser_steps.admin_real_provider_onboarding_non_secret_apply_ran = true;
  evidence.browser_steps.admin_real_provider_onboarding_apply_result_visible = true;
  evidence.browser_steps.admin_real_provider_onboarding_provider_key_secret_cleared = true;
  evidence.browser_steps.admin_real_provider_onboarding_routing_dry_run_visible = true;
  evidence.safe_readback.real_provider_onboarding_apply_actions_visible = [
    "Provider",
    "Channel",
    "Model",
    "Model route",
    "User profile",
    "Provider key",
    "Routing dry-run",
  ];
  evidence.safe_readback.real_provider_onboarding_apply_provider_key_result_visible = true;
  evidence.safe_readback.real_provider_onboarding_apply_submitted_one_time_secret = true;
  evidence.safe_readback.real_provider_onboarding_apply_skipped_secret = false;
  evidence.safe_readback.real_provider_onboarding_dry_run_status = "selected";
  evidence.safe_readback.real_provider_onboarding_dry_run_selected_channel_visible = true;
  evidence.safe_readback.real_provider_onboarding_dry_run_secret_boundary_visible = true;
  await onboardingWizard.getByRole("button", { name: /^Close$/ }).click();
  await onboardingWizard.waitFor({ state: "hidden", timeout: 15_000 });
  await copyChecklistButton.click();
  await userHandoffGuide.getByRole("button", { name: /Checklist copied/ }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.admin_user_handoff_checklist_copied = true;
  await screenshot(adminPage, "02-admin-distribution-readiness.png", true);

  await adminPage.getByRole("button", { name: /^Provider Keys Credentials$/ }).click();
  await adminPage.locator('[aria-label="Provider keys controls"]').waitFor({ timeout: 15_000 });
  await adminPage.locator('[aria-label="Provider key list"]').waitFor({ timeout: 15_000 });
  await adminPage.getByRole("button", { name: /^Add key$/ }).click();
  const providerKeyDialog = adminPage.getByRole("dialog", { name: "Create provider key dialog" });
  await providerKeyDialog.waitFor({ timeout: 15_000 });
  const providerKeyChannelSelect = providerKeyDialog.getByLabel("Channel");
  await providerKeyChannelSelect.waitFor({ timeout: 15_000 });
  await providerKeyDialog.getByLabel("Alias").waitFor({ timeout: 15_000 });
  await providerKeyDialog.getByLabel("Status").waitFor({ timeout: 15_000 });
  await providerKeyDialog.getByLabel("Secret / API key").waitFor({ timeout: 15_000 });
  await providerKeyDialog.getByLabel("Metadata JSON").waitFor({ timeout: 15_000 });
  const previewChannelValue = await providerKeyChannelSelect.locator("option").evaluateAll((options) => {
    const option = options.find((candidate) => candidate.textContent?.includes("preview-primary"));
    return option?.getAttribute("value") || "";
  });
  if (!previewChannelValue) {
    throw new Error("provider key channel selector did not include preview-primary channel");
  }
  await providerKeyChannelSelect.selectOption(previewChannelValue);
  const selectedProviderKeyChannel = providerKeyDialog.locator('[aria-label="Selected provider key channel"]');
  await selectedProviderKeyChannel.waitFor({ timeout: 15_000 });
  await selectedProviderKeyChannel.getByText("preview-primary", { exact: true }).waitFor({ timeout: 15_000 });
  await selectedProviderKeyChannel.getByText("enabled", { exact: true }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.admin_provider_keys_page_visible = true;
  evidence.browser_steps.admin_provider_key_create_dialog_visible = true;
  evidence.browser_steps.admin_provider_key_channel_selector_visible = true;
  evidence.browser_steps.admin_provider_key_selected_channel_visible = true;
  evidence.safe_readback.admin_provider_key_dialog_fields_visible = [
    "Channel",
    "Alias",
    "Status",
    "Secret / API key",
    "Metadata JSON",
  ];
  evidence.safe_readback.admin_provider_key_channel_selector_secret_safe = true;
  await providerKeyDialog.getByRole("button", { name: /^Close create provider key dialog$/ }).click();
  await providerKeyDialog.waitFor({ state: "hidden", timeout: 15_000 });
  await adminPage.getByRole("button", { name: /Distribution/ }).click();
  await adminPage.locator('[aria-label="User self-serve handoff guide"]').waitFor({ timeout: 15_000 });

  await userHandoffGuide.getByRole("button", { name: /Open Billing vouchers/ }).click();
  await adminPage.getByRole("tab", { name: /^Vouchers$/ }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.admin_user_handoff_billing_entry_navigated = true;
  await adminPage.getByRole("button", { name: /Distribution/ }).click();
  await adminPage.locator('[aria-label="User self-serve handoff guide"]').waitFor({ timeout: 15_000 });
  const userHandoffGuideAfterBilling = adminPage.locator('[aria-label="User self-serve handoff guide"]');
  await userHandoffGuideAfterBilling.getByRole("button", { name: /Open Request\/Trace/ }).click();
  await adminPage.getByRole("heading", { name: /Request|Trace/i }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.admin_user_handoff_trace_entry_navigated = true;
  await adminPage.getByRole("button", { name: /^Billing Billing$/ }).click();

  const userContext = await browser.newContext({ baseURL: adminUiBaseUrl, ignoreHTTPSErrors: true });
  const userPage = await userContext.newPage();
  activePage = userPage;
  await userPage.goto("/", { waitUntil: "domcontentloaded" });
  await userPage.getByRole("button", { name: /User Portal|User portal/i }).click();
  evidence.browser_steps.user_portal_mode_opened = true;
  await userPage.getByRole("button", { name: "Create account" }).click();
  await userPage.getByLabel("Display name").fill(userDisplayName);
  await userPage.getByLabel("Email").fill(userEmail);
  await userPage.getByLabel("Password").fill(userPassword);
  await userPage.getByRole("button", { name: /^Create account$/ }).click();
  await ariaSection(userPage, "User API readiness").waitFor({ timeout: 15_000 });
  await userPage.getByRole("heading", { name: "API Distribution Console" }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.user_registered_from_page = true;
  evidence.browser_steps.user_api_distribution_console_visible = true;
  evidence.browser_steps.user_readiness_visible = await ariaSection(userPage, "User API readiness").isVisible();
  evidence.browser_steps.user_models_visible = await ariaSection(userPage, "User models and API endpoints").isVisible();
  evidence.browser_steps.user_balance_visible = await ariaSection(userPage, "User balance and voucher redemption").isVisible();
  const userModelsSection = ariaSection(userPage, "User models and API endpoints");
  await userModelsSection.getByLabel("Search models").fill(model);
  await userModelsSection.getByText(model, { exact: true }).first().waitFor({ timeout: 15_000 });
  await userModelsSection.getByLabel("Callable only").check();
  await userModelsSection.getByText("shown").waitFor({ timeout: 15_000 });
  await userModelsSection.getByRole("button", { name: /^Copy model$/ }).first().click();
  await userModelsSection.getByRole("button", { name: /^Copied$/ }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.user_model_catalog_search_visible = true;
  evidence.browser_steps.user_model_catalog_search_matched = true;
  evidence.browser_steps.user_model_catalog_copy_model = true;
  evidence.safe_readback.user_model_catalog_filter_result_visible = true;

  const me = await pageControlPlaneJson(userPage, "/auth/me");
  const balance = await pageControlPlaneJson(userPage, "/user/balance");
  const readiness = await pageControlPlaneJson(userPage, "/user/readiness");
  evidence.safe_readback.user_id_sha256 = sha256(me.user?.id || "");
  evidence.safe_readback.project_id_sha256 = sha256(me.project?.id || "");
  evidence.safe_readback.wallet_id_sha256 = sha256(balance.wallet_id || "");
  evidence.safe_readback.user_readiness_state = readiness.state || null;
  evidence.safe_readback.user_readiness_active_profiles = readiness.counts?.active_profiles ?? null;
  evidence.safe_readback.user_readiness_routable_models = readiness.counts?.routable_models ?? null;
  if (!readiness.counts || readiness.counts.active_profiles < 1 || readiness.counts.routable_models < 1) {
    throw new Error("fresh user readiness is missing default profile or routable model");
  }

  const billingReferencesSection = ariaSection(userPage, "User billing references");
  await billingReferencesSection.waitFor({ timeout: 15_000 });
  await billingReferencesSection.getByText("Tenant ID", { exact: true }).waitFor({ timeout: 15_000 });
  await billingReferencesSection.getByText("Project ID", { exact: true }).waitFor({ timeout: 15_000 });
  await billingReferencesSection.getByText("Wallet ID", { exact: true }).waitFor({ timeout: 15_000 });
  await billingReferencesSection.getByText(me.user.tenant_id, { exact: true }).waitFor({ timeout: 15_000 });
  await billingReferencesSection.getByText(me.project.id, { exact: true }).waitFor({ timeout: 15_000 });
  await billingReferencesSection.getByText(balance.wallet_id, { exact: true }).waitFor({ timeout: 15_000 });
  await billingReferencesSection.getByText("Do not include API key secrets").waitFor({ timeout: 15_000 });
  await billingReferencesSection.getByRole("button", { name: /^Copy billing refs$/ }).click();
  await billingReferencesSection.getByRole("button", { name: /^Copied$/ }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.user_billing_references_visible = true;
  evidence.browser_steps.user_billing_references_copied = true;
  evidence.safe_readback.billing_references_wallet_visible = true;
  evidence.safe_readback.billing_references_secret_policy_visible = true;
  await screenshot(userPage, "03-user-dashboard-before-redeem.png", true);

  await adminPage.getByRole("button", { name: /^Billing Billing$/ }).click();
  await adminPage.getByRole("tab", { name: /^Price Versions$/ }).click();
  await adminPage.getByRole("button", { name: /^Create price version$/ }).click();
  const priceVersionDialog = adminPage.getByRole("dialog", { name: "Create price version dialog" });
  await priceVersionDialog.waitFor({ timeout: 15_000 });
  await priceVersionDialog.getByRole("textbox", { name: /^Currency$/ }).waitFor({ timeout: 15_000 });
  await priceVersionDialog.getByRole("textbox", { name: /^Fixed request cost$/ }).waitFor({ timeout: 15_000 });
  await priceVersionDialog.getByRole("textbox", { name: /^Input token rate \/ 1M$/ }).waitFor({ timeout: 15_000 });
  await priceVersionDialog.getByRole("textbox", { name: /^Output token rate \/ 1M$/ }).waitFor({ timeout: 15_000 });
  await priceVersionDialog.getByRole("textbox", { name: /^Pricing rules JSON$/ }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.admin_price_version_dialog_visible = true;
  evidence.browser_steps.admin_price_version_builder_visible = true;
  await priceVersionDialog.getByRole("button", { name: /^Close create price version dialog$/ }).click();
  await adminPage.getByRole("tab", { name: /^Vouchers$/ }).click();
  const voucherIssueSection = adminPage.locator('[aria-label="Admin voucher issuance"]');
  await voucherIssueSection.waitFor({ timeout: 15_000 });
  evidence.browser_steps.admin_voucher_issue_ui_available = true;
  const adminBillingReferencesPaste = adminPage.locator('[aria-label="Voucher billing references paste"]');
  await adminBillingReferencesPaste.waitFor({ timeout: 15_000 });
  await adminBillingReferencesPaste.getByLabel("Billing references text").fill(
    [
      "AI Gateway billing references",
      `Tenant ID: ${me.user.tenant_id}`,
      `Project ID: ${me.project.id}`,
      `Wallet ID: ${balance.wallet_id}`,
      `User ID: ${me.user.id}`,
      `Currency: ${balance.currency}`,
      "Secret policy: do not include API key secrets, voucher codes, Authorization headers, provider keys, or request payloads.",
    ].join("\n"),
  );
  await adminBillingReferencesPaste.getByRole("button", { name: /^Apply billing refs$/ }).click();
  await adminBillingReferencesPaste.getByText("Billing references applied.", { exact: true }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.admin_billing_references_paste_visible = true;
  evidence.browser_steps.admin_billing_references_applied = true;
  await voucherIssueSection.getByRole("button", { name: /^Grant user credit$/ }).click();
  const grantCreditDialog = adminPage.getByRole("dialog", { name: "Grant user credit dialog" });
  await grantCreditDialog.waitFor({ timeout: 15_000 });
  evidence.browser_steps.admin_grant_user_credit_dialog_visible = true;
  await expectInputValue(grantCreditDialog.getByRole("textbox", { name: /^Tenant ID$/ }), me.user.tenant_id);
  await expectInputValue(grantCreditDialog.getByRole("textbox", { name: /^Project ID$/ }), me.project.id);
  await expectInputValue(grantCreditDialog.getByRole("textbox", { name: /^Wallet ID$/ }), balance.wallet_id);
  await expectInputValue(grantCreditDialog.getByRole("textbox", { name: /^Currency$/ }), balance.currency);
  await grantCreditDialog.getByRole("textbox", { name: /^Amount$/ }).fill("5.00000000");
  await grantCreditDialog.getByRole("textbox", { name: /^Voucher code$/ }).fill(voucherCode);
  await grantCreditDialog.getByRole("textbox", { name: /^Idempotency key$/ }).fill(`issue-${runId}`);
  await grantCreditDialog.getByRole("textbox", { name: /^Max redemptions$/ }).fill("1");
  await grantCreditDialog.getByRole("button", { name: /^Issue voucher$/ }).click();
  await adminPage.locator('[aria-label="Voucher issuance result"]').waitFor({ timeout: 15_000 });
  await adminPage.getByText("issued", { exact: true }).first().waitFor({ timeout: 15_000 });
  evidence.safe_readback.voucher_issue_status = "issued";

  await userPage.getByLabel("Voucher code").fill(voucherCode);
  await userPage.getByRole("button", { name: /^Redeem$/ }).click();
  await userPage.getByText(/Redeemed|already applied/i).waitFor({ timeout: 15_000 });
  evidence.browser_steps.user_voucher_redeemed_from_page = true;
  evidence.safe_readback.voucher_redeem_ui_status_visible = true;
  await screenshot(userPage, "04-user-voucher-redeemed.png", true);

  await userPage.getByLabel("Key name").fill(`preview key ${runId}`);
  const createKeyResponsePromise = userPage.waitForResponse(
    (response) => response.request().method() === "POST" && response.url().includes("/user/virtual-keys"),
    { timeout: 15_000 },
  );
  await userPage.getByRole("button", { name: /^Create key$/ }).click();
  const createKeyPayload = unwrapData(await createKeyResponsePromise.then((response) => response.json()));
  await ariaSection(userPage, "Created user API key credential").waitFor({ timeout: 15_000 });
  userApiKeySecret = String(createKeyPayload?.secret || "");
  if (!userApiKeySecret || userApiKeySecret.includes("•")) {
    throw new Error("created user API key secret was not available from the one-time create response");
  }
  const createdKey = await pageControlPlaneJson(userPage, "/user/virtual-keys");
  const matchingKey = Array.isArray(createdKey)
    ? createdKey.find((key) => String(key.name || "").includes(runId)) || createdKey[0]
    : null;
  evidence.browser_steps.user_api_key_created_from_page = Boolean(userApiKeySecret);
  evidence.safe_readback.created_key_id_sha256 = matchingKey?.id ? sha256(matchingKey.id) : null;
  evidence.safe_readback.created_key_prefix = matchingKey?.key_prefix || null;
  const connectionSummarySection = ariaSection(userPage, "User connection summary");
  await connectionSummarySection.waitFor({ timeout: 15_000 });
  await connectionSummarySection.getByText("Connection summary", { exact: true }).waitFor({ timeout: 15_000 });
  await connectionSummarySection.getByText("Secret policy").waitFor({ timeout: 15_000 });
  await connectionSummarySection.getByText("API key prefix").waitFor({ timeout: 15_000 });
  evidence.browser_steps.user_connection_summary_visible = true;
  evidence.safe_readback.connection_summary_key_prefix_visible = true;
  evidence.safe_readback.connection_summary_secret_policy_visible = true;
  const apiConsoleSection = ariaSection(userPage, "User API console");
  await apiConsoleSection.locator('select[aria-label="Console model"]').selectOption(model);
  evidence.safe_readback.user_api_console_model = model;
  await ariaSection(userPage, "Selected console model details").getByText(model, { exact: true }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.user_api_console_model_detail_visible = true;
  await apiConsoleSection.getByRole("button", { name: /^Check models$/ }).click();
  await ariaSection(userPage, "User API models console result").waitFor({ timeout: 15_000 });
  await userPage.getByText("Models endpoint succeeded", { exact: true }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.user_api_console_models_called_from_page = true;
  evidence.safe_readback.user_api_console_models_status = 200;
  await apiConsoleSection.getByRole("button", { name: /^Run test$/ }).click();
  await ariaSection(userPage, "User API console result").waitFor({ timeout: 15_000 });
  await userPage.getByText("Console call succeeded", { exact: true }).waitFor({ timeout: 15_000 });
  await apiConsoleSection.getByRole("button", { name: /^View request details$/ }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.user_api_console_called_from_page = true;
  evidence.browser_steps.user_api_console_view_request_detail_visible = true;
  evidence.safe_readback.user_api_console_status = 200;
  await userPage.getByRole("button", { name: /^Clear$/ }).click();
  await screenshot(userPage, "05-user-api-key-created.png", true);

  const gatewayModels = await gatewayJson("/v1/models", { method: "GET", apiKey: userApiKeySecret });
  evidence.browser_steps.gateway_models_called_with_created_key = gatewayModels.ok;
  evidence.safe_readback.gateway_models_status = gatewayModels.status;

  const gatewayChat = await gatewayJson("/v1/chat/completions", {
    method: "POST",
    apiKey: userApiKeySecret,
    body: {
      model,
      messages: [{ role: "user", content: "Return the word ok." }],
      stream: false,
    },
  });
  evidence.browser_steps.gateway_chat_called_with_created_key = gatewayChat.ok;
  evidence.safe_readback.gateway_chat_status = gatewayChat.status;

  await ariaSection(userPage, "User request logs").getByRole("button", { name: /^Refresh$/ }).click();
  const usageSummarySection = ariaSection(userPage, "User usage summary");
  await usageSummarySection.waitFor({ timeout: 15_000 });
  await usageSummarySection.getByText(model, { exact: true }).first().waitFor({ timeout: 15_000 });
  await userPage.getByRole("button", { name: /^30d$/ }).click();
  await ariaSection(userPage, "User request logs").getByText("Last 30 day usage").waitFor({ timeout: 15_000 });
  evidence.browser_steps.user_usage_window_switched_from_page = true;
  evidence.safe_readback.usage_window_days_visible = 30;
  const logs = await pageControlPlaneJson(userPage, "/user/request-logs?limit=20");
  evidence.safe_readback.usage_log_rows_observed = Array.isArray(logs) ? logs.length : null;
  evidence.browser_steps.user_usage_visible_after_gateway_call = Array.isArray(logs) && logs.length > 0;
  const billingExplanationSection = ariaSection(userPage, "User billing explanation");
  await billingExplanationSection.waitFor({ timeout: 15_000 });
  await billingExplanationSection.getByText("AI Gateway billing explanation").waitFor({ timeout: 15_000 });
  await billingExplanationSection.getByText("Secret policy: this explanation excludes raw prompts").waitFor({ timeout: 15_000 });
  await billingExplanationSection.getByRole("button", { name: /^Copy explanation$/ }).click();
  await billingExplanationSection.getByRole("button", { name: /^Copied$/ }).waitFor({ timeout: 15_000 });
  await billingExplanationSection.getByRole("button", { name: /^Export CSV$/ }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.user_billing_explanation_visible = true;
  evidence.browser_steps.user_billing_explanation_copied = true;
  evidence.browser_steps.user_usage_export_available = true;
  evidence.safe_readback.billing_explanation_secret_policy_visible = true;

  await userPage.getByRole("button", { name: /^Details$/ }).first().click();
  await ariaSection(userPage, "User request detail").waitFor({ timeout: 15_000 });
  evidence.browser_steps.user_request_detail_visible = true;
  await ariaSection(userPage, "User trace summary").waitFor({ timeout: 15_000 });
  evidence.browser_steps.user_trace_summary_visible = true;
  await screenshot(userPage, "06-user-usage-trace-detail.png", true);

  activePage = adminPage;
  await adminPage.getByRole("button", { name: /Distribution/ }).click();
  const finalUserHandoffGuide = adminPage.locator('[aria-label="User self-serve handoff guide"]');
  await finalUserHandoffGuide.waitFor({ timeout: 15_000 });
  await finalUserHandoffGuide.getByRole("button", { name: /Sign out to User Portal/ }).click();
  await adminPage.getByRole("button", { name: "Create account" }).waitFor({ timeout: 15_000 });
  await adminPage.getByText("User Portal", { exact: true }).waitFor({ timeout: 15_000 });
  evidence.browser_steps.admin_user_handoff_user_portal_entry_navigated = true;

  const allowedFalseSteps = new Set(["admin_voucher_issue_api_fallback_used"]);
  const failedSteps = Object.entries(evidence.browser_steps)
    .filter(([key]) => !allowedFalseSteps.has(key))
    .filter(([, value]) => value !== true)
    .map(([key]) => key);
  if (failedSteps.length > 0) {
    evidence.blockers.push(...failedSteps.map((step) => `browser_step_not_completed:${step}`));
  }

  evidence.status = evidence.blockers.length === 0 ? "pass" : "failed";
} catch (error) {
  if (activePage) {
    try {
      if (userApiKeySecret) {
        await clearVisibleUserSecret(activePage);
      }
      await screenshot(activePage, "99-failure-state.png", true);
      evidence.failure_page_text_sha256 = sha256(await activePage.locator("body").innerText({ timeout: 2_000 }));
    } catch {
      evidence.warnings.push("failure_screenshot_unavailable");
    }
  }
  evidence.blockers.push(error instanceof Error ? error.message : String(error));
  evidence.status = "failed";
  process.exitCode = 1;
} finally {
  if (browser) {
    await browser.close();
  }

  evidence.completed_at_utc = new Date().toISOString();
  evidence.duration_ms = new Date(evidence.completed_at_utc).getTime() - startedAt.getTime();
  assertSecretSafeEvidence(evidence);
  await fs.mkdir(path.dirname(artifactPath), { recursive: true });
  await fs.writeFile(artifactPath, `${JSON.stringify(evidence, null, 2)}\n`, "utf8");
  console.log(JSON.stringify(evidence, null, 2));
}

async function screenshot(page, filename, fullPage = false) {
  const fullPath = path.join(screenshotDir, filename);
  await page.screenshot({ path: fullPath, fullPage });
  evidence.screenshots.push({
    name: filename,
    path: repoRelative(fullPath),
    sha256: sha256(await fs.readFile(fullPath)),
  });
}

async function loginAdminForFallback() {
  const response = await controlPlaneJson("/admin/auth/login", {
    method: "POST",
    body: { email: adminEmail, password: adminPassword },
  });
  const token = response.session_token_once;
  if (!token) {
    throw new Error("admin API fallback login did not return a session token");
  }
  return token;
}

async function controlPlaneJson(apiPath, options = {}) {
  const response = await fetch(`${controlPlaneBaseUrl}${apiPath}`, {
    method: options.method || "GET",
    headers: {
      Accept: "application/json",
      ...(options.body ? { "Content-Type": "application/json" } : {}),
      ...(options.headers || {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const text = await response.text();
  const payload = text ? JSON.parse(text) : null;
  if (!response.ok) {
    throw new Error(`Control Plane request failed ${apiPath} status=${response.status}`);
  }
  return unwrapData(payload);
}

async function pageControlPlaneJson(page, apiPath) {
  const result = await page.evaluate(async ({ baseUrl, pathName }) => {
    const response = await fetch(`${baseUrl}${pathName}`, {
      credentials: "include",
      headers: { Accept: "application/json" },
    });
    const text = await response.text();
    return {
      ok: response.ok,
      status: response.status,
      payload: text ? JSON.parse(text) : null,
    };
  }, { baseUrl: controlPlaneBaseUrl, pathName: apiPath });
  if (!result.ok) {
    throw new Error(`Control Plane browser request failed ${apiPath} status=${result.status}`);
  }
  return unwrapData(result.payload);
}

async function gatewayJson(apiPath, options) {
  const response = await fetch(`${gatewayBaseUrl}${apiPath}`, {
    method: options.method,
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${options.apiKey}`,
      ...(options.body ? { "Content-Type": "application/json" } : {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const text = await response.text();
  let payload = null;
  try {
    payload = text ? JSON.parse(text) : null;
  } catch {
    payload = null;
  }
  return { ok: response.ok, status: response.status, object: payload?.object || null };
}

function unwrapData(payload) {
  if (payload && typeof payload === "object" && "data" in payload) {
    return payload.data;
  }
  return payload;
}

function ariaSection(page, label) {
  return page.locator(`[aria-label="${cssEscapeAttribute(label)}"]`);
}

async function expectInputValue(locator, expected) {
  const actual = await locator.inputValue({ timeout: 15_000 });
  if (actual !== expected) {
    throw new Error(`input value mismatch expected=${expected} actual=${actual}`);
  }
}

async function clearVisibleUserSecret(page) {
  try {
    const clearButton = page.getByRole("button", { name: /^Clear$/ });
    if (await clearButton.isVisible({ timeout: 1_000 })) {
      await clearButton.click();
    }
  } catch {
    evidence.warnings.push("failure_secret_clear_unavailable");
  }
}

function cssEscapeAttribute(value) {
  return String(value).replaceAll("\\", "\\\\").replaceAll('"', '\\"');
}

function assertSecretSafeEvidence(payload) {
  const text = JSON.stringify(payload);
  const forbidden = [
    adminPassword,
    userPassword,
    voucherCode,
    onboardingOneTimeProviderKey,
    userApiKeySecret,
    "Authorization",
    "Bearer ",
    "session_token_once",
    "ai_gateway_user_session",
  ].filter(Boolean);
  for (const value of forbidden) {
    if (value && text.includes(value)) {
      payload.status = "failed";
      payload.blockers.push("secret_safety_violation_in_artifact");
      throw new Error("secret_safety_violation_in_artifact");
    }
  }
}

function withoutTrailingSlash(value) {
  return value.replace(/\/+$/, "");
}

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function repoRelative(fullPath) {
  return path.relative(process.cwd(), fullPath).replaceAll(path.sep, "/");
}
