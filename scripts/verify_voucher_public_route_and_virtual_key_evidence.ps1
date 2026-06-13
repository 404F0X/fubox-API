param(
  [string]$OutputPath = ".tmp\launch\voucher_public_route_and_virtual_key_evidence.json",
  [string]$OperatorExceptionOutputPath = ".tmp\launch\voucher_operator_only_exception.json",
  [string]$OperatorPacketOutputPath = "",
  [string]$ReadinessArtifactPath = ".tmp\launch\voucher_api_distribution_readiness.json",
  [string]$RemainingBalanceArtifactPath = ".tmp\credit-wallet\user_remaining_balance_ownership_runtime.json",
  [string]$RechargeVoucherRuntimeArtifactPath = ".tmp\credit-wallet\recharge_voucher_runtime.json",
  [string]$RouteLiveHttpProofPath = ".tmp\route-live-http-proof\route_level_live_http_proof.json",
  [string]$AdminSourcePath = "apps\control-plane\src\admin.rs",
  [string]$RbacSourcePath = "apps\control-plane\src\rbac.rs",
  [string]$OpenApiPath = "examples\openapi_admin_skeleton.yaml",
  [switch]$OperatorExceptionApproved,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-RepoBoundedPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$AllowedPrefixes
  )

  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }
  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "path_must_stay_inside_repo"
  }

  $relative = $candidate.Substring($repoPrefix.Length).Replace("\", "/")
  $allowed = $false
  foreach ($prefix in $AllowedPrefixes) {
    if ($relative.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $allowed = $true
      break
    }
  }
  if (-not $allowed) {
    throw "path_prefix_not_allowed"
  }

  return [ordered]@{ full = $candidate; relative = $relative }
}

function Read-RepoText {
  param([Parameter(Mandatory = $true)][string]$Path)

  $resolved = Resolve-RepoBoundedPath -Path $Path -AllowedPrefixes @("apps/", "examples/", "scripts/", "tests/")
  if (-not (Test-Path -LiteralPath $resolved.full -PathType Leaf)) {
    return [ordered]@{ path = $resolved.relative; exists = $false; text = "" }
  }
  return [ordered]@{ path = $resolved.relative; exists = $true; text = Get-Content -Raw -LiteralPath $resolved.full }
}

function Read-RepoJson {
  param([Parameter(Mandatory = $true)][string]$Path)

  $resolved = Resolve-RepoBoundedPath -Path $Path -AllowedPrefixes @(".tmp/", "artifacts/", "tests/fixtures/")
  if (-not (Test-Path -LiteralPath $resolved.full -PathType Leaf)) {
    return [ordered]@{ path = $resolved.relative; exists = $false; json = $null }
  }
  $raw = Get-Content -Raw -LiteralPath $resolved.full
  if (-not (Test-SecretSafeText $raw)) {
    return [ordered]@{ path = $resolved.relative; exists = $true; json = $null; secret_unsafe = $true }
  }
  return [ordered]@{ path = $resolved.relative; exists = $true; json = ($raw | ConvertFrom-Json); secret_unsafe = $false }
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
  foreach ($pattern in @(
      '(?i)authorization\s*[:=]',
      '(?i)cookie\s*[:=]',
      '(?i)bearer\s+[A-Za-z0-9._~+/\-]+=*',
      '(?i)provider[_-]?key\s*[:=]',
      '(?i)virtual[_-]?key\s*[:=]',
      '(?i)database[_-]?url\s*[:=]',
      '(?i)postgres(?:ql)?://[^"\s]+',
      '(?i)raw[_-]?voucher[_-]?code\s*[:=]',
      'sk-[A-Za-z0-9]{8,}'
    )) {
    if ($Text -match $pattern) { return $false }
  }
  return $true
}

function Get-RouterText {
  param([Parameter(Mandatory = $true)][string]$AdminText)

  if ($AdminText -match '(?s)pub\(crate\)\s+fn\s+router\(\)\s+->\s+Router<Arc<ControlPlaneState>>\s+\{(?<router>.*?)#\[derive') {
    return $Matches["router"]
  }
  return $AdminText
}

