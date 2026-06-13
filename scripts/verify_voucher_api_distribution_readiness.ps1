param(
  [string]$OutputPath = ".tmp\launch\voucher_api_distribution_readiness.json",
  [string]$AdminSourcePath = "apps\control-plane\src\admin.rs",
  [string]$AuthSourcePath = "apps\control-plane\src\auth.rs",
  [string]$RbacSourcePath = "apps\control-plane\src\rbac.rs",
  [string]$OpenApiPath = "examples\openapi_admin_skeleton.yaml",
  [string]$RechargeVoucherRuntimeArtifactPath = ".tmp\credit-wallet\recharge_voucher_runtime.json",
  [string]$UserRemainingBalanceRuntimeArtifactPath = ".tmp\credit-wallet\user_remaining_balance_ownership_runtime.json",
  [string]$GatewayPaidHotPathArtifactPath = ".tmp\paid-beta\e8_gateway_paid_hot_path.json",
  [string]$GatewayCurrentLaunchReadinessArtifactPath = ".tmp\launch\gateway_voucher_distribution_readiness.json",
  [string]$GatewayCurrentPaidHotPathLaunchArtifactPath = ".tmp\launch\e8_gateway_paid_hot_path_launch_check.json",
  [string]$RouteEvidenceArtifactPath = ".tmp\launch\voucher_public_route_and_virtual_key_evidence.json",
  [string]$OperatorExceptionArtifactPath = ".tmp\launch\voucher_operator_only_exception.json",
  [string]$RunbookPath = "docs\PAID_BETA_RUNBOOK.md",
  [string]$ReleaseChecklistPath = "project\RELEASE_CHECKLIST.md",
  [string]$TodoSlicePath = "docs\todo\slices\TODO-32-CREDIT-WALLET.md",
  [switch]$SecretScanPassed,
  [switch]$SkipSecretScan,
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
  $resolved = Resolve-RepoBoundedPath -Path $Path -AllowedPrefixes @("apps/", "examples/", "scripts/", "tests/", "docs/", "project/", "TODO/")
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

function Invoke-LaunchSecretScan {
  if ($SecretScanPassed) {
    return [ordered]@{ passed = $true; exit_code = 0; mode = "preverified_by_caller" }
  }
  if ($SkipSecretScan) {
    return [ordered]@{ passed = $false; exit_code = $null; mode = "skipped" }
  }

  $scanPath = Join-Path $repoRoot "scripts\scan_secrets.ps1"
  if (-not (Test-Path -LiteralPath $scanPath -PathType Leaf)) {
    return [ordered]@{ passed = $false; exit_code = $null; mode = "missing_script" }
  }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $scanPath | Out-Null
  $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  return [ordered]@{ passed = ($exitCode -eq 0); exit_code = $exitCode; mode = "executed" }
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return $true }
  foreach ($pattern in @(
      '(?i)authorization\s*[:=]',
      '(?i)cookie\s*[:=]',
      '(?i)bearer\s+[A-Za-z0-9._~+/\-]+=*',
      '(?i)provider[_-]?key\s*[:=]',
      '(?i)virtual[_-]?key\s*[:=]',
      '(?i)database[_-]?url\s*[:=]',
      '(?i)postgres(?:ql)?://[^"\s]+',
      '(?i)password\s*[:=]',
      '(?i)raw[_-]?voucher[_-]?code\s*[:=]',
      'sk-[A-Za-z0-9]{8,}'
    )) {
    if ($Text -match $pattern) { return $false }
  }
  return $true
}

function Get-JsonBool {
  param([AllowNull()][object]$Json, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Json -or $Json.PSObject.Properties.Name -notcontains $Name) { return $false }
  $value = $Json.PSObject.Properties[$Name].Value
  if ($value -is [bool]) { return [bool]$value }
  return ([string]$value).ToLowerInvariant() -in @("true", "1", "yes", "passed", "pass")
}

function Get-JsonString {
  param([AllowNull()][object]$Json, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Json -or $Json.PSObject.Properties.Name -notcontains $Name) { return "" }
  if ($null -eq $Json.PSObject.Properties[$Name].Value) { return "" }
  return [string]$Json.PSObject.Properties[$Name].Value
}

