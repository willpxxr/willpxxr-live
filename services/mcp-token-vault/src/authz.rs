use crate::config::ProviderConfig;
use crate::state::{AppState, SharedState};
use axum::Router;
use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::any;
use std::sync::Arc;

/// Envoy ext_authz HTTP check endpoint (see WEP-0006). Resolves the target
/// provider two ways: (1) on `tools/call`, the tool name's `provider__tool`
/// prefix; (2) on gateway-initiated calls (initialize, tools/list,
/// notifications), the per-backend route metadata that
/// MCPRoute.securityPolicy.extAuth.includeRouteMetadata forwards -- the
/// generated backend routes are named `ai-eg-mcp-br-<route>-<backend>`, and
/// the Backend name IS the provider key. A stored credential becomes an
/// `authorization` header injected upstream (mcp-route.yaml
/// headersToBackend); a missing one becomes a 500 carrying the elicitation
/// URL. Non-vault providers get a bare 200 and no headers, so their own
/// auth mechanisms (betterstack's static apiKey, etc.) are untouched.
async fn check(State(state): State<Arc<AppState>>, req: Request) -> Response {
    let (parts, body) = req.into_parts();
    let body_bytes = axum::body::to_bytes(body, 1024 * 1024)
        .await
        .unwrap_or_default();
    let parsed: serde_json::Value = serde_json::from_slice(&body_bytes).unwrap_or_default();
    let method = parsed.get("method").and_then(|m| m.as_str()).unwrap_or("");

    let provider: Option<&ProviderConfig> = match method {
        "tools/call" => {
            let tool = parsed
                .pointer("/params/name")
                .and_then(|n| n.as_str())
                .unwrap_or("");
            state
                .config
                .providers
                .iter()
                .find(|p| tool.split("__").next() == Some(p.name.as_str()))
                // Backend-side calls dispatched by the gateway have the
                // prefix stripped, so the metadata scan is the fallback.
                .or_else(|| find_by_metadata(&state.config.providers, &parts.headers))
        }
        // initialize / tools/list / notifications have no per-provider
        // signal in their bodies at all; metadata is the only discriminator.
        _ => find_by_metadata(&state.config.providers, &parts.headers),
    };

    // Diagnostics: on a passthrough (non-vault or unresolved) check, log
    // the x-envoy-* header values -- that's where Envoy Gateway's route
    // metadata rides -- plus header names generally. The check carries the
    // client's Auth0 bearer by default (headersToExtAuth unset = all
    // headers), whose value must never hit logs; authorization/cookie
    // values are never logged at any level.
    if provider.is_none() {
        let envoy_values: Vec<String> = parts
            .headers
            .iter()
            .filter(|(k, _)| k.as_str().starts_with("x-envoy"))
            .map(|(k, v)| format!("{}={}", k.as_str(), v.to_str().unwrap_or("<binary>")))
            .collect();
        let names: Vec<&str> = parts.headers.keys().map(|k| k.as_str()).collect();
        tracing::info!(%method, ?names, ?envoy_values, "extauth check passthrough");
    } else if let Some(pc) = provider {
        tracing::info!(provider = %pc.name, %method, "extauth check for vault-managed provider");
    }

    if let Some(pc) = provider {
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

    StatusCode::OK.into_response()
}

/// Matches a vault-managed provider against the ext_authz check headers:
/// includeRouteMetadata exposes Envoy Gateway's route metadata, whose
/// per-backend route names embed the Backend (== provider) name. Header
/// names are never matched -- only values -- and matching is exact-substring
/// on the provider name, which is specific enough that unrelated metadata
/// (kiwi/betterstack/kagent-tools route names) can't collide.
fn find_by_metadata<'a>(
    providers: &'a [ProviderConfig],
    headers: &axum::http::HeaderMap,
) -> Option<&'a ProviderConfig> {
    providers.iter().find(|p| {
        headers
            .iter()
            .any(|(_, v)| v.to_str().map(|v| v.contains(&p.name)).unwrap_or(false))
    })
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

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderMap;

    fn providers(names: &[&str]) -> Vec<ProviderConfig> {
        names
            .iter()
            .map(|n| ProviderConfig {
                name: n.to_string(),
                upstream_url: format!("https://mcp.{n}.app/mcp").parse().unwrap(),
                token: None,
            })
            .collect()
    }

    #[test]
    fn metadata_value_matches_provider() {
        let ps = providers(&["linear"]);
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-envoy-route-metadata",
            "ai-eg-mcp-br-ai-gateway-mcp-linear".parse().unwrap(),
        );
        assert_eq!(find_by_metadata(&ps, &headers).unwrap().name, "linear");
    }

    #[test]
    fn unrelated_metadata_does_not_match() {
        let ps = providers(&["linear"]);
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-envoy-route-metadata",
            "ai-eg-mcp-br-ai-gateway-mcp-betterstack".parse().unwrap(),
        );
        assert!(find_by_metadata(&ps, &headers).is_none());
    }
}