function New-EvidenceArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$AdminText,
    [Parameter(Mandatory = $true)][string]$RbacText,
    [Parameter(Mandatory = $true)][string]$OpenApiText,
    [AllowNull()][object]$VoucherRuntimeJson = $null,
    [AllowNull()][object]$ReadinessJson = $null,
    [AllowNull()][object]$RouteLiveProofJson = $null
  )

  $routerText = Get-RouterText -AdminText $AdminText
  $voucherOpenApi = [ordered]@{
    admin_voucher_issuances = [bool]($OpenApiText -match '(?m)^\s*/admin/voucher-issuances:')
    billing_voucher_redeem = [bool]($OpenApiText -match '(?m)^\s*/billing/vouchers/redeem:')
  }
  $voucherRoutesWired = [bool](
    $routerText -match '"/admin/voucher-issuances"' -or
    $routerText -match '"/billing/vouchers/redeem"'
  )
  $virtualKeyRouteFound = [bool](
    $routerText -match '(?s)\.route\(\s*"/admin/virtual-keys"[\s\S]*get\(list_virtual_keys\)\.post\(create_virtual_key\)' -and
    $routerText -match '\.route\("/admin/virtual-keys/\{id\}",\s*get\(get_virtual_key\)\)'
  )
  $virtualKeyContract = [ordered]@{
    route_found = $virtualKeyRouteFound
    route_invoked = $false
    bounded_db_free_route_contract = $true
    create_handler_found = [bool]($AdminText -match 'async\s+fn\s+create_virtual_key')
    server_generates_secret = [bool]($AdminText -match 'let\s+generated\s+=\s+generate_virtual_key\(\);')
    rejects_client_secret_fields = [bool]($AdminText -match 'reject_virtual_key_create_generated_fields' -and $AdminText -match 'secret, secret_hash, and key_prefix are generated by the server')
    one_time_secret_return_only = [bool]($AdminText -match 'virtual_key_response\(virtual_key,\s*Some\(secret\)\)' -and $AdminText -match 'secret_once')
    list_get_never_return_secret = [bool]($AdminText -match 'virtual_key_response\(virtual_key,\s*None\)' -and $AdminText -match 'map\(\|virtual_key\|\s+virtual_key_response\(virtual_key,\s*None\)\)')
    create_audit_marker_present = [bool]($AdminText -match 'create_virtual_key_with_default_profile_and_audit[\s\S]*"virtual_key\.create"')
    rbac_key_manage_required = [bool]($RbacText -match 'path == "/admin/virtual-keys"' -and $RbacText -match 'Permission::KeyManage')
    raw_virtual_key_secret_in_artifact = $false
  }
  $rollbackContract = [ordered]@{
    virtual_key_disable_route_present = [bool]($routerText -match '"/admin/virtual-keys/\{id\}/disable"')
    virtual_key_expire_route_present = [bool]($routerText -match '"/admin/virtual-keys/\{id\}/expire"')
    credit_grant_revoke_route_present = [bool]($routerText -match '"/admin/credit-grants/\{credit_grant_id\}/revoke"')
    credit_grant_expire_route_present = [bool]($routerText -match '"/admin/credit-grants/\{credit_grant_id\}/expire"')
    remaining_balance_recheck_route_present = [bool]($routerText -match '"/billing/wallets/\{wallet_id\}/remaining-balance"')
    audit_readback_route_present = [bool]($routerText -match '"/admin/audit-logs"')
    bounded_contract_only = $true
    live_invocation = $false
  }
  $virtualKeyVerified = [bool](
    $virtualKeyContract.route_found -and
    $virtualKeyContract.create_handler_found -and
    $virtualKeyContract.server_generates_secret -and
    $virtualKeyContract.rejects_client_secret_fields -and
    $virtualKeyContract.one_time_secret_return_only -and
    $virtualKeyContract.list_get_never_return_secret -and
    $virtualKeyContract.create_audit_marker_present -and
    $virtualKeyContract.rbac_key_manage_required
  )
  $voucherRuntimeVerified = [bool](
    (Get-JsonString -Json $VoucherRuntimeJson -Name "overall_status") -eq "pass" -and
    (Get-JsonBool -Json $VoucherRuntimeJson -Name "runtime_implemented") -and
    -not (Get-JsonBool -Json $VoucherRuntimeJson -Name "contract_only") -and
    (Get-JsonBool -Json $VoucherRuntimeJson -Name "internal_runtime_function_invoked") -and
    (Get-JsonBool -Json $VoucherRuntimeJson -Name "voucher_code_hash_readback_passed") -and
    (Get-JsonBool -Json $VoucherRuntimeJson -Name "voucher_code_redacted_output") -and
    -not (Get-JsonBool -Json $VoucherRuntimeJson -Name "raw_secret_markers_present") -and
    (Get-JsonBool -Json $VoucherRuntimeJson -Name "redeem_idempotency_readback_passed") -and
    (Get-JsonBool -Json $VoucherRuntimeJson -Name "audit_readback_passed") -and
    (Get-JsonBool -Json $VoucherRuntimeJson -Name "ledger_or_credit_readback_passed") -and
    (Get-JsonBool -Json $VoucherRuntimeJson -Name "abuse_refusal_no_write_readback_passed") -and
    (Get-JsonBool -Json $VoucherRuntimeJson -Name "secret_safe") -and
    -not (Get-JsonBool -Json $VoucherRuntimeJson -Name "paid_gate_changed")
  )
  $readinessAcceptsOperatorMediated = [bool](
    (Get-JsonString -Json $ReadinessJson -Name "overall_status") -eq "pass_with_productization_gaps" -and
    (Get-JsonBool -Json $ReadinessJson -Name "voucher_redeem_runtime_verified") -and
    (Get-JsonBool -Json $ReadinessJson -Name "gateway_current_launch_hot_path_verified") -and
    (Get-JsonBool -Json $ReadinessJson -Name "user_remaining_balance_runtime_verified") -and
    -not (Get-JsonBool -Json $ReadinessJson -Name "paid_gate_changed")
  )
  $operatorPathVerified = [bool]($voucherRuntimeVerified -and $virtualKeyVerified -and $readinessAcceptsOperatorMediated)
  $liveProofVoucher = if ($null -ne $RouteLiveProofJson -and $RouteLiveProofJson.PSObject.Properties.Name -contains "voucher") { $RouteLiveProofJson.voucher } else { $null }
  $liveProofVirtualKey = if ($null -ne $RouteLiveProofJson -and $RouteLiveProofJson.PSObject.Properties.Name -contains "virtual_key") { $RouteLiveProofJson.virtual_key } else { $null }
  $liveProofGatewayRoute = if ($null -ne $RouteLiveProofJson -and $RouteLiveProofJson.PSObject.Properties.Name -contains "gateway_route") { $RouteLiveProofJson.gateway_route } else { $null }
  $gatewayRequestIds = @()
  if ($null -ne $liveProofGatewayRoute) {
    $gatewayRequestIds = @($liveProofGatewayRoute.request_ids)
    if ($gatewayRequestIds.Count -lt 1 -and -not [string]::IsNullOrWhiteSpace([string]$liveProofGatewayRoute.request_id)) {
      $gatewayRequestIds = @([string]$liveProofGatewayRoute.request_id)
    }
  }
  $voucherRouteInvoked = [bool](
    (Get-JsonBool -Json $liveProofVoucher -Name "issue_route_invoked") -or
    (Get-JsonBool -Json $liveProofVoucher -Name "redeem_route_invoked")
  )
  $voucherRouteVerified = [bool](
    (Get-JsonString -Json $RouteLiveProofJson -Name "schema") -eq "route_level_live_http_proof.v1" -and
    (Get-JsonString -Json $RouteLiveProofJson -Name "overall_status") -eq "pass" -and
    (Get-JsonBool -Json $liveProofVoucher -Name "issue_route_invoked") -and
    (Get-JsonBool -Json $liveProofVoucher -Name "redeem_route_invoked") -and
    (Get-JsonBool -Json $liveProofVoucher -Name "issue_readback") -and
    (Get-JsonBool -Json $liveProofVoucher -Name "redeem_readback") -and
    (Get-JsonBool -Json $liveProofVoucher -Name "attempt_readback") -and
    (Get-JsonBool -Json $liveProofVoucher -Name "credit_grant_readback") -and
    (Get-JsonBool -Json $liveProofVoucher -Name "ledger_readback") -and
    (Get-JsonBool -Json $liveProofVoucher -Name "audit_readback") -and
    -not (Get-JsonBool -Json $liveProofVoucher -Name "raw_voucher_code_in_artifact") -and
    (Get-JsonBool -Json $RouteLiveProofJson -Name "secret_safe") -and
    -not (Get-JsonBool -Json $RouteLiveProofJson -Name "paid_gate_changed")
  )
  $virtualKeyLiveVerified = [bool](
    (Get-JsonString -Json $RouteLiveProofJson -Name "overall_status") -eq "pass" -and
    (Get-JsonBool -Json $liveProofVirtualKey -Name "route_invoked") -and
    (Get-JsonBool -Json $liveProofVirtualKey -Name "created") -and
    (Get-JsonBool -Json $liveProofVirtualKey -Name "get_redacted") -and
    (Get-JsonBool -Json $liveProofVirtualKey -Name "audit_readback") -and
    -not (Get-JsonBool -Json $liveProofVirtualKey -Name "raw_secret_in_artifact") -and
    (Get-JsonBool -Json $RouteLiveProofJson -Name "secret_safe")
  )

  $publicRouteBlockers = [System.Collections.Generic.List[string]]::new()
  if (-not $voucherRoutesWired) {
    [void]$publicRouteBlockers.Add("voucher_public_control_plane_routes_not_wired")
  } elseif (-not $voucherRouteVerified) {
    [void]$publicRouteBlockers.Add("voucher_public_route_live_probe_pending")
  }
  $operatorPathBlockers = [System.Collections.Generic.List[string]]::new()
  if (-not $voucherRuntimeVerified) { [void]$operatorPathBlockers.Add("voucher_internal_runtime_not_verified") }
  if (-not $virtualKeyVerified) {
    [void]$operatorPathBlockers.Add("virtual_key_bounded_route_contract_not_verified")
  }
  if (-not $readinessAcceptsOperatorMediated) { [void]$operatorPathBlockers.Add("operator_mediated_readiness_not_verified") }

  $productizationGaps = [System.Collections.Generic.List[string]]::new()
  if ($voucherRouteVerified) {
    [void]$productizationGaps.Add("public_self_serve_ux_productization_pending")
  } else {
    foreach ($blocker in $publicRouteBlockers) { [void]$productizationGaps.Add($blocker) }
  }

  $overallStatus = if ($voucherRouteVerified -and $operatorPathBlockers.Count -eq 0) { "pass" } elseif ($operatorPathVerified) { "partial" } else { "blocked" }
  return [ordered]@{
    schema = "voucher_public_route_virtual_key_evidence.v1"
    overall_status = $overallStatus
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    voucher_route_evidence = [ordered]@{
      status = if ($voucherRouteVerified) { "live_route_verified" } elseif ($voucherRoutesWired) { "route_wired_needs_live_probe" } else { "blocked" }
      route_verified = $voucherRouteVerified
      route_invoked = $voucherRouteInvoked
      public_routes_wired = $voucherRoutesWired
      openapi_contract_found = $voucherOpenApi
      route_level_live_http_proof_artifact = ".tmp/route-live-http-proof/route_level_live_http_proof.json"
      blocker = if ($publicRouteBlockers.Count -gt 0) { $publicRouteBlockers[0] } else { $null }
      feasibility_decision = if ($voucherRouteVerified) { "control_plane_routes_wired_and_live_probe_passed" } elseif ($voucherRoutesWired) { "control_plane_routes_wired_live_probe_pending" } else { "not_wired_in_this_slice" }
      rationale = if ($voucherRouteVerified) { "Live route-level proof invoked POST /admin/voucher-issuances and POST /billing/vouchers/redeem through Control Plane, then read back voucher issuance, redemption attempt, redemption, credit grant, ledger, and audit rows without raw voucher code output and with paid_gate_changed=false." } elseif ($voucherRoutesWired) { "Control-plane voucher issue/redeem handlers are wired and protected by BillingAdjust; route_verified remains false until a live HTTP probe records request, auth/RBAC, idempotency, audit, ledger/credit readback, refusal no-write, and secret-safe evidence." } else { "Existing accepted voucher evidence is an internal Rust/sqlx verifier path; public request handlers need separate auth, request parsing, response, idempotency, audit, and refusal semantics before route-level pass can be claimed." }
    }
    request_trace_lookup_keys = [ordered]@{
      source = "route_level_live_http_proof.gateway_route"
      request_ids = [object[]]@($gatewayRequestIds)
      request_id_count = [int]$gatewayRequestIds.Count
      metadata_only = $true
      raw_request_body_omitted = $true
      raw_response_body_omitted = $true
      credential_values_omitted = $true
    }
    operator_mediated_handoff_evidence = [ordered]@{
      status = if ($operatorPathVerified) { "bounded_evidence_verified_public_route_productization_gap" } else { "blocked" }
      sufficient_for_operator_mediated_handoff = $operatorPathVerified
      not_a_public_route_pass = -not $voucherRouteVerified
      voucher_internal_runtime_verified = $voucherRuntimeVerified
      virtual_key_bounded_contract_verified = $virtualKeyVerified
      readiness_accepts_operator_mediated_productization_gap = $readinessAcceptsOperatorMediated
      voucher_runtime_artifact = ".tmp/credit-wallet/recharge_voucher_runtime.json"
      readiness_artifact = ".tmp/launch/voucher_api_distribution_readiness.json"
      controls = [ordered]@{
        billing_adjust_backed_primitives = [bool]($RbacText -match 'Permission::BillingAdjust' -and $RbacText -match '"/admin/credit-grants"')
        voucher_hash_redaction_readback = [bool](
          (Get-JsonBool -Json $VoucherRuntimeJson -Name "voucher_code_hash_readback_passed") -and
          (Get-JsonBool -Json $VoucherRuntimeJson -Name "voucher_code_redacted_output")
        )
        idempotency_readback = [bool](Get-JsonBool -Json $VoucherRuntimeJson -Name "redeem_idempotency_readback_passed")
        audit_readback = [bool](Get-JsonBool -Json $VoucherRuntimeJson -Name "audit_readback_passed")
        ledger_or_credit_effect_readback = [bool](Get-JsonBool -Json $VoucherRuntimeJson -Name "ledger_or_credit_readback_passed")
        refusal_no_write = [bool](Get-JsonBool -Json $VoucherRuntimeJson -Name "abuse_refusal_no_write_readback_passed")
        virtual_key_one_time_secret_only = [bool]$virtualKeyContract.one_time_secret_return_only
        virtual_key_list_get_redacted = [bool]$virtualKeyContract.list_get_never_return_secret
        virtual_key_rbac_key_manage_required = [bool]$virtualKeyContract.rbac_key_manage_required
        raw_voucher_code_echoed = [bool](Get-JsonBool -Json $VoucherRuntimeJson -Name "raw_voucher_code_echoed")
        raw_virtual_key_secret_in_artifact = $false
        secret_safe = [bool]((Get-JsonBool -Json $VoucherRuntimeJson -Name "secret_safe") -and $virtualKeyVerified)
        paid_gate_changed = [bool](Get-JsonBool -Json $VoucherRuntimeJson -Name "paid_gate_changed")
      }
      blocker_classification = [ordered]@{
        operator_path_blockers = @($operatorPathBlockers.ToArray())
        public_self_serve_productization_blockers = @($publicRouteBlockers.ToArray())
        public_route_gap_blocks_operator_mediated_handoff = $false
      }
    }
    virtual_key_issue_readback_audit = [ordered]@{
      status = if ($virtualKeyVerified) { "bounded_contract_verified" } else { "blocked" }
      route_verified = $virtualKeyLiveVerified
      route_invoked = [bool](Get-JsonBool -Json $liveProofVirtualKey -Name "route_invoked")
      bounded_db_free_route_contract_verified = $virtualKeyVerified
      create_route = "POST /admin/virtual-keys"
      list_route = "GET /admin/virtual-keys"
      read_route = "GET /admin/virtual-keys/{id}"
      checks = $virtualKeyContract
      live_artifact_required_for_route_invoked_true = $true
    }
    rollback_revoke_contract = $rollbackContract
    implemented_runtime_flags = [ordered]@{
      voucher_public_route_verified = $voucherRouteVerified
      virtual_key_live_route_verified = $virtualKeyLiveVerified
      virtual_key_bounded_route_contract_verified = $virtualKeyVerified
      secret_safe = $true
      paid_gate_changed = $false
    }
    no_secret_outputs = [ordered]@{
      raw_voucher_code = $false
      authorization = $false
      cookie = $false
      db_url = $false
      provider_key = $false
      virtual_key_secret = $false
    }
    blockers = @($operatorPathBlockers.ToArray())
    public_route_blockers = @($publicRouteBlockers.ToArray())
    productization_gaps = @($productizationGaps.ToArray())
    resume_conditions = @(
      "for public self-serve UX: add product screens/API client flow, operator-free onboarding copy, quota/rate budget selection, user-facing errors, and final handoff metadata capture",
      "if live route proof is stale or missing: run live route-level probes for POST /admin/voucher-issuances and POST /billing/vouchers/redeem with auth/RBAC, idempotency, audit, ledger/credit readback, refusal no-write, and secret-safe evidence",
      "for operator-only substitution: provide explicit release-owner/Product/Ops approval artifact before treating the exception as approved",
      "run a live Admin virtual-key create/list/get/audit smoke if route_invoked=true is required",
      "preserve one-time virtual-key secret return only and never write raw key material to artifacts"
    )
    secret_safe = $true
    paid_gate_changed = $false
  }
}

