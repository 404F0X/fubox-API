use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const SUBSCRIPTION_SCHEDULER_EXECUTION_PLAN_SCHEMA: &str =
    "admin_subscription_scheduler_execution_plan_readback.v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubscriptionSchedulerEventType {
    Renew,
    PaymentFailed,
    Dunning,
    Expire,
    Prorate,
    Lifecycle,
}

impl SubscriptionSchedulerEventType {
    pub fn parse(value: &str) -> Self {
        match value {
            "renew" | "renewal" => Self::Renew,
            "payment_failed" | "grace" => Self::PaymentFailed,
            "dunning" => Self::Dunning,
            "expire" | "expiration" => Self::Expire,
            "prorate" | "proration" => Self::Prorate,
            _ => Self::Lifecycle,
        }
    }

    fn as_event_type(self) -> &'static str {
        match self {
            Self::Renew => "renew",
            Self::PaymentFailed => "payment_failed",
            Self::Dunning => "dunning",
            Self::Expire => "expire",
            Self::Prorate => "prorate",
            Self::Lifecycle => "lifecycle",
        }
    }

    fn kind(self) -> &'static str {
        match self {
            Self::Renew => "renewal",
            Self::PaymentFailed => "payment_failed_grace",
            Self::Dunning => "dunning",
            Self::Expire => "expiration",
            Self::Prorate => "proration",
            Self::Lifecycle => "lifecycle",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubscriptionSchedulerExecuteMode {
    DryRun,
    Apply,
    Refuse,
    Replay,
}

impl SubscriptionSchedulerExecuteMode {
    pub fn parse(value: &str) -> Self {
        match value {
            "apply" | "applied" => Self::Apply,
            "refuse" | "refused" => Self::Refuse,
            "replay" | "replayed" => Self::Replay,
            _ => Self::DryRun,
        }
    }

    fn as_mode(self) -> &'static str {
        match self {
            Self::DryRun => "dry_run",
            Self::Apply => "apply",
            Self::Refuse => "refuse",
            Self::Replay => "replay",
        }
    }

    fn target_status(self, current_status: &str) -> &str {
        match self {
            Self::Apply => "applied",
            Self::Refuse => "refused",
            Self::Replay => "replayed",
            Self::DryRun => current_status,
        }
    }
}

pub fn plan_subscription_scheduler_execution(
    event_type: &str,
    mode: &str,
    current_event_status: &str,
) -> Value {
    let event_type = SubscriptionSchedulerEventType::parse(event_type);
    let mode = SubscriptionSchedulerExecuteMode::parse(mode);
    let claimable = matches!(current_event_status, "scheduled" | "replayed");
    let mutates_local_state = mode != SubscriptionSchedulerExecuteMode::DryRun && claimable;
    let target_event_status = mode.target_status(current_event_status);

    json!({
        "schema": SUBSCRIPTION_SCHEDULER_EXECUTION_PLAN_SCHEMA,
        "kind": event_type.kind(),
        "event_type": event_type.as_event_type(),
        "mode": mode.as_mode(),
        "current_event_status": current_event_status,
        "target_event_status": target_event_status,
        "claimable": claimable,
        "mutates_local_state": mutates_local_state,
        "runtime_daemon_running": false,
        "payment_capture_handoff": payment_capture_handoff(event_type),
        "dunning_state": dunning_state(event_type, mode),
        "proration_state": proration_state(event_type),
        "local_write_policy": local_write_policy(event_type, mode, claimable),
        "idempotency": idempotency_policy(mode, claimable),
        "refusal": refusal_policy(mode, claimable),
        "steps": execution_steps(event_type, mutates_local_state),
        "safe_next_action": safe_next_action(event_type, mode, claimable),
        "omitted_fields": [
            "raw_payment_payload",
            "raw_provider_payload",
            "authorization",
            "raw_invoice_metadata",
            "provider_secret",
            "raw_idempotency_key"
        ],
        "secret_safe": true,
        "raw_payment_payload_returned": false,
        "raw_provider_payload_returned": false,
        "authorization_returned": false,
        "raw_invoice_metadata_returned": false,
        "provider_secret_returned": false,
        "raw_idempotency_key_echoed": false
    })
}

