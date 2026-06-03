use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const TRACE_AFFINITY_LOOKUP_SCHEMA: &str = "trace_affinity_previous_success_lookup_v1";
pub const TRACE_AFFINITY_REQUEST_LOGS_INDEX: &str = "idx_request_logs_trace_time";
pub const TRACE_AFFINITY_MAX_TRACE_ID_BYTES: usize = 256;
pub const TRACE_AFFINITY_DEFAULT_LOOKBACK_SECONDS: i64 = 3_600;
pub const TRACE_AFFINITY_MAX_LOOKBACK_SECONDS: i64 = 86_400;
pub const TRACE_AFFINITY_DEFAULT_LIMIT: i64 = 1;
pub const TRACE_AFFINITY_MAX_LIMIT: i64 = 8;

pub const TRACE_AFFINITY_PREVIOUS_SUCCESS_LOOKUP_SQL: &str = r#"
            select
              resolved_channel_id as channel_id,
              resolved_provider_id as provider_id,
              canonical_model_id,
              upstream_model
            from request_logs
            where tenant_id = $1
              and trace_id = $2
              and created_at >= $3::timestamptz
              and ($4::uuid is null or project_id = $4)
              and ($5::uuid is null or canonical_model_id = $5)
              and status = 'succeeded'
              and resolved_channel_id is not null
              and resolved_provider_id is not null
            order by created_at desc, id desc
            limit $6
            "#;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TraceAffinityLookupSkipReason {
    MissingTraceId,
    BlankTraceId,
    TraceIdTooLong,
    MissingNotBefore,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraceAffinityPreviousSuccessLookupInput {
    pub tenant_id: Uuid,
    pub project_id: Option<Uuid>,
    pub trace_id: Option<String>,
    pub canonical_model_id: Option<Uuid>,
    pub not_before: Option<String>,
    pub lookback_seconds: Option<i64>,
    pub limit: Option<i64>,
}

impl TraceAffinityPreviousSuccessLookupInput {
    pub fn new(tenant_id: Uuid, trace_id: Option<impl Into<String>>) -> Self {
        Self {
            tenant_id,
            project_id: None,
            trace_id: trace_id.map(Into::into),
            canonical_model_id: None,
            not_before: None,
            lookback_seconds: None,
            limit: None,
        }
    }

    pub const fn with_project_id(mut self, project_id: Uuid) -> Self {
        self.project_id = Some(project_id);
        self
    }

    pub const fn with_canonical_model_id(mut self, canonical_model_id: Uuid) -> Self {
        self.canonical_model_id = Some(canonical_model_id);
        self
    }

    pub fn with_not_before(mut self, not_before: impl Into<String>) -> Self {
        self.not_before = Some(not_before.into());
        self
    }

    pub const fn with_lookback_seconds(mut self, lookback_seconds: i64) -> Self {
        self.lookback_seconds = Some(lookback_seconds);
        self
    }

