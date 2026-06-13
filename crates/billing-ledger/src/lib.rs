mod beta_mode;
mod exact_cache;
mod ledger;
mod paid_evidence_bundle;
mod payment_demo;
mod payment_provider;
mod postgres_execution;
mod pre_authorize;
mod rating;
mod reconciliation;
mod subscription_scheduler;
mod writer_contract;

pub use beta_mode::{
    BILLING_BETA_MODE_READINESS_SCHEMA, BillingBetaModeDecision, BillingBetaModeReadinessInput,
    BillingBetaModeReadinessSummary, BillingBetaModeRequested, BillingBetaPaidEvidence,
    REQUIRED_PAID_BETA_EVIDENCE, evaluate_billing_beta_mode_readiness,
};
pub use exact_cache::{
    ExactCacheBillingError, ExactCacheBillingPlan, ExactCacheBillingRequest, ExactCacheDecision,
    ExactCacheDecisionInput, ExactCacheLedgerMetadata, ExactCachePricingRules,
    ExactCacheRatingResult, ExactCacheReadPolicy, ExactCacheStatus, ExactCacheUsageSummary,
    ExactCacheWritePolicy, decide_exact_cache_request, exact_cache_read_idempotency_key,
    exact_cache_write_idempotency_key, plan_exact_cache_billing,
};
pub use ledger::{
    AdminAdjustmentLedgerRequest, LedgerAdminAdjustmentKind, LedgerContractError, LedgerEntryDraft,
    LedgerEntryMetadata, LedgerEntryRecord, LedgerEntryStatus, LedgerEntryType,
    LedgerOperationKind, LedgerOperationOutcome, LedgerOperationPlan, LedgerRefundKind,
    LedgerStatusUpdate, LedgerStatusUpdateReason, RefundLedgerRequest, ReserveLedgerRequest,
    SettleLedgerRequest, admin_adjustment_ledger_idempotency_key, plan_ledger_admin_adjustment,
    plan_ledger_refund, plan_ledger_reserve, plan_ledger_settle, refund_ledger_idempotency_key,
    refund_partial_ledger_idempotency_key, reserve_ledger_idempotency_key,
    settle_ledger_idempotency_key,
};
pub use paid_evidence_bundle::{
    BILLING_PAID_EVIDENCE_BUNDLE_SCHEMA, BillingPaidEvidenceBundle,
    BillingPaidEvidenceBundleOverallStatus, BillingPaidEvidenceBundleValidation,
    BillingPaidEvidenceItem, BillingPaidEvidenceStatus, validate_billing_paid_evidence_bundle,
};
pub use payment_demo::{
    LOCAL_PAYMENT_DEMO_LEDGER_OPERATION, LOCAL_PAYMENT_DEMO_SCHEMA, LOCAL_PAYMENT_DEMO_SOURCE,
    LocalPaymentDemoContract, local_payment_demo_contract,
};
pub use payment_provider::{
    NetworkDisabledStripeLikeFetchExecutor, PAYMENT_PROVIDER_ADAPTER_CONFIG_SCHEMA,
    PAYMENT_PROVIDER_EXECUTOR_CONTRACT_SCHEMA, PAYMENT_PROVIDER_RUNTIME_SKELETON_SCHEMA,
    PAYMENT_PROVIDER_STRIPE_LIKE_CLIENT_HANDOFF_SCHEMA,
    PAYMENT_PROVIDER_STRIPE_LIKE_CLIENT_PLAN_SCHEMA,
    PAYMENT_PROVIDER_STRIPE_LIKE_FETCH_EXECUTOR_SCHEMA,
    PAYMENT_PROVIDER_STRIPE_LIKE_RESPONSE_OBJECT_RECONCILIATION_SCHEMA,
    PAYMENT_PROVIDER_STRIPE_LIKE_SANDBOX_ADAPTER_SCHEMA,
    PAYMENT_PROVIDER_STRIPE_LIKE_SOURCE_OF_TRUTH_SUMMARY_SCHEMA, PaymentProviderAdapterConfigInput,
    PaymentProviderAdapterConfigStatus, PaymentProviderCredentialLifecycleReadback,
    PaymentProviderEventMappingReadback, PaymentProviderEventReadback, PaymentProviderEventType,
    PaymentProviderExecutorAction, PaymentProviderExecutorGateInput,
    PaymentProviderExecutorGateReadback, PaymentProviderExecutorIdempotency,
    PaymentProviderExecutorIdempotencyReadback, PaymentProviderExecutorLedgerHandoffReadback,
    PaymentProviderExecutorProviderRefs, PaymentProviderExecutorRequest,
    PaymentProviderExecutorResult, PaymentProviderExecutorStatusMappingReadback,
    PaymentProviderHandoffRequest, PaymentProviderHeaderValue, PaymentProviderNormalizedEvent,
    PaymentProviderRefs, PaymentProviderRuntimeReadback, PaymentProviderSafeRef,
    PaymentProviderSignatureFormatSupport, PaymentProviderSignatureParseReadback,
    PaymentProviderSignatureVerificationReadback, PaymentProviderStripeApiObjectRefReadback,
    PaymentProviderStripeApiObjectRefRequirements, PaymentProviderStripeApiSourceOfTruthInput,
    PaymentProviderStripeApiSourceOfTruthReadback, ReqwestStripeLikeFetchExecutor,
    ReqwestStripeLikeFetchExecutorConfig, STRIPE_LIKE_SANDBOX_ADAPTER,
    StripeApiFetchAdapterReadback, StripeApiFetchRequest, StripeApiFetchResult,
    StripeApiObjectType, StripeLikeClientBodyFieldReadback, StripeLikeClientHandoffReadback,
    StripeLikeClientOperation, StripeLikeClientRequest, StripeLikeClientRequestPlan,
    StripeLikeClientResult, StripeLikeFetchExecutor, StripeLikeFetchExecutorRequest,
    StripeLikeFetchExecutorResult, StripeLikeHttpTimeoutReadback,
    StripeLikeProviderLocalRefReadback, StripeLikeProviderLocalRefsSummary,
    StripeLikeProviderObjectSummary, StripeLikeProviderStateReadback,
    StripeLikeRequestBuilderReadback, StripeLikeResponseHeaderSummaryInput,
    StripeLikeResponseObjectReconciliation, StripeLikeRetryPolicyReadback,
    StripeLikeSandboxAdapterInput, StripeLikeSandboxAdapterReadback,
    StripeLikeSourceObjectPresenceReadback, StripeLikeSourceOfTruthHandoffReadback,
    execute_stripe_like_fetch_executor, map_stripe_like_response_object_reconciliation,
    normalize_stripe_like_sandbox_event, payment_provider_credential_refusal_reason,
    plan_payment_provider_adapter_config_status, plan_payment_provider_executor_contract,
    plan_payment_provider_runtime_readback, plan_payment_provider_stripe_api_source_of_truth,
    plan_stripe_api_fetch_adapter_readback, plan_stripe_like_client_request,
    stripe_like_signature_format_support, summarize_stripe_like_provider_object,
    verify_stripe_like_signature_headers,
};
pub use postgres_execution::{
    CONSISTENT_LEDGER_POSTGRES_EXECUTION_SCHEMA, CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SCHEMA,
    CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SUMMARY_SCHEMA,
    CONSISTENT_LEDGER_POSTGRES_SQLX_ADAPTER_SCHEMA, ConsistentLedgerPostgresBoundaryContract,
    ConsistentLedgerPostgresDbErrorInput, ConsistentLedgerPostgresDbErrorKind,
    ConsistentLedgerPostgresExecutionPlan, ConsistentLedgerPostgresExecutorError,
    ConsistentLedgerPostgresExecutorOutcome, ConsistentLedgerPostgresExecutorResult,
    ConsistentLedgerPostgresExecutorResultSummary, ConsistentLedgerPostgresRowCountExpectation,
    ConsistentLedgerPostgresSqlxAdapterContract, ConsistentLedgerPostgresSqlxBindMarker,
    ConsistentLedgerPostgresSqlxStatementContract, ConsistentLedgerPostgresSqlxTransactionStep,
    ConsistentLedgerPostgresStatement, ConsistentLedgerPostgresStatementKind,
    ConsistentLedgerPostgresStatementOutcome, ConsistentLedgerPostgresStatementResult,
    ConsistentLedgerPostgresTransactionExecutor, ConsistentLedgerPostgresTransactionStep,
    ConsistentLedgerPostgresTransactionStepKind, execute_consistent_ledger_postgres_plan,
    map_consistent_ledger_postgres_db_error, plan_consistent_ledger_postgres_execution,
    plan_consistent_ledger_postgres_sqlx_adapter_contract,
    summarize_consistent_ledger_postgres_executor_result,
};
#[cfg(feature = "postgres-sqlx")]
pub use postgres_execution::{
    ConsistentLedgerPostgresSqlxBindValue, ConsistentLedgerPostgresSqlxExecutableStatement,
    execute_consistent_ledger_postgres_sqlx_plan,
    execute_consistent_ledger_postgres_sqlx_writer_plan, map_consistent_ledger_postgres_sqlx_error,
    plan_consistent_ledger_postgres_sqlx_executable_statements,
};
pub use pre_authorize::{
    PreAuthorizeBalance, PreAuthorizeBudget, PreAuthorizeDecision, PreAuthorizeEstimate,
    PreAuthorizeRejectReason, pre_authorize,
};
pub use rating::{
    DEFAULT_CURRENCY, DEFAULT_MONEY_SCALE, ExtendedTokenUsage, FixedDecimal, PricingRules,
    RatingError, RatingResult, TOKENS_PER_MILLION, TokenUsage,
    extract_runtime_token_usage_from_json_str, extract_runtime_token_usage_from_value,
    rate_runtime_usage_from_json, rate_usage, rate_usage_from_json,
};
pub use reconciliation::{
    BillingReconciliationCurrencyTotal, BillingReconciliationDiscrepancy,
    BillingReconciliationInputRow, BillingReconciliationReport, BillingReconciliationSummary,
    ReconciliationError, ReconciliationIssue, reconcile_billing_usage_ledger,
};
pub use subscription_scheduler::{
    SUBSCRIPTION_SCHEDULER_EXECUTION_PLAN_SCHEMA, SubscriptionSchedulerEventType,
    SubscriptionSchedulerExecuteMode, plan_subscription_scheduler_execution,
};
pub use writer_contract::{
    CONSISTENT_LEDGER_COMMAND_EXECUTOR_SCHEMA, CONSISTENT_LEDGER_WRITER_SCHEMA,
    ConsistentBudgetCheck, ConsistentBudgetDimension, ConsistentBudgetSnapshot,
    ConsistentCreditGrantSnapshot, ConsistentLedgerBoundedCommand,
    ConsistentLedgerBoundedCommandKind, ConsistentLedgerCommandExecution,
    ConsistentLedgerCommandExecutionError, ConsistentLedgerCommandExecutionOutcome,
    ConsistentLedgerCommandExecutor, ConsistentLedgerCommandPlan, ConsistentLedgerExecutorContract,
    ConsistentLedgerInMemoryStateSummary, ConsistentLedgerScope, ConsistentLedgerWriteRequest,
    ConsistentLedgerWriterError, ConsistentLedgerWriterPlan, ConsistentLedgerWriterState,
    ConsistentPostgresWriterContract, ConsistentWalletCheck, ConsistentWalletSnapshot,
    ConsistentWriterLockPlan, ConsistentWriterLockStep, ConsistentWriterStateMachine,
    InMemoryConsistentLedgerWriter, plan_consistent_ledger_write,
    plan_consistent_ledger_write_commands,
};