function Test-RechargeVoucherRuntimeArtifact {
  param([AllowNull()][object]$Artifact)
  if ($null -eq $Artifact) { return $false }
  return [bool](
    (Get-JsonString $Artifact "schema") -eq "recharge_voucher_runtime.v1" -and
    (Get-JsonString $Artifact "overall_status") -eq "pass" -and
    (Get-JsonBool $Artifact "runtime_implemented") -and
    -not (Get-JsonBool $Artifact "contract_only") -and
    ((Get-JsonBool $Artifact "internal_runtime_function_invoked") -or (Get-JsonBool $Artifact "route_invoked")) -and
    (Get-JsonBool $Artifact "voucher_storage_readback_passed") -and
    (Get-JsonBool $Artifact "voucher_code_hash_readback_passed") -and
    (Get-JsonBool $Artifact "voucher_code_redacted_output") -and
    (Get-JsonBool $Artifact "redeem_readback_passed") -and
    (Get-JsonBool $Artifact "redeem_idempotency_readback_passed") -and
    (Get-JsonBool $Artifact "ledger_or_credit_readback_passed") -and
    (Get-JsonBool $Artifact "audit_readback_passed") -and
    (Get-JsonBool $Artifact "secret_safe") -and
    -not (Get-JsonBool $Artifact "paid_gate_changed")
  )
}

function Test-RemainingBalanceRuntimeArtifact {
  param([AllowNull()][object]$Artifact)
  if ($null -eq $Artifact) { return $false }
  return [bool](
    (Get-JsonString $Artifact "schema") -eq "user_remaining_balance_runtime.v1" -and
    (Get-JsonString $Artifact "overall_status") -eq "pass" -and
    (Get-JsonBool $Artifact "runtime_implemented") -and
    (Get-JsonBool $Artifact "route_invoked") -and
    (Get-JsonBool $Artifact "user_api_runtime") -and
    (Get-JsonBool $Artifact "ownership_scope_verified") -and
    (Get-JsonBool $Artifact "read_only") -and
    (Get-JsonBool $Artifact "secret_safe") -and
    -not (Get-JsonBool $Artifact "paid_gate_changed")
  )
}

function Test-GatewayPaidHotPathArtifact {
  param([AllowNull()][object]$Artifact)
  if ($null -eq $Artifact) { return $false }
  $status = Get-JsonString $Artifact "status"
  if ($status -eq "") { $status = Get-JsonString $Artifact "overall_status" }
  $secretSafe = $true
  if ($Artifact.PSObject.Properties.Name -contains "secret_safe") {
    $secretValue = $Artifact.PSObject.Properties["secret_safe"].Value
    if ($secretValue -is [bool]) {
      $secretSafe = [bool]$secretValue
    } elseif ($null -ne $secretValue -and $secretValue.PSObject.Properties.Name -contains "raw_or_secret_marker_present") {
      $secretSafe = -not [bool]$secretValue.raw_or_secret_marker_present
    }
  }
  return [bool]($status -in @("pass", "passed") -and $secretSafe -and -not (Get-JsonBool $Artifact "secret_unsafe"))
}

function Test-LaunchRouteEvidenceArtifact {
  param([AllowNull()][object]$Artifact)
  if ($null -eq $Artifact) { return $false }
  return [bool](
    (Get-JsonString $Artifact "schema") -eq "voucher_public_route_virtual_key_evidence.v1" -and
    (Get-JsonBool $Artifact "secret_safe") -and
    -not (Get-JsonBool $Artifact "paid_gate_changed")
  )
}

function Test-VoucherPublicRouteEvidenceArtifact {
  param([AllowNull()][object]$Artifact)
  if (-not (Test-LaunchRouteEvidenceArtifact $Artifact)) { return $false }
  if ($Artifact.PSObject.Properties.Name -notcontains "voucher_route_evidence") { return $false }
  return [bool](
    (Get-JsonBool $Artifact.voucher_route_evidence "route_verified") -and
    (Get-JsonBool $Artifact.voucher_route_evidence "route_invoked")
  )
}

function Test-VirtualKeyBoundedRouteContractArtifact {
  param([AllowNull()][object]$Artifact)
  if (-not (Test-LaunchRouteEvidenceArtifact $Artifact)) { return $false }
  if ($Artifact.PSObject.Properties.Name -notcontains "virtual_key_issue_readback_audit") { return $false }
  return [bool](Get-JsonBool $Artifact.virtual_key_issue_readback_audit "bounded_db_free_route_contract_verified")
}

function Test-ApprovedOperatorOnlyExceptionArtifact {
  param([AllowNull()][object]$Artifact)
  if ($null -eq $Artifact) { return $false }
  return [bool](
    (Get-JsonString $Artifact "schema") -eq "voucher_operator_only_exception.v1" -and
    (Get-JsonBool $Artifact "approved") -and
    (Get-JsonBool $Artifact "route_substitution_allowed") -and
    (Get-JsonBool $Artifact "secret_safe") -and
    -not (Get-JsonBool $Artifact "paid_gate_changed")
  )
}

function Get-NestedProperty {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string[]]$Path
  )

  $cursor = $Json
  foreach ($name in $Path) {
    if ($null -eq $cursor -or $cursor.PSObject.Properties.Name -notcontains $name) {
      return $null
    }
    $cursor = $cursor.PSObject.Properties[$name].Value
  }
  return $cursor
}

