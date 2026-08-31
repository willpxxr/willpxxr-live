use crate::crypto::Key;
use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use sqlx::{PgPool, Row, postgres::PgPoolOptions};

pub struct Credential {
    pub kind: String,
    pub access: Option<String>,
    pub refresh: Option<String>,
    pub expires_at: Option<DateTime<Utc>>,
    pub scopes: Option<String>,
}

pub async fn connect(url: &str) -> Result<PgPool> {
    PgPoolOptions::new()
        .max_connections(5)
        .acquire_timeout(std::time::Duration::from_secs(10))
        .connect(url)
        .await
        .context("connecting to database")
}

pub async fn migrate(pool: &PgPool) -> Result<()> {
    sqlx::migrate!("./migrations")
        .run(pool)
        .await
        .context("running migrations")?;
    Ok(())
}

pub async fn upsert(
    pool: &PgPool,
    key: &Key,
    provider: &str,
    kind: &str,
    access: Option<&str>,
    refresh: Option<&str>,
    expires_at: Option<DateTime<Utc>>,
    scopes: Option<&str>,
) -> Result<()> {
    sqlx::query(
        "INSERT INTO credentials
             (provider, principal, kind, access_token_enc, refresh_token_enc, expires_at, scopes, rotated_at)
         VALUES ($1, 'default', $2, $3, $4, $5, $6, now())
         ON CONFLICT (provider, principal) DO UPDATE SET
             kind = EXCLUDED.kind,
             access_token_enc = EXCLUDED.access_token_enc,
             refresh_token_enc = COALESCE(EXCLUDED.refresh_token_enc, credentials.refresh_token_enc),
             expires_at = EXCLUDED.expires_at,
             scopes = COALESCE(EXCLUDED.scopes, credentials.scopes),
             rotated_at = now()",
    )
    .bind(provider)
    .bind(kind)
    .bind(access.map(|s| key.encrypt_string(s)).transpose()?)
    .bind(refresh.map(|s| key.encrypt_string(s)).transpose()?)
    .bind(expires_at)
    .bind(scopes)
    .execute(pool)
    .await
    .context("upserting credential")?;
    Ok(())
}

pub async fn get(pool: &PgPool, key: &Key, provider: &str) -> Result<Option<Credential>> {
    let row = sqlx::query(
        "SELECT kind, access_token_enc, refresh_token_enc, expires_at, scopes
         FROM credentials
         WHERE provider = $1 AND principal = 'default'",
    )
    .bind(provider)
    .fetch_optional(pool)
    .await
    .context("fetching credential")?;

    let Some(row) = row else {
        return Ok(None);
    };

    let kind: String = row.get("kind");
    let access_enc: Option<Vec<u8>> = row.try_get("access_token_enc")?;
    let refresh_enc: Option<Vec<u8>> = row.try_get("refresh_token_enc")?;
    Ok(Some(Credential {
        kind,
        access: access_enc.map(|b| key.decrypt_string(&b)).transpose()?,
        refresh: refresh_enc.map(|b| key.decrypt_string(&b)).transpose()?,
        expires_at: row.try_get("expires_at")?,
        scopes: row.try_get("scopes")?,
    }))
}

pub struct PendingElicitation {
    pub provider: String,
    pub code_verifier: String,
}

pub async fn insert_pending(
    pool: &PgPool,
    state_param: &str,
    provider: &str,
    code_verifier: &str,
) -> Result<()> {
    sqlx::query(
        "INSERT INTO pending_elicitations (state_param, provider, code_verifier)
         VALUES ($1, $2, $3)
         ON CONFLICT (state_param) DO UPDATE SET
             provider = EXCLUDED.provider,
             code_verifier = EXCLUDED.code_verifier,
             created_at = now()",
    )
    .bind(state_param)
    .bind(provider)
    .bind(code_verifier)
    .execute(pool)
    .await
    .context("inserting pending elicitation")?;
    Ok(())
}

pub async fn take_pending(pool: &PgPool, state_param: &str) -> Result<Option<PendingElicitation>> {
    let row = sqlx::query(
        "DELETE FROM pending_elicitations WHERE state_param = $1
         RETURNING provider, code_verifier",
    )
    .bind(state_param)
    .fetch_optional(pool)
    .await
    .context("consuming pending elicitation")?;
    Ok(row.map(|r| PendingElicitation {
        provider: r.get("provider"),
        code_verifier: r.get("code_verifier"),
    }))
}

pub async fn purge_old_pending(pool: &PgPool) -> Result<()> {
    sqlx::query("DELETE FROM pending_elicitations WHERE created_at < now() - interval '1 hour'")
        .execute(pool)
        .await
        .context("purging stale elicitations")?;
    Ok(())
}
