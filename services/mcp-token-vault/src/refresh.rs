use crate::config::ProviderConfig;
use crate::state::AppState;
use anyhow::{Context, Result, bail};
use chrono::{DateTime, Duration, Utc};
use serde::Deserialize;
use std::sync::Arc;

const REFRESH_SKEW: Duration = Duration::minutes(5);
const LOOP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60);

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    expires_in: Option<i64>,
    #[serde(default)]
    scope: Option<String>,
}

fn needs_refresh(expires_at: Option<DateTime<Utc>>) -> bool {
    match expires_at {
        None => true,
        Some(t) => t - Utc::now() < REFRESH_SKEW,
    }
}

async fn refresh_unlocked(state: &AppState, pc: &ProviderConfig) -> Result<()> {
    let Some(token) = &pc.token else {
        bail!("provider {} has no oauth token config", pc.name);
    };
    let cred = crate::store::get(&state.pool, &state.key, &pc.name)
        .await?
        .ok_or_else(|| anyhow::anyhow!("no credential stored for provider {}", pc.name))?;
    if cred.kind != "oauth" {
        bail!("provider {} credential is not oauth", pc.name);
    }
    let refresh_token = cred
        .refresh
        .ok_or_else(|| anyhow::anyhow!("no refresh token stored for provider {}", pc.name))?;

    let resp: TokenResponse = state
        .client
        .post(&token.token_url)
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token.as_str()),
            ("client_id", token.client_id.as_str()),
            ("client_secret", token.client_secret.as_str()),
        ])
        .send()
        .await
        .context("refresh token request failed")?
        .error_for_status()
        .context("refresh token request rejected")?
        .json()
        .await
        .context("parsing refresh token response")?;

    let expires_at = Utc::now() + Duration::seconds(resp.expires_in.unwrap_or(3600));
    crate::store::upsert(
        &state.pool,
        &state.key,
        &pc.name,
        "oauth",
        Some(&resp.access_token),
        resp.refresh_token.as_deref(),
        Some(expires_at),
        resp.scope.as_deref().or(cred.scopes.as_deref()),
    )
    .await?;
    tracing::info!(provider = %pc.name, "refreshed access token");
    Ok(())
}

pub async fn refresh(state: Arc<AppState>, pc: &ProviderConfig) -> Result<()> {
    let _guard = state.refresh_lock.lock().await;
    refresh_unlocked(&state, pc).await
}

pub async fn current_access(state: &AppState, pc: &ProviderConfig, force: bool) -> Result<String> {
    let load = || async {
        crate::store::get(&state.pool, &state.key, &pc.name)
            .await?
            .ok_or_else(|| anyhow::anyhow!("no credential stored for provider {}", pc.name))
    };

    let cred = load().await?;
    if cred.kind == "oauth" {
        let stale = force || cred.access.is_none() || needs_refresh(cred.expires_at);
        if stale {
            let _guard = state.refresh_lock.lock().await;
            let cred = load().await?;
            if force || cred.access.is_none() || needs_refresh(cred.expires_at) {
                refresh_unlocked(state, pc).await?;
            }
            return load().await?.access.ok_or_else(|| {
                anyhow::anyhow!("provider {} has no access token after refresh", pc.name)
            });
        }
    }
    cred.access
        .ok_or_else(|| anyhow::anyhow!("provider {} has no access token", pc.name))
}

pub async fn run_loop(state: Arc<AppState>, providers: Vec<ProviderConfig>) {
    loop {
        for pc in &providers {
            let has_refreshable = crate::store::get(&state.pool, &state.key, &pc.name)
                .await
                .ok()
                .flatten()
                .map(|c| c.kind == "oauth" && c.refresh.is_some())
                .unwrap_or(false);
            if !has_refreshable {
                continue;
            }
            if let Err(e) = refresh(state.clone(), pc).await {
                tracing::warn!(provider = %pc.name, error = %e, "periodic refresh failed");
            }
        }
        tokio::time::sleep(LOOP_INTERVAL).await;
    }
}