function Get-GatewayCurrentLaunchStatus {
  param(
    [AllowNull()][object]$ReadinessArtifact,
    [AllowNull()][object]$HotPathArtifact
  )

  $historicalPassedFromReadiness = $false
  $readinessCurrent = $null
  $readinessBlocker = ""
  $readinessStatus = ""
  if ($null -ne $ReadinessArtifact) {
    $historicalValue = Get-NestedProperty -Json $ReadinessArtifact -Path @("paid_hot_path_verified", "historical_e8_artifact_passed")
    if ($historicalValue -is [bool]) { $historicalPassedFromReadiness = [bool]$historicalValue }

    $readinessCurrent = Get-NestedProperty -Json $ReadinessArtifact -Path @("paid_hot_path_verified", "current_launch_live_verified")
    $readinessBlockerValue = Get-NestedProperty -Json $ReadinessArtifact -Path @("paid_hot_path_verified", "blocker")
    if ($null -ne $readinessBlockerValue) { $readinessBlocker = [string]$readinessBlockerValue }
    $readinessStatusValue = Get-NestedProperty -Json $ReadinessArtifact -Path @("paid_hot_path_verified", "launch_status")
    if ($null -ne $readinessStatusValue) { $readinessStatus = [string]$readinessStatusValue }
  }

  $hotPathStatus = Get-JsonString $HotPathArtifact "status"
  if ($hotPathStatus -eq "") { $hotPathStatus = Get-JsonString $HotPathArtifact "overall_status" }
  $hotPathBlocker = Get-JsonString $HotPathArtifact "external_blocker"
  if ($hotPathBlocker -eq "") { $hotPathBlocker = Get-JsonString $HotPathArtifact "blocker" }

  $currentVerified = $false
  if ($readinessCurrent -is [bool]) {
    $currentVerified = [bool]$readinessCurrent
  } elseif ($null -ne $HotPathArtifact) {
    $currentVerified = [bool]($hotPathStatus -in @("pass", "passed", "live_completed") -and -not (Get-JsonBool $HotPathArtifact "secret_unsafe"))
  }

  $blocker = ""
  if (-not $currentVerified) {
    if (-not [string]::IsNullOrWhiteSpace($readinessBlocker)) {
      $blocker = $readinessBlocker
    } elseif (-not [string]::IsNullOrWhiteSpace($hotPathBlocker)) {
      $blocker = $hotPathBlocker
    } elseif ($null -eq $ReadinessArtifact -and $null -eq $HotPathArtifact) {
      $blocker = "gateway_current_launch_hot_path_artifact_missing"
    } else {
      $blocker = "gateway_current_launch_hot_path_not_verified"
    }
  }

  return [ordered]@{
    historical_passed_from_readiness = $historicalPassedFromReadiness
    current_verified = $currentVerified
    current_blocker = $blocker
    readiness_launch_status = $readinessStatus
    hot_path_status = $hotPathStatus
  }
}

