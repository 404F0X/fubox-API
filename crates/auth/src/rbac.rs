use serde::{Deserialize, Serialize};
use std::{fmt, str::FromStr};
use thiserror::Error;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum RoleParseError {
    #[error("role must not be empty")]
    Empty,
    #[error("role is unsupported: {0}")]
    Unsupported(String),
}

#[derive(Debug, Error, Clone, Copy, PartialEq, Eq)]
pub enum AccessControlError {
    #[error("principal has no roles")]
    MissingRole,
    #[error("principal is missing permission {permission}")]
    PermissionDenied { permission: Permission },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Owner,
    Admin,
    Ops,
    Billing,
    Developer,
    Viewer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Permission {
    TenantAdmin,
    ProjectAdmin,
    ProviderManage,
    KeyManage,
    BillingRead,
    BillingAdjust,
    LogReadMetadata,
    LogReadPayload,
    AuditRead,
    SystemConfig,
}

impl Role {
    pub const ALL: [Self; 6] = [
        Self::Owner,
        Self::Admin,
        Self::Ops,
        Self::Billing,
        Self::Developer,
        Self::Viewer,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Admin => "admin",
            Self::Ops => "ops",
            Self::Billing => "billing",
            Self::Developer => "developer",
            Self::Viewer => "viewer",
        }
    }

    pub const fn allows(self, permission: Permission) -> bool {
        role_allows(self, permission)
    }
}

impl Permission {
    pub const ALL: [Self; 10] = [
        Self::TenantAdmin,
        Self::ProjectAdmin,
        Self::ProviderManage,
        Self::KeyManage,
        Self::BillingRead,
        Self::BillingAdjust,
        Self::LogReadMetadata,
        Self::LogReadPayload,
        Self::AuditRead,
        Self::SystemConfig,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::TenantAdmin => "tenant_admin",
            Self::ProjectAdmin => "project_admin",
            Self::ProviderManage => "provider_manage",
            Self::KeyManage => "key_manage",
            Self::BillingRead => "billing_read",
            Self::BillingAdjust => "billing_adjust",
            Self::LogReadMetadata => "log_read_metadata",
            Self::LogReadPayload => "log_read_payload",
            Self::AuditRead => "audit_read",
            Self::SystemConfig => "system_config",
        }
    }
}

pub const fn role_allows(role: Role, permission: Permission) -> bool {
    match role {
        Role::Owner => true,
        Role::Admin => matches!(
            permission,
            Permission::TenantAdmin
                | Permission::ProjectAdmin
                | Permission::ProviderManage
                | Permission::KeyManage
                | Permission::BillingRead
                | Permission::LogReadMetadata
                | Permission::LogReadPayload
                | Permission::AuditRead
        ),
        Role::Ops => matches!(
            permission,
            Permission::ProviderManage
                | Permission::KeyManage
                | Permission::LogReadMetadata
                | Permission::AuditRead
        ),
        Role::Billing => matches!(
            permission,
            Permission::BillingRead | Permission::BillingAdjust
        ),
        Role::Developer => matches!(
            permission,
            Permission::KeyManage | Permission::LogReadMetadata
        ),
        Role::Viewer => matches!(
            permission,
            Permission::BillingRead | Permission::LogReadMetadata | Permission::AuditRead
        ),
    }
}

pub fn any_role_allows(roles: &[Role], permission: Permission) -> bool {
    roles.iter().any(|role| role.allows(permission))
}

pub fn require_permission(
    roles: &[Role],
    permission: Permission,
) -> Result<(), AccessControlError> {
    if roles.is_empty() {
        return Err(AccessControlError::MissingRole);
    }
    if any_role_allows(roles, permission) {
        return Ok(());
    }

    Err(AccessControlError::PermissionDenied { permission })
}

impl fmt::Display for Role {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for Role {
    type Err = RoleParseError;

    fn from_str(raw: &str) -> Result<Self, Self::Err> {
        let normalized = raw.trim().to_ascii_lowercase();
        if normalized.is_empty() {
            return Err(RoleParseError::Empty);
        }

        match normalized.as_str() {
            "owner" => Ok(Self::Owner),
            "admin" => Ok(Self::Admin),
            "ops" => Ok(Self::Ops),
            "billing" => Ok(Self::Billing),
            "developer" => Ok(Self::Developer),
            "viewer" => Ok(Self::Viewer),
            _ => Err(RoleParseError::Unsupported(raw.to_owned())),
        }
    }
}

impl fmt::Display for Permission {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_roles_from_database_values() {
        assert_eq!("owner".parse::<Role>().unwrap(), Role::Owner);
        assert_eq!(" ADMIN ".parse::<Role>().unwrap(), Role::Admin);
        assert_eq!("ops".parse::<Role>().unwrap(), Role::Ops);
        assert_eq!("billing".parse::<Role>().unwrap(), Role::Billing);
        assert_eq!("developer".parse::<Role>().unwrap(), Role::Developer);
        assert_eq!("viewer".parse::<Role>().unwrap(), Role::Viewer);
    }

    #[test]
    fn rejects_unknown_roles() {
        assert_eq!(" ".parse::<Role>().unwrap_err(), RoleParseError::Empty);
        assert_eq!(
            "super_admin".parse::<Role>().unwrap_err(),
            RoleParseError::Unsupported("super_admin".to_owned())
        );
    }

    #[test]
    fn owner_allows_every_permission() {
        for permission in Permission::ALL {
            assert!(Role::Owner.allows(permission), "missing {permission}");
        }
    }

    #[test]
    fn role_permission_matrix_enforces_least_privilege() {
        assert!(Role::Admin.allows(Permission::TenantAdmin));
        assert!(Role::Admin.allows(Permission::LogReadPayload));
        assert!(!Role::Admin.allows(Permission::SystemConfig));
        assert!(!Role::Admin.allows(Permission::BillingAdjust));

        assert!(Role::Ops.allows(Permission::ProviderManage));
        assert!(Role::Ops.allows(Permission::KeyManage));
        assert!(!Role::Ops.allows(Permission::BillingRead));
        assert!(!Role::Ops.allows(Permission::LogReadPayload));

        assert!(Role::Billing.allows(Permission::BillingRead));
        assert!(Role::Billing.allows(Permission::BillingAdjust));
        assert!(!Role::Billing.allows(Permission::ProjectAdmin));

        assert!(Role::Developer.allows(Permission::KeyManage));
        assert!(!Role::Developer.allows(Permission::ProviderManage));

        assert!(Role::Viewer.allows(Permission::AuditRead));
        assert!(!Role::Viewer.allows(Permission::KeyManage));
    }

    #[test]
    fn require_permission_accepts_any_matching_role() {
        assert_eq!(
            require_permission(&[], Permission::AuditRead).unwrap_err(),
            AccessControlError::MissingRole
        );
        assert!(require_permission(&[Role::Viewer], Permission::AuditRead).is_ok());
        assert!(
            require_permission(&[Role::Viewer, Role::Billing], Permission::BillingAdjust).is_ok()
        );
        assert_eq!(
            require_permission(&[Role::Viewer], Permission::KeyManage).unwrap_err(),
            AccessControlError::PermissionDenied {
                permission: Permission::KeyManage,
            }
        );
    }
}