fn payment_capture_handoff(event_type: SubscriptionSchedulerEventType) -> Value {
    let capture_required = matches!(
        event_type,
        SubscriptionSchedulerEventType::Renew | SubscriptionSchedulerEventType::Dunning
    );
    let refund_required = event_type == SubscriptionSchedulerEventType::Prorate;

    json!({
        "required": capture_required,
        "refund_or_credit_note_handoff_possible": refund_required,
        "status": if capture_required {
            "provider_capture_reconciliation_required"
        } else if refund_required {
            "refund_or_credit_note_reconciliation_required_for_negative_delta"
        } else {
            "not_applicable"
        },
        "payment_capture_executed": false,
        "network_call_enabled": false,
        "network_call_performed": false,
        "candidate_required_before_subscription_capture_apply": capture_required,
        "scheduler_handoff_writes": {
            "payment_captures": "not_written_by_subscription_handoff",
            "ledger_entries": "not_written_by_subscription_handoff",
            "credit_grants": "not_written_by_subscription_handoff"
        },
        "safe_next_action": if capture_required {
            "fetch_provider_object_summary_and_reconcile_before_accepting_capture"
        } else if refund_required {
            "calculate_delta_locally_then_reconcile_refund_or_credit_note_executor_before_success"
        } else {
            "no_payment_provider_action_for_this_event_type"
        }
    })
}

fn dunning_state(
    event_type: SubscriptionSchedulerEventType,
    mode: SubscriptionSchedulerExecuteMode,
) -> Value {
    let applies = matches!(
        event_type,
        SubscriptionSchedulerEventType::PaymentFailed
            | SubscriptionSchedulerEventType::Dunning
            | SubscriptionSchedulerEventType::Expire
    );
    json!({
        "applies": applies,
        "status_after_failure": if applies { "payment_failed" } else { "not_applicable" },
        "retry_status": match event_type {
            SubscriptionSchedulerEventType::PaymentFailed => "retry_started_when_applied",
            SubscriptionSchedulerEventType::Dunning => "retry_attempt_recorded_when_applied",
            SubscriptionSchedulerEventType::Expire => "final_action_expire_subscription",
            _ => "not_applicable",
        },
        "max_attempts": if applies { json!(3) } else { Value::Null },
        "final_action": if applies { "expire_subscription" } else { "not_applicable" },
        "failure_no_credit_issued": applies,
        "mode": mode.as_mode(),
        "payment_capture_executed": false
    })
}

fn proration_state(event_type: SubscriptionSchedulerEventType) -> Value {
    let applies = event_type == SubscriptionSchedulerEventType::Prorate;
    json!({
        "applies": applies,
        "calculation": if applies { "target_minus_current_unit_price_times_remaining_period_ratio" } else { "not_applicable" },
        "positive_delta_policy": if applies { "create_local_invoice_order_and_credit_or_ledger_refs_after_apply" } else { "not_applicable" },
        "negative_delta_policy": if applies { "create_local_credit_adjustment_and_pending_refund_or_credit_note_handoff" } else { "not_applicable" },
        "zero_delta_policy": if applies { "refuse_or_noop_without_accounting_write" } else { "not_applicable" },
        "payment_capture_executed": false,
        "refund_executed": false
    })
}

