use crate::state::AppState;
use anyhow::{Context, Result, bail};
use axum::extract::{Path, Query, State};
use axum::response::{Html, IntoResponse, Redirect, Response};
use base64::Engine;

use chrono::{Duration, Utc};
use serde_json::json;
use std::collections::HashMap;
use std::sync::Arc;

const SUCCESS_HTML: &str = "<html><body><h3>Authorized.</h3><p>Credential stored. You can retry your request.</p></body></html>";

fn random_bytes(n: usize) -> Vec<u8> {
    let mut out = vec![0u8; n];
    getrandom::fill(&mut out).expect("os rng failure");
    out
}

fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn pkce_challenge(verifier: &str) -> String {
    use sha2::{Digest, Sha256};
    b64url(&Sha256::digest(verifier.as_bytes()))
}

pub async fn start(
    State(state): State<Arc<AppState>>,
    Path(provider): Path<String>,
    Query(pairs): Query<Vec<(String, String)>>,
) -> Response {
    match start_inner(&state, &provider, &pairs).await {
        Ok(url) => Redirect::to(url.as_str()).into_response(),
        Err(e) => Html(format!(
            "<html><body><h3>Elicitation error</h3><p>{e:#}</p></body></html>"
        ))
        .into_response(),
    }
}

async fn start_inner(
    state: &AppState,
    provider: &str,
    query: &[(String, String)],
) -> Result<String> {
    let pc = state
        .config
        .providers
        .iter()
        .find(|p| p.name == provider)
        .context("unknown provider")?;
    let token = pc
        .token
        .as_ref()
        .context("provider has no oauth configuration")?;
    let authorize_url = token
        .authorize_url
        .as_ref()
        .context("provider has no interactive elicitation (AUTHORIZE_URL) configured")?;
    let redirect_uri = token
        .redirect_uri
        .as_ref()
        .context("no REDIRECT_URI configured")?;

    crate::store::purge_old_pending(&state.pool).await?;

    let state_param = b64url(&random_bytes(16));
    let code_verifier = b64url(&random_bytes(32));

    crate::store::insert_pending(&state.pool, &state_param, provider, &code_verifier).await?;

    let mut url: reqwest::Url = authorize_url
        .parse()
        .context("provider AUTHORIZE_URL is not a valid URL")?;
    {
        let mut q = url.query_pairs_mut();
        q.append_pair("response_type", "code");
        q.append_pair("client_id", &token.client_id);
        q.append_pair("redirect_uri", redirect_uri);
        // Scope selection: defaults from config; the UI may opt into extra
        // scopes via ?scopes= (repeated or comma-separated). Requested
        // scopes must be declared in config (defaults + optional) -- a typo
        // should error loudly, not silently change the consent screen.
        let split = |s: &Option<String>| -> Vec<String> {
            s.as_deref()
                .map(|s| {
                    s.split(',')
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .map(String::from)
                        .collect()
                })
                .unwrap_or_default()
        };
        let defaults = split(&token.scopes);
        let optionals = split(&token.optional_scopes);
        let mut requested: Vec<String> = query
            .iter()
            .filter(|(k, _)| k == "scopes")
            .flat_map(|(_, v)| split(&Some(v.clone())))
            .collect();
        requested.dedup();
        if requested.is_empty() {
            requested = defaults.clone();
        } else {
            let allowed: Vec<&String> = defaults.iter().chain(optionals.iter()).collect();
            for s in &requested {
                if !allowed.contains(&s) {
                    bail!(
                        "scope {s} is not configured for provider {provider} (defaults: {}; optional: {})",
                        defaults.join(","),
                        optionals.join(",")
                    );
                }
            }
        }
        if !requested.is_empty() {
            q.append_pair("scope", &requested.join(","));
        }
        if let Some(actor) = &token.actor {
            q.append_pair("actor", actor);
        }
        q.append_pair("state", &state_param);
        q.append_pair("code_challenge", &pkce_challenge(&code_verifier));
        q.append_pair("code_challenge_method", "S256");
    }
    Ok(url.to_string())
}

pub async fn callback(
    State(state): State<Arc<AppState>>,
    Path(provider): Path<String>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    match callback_inner(&state, &provider, &params).await {
        Ok(()) => Html(SUCCESS_HTML).into_response(),
        Err(e) => {
            tracing::warn!(provider = %provider, error = %e, "elicitation callback failed");
            Html(format!(
                "<html><body><h3>Authorization failed</h3><p>{e:#}</p></body></html>"
            ))
            .into_response()
        }
    }
}

async fn callback_inner(
    state: &AppState,
    provider: &str,
    params: &HashMap<String, String>,
) -> Result<()> {
    let code = params
        .get("code")
        .context("callback missing code parameter")?;
    let state_param = params
        .get("state")
        .context("callback missing state parameter")?;

    let pending = crate::store::take_pending(&state.pool, state_param)
        .await?
        .context("unknown or expired elicitation state")?;
    if pending.provider != provider {
        bail!("elicitation state does not match provider");
    }

    let pc = state
        .config
        .providers
        .iter()
        .find(|p| p.name == provider)
        .context("unknown provider")?;
    let token = pc
        .token
        .as_ref()
        .context("provider has no oauth configuration")?;
    let redirect_uri = token
        .redirect_uri
        .as_ref()
        .context("no REDIRECT_URI configured")?;

    #[derive(serde::Deserialize)]
    struct TokenResponse {
        access_token: String,
        #[serde(default)]
        refresh_token: Option<String>,
        #[serde(default)]
        expires_in: Option<i64>,
        #[serde(default)]
        scope: Option<String>,
    }

    let resp: TokenResponse = state
        .client
        .post(&token.token_url)
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code.as_str()),
            ("redirect_uri", redirect_uri.as_str()),
            ("client_id", token.client_id.as_str()),
            ("client_secret", token.client_secret.as_str()),
            ("code_verifier", pending.code_verifier.as_str()),
        ])
        .send()
        .await
        .context("token exchange request failed")?
        .error_for_status()
        .context("token exchange rejected")?
        .json()
        .await
        .context("parsing token exchange response")?;

    let expires_at = Utc::now() + Duration::seconds(resp.expires_in.unwrap_or(3600));
    crate::store::upsert(
        &state.pool,
        &state.key,
        provider,
        "oauth",
        Some(&resp.access_token),
        resp.refresh_token.as_deref(),
        Some(expires_at),
        resp.scope.as_deref(),
    )
    .await?;
    tracing::info!(provider = %provider, "elicitation completed, credential stored");
    Ok(())
}

pub fn elicitation_url(config: &crate::config::Config, provider: &str) -> Option<String> {
    let base = config.elicitation_base_url.as_ref()?;
    Some(format!(
        "{}/oauth/{}/start",
        base.trim_end_matches('/'),
        provider
    ))
}

pub fn missing_credential_response(config: &crate::config::Config, provider: &str) -> Response {
    match elicitation_url(config, provider) {
        Some(url) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            axum::Json(json!({"url": url, "status_url": null})),
        )
            .into_response(),
        None => (
            axum::http::StatusCode::SERVICE_UNAVAILABLE,
            format!("no credential stored for provider {provider} and no elicitation configured"),
        )
            .into_response(),
    }
}
