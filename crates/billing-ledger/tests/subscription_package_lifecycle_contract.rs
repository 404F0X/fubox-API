use ai_gateway_billing_ledger::plan_subscription_scheduler_execution;
use serde::{Deserialize, Serialize};
use serde_json::Value;

const FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/subscription_package_lifecycle_contract.json");

#[derive(Debug, Deserialize)]
struct SubscriptionPackageLifecycleContract {
    schema: String,
    status: String,
    runtime_implemented: bool,
    contract_only: bool,
    paid_gate_changed: bool,
    secret_safe: bool,
    money_contract: MoneyContract,
    plan_states: Vec<String>,
    subscription_states: Vec<String>,
    secret_safe_contract: SecretSafeContract,
    accounting_contract: AccountingContract,
    runtime_acceptance_contract: RuntimeAcceptanceContract,
    expected_payment_reconciliation: ExpectedPaymentReconciliation,
    execution_plan_contract: ExecutionPlanContract,
    runtime_feasibility_plan: RuntimeFeasibilityPlan,
    schema_contract: SchemaContract,
    required_cases: Vec<String>,
    cases: Vec<ContractCase>,
}

#[derive(Debug, Deserialize)]
struct MoneyContract {
    format: String,
    scale: usize,
    float_allowed: bool,
}

