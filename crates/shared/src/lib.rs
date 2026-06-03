use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum GatewayErrorOwner {
    Gateway,
    Provider,
    Client,
    Billing,
    Policy,
}

#[derive(Debug, Error, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[error("{owner:?}:{code}: {message}")]
pub struct GatewayError {
    pub owner: GatewayErrorOwner,
    pub code: String,
    pub message: String,
}

impl GatewayError {
    pub fn new(
        owner: GatewayErrorOwner,
        code: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            owner,
            code: code.into(),
            message: message.into(),
        }
    }
}
