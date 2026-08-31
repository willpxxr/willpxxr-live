use crate::{config, crypto, store};
use anyhow::{Context, Result};
use std::sync::Arc;

pub struct AppState {
    pub pool: sqlx::PgPool,
    pub key: crypto::Key,
    pub config: config::Config,
    pub refresh_lock: tokio::sync::Mutex<()>,
    pub client: reqwest::Client,
}

pub async fn build() -> Result<Arc<AppState>> {
    let cfg = config::Config::from_env()?;
    let key = crypto::Key::from_env()?;
    if let Some(admin_url) = &cfg.admin_database_url {
        store::bootstrap_role(admin_url, &cfg.database_url)
            .await
            .context("bootstrapping database role")?;
    }
    let pool = store::connect(&cfg.database_url).await?;
    store::migrate(&pool).await?;
    let client = reqwest::Client::builder()
        .user_agent("mcp-token-vault/0.1")
        .build()?;
    Ok(Arc::new(AppState {
        pool,
        key,
        config: cfg,
        refresh_lock: tokio::sync::Mutex::new(()),
        client,
    }))
}

pub type SharedState = Arc<AppState>;