function New-OperatorOnlyExceptionArtifact {
  param(
    [Parameter(Mandatory = $true)][object]$RouteEvidenceArtifact,
    [bool]$Approved
  )

  $voucherBlocked = [bool]($RouteEvidenceArtifact.voucher_route_evidence.route_verified -eq $false)
  $routeVerified = [bool]$RouteEvidenceArtifact.voucher_route_evidence.route_verified
  $status = if ($routeVerified) { "not_needed_public_route_verified" } elseif ($Approved -and $voucherBlocked) { "approved_operator_only_exception" } else { "unapproved" }
  $routeSubstitutionAllowed = [bool]($Approved -and $voucherBlocked)
  return [ordered]@{
    schema = "voucher_operator_only_exception.v1"
    overall_status = $status
    approved = $routeSubstitutionAllowed
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    applies_to = "selected_trusted_user_voucher_backed_beta_operator_mediated_distribution"
    scope = "selected_trusted_user_beta_operator_mediated_only"
    route_substitution_allowed = $routeSubstitutionAllowed
    production_distribution_ready = $routeVerified
    full_commercial_ready = $false
    public_self_serve_ready = $false
    not_a_public_voucher_route_pass = -not $routeVerified
    voucher_public_routes_wired = [bool]$RouteEvidenceArtifact.voucher_route_evidence.public_routes_wired
    voucher_route_verified = [bool]$RouteEvidenceArtifact.voucher_route_evidence.route_verified
    operator_only_manual_flow = [ordered]@{
      step_1 = "operator uses accepted internal recharge/voucher runtime artifact and bounded tenant/project/wallet ids"
      step_2 = "operator issues or assigns Admin-created virtual key through bounded virtual-key route contract"
      step_3 = "operator records voucher/credit grant or ledger ids, remaining-balance readback, audit ids, owner, and rollback contact"
      step_4 = "operator disables/revokes virtual key and revokes/expires voucher-backed quota for rollback"
    }
    required_approval = [ordered]@{
      release_owner_approval_required = $true
      product_ops_approval_required = $true
      approval_artifact_present = $routeSubstitutionAllowed
      unapproved_exception_must_not_pass_readiness = -not $routeSubstitutionAllowed
    }
    risks = if ($routeVerified) {
      @(
        "operator-only exception is not needed for route substitution because public voucher route proof exists",
        "support/audit packets and per-user handoff metadata are still outside product self-serve UX"
      )
    } else {
      @(
        "no public HTTP voucher issuance/redeem route invocation",
        "manual operator workflow can drift without route-level request validation",
        "support/audit packets must be maintained outside product self-serve flow"
      )
    }
    resume_conditions = if ($routeVerified) {
      @(
        "complete public self-serve UX/productization before claiming full commercial readiness",
        "keep route proof current with secret-safe paid-gate-neutral readbacks"
      )
    } else {
      @(
        "wire POST /admin/voucher-issuances and POST /billing/vouchers/redeem to route handlers",
        "or provide explicit release-owner/Product/Ops approval artifact for selected trusted-user Beta operator-only distribution",
        "prove route or exception path with secret-safe evidence and paid-gate-neutral readbacks"
      )
    }
    no_secret_outputs = [ordered]@{
      raw_voucher_code = $false
      authorization = $false
      cookie = $false
      db_url = $false
      provider_key = $false
      virtual_key_secret = $false
    }
    secret_safe = $true
    paid_gate_changed = $false
  }
}