fn local_write_policy(
    event_type: SubscriptionSchedulerEventType,
    mode: SubscriptionSchedulerExecuteMode,
    claimable: bool,
) -> Value {
    let no_write = mode == SubscriptionSchedulerExecuteMode::DryRun || !claimable;
    let writes = if no_write {
        json!([])
    } else if mode == SubscriptionSchedulerExecuteMode::Refuse {
        json!([
            "subscription_events_or_schedules.event_status",
            "subscription_events_or_schedules.refusal_code",
            "subscription_events_or_schedules.metadata"
        ])
    } else if mode == SubscriptionSchedulerExecuteMode::Replay {
        json!([
            "subscription_events_or_schedules.event_status",
            "subscription_events_or_schedules.metadata"
        ])
    } else {
        match event_type {
            SubscriptionSchedulerEventType::Renew => json!([
                "subscription_events_or_schedules",
                "subscriptions",
                "payment_orders",
                "payment_intents",
                "invoices",
                "credit_grants",
                "ledger_entries"
            ]),
            SubscriptionSchedulerEventType::PaymentFailed
            | SubscriptionSchedulerEventType::Dunning
            | SubscriptionSchedulerEventType::Expire => {
                json!(["subscription_events_or_schedules", "subscriptions"])
            }
            SubscriptionSchedulerEventType::Prorate => json!([
                "subscription_events_or_schedules",
                "subscriptions",
                "payment_orders",
                "payment_intents",
                "invoices",
                "credit_grants",
                "ledger_entries",
                "payment_refunds"
            ]),
            SubscriptionSchedulerEventType::Lifecycle => {
                json!(["subscription_events_or_schedules"])
            }
        }
    };

    json!({
        "no_write_path": no_write,
        "writes_limited_to": writes,
        "subscription_rows_update_allowed": !no_write && mode == SubscriptionSchedulerExecuteMode::Apply,
        "invoice_order_ledger_credit_writes": if no_write || mode != SubscriptionSchedulerExecuteMode::Apply {
            "none"
        } else {
            "bounded_local_settlement_when_applicable"
        },
        "payment_provider_writes": "never_from_subscription_scheduler_plan",
        "raw_metadata_write_allowed": false
    })
}

fn idempotency_policy(mode: SubscriptionSchedulerExecuteMode, claimable: bool) -> Value {
    json!({
        "raw_key_echoed": false,
        "fingerprint_only": true,
        "same_event_terminal_replay": if claimable { "not_terminal_yet" } else { "readback_existing_refs_without_duplicate_write" },
        "mode_noop": mode == SubscriptionSchedulerExecuteMode::DryRun,
        "duplicate_local_write_allowed": false
    })
}

fn refusal_policy(mode: SubscriptionSchedulerExecuteMode, claimable: bool) -> Value {
    let refused = mode == SubscriptionSchedulerExecuteMode::Refuse && claimable;
    json!({
        "active": refused,
        "refusal_code": if refused { "admin_subscription_scheduler_refused" } else { "not_applicable" },
        "subscription_write_allowed": !refused,
        "ledger_write_allowed": !refused,
        "credit_grant_write_allowed": !refused,
        "invoice_write_allowed": !refused,
        "payment_capture_allowed": false,
        "no_write_accounting_path": refused
    })
}

fn execution_steps(event_type: SubscriptionSchedulerEventType, mutates_local_state: bool) -> Value {
    let status = |applies: bool| {
        if mutates_local_state && applies {
            "bounded_local_execution"
        } else {
            "readback_plan_only"
        }
    };
    match event_type {
        SubscriptionSchedulerEventType::Renew => json!([
            {"name": "provider_capture_reconciliation_handoff", "status": "required_before_provider_success", "executed": false},
            {"name": "invoice_order_linkage", "status": status(true), "executed": mutates_local_state},
            {"name": "credit_grant_or_ledger_marker", "status": status(true), "executed": mutates_local_state},
            {"name": "subscription_period_advance", "status": status(true), "executed": mutates_local_state}
        ]),
        SubscriptionSchedulerEventType::PaymentFailed => json!([
            {"name": "mark_payment_failed", "status": status(true), "executed": mutates_local_state},
            {"name": "start_dunning_window", "status": status(true), "executed": mutates_local_state}
        ]),
        SubscriptionSchedulerEventType::Dunning => json!([
            {"name": "provider_capture_reconciliation_handoff", "status": "required_before_provider_success", "executed": false},
            {"name": "record_retry_attempt", "status": status(true), "executed": mutates_local_state},
            {"name": "schedule_next_retry_or_expire", "status": status(true), "executed": mutates_local_state}
        ]),
        SubscriptionSchedulerEventType::Expire => json!([
            {"name": "expire_subscription_access", "status": status(true), "executed": mutates_local_state},
            {"name": "stop_future_renewal", "status": status(true), "executed": mutates_local_state}
        ]),
        SubscriptionSchedulerEventType::Prorate => json!([
            {"name": "calculate_proration_delta", "status": status(true), "executed": mutates_local_state},
            {"name": "invoice_or_credit_note_linkage", "status": status(true), "executed": mutates_local_state},
            {"name": "credit_grant_or_ledger_marker", "status": status(true), "executed": mutates_local_state},
            {"name": "plan_change_commit", "status": status(true), "executed": mutates_local_state}
        ]),
        SubscriptionSchedulerEventType::Lifecycle => json!([
            {"name": "record_lifecycle_event", "status": status(true), "executed": mutates_local_state}
        ]),
    }
}