pub const BETA_BILLING_MODE_CONTRACT_SCHEMA: &str = "billing_ledger_beta_billing_mode_contract.v1";
pub const BETA_BILLING_MODE_USAGE_ONLY: &str = "usage_only_beta";

#[cfg(test)]
mod beta_billing_mode_contract_tests {
    use serde::Deserialize;

    use super::{BETA_BILLING_MODE_CONTRACT_SCHEMA, BETA_BILLING_MODE_USAGE_ONLY};

    const USAGE_ONLY_BETA_FIXTURE: &str =
        include_str!("../../../tests/fixtures/billing/usage_only_beta_billing_mode_contract.json");

    #[derive(Debug, Deserialize)]
    struct UsageOnlyBetaFixture {
        contract: String,
        billing_mode: String,
        status: String,
        beta_user_message: String,
        api_response_contract: ApiResponseContract,
        usage_cost_display: UsageCostDisplay,
        ledger_policy: LedgerPolicy,
        budget_policy: BudgetPolicy,
        paid_beta_blockers: Vec<String>,
    }

    #[derive(Debug, Deserialize)]
    struct ApiResponseContract {
        required_fields: RequiredResponseFields,
        must_not_claim: Vec<String>,
    }

    #[derive(Debug, Deserialize)]
    struct RequiredResponseFields {
        billing_mode: String,
        billing_settlement_status: String,
        real_money_charges_enabled: bool,
        paid_beta_sales_enabled: bool,
        balance_strong_consistency_commitment: bool,
        ledger_source_of_truth: String,
        usage_cost_visibility: String,
        budget_hard_limit_policy: String,
    }

