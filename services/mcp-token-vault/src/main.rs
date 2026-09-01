mod admin;
mod authz;
mod config;
mod crypto;
mod oauth;
mod proxy;
mod refresh;
mod state;
mod store;
mod ui;

use anyhow::Result;
use axum::Router;
use state::SharedState;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "mcp_token_vault=info,sqlx=warn".into()),
        )
        .init();

    let state: SharedState = state::build().await?;
    let cfg = state.config.clone();

    tokio::spawn(refresh::run_loop(state.clone(), cfg.providers.clone()));

    let admin_state = state.clone();
    let admin_listener = tokio::net::TcpListener::bind(("0.0.0.0", cfg.admin_port)).await?;
    tracing::info!(port = cfg.admin_port, "admin listening");
    tokio::spawn(async move {
        axum::serve(admin_listener, admin::router(admin_state))
            .with_graceful_shutdown(shutdown())
            .await
            .ok();
    });

    let oauth_state = state.clone();
    let oauth_listener = tokio::net::TcpListener::bind(("0.0.0.0", cfg.oauth_port)).await?;
    tracing::info!(port = cfg.oauth_port, "oauth listening");
    tokio::spawn(async move {
        axum::serve(oauth_listener, admin::oauth_router(oauth_state))
            .with_graceful_shutdown(shutdown())
            .await
            .ok();
    });

    let authz_state = state.clone();
    let authz_listener = tokio::net::TcpListener::bind(("0.0.0.0", cfg.authz_port)).await?;
    tracing::info!(port = cfg.authz_port, "authz listening");
    tokio::spawn(async move {
        axum::serve(authz_listener, authz::router(authz_state))
            .with_graceful_shutdown(shutdown())
            .await
            .ok();
    });

    let proxy_state = state.clone();
    let proxy_listener = tokio::net::TcpListener::bind(("0.0.0.0", cfg.proxy_port)).await?;
    tracing::info!(port = cfg.proxy_port, "proxy listening");
    tokio::spawn(async move {
        let app = Router::new().fallback(move |req: axum::extract::Request| {
            let st = proxy_state.clone();
            async move { proxy::handle(st, req).await }
        });
        axum::serve(proxy_listener, app)
            .with_graceful_shutdown(shutdown())
            .await
            .ok();
    });

    shutdown().await;
    tracing::info!("shutting down");
    Ok(())
}

async fn shutdown() {
    let ctrl_c = tokio::signal::ctrl_c();
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("install SIGTERM handler");
        tokio::select! {
            _ = ctrl_c => {},
            _ = term.recv() => {},
        }
    }
    #[cfg(not(unix))]
    {
        let _ = ctrl_c.await;
    }
}
