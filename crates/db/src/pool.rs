use ai_gateway_config::AppConfig;
use sqlx::{Pool, Postgres, postgres::PgPoolOptions};
use thiserror::Error;

pub type PgPool = Pool<Postgres>;

#[derive(Debug, Error)]
pub enum DbError {
    #[error("unsupported database driver `{0}`")]
    UnsupportedDriver(String),
    #[error("failed to connect to postgres: {0}")]
    Connect(sqlx::Error),
    #[error("database query failed: {0}")]
    Query(sqlx::Error),
    #[error("database returned invalid data: {0}")]
    InvalidData(String),
}

pub async fn connect(config: &AppConfig) -> Result<PgPool, DbError> {
    if config.database.driver != "postgres" {
        return Err(DbError::UnsupportedDriver(config.database.driver.clone()));
    }

    PgPoolOptions::new()
        .max_connections(8)
        .connect(&config.database.dsn)
        .await
        .map_err(DbError::Connect)
}
