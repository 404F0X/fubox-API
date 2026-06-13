use ai_gateway_billing_ledger::{
    AdminAdjustmentLedgerRequest, DEFAULT_MONEY_SCALE, FixedDecimal, LedgerAdminAdjustmentKind,
    LedgerContractError, LedgerEntryRecord, LedgerEntryStatus, LedgerEntryType,
    LedgerOperationKind, LedgerOperationOutcome, admin_adjustment_ledger_idempotency_key,
    plan_ledger_admin_adjustment,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

const FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/opening_balance_import_contract.json");

#[derive(Debug, Deserialize)]
struct OpeningBalanceImportContract {
    schema: String,
    status: String,
    runtime_writer_changed: bool,
    paid_gate_changed: bool,
    endpoint: EndpointContract,
    writer_mapping: WriterMapping,
    runtime_schema_contract: RuntimeSchemaContract,
    runtime_acceptance_contract: RuntimeAcceptanceContract,
    money_contract: MoneyContract,
    secret_safe_forbidden_terms: Vec<String>,
    cases: Vec<OpeningImportCase>,
}

#[derive(Debug, Deserialize)]
struct EndpointContract {
    method: String,
    path: String,
    owner: String,
}

#[derive(Debug, Deserialize)]
struct WriterMapping {
    primitive: String,
    adjustment_kind: String,
    ledger_entry_type: String,
    ledger_entry_status: String,
    opening_marker: String,
    command_metadata_contract: CommandMetadataContract,
    direct_wallet_snapshot_mutation_allowed: bool,
    contract_runtime_wiring: String,
}

#[derive(Debug, Deserialize)]
struct CommandMetadataContract {
    metadata_operation: String,
    required_metadata_fields: Vec<String>,
    raw_idempotency_key_output_allowed: bool,
    raw_import_payload_output_allowed: bool,
}

#[derive(Debug, Deserialize)]
struct RuntimeSchemaContract {
    requires_schema: bool,
    runtime_implemented: bool,
    table: String,
    required_columns: Vec<String>,
    required_unique_constraints: Vec<String>,
    required_statuses: Vec<String>,
    required_replay_fields: Vec<String>,
    required_conflict_guards: Vec<String>,
    schema_contract_compatible: bool,
    e11_schema_landed: bool,
}

#[derive(Debug, Deserialize)]
struct RuntimeAcceptanceContract {
    route_or_internal_runtime_invoked_required: bool,
    psql_plan_not_runtime_acceptance: bool,
    rollback_contained_psql_plan_allowed_as_blocked_evidence: bool,
    runtime_implemented_requires_live_readback: bool,
    no_direct_wallet_mutation_required: bool,
    required_live_readback_fields: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct MoneyContract {
    format: String,
    scale: u32,
    float_allowed: bool,
}

#[derive(Debug, Deserialize)]
struct OpeningImportCase {
    name: String,
    scenario: String,
    request: OpeningImportRequest,
    existing_ledger_entry: Option<ExistingLedgerEntry>,
    attempted_accounting_marker: Option<String>,
    expected: ExpectedOutcome,
}

#[derive(Debug, Deserialize)]
struct OpeningImportRequest {
    idempotency_key: String,
    tenant_id: String,
    wallet_id: String,
    wallet_currency: String,
    currency: String,
    opening_amount: Value,
    external_source: String,
    external_reference_id: String,
    adjustment_operation_id: String,
    reason: String,
    actor_id: String,
    actor_type: String,
}

#[derive(Debug, Deserialize)]
struct ExistingLedgerEntry {
    ledger_entry_id: String,
    amount: String,
    currency: String,
    status: String,
}

#[derive(Debug, Deserialize)]
struct ExpectedOutcome {
    decision: String,
    writer_invoked: bool,
    idempotency: String,
    accounting_markers: Vec<String>,
    refusal_code: Option<String>,
    writer_request: Option<ExpectedWriterRequest>,
    response: Value,
    audit_summary: Value,
}

#[derive(Debug, Deserialize)]
struct ExpectedWriterRequest {
    primitive: String,
    adjustment_operation_id: String,
    amount: String,
    currency: String,
    adjustment_kind: String,
    metadata: ExpectedWriterMetadata,
}

#[derive(Debug, Deserialize, Serialize)]
struct ExpectedWriterMetadata {
    operation: String,
    external_source: String,
    external_reference_id: String,
    reason: String,
}

#[test]
fn opening_balance_import_contract_fixture_maps_to_admin_adjustment_credit() {
    let fixture: OpeningBalanceImportContract =
        serde_json::from_str(FIXTURE).expect("opening balance import fixture should parse");

    assert_eq!(fixture.schema, "billing_opening_balance_import_contract.v1");
    assert_eq!(fixture.status, "contract_enforced_not_runtime_wired");
    assert!(!fixture.runtime_writer_changed);
    assert!(!fixture.paid_gate_changed);
    assert_eq!(fixture.endpoint.method, "POST");
    assert_eq!(fixture.endpoint.path, "/billing/opening-balance-imports");
    assert!(fixture.endpoint.owner.contains("E9 Billing Ledger"));

    assert_eq!(
        fixture.writer_mapping.primitive,
        "AdminAdjustmentLedgerRequest"
    );
    assert_eq!(fixture.writer_mapping.adjustment_kind, "credit");
    assert_eq!(fixture.writer_mapping.ledger_entry_type, "adjust");
    assert_eq!(fixture.writer_mapping.ledger_entry_status, "confirmed");
    assert_eq!(fixture.writer_mapping.opening_marker, "opening_entry");
    assert_command_metadata_contract(&fixture.writer_mapping.command_metadata_contract);
    assert!(
        !fixture
            .writer_mapping
            .direct_wallet_snapshot_mutation_allowed
    );
    assert_eq!(
        fixture.writer_mapping.contract_runtime_wiring,
        "not_runtime_wired"
    );
    assert_runtime_schema_contract(&fixture.runtime_schema_contract);
    assert_runtime_acceptance_contract(&fixture.runtime_acceptance_contract);

    assert_eq!(
        fixture.money_contract.format,
        "decimal_string_with_currency"
    );
    assert_eq!(fixture.money_contract.scale, DEFAULT_MONEY_SCALE);
    assert!(!fixture.money_contract.float_allowed);

    let case_names = fixture
        .cases
        .iter()
        .map(|case| case.name.as_str())
        .collect::<Vec<_>>();
    for required in [
        "accepted_apply",
        "idempotent_replay",
        "same_key_conflict",
        "duplicate_external_reference_conflict",
        "wallet_currency_mismatch",
        "non_positive_amount_refusal",
        "direct_wallet_snapshot_mutation_forbidden",
    ] {
        assert!(case_names.contains(&required), "missing case `{required}`");
    }

    for case in &fixture.cases {
        assert_case_shape(case, fixture.money_contract.scale);
        assert_secret_safe(case, &fixture.secret_safe_forbidden_terms);
        assert_no_float_money_shape(&case.request.opening_amount, &case.name);
        assert_request_contract(case);

        if case.expected.writer_invoked {
            assert_writer_mapping(case);
        } else {
            assert!(
                case.expected.writer_request.is_none(),
                "{} refused before writer mapping should not carry writer request",
                case.name
            );
        }
    }
}

fn assert_runtime_acceptance_contract(contract: &RuntimeAcceptanceContract) {
    assert!(contract.route_or_internal_runtime_invoked_required);
    assert!(contract.psql_plan_not_runtime_acceptance);
    assert!(contract.rollback_contained_psql_plan_allowed_as_blocked_evidence);
    assert!(contract.runtime_implemented_requires_live_readback);
    assert!(contract.no_direct_wallet_mutation_required);

    for field in [
        "opening_import_id",
        "ledger_entry_id",
        "admin_adjustment_entry_id",
        "audit_id",
        "idempotency_result",
        "metadata_operation",
        "wallet_snapshot_mutated",
        "opening_import_readback_passed",
        "ledger_or_admin_adjustment_readback_passed",
        "audit_readback_passed",
        "replay_readback_passed",
        "refusal_readback_passed",
        "rollback_readback_passed",
    ] {
        assert!(
            contract
                .required_live_readback_fields
                .iter()
                .any(|item| item == field),
            "runtime acceptance contract missing live readback field `{field}`"
        );
    }
}

fn assert_command_metadata_contract(contract: &CommandMetadataContract) {
    assert_eq!(contract.metadata_operation, "opening_balance_import");
    for field in [
        "operation",
        "external_source",
        "external_reference_id",
        "reason",
    ] {
        assert!(
            contract
                .required_metadata_fields
                .iter()
                .any(|item| item == field),
            "command metadata contract missing `{field}`"
        );
    }
    assert!(!contract.raw_idempotency_key_output_allowed);
    assert!(!contract.raw_import_payload_output_allowed);
}

fn assert_runtime_schema_contract(contract: &RuntimeSchemaContract) {
    assert!(contract.requires_schema);
    assert!(!contract.runtime_implemented);
    assert_eq!(contract.table, "opening_balance_imports");
    assert!(contract.schema_contract_compatible);
    assert!(contract.e11_schema_landed);

    for column in [
        "id",
        "tenant_id",
        "wallet_id",
        "currency",
        "opening_amount",
        "external_source",
        "external_reference_id",
        "idempotency_key",
        "status",
        "ledger_entry_id",
        "admin_adjustment_entry_id",
        "audit_id",
        "request_summary",
    ] {
        assert!(
            contract.required_columns.iter().any(|item| item == column),
            "schema contract missing column `{column}`"
        );
    }
    for constraint in [
        "(tenant_id,idempotency_key)",
        "(tenant_id,external_source,external_reference_id)",
    ] {
        assert!(
            contract
                .required_unique_constraints
                .iter()
                .any(|item| item == constraint),
            "schema contract missing unique constraint `{constraint}`"
        );
    }
    for status in ["imported", "replayed", "refused"] {
        assert!(
            contract.required_statuses.iter().any(|item| item == status),
            "schema contract missing status `{status}`"
        );
    }
    for field in [
        "opening_import_id",
        "ledger_entry_id",
        "admin_adjustment_entry_id",
        "audit_id",
        "request_summary",
    ] {
        assert!(
            contract
                .required_replay_fields
                .iter()
                .any(|item| item == field),
            "schema contract missing replay field `{field}`"
        );
    }
    for guard in [
        "idempotency_replay_same_body",
        "idempotency_conflict_same_key_different_body",
        "external_reference_conflict_different_key",
        "wallet_currency_mismatch_refusal",
    ] {
        assert!(
            contract
                .required_conflict_guards
                .iter()
                .any(|item| item == guard),
            "schema contract missing conflict guard `{guard}`"
        );
    }
}

fn assert_case_shape(case: &OpeningImportCase, scale: u32) {
    assert!(!case.name.trim().is_empty(), "case name is required");
    assert!(
        !case.scenario.trim().is_empty(),
        "{} scenario is required",
        case.name
    );
    assert_uuid(&case.request.tenant_id, &case.name, "tenant_id");
    assert_uuid(&case.request.wallet_id, &case.name, "wallet_id");
    assert_uuid(
        &case.request.adjustment_operation_id,
        &case.name,
        "adjustment_operation_id",
    );
    assert_eq!(case.request.currency.len(), 3, "{} currency", case.name);
    assert!(
        case.request
            .currency
            .chars()
            .all(|ch| ch.is_ascii_uppercase()),
        "{} currency must be uppercase",
        case.name
    );
    assert_decimal_string(&case.request.opening_amount, scale, &case.name);
    assert!(
        !case.request.idempotency_key.trim().is_empty(),
        "{} idempotency key required on request",
        case.name
    );
    assert!(
        !case.request.external_source.trim().is_empty(),
        "{} external source required",
        case.name
    );
    assert!(
        !case.request.external_reference_id.trim().is_empty(),
        "{} external reference required",
        case.name
    );
    assert!(
        !case.request.reason.trim().is_empty(),
        "{} reason",
        case.name
    );
    assert!(
        !case.request.actor_id.trim().is_empty(),
        "{} actor_id",
        case.name
    );
    assert!(
        !case.request.actor_type.trim().is_empty(),
        "{} actor_type",
        case.name
    );
    assert_eq!(
        case.expected
            .response
            .get("secret_safe")
            .and_then(Value::as_bool),
        Some(true),
        "{} response secret_safe",
        case.name
    );
    assert_eq!(
        case.expected
            .audit_summary
            .get("secret_safe")
            .and_then(Value::as_bool),
        Some(true),
        "{} audit summary secret_safe",
        case.name
    );
}

fn assert_request_contract(case: &OpeningImportCase) {
    match case.name.as_str() {
        "accepted_apply" => {
            assert_eq!(case.expected.decision, "opening_import_applied");
            assert_eq!(case.expected.idempotency, "applied");
            assert_opening_markers(case);
        }
        "idempotent_replay" => {
            assert_eq!(case.expected.decision, "opening_import_replayed");
            assert_eq!(case.expected.idempotency, "replayed");
            assert_opening_markers(case);
        }
        "same_key_conflict" => {
            assert_eq!(case.expected.decision, "idempotency_conflict");
            assert_eq!(
                case.expected.refusal_code.as_deref(),
                Some("idempotency_conflict")
            );
        }
        "duplicate_external_reference_conflict" => {
            assert_eq!(
                case.expected.refusal_code.as_deref(),
                Some("external_reference_conflict")
            );
            assert!(!case.expected.writer_invoked);
        }
        "wallet_currency_mismatch" => {
            assert_ne!(case.request.wallet_currency, case.request.currency);
            assert_eq!(
                case.expected.refusal_code.as_deref(),
                Some("wallet_currency_mismatch")
            );
            assert!(!case.expected.writer_invoked);
        }
        "non_positive_amount_refusal" => {
            let amount = money(
                case.request
                    .opening_amount
                    .as_str()
                    .expect("opening amount string"),
            );
            assert!(
                amount.units() <= 0,
                "{} should fixture a non-positive amount",
                case.name
            );
            assert_eq!(
                case.expected.refusal_code.as_deref(),
                Some("non_positive_opening_amount")
            );
            assert!(!case.expected.writer_invoked);
        }
        "direct_wallet_snapshot_mutation_forbidden" => {
            assert_eq!(
                case.attempted_accounting_marker.as_deref(),
                Some("direct_wallet_snapshot_update")
            );
            assert_eq!(
                case.expected.refusal_code.as_deref(),
                Some("direct_wallet_snapshot_mutation_forbidden")
            );
            assert!(!case.expected.writer_invoked);
        }
        other => panic!("unexpected fixture case `{other}`"),
    }
}

fn assert_writer_mapping(case: &OpeningImportCase) {
    let expected = case
        .expected
        .writer_request
        .as_ref()
        .expect("writer-invoked case must include expected writer request");
    assert_eq!(expected.primitive, "AdminAdjustmentLedgerRequest");
    assert_eq!(expected.adjustment_kind, "credit");
    assert_eq!(
        expected.amount,
        case.request.opening_amount.as_str().unwrap()
    );
    assert_eq!(expected.currency, case.request.currency);
    assert_eq!(
        expected.adjustment_operation_id,
        case.request.adjustment_operation_id
    );
    assert_eq!(expected.metadata.operation, "opening_balance_import");
    assert_eq!(
        expected.metadata.external_source,
        case.request.external_source
    );
    assert_eq!(
        expected.metadata.external_reference_id,
        case.request.external_reference_id
    );
    assert_eq!(expected.metadata.reason, case.request.reason);
    let serialized_metadata =
        serde_json::to_string(&expected.metadata).expect("writer metadata should serialize");
    assert!(!serialized_metadata.contains("idempotency_key"));
    assert!(!serialized_metadata.contains("opening_import:"));
    assert!(!serialized_metadata.contains("raw_import_payload"));
    assert!(!serialized_metadata.contains("authorization"));
    assert!(!serialized_metadata.contains("provider_key"));
    assert!(!serialized_metadata.contains("virtual_key"));
    assert!(serialized_metadata.contains("opening_balance_import"));

    let operation_id = uuid(&case.request.adjustment_operation_id);
    let request = AdminAdjustmentLedgerRequest {
        adjustment_operation_id: operation_id,
        request_id: None,
        related_ledger_entry_id: None,
        amount: money(&expected.amount),
        currency: expected.currency.clone(),
    };
    let existing_entries = case
        .existing_ledger_entry
        .as_ref()
        .map(|existing| vec![existing_adjust_record(operation_id, existing)])
        .unwrap_or_default();
    let plan = plan_ledger_admin_adjustment(request, &existing_entries);

    match case.name.as_str() {
        "accepted_apply" => {
            let plan = plan.expect("accepted opening import should plan");
            assert_eq!(plan.operation, LedgerOperationKind::AdminAdjustment);
            assert_eq!(
                plan.idempotency_key,
                admin_adjustment_ledger_idempotency_key(operation_id)
            );
            assert_eq!(plan.outcome, LedgerOperationOutcome::Apply);
            assert_eq!(plan.entries.len(), 1);
            let entry = &plan.entries[0];
            assert_eq!(entry.entry_type, LedgerEntryType::Adjust);
            assert_eq!(entry.status, LedgerEntryStatus::Confirmed);
            assert_eq!(entry.amount.to_string(), expected.amount);
            assert_eq!(entry.currency, expected.currency);
            assert_eq!(entry.request_id, None);
            assert_eq!(entry.related_ledger_entry_id, None);
            assert_eq!(
                entry.metadata.operation,
                LedgerOperationKind::AdminAdjustment
            );
            assert_eq!(
                entry.metadata.admin_adjustment_kind,
                Some(LedgerAdminAdjustmentKind::Credit)
            );
            assert_writer_output_secret_safe(&plan);
        }
        "idempotent_replay" => {
            let existing = case
                .existing_ledger_entry
                .as_ref()
                .expect("replay case includes existing entry");
            let plan = plan.expect("same opening import should replay");
            assert_eq!(
                plan.outcome,
                LedgerOperationOutcome::Idempotent {
                    existing_entry_id: uuid(&existing.ledger_entry_id)
                }
            );
            assert!(plan.entries.is_empty());
        }
        "same_key_conflict" => {
            let err = plan.expect_err("same operation id with different amount should conflict");
            assert!(matches!(
                err,
                LedgerContractError::IdempotencyConflict { .. }
            ));
        }
        other => panic!("{other} should not invoke writer in this contract"),
    }
}

fn assert_opening_markers(case: &OpeningImportCase) {
    for marker in ["opening_entry", "admin_adjustment_entry", "ledger_entry"] {
        assert!(
            case.expected
                .accounting_markers
                .iter()
                .any(|item| item == marker),
            "{} missing marker `{marker}`",
            case.name
        );
    }
}

fn existing_adjust_record(operation_id: Uuid, existing: &ExistingLedgerEntry) -> LedgerEntryRecord {
    let status = match existing.status.as_str() {
        "confirmed" => LedgerEntryStatus::Confirmed,
        other => panic!("unsupported existing ledger status `{other}`"),
    };
    LedgerEntryRecord {
        id: uuid(&existing.ledger_entry_id),
        request_id: None,
        related_ledger_entry_id: None,
        entry_type: LedgerEntryType::Adjust,
        amount: money(&existing.amount),
        currency: existing.currency.clone(),
        status,
        idempotency_key: admin_adjustment_ledger_idempotency_key(operation_id),
    }
}

fn assert_writer_output_secret_safe<T: Serialize>(value: &T) {
    let serialized = serde_json::to_string(value).expect("value should serialize");
    for forbidden in [
        "opening_import:new_api_balance",
        "idempotency_key",
        "raw_import_payload",
        "authorization",
        "bearer",
        "provider_key",
        "virtual_key",
        "database_url",
        "postgres://",
    ] {
        assert!(
            !serialized.to_ascii_lowercase().contains(forbidden),
            "writer output contained forbidden marker `{forbidden}`"
        );
    }
}

fn assert_secret_safe(case: &OpeningImportCase, forbidden_terms: &[String]) {
    let response = serde_json::to_string(&case.expected.response).expect("response serializes");
    let audit = serde_json::to_string(&case.expected.audit_summary).expect("audit serializes");
    let lower_response = response.to_ascii_lowercase();
    let lower_audit = audit.to_ascii_lowercase();
    for term in forbidden_terms {
        let lower_term = term.to_ascii_lowercase();
        assert!(
            !lower_response.contains(&lower_term),
            "{} response contains forbidden term `{term}`",
            case.name
        );
        assert!(
            !lower_audit.contains(&lower_term),
            "{} audit contains forbidden term `{term}`",
            case.name
        );
    }
}

fn assert_no_float_money_shape(value: &Value, label: &str) {
    assert!(
        value.is_string(),
        "{label} opening_amount must be decimal string, not JSON float/number"
    );
}

fn assert_decimal_string(value: &Value, scale: u32, label: &str) {
    let text = value
        .as_str()
        .unwrap_or_else(|| panic!("{label} money must be string"));
    let (whole, fractional) = text
        .split_once('.')
        .unwrap_or_else(|| panic!("{label} money must include decimal point"));
    assert!(
        !whole.is_empty()
            && whole
                .strip_prefix('-')
                .unwrap_or(whole)
                .chars()
                .all(|ch| ch.is_ascii_digit()),
        "{label} whole money part"
    );
    assert_eq!(
        fractional.len(),
        scale as usize,
        "{label} money scale should be {scale}"
    );
    assert!(
        fractional.chars().all(|ch| ch.is_ascii_digit()),
        "{label} fractional money part"
    );
}

fn assert_uuid(value: &str, label: &str, field: &str) {
    Uuid::parse_str(value).unwrap_or_else(|_| panic!("{label}.{field} must be uuid"));
}

fn uuid(value: &str) -> Uuid {
    Uuid::parse_str(value).expect("fixture uuid")
}

fn money(value: &str) -> FixedDecimal {
    FixedDecimal::parse(value, DEFAULT_MONEY_SCALE).expect("fixture money")
}
