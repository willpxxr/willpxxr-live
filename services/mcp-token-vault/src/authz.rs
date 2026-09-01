use crate::config::ProviderConfig;
use crate::state::{AppState, SharedState};
use axum::Router;
use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::any;
use std::sync::Arc;

/// Envoy ext_authz HTTP check endpoint (see WEP-0006). On `tools/call` the
/// tool name's `provider__tool` prefix selects the provider; a stored
/// credential becomes an `authorization` header injected upstream, and a
/// missing one becomes a 500 carrying the elicitation URL. Everything else
/// (initialize, tools/list, notifications) passes untouched.
async fn check(State(state): State<Arc<AppState>>, req: Request) -> Response {
    let (_parts, body) = req.into_parts();
    let body_bytes = axum::body::to_bytes(body, 1024 * 1024)
        .await
        .unwrap_or_default();
    let parsed: serde_json::Value = serde_json::from_slice(&body_bytes).unwrap_or_default();

    if parsed.get("method").and_then(|m| m.as_str()) == Some("tools/call") {
        let tool = parsed
            .pointer("/params/name")
            .and_then(|n| n.as_str())
            .unwrap_or("");
        let provider = tool.split("__").next().unwrap_or("");
        if let Some(pc) = state.config.providers.iter().find(|p| p.name == provider) {
            tracing::info!(provider = %pc.name, %tool, "tools/call for vault-managed provider");
            return match resolve_credential(&state, pc).await {
                Ok(token) => (
                    StatusCode::OK,
                    [(axum::http::header::AUTHORIZATION, format!("Bearer {token}"))],
                )
                    .into_response(),
                Err(e) => {
                    tracing::warn!(provider = %pc.name, error = %e, "credential unavailable, eliciting");
                    crate::oauth::missing_credential_response(&state.config, &pc.name)
                }
            };
        }
    }

    StatusCode::OK.into_response()
}

async fn resolve_credential(state: &AppState, pc: &ProviderConfig) -> anyhow::Result<String> {
    let cred = crate::store::get(&state.pool, &state.key, &pc.name)
        .await?
        .ok_or_else(|| anyhow::anyhow!("no credential stored for provider {}", pc.name))?;
    if cred.kind == "oauth" {
        crate::refresh::current_access(state, pc, false).await
    } else {
        cred.access
            .ok_or_else(|| anyhow::anyhow!("provider {} has no api key", pc.name))
    }
}

pub fn router(state: SharedState) -> Router {
    Router::new().route("/authz", any(check)).with_state(state)
}