#[derive(Debug, Deserialize)]
struct SecretSafeContract {
    raw_provider_payload_output_allowed: bool,
    raw_plan_payload_output_allowed: bool,
    token_output_allowed: bool,
    voucher_or_code_output_allowed: bool,
    forbidden_output_terms: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct AccountingContract {
    subscription_credit_requires_credit_grant_or_ledger_marker: bool,
    renewal_requires_invoice_or_order_linkage: bool,
    cancel_or_terminate_requires_grant_revoke_or_ledger_reversal_marker_when_credit_issued: bool,
    audit_metadata_required: bool,
    direct_wallet_snapshot_mutation_allowed: bool,
    allowed_markers: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct RuntimeAcceptanceContract {
    runtime_artifact_schema: String,
    runtime_artifact_path: String,
    contract_artifact_must_not_mark_runtime_verified: bool,
    runtime_implemented_required: bool,
    contract_only_required: bool,
    route_or_internal_runtime_invocation_required: bool,
    plan_package_crud_readback_required: bool,
    subscription_lifecycle_readback_required: bool,
    subscription_state_transitions_readback_required: bool,
    trial_proration_dunning_readback_required: bool,
    credit_grant_or_ledger_effect_readback_required: bool,
    invoice_order_linkage_readback_required: bool,
    idempotency_replay_readback_required: bool,
    conflict_no_duplicate_write_readback_required: bool,
    refusal_no_write_readback_required: bool,
    audit_readback_required: bool,
    money_decimal_strings_required: bool,
    secret_safe_required: bool,
    paid_gate_changed_required: bool,
    direct_wallet_snapshot_mutation_forbidden: bool,
    raw_provider_payload_output_allowed: bool,
    raw_plan_payload_output_allowed: bool,
    token_output_allowed: bool,
    voucher_or_code_output_allowed: bool,
}

#[derive(Debug, Deserialize)]
struct ExpectedPaymentReconciliation {
    schema: String,
    source_handoff_schema: String,
    candidate_schema: String,
    candidate_source: String,
    candidate_required_before_subscription_capture_apply: bool,
    payment_logic_reimplemented_by_subscription: bool,
    expected_provider_object_types: Vec<String>,
    expected_provider_statuses: Vec<String>,
    expected_local_refs: Vec<String>,
    status_mapping: PaymentReconciliationStatusMapping,
    safe_next_action_mapping: PaymentReconciliationNextActionMapping,
    scheduler_handoff_network_call_enabled: bool,
    scheduler_handoff_network_call_performed: bool,
    scheduler_handoff_writes: PaymentReconciliationHandoffWrites,
    raw_provider_payload_output_allowed: bool,
    authorization_output_allowed: bool,
    provider_secret_output_allowed: bool,
    secret_safe: bool,
}

#[derive(Debug, Deserialize)]
struct PaymentReconciliationStatusMapping {
    matched: String,
    mismatch: String,
    blocked: String,
}

#[derive(Debug, Deserialize)]
struct PaymentReconciliationNextActionMapping {
    matched: String,
    mismatch: String,
    blocked_retryable: String,
    blocked_missing_summary: String,
}

#[derive(Debug, Deserialize)]
struct PaymentReconciliationHandoffWrites {
    payment_captures: String,
    ledger_entries: String,
    credit_grants: String,
}

#[derive(Debug, Deserialize)]
struct ExecutionPlanContract {
    schema: String,
    runtime_daemon_running: bool,
    local_business_logic_implemented: bool,
    real_payment_capture_enabled: bool,
    event_types: Vec<String>,
    execute_modes: Vec<String>,
    required_readbacks: Vec<String>,
    no_write_paths: Vec<String>,
    forbidden_output_terms: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct RuntimeFeasibilityPlan {
    status: String,
    runtime_implemented: bool,
    contract_only: bool,
    paid_gate_changed: bool,
    gateway_change_required: bool,
    control_plane_runtime_required: bool,
    new_schema_required: bool,
    reusable_primitives: Vec<RuntimePrimitive>,
    missing_primitives: Vec<RuntimePrimitive>,
    proposed_slices: Vec<ProposedRuntimeSlice>,
}

#[derive(Debug, Deserialize)]
struct RuntimePrimitive {
    primitive: String,
    status: Option<String>,
    usage: Option<String>,
    required: Option<bool>,
    reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ProposedRuntimeSlice {
    slice: String,
    owner: String,
    scope: String,
    requires_migration: bool,
    runtime_acceptance: bool,
}

#[derive(Debug, Deserialize)]
struct SchemaContract {
    schema_contract_version: String,
    runtime_implemented: bool,
    contract_only: bool,
    paid_gate_changed: bool,
    migration_required: bool,
    draft_migration_path: String,
    tables: Vec<SchemaTable>,
    required_relationships: Vec<String>,
    invariants: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct SchemaTable {
    name: String,
    required: bool,
    purpose: String,
    required_columns: Vec<String>,
    #[serde(default)]
    money_decimal_columns: Vec<String>,
    unique_constraints: Vec<String>,
    foreign_keys: Vec<String>,
    secret_safe_columns: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ContractCase {
    name: String,
    operation: String,
    decision: String,
    #[serde(default)]
    idempotency: String,
    #[serde(default)]
    refusal_code: String,
    #[serde(default)]
    same_idempotency_key: bool,
    #[serde(default)]
    same_body: bool,
    #[serde(default)]
    new_subscription_row_written: Option<bool>,
    #[serde(default)]
    new_credit_grant_row_written: Option<bool>,
    #[serde(default)]
    new_ledger_entry_written: Option<bool>,
    #[serde(default)]
    new_invoice_row_written: Option<bool>,
    #[serde(default)]
    subscription_write_allowed: Option<bool>,
    #[serde(default)]
    ledger_write_allowed: Option<bool>,
    #[serde(default)]
    credit_grant_write_allowed: Option<bool>,
    #[serde(default)]
    invoice_write_allowed: Option<bool>,
    #[serde(default)]
    request: Value,
    response: Value,
    accounting_markers: Vec<String>,
    #[serde(default)]
    audit_metadata: Value,
    #[serde(default)]
    reconciliation: Value,
}

#[test]
fn subscription_package_contract_fixture_enforces_product_ledger_invariants() {
    let fixture: SubscriptionPackageLifecycleContract =
        serde_json::from_str(FIXTURE).expect("fixture parses");
    assert_eq!(fixture.schema, "subscription_package_lifecycle_contract.v1");
    assert_eq!(fixture.status, "contract_enforced_not_runtime_wired");
    assert!(!fixture.runtime_implemented);
    assert!(fixture.contract_only);
    assert!(!fixture.paid_gate_changed);
    assert!(fixture.secret_safe);
    assert_money_contract(&fixture.money_contract);
    assert_lifecycle_states(&fixture);
    assert_secret_contract(&fixture.secret_safe_contract);
    assert_accounting_contract(&fixture.accounting_contract);
    assert_runtime_acceptance_contract(&fixture.runtime_acceptance_contract);
    assert_expected_payment_reconciliation(&fixture.expected_payment_reconciliation);
    assert_execution_plan_contract(&fixture.execution_plan_contract);
    assert_runtime_feasibility_plan(&fixture.runtime_feasibility_plan);
    assert_schema_contract(&fixture.schema_contract);

    let case_names = fixture
        .cases
        .iter()
        .map(|case| case.name.as_str())
        .collect::<Vec<_>>();
    for required in &fixture.required_cases {
        assert!(
            case_names.contains(&required.as_str()),
            "missing required case {required}"
        );
    }

    for case in &fixture.cases {
        assert_case_shape(case, &fixture);
        assert_money_fields(case, fixture.money_contract.scale);
        assert_secret_safe(case, &fixture.secret_safe_contract.forbidden_output_terms);
        assert_accounting_markers(case, &fixture.accounting_contract);
    }

    assert_credit_effect_cases(&fixture.cases);
    assert_invoice_order_linkage(&fixture.cases);
    assert_replay_case(&fixture.cases);
    assert_cancel_termination_reversal(&fixture.cases);
    assert_refusal_cases(&fixture.cases);
}

#[test]
fn subscription_scheduler_execution_plan_readback_is_stable_and_secret_safe() {
    let renewal = plan_subscription_scheduler_execution("renew", "apply", "scheduled");
    assert_eq!(
        renewal.get("schema").and_then(Value::as_str),
        Some("admin_subscription_scheduler_execution_plan_readback.v1")
    );
    assert_eq!(
        renewal
            .pointer("/payment_capture_handoff/required")
            .and_then(Value::as_bool),
        Some(true)
    );
    assert_eq!(
        renewal
            .pointer("/payment_capture_handoff/payment_capture_executed")
            .and_then(Value::as_bool),
        Some(false)
    );
    assert_eq!(
        renewal
            .get("runtime_daemon_running")
            .and_then(Value::as_bool),
        Some(false)
    );

    let dunning = plan_subscription_scheduler_execution("dunning", "apply", "scheduled");
    assert_eq!(
        dunning
            .pointer("/dunning_state/status_after_failure")
            .and_then(Value::as_str),
        Some("payment_failed")
    );
    assert_eq!(
        dunning
            .pointer("/dunning_state/final_action")
            .and_then(Value::as_str),
        Some("expire_subscription")
    );

    let proration = plan_subscription_scheduler_execution("prorate", "dry_run", "scheduled");
    assert_eq!(
        proration
            .pointer("/proration_state/negative_delta_policy")
            .and_then(Value::as_str),
        Some("create_local_credit_adjustment_and_pending_refund_or_credit_note_handoff")
    );
    assert_eq!(
        proration
            .pointer("/local_write_policy/no_write_path")
            .and_then(Value::as_bool),
        Some(true)
    );

    let terminal_replay = plan_subscription_scheduler_execution("renew", "apply", "applied");
    assert_eq!(
        terminal_replay
            .pointer("/idempotency/same_event_terminal_replay")
            .and_then(Value::as_str),
        Some("readback_existing_refs_without_duplicate_write")
    );
    assert_eq!(
        renewal
            .get("raw_provider_payload_returned")
            .and_then(Value::as_bool),
        Some(false)
    );
    assert_eq!(
        renewal
            .get("authorization_returned")
            .and_then(Value::as_bool),
        Some(false)
    );
    assert_eq!(
        renewal
            .get("provider_secret_returned")
            .and_then(Value::as_bool),
        Some(false)
    );
}

fn assert_money_contract(contract: &MoneyContract) {
    assert_eq!(contract.format, "decimal_string_with_currency");
    assert_eq!(contract.scale, 8);
    assert!(!contract.float_allowed);
}

fn assert_lifecycle_states(fixture: &SubscriptionPackageLifecycleContract) {
    for state in ["created", "updated", "archived"] {
        assert!(fixture.plan_states.contains(&state.to_string()));
    }
    for state in [
        "created",
        "trialing",
        "active",
        "renewed",
        "paused",
        "resumed",
        "cancelled",
        "payment_failed",
        "expired",
        "terminated",
    ] {
        assert!(fixture.subscription_states.contains(&state.to_string()));
    }
}

fn assert_secret_contract(contract: &SecretSafeContract) {
    assert!(!contract.raw_provider_payload_output_allowed);
    assert!(!contract.raw_plan_payload_output_allowed);
    assert!(!contract.token_output_allowed);
    assert!(!contract.voucher_or_code_output_allowed);
}

fn assert_accounting_contract(contract: &AccountingContract) {
    assert!(contract.subscription_credit_requires_credit_grant_or_ledger_marker);
    assert!(contract.renewal_requires_invoice_or_order_linkage);
    assert!(
        contract
            .cancel_or_terminate_requires_grant_revoke_or_ledger_reversal_marker_when_credit_issued
    );
    assert!(contract.audit_metadata_required);
    assert!(!contract.direct_wallet_snapshot_mutation_allowed);
}

fn assert_runtime_acceptance_contract(contract: &RuntimeAcceptanceContract) {
    assert_eq!(
        contract.runtime_artifact_schema,
        "subscription_package_lifecycle_runtime.v1"
    );
    assert_eq!(
        contract.runtime_artifact_path,
        ".tmp/credit-wallet/subscription_package_lifecycle_runtime.json"
    );
    assert!(contract.contract_artifact_must_not_mark_runtime_verified);
    assert!(contract.runtime_implemented_required);
    assert!(!contract.contract_only_required);
    assert!(contract.route_or_internal_runtime_invocation_required);
    assert!(contract.plan_package_crud_readback_required);
    assert!(contract.subscription_lifecycle_readback_required);
    assert!(contract.subscription_state_transitions_readback_required);
    assert!(contract.trial_proration_dunning_readback_required);
    assert!(contract.credit_grant_or_ledger_effect_readback_required);
    assert!(contract.invoice_order_linkage_readback_required);
    assert!(contract.idempotency_replay_readback_required);
    assert!(contract.conflict_no_duplicate_write_readback_required);
    assert!(contract.refusal_no_write_readback_required);
    assert!(contract.audit_readback_required);
    assert!(contract.money_decimal_strings_required);
    assert!(contract.secret_safe_required);
    assert!(!contract.paid_gate_changed_required);
    assert!(contract.direct_wallet_snapshot_mutation_forbidden);
    assert!(!contract.raw_provider_payload_output_allowed);
    assert!(!contract.raw_plan_payload_output_allowed);
    assert!(!contract.token_output_allowed);
    assert!(!contract.voucher_or_code_output_allowed);
}

fn assert_expected_payment_reconciliation(contract: &ExpectedPaymentReconciliation) {
    assert_eq!(
        contract.schema,
        "admin_subscription_scheduler_expected_payment_reconciliation.v1"
    );
    assert_eq!(
        contract.source_handoff_schema,
        "admin_subscription_scheduler_provider_capture_reconciliation_plan.v1"
    );
    assert_eq!(
        contract.candidate_schema,
        "payment_provider_stripe_like_response_object_reconciliation.v1"
    );
    assert_eq!(
        contract.candidate_source,
        "/admin/billing/payment-provider/executor.data.stripe_like_response_object_reconciliation"
    );
    assert!(contract.candidate_required_before_subscription_capture_apply);
    assert!(!contract.payment_logic_reimplemented_by_subscription);
    for expected in ["payment_intent", "charge"] {
        assert!(
            contract
                .expected_provider_object_types
                .contains(&expected.to_string())
        );
    }
    assert!(
        contract
            .expected_provider_statuses
            .contains(&"succeeded".to_string())
    );
    assert!(
        contract
            .expected_local_refs
            .contains(&"payment_intent_id".to_string())
    );
    assert_eq!(
        contract.status_mapping.matched,
        "provider_capture_reconciliation_matched_waiting_executor_apply"
    );
    assert_eq!(
        contract.status_mapping.mismatch,
        "blocked_review_payment_reconciliation_mismatch"
    );
    assert_eq!(
        contract.status_mapping.blocked,
        "provider_source_ready_waiting_fetch"
    );
    assert_eq!(
        contract.safe_next_action_mapping.matched,
        "accept_reconciliation_candidate_then_apply_or_replay_local_action_in_payment_executor"
    );
    assert_eq!(
        contract.safe_next_action_mapping.mismatch,
        "do_not_apply_local_action_review_mismatch_reasons"
    );
    assert_eq!(
        contract.safe_next_action_mapping.blocked_retryable,
        "retry_provider_object_fetch_after_backoff_without_local_write"
    );
    assert_eq!(
        contract.safe_next_action_mapping.blocked_missing_summary,
        "load_provider_object_summary_before_local_write"
    );
    assert!(!contract.scheduler_handoff_network_call_enabled);
    assert!(!contract.scheduler_handoff_network_call_performed);
    assert_eq!(
        contract.scheduler_handoff_writes.payment_captures,
        "not_written_by_subscription_handoff"
    );
    assert_eq!(
        contract.scheduler_handoff_writes.ledger_entries,
        "not_written_by_subscription_handoff"
    );
    assert_eq!(
        contract.scheduler_handoff_writes.credit_grants,
        "not_written_by_subscription_handoff"
    );
    assert!(!contract.raw_provider_payload_output_allowed);
    assert!(!contract.authorization_output_allowed);
    assert!(!contract.provider_secret_output_allowed);
    assert!(contract.secret_safe);
}

fn assert_execution_plan_contract(contract: &ExecutionPlanContract) {
    assert_eq!(
        contract.schema,
        "admin_subscription_scheduler_execution_plan_readback.v1"
    );
    assert!(!contract.runtime_daemon_running);
    assert!(contract.local_business_logic_implemented);
    assert!(!contract.real_payment_capture_enabled);
    for event_type in ["renew", "payment_failed", "dunning", "expire", "prorate"] {
        assert!(
            contract.event_types.contains(&event_type.to_string()),
            "missing event_type {event_type}"
        );
    }
    for mode in ["dry_run", "apply", "refuse", "replay"] {
        assert!(
            contract.execute_modes.contains(&mode.to_string()),
            "missing execute mode {mode}"
        );
    }
    for required in [
        "payment_capture_handoff",
        "dunning_state",
        "proration_state",
        "local_write_policy",
        "idempotency",
        "refusal",
    ] {
        assert!(
            contract.required_readbacks.contains(&required.to_string()),
            "missing readback {required}"
        );
    }
    for path in [
        "dry_run",
        "terminal_idempotent_replay",
        "refusal_accounting_no_write",
    ] {
        assert!(
            contract.no_write_paths.contains(&path.to_string()),
            "missing no-write path {path}"
        );
    }
    for term in &contract.forbidden_output_terms {
        assert!(
            !term.trim().is_empty(),
            "forbidden output term must not be blank"
        );
    }
}

fn assert_runtime_feasibility_plan(plan: &RuntimeFeasibilityPlan) {
    assert_eq!(
        plan.status,
        "feasible_with_new_schema_and_control_plane_runtime"
    );
    assert!(!plan.runtime_implemented);
    assert!(plan.contract_only);
    assert!(!plan.paid_gate_changed);
    assert!(!plan.gateway_change_required);
    assert!(plan.control_plane_runtime_required);
    assert!(plan.new_schema_required);

    let reusable = plan
        .reusable_primitives
        .iter()
        .map(|item| item.primitive.as_str())
        .collect::<Vec<_>>();
    for primitive in [
        "credit_grants",
        "ledger_entries_admin_adjustment",
        "audit_logs",
        "admin_credit_grant_crud_runtime",
        "opening_balance_import_idempotent_transaction_pattern",
        "remaining_balance_read_model",
    ] {
        assert!(
            reusable.contains(&primitive),
            "missing reusable primitive {primitive}"
        );
    }
    for primitive in &plan.reusable_primitives {
        assert_eq!(primitive.status.as_deref(), Some("available"));
        assert!(
            primitive
                .usage
                .as_deref()
                .is_some_and(|usage| !usage.trim().is_empty()),
            "{} must describe usage",
            primitive.primitive
        );
    }

    let missing = plan
        .missing_primitives
        .iter()
        .map(|item| item.primitive.as_str())
        .collect::<Vec<_>>();
    for primitive in [
        "subscription_plans_and_packages_schema",
        "subscriptions_schema",
        "subscription_events_or_schedules_schema",
        "invoice_order_linkage_schema_or_runtime_reference",
        "payment_provider_callback_or_scheduler_hook",
    ] {
        assert!(
            missing.contains(&primitive),
            "missing required runtime gap {primitive}"
        );
    }
    for primitive in &plan.missing_primitives {
        assert_eq!(primitive.required, Some(true));
        assert!(
            primitive
                .reason
                .as_deref()
                .is_some_and(|reason| !reason.trim().is_empty()),
            "{} must describe reason",
            primitive.primitive
        );
    }

    assert_eq!(plan.proposed_slices.len(), 5);
    assert!(
        plan.proposed_slices
            .iter()
            .any(|slice| slice.requires_migration),
        "at least one slice must own schema migration"
    );
    assert!(
        plan.proposed_slices
            .iter()
            .any(|slice| slice.runtime_acceptance),
        "one slice must own runtime acceptance artifact"
    );
    for slice in &plan.proposed_slices {
        assert!(slice.slice.starts_with("TODO-32K-S"));
        assert!(!slice.owner.trim().is_empty());
        assert!(!slice.scope.trim().is_empty());
    }
}

fn assert_schema_contract(contract: &SchemaContract) {
    assert_eq!(
        contract.schema_contract_version,
        "subscription_package_lifecycle_schema_contract.v1"
    );
    assert!(!contract.runtime_implemented);
    assert!(contract.contract_only);
    assert!(!contract.paid_gate_changed);
    assert!(contract.migration_required);
    assert_eq!(
        contract.draft_migration_path,
        "db/migrations/TODO-32K_subscription_package_lifecycle.sql"
    );

    let table_names = contract
        .tables
        .iter()
        .map(|table| table.name.as_str())
        .collect::<Vec<_>>();
    for table in [
        "subscription_plans",
        "subscription_packages",
        "subscriptions",
        "subscription_events_or_schedules",
    ] {
        assert!(table_names.contains(&table), "missing table {table}");
    }

    assert_schema_table(
        contract,
        "subscription_plans",
        &[
            "id",
            "tenant_id",
            "plan_code",
            "status",
            "currency",
            "billing_interval",
            "unit_price",
            "included_credit_amount",
            "metadata",
        ],
        &["unit_price", "included_credit_amount"],
        "unique(tenant_id, plan_code)",
    );
    assert_schema_table(
        contract,
        "subscription_packages",
        &[
            "id",
            "tenant_id",
            "plan_id",
            "package_code",
            "status",
            "metadata",
        ],
        &[],
        "unique(tenant_id, package_code)",
    );
    assert_schema_table(
        contract,
        "subscriptions",
        &[
            "id",
            "tenant_id",
            "project_id",
            "wallet_id",
            "plan_id",
            "package_id",
            "status",
            "currency",
            "current_period_start",
            "current_period_end",
            "idempotency_fingerprint",
            "latest_credit_grant_id",
            "latest_ledger_entry_id",
            "latest_invoice_id",
            "latest_order_id",
            "metadata",
        ],
        &[],
        "unique(tenant_id, idempotency_fingerprint)",
    );
    assert_schema_table(
        contract,
        "subscription_events_or_schedules",
        &[
            "id",
            "tenant_id",
            "subscription_id",
            "event_type",
            "event_status",
            "effective_at",
            "idempotency_fingerprint",
            "credit_grant_id",
            "ledger_entry_id",
            "invoice_id",
            "order_id",
            "audit_id",
            "refusal_code",
            "request_summary",
            "metadata",
        ],
        &[],
        "unique(tenant_id, idempotency_fingerprint)",
    );

    for relationship in [
        "subscription credit issuance links to credit_grants.id or ledger_entries.id",
        "renewal and activation link to bounded invoice_id and order_id references",
        "refusal events write no credit_grants, ledger_entries, invoice, or order rows",
        "wallet balance snapshot is never directly mutated as accounting truth",
    ] {
        assert!(
            contract
                .required_relationships
                .contains(&relationship.to_string()),
            "missing relationship {relationship}"
        );
    }
    for invariant in [
        "idempotency_fingerprint is stored hashed or otherwise non-raw",
        "same idempotency key and same body replays original subscription/event ids",
        "same idempotency key and different body refuses without new writes",
        "amount and price fields use fixed decimal strings and SQL numeric scale 8",
        "metadata and request_summary omit raw provider payloads, tokens, DB URLs, voucher codes, and secrets",
    ] {
        assert!(
            contract.invariants.contains(&invariant.to_string()),
            "missing invariant {invariant}"
        );
    }
}

fn assert_schema_table(
    contract: &SchemaContract,
    name: &str,
    required_columns: &[&str],
    money_columns: &[&str],
    unique_constraint: &str,
) {
    let table = contract
        .tables
        .iter()
        .find(|table| table.name == name)
        .unwrap_or_else(|| panic!("missing table {name}"));
    assert!(table.required, "{name} must be required");
    assert!(!table.purpose.trim().is_empty(), "{name} purpose");
    for column in required_columns {
        assert!(
            table.required_columns.contains(&column.to_string()),
            "{name} missing column {column}"
        );
    }
    for column in money_columns {
        assert!(
            table.money_decimal_columns.contains(&column.to_string()),
            "{name} missing money column {column}"
        );
    }
    assert!(
        table
            .unique_constraints
            .contains(&unique_constraint.to_string()),
        "{name} missing unique constraint"
    );
    assert!(!table.foreign_keys.is_empty(), "{name} needs foreign keys");
    assert!(
        table
            .secret_safe_columns
            .iter()
            .any(|column| column == "metadata"),
        "{name} must mark metadata secret-safe"
    );
}

fn assert_case_shape(case: &ContractCase, fixture: &SubscriptionPackageLifecycleContract) {
    assert!(!case.name.trim().is_empty());
    assert!(!case.operation.trim().is_empty());
    assert!(
        fixture.plan_states.contains(&case.decision)
            || fixture.subscription_states.contains(&case.decision)
            || matches!(case.decision.as_str(), "refused" | "replayed"),
        "{} unsupported decision {}",
        case.name,
        case.decision
    );
    assert_eq!(
        case.response.get("secret_safe").and_then(Value::as_bool),
        Some(true),
        "{} response must be secret_safe",
        case.name
    );
}

fn assert_money_fields(case: &ContractCase, scale: usize) {
    visit_money_strings(&case.request, scale, &case.name);
    visit_money_strings(&case.response, scale, &case.name);
    visit_money_strings(&case.reconciliation, scale, &case.name);
    for container in [&case.request, &case.response, &case.reconciliation] {
        if let Some(currency) = container.get("currency").and_then(Value::as_str) {
            assert_eq!(currency.len(), 3, "{} currency length", case.name);
            assert!(
                currency.chars().all(|ch| ch.is_ascii_uppercase()),
                "{} currency must be uppercase ASCII",
                case.name
            );
        }
    }
}

fn visit_money_strings(value: &Value, scale: usize, label: &str) {
    match value {
        Value::Object(map) => {
            for (key, item) in map {
                if key.contains("amount") || key.contains("price") || key.contains("total") {
                    assert_decimal_string(item, scale, label, key);
                }
                visit_money_strings(item, scale, label);
            }
        }
        Value::Array(items) => {
            for item in items {
                visit_money_strings(item, scale, label);
            }
        }
        _ => {}
    }
}

fn assert_decimal_string(value: &Value, scale: usize, label: &str, field: &str) {
    let text = value
        .as_str()
        .unwrap_or_else(|| panic!("{label}.{field} must be a string, not number"));
    let signless = text.strip_prefix('-').unwrap_or(text);
    let (whole, fractional) = signless
        .split_once('.')
        .unwrap_or_else(|| panic!("{label}.{field} must contain decimal point"));
    assert!(
        !whole.is_empty() && whole.chars().all(|ch| ch.is_ascii_digit()),
        "{label}.{field} invalid whole decimal part"
    );
    assert_eq!(fractional.len(), scale, "{label}.{field} scale");
    assert!(fractional.chars().all(|ch| ch.is_ascii_digit()));
}

fn assert_secret_safe(case: &ContractCase, forbidden_terms: &[String]) {
    let serialized = serde_json::to_string(case).expect("case serializes");
    let normalized = serialized.to_ascii_lowercase();
    for term in forbidden_terms {
        assert!(
            !normalized.contains(&term.to_ascii_lowercase()),
            "{} contains forbidden output term `{term}`",
            case.name
        );
    }
}

fn assert_accounting_markers(case: &ContractCase, contract: &AccountingContract) {
    for marker in &case.accounting_markers {
        assert!(
            contract.allowed_markers.contains(marker),
            "{} unsupported accounting marker `{marker}`",
            case.name
        );
    }
    if matches!(case.decision.as_str(), "active" | "renewed" | "trialing")
        && case
            .accounting_markers
            .iter()
            .any(|marker| marker == "reconciliation_marker")
    {
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "credit_grant_row" || marker == "admin_adjustment_entry"),
            "{} subscription credit must write grant or ledger/admin adjustment marker",
            case.name
        );
    }
    if case.decision == "refused" {
        assert_eq!(
            case.subscription_write_allowed,
            Some(false),
            "{} subscription write",
            case.name
        );
        assert_eq!(
            case.ledger_write_allowed,
            Some(false),
            "{} ledger write",
            case.name
        );
        assert_eq!(
            case.credit_grant_write_allowed,
            Some(false),
            "{} grant write",
            case.name
        );
        assert_eq!(
            case.invoice_write_allowed,
            Some(false),
            "{} invoice write",
            case.name
        );
    }
}

fn assert_credit_effect_cases(cases: &[ContractCase]) {
    for name in [
        "subscription_created_trial",
        "subscription_active_credit_issued",
        "subscription_renewed",
        "subscription_proration_applied",
    ] {
        let case = cases.iter().find(|case| case.name == name).unwrap();
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "credit_grant_row")
        );
        assert_eq!(
            case.reconciliation.get("matched").and_then(Value::as_bool),
            Some(true)
        );
    }
}

fn assert_invoice_order_linkage(cases: &[ContractCase]) {
    for name in [
        "trial_end_activates_subscription",
        "subscription_active_credit_issued",
        "subscription_renewed",
    ] {
        let case = cases.iter().find(|case| case.name == name).unwrap();
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "invoice_link")
        );
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "order_link")
        );
    }
}