fn safe_next_action(
    event_type: SubscriptionSchedulerEventType,
    mode: SubscriptionSchedulerExecuteMode,
    claimable: bool,
) -> &'static str {
    if mode == SubscriptionSchedulerExecuteMode::DryRun {
        return "review_plan_then_execute_apply_refuse_or_replay_with_reason";
    }
    if !claimable {
        return "show_existing_readback_without_duplicate_write";
    }
    if mode == SubscriptionSchedulerExecuteMode::Refuse {
        return "record_refusal_and_show_no_accounting_write_path";
    }
    match event_type {
        SubscriptionSchedulerEventType::Renew | SubscriptionSchedulerEventType::Dunning => {
            "record_bounded_local_readback_then_wait_for_payment_provider_reconciliation"
        }
        SubscriptionSchedulerEventType::Prorate => {
            "record_proration_readback_then_reconcile_capture_or_refund_handoff"
        }
        SubscriptionSchedulerEventType::Expire => "record_expired_state_readback",
        SubscriptionSchedulerEventType::PaymentFailed => "record_payment_failed_and_dunning_state",
        SubscriptionSchedulerEventType::Lifecycle => "record_lifecycle_readback",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renewal_plan_keeps_provider_capture_as_handoff() {
        let plan = plan_subscription_scheduler_execution("renew", "apply", "scheduled");
        assert_eq!(
            plan["schema"],
            json!(SUBSCRIPTION_SCHEDULER_EXECUTION_PLAN_SCHEMA)
        );
        assert_eq!(plan["kind"], json!("renewal"));
        assert_eq!(plan["payment_capture_handoff"]["required"], json!(true));
        assert_eq!(
            plan["payment_capture_handoff"]["payment_capture_executed"],
            json!(false)
        );
        assert_eq!(
            plan["payment_capture_handoff"]["scheduler_handoff_writes"]["payment_captures"],
            json!("not_written_by_subscription_handoff")
        );
        assert_eq!(plan["runtime_daemon_running"], json!(false));
    }

    #[test]
    fn refusal_plan_is_accounting_no_write() {
        let plan = plan_subscription_scheduler_execution("dunning", "refuse", "scheduled");
        assert_eq!(plan["refusal"]["active"], json!(true));
        assert_eq!(plan["refusal"]["ledger_write_allowed"], json!(false));
        assert_eq!(
            plan["local_write_policy"]["payment_provider_writes"],
            json!("never_from_subscription_scheduler_plan")
        );
    }

    #[test]
    fn terminal_replay_is_idempotent_noop_readback() {
        let plan = plan_subscription_scheduler_execution("prorate", "apply", "applied");
        assert_eq!(plan["claimable"], json!(false));
        assert_eq!(plan["local_write_policy"]["no_write_path"], json!(true));
        assert_eq!(
            plan["idempotency"]["same_event_terminal_replay"],
            json!("readback_existing_refs_without_duplicate_write")
        );
    }
}
