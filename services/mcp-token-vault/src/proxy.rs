use crate::state::AppState;
use anyhow::{Context, Result};
use axum::body::Body;
use axum::extract::Request;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use std::sync::Arc;

const MAX_REQUEST_BODY: usize = 2 * 1024 * 1024;
const REQUEST_STRIP: &[&str] = &[
    "host",
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "content-length",
    "authorization",
];
const RESPONSE_STRIP: &[&str] = &[
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "content-length",
    "date",
    "server",
];

/// MCP proxy endpoint: one listener, path-dispatched by provider
/// (`/{provider}/...`). Injects the fresh upstream bearer per request;
/// unknown provider -> 404; missing credential -> 401 with the elicitation
/// URL. Network-trusted (CNP restricts ingress to envoy-gateway-system).
pub async fn handle(state: Arc<AppState>, req: Request) -> Response {
    match handle_inner(state, req).await {
        Ok(resp) => resp,
        Err(e) => {
            tracing::error!(error = %e, "proxy error");
            (StatusCode::BAD_GATEWAY, format!("{e:#}")).into_response()
        }
    }
}

async fn handle_inner(state: Arc<AppState>, req: Request) -> Result<Response> {
    let (parts, body) = req.into_parts();
    let full_path = parts.uri.path().to_string();
    let provider_name = full_path
        .trim_start_matches('/')
        .split('/')
        .next()
        .unwrap_or("")
        .to_string();
    let Some(pc) = state
        .config
        .providers
        .iter()
        .find(|p| p.name == provider_name)
        .cloned()
    else {
        return Ok((
            StatusCode::NOT_FOUND,
            format!("unknown provider path /{provider_name}"),
        )
            .into_response());
    };
    let prefix = format!("/{provider_name}");
    let remainder = full_path.strip_prefix(&prefix).unwrap_or("").to_string();
    let query = parts
        .uri
        .query()
        .map(|q| format!("?{q}"))
        .unwrap_or_default();

    let cred = crate::store::get(&state.pool, &state.key, &pc.name).await?;
    let token = match cred.as_ref().map(|c| c.kind.as_str()) {
        Some("oauth") => crate::refresh::current_access(&state, &pc, false).await?,
        Some("api_key") => cred
            .and_then(|c| c.access)
            .ok_or_else(|| anyhow::anyhow!("provider {} has no api key", pc.name))?,
        _ => {
            let url = crate::oauth::elicitation_url(&state.config, &pc.name)
                .unwrap_or_else(|| format!("/oauth/{}/start", pc.name));
            return Ok((
                StatusCode::UNAUTHORIZED,
                format!("no credential stored for provider {provider_name}; connect at {url}"),
            )
                .into_response());
        }
    };

    let upstream = pc.upstream_url.as_str().trim_end_matches('/');
    let url = format!("{upstream}{remainder}{query}");
    let bytes = axum::body::to_bytes(body, MAX_REQUEST_BODY)
        .await
        .context("reading request body")?;

    let mut resp = send(&state, &parts.method, &url, &parts.headers, &token, &bytes).await?;
    if resp.status() == StatusCode::UNAUTHORIZED && pc.token.is_some() {
        tracing::info!(provider = %pc.name, "upstream 401, forcing refresh");
        let token = crate::refresh::current_access(&state, &pc, true).await?;
        resp = send(&state, &parts.method, &url, &parts.headers, &token, &bytes).await?;
    }

    let status = resp.status();
    let mut builder = Response::builder().status(status);
    for (name, value) in resp.headers() {
        if RESPONSE_STRIP.contains(&name.as_str()) {
            continue;
        }
        builder = builder.header(name, value);
    }
    let body = Body::from_stream(resp.bytes_stream());
    builder.body(body).context("building upstream response")
}

async fn send(
    state: &AppState,
    method: &axum::http::Method,
    url: &str,
    headers: &axum::http::HeaderMap,
    auth: &str,
    body: &[u8],
) -> Result<reqwest::Response> {
    let mut out_headers = reqwest::header::HeaderMap::new();
    for (name, value) in headers.iter() {
        if REQUEST_STRIP.contains(&name.as_str()) {
            continue;
        }
        out_headers.append(name.clone(), value.clone());
    }

    let response = state
        .client
        .request(method.clone(), url)
        .headers(out_headers)
        .bearer_auth(auth)
        .body(body.to_vec())
        .send()
        .await
        .context("upstream request failed")?;
    Ok(response)
}
