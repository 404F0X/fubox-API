use std::net::IpAddr;

use ai_gateway_auth::keys::parse_virtual_key;
use ai_gateway_config::AppConfig;
use ai_gateway_routing::{
    ChannelModelMappingPolicy, ExplicitModelMapping, ModelNameCasePolicy, map_upstream_model_name,
};
use serde::Serialize;
use serde_json::{Value, json};
use sqlx::{Pool, Postgres, Row, postgres::PgPoolOptions, types::Json};
use uuid::Uuid;

use crate::errors::GatewayApiError;

type PgPool = Pool<Postgres>;

#[derive(Debug, Clone)]
pub struct GatewayRepository {
    pool: PgPool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthContext {
    pub tenant_id: Uuid,
    pub project_id: Uuid,
    pub virtual_key_id: Uuid,
    pub api_key_profile_id: Option<Uuid>,
    pub payload_policy_id: Option<Uuid>,
    pub payload_policy_mode: Option<String>,
    pub key_prefix: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct VisibleModel {
    pub id: String,
    pub object: &'static str,
    pub created: i64,
    pub owned_by: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedCanonicalModel {
    pub id: Uuid,
    pub model_key: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ResolvedChatRoute {
    pub canonical_model_id: Uuid,
    pub canonical_model_key: String,
    pub model_association_id: Uuid,
    pub association_type: String,
    pub provider_id: Uuid,
    pub channel_id: Uuid,
    pub provider_key_id: Uuid,
    pub channel_name: String,
    pub endpoint: String,
    pub protocol_mode: String,
    pub upstream_model: String,
    pub channel_status: String,
    pub fallback_allowed: bool,
    pub association_priority: i32,
    pub channel_priority: i32,
    pub channel_weight: i32,
    pub channel_health_score: f64,
    pub provider_key_rpm_limit: Option<i32>,
    pub provider_key_tpm_limit: Option<i32>,
    pub provider_key_concurrency_limit: Option<i32>,
    pub provider_key_current_window_state: Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraceAffinityPreviousSuccessRoute {
    pub channel_id: Uuid,
    pub provider_id: Uuid,
    pub canonical_model_id: Option<Uuid>,
    pub upstream_model: Option<String>,
}

const MODEL_MAPPING_EXPLICIT_MAPPINGS_KEY: &str = "explicit_mappings";
const MODEL_MAPPING_LEGACY_MAPPINGS_KEY: &str = "mappings";
const MODEL_MAPPING_TRIM_PREFIXES_KEY: &str = "trim_prefixes";
const MODEL_MAPPING_TRIM_PREFIX_KEY: &str = "trim_prefix";
const MODEL_MAPPING_CASE_POLICY_KEY: &str = "case_policy";
const MODEL_MAPPING_POLICY_KEYS: &[&str] = &[
    MODEL_MAPPING_EXPLICIT_MAPPINGS_KEY,
    MODEL_MAPPING_LEGACY_MAPPINGS_KEY,
    MODEL_MAPPING_TRIM_PREFIXES_KEY,
    MODEL_MAPPING_TRIM_PREFIX_KEY,
    MODEL_MAPPING_CASE_POLICY_KEY,
];

fn resolved_upstream_model_name(
    association_upstream_model_name: Option<&str>,
    canonical_model_key: &str,
    channel_model_mappings: &Value,
) -> String {
    association_upstream_model_name
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| {
            let policy = channel_model_mapping_policy(channel_model_mappings);
            map_upstream_model_name(canonical_model_key, &policy)
        })
}

fn channel_model_mapping_policy(model_mappings: &Value) -> ChannelModelMappingPolicy {
    let mut policy = ChannelModelMappingPolicy::new();
    let Some(object) = model_mappings.as_object() else {
        return policy;
    };

    for (requested_model, upstream_model) in object {
        if MODEL_MAPPING_POLICY_KEYS.contains(&requested_model.as_str()) {
            continue;
        }
        if let Some(upstream_model) = upstream_model.as_str() {
            push_explicit_model_mapping(&mut policy, requested_model, upstream_model);
        }
    }

    push_explicit_model_mappings_from_value(
        &mut policy,
        object.get(MODEL_MAPPING_EXPLICIT_MAPPINGS_KEY),
    );
    push_explicit_model_mappings_from_value(
        &mut policy,
        object.get(MODEL_MAPPING_LEGACY_MAPPINGS_KEY),
    );
    push_trim_prefixes_from_value(&mut policy, object.get(MODEL_MAPPING_TRIM_PREFIXES_KEY));
    push_trim_prefixes_from_value(&mut policy, object.get(MODEL_MAPPING_TRIM_PREFIX_KEY));

    if let Some(case_policy) = object
        .get(MODEL_MAPPING_CASE_POLICY_KEY)
        .and_then(Value::as_str)
    {
        policy.case_policy = ModelNameCasePolicy::parse(case_policy);
    }

    policy
}

fn push_explicit_model_mappings_from_value(
    policy: &mut ChannelModelMappingPolicy,
    value: Option<&Value>,
) {
    match value {
        Some(Value::Object(mappings)) => {
            for (requested_model, upstream_model) in mappings {
                if let Some(upstream_model) = upstream_model.as_str() {
                    push_explicit_model_mapping(policy, requested_model, upstream_model);
                }
            }
        }
        Some(Value::Array(mappings)) => {
            for mapping in mappings {
                let requested_model = mapping
                    .get("requested_model")
                    .or_else(|| mapping.get("requested"))
                    .and_then(Value::as_str);
                let upstream_model = mapping
                    .get("upstream_model")
                    .or_else(|| mapping.get("upstream_model_name"))
                    .or_else(|| mapping.get("upstream"))
                    .and_then(Value::as_str);

                if let (Some(requested_model), Some(upstream_model)) =
                    (requested_model, upstream_model)
                {
                    push_explicit_model_mapping(policy, requested_model, upstream_model);
                }
            }
        }
        _ => {}
    }
}

fn push_explicit_model_mapping(
    policy: &mut ChannelModelMappingPolicy,
    requested_model: &str,
    upstream_model: &str,
) {
    let requested_model = requested_model.trim();
    if requested_model.is_empty() {
        return;
    }

    policy.explicit_mappings.push(ExplicitModelMapping::new(
        requested_model,
        upstream_model.trim(),
    ));
}

fn push_trim_prefixes_from_value(policy: &mut ChannelModelMappingPolicy, value: Option<&Value>) {
    match value {
        Some(Value::String(prefix)) => push_trim_prefix(policy, prefix),
        Some(Value::Array(prefixes)) => {
            for prefix in prefixes {
                if let Some(prefix) = prefix.as_str() {
                    push_trim_prefix(policy, prefix);
                }
            }
        }
        _ => {}
    }
}

fn push_trim_prefix(policy: &mut ChannelModelMappingPolicy, prefix: &str) {
    policy.trim_prefixes.push(prefix.trim().to_string());
}

fn provider_attempt_upstream_model(route: &ResolvedChatRoute) -> &str {
    route.upstream_model.as_str()
}

fn merge_payload_metadata(mut route_decision_snapshot: Value, payload_metadata: Value) -> Value {
    if payload_metadata.is_null() {
        return route_decision_snapshot;
    }

    if let Some(object) = route_decision_snapshot.as_object_mut() {
        object.insert("payload_policy".to_string(), payload_metadata);
        route_decision_snapshot
    } else {
        json!({ "payload_policy": payload_metadata })
    }
}

#[derive(Debug, Clone)]
pub struct RequestRouteLog<'a> {
    pub trace_id: Option<String>,
    pub canonical_model_id: Option<Uuid>,
    pub upstream_model: Option<&'a str>,
    pub resolved_provider_id: Option<Uuid>,
    pub resolved_channel_id: Option<Uuid>,
    pub provider_key_id: Option<Uuid>,
    pub route_policy_version: Option<&'a str>,
    pub route_decision_snapshot: Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedProviderKey {
    pub id: Uuid,
    pub encrypted_secret: String,
}

#[derive(Debug, Clone)]
pub struct RequestFinalUpdate {
    pub status: &'static str,
    pub http_status: i32,
    pub error_owner: Option<String>,
    pub error_code: Option<String>,
    pub retryable: Option<bool>,
    pub latency_ms: i32,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub final_cost: Option<String>,
    pub currency: Option<String>,
    pub price_version_id: Option<Uuid>,
    pub response_body_hash: Option<String>,
    pub payload_stored: bool,
    pub redaction_status: Option<&'static str>,
    pub payload_metadata: Option<Value>,
}

#[derive(Debug, Clone)]
pub struct RequestPayloadLog {
    pub payload_policy_id: Option<Uuid>,
    pub payload_stored: bool,
    pub redaction_status: &'static str,
    pub metadata: Value,
}

#[derive(Debug, Clone)]
pub struct ProviderAttemptFinalUpdate {
    pub status: &'static str,
    pub http_status: i32,
    pub error_owner: Option<String>,
    pub error_code: Option<String>,
    pub retryable: Option<bool>,
    pub fallback_reason: Option<String>,
    pub latency_ms: i32,
    pub metadata: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProviderKeyRuntimeStatusUpdate {
    pub provider_key_id: Uuid,
    pub provider_id: Uuid,
    pub channel_id: Uuid,
    pub status: &'static str,
    pub cooldown_ms: Option<i64>,
    pub last_error_code: String,
    pub metadata: Value,
}

#[derive(Debug, Clone)]
pub struct StreamRequestFinalUpdate {
    pub status: &'static str,
    pub http_status: i32,
    pub error_owner: Option<String>,
    pub error_code: Option<String>,
    pub retryable: Option<bool>,
    pub latency_ms: i32,
    pub partial_sent: bool,
    pub stream_end_reason: &'static str,
    pub ttft_ms: Option<i32>,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub final_cost: Option<String>,
    pub currency: Option<String>,
    pub price_version_id: Option<Uuid>,
    pub response_body_hash: Option<String>,
}

#[derive(Debug, Clone)]
pub struct StreamProviderAttemptFinalUpdate {
    pub status: &'static str,
    pub http_status: i32,
    pub error_owner: Option<String>,
    pub error_code: Option<String>,
    pub retryable: Option<bool>,
    pub fallback_reason: Option<String>,
    pub latency_ms: i32,
    pub ttft_ms: Option<i32>,
    pub metadata: Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedPriceVersion {
    pub id: Uuid,
    pub pricing_rules_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreAuthorizeReadModel {
    pub wallet: Option<PreAuthorizeWalletBalance>,
    pub budgets: Vec<PreAuthorizeBudgetRemaining>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreAuthorizeWalletBalance {
    pub currency: String,
    pub available_balance: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreAuthorizeBudgetRemaining {
    pub currency: String,
    pub remaining_amount: String,
}

#[derive(Debug, Clone)]
pub struct LedgerSettleEntry<'a> {
    pub request_id: Uuid,
    pub model: &'a str,
    pub final_cost: &'a str,
    pub currency: &'a str,
    pub price_version_id: Uuid,
    pub input_tokens: i64,
    pub output_tokens: i64,
}

const UPDATE_PROVIDER_KEY_RUNTIME_STATUS_SQL: &str = r#"
            update provider_keys pk
               set status = $5,
                   cooldown_until = case
                     when $6::bigint is null then null
                     else now() + (($6::double precision / 1000.0) * interval '1 second')
                   end,
                   last_error_code = $7,
                   metadata = metadata || $8::jsonb,
                   updated_at = now()
             where pk.tenant_id = $1
               and pk.id = $2
               and pk.channel_id = $3
               and pk.status not in ('manual_disabled', 'deleted')
               and exists (
                 select 1
                   from channels c
                  where c.tenant_id = pk.tenant_id
                    and c.id = pk.channel_id
                    and c.provider_id = $4
                    and c.deleted_at is null
               )
            "#;

const RESOLVE_ACTIVE_PRICE_VERSION_SQL: &str = r#"
            with canonical_model as (
              select
                cm.id,
                cm.tenant_id,
                cm.default_price_book_id
              from canonical_models cm
              where cm.tenant_id = $1
                and cm.id = $4
                and cm.status = 'active'
                and cm.deleted_at is null
            ),
            selector_candidates as (
              select
                1 as selector_priority,
                p.default_price_book_id as price_book_id
              from api_key_profiles p
              where p.tenant_id = $1
                and p.project_id = $3
                and p.id = $2
                and p.status = 'active'
                and p.deleted_at is null
                and p.default_price_book_id is not null

              union all

              select
                2 as selector_priority,
                prj.default_price_book_id as price_book_id
              from projects prj
              where prj.tenant_id = $1
                and prj.id = $3
                and prj.status = 'active'
                and prj.deleted_at is null
                and prj.default_price_book_id is not null

              union all

              select
                3 as selector_priority,
                t.default_price_book_id as price_book_id
              from tenants t
              where t.id = $1
                and t.status = 'active'
                and t.deleted_at is null
                and t.default_price_book_id is not null

              union all

              select
                4 as selector_priority,
                cm.default_price_book_id as price_book_id
              from canonical_model cm
              where cm.default_price_book_id is not null
            )
            select
              pv.id,
              (jsonb_build_object('currency', pb.currency) || pv.pricing_rules)::text
                as pricing_rules_json
            from canonical_model cm
            join selector_candidates sc on true
            join price_books pb
              on pb.tenant_id = $1
             and pb.id = sc.price_book_id
             and pb.status = 'active'
             and (pb.project_id is null or pb.project_id = $3)
            join lateral (
              select
                pv.id,
                pv.pricing_rules
              from price_versions pv
              where pv.tenant_id = cm.tenant_id
                and pv.price_book_id = pb.id
                and pv.status = 'active'
                and pv.effective_at <= now()
                and (pv.retired_at is null or pv.retired_at > now())
                and (pv.canonical_model_id = cm.id or pv.canonical_model_id is null)
              order by
                (pv.canonical_model_id is not null) desc,
                pv.effective_at desc,
                pv.created_at desc,
                pv.id asc
              limit 1
            ) pv on true
            order by sc.selector_priority asc
            limit 1
            "#;

const PRE_AUTHORIZE_WALLET_BALANCE_SQL: &str = r#"
            with selected_wallet as (
              select
                w.id,
                w.currency,
                w.balance_floor
              from wallets w
              where w.tenant_id = $1
                and (w.project_id = $2 or w.project_id is null)
                and w.currency = $3
                and w.status = 'active'
                and w.deleted_at is null
              order by (w.project_id = $2) desc, w.created_at asc, w.id asc
              limit 1
            ),
            credit_balance as (
              select coalesce(sum(cg.remaining_amount), 0::numeric) as amount
              from credit_grants cg
              join selected_wallet w
                on w.id = cg.wallet_id
               and w.currency = cg.currency
              where cg.tenant_id = $1
                and cg.status = 'active'
                and cg.valid_from <= now()
                and (cg.valid_until is null or cg.valid_until > now())
            ),
            ledger_balance as (
              select coalesce(sum(le.amount), 0::numeric) as amount
              from ledger_entries le
              join selected_wallet w
                on w.currency = le.currency
               and (
                 le.wallet_id = w.id
                 or (le.wallet_id is null and le.project_id = $2)
               )
              where le.tenant_id = $1
                and le.status in ('pending', 'confirmed')
            )
            select
              w.currency,
              (credit_balance.amount + ledger_balance.amount - w.balance_floor)::text
                as available_balance
            from selected_wallet w
            cross join credit_balance
            cross join ledger_balance
            "#;

const PRE_AUTHORIZE_BUDGET_REMAINING_SQL: &str = r#"
            with active_budgets as (
              select
                b.id,
                b.scope,
                b.currency,
                b.limit_amount,
                case b.period
                  when 'day' then date_trunc('day', now())
                  when 'week' then date_trunc('week', now())
                  when 'month' then date_trunc('month', now())
                  when 'rolling_24h' then now() - interval '24 hours'
                  when 'rolling_7d' then now() - interval '7 days'
                  when 'rolling_30d' then now() - interval '30 days'
                  else b.period_anchor
                end as window_start
              from budgets b
              where b.tenant_id = $1
                and b.currency = $3
                and b.status = 'active'
                and b.deleted_at is null
                and (
                  b.scope = 'tenant'
                  or (b.scope = 'project' and b.project_id = $2)
                  or (b.scope = 'virtual_key' and b.virtual_key_id = $4)
                )
            ),
            budget_spend as (
              select
                b.id,
                coalesce(sum(rl.final_cost), 0::numeric) as spent_amount
              from active_budgets b
              left join request_logs rl
                on rl.tenant_id = $1
               and rl.currency = b.currency
               and rl.status in ('succeeded', 'partial')
               and coalesce(rl.completed_at, rl.created_at) >= b.window_start
               and (
                 b.scope = 'tenant'
                 or (b.scope = 'project' and rl.project_id = $2)
                 or (b.scope = 'virtual_key' and rl.virtual_key_id = $4)
               )
              group by b.id
            )
            select
              b.currency,
              (b.limit_amount - s.spent_amount)::text as remaining_amount
            from active_budgets b
            join budget_spend s on s.id = b.id
            order by
              case b.scope
                when 'virtual_key' then 0
                when 'project' then 1
                else 2
              end,
              b.id asc
            "#;

impl GatewayRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn readyz_check(&self) -> Result<(), GatewayApiError> {
        sqlx::query("select 1")
            .execute(&self.pool)
            .await
            .map_err(|error| GatewayApiError::database_query_failed("database_readyz", error))?;

        Ok(())
    }

    pub async fn authenticate_virtual_key(
        &self,
        raw_key: &str,
        profile_ref: Option<&str>,
        client_ip: IpAddr,
    ) -> Result<AuthContext, GatewayApiError> {
        let parsed = parse_virtual_key(raw_key)
            .map_err(|error| GatewayApiError::invalid_api_key_format(error.to_string()))?;

        let row = sqlx::query(
            r#"
            select
              vk.id,
              vk.tenant_id,
              vk.project_id,
              vk.ip_allowlist as key_ip_allowlist,
              vkb.profile_id as api_key_profile_id,
              case
                when vk.expires_at is not null and vk.expires_at <= now() then 'expired'
                else vk.status
              end as effective_status,
              p.status as profile_status,
              p.ip_allowlist as profile_ip_allowlist,
              p.request_overrides as profile_request_overrides,
              pp.id as payload_policy_id,
              pp.mode as payload_policy_mode
            from virtual_keys vk
            left join lateral (
              select
                b.profile_id
              from virtual_key_profile_bindings b
              join api_key_profiles selected_profile
                on selected_profile.tenant_id = b.tenant_id
               and selected_profile.project_id = b.project_id
               and selected_profile.id = b.profile_id
              where b.tenant_id = vk.tenant_id
                and b.project_id = vk.project_id
                and b.virtual_key_id = vk.id
                and (
                  ($3::text is null and b.is_default = true)
                  or (
                    $3::text is not null
                    and (
                      selected_profile.id::text = lower($3::text)
                      or selected_profile.name = $3
                    )
                  )
                )
              order by
                case
                  when $3::text is not null and selected_profile.id::text = lower($3::text) then 0
                  when $3::text is not null and selected_profile.name = $3 then 1
                  else 2
                end
              limit 1
            ) vkb on true
            left join api_key_profiles p
              on p.tenant_id = vk.tenant_id
             and p.project_id = vk.project_id
             and p.id = vkb.profile_id
             and p.deleted_at is null
            left join payload_policies pp
              on pp.tenant_id = p.tenant_id
             and pp.id = p.payload_policy_id
             and pp.status = 'active'
             and pp.deleted_at is null
            where vk.key_prefix = $1
              and vk.secret_hash = $2
              and vk.status <> 'deleted'
            limit 1
            "#,
        )
        .bind(&parsed.prefix)
        .bind(&parsed.secret_hash)
        .bind(profile_ref)
        .fetch_optional(&self.pool)
        .await
        .map_err(|error| GatewayApiError::database_query_failed("virtual_key_lookup", error))?;

        let Some(row) = row else {
            return Err(GatewayApiError::invalid_api_key());
        };

        let effective_status = row.get::<String, _>("effective_status");
        if effective_status != "active" {
            return Err(GatewayApiError::api_key_forbidden(&effective_status));
        }

        let api_key_profile_id = row.try_get("api_key_profile_id").ok().flatten();
        if profile_ref.is_some() && api_key_profile_id.is_none() {
            return Err(GatewayApiError::api_key_profile_forbidden("unbound"));
        }

        let profile_status = row
            .try_get::<Option<String>, _>("profile_status")
            .ok()
            .flatten();
        if let Some(status) = profile_status.as_deref()
            && status != "active"
        {
            return Err(GatewayApiError::api_key_profile_forbidden(status));
        }
        if api_key_profile_id.is_some() && profile_status.is_none() {
            return Err(GatewayApiError::api_key_profile_forbidden("deleted"));
        }

        let key_ip_allowlist = row.get::<Json<Value>, _>("key_ip_allowlist").0;
        let profile_ip_allowlist = row
            .try_get::<Option<Json<Value>>, _>("profile_ip_allowlist")
            .ok()
            .flatten()
            .map(|value| value.0);
        let profile_request_overrides = row
            .try_get::<Option<Json<Value>>, _>("profile_request_overrides")
            .ok()
            .flatten()
            .map(|value| value.0);
        enforce_auth_ip_allowlists(
            &key_ip_allowlist,
            profile_ip_allowlist.as_ref(),
            profile_request_overrides.as_ref(),
            client_ip,
        )?;

        let context = AuthContext {
            tenant_id: row.get("tenant_id"),
            project_id: row.get("project_id"),
            virtual_key_id: row.get("id"),
            api_key_profile_id,
            payload_policy_id: row.try_get("payload_policy_id").ok().flatten(),
            payload_policy_mode: row.try_get("payload_policy_mode").ok().flatten(),
            key_prefix: parsed.prefix,
        };

        if let Err(error) = sqlx::query(
            r#"
            update virtual_keys
               set last_used_at = now()
             where tenant_id = $1
               and id = $2
               and (last_used_at is null or last_used_at < now() - interval '60 seconds')
            "#,
        )
        .bind(context.tenant_id)
        .bind(context.virtual_key_id)
        .execute(&self.pool)
        .await
        {
            tracing::warn!(%error, "failed to update virtual key last_used_at");
        }

        Ok(context)
    }

    pub async fn list_visible_models(
        &self,
        auth: &AuthContext,
    ) -> Result<Vec<VisibleModel>, GatewayApiError> {
        let rows = sqlx::query(
            r#"
            select
              cm.model_key,
              cm.capabilities,
              cm.supports_stream,
              cm.supports_tools,
              cm.supports_vision,
              cm.supports_audio,
              cm.supports_reasoning
            from canonical_models cm
            left join api_key_profiles p
              on p.tenant_id = cm.tenant_id
             and p.project_id = $3
             and p.id = $2
             and p.deleted_at is null
            where cm.tenant_id = $1
              and cm.status = 'active'
              and cm.deleted_at is null
              and cm.visibility in ('public', 'internal')
              and ($2::uuid is null or p.id is not null)
              and (
                $2::uuid is null
                or coalesce(jsonb_array_length(p.allowed_models), 0) = 0
                or p.allowed_models ? cm.model_key
              )
              and not (coalesce(p.denied_models, '[]'::jsonb) ? cm.model_key)
            order by cm.model_key asc
            "#,
        )
        .bind(auth.tenant_id)
        .bind(auth.api_key_profile_id)
        .bind(auth.project_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|error| GatewayApiError::database_query_failed("list_visible_models", error))?;

        Ok(rows
            .into_iter()
            .map(|row| {
                let id = row.get::<String, _>("model_key");
                let capabilities = row
                    .try_get::<Json<Value>, _>("capabilities")
                    .map(|json| json.0)
                    .unwrap_or_else(|_| json!({}));
                let owned_by = model_owner_from_capabilities(&capabilities);

                VisibleModel {
                    id,
                    object: "model",
                    created: 0,
                    owned_by,
                }
            })
            .collect())
    }

    pub async fn resolve_canonical_model(
        &self,
        auth: &AuthContext,
        requested_model: &str,
    ) -> Result<Option<ResolvedCanonicalModel>, GatewayApiError> {
        let row = sqlx::query(
            r#"
            select
              cm.id,
              cm.model_key
            from canonical_models cm
            left join api_key_profiles p
              on p.tenant_id = cm.tenant_id
             and p.project_id = $3
             and p.id = $2
             and p.status = 'active'
             and p.deleted_at is null
            where cm.tenant_id = $1
              and cm.model_key = coalesce(p.model_aliases ->> $4, $4)
              and cm.status = 'active'
              and cm.deleted_at is null
              and ($2::uuid is null or p.id is not null)
              and (
                $2::uuid is null
                or coalesce(jsonb_array_length(p.allowed_models), 0) = 0
                or p.allowed_models ? cm.model_key
              )
              and not (
                $2::uuid is not null
                and coalesce(p.denied_models, '[]'::jsonb) ? cm.model_key
              )
            limit 1
            "#,
        )
        .bind(auth.tenant_id)
        .bind(auth.api_key_profile_id)
        .bind(auth.project_id)
        .bind(requested_model)
        .fetch_optional(&self.pool)
        .await
        .map_err(|error| {
            GatewayApiError::database_query_failed("resolve_canonical_model", error)
        })?;

        Ok(row.map(|row| ResolvedCanonicalModel {
            id: row.get("id"),
            model_key: row.get("model_key"),
        }))
    }

    pub async fn resolve_chat_route_candidates(
        &self,
        auth: &AuthContext,
        model: &ResolvedCanonicalModel,
    ) -> Result<Vec<ResolvedChatRoute>, GatewayApiError> {
        let rows = sqlx::query(
            r#"
            select
              ma.id as model_association_id,
              ma.association_type,
              ma.upstream_model_name as association_upstream_model_name,
              ma.priority as association_priority,
              ma.fallback_allowed as association_fallback_allowed,
              c.id as channel_id,
              c.name as channel_name,
              c.endpoint,
              c.protocol_mode,
              c.status as channel_status,
              c.model_mappings as channel_model_mappings,
              c.provider_id,
              pk.id as provider_key_id,
              pk.rpm_limit as provider_key_rpm_limit,
              pk.tpm_limit as provider_key_tpm_limit,
              pk.concurrency_limit as provider_key_concurrency_limit,
              pk.current_window_state as provider_key_current_window_state,
              c.priority as channel_priority,
              c.weight as channel_weight,
              least(c.health_score, pk.health_score)::double precision as channel_health_score
            from model_associations ma
            join channels c
              on c.tenant_id = ma.tenant_id
             and c.deleted_at is null
             and c.status <> 'deleted'
             and c.protocol_mode = 'openai_compatible'
             and (
               (ma.association_type = 'explicit_channel' and c.id = ma.channel_id)
               or (ma.association_type = 'channel_tag' and ma.channel_tag is not null and c.tags ? ma.channel_tag)
               or ma.association_type = 'global'
               or (ma.association_type = 'model_pattern' and ma.model_pattern is not null and $5 ~ ma.model_pattern)
             )
            join providers pr
              on pr.tenant_id = c.tenant_id
             and pr.id = c.provider_id
             and pr.status = 'enabled'
             and pr.deleted_at is null
            join lateral (
              select
                pk.id,
                pk.health_score,
                pk.rpm_limit,
                pk.tpm_limit,
                pk.concurrency_limit,
                pk.current_window_state
              from provider_keys pk
              where pk.tenant_id = c.tenant_id
                and pk.channel_id = c.id
                and pk.status in ('enabled', 'degraded', 'recovery_probe')
                and pk.deleted_at is null
                and (pk.cooldown_until is null or pk.cooldown_until <= now())
              order by
                case pk.status
                  when 'enabled' then 0
                  when 'recovery_probe' then 1
                  when 'degraded' then 2
                  else 3
                end asc,
                pk.health_score desc,
                pk.id asc
              limit 1
            ) pk on true
            left join api_key_profiles p
              on p.tenant_id = ma.tenant_id
             and p.project_id = $3
             and p.id = $2
             and p.status = 'active'
             and p.deleted_at is null
            where ma.tenant_id = $1
              and ma.canonical_model_id = $4
              and ma.status = 'enabled'
              and ma.deleted_at is null
              and ($2::uuid is null or p.id is not null)
              and (
                $2::uuid is null
                or coalesce(jsonb_array_length(p.allowed_channel_tags), 0) = 0
                or exists (
                  select 1
                  from jsonb_array_elements_text(p.allowed_channel_tags) allowed(tag)
                  where c.tags ? allowed.tag
                )
              )
              and not (
                $2::uuid is not null
                and coalesce(p.blocked_provider_ids, '[]'::jsonb) ? c.provider_id::text
              )
            order by
              ma.priority asc,
              c.priority asc,
              c.weight desc,
              ma.id asc,
              c.id asc
            "#,
        )
        .bind(auth.tenant_id)
        .bind(auth.api_key_profile_id)
        .bind(auth.project_id)
        .bind(model.id)
        .bind(&model.model_key)
        .fetch_all(&self.pool)
        .await
        .map_err(|error| {
            GatewayApiError::database_query_failed("resolve_chat_route_candidates", error)
        })?;

        Ok(rows
            .into_iter()
            .map(|row| {
                let association_upstream_model_name =
                    row.get::<Option<String>, _>("association_upstream_model_name");
                let channel_model_mappings = row
                    .try_get::<Json<Value>, _>("channel_model_mappings")
                    .map(|json| json.0)
                    .unwrap_or_else(|_| json!({}));
                let upstream_model = resolved_upstream_model_name(
                    association_upstream_model_name.as_deref(),
                    &model.model_key,
                    &channel_model_mappings,
                );

                ResolvedChatRoute {
                    canonical_model_id: model.id,
                    canonical_model_key: model.model_key.clone(),
                    model_association_id: row.get("model_association_id"),
                    association_type: row.get("association_type"),
                    provider_id: row.get("provider_id"),
                    channel_id: row.get("channel_id"),
                    provider_key_id: row.get("provider_key_id"),
                    provider_key_rpm_limit: row.get("provider_key_rpm_limit"),
                    provider_key_tpm_limit: row.get("provider_key_tpm_limit"),
                    provider_key_concurrency_limit: row.get("provider_key_concurrency_limit"),
                    provider_key_current_window_state: row
                        .try_get::<Json<Value>, _>("provider_key_current_window_state")
                        .map(|json| json.0)
                        .unwrap_or_else(|_| json!({})),
                    channel_name: row.get("channel_name"),
                    endpoint: row.get("endpoint"),
                    protocol_mode: row.get("protocol_mode"),
                    upstream_model,
                    channel_status: row.get("channel_status"),
                    fallback_allowed: row.get("association_fallback_allowed"),
                    association_priority: row.get("association_priority"),
                    channel_priority: row.get("channel_priority"),
                    channel_weight: row.get("channel_weight"),
                    channel_health_score: row.get("channel_health_score"),
                }
            })
            .collect())
    }

    pub async fn find_trace_affinity_previous_success(
        &self,
        auth: &AuthContext,
        trace_id: &str,
        model: &ResolvedCanonicalModel,
        lookback_seconds: i64,
    ) -> Result<Option<TraceAffinityPreviousSuccessRoute>, GatewayApiError> {
        let row = sqlx::query(
            r#"
            select
              resolved_channel_id as channel_id,
              resolved_provider_id as provider_id,
              canonical_model_id,
              upstream_model
            from request_logs
            where tenant_id = $1
              and project_id = $2
              and trace_id = $3
              and created_at >= now() - (($4::double precision) * interval '1 second')
              and canonical_model_id = $5
              and status = 'succeeded'
              and resolved_channel_id is not null
              and resolved_provider_id is not null
            order by created_at desc, id desc
            limit 1
            "#,
        )
        .bind(auth.tenant_id)
        .bind(auth.project_id)
        .bind(trace_id)
        .bind(lookback_seconds)
        .bind(model.id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|error| {
            GatewayApiError::database_query_failed("trace_affinity_previous_success", error)
        })?;

        Ok(row.map(|row| TraceAffinityPreviousSuccessRoute {
            channel_id: row.get("channel_id"),
            provider_id: row.get("provider_id"),
            canonical_model_id: row.get("canonical_model_id"),
            upstream_model: row.get("upstream_model"),
        }))
    }

    pub async fn create_request_started(
        &self,
        auth: &AuthContext,
        requested_model: Option<&str>,
        request_body_hash: Option<&str>,
        payload_log: RequestPayloadLog,
        route: RequestRouteLog<'_>,
    ) -> Result<Uuid, GatewayApiError> {
        let row = sqlx::query(
            r#"
            insert into request_logs (
              tenant_id,
              project_id,
              virtual_key_id,
              api_key_profile_id,
              trace_id,
              inbound_protocol,
              outbound_protocol,
              protocol_mode,
              requested_model,
              canonical_model_id,
              upstream_model,
              resolved_provider_id,
              resolved_channel_id,
              provider_key_id,
              route_policy_version,
              status,
              payload_policy_id,
              payload_stored,
              redaction_status,
              request_body_hash,
              route_decision_snapshot
            )
            values (
              $1, $2, $3, $4, $5, 'openai', 'openai', 'openai_compatible',
              $6, $7, $8, $9, $10, $11, $12, 'started', $13, $14, $15, $16, $17
            )
            returning id
            "#,
        )
        .bind(auth.tenant_id)
        .bind(auth.project_id)
        .bind(auth.virtual_key_id)
        .bind(auth.api_key_profile_id)
        .bind(route.trace_id.as_deref())
        .bind(requested_model)
        .bind(route.canonical_model_id)
        .bind(route.upstream_model)
        .bind(route.resolved_provider_id)
        .bind(route.resolved_channel_id)
        .bind(route.provider_key_id)
        .bind(route.route_policy_version)
        .bind(payload_log.payload_policy_id)
        .bind(payload_log.payload_stored)
        .bind(payload_log.redaction_status)
        .bind(request_body_hash)
        .bind(Json(merge_payload_metadata(
            route.route_decision_snapshot,
            payload_log.metadata,
        )))
        .fetch_one(&self.pool)
        .await
        .map_err(|error| GatewayApiError::database_query_failed("request_log_start", error))?;

        Ok(row.get("id"))
    }

    pub async fn update_request_route_selection(
        &self,
        auth: &AuthContext,
        request_id: Uuid,
        route: RequestRouteLog<'_>,
    ) -> Result<(), GatewayApiError> {
        sqlx::query(
            r#"
            update request_logs
               set canonical_model_id = $3,
                   upstream_model = $4,
                   resolved_provider_id = $5,
                   resolved_channel_id = $6,
                   provider_key_id = $7,
                   route_policy_version = $8,
                   route_decision_snapshot = $9 || case
                     when route_decision_snapshot ? 'payload_policy'
                     then jsonb_build_object('payload_policy', route_decision_snapshot->'payload_policy')
                     else '{}'::jsonb
                   end
             where tenant_id = $1
               and id = $2
            "#,
        )
        .bind(auth.tenant_id)
        .bind(request_id)
        .bind(route.canonical_model_id)
        .bind(route.upstream_model)
        .bind(route.resolved_provider_id)
        .bind(route.resolved_channel_id)
        .bind(route.provider_key_id)
        .bind(route.route_policy_version)
        .bind(Json(route.route_decision_snapshot))
        .execute(&self.pool)
        .await
        .map_err(|error| {
            GatewayApiError::database_query_failed("request_log_route_update", error)
        })?;

        Ok(())
    }

    pub async fn finish_request(
        &self,
        auth: &AuthContext,
        request_id: Uuid,
        update: RequestFinalUpdate,
    ) -> Result<(), GatewayApiError> {
        sqlx::query(
            r#"
            update request_logs
               set status = $3,
                   http_status = $4,
                   error_owner = $5,
                   error_code = $6,
                   retryable = $7,
                   latency_ms = $8,
                   input_tokens = coalesce($9, input_tokens),
                   output_tokens = coalesce($10, output_tokens),
                   final_cost = coalesce(($11::text)::numeric, final_cost),
                   currency = coalesce($12, currency),
                   price_version_id = coalesce($13, price_version_id),
                   response_body_hash = $14,
                   payload_stored = payload_stored or $15,
                   redaction_status = coalesce($16, redaction_status),
                   route_decision_snapshot = route_decision_snapshot || case
                     when $17::jsonb is null then '{}'::jsonb
                     else jsonb_build_object(
                       'payload_policy',
                       coalesce(route_decision_snapshot->'payload_policy', '{}'::jsonb) || $17::jsonb
                     )
                   end,
                   completed_at = now()
             where tenant_id = $1
               and id = $2
            "#,
        )
        .bind(auth.tenant_id)
        .bind(request_id)
        .bind(update.status)
        .bind(update.http_status)
        .bind(update.error_owner)
        .bind(update.error_code)
        .bind(update.retryable)
        .bind(update.latency_ms)
        .bind(update.input_tokens)
        .bind(update.output_tokens)
        .bind(update.final_cost)
        .bind(update.currency)
        .bind(update.price_version_id)
        .bind(update.response_body_hash)
        .bind(update.payload_stored)
        .bind(update.redaction_status)
        .bind(update.payload_metadata.map(Json))
        .execute(&self.pool)
        .await
        .map_err(|error| GatewayApiError::database_query_failed("request_log_finish", error))?;

        Ok(())
    }

    pub async fn finish_stream_request(
        &self,
        auth: &AuthContext,
        request_id: Uuid,
        update: StreamRequestFinalUpdate,
    ) -> Result<(), GatewayApiError> {
        sqlx::query(
            r#"
            update request_logs
               set status = $3,
                   http_status = $4,
                   error_owner = $5,
                   error_code = $6,
                   retryable = $7,
                   latency_ms = $8,
                   partial_sent = $9,
                   stream_end_reason = $10,
                   ttft_ms = $11,
                   input_tokens = coalesce($12, input_tokens),
                   output_tokens = coalesce($13, output_tokens),
                   final_cost = coalesce(($14::text)::numeric, final_cost),
                   currency = coalesce($15, currency),
                   price_version_id = coalesce($16, price_version_id),
                   response_body_hash = $17,
                   completed_at = now()
             where tenant_id = $1
               and id = $2
            "#,
        )
        .bind(auth.tenant_id)
        .bind(request_id)
        .bind(update.status)
        .bind(update.http_status)
        .bind(update.error_owner)
        .bind(update.error_code)
        .bind(update.retryable)
        .bind(update.latency_ms)
        .bind(update.partial_sent)
        .bind(update.stream_end_reason)
        .bind(update.ttft_ms)
        .bind(update.input_tokens)
        .bind(update.output_tokens)
        .bind(update.final_cost)
        .bind(update.currency)
        .bind(update.price_version_id)
        .bind(update.response_body_hash)
        .execute(&self.pool)
        .await
        .map_err(|error| {
            GatewayApiError::database_query_failed("request_log_finish_stream", error)
        })?;

        Ok(())
    }

    pub async fn resolve_active_price_version(
        &self,
        auth: &AuthContext,
        canonical_model_id: Uuid,
    ) -> Result<Option<ResolvedPriceVersion>, GatewayApiError> {
        let row = sqlx::query(RESOLVE_ACTIVE_PRICE_VERSION_SQL)
            .bind(auth.tenant_id)
            .bind(auth.api_key_profile_id)
            .bind(auth.project_id)
            .bind(canonical_model_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|error| {
                GatewayApiError::database_query_failed("resolve_active_price_version", error)
            })?;

        Ok(row.map(|row| ResolvedPriceVersion {
            id: row.get("id"),
            pricing_rules_json: row.get("pricing_rules_json"),
        }))
    }

    pub async fn resolve_pre_authorize_read_model(
        &self,
        auth: &AuthContext,
        currency: &str,
    ) -> Result<PreAuthorizeReadModel, GatewayApiError> {
        let wallet_row = sqlx::query(PRE_AUTHORIZE_WALLET_BALANCE_SQL)
            .bind(auth.tenant_id)
            .bind(auth.project_id)
            .bind(currency)
            .fetch_optional(&self.pool)
            .await
            .map_err(|error| {
                GatewayApiError::database_query_failed("pre_authorize_wallet_balance", error)
            })?;

        let wallet = wallet_row.map(|row| PreAuthorizeWalletBalance {
            currency: row.get("currency"),
            available_balance: row.get("available_balance"),
        });

        let budget_rows = sqlx::query(PRE_AUTHORIZE_BUDGET_REMAINING_SQL)
            .bind(auth.tenant_id)
            .bind(auth.project_id)
            .bind(currency)
            .bind(auth.virtual_key_id)
            .fetch_all(&self.pool)
            .await
            .map_err(|error| {
                GatewayApiError::database_query_failed("pre_authorize_budget_remaining", error)
            })?;

        let budgets = budget_rows
            .into_iter()
            .map(|row| PreAuthorizeBudgetRemaining {
                currency: row.get("currency"),
                remaining_amount: row.get("remaining_amount"),
            })
            .collect();

        Ok(PreAuthorizeReadModel { wallet, budgets })
    }

    pub async fn insert_confirmed_settle_ledger_entry(
        &self,
        auth: &AuthContext,
        entry: LedgerSettleEntry<'_>,
    ) -> Result<bool, GatewayApiError> {
        let Some(amount) = settle_ledger_amount(entry.final_cost) else {
            return Ok(false);
        };
        let idempotency_key = settle_ledger_idempotency_key(entry.request_id);
        let usage_snapshot = confirmed_settle_ledger_usage_snapshot(&entry);
        let metadata = confirmed_settle_ledger_metadata(&entry);

        let result = sqlx::query(
            r#"
            insert into ledger_entries (
              tenant_id,
              project_id,
              request_id,
              virtual_key_id,
              entry_type,
              amount,
              currency,
              status,
              idempotency_key,
              price_version_id,
              usage_snapshot,
              metadata
            )
            values (
              $1, $2, $3, $4, 'settle', ($5::text)::numeric, $6, 'confirmed',
              $7, $8, $9, $10
            )
            on conflict do nothing
            "#,
        )
        .bind(auth.tenant_id)
        .bind(auth.project_id)
        .bind(entry.request_id)
        .bind(auth.virtual_key_id)
        .bind(amount)
        .bind(entry.currency)
        .bind(idempotency_key)
        .bind(entry.price_version_id)
        .bind(Json(usage_snapshot))
        .bind(Json(metadata))
        .execute(&self.pool)
        .await
        .map_err(|error| GatewayApiError::database_query_failed("ledger_settle_insert", error))?;

        Ok(result.rows_affected() > 0)
    }

    pub async fn get_provider_key_for_attempt(
        &self,
        auth: &AuthContext,
        provider_key_id: Uuid,
        provider_id: Uuid,
        channel_id: Uuid,
    ) -> Result<Option<ResolvedProviderKey>, GatewayApiError> {
        let row = sqlx::query(
            r#"
            select
              pk.id,
              pk.encrypted_secret
            from provider_keys pk
            join channels c
              on c.tenant_id = pk.tenant_id
             and c.id = pk.channel_id
             and c.provider_id = $3
             and c.deleted_at is null
            where pk.tenant_id = $1
              and pk.id = $2
              and pk.channel_id = $4
              and pk.status in ('enabled', 'degraded', 'recovery_probe')
              and pk.deleted_at is null
              and (pk.cooldown_until is null or pk.cooldown_until <= now())
            limit 1
            "#,
        )
        .bind(auth.tenant_id)
        .bind(provider_key_id)
        .bind(provider_id)
        .bind(channel_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|error| GatewayApiError::database_query_failed("provider_key_lookup", error))?;

        Ok(row.map(|row| ResolvedProviderKey {
            id: row.get("id"),
            encrypted_secret: row.get("encrypted_secret"),
        }))
    }

    pub async fn create_provider_attempt_started(
        &self,
        auth: &AuthContext,
        request_id: Uuid,
        route: &ResolvedChatRoute,
        attempt_no: i32,
    ) -> Result<Uuid, GatewayApiError> {
        let row = sqlx::query(
            r#"
            insert into provider_attempts (
              tenant_id,
              request_id,
              provider_id,
              channel_id,
              provider_key_id,
              attempt_no,
              upstream_model,
              status
            )
            values ($1, $2, $3, $4, $5, $6, $7, 'started')
            returning id
            "#,
        )
        .bind(auth.tenant_id)
        .bind(request_id)
        .bind(route.provider_id)
        .bind(route.channel_id)
        .bind(route.provider_key_id)
        .bind(attempt_no)
        .bind(provider_attempt_upstream_model(route))
        .fetch_one(&self.pool)
        .await
        .map_err(|error| GatewayApiError::database_query_failed("provider_attempt_start", error))?;

        Ok(row.get("id"))
    }

    pub async fn finish_provider_attempt(
        &self,
        auth: &AuthContext,
        attempt_id: Uuid,
        update: ProviderAttemptFinalUpdate,
    ) -> Result<(), GatewayApiError> {
        sqlx::query(
            r#"
            update provider_attempts
               set status = $3,
                   http_status = $4,
                   error_owner = $5,
                   error_code = $6,
                   retryable = $7,
                   latency_ms = $8,
                   fallback_reason = $9,
                   metadata = metadata || $10::jsonb,
                   completed_at = now()
             where tenant_id = $1
               and id = $2
            "#,
        )
        .bind(auth.tenant_id)
        .bind(attempt_id)
        .bind(update.status)
        .bind(update.http_status)
        .bind(update.error_owner)
        .bind(update.error_code)
        .bind(update.retryable)
        .bind(update.latency_ms)
        .bind(update.fallback_reason)
        .bind(Json(update.metadata))
        .execute(&self.pool)
        .await
        .map_err(|error| {
            GatewayApiError::database_query_failed("provider_attempt_finish", error)
        })?;

        Ok(())
    }

    pub async fn finish_stream_provider_attempt(
        &self,
        auth: &AuthContext,
        attempt_id: Uuid,
        update: StreamProviderAttemptFinalUpdate,
    ) -> Result<(), GatewayApiError> {
        sqlx::query(
            r#"
            update provider_attempts
               set status = $3,
                   http_status = $4,
                   error_owner = $5,
                   error_code = $6,
                   retryable = $7,
                   latency_ms = $8,
                   ttft_ms = $9,
                   fallback_reason = $10,
                   metadata = metadata || $11::jsonb,
                   completed_at = now()
             where tenant_id = $1
               and id = $2
            "#,
        )
        .bind(auth.tenant_id)
        .bind(attempt_id)
        .bind(update.status)
        .bind(update.http_status)
        .bind(update.error_owner)
        .bind(update.error_code)
        .bind(update.retryable)
        .bind(update.latency_ms)
        .bind(update.ttft_ms)
        .bind(update.fallback_reason)
        .bind(Json(update.metadata))
        .execute(&self.pool)
        .await
        .map_err(|error| {
            GatewayApiError::database_query_failed("provider_attempt_finish_stream", error)
        })?;

        Ok(())
    }

    pub async fn update_provider_key_runtime_status(
        &self,
        auth: &AuthContext,
        update: ProviderKeyRuntimeStatusUpdate,
    ) -> Result<bool, GatewayApiError> {
        let result = sqlx::query(UPDATE_PROVIDER_KEY_RUNTIME_STATUS_SQL)
            .bind(auth.tenant_id)
            .bind(update.provider_key_id)
            .bind(update.channel_id)
            .bind(update.provider_id)
            .bind(update.status)
            .bind(update.cooldown_ms)
            .bind(update.last_error_code)
            .bind(Json(update.metadata))
            .execute(&self.pool)
            .await
            .map_err(|error| {
                GatewayApiError::database_query_failed("provider_key_runtime_status_update", error)
            })?;

        Ok(result.rows_affected() > 0)
    }
}

pub async fn connect_gateway_repository(
    config: &AppConfig,
) -> Result<GatewayRepository, GatewayApiError> {
    if config.database.driver != "postgres" {
        return Err(GatewayApiError::database_query_failed(
            "database_connect",
            format!("unsupported database driver `{}`", config.database.driver),
        ));
    }

    let pool = PgPoolOptions::new()
        .max_connections(8)
        .connect(&config.database.dsn)
        .await
        .map_err(|error| GatewayApiError::database_query_failed("database_connect", error))?;

    Ok(GatewayRepository::new(pool))
}

fn model_owner_from_capabilities(capabilities: &Value) -> String {
    capabilities
        .get("owned_by")
        .and_then(Value::as_str)
        .unwrap_or("ai-gateway")
        .to_string()
}

pub(crate) fn settle_ledger_idempotency_key(request_id: Uuid) -> String {
    format!("settle:{request_id}")
}

pub(crate) fn settle_ledger_amount(final_cost: &str) -> Option<String> {
    let final_cost = final_cost.trim();
    if !decimal_string_is_nonzero(final_cost) {
        return None;
    }

    if final_cost.starts_with('-') {
        Some(final_cost.to_string())
    } else {
        Some(format!("-{final_cost}"))
    }
}

fn decimal_string_is_nonzero(value: &str) -> bool {
    value
        .trim_start_matches(['-', '+'])
        .chars()
        .any(|character| character.is_ascii_digit() && character != '0')
}

pub(crate) fn confirmed_settle_ledger_metadata(entry: &LedgerSettleEntry<'_>) -> Value {
    json!({
        "request_id": entry.request_id.to_string(),
        "model": entry.model,
        "price_version_id": entry.price_version_id.to_string(),
        "input_tokens": entry.input_tokens,
        "output_tokens": entry.output_tokens
    })
}

fn confirmed_settle_ledger_usage_snapshot(entry: &LedgerSettleEntry<'_>) -> Value {
    json!({
        "input_tokens": entry.input_tokens,
        "output_tokens": entry.output_tokens
    })
}

fn enforce_auth_ip_allowlists(
    key_allowlist: &Value,
    profile_allowlist: Option<&Value>,
    profile_request_overrides: Option<&Value>,
    client_ip: IpAddr,
) -> Result<(), GatewayApiError> {
    enforce_ip_allowlist(key_allowlist, client_ip)?;

    if let Some(profile_allowlist) = profile_allowlist
        && !is_empty_json_array(profile_allowlist)
    {
        enforce_ip_allowlist(profile_allowlist, client_ip)?;
    }

    if let Some(profile_request_overrides) = profile_request_overrides {
        enforce_profile_ip_allowlist(profile_request_overrides, client_ip)?;
    }

    Ok(())
}

fn is_empty_json_array(value: &Value) -> bool {
    value.as_array().is_some_and(Vec::is_empty)
}

fn enforce_ip_allowlist(allowlist: &Value, client_ip: IpAddr) -> Result<(), GatewayApiError> {
    if ip_allowlist_allows(allowlist, client_ip) {
        return Ok(());
    }

    Err(GatewayApiError::api_key_ip_forbidden())
}

fn enforce_profile_ip_allowlist(
    request_overrides: &Value,
    client_ip: IpAddr,
) -> Result<(), GatewayApiError> {
    match profile_ip_allowlist_policy(request_overrides) {
        ProfileIpAllowlistPolicy::NotConfigured => Ok(()),
        ProfileIpAllowlistPolicy::Configured(allowlist) => {
            enforce_ip_allowlist(allowlist, client_ip)
        }
        ProfileIpAllowlistPolicy::Malformed => Err(GatewayApiError::api_key_ip_forbidden()),
    }
}

enum ProfileIpAllowlistPolicy<'a> {
    NotConfigured,
    Configured(&'a Value),
    Malformed,
}

fn profile_ip_allowlist_policy(request_overrides: &Value) -> ProfileIpAllowlistPolicy<'_> {
    let Some(overrides) = request_overrides.as_array() else {
        return ProfileIpAllowlistPolicy::NotConfigured;
    };

    for policy in overrides {
        let Some(policy) = policy.as_object() else {
            continue;
        };
        if !is_profile_ip_allowlist_policy(policy) {
            continue;
        }

        return policy
            .get("ip_allowlist")
            .or_else(|| policy.get("entries"))
            .map(ProfileIpAllowlistPolicy::Configured)
            .unwrap_or(ProfileIpAllowlistPolicy::Malformed);
    }

    ProfileIpAllowlistPolicy::NotConfigured
}

fn is_profile_ip_allowlist_policy(policy: &serde_json::Map<String, Value>) -> bool {
    policy
        .get("type")
        .or_else(|| policy.get("kind"))
        .and_then(Value::as_str)
        .is_some_and(|policy_type| {
            policy_type.eq_ignore_ascii_case("profile_ip_allowlist")
                || policy_type.eq_ignore_ascii_case("ip_allowlist")
        })
}

fn ip_allowlist_allows(allowlist: &Value, client_ip: IpAddr) -> bool {
    let Some(entries) = allowlist.as_array() else {
        return false;
    };
    if entries.is_empty() {
        return true;
    }

    entries
        .iter()
        .filter_map(Value::as_str)
        .any(|entry| ip_allowlist_entry_matches(entry, client_ip))
}

fn ip_allowlist_entry_matches(entry: &str, client_ip: IpAddr) -> bool {
    let entry = entry.trim();
    if entry.is_empty() {
        return false;
    }

    if let Some((network, prefix_len)) = entry.split_once('/') {
        return cidr_matches(network.trim(), prefix_len.trim(), client_ip);
    }

    entry
        .parse::<IpAddr>()
        .is_ok_and(|allowed_ip| allowed_ip == client_ip)
}

fn cidr_matches(network: &str, prefix_len: &str, client_ip: IpAddr) -> bool {
    let Ok(network_ip) = network.parse::<IpAddr>() else {
        return false;
    };
    let Ok(prefix_len) = prefix_len.parse::<u8>() else {
        return false;
    };

    match (network_ip, client_ip) {
        (IpAddr::V4(network), IpAddr::V4(client)) => {
            prefix_matches(network.octets(), client.octets(), prefix_len, 32)
        }
        (IpAddr::V6(network), IpAddr::V6(client)) => {
            prefix_matches(network.octets(), client.octets(), prefix_len, 128)
        }
        _ => false,
    }
}

fn prefix_matches<const N: usize>(
    network: [u8; N],
    client: [u8; N],
    prefix_len: u8,
    max_prefix_len: u8,
) -> bool {
    if prefix_len > max_prefix_len {
        return false;
    }

    let full_bytes = usize::from(prefix_len / 8);
    if network[..full_bytes] != client[..full_bytes] {
        return false;
    }

    let remaining_bits = prefix_len % 8;
    if remaining_bits == 0 {
        return true;
    }

    let mask = u8::MAX << (8 - remaining_bits);
    (network[full_bytes] & mask) == (client[full_bytes] & mask)
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, Ipv6Addr};

    use super::*;

    #[test]
    fn provider_key_runtime_status_update_sql_preserves_manual_disabled() {
        assert!(UPDATE_PROVIDER_KEY_RUNTIME_STATUS_SQL.contains("provider_keys pk"));
        assert!(
            UPDATE_PROVIDER_KEY_RUNTIME_STATUS_SQL
                .contains("pk.status not in ('manual_disabled', 'deleted')")
        );
        assert!(UPDATE_PROVIDER_KEY_RUNTIME_STATUS_SQL.contains("c.provider_id = $4"));
    }

    #[test]
    fn provider_key_runtime_status_update_sql_calculates_cooldown_until_from_ms() {
        assert!(
            UPDATE_PROVIDER_KEY_RUNTIME_STATUS_SQL
                .contains("now() + (($6::double precision / 1000.0) * interval '1 second')")
        );
        assert!(UPDATE_PROVIDER_KEY_RUNTIME_STATUS_SQL.contains("when $6::bigint is null"));
    }

    fn test_resolved_route(upstream_model: String) -> ResolvedChatRoute {
        ResolvedChatRoute {
            canonical_model_id: Uuid::from_u128(10),
            canonical_model_key: "openrouter/openai/GPT-4O-MINI".to_string(),
            model_association_id: Uuid::from_u128(11),
            association_type: "channel_tag".to_string(),
            provider_id: Uuid::from_u128(12),
            channel_id: Uuid::from_u128(13),
            provider_key_id: Uuid::from_u128(14),
            channel_name: "openrouter-compatible".to_string(),
            endpoint: "https://provider.example.test/v1".to_string(),
            protocol_mode: "openai_compatible".to_string(),
            upstream_model,
            channel_status: "enabled".to_string(),
            fallback_allowed: true,
            association_priority: 1,
            channel_priority: 2,
            channel_weight: 100,
            channel_health_score: 1.0,
            provider_key_rpm_limit: None,
            provider_key_tpm_limit: None,
            provider_key_concurrency_limit: None,
            provider_key_current_window_state: json!({}),
        }
    }

    #[test]
    fn channel_mapping_runtime_trims_openrouter_prefix_and_updates_log_inputs() {
        let upstream_model = resolved_upstream_model_name(
            None,
            "openrouter/openai/GPT-4O-MINI",
            &json!({
                "trim_prefixes": ["openrouter/openai"],
                "case_policy": "lower"
            }),
        );
        let route = test_resolved_route(upstream_model);
        let request_log = RequestRouteLog {
            trace_id: None,
            canonical_model_id: Some(route.canonical_model_id),
            upstream_model: Some(route.upstream_model.as_str()),
            resolved_provider_id: Some(route.provider_id),
            resolved_channel_id: Some(route.channel_id),
            provider_key_id: Some(route.provider_key_id),
            route_policy_version: Some("test"),
            route_decision_snapshot: json!({ "selection": "selected" }),
        };

        assert_eq!(route.upstream_model, "gpt-4o-mini");
        assert_eq!(request_log.upstream_model, Some("gpt-4o-mini"));
        assert_eq!(provider_attempt_upstream_model(&route), "gpt-4o-mini");
    }

    #[test]
    fn association_upstream_model_overrides_channel_mapping_policy() {
        let upstream_model = resolved_upstream_model_name(
            Some(" provider-fixed-model "),
            "openrouter/meta/LLAMA-3.1-70B",
            &json!({
                "trim_prefixes": ["openrouter/meta"],
                "case_policy": "lower"
            }),
        );

        assert_eq!(upstream_model, "provider-fixed-model");
    }

    #[test]
    fn channel_mapping_runtime_keeps_legacy_explicit_mapping_priority() {
        let upstream_model = resolved_upstream_model_name(
            None,
            "openrouter/openai/GPT-4O",
            &json!({
                "openrouter/openai/GPT-4O": "gpt-4o-special",
                "trim_prefixes": ["openrouter/openai"],
                "case_policy": "lower"
            }),
        );

        assert_eq!(upstream_model, "gpt-4o-special");
    }

    #[test]
    fn channel_mapping_runtime_supports_structured_explicit_mappings() {
        let upstream_model = resolved_upstream_model_name(
            None,
            "openrouter/anthropic/Claude-3-OPUS",
            &json!({
                "explicit_mappings": [
                    {
                        "requested_model": "openrouter/anthropic/Claude-3-OPUS",
                        "upstream_model": "claude-3-opus-provider"
                    }
                ],
                "trim_prefixes": ["openrouter/anthropic"],
                "case_policy": "lower"
            }),
        );

        assert_eq!(upstream_model, "claude-3-opus-provider");
    }

    #[test]
    fn pricing_policy_sql_matches_selector_fixture_contract() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/gateway/pricing_policy_selection.json"
        ))
        .expect("pricing policy fixture should be valid json");

        let sql = normalized_sql(RESOLVE_ACTIVE_PRICE_VERSION_SQL);
        let expected_order = fixture["selector_priority"]
            .as_array()
            .expect("selector_priority should be an array")
            .iter()
            .map(|selector| selector["source"].as_str().expect("selector source"))
            .collect::<Vec<_>>();

        assert_eq!(
            expected_order,
            vec![
                "api_key_profiles",
                "projects",
                "tenants",
                "canonical_models"
            ]
        );

        for required in fixture["required_sql_guards"]
            .as_array()
            .expect("required_sql_guards should be an array")
        {
            let guard = required.as_str().expect("sql guard should be a string");
            assert!(
                sql.contains(&normalized_sql(guard)),
                "missing SQL guard: {guard}"
            );
        }

        assert!(
            sql.find("from api_key_profiles p")
                .expect("profile selector")
                < sql.find("from projects prj").expect("project selector")
        );
        assert!(
            sql.find("from projects prj").expect("project selector")
                < sql.find("from tenants t").expect("tenant selector")
        );
        assert!(
            sql.find("from tenants t").expect("tenant selector")
                < sql
                    .find("from canonical_model cm where cm.default_price_book_id is not null")
                    .expect("canonical selector")
        );
    }

    #[test]
    fn pricing_policy_sql_keeps_price_version_ordering_contract() {
        let sql = normalized_sql(RESOLVE_ACTIVE_PRICE_VERSION_SQL);
        let model_specific = sql
            .find("(pv.canonical_model_id is not null) desc")
            .expect("model-specific price versions should sort first");
        let effective = sql
            .find("pv.effective_at desc")
            .expect("newer effective price versions should sort next");
        let created = sql
            .find("pv.created_at desc")
            .expect("newer created price versions should break ties");
        let id = sql
            .find("pv.id asc")
            .expect("id should provide stable final ordering");

        assert!(model_specific < effective);
        assert!(effective < created);
        assert!(created < id);
    }

    #[test]
    fn pre_authorize_wallet_sql_uses_active_project_wallet_and_conservative_balance() {
        let sql = normalized_sql(PRE_AUTHORIZE_WALLET_BALANCE_SQL);

        assert!(sql.contains("from wallets w"));
        assert!(sql.contains("and (w.project_id = $2 or w.project_id is null)"));
        assert!(sql.contains("order by (w.project_id = $2) desc"));
        assert!(sql.contains("and w.currency = $3"));
        assert!(sql.contains("and w.status = 'active'"));
        assert!(sql.contains("from credit_grants cg"));
        assert!(sql.contains("cg.valid_from <= now()"));
        assert!(sql.contains("from ledger_entries le"));
        assert!(sql.contains("le.wallet_id = w.id"));
        assert!(sql.contains("le.wallet_id is null and le.project_id = $2"));
        assert!(sql.contains("le.status in ('pending', 'confirmed')"));
        assert!(sql.contains("credit_balance.amount + ledger_balance.amount - w.balance_floor"));
    }

    #[test]
    fn pre_authorize_budget_sql_scopes_and_windows_budget_usage() {
        let sql = normalized_sql(PRE_AUTHORIZE_BUDGET_REMAINING_SQL);

        assert!(sql.contains("from budgets b"));
        assert!(sql.contains("b.scope = 'tenant'"));
        assert!(sql.contains("b.scope = 'project' and b.project_id = $2"));
        assert!(sql.contains("b.scope = 'virtual_key' and b.virtual_key_id = $4"));
        assert!(sql.contains("when 'rolling_24h' then now() - interval '24 hours'"));
        assert!(sql.contains("from active_budgets b left join request_logs rl"));
        assert!(sql.contains("rl.status in ('succeeded', 'partial')"));
        assert!(sql.contains("(b.limit_amount - s.spent_amount)::text as remaining_amount"));
    }

    #[test]
    fn settle_ledger_idempotency_key_is_request_scoped() {
        let request_id = Uuid::from_u128(42);

        assert_eq!(
            settle_ledger_idempotency_key(request_id),
            format!("settle:{request_id}")
        );
    }

    #[test]
    fn settle_ledger_amount_is_negative_and_rejects_zero() {
        assert_eq!(
            settle_ledger_amount("0.00012345").as_deref(),
            Some("-0.00012345")
        );
        assert_eq!(
            settle_ledger_amount("-0.00012345").as_deref(),
            Some("-0.00012345")
        );
        assert_eq!(settle_ledger_amount("0.00000000"), None);
    }

    #[test]
    fn settle_ledger_metadata_carries_request_model_price_and_usage() {
        let request_id = Uuid::from_u128(43);
        let price_version_id = Uuid::from_u128(44);
        let entry = LedgerSettleEntry {
            request_id,
            model: "mock-gpt",
            final_cost: "0.00012345",
            currency: "USD",
            price_version_id,
            input_tokens: 12,
            output_tokens: 34,
        };

        let metadata = confirmed_settle_ledger_metadata(&entry);

        assert_eq!(metadata["request_id"], request_id.to_string());
        assert_eq!(metadata["model"], "mock-gpt");
        assert_eq!(metadata["price_version_id"], price_version_id.to_string());
        assert_eq!(metadata["input_tokens"], 12);
        assert_eq!(metadata["output_tokens"], 34);
    }

    fn normalized_sql(sql: &str) -> String {
        sql.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    #[test]
    fn empty_ip_allowlist_allows_any_client_ip() {
        assert!(ip_allowlist_allows(
            &json!([]),
            IpAddr::V4(Ipv4Addr::new(198, 51, 100, 23))
        ));
        assert!(ip_allowlist_allows(
            &json!([]),
            IpAddr::V6(Ipv6Addr::LOCALHOST)
        ));
    }

    #[test]
    fn ip_allowlist_matches_single_ipv4_and_ipv6_addresses() {
        assert!(ip_allowlist_allows(
            &json!(["198.51.100.23"]),
            IpAddr::V4(Ipv4Addr::new(198, 51, 100, 23))
        ));
        assert!(!ip_allowlist_allows(
            &json!(["198.51.100.23"]),
            IpAddr::V4(Ipv4Addr::new(198, 51, 100, 24))
        ));
        assert!(ip_allowlist_allows(
            &json!(["2001:db8::42"]),
            "2001:db8::42".parse().unwrap()
        ));
    }

    #[test]
    fn ip_allowlist_matches_ipv4_and_ipv6_cidr_entries() {
        assert!(ip_allowlist_allows(
            &json!(["203.0.113.0/24"]),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 88))
        ));
        assert!(!ip_allowlist_allows(
            &json!(["203.0.113.0/24"]),
            IpAddr::V4(Ipv4Addr::new(203, 0, 114, 1))
        ));
        assert!(ip_allowlist_allows(
            &json!(["2001:db8:abcd::/48"]),
            "2001:db8:abcd:2::1".parse().unwrap()
        ));
        assert!(!ip_allowlist_allows(
            &json!(["2001:db8:abcd::/48"]),
            "2001:db8:abce::1".parse().unwrap()
        ));
    }

    #[test]
    fn invalid_ip_allowlist_entries_are_ignored_without_granting_access() {
        assert!(ip_allowlist_allows(
            &json!(["not-an-ip", "203.0.113.0/24", "2001:db8::/129", 42]),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 5))
        ));
        assert!(!ip_allowlist_allows(
            &json!(["not-an-ip", "2001:db8::/129", 42]),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 5))
        ));
        assert!(!ip_allowlist_allows(
            &json!({"unexpected": "shape"}),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 5))
        ));
    }

    #[test]
    fn profile_ip_allowlist_tightens_key_ip_allowlist_after_key_allows() {
        let key_allowlist = json!(["203.0.113.0/24"]);
        let profile_request_overrides = json!([
            {
                "type": "profile_ip_allowlist",
                "ip_allowlist": ["203.0.113.42"]
            }
        ]);

        assert!(
            enforce_auth_ip_allowlists(
                &key_allowlist,
                None,
                Some(&profile_request_overrides),
                IpAddr::V4(Ipv4Addr::new(203, 0, 113, 42)),
            )
            .is_ok()
        );

        let error = enforce_auth_ip_allowlists(
            &key_allowlist,
            None,
            Some(&profile_request_overrides),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 43)),
        )
        .expect_err("profile allowlist should tighten the key allowlist");

        assert_eq!(error.status, axum::http::StatusCode::FORBIDDEN);
        assert_eq!(error.code, "api_key_ip_forbidden");
        assert_eq!(error.stage, "auth");
    }

    #[test]
    fn dedicated_profile_ip_allowlist_tightens_key_ip_allowlist() {
        let key_allowlist = json!(["203.0.113.0/24"]);
        let profile_allowlist = json!(["203.0.113.42"]);

        assert!(
            enforce_auth_ip_allowlists(
                &key_allowlist,
                Some(&profile_allowlist),
                None,
                IpAddr::V4(Ipv4Addr::new(203, 0, 113, 42)),
            )
            .is_ok()
        );

        let error = enforce_auth_ip_allowlists(
            &key_allowlist,
            Some(&profile_allowlist),
            None,
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 43)),
        )
        .expect_err("dedicated profile allowlist should tighten the key allowlist");

        assert_eq!(error.status, axum::http::StatusCode::FORBIDDEN);
        assert_eq!(error.code, "api_key_ip_forbidden");
        assert_eq!(error.stage, "auth");
    }

    #[test]
    fn empty_dedicated_profile_ip_allowlist_does_not_add_restriction() {
        let key_allowlist = json!(["203.0.113.0/24"]);
        let profile_allowlist = json!([]);

        assert!(
            enforce_auth_ip_allowlists(
                &key_allowlist,
                Some(&profile_allowlist),
                None,
                IpAddr::V4(Ipv4Addr::new(203, 0, 113, 43)),
            )
            .is_ok()
        );
    }

    #[test]
    fn profile_ip_allowlist_cannot_expand_key_ip_allowlist() {
        let key_allowlist = json!(["192.0.2.0/24"]);
        let profile_request_overrides = json!([
            {
                "type": "profile_ip_allowlist",
                "ip_allowlist": ["203.0.113.42"]
            }
        ]);

        let error = enforce_auth_ip_allowlists(
            &key_allowlist,
            None,
            Some(&profile_request_overrides),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 42)),
        )
        .expect_err("profile allowlist must not expand a key allowlist denial");

        assert_eq!(error.status, axum::http::StatusCode::FORBIDDEN);
        assert_eq!(error.code, "api_key_ip_forbidden");
        assert_eq!(error.stage, "auth");
    }

    #[test]
    fn empty_profile_ip_allowlist_does_not_add_restriction() {
        let key_allowlist = json!(["203.0.113.0/24"]);
        let profile_request_overrides = json!([
            {
                "type": "profile_ip_allowlist",
                "ip_allowlist": []
            }
        ]);

        assert!(
            enforce_auth_ip_allowlists(
                &key_allowlist,
                None,
                Some(&profile_request_overrides),
                IpAddr::V4(Ipv4Addr::new(203, 0, 113, 43)),
            )
            .is_ok()
        );
    }

    #[test]
    fn missing_profile_ip_allowlist_does_not_add_restriction() {
        let key_allowlist = json!(["203.0.113.0/24"]);
        let profile_request_overrides = json!([
            {
                "type": "request_override",
                "set_headers": {"x-example": "value"}
            }
        ]);

        assert!(
            enforce_auth_ip_allowlists(
                &key_allowlist,
                None,
                Some(&profile_request_overrides),
                IpAddr::V4(Ipv4Addr::new(203, 0, 113, 43)),
            )
            .is_ok()
        );
    }

    #[test]
    fn invalid_profile_ip_allowlist_entries_are_ignored_without_granting_access() {
        let profile_request_overrides = json!([
            {
                "type": "profile_ip_allowlist",
                "ip_allowlist": ["not-an-ip", "2001:db8::/129", 42]
            }
        ]);

        let error = enforce_auth_ip_allowlists(
            &json!([]),
            None,
            Some(&profile_request_overrides),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 5)),
        )
        .expect_err("invalid profile allowlist entries must not grant access");

        assert_eq!(error.status, axum::http::StatusCode::FORBIDDEN);
        assert_eq!(error.code, "api_key_ip_forbidden");
        assert_eq!(error.stage, "auth");
    }

    #[test]
    fn malformed_profile_ip_allowlist_policy_does_not_grant_access() {
        let profile_request_overrides = json!([
            {
                "type": "profile_ip_allowlist"
            }
        ]);

        let error = enforce_auth_ip_allowlists(
            &json!([]),
            None,
            Some(&profile_request_overrides),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 5)),
        )
        .expect_err("malformed profile allowlist policy must not grant access");

        assert_eq!(error.status, axum::http::StatusCode::FORBIDDEN);
        assert_eq!(error.code, "api_key_ip_forbidden");
        assert_eq!(error.stage, "auth");
    }

    #[test]
    fn profile_ip_allowlist_fixture_documents_auth_contract() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/gateway/profile_ip_allowlist.json"
        ))
        .expect("profile IP allowlist fixture should be valid json");

        assert_eq!(fixture["scenario"], "gateway_profile_ip_allowlist_smoke");
        assert_eq!(
            fixture["profile_policy"]["source"],
            "api_key_profiles.ip_allowlist"
        );
        assert!(ip_allowlist_allows(
            &fixture["profile_policy"]["ip_allowlist_example"],
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 42))
        ));
        assert!(!ip_allowlist_allows(
            &fixture["profile_policy"]["ip_allowlist_example"],
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 43))
        ));

        let request_overrides = &fixture["profile_policy"]["request_overrides_example"];
        let ProfileIpAllowlistPolicy::Configured(allowlist) =
            profile_ip_allowlist_policy(request_overrides)
        else {
            panic!("fixture must include a configured profile IP allowlist policy");
        };

        assert!(ip_allowlist_allows(
            allowlist,
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 42))
        ));
        assert!(!ip_allowlist_allows(
            allowlist,
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 43))
        ));
    }

    #[test]
    fn ip_allowlist_rejection_uses_auth_policy_error() {
        let error = enforce_ip_allowlist(
            &json!(["192.0.2.0/24"]),
            IpAddr::V4(Ipv4Addr::new(198, 51, 100, 23)),
        )
        .expect_err("client ip should be rejected");

        assert_eq!(error.status, axum::http::StatusCode::FORBIDDEN);
        assert_eq!(error.code, "api_key_ip_forbidden");
        assert_eq!(error.stage, "auth");
    }
}
