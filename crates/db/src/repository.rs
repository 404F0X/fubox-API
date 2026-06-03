use ai_gateway_billing_ledger::{
    BillingReconciliationInputRow, BillingReconciliationReport, reconcile_billing_usage_ledger,
};
use serde_json::Value;
use sqlx::{Postgres, Row, Transaction, postgres::PgRow};
use uuid::Uuid;

use crate::{
    models::{
        ApiKeyProfile, AuditLog, BillingReconciliationReportFilter, CanonicalModel, Channel,
        LedgerEntry, LedgerEntryListFilter, ModelAssociation, NewApiKeyProfile, NewAuditLog,
        NewCanonicalModel, NewChannel, NewModelAssociation, NewProvider, NewProviderAttempt,
        NewProviderKey, NewRequestLogStarted, NewVirtualKey, PriceVersion, PriceVersionListFilter,
        Provider, ProviderAttempt, ProviderAttemptRead, ProviderKey, RecoveryProbeCandidate,
        RequestLog, RequestLogFinalUpdate, RequestLogListFilter, RequestLogSummary,
        RequestTraceFilter, RouteCandidate, RouteCandidates, UpdateApiKeyProfile,
        UpdateCanonicalModel, UpdateChannel, UpdateModelAssociation, UpdateProvider, VirtualKey,
    },
    pool::{DbError, PgPool},
};

#[derive(Debug, Clone)]
pub struct DbRepository {
    pool: PgPool,
}

#[derive(Debug, Clone)]
pub struct NewPriceVersionInput {
    pub tenant_id: Uuid,
    pub price_book_id: Uuid,
    pub canonical_model_id: Option<Uuid>,
    pub version: String,
    pub pricing_rules: Value,
    pub effective_at: Option<String>,
    pub retired_at: Option<String>,
    pub status: String,
}

impl DbRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub async fn insert_audit_log(&self, audit: NewAuditLog) -> Result<AuditLog, DbError> {
        let row = sqlx::query(
            r#"
            insert into audit_logs (
              tenant_id, actor_user_id, request_id, action, resource_type, resource_id,
              resource_tenant_id, before_snapshot, after_snapshot, metadata
            )
            values (
              $1,
              (
                select s.user_id
                from user_sessions s
                where s.tenant_id = $1 and s.id = $2
              ),
              $3, $4, $5, $6, $7, $8, $9, $10
            )
            returning
              id, tenant_id, actor_user_id, request_id, action, resource_type, resource_id,
              resource_tenant_id, before_snapshot, after_snapshot, metadata,
              created_at::text as created_at
            "#,
        )
        .bind(audit.tenant_id)
        .bind(audit.actor_session_id)
        .bind(audit.request_id)
        .bind(audit.action)
        .bind(audit.resource_type)
        .bind(audit.resource_id)
        .bind(audit.resource_tenant_id)
        .bind(audit.before_snapshot)
        .bind(audit.after_snapshot)
        .bind(audit.metadata)
        .fetch_one(&self.pool)
        .await
        .map_err(DbError::Query)?;

