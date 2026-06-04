use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

pub const PROVIDER_KEY_RATE_LIMIT_RESERVATION_PERSISTENCE_SCHEMA: &str =
    "provider_key_rate_limit_reservation_persistence_v1";
pub const PROVIDER_KEY_RATE_LIMIT_RESERVATION_SCOPE_INDEX: &str =
    "provider_keys_tenant_id_id_channel_scope";
pub const PROVIDER_KEY_RATE_LIMIT_RESERVATION_MAX_ROWS: usize = 1;

pub const PROVIDER_KEY_RATE_LIMIT_RESERVATION_ACQUIRE_SQL: &str = r#"
            with scoped_provider_key as (
              select
                tenant_id, id, channel_id,
                rpm_limit, tpm_limit, concurrency_limit,
                current_window_state
              from provider_keys
              where tenant_id = $1
                and id = $2
                and channel_id = $3
                and deleted_at is null
                and status not in ('manual_disabled', 'deleted')
              for update
            ),
            window_values as (
              select
                tenant_id, id, channel_id,
                rpm_limit, tpm_limit, concurrency_limit,
                case
                  when rpm_limit is null then null
                  when jsonb_typeof(current_window_state #> '{rpm,used}') = 'number'
                    then (current_window_state #>> '{rpm,used}')::bigint
                  else null
                end as rpm_used,
                case
                  when tpm_limit is null then null
                  when jsonb_typeof(current_window_state #> '{tpm,used}') = 'number'
                    then (current_window_state #>> '{tpm,used}')::bigint
                  else null
                end as tpm_used,
                case
                  when concurrency_limit is null then null
                  when jsonb_typeof(current_window_state #> '{concurrency,used}') = 'number'
                    then (current_window_state #>> '{concurrency,used}')::bigint
                  else null
                end as concurrency_used
              from scoped_provider_key
            ),
            eligible as (
              select
                tenant_id, id, channel_id,
                rpm_limit, tpm_limit, concurrency_limit,
                rpm_used, tpm_used, concurrency_used
              from window_values
              where $4::bigint >= 0
                and $5::bigint >= 0
                and $6::bigint >= 0
                and (
                  (rpm_limit is not null and $4::bigint > 0)
                  or (tpm_limit is not null and $5::bigint > 0)
                  or (concurrency_limit is not null and $6::bigint > 0)
                )
                and (
                  rpm_limit is null
                  or (rpm_limit > 0 and rpm_used is not null and rpm_used >= 0 and rpm_used + $4::bigint <= rpm_limit)
                )
                and (
                  tpm_limit is null
                  or (tpm_limit > 0 and tpm_used is not null and tpm_used >= 0 and tpm_used + $5::bigint <= tpm_limit)
                )
                and (
                  concurrency_limit is null
                  or (
                    concurrency_limit > 0
                    and concurrency_used is not null
                    and concurrency_used >= 0
                    and concurrency_used + $6::bigint <= concurrency_limit
                  )
                )
            )
            update provider_keys pk
               set current_window_state =
                   case
                     when eligible.concurrency_limit is null then
                       case
                         when eligible.tpm_limit is null then
                           case
                             when eligible.rpm_limit is null then pk.current_window_state
                             else jsonb_set(pk.current_window_state, '{rpm,used}', to_jsonb(eligible.rpm_used + $4::bigint), true)
                           end
                         else jsonb_set(
                           case
                             when eligible.rpm_limit is null then pk.current_window_state
                             else jsonb_set(pk.current_window_state, '{rpm,used}', to_jsonb(eligible.rpm_used + $4::bigint), true)
                           end,
                           '{tpm,used}', to_jsonb(eligible.tpm_used + $5::bigint), true
                         )
                       end
                     else jsonb_set(
                       case
                         when eligible.tpm_limit is null then
                           case
                             when eligible.rpm_limit is null then pk.current_window_state
                             else jsonb_set(pk.current_window_state, '{rpm,used}', to_jsonb(eligible.rpm_used + $4::bigint), true)
                           end
                         else jsonb_set(
                           case
                             when eligible.rpm_limit is null then pk.current_window_state
                             else jsonb_set(pk.current_window_state, '{rpm,used}', to_jsonb(eligible.rpm_used + $4::bigint), true)
                           end,
                           '{tpm,used}', to_jsonb(eligible.tpm_used + $5::bigint), true
                         )
                       end,
                       '{concurrency,used}', to_jsonb(eligible.concurrency_used + $6::bigint), true
                     )
                   end,
                   updated_at = now()
              from eligible
             where pk.tenant_id = eligible.tenant_id
               and pk.id = eligible.id
               and pk.channel_id = eligible.channel_id
            returning
              pk.id as provider_key_id,
              pk.channel_id,
              pk.rpm_limit,
              pk.tpm_limit,
              pk.concurrency_limit,
              pk.current_window_state #>> '{rpm,used}' as rpm_used,
              pk.current_window_state #>> '{tpm,used}' as tpm_used,
              pk.current_window_state #>> '{concurrency,used}' as concurrency_used
            "#;

pub const PROVIDER_KEY_RATE_LIMIT_RESERVATION_RELEASE_SQL: &str = r#"
            with scoped_provider_key as (
              select
                tenant_id, id, channel_id,
                rpm_limit, tpm_limit, concurrency_limit,
                current_window_state
              from provider_keys
              where tenant_id = $1
                and id = $2
                and channel_id = $3
                and deleted_at is null
                and status not in ('manual_disabled', 'deleted')
                and $7::boolean = true
              for update
            ),
            window_values as (
              select
                tenant_id, id, channel_id,
                rpm_limit, tpm_limit, concurrency_limit,
                case
                  when rpm_limit is null then null
                  when jsonb_typeof(current_window_state #> '{rpm,used}') = 'number'
                    then (current_window_state #>> '{rpm,used}')::bigint
                  else null
                end as rpm_used,
                case
                  when tpm_limit is null then null
                  when jsonb_typeof(current_window_state #> '{tpm,used}') = 'number'
                    then (current_window_state #>> '{tpm,used}')::bigint
                  else null
                end as tpm_used,
                case
                  when concurrency_limit is null then null
                  when jsonb_typeof(current_window_state #> '{concurrency,used}') = 'number'
                    then (current_window_state #>> '{concurrency,used}')::bigint
                  else null
                end as concurrency_used
              from scoped_provider_key
            ),
            eligible as (
              select
                tenant_id, id, channel_id,
                rpm_limit, tpm_limit, concurrency_limit,
                rpm_used, tpm_used, concurrency_used
              from window_values
              where $4::bigint >= 0
                and $5::bigint >= 0
                and $6::bigint >= 0
                and (
                  (rpm_limit is not null and $4::bigint > 0)
                  or (tpm_limit is not null and $5::bigint > 0)
                  or (concurrency_limit is not null and $6::bigint > 0)
                )
                and (rpm_limit is null or (rpm_limit > 0 and rpm_used is not null and rpm_used >= 0))
                and (tpm_limit is null or (tpm_limit > 0 and tpm_used is not null and tpm_used >= 0))
                and (
                  concurrency_limit is null
                  or (concurrency_limit > 0 and concurrency_used is not null and concurrency_used >= 0)
                )
            )
            update provider_keys pk
               set current_window_state =
                   case
                     when eligible.concurrency_limit is null then
                       case
                         when eligible.tpm_limit is null then
                           case
                             when eligible.rpm_limit is null then pk.current_window_state
                             else jsonb_set(pk.current_window_state, '{rpm,used}', to_jsonb(greatest(eligible.rpm_used - $4::bigint, 0)), true)
                           end
                         else jsonb_set(
                           case
                             when eligible.rpm_limit is null then pk.current_window_state
                             else jsonb_set(pk.current_window_state, '{rpm,used}', to_jsonb(greatest(eligible.rpm_used - $4::bigint, 0)), true)
                           end,
                           '{tpm,used}', to_jsonb(greatest(eligible.tpm_used - $5::bigint, 0)), true
                         )
                       end
                     else jsonb_set(
                       case
                         when eligible.tpm_limit is null then
                           case
                             when eligible.rpm_limit is null then pk.current_window_state
                             else jsonb_set(pk.current_window_state, '{rpm,used}', to_jsonb(greatest(eligible.rpm_used - $4::bigint, 0)), true)
                           end
                         else jsonb_set(
                           case
                             when eligible.rpm_limit is null then pk.current_window_state
                             else jsonb_set(pk.current_window_state, '{rpm,used}', to_jsonb(greatest(eligible.rpm_used - $4::bigint, 0)), true)
                           end,
                           '{tpm,used}', to_jsonb(greatest(eligible.tpm_used - $5::bigint, 0)), true
                         )
                       end,
                       '{concurrency,used}', to_jsonb(greatest(eligible.concurrency_used - $6::bigint, 0)), true
                     )
                   end,
                   updated_at = now()
              from eligible
             where pk.tenant_id = eligible.tenant_id
               and pk.id = eligible.id
               and pk.channel_id = eligible.channel_id
            returning
              pk.id as provider_key_id,
              pk.channel_id,
              pk.rpm_limit,
              pk.tpm_limit,
              pk.concurrency_limit,
              pk.current_window_state #>> '{rpm,used}' as rpm_used,
              pk.current_window_state #>> '{tpm,used}' as tpm_used,
              pk.current_window_state #>> '{concurrency,used}' as concurrency_used
            "#;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProviderKeyRateLimitReservationOperation {
    Acquire,
    Release,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProviderKeyRateLimitReservationStatus {
    SqlReady,
    Refused,
    Noop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProviderKeyRateLimitReservationRefusal {
    InvalidRequired,
    InvalidLimit,
    MissingWindow,
    InvalidWindow,
    OverLimit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProviderKeyRateLimitDimension {
    RequestsPerMinute,
    TokensPerMinute,
    Concurrency,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProviderKeyRateLimitDimensionStatus {
    Unlimited,
    WindowReady,
    MissingWindow,
    InvalidWindow,
    InvalidLimit,
    InvalidRequired,
    OverLimit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProviderKeyRateLimitCounterUpdate {
    None,
    Increment,
    Decrement,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderKeyRateLimitRequiredCapacity {
    pub requests_per_minute: i64,
    pub tokens_per_minute: i64,
    pub concurrency: i64,
}

impl ProviderKeyRateLimitRequiredCapacity {
    pub const fn new(requests_per_minute: i64, tokens_per_minute: i64, concurrency: i64) -> Self {
        Self {
            requests_per_minute,
            tokens_per_minute,
            concurrency,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProviderKeyRateLimitReservationPersistenceInput {
    pub tenant_id: Uuid,
    pub provider_key_id: Uuid,
    pub channel_id: Uuid,
    pub operation: ProviderKeyRateLimitReservationOperation,
    pub reservation_acquired: bool,
    pub rpm_limit: Option<i32>,
    pub tpm_limit: Option<i32>,
    pub concurrency_limit: Option<i32>,
    pub current_window_state: Value,
    pub required: ProviderKeyRateLimitRequiredCapacity,
}

impl ProviderKeyRateLimitReservationPersistenceInput {
    pub fn acquire(
        tenant_id: Uuid,
        provider_key_id: Uuid,
        channel_id: Uuid,
        current_window_state: Value,
        required: ProviderKeyRateLimitRequiredCapacity,
    ) -> Self {
        Self {
            tenant_id,
            provider_key_id,
            channel_id,
            operation: ProviderKeyRateLimitReservationOperation::Acquire,
            reservation_acquired: false,
            rpm_limit: None,
            tpm_limit: None,
            concurrency_limit: None,
            current_window_state,
            required,
        }
    }

    pub fn release(
        tenant_id: Uuid,
        provider_key_id: Uuid,
        channel_id: Uuid,
        current_window_state: Value,
        required: ProviderKeyRateLimitRequiredCapacity,
        reservation_acquired: bool,
    ) -> Self {
        Self {
            tenant_id,
            provider_key_id,
            channel_id,
            operation: ProviderKeyRateLimitReservationOperation::Release,
            reservation_acquired,
            rpm_limit: None,
            tpm_limit: None,
            concurrency_limit: None,
            current_window_state,
            required,
        }
    }

    pub const fn with_limits(
        mut self,
        rpm_limit: Option<i32>,
        tpm_limit: Option<i32>,
        concurrency_limit: Option<i32>,
    ) -> Self {
        self.rpm_limit = rpm_limit;
        self.tpm_limit = tpm_limit;
        self.concurrency_limit = concurrency_limit;
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderKeyRateLimitReservationPersistencePlan {
    pub operation: ProviderKeyRateLimitReservationOperation,
    pub status: ProviderKeyRateLimitReservationStatus,
    pub refusal_reason: Option<ProviderKeyRateLimitReservationRefusal>,
    pub tenant_id: Uuid,
    pub provider_key_id: Uuid,
    pub channel_id: Uuid,
    pub dimensions: Vec<ProviderKeyRateLimitReservationDimensionPlan>,
    pub counter_updates_planned: usize,
}

impl ProviderKeyRateLimitReservationPersistencePlan {
    pub fn sql(&self) -> Option<&'static str> {
        if self.status != ProviderKeyRateLimitReservationStatus::SqlReady {
            return None;
        }

        match self.operation {
            ProviderKeyRateLimitReservationOperation::Acquire => {
                Some(PROVIDER_KEY_RATE_LIMIT_RESERVATION_ACQUIRE_SQL)
            }
            ProviderKeyRateLimitReservationOperation::Release => {
                Some(PROVIDER_KEY_RATE_LIMIT_RESERVATION_RELEASE_SQL)
            }
        }
    }

    pub fn summary(&self) -> ProviderKeyRateLimitReservationPersistenceSummary {
        ProviderKeyRateLimitReservationPersistenceSummary {
            schema: PROVIDER_KEY_RATE_LIMIT_RESERVATION_PERSISTENCE_SCHEMA.to_string(),
            operation: self.operation,
            status: self.status,
            refusal_reason: self.refusal_reason,
            sql_name: self.sql_name().map(str::to_string),
            source_table: "provider_keys".to_string(),
            scope_index: PROVIDER_KEY_RATE_LIMIT_RESERVATION_SCOPE_INDEX.to_string(),
            scope_columns: static_strings(&["tenant_id", "provider_key_id", "channel_id"]),
            tenant_scoped: true,
            provider_key_scoped: true,
            channel_scoped: true,
            row_lock: self.status == ProviderKeyRateLimitReservationStatus::SqlReady,
            bounded_rows: PROVIDER_KEY_RATE_LIMIT_RESERVATION_MAX_ROWS,
            bind_count: self.bind_count(),
            current_window_state_material_in_output: false,
            counter_updates_planned: self.counter_updates_planned,
            dimensions: self.dimensions.clone(),
            output_fields: static_strings(&[
                "provider_key_id",
                "channel_id",
                "rpm_used",
                "tpm_used",
                "concurrency_used",
            ]),
            omitted_fields: omitted_material_fields(),
        }
    }

    fn sql_name(&self) -> Option<&'static str> {
        if self.status != ProviderKeyRateLimitReservationStatus::SqlReady {
            return None;
        }

        match self.operation {
            ProviderKeyRateLimitReservationOperation::Acquire => {
                Some("PROVIDER_KEY_RATE_LIMIT_RESERVATION_ACQUIRE_SQL")
            }
            ProviderKeyRateLimitReservationOperation::Release => {
                Some("PROVIDER_KEY_RATE_LIMIT_RESERVATION_RELEASE_SQL")
            }
        }
    }

    fn bind_count(&self) -> usize {
        if self.status != ProviderKeyRateLimitReservationStatus::SqlReady {
            return 0;
        }

        match self.operation {
            ProviderKeyRateLimitReservationOperation::Acquire => 6,
            ProviderKeyRateLimitReservationOperation::Release => 7,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderKeyRateLimitReservationDimensionPlan {
    pub dimension: ProviderKeyRateLimitDimension,
    pub status: ProviderKeyRateLimitDimensionStatus,
    pub limit: Option<u64>,
    pub used_before: Option<u64>,
    pub required: u64,
    pub used_after: Option<u64>,
    pub counter_update: ProviderKeyRateLimitCounterUpdate,
    pub window_present: bool,
    pub saturated_release: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderKeyRateLimitReservationPersistenceSummary {
    pub schema: String,
    pub operation: ProviderKeyRateLimitReservationOperation,
    pub status: ProviderKeyRateLimitReservationStatus,
    pub refusal_reason: Option<ProviderKeyRateLimitReservationRefusal>,
    pub sql_name: Option<String>,
    pub source_table: String,
    pub scope_index: String,
    pub scope_columns: Vec<String>,
    pub tenant_scoped: bool,
    pub provider_key_scoped: bool,
    pub channel_scoped: bool,
    pub row_lock: bool,
    pub bounded_rows: usize,
    pub bind_count: usize,
    pub current_window_state_material_in_output: bool,
    pub counter_updates_planned: usize,
    pub dimensions: Vec<ProviderKeyRateLimitReservationDimensionPlan>,
    pub output_fields: Vec<String>,
    pub omitted_fields: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderKeyRateLimitReservationExecutionInput {
    pub tenant_id: Uuid,
    pub provider_key_id: Uuid,
    pub channel_id: Uuid,
    pub operation: ProviderKeyRateLimitReservationOperation,
    pub reservation_acquired: bool,
    pub required: ProviderKeyRateLimitRequiredCapacity,
}

impl ProviderKeyRateLimitReservationExecutionInput {
    pub const fn acquire(
        tenant_id: Uuid,
        provider_key_id: Uuid,
        channel_id: Uuid,
        required: ProviderKeyRateLimitRequiredCapacity,
    ) -> Self {
        Self {
            tenant_id,
            provider_key_id,
            channel_id,
            operation: ProviderKeyRateLimitReservationOperation::Acquire,
            reservation_acquired: false,
            required,
        }
    }

    pub const fn release(
        tenant_id: Uuid,
        provider_key_id: Uuid,
        channel_id: Uuid,
        required: ProviderKeyRateLimitRequiredCapacity,
        reservation_acquired: bool,
    ) -> Self {
        Self {
            tenant_id,
            provider_key_id,
            channel_id,
            operation: ProviderKeyRateLimitReservationOperation::Release,
            reservation_acquired,
            required,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderKeyRateLimitReservationExecutionCommand {
    pub operation: ProviderKeyRateLimitReservationOperation,
    pub status: ProviderKeyRateLimitReservationStatus,
    pub refusal_reason: Option<ProviderKeyRateLimitReservationRefusal>,
    pub tenant_id: Uuid,
    pub provider_key_id: Uuid,
    pub channel_id: Uuid,
    pub reservation_acquired: bool,
    pub required: ProviderKeyRateLimitRequiredCapacity,
    pub requested_counter_updates: usize,
}

impl ProviderKeyRateLimitReservationExecutionCommand {
    pub fn sql(&self) -> Option<&'static str> {
        if self.status != ProviderKeyRateLimitReservationStatus::SqlReady {
            return None;
        }

        match self.operation {
            ProviderKeyRateLimitReservationOperation::Acquire => {
                Some(PROVIDER_KEY_RATE_LIMIT_RESERVATION_ACQUIRE_SQL)
            }
            ProviderKeyRateLimitReservationOperation::Release => {
                Some(PROVIDER_KEY_RATE_LIMIT_RESERVATION_RELEASE_SQL)
            }
        }
    }

    pub fn summary(&self) -> ProviderKeyRateLimitReservationExecutionSummary {
        ProviderKeyRateLimitReservationExecutionSummary {
            schema: PROVIDER_KEY_RATE_LIMIT_RESERVATION_PERSISTENCE_SCHEMA.to_string(),
            operation: self.operation,
            status: self.status,
            refusal_reason: self.refusal_reason,
            sql_name: self.sql_name().map(str::to_string),
            source_table: "provider_keys".to_string(),
            scope_index: PROVIDER_KEY_RATE_LIMIT_RESERVATION_SCOPE_INDEX.to_string(),
            scope_columns: static_strings(&["tenant_id", "provider_key_id", "channel_id"]),
            tenant_scoped: true,
            provider_key_scoped: true,
            channel_scoped: true,
            row_lock: self.status == ProviderKeyRateLimitReservationStatus::SqlReady,
            bounded_rows: PROVIDER_KEY_RATE_LIMIT_RESERVATION_MAX_ROWS,
            bind_count: self.bind_count(),
            requested_counter_updates: self.requested_counter_updates,
            current_window_state_material_in_output: false,
            output_fields: static_strings(&[
                "provider_key_id",
                "channel_id",
                "rpm_used",
                "tpm_used",
                "concurrency_used",
            ]),
            omitted_fields: omitted_material_fields(),
        }
    }

    fn sql_name(&self) -> Option<&'static str> {
        if self.status != ProviderKeyRateLimitReservationStatus::SqlReady {
            return None;
        }

        match self.operation {
            ProviderKeyRateLimitReservationOperation::Acquire => {
                Some("PROVIDER_KEY_RATE_LIMIT_RESERVATION_ACQUIRE_SQL")
            }
            ProviderKeyRateLimitReservationOperation::Release => {
                Some("PROVIDER_KEY_RATE_LIMIT_RESERVATION_RELEASE_SQL")
            }
        }
    }

    fn bind_count(&self) -> usize {
        if self.status != ProviderKeyRateLimitReservationStatus::SqlReady {
            return 0;
        }

        match self.operation {
            ProviderKeyRateLimitReservationOperation::Acquire => 6,
            ProviderKeyRateLimitReservationOperation::Release => 7,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderKeyRateLimitReservationExecutionSummary {
    pub schema: String,
    pub operation: ProviderKeyRateLimitReservationOperation,
    pub status: ProviderKeyRateLimitReservationStatus,
    pub refusal_reason: Option<ProviderKeyRateLimitReservationRefusal>,
    pub sql_name: Option<String>,
    pub source_table: String,
    pub scope_index: String,
    pub scope_columns: Vec<String>,
    pub tenant_scoped: bool,
    pub provider_key_scoped: bool,
    pub channel_scoped: bool,
    pub row_lock: bool,
    pub bounded_rows: usize,
    pub bind_count: usize,
    pub requested_counter_updates: usize,
    pub current_window_state_material_in_output: bool,
    pub output_fields: Vec<String>,
    pub omitted_fields: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProviderKeyRateLimitReservationExecutionStatus {
    Applied,
    NotApplied,
    Refused,
    Noop,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderKeyRateLimitReservationExecutionRow {
    pub provider_key_id: Uuid,
    pub channel_id: Uuid,
    pub rpm_limit: Option<i32>,
    pub tpm_limit: Option<i32>,
    pub concurrency_limit: Option<i32>,
    pub rpm_used: Option<u64>,
    pub tpm_used: Option<u64>,
    pub concurrency_used: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderKeyRateLimitReservationExecutionResult {
    pub schema: String,
    pub operation: ProviderKeyRateLimitReservationOperation,
    pub status: ProviderKeyRateLimitReservationExecutionStatus,
    pub refusal_reason: Option<ProviderKeyRateLimitReservationRefusal>,
    pub sql_name: Option<String>,
    pub affected_rows: usize,
    pub bounded_rows: usize,
    pub current_window_state_material_in_output: bool,
    pub row: Option<ProviderKeyRateLimitReservationExecutionRow>,
    pub omitted_fields: Vec<String>,
}

impl ProviderKeyRateLimitReservationExecutionResult {
    pub fn from_command_without_query(
        command: &ProviderKeyRateLimitReservationExecutionCommand,
    ) -> Self {
        let status = match command.status {
            ProviderKeyRateLimitReservationStatus::Noop => {
                ProviderKeyRateLimitReservationExecutionStatus::Noop
            }
            ProviderKeyRateLimitReservationStatus::Refused => {
                ProviderKeyRateLimitReservationExecutionStatus::Refused
            }
            ProviderKeyRateLimitReservationStatus::SqlReady => {
                ProviderKeyRateLimitReservationExecutionStatus::NotApplied
            }
        };
        Self::new(command, status, None)
    }

    pub fn from_command_row(
        command: &ProviderKeyRateLimitReservationExecutionCommand,
        row: Option<ProviderKeyRateLimitReservationExecutionRow>,
    ) -> Self {
        let status = if row.is_some() {
            ProviderKeyRateLimitReservationExecutionStatus::Applied
        } else {
            ProviderKeyRateLimitReservationExecutionStatus::NotApplied
        };
        Self::new(command, status, row)
    }

    fn new(
        command: &ProviderKeyRateLimitReservationExecutionCommand,
        status: ProviderKeyRateLimitReservationExecutionStatus,
        row: Option<ProviderKeyRateLimitReservationExecutionRow>,
    ) -> Self {
        let affected_rows = usize::from(row.is_some());
        Self {
            schema: PROVIDER_KEY_RATE_LIMIT_RESERVATION_PERSISTENCE_SCHEMA.to_string(),
            operation: command.operation,
            status,
            refusal_reason: command.refusal_reason,
            sql_name: command.sql_name().map(str::to_string),
            affected_rows,
            bounded_rows: PROVIDER_KEY_RATE_LIMIT_RESERVATION_MAX_ROWS,
            current_window_state_material_in_output: false,
            row,
            omitted_fields: omitted_material_fields(),
        }
    }
}

pub fn build_provider_key_rate_limit_reservation_execution_command(
    input: ProviderKeyRateLimitReservationExecutionInput,
) -> ProviderKeyRateLimitReservationExecutionCommand {
    let (status, refusal_reason) = execution_command_status(&input);
    ProviderKeyRateLimitReservationExecutionCommand {
        operation: input.operation,
        status,
        refusal_reason,
        tenant_id: input.tenant_id,
        provider_key_id: input.provider_key_id,
        channel_id: input.channel_id,
        reservation_acquired: input.reservation_acquired,
        required: input.required,
        requested_counter_updates: if status == ProviderKeyRateLimitReservationStatus::SqlReady {
            requested_counter_updates(input.required)
        } else {
            0
        },
    }
}

fn execution_command_status(
    input: &ProviderKeyRateLimitReservationExecutionInput,
) -> (
    ProviderKeyRateLimitReservationStatus,
    Option<ProviderKeyRateLimitReservationRefusal>,
) {
    if input.required.requests_per_minute < 0
        || input.required.tokens_per_minute < 0
        || input.required.concurrency < 0
    {
        return (
            ProviderKeyRateLimitReservationStatus::Refused,
            Some(ProviderKeyRateLimitReservationRefusal::InvalidRequired),
        );
    }

    if requested_counter_updates(input.required) == 0 {
        return (ProviderKeyRateLimitReservationStatus::Noop, None);
    }

    if input.operation == ProviderKeyRateLimitReservationOperation::Release
        && !input.reservation_acquired
    {
        return (ProviderKeyRateLimitReservationStatus::Noop, None);
    }

    (ProviderKeyRateLimitReservationStatus::SqlReady, None)
}

fn requested_counter_updates(required: ProviderKeyRateLimitRequiredCapacity) -> usize {
    [
        required.requests_per_minute,
        required.tokens_per_minute,
        required.concurrency,
    ]
    .into_iter()
    .filter(|required| *required > 0)
    .count()
}

pub fn build_provider_key_rate_limit_reservation_persistence_plan(
    input: ProviderKeyRateLimitReservationPersistenceInput,
) -> ProviderKeyRateLimitReservationPersistencePlan {
    let evaluations = [
        evaluate_dimension(
            ProviderKeyRateLimitDimension::RequestsPerMinute,
            input.rpm_limit,
            read_window_counter(
                &input.current_window_state,
                &[
                    &["rpm", "used"],
                    &["requests_per_minute", "used"],
                    &["rpm_used"],
                    &["requests_per_minute_used"],
                ],
            ),
            input.required.requests_per_minute,
            input.operation,
        ),
        evaluate_dimension(
            ProviderKeyRateLimitDimension::TokensPerMinute,
            input.tpm_limit,
            read_window_counter(
                &input.current_window_state,
                &[
                    &["tpm", "used"],
                    &["tokens_per_minute", "used"],
                    &["tpm_used"],
                    &["tokens_per_minute_used"],
                ],
            ),
            input.required.tokens_per_minute,
            input.operation,
        ),
        evaluate_dimension(
            ProviderKeyRateLimitDimension::Concurrency,
            input.concurrency_limit,
            read_window_counter(
                &input.current_window_state,
                &[
                    &["concurrency", "used"],
                    &["active_concurrency"],
                    &["in_flight"],
                    &["concurrency_used"],
                ],
            ),
            input.required.concurrency,
            input.operation,
        ),
    ];

    let (mut status, refusal_reason) =
        persistence_status(input.operation, input.reservation_acquired, &evaluations);
    let mut dimensions = evaluations
        .iter()
        .map(|evaluation| dimension_plan(input.operation, status, evaluation))
        .collect::<Vec<_>>();
    let mut counter_updates_planned = dimensions
        .iter()
        .filter(|dimension| dimension.counter_update != ProviderKeyRateLimitCounterUpdate::None)
        .count();
    if status == ProviderKeyRateLimitReservationStatus::SqlReady && counter_updates_planned == 0 {
        status = ProviderKeyRateLimitReservationStatus::Noop;
        dimensions = evaluations
            .iter()
            .map(|evaluation| dimension_plan(input.operation, status, evaluation))
            .collect();
        counter_updates_planned = 0;
    }

    ProviderKeyRateLimitReservationPersistencePlan {
        operation: input.operation,
        status,
        refusal_reason,
        tenant_id: input.tenant_id,
        provider_key_id: input.provider_key_id,
        channel_id: input.channel_id,
        dimensions,
        counter_updates_planned,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct DimensionEvaluation {
    dimension: ProviderKeyRateLimitDimension,
    status: ProviderKeyRateLimitDimensionStatus,
    limit: Option<u64>,
    used: Option<u64>,
    required: u64,
    window_present: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CounterRead {
    Missing,
    Invalid,
    Value(i64),
}

fn evaluate_dimension(
    dimension: ProviderKeyRateLimitDimension,
    raw_limit: Option<i32>,
    counter: CounterRead,
    raw_required: i64,
    operation: ProviderKeyRateLimitReservationOperation,
) -> DimensionEvaluation {
    let required = raw_required.max(0) as u64;
    if raw_required < 0 {
        return dimension_evaluation(
            dimension,
            ProviderKeyRateLimitDimensionStatus::InvalidRequired,
            raw_limit.and_then(non_negative_u64_from_i32),
            None,
            required,
            !matches!(counter, CounterRead::Missing),
        );
    }

    let Some(limit) = raw_limit else {
        return dimension_evaluation(
            dimension,
            ProviderKeyRateLimitDimensionStatus::Unlimited,
            None,
            None,
            required,
            !matches!(counter, CounterRead::Missing),
        );
    };
    if limit <= 0 {
        return dimension_evaluation(
            dimension,
            ProviderKeyRateLimitDimensionStatus::InvalidLimit,
            None,
            None,
            required,
            !matches!(counter, CounterRead::Missing),
        );
    }

    let limit = limit as u64;
    let used = match counter {
        CounterRead::Missing => {
            return dimension_evaluation(
                dimension,
                ProviderKeyRateLimitDimensionStatus::MissingWindow,
                Some(limit),
                None,
                required,
                false,
            );
        }
        CounterRead::Invalid | CounterRead::Value(i64::MIN..=-1) => {
            return dimension_evaluation(
                dimension,
                ProviderKeyRateLimitDimensionStatus::InvalidWindow,
                Some(limit),
                None,
                required,
                true,
            );
        }
        CounterRead::Value(used) => used as u64,
    };

    let status = if operation == ProviderKeyRateLimitReservationOperation::Acquire
        && used.saturating_add(required) > limit
    {
        ProviderKeyRateLimitDimensionStatus::OverLimit
    } else {
        ProviderKeyRateLimitDimensionStatus::WindowReady
    };

    dimension_evaluation(dimension, status, Some(limit), Some(used), required, true)
}

fn dimension_evaluation(
    dimension: ProviderKeyRateLimitDimension,
    status: ProviderKeyRateLimitDimensionStatus,
    limit: Option<u64>,
    used: Option<u64>,
    required: u64,
    window_present: bool,
) -> DimensionEvaluation {
    DimensionEvaluation {
        dimension,
        status,
        limit,
        used,
        required,
        window_present,
    }
}

fn persistence_status(
    operation: ProviderKeyRateLimitReservationOperation,
    reservation_acquired: bool,
    evaluations: &[DimensionEvaluation],
) -> (
    ProviderKeyRateLimitReservationStatus,
    Option<ProviderKeyRateLimitReservationRefusal>,
) {
    if operation == ProviderKeyRateLimitReservationOperation::Release && !reservation_acquired {
        return (ProviderKeyRateLimitReservationStatus::Noop, None);
    }

    if evaluations
        .iter()
        .any(|e| e.status == ProviderKeyRateLimitDimensionStatus::InvalidRequired)
    {
        return (
            ProviderKeyRateLimitReservationStatus::Refused,
            Some(ProviderKeyRateLimitReservationRefusal::InvalidRequired),
        );
    }
    if evaluations
        .iter()
        .any(|e| e.status == ProviderKeyRateLimitDimensionStatus::InvalidLimit)
    {
        return (
            ProviderKeyRateLimitReservationStatus::Refused,
            Some(ProviderKeyRateLimitReservationRefusal::InvalidLimit),
        );
    }
    if evaluations
        .iter()
        .any(|e| e.status == ProviderKeyRateLimitDimensionStatus::MissingWindow)
    {
        return (
            ProviderKeyRateLimitReservationStatus::Refused,
            Some(ProviderKeyRateLimitReservationRefusal::MissingWindow),
        );
    }
    if evaluations
        .iter()
        .any(|e| e.status == ProviderKeyRateLimitDimensionStatus::InvalidWindow)
    {
        return (
            ProviderKeyRateLimitReservationStatus::Refused,
            Some(ProviderKeyRateLimitReservationRefusal::InvalidWindow),
        );
    }
    if operation == ProviderKeyRateLimitReservationOperation::Acquire
        && evaluations
            .iter()
            .any(|e| e.status == ProviderKeyRateLimitDimensionStatus::OverLimit)
    {
        return (
            ProviderKeyRateLimitReservationStatus::Refused,
            Some(ProviderKeyRateLimitReservationRefusal::OverLimit),
        );
    }

    (ProviderKeyRateLimitReservationStatus::SqlReady, None)
}

fn dimension_plan(
    operation: ProviderKeyRateLimitReservationOperation,
    persistence_status: ProviderKeyRateLimitReservationStatus,
    evaluation: &DimensionEvaluation,
) -> ProviderKeyRateLimitReservationDimensionPlan {
    let counter_update = counter_update_for_dimension(operation, persistence_status, evaluation);
    let used_after = match (evaluation.used, counter_update) {
        (Some(used), ProviderKeyRateLimitCounterUpdate::Increment) => {
            Some(used.saturating_add(evaluation.required))
        }
        (Some(used), ProviderKeyRateLimitCounterUpdate::Decrement) => {
            Some(used.saturating_sub(evaluation.required))
        }
        (Some(used), ProviderKeyRateLimitCounterUpdate::None) => Some(used),
        (None, _) => None,
    };

    ProviderKeyRateLimitReservationDimensionPlan {
        dimension: evaluation.dimension,
        status: evaluation.status,
        limit: evaluation.limit,
        used_before: evaluation.used,
        required: evaluation.required,
        used_after,
        counter_update,
        window_present: evaluation.window_present,
        saturated_release: matches!(counter_update, ProviderKeyRateLimitCounterUpdate::Decrement)
            && evaluation
                .used
                .is_some_and(|used| used < evaluation.required),
    }
}

fn counter_update_for_dimension(
    operation: ProviderKeyRateLimitReservationOperation,
    persistence_status: ProviderKeyRateLimitReservationStatus,
    evaluation: &DimensionEvaluation,
) -> ProviderKeyRateLimitCounterUpdate {
    if persistence_status != ProviderKeyRateLimitReservationStatus::SqlReady
        || evaluation.limit.is_none()
        || evaluation.used.is_none()
        || evaluation.required == 0
    {
        return ProviderKeyRateLimitCounterUpdate::None;
    }

    match operation {
        ProviderKeyRateLimitReservationOperation::Acquire => {
            ProviderKeyRateLimitCounterUpdate::Increment
        }
        ProviderKeyRateLimitReservationOperation::Release => {
            ProviderKeyRateLimitCounterUpdate::Decrement
        }
    }
}

fn read_window_counter(state: &Value, paths: &[&[&str]]) -> CounterRead {
    for path in paths {
        if let Some(value) = value_at_path(state, path) {
            return parse_counter_value(value);
        }
    }

    CounterRead::Missing
}

fn value_at_path<'a>(value: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let mut current = value;
    for segment in path {
        current = current.get(*segment)?;
    }
    Some(current)
}

fn parse_counter_value(value: &Value) -> CounterRead {
    if let Some(value) = value.as_i64() {
        return CounterRead::Value(value);
    }
    if let Some(value) = value.as_u64() {
        return match i64::try_from(value) {
            Ok(value) => CounterRead::Value(value),
            Err(_) => CounterRead::Invalid,
        };
    }
    CounterRead::Invalid
}

fn non_negative_u64_from_i32(value: i32) -> Option<u64> {
    (value >= 0).then_some(value as u64)
}

fn static_strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

fn omitted_material_fields() -> Vec<String> {
    static_strings(&[
        "raw_window_state_material",
        "provider_credential_material",
        "secret_fingerprint_material",
        "request_content_material",
        "response_content_material",
        "upstream_location_material",
        "metadata_material",
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use serde_json::json;

    #[derive(Debug, Deserialize)]
    struct RateLimitPersistenceFixture {
        input: RateLimitPersistenceFixtureInput,
        expected_plan_summary: ProviderKeyRateLimitReservationPersistenceSummary,
        expected_execution_command_summary: ProviderKeyRateLimitReservationExecutionSummary,
        expected_sql_fragments: RateLimitSqlFragments,
        disallowed_sql_fragments: Vec<String>,
        refusal_cases: Vec<RateLimitPersistenceRefusalFixture>,
    }

    #[derive(Debug, Deserialize)]
    struct RateLimitPersistenceFixtureInput {
        tenant_id: Uuid,
        provider_key_id: Uuid,
        channel_id: Uuid,
        rpm_limit: Option<i32>,
        tpm_limit: Option<i32>,
        concurrency_limit: Option<i32>,
        required: ProviderKeyRateLimitRequiredCapacity,
        current_window_state: Value,
    }

    #[derive(Debug, Deserialize)]
    struct RateLimitSqlFragments {
        acquire: Vec<String>,
        release: Vec<String>,
    }

    #[derive(Debug, Deserialize)]
    struct RateLimitPersistenceRefusalFixture {
        current_window_state: Value,
        rpm_limit: Option<i32>,
        tpm_limit: Option<i32>,
        concurrency_limit: Option<i32>,
        required: ProviderKeyRateLimitRequiredCapacity,
        expected_refusal_reason: ProviderKeyRateLimitReservationRefusal,
    }

    #[test]
    fn provider_key_rate_limit_reservation_fixture_contract_is_stable() {
        let fixture: RateLimitPersistenceFixture = serde_json::from_str(include_str!(
            "../../../tests/fixtures/db/provider_key_rate_limit_reservation_persistence_contract.json"
        ))
        .expect("rate-limit persistence fixture should be valid");
        let input = fixture_input(&fixture.input);

        let plan = build_provider_key_rate_limit_reservation_persistence_plan(input);
        let summary = plan.summary();

        assert_eq!(
            plan.sql(),
            Some(PROVIDER_KEY_RATE_LIMIT_RESERVATION_ACQUIRE_SQL)
        );
        assert_eq!(summary, fixture.expected_plan_summary);
        let execution_command = build_provider_key_rate_limit_reservation_execution_command(
            fixture_execution_input(&fixture.input),
        );
        assert_eq!(
            execution_command.sql(),
            Some(PROVIDER_KEY_RATE_LIMIT_RESERVATION_ACQUIRE_SQL)
        );
        assert_eq!(
            execution_command.summary(),
            fixture.expected_execution_command_summary
        );

        for fragment in fixture.expected_sql_fragments.acquire {
            assert!(
                PROVIDER_KEY_RATE_LIMIT_RESERVATION_ACQUIRE_SQL.contains(&fragment),
                "acquire SQL skeleton should contain fragment: {fragment}"
            );
        }
        for fragment in fixture.expected_sql_fragments.release {
            assert!(
                PROVIDER_KEY_RATE_LIMIT_RESERVATION_RELEASE_SQL.contains(&fragment),
                "release SQL skeleton should contain fragment: {fragment}"
            );
        }

        let sql_lower = format!(
            "{}\n{}",
            PROVIDER_KEY_RATE_LIMIT_RESERVATION_ACQUIRE_SQL,
            PROVIDER_KEY_RATE_LIMIT_RESERVATION_RELEASE_SQL
        )
        .to_ascii_lowercase();
        for fragment in fixture.disallowed_sql_fragments {
            assert!(
                !sql_lower.contains(&fragment.to_ascii_lowercase()),
                "SQL skeleton should omit sensitive or unbounded fragment: {fragment}"
            );
        }
    }

    #[test]
    fn provider_key_rate_limit_reservation_execution_boundary_is_repository_facing() {
        let repository_source = include_str!("repository.rs");

        for fragment in [
            "execute_provider_key_rate_limit_reservation",
            "ProviderKeyRateLimitReservationExecutionInput",
            "build_provider_key_rate_limit_reservation_execution_command",
            "ProviderKeyRateLimitReservationStatus::SqlReady",
            ".fetch_optional(&self.pool)",
            "provider_key_rate_limit_reservation_execution_row_from_row",
        ] {
            assert!(
                repository_source.contains(fragment),
                "repository execution boundary should contain fragment: {fragment}"
            );
        }
    }

    #[test]
    fn provider_key_rate_limit_reservation_execution_command_noops_and_refuses_without_db() {
        let tenant_id = Uuid::from_u128(1);
        let provider_key_id = Uuid::from_u128(2);
        let channel_id = Uuid::from_u128(3);

        let zero_required = build_provider_key_rate_limit_reservation_execution_command(
            ProviderKeyRateLimitReservationExecutionInput::acquire(
                tenant_id,
                provider_key_id,
                channel_id,
                ProviderKeyRateLimitRequiredCapacity::new(0, 0, 0),
            ),
        );
        assert_eq!(
            zero_required.status,
            ProviderKeyRateLimitReservationStatus::Noop
        );
        assert_eq!(zero_required.sql(), None);
        assert_eq!(zero_required.summary().bind_count, 0);
        assert_eq!(zero_required.summary().requested_counter_updates, 0);

        let unacquired_release = build_provider_key_rate_limit_reservation_execution_command(
            ProviderKeyRateLimitReservationExecutionInput::release(
                tenant_id,
                provider_key_id,
                channel_id,
                ProviderKeyRateLimitRequiredCapacity::new(1, 1, 1),
                false,
            ),
        );
        assert_eq!(
            unacquired_release.status,
            ProviderKeyRateLimitReservationStatus::Noop
        );
        assert_eq!(unacquired_release.sql(), None);

        let invalid_required = build_provider_key_rate_limit_reservation_execution_command(
            ProviderKeyRateLimitReservationExecutionInput::acquire(
                tenant_id,
                provider_key_id,
                channel_id,
                ProviderKeyRateLimitRequiredCapacity::new(-1, 1, 1),
            ),
        );
        assert_eq!(
            invalid_required.status,
            ProviderKeyRateLimitReservationStatus::Refused
        );
        assert_eq!(
            invalid_required.refusal_reason,
            Some(ProviderKeyRateLimitReservationRefusal::InvalidRequired)
        );
        assert_eq!(invalid_required.sql(), None);

        let release = build_provider_key_rate_limit_reservation_execution_command(
            ProviderKeyRateLimitReservationExecutionInput::release(
                tenant_id,
                provider_key_id,
                channel_id,
                ProviderKeyRateLimitRequiredCapacity::new(1, 1, 1),
                true,
            ),
        );
        assert_eq!(
            release.status,
            ProviderKeyRateLimitReservationStatus::SqlReady
        );
        assert_eq!(
            release.sql(),
            Some(PROVIDER_KEY_RATE_LIMIT_RESERVATION_RELEASE_SQL)
        );
        assert_eq!(release.summary().bind_count, 7);
    }

    #[test]
    fn provider_key_rate_limit_reservation_execution_result_is_secret_safe() {
        let command = build_provider_key_rate_limit_reservation_execution_command(
            ProviderKeyRateLimitReservationExecutionInput::acquire(
                Uuid::from_u128(1),
                Uuid::from_u128(2),
                Uuid::from_u128(3),
                ProviderKeyRateLimitRequiredCapacity::new(1, 128, 1),
            ),
        );
        let result = ProviderKeyRateLimitReservationExecutionResult::from_command_row(
            &command,
            Some(ProviderKeyRateLimitReservationExecutionRow {
                provider_key_id: Uuid::from_u128(2),
                channel_id: Uuid::from_u128(3),
                rpm_limit: Some(60),
                tpm_limit: Some(1_000),
                concurrency_limit: Some(4),
                rpm_used: Some(11),
                tpm_used: Some(378),
                concurrency_used: Some(2),
            }),
        );

        assert_eq!(
            result.status,
            ProviderKeyRateLimitReservationExecutionStatus::Applied
        );
        assert_eq!(result.affected_rows, 1);
        assert_eq!(
            result.bounded_rows,
            PROVIDER_KEY_RATE_LIMIT_RESERVATION_MAX_ROWS
        );
        assert_eq!(result.current_window_state_material_in_output, false);

        let result_text = serde_json::to_string(&result)
            .expect("result should serialize")
            .to_ascii_lowercase();
        for forbidden in [
            "sk-live-secret",
            "bearer",
            "authorization",
            "provider_key_secret",
            "\"current_window_state\":",
            "request_body",
            "response_body",
            "payload",
            "endpoint",
        ] {
            assert!(
                !result_text.contains(forbidden),
                "execution result leaked forbidden marker: {forbidden}"
            );
        }
    }

    #[test]
    fn provider_key_rate_limit_reservation_refusal_cases_are_conservative() {
        let fixture: RateLimitPersistenceFixture = serde_json::from_str(include_str!(
            "../../../tests/fixtures/db/provider_key_rate_limit_reservation_persistence_contract.json"
        ))
        .expect("rate-limit persistence fixture should be valid");

        for case in fixture.refusal_cases {
            let input = ProviderKeyRateLimitReservationPersistenceInput::acquire(
                fixture.input.tenant_id,
                fixture.input.provider_key_id,
                fixture.input.channel_id,
                case.current_window_state,
                case.required,
            )
            .with_limits(case.rpm_limit, case.tpm_limit, case.concurrency_limit);

            let plan = build_provider_key_rate_limit_reservation_persistence_plan(input);
            assert_eq!(plan.status, ProviderKeyRateLimitReservationStatus::Refused);
            assert_eq!(plan.refusal_reason, Some(case.expected_refusal_reason));
            assert_eq!(plan.sql(), None);
            assert_eq!(plan.counter_updates_planned, 0);
        }
    }

    #[test]
    fn provider_key_rate_limit_reservation_release_saturates_and_noops() {
        let tenant_id = Uuid::from_u128(1);
        let provider_key_id = Uuid::from_u128(2);
        let channel_id = Uuid::from_u128(3);
        let required = ProviderKeyRateLimitRequiredCapacity::new(3, 20, 2);
        let state = json!({
            "rpm": { "used": 1 },
            "tpm": { "used": 100 },
            "concurrency": { "used": 1 }
        });

        let release = build_provider_key_rate_limit_reservation_persistence_plan(
            ProviderKeyRateLimitReservationPersistenceInput::release(
                tenant_id,
                provider_key_id,
                channel_id,
                state.clone(),
                required,
                true,
            )
            .with_limits(Some(60), Some(1_000), Some(4)),
        );
        assert_eq!(
            release.status,
            ProviderKeyRateLimitReservationStatus::SqlReady
        );
        assert_eq!(
            release.sql(),
            Some(PROVIDER_KEY_RATE_LIMIT_RESERVATION_RELEASE_SQL)
        );
        assert_eq!(release.counter_updates_planned, 3);
        let rpm = release
            .dimensions
            .iter()
            .find(|dimension| {
                dimension.dimension == ProviderKeyRateLimitDimension::RequestsPerMinute
            })
            .expect("rpm dimension should exist");
        assert_eq!(rpm.used_after, Some(0));
        assert!(rpm.saturated_release);

        let unlimited_acquire = build_provider_key_rate_limit_reservation_persistence_plan(
            ProviderKeyRateLimitReservationPersistenceInput::acquire(
                tenant_id,
                provider_key_id,
                channel_id,
                state.clone(),
                required,
            )
            .with_limits(None, None, None),
        );
        assert_eq!(
            unlimited_acquire.status,
            ProviderKeyRateLimitReservationStatus::Noop
        );
        assert_eq!(unlimited_acquire.sql(), None);
        assert_eq!(unlimited_acquire.counter_updates_planned, 0);

        let noop = build_provider_key_rate_limit_reservation_persistence_plan(
            ProviderKeyRateLimitReservationPersistenceInput::release(
                tenant_id,
                provider_key_id,
                channel_id,
                state,
                required,
                false,
            )
            .with_limits(Some(60), Some(1_000), Some(4)),
        );
        assert_eq!(noop.status, ProviderKeyRateLimitReservationStatus::Noop);
        assert_eq!(noop.sql(), None);
        assert_eq!(noop.counter_updates_planned, 0);

        let missing_window_release = build_provider_key_rate_limit_reservation_persistence_plan(
            ProviderKeyRateLimitReservationPersistenceInput::release(
                tenant_id,
                provider_key_id,
                channel_id,
                json!({}),
                required,
                true,
            )
            .with_limits(Some(60), None, None),
        );
        assert_eq!(
            missing_window_release.status,
            ProviderKeyRateLimitReservationStatus::Refused
        );
        assert_eq!(
            missing_window_release.refusal_reason,
            Some(ProviderKeyRateLimitReservationRefusal::MissingWindow)
        );
        assert_eq!(missing_window_release.sql(), None);
    }

    #[test]
    fn provider_key_rate_limit_reservation_summary_omits_secret_and_raw_window_material() {
        let input = ProviderKeyRateLimitReservationPersistenceInput::acquire(
            Uuid::from_u128(1),
            Uuid::from_u128(2),
            Uuid::from_u128(3),
            json!({
                "rpm": { "used": 1 },
                "tpm": { "used": 2 },
                "concurrency": { "used": 0 },
                "authorization": "Bearer sk-live-secret",
                "endpoint": "https://provider.example.test/v1",
                "payload": "raw request body"
            }),
            ProviderKeyRateLimitRequiredCapacity::new(1, 1, 1),
        )
        .with_limits(Some(60), Some(1_000), Some(4));
        let summary_text = serde_json::to_string(
            &build_provider_key_rate_limit_reservation_persistence_plan(input).summary(),
        )
        .expect("summary should serialize")
        .to_ascii_lowercase();

        for forbidden in [
            "sk-live-secret",
            "bearer",
            "https://provider.example.test",
            "raw request body",
            "\"authorization\"",
            "\"payload\":\"",
            "\"endpoint\":\"https",
            "\"current_window_state\":{",
        ] {
            assert!(
                !summary_text.contains(forbidden),
                "rate-limit persistence summary leaked forbidden marker: {forbidden}"
            );
        }
    }

    fn fixture_input(
        fixture: &RateLimitPersistenceFixtureInput,
    ) -> ProviderKeyRateLimitReservationPersistenceInput {
        ProviderKeyRateLimitReservationPersistenceInput::acquire(
            fixture.tenant_id,
            fixture.provider_key_id,
            fixture.channel_id,
            fixture.current_window_state.clone(),
            fixture.required,
        )
        .with_limits(
            fixture.rpm_limit,
            fixture.tpm_limit,
            fixture.concurrency_limit,
        )
    }

    fn fixture_execution_input(
        fixture: &RateLimitPersistenceFixtureInput,
    ) -> ProviderKeyRateLimitReservationExecutionInput {
        ProviderKeyRateLimitReservationExecutionInput::acquire(
            fixture.tenant_id,
            fixture.provider_key_id,
            fixture.channel_id,
            fixture.required,
        )
    }
}