    #[derive(Debug, Deserialize)]
    struct UsageCostDisplay {
        allowed: bool,
        settled_billing: bool,
        copy: String,
    }

    #[derive(Debug, Deserialize)]
    struct LedgerPolicy {
        settled_source_of_truth: bool,
        source_of_truth_label: String,
        dashboard_aggregate_is_accounting_truth: bool,
        double_write_allowed: bool,
        idempotency_key_required_for_future_paid_writer: bool,
    }

    #[derive(Debug, Deserialize)]
    struct BudgetPolicy {
        hard_limit_strongly_consistent: bool,
        allowed_until_paid_writer: String,
        oversell_copy_allowed: bool,
    }

    #[test]
    fn usage_only_beta_contract_does_not_claim_settled_paid_billing() {
        let fixture: UsageOnlyBetaFixture =
            serde_json::from_str(USAGE_ONLY_BETA_FIXTURE).expect("fixture should parse");

        assert_eq!(fixture.contract, BETA_BILLING_MODE_CONTRACT_SCHEMA);
        assert_eq!(fixture.billing_mode, BETA_BILLING_MODE_USAGE_ONLY);
        assert_eq!(fixture.status, "selected");
        assert!(fixture.beta_user_message.contains("no real-money charges"));
        assert!(
            fixture
                .beta_user_message
                .contains("not settled billing source-of-truth")
        );

        let fields = fixture.api_response_contract.required_fields;
        assert_eq!(fields.billing_mode, BETA_BILLING_MODE_USAGE_ONLY);
        assert_eq!(fields.billing_settlement_status, "not_settled");
        assert!(!fields.real_money_charges_enabled);
        assert!(!fields.paid_beta_sales_enabled);
        assert!(!fields.balance_strong_consistency_commitment);
        assert_eq!(fields.ledger_source_of_truth, "not_settled_source_of_truth");
        assert_eq!(fields.usage_cost_visibility, "estimate_only");
        assert_eq!(
            fields.budget_hard_limit_policy,
            "conservative_deny_only_until_strong_consistency"
        );

        assert!(fixture.usage_cost_display.allowed);
        assert!(!fixture.usage_cost_display.settled_billing);
        assert!(fixture.usage_cost_display.copy.contains("visibility only"));
        assert!(!fixture.ledger_policy.settled_source_of_truth);
        assert_eq!(
            fixture.ledger_policy.source_of_truth_label,
            "usage_visibility_only"
        );
        assert!(
            !fixture
                .ledger_policy
                .dashboard_aggregate_is_accounting_truth
        );
        assert!(!fixture.ledger_policy.double_write_allowed);
        assert!(
            fixture
                .ledger_policy
                .idempotency_key_required_for_future_paid_writer
        );
        assert!(!fixture.budget_policy.hard_limit_strongly_consistent);
        assert_eq!(
            fixture.budget_policy.allowed_until_paid_writer,
            "conservative_deny_only"
        );
        assert!(!fixture.budget_policy.oversell_copy_allowed);

        assert!(
            fixture
                .api_response_contract
                .must_not_claim
                .iter()
                .any(|claim| claim == "paid_controlled_beta")
        );
        assert!(
            fixture
                .api_response_contract
                .must_not_claim
                .iter()
                .any(|claim| claim == "settled_billing_source_of_truth")
        );
        assert!(
            fixture
                .paid_beta_blockers
                .iter()
                .any(|blocker| blocker == "gateway_hot_path_reserve_settle_refund_not_complete")
        );
    }
}