function New-ReadinessArtifact {
  param(
    [string]$AdminText,
    [string]$AuthText,
    [string]$RbacText,
    [string]$OpenApiText,
    [string]$RunbookText,
    [string]$ReleaseChecklistText,
    [string]$TodoSliceText,
    [AllowNull()][object]$VoucherArtifact,
    [AllowNull()][object]$RemainingBalanceArtifact,
    [AllowNull()][object]$GatewayArtifact,
    [AllowNull()][object]$GatewayCurrentReadinessArtifact,
    [AllowNull()][object]$GatewayCurrentHotPathArtifact,
    [AllowNull()][object]$RouteEvidenceArtifact,
    [AllowNull()][object]$OperatorExceptionArtifact,
    [bool]$SecretScanOk
  )

  $routerText = $AdminText
  if ($AdminText -match '(?s)pub\(crate\)\s+fn\s+router\(\)\s+->\s+Router<Arc<ControlPlaneState>>\s+\{(?<router>.*?)async\s+fn\s+list_api_key_profiles') {
    $routerText = $Matches["router"]
  }

  $adminVirtualKeyRoutes = [ordered]@{
    list = [bool]($routerText -match '(?s)\.route\(\s*"/admin/virtual-keys"[\s\S]*get\(list_virtual_keys\)\.post\(create_virtual_key\)')
    create = [bool]($AdminText -match 'async\s+fn\s+create_virtual_key')
    read = [bool]($routerText -match '\.route\("/admin/virtual-keys/\{id\}",\s*get\(get_virtual_key\)\)')
    disable = [bool]($routerText -match '"/admin/virtual-keys/\{id\}/disable"')
    expire = [bool]($routerText -match '"/admin/virtual-keys/\{id\}/expire"')
    audit_write = [bool]($AdminText -match 'create_virtual_key_with_default_profile_and_audit[\s\S]*"virtual_key\.create"')
    one_time_secret_only = [bool]($AdminText -match 'secret_once_returned')
  }
  $voucherOpenApiRoutes = [ordered]@{
    recharge_intents = [bool]($OpenApiText -match '(?m)^\s*/billing/recharge-intents:')
    voucher_campaigns = [bool]($OpenApiText -match '(?m)^\s*/admin/voucher-campaigns:')
    voucher_issuances = [bool]($OpenApiText -match '(?m)^\s*/admin/voucher-issuances:')
    voucher_redeem = [bool]($OpenApiText -match '(?m)^\s*/billing/vouchers/redeem:')
  }
  $voucherPublicRoutesWired = [bool](
    $routerText -match '"/billing/vouchers/redeem"' -or
    $routerText -match '"/admin/voucher-issuances"' -or
    $routerText -match '"/admin/voucher-campaigns"'
  )
  $remainingBalanceRoute = [bool]($routerText -match '"/billing/wallets/\{wallet_id\}/remaining-balance"' -and $RbacText -match 'wallet_remaining_balance_path')
  $remainingBalanceOwnership = [bool]($AuthText -match 'authenticate_remaining_balance_principal' -and $AuthText -match 'from virtual_keys vk' -and $AuthText -match 'from user_sessions s')
  $auditRoute = [bool]($AdminText -match '"/admin/audit-logs"' -and $RbacText -match 'permission_map_requires_audit_read_for_audit_logs')

  $gatewayVirtualKeyAuth = [bool]($AdminText -match 'virtual_keys' -or $AuthText -match 'from virtual_keys vk')
  $devSeedOrSdkKey = [bool]($RunbookText -match 'virtual key' -or $TodoSliceText -match 'virtual key' -or $ReleaseChecklistText -match 'virtual key')
  $virtualKeyAuthOrSeedAvailable = [bool](($gatewayVirtualKeyAuth -or $devSeedOrSdkKey) -and $adminVirtualKeyRoutes.create -and $adminVirtualKeyRoutes.audit_write)
  $voucherRuntimeAccepted = Test-RechargeVoucherRuntimeArtifact $VoucherArtifact
  $remainingBalanceAccepted = Test-RemainingBalanceRuntimeArtifact $RemainingBalanceArtifact
  $gatewayHistoricalPaidPresent = (Test-GatewayPaidHotPathArtifact $GatewayArtifact)
  $gatewayCurrent = Get-GatewayCurrentLaunchStatus -ReadinessArtifact $GatewayCurrentReadinessArtifact -HotPathArtifact $GatewayCurrentHotPathArtifact
  $gatewayHistoricalPaidPresent = [bool]($gatewayHistoricalPaidPresent -or $gatewayCurrent.historical_passed_from_readiness)
  $gatewayCurrentLaunchVerified = [bool]$gatewayCurrent.current_verified
  $voucherPublicRouteEvidenceAccepted = Test-VoucherPublicRouteEvidenceArtifact $RouteEvidenceArtifact
  $virtualKeyBoundedRouteContractAccepted = Test-VirtualKeyBoundedRouteContractArtifact $RouteEvidenceArtifact
  $operatorOnlyExceptionApproved = Test-ApprovedOperatorOnlyExceptionArtifact $OperatorExceptionArtifact
  $publicRouteEvidencePresent = [bool](
    ($voucherPublicRoutesWired -and $voucherOpenApiRoutes.voucher_redeem -and $voucherPublicRouteEvidenceAccepted) -or
    $operatorOnlyExceptionApproved
  )
  $docsRunbookPresent = [bool](
    $RunbookText -match 'paid' -and
    $ReleaseChecklistText -match 'Voucher-Backed API Beta Distribution' -and
    $TodoSliceText -match 'recharge_voucher_runtime_verified=true'
  )
  $paymentSubscriptionDeferred = [bool](
    $ReleaseChecklistText -match 'deferred external dependencies' -and
    $TodoSliceText -match 'payment_order_invoice_runtime_verified=false' -and
    $TodoSliceText -match 'subscription_package_lifecycle_runtime_verified=false'
  )

  $blockers = [System.Collections.Generic.List[string]]::new()
  if (-not $virtualKeyAuthOrSeedAvailable) { [void]$blockers.Add("virtual_key_auth_or_seed_not_available") }
  if (-not $voucherRuntimeAccepted) { [void]$blockers.Add("voucher_internal_runtime_artifact_missing_or_not_pass") }
  if (-not $remainingBalanceAccepted) { [void]$blockers.Add("user_remaining_balance_runtime_artifact_missing_or_not_pass") }
  if (-not $gatewayCurrentLaunchVerified) { [void]$blockers.Add("gateway_current_launch_hot_path_not_verified") }
  if (-not $SecretScanOk) { [void]$blockers.Add("secret_scan_not_passed_for_launch_gate") }
  if (-not $docsRunbookPresent) { [void]$blockers.Add("docs_runbook_or_launch_checklist_missing") }

  $productizationGaps = [System.Collections.Generic.List[string]]::new()
  if (-not $publicRouteEvidencePresent) { [void]$productizationGaps.Add("public_recharge_voucher_route_evidence_pending") }
  if ($paymentSubscriptionDeferred) {
    [void]$productizationGaps.Add("payment_order_invoice_external_runtime_deferred")
    [void]$productizationGaps.Add("subscription_scheduler_provider_runtime_deferred")
  }

  $overallStatus = "pass"
  if ($blockers.Count -gt 0) {
    $overallStatus = "blocked"
  } elseif ($productizationGaps.Count -gt 0) {
    $overallStatus = "pass_with_productization_gaps"
  }

  return [ordered]@{
    schema = "voucher_api_distribution_launch_gate.v1"
    overall_status = $overallStatus
    qa_verdict = $overallStatus
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    launch_target = "voucher_backed_api_distribution"
    production_distribution_ready = [bool]($overallStatus -in @("pass", "pass_with_productization_gaps") -and $gatewayCurrentLaunchVerified)
    production_distribution_full_ready = [bool]($overallStatus -eq "pass" -and $gatewayCurrentLaunchVerified)
    current_runtime_evidence_precedence = $true
    virtual_key_auth_or_seed_available = $virtualKeyAuthOrSeedAvailable
    gateway_historical_paid_hot_path_verified = $gatewayHistoricalPaidPresent
    gateway_current_launch_hot_path_verified = $gatewayCurrentLaunchVerified
    gateway_current_blocker = $gatewayCurrent.current_blocker
    gateway_live_paid_hot_path_verified = $gatewayCurrentLaunchVerified
    voucher_redeem_runtime_verified = $voucherRuntimeAccepted
    user_remaining_balance_runtime_verified = $remainingBalanceAccepted
    public_route_voucher_evidence_present = $publicRouteEvidencePresent
    operator_only_exception_approved = $operatorOnlyExceptionApproved
    secret_scan_passed = $SecretScanOk
    payment_subscription_external_runtime_deferred = $paymentSubscriptionDeferred
    docs_runbook_present = $docsRunbookPresent
    secret_safe = $true
    paid_gate_changed = $false
    route_map = [ordered]@{
      virtual_key_admin_routes = [ordered]@{
        routes_found = $adminVirtualKeyRoutes
        routes = @(
          "GET /admin/virtual-keys",
          "POST /admin/virtual-keys",
          "GET /admin/virtual-keys/{id}",
          "POST /admin/virtual-keys/{id}/disable",
          "POST /admin/virtual-keys/{id}/expire"
        )
        create_function = "create_virtual_key"
        readback_functions = @("list_virtual_keys", "get_virtual_key")
        audit_function = "create_virtual_key_with_default_profile_and_audit"
      }
      voucher_routes = [ordered]@{
        openapi_contract_found = $voucherOpenApiRoutes
        public_control_plane_routes_wired = $voucherPublicRoutesWired
        internal_runtime_function = "execute_recharge_voucher_internal_runtime_tx"
      }
      remaining_balance_route = [ordered]@{
        route_found = $remainingBalanceRoute
        endpoint = "GET /billing/wallets/{wallet_id}/remaining-balance"
        ownership_resolver_found = $remainingBalanceOwnership
        resolver_function = "authenticate_remaining_balance_principal"
      }
      audit_readback_route = [ordered]@{
        route_found = $auditRoute
        endpoint = "GET /admin/audit-logs"
      }
    }
    readiness = [ordered]@{
      voucher_redeem_route_verified = $false
      voucher_public_route_artifact_verified = $voucherPublicRouteEvidenceAccepted
      voucher_operator_only_exception_approved = $operatorOnlyExceptionApproved
      voucher_internal_runtime_verified = $voucherRuntimeAccepted
      public_route_voucher_evidence_present = $publicRouteEvidencePresent
      virtual_key_issue_route_found = [bool]($adminVirtualKeyRoutes.create -and $adminVirtualKeyRoutes.audit_write)
      virtual_key_issue_route_verified = $false
      virtual_key_issue_bounded_contract_verified = $virtualKeyBoundedRouteContractAccepted
      user_balance_route_verified = $remainingBalanceAccepted
      gateway_paid_hot_path_artifact_present = $gatewayHistoricalPaidPresent
      gateway_historical_paid_hot_path_verified = $gatewayHistoricalPaidPresent
      gateway_current_launch_hot_path_verified = $gatewayCurrentLaunchVerified
      gateway_current_blocker = $gatewayCurrent.current_blocker
      admin_audit_readback_route_found = $auditRoute
      launch_ready_without_payment_provider = [bool]($overallStatus -in @("pass", "pass_with_productization_gaps"))
    }
    artifact_inputs = [ordered]@{
      recharge_voucher_runtime = ".tmp/credit-wallet/recharge_voucher_runtime.json"
      user_remaining_balance_runtime = ".tmp/credit-wallet/user_remaining_balance_ownership_runtime.json"
      gateway_historical_paid_hot_path = ".tmp/paid-beta/e8_gateway_paid_hot_path.json"
      gateway_current_launch_readiness = ".tmp/launch/gateway_voucher_distribution_readiness.json"
      gateway_current_paid_hot_path_launch_check = ".tmp/launch/e8_gateway_paid_hot_path_launch_check.json"
      route_evidence = ".tmp/launch/voucher_public_route_and_virtual_key_evidence.json"
      operator_only_exception = ".tmp/launch/voucher_operator_only_exception.json"
    }
    deferred_external_runtime_items = @(
      "payment_order_invoice_provider_callback_capture",
      "payment_order_invoice_runtime",
      "subscription_scheduler_provider_dunning_runtime",
      "subscription_package_lifecycle_runtime"
    )
    remaining_blockers = @($blockers.ToArray())
    blocker_details = @($(if (-not $gatewayCurrentLaunchVerified) { @([ordered]@{
      id = "gateway_current_launch_hot_path_not_verified"
      blocker = $gatewayCurrent.current_blocker
      resume_condition = "E8-LAUNCH-02 must prove insufficient-balance returns billing 402 and provider_attempt_rows=0, or release owner must document an explicit waiver."
    }) } else { @() }))
    productization_gaps = @($productizationGaps.ToArray())
    resume_conditions = @(
      "public recharge/voucher route invocation evidence with auth/RBAC or ownership scope",
      "or explicit approved operator-only exception artifact for voucher-backed distribution",
      "route-level idempotency, redaction, audit, ledger/credit readbacks, refusal no-write, secret-safe and paid-gate-neutral evidence",
      "payment/order/invoice provider callback/capture or approved bounded internal policy before TODO-32J runtime",
      "subscription scheduler/provider/invoice runtime before TODO-32K runtime"
    )
    no_secret_outputs = [ordered]@{
      raw_voucher_code = $false
      authorization = $false
      cookie = $false
      db_url = $false
      provider_key = $false
      virtual_key_secret = $false
    }
  }
}

