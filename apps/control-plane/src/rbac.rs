use std::sync::Arc;

use ai_gateway_auth::{Permission, Role};
use axum::{
    extract::{Request, State},
    http::Method,
    middleware::Next,
    response::{IntoResponse, Response},
};
use serde::Serialize;
use uuid::Uuid;

use crate::{
    ControlPlaneState,
    auth::{AuthError, authenticate_headers, authenticate_remaining_balance_principal},
};

pub(crate) async fn require_admin_rbac(
    State(state): State<Arc<ControlPlaneState>>,
    mut request: Request,
    next: Next,
) -> Response {
    if is_public_admin_path(request.uri().path()) {
        return next.run(request).await;
    }

    let permission = permission_for_admin_request(request.method(), request.uri().path());
    if wallet_remaining_balance_path(request.uri().path()) {
        let admin_session = authenticate_headers(state.as_ref(), request.headers()).await;
        if let Ok(session) = admin_session {
            if session.has_any_role()
                && permission.is_none_or(|permission| {
                    if permission == Permission::KeyManage {
                        control_plane_roles_allow_permission(session.roles(), permission)
                    } else {
                        session.require_permission(permission).is_ok()
                    }
                })
            {
                request.extensions_mut().insert(session);
                return next.run(request).await;
            }
        }

        let Some(wallet_id) = wallet_id_from_remaining_balance_path(request.uri().path()) else {
            return AuthError::forbidden().into_response();
        };
        match authenticate_remaining_balance_principal(state.as_ref(), request.headers(), wallet_id)
            .await
        {
            Ok(principal) => {
                request.extensions_mut().insert(principal);
                return next.run(request).await;
            }
            Err(error) => return error.into_response(),
        }
    }

    let session = match authenticate_headers(state.as_ref(), request.headers()).await {
        Ok(session) => session,
        Err(error) => return error.into_response(),
    };

    if !session.has_any_role() {
        return AuthError::forbidden().into_response();
    }
    if let Some(permission) = permission {
        let allowed = if permission == Permission::KeyManage {
            control_plane_roles_allow_permission(session.roles(), permission)
        } else {
            session.require_permission(permission).is_ok()
        };
        if !allowed {
            return AuthError::forbidden().into_response();
        }
    }

    request.extensions_mut().insert(session);
    next.run(request).await
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub(crate) struct ControlPlaneCapability {
    key: &'static str,
    method: &'static str,
    path: &'static str,
    required_permission: Option<Permission>,
    credential_sensitive_read: bool,
    secret_safe: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct ControlPlaneCapabilitySummary {
    roles: Vec<&'static str>,
    personas: Vec<&'static str>,
    #[serde(rename = "capabilities")]
    allowed: Vec<&'static str>,
    #[serde(rename = "denied_capabilities")]
    denied: Vec<&'static str>,
    secret_safe: bool,
}

pub(crate) const CONTROL_PLANE_CAPABILITIES: [ControlPlaneCapability; 48] = [
    ControlPlaneCapability {
        key: "provider.read",
        method: "GET",
        path: "/admin/providers",
        required_permission: Some(Permission::ProviderManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "provider.manage",
        method: "PATCH",
        path: "/admin/providers/{id}",
        required_permission: Some(Permission::ProviderManage),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "key.read",
        method: "GET",
        path: "/admin/provider-keys",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "key.manage",
        method: "POST",
        path: "/admin/provider-keys",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "user.manage.read",
        method: "GET",
        path: "/admin/users",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "user.status.manage",
        method: "PATCH",
        path: "/admin/users/{id}/status",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "enterprise_identity.read",
        method: "GET",
        path: "/admin/enterprise/identity-connections",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "enterprise_identity.validation_plan",
        method: "GET",
        path: "/admin/enterprise/identity-connections/validation-plan",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "enterprise_identity.oidc_validate_code_plan",
        method: "POST",
        path: "/admin/enterprise/identity-connections/oidc/validate-code-plan",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "enterprise_identity.oidc_execute_validated_login",
        method: "POST",
        path: "/admin/enterprise/identity-connections/oidc/execute-validated-login",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "enterprise_identity.saml_validate_acs_plan",
        method: "POST",
        path: "/admin/enterprise/identity-connections/saml/validate-acs-plan",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "enterprise_identity.saml_execute_validated_acs",
        method: "POST",
        path: "/admin/enterprise/identity-connections/saml/execute-validated-acs",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "enterprise_identity.binding_plan",
        method: "POST",
        path: "/admin/enterprise/identity-bindings/plan",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "enterprise_identity.session_issue_plan",
        method: "POST",
        path: "/admin/enterprise/identity-sessions/issue-plan",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "enterprise_accounts.read",
        method: "GET",
        path: "/admin/enterprise/accounts",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "enterprise_sales_dashboard.read",
        method: "GET",
        path: "/admin/enterprise/sales-dashboard",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "enterprise_accounts.write",
        method: "PATCH",
        path: "/admin/enterprise/accounts",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "provider_key.recovery",
        method: "POST",
        path: "/admin/provider-keys/{id}/recovery",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "provider_key.rotate",
        method: "POST",
        path: "/admin/provider-keys/{id}/rotate",
        required_permission: Some(Permission::KeyManage),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "request_log.read",
        method: "GET",
        path: "/admin/request-logs",
        required_permission: Some(Permission::LogReadMetadata),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "request_log.payload_preview",
        method: "GET",
        path: "/admin/request-logs/{id}/payload",
        required_permission: Some(Permission::LogReadMetadata),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "trace.read",
        method: "GET",
        path: "/admin/traces/{trace_id}",
        required_permission: Some(Permission::LogReadMetadata),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "audit.read",
        method: "GET",
        path: "/admin/audit-logs",
        required_permission: Some(Permission::AuditRead),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "billing.read",
        method: "GET",
        path: "/admin/ledger/entries",
        required_permission: Some(Permission::BillingRead),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "price.read",
        method: "GET",
        path: "/admin/price-versions",
        required_permission: Some(Permission::BillingRead),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "reconciliation.read",
        method: "GET",
        path: "/admin/billing/reconciliation",
        required_permission: Some(Permission::BillingRead),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "credit_grant.read",
        method: "GET",
        path: "/admin/credit-grants",
        required_permission: Some(Permission::BillingRead),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "credit_grant.read_detail",
        method: "GET",
        path: "/admin/credit-grants/{id}",
        required_permission: Some(Permission::BillingRead),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "wallet.remaining_balance.read",
        method: "GET",
        path: "/billing/wallets/{id}/remaining-balance",
        required_permission: Some(Permission::BillingRead),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "price_version.create",
        method: "POST",
        path: "/admin/price-versions",
        required_permission: Some(Permission::BillingAdjust),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "credit_grant.create",
        method: "POST",
        path: "/admin/credit-grants",
        required_permission: Some(Permission::BillingAdjust),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "credit_grant.expire",
        method: "POST",
        path: "/admin/credit-grants/{id}/expire",
        required_permission: Some(Permission::BillingAdjust),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "credit_grant.revoke",
        method: "POST",
        path: "/admin/credit-grants/{id}/revoke",
        required_permission: Some(Permission::BillingAdjust),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "voucher.read",
        method: "GET",
        path: "/admin/voucher-issuances",
        required_permission: Some(Permission::BillingRead),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "voucher.issue",
        method: "POST",
        path: "/admin/voucher-issuances",
        required_permission: Some(Permission::BillingAdjust),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "voucher.revoke",
        method: "POST",
        path: "/admin/voucher-issuances/{id}/revoke",
        required_permission: Some(Permission::BillingAdjust),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "voucher.issue_batch",
        method: "POST",
        path: "/admin/voucher-issuance-batches",
        required_permission: Some(Permission::BillingAdjust),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "voucher.batch_read",
        method: "GET",
        path: "/admin/voucher-issuance-batches/{batch_hash}",
        required_permission: Some(Permission::BillingRead),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "voucher.batch_revoke",
        method: "POST",
        path: "/admin/voucher-issuance-batches/{batch_hash}/revoke",
        required_permission: Some(Permission::BillingAdjust),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "voucher.redeem",
        method: "POST",
        path: "/billing/vouchers/redeem",
        required_permission: Some(Permission::BillingAdjust),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "ledger_adjustment.dry_run",
        method: "POST",
        path: "/admin/ledger/adjustments/dry-run",
        required_permission: Some(Permission::BillingAdjust),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "manual_test.run",
        method: "POST",
        path: "/admin/channels/{id}/manual-test",
        required_permission: Some(Permission::ProviderManage),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "provider_health.read",
        method: "GET",
        path: "/admin/providers/health-summary",
        required_permission: Some(Permission::ProviderManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "distribution_readiness.read",
        method: "GET",
        path: "/admin/distribution/readiness",
        required_permission: Some(Permission::ProviderManage),
        credential_sensitive_read: true,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "alert_webhook.validate",
        method: "POST",
        path: "/admin/alerts/webhook/dry-run",
        required_permission: Some(Permission::ProviderManage),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "prompt_eval_shadow.validate",
        method: "POST",
        path: "/admin/prompt-eval-shadow/dry-run",
        required_permission: Some(Permission::ProviderManage),
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "health.liveness",
        method: "GET",
        path: "/healthz",
        required_permission: None,
        credential_sensitive_read: false,
        secret_safe: true,
    },
    ControlPlaneCapability {
        key: "health.readiness",
        method: "GET",
        path: "/readyz",
        required_permission: None,
        credential_sensitive_read: false,
        secret_safe: true,
    },
];

pub(crate) fn control_plane_roles_allow_permission(roles: &[Role], permission: Permission) -> bool {
    !roles.is_empty()
        && roles
            .iter()
            .any(|role| role_allows_control_plane_permission(*role, permission))
}

pub(crate) const fn role_allows_control_plane_permission(
    role: Role,
    permission: Permission,
) -> bool {
    match permission {
        Permission::KeyManage => matches!(role, Role::Owner | Role::Admin | Role::Ops),
        _ => role.allows(permission),
    }
}

pub(crate) const fn role_persona(role: Role) -> &'static str {
    match role {
        Role::Owner => "SuperAdmin",
        Role::Admin => "TenantAdmin",
        Role::Ops => "Ops",
        Role::Billing => "Billing",
        Role::Developer => "Developer",
        Role::Viewer => "Viewer",
    }
}

pub(crate) fn capability_allowed_for_roles(
    roles: &[Role],
    capability: &ControlPlaneCapability,
) -> bool {
    match capability.required_permission {
        Some(permission) => control_plane_roles_allow_permission(roles, permission),
        None => true,
    }
}

pub(crate) fn capability_summary_for_roles(roles: &[Role]) -> ControlPlaneCapabilitySummary {
    let mut role_names = Vec::with_capacity(roles.len());
    let mut personas = Vec::with_capacity(roles.len());
    for role in roles {
        role_names.push(role.as_str());
        personas.push(role_persona(*role));
    }

    let mut allowed = Vec::new();
    let mut denied = Vec::new();
    for capability in CONTROL_PLANE_CAPABILITIES {
        if capability_allowed_for_roles(roles, &capability) {
            allowed.push(capability.key);
        } else {
            denied.push(capability.key);
        }
    }

    ControlPlaneCapabilitySummary {
        roles: role_names,
        personas,
        allowed,
        denied,
        secret_safe: true,
    }
}

pub(crate) fn permission_for_admin_request(method: &Method, path: &str) -> Option<Permission> {
    if request_logs_path(path) {
        return Some(Permission::LogReadMetadata);
    }
    if audit_logs_path(path) {
        return Some(Permission::AuditRead);
    }
    if billing_adjust_path(method, path) {
        return Some(Permission::BillingAdjust);
    }
    if billing_read_path(path) {
        return Some(Permission::BillingRead);
    }

    if alert_webhook_path(path) {
        return Some(Permission::ProviderManage);
    }
    if prompt_eval_shadow_path(path) {
        return Some(Permission::ProviderManage);
    }
    if provider_manage_path(path) {
        return Some(Permission::ProviderManage);
    }
    if key_manage_path(path) {
        return Some(Permission::KeyManage);
    }
    if user_manage_path(path) {
        return Some(Permission::KeyManage);
    }

    None
}

fn is_public_admin_path(path: &str) -> bool {
    matches!(
        path,
        "/admin/auth/login" | "/admin/auth/logout" | "/admin/auth/me" | "/healthz" | "/readyz"
    )
}

fn request_logs_path(path: &str) -> bool {
    path == "/admin/request-logs"
        || path.starts_with("/admin/request-logs/")
        || path.starts_with("/admin/traces/")
}

fn audit_logs_path(path: &str) -> bool {
    path == "/admin/audit-logs"
}

fn billing_read_path(path: &str) -> bool {
    path == "/admin/billing/reconciliation"
        || path == "/admin/price-versions"
        || path == "/admin/ledger/entries"
        || path == "/admin/credit-grants"
        || path == "/admin/voucher-issuances"
        || path == "/admin/subscriptions/scheduler-worker"
        || path == "/admin/subscriptions/run-due-scheduler-events"
        || subscription_scheduler_event_execute_path(path)
        || voucher_batch_read_detail_path(path)
        || credit_grant_read_detail_path(path)
        || wallet_remaining_balance_path(path)
}

fn billing_adjust_path(method: &Method, path: &str) -> bool {
    *method == Method::POST
        && matches!(
            path,
            "/admin/price-versions"
                | "/admin/credit-grants"
                | "/admin/voucher-issuances"
                | "/admin/voucher-issuance-batches"
                | "/admin/ledger/adjustments/dry-run"
                | "/admin/subscriptions/scheduler-plan"
                | "/billing/vouchers/redeem"
                | "/billing/opening-balance-imports"
        )
        || (*method == Method::POST && subscription_scheduler_event_lease_path(path))
        || (*method == Method::POST && subscription_scheduler_event_execute_path(path))
        || (*method == Method::POST
            && (credit_grant_lifecycle_write_path(path) || voucher_lifecycle_write_path(path)))
}

fn subscription_scheduler_event_execute_path(path: &str) -> bool {
    path.starts_with("/admin/subscriptions/scheduler-events/") && path.ends_with("/execute-plan")
}

fn subscription_scheduler_event_lease_path(path: &str) -> bool {
    path.starts_with("/admin/subscriptions/scheduler-events/") && path.ends_with("/lease")
}

fn credit_grant_read_detail_path(path: &str) -> bool {
    path.starts_with("/admin/credit-grants/")
        && !path.ends_with("/expire")
        && !path.ends_with("/revoke")
}

fn credit_grant_lifecycle_write_path(path: &str) -> bool {
    path.starts_with("/admin/credit-grants/")
        && (path.ends_with("/expire") || path.ends_with("/revoke"))
}

fn voucher_lifecycle_write_path(path: &str) -> bool {
    (path.starts_with("/admin/voucher-issuances/") && path.ends_with("/revoke"))
        || (path.starts_with("/admin/voucher-issuance-batches/") && path.ends_with("/revoke"))
}

fn voucher_batch_read_detail_path(path: &str) -> bool {
    path.starts_with("/admin/voucher-issuance-batches/") && !path.ends_with("/revoke")
}

fn wallet_remaining_balance_path(path: &str) -> bool {
    path.starts_with("/billing/wallets/") && path.ends_with("/remaining-balance")
}

fn wallet_id_from_remaining_balance_path(path: &str) -> Option<Uuid> {
    let value = path
        .strip_prefix("/billing/wallets/")?
        .strip_suffix("/remaining-balance")?
        .trim_matches('/');
    Uuid::parse_str(value).ok()
}

fn alert_webhook_path(path: &str) -> bool {
    path == "/admin/alerts/webhook/dry-run"
}

fn prompt_eval_shadow_path(path: &str) -> bool {
    path == "/admin/prompt-eval-shadow/dry-run"
}

fn provider_manage_path(path: &str) -> bool {
    path == "/admin/distribution/readiness"
        || path == "/admin/providers"
        || path.starts_with("/admin/providers/")
        || path == "/admin/channels"
        || path.starts_with("/admin/channels/")
        || path == "/admin/models"
        || path.starts_with("/admin/models/")
        || path == "/admin/model-associations"
        || path.starts_with("/admin/model-associations/")
}

fn key_manage_path(path: &str) -> bool {
    path == "/admin/provider-keys"
        || path.starts_with("/admin/provider-keys/")
        || path == "/admin/enterprise/identity-connections"
        || path == "/admin/enterprise/identity-connections/validation-plan"
        || path == "/admin/enterprise/identity-connections/oidc/validate-code-plan"
        || path == "/admin/enterprise/identity-connections/oidc/execute-validated-login"
        || path == "/admin/enterprise/identity-connections/saml/validate-acs-plan"
        || path == "/admin/enterprise/identity-connections/saml/execute-validated-acs"
        || path == "/admin/enterprise/identity-bindings/plan"
        || path == "/admin/enterprise/identity-sessions/issue-plan"
        || path == "/admin/enterprise/accounts"
        || path == "/admin/enterprise/sales-dashboard"
        || path == "/admin/settings/network-security"
        || path == "/admin/api-key-profiles"
        || path.starts_with("/admin/api-key-profiles/")
        || path == "/admin/virtual-keys"
        || path.starts_with("/admin/virtual-keys/")
}

fn user_manage_path(path: &str) -> bool {
    path == "/admin/users" || path.starts_with("/admin/users/")
}

#[cfg(test)]
mod tests {
    use super::*;
    use ai_gateway_auth::Role;
    use serde_json::{Value, json};

    fn role_allows_admin_request(role: Role, method: &Method, path: &str) -> bool {
        match permission_for_admin_request(method, path) {
            Some(permission) => role_allows_control_plane_permission(role, permission),
            None => true,
        }
    }

    fn role_names_for_capability(capability: &ControlPlaneCapability) -> Vec<String> {
        Role::ALL
            .iter()
            .copied()
            .filter(|role| capability_allowed_for_roles(&[*role], capability))
            .map(|role| role.as_str().to_string())
            .collect()
    }

    fn json_string_array(value: &Value) -> Vec<String> {
        value
            .as_array()
            .expect("value should be an array")
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .expect("array values should be strings")
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn permission_map_requires_manage_for_admin_writes() {
        assert_eq!(
            permission_for_admin_request(&Method::POST, "/admin/providers"),
            Some(Permission::ProviderManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::PATCH,
                "/admin/channels/00000000-0000-0000-0000-000000000001"
            ),
            Some(Permission::ProviderManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::DELETE,
                "/admin/models/00000000-0000-0000-0000-000000000001"
            ),
            Some(Permission::ProviderManage)
        );
        assert_eq!(
            permission_for_admin_request(&Method::POST, "/admin/provider-keys"),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::POST,
                "/admin/provider-keys/00000000-0000-0000-0000-000000000001/recovery"
            ),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::POST,
                "/admin/provider-keys/00000000-0000-0000-0000-000000000001/rotate"
            ),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::PATCH,
                "/admin/api-key-profiles/00000000-0000-0000-0000-000000000001"
            ),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::POST,
                "/admin/virtual-keys/00000000-0000-0000-0000-000000000001/disable"
            ),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(&Method::POST, "/admin/price-versions"),
            Some(Permission::BillingAdjust)
        );
    }

    #[test]
    fn provider_key_recovery_requires_key_manage_rbac() {
        let path = "/admin/provider-keys/00000000-0000-0000-0000-000000000001/recovery";

        assert_eq!(
            permission_for_admin_request(&Method::POST, path),
            Some(Permission::KeyManage)
        );
        assert!(!role_allows_admin_request(
            Role::Viewer,
            &Method::POST,
            path
        ));
        assert!(!role_allows_admin_request(
            Role::Developer,
            &Method::POST,
            path
        ));
        assert!(!role_allows_admin_request(
            Role::Billing,
            &Method::POST,
            path
        ));
        assert!(role_allows_admin_request(Role::Ops, &Method::POST, path));
        assert!(role_allows_admin_request(Role::Admin, &Method::POST, path));
        assert!(role_allows_admin_request(Role::Owner, &Method::POST, path));
    }

    #[test]
    fn provider_key_rotate_requires_key_manage_rbac() {
        let path = "/admin/provider-keys/00000000-0000-0000-0000-000000000001/rotate";

        assert_eq!(
            permission_for_admin_request(&Method::POST, path),
            Some(Permission::KeyManage)
        );
        assert!(!role_allows_admin_request(
            Role::Viewer,
            &Method::POST,
            path
        ));
        assert!(!role_allows_admin_request(
            Role::Developer,
            &Method::POST,
            path
        ));
        assert!(role_allows_admin_request(Role::Ops, &Method::POST, path));
        assert!(role_allows_admin_request(Role::Admin, &Method::POST, path));
        assert!(role_allows_admin_request(Role::Owner, &Method::POST, path));
    }

    #[test]
    fn permission_map_requires_manage_for_admin_reads() {
        assert_eq!(
            permission_for_admin_request(&Method::GET, "/admin/providers"),
            Some(Permission::ProviderManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::HEAD,
                "/admin/models/00000000-0000-0000-0000-000000000001"
            ),
            Some(Permission::ProviderManage)
        );
        assert_eq!(
            permission_for_admin_request(&Method::OPTIONS, "/admin/model-associations"),
            Some(Permission::ProviderManage)
        );
        assert_eq!(
            permission_for_admin_request(&Method::GET, "/admin/provider-keys"),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(&Method::GET, "/admin/enterprise/identity-connections"),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::GET,
                "/admin/enterprise/identity-connections/validation-plan"
            ),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::POST,
                "/admin/enterprise/identity-connections/oidc/validate-code-plan"
            ),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::POST,
                "/admin/enterprise/identity-connections/oidc/execute-validated-login"
            ),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::POST,
                "/admin/enterprise/identity-connections/saml/validate-acs-plan"
            ),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::POST,
                "/admin/enterprise/identity-connections/saml/execute-validated-acs"
            ),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(&Method::POST, "/admin/enterprise/identity-bindings/plan"),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::POST,
                "/admin/enterprise/identity-sessions/issue-plan"
            ),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(&Method::GET, "/admin/enterprise/accounts"),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(&Method::PATCH, "/admin/enterprise/accounts"),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::HEAD,
                "/admin/api-key-profiles/00000000-0000-0000-0000-000000000001"
            ),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(&Method::OPTIONS, "/admin/virtual-keys"),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(&Method::GET, "/admin/users"),
            Some(Permission::KeyManage)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::PATCH,
                "/admin/users/00000000-0000-0000-0000-000000000001/status"
            ),
            Some(Permission::KeyManage)
        );
    }

    #[test]
    fn key_and_user_management_reject_viewer_and_allow_manager_and_admin() {
        let paths = [
            "/admin/provider-keys",
            "/admin/provider-keys/00000000-0000-0000-0000-000000000001",
            "/admin/enterprise/identity-connections",
            "/admin/enterprise/identity-connections/validation-plan",
            "/admin/enterprise/identity-connections/oidc/validate-code-plan",
            "/admin/enterprise/identity-connections/oidc/execute-validated-login",
            "/admin/enterprise/identity-connections/saml/validate-acs-plan",
            "/admin/enterprise/identity-connections/saml/execute-validated-acs",
            "/admin/enterprise/identity-bindings/plan",
            "/admin/enterprise/identity-sessions/issue-plan",
            "/admin/enterprise/accounts",
            "/admin/api-key-profiles",
            "/admin/api-key-profiles/00000000-0000-0000-0000-000000000001",
            "/admin/virtual-keys",
            "/admin/virtual-keys/00000000-0000-0000-0000-000000000001",
            "/admin/users",
            "/admin/users/00000000-0000-0000-0000-000000000001/status",
        ];
        let methods = [Method::GET, Method::HEAD, Method::OPTIONS];

        for method in methods {
            for path in paths {
                assert_eq!(
                    permission_for_admin_request(&method, path),
                    Some(Permission::KeyManage),
                    "{method} {path}"
                );
                assert!(
                    !role_allows_admin_request(Role::Viewer, &method, path),
                    "viewer unexpectedly allowed {method} {path}"
                );
                assert!(
                    !role_allows_admin_request(Role::Developer, &method, path),
                    "developer unexpectedly allowed {method} {path}"
                );
                assert!(
                    role_allows_admin_request(Role::Ops, &method, path),
                    "manager unexpectedly denied {method} {path}"
                );
                assert!(
                    role_allows_admin_request(Role::Admin, &method, path),
                    "admin unexpectedly denied {method} {path}"
                );
            }
        }
    }

    #[test]
    fn control_plane_key_manage_is_stricter_than_shared_auth_role() {
        assert!(Role::Developer.allows(Permission::KeyManage));
        assert!(!role_allows_control_plane_permission(
            Role::Developer,
            Permission::KeyManage
        ));
        assert!(role_allows_control_plane_permission(
            Role::Owner,
            Permission::KeyManage
        ));
        assert!(role_allows_control_plane_permission(
            Role::Admin,
            Permission::KeyManage
        ));
        assert!(role_allows_control_plane_permission(
            Role::Ops,
            Permission::KeyManage
        ));
    }

    #[test]
    fn rbac_acceptance_matrix_covers_control_plane_roles_and_surfaces() {
        for capability in CONTROL_PLANE_CAPABILITIES {
            let method = Method::from_bytes(capability.method.as_bytes())
                .expect("capability method should be valid HTTP");
            assert_eq!(
                permission_for_admin_request(&method, capability.path),
                capability.required_permission,
                "{} {}",
                capability.method,
                capability.path
            );
            assert!(
                capability.secret_safe,
                "{} must stay secret-safe",
                capability.key
            );
        }

        let provider_allowed = role_names_for_capability(
            CONTROL_PLANE_CAPABILITIES
                .iter()
                .find(|capability| capability.key == "provider.manage")
                .expect("provider manage capability should exist"),
        );
        assert_eq!(provider_allowed, vec!["owner", "admin", "ops"]);

        let key_allowed = role_names_for_capability(
            CONTROL_PLANE_CAPABILITIES
                .iter()
                .find(|capability| capability.key == "key.manage")
                .expect("key manage capability should exist"),
        );
        assert_eq!(key_allowed, vec!["owner", "admin", "ops"]);

        let billing_adjust_allowed = role_names_for_capability(
            CONTROL_PLANE_CAPABILITIES
                .iter()
                .find(|capability| capability.key == "price_version.create")
                .expect("price version create capability should exist"),
        );
        assert_eq!(billing_adjust_allowed, vec!["owner", "billing"]);
        let ledger_adjustment_allowed = role_names_for_capability(
            CONTROL_PLANE_CAPABILITIES
                .iter()
                .find(|capability| capability.key == "ledger_adjustment.dry_run")
                .expect("ledger adjustment dry-run capability should exist"),
        );
        assert_eq!(ledger_adjustment_allowed, vec!["owner", "billing"]);

        for capability in CONTROL_PLANE_CAPABILITIES
            .iter()
            .filter(|capability| capability.credential_sensitive_read)
        {
            assert!(
                !capability_allowed_for_roles(&[Role::Viewer], capability),
                "viewer unexpectedly received credential-sensitive read {}",
                capability.key
            );
        }
    }

    #[test]
    fn rbac_capability_summary_is_secret_safe() {
        let viewer = capability_summary_for_roles(&[Role::Viewer]);
        assert_eq!(viewer.roles, vec!["viewer"]);
        assert_eq!(viewer.personas, vec!["Viewer"]);
        assert!(viewer.secret_safe);
        assert!(viewer.allowed.contains(&"request_log.read"));
        assert!(viewer.allowed.contains(&"audit.read"));
        assert!(viewer.allowed.contains(&"billing.read"));
        assert!(viewer.denied.contains(&"provider.read"));
        assert!(viewer.denied.contains(&"key.read"));
        assert!(viewer.denied.contains(&"price_version.create"));
        assert!(viewer.denied.contains(&"ledger_adjustment.dry_run"));

        let owner = capability_summary_for_roles(&[Role::Owner]);
        assert_eq!(owner.roles, vec!["owner"]);
        assert_eq!(owner.personas, vec!["SuperAdmin"]);
        assert_eq!(owner.denied, Vec::<&'static str>::new());

        let serialized = serde_json::to_value(viewer).expect("summary should serialize");
        assert!(serialized["capabilities"].as_array().is_some());
        assert!(serialized["denied_capabilities"].as_array().is_some());
        assert!(serialized.get("allowed").is_none());
        assert!(serialized.get("denied").is_none());
    }

    #[test]
    fn rbac_matrix_contract_fixture_matches_control_plane_policy() {
        let fixture = serde_json::from_str::<Value>(include_str!(
            "../../../tests/fixtures/control-plane/rbac_matrix_contract.json"
        ))
        .expect("fixture should be valid json");
        let serialized = serde_json::to_string(&fixture).expect("fixture should serialize");

        assert_eq!(fixture["summary_contract"]["backend_only"], json!(false));
        assert_eq!(fixture["summary_contract"]["secret_safe"], json!(true));
        assert_eq!(
            fixture["summary_contract"]["auth_me_response_includes_capabilities"],
            json!(true)
        );
        assert_eq!(fixture["role_mapping"]["SuperAdmin"], json!("owner"));
        assert_eq!(fixture["role_mapping"]["TenantAdmin"], json!("admin"));

        let capabilities = fixture["capabilities"]
            .as_array()
            .expect("capabilities should be an array");
        assert_eq!(capabilities.len(), CONTROL_PLANE_CAPABILITIES.len());

        for capability in CONTROL_PLANE_CAPABILITIES {
            let fixture_capability = capabilities
                .iter()
                .find(|fixture_capability| {
                    fixture_capability["key"]
                        .as_str()
                        .is_some_and(|key| key == capability.key)
                })
                .expect("fixture capability should exist");
            let required_permission = capability
                .required_permission
                .map(|permission| json!(permission.as_str()))
                .unwrap_or(Value::Null);
            let allowed_roles = role_names_for_capability(&capability);
            let denied_roles = Role::ALL
                .iter()
                .copied()
                .map(|role| role.as_str().to_string())
                .filter(|role| !allowed_roles.contains(role))
                .collect::<Vec<_>>();

            assert_eq!(fixture_capability["method"], json!(capability.method));
            assert_eq!(fixture_capability["path"], json!(capability.path));
            assert_eq!(
                fixture_capability["required_permission"], required_permission,
                "{}",
                capability.key
            );
            assert_eq!(
                json_string_array(&fixture_capability["allowed_roles"]),
                allowed_roles,
                "{}",
                capability.key
            );
            assert_eq!(
                json_string_array(&fixture_capability["denied_roles"]),
                denied_roles,
                "{}",
                capability.key
            );
            assert_eq!(
                fixture_capability["credential_sensitive_read"],
                json!(capability.credential_sensitive_read),
                "{}",
                capability.key
            );
            assert_eq!(
                fixture_capability["secret_safe"],
                json!(capability.secret_safe),
                "{}",
                capability.key
            );
        }

        for forbidden in [
            "sk-",
            "api_key",
            "encrypted_secret",
            "secret_fingerprint",
            "secret_hash",
            "private_key",
            "request_body",
            "response_body",
            "raw_key",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "rbac matrix fixture must not contain {forbidden}"
            );
        }
    }

    #[test]
    fn rbac_capability_summary_is_documented_in_openapi_extension() {
        let openapi = include_str!("../../../examples/openapi_admin_skeleton.yaml");

        assert!(openapi.contains("x-control-plane-rbac-capability-summary:"));
        assert!(
            openapi.contains("fixture: tests/fixtures/control-plane/rbac_matrix_contract.json")
        );
        assert!(openapi.contains("auth_me_response_includes_capabilities: true"));
        assert!(openapi.contains("capability_summary:"));
        assert!(openapi.contains("denied_capabilities:"));
        assert!(openapi.contains("provider_key_manage:"));
        assert!(openapi.contains("allowed_roles: [owner, admin, ops]"));
        assert!(openapi.contains("billing_adjust:"));
        assert!(openapi.contains("allowed_roles: [owner, billing]"));
    }

    #[test]
    fn provider_management_reads_reject_viewer_and_allow_manager_and_admin() {
        let paths = [
            "/admin/providers",
            "/admin/providers/00000000-0000-0000-0000-000000000001",
        ];
        let methods = [Method::GET, Method::HEAD, Method::OPTIONS];

        for method in methods {
            for path in paths {
                assert_eq!(
                    permission_for_admin_request(&method, path),
                    Some(Permission::ProviderManage),
                    "{method} {path}"
                );
                assert!(
                    !role_allows_admin_request(Role::Viewer, &method, path),
                    "viewer unexpectedly allowed {method} {path}"
                );
                assert!(
                    role_allows_admin_request(Role::Ops, &method, path),
                    "manager unexpectedly denied {method} {path}"
                );
                assert!(
                    role_allows_admin_request(Role::Admin, &method, path),
                    "admin unexpectedly denied {method} {path}"
                );
            }
        }
    }

    #[test]
    fn alert_webhook_dry_run_requires_manage_permission() {
        let path = "/admin/alerts/webhook/dry-run";

        assert_eq!(
            permission_for_admin_request(&Method::POST, path),
            Some(Permission::ProviderManage)
        );
        assert!(!role_allows_admin_request(
            Role::Viewer,
            &Method::POST,
            path
        ));
        assert!(!role_allows_admin_request(
            Role::Billing,
            &Method::POST,
            path
        ));
        assert!(!role_allows_admin_request(
            Role::Developer,
            &Method::POST,
            path
        ));
        assert!(role_allows_admin_request(Role::Ops, &Method::POST, path));
        assert!(role_allows_admin_request(Role::Admin, &Method::POST, path));
        assert!(role_allows_admin_request(Role::Owner, &Method::POST, path));
    }

    #[test]
    fn prompt_eval_shadow_dry_run_requires_manage_permission() {
        let path = "/admin/prompt-eval-shadow/dry-run";

        assert_eq!(
            permission_for_admin_request(&Method::POST, path),
            Some(Permission::ProviderManage)
        );
        assert!(!role_allows_admin_request(
            Role::Viewer,
            &Method::POST,
            path
        ));
        assert!(!role_allows_admin_request(
            Role::Billing,
            &Method::POST,
            path
        ));
        assert!(!role_allows_admin_request(
            Role::Developer,
            &Method::POST,
            path
        ));
        assert!(role_allows_admin_request(Role::Ops, &Method::POST, path));
        assert!(role_allows_admin_request(Role::Admin, &Method::POST, path));
        assert!(role_allows_admin_request(Role::Owner, &Method::POST, path));
    }

    #[test]
    fn permission_map_keeps_auth_and_health_paths_without_business_permission() {
        assert!(is_public_admin_path("/admin/auth/login"));
        assert!(is_public_admin_path("/admin/auth/logout"));
        assert!(is_public_admin_path("/admin/auth/me"));
        assert!(is_public_admin_path("/healthz"));
        assert!(is_public_admin_path("/readyz"));

        assert_eq!(
            permission_for_admin_request(&Method::POST, "/admin/auth/login"),
            None
        );
        assert_eq!(
            permission_for_admin_request(&Method::POST, "/admin/auth/logout"),
            None
        );
        assert_eq!(
            permission_for_admin_request(&Method::GET, "/admin/auth/me"),
            None
        );
        assert_eq!(permission_for_admin_request(&Method::GET, "/healthz"), None);
        assert_eq!(permission_for_admin_request(&Method::GET, "/readyz"), None);
    }

    #[test]
    fn permission_map_requires_log_read_for_request_logs() {
        assert_eq!(
            permission_for_admin_request(&Method::GET, "/admin/request-logs"),
            Some(Permission::LogReadMetadata)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::GET,
                "/admin/request-logs/00000000-0000-0000-0000-000000000001"
            ),
            Some(Permission::LogReadMetadata)
        );
        assert_eq!(
            permission_for_admin_request(
                &Method::GET,
                "/admin/request-logs/00000000-0000-0000-0000-000000000001/payload"
            ),
            Some(Permission::LogReadMetadata)
        );
        assert!(role_allows_admin_request(
            Role::Viewer,
            &Method::GET,
            "/admin/request-logs/00000000-0000-0000-0000-000000000001/payload"
        ));
        assert!(role_allows_admin_request(
            Role::Developer,
            &Method::GET,
            "/admin/request-logs/00000000-0000-0000-0000-000000000001/payload"
        ));
        assert!(!role_allows_admin_request(
            Role::Billing,
            &Method::GET,
            "/admin/request-logs/00000000-0000-0000-0000-000000000001/payload"
        ));
        assert_eq!(
            permission_for_admin_request(&Method::GET, "/admin/traces/trace-contract-1"),
            Some(Permission::LogReadMetadata)
        );
        assert!(role_allows_admin_request(
            Role::Viewer,
            &Method::GET,
            "/admin/traces/trace-contract-1"
        ));
        assert!(role_allows_admin_request(
            Role::Developer,
            &Method::GET,
            "/admin/traces/trace-contract-1"
        ));
        assert!(!role_allows_admin_request(
            Role::Billing,
            &Method::GET,
            "/admin/traces/trace-contract-1"
        ));
    }

    #[test]
    fn permission_map_requires_audit_read_for_audit_logs() {
        let path = "/admin/audit-logs";

        assert_eq!(
            permission_for_admin_request(&Method::GET, path),
            Some(Permission::AuditRead)
        );
        assert!(role_allows_admin_request(Role::Owner, &Method::GET, path));
        assert!(role_allows_admin_request(Role::Admin, &Method::GET, path));
        assert!(role_allows_admin_request(Role::Ops, &Method::GET, path));
        assert!(role_allows_admin_request(Role::Viewer, &Method::GET, path));
        assert!(!role_allows_admin_request(
            Role::Developer,
            &Method::GET,
            path
        ));
        assert!(!role_allows_admin_request(
            Role::Billing,
            &Method::GET,
            path
        ));
    }

    #[test]
    fn permission_map_requires_billing_read_for_reconciliation() {
        for path in [
            "/admin/billing/reconciliation",
            "/admin/price-versions",
            "/admin/ledger/entries",
            "/admin/credit-grants",
            "/admin/credit-grants/00000000-0000-0000-0000-000000000123",
            "/admin/voucher-issuances",
            "/billing/wallets/00000000-0000-0000-0000-000000000123/remaining-balance",
        ] {
            assert_eq!(
                permission_for_admin_request(&Method::GET, path),
                Some(Permission::BillingRead),
                "{path}"
            );
            assert!(
                role_allows_admin_request(Role::Billing, &Method::GET, path),
                "billing unexpectedly denied {path}"
            );
            assert!(
                role_allows_admin_request(Role::Viewer, &Method::GET, path),
                "viewer unexpectedly denied {path}"
            );
            assert!(
                !role_allows_admin_request(Role::Developer, &Method::GET, path),
                "developer unexpectedly allowed {path}"
            );
        }
    }

    #[test]
    fn billing_adjust_writes_require_billing_adjust() {
        for path in [
            "/admin/price-versions",
            "/admin/credit-grants",
            "/admin/credit-grants/00000000-0000-0000-0000-000000000123/expire",
            "/admin/credit-grants/00000000-0000-0000-0000-000000000123/revoke",
            "/admin/voucher-issuances",
            "/admin/voucher-issuances/00000000-0000-0000-0000-000000000123/revoke",
            "/admin/voucher-issuance-batches",
            "/billing/vouchers/redeem",
            "/admin/ledger/adjustments/dry-run",
            "/billing/opening-balance-imports",
        ] {
            assert_eq!(
                permission_for_admin_request(&Method::POST, path),
                Some(Permission::BillingAdjust),
                "{path}"
            );
            assert!(
                role_allows_admin_request(Role::Billing, &Method::POST, path),
                "billing unexpectedly denied {path}"
            );
            assert!(
                role_allows_admin_request(Role::Owner, &Method::POST, path),
                "owner unexpectedly denied {path}"
            );
            assert!(
                !role_allows_admin_request(Role::Viewer, &Method::POST, path),
                "viewer unexpectedly allowed {path}"
            );
            assert!(
                !role_allows_admin_request(Role::Developer, &Method::POST, path),
                "developer unexpectedly allowed {path}"
            );
            assert!(
                !role_allows_admin_request(Role::Ops, &Method::POST, path),
                "ops unexpectedly allowed {path}"
            );
            assert!(
                !role_allows_admin_request(Role::Admin, &Method::POST, path),
                "admin unexpectedly allowed {path}"
            );
        }
    }
}