    pub const fn with_limit(mut self, limit: i64) -> Self {
        self.limit = Some(limit);
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TraceAffinityPreviousSuccessLookupPlan {
    Query(TraceAffinityPreviousSuccessLookupQuery),
    Skip(TraceAffinityPreviousSuccessLookupSkip),
}

impl TraceAffinityPreviousSuccessLookupPlan {
    pub fn summary(&self) -> TraceAffinityPreviousSuccessLookupSummary {
        match self {
            Self::Query(query) => query.summary(),
            Self::Skip(skip) => skip.summary(),
        }
    }

    pub fn query(&self) -> Option<&TraceAffinityPreviousSuccessLookupQuery> {
        match self {
            Self::Query(query) => Some(query),
            Self::Skip(_) => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraceAffinityPreviousSuccessLookupQuery {
    pub tenant_id: Uuid,
    pub project_id: Option<Uuid>,
    pub trace_id: String,
    pub trace_id_len: usize,
    pub canonical_model_id: Option<Uuid>,
    pub not_before: String,
    pub lookback_seconds: i64,
    pub limit: i64,
}

impl TraceAffinityPreviousSuccessLookupQuery {
    pub fn summary(&self) -> TraceAffinityPreviousSuccessLookupSummary {
        TraceAffinityPreviousSuccessLookupSummary {
            schema: TRACE_AFFINITY_LOOKUP_SCHEMA.to_string(),
            enabled: true,
            skip_reason: None,
            source_table: "request_logs".to_string(),
            index_hint: TRACE_AFFINITY_REQUEST_LOGS_INDEX.to_string(),
            index_columns: static_strings(&["tenant_id", "trace_id", "created_at"]),
            tenant_scoped: true,
            project_scoped: self.project_id.is_some(),
            canonical_model_scoped: self.canonical_model_id.is_some(),
            trace_id_len: Some(self.trace_id_len),
            trace_id_material_in_output: false,
            created_at_ttl_bound: true,
            not_before_bound: true,
            lookback_seconds: self.lookback_seconds,
            limit: self.limit,
            status_filter: "succeeded".to_string(),
            order_by: "created_at desc, id desc".to_string(),
            output_fields: static_strings(&[
                "channel_id",
                "provider_id",
                "canonical_model_id",
                "upstream_model",
            ]),
            omitted_fields: omitted_material_fields(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraceAffinityPreviousSuccessLookupSkip {
    pub reason: TraceAffinityLookupSkipReason,
    pub trace_id_len: Option<usize>,
    pub lookback_seconds: i64,
    pub limit: i64,
}

impl TraceAffinityPreviousSuccessLookupSkip {
    pub fn summary(&self) -> TraceAffinityPreviousSuccessLookupSummary {
        TraceAffinityPreviousSuccessLookupSummary {
            schema: TRACE_AFFINITY_LOOKUP_SCHEMA.to_string(),
            enabled: false,
            skip_reason: Some(self.reason),
            source_table: "request_logs".to_string(),
            index_hint: TRACE_AFFINITY_REQUEST_LOGS_INDEX.to_string(),
            index_columns: static_strings(&["tenant_id", "trace_id", "created_at"]),
            tenant_scoped: true,
            project_scoped: false,
            canonical_model_scoped: false,
            trace_id_len: self.trace_id_len,
            trace_id_material_in_output: false,
            created_at_ttl_bound: true,
            not_before_bound: false,
            lookback_seconds: self.lookback_seconds,
            limit: self.limit,
            status_filter: "succeeded".to_string(),
            order_by: "created_at desc, id desc".to_string(),
            output_fields: static_strings(&[
                "channel_id",
                "provider_id",
                "canonical_model_id",
                "upstream_model",
            ]),
            omitted_fields: omitted_material_fields(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TraceAffinityPreviousSuccessLookupSummary {
    pub schema: String,
    pub enabled: bool,
    pub skip_reason: Option<TraceAffinityLookupSkipReason>,
    pub source_table: String,
    pub index_hint: String,
    pub index_columns: Vec<String>,
    pub tenant_scoped: bool,
    pub project_scoped: bool,
    pub canonical_model_scoped: bool,
    pub trace_id_len: Option<usize>,
    pub trace_id_material_in_output: bool,
    pub created_at_ttl_bound: bool,
    pub not_before_bound: bool,
    pub lookback_seconds: i64,
    pub limit: i64,
    pub status_filter: String,
    pub order_by: String,
    pub output_fields: Vec<String>,
    pub omitted_fields: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TraceAffinityPreviousSuccessRoute {
    pub channel_id: Uuid,
    pub provider_id: Uuid,
    pub canonical_model_id: Option<Uuid>,
    pub upstream_model: Option<String>,
}

pub fn build_trace_affinity_previous_success_lookup(
    input: TraceAffinityPreviousSuccessLookupInput,
) -> TraceAffinityPreviousSuccessLookupPlan {
    let lookback_seconds = bounded_lookback_seconds(input.lookback_seconds);
    let limit = bounded_limit(input.limit);

    let Some(raw_trace_id) = input.trace_id else {
        return skip(
            TraceAffinityLookupSkipReason::MissingTraceId,
            None,
            lookback_seconds,
            limit,
        );
    };

    let trace_id = raw_trace_id.trim();
    if trace_id.is_empty() {
        return skip(
            TraceAffinityLookupSkipReason::BlankTraceId,
            Some(0),
            lookback_seconds,
            limit,
        );
    }

    let trace_id_len = trace_id.len();
    if trace_id_len > TRACE_AFFINITY_MAX_TRACE_ID_BYTES {
        return skip(
            TraceAffinityLookupSkipReason::TraceIdTooLong,
            Some(trace_id_len),
            lookback_seconds,
            limit,
        );
    }

    let Some(raw_not_before) = input.not_before else {
        return skip(
            TraceAffinityLookupSkipReason::MissingNotBefore,
            Some(trace_id_len),
            lookback_seconds,
            limit,
        );
    };
    let not_before = raw_not_before.trim();
    if not_before.is_empty() {
        return skip(
            TraceAffinityLookupSkipReason::MissingNotBefore,
            Some(trace_id_len),
            lookback_seconds,
            limit,
        );
    }

    TraceAffinityPreviousSuccessLookupPlan::Query(TraceAffinityPreviousSuccessLookupQuery {
        tenant_id: input.tenant_id,
        project_id: input.project_id,
        trace_id: trace_id.to_string(),
        trace_id_len,
        canonical_model_id: input.canonical_model_id,
        not_before: not_before.to_string(),
        lookback_seconds,
        limit,
    })
}

fn skip(
    reason: TraceAffinityLookupSkipReason,
    trace_id_len: Option<usize>,
    lookback_seconds: i64,
    limit: i64,
) -> TraceAffinityPreviousSuccessLookupPlan {
    TraceAffinityPreviousSuccessLookupPlan::Skip(TraceAffinityPreviousSuccessLookupSkip {
        reason,
        trace_id_len,
        lookback_seconds,
        limit,
    })
}

fn bounded_lookback_seconds(lookback_seconds: Option<i64>) -> i64 {
    match lookback_seconds {
        Some(seconds) if seconds > 0 => seconds.min(TRACE_AFFINITY_MAX_LOOKBACK_SECONDS),
        _ => TRACE_AFFINITY_DEFAULT_LOOKBACK_SECONDS,
    }
}

fn bounded_limit(limit: Option<i64>) -> i64 {
    match limit {
        Some(limit) if limit > 0 => limit.min(TRACE_AFFINITY_MAX_LIMIT),
        _ => TRACE_AFFINITY_DEFAULT_LIMIT,
    }
}

fn static_strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

fn omitted_material_fields() -> Vec<String> {
    static_strings(&[
        "request_id",
        "trace_id",
        "provider_key_id",
        "virtual_key_id",
        "api_key_profile_id",
        "route_decision_snapshot",
        "request_body_hash",
        "response_body_hash",
        "payload_object_ref",
        "payload",
        "body",
        "metadata",
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Debug, Deserialize)]
    struct TraceAffinityLookupFixture {
        input: TraceAffinityLookupFixtureInput,
        expected_plan_summary: TraceAffinityPreviousSuccessLookupSummary,
        expected_sql_fragments: Vec<String>,
        disallowed_sql_fragments: Vec<String>,
        refusal_cases: Vec<TraceAffinityLookupRefusalFixture>,
    }

    #[derive(Debug, Deserialize)]
    struct TraceAffinityLookupFixtureInput {
        tenant_id: Uuid,
        project_id: Option<Uuid>,
        trace_id: String,
        canonical_model_id: Option<Uuid>,
        not_before: String,
        lookback_seconds: i64,
        limit: i64,
    }

    #[derive(Debug, Deserialize)]
    struct TraceAffinityLookupRefusalFixture {
        trace_id: Option<String>,
        not_before: Option<String>,
        expected_skip_reason: TraceAffinityLookupSkipReason,
    }

    #[test]
    fn previous_success_lookup_fixture_contract_is_stable() {
        let fixture: TraceAffinityLookupFixture = serde_json::from_str(include_str!(
            "../../../tests/fixtures/db/trace_affinity_previous_success_lookup_contract.json"
        ))
        .expect("trace affinity lookup fixture should be valid");

        let input = TraceAffinityPreviousSuccessLookupInput::new(
            fixture.input.tenant_id,
            Some(fixture.input.trace_id),
        )
        .with_project_id(fixture.input.project_id.expect("project scope"))
        .with_canonical_model_id(
            fixture
                .input
                .canonical_model_id
                .expect("canonical model scope"),
        )
        .with_not_before(fixture.input.not_before)
        .with_lookback_seconds(fixture.input.lookback_seconds)
        .with_limit(fixture.input.limit);

        let plan = build_trace_affinity_previous_success_lookup(input);
        let query = plan.query().expect("fixture should produce a query plan");

        assert_eq!(query.limit, TRACE_AFFINITY_MAX_LIMIT);
        assert_eq!(query.trace_id_len, 16);
        assert_eq!(plan.summary(), fixture.expected_plan_summary);

        for fragment in fixture.expected_sql_fragments {
            assert!(
                TRACE_AFFINITY_PREVIOUS_SUCCESS_LOOKUP_SQL.contains(&fragment),
                "SQL skeleton should contain fragment: {fragment}"
            );
        }

        let sql_lower = TRACE_AFFINITY_PREVIOUS_SUCCESS_LOOKUP_SQL.to_ascii_lowercase();
        for fragment in fixture.disallowed_sql_fragments {
            assert!(
                !sql_lower.contains(&fragment.to_ascii_lowercase()),
                "SQL skeleton should omit sensitive or unbounded fragment: {fragment}"
            );
        }
    }

    #[test]
    fn previous_success_lookup_skip_reasons_are_stable() {
        let fixture: TraceAffinityLookupFixture = serde_json::from_str(include_str!(
            "../../../tests/fixtures/db/trace_affinity_previous_success_lookup_contract.json"
        ))
        .expect("trace affinity lookup fixture should be valid");
        let tenant_id = fixture.input.tenant_id;

        for case in fixture.refusal_cases {
            let mut input =
                TraceAffinityPreviousSuccessLookupInput::new(tenant_id, case.trace_id.clone())
                    .with_limit(99)
                    .with_lookback_seconds(99_999);
            if let Some(not_before) = case.not_before {
                input = input.with_not_before(not_before);
            }

            let plan = build_trace_affinity_previous_success_lookup(input);
            let summary = plan.summary();

            assert!(!summary.enabled);
            assert_eq!(summary.skip_reason, Some(case.expected_skip_reason));
            assert_eq!(summary.limit, TRACE_AFFINITY_MAX_LIMIT);
            assert_eq!(
                summary.lookback_seconds,
                TRACE_AFFINITY_MAX_LOOKBACK_SECONDS
            );
        }
    }

    #[test]
    fn previous_success_lookup_summary_omits_trace_and_secret_material() {
        let input = TraceAffinityPreviousSuccessLookupInput::new(
            Uuid::from_u128(1),
            Some("trace Bearer sk-live-secret"),
        )
        .with_not_before("2026-06-03T11:00:00Z");

        let summary_text =
            serde_json::to_string(&build_trace_affinity_previous_success_lookup(input).summary())
                .expect("summary should serialize")
                .to_ascii_lowercase();

        for forbidden in [
            "trace bearer",
            "sk-live-secret",
            "authorization",
            "provider_key_id:",
            "request_body_hash:",
            "response_body_hash:",
        ] {
            assert!(
                !summary_text.contains(forbidden),
                "trace affinity summary should omit sensitive material: {forbidden}"
            );
        }
    }
}
