mod admin;
mod alerts;
mod auth;
mod auth_login_rate_limit;
mod auth_repo;
mod prompt_eval_shadow;
mod rbac;

use std::{net::SocketAddr, sync::Arc, time::Duration};

use ai_gateway_app_core::{AppState, health_payload, normalize_listen_addr};
use ai_gateway_config::AppConfig;
use ai_gateway_observability::init_tracing;
use axum::{
    Json, Router,
    extract::State,
    http::{
        HeaderValue, Method, StatusCode,
        header::{AUTHORIZATION, CONTENT_TYPE},
    },
    response::IntoResponse,
    routing::get,
};
use sqlx::{PgPool, postgres::PgPoolOptions};
use tower_http::{
    cors::{AllowOrigin, CorsLayer},
    trace::TraceLayer,
};
use uuid::Uuid;

use crate::auth_login_rate_limit::{
    LoginFailureRateLimitStore, login_failure_rate_limit_store_from_env,
};

pub(crate) const DEFAULT_TENANT_ID: Uuid = Uuid::from_u128(0x00000000_0000_0000_0000_000000000001);
const DB_CONNECT_ATTEMPTS: u32 = 30;
const CONTROL_CORS_ALLOWED_ORIGINS_ENV: &str = "AI_GATEWAY_CONTROL_CORS_ALLOWED_ORIGINS";

#[derive(Debug, Clone)]
pub(crate) struct ControlPlaneState {
    app: AppState,
    db: PgPool,
    login_failure_rate_limits: Arc<dyn LoginFailureRateLimitStore>,
}

impl ControlPlaneState {
    fn new(app: AppState, db: PgPool) -> Self {
        let login_failure_rate_limits = login_failure_rate_limit_store_from_env(
            &app.config().redis.addr,
            app.config().redis.db,
        );
        Self {
            app,
            db,
            login_failure_rate_limits,
        }
    }

    fn app(&self) -> &AppState {
        &self.app
    }

    pub(crate) fn db(&self) -> &PgPool {
        &self.db
    }

    pub(crate) fn login_failure_rate_limits(&self) -> &dyn LoginFailureRateLimitStore {
        self.login_failure_rate_limits.as_ref()
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    init_tracing("control-plane");

    let config = AppConfig::load_from_env()?;
    config.validate()?;
    if config.database.driver != "postgres" {
        return Err(format!(
            "unsupported control-plane database driver `{}`",
            config.database.driver
        )
        .into());
    }

    let listen =
        std::env::var("AI_GATEWAY_CONTROL_LISTEN").unwrap_or_else(|_| "0.0.0.0:8081".to_string());
    let addr: SocketAddr = normalize_listen_addr(&listen).parse()?;
    let db = connect_with_retry(&config).await?;
    let cors = control_plane_cors(&config);
    let state = Arc::new(ControlPlaneState::new(
        AppState::new("control-plane", config),
        db,
    ));

    let admin_router = admin::router().route_layer(axum::middleware::from_fn_with_state(
        state.clone(),
        rbac::require_admin_rbac,
    ));

    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .merge(auth::router())
        .merge(admin_router)
        .layer(TraceLayer::new_for_http())
        .layer(cors)
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!(%addr, "control-plane listening");
    axum::serve(listener, app).await?;
    Ok(())
}

fn control_plane_cors(config: &AppConfig) -> CorsLayer {
    let origins = allowed_cors_origins(config);
    CorsLayer::new()
        .allow_origin(AllowOrigin::list(origins))
        .allow_methods([
            Method::GET,
            Method::HEAD,
            Method::POST,
            Method::PATCH,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers([
            CONTENT_TYPE,
            AUTHORIZATION,
            axum::http::HeaderName::from_static(auth::ADMIN_SESSION_HEADER),
        ])
        .allow_credentials(true)
}

fn allowed_cors_origins(config: &AppConfig) -> Vec<HeaderValue> {
    let raw = std::env::var(CONTROL_CORS_ALLOWED_ORIGINS_ENV).unwrap_or_default();
    let defaults = [
        "http://localhost:5173",
        "http://127.0.0.1:5173",
        config.server.public_base_url.as_str(),
    ];
    let candidates: Vec<&str> = if raw.trim().is_empty() {
        defaults.to_vec()
    } else {
        raw.split(',')
            .map(str::trim)
            .filter(|origin| !origin.is_empty())
            .collect()
    };

    let mut origins: Vec<HeaderValue> = Vec::new();
    for origin in candidates {
        if origin == "*"
            || origins
                .iter()
                .any(|existing| existing.as_bytes() == origin.as_bytes())
        {
            continue;
        }
        if let Ok(value) = HeaderValue::from_str(origin) {
            origins.push(value);
        }
    }

    origins
}

async fn connect_with_retry(config: &AppConfig) -> Result<PgPool, sqlx::Error> {
    let mut last_error = None;

    for attempt in 1..=DB_CONNECT_ATTEMPTS {
        match PgPoolOptions::new()
            .max_connections(8)
            .connect(&config.database.dsn)
            .await
        {
            Ok(pool) => return Ok(pool),
            Err(error) => {
                tracing::warn!(
                    attempt,
                    max_attempts = DB_CONNECT_ATTEMPTS,
                    %error,
                    "postgres connection failed"
                );
                last_error = Some(error);
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }

    Err(last_error.expect("at least one db connection attempt is executed"))
}

async fn healthz(State(state): State<Arc<ControlPlaneState>>) -> impl IntoResponse {
    Json(health_payload(state.app().service_name()))
}

async fn readyz(State(state): State<Arc<ControlPlaneState>>) -> impl IntoResponse {
    match sqlx::query("select 1").execute(state.db()).await {
        Ok(_) => (
            StatusCode::OK,
            Json(serde_json::json!({
                "service": state.app().service_name(),
                "status": "ready",
                "database": "connected",
            })),
        ),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({
                "service": state.app().service_name(),
                "status": "not_ready",
                "database": "unavailable",
            })),
        ),
    }
}
