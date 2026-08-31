mod admin;
mod config;
mod crypto;
mod oauth;
mod proxy;
mod refresh;
mod state;
mod store;

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

    let mut handles = Vec::new();
    for pc in cfg.providers {
        let st = state.clone();
        let pc_task = pc.clone();
        let port = pc.listen_port;
        let app = Router::new().fallback(move |req: axum::extract::Request| {
            let st = st.clone();
            let pc = pc_task.clone();
            async move { proxy::handle(st, pc, req).await }
        });
        let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
        tracing::info!(provider = %pc.name, port, "proxy listening");
        handles.push(tokio::spawn(async move {
            axum::serve(listener, app)
                .with_graceful_shutdown(shutdown())
                .await
                .ok();
        }));
    }

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