function Get-JsonString {
  param([AllowNull()][object]$Json, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Json -or $Json.PSObject.Properties.Name -notcontains $Name) { return "" }
  if ($null -eq $Json.PSObject.Properties[$Name].Value) { return "" }
  return [string]$Json.PSObject.Properties[$Name].Value
}

function Get-JsonBool {
  param([AllowNull()][object]$Json, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Json -or $Json.PSObject.Properties.Name -notcontains $Name) { return $false }
  $value = $Json.PSObject.Properties[$Name].Value
  if ($value -is [bool]) { return [bool]$value }
  return ([string]$value).ToLowerInvariant() -in @("true", "1", "yes", "pass", "passed")
}

function New-OperatorPacketArtifact {
  param(
    [Parameter(Mandatory = $true)][object]$RouteEvidenceArtifact,
    [Parameter(Mandatory = $true)][object]$ExceptionArtifact,
    [Parameter(Mandatory = $true)][object]$ReadinessArtifact,
    [Parameter(Mandatory = $true)][object]$RemainingBalanceArtifact,
    [Parameter(Mandatory = $true)][object]$VoucherRuntimeArtifact
  )

  $readiness = $ReadinessArtifact.json
  $balance = $RemainingBalanceArtifact.json
  $voucher = $VoucherRuntimeArtifact.json
  $tenantId = Get-JsonString -Json $balance -Name "tenant_id"
  if ([string]::IsNullOrWhiteSpace($tenantId)) { $tenantId = Get-JsonString -Json $voucher -Name "tenant_id" }
  $walletId = Get-JsonString -Json $balance -Name "wallet_id"
  if ([string]::IsNullOrWhiteSpace($walletId)) { $walletId = Get-JsonString -Json $voucher -Name "wallet_id" }
  $projectId = Get-JsonString -Json $balance -Name "project_id"
  $currency = Get-JsonString -Json $balance -Name "currency"
  if ([string]::IsNullOrWhiteSpace($currency)) { $currency = Get-JsonString -Json $voucher -Name "currency" }

  $gatewayVerified = Get-JsonBool -Json $readiness "gateway_current_launch_hot_path_verified"
  $voucherRouteVerified = [bool]$RouteEvidenceArtifact.voucher_route_evidence.route_verified
  $exceptionApproved = [bool]$ExceptionArtifact.approved
  $virtualKeyBounded = [bool]$RouteEvidenceArtifact.virtual_key_issue_readback_audit.bounded_db_free_route_contract_verified
  $rollbackContract = $RouteEvidenceArtifact.rollback_revoke_contract
  $rollbackContractVerified = [bool](
    $rollbackContract.virtual_key_disable_route_present -and
    $rollbackContract.virtual_key_expire_route_present -and
    ($rollbackContract.credit_grant_revoke_route_present -or $rollbackContract.credit_grant_expire_route_present) -and
    $rollbackContract.remaining_balance_recheck_route_present -and
    $rollbackContract.audit_readback_route_present
  )
  $balanceVerified = Get-JsonBool -Json $readiness "user_remaining_balance_runtime_verified"
  $voucherRuntimeVerified = Get-JsonBool -Json $readiness "voucher_redeem_runtime_verified"
  $scopedBetaPrerequisitesMet = [bool]($gatewayVerified -and $virtualKeyBounded -and $balanceVerified -and $voucherRuntimeVerified)
  $perUserOperatorMetadataFilled = $false
  $readyToSend = [bool]($scopedBetaPrerequisitesMet -and $perUserOperatorMetadataFilled)
  $readyToRollbackAfterSend = if ($rollbackContractVerified) { "bounded_contract_ready_live_invocation_pending" } else { "blocked" }
  $gatewayBlockerText = Get-JsonString -Json $readiness -Name "gateway_current_blocker"
  $gatewayBlockerCode = if ($gatewayVerified) {
    ""
  } elseif ($gatewayBlockerText -match 'expected HTTP 402, got HTTP 200') {
    "gateway_current_launch_hot_path_expected_402_got_200"
  } elseif ([string]::IsNullOrWhiteSpace($gatewayBlockerText)) {
    "gateway_current_launch_hot_path_not_verified"
  } else {
    "gateway_current_launch_hot_path_blocked"
  }

  $blockers = [System.Collections.Generic.List[string]]::new()
  if (-not $gatewayVerified) { [void]$blockers.Add("gateway_current_launch_hot_path_not_verified") }
  if (-not $voucherRuntimeVerified) { [void]$blockers.Add("voucher_internal_runtime_not_verified") }
  if (-not $virtualKeyBounded) { [void]$blockers.Add("virtual_key_distribution_contract_not_verified") }
  if (-not $balanceVerified) { [void]$blockers.Add("remaining_balance_runtime_not_verified") }
  if (-not $rollbackContractVerified) { [void]$blockers.Add("rollback_revoke_contract_not_verified") }

  $productizationGaps = [System.Collections.Generic.List[string]]::new()
  if (-not ($voucherRouteVerified -or $exceptionApproved)) {
    [void]$productizationGaps.Add("public_voucher_route_or_operator_exception_policy_pending")
  } elseif ($exceptionApproved -and -not $voucherRouteVerified) {
    [void]$productizationGaps.Add("public_voucher_route_productization_backlog")
  } elseif ($voucherRouteVerified) {
    [void]$productizationGaps.Add("public_self_serve_ux_productization_pending")
  }
  $perUserExternalInputs = [System.Collections.Generic.List[string]]::new()
  if (-not $perUserOperatorMetadataFilled) {
    [void]$perUserExternalInputs.Add("per_user_operator_metadata_required")
  }

  return [ordered]@{
    schema = "api_distribution_operator_packet.v1"
    overall_status = if ($readyToSend) { "ready" } elseif ($blockers.Count -eq 0) { "per_user_metadata_required" } else { "blocked" }
    ready_to_send = $readyToSend
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    launch_target = "trusted_user_voucher_backed_api_distribution"
    scope = "selected_trusted_user_beta_operator_mediated_only"
    full_commercial_ready = $false
    public_self_serve_ready = $false
    bounded_subject = [ordered]@{
      tenant_id = if ([string]::IsNullOrWhiteSpace($tenantId)) { "to_be_filled_by_operator" } else { $tenantId }
      project_id = if ([string]::IsNullOrWhiteSpace($projectId)) { "to_be_filled_by_operator" } else { $projectId }
      wallet_id = if ([string]::IsNullOrWhiteSpace($walletId)) { "to_be_filled_by_operator" } else { $walletId }
      currency = if ([string]::IsNullOrWhiteSpace($currency)) { "to_be_filled_by_operator" } else { $currency }
    }
    virtual_key_distribution = [ordered]@{
      status = if ($virtualKeyBounded) { "bounded_contract_verified_live_invocation_pending" } else { "blocked" }
      create_route = "POST /admin/virtual-keys"
      list_route = "GET /admin/virtual-keys"
      read_route = "GET /admin/virtual-keys/{id}"
      one_time_secret_only = [bool]$RouteEvidenceArtifact.virtual_key_issue_readback_audit.checks.one_time_secret_return_only
      list_get_never_return_secret = [bool]$RouteEvidenceArtifact.virtual_key_issue_readback_audit.checks.list_get_never_return_secret
      audit_marker_present = [bool]$RouteEvidenceArtifact.virtual_key_issue_readback_audit.checks.create_audit_marker_present
      rbac_scope_present = [bool]$RouteEvidenceArtifact.virtual_key_issue_readback_audit.checks.rbac_key_manage_required
      raw_virtual_key_secret_in_packet = $false
    }
    rollback_revoke_verification = [ordered]@{
      status = $readyToRollbackAfterSend
      rollback_virtual_key_disable_route_present = [bool]$rollbackContract.virtual_key_disable_route_present
      rollback_virtual_key_expire_route_present = [bool]$rollbackContract.virtual_key_expire_route_present
      credit_revoke_or_expire_route_present = [bool]($rollbackContract.credit_grant_revoke_route_present -or $rollbackContract.credit_grant_expire_route_present)
      credit_grant_revoke_route_present = [bool]$rollbackContract.credit_grant_revoke_route_present
      credit_grant_expire_route_present = [bool]$rollbackContract.credit_grant_expire_route_present
      remaining_balance_recheck_present = [bool]$rollbackContract.remaining_balance_recheck_route_present
      audit_readback_route_present = [bool]$rollbackContract.audit_readback_route_present
      bounded_contract_only = $true
      live_invocation = $false
    }
    voucher_quota = [ordered]@{
      status = if ($voucherRouteVerified) { "public_route_verified" } elseif ($exceptionApproved) { "operator_only_exception_approved" } elseif ($voucherRuntimeVerified) { "internal_runtime_verified_productization_gap" } else { "blocked" }
      internal_runtime_verified = $voucherRuntimeVerified
      public_route_verified = $voucherRouteVerified
      operator_only_exception_approved = $exceptionApproved
      voucher_runtime_artifact = ".tmp/credit-wallet/recharge_voucher_runtime.json"
    }
    per_user_packet_requirements = [ordered]@{
      status = "required_before_key_handoff"
      release_owner = "to_be_filled_by_release_owner"
      support_contact = "to_be_filled_by_operator"
      tenant_project_wallet_ids = "confirm_target_subject_before_key_handoff"
      quota_rate_budget_record = ".tmp/launch/trusted_user_quota_rate_budget_record_template.json"
      rollback_owner = "to_be_filled_by_operator"
      secret_scan_record = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1"
    }
    remaining_balance = [ordered]@{
      status = if ($balanceVerified) { "verified" } else { "blocked" }
      artifact = ".tmp/credit-wallet/user_remaining_balance_ownership_runtime.json"
    }
    gateway = [ordered]@{
      status = if ($gatewayVerified) { "verified" } else { "blocked" }
      blocker = $gatewayBlockerCode
      readiness_artifact = ".tmp/launch/voucher_api_distribution_readiness.json"
    }
    rollback_revoke_steps = @(
      "disable or expire issued virtual key through Admin virtual-key route",
      "revoke or expire voucher-backed credit grant/quota through accepted Admin credit surface",
      "rerun remaining-balance readback and audit readback",
      "record support owner and rollback timestamp in bounded ticket"
    )
    support_audit_owner = [ordered]@{
      support_owner = "to_be_filled_by_operator"
      audit_owner = "to_be_filled_by_operator"
      launch_approver = "to_be_filled_by_release_owner"
      escalation_contact = "to_be_filled_by_operator"
      rollback_owner = "to_be_filled_by_operator"
    }
    artifact_links = [ordered]@{
      route_evidence = ".tmp/launch/voucher_public_route_and_virtual_key_evidence.json"
      operator_exception = ".tmp/launch/voucher_operator_only_exception.json"
      readiness = ".tmp/launch/voucher_api_distribution_readiness.json"
      remaining_balance = ".tmp/credit-wallet/user_remaining_balance_ownership_runtime.json"
      voucher_runtime = ".tmp/credit-wallet/recharge_voucher_runtime.json"
    }
    blockers = @($blockers.ToArray())
    per_user_external_inputs = @($perUserExternalInputs.ToArray())
    productization_gaps = @($productizationGaps.ToArray())
    no_secret_outputs = [ordered]@{
      raw_voucher_code = $false
      authorization = $false
      cookie = $false
      db_url = $false
      provider_key = $false
      virtual_key_secret = $false
    }
    secret_safe = $true
    paid_gate_changed = $false
  }
}

