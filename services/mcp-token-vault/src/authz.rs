use crate::state::{AppState, SharedState};
use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::any;
use axum::Router;
use std::sync::Arc;

/// Envoy ext_authz HTTP check endpoint. The original request (headers, and
/// the body when bodyToExtAuth is configured) arrives here; a 200 response
/// allows the request with any response headers merged into the upstream
/// request, and a non-200 denies it with that status/body sent to the
/// client.
async fn check(State(state): State<Arc<AppState>>, req: Request) -> Response {
    let (parts, body) = req.into_parts();
    let original_path = parts
        .headers
        .get("x-envoy-original-path")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_else(|| parts.uri.path());
    let body_bytes = axum::body::to_bytes(body, 1024 * 1024)
        .await
        .unwrap_or_default();
    tracing::info!(
        method = %parts.method,
        path = %original_path,
        body = %String::from_utf8_lossy(&body_bytes),
        headers = ?parts
            .headers
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_str().unwrap_or("<binary>").to_string()))
            .collect::<Vec<_>>(),
        "ext_authz check"
    );

    let _ = state;
    StatusCode::OK.into_response()
}

pub fn router(state: SharedState) -> Router {
    let _ = Body::default;
    Router::new().route("/authz", any(check)).with_state(state)
}