        audit_log_from_row(row).map_err(DbError::Query)
    }

    async fn insert_audit_log_in_tx(
        tx: &mut Transaction<'_, Postgres>,
        audit: NewAuditLog,
    ) -> Result<AuditLog, DbError> {
        let row = sqlx::query(
            r#"
            insert into audit_logs (
              tenant_id, actor_user_id, request_id, action, resource_type, resource_id,
              resource_tenant_id, before_snapshot, after_snapshot, metadata
            )
            values (
              $1,
              (
                select s.user_id
                from user_sessions s
                where s.tenant_id = $1 and s.id = $2
              ),
              $3, $4, $5, $6, $7, $8, $9, $10
            )
            returning
              id, tenant_id, actor_user_id, request_id, action, resource_type, resource_id,
              resource_tenant_id, before_snapshot, after_snapshot, metadata,
              created_at::text as created_at
            "#,
        )
        .bind(audit.tenant_id)
        .bind(audit.actor_session_id)
        .bind(audit.request_id)
        .bind(audit.action)
        .bind(audit.resource_type)
        .bind(audit.resource_id)
        .bind(audit.resource_tenant_id)
        .bind(audit.before_snapshot)
        .bind(audit.after_snapshot)
        .bind(audit.metadata)
        .fetch_one(&mut **tx)
        .await
        .map_err(DbError::Query)?;

        audit_log_from_row(row).map_err(DbError::Query)
    }

    pub async fn find_virtual_key_by_prefix(
        &self,
        key_prefix: &str,
    ) -> Result<Option<VirtualKey>, DbError> {
        let row = sqlx::query(
            r#"
            select
              id, tenant_id, project_id, name, key_prefix, secret_hash, status,
              default_profile_id, ip_allowlist, rate_limit_policy, budget_policy, metadata
            from virtual_keys
            where key_prefix = $1 and deleted_at is null
            "#,
        )
        .bind(key_prefix)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(virtual_key_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn touch_virtual_key_used(
        &self,
        tenant_id: Uuid,
        virtual_key_id: Uuid,
    ) -> Result<Option<VirtualKey>, DbError> {
        let row = sqlx::query(
            r#"
            update virtual_keys
            set last_used_at = now(), updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, project_id, name, key_prefix, secret_hash, status,
              default_profile_id, ip_allowlist, rate_limit_policy, budget_policy, metadata
            "#,
        )
        .bind(tenant_id)
        .bind(virtual_key_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(virtual_key_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn get_virtual_key(
        &self,
        tenant_id: Uuid,
        virtual_key_id: Uuid,
    ) -> Result<Option<VirtualKey>, DbError> {
        let row = sqlx::query(
            r#"
            select
              id, tenant_id, project_id, name, key_prefix, secret_hash, status,
              default_profile_id, ip_allowlist, rate_limit_policy, budget_policy, metadata
            from virtual_keys
            where tenant_id = $1 and id = $2 and deleted_at is null
            "#,
        )
        .bind(tenant_id)
        .bind(virtual_key_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(virtual_key_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn create_virtual_key_with_default_profile(
        &self,
        virtual_key: NewVirtualKey,
    ) -> Result<VirtualKey, DbError> {
        let mut tx = self.pool.begin().await.map_err(DbError::Query)?;
        let row = sqlx::query(
            r#"
            insert into virtual_keys (
              id, tenant_id, project_id, name, key_prefix, secret_hash, status,
              default_profile_id, ip_allowlist, rate_limit_policy, budget_policy, metadata
            )
            values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
            returning
              id, tenant_id, project_id, name, key_prefix, secret_hash, status,
              default_profile_id, ip_allowlist, rate_limit_policy, budget_policy, metadata
            "#,
        )
        .bind(virtual_key.id)
        .bind(virtual_key.tenant_id)
        .bind(virtual_key.project_id)
        .bind(&virtual_key.name)
        .bind(&virtual_key.key_prefix)
        .bind(&virtual_key.secret_hash)
        .bind(&virtual_key.status)
        .bind(virtual_key.default_profile_id)
        .bind(&virtual_key.ip_allowlist)
        .bind(&virtual_key.rate_limit_policy)
        .bind(&virtual_key.budget_policy)
        .bind(&virtual_key.metadata)
        .fetch_one(&mut *tx)
        .await
        .map_err(DbError::Query)?;

        sqlx::query(
            r#"
            insert into virtual_key_profile_bindings (
              tenant_id, project_id, virtual_key_id, profile_id, is_default
            )
            values ($1, $2, $3, $4, true)
            "#,
        )
        .bind(virtual_key.tenant_id)
        .bind(virtual_key.project_id)
        .bind(virtual_key.id)
        .bind(virtual_key.default_profile_id)
        .execute(&mut *tx)
        .await
        .map_err(DbError::Query)?;

        tx.commit().await.map_err(DbError::Query)?;

        virtual_key_from_row(row).map_err(DbError::Query)
    }

    pub async fn list_virtual_keys(
        &self,
        tenant_id: Uuid,
        project_id: Uuid,
        status: Option<&str>,
    ) -> Result<Vec<VirtualKey>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, project_id, name, key_prefix, secret_hash, status,
              default_profile_id, ip_allowlist, rate_limit_policy, budget_policy, metadata
            from virtual_keys
            where tenant_id = $1
              and project_id = $2
              and ($3::text is null or status = $3)
              and deleted_at is null
            order by name, id
            "#,
        )
        .bind(tenant_id)
        .bind(project_id)
        .bind(status)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, virtual_key_from_row)
    }

    pub async fn update_virtual_key_status(
        &self,
        tenant_id: Uuid,
        virtual_key_id: Uuid,
        status: &str,
    ) -> Result<Option<VirtualKey>, DbError> {
        let row = sqlx::query(
            r#"
            update virtual_keys
            set status = $3,
                updated_at = now(),
                deleted_at = case when $3 = 'deleted' then now() else deleted_at end
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, project_id, name, key_prefix, secret_hash, status,
              default_profile_id, ip_allowlist, rate_limit_policy, budget_policy, metadata
            "#,
        )
        .bind(tenant_id)
        .bind(virtual_key_id)
        .bind(status)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(virtual_key_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn api_key_profile_has_active_virtual_keys(
        &self,
        tenant_id: Uuid,
        profile_id: Uuid,
    ) -> Result<bool, DbError> {
        let row = sqlx::query(
            r#"
            select exists (
              select 1
              from virtual_keys vk
              where vk.tenant_id = $1
                and vk.status = 'active'
                and vk.deleted_at is null
                and (
                  vk.default_profile_id = $2
                  or exists (
                    select 1
                    from virtual_key_profile_bindings b
                    where b.tenant_id = vk.tenant_id
                      and b.project_id = vk.project_id
                      and b.virtual_key_id = vk.id
                      and b.profile_id = $2
                  )
                )
              limit 1
            ) as has_active_virtual_keys
            "#,
        )
        .bind(tenant_id)
        .bind(profile_id)
        .fetch_one(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.try_get("has_active_virtual_keys")
            .map_err(DbError::Query)
    }

    pub async fn get_api_key_profile(
        &self,
        tenant_id: Uuid,
        profile_id: Uuid,
    ) -> Result<Option<ApiKeyProfile>, DbError> {
        let row = sqlx::query(
            r#"
            select
              id, tenant_id, project_id, name, inbound_protocol, default_protocol_mode,
              model_aliases, allowed_models, denied_models, allowed_channel_tags,
              blocked_provider_ids, trace_header_rules, ip_allowlist, request_overrides,
              payload_policy_id, status
            from api_key_profiles
            where tenant_id = $1 and id = $2 and deleted_at is null
            "#,
        )
        .bind(tenant_id)
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(api_key_profile_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn create_api_key_profile(
        &self,
        profile: NewApiKeyProfile,
    ) -> Result<ApiKeyProfile, DbError> {
        let row = sqlx::query(
            r#"
            insert into api_key_profiles (
              tenant_id, project_id, name, inbound_protocol, default_protocol_mode,
              model_aliases, allowed_models, denied_models, allowed_channel_tags,
              blocked_provider_ids, trace_header_rules, ip_allowlist, request_overrides,
              payload_policy_id, status
            )
            values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
            returning
              id, tenant_id, project_id, name, inbound_protocol, default_protocol_mode,
              model_aliases, allowed_models, denied_models, allowed_channel_tags,
              blocked_provider_ids, trace_header_rules, ip_allowlist, request_overrides,
              payload_policy_id, status
            "#,
        )
        .bind(profile.tenant_id)
        .bind(profile.project_id)
        .bind(profile.name)
        .bind(profile.inbound_protocol)
        .bind(profile.default_protocol_mode)
        .bind(profile.model_aliases)
        .bind(profile.allowed_models)
        .bind(profile.denied_models)
        .bind(profile.allowed_channel_tags)
        .bind(profile.blocked_provider_ids)
        .bind(profile.trace_header_rules)
        .bind(profile.ip_allowlist)
        .bind(profile.request_overrides)
        .bind(profile.payload_policy_id)
        .bind(profile.status)
        .fetch_one(&self.pool)
        .await
        .map_err(DbError::Query)?;

        api_key_profile_from_row(row).map_err(DbError::Query)
    }

    pub async fn list_api_key_profiles(
        &self,
        tenant_id: Uuid,
        project_id: Option<Uuid>,
    ) -> Result<Vec<ApiKeyProfile>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, project_id, name, inbound_protocol, default_protocol_mode,
              model_aliases, allowed_models, denied_models, allowed_channel_tags,
              blocked_provider_ids, trace_header_rules, ip_allowlist, request_overrides,
              payload_policy_id, status
            from api_key_profiles
            where tenant_id = $1
              and ($2::uuid is null or project_id = $2)
              and deleted_at is null
            order by project_id, name
            "#,
        )
        .bind(tenant_id)
        .bind(project_id)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, api_key_profile_from_row)
    }

    pub async fn update_api_key_profile(
        &self,
        tenant_id: Uuid,
        profile_id: Uuid,
        update: UpdateApiKeyProfile,
    ) -> Result<Option<ApiKeyProfile>, DbError> {
        let row = sqlx::query(
            r#"
            update api_key_profiles
            set name = $3,
                inbound_protocol = $4,
                default_protocol_mode = $5,
                model_aliases = $6,
                allowed_models = $7,
                denied_models = $8,
                allowed_channel_tags = $9,
                blocked_provider_ids = $10,
                trace_header_rules = $11,
                ip_allowlist = $12,
                request_overrides = $13,
                payload_policy_id = $14,
                status = $15,
                updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, project_id, name, inbound_protocol, default_protocol_mode,
              model_aliases, allowed_models, denied_models, allowed_channel_tags,
              blocked_provider_ids, trace_header_rules, ip_allowlist, request_overrides,
              payload_policy_id, status
            "#,
        )
        .bind(tenant_id)
        .bind(profile_id)
        .bind(update.name)
        .bind(update.inbound_protocol)
        .bind(update.default_protocol_mode)
        .bind(update.model_aliases)
        .bind(update.allowed_models)
        .bind(update.denied_models)
        .bind(update.allowed_channel_tags)
        .bind(update.blocked_provider_ids)
        .bind(update.trace_header_rules)
        .bind(update.ip_allowlist)
        .bind(update.request_overrides)
        .bind(update.payload_policy_id)
        .bind(update.status)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(api_key_profile_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn update_api_key_profile_status(
        &self,
        tenant_id: Uuid,
        profile_id: Uuid,
        status: &str,
    ) -> Result<Option<ApiKeyProfile>, DbError> {
        let row = sqlx::query(
            r#"
            update api_key_profiles
            set status = $3, updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, project_id, name, inbound_protocol, default_protocol_mode,
              model_aliases, allowed_models, denied_models, allowed_channel_tags,
              blocked_provider_ids, trace_header_rules, ip_allowlist, request_overrides,
              payload_policy_id, status
            "#,
        )
        .bind(tenant_id)
        .bind(profile_id)
        .bind(status)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(api_key_profile_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn soft_delete_api_key_profile(
        &self,
        tenant_id: Uuid,
        profile_id: Uuid,
    ) -> Result<Option<ApiKeyProfile>, DbError> {
        let row = sqlx::query(
            r#"
            update api_key_profiles
            set status = 'deleted', updated_at = now(), deleted_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, project_id, name, inbound_protocol, default_protocol_mode,
              model_aliases, allowed_models, denied_models, allowed_channel_tags,
              blocked_provider_ids, trace_header_rules, ip_allowlist, request_overrides,
              payload_policy_id, status
            "#,
        )
        .bind(tenant_id)
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(api_key_profile_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn get_default_profile_for_virtual_key(
        &self,
        virtual_key: &VirtualKey,
    ) -> Result<Option<ApiKeyProfile>, DbError> {
        if let Some(profile_id) = virtual_key.default_profile_id {
            return self
                .get_api_key_profile(virtual_key.tenant_id, profile_id)
                .await;
        }

        let row = sqlx::query(
            r#"
            select
              p.id, p.tenant_id, p.project_id, p.name, p.inbound_protocol,
              p.default_protocol_mode, p.model_aliases, p.allowed_models,
              p.denied_models, p.allowed_channel_tags, p.blocked_provider_ids,
              p.trace_header_rules, p.ip_allowlist, p.request_overrides,
              p.payload_policy_id, p.status
            from virtual_key_profile_bindings b
            join api_key_profiles p
              on p.tenant_id = b.tenant_id
             and p.project_id = b.project_id
             and p.id = b.profile_id
            where b.tenant_id = $1
              and b.virtual_key_id = $2
              and b.is_default
              and p.deleted_at is null
            "#,
        )
        .bind(virtual_key.tenant_id)
        .bind(virtual_key.id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(api_key_profile_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn list_visible_models(
        &self,
        tenant_id: Uuid,
    ) -> Result<Vec<CanonicalModel>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, model_key, display_name, family, capabilities,
              context_length, max_output_tokens, supports_stream, supports_tools,
              supports_vision, supports_audio, supports_reasoning, visibility, status
            from canonical_models
            where tenant_id = $1
              and visibility in ('public', 'internal')
              and status = 'active'
              and deleted_at is null
            order by model_key
            "#,
        )
        .bind(tenant_id)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, canonical_model_from_row)
    }

    pub async fn list_visible_models_for_profile(
        &self,
        tenant_id: Uuid,
        profile_id: Uuid,
    ) -> Result<Vec<CanonicalModel>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              m.id, m.tenant_id, m.model_key, m.display_name, m.family, m.capabilities,
              m.context_length, m.max_output_tokens, m.supports_stream, m.supports_tools,
              m.supports_vision, m.supports_audio, m.supports_reasoning, m.visibility, m.status
            from canonical_models m
            join api_key_profiles p on p.tenant_id = m.tenant_id
            where p.tenant_id = $1
              and p.id = $2
              and p.status = 'active'
              and p.deleted_at is null
              and m.visibility in ('public', 'internal')
              and m.status = 'active'
              and m.deleted_at is null
              and (
                p.allowed_models = '[]'::jsonb
                or exists (
                  select 1
                  from jsonb_array_elements_text(p.allowed_models) allowed(model_key)
                  where allowed.model_key = m.model_key
                )
              )
              and not exists (
                select 1
                from jsonb_array_elements_text(p.denied_models) denied(model_key)
                where denied.model_key = m.model_key
              )
            order by m.model_key
            "#,
        )
        .bind(tenant_id)
        .bind(profile_id)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, canonical_model_from_row)
    }

    pub async fn get_route_candidates_for_model(
        &self,
        tenant_id: Uuid,
        profile_id: Uuid,
        model_key: &str,
    ) -> Result<Option<RouteCandidates>, DbError> {
        let model_row = sqlx::query(
            r#"
            select
              m.id, m.tenant_id, m.model_key, m.display_name, m.family, m.capabilities,
              m.context_length, m.max_output_tokens, m.supports_stream, m.supports_tools,
              m.supports_vision, m.supports_audio, m.supports_reasoning, m.visibility, m.status
            from api_key_profiles p
            join canonical_models m
              on m.tenant_id = p.tenant_id
             and m.model_key = coalesce(nullif(p.model_aliases ->> $3, ''), $3)
            where p.tenant_id = $1
              and p.id = $2
              and p.status = 'active'
              and p.deleted_at is null
              and m.status = 'active'
              and m.visibility in ('public', 'internal')
              and m.deleted_at is null
              and (
                coalesce(jsonb_array_length(p.allowed_models), 0) = 0
                or p.allowed_models ? m.model_key
              )
              and not (coalesce(p.denied_models, '[]'::jsonb) ? m.model_key)
            "#,
        )
        .bind(tenant_id)
        .bind(profile_id)
        .bind(model_key)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        let Some(model_row) = model_row else {
            return Ok(None);
        };
        let canonical_model = canonical_model_from_row(model_row).map_err(DbError::Query)?;

        let rows = sqlx::query(ROUTE_CANDIDATES_FOR_MODEL_SELECT)
            .bind(tenant_id)
            .bind(profile_id)
            .bind(canonical_model.id)
            .bind(&canonical_model.model_key)
            .fetch_all(&self.pool)
            .await
            .map_err(DbError::Query)?;

        let candidates = rows
            .into_iter()
            .map(route_candidate_from_row)
            .collect::<Result<Vec<_>, _>>()
            .map_err(DbError::Query)?;

        Ok(Some(RouteCandidates {
            canonical_model,
            candidates,
        }))
    }

    pub async fn upsert_provider(&self, new_provider: NewProvider) -> Result<Provider, DbError> {
        let row = sqlx::query(
            r#"
            insert into providers (tenant_id, code, name, status, metadata)
            values ($1, $2, $3, $4, $5)
            on conflict (tenant_id, code) do update
            set name = excluded.name,
                status = excluded.status,
                metadata = excluded.metadata,
                updated_at = now(),
                deleted_at = null
            returning id, tenant_id, code, name, status, metadata
            "#,
        )
        .bind(new_provider.tenant_id)
        .bind(new_provider.code)
        .bind(new_provider.name)
        .bind(new_provider.status)
        .bind(new_provider.metadata)
        .fetch_one(&self.pool)
        .await
        .map_err(DbError::Query)?;

        provider_from_row(row).map_err(DbError::Query)
    }

    pub async fn get_provider(
        &self,
        tenant_id: Uuid,
        provider_id: Uuid,
    ) -> Result<Option<Provider>, DbError> {
        let row = sqlx::query(
            r#"
            select id, tenant_id, code, name, status, metadata
            from providers
            where tenant_id = $1 and id = $2 and deleted_at is null
            "#,
        )
        .bind(tenant_id)
        .bind(provider_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(provider_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn list_providers(&self, tenant_id: Uuid) -> Result<Vec<Provider>, DbError> {
        let rows = sqlx::query(
            r#"
            select id, tenant_id, code, name, status, metadata
            from providers
            where tenant_id = $1 and deleted_at is null
            order by code
            "#,
        )
        .bind(tenant_id)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, provider_from_row)
    }

    pub async fn update_provider(
        &self,
        tenant_id: Uuid,
        provider_id: Uuid,
        update: UpdateProvider,
    ) -> Result<Option<Provider>, DbError> {
        let row = sqlx::query(
            r#"
            update providers
            set code = $3,
                name = $4,
                status = $5,
                metadata = $6,
                updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning id, tenant_id, code, name, status, metadata
            "#,
        )
        .bind(tenant_id)
        .bind(provider_id)
        .bind(update.code)
        .bind(update.name)
        .bind(update.status)
        .bind(update.metadata)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(provider_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn update_provider_status(
        &self,
        tenant_id: Uuid,
        provider_id: Uuid,
        status: &str,
    ) -> Result<Option<Provider>, DbError> {
        let row = sqlx::query(
            r#"
            update providers
            set status = $3, updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning id, tenant_id, code, name, status, metadata
            "#,
        )
        .bind(tenant_id)
        .bind(provider_id)
        .bind(status)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(provider_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn soft_delete_provider(
        &self,
        tenant_id: Uuid,
        provider_id: Uuid,
    ) -> Result<Option<Provider>, DbError> {
        let row = sqlx::query(
            r#"
            update providers
            set status = 'deleted', updated_at = now(), deleted_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning id, tenant_id, code, name, status, metadata
            "#,
        )
        .bind(tenant_id)
        .bind(provider_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(provider_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn upsert_channel(&self, new_channel: NewChannel) -> Result<Channel, DbError> {
        let row = sqlx::query(
            r#"
            insert into channels (
              tenant_id, provider_id, name, endpoint, protocol_mode, status, region,
              priority, weight, tags, model_mappings, request_overrides,
              timeout_policy, probe_policy, health_score
            )
            values (
              $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
              $13, $14, ($15::double precision)::numeric
            )
            on conflict (tenant_id, provider_id, name) do update
            set endpoint = excluded.endpoint,
                protocol_mode = excluded.protocol_mode,
                status = excluded.status,
                region = excluded.region,
                priority = excluded.priority,
                weight = excluded.weight,
                tags = excluded.tags,
                model_mappings = excluded.model_mappings,
                request_overrides = excluded.request_overrides,
                timeout_policy = excluded.timeout_policy,
                probe_policy = excluded.probe_policy,
                health_score = excluded.health_score,
                updated_at = now(),
                deleted_at = null
            returning
              id, tenant_id, provider_id, name, endpoint, protocol_mode, status, region,
              priority, weight, tags, model_mappings, request_overrides, timeout_policy,
              probe_policy, health_score::double precision as health_score
            "#,
        )
        .bind(new_channel.tenant_id)
        .bind(new_channel.provider_id)
        .bind(new_channel.name)
        .bind(new_channel.endpoint)
        .bind(new_channel.protocol_mode)
        .bind(new_channel.status)
        .bind(new_channel.region)
        .bind(new_channel.priority)
        .bind(new_channel.weight)
        .bind(new_channel.tags)
        .bind(new_channel.model_mappings)
        .bind(new_channel.request_overrides)
        .bind(new_channel.timeout_policy)
        .bind(new_channel.probe_policy)
        .bind(new_channel.health_score)
        .fetch_one(&self.pool)
        .await
        .map_err(DbError::Query)?;

        channel_from_row(row).map_err(DbError::Query)
    }

    pub async fn get_channel(
        &self,
        tenant_id: Uuid,
        channel_id: Uuid,
    ) -> Result<Option<Channel>, DbError> {
        let row = sqlx::query(CHANNEL_SELECT_BY_ID)
            .bind(tenant_id)
            .bind(channel_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(DbError::Query)?;

        row.map(channel_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn list_channels(&self, tenant_id: Uuid) -> Result<Vec<Channel>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, provider_id, name, endpoint, protocol_mode, status, region,
              priority, weight, tags, model_mappings, request_overrides, timeout_policy,
              probe_policy, health_score::double precision as health_score
            from channels
            where tenant_id = $1 and deleted_at is null
            order by priority, name
            "#,
        )
        .bind(tenant_id)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, channel_from_row)
    }

    pub async fn list_channels_for_provider(
        &self,
        tenant_id: Uuid,
        provider_id: Uuid,
    ) -> Result<Vec<Channel>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, provider_id, name, endpoint, protocol_mode, status, region,
              priority, weight, tags, model_mappings, request_overrides, timeout_policy,
              probe_policy, health_score::double precision as health_score
            from channels
            where tenant_id = $1
              and provider_id = $2
              and deleted_at is null
            order by priority, name
            "#,
        )
        .bind(tenant_id)
        .bind(provider_id)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, channel_from_row)
    }

    pub async fn update_channel(
        &self,
        tenant_id: Uuid,
        channel_id: Uuid,
        update: UpdateChannel,
    ) -> Result<Option<Channel>, DbError> {
        let row = sqlx::query(
            r#"
            update channels
            set provider_id = $3,
                name = $4,
                endpoint = $5,
                protocol_mode = $6,
                status = $7,
                region = $8,
                priority = $9,
                weight = $10,
                tags = $11,
                model_mappings = $12,
                request_overrides = $13,
                timeout_policy = $14,
                probe_policy = $15,
                health_score = ($16::double precision)::numeric,
                updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, provider_id, name, endpoint, protocol_mode, status, region,
              priority, weight, tags, model_mappings, request_overrides, timeout_policy,
              probe_policy, health_score::double precision as health_score
            "#,
        )
        .bind(tenant_id)
        .bind(channel_id)
        .bind(update.provider_id)
        .bind(update.name)
        .bind(update.endpoint)
        .bind(update.protocol_mode)
        .bind(update.status)
        .bind(update.region)
        .bind(update.priority)
        .bind(update.weight)
        .bind(update.tags)
        .bind(update.model_mappings)
        .bind(update.request_overrides)
        .bind(update.timeout_policy)
        .bind(update.probe_policy)
        .bind(update.health_score)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(channel_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn update_channel_status(
        &self,
        tenant_id: Uuid,
        channel_id: Uuid,
        status: &str,
    ) -> Result<Option<Channel>, DbError> {
        let row = sqlx::query(
            r#"
            update channels
            set status = $3, updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, provider_id, name, endpoint, protocol_mode, status, region,
              priority, weight, tags, model_mappings, request_overrides, timeout_policy,
              probe_policy, health_score::double precision as health_score
            "#,
        )
        .bind(tenant_id)
        .bind(channel_id)
        .bind(status)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(channel_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn soft_delete_channel(
        &self,
        tenant_id: Uuid,
        channel_id: Uuid,
    ) -> Result<Option<Channel>, DbError> {
        let row = sqlx::query(
            r#"
            update channels
            set status = 'deleted', updated_at = now(), deleted_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, provider_id, name, endpoint, protocol_mode, status, region,
              priority, weight, tags, model_mappings, request_overrides, timeout_policy,
              probe_policy, health_score::double precision as health_score
            "#,
        )
        .bind(tenant_id)
        .bind(channel_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(channel_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn get_provider_key(
        &self,
        tenant_id: Uuid,
        provider_key_id: Uuid,
    ) -> Result<Option<ProviderKey>, DbError> {
        let row = sqlx::query(
            r#"
            select
              id, tenant_id, channel_id, key_alias,
              secret_fingerprint is not null as has_secret_fingerprint,
              status,
              health_score::double precision as health_score,
              cooldown_until::text as cooldown_until, last_error_code, rpm_limit,
              tpm_limit, concurrency_limit, current_window_state, metadata,
              true as secret_redacted
            from provider_keys
            where tenant_id = $1 and id = $2 and deleted_at is null
            "#,
        )
        .bind(tenant_id)
        .bind(provider_key_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(provider_key_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn insert_provider_key(
        &self,
        provider_key: NewProviderKey,
    ) -> Result<ProviderKey, DbError> {
        let row = sqlx::query(
            r#"
            insert into provider_keys (
              id, tenant_id, channel_id, key_alias, encrypted_secret,
              secret_fingerprint, status, metadata
            )
            values ($1, $2, $3, $4, $5, $6, $7, $8)
            returning
              id, tenant_id, channel_id, key_alias,
              secret_fingerprint is not null as has_secret_fingerprint,
              status,
              health_score::double precision as health_score,
              cooldown_until::text as cooldown_until, last_error_code, rpm_limit,
              tpm_limit, concurrency_limit, current_window_state, metadata,
              true as secret_redacted
            "#,
        )
        .bind(provider_key.id)
        .bind(provider_key.tenant_id)
        .bind(provider_key.channel_id)
        .bind(provider_key.key_alias)
        .bind(provider_key.encrypted_secret)
        .bind(provider_key.secret_fingerprint)
        .bind(provider_key.status)
        .bind(provider_key.metadata)
        .fetch_one(&self.pool)
        .await
        .map_err(DbError::Query)?;

        provider_key_from_row(row).map_err(DbError::Query)
    }

    pub async fn insert_provider_key_with_audit<F>(
        &self,
        provider_key: NewProviderKey,
        build_audit: F,
    ) -> Result<ProviderKey, DbError>
    where
        F: FnOnce(&ProviderKey) -> NewAuditLog,
    {
        let mut tx = self.pool.begin().await.map_err(DbError::Query)?;
        let row = sqlx::query(
            r#"
            insert into provider_keys (
              id, tenant_id, channel_id, key_alias, encrypted_secret,
              secret_fingerprint, status, metadata
            )
            values ($1, $2, $3, $4, $5, $6, $7, $8)
            returning
              id, tenant_id, channel_id, key_alias,
              secret_fingerprint is not null as has_secret_fingerprint,
              status,
              health_score::double precision as health_score,
              cooldown_until::text as cooldown_until, last_error_code, rpm_limit,
              tpm_limit, concurrency_limit, current_window_state, metadata,
              true as secret_redacted
            "#,
        )
        .bind(provider_key.id)
        .bind(provider_key.tenant_id)
        .bind(provider_key.channel_id)
        .bind(provider_key.key_alias)
        .bind(provider_key.encrypted_secret)
        .bind(provider_key.secret_fingerprint)
        .bind(provider_key.status)
        .bind(provider_key.metadata)
        .fetch_one(&mut *tx)
        .await
        .map_err(DbError::Query)?;

        let provider_key = provider_key_from_row(row).map_err(DbError::Query)?;
        let audit = build_audit(&provider_key);
        Self::insert_audit_log_in_tx(&mut tx, audit).await?;
        tx.commit().await.map_err(DbError::Query)?;

        Ok(provider_key)
    }

    pub async fn list_provider_keys(&self, tenant_id: Uuid) -> Result<Vec<ProviderKey>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, channel_id, key_alias,
              secret_fingerprint is not null as has_secret_fingerprint,
              status,
              health_score::double precision as health_score,
              cooldown_until::text as cooldown_until, last_error_code, rpm_limit,
              tpm_limit, concurrency_limit, current_window_state, metadata,
              true as secret_redacted
            from provider_keys
            where tenant_id = $1 and deleted_at is null
            order by channel_id, key_alias
            "#,
        )
        .bind(tenant_id)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, provider_key_from_row)
    }

    pub async fn list_recovery_probe_candidates(
        &self,
        tenant_id: Uuid,
        limit: i64,
    ) -> Result<Vec<RecoveryProbeCandidate>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              pk.tenant_id,
              pr.id as provider_id,
              pr.code as provider_code,
              pr.name as provider_name,
              ch.id as channel_id,
              ch.name as channel_name,
              ch.endpoint as channel_endpoint,
              ch.protocol_mode as channel_protocol_mode,
              ch.status as channel_status,
              pk.id as provider_key_id,
              pk.key_alias,
              pk.status as provider_key_status,
              pk.health_score::double precision as provider_key_health_score,
              pk.cooldown_until::text as cooldown_until,
              pk.last_error_code,
              pk.secret_fingerprint is not null as has_secret_fingerprint,
              true as secret_redacted
            from provider_keys pk
            join channels ch
              on ch.tenant_id = pk.tenant_id
             and ch.id = pk.channel_id
             and ch.deleted_at is null
             and ch.status in ('enabled', 'degraded', 'cooldown', 'recovery_probe')
            join providers pr
              on pr.tenant_id = ch.tenant_id
             and pr.id = ch.provider_id
             and pr.status = 'enabled'
             and pr.deleted_at is null
            where pk.tenant_id = $1
              and pk.deleted_at is null
              and (
                pk.status = 'recovery_probe'
                or (pk.status = 'cooldown' and pk.cooldown_until <= now())
              )
            order by
              case pk.status
                when 'recovery_probe' then 0
                when 'cooldown' then 1
                else 2
              end,
              pk.cooldown_until nulls first,
              ch.priority asc,
              pk.health_score desc,
              pk.id asc
            limit $2
            "#,
        )
        .bind(tenant_id)
        .bind(limit.max(0))
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, recovery_probe_candidate_from_row)
    }

    pub async fn update_provider_key_admin(
        &self,
        tenant_id: Uuid,
        provider_key_id: Uuid,
        status: &str,
        metadata: serde_json::Value,
    ) -> Result<Option<ProviderKey>, DbError> {
        let row = sqlx::query(
            r#"
            update provider_keys
            set status = $3,
                metadata = $4,
                updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, channel_id, key_alias,
              secret_fingerprint is not null as has_secret_fingerprint,
              status,
              health_score::double precision as health_score,
              cooldown_until::text as cooldown_until, last_error_code, rpm_limit,
              tpm_limit, concurrency_limit, current_window_state, metadata,
              true as secret_redacted
            "#,
        )
        .bind(tenant_id)
        .bind(provider_key_id)
        .bind(status)
        .bind(metadata)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(provider_key_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn update_provider_key_admin_with_audit<F>(
        &self,
        tenant_id: Uuid,
        provider_key_id: Uuid,
        status: &str,
        metadata: serde_json::Value,
        build_audit: F,
    ) -> Result<Option<ProviderKey>, DbError>
    where
        F: FnOnce(&ProviderKey, &ProviderKey) -> NewAuditLog,
    {
        let mut tx = self.pool.begin().await.map_err(DbError::Query)?;
        let before_row = sqlx::query(
            r#"
            select
              id, tenant_id, channel_id, key_alias,
              secret_fingerprint is not null as has_secret_fingerprint,
              status,
              health_score::double precision as health_score,
              cooldown_until::text as cooldown_until, last_error_code, rpm_limit,
              tpm_limit, concurrency_limit, current_window_state, metadata,
              true as secret_redacted
            from provider_keys
            where tenant_id = $1 and id = $2 and deleted_at is null
            for update
            "#,
        )
        .bind(tenant_id)
        .bind(provider_key_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(DbError::Query)?;

        let Some(before_row) = before_row else {
            return Ok(None);
        };
        let before = provider_key_from_row(before_row).map_err(DbError::Query)?;

        let after_row = sqlx::query(
            r#"
            update provider_keys
            set status = $3,
                metadata = $4,
                updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, channel_id, key_alias,
              secret_fingerprint is not null as has_secret_fingerprint,
              status,
              health_score::double precision as health_score,
              cooldown_until::text as cooldown_until, last_error_code, rpm_limit,
              tpm_limit, concurrency_limit, current_window_state, metadata,
              true as secret_redacted
            "#,
        )
        .bind(tenant_id)
        .bind(provider_key_id)
        .bind(status)
        .bind(metadata)
        .fetch_one(&mut *tx)
        .await
        .map_err(DbError::Query)?;

        let after = provider_key_from_row(after_row).map_err(DbError::Query)?;
        let audit = build_audit(&before, &after);
        Self::insert_audit_log_in_tx(&mut tx, audit).await?;
        tx.commit().await.map_err(DbError::Query)?;

        Ok(Some(after))
    }

    pub async fn update_provider_key_status(
        &self,
        tenant_id: Uuid,
        provider_key_id: Uuid,
        status: &str,
    ) -> Result<Option<ProviderKey>, DbError> {
        let row = sqlx::query(
            r#"
            update provider_keys
            set status = $3, updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, channel_id, key_alias,
              secret_fingerprint is not null as has_secret_fingerprint,
              status,
              health_score::double precision as health_score,
              cooldown_until::text as cooldown_until, last_error_code, rpm_limit,
              tpm_limit, concurrency_limit, current_window_state, metadata,
              true as secret_redacted
            "#,
        )
        .bind(tenant_id)
        .bind(provider_key_id)
        .bind(status)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(provider_key_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn soft_delete_provider_key(
        &self,
        tenant_id: Uuid,
        provider_key_id: Uuid,
    ) -> Result<Option<ProviderKey>, DbError> {
        let row = sqlx::query(
            r#"
            update provider_keys
            set status = 'deleted', updated_at = now(), deleted_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, channel_id, key_alias,
              secret_fingerprint is not null as has_secret_fingerprint,
              status,
              health_score::double precision as health_score,
              cooldown_until::text as cooldown_until, last_error_code, rpm_limit,
              tpm_limit, concurrency_limit, current_window_state, metadata,
              true as secret_redacted
            "#,
        )
        .bind(tenant_id)
        .bind(provider_key_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(provider_key_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn soft_delete_provider_key_with_audit<F>(
        &self,
        tenant_id: Uuid,
        provider_key_id: Uuid,
        build_audit: F,
    ) -> Result<Option<ProviderKey>, DbError>
    where
        F: FnOnce(&ProviderKey, &ProviderKey) -> NewAuditLog,
    {
        let mut tx = self.pool.begin().await.map_err(DbError::Query)?;
        let before_row = sqlx::query(
            r#"
            select
              id, tenant_id, channel_id, key_alias,
              secret_fingerprint is not null as has_secret_fingerprint,
              status,
              health_score::double precision as health_score,
              cooldown_until::text as cooldown_until, last_error_code, rpm_limit,
              tpm_limit, concurrency_limit, current_window_state, metadata,
              true as secret_redacted
            from provider_keys
            where tenant_id = $1 and id = $2 and deleted_at is null
            for update
            "#,
        )
        .bind(tenant_id)
        .bind(provider_key_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(DbError::Query)?;

        let Some(before_row) = before_row else {
            return Ok(None);
        };
        let before = provider_key_from_row(before_row).map_err(DbError::Query)?;

        let after_row = sqlx::query(
            r#"
            update provider_keys
            set status = 'deleted', updated_at = now(), deleted_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, channel_id, key_alias,
              secret_fingerprint is not null as has_secret_fingerprint,
              status,
              health_score::double precision as health_score,
              cooldown_until::text as cooldown_until, last_error_code, rpm_limit,
              tpm_limit, concurrency_limit, current_window_state, metadata,
              true as secret_redacted
            "#,
        )
        .bind(tenant_id)
        .bind(provider_key_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(DbError::Query)?;

        let after = provider_key_from_row(after_row).map_err(DbError::Query)?;
        let audit = build_audit(&before, &after);
        Self::insert_audit_log_in_tx(&mut tx, audit).await?;
        tx.commit().await.map_err(DbError::Query)?;

        Ok(Some(after))
    }

    pub async fn upsert_canonical_model(
        &self,
        new_model: NewCanonicalModel,
    ) -> Result<CanonicalModel, DbError> {
        let row = sqlx::query(
            r#"
            insert into canonical_models (
              tenant_id, model_key, display_name, family, capabilities, context_length,
              max_output_tokens, supports_stream, supports_tools, supports_vision,
              supports_audio, supports_reasoning, visibility, status
            )
            values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
            on conflict (tenant_id, model_key) do update
            set display_name = excluded.display_name,
                family = excluded.family,
                capabilities = excluded.capabilities,
                context_length = excluded.context_length,
                max_output_tokens = excluded.max_output_tokens,
                supports_stream = excluded.supports_stream,
                supports_tools = excluded.supports_tools,
                supports_vision = excluded.supports_vision,
                supports_audio = excluded.supports_audio,
                supports_reasoning = excluded.supports_reasoning,
                visibility = excluded.visibility,
                status = excluded.status,
                updated_at = now(),
                deleted_at = null
            returning
              id, tenant_id, model_key, display_name, family, capabilities,
              context_length, max_output_tokens, supports_stream, supports_tools,
              supports_vision, supports_audio, supports_reasoning, visibility, status
            "#,
        )
        .bind(new_model.tenant_id)
        .bind(new_model.model_key)
        .bind(new_model.display_name)
        .bind(new_model.family)
        .bind(new_model.capabilities)
        .bind(new_model.context_length)
        .bind(new_model.max_output_tokens)
        .bind(new_model.supports_stream)
        .bind(new_model.supports_tools)
        .bind(new_model.supports_vision)
        .bind(new_model.supports_audio)
        .bind(new_model.supports_reasoning)
        .bind(new_model.visibility)
        .bind(new_model.status)
        .fetch_one(&self.pool)
        .await
        .map_err(DbError::Query)?;

        canonical_model_from_row(row).map_err(DbError::Query)
    }

    pub async fn get_canonical_model_by_key(
        &self,
        tenant_id: Uuid,
        model_key: &str,
    ) -> Result<Option<CanonicalModel>, DbError> {
        let row = sqlx::query(
            r#"
            select
              id, tenant_id, model_key, display_name, family, capabilities,
              context_length, max_output_tokens, supports_stream, supports_tools,
              supports_vision, supports_audio, supports_reasoning, visibility, status
            from canonical_models
            where tenant_id = $1 and model_key = $2 and deleted_at is null
            "#,
        )
        .bind(tenant_id)
        .bind(model_key)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(canonical_model_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn get_canonical_model(
        &self,
        tenant_id: Uuid,
        canonical_model_id: Uuid,
    ) -> Result<Option<CanonicalModel>, DbError> {
        let row = sqlx::query(
            r#"
            select
              id, tenant_id, model_key, display_name, family, capabilities,
              context_length, max_output_tokens, supports_stream, supports_tools,
              supports_vision, supports_audio, supports_reasoning, visibility, status
            from canonical_models
            where tenant_id = $1 and id = $2 and deleted_at is null
            "#,
        )
        .bind(tenant_id)
        .bind(canonical_model_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(canonical_model_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn list_canonical_models(
        &self,
        tenant_id: Uuid,
    ) -> Result<Vec<CanonicalModel>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, model_key, display_name, family, capabilities,
              context_length, max_output_tokens, supports_stream, supports_tools,
              supports_vision, supports_audio, supports_reasoning, visibility, status
            from canonical_models
            where tenant_id = $1 and deleted_at is null
            order by model_key
            "#,
        )
        .bind(tenant_id)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, canonical_model_from_row)
    }

    pub async fn update_canonical_model(
        &self,
        tenant_id: Uuid,
        canonical_model_id: Uuid,
        update: UpdateCanonicalModel,
    ) -> Result<Option<CanonicalModel>, DbError> {
        let row = sqlx::query(
            r#"
            update canonical_models
            set model_key = $3,
                display_name = $4,
                family = $5,
                capabilities = $6,
                context_length = $7,
                max_output_tokens = $8,
                supports_stream = $9,
                supports_tools = $10,
                supports_vision = $11,
                supports_audio = $12,
                supports_reasoning = $13,
                visibility = $14,
                status = $15,
                updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, model_key, display_name, family, capabilities,
              context_length, max_output_tokens, supports_stream, supports_tools,
              supports_vision, supports_audio, supports_reasoning, visibility, status
            "#,
        )
        .bind(tenant_id)
        .bind(canonical_model_id)
        .bind(update.model_key)
        .bind(update.display_name)
        .bind(update.family)
        .bind(update.capabilities)
        .bind(update.context_length)
        .bind(update.max_output_tokens)
        .bind(update.supports_stream)
        .bind(update.supports_tools)
        .bind(update.supports_vision)
        .bind(update.supports_audio)
        .bind(update.supports_reasoning)
        .bind(update.visibility)
        .bind(update.status)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(canonical_model_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn update_canonical_model_status(
        &self,
        tenant_id: Uuid,
        canonical_model_id: Uuid,
        status: &str,
    ) -> Result<Option<CanonicalModel>, DbError> {
        let row = sqlx::query(
            r#"
            update canonical_models
            set status = $3, updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, model_key, display_name, family, capabilities,
              context_length, max_output_tokens, supports_stream, supports_tools,
              supports_vision, supports_audio, supports_reasoning, visibility, status
            "#,
        )
        .bind(tenant_id)
        .bind(canonical_model_id)
        .bind(status)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(canonical_model_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn soft_delete_canonical_model(
        &self,
        tenant_id: Uuid,
        canonical_model_id: Uuid,
    ) -> Result<Option<CanonicalModel>, DbError> {
        let row = sqlx::query(
            r#"
            update canonical_models
            set status = 'deleted', updated_at = now(), deleted_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, model_key, display_name, family, capabilities,
              context_length, max_output_tokens, supports_stream, supports_tools,
              supports_vision, supports_audio, supports_reasoning, visibility, status
            "#,
        )
        .bind(tenant_id)
        .bind(canonical_model_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(canonical_model_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn create_model_association(
        &self,
        association: NewModelAssociation,
    ) -> Result<ModelAssociation, DbError> {
        let row = sqlx::query(
            r#"
            insert into model_associations (
              tenant_id, canonical_model_id, association_type, channel_id, channel_tag,
              model_pattern, upstream_model_name, priority, conditions, fallback_allowed,
              canary_percent, status
            )
            values (
              $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
              ($11::double precision)::numeric, $12
            )
            returning
              id, tenant_id, canonical_model_id, association_type, channel_id, channel_tag,
              model_pattern, upstream_model_name, priority, conditions, fallback_allowed,
              canary_percent::double precision as canary_percent, status
            "#,
        )
        .bind(association.tenant_id)
        .bind(association.canonical_model_id)
        .bind(association.association_type)
        .bind(association.channel_id)
        .bind(association.channel_tag)
        .bind(association.model_pattern)
        .bind(association.upstream_model_name)
        .bind(association.priority)
        .bind(association.conditions)
        .bind(association.fallback_allowed)
        .bind(association.canary_percent)
        .bind(association.status)
        .fetch_one(&self.pool)
        .await
        .map_err(DbError::Query)?;

        model_association_from_row(row).map_err(DbError::Query)
    }

    pub async fn list_model_associations_for_model(
        &self,
        tenant_id: Uuid,
        canonical_model_id: Uuid,
    ) -> Result<Vec<ModelAssociation>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, canonical_model_id, association_type, channel_id, channel_tag,
              model_pattern, upstream_model_name, priority, conditions, fallback_allowed,
              canary_percent::double precision as canary_percent, status
            from model_associations
            where tenant_id = $1
              and canonical_model_id = $2
              and status <> 'deleted'
              and deleted_at is null
            order by priority, id
            "#,
        )
        .bind(tenant_id)
        .bind(canonical_model_id)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, model_association_from_row)
    }

    pub async fn list_model_associations(
        &self,
        tenant_id: Uuid,
    ) -> Result<Vec<ModelAssociation>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, canonical_model_id, association_type, channel_id, channel_tag,
              model_pattern, upstream_model_name, priority, conditions, fallback_allowed,
              canary_percent::double precision as canary_percent, status
            from model_associations
            where tenant_id = $1
              and status <> 'deleted'
              and deleted_at is null
            order by canonical_model_id, priority, id
            "#,
        )
        .bind(tenant_id)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, model_association_from_row)
    }

    pub async fn get_model_association(
        &self,
        tenant_id: Uuid,
        association_id: Uuid,
    ) -> Result<Option<ModelAssociation>, DbError> {
        let row = sqlx::query(
            r#"
            select
              id, tenant_id, canonical_model_id, association_type, channel_id, channel_tag,
              model_pattern, upstream_model_name, priority, conditions, fallback_allowed,
              canary_percent::double precision as canary_percent, status
            from model_associations
            where tenant_id = $1
              and id = $2
              and status <> 'deleted'
              and deleted_at is null
            "#,
        )
        .bind(tenant_id)
        .bind(association_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(model_association_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn update_model_association(
        &self,
        tenant_id: Uuid,
        association_id: Uuid,
        update: UpdateModelAssociation,
    ) -> Result<Option<ModelAssociation>, DbError> {
        let row = sqlx::query(
            r#"
            update model_associations
            set canonical_model_id = $3,
                association_type = $4,
                channel_id = $5,
                channel_tag = $6,
                model_pattern = $7,
                upstream_model_name = $8,
                priority = $9,
                conditions = $10,
                fallback_allowed = $11,
                canary_percent = ($12::double precision)::numeric,
                status = $13,
                updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, canonical_model_id, association_type, channel_id, channel_tag,
              model_pattern, upstream_model_name, priority, conditions, fallback_allowed,
              canary_percent::double precision as canary_percent, status
            "#,
        )
        .bind(tenant_id)
        .bind(association_id)
        .bind(update.canonical_model_id)
        .bind(update.association_type)
        .bind(update.channel_id)
        .bind(update.channel_tag)
        .bind(update.model_pattern)
        .bind(update.upstream_model_name)
        .bind(update.priority)
        .bind(update.conditions)
        .bind(update.fallback_allowed)
        .bind(update.canary_percent)
        .bind(update.status)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(model_association_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn update_model_association_status(
        &self,
        tenant_id: Uuid,
        association_id: Uuid,
        status: &str,
    ) -> Result<Option<ModelAssociation>, DbError> {
        let row = sqlx::query(
            r#"
            update model_associations
            set status = $3, updated_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, canonical_model_id, association_type, channel_id, channel_tag,
              model_pattern, upstream_model_name, priority, conditions, fallback_allowed,
              canary_percent::double precision as canary_percent, status
            "#,
        )
        .bind(tenant_id)
        .bind(association_id)
        .bind(status)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(model_association_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn soft_delete_model_association(
        &self,
        tenant_id: Uuid,
        association_id: Uuid,
    ) -> Result<Option<ModelAssociation>, DbError> {
        let row = sqlx::query(
            r#"
            update model_associations
            set status = 'deleted', updated_at = now(), deleted_at = now()
            where tenant_id = $1 and id = $2 and deleted_at is null
            returning
              id, tenant_id, canonical_model_id, association_type, channel_id, channel_tag,
              model_pattern, upstream_model_name, priority, conditions, fallback_allowed,
              canary_percent::double precision as canary_percent, status
            "#,
        )
        .bind(tenant_id)
        .bind(association_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(model_association_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn insert_request_log_started(
        &self,
        request: NewRequestLogStarted,
    ) -> Result<RequestLog, DbError> {
        let row = sqlx::query(
            r#"
            insert into request_logs (
              id, tenant_id, project_id, virtual_key_id, api_key_profile_id,
              trace_id, thread_id, client_request_id, inbound_protocol,
              outbound_protocol, protocol_mode, requested_model, canonical_model_id,
              upstream_model, resolved_provider_id, resolved_channel_id, provider_key_id,
              status, route_decision_snapshot
            )
            values (
              coalesce($1, gen_random_uuid()), $2, $3, $4, $5,
              $6, $7, $8, $9, $10, $11, $12, $13,
              $14, $15, $16, $17, 'started', $18
            )
            returning
              id, tenant_id, project_id, virtual_key_id, api_key_profile_id,
              trace_id, thread_id, client_request_id, inbound_protocol, outbound_protocol,
              protocol_mode, requested_model, canonical_model_id, upstream_model,
              resolved_provider_id, resolved_channel_id, provider_key_id, route_policy_version,
              status, http_status, error_owner, error_code, retryable, partial_sent,
              stream_end_reason, input_tokens, output_tokens, final_cost::text as final_cost,
              currency, latency_ms, ttft_ms, payload_policy_id, payload_stored,
              redaction_status, request_body_hash, response_body_hash,
              created_at::text as created_at, completed_at::text as completed_at,
              route_decision_snapshot
            "#,
        )
        .bind(request.id)
        .bind(request.tenant_id)
        .bind(request.project_id)
        .bind(request.virtual_key_id)
        .bind(request.api_key_profile_id)
        .bind(request.trace_id)
        .bind(request.thread_id)
        .bind(request.client_request_id)
        .bind(request.inbound_protocol)
        .bind(request.outbound_protocol)
        .bind(request.protocol_mode)
        .bind(request.requested_model)
        .bind(request.canonical_model_id)
        .bind(request.upstream_model)
        .bind(request.resolved_provider_id)
        .bind(request.resolved_channel_id)
        .bind(request.provider_key_id)
        .bind(request.route_decision_snapshot)
        .fetch_one(&self.pool)
        .await
        .map_err(DbError::Query)?;

        request_log_from_row(row).map_err(DbError::Query)
    }

    pub async fn finalize_request_log(
        &self,
        tenant_id: Uuid,
        request_id: Uuid,
        update: RequestLogFinalUpdate,
    ) -> Result<Option<RequestLog>, DbError> {
        let row = sqlx::query(
            r#"
            update request_logs
            set status = $3,
                http_status = $4,
                error_owner = $5,
                error_code = $6,
                retryable = $7,
                partial_sent = $8,
                stream_end_reason = $9,
                input_tokens = $10,
                output_tokens = $11,
                latency_ms = $12,
                ttft_ms = $13,
                final_cost = coalesce(($14::text)::numeric, final_cost),
                currency = coalesce($15, currency),
                completed_at = now()
            where tenant_id = $1 and id = $2
            returning
              id, tenant_id, project_id, virtual_key_id, api_key_profile_id,
              trace_id, thread_id, client_request_id, inbound_protocol, outbound_protocol,
              protocol_mode, requested_model, canonical_model_id, upstream_model,
              resolved_provider_id, resolved_channel_id, provider_key_id, route_policy_version,
              status, http_status, error_owner, error_code, retryable, partial_sent,
              stream_end_reason, input_tokens, output_tokens, final_cost::text as final_cost,
              currency, latency_ms, ttft_ms, payload_policy_id, payload_stored,
              redaction_status, request_body_hash, response_body_hash,
              created_at::text as created_at, completed_at::text as completed_at,
              route_decision_snapshot
            "#,
        )
        .bind(tenant_id)
        .bind(request_id)
        .bind(update.status)
        .bind(update.http_status)
        .bind(update.error_owner)
        .bind(update.error_code)
        .bind(update.retryable)
        .bind(update.partial_sent)
        .bind(update.stream_end_reason)
        .bind(update.input_tokens)
        .bind(update.output_tokens)
        .bind(update.latency_ms)
        .bind(update.ttft_ms)
        .bind(update.final_cost)
        .bind(update.currency)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(request_log_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn list_request_logs(
        &self,
        tenant_id: Uuid,
        filter: RequestLogListFilter,
    ) -> Result<Vec<RequestLogSummary>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, project_id, virtual_key_id, api_key_profile_id,
              trace_id, thread_id, client_request_id, inbound_protocol, outbound_protocol,
              protocol_mode, requested_model, canonical_model_id, upstream_model,
              resolved_provider_id, resolved_channel_id, provider_key_id, route_policy_version,
              status, http_status, error_owner, error_code, retryable, partial_sent,
              stream_end_reason, input_tokens, output_tokens, final_cost::text as final_cost,
              currency, latency_ms, ttft_ms, payload_policy_id, payload_stored,
              redaction_status, request_body_hash, response_body_hash,
              created_at::text as created_at, completed_at::text as completed_at
            from request_logs
            where tenant_id = $1
              and ($2::text is null or status = $2)
              and ($3::text is null or requested_model = $3 or upstream_model = $3)
              and ($4::uuid is null or canonical_model_id = $4)
              and ($5::uuid is null or resolved_channel_id = $5)
            order by created_at desc
            limit $6
            "#,
        )
        .bind(tenant_id)
        .bind(filter.status)
        .bind(filter.model)
        .bind(filter.canonical_model_id)
        .bind(filter.channel_id)
        .bind(filter.limit)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, request_log_summary_from_row)
    }

    pub async fn list_request_logs_for_trace(
        &self,
        tenant_id: Uuid,
        filter: RequestTraceFilter,
    ) -> Result<Vec<RequestLogSummary>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, project_id, virtual_key_id, api_key_profile_id,
              trace_id, thread_id, client_request_id, inbound_protocol, outbound_protocol,
              protocol_mode, requested_model, canonical_model_id, upstream_model,
              resolved_provider_id, resolved_channel_id, provider_key_id, route_policy_version,
              status, http_status, error_owner, error_code, retryable, partial_sent,
              stream_end_reason, input_tokens, output_tokens, final_cost::text as final_cost,
              currency, latency_ms, ttft_ms, payload_policy_id, payload_stored,
              redaction_status, request_body_hash, response_body_hash,
              created_at::text as created_at, completed_at::text as completed_at
            from request_logs
            where tenant_id = $1
              and trace_id = $2
            order by created_at desc, id desc
            limit $3
            "#,
        )
        .bind(tenant_id)
        .bind(filter.trace_id)
        .bind(filter.limit)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, request_log_summary_from_row)
    }

    pub async fn get_request_log(
        &self,
        tenant_id: Uuid,
        request_id: Uuid,
    ) -> Result<Option<RequestLog>, DbError> {
        let row = sqlx::query(
            r#"
            select
              id, tenant_id, project_id, virtual_key_id, api_key_profile_id,
              trace_id, thread_id, client_request_id, inbound_protocol, outbound_protocol,
              protocol_mode, requested_model, canonical_model_id, upstream_model,
              resolved_provider_id, resolved_channel_id, provider_key_id, route_policy_version,
              status, http_status, error_owner, error_code, retryable, partial_sent,
              stream_end_reason, input_tokens, output_tokens, final_cost::text as final_cost,
              currency, latency_ms, ttft_ms, payload_policy_id, payload_stored,
              redaction_status, request_body_hash, response_body_hash,
              created_at::text as created_at, completed_at::text as completed_at,
              route_decision_snapshot
            from request_logs
            where tenant_id = $1 and id = $2
            "#,
        )
        .bind(tenant_id)
        .bind(request_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(request_log_from_row)
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn list_price_versions(
        &self,
        tenant_id: Uuid,
        filter: PriceVersionListFilter,
    ) -> Result<Vec<PriceVersion>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, price_book_id, canonical_model_id, version, pricing_rules,
              effective_at::text as effective_at, retired_at::text as retired_at,
              status, created_at::text as created_at
            from price_versions
            where tenant_id = $1
              and ($2::uuid is null or price_book_id = $2)
              and ($3::uuid is null or canonical_model_id = $3)
              and ($4::text is null or status = $4)
            order by effective_at desc, created_at desc, id
            limit $5
            "#,
        )
        .bind(tenant_id)
        .bind(filter.price_book_id)
        .bind(filter.canonical_model_id)
        .bind(filter.status)
        .bind(filter.limit)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, price_version_from_row)
    }

    pub async fn get_price_book_currency(
        &self,
        tenant_id: Uuid,
        price_book_id: Uuid,
    ) -> Result<Option<String>, DbError> {
        let row = sqlx::query(
            r#"
            select currency
            from price_books
            where tenant_id = $1
              and id = $2
              and status <> 'archived'
            "#,
        )
        .bind(tenant_id)
        .bind(price_book_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::Query)?;

        row.map(|row| row.try_get("currency"))
            .transpose()
            .map_err(DbError::Query)
    }

    pub async fn insert_price_version_with_audit<F>(
        &self,
        input: NewPriceVersionInput,
        build_audit: F,
    ) -> Result<Option<PriceVersion>, DbError>
    where
        F: FnOnce(&PriceVersion) -> NewAuditLog,
    {
        let mut tx = self.pool.begin().await.map_err(DbError::Query)?;
        let row = sqlx::query(
            r#"
            insert into price_versions (
              tenant_id, price_book_id, canonical_model_id, version, pricing_rules,
              effective_at, retired_at, status
            )
            select
              $1, $2, $3, $4, $5,
              case when $6::text is null then now() else $6::text::timestamptz end,
              $7::text::timestamptz,
              $8
            where exists (
              select 1
              from price_books pb
              where pb.tenant_id = $1
                and pb.id = $2
                and pb.status <> 'archived'
            )
              and (
                $3::uuid is null
                or exists (
                  select 1
                  from canonical_models m
                  where m.tenant_id = $1
                    and m.id = $3
                    and m.deleted_at is null
                )
              )
            returning
              id, tenant_id, price_book_id, canonical_model_id, version, pricing_rules,
              effective_at::text as effective_at, retired_at::text as retired_at,
              status, created_at::text as created_at
            "#,
        )
        .bind(input.tenant_id)
        .bind(input.price_book_id)
        .bind(input.canonical_model_id)
        .bind(input.version)
        .bind(input.pricing_rules)
        .bind(input.effective_at)
        .bind(input.retired_at)
        .bind(input.status)
        .fetch_optional(&mut *tx)
        .await
        .map_err(DbError::Query)?;

        let Some(row) = row else {
            return Ok(None);
        };
        let price_version = price_version_from_row(row).map_err(DbError::Query)?;
        let audit = build_audit(&price_version);
        Self::insert_audit_log_in_tx(&mut tx, audit).await?;
        tx.commit().await.map_err(DbError::Query)?;

        Ok(Some(price_version))
    }

    pub async fn list_ledger_entries(
        &self,
        tenant_id: Uuid,
        filter: LedgerEntryListFilter,
    ) -> Result<Vec<LedgerEntry>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, project_id, wallet_id, request_id, virtual_key_id, trace_id,
              related_ledger_entry_id, entry_type, amount::text as amount, currency, status,
              idempotency_key, price_version_id, usage_snapshot, policy_snapshot, metadata,
              occurred_at::text as occurred_at, created_at::text as created_at
            from ledger_entries
            where tenant_id = $1
              and ($2::uuid is null or project_id = $2)
              and ($3::uuid is null or request_id = $3)
              and ($4::uuid is null or wallet_id = $4)
            order by created_at desc, id
            limit $5
            "#,
        )
        .bind(tenant_id)
        .bind(filter.project_id)
        .bind(filter.request_id)
        .bind(filter.wallet_id)
        .bind(filter.limit)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, ledger_entry_from_row)
    }

    pub async fn billing_reconciliation_report(
        &self,
        tenant_id: Uuid,
        filter: BillingReconciliationReportFilter,
    ) -> Result<BillingReconciliationReport, DbError> {
        let rows = sqlx::query(BILLING_RECONCILIATION_INPUT_SELECT)
            .bind(tenant_id)
            .bind(filter.day)
            .fetch_all(&self.pool)
            .await
            .map_err(DbError::Query)?;

        let rows = rows
            .into_iter()
            .map(billing_reconciliation_input_from_row)
            .collect::<Result<Vec<_>, _>>()
            .map_err(DbError::Query)?;

        reconcile_billing_usage_ledger(tenant_id, rows, filter.discrepancy_limit)
            .map_err(|error| DbError::InvalidData(error.to_string()))
    }

    pub async fn list_provider_attempts_for_request(
        &self,
        tenant_id: Uuid,
        request_id: Uuid,
    ) -> Result<Vec<ProviderAttemptRead>, DbError> {
        let rows = sqlx::query(
            r#"
            select
              id, tenant_id, request_id, provider_id, channel_id, provider_key_id,
              attempt_no, upstream_model, status, http_status, error_owner, error_code,
              retryable, fallback_reason, latency_ms, ttft_ms, provider_request_id,
              input_tokens, output_tokens, started_at::text as started_at,
              completed_at::text as completed_at
            from provider_attempts
            where tenant_id = $1 and request_id = $2
            order by attempt_no
            "#,
        )
        .bind(tenant_id)
        .bind(request_id)
        .fetch_all(&self.pool)
        .await
        .map_err(DbError::Query)?;

        map_rows(rows, provider_attempt_read_from_row)
    }

    pub async fn insert_provider_attempt(
        &self,
        attempt: NewProviderAttempt,
    ) -> Result<ProviderAttempt, DbError> {
        let row = sqlx::query(
            r#"
            insert into provider_attempts (
              tenant_id, request_id, provider_id, channel_id, provider_key_id,
              attempt_no, upstream_model, status, http_status, error_owner,
              error_code, retryable, fallback_reason, latency_ms, ttft_ms,
              provider_request_id, input_tokens, output_tokens, metadata, completed_at
            )
            values (
              $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
              $11, $12, $13, $14, $15, $16, $17, $18, $19,
              case when $20 then now() else null end
            )
            returning
              id, tenant_id, request_id, provider_id, channel_id, provider_key_id,
              attempt_no, upstream_model, status, http_status, error_owner, error_code,
              retryable, fallback_reason, latency_ms, ttft_ms, provider_request_id,
              input_tokens, output_tokens, metadata
            "#,
        )
        .bind(attempt.tenant_id)
        .bind(attempt.request_id)
        .bind(attempt.provider_id)
        .bind(attempt.channel_id)
        .bind(attempt.provider_key_id)
        .bind(attempt.attempt_no)
        .bind(attempt.upstream_model)
        .bind(attempt.status)
        .bind(attempt.http_status)
        .bind(attempt.error_owner)
        .bind(attempt.error_code)
        .bind(attempt.retryable)
        .bind(attempt.fallback_reason)
        .bind(attempt.latency_ms)
        .bind(attempt.ttft_ms)
        .bind(attempt.provider_request_id)
        .bind(attempt.input_tokens)
        .bind(attempt.output_tokens)
        .bind(attempt.metadata)
        .bind(attempt.completed)
        .fetch_one(&self.pool)
        .await
        .map_err(DbError::Query)?;

        provider_attempt_from_row(row).map_err(DbError::Query)
    }
}

const ROUTE_CANDIDATES_FOR_MODEL_SELECT: &str = r#"
select
  ma.id as association_id,
  ma.tenant_id as association_tenant_id,
  ma.canonical_model_id as association_canonical_model_id,
  ma.association_type as association_type,
  ma.channel_id as association_channel_id,
  ma.channel_tag as association_channel_tag,
  ma.model_pattern as association_model_pattern,
  ma.upstream_model_name as association_upstream_model_name,
  ma.priority as association_priority,
  ma.conditions as association_conditions,
  ma.fallback_allowed as association_fallback_allowed,
  ma.canary_percent::double precision as association_canary_percent,
  ma.status as association_status,
  ch.id as channel_id,
  ch.tenant_id as channel_tenant_id,
  ch.provider_id as channel_provider_id,
  ch.name as channel_name,
  ch.endpoint as channel_endpoint,
  ch.protocol_mode as channel_protocol_mode,
  ch.status as channel_status,
  ch.region as channel_region,
  ch.priority as channel_priority,
  ch.weight as channel_weight,
  ch.tags as channel_tags,
  ch.model_mappings as channel_model_mappings,
  ch.request_overrides as channel_request_overrides,
  ch.timeout_policy as channel_timeout_policy,
  ch.probe_policy as channel_probe_policy,
  ch.health_score::double precision as channel_health_score,
  pr.id as provider_id,
  pr.tenant_id as provider_tenant_id,
  pr.code as provider_code,
  pr.name as provider_name,
  pr.status as provider_status,
  pr.metadata as provider_metadata,
  coalesce(ma.upstream_model_name, ch.model_mappings ->> $4, $4) as resolved_upstream_model_name
from api_key_profiles p
join model_associations ma
  on ma.tenant_id = p.tenant_id
 and ma.canonical_model_id = $3
 and ma.status = 'enabled'
 and ma.deleted_at is null
join channels ch
  on ch.tenant_id = ma.tenant_id
 and (
   (ma.association_type = 'explicit_channel' and ch.id = ma.channel_id)
   or (ma.association_type = 'channel_tag' and ma.channel_tag is not null and ch.tags ? ma.channel_tag)
   or ma.association_type = 'global'
   or (ma.association_type = 'model_pattern' and ma.model_pattern is not null and $4 ~ ma.model_pattern)
 )
 and ch.status <> 'deleted'
 and ch.deleted_at is null
join providers pr
  on pr.tenant_id = ch.tenant_id
 and pr.id = ch.provider_id
 and pr.status = 'enabled'
 and pr.deleted_at is null
where p.tenant_id = $1
  and p.id = $2
  and p.status = 'active'
  and p.deleted_at is null
  and (
    coalesce(jsonb_array_length(p.allowed_channel_tags), 0) = 0
    or exists (
      select 1
      from jsonb_array_elements_text(p.allowed_channel_tags) allowed(tag)
      where ch.tags ? allowed.tag
    )
  )
  and not (coalesce(p.blocked_provider_ids, '[]'::jsonb) ? pr.id::text)
order by ma.priority, ch.priority, ch.weight desc, ma.id, ch.id
"#;

const CHANNEL_SELECT_BY_ID: &str = r#"
select
  id, tenant_id, provider_id, name, endpoint, protocol_mode, status, region,
  priority, weight, tags, model_mappings, request_overrides, timeout_policy,
  probe_policy, health_score::double precision as health_score
from channels
where tenant_id = $1 and id = $2 and deleted_at is null
"#;

const BILLING_RECONCILIATION_INPUT_SELECT: &str = r#"
with bounds as (
  select
    $1::uuid as tenant_id,
    coalesce(($2::text)::date, timezone('UTC', now())::date - 1) as report_day
),
periods as (
  select
    tenant_id,
    (report_day::timestamp at time zone 'UTC') as period_start,
    ((report_day + 1)::timestamp at time zone 'UTC') as period_end
  from bounds
),
request_usage as (
  select
    r.tenant_id,
    r.id as request_id,
    r.project_id,
    r.virtual_key_id,
    r.trace_id,
    r.canonical_model_id,
    r.resolved_provider_id,
    r.resolved_channel_id,
    r.requested_model,
    r.upstream_model,
    r.status as request_status,
    r.input_tokens,
    r.output_tokens,
    r.final_cost::text as request_final_cost,
    r.currency as request_currency,
    r.created_at as request_created_at,
    r.completed_at as request_completed_at
  from request_logs r
  join periods p on p.tenant_id = r.tenant_id
  where r.tenant_id = $1
    and r.status in ('succeeded', 'partial')
    and coalesce(r.completed_at, r.created_at) >= p.period_start
    and coalesce(r.completed_at, r.created_at) < p.period_end
),
ledger_rollup as (
  select
    le.tenant_id,
    le.request_id,
    case when le.request_id is null then le.id else null end as null_request_ledger_id,
    min(le.project_id) as project_id,
    min(le.virtual_key_id) as virtual_key_id,
    min(le.trace_id) as trace_id,
    array_agg(le.id order by le.created_at, le.id) as ledger_entry_ids,
    count(*)::bigint as ledger_entry_count,
    sum(le.amount)::text as ledger_amount,
    case
      when count(distinct le.currency) = 1 then min(le.currency)
      else 'MIXED'
    end as ledger_currency,
    min(le.created_at) as ledger_first_created_at,
    max(le.created_at) as ledger_last_created_at
  from ledger_entries le
  join periods p on p.tenant_id = le.tenant_id
  where le.tenant_id = $1
    and le.entry_type in ('settle', 'refund')
    and le.status in ('pending', 'confirmed')
    and le.occurred_at >= p.period_start
    and le.occurred_at < p.period_end
  group by le.tenant_id, le.request_id, case when le.request_id is null then le.id else null end
),
joined as (
  select
    coalesce(r.tenant_id, l.tenant_id) as row_tenant_id,
    coalesce(r.request_id, l.request_id) as request_id,
    coalesce(r.project_id, l.project_id) as project_id,
    coalesce(r.virtual_key_id, l.virtual_key_id) as virtual_key_id,
    coalesce(r.trace_id, l.trace_id) as trace_id,
    r.canonical_model_id,
    r.resolved_provider_id,
    r.resolved_channel_id,
    r.requested_model,
    r.upstream_model,
    r.request_status,
    r.input_tokens,
    r.output_tokens,
    r.request_final_cost,
    r.request_currency,
    l.ledger_entry_ids,
    l.ledger_entry_count,
    l.ledger_amount,
    l.ledger_currency,
    r.request_created_at,
    r.request_completed_at,
    l.ledger_first_created_at,
    l.ledger_last_created_at
  from request_usage r
  full outer join ledger_rollup l
    on l.tenant_id = r.tenant_id
   and l.request_id = r.request_id
)
select
  p.tenant_id,
  p.period_start::text as period_start,
  p.period_end::text as period_end,
  j.request_id,
  j.project_id,
  j.virtual_key_id,
  j.trace_id,
  j.canonical_model_id,
  j.resolved_provider_id,
  j.resolved_channel_id,
  j.requested_model,
  j.upstream_model,
  j.request_status,
  j.input_tokens,
  j.output_tokens,
  j.request_final_cost,
  j.request_currency,
  j.ledger_entry_ids,
  j.ledger_entry_count,
  j.ledger_amount,
  j.ledger_currency
from periods p
left join joined j on j.row_tenant_id = p.tenant_id
order by coalesce(j.request_completed_at, j.request_created_at, j.ledger_last_created_at) desc nulls last,
         j.request_id nulls last
"#;

fn map_rows<T>(
    rows: Vec<PgRow>,
    mapper: fn(PgRow) -> Result<T, sqlx::Error>,
) -> Result<Vec<T>, DbError> {
    rows.into_iter()
        .map(mapper)
        .collect::<Result<Vec<_>, _>>()
        .map_err(DbError::Query)
}

fn audit_log_from_row(row: PgRow) -> Result<AuditLog, sqlx::Error> {
    Ok(AuditLog {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        actor_user_id: row.try_get("actor_user_id")?,
        request_id: row.try_get("request_id")?,
        action: row.try_get("action")?,
        resource_type: row.try_get("resource_type")?,
        resource_id: row.try_get("resource_id")?,
        resource_tenant_id: row.try_get("resource_tenant_id")?,
        before_snapshot: row.try_get("before_snapshot")?,
        after_snapshot: row.try_get("after_snapshot")?,
        metadata: row.try_get("metadata")?,
        created_at: row.try_get("created_at")?,
    })
}

fn virtual_key_from_row(row: PgRow) -> Result<VirtualKey, sqlx::Error> {
    Ok(VirtualKey {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        project_id: row.try_get("project_id")?,
        name: row.try_get("name")?,
        key_prefix: row.try_get("key_prefix")?,
        secret_hash: row.try_get("secret_hash")?,
        status: row.try_get("status")?,
        default_profile_id: row.try_get("default_profile_id")?,
        ip_allowlist: row.try_get("ip_allowlist")?,
        rate_limit_policy: row.try_get("rate_limit_policy")?,
        budget_policy: row.try_get("budget_policy")?,
        metadata: row.try_get("metadata")?,
    })
}

fn api_key_profile_from_row(row: PgRow) -> Result<ApiKeyProfile, sqlx::Error> {
    Ok(ApiKeyProfile {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        project_id: row.try_get("project_id")?,
        name: row.try_get("name")?,
        inbound_protocol: row.try_get("inbound_protocol")?,
        default_protocol_mode: row.try_get("default_protocol_mode")?,
        model_aliases: row.try_get("model_aliases")?,
        allowed_models: row.try_get("allowed_models")?,
        denied_models: row.try_get("denied_models")?,
        allowed_channel_tags: row.try_get("allowed_channel_tags")?,
        blocked_provider_ids: row.try_get("blocked_provider_ids")?,
        trace_header_rules: row.try_get("trace_header_rules")?,
        ip_allowlist: row.try_get("ip_allowlist")?,
        request_overrides: row.try_get("request_overrides")?,
        payload_policy_id: row.try_get("payload_policy_id")?,
        status: row.try_get("status")?,
    })
}

fn provider_from_row(row: PgRow) -> Result<Provider, sqlx::Error> {
    Ok(Provider {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        code: row.try_get("code")?,
        name: row.try_get("name")?,
        status: row.try_get("status")?,
        metadata: row.try_get("metadata")?,
    })
}

fn channel_from_row(row: PgRow) -> Result<Channel, sqlx::Error> {
    Ok(Channel {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        provider_id: row.try_get("provider_id")?,
        name: row.try_get("name")?,
        endpoint: row.try_get("endpoint")?,
        protocol_mode: row.try_get("protocol_mode")?,
        status: row.try_get("status")?,
        region: row.try_get("region")?,
        priority: row.try_get("priority")?,
        weight: row.try_get("weight")?,
        tags: row.try_get("tags")?,
        model_mappings: row.try_get("model_mappings")?,
        request_overrides: row.try_get("request_overrides")?,
        timeout_policy: row.try_get("timeout_policy")?,
        probe_policy: row.try_get("probe_policy")?,
        health_score: row.try_get("health_score")?,
    })
}

fn provider_key_from_row(row: PgRow) -> Result<ProviderKey, sqlx::Error> {
    Ok(ProviderKey {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        channel_id: row.try_get("channel_id")?,
        key_alias: row.try_get("key_alias")?,
        has_secret_fingerprint: row.try_get("has_secret_fingerprint")?,
        status: row.try_get("status")?,
        health_score: row.try_get("health_score")?,
        cooldown_until: row.try_get("cooldown_until")?,
        last_error_code: row.try_get("last_error_code")?,
        rpm_limit: row.try_get("rpm_limit")?,
        tpm_limit: row.try_get("tpm_limit")?,
        concurrency_limit: row.try_get("concurrency_limit")?,
        current_window_state: row.try_get("current_window_state")?,
        metadata: row.try_get("metadata")?,
        secret_redacted: row.try_get("secret_redacted")?,
    })
}

fn recovery_probe_candidate_from_row(row: PgRow) -> Result<RecoveryProbeCandidate, sqlx::Error> {
    Ok(RecoveryProbeCandidate {
        tenant_id: row.try_get("tenant_id")?,
        provider_id: row.try_get("provider_id")?,
        provider_code: row.try_get("provider_code")?,
        provider_name: row.try_get("provider_name")?,
        channel_id: row.try_get("channel_id")?,
        channel_name: row.try_get("channel_name")?,
        channel_endpoint: row.try_get("channel_endpoint")?,
        channel_protocol_mode: row.try_get("channel_protocol_mode")?,
        channel_status: row.try_get("channel_status")?,
        provider_key_id: row.try_get("provider_key_id")?,
        key_alias: row.try_get("key_alias")?,
        provider_key_status: row.try_get("provider_key_status")?,
        provider_key_health_score: row.try_get("provider_key_health_score")?,
        cooldown_until: row.try_get("cooldown_until")?,
        last_error_code: row.try_get("last_error_code")?,
        has_secret_fingerprint: row.try_get("has_secret_fingerprint")?,
        secret_redacted: row.try_get("secret_redacted")?,
    })
}

fn canonical_model_from_row(row: PgRow) -> Result<CanonicalModel, sqlx::Error> {
    Ok(CanonicalModel {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        model_key: row.try_get("model_key")?,
        display_name: row.try_get("display_name")?,
        family: row.try_get("family")?,
        capabilities: row.try_get("capabilities")?,
        context_length: row.try_get("context_length")?,
        max_output_tokens: row.try_get("max_output_tokens")?,
        supports_stream: row.try_get("supports_stream")?,
        supports_tools: row.try_get("supports_tools")?,
        supports_vision: row.try_get("supports_vision")?,
        supports_audio: row.try_get("supports_audio")?,
        supports_reasoning: row.try_get("supports_reasoning")?,
        visibility: row.try_get("visibility")?,
        status: row.try_get("status")?,
    })
}

fn model_association_from_row(row: PgRow) -> Result<ModelAssociation, sqlx::Error> {
    Ok(ModelAssociation {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        canonical_model_id: row.try_get("canonical_model_id")?,
        association_type: row.try_get("association_type")?,
        channel_id: row.try_get("channel_id")?,
        channel_tag: row.try_get("channel_tag")?,
        model_pattern: row.try_get("model_pattern")?,
        upstream_model_name: row.try_get("upstream_model_name")?,
        priority: row.try_get("priority")?,
        conditions: row.try_get("conditions")?,
        fallback_allowed: row.try_get("fallback_allowed")?,
        canary_percent: row.try_get("canary_percent")?,
        status: row.try_get("status")?,
    })
}

fn route_candidate_from_row(row: PgRow) -> Result<RouteCandidate, sqlx::Error> {
    Ok(RouteCandidate {
        association: ModelAssociation {
            id: row.try_get("association_id")?,
            tenant_id: row.try_get("association_tenant_id")?,
            canonical_model_id: row.try_get("association_canonical_model_id")?,
            association_type: row.try_get("association_type")?,
            channel_id: row.try_get("association_channel_id")?,
            channel_tag: row.try_get("association_channel_tag")?,
            model_pattern: row.try_get("association_model_pattern")?,
            upstream_model_name: row.try_get("association_upstream_model_name")?,
            priority: row.try_get("association_priority")?,
            conditions: row.try_get("association_conditions")?,
            fallback_allowed: row.try_get("association_fallback_allowed")?,
            canary_percent: row.try_get("association_canary_percent")?,
            status: row.try_get("association_status")?,
        },
        channel: Channel {
            id: row.try_get("channel_id")?,
            tenant_id: row.try_get("channel_tenant_id")?,
            provider_id: row.try_get("channel_provider_id")?,
            name: row.try_get("channel_name")?,
            endpoint: row.try_get("channel_endpoint")?,
            protocol_mode: row.try_get("channel_protocol_mode")?,
            status: row.try_get("channel_status")?,
            region: row.try_get("channel_region")?,
            priority: row.try_get("channel_priority")?,
            weight: row.try_get("channel_weight")?,
            tags: row.try_get("channel_tags")?,
            model_mappings: row.try_get("channel_model_mappings")?,
            request_overrides: row.try_get("channel_request_overrides")?,
            timeout_policy: row.try_get("channel_timeout_policy")?,
            probe_policy: row.try_get("channel_probe_policy")?,
            health_score: row.try_get("channel_health_score")?,
        },
        provider: Provider {
            id: row.try_get("provider_id")?,
            tenant_id: row.try_get("provider_tenant_id")?,
            code: row.try_get("provider_code")?,
            name: row.try_get("provider_name")?,
            status: row.try_get("provider_status")?,
            metadata: row.try_get("provider_metadata")?,
        },
        resolved_upstream_model_name: row.try_get("resolved_upstream_model_name")?,
    })
}

fn request_log_from_row(row: PgRow) -> Result<RequestLog, sqlx::Error> {
    Ok(RequestLog {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        project_id: row.try_get("project_id")?,
        virtual_key_id: row.try_get("virtual_key_id")?,
        api_key_profile_id: row.try_get("api_key_profile_id")?,
        trace_id: row.try_get("trace_id")?,
        thread_id: row.try_get("thread_id")?,
        client_request_id: row.try_get("client_request_id")?,
        inbound_protocol: row.try_get("inbound_protocol")?,
        outbound_protocol: row.try_get("outbound_protocol")?,
        protocol_mode: row.try_get("protocol_mode")?,
        requested_model: row.try_get("requested_model")?,
        canonical_model_id: row.try_get("canonical_model_id")?,
        upstream_model: row.try_get("upstream_model")?,
        resolved_provider_id: row.try_get("resolved_provider_id")?,
        resolved_channel_id: row.try_get("resolved_channel_id")?,
        provider_key_id: row.try_get("provider_key_id")?,
        route_policy_version: row.try_get("route_policy_version")?,
        status: row.try_get("status")?,
        http_status: row.try_get("http_status")?,
        error_owner: row.try_get("error_owner")?,
        error_code: row.try_get("error_code")?,
        retryable: row.try_get("retryable")?,
        partial_sent: row.try_get("partial_sent")?,
        stream_end_reason: row.try_get("stream_end_reason")?,
        input_tokens: row.try_get("input_tokens")?,
        output_tokens: row.try_get("output_tokens")?,
        final_cost: row.try_get("final_cost")?,
        currency: row.try_get("currency")?,
        latency_ms: row.try_get("latency_ms")?,
        ttft_ms: row.try_get("ttft_ms")?,
        payload_policy_id: row.try_get("payload_policy_id")?,
        payload_stored: row.try_get("payload_stored")?,
        redaction_status: row.try_get("redaction_status")?,
        request_body_hash: row.try_get("request_body_hash")?,
        response_body_hash: row.try_get("response_body_hash")?,
        created_at: row.try_get("created_at")?,
        completed_at: row.try_get("completed_at")?,
        route_decision_snapshot: row.try_get("route_decision_snapshot")?,
    })
}

fn request_log_summary_from_row(row: PgRow) -> Result<RequestLogSummary, sqlx::Error> {
    Ok(RequestLogSummary {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        project_id: row.try_get("project_id")?,
        virtual_key_id: row.try_get("virtual_key_id")?,
        api_key_profile_id: row.try_get("api_key_profile_id")?,
        trace_id: row.try_get("trace_id")?,
        thread_id: row.try_get("thread_id")?,
        client_request_id: row.try_get("client_request_id")?,
        inbound_protocol: row.try_get("inbound_protocol")?,
        outbound_protocol: row.try_get("outbound_protocol")?,
        protocol_mode: row.try_get("protocol_mode")?,
        requested_model: row.try_get("requested_model")?,
        canonical_model_id: row.try_get("canonical_model_id")?,
        upstream_model: row.try_get("upstream_model")?,
        resolved_provider_id: row.try_get("resolved_provider_id")?,
        resolved_channel_id: row.try_get("resolved_channel_id")?,
        provider_key_id: row.try_get("provider_key_id")?,
        route_policy_version: row.try_get("route_policy_version")?,
        status: row.try_get("status")?,
        http_status: row.try_get("http_status")?,
        error_owner: row.try_get("error_owner")?,
        error_code: row.try_get("error_code")?,
        retryable: row.try_get("retryable")?,
        partial_sent: row.try_get("partial_sent")?,
        stream_end_reason: row.try_get("stream_end_reason")?,
        input_tokens: row.try_get("input_tokens")?,
        output_tokens: row.try_get("output_tokens")?,
        final_cost: row.try_get("final_cost")?,
        currency: row.try_get("currency")?,
        latency_ms: row.try_get("latency_ms")?,
        ttft_ms: row.try_get("ttft_ms")?,
        payload_policy_id: row.try_get("payload_policy_id")?,
        payload_stored: row.try_get("payload_stored")?,
        redaction_status: row.try_get("redaction_status")?,
        request_body_hash: row.try_get("request_body_hash")?,
        response_body_hash: row.try_get("response_body_hash")?,
        created_at: row.try_get("created_at")?,
        completed_at: row.try_get("completed_at")?,
    })
}

fn price_version_from_row(row: PgRow) -> Result<PriceVersion, sqlx::Error> {
    Ok(PriceVersion {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        price_book_id: row.try_get("price_book_id")?,
        canonical_model_id: row.try_get("canonical_model_id")?,
        version: row.try_get("version")?,
        pricing_rules: row.try_get("pricing_rules")?,
        effective_at: row.try_get("effective_at")?,
        retired_at: row.try_get("retired_at")?,
        status: row.try_get("status")?,
        created_at: row.try_get("created_at")?,
    })
}

fn ledger_entry_from_row(row: PgRow) -> Result<LedgerEntry, sqlx::Error> {
    Ok(LedgerEntry {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        project_id: row.try_get("project_id")?,
        wallet_id: row.try_get("wallet_id")?,
        request_id: row.try_get("request_id")?,
        virtual_key_id: row.try_get("virtual_key_id")?,
        trace_id: row.try_get("trace_id")?,
        related_ledger_entry_id: row.try_get("related_ledger_entry_id")?,
        entry_type: row.try_get("entry_type")?,
        amount: row.try_get("amount")?,
        currency: row.try_get("currency")?,
        status: row.try_get("status")?,
        idempotency_key: row.try_get("idempotency_key")?,
        price_version_id: row.try_get("price_version_id")?,
        usage_snapshot: row.try_get("usage_snapshot")?,
        policy_snapshot: row.try_get("policy_snapshot")?,
        metadata: row.try_get("metadata")?,
        occurred_at: row.try_get("occurred_at")?,
        created_at: row.try_get("created_at")?,
    })
}

fn billing_reconciliation_input_from_row(
    row: PgRow,
) -> Result<BillingReconciliationInputRow, sqlx::Error> {
    Ok(BillingReconciliationInputRow {
        tenant_id: row.try_get("tenant_id")?,
        period_start: row.try_get("period_start")?,
        period_end: row.try_get("period_end")?,
        request_id: row.try_get("request_id")?,
        project_id: row.try_get("project_id")?,
        virtual_key_id: row.try_get("virtual_key_id")?,
        trace_id: row.try_get("trace_id")?,
        canonical_model_id: row.try_get("canonical_model_id")?,
        resolved_provider_id: row.try_get("resolved_provider_id")?,
        resolved_channel_id: row.try_get("resolved_channel_id")?,
        requested_model: row.try_get("requested_model")?,
        upstream_model: row.try_get("upstream_model")?,
        request_status: row.try_get("request_status")?,
        input_tokens: row.try_get("input_tokens")?,
        output_tokens: row.try_get("output_tokens")?,
        request_final_cost: row.try_get("request_final_cost")?,
        request_currency: row.try_get("request_currency")?,
        ledger_entry_ids: row
            .try_get::<Option<Vec<Uuid>>, _>("ledger_entry_ids")?
            .unwrap_or_default(),
        ledger_entry_count: row
            .try_get::<Option<i64>, _>("ledger_entry_count")?
            .unwrap_or(0),
        ledger_amount: row.try_get("ledger_amount")?,
        ledger_currency: row.try_get("ledger_currency")?,
    })
}

fn provider_attempt_from_row(row: PgRow) -> Result<ProviderAttempt, sqlx::Error> {
    Ok(ProviderAttempt {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        request_id: row.try_get("request_id")?,
        provider_id: row.try_get("provider_id")?,
        channel_id: row.try_get("channel_id")?,
        provider_key_id: row.try_get("provider_key_id")?,
        attempt_no: row.try_get("attempt_no")?,
        upstream_model: row.try_get("upstream_model")?,
        status: row.try_get("status")?,
        http_status: row.try_get("http_status")?,
        error_owner: row.try_get("error_owner")?,
        error_code: row.try_get("error_code")?,
        retryable: row.try_get("retryable")?,
        fallback_reason: row.try_get("fallback_reason")?,
        latency_ms: row.try_get("latency_ms")?,
        ttft_ms: row.try_get("ttft_ms")?,
        provider_request_id: row.try_get("provider_request_id")?,
        input_tokens: row.try_get("input_tokens")?,
        output_tokens: row.try_get("output_tokens")?,
        metadata: row.try_get("metadata")?,
    })
}

fn provider_attempt_read_from_row(row: PgRow) -> Result<ProviderAttemptRead, sqlx::Error> {
    Ok(ProviderAttemptRead {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        request_id: row.try_get("request_id")?,
        provider_id: row.try_get("provider_id")?,
        channel_id: row.try_get("channel_id")?,
        provider_key_id: row.try_get("provider_key_id")?,
        attempt_no: row.try_get("attempt_no")?,
        upstream_model: row.try_get("upstream_model")?,
        status: row.try_get("status")?,
        http_status: row.try_get("http_status")?,
        error_owner: row.try_get("error_owner")?,
        error_code: row.try_get("error_code")?,
        retryable: row.try_get("retryable")?,
        fallback_reason: row.try_get("fallback_reason")?,
        latency_ms: row.try_get("latency_ms")?,
        ttft_ms: row.try_get("ttft_ms")?,
        provider_request_id: row.try_get("provider_request_id")?,
        input_tokens: row.try_get("input_tokens")?,
        output_tokens: row.try_get("output_tokens")?,
        started_at: row.try_get("started_at")?,
        completed_at: row.try_get("completed_at")?,
    })
}
