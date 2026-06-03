use std::fmt;

use ai_gateway_auth::{Role, parse_session_token};
use sqlx::{Row, postgres::PgRow};
use uuid::Uuid;

#[derive(Clone, PartialEq)]
pub(crate) struct StoredAdminUser {
    pub(crate) id: Uuid,
    pub(crate) tenant_id: Uuid,
    pub(crate) email: String,
    pub(crate) display_name: String,
    pub(crate) password_hash: Option<String>,
    pub(crate) roles: Vec<Role>,
}

impl fmt::Debug for StoredAdminUser {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StoredAdminUser")
            .field("id", &self.id)
            .field("tenant_id", &self.tenant_id)
            .field("email", &self.email)
            .field("display_name", &self.display_name)
            .field(
                "password_hash",
                &self.password_hash.as_ref().map(|_| "[REDACTED]"),
            )
            .field("roles", &self.roles)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct CreatedAdminSession {
    pub(crate) id: Uuid,
    pub(crate) expires_at: String,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct StoredAdminSession {
    pub(crate) id: Uuid,
    pub(crate) user: StoredAdminUser,
    pub(crate) expires_at: String,
}

#[derive(Debug)]
pub(crate) enum AuthRepoError {
    Query,
}

impl From<sqlx::Error> for AuthRepoError {
    fn from(error: sqlx::Error) -> Self {
        let _ = error;
        Self::Query
    }
}

#[derive(Debug, Clone)]
pub(crate) struct AuthRepository {
    pool: sqlx::PgPool,
}

impl AuthRepository {
    pub(crate) fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }

    pub(crate) async fn find_active_user_by_email(
        &self,
        tenant_id: Uuid,
        email: &str,
    ) -> Result<Option<StoredAdminUser>, AuthRepoError> {
        let row = sqlx::query(
            r#"
            select id, tenant_id, email, display_name, password_hash
            from users
            where tenant_id = $1
              and lower(email) = lower($2)
              and status = 'active'
              and deleted_at is null
            "#,
        )
        .bind(tenant_id)
        .bind(email)
        .fetch_optional(&self.pool)
        .await?;

        self.user_from_optional_row(row).await
    }

    pub(crate) async fn create_session(
        &self,
        tenant_id: Uuid,
        user_id: Uuid,
        token_lookup_prefix: &str,
        token_hash: &str,
        user_agent: Option<&str>,
        ttl_seconds: i32,
    ) -> Result<CreatedAdminSession, AuthRepoError> {
        let row = sqlx::query(
            r#"
            insert into user_sessions (
              tenant_id,
              user_id,
              token_lookup_prefix,
              token_hash,
              status,
              user_agent,
              metadata,
              expires_at
            )
            values ($1, $2, $3, $4, 'active', $5, '{}'::jsonb, now() + ($6::integer * interval '1 second'))
            returning id, expires_at::text as expires_at
            "#,
        )
        .bind(tenant_id)
        .bind(user_id)
        .bind(token_lookup_prefix)
        .bind(token_hash)
        .bind(user_agent)
        .bind(ttl_seconds)
        .fetch_one(&self.pool)
        .await?;

        sqlx::query(
            r#"
            update users
            set last_login_at = now(), updated_at = now()
            where tenant_id = $1 and id = $2
            "#,
        )
        .bind(tenant_id)
        .bind(user_id)
        .execute(&self.pool)
        .await?;

        Ok(CreatedAdminSession {
            id: row.try_get("id")?,
            expires_at: row.try_get("expires_at")?,
        })
    }

    pub(crate) async fn find_active_session_by_token(
        &self,
        token: &str,
    ) -> Result<Option<StoredAdminSession>, AuthRepoError> {
        let parsed = match parse_session_token(token) {
            Ok(parsed) => parsed,
            Err(_) => return Ok(None),
        };

        let row = sqlx::query(
            r#"
            select
              s.id as session_id,
              s.expires_at::text as session_expires_at,
              u.id,
              u.tenant_id,
              u.email,
              u.display_name,
              u.password_hash
            from user_sessions s
            join users u on u.tenant_id = s.tenant_id and u.id = s.user_id
            where s.token_lookup_prefix = $1
              and s.token_hash = $2
              and s.status = 'active'
              and s.revoked_at is null
              and s.expires_at > now()
              and u.status = 'active'
              and u.deleted_at is null
            "#,
        )
        .bind(parsed.prefix)
        .bind(parsed.token_hash)
        .fetch_optional(&self.pool)
        .await?;

        let Some(row) = row else {
            return Ok(None);
        };

        let user = self.user_from_row(&row).await?;
        let session = StoredAdminSession {
            id: row.try_get("session_id")?,
            user,
            expires_at: row.try_get("session_expires_at")?,
        };

        sqlx::query(
            r#"
            update user_sessions
            set last_seen_at = now()
            where tenant_id = $1 and id = $2 and status = 'active'
            "#,
        )
        .bind(session.user.tenant_id)
        .bind(session.id)
        .execute(&self.pool)
        .await?;

        Ok(Some(session))
    }

    pub(crate) async fn revoke_session(
        &self,
        tenant_id: Uuid,
        session_id: Uuid,
    ) -> Result<(), AuthRepoError> {
        sqlx::query(
            r#"
            update user_sessions
            set status = 'revoked', revoked_at = coalesce(revoked_at, now())
            where tenant_id = $1 and id = $2 and status = 'active'
            "#,
        )
        .bind(tenant_id)
        .bind(session_id)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    async fn user_from_optional_row(
        &self,
        row: Option<PgRow>,
    ) -> Result<Option<StoredAdminUser>, AuthRepoError> {
        match row {
            Some(row) => self.user_from_row(&row).await.map(Some),
            None => Ok(None),
        }
    }

    async fn user_from_row(&self, row: &PgRow) -> Result<StoredAdminUser, AuthRepoError> {
        let tenant_id = row.try_get("tenant_id")?;
        let user_id = row.try_get("id")?;
        let roles = self.list_user_roles(tenant_id, user_id).await?;

        Ok(StoredAdminUser {
            id: user_id,
            tenant_id,
            email: row.try_get("email")?,
            display_name: row.try_get("display_name")?,
            password_hash: row.try_get("password_hash")?,
            roles,
        })
    }

    async fn list_user_roles(
        &self,
        tenant_id: Uuid,
        user_id: Uuid,
    ) -> Result<Vec<Role>, AuthRepoError> {
        let rows = sqlx::query(
            r#"
            select distinct role
            from (
              select tm.role
              from team_members tm
              join teams t on t.tenant_id = tm.tenant_id and t.id = tm.team_id
              where tm.tenant_id = $1
                and tm.user_id = $2
                and t.status = 'active'
                and t.deleted_at is null

              union all

              select pm.role
              from project_members pm
              join projects p on p.tenant_id = pm.tenant_id and p.id = pm.project_id
              where pm.tenant_id = $1
                and pm.user_id = $2
                and p.status = 'active'
                and p.deleted_at is null
            ) memberships
            order by role
            "#,
        )
        .bind(tenant_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;

        let mut roles = Vec::new();
        for row in rows {
            let raw_role: String = row.try_get("role")?;
            if let Ok(role) = raw_role.parse::<Role>()
                && !roles.contains(&role)
            {
                roles.push(role);
            }
        }

        sort_roles(&mut roles);
        Ok(roles)
    }
}

fn sort_roles(roles: &mut [Role]) {
    roles.sort_by_key(|role| role_rank(*role));
}

fn role_rank(role: Role) -> usize {
    Role::ALL
        .iter()
        .position(|candidate| *candidate == role)
        .unwrap_or(Role::ALL.len())
}