if ($SelfTest) {
  $admin = @'
pub(crate) fn router() -> Router<Arc<ControlPlaneState>> {
  Router::new()
    .route("/admin/virtual-keys", get(list_virtual_keys).post(create_virtual_key))
    .route("/admin/virtual-keys/{id}", get(get_virtual_key))
    .route("/admin/virtual-keys/{id}/disable", post(disable_virtual_key))
    .route("/admin/virtual-keys/{id}/expire", post(expire_virtual_key))
    .route("/admin/credit-grants/{credit_grant_id}/revoke", post(revoke_admin_credit_grant))
    .route("/admin/credit-grants/{credit_grant_id}/expire", post(expire_admin_credit_grant))
    .route("/billing/wallets/{wallet_id}/remaining-balance", get(get_billing_wallet_remaining_balance))
    .route("/admin/audit-logs", get(list_audit_logs_admin))
}
async fn create_virtual_key() {
  reject_virtual_key_create_generated_fields(&request)?;
  let generated = generate_virtual_key();
  create_virtual_key_with_default_profile_and_audit(new_virtual_key, |after| new_admin_audit_log(&session, "virtual_key.create", None, after, json!({"secret_once_returned": true}), None));
  virtual_key_response(virtual_key, Some(secret));
}
fn reject_virtual_key_create_generated_fields() { "virtual key secret, secret_hash, and key_prefix are generated by the server"; }
fn list_virtual_keys() { map(|virtual_key| virtual_key_response(virtual_key, None)); }
fn get_virtual_key() { virtual_key_response(virtual_key, None); }
fn virtual_key_response() { secret_once; }
#[derive
'@
  $rbac = 'path == "/admin/virtual-keys" Permission::KeyManage'
  $openapi = "/admin/voucher-issuances:`n/billing/vouchers/redeem:"
  $voucherRuntime = [pscustomobject]@{
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    internal_runtime_function_invoked = $true
    voucher_code_hash_readback_passed = $true
    voucher_code_redacted_output = $true
    raw_secret_markers_present = $false
    raw_voucher_code_echoed = $false
    redeem_idempotency_readback_passed = $true
    audit_readback_passed = $true
    ledger_or_credit_readback_passed = $true
    abuse_refusal_no_write_readback_passed = $true
    secret_safe = $true
    paid_gate_changed = $false
  }
  $readiness = [pscustomobject]@{
    overall_status = "pass_with_productization_gaps"
    voucher_redeem_runtime_verified = $true
    gateway_current_launch_hot_path_verified = $true
    user_remaining_balance_runtime_verified = $true
    paid_gate_changed = $false
  }
  $artifact = New-EvidenceArtifact -AdminText $admin -RbacText $rbac -OpenApiText $openapi -VoucherRuntimeJson $voucherRuntime -ReadinessJson $readiness
  $exception = New-OperatorOnlyExceptionArtifact -RouteEvidenceArtifact $artifact -Approved $false
  $approvedException = New-OperatorOnlyExceptionArtifact -RouteEvidenceArtifact $artifact -Approved $true
  $packet = New-OperatorPacketArtifact `
    -RouteEvidenceArtifact $artifact `
    -ExceptionArtifact $exception `
    -ReadinessArtifact ([ordered]@{ json = [pscustomobject]@{ gateway_current_launch_hot_path_verified = $false; user_remaining_balance_runtime_verified = $true; voucher_redeem_runtime_verified = $true; gateway_current_blocker = "selftest_gateway_blocked" } }) `
    -RemainingBalanceArtifact ([ordered]@{ json = [pscustomobject]@{ tenant_id = "tenant-selftest"; project_id = "project-selftest"; wallet_id = "wallet-selftest"; currency = "USD" } }) `
    -VoucherRuntimeArtifact ([ordered]@{ json = [pscustomobject]@{ tenant_id = "tenant-selftest"; wallet_id = "wallet-selftest"; currency = "USD" } })
  $recoveredPacket = New-OperatorPacketArtifact `
    -RouteEvidenceArtifact $artifact `
    -ExceptionArtifact $exception `
    -ReadinessArtifact ([ordered]@{ json = [pscustomobject]@{ gateway_current_launch_hot_path_verified = $true; user_remaining_balance_runtime_verified = $true; voucher_redeem_runtime_verified = $true; gateway_current_blocker = "" } }) `
    -RemainingBalanceArtifact ([ordered]@{ json = [pscustomobject]@{ tenant_id = "tenant-selftest"; project_id = "project-selftest"; wallet_id = "wallet-selftest"; currency = "USD" } }) `
    -VoucherRuntimeArtifact ([ordered]@{ json = [pscustomobject]@{ tenant_id = "tenant-selftest"; wallet_id = "wallet-selftest"; currency = "USD" } })
  $approvedPacket = New-OperatorPacketArtifact `
    -RouteEvidenceArtifact $artifact `
    -ExceptionArtifact $approvedException `
    -ReadinessArtifact ([ordered]@{ json = [pscustomobject]@{ gateway_current_launch_hot_path_verified = $true; user_remaining_balance_runtime_verified = $true; voucher_redeem_runtime_verified = $true; gateway_current_blocker = "" } }) `
    -RemainingBalanceArtifact ([ordered]@{ json = [pscustomobject]@{ tenant_id = "tenant-selftest"; project_id = "project-selftest"; wallet_id = "wallet-selftest"; currency = "USD" } }) `
    -VoucherRuntimeArtifact ([ordered]@{ json = [pscustomobject]@{ tenant_id = "tenant-selftest"; wallet_id = "wallet-selftest"; currency = "USD" } })
  $unsafeRejected = -not (Test-SecretSafeText "Authorization: Bearer unsafe")
  $status = if (
    $artifact.overall_status -eq "partial" -and
    $artifact.operator_mediated_handoff_evidence.sufficient_for_operator_mediated_handoff -and
    $artifact.implemented_runtime_flags.virtual_key_bounded_route_contract_verified -and
    -not $artifact.implemented_runtime_flags.voucher_public_route_verified -and
    ($artifact.public_route_blockers -contains "voucher_public_control_plane_routes_not_wired") -and
    -not ($artifact.blockers -contains "voucher_public_control_plane_routes_not_wired") -and
    $exception.approved -eq $false -and
    $exception.route_substitution_allowed -eq $false -and
    $approvedException.approved -eq $true -and
    $approvedException.route_substitution_allowed -eq $true -and
    $approvedException.not_a_public_voucher_route_pass -eq $true -and
    $approvedException.voucher_public_routes_wired -eq $false -and
    $approvedException.voucher_route_verified -eq $false -and
    $approvedException.secret_safe -eq $true -and
    $approvedException.paid_gate_changed -eq $false -and
    $packet.ready_to_send -eq $false -and
    $packet.rollback_revoke_verification.status -eq "bounded_contract_ready_live_invocation_pending" -and
    ($packet.productization_gaps -contains "public_voucher_route_or_operator_exception_policy_pending") -and
    ($packet.per_user_external_inputs -contains "per_user_operator_metadata_required") -and
    $recoveredPacket.gateway.status -eq "verified" -and
    [string]::IsNullOrWhiteSpace($recoveredPacket.gateway.blocker) -and
    -not ($recoveredPacket.blockers -contains "gateway_current_launch_hot_path_not_verified") -and
    ($recoveredPacket.productization_gaps -contains "public_voucher_route_or_operator_exception_policy_pending") -and
    ($recoveredPacket.per_user_external_inputs -contains "per_user_operator_metadata_required") -and
    $recoveredPacket.overall_status -eq "per_user_metadata_required" -and
    $approvedPacket.ready_to_send -eq $false -and
    $approvedPacket.voucher_quota.status -eq "operator_only_exception_approved" -and
    ($approvedPacket.productization_gaps -contains "public_voucher_route_productization_backlog") -and
    ($approvedPacket.per_user_external_inputs -contains "per_user_operator_metadata_required") -and
    $approvedPacket.voucher_quota.public_route_verified -eq $false -and
    $unsafeRejected
  ) { "pass" } else { "fail" }
  [ordered]@{
    schema = "voucher_public_route_virtual_key_evidence_selftest.v1"
    status = $status
    operator_mediated_handoff_verified = [bool]$artifact.operator_mediated_handoff_evidence.sufficient_for_operator_mediated_handoff
    virtual_key_bounded_contract_verified = $artifact.implemented_runtime_flags.virtual_key_bounded_route_contract_verified
    voucher_public_route_productization_gap = [bool]($artifact.public_route_blockers -contains "voucher_public_control_plane_routes_not_wired")
    public_route_gap_not_operator_path_blocker = [bool](-not ($artifact.blockers -contains "voucher_public_control_plane_routes_not_wired"))
    unapproved_operator_exception_does_not_pass = [bool](-not $exception.route_substitution_allowed)
    approved_operator_exception_allows_route_substitution_only = [bool](
      $approvedException.route_substitution_allowed -and
      $approvedException.not_a_public_voucher_route_pass -and
      -not $approvedException.voucher_public_routes_wired -and
      -not $approvedException.voucher_route_verified
    )
    operator_packet_waits_for_per_user_metadata = [bool](-not $packet.ready_to_send)
    operator_packet_classifies_per_user_external_input = [bool]($packet.per_user_external_inputs -contains "per_user_operator_metadata_required")
    recovered_gateway_packet_has_no_gateway_blocker = [bool](
      $recoveredPacket.gateway.status -eq "verified" -and
      [string]::IsNullOrWhiteSpace($recoveredPacket.gateway.blocker) -and
      -not ($recoveredPacket.blockers -contains "gateway_current_launch_hot_path_not_verified")
    )
    recovered_gateway_packet_keeps_route_productization_gap = [bool]($recoveredPacket.productization_gaps -contains "public_voucher_route_or_operator_exception_policy_pending")
    approved_packet_keeps_public_route_backlog = [bool]($approvedPacket.productization_gaps -contains "public_voucher_route_productization_backlog")
    rollback_revoke_contract_verified = [bool]($packet.rollback_revoke_verification.status -eq "bounded_contract_ready_live_invocation_pending")
    raw_auth_marker_rejected = $unsafeRejected
    runtime_claimed = $false
    secret_safe = $true
  } | ConvertTo-Json -Depth 8
  if ($status -eq "pass") { exit 0 }
  exit 1
}

$admin = Read-RepoText -Path $AdminSourcePath
$rbac = Read-RepoText -Path $RbacSourcePath
$openapi = Read-RepoText -Path $OpenApiPath
$readinessArtifact = Read-RepoJson -Path $ReadinessArtifactPath
$remainingBalanceArtifact = Read-RepoJson -Path $RemainingBalanceArtifactPath
$voucherRuntimeArtifact = Read-RepoJson -Path $RechargeVoucherRuntimeArtifactPath
$routeLiveProofArtifact = Read-RepoJson -Path $RouteLiveHttpProofPath
$artifact = New-EvidenceArtifact -AdminText $admin.text -RbacText $rbac.text -OpenApiText $openapi.text -VoucherRuntimeJson $voucherRuntimeArtifact.json -ReadinessJson $readinessArtifact.json -RouteLiveProofJson $routeLiveProofArtifact.json
$exceptionArtifact = New-OperatorOnlyExceptionArtifact -RouteEvidenceArtifact $artifact -Approved ([bool]$OperatorExceptionApproved)
$operatorPacketArtifact = New-OperatorPacketArtifact `
  -RouteEvidenceArtifact $artifact `
  -ExceptionArtifact $exceptionArtifact `
  -ReadinessArtifact $readinessArtifact `
  -RemainingBalanceArtifact $remainingBalanceArtifact `
  -VoucherRuntimeArtifact $voucherRuntimeArtifact
$serialized = $artifact | ConvertTo-Json -Depth 12
if (-not (Test-SecretSafeText $serialized)) {
  throw "artifact_secret_safety_check_failed"
}
$exceptionSerialized = $exceptionArtifact | ConvertTo-Json -Depth 12
if (-not (Test-SecretSafeText $exceptionSerialized)) {
  throw "operator_exception_secret_safety_check_failed"
}
$operatorPacketSerialized = $operatorPacketArtifact | ConvertTo-Json -Depth 12
if (-not (Test-SecretSafeText $operatorPacketSerialized)) {
  throw "operator_packet_secret_safety_check_failed"
}

$output = Resolve-RepoBoundedPath -Path $OutputPath -AllowedPrefixes @(".tmp/launch/", "artifacts/")
$outputDirectory = Split-Path -Parent $output.full
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
  New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}
