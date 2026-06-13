use serde::Serialize;

pub const LOCAL_PAYMENT_DEMO_SCHEMA: &str = "billing_local_payment_demo.v1";
pub const LOCAL_PAYMENT_DEMO_SOURCE: &str = "local_runtime_demo";
pub const LOCAL_PAYMENT_DEMO_LEDGER_OPERATION: &str = "payment_demo_credit_grant";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LocalPaymentDemoContract {
    pub schema: &'static str,
    pub mode: &'static str,
    pub local_only: bool,
    pub merchant_connected: bool,
    pub production_payment_evidence: bool,
    pub money_scale: u32,
    pub ledger_entry_type: &'static str,
    pub ledger_operation: &'static str,
    pub invoice_policy: &'static str,
    pub receipt_policy: &'static str,
    pub reconciliation_policy: &'static str,
    pub forbidden_outputs: &'static [&'static str],
}

pub fn local_payment_demo_contract() -> LocalPaymentDemoContract {
    LocalPaymentDemoContract {
        schema: LOCAL_PAYMENT_DEMO_SCHEMA,
        mode: "runtime_demo",
        local_only: true,
        merchant_connected: false,
        production_payment_evidence: false,
        money_scale: 8,
        ledger_entry_type: "adjust",
        ledger_operation: LOCAL_PAYMENT_DEMO_LEDGER_OPERATION,
        invoice_policy: "runtime_record_not_legal_tax_invoice",
        receipt_policy: "runtime_record_not_legal_tax_receipt",
        reconciliation_policy: "matched_runtime_readback_not_production_finance_reconciliation",
        forbidden_outputs: &[
            "idempotency_key",
            "raw_metadata",
            "provider_secret",
            "client_secret",
            "authorization",
            "provider_payload",
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_payment_demo_contract_is_explicitly_not_production_payment() {
        let contract = local_payment_demo_contract();

        assert_eq!(contract.schema, LOCAL_PAYMENT_DEMO_SCHEMA);
        assert!(contract.local_only);
        assert!(!contract.merchant_connected);
        assert!(!contract.production_payment_evidence);
        assert_eq!(contract.money_scale, 8);
        assert_eq!(contract.ledger_entry_type, "adjust");
        assert_eq!(
            contract.invoice_policy,
            "runtime_record_not_legal_tax_invoice"
        );
        assert_eq!(
            contract.receipt_policy,
            "runtime_record_not_legal_tax_receipt"
        );
        assert_eq!(
            contract.reconciliation_policy,
            "matched_runtime_readback_not_production_finance_reconciliation"
        );
        assert!(contract.forbidden_outputs.contains(&"idempotency_key"));
        assert!(contract.forbidden_outputs.contains(&"raw_metadata"));
    }
}
