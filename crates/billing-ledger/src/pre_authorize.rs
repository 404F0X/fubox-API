use crate::FixedDecimal;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PreAuthorizeEstimate {
    pub minimum_cost: FixedDecimal,
    pub billable_if_usage_present: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PreAuthorizeBalance {
    pub available: FixedDecimal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PreAuthorizeBudget {
    pub remaining: FixedDecimal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreAuthorizeDecision {
    Allow,
    Reject(PreAuthorizeRejectReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreAuthorizeRejectReason {
    InsufficientWalletBalance,
    InsufficientBudget,
}

pub fn pre_authorize(
    estimate: PreAuthorizeEstimate,
    wallet: Option<PreAuthorizeBalance>,
    budgets: &[PreAuthorizeBudget],
) -> PreAuthorizeDecision {
    if let Some(wallet) = wallet
        && amount_is_insufficient(wallet.available, estimate)
    {
        return PreAuthorizeDecision::Reject(PreAuthorizeRejectReason::InsufficientWalletBalance);
    }

    if budgets
        .iter()
        .any(|budget| amount_is_insufficient(budget.remaining, estimate))
    {
        return PreAuthorizeDecision::Reject(PreAuthorizeRejectReason::InsufficientBudget);
    }

    PreAuthorizeDecision::Allow
}

fn amount_is_insufficient(available: FixedDecimal, estimate: PreAuthorizeEstimate) -> bool {
    if available.scale() != estimate.minimum_cost.scale() {
        return false;
    }

    if estimate.minimum_cost.units() > 0 {
        return available.units() < estimate.minimum_cost.units();
    }

    estimate.billable_if_usage_present && available.units() <= 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn money(value: &str) -> FixedDecimal {
        FixedDecimal::parse(value, 8).expect("valid money")
    }

    fn estimate(minimum_cost: &str, billable_if_usage_present: bool) -> PreAuthorizeEstimate {
        PreAuthorizeEstimate {
            minimum_cost: money(minimum_cost),
            billable_if_usage_present,
        }
    }

    #[test]
    fn rejects_when_wallet_balance_is_below_positive_minimum_cost() {
        let decision = pre_authorize(
            estimate("0.01000000", true),
            Some(PreAuthorizeBalance {
                available: money("0.00999999"),
            }),
            &[],
        );

        assert_eq!(
            decision,
            PreAuthorizeDecision::Reject(PreAuthorizeRejectReason::InsufficientWalletBalance)
        );
    }

    #[test]
    fn rejects_when_budget_remaining_is_below_positive_minimum_cost() {
        let decision = pre_authorize(
            estimate("0.01000000", true),
            None,
            &[PreAuthorizeBudget {
                remaining: money("0.00000000"),
            }],
        );

        assert_eq!(
            decision,
            PreAuthorizeDecision::Reject(PreAuthorizeRejectReason::InsufficientBudget)
        );
    }

    #[test]
    fn rejects_zero_available_amount_for_billable_usage_pricing() {
        let decision = pre_authorize(
            estimate("0.00000000", true),
            Some(PreAuthorizeBalance {
                available: money("0.00000000"),
            }),
            &[],
        );

        assert_eq!(
            decision,
            PreAuthorizeDecision::Reject(PreAuthorizeRejectReason::InsufficientWalletBalance)
        );
    }

    #[test]
    fn allows_when_data_is_missing_or_amounts_cover_minimum_cost() {
        assert_eq!(
            pre_authorize(estimate("0.01000000", true), None, &[]),
            PreAuthorizeDecision::Allow
        );
        assert_eq!(
            pre_authorize(
                estimate("0.01000000", true),
                Some(PreAuthorizeBalance {
                    available: money("0.01000000")
                }),
                &[PreAuthorizeBudget {
                    remaining: money("0.10000000")
                }]
            ),
            PreAuthorizeDecision::Allow
        );
    }

    #[test]
    fn allows_zero_cost_non_billable_pricing_even_with_zero_balance() {
        let decision = pre_authorize(
            estimate("0.00000000", false),
            Some(PreAuthorizeBalance {
                available: money("0.00000000"),
            }),
            &[PreAuthorizeBudget {
                remaining: money("0.00000000"),
            }],
        );

        assert_eq!(decision, PreAuthorizeDecision::Allow);
    }
}
