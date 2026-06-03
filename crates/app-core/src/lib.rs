use ai_gateway_config::AppConfig;
use serde_json::{Value, json};

#[derive(Debug, Clone)]
pub struct AppState {
    service_name: &'static str,
    config: AppConfig,
}

impl AppState {
    pub fn new(service_name: &'static str, config: AppConfig) -> Self {
        Self {
            service_name,
            config,
        }
    }

    pub fn service_name(&self) -> &'static str {
        self.service_name
    }

    pub fn config(&self) -> &AppConfig {
        &self.config
    }
}

pub fn health_payload(service: &str) -> Value {
    json!({
        "service": service,
        "status": "ok",
    })
}

pub fn normalize_listen_addr(input: &str) -> String {
    if input.starts_with(':') {
        format!("0.0.0.0{input}")
    } else {
        input.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands_port_only_addr() {
        assert_eq!(normalize_listen_addr(":8080"), "0.0.0.0:8080");
        assert_eq!(normalize_listen_addr("127.0.0.1:8080"), "127.0.0.1:8080");
    }
}