fn assert_replay_case(cases: &[ContractCase]) {
    let case = cases
        .iter()
        .find(|case| case.name == "subscription_create_idempotent_replay")
        .expect("subscription replay case");
    assert!(case.same_idempotency_key);
    assert!(case.same_body);
    assert_eq!(case.idempotency, "replayed");
    assert_eq!(case.new_subscription_row_written, Some(false));
    assert_eq!(case.new_credit_grant_row_written, Some(false));
    assert_eq!(case.new_ledger_entry_written, Some(false));
    assert_eq!(case.new_invoice_row_written, Some(false));
}

fn assert_cancel_termination_reversal(cases: &[ContractCase]) {
    for name in ["subscription_cancelled", "subscription_terminated"] {
        let case = cases.iter().find(|case| case.name == name).unwrap();
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "credit_grant_revoke_row")
        );
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "ledger_reversal_entry")
        );
    }
}

fn assert_refusal_cases(cases: &[ContractCase]) {
    for (name, code) in [
        (
            "subscription_create_same_key_conflict_refused",
            "subscription_idempotency_conflict",
        ),
        (
            "ownership_mismatch_refused",
            "subscription_ownership_mismatch",
        ),
        (
            "currency_mismatch_refused",
            "subscription_currency_mismatch",
        ),
        (
            "non_positive_price_refused",
            "non_positive_subscription_price",
        ),
        ("invalid_plan_refused", "invalid_or_archived_plan"),
    ] {
        let case = cases.iter().find(|case| case.name == name).unwrap();
        assert_eq!(case.decision, "refused");
        assert_eq!(case.refusal_code, code);
        assert_eq!(
            case.response.get("refusal_code").and_then(Value::as_str),
            Some(code)
        );
    }
}
