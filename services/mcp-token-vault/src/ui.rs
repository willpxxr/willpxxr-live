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
                let scopes = info
                    .scopes
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .map(|s| format!(", granted scopes: <code>{}</code>", escape(s)))
                    .unwrap_or_default();
                format!(
                    "<span class=\"ok\">{}</span>{}{}",
                    escape(&info.kind),
                    expiry,
                    scopes
                )
            }
        };
        let action = match pc.token.as_ref().filter(|t| t.authorize_url.is_some()) {
            None => "<span class=\"hint\">non-interactive: bootstrap via the admin API</span>"
                .to_string(),
            Some(token) => {
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
                if defaults.is_empty() && optionals.is_empty() {
                    // No scope model configured: plain connect link.
                    format!(
                        "<a class=\"btn\" href=\"/oauth/{}/start\">Connect {}</a>",
                        escape(&pc.name),
                        escape(&pc.name)
                    )
                } else {
                    // Collapsible scope picker: defaults pre-checked,
                    // optionals unticked; the ticked set is requested at
                    // authorize (validated against this list server-side).
                    // Submitting with nothing ticked falls back to the
                    // default set.
                    let checkbox = |scope: &str, checked: bool| {
                        format!(
                            "<label><input type=\"checkbox\" name=\"scopes\" value=\"{}\"{}> {}</label>",
                            escape(scope),
                            if checked { " checked" } else { "" },
                            escape(scope)
                        )
                    };
                    let mut rows: Vec<String> =
                        defaults.iter().map(|s| checkbox(s, true)).collect();
                    rows.extend(
                        optionals
                            .iter()
                            .filter(|s| !defaults.contains(s))
                            .map(|s| checkbox(s, false)),
                    );
                    format!(
                        "<details><summary class=\"btn\">Connect {}</summary>\
<form method=\"get\" action=\"/oauth/{}/start\">{}\
<button type=\"submit\">Authorize</button>\
<p class=\"hint\">untick everything to connect with the default set ({})</p>\
</form></details>",
                        escape(&pc.name),
                        escape(&pc.name),
                        rows.concat(),
                        escape(&defaults.join(","))
                    )
                }
            }
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
.hint{{color:#666;font-size:.85rem}}.btn{{display:inline-block;padding:.4rem .9rem;border:1px solid #1a73e8;\
border-radius:6px;color:#1a73e8;text-decoration:none;cursor:pointer}}details{{margin:.5rem 0}}summary.btn{{list-style:none}}summary.btn::before{{content:\"+ \"}}details[open] summary.btn::before{{content:\"− \"}}form{{margin:.6rem 0 0}}form label{{display:block;margin:.25rem 0}}form button{{margin-top:.5rem;padding:.4rem .9rem;\
border:1px solid #1a73e8;border-radius:6px;background:#1a73e8;color:#fff;cursor:pointer}}\
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
