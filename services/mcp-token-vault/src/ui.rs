use crate::state::AppState;
use axum::extract::State;
use axum::response::{Html, IntoResponse, Response};
use std::sync::Arc;

/// Landing page for the out-of-band credential UI (WEP-0006): the browser
/// front door for `/oauth/<provider>/start`. Exists because the in-band MCP
/// elicitation path is a dead end -- the AI Gateway proxy swallows the
/// upstream error carrying the elicitation URL, so the connect URL must be a
/// stable address the user knows, not a payload relayed through the proxy.
pub async fn index(State(state): State<Arc<AppState>>) -> Response {
    match index_inner(&state).await {
        Ok(html) => Html(html).into_response(),
        Err(e) => {
            tracing::error!(error = %e, "credential UI index failed");
            Html(format!(
                "<html><body><h3>Credential vault</h3><p>Error: {e:#}</p></body></html>"
            ))
            .into_response()
        }
    }
}

async fn index_inner(state: &AppState) -> anyhow::Result<String> {
    let mut cards = String::new();
    for pc in &state.config.providers {
        let stored = crate::store::get_metadata(&state.pool, &pc.name).await?;
        let status = match &stored {
            None => "<span class=\"missing\">no credential stored</span>".to_string(),
            Some(info) => {
                let expiry = match info.expires_at {
                    Some(t) => format!(
                        ", expires <time>{}</time>",
                        escape(&t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
                    ),
                    None => String::new(),
                };
                format!("<span class=\"ok\">{}</span>{}", escape(&info.kind), expiry)
            }
        };
        let action = if pc
            .token
            .as_ref()
            .and_then(|t| t.authorize_url.as_ref())
            .is_some()
        {
            format!(
                "<a class=\"btn\" href=\"/oauth/{}/start\">Connect {}</a>",
                escape(&pc.name),
                escape(&pc.name)
            )
        } else {
            "<span class=\"hint\">non-interactive: bootstrap via the admin API</span>".to_string()
        };
        cards.push_str(&format!(
            "<section><h2>{}</h2><p class=\"upstream\">{}</p><p class=\"status\">{}</p><p>{}</p></section>",
            escape(&pc.name),
            escape(pc.upstream_url.host_str().unwrap_or("?")),
            status,
            action,
        ));
    }

    Ok(format!(
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">\
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
<title>MCP credential vault</title><style>\
body{{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem;color:#222}}\
h1{{font-size:1.4rem}}section{{border:1px solid #ddd;border-radius:8px;padding:1rem;margin:1rem 0}}\
h2{{margin:0 0 .25rem;font-size:1.1rem;text-transform:capitalize}}\
.upstream{{margin:.1rem 0;color:#666;font-family:monospace;font-size:.85rem}}\
.status{{margin:.5rem 0}}.missing{{color:#b3261e}}.ok{{color:#1b7f37}}\
.hint{{color:#666}}.btn{{display:inline-block;padding:.4rem .9rem;border:1px solid #1a73e8;\
border-radius:6px;color:#1a73e8;text-decoration:none}}\
</style></head><body><h1>MCP credential vault</h1>\
<p>Connect third-party credentials used by the MCP gateway \
(mcp.internal.willpxxr.com). After connecting, retry the failed tool call.</p>\
{cards}</body></html>"
    ))
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

#[cfg(test)]
mod tests {
    use super::escape;

    #[test]
    fn escapes_html() {
        assert_eq!(escape("<b>&\"x\""), "&lt;b&gt;&amp;&quot;x&quot;");
    }
}
