use anyhow::{Context, Result, bail};
use std::collections::BTreeMap;

#[derive(Clone, Debug)]
pub struct TokenConfig {
    pub token_url: String,
    pub client_id: String,
    pub client_secret: String,
    pub authorize_url: Option<String>,
    pub scopes: Option<String>,
    pub redirect_uri: Option<String>,
}

#[derive(Clone, Debug)]
pub struct ProviderConfig {
    pub name: String,
    pub listen_port: u16,
    pub upstream_url: reqwest::Url,
    pub token: Option<TokenConfig>,
}

#[derive(Clone, Debug)]
pub struct Config {
    pub database_url: String,
    pub admin_port: u16,
    pub oauth_port: u16,
    pub admin_token: Option<String>,
    pub elicitation_base_url: Option<String>,
    pub providers: Vec<ProviderConfig>,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        let database_url = std::env::var("DATABASE_URL").context("DATABASE_URL not set")?;
        let admin_port = std::env::var("ADMIN_PORT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(9090);
        let oauth_port = std::env::var("OAUTH_PORT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(9091);
        let admin_token = std::env::var("ADMIN_TOKEN").ok().filter(|s| !s.is_empty());
        let elicitation_base_url = std::env::var("ELICITATION_BASE_URL")
            .ok()
            .filter(|s| !s.is_empty());

        let mut names: BTreeMap<String, u16> = BTreeMap::new();
        for (k, v) in std::env::vars() {
            if let Some(rest) = k.strip_prefix("PROVIDER_")
                && let Some(name) = rest.strip_suffix("_LISTEN_PORT") {
                    let port: u16 = v.parse().with_context(|| format!("bad port for {name}"))?;
                    names.insert(name.to_lowercase(), port);
                }
        }
        if names.is_empty() {
            bail!("no PROVIDER_*_LISTEN_PORT configured");
        }

        let mut providers = Vec::new();
        for (name, listen_port) in names {
            let prefix = format!("PROVIDER_{}_", name.to_uppercase());
            let upstream = std::env::var(format!("{prefix}UPSTREAM_URL"))
                .with_context(|| format!("{prefix}UPSTREAM_URL not set"))?;
            let upstream_url: reqwest::Url = upstream
                .parse()
                .with_context(|| format!("bad upstream url for {name}"))?;
            let token = match (
                std::env::var(format!("{prefix}TOKEN_URL")),
                std::env::var(format!("{prefix}CLIENT_ID")),
                std::env::var(format!("{prefix}CLIENT_SECRET")),
                std::env::var(format!("{prefix}AUTHORIZE_URL")),
                std::env::var(format!("{prefix}REDIRECT_URI")),
                std::env::var(format!("{prefix}SCOPES")),
            ) {
                (Ok(token_url), Ok(client_id), Ok(client_secret), Err(_), _, _) => {
                    Some(TokenConfig {
                        token_url,
                        client_id,
                        client_secret,
                        authorize_url: None,
                        scopes: None,
                        redirect_uri: None,
                    })
                }
                (
                    Ok(token_url),
                    Ok(client_id),
                    Ok(client_secret),
                    Ok(authorize_url),
                    Ok(redirect_uri),
                    scopes,
                ) => Some(TokenConfig {
                    token_url,
                    client_id,
                    client_secret,
                    authorize_url: Some(authorize_url),
                    scopes: scopes.ok().filter(|s| !s.is_empty()),
                    redirect_uri: Some(redirect_uri),
                }),
                _ => bail!(
                    "provider {name}: TOKEN_URL/CLIENT_ID/CLIENT_SECRET must be set; AUTHORIZE_URL requires REDIRECT_URI"
                ),
            };
            providers.push(ProviderConfig {
                name,
                listen_port,
                upstream_url,
                token,
            });
        }

        Ok(Self {
            database_url,
            admin_port,
            oauth_port,
            admin_token,
            elicitation_base_url,
            providers,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_provider_env() {
        unsafe {
            std::env::set_var("DATABASE_URL", "postgres://x");
            std::env::set_var("PROVIDER_LINEAR_LISTEN_PORT", "8081");
            std::env::set_var("PROVIDER_LINEAR_UPSTREAM_URL", "https://mcp.linear.app/mcp");
            std::env::set_var(
                "PROVIDER_LINEAR_TOKEN_URL",
                "https://auth.linear.app/oauth/token",
            );
            std::env::set_var("PROVIDER_LINEAR_CLIENT_ID", "id");
            std::env::set_var("PROVIDER_LINEAR_CLIENT_SECRET", "secret");
        }
        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.providers.len(), 1);
        let p = &cfg.providers[0];
        assert_eq!(p.name, "linear");
        assert_eq!(p.listen_port, 8081);
        assert_eq!(p.upstream_url.as_str(), "https://mcp.linear.app/mcp");
        assert!(p.token.is_some());
    }
}
