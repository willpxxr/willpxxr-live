use crate::state::{AppState, SharedState};
use axum::extract::{Request, State};
use axum::http::{StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{Duration, Utc};
use serde::Deserialize;
use std::sync::Arc;

#[derive(Deserialize)]
struct Bootstrap {
    provider: String,
    #[serde(default = "default_kind")]
    kind: String,
    #[serde(default)]
    access_token: Option<String>,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    expires_in: Option<i64>,
    #[serde(default)]
    scopes: Option<String>,
}

fn default_kind() -> String {
    "oauth".to_string()
}

async fn require_admin(State(state): State<SharedState>, req: Request, next: Next) -> Response {
    if let Some(expected) = &state.config.admin_token {
        let provided = req
            .headers()
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok());
        if provided != Some(&format!("Bearer {expected}")) {
            return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
        }
    }
    next.run(req).await
}

async fn healthz() -> &'static str {
    "ok"
}

async fn bootstrap(
    State(state): State<Arc<AppState>>,
    Json(body): Json<Bootstrap>,
) -> Result<Json<serde_json::Value>, Response> {
    let pc = state
        .config
        .providers
        .iter()
        .find(|p| p.name == body.provider)
        .ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                format!("unknown provider {}", body.provider),
            )
                .into_response()
        })?;

    if body.kind != "oauth" && body.kind != "api_key" {
        return Err((
            StatusCode::BAD_REQUEST,
            "kind must be oauth or api_key".to_string(),
        )
            .into_response());
    }
    if body.kind == "oauth" && body.refresh_token.is_none() && body.access_token.is_none() {
        return Err((
            StatusCode::BAD_REQUEST,
            "oauth bootstrap needs a refresh_token or access_token".to_string(),
        )
            .into_response());
    }
    if body.kind == "api_key" && body.access_token.is_none() {
        return Err((
            StatusCode::BAD_REQUEST,
            "api_key bootstrap needs access_token".to_string(),
        )
            .into_response());
    }

    let expires_at = body.expires_in.map(|s| Utc::now() + Duration::seconds(s));

    crate::store::upsert(
        &state.pool,
        &state.key,
        &body.provider,
        &body.kind,
        body.access_token.as_deref(),
        body.refresh_token.as_deref(),
        expires_at,
        body.scopes.as_deref(),
    )
    .await
    .map_err(err)?;

    if body.kind == "oauth" && body.refresh_token.is_some() {
        crate::refresh::refresh(state.clone(), pc)
            .await
            .map_err(err)?;
    }

    Ok(Json(
        serde_json::json!({"ok": true, "provider": body.provider}),
    ))
}

fn err(e: anyhow::Error) -> Response {
    tracing::error!(error = %e, "admin request failed");
    (StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}")).into_response()
}

pub fn router(state: SharedState) -> Router {
    let protected = Router::new()
        .route("/bootstrap", post(bootstrap))
        .layer(middleware::from_fn_with_state(state.clone(), require_admin));
    Router::new()
        .route("/healthz", get(healthz))
        .merge(protected)
        .with_state(state)
}

/// Browser-facing router (OAUTH_PORT). Path layout mirrors the gateway
/// route split in apps/mcp-token-vault/httproute-ui.yaml: `/` and
/// `/oauth/{provider}/start` sit behind the Auth0 SecurityPolicy, while the
/// provider callback lives under `/cb/` on an unpolicied HTTPRoute -- the
/// upstream provider redirects there with the authorization code and cannot
/// perform Auth0 browser login mid-redirect. The callback's protection is
/// the single-use PKCE state table (store::take_pending) instead.
pub fn oauth_router(state: SharedState) -> Router {
    let callback = Router::new().route("/oauth/{provider}/callback", get(crate::oauth::callback));
    Router::new()
        .route("/", get(crate::ui::index))
        .route("/oauth/{provider}/start", get(crate::oauth::start))
        .nest("/cb", callback)
        .with_state(state)
}