if ($SelfTest) {
  $artifact = New-ReadinessArtifact `
    -AdminText '.route("/admin/virtual-keys", get(list_virtual_keys).post(create_virtual_key)) async fn create_virtual_key() {} create_virtual_key_with_default_profile_and_audit "virtual_key.create" secret_once_returned' `
    -AuthText 'authenticate_remaining_balance_principal from virtual_keys vk from user_sessions s' `
    -RbacText 'wallet_remaining_balance_path permission_map_requires_audit_read_for_audit_logs' `
    -OpenApiText "/billing/vouchers/redeem:`n/admin/voucher-issuances:`n/admin/voucher-campaigns:`n/billing/recharge-intents:" `
    -RunbookText "paid beta virtual key runbook" `
    -ReleaseChecklistText "Voucher-Backed API Beta Distribution deferred external dependencies" `
    -TodoSliceText "recharge_voucher_runtime_verified=true payment_order_invoice_runtime_verified=false subscription_package_lifecycle_runtime_verified=false virtual key" `
    -VoucherArtifact ([pscustomobject]@{
      schema = "recharge_voucher_runtime.v1"; overall_status = "pass"; runtime_implemented = $true; contract_only = $false; internal_runtime_function_invoked = $true; voucher_storage_readback_passed = $true; voucher_code_hash_readback_passed = $true; voucher_code_redacted_output = $true; redeem_readback_passed = $true; redeem_idempotency_readback_passed = $true; ledger_or_credit_readback_passed = $true; audit_readback_passed = $true; secret_safe = $true; paid_gate_changed = $false
    }) `
    -RemainingBalanceArtifact ([pscustomobject]@{
      schema = "user_remaining_balance_runtime.v1"; overall_status = "pass"; runtime_implemented = $true; route_invoked = $true; user_api_runtime = $true; ownership_scope_verified = $true; read_only = $true; secret_safe = $true; paid_gate_changed = $false
    }) `
    -GatewayArtifact ([pscustomobject]@{ status = "passed" }) `
    -GatewayCurrentReadinessArtifact ([pscustomobject]@{
      paid_hot_path_verified = [pscustomobject]@{
        historical_e8_artifact_passed = $true
        current_launch_live_verified = $true
        launch_status = "pass"
      }
    }) `
    -GatewayCurrentHotPathArtifact ([pscustomobject]@{ status = "passed" }) `
    -RouteEvidenceArtifact ([pscustomobject]@{
      schema = "voucher_public_route_virtual_key_evidence.v1"
      secret_safe = $true
      paid_gate_changed = $false
      voucher_route_evidence = [pscustomobject]@{ route_verified = $false; route_invoked = $false }
      virtual_key_issue_readback_audit = [pscustomobject]@{ bounded_db_free_route_contract_verified = $true }
    }) `
    -OperatorExceptionArtifact ([pscustomobject]@{
      schema = "voucher_operator_only_exception.v1"; approved = $false; route_substitution_allowed = $false; secret_safe = $true; paid_gate_changed = $false
    }) `
    -SecretScanOk $true
  $blockedCurrentArtifact = New-ReadinessArtifact `
    -AdminText '.route("/admin/virtual-keys", get(list_virtual_keys).post(create_virtual_key)) async fn create_virtual_key() {} create_virtual_key_with_default_profile_and_audit "virtual_key.create" secret_once_returned' `
    -AuthText 'authenticate_remaining_balance_principal from virtual_keys vk from user_sessions s' `
    -RbacText 'wallet_remaining_balance_path permission_map_requires_audit_read_for_audit_logs' `
    -OpenApiText "/billing/vouchers/redeem:`n/admin/voucher-issuances:`n/admin/voucher-campaigns:`n/billing/recharge-intents:" `
    -RunbookText "paid beta virtual key runbook" `
    -ReleaseChecklistText "Voucher-Backed API Beta Distribution deferred external dependencies" `
    -TodoSliceText "recharge_voucher_runtime_verified=true payment_order_invoice_runtime_verified=false subscription_package_lifecycle_runtime_verified=false virtual key" `
    -VoucherArtifact ([pscustomobject]@{
      schema = "recharge_voucher_runtime.v1"; overall_status = "pass"; runtime_implemented = $true; contract_only = $false; internal_runtime_function_invoked = $true; voucher_storage_readback_passed = $true; voucher_code_hash_readback_passed = $true; voucher_code_redacted_output = $true; redeem_readback_passed = $true; redeem_idempotency_readback_passed = $true; ledger_or_credit_readback_passed = $true; audit_readback_passed = $true; secret_safe = $true; paid_gate_changed = $false
    }) `
    -RemainingBalanceArtifact ([pscustomobject]@{
      schema = "user_remaining_balance_runtime.v1"; overall_status = "pass"; runtime_implemented = $true; route_invoked = $true; user_api_runtime = $true; ownership_scope_verified = $true; read_only = $true; secret_safe = $true; paid_gate_changed = $false
    }) `
    -GatewayArtifact ([pscustomobject]@{ status = "passed" }) `
    -GatewayCurrentReadinessArtifact ([pscustomobject]@{
      paid_hot_path_verified = [pscustomobject]@{
        historical_e8_artifact_passed = $true
        current_launch_live_verified = $false
        launch_status = "blocked"
        blocker = "expected HTTP 402, got HTTP 200"
      }
    }) `
    -GatewayCurrentHotPathArtifact ([pscustomobject]@{ status = "blocked"; external_blocker = "expected HTTP 402, got HTTP 200" }) `
    -RouteEvidenceArtifact ([pscustomobject]@{
      schema = "voucher_public_route_virtual_key_evidence.v1"
      secret_safe = $true
      paid_gate_changed = $false
      voucher_route_evidence = [pscustomobject]@{ route_verified = $false; route_invoked = $false }
      virtual_key_issue_readback_audit = [pscustomobject]@{ bounded_db_free_route_contract_verified = $true }
    }) `
    -OperatorExceptionArtifact ([pscustomobject]@{
      schema = "voucher_operator_only_exception.v1"; approved = $false; route_substitution_allowed = $false; secret_safe = $true; paid_gate_changed = $false
    }) `
    -SecretScanOk $true
  $unsafeRejected = -not (Test-SecretSafeText "Authorization: bearer unsafe")
  $cases = @(
    [ordered]@{ name = "voucher_backed_launch_allows_provider_defer_with_productization_gap"; status = if ($artifact.overall_status -eq "pass_with_productization_gaps" -and $artifact.voucher_redeem_runtime_verified -eq $true -and $artifact.public_route_voucher_evidence_present -eq $false) { "pass" } else { "fail" } },
    [ordered]@{ name = "current_gateway_blocker_overrides_historical_paid_artifact"; status = if ($blockedCurrentArtifact.overall_status -eq "blocked" -and $blockedCurrentArtifact.gateway_historical_paid_hot_path_verified -eq $true -and $blockedCurrentArtifact.gateway_current_launch_hot_path_verified -eq $false -and $blockedCurrentArtifact.production_distribution_ready -eq $false) { "pass" } else { "fail" } },
    [ordered]@{ name = "virtual_key_route_found_not_live_verified"; status = if ($artifact.readiness.virtual_key_issue_route_found -eq $true -and $artifact.readiness.virtual_key_issue_route_verified -eq $false) { "pass" } else { "fail" } },
    [ordered]@{ name = "virtual_key_bounded_contract_can_be_recorded_without_live_secret"; status = if ($artifact.readiness.virtual_key_issue_bounded_contract_verified -eq $true -and $artifact.no_secret_outputs.virtual_key_secret -eq $false) { "pass" } else { "fail" } },
    [ordered]@{ name = "unapproved_operator_exception_does_not_pass_route_gap"; status = if ($artifact.operator_only_exception_approved -eq $false -and $artifact.public_route_voucher_evidence_present -eq $false) { "pass" } else { "fail" } },
    [ordered]@{ name = "raw_auth_marker_rejected"; status = if ($unsafeRejected) { "pass" } else { "fail" } },
    [ordered]@{ name = "missing_secret_scan_blocks_launch"; status = if ((New-ReadinessArtifact -AdminText $artifact.route_map.virtual_key_admin_routes.routes[0] -AuthText "" -RbacText "" -OpenApiText "" -RunbookText "" -ReleaseChecklistText "" -TodoSliceText "" -VoucherArtifact $null -RemainingBalanceArtifact $null -GatewayArtifact $null -SecretScanOk $false).overall_status -eq "blocked") { "pass" } else { "fail" } }
  )
  $status = if (@($cases | Where-Object { $_.status -ne "pass" }).Count -eq 0) { "pass" } else { "fail" }
  [ordered]@{
    schema = "voucher_api_distribution_readiness_selftest.v1"
    status = $status
    cases = $cases
    runtime_claimed = $false
    secret_safe = $true
  } | ConvertTo-Json -Depth 8
  if ($status -eq "pass") { exit 0 }
  exit 1
}