$serialized | Set-Content -LiteralPath $output.full -Encoding UTF8
$exceptionOutput = Resolve-RepoBoundedPath -Path $OperatorExceptionOutputPath -AllowedPrefixes @(".tmp/launch/", "artifacts/")
$exceptionOutputDirectory = Split-Path -Parent $exceptionOutput.full
if (-not [string]::IsNullOrWhiteSpace($exceptionOutputDirectory)) {
  New-Item -ItemType Directory -Force -Path $exceptionOutputDirectory | Out-Null
}
$exceptionSerialized | Set-Content -LiteralPath $exceptionOutput.full -Encoding UTF8
if (-not [string]::IsNullOrWhiteSpace($OperatorPacketOutputPath)) {
  $operatorPacketOutput = Resolve-RepoBoundedPath -Path $OperatorPacketOutputPath -AllowedPrefixes @(".tmp/launch/", "artifacts/")
  $operatorPacketOutputDirectory = Split-Path -Parent $operatorPacketOutput.full
  if (-not [string]::IsNullOrWhiteSpace($operatorPacketOutputDirectory)) {
    New-Item -ItemType Directory -Force -Path $operatorPacketOutputDirectory | Out-Null
  }
  $operatorPacketSerialized | Set-Content -LiteralPath $operatorPacketOutput.full -Encoding UTF8
}
$artifact | ConvertTo-Json -Depth 12
exit 0
