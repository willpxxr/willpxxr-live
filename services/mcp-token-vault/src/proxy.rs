use crate::config::ProviderConfig;
use crate::state::AppState;
use anyhow::{Context, Result, bail};
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

pub async fn handle(state: Arc<AppState>, pc: ProviderConfig, req: Request) -> Response {
    match handle_inner(state, pc, req).await {
        Ok(resp) => resp,
        Err(e) => {
            tracing::error!(error = %e, "proxy error");
            (StatusCode::BAD_GATEWAY, format!("{e:#}")).into_response()
        }
    }
}

async fn handle_inner(state: Arc<AppState>, pc: ProviderConfig, req: Request) -> Result<Response> {
    let stored = crate::store::get(&state.pool, &state.key, &pc.name).await?;
    if stored.is_none() {
        tracing::info!(provider = %pc.name, "no credential, triggering elicitation");
        return Ok(crate::oauth::missing_credential_response(
            &state.config,
            &pc.name,
        ));
    }

    let (parts, body) = req.into_parts();
    let path = parts
        .uri
        .path_and_query()
        .map(|pq| pq.as_str().to_string())
        .unwrap_or_else(|| "/".to_string());
    let url = format!("{}{}", pc.upstream_url.as_str().trim_end_matches('/'), path);
    let bytes = axum::body::to_bytes(body, MAX_REQUEST_BODY)
        .await
        .context("reading request body")?;

    let mut auth = match stored.as_ref().map(|c| c.kind.as_str()) {
        Some("oauth") => crate::refresh::current_access(&state, &pc, false).await?,
        Some("api_key") => stored
            .and_then(|c| c.access)
            .ok_or_else(|| anyhow::anyhow!("provider {} has no api key", pc.name))?,
        Some(other) => bail!("unknown credential kind {other}"),
        None => unreachable!("checked above"),
    };

    let mut resp = send(&state, &parts.method, &url, &parts.headers, &auth, &bytes).await?;

    if resp.status() == StatusCode::UNAUTHORIZED && pc.token.is_some() {
        tracing::info!(provider = %pc.name, "upstream 401, forcing refresh");
        auth = crate::refresh::current_access(&state, &pc, true).await?;
        resp = send(&state, &parts.method, &url, &parts.headers, &auth, &bytes).await?;
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