$admin = Read-RepoText $AdminSourcePath
$auth = Read-RepoText $AuthSourcePath
$rbac = Read-RepoText $RbacSourcePath
$openapi = Read-RepoText $OpenApiPath
$runbook = Read-RepoText $RunbookPath
$releaseChecklist = Read-RepoText $ReleaseChecklistPath
$todoSlice = Read-RepoText $TodoSlicePath
$voucher = Read-RepoJson $RechargeVoucherRuntimeArtifactPath
$remaining = Read-RepoJson $UserRemainingBalanceRuntimeArtifactPath
$gateway = Read-RepoJson $GatewayPaidHotPathArtifactPath
$gatewayCurrentReadiness = Read-RepoJson $GatewayCurrentLaunchReadinessArtifactPath
$gatewayCurrentHotPath = Read-RepoJson $GatewayCurrentPaidHotPathLaunchArtifactPath
$routeEvidence = Read-RepoJson $RouteEvidenceArtifactPath
$operatorException = Read-RepoJson $OperatorExceptionArtifactPath
$output = Resolve-RepoBoundedPath -Path $OutputPath -AllowedPrefixes @(".tmp/", "artifacts/")
$secretScan = Invoke-LaunchSecretScan

$artifact = New-ReadinessArtifact `
  -AdminText $admin.text `
  -AuthText $auth.text `
  -RbacText $rbac.text `
  -OpenApiText $openapi.text `
  -RunbookText $runbook.text `
  -ReleaseChecklistText $releaseChecklist.text `
  -TodoSliceText $todoSlice.text `
  -VoucherArtifact $voucher.json `
  -RemainingBalanceArtifact $remaining.json `
  -GatewayArtifact $gateway.json `
  -GatewayCurrentReadinessArtifact $gatewayCurrentReadiness.json `
  -GatewayCurrentHotPathArtifact $gatewayCurrentHotPath.json `
  -RouteEvidenceArtifact $routeEvidence.json `
  -OperatorExceptionArtifact $operatorException.json `
  -SecretScanOk ([bool]$secretScan.passed)

$artifact.secret_scan = [ordered]@{
  mode = $secretScan.mode
  exit_code = $secretScan.exit_code
  passed = [bool]$secretScan.passed
}

$outputDirectory = Split-Path -Parent $output.full
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
  New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}
$artifact | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $output.full -Encoding UTF8
$artifact | ConvertTo-Json -Depth 12
exit 0
